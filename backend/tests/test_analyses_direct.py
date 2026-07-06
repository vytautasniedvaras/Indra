"""In-process tests for analysis internals that otherwise only run inside
worker processes (coverage there is invisible): onsets, novelty, the runner,
the import pipeline, block-region reads, and the feature store."""

from __future__ import annotations

import multiprocessing
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from indra.analyses.novelty import _checkerboard_kernel, foote_novelty
from indra.analyses.onsets import detect_onsets
from indra.analyses.runner import run_analysis
from indra.ingest.blocks import read_blocks, read_range
from indra.ingest.pipeline import run_import
from indra.jobs.cancellation import JobCancelledError
from indra.storage.features import minmax_buckets, read_feature, write_feature
from indra.storage.paths import ProjectPaths
from tests.conftest import SR


class _Queue:
    def put_nowait(self, item: object) -> None: ...
    def put(self, item: object) -> None: ...
    def get(self, block: bool = True, timeout: float | None = None) -> object: ...


@pytest.fixture(scope="module")
def cancel_event():  # type: ignore[no-untyped-def]
    return multiprocessing.Manager().Event()


@pytest.fixture(scope="module")
def structured_wav(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """6 s: tone → noise, clicks at 1.0 s and 4.0 s."""
    rng = np.random.default_rng(9)
    t = np.arange(3 * SR) / SR
    tone = 0.5 * np.sin(2 * np.pi * 330.0 * t)
    noise = (0.4 * rng.standard_normal(3 * SR)).clip(-1, 1)
    y = np.concatenate([tone, noise]).astype(np.float32)
    for click_t in (1.0, 4.0):
        i = int(click_t * SR)
        y[i : i + 200] += 0.9 * np.hanning(200)
    path = tmp_path_factory.mktemp("direct") / "structured.wav"
    sf.write(path, y.clip(-1, 1), SR, subtype="FLOAT")
    return path


# -- blocks region reads ---------------------------------------------------------


def test_read_blocks_region(structured_wav: Path) -> None:
    whole = np.concatenate(list(read_blocks(structured_wav, 8192)), axis=0)
    part = np.concatenate(list(read_blocks(structured_wav, 8192, 1000, 9000)), axis=0)
    assert part.shape[0] == 8000
    assert np.array_equal(part, whole[1000:9000])


def test_read_range(structured_wav: Path) -> None:
    chunk = read_range(structured_wav, 500, 1500)
    assert chunk.shape[0] == 1000


def test_read_blocks_av_region(fixture_dir: Path) -> None:
    part = np.concatenate(list(read_blocks(fixture_dir / "tone.m4a", 4096, 2000, 6000)), axis=0)
    assert part.shape[0] == 4000


# -- onsets ------------------------------------------------------------------------


def test_detect_onsets_direct(structured_wav: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    result = detect_onsets(structured_wav, SR, {}, cancel_event)
    assert result["env"].shape == result["env_t"].shape
    # The click in silence-backed tone (1.0 s) and the tone→noise section
    # boundary (3.0 s) are the salient events; a click buried in loud noise
    # is legitimately suppressed by PCEN normalization.
    for expected in (1.0, 3.0):
        assert np.min(np.abs(result["onset_t"] - expected)) < 0.1


def test_detect_onsets_region(structured_wav: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    result = detect_onsets(structured_wav, SR, {"region": {"t0": 3.5, "t1": 6.0}}, cancel_event)
    assert result["env_t"][0] >= 3.49
    # Within the noise-only region the buried click IS the salient event.
    assert np.min(np.abs(result["onset_t"] - 4.0)) < 0.1
    assert np.all(np.abs(result["onset_t"] - 1.0) > 0.5), "click outside region must not appear"


def test_detect_onsets_cancelled(structured_wav: Path) -> None:
    event = multiprocessing.Manager().Event()
    event.set()
    with pytest.raises(JobCancelledError):
        detect_onsets(structured_wav, SR, {}, event)


# -- novelty -----------------------------------------------------------------------


def test_checkerboard_kernel_shape_and_balance() -> None:
    kernel = _checkerboard_kernel(8)
    assert kernel.shape == (17, 17)
    assert abs(float(kernel.sum())) < 1e-9  # balanced +/- quadrants
    assert kernel[10, 10] > 0 and kernel[10, 4] < 0


def test_foote_novelty_boundary(structured_wav: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    out = foote_novelty(
        structured_wav, SR, {"scales_s": [2.0], "hop": 1024}, cancel_event, duration_s=6.0
    )
    novelty = out["novelty_2s"]
    times = out["time_s"]
    peak_t = float(times[int(novelty.argmax())])
    assert abs(peak_t - 3.0) < 1.0


def test_foote_novelty_chroma_feature(structured_wav: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    out = foote_novelty(
        structured_wav,
        SR,
        {"feature": "chroma", "scales_s": [2.0], "hop": 1024},
        cancel_event,
        duration_s=6.0,
    )
    assert len(out["novelty_2s"]) == len(out["time_s"]) > 0


def test_foote_novelty_too_short(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    path = tmp_path / "tiny.wav"
    sf.write(path, np.zeros(2048, dtype=np.float32), SR, subtype="FLOAT")
    out = foote_novelty(path, SR, {"scales_s": [8.0]}, cancel_event)
    assert len(out["time_s"]) == 0


# -- import pipeline + runner (in-process) ------------------------------------------


def test_run_import_and_run_analysis_direct(  # type: ignore[no-untyped-def]
    structured_wav: Path, tmp_path: Path, cancel_event
) -> None:
    project = tmp_path / "direct.indra"
    spec = {
        "params": {"path": str(structured_wav), "mode": "copy", "project_root": str(project)},
        "audio_id": "",
    }
    queue = _Queue()
    result = run_import(spec, cancel_event, queue)
    audio_id = result["audio_id"]
    assert not result["already_imported"]
    paths = ProjectPaths(project)
    assert paths.waveform_zarr(audio_id).exists()
    assert paths.spec_zarr(audio_id).exists()

    analysis = run_analysis(
        {
            "params": {"_kind": "roughness_mpt", "project_root": str(project)},
            "audio_id": audio_id,
        },
        cancel_event,
        queue,
    )
    feature_path = project / analysis["feature_path"]
    assert feature_path.exists()
    columns, metadata = read_feature(feature_path)
    assert metadata["kind"] == "roughness_mpt"
    assert len(columns["value"]) == analysis["stats"]["n"]


def test_run_analysis_unknown_audio(tmp_path: Path, cancel_event) -> None:  # type: ignore[no-untyped-def]
    project = tmp_path / "empty.indra"
    ProjectPaths(project).ensure()
    with pytest.raises(ValueError, match="unknown audio"):
        run_analysis(
            {
                "params": {"_kind": "roughness_mpt", "project_root": str(project)},
                "audio_id": "nope",
            },
            cancel_event,
            _Queue(),
        )


# -- feature store -------------------------------------------------------------------


def test_feature_roundtrip_and_metadata(tmp_path: Path) -> None:
    paths = ProjectPaths(tmp_path / "f.indra")
    paths.ensure()
    times = np.linspace(0, 10, 101).astype(np.float32)
    values = np.sin(times).astype(np.float32)
    out = write_feature(
        paths,
        "aud1",
        "roughness_mpt",
        "k" * 32,
        {"time_s": times, "value": values},
        {"hop": 1024},
        22050,
    )
    columns, metadata = read_feature(out)
    assert metadata["params"] == {"hop": 1024}
    assert metadata["sr"] == 22050
    np.testing.assert_allclose(columns["value"], values, rtol=1e-6)
    assert list(columns["frame_index"][:3]) == [0, 1, 2]


def test_feature_column_length_mismatch(tmp_path: Path) -> None:
    paths = ProjectPaths(tmp_path / "g.indra")
    paths.ensure()
    with pytest.raises(ValueError, match="length"):
        write_feature(
            paths,
            "a",
            "k",
            "x" * 32,
            {"time_s": np.zeros(5, np.float32), "value": np.zeros(4, np.float32)},
            {},
            22050,
        )


def test_minmax_buckets_extrema_and_edges() -> None:
    times = np.arange(100, dtype=np.float64)
    values = np.zeros(100, dtype=np.float32)
    values[37] = 5.0
    values[71] = -3.0
    buckets = minmax_buckets(times, values, 10)
    assert len(buckets["min"]) == 10
    assert max(buckets["max"]) == 5.0
    assert min(buckets["min"]) == -3.0
    assert minmax_buckets(times, values, 0) == {"t": [], "min": [], "max": []}
    assert minmax_buckets(times[:0], values[:0], 4) == {"t": [], "min": [], "max": []}
    # more buckets than points clamps
    small = minmax_buckets(times[:3], values[:3], 10)
    assert len(small["min"]) == 3
