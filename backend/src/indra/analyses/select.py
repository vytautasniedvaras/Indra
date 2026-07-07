"""Magic selection: seeded region-growing over the time-frequency plane.

Photoshop-magic-wand analog for sound, computed on the PRECOMPUTED uint8 dB
spectrogram pyramid (no audio decode — fast and file-length independent):

- `magic_select`: flood-fill from a seed point/box, keeping cells whose level
  is within `tolerance_db` of the seed statistic. `adapt="local_median"`
  makes the criterion contextual: cell and seed levels are measured RELATIVE
  to their own time-slice's median (local noise floor), so quiet-but-distinct
  textures are selectable even when absolute level drifts.
- `similar_segments`: multimodal "select the same thing everywhere" — matches
  the seed's band-energy profile across the whole file, optionally weighted by
  any already-computed feature curves (roughness/entropy/harmonicity).

Results are "ribbons": per-time-column frequency intervals — compact, drawable
as spectrogram overlays, and directly convertible to audition masks.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Callable
from itertools import pairwise
from pathlib import Path
from typing import Any

import numpy as np
import zarr
from numpy.typing import NDArray

from indra.jobs.cancellation import CancelEvent, check_cancel

# Bound the working window regardless of file length (§4.4): cells at the
# chosen LOD, time extent capped around the seed.
MAX_WINDOW_CELLS = 4_000_000
MAX_EXTENT_S = 600.0

FloatArray = NDArray[np.float32]


class SpecPyramid:
    """The precomputed dB pyramid, opened once: attrs + LOD-budget choices."""

    def __init__(self, spec_path: Path) -> None:
        self.group = zarr.open_group(str(spec_path), mode="r")
        self.sr = int(self.group.attrs["sr"])
        self.hop = int(self.group.attrs["hop"])
        self.n_fft = int(self.group.attrs["n_fft"])
        self.n_bins = int(self.group.attrs["n_bins"])
        self.levels = int(self.group.attrs["levels"])

    @property
    def hz_per_bin(self) -> float:
        return self.sr / self.n_fft

    def s_per_col(self, lod: int) -> float:
        return float(self.hop * (2**lod)) / self.sr

    def finest_lod_for_span(self, span_s: float) -> int:
        """Finest LOD whose cell count over span_s fits the window budget."""
        lod = 0
        while lod < self.levels - 1:
            if (span_s / self.s_per_col(lod)) * self.n_bins <= MAX_WINDOW_CELLS:
                break
            lod += 1
        return lod

    def finest_whole_file_lod(self) -> int:
        """Finest LOD whose full array fits the window budget (coarsest fallback)."""
        for lod in range(self.levels):
            arr = self.group[str(lod)]
            if int(arr.shape[0]) * int(arr.shape[1]) <= MAX_WINDOW_CELLS:
                return lod
        return self.levels - 1

    def read(self, lod: int, c0: int = 0, c1: int | None = None) -> FloatArray:
        arr = self.group[str(lod)]
        # uint8 counts as dB*2.55 units
        return np.asarray(arr[c0:c1] if c1 is not None else arr[:], dtype=np.float32)


def _load_window(
    pyramid: SpecPyramid, t_center: float, extent_s: float
) -> tuple[FloatArray, int, float, float]:
    """Load a dB window (frames, bins) around t_center at the finest LOD that
    fits the cell budget. Returns (window, lod, t_start_s, s_per_col)."""
    lod = pyramid.finest_lod_for_span(2 * extent_s)
    s_per_col = pyramid.s_per_col(lod)
    n_frames = int(pyramid.group[str(lod)].shape[0])
    c0 = max(0, int((t_center - extent_s) / s_per_col))
    c1 = min(n_frames, int((t_center + extent_s) / s_per_col) + 1)
    return pyramid.read(lod, c0, c1), lod, c0 * s_per_col, s_per_col


def _adapted(window: FloatArray, adapt: str) -> FloatArray:
    """Contextual level: subtract each time-slice's median (local noise floor)."""
    if adapt == "local_median":
        adjusted: FloatArray = window - np.median(window, axis=1, keepdims=True)
        return adjusted
    return window


