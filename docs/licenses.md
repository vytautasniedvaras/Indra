# Dependency license record

Policy: permissive-only (ADR 0010, BUILD_SPEC §10.6). Every runtime dependency is recorded here
when added. CI runs `pip-licenses` + `backend/scripts/check_licenses.py`, failing on any
AGPL / GPL / LGPL-static / CC-BY-NC / CC-BY-ND / SSPL appearance.

## Direct runtime dependencies (verified 2026-07-06)

| Dependency | Version | License | Notes |
|---|---|---|---|
| fastapi | 0.139.x | MIT | |
| uvicorn | 0.50.x | BSD-3-Clause | |
| sse-starlette | 3.4.x | BSD-3-Clause | |
| pydantic | 2.13.x | MIT | |
| numpy | 2.1.x | BSD-3-Clause | |
| scipy | 1.18.x | BSD-3-Clause | |
| librosa | 0.11.x | ISC | |
| soundfile | 0.14.x | BSD-3-Clause | bundles libsndfile (LGPL, dynamically linked — upstream-sanctioned distribution model) |
| av | 14.2.x | BSD-3-Clause | bundles FFmpeg libs (LGPL build, dynamically linked) |
| pyarrow | 24.x | Apache-2.0 | |
| zarr | 3.2.x | MIT | |
| numcodecs | 0.16.x | MIT | |
| blake3 | 1.0.x | CC0-1.0 OR Apache-2.0 | |
| xxhash | 3.8.x | BSD-2-Clause | |
| libfmp | 1.3.x | MIT | |

## Vendored code

| Package | Location | License | Source |
|---|---|---|---|
| mpt (Music Perception Toolbox) | `backend/src/indra/_vendor/mpt/` | MIT | github.com/andymilne/Music-Perception-Toolbox @ `12a006c` (see VENDOR_README.md, ADR 0011) |

## Documented exceptions

| Package | License | Rationale |
|---|---|---|
| soxr (transitive, via librosa) | LGPL-2.1-or-later | Mandatory hard dependency of spec-pinned librosa. python-soxr is a thin wrapper; the LGPL library is dynamically linked/relinkable, satisfying LGPL §4 for distribution. The policy excludes *LGPL-static* only. Exception encoded in `backend/scripts/check_licenses.py`. |
