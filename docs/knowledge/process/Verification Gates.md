---
title: Verification Gates
type: process
tags:
- process
- ci
permalink: indra/process/verification-gates
---

Before any push: `cd backend && .venv/bin/ruff check src tests && .venv/bin/ruff format
src tests && .venv/bin/mypy src/indra && .venv/bin/pytest -q --cov=indra` (coverage
gate ≥80). Swift: Linux `swift test` via Docker if available, else CI. License gate
fails on AGPL/GPL/CC-NC in the backend dependency tree (soxr LGPL-dynamic exception
documented).

- [gotcha] Use `.venv/bin/ruff`, not any global ruff — format version drift broke CI once

## Relations

- documented_in [[Architecture Guide]]