"""Normalization from UCP catalog payloads to a stable broker shape.

The broker returns a small, stable JSON contract to the iOS app so the client is not
coupled to the full UCP schema. Parsing is intentionally *tolerant* — UCP responses vary
by version and Shopify extension fields, so missing keys degrade gracefully rather than
raising.

## Real UCP catalog shape (confirmed against the live Global Catalog, 2026-04-08)

A `search_catalog` product node looks like::

    {
      "id": "gid://shopify/p/…",
      "title": "Merino Wool Sock",
      "description": {"plain": "…"},                 # text fields are {plain} objects
      "options": [{"name": "Color", "values": [{"label": "Black"}, …]}],
      "media": [{"type": "image", "url": "https://cdn.shopify.com/…", "alt_text": "…"}],
      "price_range": {"min": {"amount": 1264, "currency": "USD"}, "max": {…}},
      "variants": [
        {
          "id": "gid://shopify/ProductVariant/…",
          "url": "https://merchant.example/products/slug?variant=…",  # the buy/handoff link
          "price": {"amount": 1264, "currency": "USD"},
          "availability": {"available": true},
          …
        }
      ]
    }

There is **no top-level `seller`, `images`, `buy_url`, or `variant_id`** — those names were
guessed before a live key existed. The real fields are `media`, `variants[].url`, and
`variants[].id`; the seller domain is the host of the variant URL. We still read the old
names as fallbacks so the contract survives shape drift.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import urlparse


def _money(node: Any) -> dict[str, Any] | None:
    """Extract a {amount, currency} money node (amounts are integer minor units)."""
    if not isinstance(node, dict):
        return None
    amount = node.get("amount")
    currency = node.get("currency")
    if amount is None:
        return None
    return {"amount": amount, "currency": currency}


def _flatten_text(node: Any) -> str | None:
    """UCP text fields arrive as ``{"plain": "…"}`` objects; older shapes use a bare string."""
    if isinstance(node, dict):
        plain = node.get("plain")
        return plain if isinstance(plain, str) else None
    if isinstance(node, str):
        return node
    return None


def _first_image_url(node: dict[str, Any]) -> str | None:
    """First image URL, reading the real ``media`` array (falling back to ``images``/``image``)."""
    media = node.get("media") or node.get("images") or []
    if isinstance(media, list):
        for item in media:
            if isinstance(item, dict) and item.get("url"):
                return item["url"]
    image = node.get("image")
    if isinstance(image, dict):
        return image.get("url")
    return None


def _options(node: dict[str, Any]) -> list[dict[str, Any]]:
    """Normalize ``options`` to ``[{name, values: [str]}]`` (values are ``{label}`` objects)."""
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
    return options


def _seller_domain(node: dict[str, Any], buy_url: str | None) -> str | None:
    """Seller domain: explicit ``seller.domain`` if present, else the host of the buy URL."""
    seller = node.get("seller") or {}
    domain = seller.get("domain") if isinstance(seller, dict) else None
    if domain:
        return domain
    if buy_url:
        return urlparse(buy_url).netloc or None
    return None


def normalize_product(node: dict[str, Any]) -> dict[str, Any]:
    """Map a single UCP product to the broker's product shape (best-effort, tolerant)."""
    variants = node.get("variants") or []
    variant = variants[0] if variants and isinstance(variants[0], dict) else {}

    # The buy/handoff link lives on the variant (`url`); older guesses live on the node.
    buy_url = variant.get("url") or node.get("buy_url") or node.get("checkout_url")
    variant_id = (
        variant.get("id")
        or node.get("variant_id")
        or node.get("selected_variant_id")
    )

    price_range = node.get("price_range") or {}
    price_min = _money(price_range.get("min")) or _money(variant.get("price"))
    price_max = _money(price_range.get("max")) or price_min

    return {
        "id": node.get("id"),
        "title": node.get("title"),
        "description": _flatten_text(node.get("description")),
        "imageURL": _first_image_url(node),
        "priceMin": price_min,
        "priceMax": price_max,
        "sellerDomain": _seller_domain(node, buy_url),
        "options": _options(node),
        # Per-variant checkout/buy link — the per-shop handoff target (UCP continue_url).
        "buyURL": buy_url,
        "variantId": variant_id,
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
