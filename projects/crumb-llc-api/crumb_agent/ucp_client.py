"""Stateless client for Shopify's UCP Global Catalog MCP endpoint.

Auth flow (confirmed against shopify.dev/docs/agents):

1. ``POST {token_url}`` with ``grant_type=client_credentials`` → a JWT ``access_token``
   (~60-minute TTL). Cached in-process and refreshed on a buffer; nothing is persisted.
2. ``POST {catalog_url}`` (JSON-RPC 2.0 ``tools/call``) with
   ``Authorization: Bearer <token>`` and ``meta.ucp-agent.profile`` pointing at our hosted
   agent profile. Tools: ``search_catalog`` and ``get_product``.

The transport is injectable so tests run without network or an ``httpx`` install.
"""

from __future__ import annotations

import threading
import time
from typing import Any, Protocol

from .config import Settings


class _Response(Protocol):
    status_code: int

    def json(self) -> Any: ...


class _Transport(Protocol):
    def post(self, url: str, *, json: dict[str, Any], headers: dict[str, str]) -> _Response: ...


class UCPError(Exception):
    """Raised when a UCP token or tool call fails."""

    def __init__(self, message: str, *, status: int | None = None, code: str | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


class UCPClient:
    """Mints/caches a bearer token and calls UCP catalog tools."""

    def __init__(
        self,
        settings: Settings,
        transport: _Transport | None = None,
        *,
        now: "callable[[], float] | None" = None,
    ) -> None:
        self._settings = settings
        self._transport = transport if transport is not None else _default_transport(settings)
        self._now = now or time.time
        self._token: str | None = None
        self._token_expiry: float = 0.0
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ tokens

    def access_token(self) -> str:
        """Return a valid bearer token, fetching a fresh one if needed."""
        with self._lock:
            buffer = self._settings.token_refresh_buffer_seconds
            if self._token and self._now() < self._token_expiry - buffer:
                return self._token

            if not (self._settings.client_id and self._settings.client_secret):
                raise UCPError("Missing Shopify UCP credentials", code="missing_credentials")

            resp = self._transport.post(
                self._settings.token_url,
                json={
                    "client_id": self._settings.client_id,
                    "client_secret": self._settings.client_secret,
                    "grant_type": "client_credentials",
                },
                headers={"Content-Type": "application/json"},
            )
            if resp.status_code != 200:
                raise UCPError(
                    f"Token request failed ({resp.status_code})",
                    status=resp.status_code,
                    code="token_request_failed",
                )
            data = resp.json()
            token = data.get("access_token") if isinstance(data, dict) else None
            if not token:
                raise UCPError("No access_token in token response", code="invalid_token_response")

            expires_in = data.get("expires_in", self._settings.token_ttl_seconds)
            try:
                ttl = float(expires_in)
            except (TypeError, ValueError):
                ttl = float(self._settings.token_ttl_seconds)

            self._token = token
            self._token_expiry = self._now() + ttl
            return token

    # ------------------------------------------------------------------- tools

    def search_catalog(
        self,
        query: str,
        *,
        context: dict[str, Any] | None = None,
        profile_url: str | None = None,
        request_id: int = 1,
    ) -> dict[str, Any]:
        """UCP ``search_catalog`` over the Global Catalog."""
        catalog: dict[str, Any] = {"query": query}
        if context:
            catalog["context"] = context
        return self._call_tool(
            "search_catalog",
            {"meta": self._meta(profile_url), "catalog": catalog},
            request_id=request_id,
        )

    def get_product(
        self,
        product_id: str,
        *,
        selected: list[dict[str, Any]] | None = None,
        profile_url: str | None = None,
        request_id: int = 1,
    ) -> dict[str, Any]:
        """UCP ``get_product`` for a product/variant id, with optional variant selection.

        NOTE: the exact `selected` argument schema should be confirmed against the live
        input schema (`ucp catalog get_product --input-schema`) once a real catalog key
        exists; the wrapper shape here follows the documented examples.
        """
        catalog: dict[str, Any] = {"product_id": product_id}
        if selected:
            catalog["selected"] = selected
        return self._call_tool(
            "get_product",
            {"meta": self._meta(profile_url), "catalog": catalog},
            request_id=request_id,
        )

    # --------------------------------------------------------------- internals

    def _meta(self, profile_url: str | None) -> dict[str, Any]:
        url = profile_url or self._settings.agent_profile_url
        return {"ucp-agent": {"profile": url}}

    def _call_tool(self, name: str, arguments: dict[str, Any], *, request_id: int) -> dict[str, Any]:
        if not self._settings.catalog_url:
            raise UCPError("SHOPIFY_CATALOG_URL is not configured", code="missing_catalog_url")

        token = self.access_token()
        resp = self._transport.post(
            self._settings.catalog_url,
            json={
                "jsonrpc": "2.0",
                "method": "tools/call",
                "id": request_id,
                "params": {"name": name, "arguments": arguments},
            },
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {token}",
            },
        )
        if resp.status_code != 200:
            raise UCPError(
                f"{name} failed ({resp.status_code})",
                status=resp.status_code,
                code="tool_call_failed",
            )
        data = resp.json()
        if not isinstance(data, dict):
            raise UCPError(f"{name} returned a non-JSON-RPC body", code="invalid_response")
        if data.get("error"):
            raise UCPError(f"{name} JSON-RPC error: {data['error']}", code="jsonrpc_error")

        result = data.get("result", {})
        # MCP tool results carry the typed payload under `structuredContent`.
        if isinstance(result, dict) and "structuredContent" in result:
            return result["structuredContent"]
        return result if isinstance(result, dict) else {}


def _default_transport(settings: Settings) -> _Transport:
    """Lazily build an httpx client so importing this module never requires httpx."""
    import httpx

    return httpx.Client(timeout=settings.http_timeout_seconds)
