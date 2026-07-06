"""SQLite project database: connection, migrations, typed row helpers.

project.sqlite is the only non-regenerable file in a bundle (BUILD_SPEC §4.2).
WAL mode so the server process and worker processes can read/write concurrently.
"""

from __future__ import annotations

import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2

_SCHEMA = """
CREATE TABLE IF NOT EXISTS audio_files (
    id            TEXT PRIMARY KEY,          -- blake3 hex of decoded PCM
    orig_path     TEXT NOT NULL,
    stored_path   TEXT NOT NULL,             -- relative to bundle root
    mode          TEXT NOT NULL CHECK (mode IN ('copy', 'reference')),
    sr            INTEGER NOT NULL,
    channels      INTEGER NOT NULL,
    frames        INTEGER NOT NULL,
    duration_s    REAL NOT NULL,
    format        TEXT NOT NULL,
    imported_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS labels (
    id    INTEGER PRIMARY KEY,
    name  TEXT NOT NULL UNIQUE,
    color TEXT
);

CREATE TABLE IF NOT EXISTS annotations (
    -- AUTOINCREMENT: ids must never be reused, or undo/redo patches that
    -- reference deleted ids would target a recycled row.
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    audio_id   TEXT NOT NULL REFERENCES audio_files(id),
    t0         REAL NOT NULL,
    t1         REAL NOT NULL,
    f0         REAL,
    f1         REAL,
    label      TEXT,
    note       TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_annotations_audio ON annotations(audio_id, t0);

CREATE TABLE IF NOT EXISTS undo_log (
    id            INTEGER PRIMARY KEY,
    ts            TEXT NOT NULL DEFAULT (datetime('now')),
    scope         TEXT NOT NULL,
    action_name   TEXT NOT NULL,
    forward_patch TEXT NOT NULL,              -- RFC-6902 JSON
    inverse_patch TEXT NOT NULL,
    undone        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS analysis_cache (
    key            TEXT PRIMARY KEY,
    audio_id       TEXT NOT NULL DEFAULT '',
    kind           TEXT NOT NULL,
    params_json    TEXT NOT NULL,
    engine_version TEXT NOT NULL,
    result_json    TEXT NOT NULL,
    blob_path      TEXT NOT NULL DEFAULT '',  -- relative to bundle root; '' = inline result only
    blob_kind      TEXT NOT NULL DEFAULT '',
    size_bytes     INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL DEFAULT (datetime('now')),
    last_used_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_cache_lru ON analysis_cache(last_used_at);

CREATE TABLE IF NOT EXISTS jobs (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,
    params_json TEXT NOT NULL,
    state       TEXT NOT NULL,
    started_at  REAL,
    finished_at REAL,
    result_json TEXT,
    error_json  TEXT
);
"""


def _configure(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.row_factory = sqlite3.Row


def open_db(path: Path) -> sqlite3.Connection:
    """Open (and migrate) the project database. Safe to call from any process."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False)
    _configure(conn)
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version < SCHEMA_VERSION:
        with conn:
            if version == 1:
                _migrate_v1_to_v2(conn)
            conn.executescript(_SCHEMA)
            conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
    return conn


def _migrate_v1_to_v2(conn: sqlite3.Connection) -> None:
    """v2: annotations.id becomes AUTOINCREMENT (no rowid reuse; see schema)."""
    conn.executescript(
        """
        ALTER TABLE annotations RENAME TO annotations_v1;
        CREATE TABLE annotations (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            audio_id   TEXT NOT NULL REFERENCES audio_files(id),
            t0         REAL NOT NULL,
            t1         REAL NOT NULL,
            f0         REAL,
            f1         REAL,
            label      TEXT,
            note       TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        INSERT INTO annotations SELECT * FROM annotations_v1;
        DROP TABLE annotations_v1;
        """
    )


class Database:
    """Thread-safe wrapper around the single server-process connection."""

    def __init__(self, path: Path) -> None:
        self._conn = open_db(path)
        self._lock = threading.Lock()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        with self._lock, self._conn:
            yield self._conn

    def query(self, sql: str, params: tuple[Any, ...] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return list(self._conn.execute(sql, params).fetchall())

    def query_one(self, sql: str, params: tuple[Any, ...] = ()) -> sqlite3.Row | None:
        with self._lock:
            row = self._conn.execute(sql, params).fetchone()
            return row  # type: ignore[no-any-return]

    def execute(self, sql: str, params: tuple[Any, ...] = ()) -> None:
        with self._lock, self._conn:
            self._conn.execute(sql, params)
