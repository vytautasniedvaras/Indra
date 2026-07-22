"""Job system tests: completion, monotonic progress + ETA over SSE,
cancellation latency, resume-from-cache, failure propagation (§8.1)."""

from __future__ import annotations

import json
import time
import uuid
from typing import Any

from fastapi.testclient import TestClient

from tests.conftest import wait_for_job


def _submit(client: TestClient, params: dict[str, Any]) -> str:
    response = client.post("/analyze", json={"kind": "debug_slow", "params": params})
    assert response.status_code == 200
    job_id: str = response.json()["job_id"]
    return job_id


def _sse_events(client: TestClient, job_id: str, timeout_s: float = 30.0) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    with client.stream("GET", f"/jobs/{job_id}/events", timeout=timeout_s) as response:
        assert response.status_code == 200
        current: dict[str, str] = {}
        for line in response.iter_lines():
            if line.startswith("event:"):
                current["event"] = line.split(":", 1)[1].strip()
            elif line.startswith("data:"):
                current["data"] = line.split(":", 1)[1].strip()
            elif not line and current.get("data"):
                events.append(
                    {"event": current.get("event", "message"), **json.loads(current["data"])}
                )
                if current.get("event") in ("done", "failed", "cancelled"):
                    break
                current = {}
    return events


def test_job_runs_to_completion(client: TestClient) -> None:
    job_id = _submit(client, {"steps": 5, "step_s": 0.01, "run": uuid.uuid4().hex})
    info = wait_for_job(client, job_id)
    assert info["state"] == "done"
    assert info["progress"] == 1.0
    assert info["result_ref"]["kind"] == "debug_slow"
    assert info["started_at"] is not None and info["finished_at"] is not None


def test_progress_events_monotonic_with_eta(client: TestClient) -> None:
    job_id = _submit(client, {"steps": 10, "step_s": 0.05, "run": uuid.uuid4().hex})
    events = _sse_events(client, job_id)
    progresses = [e["progress"] for e in events]
    assert progresses == sorted(progresses), "progress must be monotonic"
    assert events[-1]["event"] == "done"
    assert events[-1]["progress"] == 1.0
    assert any(e.get("eta_s") is not None for e in events[:-1]), "an ETA must be emitted"


def test_cancellation_within_two_seconds(client: TestClient) -> None:
    job_id = _submit(client, {"steps": 400, "step_s": 0.05, "run": uuid.uuid4().hex})
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        info = client.get(f"/jobs/{job_id}").json()
        if info["state"] == "running" and info["progress"] > 0:
            break
        time.sleep(0.02)
    else:
        raise AssertionError("job never started making progress")

    cancelled_at = time.monotonic()
    response = client.post(f"/jobs/{job_id}/cancel")
    assert response.json() == {"cancelled": True}
    info = wait_for_job(client, job_id, timeout_s=5.0)
    latency = time.monotonic() - cancelled_at
    assert info["state"] == "cancelled"
    assert latency < 2.0, f"cancellation took {latency:.2f}s (budget 2s)"


def test_cancel_terminal_job_is_false(client: TestClient) -> None:
    job_id = _submit(client, {"steps": 2, "step_s": 0.01, "run": uuid.uuid4().hex})
    wait_for_job(client, job_id)
    assert client.post(f"/jobs/{job_id}/cancel").json() == {"cancelled": False}


def test_resume_from_cache(client: TestClient) -> None:
    params = {"steps": 3, "step_s": 0.05, "run": uuid.uuid4().hex}
    first = wait_for_job(client, _submit(client, params))
    assert first["state"] == "done"

    t0 = time.monotonic()
    job_id = _submit(client, params)
    info = client.get(f"/jobs/{job_id}").json()
    assert info["state"] == "done", "cache hit must complete immediately"
    assert time.monotonic() - t0 < 1.0
    assert info["message"] == "cached"
    assert info["result_ref"] == first["result_ref"]


def test_param_change_misses_cache(client: TestClient) -> None:
    params = {"steps": 3, "step_s": 0.05, "run": uuid.uuid4().hex}
    wait_for_job(client, _submit(client, params))
    other = wait_for_job(client, _submit(client, {**params, "steps": 4}))
    assert other["state"] == "done"


def test_failure_propagates(client: TestClient) -> None:
    job_id = _submit(client, {"steps": 5, "step_s": 0.01, "fail_at": 1, "run": uuid.uuid4().hex})
    info = wait_for_job(client, job_id)
    assert info["state"] == "failed"
    assert info["error"]["code"] == "worker_error"
    assert "injected failure" in info["error"]["message"]


def test_sse_late_subscriber_gets_terminal_event(client: TestClient) -> None:
    job_id = _submit(client, {"steps": 2, "step_s": 0.01, "run": uuid.uuid4().hex})
    wait_for_job(client, job_id)
    events = _sse_events(client, job_id)
    assert len(events) == 1
    assert events[0]["event"] == "done"


def test_jobs_list(client: TestClient) -> None:
    job_id = _submit(client, {"steps": 1, "step_s": 0.01, "run": uuid.uuid4().hex})
    wait_for_job(client, job_id)
    listing = client.get("/jobs").json()
    assert any(job["id"] == job_id for job in listing)
