"""Smoke tests for the FastAPI layer.

These force an *unconfigured* broker (no credentials) regardless of any local `.env`, so
they're deterministic on a developer machine that has real creds. No network is used.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import server
from crumb_agent.config import get_settings


@pytest.fixture(autouse=True)
def unconfigured(monkeypatch: pytest.MonkeyPatch) -> None:
    # Empty env vars take precedence over any `.env`, forcing has_credentials = False.
    for key in (
        "SHOPIFY_UCP_CLIENT_ID",
        "SHOPIFY_UCP_CLIENT_SECRET",
        "SHOPIFY_CATALOG_URL",
        "CRUMB_BROKER_KEY",
    ):
        monkeypatch.setenv(key, "")
    get_settings.cache_clear()
    server._client = None
    yield
    get_settings.cache_clear()
    server._client = None


def _client() -> TestClient:
    return TestClient(server.app)


def test_healthz_ok() -> None:
    resp = _client().get("/healthz")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["configured"] is False


def test_profile_advertises_catalog_search() -> None:
    resp = _client().get("/.well-known/ucp")
    assert resp.status_code == 200
    caps = resp.json()["ucp"]["capabilities"]
    assert "dev.ucp.shopping.catalog.search" in caps
    assert "dev.ucp.shopping.checkout" not in caps


def test_profile_is_cacheable() -> None:
    # Shopify rejects the profile during UCP negotiation ("profile_malformed:
    # Invalid cache control") unless the response carries a valid Cache-Control header.
    resp = _client().get("/.well-known/ucp")
    assert resp.status_code == 200
    assert "max-age" in resp.headers.get("cache-control", "")


def test_search_without_credentials_returns_503() -> None:
    resp = _client().post("/catalog/search", json={"query": "coffee"})
    assert resp.status_code == 503
    assert resp.json()["detail"] == "broker_not_configured"


def test_search_validation_error_is_422() -> None:
    resp = _client().post("/catalog/search", json={})  # missing "query"
    assert resp.status_code == 422
