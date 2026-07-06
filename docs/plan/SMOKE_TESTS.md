# Indra — Pending local smoke tests (for the user's Mac)

Accumulating queue of things only verifiable on real Apple hardware. Development never blocks
on these; run them whenever convenient and report results (a GitHub issue comment or a session
message is fine). Items are grouped by phase and removed once confirmed.

## Phase 0/1 (optional, low priority — everything below is also covered by CI/local tests)

1. `cd backend && uv venv && source .venv/bin/activate && uv pip install -e ".[dev]" && pytest -q`
   → expect all green on macOS (validates soundfile/av wheels on Apple Silicon).
2. `python -m indra.server --project /tmp/scratch.indra --port 0` → note port; `curl -s
   http://127.0.0.1:$PORT/health` → `{"status":"ok"}`.
3. Import a real WAV of yours via curl (token in `~/Library/Application Support/Indra/
   session.json`), then open `dev/api_probe.html`, paste port + token, press "probe" →
   waveform + spectrogram render.
4. `cd apple/IndraKit && swift test --parallel` with Xcode 16.2+ → 47 tests green on macOS
   (CI only proves Linux).
