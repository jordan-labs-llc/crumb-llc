"""FastAPI HTTP layer for the Crumb UCP broker (runs as a container on Azure Container
Apps). The pure logic lives in ``crumb_agent`` and is unchanged; this module only maps
HTTP to it.

Routes:
- ``GET /healthz``           — liveness + whether credentials are configured (open)
- ``GET /.well-known/ucp``   — public agent profile (Shopify fetches this; open)
- ``POST /catalog/search``   — {"query": str, "context"?: obj}
- ``POST /catalog/product``  — {"productId": str, "selected"?: [...]}

If ``CRUMB_BROKER_KEY`` is set, the catalog routes require a matching ``x-broker-key``
header. All Shopify credentials stay server-side.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

from crumb_agent.config import get_settings
from crumb_agent.models import normalize_product, normalize_search
from crumb_agent.profile import build_profile
from crumb_agent.ucp_client import UCPClient, UCPError

logger = logging.getLogger("crumb_agent")

app = FastAPI(title="Crumb UCP Broker", version="0.1.0")

_client: UCPClient | None = None


def ucp() -> UCPClient:
    global _client
    if _client is None:
        _client = UCPClient(get_settings())
    return _client


class SearchBody(BaseModel):
    query: str
    context: dict[str, Any] | None = None


class ProductBody(BaseModel):
    productId: str
    selected: list[dict[str, Any]] | None = None


def _require_key(x_broker_key: str | None) -> None:
    expected = get_settings().broker_key
    if expected and x_broker_key != expected:
        raise HTTPException(status_code=401, detail="invalid_broker_key")


def _profile_url(request: Request) -> str:
    settings = get_settings()
    if settings.agent_profile_url:
        return settings.agent_profile_url
    host = request.headers.get("x-forwarded-host") or request.url.netloc
    scheme = request.headers.get("x-forwarded-proto") or request.url.scheme or "https"
    return f"{scheme}://{host}/.well-known/ucp"


def _raise_for_ucp_error(exc: UCPError) -> None:
    if exc.code in ("missing_credentials", "missing_catalog_url"):
        logger.warning("Broker not configured: %s", exc)
        raise HTTPException(status_code=503, detail="broker_not_configured") from exc
    logger.error("UCP call failed: %s (status=%s)", exc, exc.status)
    raise HTTPException(status_code=502, detail="upstream_error") from exc


@app.get("/healthz")
def healthz() -> dict[str, Any]:
    return {"status": "ok", "configured": get_settings().has_credentials}


@app.get("/.well-known/ucp")
def ucp_profile(request: Request) -> dict[str, Any]:
    return build_profile(get_settings(), profile_url=_profile_url(request))


@app.post("/catalog/search")
def catalog_search(
    body: SearchBody,
    request: Request,
    x_broker_key: str | None = Header(default=None),
) -> dict[str, Any]:
    _require_key(x_broker_key)
    try:
        structured = ucp().search_catalog(
            body.query, context=body.context, profile_url=_profile_url(request)
        )
    except UCPError as exc:
        _raise_for_ucp_error(exc)
    return normalize_search(structured)


@app.post("/catalog/product")
def catalog_product(
    body: ProductBody,
    request: Request,
    x_broker_key: str | None = Header(default=None),
) -> dict[str, Any]:
    _require_key(x_broker_key)
    try:
        structured = ucp().get_product(
            body.productId, selected=body.selected, profile_url=_profile_url(request)
        )
    except UCPError as exc:
        _raise_for_ucp_error(exc)
    product = structured.get("product") if isinstance(structured, dict) else None
    if isinstance(product, dict):
        return {"product": normalize_product(product)}
    return {"product": normalize_product(structured)}
