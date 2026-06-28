"""Crumb UCP broker — stateless Azure Functions app that fronts Shopify's UCP
Global Catalog (search_catalog / get_product) and keeps all credentials server-side.

Pure logic lives here in ``crumb_agent`` (no ``azure.functions`` dependency) so it is
unit-testable without the Functions host. ``function_app.py`` is the thin HTTP layer.
"""

__all__ = ["config", "ucp_client", "models", "profile"]