def _seed_cells(
    seed: dict[str, Any],
    t_start: float,
    s_per_col: float,
    hz_per_bin: float,
    shape: tuple[int, int],
) -> tuple[slice, slice]:
    """Seed point/box → (col slice, bin slice), clamped, at least 1 cell."""
    if "t" in seed:  # point (with a small neighborhood for a stable statistic)
        col = int((float(seed["t"]) - t_start) / s_per_col)
        bin_ = int(float(seed["f"]) / hz_per_bin)
        c = slice(max(0, col - 1), min(shape[0], col + 2))
        b = slice(max(0, bin_ - 2), min(shape[1], bin_ + 3))
    else:  # box
        c = slice(
            max(0, int((float(seed["t0"]) - t_start) / s_per_col)),
            min(shape[0], int((float(seed["t1"]) - t_start) / s_per_col) + 1),
        )
        b = slice(
            max(0, int(float(seed["f0"]) / hz_per_bin)),
            min(shape[1], int(float(seed["f1"]) / hz_per_bin) + 1),
        )
    if c.stop <= c.start or b.stop <= b.start:
        raise ValueError("seed is outside the analyzed area")
    return c, b


def _mask_to_ribbons(
    mask: NDArray[np.bool_], t_start: float, s_per_col: float, hz_per_bin: float
) -> list[dict[str, Any]]:
    """Boolean (frames, bins) mask → per-column frequency intervals."""
    ribbons: list[dict[str, Any]] = []
    for col in range(mask.shape[0]):
        row = mask[col]
        if not row.any():
            continue
        edges = np.flatnonzero(np.diff(np.concatenate(([0], row.view(np.int8), [0]))))
        intervals = [
            [float(lo * hz_per_bin), float(hi * hz_per_bin)]
            for lo, hi in zip(edges[0::2], edges[1::2], strict=True)
        ]
        ribbons.append(
            {
                "t0": t_start + col * s_per_col,
                "t1": t_start + (col + 1) * s_per_col,
                "intervals": intervals,
            }
        )
    return ribbons


def magic_select(
    spec_path: Path,
    seed: dict[str, Any],
    params: dict[str, Any],
    cancel_event: CancelEvent,
) -> dict[str, Any]:
    """Seeded region grow. Returns ribbons + stats + the boolean mask window."""
    tolerance = float(params.get("tolerance_db", 8.0)) * 2.55  # dB → uint8 units
    contiguous = bool(params.get("contiguous", True))
    adapt = str(params.get("adapt", "local_median"))
    extent_s = min(float(params.get("max_extent_s", 120.0)), MAX_EXTENT_S)

    t_seed = float(seed.get("t", (float(seed.get("t0", 0)) + float(seed.get("t1", 0))) / 2))
    pyramid = SpecPyramid(spec_path)
    window, lod, t_start, s_per_col = _load_window(pyramid, t_seed, extent_s)
    check_cancel(cancel_event)
    hz_per_bin = pyramid.hz_per_bin

    levels = _adapted(window, adapt)
    cols, bins = _seed_cells(seed, t_start, s_per_col, hz_per_bin, levels.shape)
    # Seed statistic: the SALIENT level in the neighborhood (90th percentile),
    # not the median — a point seed on a thin spectral line has mostly off-line
    # cells around it, and their median matches neither the line nor the floor.
    seed_level = float(np.percentile(levels[cols, bins], 90.0))

    within = np.abs(levels - seed_level) <= tolerance
    if not contiguous:
        mask = within
    else:
        # BFS flood fill (4-connectivity) from every seed cell.
        mask = np.zeros_like(within, dtype=bool)
        queue: deque[tuple[int, int]] = deque()
        for c in range(cols.start, cols.stop):
            for b in range(bins.start, bins.stop):
                if within[c, b] and not mask[c, b]:
                    mask[c, b] = True
                    queue.append((c, b))
        steps = 0
        n_cols, n_rows = within.shape
        while queue:
            c, b = queue.popleft()
            steps += 1
            if steps % 100_000 == 0:
                check_cancel(cancel_event)
            for dc, db_ in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nc, nb = c + dc, b + db_
                if 0 <= nc < n_cols and 0 <= nb < n_rows and within[nc, nb] and not mask[nc, nb]:
                    mask[nc, nb] = True
                    queue.append((nc, nb))

    ribbons = _mask_to_ribbons(mask, t_start, s_per_col, hz_per_bin)
    cells = int(mask.sum())
    result: dict[str, Any] = {
        "ribbons": ribbons,
        "lod": lod,
        "seconds_per_column": s_per_col,
        "hz_per_bin": hz_per_bin,
        "cells": cells,
        "seed_level_db": seed_level / 2.55,
        "bounds": None,
    }
    if ribbons:
        f_lo = min(i[0] for r in ribbons for i in r["intervals"])
        f_hi = max(i[1] for r in ribbons for i in r["intervals"])
        result["bounds"] = {
            "t0": ribbons[0]["t0"],
            "t1": ribbons[-1]["t1"],
            "f0": f_lo,
            "f1": f_hi,
        }
    return result


