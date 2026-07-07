"""Onset tweaking: pick_peaks seam, /onsets/repick (batch re-thresholding on the
saved envelope, synchronous) and /onsets/commit (picked onsets → point
annotations as ONE undoable action)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from indra.analyses.onsets import pick_peaks
from tests.conftest import SR, wait_for_job


def _synthetic_envelope() -> tuple[Any, Any]:
    """60 s envelope at 200 fps: 8 strong peaks, 8 weak peaks, mild noise floor."""
    rng = np.random.default_rng(11)
    n = 60 * 200
    env = 0.02 * np.abs(rng.standard_normal(n)).astype(np.float32)
    for i, t in enumerate(range(2, 58, 7)):  # strong every 7 s
        env[t * 200] = 1.0 - 0.02 * i
    for t in range(5, 55, 7):  # weak, offset by 3 s from the strong ones
        env[t * 200] = 0.25
    times = (np.arange(n) / 200.0).astype(np.float32)
    return env, times


def test_pick_peaks_delta_monotonic() -> None:
    env, times = _synthetic_envelope()
    counts = [len(pick_peaks(env, times, {"delta": d})["onset_t"]) for d in (0.05, 0.15, 0.5)]
    assert counts[0] >= counts[1] >= counts[2], counts
    assert counts[0] > counts[2], "raising delta must eventually drop the weak peaks"
    # loosest pick sees both families, strictest only the strong one
    assert counts[0] >= 16
    assert counts[2] == pytest.approx(8, abs=1)


def test_pick_peaks_wait_enforces_gap() -> None:
    env, times = _synthetic_envelope()
    picked = pick_peaks(env, times, {"delta": 0.05, "wait_s": 5.0})["onset_t"]
    assert len(picked) >= 2
    assert float(np.min(np.diff(picked))) >= 5.0 - 1e-3


@pytest.fixture(scope="module")
def click_wav(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """10 s of quiet noise with 5 loud clicks and 3 soft clicks."""
    rng = np.random.default_rng(3)
    y = (0.01 * rng.standard_normal(10 * SR)).astype(np.float32)
    for t in (1.0, 3.0, 5.0, 7.0, 9.0):
        i = int(t * SR)
        y[i : i + 150] += 0.9 * np.hanning(150).astype(np.float32)
    for t in (2.0, 4.5, 8.0):
        i = int(t * SR)
        y[i : i + 150] += 0.12 * np.hanning(150).astype(np.float32)
    path = tmp_path_factory.mktemp("repick") / "clicks.wav"
    sf.write(path, y.clip(-1, 1), SR, subtype="FLOAT")
    return path


@pytest.fixture(scope="module")
def audio_id(client: TestClient, click_wav: Path) -> str:
    response = client.post("/files/import", json={"path": str(click_wav), "mode": "copy"})
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    return str(info["result_ref"]["audio_id"])


@pytest.fixture(scope="module")
def onsets_result(client: TestClient, audio_id: str) -> dict[str, Any]:
    response = client.post(
        "/analyze", json={"kind": "onsets_superflux_pcen", "audio_id": audio_id, "params": {}}
    )
    info = wait_for_job(client, response.json()["job_id"], timeout_s=300.0)
    assert info["state"] == "done", info
    result: dict[str, Any] = info["result_ref"]
    return result


def test_repick_default_matches_original(
    client: TestClient, audio_id: str, onsets_result: dict[str, Any]
) -> None:
    """No overrides → the re-pick reproduces the original detection exactly."""
    response = client.post("/onsets/repick", json={"audio_id": audio_id})
    assert response.status_code == 200, response.text
    repicked = response.json()
    assert repicked["source_key"] == onsets_result["cache_key"]
    assert repicked["onsets"]["t"] == pytest.approx(onsets_result["onsets"]["t"], abs=1e-4)


def test_repick_delta_rethresholds(client: TestClient, audio_id: str, onsets_result: dict) -> None:  # type: ignore[type-arg]
    loose = client.post("/onsets/repick", json={"audio_id": audio_id, "delta": 0.02}).json()
    strict = client.post("/onsets/repick", json={"audio_id": audio_id, "delta": 0.6}).json()
    assert loose["n"] >= strict["n"]
    # strict keeps the loud clicks
    strict_t = np.asarray(strict["onsets"]["t"])
    assert strict["n"] >= 3
    for expected in (1.0, 5.0, 9.0):
        assert float(np.min(np.abs(strict_t - expected))) < 0.1
    # loose finds at least one of the soft clicks the strict pass drops
    loose_t = np.asarray(loose["onsets"]["t"])
    soft_hits = sum(float(np.min(np.abs(loose_t - t))) < 0.1 for t in (2.0, 4.5, 8.0))
    assert soft_hits >= 1


def test_repick_region_scopes_the_pick(
    client: TestClient, audio_id: str, onsets_result: dict
) -> None:  # type: ignore[type-arg]
    response = client.post(
        "/onsets/repick",
        json={"audio_id": audio_id, "delta": 0.02, "region": {"t0": 4.0, "t1": 8.0}},
    )
    onsets = response.json()["onsets"]["t"]
    assert onsets, "region re-pick found nothing"
    assert all(4.0 <= t <= 8.0 for t in onsets)


def test_repick_unknown_audio_404(client: TestClient) -> None:
    assert client.post("/onsets/repick", json={"audio_id": "nope"}).status_code == 404


def test_commit_onsets_single_undo(
    client: TestClient, audio_id: str, onsets_result: dict[str, Any]
) -> None:
    """Committing N picked onsets creates N point annotations undone by ONE /undo."""
    picked = client.post("/onsets/repick", json={"audio_id": audio_id, "delta": 0.6}).json()
    commit = client.post(
        "/onsets/commit",
        json={
            "audio_id": audio_id,
            "times": picked["onsets"]["t"],
            "strengths": picked["onsets"]["strength"],
        },
    )
    assert commit.status_code == 200, commit.text
    created = commit.json()["created"]
    assert created == picked["n"] > 0

    rows = client.get("/annotations", params={"audio_id": audio_id}).json()
    onset_rows = [r for r in rows if r["label"] == "onset"]
    assert len(onset_rows) == created
    assert all(r["t0"] == r["t1"] for r in onset_rows)

    undo = client.post("/undo")
    assert undo.status_code == 200
    assert f"{created} onsets" in undo.json()["action_name"]
    rows_after = client.get("/annotations", params={"audio_id": audio_id}).json()
    assert not [r for r in rows_after if r["label"] == "onset"]

    redo = client.post("/redo")
    assert redo.status_code == 200
    rows_redone = client.get("/annotations", params={"audio_id": audio_id}).json()
    assert len([r for r in rows_redone if r["label"] == "onset"]) == created
