"""Smoke tests for the FastAPI layer (no network, no credentials configured)."""

from __future__ import annotations

import importlib

from fastapi.testclient import TestClient

import server
from crumb_agent.config import get_settings


def _client() -> TestClient:
    # Ensure a clean, unconfigured settings + client for each test.
    get_settings.cache_clear()
    importlib.reload(server)
    return TestClient(server.app)


def test_healthz_ok() -> None:
    resp = _client().get("/healthz")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["configured"] is False  # no creds in the test env


def test_profile_advertises_catalog_search() -> None:
    resp = _client().get("/.well-known/ucp")
    assert resp.status_code == 200
    caps = resp.json()["ucp"]["capabilities"]
    assert "dev.ucp.shopping.catalog.search" in caps
    assert "dev.ucp.shopping.checkout" not in caps


def test_search_without_credentials_returns_503() -> None:
    resp = _client().post("/catalog/search", json={"query": "coffee"})
    assert resp.status_code == 503
    assert resp.json()["detail"] == "broker_not_configured"


def test_search_validation_error_is_422() -> None:
    resp = _client().post("/catalog/search", json={})  # missing "query"
    assert resp.status_code == 422
