"""Smoke tests for the FastAPI layer.

These force an *unconfigured* broker (no credentials) regardless of any local `.env`, so
they're deterministic on a developer machine that has real creds. No network is used.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import server
from crumb_agent.checkout import CheckoutOutcome
from crumb_agent.config import get_settings


@pytest.fixture(autouse=True)
def unconfigured(monkeypatch: pytest.MonkeyPatch) -> None:
    # Empty env vars take precedence over any `.env`, forcing has_credentials = False.
    for key in (
        "SHOPIFY_UCP_CLIENT_ID",
        "SHOPIFY_UCP_CLIENT_SECRET",
        "SHOPIFY_CATALOG_URL",
        "CRUMB_BROKER_KEY",
        "UCP_CHECKOUT_MERCHANTS_JSON",
    ):
        monkeypatch.setenv(key, "")
    get_settings.cache_clear()
    server._client = None
    server._checkout_client = None
    yield
    get_settings.cache_clear()
    server._client = None
    server._checkout_client = None


def _client() -> TestClient:
    return TestClient(server.app)


def test_healthz_ok() -> None:
    resp = _client().get("/healthz")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["configured"] is False
    assert body["checkoutConfigured"] is False


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


def test_checkout_unknown_merchant_is_typed_unsupported() -> None:
    resp = _client().post(
        "/checkout/create",
        json={
            "merchantId": "not-configured",
            "items": [{"variantId": "variant-1", "quantity": 1}],
            "idempotencyKey": "00000000-0000-4000-8000-000000000001",
        },
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "result": "unsupported",
        "merchantId": "not-configured",
        "reason": "merchant_not_allowlisted",
    }


def test_checkout_route_uses_broker_auth(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CRUMB_BROKER_KEY", "secret")
    get_settings.cache_clear()
    resp = _client().post(
        "/checkout/create",
        json={
            "merchantId": "x",
            "items": [{"variantId": "v"}],
            "idempotencyKey": "00000000-0000-4000-8000-000000000001",
        },
    )
    assert resp.status_code == 401


def test_enabled_checkout_fails_closed_without_broker_secret(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("UCP_CHECKOUT_MERCHANTS_JSON", '{"shop":"https://shop.example"}')
    monkeypatch.setenv("CRUMB_BROKER_KEY", "")
    get_settings.cache_clear()
    resp = _client().post(
        "/checkout/create",
        json={
            "merchantId": "shop",
            "items": [{"variantId": "v"}],
            "idempotencyKey": "00000000-0000-4000-8000-000000000001",
        },
    )
    assert resp.status_code == 503
    assert resp.json()["detail"] == "checkout_auth_not_configured"


def test_request_id_is_fresh_per_attempt_and_idempotency_stays_stable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("UCP_CHECKOUT_MERCHANTS_JSON", '{"shop":"https://shop.example"}')
    monkeypatch.setenv("CRUMB_BROKER_KEY", "secret")
    get_settings.cache_clear()

    class StubCheckout:
        calls: list[dict] = []

        def create(self, merchant_id, items, **kwargs):
            self.calls.append(kwargs)
            return CheckoutOutcome("unsupported", merchant_id, "fixture")

    stub = StubCheckout()
    server._checkout_client = stub
    ids = iter(["attempt-1", "attempt-2"])
    monkeypatch.setattr(server, "uuid4", lambda: next(ids))
    body = {
        "merchantId": "shop",
        "items": [{"variantId": "v"}],
        "idempotencyKey": "00000000-0000-4000-8000-000000000001",
    }
    client = _client()
    for _ in range(2):
        response = client.post(
            "/checkout/create",
            json=body,
            headers={"x-broker-key": "secret", "x-request-id": "caller-controlled"},
        )
        assert response.status_code == 200
    assert [call["request_id"] for call in stub.calls] == ["attempt-1", "attempt-2"]
    assert {call["idempotency_key"] for call in stub.calls} == {body["idempotencyKey"]}


def test_checkout_rejects_empty_items_and_short_idempotency_key() -> None:
    resp = _client().post(
        "/checkout/create",
        json={"merchantId": "x", "items": [], "idempotencyKey": "short"},
    )
    assert resp.status_code == 422


def test_broker_exposes_no_checkout_update_or_complete_routes() -> None:
    """The production broker must remain create-only and unable to receive PII/payment."""
    paths = {route.path for route in server.app.routes}
    assert "/checkout/create" in paths
    assert "/checkout/get" not in paths
    assert "/checkout/update" not in paths
    assert "/checkout/complete" not in paths
    assert "/checkout/{checkout_id}" not in paths
    assert "/checkout/{checkout_id}/complete" not in paths


def test_checkout_mutation_contracts_return_not_found_not_stub_success() -> None:
    client = _client()
    assert (
        client.put("/checkout/session-1", json={"buyer": {"email": "x@example.com"}}).status_code
        == 404
    )
    assert client.post("/checkout/session-1/complete", json={"payment_data": {}}).status_code == 404
