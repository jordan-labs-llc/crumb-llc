"""Azure Functions HTTP layer for the Crumb UCP broker.

Routes (host.json sets routePrefix="" so these sit at the domain root):

- ``GET  /.well-known/ucp``  — public agent profile (Shopify fetches this; ANONYMOUS)
- ``GET  /healthz``          — liveness probe (ANONYMOUS)
- ``POST /catalog/search``   — body {"query": str, "context"?: obj}  (FUNCTION key)
- ``POST /catalog/product``  — body {"productId": str, "selected"?: [...]} (FUNCTION key)

All Shopify credentials stay server-side; the iOS app only ever sees this broker.
"""

from __future__ import annotations

import json
import logging
from urllib.parse import urlsplit

import azure.functions as func

from crumb_agent.config import get_settings
from crumb_agent.models import normalize_product, normalize_search
from crumb_agent.profile import build_profile
from crumb_agent.ucp_client import UCPClient, UCPError

logger = logging.getLogger("crumb_agent")

app = func.FunctionApp()

_client: UCPClient | None = None


def _ucp() -> UCPClient:
    global _client
    if _client is None:
        _client = UCPClient(get_settings())
    return _client


def _json(payload: dict, status: int = 200) -> func.HttpResponse:
    return func.HttpResponse(json.dumps(payload), status_code=status, mimetype="application/json")


def _profile_url(req: func.HttpRequest) -> str:
    """The public URL of the hosted profile. Prefer the configured value; otherwise derive
    it from the request so it works on *.azurewebsites.net without extra config."""
    settings = get_settings()
    if settings.agent_profile_url:
        return settings.agent_profile_url
    parts = urlsplit(req.url)
    host = req.headers.get("x-forwarded-host", parts.netloc)
    scheme = req.headers.get("x-forwarded-proto", parts.scheme or "https")
    return f"{scheme}://{host}/.well-known/ucp"


@app.route(route=".well-known/ucp", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def ucp_profile(req: func.HttpRequest) -> func.HttpResponse:
    return _json(build_profile(get_settings(), profile_url=_profile_url(req)))


@app.route(route="healthz", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def healthz(req: func.HttpRequest) -> func.HttpResponse:
    settings = get_settings()
    return _json({"status": "ok", "configured": settings.has_credentials})


@app.route(route="catalog/search", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def catalog_search(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return _json({"error": "invalid_json"}, status=400)

    query = (body or {}).get("query")
    if not query or not isinstance(query, str):
        return _json({"error": "missing_query"}, status=400)
    context = body.get("context") if isinstance(body.get("context"), dict) else None

    try:
        structured = _ucp().search_catalog(query, context=context, profile_url=_profile_url(req))
    except UCPError as exc:
        return _handle_ucp_error(exc)

    return _json(normalize_search(structured))


@app.route(route="catalog/product", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def catalog_product(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return _json({"error": "invalid_json"}, status=400)

    product_id = (body or {}).get("productId")
    if not product_id or not isinstance(product_id, str):
        return _json({"error": "missing_productId"}, status=400)
    selected = body.get("selected") if isinstance(body.get("selected"), list) else None

    try:
        structured = _ucp().get_product(product_id, selected=selected, profile_url=_profile_url(req))
    except UCPError as exc:
        return _handle_ucp_error(exc)

    product = structured.get("product") if isinstance(structured, dict) else None
    if isinstance(product, dict):
        return _json({"product": normalize_product(product)})
    # Some responses return the product at the top level.
    return _json({"product": normalize_product(structured)})


def _handle_ucp_error(exc: UCPError) -> func.HttpResponse:
    if exc.code in ("missing_credentials", "missing_catalog_url"):
        logger.warning("Broker not configured: %s", exc)
        return _json({"error": "broker_not_configured", "detail": str(exc)}, status=503)
    logger.error("UCP call failed: %s (status=%s)", exc, exc.status)
    return _json({"error": "upstream_error", "detail": str(exc)}, status=502)
