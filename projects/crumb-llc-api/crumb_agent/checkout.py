"""Constrained UCP checkout-session preparation.

The device supplies only an opaque merchant id and variant ids. Merchant origins come
from server configuration, and this client stops before payment or order completion.
"""

from __future__ import annotations

import ipaddress
import socket
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urljoin, urlparse

from .config import Settings

CHECKOUT_CAPABILITY = "dev.ucp.shopping.checkout"
ALLOWED_STATUSES = {
    "incomplete",
    "requires_escalation",
    "ready_for_complete",
    "complete_in_progress",
    "completed",
    "canceled",
}
CREATE_STATUSES = {"incomplete", "requires_escalation", "ready_for_complete"}


class _Response(Protocol):
    status_code: int
    headers: Any

    def json(self) -> Any: ...


class _Transport(Protocol):
    def get(self, url: str, *, headers: dict[str, str]) -> _Response: ...
    def post(self, url: str, *, json: dict[str, Any], headers: dict[str, str]) -> _Response: ...


@dataclass(frozen=True)
class CheckoutOutcome:
    result: str
    merchant_id: str
    reason: str | None = None
    session: dict[str, Any] | None = None

    def as_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {"result": self.result, "merchantId": self.merchant_id}
        if self.reason:
            value["reason"] = self.reason
        if self.session is not None:
            value["session"] = self.session
        return value


class CheckoutProtocolError(Exception):
    pass


def _default_resolver(host: str) -> list[str]:
    return list({item[4][0] for item in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)})


def _safe_https_url(url: str, resolver: Callable[[str], list[str]]) -> bool:
    try:
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            return False
        if parsed.port not in (None, 443):
            return False
        addresses = resolver(parsed.hostname)
        if not addresses:
            return False
        for address in addresses:
            ip = ipaddress.ip_address(address)
            if not ip.is_global:
                return False
        return True
    except (OSError, ValueError):
        return False


def _capability_versions(profile: dict[str, Any]) -> list[str]:
    ucp = profile.get("ucp")
    caps = ucp.get("capabilities") if isinstance(ucp, dict) else None
    values = caps.get(CHECKOUT_CAPABILITY) if isinstance(caps, dict) else None
    if isinstance(values, dict):
        values = [values]
    if not isinstance(values, list):
        return []
    return [
        v["version"] for v in values if isinstance(v, dict) and isinstance(v.get("version"), str)
    ]


def _rest_endpoint(profile: dict[str, Any], version: str) -> str | None:
    ucp = profile.get("ucp")
    services = ucp.get("services") if isinstance(ucp, dict) else None
    shopping = services.get("dev.ucp.shopping") if isinstance(services, dict) else None
    if isinstance(shopping, dict):  # older profile shape
        rest = shopping.get("rest")
        return rest.get("endpoint") if isinstance(rest, dict) else None
    if not isinstance(shopping, list):
        return None
    for service in shopping:
        if (
            isinstance(service, dict)
            and service.get("version") == version
            and service.get("transport") == "rest"
        ):
            endpoint = service.get("endpoint")
            if isinstance(endpoint, str):
                return endpoint
    return None


