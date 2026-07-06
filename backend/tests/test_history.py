"""Annotation CRUD + backend-authoritative undo/redo (§7, Phase 3)."""

from __future__ import annotations

from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from tests.conftest import SR, wait_for_job


@pytest.fixture(scope="module")
def audio_id(client: TestClient, tmp_path_factory: pytest.TempPathFactory) -> str:
    path = tmp_path_factory.mktemp("hist") / "quiet.wav"
    sf.write(path, (0.2 * np.sin(np.arange(SR) / 30)).astype(np.float32), SR, subtype="FLOAT")
    response = client.post("/files/import", json={"path": str(path), "mode": "copy"})
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    assert info["state"] == "done", info
    return str(info["result_ref"]["audio_id"])


def _create(client: TestClient, audio_id: str, **kwargs: Any) -> dict[str, Any]:
    body = {"audio_id": audio_id, "t0": 1.0, "t1": 2.0, **kwargs}
    response = client.post("/annotations", json=body)
    assert response.status_code == 200, response.text
    record: dict[str, Any] = response.json()
    return record


def _ids(client: TestClient, audio_id: str) -> list[int]:
    return [a["id"] for a in client.get("/annotations", params={"audio_id": audio_id}).json()]


def test_crud_roundtrip(client: TestClient, audio_id: str) -> None:
    created = _create(client, audio_id, label="drone", note="low beating", f0=50.0, f1=120.0)
    assert created["label"] == "drone"
    assert created["id"] in _ids(client, audio_id)

    patched = client.patch(
        f"/annotations/{created['id']}", json={"note": "slow beating", "t1": 3.5}
    ).json()
    assert patched["note"] == "slow beating"
    assert patched["t1"] == 3.5
    assert patched["label"] == "drone"  # untouched fields survive

    assert client.delete(f"/annotations/{created['id']}").json() == {"deleted": True}
    assert created["id"] not in _ids(client, audio_id)


def test_crud_validation(client: TestClient, audio_id: str) -> None:
    response = client.post("/annotations", json={"audio_id": "nope", "t0": 0, "t1": 1})
    assert response.status_code == 404
    assert (
        client.post("/annotations", json={"audio_id": audio_id, "t0": 5, "t1": 1}).status_code
        == 400
    )
    assert client.patch("/annotations/99999", json={"note": "x"}).status_code == 404
    assert client.delete("/annotations/99999").status_code == 404
    assert client.patch("/annotations/99999", json={}).status_code in (400, 404)


def test_undo_redo_lifecycle(client: TestClient, audio_id: str) -> None:
    created = _create(client, audio_id, label="hit")
    annotation_id = created["id"]

    # undo the create → annotation gone
    undo = client.post("/undo").json()
    assert undo["action_name"] == "Add annotation"
    assert undo["applied_patch"][0]["op"] == "remove"
    assert annotation_id not in _ids(client, audio_id)

    # redo → annotation back with the same id and fields
    redo = client.post("/redo").json()
    assert redo["action_name"] == "Add annotation"
    assert annotation_id in _ids(client, audio_id)
    restored = next(
        a
        for a in client.get("/annotations", params={"audio_id": audio_id}).json()
        if a["id"] == annotation_id
    )
    assert restored["label"] == "hit"


def test_undo_edit_restores_previous_values(client: TestClient, audio_id: str) -> None:
    created = _create(client, audio_id, label="before")
    client.patch(f"/annotations/{created['id']}", json={"label": "after"})
    client.post("/undo")
    current = next(
        a
        for a in client.get("/annotations", params={"audio_id": audio_id}).json()
        if a["id"] == created["id"]
    )
    assert current["label"] == "before"


def test_undo_delete_restores_row(client: TestClient, audio_id: str) -> None:
    created = _create(client, audio_id, label="precious", note="do not lose")
    client.delete(f"/annotations/{created['id']}")
    assert created["id"] not in _ids(client, audio_id)
    client.post("/undo")
    restored = next(
        a
        for a in client.get("/annotations", params={"audio_id": audio_id}).json()
        if a["id"] == created["id"]
    )
    assert restored["note"] == "do not lose"


def test_new_action_invalidates_redo(client: TestClient, audio_id: str) -> None:
    first = _create(client, audio_id, label="one")
    client.post("/undo")  # undo create of "one"
    depth_before = client.post("/redo").json()  # sanity: redo works
    assert depth_before["redo_stack_depth"] == 0
    client.post("/undo")  # undo again → redo stack = 1
    _create(client, audio_id, label="two")  # new action → invalidates redo
    response = client.post("/redo")
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "nothing_to_redo"
    assert first["id"] not in _ids(client, audio_id)


def test_undo_empty_stack_409(client: TestClient, audio_id: str) -> None:
    # drain the stack
    while client.post("/undo").status_code == 200:
        pass
    response = client.post("/undo")
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "nothing_to_undo"


def test_history_lists_recent_actions(client: TestClient, audio_id: str) -> None:
    _create(client, audio_id, label="a")
    created = _create(client, audio_id, label="b")
    client.patch(f"/annotations/{created['id']}", json={"note": "n"})
    entries = client.get("/history").json()
    names = [e["action_name"] for e in entries]
    assert names[0] == "Edit annotation"
    assert "Add annotation" in names
    assert all(set(e) == {"id", "ts", "scope", "action_name"} for e in entries)


def test_depths_reported(client: TestClient, audio_id: str) -> None:
    _create(client, audio_id)
    _create(client, audio_id)
    undo = client.post("/undo").json()
    assert undo["undo_stack_depth"] >= 1
    assert undo["redo_stack_depth"] == 1
