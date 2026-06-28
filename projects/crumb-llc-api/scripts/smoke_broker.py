#!/usr/bin/env python3
"""Smoke-test the DEPLOYED broker end to end.

Hits the broker's own endpoints — the token exchange, profile, and Shopify call all happen
server-side, so this needs no Shopify credentials locally (and no public-profile setup).

Config (env):
  BROKER / CRUMB_API_BASE_URL   the broker base URL (required)
  BROKER_KEY / CRUMB_BROKER_KEY  the x-broker-key header value (if the broker requires it)

Usage:  BROKER=https://... python scripts/smoke_broker.py [query words...]
"""

from __future__ import annotations

import os
import sys

import httpx


def main() -> int:
    base = os.environ.get("BROKER") or os.environ.get("CRUMB_API_BASE_URL")
    if not base:
        print("✗ set BROKER=https://<your-broker>  (or CRUMB_API_BASE_URL)")
        return 2
    base = base.rstrip("/")

    key = os.environ.get("BROKER_KEY") or os.environ.get("CRUMB_BROKER_KEY")
    headers = {"x-broker-key": key} if key else {}
    query = " ".join(sys.argv[1:]) or "wireless headphones under $100"

    with httpx.Client(timeout=30.0) as http:
        try:
            health = http.get(f"{base}/healthz")
            print(f"→ GET  /healthz        → {health.status_code} {health.text}")
            resp = http.post(
                f"{base}/catalog/search", json={"query": query}, headers=headers
            )
        except httpx.HTTPError as exc:
            print(f"✗ request failed: {exc}")
            return 1

    print(f"→ POST /catalog/search → {resp.status_code}")
    if resp.status_code != 200:
        print(resp.text)
        return 1

    data = resp.json()
    products = data.get("products", [])
    print(f"✓ {len(products)} product(s); ucp={data.get('ucpVersion')}")
    for product in products[:5]:
        print(f"   • {product.get('title')}  ({product.get('sellerDomain')})")

    return 0 if products else 1


if __name__ == "__main__":
    raise SystemExit(main())
