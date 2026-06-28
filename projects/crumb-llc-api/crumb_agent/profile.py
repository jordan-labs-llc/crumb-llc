"""The hosted UCP agent profile.

Every UCP request carries ``meta.ucp-agent.profile`` pointing at a public URL serving this
document. Shopify fetches and caches it to negotiate capabilities and apply a trust tier.
For the discovery-only broker we advertise just the catalog search capability — no cart or
checkout capabilities, which keeps us in the low-trust, no-customer-data lane.
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
    return {
        "ucp": {
            "version": version,
            "id": profile_url or settings.agent_profile_url or None,
            "agent": {
                "name": "Crumb",
                "description": "A task-driven personal-curator shopping agent.",
            },
            "capabilities": {
                # Discovery only. See module docstring for why cart/checkout are omitted.
                "dev.ucp.shopping.catalog.search": [{"version": version}],
            },
        }
    }
