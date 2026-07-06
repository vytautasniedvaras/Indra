# Vendored: Music Perception Toolbox (mpt)

- Source: https://github.com/andymilne/Music-Perception-Toolbox
- Subdirectory: `python/mpt`
- Commit: `12a006c32f825c406ca2f41a5fcd5870a78c4a56` (v2.0.2 lineage, 2026-04-15)
- License: MIT (see LICENSE in this directory)

Vendored because the upstream package cannot be pip-installed from the
`#subdirectory=python` fragment: its pyproject.toml references
`readme = "../README.md"`, which modern setuptools rejects as outside the
package root (verified with both pip and uv, 2026-07-06; broken at upstream
HEAD too). See ADR 0011.

Files are unmodified from upstream. Import as `from indra._vendor import mpt`.
To update: copy `python/mpt/*.py` from the desired upstream commit, update the
commit SHA here, and re-run `tests/test_mpt_frames.py` golden tests.
