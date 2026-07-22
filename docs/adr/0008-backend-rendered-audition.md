# 0008. Backend-rendered STFT→mask→ISTFT audition (not realtime EQ)
Date: 2026-07-06
Status: accepted
Context: TIAALS-style "hear the selected time-frequency box in isolation" needs clean spectral isolation. Realtime AVAudioUnitEQ band-passing smears arbitrary masks (lasso, harmonic-follower) and cannot match RX-quality isolation.
Decision: POST /audition sends a mask spec; the backend renders STFT → mask (with fade edges) → ISTFT to a scratch WAV keyed by mask hash (cached); the client schedules that WAV on an AVAudioPlayerNode. A quick-preview fallback uses steep parametric EQ bands while the render is in flight.
Consequences: Audition latency = render time (mitigated by caching and the EQ preview); highest isolation quality; mask rendering is headlessly testable.
Alternatives considered: realtime EQ only (poor quality on complex masks), client-side FFT masking (duplicates DSP stack in Swift).