# Fixed log-spaced band edges in Hz: profiles from files with different sample
# rates land in the SAME 24-dimensional space, so seeds transfer across files.
PROFILE_BANDS_HZ: FloatArray = np.geomspace(40.0, 16000.0, 25).astype(np.float32)
N_PROFILE_BANDS = len(PROFILE_BANDS_HZ) - 1


def file_profiles(spec_path: Path, cancel_event: CancelEvent) -> tuple[FloatArray, float, int]:
    """Unit-normalized band-deviation profiles for a whole file.

    Returns (unit_profiles [n_cols, 24], seconds_per_column, lod). Bands are
    fixed Hz ranges (PROFILE_BANDS_HZ); bands above the file's Nyquist are
    zero, which after baseline removal reads as "no deviation" — profiles from
    different sample rates stay comparable.
    """
    import scipy.ndimage

    pyramid = SpecPyramid(spec_path)
    # Coarse LOD: whole-file scan must stay bounded.
    lod = pyramid.finest_whole_file_lod()
    s_per_col = pyramid.s_per_col(lod)
    spec = pyramid.read(lod)
    check_cancel(cancel_event)

    hz_per_bin = pyramid.hz_per_bin
    n_bins = spec.shape[1]
    n_cols = spec.shape[0]
    bands = []
    for f_lo, f_hi in pairwise(PROFILE_BANDS_HZ):
        lo = min(n_bins, max(1, int(f_lo / hz_per_bin)))
        hi = min(n_bins, max(lo + 1, int(f_hi / hz_per_bin) + 1))
        if lo >= n_bins:  # band entirely above Nyquist
            bands.append(np.zeros(n_cols, dtype=np.float32))
        else:
            bands.append(spec[:, lo:hi].mean(axis=1))
    profiles = np.stack(bands, axis=1)
    # Remove the file's per-band baseline (median over time): raw dB profiles
    # are dominated by the shared noise floor, making every column look alike.
    # After this, profiles describe what DEVIATES from the file's background —
    # which also removes per-file level/EQ offsets, so seeds transfer.
    profiles = profiles - np.median(profiles, axis=0, keepdims=True)
    # Texture is a time-extended property: smooth profiles over ~0.25 s to
    # suppress per-column jitter before angular comparison.
    smooth_cols = max(1, round(0.25 / s_per_col))
    profiles = scipy.ndimage.uniform_filter1d(profiles, smooth_cols, axis=0)
    norms = np.linalg.norm(profiles, axis=1, keepdims=True)
    # Columns at the baseline have ~zero deviation: give them a tiny unit
    # vector so their cosine distance to any real seed is ~1 (dissimilar).
    unit: FloatArray = profiles / np.maximum(norms, 1e-3)
    return unit, s_per_col, lod


