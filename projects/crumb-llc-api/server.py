"""FastAPI HTTP layer for the Crumb UCP broker (runs as a container on Azure Container
Apps). The pure logic lives in ``crumb_agent`` and is unchanged; this module only maps
HTTP to it.

Routes:
- ``GET /healthz``           — liveness + whether credentials are configured (open)
- ``GET /.well-known/ucp``   — public agent profile (Shopify fetches this; open)
- ``POST /catalog/search``   — {"query": str, "context"?: obj}
- ``POST /catalog/product``  — {"productId": str, "selected"?: [...]}
- ``POST /checkout/create``  — prepare one allowlisted merchant checkout session

There are intentionally no live checkout get/update/complete routes. In particular this
broker cannot receive buyer PII, fulfillment updates, payment instruments, or proxy an
order-completion request. The native sandbox lifecycle lives entirely on the device.

If ``CRUMB_BROKER_KEY`` is set, the catalog routes require a matching ``x-broker-key``
header. All Shopify credentials stay server-side.
"""

from __future__ import annotations

import logging
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, Header, HTTPException, Request, Response
from pydantic import BaseModel, Field

from crumb_agent.checkout import CheckoutClient
from crumb_agent.config import get_settings
from crumb_agent.models import normalize_product, normalize_search
from crumb_agent.profile import build_profile
from crumb_agent.ucp_client import UCPClient, UCPError

logger = logging.getLogger("crumb_agent")

app = FastAPI(title="Crumb UCP Broker", version="0.1.0")

_client: UCPClient | None = None
_checkout_client: CheckoutClient | None = None


def ucp() -> UCPClient:
    global _client
    if _client is None:
        _client = UCPClient(get_settings())
    return _client


def checkout() -> CheckoutClient:
    global _checkout_client
    if _checkout_client is None:
        _checkout_client = CheckoutClient(get_settings())
    return _checkout_client


class SearchBody(BaseModel):
    query: str
    context: dict[str, Any] | None = None


class ProductBody(BaseModel):
    productId: str
    selected: list[dict[str, Any]] | None = None


class CheckoutItemBody(BaseModel):
    variantId: str = Field(min_length=1, max_length=1000)
    quantity: int = Field(default=1, ge=1, le=100)


class CheckoutBody(BaseModel):
    merchantId: str = Field(min_length=1, max_length=255)
    items: list[CheckoutItemBody] = Field(min_length=1, max_length=100)
    idempotencyKey: str = Field(min_length=20, max_length=255)


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
    settings = get_settings()
    return {
        "status": "ok",
        "configured": settings.has_credentials,
        "checkoutConfigured": settings.checkout_enabled,
    }


@app.get("/.well-known/ucp")
def ucp_profile(request: Request, response: Response) -> dict[str, Any]:
    # Shopify fetches and caches this during UCP negotiation and rejects the profile
    # ("profile_malformed: Invalid cache control") unless the response is cacheable.
    response.headers["Cache-Control"] = "public, max-age=3600"
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


@app.post("/checkout/create")
def checkout_create(
    body: CheckoutBody,
    request: Request,
    x_broker_key: str | None = Header(default=None),
) -> dict[str, Any]:
    """Prepare, but never complete, one merchant-scoped UCP checkout session."""
    settings = get_settings()
    # Live checkout is a state-changing upstream operation. Unlike read-only catalog,
    # enabling it without an app-to-broker secret is a deployment error, not open access.
    if settings.checkout_enabled and not settings.broker_key:
        raise HTTPException(status_code=503, detail="checkout_auth_not_configured")
    _require_key(x_broker_key)
    # Idempotency remains stable across retries; Request-Id traces this individual attempt.
    request_id = str(uuid4())
    outcome = checkout().create(
        body.merchantId,
        [item.model_dump() for item in body.items],
        idempotency_key=body.idempotencyKey,
        request_id=request_id,
        profile_url=_profile_url(request),
    )
    return outcome.as_dict()