def _normalize_session(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise CheckoutProtocolError("invalid_session_body")
    required = ("id", "status", "currency", "line_items", "totals", "links")
    if any(key not in payload for key in required):
        raise CheckoutProtocolError("missing_session_fields")
    if not isinstance(payload["id"], str) or not payload["id"]:
        raise CheckoutProtocolError("invalid_session_id")
    if payload["status"] not in ALLOWED_STATUSES:
        raise CheckoutProtocolError("invalid_session_status")
    # This broker performs Create only. Terminal or in-progress states cannot be verified
    # here (the response order is deliberately not normalized), so surfacing them would
    # create a misleading order/completion claim in the app.
    if payload["status"] not in CREATE_STATUSES:
        raise CheckoutProtocolError("invalid_create_status")
    if not isinstance(payload["currency"], str) or len(payload["currency"]) != 3:
        raise CheckoutProtocolError("invalid_currency")
    if not isinstance(payload["line_items"], list) or not isinstance(payload["totals"], list):
        raise CheckoutProtocolError("invalid_session_collections")
    for line in payload["line_items"]:
        item = line.get("item") if isinstance(line, dict) else None
        if (
            not isinstance(line, dict)
            or not isinstance(line.get("id"), str)
            or not isinstance(line.get("quantity"), int)
            or not isinstance(line.get("totals"), list)
            or not isinstance(item, dict)
            or not isinstance(item.get("id"), str)
            or not isinstance(item.get("title"), str)
            or not isinstance(item.get("price"), int)
        ):
            raise CheckoutProtocolError("invalid_line_items")
    for total in payload["totals"]:
        if (
            not isinstance(total, dict)
            or not isinstance(total.get("type"), str)
            or not isinstance(total.get("amount"), int)
        ):
            raise CheckoutProtocolError("invalid_totals")
    if not isinstance(payload["links"], list):
        raise CheckoutProtocolError("invalid_links")
    continue_url = payload.get("continue_url")
    if payload["status"] == "requires_escalation" and not isinstance(continue_url, str):
        raise CheckoutProtocolError("missing_continue_url")
    if payload["status"] == "requires_escalation":
        messages = payload.get("messages")
        buyer_action = {
            "requires_buyer_input",
            "requires_buyer_review",
        }
        if not isinstance(messages, list) or not any(
            isinstance(message, dict)
            and message.get("type") == "error"
            and message.get("severity") in buyer_action
            for message in messages
        ):
            raise CheckoutProtocolError("missing_buyer_action_message")
    return {
        "id": payload["id"],
        "status": payload["status"],
        "currency": payload["currency"].upper(),
        "lineItems": payload["line_items"],
        "totals": payload["totals"],
        "messages": payload.get("messages", []),
        "links": payload["links"],
        "expiresAt": payload.get("expires_at"),
        "continueURL": continue_url,
    }


class CheckoutClient:
    def __init__(
        self,
        settings: Settings,
        transport: _Transport | None = None,
        resolver: Callable[[str], list[str]] = _default_resolver,
    ) -> None:
        self.settings = settings
        self.transport = transport or self._make_transport(settings)
        self.resolver = resolver

    @staticmethod
    def _make_transport(settings: Settings) -> _Transport:
        import httpx

        return httpx.Client(
            timeout=httpx.Timeout(settings.http_timeout_seconds), follow_redirects=False
        )

    def create(
        self,
        merchant_id: str,
        items: list[dict[str, Any]],
        *,
        idempotency_key: str,
        request_id: str,
        profile_url: str,
    ) -> CheckoutOutcome:
        origin = self.settings.checkout_merchants.get(merchant_id)
        if not origin:
            return CheckoutOutcome("unsupported", merchant_id, "merchant_not_allowlisted")
        if not _safe_https_url(origin, self.resolver):
            return CheckoutOutcome("unsupported", merchant_id, "unsafe_merchant_origin")
        discovery_url = urljoin(origin.rstrip("/") + "/", ".well-known/ucp")
        try:
            response = self.transport.get(discovery_url, headers={"Accept": "application/json"})
        except Exception:  # noqa: BLE001 - injected transports expose no shared error base
            return CheckoutOutcome("unsupported", merchant_id, "discovery_failed")
        if 300 <= response.status_code < 400:
            return CheckoutOutcome("unsupported", merchant_id, "discovery_redirect_not_allowed")
        if response.status_code in (401, 403):
            return CheckoutOutcome(
                "authentication_unsupported", merchant_id, "discovery_auth_required"
            )
        if not 200 <= response.status_code < 300:
            return CheckoutOutcome("unsupported", merchant_id, "discovery_failed")
        try:
            profile = response.json()
        except ValueError:
            return CheckoutOutcome("unsupported", merchant_id, "invalid_discovery_profile")
        if not isinstance(profile, dict):
            return CheckoutOutcome("unsupported", merchant_id, "invalid_discovery_profile")
        supported = _capability_versions(profile)
        version = self.settings.ucp_version if self.settings.ucp_version in supported else None
        if not version:
            return CheckoutOutcome("unsupported", merchant_id, "checkout_capability_not_negotiated")
        endpoint = _rest_endpoint(profile, version)
        if not endpoint or not _safe_https_url(endpoint, self.resolver):
            return CheckoutOutcome(
                "unsupported", merchant_id, "unsafe_or_missing_checkout_endpoint"
            )
        url = endpoint.rstrip("/") + "/checkout-sessions"
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "UCP-Agent": f'profile="{profile_url}"',
            "Request-Id": request_id,
            "Idempotency-Key": idempotency_key,
        }
        checkout = {
            "line_items": [
                {"item": {"id": item["variantId"]}, "quantity": item["quantity"]} for item in items
            ]
        }
        try:
            created = self.transport.post(url, json=checkout, headers=headers)
        except Exception:  # noqa: BLE001 - network errors are a typed, retryable app outcome
            return CheckoutOutcome("unsupported", merchant_id, "checkout_transport_failed")
        if 300 <= created.status_code < 400:
            return CheckoutOutcome("unsupported", merchant_id, "checkout_redirect_not_allowed")
        if created.status_code in (401, 403):
            return CheckoutOutcome(
                "authentication_unsupported", merchant_id, "checkout_auth_required"
            )
        if not 200 <= created.status_code < 300:
            return CheckoutOutcome("unsupported", merchant_id, "checkout_transport_failed")
        try:
            session = _normalize_session(created.json())
        except (ValueError, CheckoutProtocolError) as exc:
            reason = str(exc) or "invalid_checkout_response"
            return CheckoutOutcome("preparation_failed", merchant_id, reason)
        continue_url = session.get("continueURL")
        if continue_url and not _safe_https_url(continue_url, self.resolver):
            return CheckoutOutcome("preparation_failed", merchant_id, "unsafe_continue_url")
        return CheckoutOutcome("prepared", merchant_id, session=session)