def _segments_from_distance(
    distance: FloatArray, s_per_col: float, threshold: float, min_len_s: float, unit: FloatArray
) -> list[dict[str, Any]]:
    """Threshold a distance curve into segments; each carries its mean profile."""
    matched = distance <= threshold
    # close 1-column gaps, then extract runs
    for col in range(1, len(matched) - 1):
        if not matched[col] and matched[col - 1] and matched[col + 1]:
            matched[col] = True
    segments: list[dict[str, Any]] = []
    run_start: int | None = None
    for col, hit in enumerate(np.concatenate([matched, [False]])):
        if hit and run_start is None:
            run_start = col
        elif not hit and run_start is not None:
            t0, t1 = run_start * s_per_col, col * s_per_col
            if t1 - t0 >= min_len_s:
                profile = unit[run_start:col].mean(axis=0)
                profile /= max(float(np.linalg.norm(profile)), 1e-6)
                segments.append(
                    {
                        "t0": float(t0),
                        "t1": float(t1),
                        "distance": float(distance[run_start:col].mean()),
                        "_profile": profile,
                    }
                )
            run_start = None
    return segments


N_SEED_EXEMPLARS = 5


def seed_exemplars(
    spec_path: Path, seed: dict[str, Any], cancel_event: CancelEvent
) -> tuple[FloatArray, FloatArray, float, int, tuple[int, int]]:
    """Seed exemplar matrix [k, bands] + the seed file's own profiles.

    Exemplars are the mean profile PLUS evenly spaced columns across the seed
    window. A target column matches if it matches ANY exemplar, so an evolving
    seed (a sweep, a gesture) is matched phase-by-phase instead of being
    smeared into one average profile that resembles none of its moments.
    """
    unit, s_per_col, lod = file_profiles(spec_path, cancel_event)
    c0 = max(0, int(float(seed["t0"]) / s_per_col))
    c1 = min(unit.shape[0], int(float(seed["t1"]) / s_per_col) + 1)
    if c1 <= c0:
        raise ValueError("seed region is empty at scan resolution")
    mean = unit[c0:c1].mean(axis=0)
    mean /= max(float(np.linalg.norm(mean)), 1e-6)
    picks = np.unique(np.linspace(c0, c1 - 1, N_SEED_EXEMPLARS).astype(int))
    exemplars = np.vstack([mean[np.newaxis, :], unit[picks]])
    return exemplars.astype(np.float32), unit, s_per_col, lod, (c0, c1)


def _exemplar_distance(unit: FloatArray, exemplars: FloatArray) -> FloatArray:
    """Cosine distance to the NEAREST exemplar, per column."""
    distance: FloatArray = (1.0 - (unit @ exemplars.T).max(axis=1)).astype(np.float32)
    return distance


def similar_segments(
    spec_path: Path,
    seed: dict[str, Any],
    params: dict[str, Any],
    cancel_event: CancelEvent,
    feature_curves: dict[str, tuple[FloatArray, FloatArray]] | None = None,
) -> dict[str, Any]:
    """Find time segments whose spectral (and feature) profile matches the seed.

    Multimodal distance = cosine distance of band-energy profiles, optionally
    averaged with normalized distances of any provided feature curves
    (feature_curves: kind -> (times, values), e.g. an already-computed
    roughness or entropy curve).
    """
    threshold = float(params.get("threshold", 0.4))
    min_len_s = float(params.get("min_segment_s", 0.5))

    exemplars, unit, s_per_col, lod, (c0, c1) = seed_exemplars(spec_path, seed, cancel_event)
    distance = _exemplar_distance(unit, exemplars)

    if feature_curves:
        times = np.arange(unit.shape[0]) * s_per_col
        for _kind, (f_times, f_values) in feature_curves.items():
            if len(f_values) < 2:
                continue
            resampled = np.interp(times, f_times, f_values)
            spread = float(resampled.std()) or 1.0
            seed_mean = float(resampled[c0:c1].mean())
            distance = distance + np.abs(resampled - seed_mean) / (3.0 * spread)
        distance = distance / (1 + len(feature_curves))

    check_cancel(cancel_event)
    segments = _segments_from_distance(
        distance.astype(np.float32), s_per_col, threshold, min_len_s, unit
    )
    for segment in segments:
        del segment["_profile"]
    return {
        "segments": segments,
        "lod": lod,
        "seconds_per_column": s_per_col,
        "threshold": threshold,
        "features_used": sorted(feature_curves) if feature_curves else [],
    }


