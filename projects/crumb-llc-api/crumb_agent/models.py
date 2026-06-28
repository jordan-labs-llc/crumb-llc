"""Normalization from UCP catalog payloads to a stable broker shape.

The broker returns a small, stable JSON contract to the iOS app so the client is not
coupled to the full UCP schema. Parsing is intentionally *tolerant* — UCP responses vary
by version and Shopify extension fields, so missing keys degrade gracefully rather than
raising. Fields marked "best-effort" should be confirmed against live responses.
"""

from __future__ import annotations

from typing import Any


def _money(node: Any) -> dict[str, Any] | None:
    """Extract a {amount, currency} money node (amounts are integer minor units)."""
    if not isinstance(node, dict):
        return None
    amount = node.get("amount")
    currency = node.get("currency")
    if amount is None:
        return None
    return {"amount": amount, "currency": currency}


def normalize_product(node: dict[str, Any]) -> dict[str, Any]:
    """Map a single UCP product to the broker's product shape (best-effort)."""
    price_range = node.get("price_range") or {}
    seller = node.get("seller") or {}

    options = []
    for option in node.get("options", []) or []:
        if not isinstance(option, dict):
            continue
        values = [
            v.get("label")
            for v in option.get("values", []) or []
            if isinstance(v, dict) and v.get("label") is not None
        ]
        options.append({"name": option.get("name"), "values": values})

    images = node.get("images") or []
    image_url = None
    if images and isinstance(images[0], dict):
        image_url = images[0].get("url")
    elif isinstance(node.get("image"), dict):
        image_url = node["image"].get("url")

    return {
        "id": node.get("id"),
        "title": node.get("title"),
        "description": node.get("description"),
        "imageURL": image_url,
        "priceMin": _money(price_range.get("min")),
        "priceMax": _money(price_range.get("max")),
        "sellerDomain": seller.get("domain"),
        "options": options,
        # Per-variant checkout/buy link is the per-shop handoff target (UCP continue_url).
        "buyURL": node.get("buy_url") or node.get("checkout_url"),
        "variantId": node.get("variant_id") or node.get("selected_variant_id"),
    }


def normalize_search(structured: dict[str, Any]) -> dict[str, Any]:
    """Map a UCP search_catalog result to ``{products: [...], ucpVersion: str|None}``."""
    products = structured.get("products", []) if isinstance(structured, dict) else []
    version = None
    ucp = structured.get("ucp") if isinstance(structured, dict) else None
    if isinstance(ucp, dict):
        version = ucp.get("version")
    return {
        "products": [normalize_product(p) for p in products if isinstance(p, dict)],
        "ucpVersion": version,
    }
