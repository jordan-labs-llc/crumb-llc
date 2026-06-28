"""Tests for the UCP → broker normalization, pinned to the real Global Catalog shape.

The product fixture mirrors a live ``search_catalog`` node (confirmed 2026-04-08): text
fields are ``{plain}`` objects, images live under ``media``, and the buy link + variant id
live on ``variants[0]`` (there is no top-level ``seller``/``images``/``buy_url``).
"""

from __future__ import annotations

from crumb_agent.models import normalize_product, normalize_search

# A trimmed-but-faithful live product node.
LIVE_PRODUCT = {
    "id": "gid://shopify/p/1iRHyDgg1fYgi8HCOVLLud",
    "title": "Merino Wool Sock",
    "description": {"plain": "Super warm, durable merino wool socks made in Australia."},
    "options": [
        {"name": "Color", "values": [{"label": "Black"}, {"label": "Navy"}]},
        {"name": "Size", "values": [{"label": "6-11"}]},
    ],
    "media": [
        {
            "type": "image",
            "url": "https://cdn.shopify.com/s/files/1/0449/9724/7129/products/merinoblack.jpg",
            "alt_text": "Merino Wool Sock",
        }
    ],
    "price_range": {
        "min": {"amount": 1264, "currency": "USD"},
        "max": {"amount": 1264, "currency": "USD"},
    },
    "variants": [
        {
            "id": "gid://shopify/ProductVariant/35625819013273",
            "title": "Merino Wool Sock",
            "description": {"plain": "Merino wool is a natural fibre…"},
            "url": "https://www.naturessocksaustralia.com.au/products/australian-merino-wool-socks?variant=35625819013273",
            "price": {"amount": 1264, "currency": "USD"},
            "availability": {"available": True},
        }
    ],
}


def test_normalize_maps_real_catalog_shape() -> None:
    p = normalize_product(LIVE_PRODUCT)

    assert p["id"] == "gid://shopify/p/1iRHyDgg1fYgi8HCOVLLud"
    assert p["title"] == "Merino Wool Sock"
    # description object flattened to its plain text
    assert p["description"] == "Super warm, durable merino wool socks made in Australia."
    # image comes from media[0].url, not images/image
    assert p["imageURL"].endswith("/merinoblack.jpg")
    # buy/handoff link + variant id come from variants[0]
    assert p["buyURL"].startswith("https://www.naturessocksaustralia.com.au/products/")
    assert p["variantId"] == "gid://shopify/ProductVariant/35625819013273"
    # seller domain recovered from the variant URL host
    assert p["sellerDomain"] == "www.naturessocksaustralia.com.au"
    # price from price_range.min (minor units preserved)
    assert p["priceMin"] == {"amount": 1264, "currency": "USD"}
    # options flattened to [{name, values:[str]}]
    assert p["options"][0] == {"name": "Color", "values": ["Black", "Navy"]}


def test_price_falls_back_to_variant_when_no_range() -> None:
    node = {
        "id": "p1",
        "title": "Thing",
        "variants": [{"id": "v1", "url": "https://shop.example/p/x", "price": {"amount": 500, "currency": "USD"}}],
    }
    p = normalize_product(node)
    assert p["priceMin"] == {"amount": 500, "currency": "USD"}
    assert p["sellerDomain"] == "shop.example"


def test_legacy_field_names_still_read() -> None:
    # Tolerant to the older/guessed shape so the contract survives drift.
    node = {
        "id": "p2",
        "title": "Legacy",
        "description": "already a string",
        "image": {"url": "https://cdn.example/img.jpg"},
        "seller": {"domain": "legacy.example"},
        "buy_url": "https://legacy.example/cart/c/1",
        "variant_id": "v-legacy",
        "price_range": {"min": {"amount": 999, "currency": "USD"}},
    }
    p = normalize_product(node)
    assert p["description"] == "already a string"
    assert p["imageURL"] == "https://cdn.example/img.jpg"
    assert p["sellerDomain"] == "legacy.example"
    assert p["buyURL"] == "https://legacy.example/cart/c/1"
    assert p["variantId"] == "v-legacy"


def test_missing_fields_degrade_to_none() -> None:
    p = normalize_product({"id": "bare", "title": "Bare"})
    assert p["imageURL"] is None
    assert p["buyURL"] is None
    assert p["variantId"] is None
    assert p["sellerDomain"] is None
    assert p["priceMin"] is None
    assert p["options"] == []


def test_normalize_search_wraps_products_and_version() -> None:
    out = normalize_search({"products": [LIVE_PRODUCT], "ucp": {"version": "2026-04-08"}})
    assert out["ucpVersion"] == "2026-04-08"
    assert len(out["products"]) == 1
    assert out["products"][0]["imageURL"].endswith("/merinoblack.jpg")