def similar_segments_multi(
    seed_spec_path: Path,
    seed: dict[str, Any],
    targets: list[tuple[str, Path]],
    params: dict[str, Any],
    cancel_event: CancelEvent,
    progress_cb: Callable[[float], None] | None = None,
) -> dict[str, Any]:
    """Folder-wide similar search: one seed, segments from MANY files.

    The seed vector is computed once from the seed file; every target file is
    scanned in the shared fixed-Hz profile space (per-file baseline removal
    keeps different noise floors / levels / sample rates comparable). Feature
    curves are per-file quantities and don't apply here.
    """
    threshold = float(params.get("threshold", 0.4))
    min_len_s = float(params.get("min_segment_s", 0.5))
    embed = bool(params.get("embed", False))

    exemplars, _unit, _spc, _lod, _cols = seed_exemplars(seed_spec_path, seed, cancel_event)
    segments: list[dict[str, Any]] = []
    scanned: list[str] = []
    for index, (audio_id, spec_path) in enumerate(targets):
        check_cancel(cancel_event)
        if not spec_path.exists():
            continue
        unit, s_per_col, _ = file_profiles(spec_path, cancel_event)
        distance = _exemplar_distance(unit, exemplars)
        for segment in _segments_from_distance(distance, s_per_col, threshold, min_len_s, unit):
            segment["audio_id"] = audio_id
            segments.append(segment)
        scanned.append(audio_id)
        if progress_cb is not None:
            progress_cb((index + 1) / len(targets))

    segments.sort(key=lambda s: s["distance"])
    result: dict[str, Any] = {
        "segments": segments,
        "threshold": threshold,
        "scanned": scanned,
    }
    if embed and segments:
        result["embedding"] = embed_segments([s["_profile"] for s in segments])
    for segment in segments:
        del segment["_profile"]
    return result


def embed_segments(profiles: list[FloatArray]) -> dict[str, Any]:
    """Cluster-map support: 2-D coordinates + hierarchical cluster labels.

    Input: one unit profile vector per segment. Output coords are the first two
    principal components (deterministic sign convention); clusters come from
    average-linkage agglomeration on cosine distance, cut at 0.4 — the same
    scale as the search threshold, so "one cluster" ≈ "would match each other".
    """
    import scipy.cluster.hierarchy as hierarchy

    matrix = np.stack(profiles, axis=0)
    centered = matrix - matrix.mean(axis=0, keepdims=True)
    _u, _s, vt = np.linalg.svd(centered, full_matrices=False)
    axes = vt[:2] if vt.shape[0] >= 2 else np.vstack([vt, np.zeros_like(vt[:1])])
    # Deterministic orientation: make each axis's largest component positive.
    for axis in axes:
        if axis[np.argmax(np.abs(axis))] < 0:
            axis *= -1
    coords = centered @ axes.T
    if len(profiles) >= 2:
        linkage = hierarchy.linkage(matrix, method="average", metric="cosine")
        labels = hierarchy.fcluster(linkage, t=0.4, criterion="distance")
    else:
        labels = np.ones(len(profiles), dtype=int)
    return {
        "xy": [[float(x), float(y)] for x, y in coords],
        "cluster": [int(label) for label in labels],
        "n_clusters": int(labels.max()) if len(labels) else 0,
    }
