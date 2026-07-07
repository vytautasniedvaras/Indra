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


def _load_window(
    spec_path: Path, t_center: float, extent_s: float
) -> tuple[FloatArray, int, float, float, int]:
    """Load a dB window (frames, bins) around t_center at the finest LOD that
    fits the cell budget. Returns (window, lod, t_start_s, s_per_col, n_bins)."""
    group = zarr.open_group(str(spec_path), mode="r")
    sr = int(group.attrs["sr"])
    hop = int(group.attrs["hop"])
    n_bins = int(group.attrs["n_bins"])
    levels = int(group.attrs["levels"])

    lod = 0
    while lod < levels - 1:
        s_per_col = hop * (2**lod) / sr
        if (2 * extent_s / s_per_col) * n_bins <= MAX_WINDOW_CELLS:
            break
        lod += 1
    arr = group[str(lod)]
    s_per_col = hop * (2**lod) / sr
    n_frames = int(arr.shape[0])
    c0 = max(0, int((t_center - extent_s) / s_per_col))
    c1 = min(n_frames, int((t_center + extent_s) / s_per_col) + 1)
    window = np.asarray(arr[c0:c1], dtype=np.float32)  # uint8 counts as dB*2.55 units
    return window, lod, c0 * s_per_col, s_per_col, n_bins


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
    window, lod, t_start, s_per_col, _n_bins = _load_window(spec_path, t_seed, extent_s)
    check_cancel(cancel_event)

    group = zarr.open_group(str(spec_path), mode="r")
    sr = int(group.attrs["sr"])
    n_fft = int(group.attrs["n_fft"])
    hz_per_bin = sr / n_fft

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

    group = zarr.open_group(str(spec_path), mode="r")
    sr = int(group.attrs["sr"])
    hop = int(group.attrs["hop"])
    levels = int(group.attrs["levels"])
    # Coarse LOD: whole-file scan must stay bounded.
    lod = levels - 1
    for candidate in range(levels):
        arr = group[str(candidate)]
        if int(arr.shape[0]) * int(arr.shape[1]) <= MAX_WINDOW_CELLS:
            lod = candidate
            break
    arr = group[str(lod)]
    s_per_col = hop * (2**lod) / sr
    spec = np.asarray(arr[:], dtype=np.float32)
    check_cancel(cancel_event)

    # Band-energy profile per column, mel-ish log bin pooling to 24 bands.
    n_bins = spec.shape[1]
    edges = np.unique(np.geomspace(1, n_bins - 1, 25).astype(int))
    profiles = np.stack(
        [spec[:, lo:hi].mean(axis=1) for lo, hi in pairwise(edges)],
        axis=1,
    )
    # Remove the file's per-band baseline (median over time): raw dB profiles
    # are dominated by the shared noise floor, making every column look alike.
    # After this, profiles describe what DEVIATES from the file's background.
    profiles = profiles - np.median(profiles, axis=0, keepdims=True)
    # Texture is a time-extended property: smooth profiles over ~0.25 s to
    # suppress per-column jitter before angular comparison.
    import scipy.ndimage

    smooth_cols = max(1, round(0.25 / s_per_col))
    profiles = scipy.ndimage.uniform_filter1d(profiles, smooth_cols, axis=0)
    norms = np.linalg.norm(profiles, axis=1, keepdims=True)
    # Columns at the baseline have ~zero deviation: give them a tiny unit
    # vector so their cosine distance to any real seed is ~1 (dissimilar).
    unit = profiles / np.maximum(norms, 1e-3)

    c0 = max(0, int(float(seed["t0"]) / s_per_col))
    c1 = min(spec.shape[0], int(float(seed["t1"]) / s_per_col) + 1)
    if c1 <= c0:
        raise ValueError("seed region is empty at scan resolution")
    seed_vec = unit[c0:c1].mean(axis=0)
    seed_vec /= max(float(np.linalg.norm(seed_vec)), 1e-6)
    distance = 1.0 - unit @ seed_vec

    if feature_curves:
        times = np.arange(spec.shape[0]) * s_per_col
        for _kind, (f_times, f_values) in feature_curves.items():
            if len(f_values) < 2:
                continue
            resampled = np.interp(times, f_times, f_values)
            spread = float(resampled.std()) or 1.0
            seed_mean = float(resampled[c0:c1].mean())
            distance = distance + np.abs(resampled - seed_mean) / (3.0 * spread)
        distance = distance / (1 + len(feature_curves))

    check_cancel(cancel_event)
    matched = distance <= threshold
    # close 1-column gaps, then extract runs
    for col in range(1, len(matched) - 1):
        if not matched[col] and matched[col - 1] and matched[col + 1]:
            matched[col] = True
    segments: list[dict[str, float]] = []
    run_start: int | None = None
    for col, hit in enumerate(np.concatenate([matched, [False]])):
        if hit and run_start is None:
            run_start = col
        elif not hit and run_start is not None:
            t0, t1 = run_start * s_per_col, col * s_per_col
            if t1 - t0 >= min_len_s:
                segments.append(
                    {
                        "t0": float(t0),
                        "t1": float(t1),
                        "distance": float(distance[run_start:col].mean()),
                    }
                )
            run_start = None
    return {
        "segments": segments,
        "lod": lod,
        "seconds_per_column": s_per_col,
        "threshold": threshold,
        "features_used": sorted(feature_curves) if feature_curves else [],
    }
