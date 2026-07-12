from __future__ import annotations

from typing import Any

import pytest

from crumb_agent.checkout import CheckoutClient
from crumb_agent.config import Settings


class Response:
    def __init__(self, status: int, payload: Any, headers: dict[str, str] | None = None) -> None:
        self.status_code = status
        self.payload = payload
        self.headers = headers or {}

    def json(self) -> Any:
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload


def profile(
    *, endpoint: str = "https://api.shop.example/ucp/v1", version: str = "2026-04-08"
) -> dict:
    return {
        "ucp": {
            "capabilities": {"dev.ucp.shopping.checkout": [{"version": version}]},
            "services": {
                "dev.ucp.shopping": [
                    {
                        "version": version,
                        "transport": "rest",
                        "endpoint": endpoint,
                    }
                ]
            },
        }
    }


def session(**updates: Any) -> dict:
    value = {
        "id": "checkout_1",
        "status": "requires_escalation",
        "currency": "USD",
        "line_items": [
            {
                "id": "li_1",
                "item": {"id": "variant_1", "title": "Thing", "price": 1200},
                "quantity": 1,
                "totals": [{"type": "total", "amount": 1200}],
            }
        ],
        "totals": [{"type": "total", "display_text": "Total", "amount": 1200}],
        "links": [{"type": "privacy_policy", "url": "https://shop.example/privacy"}],
        "messages": [
            {
                "type": "error",
                "code": "review",
                "content": "Review with merchant",
                "severity": "requires_buyer_review",
            }
        ],
        "continue_url": "https://shop.example/checkout/1",
    }
    value.update(updates)
    return value


class Transport:
    def __init__(self, discovery: Response | None = None, created: Response | None = None) -> None:
        self.discovery = discovery or Response(200, profile())
        self.created = created or Response(200, session())
        self.calls: list[tuple[str, str, Any, dict[str, str]]] = []

    def get(self, url: str, *, headers: dict[str, str]) -> Response:
        self.calls.append(("GET", url, None, headers))
        return self.discovery

    def post(self, url: str, *, json: dict, headers: dict[str, str]) -> Response:
        self.calls.append(("POST", url, json, headers))
        return self.created


def settings(registry: str = '{"shop-1":"https://shop.example"}') -> Settings:
    return Settings(
        ucp_version="2026-04-08",
        checkout_merchants_json=registry,
        agent_profile_url="https://broker.example/.well-known/ucp",
    )


def public(_host: str) -> list[str]:
    return ["93.184.216.34"]


def create(client: CheckoutClient, merchant: str = "shop-1"):
    return client.create(
        merchant,
        [{"variantId": "variant_1", "quantity": 2}],
        idempotency_key="00000000-0000-4000-8000-000000000001",
        request_id="request-1",
        profile_url="https://broker.example/.well-known/ucp",
    )


def test_prepares_exact_checkout_session_request() -> None:
    transport = Transport()
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public))
    assert outcome.result == "prepared"
    assert outcome.session and outcome.session["continueURL"].endswith("/checkout/1")
    assert transport.calls[0][1] == "https://shop.example/.well-known/ucp"
    method, url, body, headers = transport.calls[1]
    assert (method, url) == ("POST", "https://api.shop.example/ucp/v1/checkout-sessions")
    assert body == {"line_items": [{"item": {"id": "variant_1"}, "quantity": 2}]}
    assert headers["Idempotency-Key"].endswith("0001")
    assert headers["Request-Id"] == "request-1"
    assert headers["UCP-Agent"] == 'profile="https://broker.example/.well-known/ucp"'


def test_accepts_created_201_response() -> None:
    transport = Transport(created=Response(201, session()))
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public))
    assert outcome.result == "prepared"


def test_unknown_merchant_never_causes_network_request() -> None:
    transport = Transport()
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public), "evil")
    assert outcome.result == "unsupported"
    assert outcome.reason == "merchant_not_allowlisted"
    assert transport.calls == []


def test_private_allowlisted_origin_is_still_rejected() -> None:
    transport = Transport()
    client = CheckoutClient(
        settings('{"shop-1":"https://internal.example"}'),
        transport=transport,
        resolver=lambda _: ["127.0.0.1"],
    )
    assert create(client).reason == "unsafe_merchant_origin"
    assert transport.calls == []


def test_redirects_are_not_followed() -> None:
    transport = Transport(discovery=Response(302, {}, {"location": "https://elsewhere.example"}))
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public))
    assert outcome.reason == "discovery_redirect_not_allowed"
    assert len(transport.calls) == 1


def test_version_must_be_in_capability_intersection() -> None:
    transport = Transport(discovery=Response(200, profile(version="2026-01-11")))
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public))
    assert outcome.reason == "checkout_capability_not_negotiated"
    assert len(transport.calls) == 1


def test_unsafe_advertised_endpoint_is_rejected() -> None:
    transport = Transport(discovery=Response(200, profile(endpoint="http://127.0.0.1/ucp")))
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public))
    assert outcome.reason == "unsafe_or_missing_checkout_endpoint"


def test_authentication_requirement_is_typed() -> None:
    transport = Transport(created=Response(401, {}))
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public))
    assert outcome.result == "authentication_unsupported"
    assert outcome.reason == "checkout_auth_required"


def test_requires_escalation_requires_safe_continue_url() -> None:
    missing = Transport(created=Response(200, session(continue_url=None)))
    outcome = create(CheckoutClient(settings(), transport=missing, resolver=public))
    assert outcome.reason == "missing_continue_url"

    unsafe = Transport(created=Response(200, session(continue_url="http://shop.example/x")))
    outcome = create(CheckoutClient(settings(), transport=unsafe, resolver=public))
    assert outcome.reason == "unsafe_continue_url"


def test_requires_escalation_requires_buyer_action_error() -> None:
    no_action = Transport(created=Response(200, session(messages=[])))
    outcome = create(CheckoutClient(settings(), transport=no_action, resolver=public))
    assert outcome.result == "preparation_failed"
    assert outcome.reason == "missing_buyer_action_message"


def test_required_session_fields_and_status_are_validated() -> None:
    invalid = Transport(created=Response(200, session(status="surprise")))
    outcome = create(CheckoutClient(settings(), transport=invalid, resolver=public))
    assert outcome.reason == "invalid_session_status"
    missing = Transport(created=Response(200, {"id": "x"}))
    outcome = create(CheckoutClient(settings(), transport=missing, resolver=public))
    assert outcome.reason == "missing_session_fields"


@pytest.mark.parametrize("status", ["complete_in_progress", "completed", "canceled"])
def test_create_rejects_terminal_or_processing_status(status: str) -> None:
    transport = Transport(created=Response(200, session(status=status)))
    outcome = create(CheckoutClient(settings(), transport=transport, resolver=public))
    assert outcome.result == "preparation_failed"
    assert outcome.reason == "invalid_create_status"


def test_sparse_line_item_is_rejected_before_the_app_decodes_it() -> None:
    sparse = Transport(created=Response(200, session(line_items=[{"id": "line"}])))
    outcome = create(CheckoutClient(settings(), transport=sparse, resolver=public))
    assert outcome.result == "preparation_failed"
    assert outcome.reason == "invalid_line_items"
