# Indra — session orientation

Native macOS audio-curation tool: Python/FastAPI analysis backend + Swift app.
`docs/BUILD_SPEC.md` is the authoritative spec; deviations live in `docs/plan/STATUS.md`.

Start every session by reading `docs/plan/STATUS.md` (current phase, checklists, next
action). For the why-graph — modules, invariants, decisions and how they connect — use
the knowledge graph at `docs/knowledge/` (conventions in its README; query via the
`basic-memory` MCP tools or `scripts/bm`). Read `docs/architecture.md` before touching
anything load-bearing.

Rules that are easy to get wrong:

- Work on branch `feature/phases-0-4`; PR per phase; NEVER push main.
- Commits: ONE short functional line, conventional prefix (feat:/fix:/docs:/test:/chore:),
  no bodies unless necessary, NO attribution trailers, NO session links.
- Backend gate before any push: `cd backend && .venv/bin/ruff check src tests &&
  .venv/bin/ruff format src tests && .venv/bin/mypy src/indra && .venv/bin/pytest -q --cov=indra`.
- Swift has no local toolchain here — CI verifies it (Linux job + macOS job on `apple/**`).
- Never block on Mac smoke tests; queue them in `docs/plan/SMOKE_TESTS.md`.
- If an analysis' computation changes, bump `ENGINE_VERSION` (see docs/knowledge/invariants/).
- Update STATUS.md and the knowledge graph when you land meaningful work.

Skills in `.claude/skills/` (tdd, codebase-design, code-review, diagnosing-bugs) are the
house method — use them. For Mac-side bug reports, `diagnosing-bugs` is the intended loop.
