"""API contract tests: auth, error envelope shape, endpoint schemas."""

from __future__ import annotations

from fastapi.testclient import TestClient

from tests.conftest import TEST_TOKEN


def _error_shape(body: dict) -> None:  # type: ignore[type-arg]
    assert set(body) == {"error"}
    assert set(body["error"]) == {"code", "message", "details"}


def test_health_needs_no_token(client: TestClient) -> None:
    response = client.get("/health", headers={"Authorization": ""})
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_missing_token_rejected(client: TestClient) -> None:
    response = client.get("/project", headers={"Authorization": ""})
    assert response.status_code == 401
    _error_shape(response.json())


def test_wrong_token_rejected(client: TestClient) -> None:
    response = client.get("/project", headers={"Authorization": "Bearer nope"})
    assert response.status_code == 401


def test_right_token_accepted(client: TestClient) -> None:
    response = client.get("/project", headers={"Authorization": f"Bearer {TEST_TOKEN}"})
    assert response.status_code == 200


def test_project_shape(client: TestClient) -> None:
    body = client.get("/project").json()
    assert body["format_version"] == 1
    assert body["engine_version"].startswith("indra-engine")
    assert body["root"].endswith(".indra")


def test_files_initially_empty(client: TestClient) -> None:
    assert client.get("/files").json() == []


def test_import_missing_file_404(client: TestClient) -> None:
    response = client.post("/files/import", json={"path": "/nonexistent/file.wav"})
    assert response.status_code == 404
    body = response.json()
    _error_shape(body)
    assert body["error"]["code"] == "not_found"


def test_import_validation_error_422(client: TestClient) -> None:
    response = client.post("/files/import", json={"mode": "copy"})
    assert response.status_code == 422
    body = response.json()
    _error_shape(body)
    assert body["error"]["code"] == "validation_error"


def test_import_bad_mode_422(client: TestClient) -> None:
    response = client.post("/files/import", json={"path": "/tmp/x.wav", "mode": "hardlink"})
    assert response.status_code == 422


def test_analyze_unknown_kind_400(client: TestClient) -> None:
    response = client.post("/analyze", json={"kind": "nonsense"})
    assert response.status_code == 400
    _error_shape(response.json())


def test_analyze_import_kind_rejected(client: TestClient) -> None:
    response = client.post("/analyze", json={"kind": "import"})
    assert response.status_code == 400


def test_unknown_job_404(client: TestClient) -> None:
    for method, url in [
        ("GET", "/jobs/doesnotexist"),
        ("POST", "/jobs/doesnotexist/cancel"),
        ("GET", "/jobs/doesnotexist/events"),
    ]:
        response = client.request(method, url)
        assert response.status_code == 404, url
        _error_shape(response.json())


def test_manifest_unknown_audio_404(client: TestClient) -> None:
    response = client.get("/files/deadbeef/manifest")
    assert response.status_code == 404
