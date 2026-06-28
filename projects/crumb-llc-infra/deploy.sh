#!/usr/bin/env bash
# Provision the Crumb UCP broker infrastructure into its own resource group.
#
# Usage:
#   ./deploy.sh                                  # deploy without Shopify creds (broker idle)
#   SHOPIFY_CLIENT_ID=... SHOPIFY_CLIENT_SECRET=... SHOPIFY_CATALOG_URL=... ./deploy.sh
#
# Secrets are passed on the command line (never committed) and seeded into Key Vault.
set -euo pipefail

RG="${RG:-rg-crumb-agent}"
LOCATION="${LOCATION:-eastus}"

echo "==> Ensuring resource group ${RG} (${LOCATION})"
az group create -n "$RG" -l "$LOCATION" -o none

EXTRA_PARAMS=()
if [[ -n "${SHOPIFY_CLIENT_ID:-}" && -n "${SHOPIFY_CLIENT_SECRET:-}" ]]; then
  echo "==> Seeding Shopify credentials into Key Vault"
  EXTRA_PARAMS+=(shopifyClientId="$SHOPIFY_CLIENT_ID" shopifyClientSecret="$SHOPIFY_CLIENT_SECRET")
fi
if [[ -n "${SHOPIFY_CATALOG_URL:-}" ]]; then
  EXTRA_PARAMS+=(shopifyCatalogUrl="$SHOPIFY_CATALOG_URL")
fi

echo "==> Deploying main.bicep"
az deployment group create \
  -g "$RG" \
  -f main.bicep \
  -p environments/dev.bicepparam \
  ${EXTRA_PARAMS:+-p "${EXTRA_PARAMS[@]}"} \
  -o table

echo "==> Outputs"
az deployment group show -g "$RG" -n main --query properties.outputs -o jsonc 2>/dev/null || true
