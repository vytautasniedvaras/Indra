"""Server configuration."""

from __future__ import annotations

import os
import secrets
import sys
from dataclasses import dataclass, field
from pathlib import Path


def default_session_file() -> Path:
    """Platform path for the session handshake file (port + bearer token)."""
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support" / "Indra"
    else:
        xdg = os.environ.get("XDG_DATA_HOME")
        base = (Path(xdg) if xdg else Path.home() / ".local" / "share") / "indra"
    return base / "session.json"


@dataclass
class ServerConfig:
    project_root: Path
    token: str = field(default_factory=lambda: secrets.token_urlsafe(32))
    host: str = "127.0.0.1"  # loopback only; never 0.0.0.0
    port: int = 0
    max_workers: int | None = None
    cache_limit_bytes: int = 8 * 1024**3
    session_file: Path = field(default_factory=default_session_file)

    def resolved_max_workers(self) -> int:
        if self.max_workers is not None:
            return max(1, self.max_workers)
        return max(1, (os.cpu_count() or 2) - 1)
