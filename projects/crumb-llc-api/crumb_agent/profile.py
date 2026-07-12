"""The hosted UCP agent profile.

Every UCP request carries ``meta.ucp-agent.profile`` pointing at a public URL serving this
document. Shopify fetches and caches it to negotiate capabilities and apply a trust tier.
Checkout is advertised only when an explicit merchant registry enables the broker's
checkout-session preparation path. This is a platform capability declaration, not a
merchant service endpoint. The live profile never advertises a payment handler: Crumb's
mock payment lifecycle is device-local test data, not a credential provider.
"""

from __future__ import annotations

from typing import Any

from .config import Settings


def build_profile(settings: Settings, *, profile_url: str | None = None) -> dict[str, Any]:
    """Build the agent profile document.

    ``profile_url`` is the public URL this document is served from; it is echoed into the
    profile's ``id`` so the hosted location is self-describing.
    """
    version = settings.ucp_version
    capabilities: dict[str, list[dict[str, Any]]] = {
        "dev.ucp.shopping.catalog.search": [{"version": version}],
    }
    if settings.checkout_enabled:
        capabilities["dev.ucp.shopping.checkout"] = [
            {
                "version": version,
                "spec": f"https://ucp.dev/{version}/specification/checkout",
                "schema": f"https://ucp.dev/{version}/schemas/shopping/checkout.json",
            }
        ]
    return {
        "ucp": {
            "version": version,
            "id": profile_url or settings.agent_profile_url or None,
            "agent": {
                "name": "Crumb",
                "description": "A task-driven personal-curator shopping agent.",
            },
            "capabilities": capabilities,
            # Deliberately no `payment_handlers`. Adding one requires real provider and
            # merchant onboarding; the app's sandbox handler must never escape the device.
        }
    }
