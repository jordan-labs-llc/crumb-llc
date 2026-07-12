"""Broker configuration, read from environment variables.

In Azure these are Function App *application settings*; the two real secrets
(`SHOPIFY_UCP_CLIENT_ID` / `SHOPIFY_UCP_CLIENT_SECRET`) are wired as **Key Vault
references** so their values resolve from Key Vault via the app's managed identity and
never live in the deployment or the image. Locally they come from `local.settings.json`
(gitignored). See `local.settings.json.example`.
"""

from __future__ import annotations

import json
from functools import lru_cache
from typing import Any
from urllib.parse import urlparse

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Combined broker settings. Field aliases are the exact env-var names."""

    model_config = SettingsConfigDict(
        env_prefix="",
        case_sensitive=False,
        populate_by_name=True,
        extra="ignore",
        # Pick up a local .env for dev (uvicorn, make verify). Absent in the container,
        # where these come from env vars / Key Vault references. OS env wins over .env.
        env_file=".env",
        env_file_encoding="utf-8",
    )

    # --- Shopify UCP credentials (the only secrets) ---
    client_id: str = Field(default="", alias="SHOPIFY_UCP_CLIENT_ID")
    client_secret: str = Field(default="", alias="SHOPIFY_UCP_CLIENT_SECRET")

    # --- UCP endpoints / config (not secret) ---
    # The Global Catalog MCP endpoint copied from the Dev Dashboard ("Catalogs → Copy URL").
    catalog_url: str = Field(default="", alias="SHOPIFY_CATALOG_URL")
    # Client-credentials token endpoint.
    token_url: str = Field(
        default="https://api.shopify.com/auth/access_token",
        alias="SHOPIFY_TOKEN_URL",
    )
    # UCP protocol version advertised in the hosted agent profile.
    ucp_version: str = Field(default="2026-04-08", alias="UCP_VERSION")
    # Optional shared key. When set, callers must send it as the `x-broker-key` header.
    broker_key: str = Field(default="", alias="CRUMB_BROKER_KEY")
    # Public URL of the hosted agent profile. If empty, the HTTP layer derives it from the
    # incoming request host (so it works on *.azurewebsites.net without extra config).
    agent_profile_url: str = Field(default="", alias="AGENT_PROFILE_URL")

    # Explicit merchant-id -> HTTPS UCP origin registry. Checkout discovery never uses an
    # origin supplied by the device; an empty registry disables live checkout preparation.
    checkout_merchants_json: str = Field(default="", alias="UCP_CHECKOUT_MERCHANTS_JSON")

    # --- Token caching ---
    # Fallback TTL when the token response omits `expires_in` (Shopify JWTs last ~60 min).
    token_ttl_seconds: int = Field(default=3600, alias="UCP_TOKEN_TTL_SECONDS")
    # Refresh this many seconds before expiry to avoid using a token mid-flight.
    token_refresh_buffer_seconds: int = Field(default=300, alias="UCP_TOKEN_REFRESH_BUFFER_SECONDS")

    # --- Networking ---
    http_timeout_seconds: float = Field(default=15.0, alias="UCP_HTTP_TIMEOUT_SECONDS")

    @property
    def has_credentials(self) -> bool:
        """True only when the broker is configured to make live UCP calls."""
        return bool(self.client_id and self.client_secret and self.catalog_url)

    @property
    def checkout_merchants(self) -> dict[str, str]:
        """Return syntactically safe HTTPS origins, ignoring malformed entries."""
        if not self.checkout_merchants_json:
            return {}
        try:
            value: Any = json.loads(self.checkout_merchants_json)
        except (TypeError, ValueError):
            return {}
        if not isinstance(value, dict):
            return {}
        merchants: dict[str, str] = {}
        for key, origin in value.items():
            if not isinstance(key, str) or not key or not isinstance(origin, str):
                continue
            try:
                parsed = urlparse(origin)
                valid = (
                    parsed.scheme == "https"
                    and bool(parsed.hostname)
                    and not parsed.username
                    and not parsed.password
                    and parsed.port in (None, 443)
                    and parsed.path in ("", "/")
                    and not parsed.query
                    and not parsed.fragment
                )
            except ValueError:
                valid = False
            if valid:
                merchants[key] = origin.rstrip("/")
        return merchants

    @property
    def checkout_enabled(self) -> bool:
        return bool(self.checkout_merchants)


@lru_cache
def get_settings() -> Settings:
    """Process-wide cached settings."""
    return Settings()
