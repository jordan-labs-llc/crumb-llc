"""Unit tests for the UCP client and normalization — no network, no httpx required."""

from __future__ import annotations

from typing import Any

import pytest

from crumb_agent.config import Settings
from crumb_agent.models import normalize_product, normalize_search
from crumb_agent.profile import build_profile
from crumb_agent.ucp_client import UCPClient, UCPError


class FakeResponse:
    def __init__(self, status_code: int, payload: Any) -> None:
        self.status_code = status_code
        self._payload = payload

    def json(self) -> Any:
        return self._payload


class FakeTransport:
    """Records calls and returns queued responses keyed by URL substring."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.token_response = FakeResponse(200, {"access_token": "jwt-123", "expires_in": 3600})
        self.catalog_response = FakeResponse(
            200,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                    "structuredContent": {
                        "ucp": {"version": "2026-04-08"},
                        "products": [
                            {
                                "id": "gid://shopify/p/abc",
                                "title": "Organic Crewneck",
                                "price_range": {
                                    "min": {"amount": 8900, "currency": "USD"},
                                    "max": {"amount": 9900, "currency": "USD"},
                                },
                                "seller": {"domain": "northbound.example"},
                                "options": [{"name": "Size", "values": [{"label": "M"}]}],
                            }
                        ],
                    }
                },
            },
        )

    def post(self, url: str, *, json: dict, headers: dict) -> FakeResponse:
        self.calls.append({"url": url, "json": json, "headers": headers})
        if "access_token" in url:
            return self.token_response
        return self.catalog_response


def _settings() -> Settings:
    return Settings(
        client_id="cid",
        client_secret="csecret",
        catalog_url="https://catalog.example/api/ucp/mcp",
        token_url="https://api.shopify.com/auth/access_token",
        agent_profile_url="https://broker.example/.well-known/ucp",
    )


def test_token_is_fetched_once_and_cached() -> None:
    transport = FakeTransport()
    clock = {"t": 1000.0}
    client = UCPClient(_settings(), transport=transport, now=lambda: clock["t"])

    assert client.access_token() == "jwt-123"
    assert client.access_token() == "jwt-123"  # cached

    token_calls = [c for c in transport.calls if "access_token" in c["url"]]
    assert len(token_calls) == 1
    body = token_calls[0]["json"]
    assert body["grant_type"] == "client_credentials"
    assert body["client_id"] == "cid"


def test_token_refreshes_after_expiry_buffer() -> None:
    transport = FakeTransport()
    clock = {"t": 1000.0}
    client = UCPClient(_settings(), transport=transport, now=lambda: clock["t"])

    client.access_token()
    clock["t"] = 1000.0 + 3600.0  # past expiry
    client.access_token()

    token_calls = [c for c in transport.calls if "access_token" in c["url"]]
    assert len(token_calls) == 2


def test_search_builds_jsonrpc_with_bearer_and_profile() -> None:
    transport = FakeTransport()
    client = UCPClient(_settings(), transport=transport, now=lambda: 1000.0)

    structured = client.search_catalog("crewneck", profile_url="https://p.example/.well-known/ucp")

    catalog_call = [c for c in transport.calls if c["url"].endswith("/mcp")][0]
    assert catalog_call["headers"]["Authorization"] == "Bearer jwt-123"
    params = catalog_call["json"]["params"]
    assert catalog_call["json"]["method"] == "tools/call"
    assert params["name"] == "search_catalog"
    assert params["arguments"]["catalog"]["query"] == "crewneck"
    assert (
        params["arguments"]["meta"]["ucp-agent"]["profile"]
        == "https://p.example/.well-known/ucp"
    )
    # And the structured content flows back.
    assert structured["products"][0]["title"] == "Organic Crewneck"


def test_missing_catalog_url_raises() -> None:
    settings = Settings(client_id="a", client_secret="b", catalog_url="")
    client = UCPClient(settings, transport=FakeTransport(), now=lambda: 0.0)
    with pytest.raises(UCPError) as exc:
        client.search_catalog("x")
    assert exc.value.code == "missing_catalog_url"


def test_token_failure_raises() -> None:
    transport = FakeTransport()
    transport.token_response = FakeResponse(401, {"error": "unauthorized"})
    client = UCPClient(_settings(), transport=transport, now=lambda: 0.0)
    with pytest.raises(UCPError) as exc:
        client.access_token()
    assert exc.value.status == 401


def test_normalize_search_and_product() -> None:
    structured = {
        "ucp": {"version": "2026-04-08"},
        "products": [
            {
                "id": "p1",
                "title": "Kettle",
                "price_range": {"min": {"amount": 12900, "currency": "USD"}},
                "seller": {"domain": "field-flask.example"},
            }
        ],
    }
    out = normalize_search(structured)
    assert out["ucpVersion"] == "2026-04-08"
    assert out["products"][0]["sellerDomain"] == "field-flask.example"
    assert out["products"][0]["priceMin"] == {"amount": 12900, "currency": "USD"}

    one = normalize_product({"id": "p2", "title": "Mug"})
    assert one["id"] == "p2"
    assert one["priceMin"] is None  # tolerant of missing fields


def test_profile_advertises_catalog_search_only() -> None:
    profile = build_profile(_settings(), profile_url="https://broker.example/.well-known/ucp")
    caps = profile["ucp"]["capabilities"]
    assert "dev.ucp.shopping.catalog.search" in caps
    assert "dev.ucp.shopping.checkout" not in caps
    assert profile["ucp"]["id"] == "https://broker.example/.well-known/ucp"
