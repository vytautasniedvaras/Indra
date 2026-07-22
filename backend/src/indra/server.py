"""Server entrypoint: python -m indra.server --project foo.indra --port 0.

Binds 127.0.0.1 only. Writes {port, token, pid, project} to the session
handshake file so the app can discover a spawned backend (BUILD_SPEC §4.1).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
from pathlib import Path

import uvicorn

from indra.app import create_app
from indra.config import ServerConfig


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="indra.server", description="Indra analysis engine")
    parser.add_argument("--project", required=True, help="path to the .indra project bundle")
    parser.add_argument("--port", type=int, default=0, help="port (0 = pick a free one)")
    parser.add_argument("--workers", type=int, default=None, help="analysis worker processes")
    args = parser.parse_args(argv)

    config = ServerConfig(
        project_root=Path(args.project).expanduser().resolve(),
        port=args.port,
        max_workers=args.workers,
    )
    app = create_app(config)

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((config.host, config.port))
    port = sock.getsockname()[1]

    config.session_file.parent.mkdir(parents=True, exist_ok=True)
    config.session_file.write_text(
        json.dumps(
            {
                "port": port,
                "token": config.token,
                "pid": os.getpid(),
                "project": str(config.project_root),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Indra backend listening on {config.host}:{port}")
    print(f"Session file: {config.session_file}")

    server = uvicorn.Server(uvicorn.Config(app, log_level="info"))
    server.run(sockets=[sock])


if __name__ == "__main__":
    main()
