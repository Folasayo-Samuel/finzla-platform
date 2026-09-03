"""Minimal test suite — proves the contract the ALB depends on."""

import os

from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_health_returns_200_and_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_version_exposes_build_provenance():
    r = client.get("/version")
    assert r.status_code == 200
    body = r.json()
    for key in ("version", "git_sha", "build_number", "environment"):
        assert key in body, f"/version must expose {key}"


def test_version_reports_configured_environment(monkeypatch):
    # APP_ENV is read at import time, so assert against the imported value
    # rather than re-importing the module.
    r = client.get("/version")
    assert r.json()["environment"] == os.getenv("APP_ENV", "local")


def test_no_secrets_leaked_in_version_payload():
    """Regression guard: /version must never grow into a config dump."""
    body = client.get("/version").json()
    allowed = {"version", "git_sha", "build_number", "environment", "uptime_seconds"}
    assert set(body) == allowed, "unexpected field added to /version"
