"""Backend-authoritative undo history (BUILD_SPEC §7.1).

Every annotation mutation goes through HistoryManager, which mutates the DB in
a transaction and appends an undo_log row holding RFC-6902 forward + inverse
patches against the logical document
    { "annotations": { "<id>": {…fields…} } }.
Undo applies the inverse patch, redo the forward patch; any new forward action
invalidates the redo stack (standard branching model). Analysis cache
regeneration is derived data and never enters the log.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Any

from indra.storage.db import Database

SCOPE_ANNOTATIONS = "annotations"

_ANNOTATION_FIELDS = ("audio_id", "t0", "t1", "f0", "f1", "label", "note")


class HistoryError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _annotation_value(row: sqlite3.Row) -> dict[str, Any]:
    return {field: row[field] for field in _ANNOTATION_FIELDS}


class HistoryManager:
    """Owns annotation mutations + the undo/redo log."""

    def __init__(self, db: Database) -> None:
        self._db = db

    # -- annotation operations (forward actions) --------------------------------

    def create_annotation(self, fields: dict[str, Any]) -> dict[str, Any]:
        with self._db.tx() as conn:
            cursor = conn.execute(
                "INSERT INTO annotations (audio_id, t0, t1, f0, f1, label, note)"
                " VALUES (?,?,?,?,?,?,?)",
                tuple(fields.get(f) for f in _ANNOTATION_FIELDS),
            )
            annotation_id = int(cursor.lastrowid or 0)
            row = conn.execute("SELECT * FROM annotations WHERE id=?", (annotation_id,)).fetchone()
            value = _annotation_value(row)
            self._append(
                conn,
                "Add annotation",
                forward=[{"op": "add", "path": f"/annotations/{annotation_id}", "value": value}],
                inverse=[{"op": "remove", "path": f"/annotations/{annotation_id}"}],
            )
            return dict(row)

    def update_annotation(self, annotation_id: int, updates: dict[str, Any]) -> dict[str, Any]:
        with self._db.tx() as conn:
            old = conn.execute("SELECT * FROM annotations WHERE id=?", (annotation_id,)).fetchone()
            if old is None:
                raise HistoryError("not_found", f"no such annotation: {annotation_id}")
            fields = {k: v for k, v in updates.items() if k in _ANNOTATION_FIELDS}
            if not fields:
                raise HistoryError("bad_request", "no updatable fields in patch")
            assignments = ", ".join(f"{name}=?" for name in fields)
            conn.execute(
                f"UPDATE annotations SET {assignments}, updated_at=datetime('now') WHERE id=?",
                (*fields.values(), annotation_id),
            )
            new = conn.execute("SELECT * FROM annotations WHERE id=?", (annotation_id,)).fetchone()
            self._append(
                conn,
                "Edit annotation",
                forward=[
                    {
                        "op": "replace",
                        "path": f"/annotations/{annotation_id}",
                        "value": _annotation_value(new),
                    }
                ],
                inverse=[
                    {
                        "op": "replace",
                        "path": f"/annotations/{annotation_id}",
                        "value": _annotation_value(old),
                    }
                ],
            )
            return dict(new)

    def delete_annotation(self, annotation_id: int) -> None:
        with self._db.tx() as conn:
            old = conn.execute("SELECT * FROM annotations WHERE id=?", (annotation_id,)).fetchone()
            if old is None:
                raise HistoryError("not_found", f"no such annotation: {annotation_id}")
            conn.execute("DELETE FROM annotations WHERE id=?", (annotation_id,))
            self._append(
                conn,
                "Delete annotation",
                forward=[{"op": "remove", "path": f"/annotations/{annotation_id}"}],
                inverse=[
                    {
                        "op": "add",
                        "path": f"/annotations/{annotation_id}",
                        "value": _annotation_value(old),
                    }
                ],
            )

    # -- undo / redo --------------------------------------------------------------

    def undo(self) -> dict[str, Any]:
        with self._db.tx() as conn:
            row = conn.execute(
                "SELECT * FROM undo_log WHERE undone=0 ORDER BY id DESC LIMIT 1"
            ).fetchone()
            if row is None:
                raise HistoryError("nothing_to_undo", "undo stack is empty")
            patch = json.loads(str(row["inverse_patch"]))
            self._apply_patch(conn, patch)
            conn.execute("UPDATE undo_log SET undone=1 WHERE id=?", (row["id"],))
            return self._response(conn, row, patch)

    def redo(self) -> dict[str, Any]:
        with self._db.tx() as conn:
            row = conn.execute(
                "SELECT * FROM undo_log WHERE undone=1 ORDER BY id ASC LIMIT 1"
            ).fetchone()
            if row is None:
                raise HistoryError("nothing_to_redo", "redo stack is empty")
            patch = json.loads(str(row["forward_patch"]))
            self._apply_patch(conn, patch)
            conn.execute("UPDATE undo_log SET undone=0 WHERE id=?", (row["id"],))
            return self._response(conn, row, patch)

    def history(self, limit: int = 100) -> list[dict[str, Any]]:
        rows = self._db.query(
            "SELECT id, ts, scope, action_name FROM undo_log WHERE undone=0"
            " ORDER BY id DESC LIMIT ?",
            (limit,),
        )
        return [dict(row) for row in rows]

    def depths(self) -> tuple[int, int]:
        row = self._db.query_one(
            "SELECT SUM(undone=0) AS undo_n, SUM(undone=1) AS redo_n FROM undo_log"
        )
        if row is None:
            return (0, 0)
        return (int(row["undo_n"] or 0), int(row["redo_n"] or 0))

    # -- internals ------------------------------------------------------------------

    def _append(
        self,
        conn: sqlite3.Connection,
        action_name: str,
        forward: list[dict[str, Any]],
        inverse: list[dict[str, Any]],
    ) -> None:
        # A new forward action invalidates the redo branch (§7.1).
        conn.execute("DELETE FROM undo_log WHERE undone=1")
        conn.execute(
            "INSERT INTO undo_log (scope, action_name, forward_patch, inverse_patch)"
            " VALUES (?,?,?,?)",
            (SCOPE_ANNOTATIONS, action_name, json.dumps(forward), json.dumps(inverse)),
        )

    def _apply_patch(self, conn: sqlite3.Connection, patch: list[dict[str, Any]]) -> None:
        """Interpret RFC-6902 ops against the /annotations/<id> document."""
        for op in patch:
            prefix, _, raw_id = op["path"].rpartition("/")
            if prefix != "/annotations":
                raise HistoryError("internal", f"unsupported patch path: {op['path']}")
            annotation_id = int(raw_id)
            if op["op"] == "remove":
                conn.execute("DELETE FROM annotations WHERE id=?", (annotation_id,))
            elif op["op"] == "add":
                value = op["value"]
                conn.execute(
                    "INSERT OR REPLACE INTO annotations (id, audio_id, t0, t1, f0, f1, label, note)"
                    " VALUES (?,?,?,?,?,?,?,?)",
                    (annotation_id, *(value.get(f) for f in _ANNOTATION_FIELDS)),
                )
            elif op["op"] == "replace":
                value = op["value"]
                assignments = ", ".join(f"{name}=?" for name in _ANNOTATION_FIELDS)
                conn.execute(
                    f"UPDATE annotations SET {assignments}, updated_at=datetime('now') WHERE id=?",
                    (*(value.get(f) for f in _ANNOTATION_FIELDS), annotation_id),
                )
            else:
                raise HistoryError("internal", f"unsupported patch op: {op['op']}")

    def _response(
        self, conn: sqlite3.Connection, row: sqlite3.Row, patch: list[dict[str, Any]]
    ) -> dict[str, Any]:
        undo_n = conn.execute("SELECT COUNT(*) FROM undo_log WHERE undone=0").fetchone()[0]
        redo_n = conn.execute("SELECT COUNT(*) FROM undo_log WHERE undone=1").fetchone()[0]
        return {
            "applied_patch": patch,
            "scope": str(row["scope"]),
            "action_name": str(row["action_name"]),
            "undo_stack_depth": int(undo_n),
            "redo_stack_depth": int(redo_n),
        }
