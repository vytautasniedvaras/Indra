"""Audio probing: soundfile first, pyav fallback (BUILD_SPEC §6.2 step 1)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import soundfile as sf


@dataclass(frozen=True)
class ProbeResult:
    sr: int
    channels: int
    frames: int
    duration_s: float
    format: str
    decoder: str  # "soundfile" | "av"


def probe(path: Path) -> ProbeResult:
    try:
        info = sf.info(str(path))
        return ProbeResult(
            sr=int(info.samplerate),
            channels=int(info.channels),
            frames=int(info.frames),
            duration_s=float(info.frames) / float(info.samplerate),
            format=f"{info.format}/{info.subtype}",
            decoder="soundfile",
        )
    except sf.LibsndfileError:
        return _probe_av(path)


def _probe_av(path: Path) -> ProbeResult:
    import av

    with av.open(str(path)) as container:
        streams = [s for s in container.streams if s.type == "audio"]
        if not streams:
            raise ValueError(f"no audio stream in {path}")
        stream = streams[0]
        sr = int(stream.codec_context.sample_rate)
        channels = int(stream.codec_context.channels)
        if stream.duration is not None and stream.time_base is not None:
            duration_s = float(stream.duration * stream.time_base)
        elif container.duration is not None:
            duration_s = container.duration / av.time_base
        else:
            duration_s = 0.0
        return ProbeResult(
            sr=sr,
            channels=channels,
            frames=round(duration_s * sr),
            duration_s=duration_s,
            format=f"{container.format.name}/{stream.codec_context.name}",
            decoder="av",
        )
