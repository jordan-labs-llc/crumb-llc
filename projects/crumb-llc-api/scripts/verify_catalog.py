#!/usr/bin/env python3
"""Verify the Shopify UCP catalog directly, using the broker's own UCPClient.

Reads config from `.env` (SHOPIFY_UCP_CLIENT_ID/SECRET, SHOPIFY_CATALOG_URL,
AGENT_PROFILE_URL). Performs the real client-credentials token exchange and a
`search_catalog` call, then prints the first few products. Exits non-zero on failure.

IMPORTANT: AGENT_PROFILE_URL must be a PUBLIC url that Shopify can fetch (e.g. your
deployed broker's `/.well-known/ucp`). A local/placeholder profile is rejected by Shopify.

Usage:  python scripts/verify_catalog.py [query words...]
"""

from __future__ import annotations

import os
import sys

# Make the project root importable when run as `python scripts/verify_catalog.py`.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from crumb_agent.config import get_settings  # noqa: E402
from crumb_agent.models import normalize_search  # noqa: E402
from crumb_agent.ucp_client import UCPClient, UCPError  # noqa: E402


def main() -> int:
    settings = get_settings()
    query = " ".join(sys.argv[1:]) or "wireless headphones under $100"

    missing = [
        name
        for name, value in {
            "SHOPIFY_UCP_CLIENT_ID": settings.client_id,
            "SHOPIFY_UCP_CLIENT_SECRET": settings.client_secret,
            "SHOPIFY_CATALOG_URL": settings.catalog_url,
        }.items()
        if not value
    ]
    if missing:
        print(f"✗ missing config: {', '.join(missing)}  (set them in .env)")
        return 2

    profile = settings.agent_profile_url
    if not profile:
        print("✗ AGENT_PROFILE_URL is not set.")
        print("  Shopify fetches your profile, so it must be PUBLIC — point it at your")
        print("  deployed broker's /.well-known/ucp.")
        return 2
    if "localhost" in profile or "127.0.0.1" in profile:
        print(f"✗ AGENT_PROFILE_URL ({profile}) is not publicly reachable; Shopify can't")
        print("  fetch it. Use your deployed broker's /.well-known/ucp instead.")
        return 2

    print(f"→ token endpoint : {settings.token_url}")
    print(f"→ catalog url    : {settings.catalog_url}")
    print(f"→ agent profile  : {profile}")
    print(f"→ query          : {query!r}\n")

    client = UCPClient(settings)
    try:
        token = client.access_token()
        print(f"✓ obtained access token ({len(token)} chars)")
        structured = client.search_catalog(query, profile_url=profile)
    except UCPError as exc:
        print(f"✗ UCP error [{exc.code}] status={exc.status}: {exc}")
        return 1
    except Exception as exc:  # noqa: BLE001 — surface any transport/parse failure
        print(f"✗ unexpected error: {exc}")
        return 1

    result = normalize_search(structured)
    products = result.get("products", [])
    print(f"✓ search_catalog returned {len(products)} product(s); ucp={result.get('ucpVersion')}\n")
    for product in products[:5]:
        price = product.get("priceMin") or {}
        amount = price.get("amount")
        currency = price.get("currency") or ""
        money = f"{amount / 100:.2f} {currency}".strip() if isinstance(amount, (int, float)) else "?"
        print(f"   • {product.get('title')}  —  {money}  ({product.get('sellerDomain')})")

    return 0 if products else 1


if __name__ == "__main__":
    raise SystemExit(main())
