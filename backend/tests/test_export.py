"""Export round-trip: project → JSON/CSV → parse → verify fidelity (§6.6, §8.1)."""

from __future__ import annotations

import csv
import io
import json
import zipfile
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from tests.conftest import SR, wait_for_job


@pytest.fixture(scope="module")
def exported_project(
    client: TestClient, tmp_path_factory: pytest.TempPathFactory
) -> dict[str, Any]:
    """Import → analyze (roughness + onsets) → annotate. Returns ids/handles."""
    t = np.arange(2 * SR) / SR
    dyad = 0.4 * np.sin(2 * np.pi * 440.0 * t) + 0.4 * np.sin(2 * np.pi * 466.16 * t)
    tone = 0.5 * np.sin(2 * np.pi * 440.0 * t)
    y = np.concatenate([dyad, tone]).astype(np.float32)
    y[SR : SR + 200] += 0.9 * np.hanning(200)
    path = tmp_path_factory.mktemp("export") / "piece.wav"
    sf.write(path, y.clip(-1, 1), SR, subtype="FLOAT")

    response = client.post("/files/import", json={"path": str(path), "mode": "copy"})
    info = wait_for_job(client, response.json()["job_id"], timeout_s=120.0)
    audio_id = str(info["result_ref"]["audio_id"])

    for kind in ("roughness_mpt", "onsets_superflux_pcen"):
        job = client.post("/analyze", json={"kind": kind, "audio_id": audio_id}).json()
        assert wait_for_job(client, job["job_id"], timeout_s=300.0)["state"] == "done"

    a1 = client.post(
        "/annotations",
        json={"audio_id": audio_id, "t0": 0.5, "t1": 1.5, "label": "dyad", "note": "beating"},
    ).json()
    a2 = client.post(
        "/annotations",
        json={
            "audio_id": audio_id,
            "t0": 2.5,
            "t1": 3.5,
            "f0": 100.0,
            "f1": 4000.0,
            "label": "wash",
        },
    ).json()
    return {"audio_id": audio_id, "annotations": [a1, a2]}


def test_json_export_roundtrip(client: TestClient, exported_project: dict[str, Any]) -> None:
    audio_id = exported_project["audio_id"]
    response = client.post(
        "/export",
        json={
            "audio_id": audio_id,
            "kinds": ["roughness_mpt", "onsets_superflux_pcen"],
            "format": "json",
        },
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")
    assert "attachment" in response.headers["content-disposition"]

    document = json.loads(response.content)
    assert document["schema_version"] == 1
    assert document["engine_version"].startswith("indra-engine")
    assert document["audio"]["sr"] == SR
    assert document["audio"]["duration_s"] == pytest.approx(4.0, abs=0.01)

    labels = {a["label"] for a in document["annotations"]}
    assert labels == {"dyad", "wash"}
    wash = next(a for a in document["annotations"] if a["label"] == "wash")
    assert wash["f0"] == 100.0 and wash["f1"] == 4000.0

    roughness = document["features"]["roughness_mpt"]
    assert len(roughness["value"]) == len(roughness["time_s"]) > 50
    # dyad half must be rougher than pure-tone half
    values = np.asarray(roughness["value"])
    times = np.asarray(roughness["time_s"])
    assert values[times < 1.9].mean() > 2 * values[times >= 2.1].mean()

    assert any(abs(o["t"] - 1.0) < 0.1 for o in document["onsets"]) or any(
        abs(o["t"] - 2.0) < 0.15 for o in document["onsets"]
    )


def test_json_export_region(client: TestClient, exported_project: dict[str, Any]) -> None:
    audio_id = exported_project["audio_id"]
    document = json.loads(
        client.post(
            "/export",
            json={
                "audio_id": audio_id,
                "kinds": ["roughness_mpt"],
                "format": "json",
                "region": {"t0": 0.0, "t1": 2.0},
            },
        ).content
    )
    times = document["features"]["roughness_mpt"]["time_s"]
    assert times[-1] <= 2.0
    labels = {a["label"] for a in document["annotations"]}
    assert labels == {"dyad"}, "annotation outside the region must be excluded"


def test_csv_export_zip(client: TestClient, exported_project: dict[str, Any]) -> None:
    audio_id = exported_project["audio_id"]
    response = client.post(
        "/export",
        json={
            "audio_id": audio_id,
            "kinds": ["roughness_mpt", "onsets_superflux_pcen"],
            "format": "csv",
        },
    )
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/zip"

    archive = zipfile.ZipFile(io.BytesIO(response.content))
    names = set(archive.namelist())
    assert names == {"features.csv", "annotations.csv", "onsets.csv", "manifest.json"}

    features = list(csv.reader(io.TextIOWrapper(archive.open("features.csv"), "utf-8")))
    header, rows = features[0], features[1:]
    assert header[0] == "time_s"
    assert "roughness_mpt.value" in header
    assert len(rows) > 50
    assert all(len(row) == len(header) for row in rows)

    annotations = list(csv.reader(io.TextIOWrapper(archive.open("annotations.csv"), "utf-8")))
    assert annotations[0][:4] == ["id", "audio_id", "t0", "t1"]
    assert len(annotations) == 3  # header + 2

    manifest = json.loads(archive.read("manifest.json"))
    assert manifest["schema_version"] == 1


def test_export_missing_feature_404(client: TestClient, exported_project: dict[str, Any]) -> None:
    response = client.post(
        "/export",
        json={"audio_id": exported_project["audio_id"], "kinds": ["foote_novelty_multiscale"]},
    )
    assert response.status_code == 404
    assert "not computed" in response.json()["error"]["message"]


def test_export_unknown_audio_404(client: TestClient) -> None:
    response = client.post("/export", json={"audio_id": "nope", "kinds": []})
    assert response.status_code == 404


def test_export_annotations_only(client: TestClient, exported_project: dict[str, Any]) -> None:
    document = json.loads(
        client.post("/export", json={"audio_id": exported_project["audio_id"], "kinds": []}).content
    )
    assert document["features"] == {}
    assert len(document["annotations"]) == 2
