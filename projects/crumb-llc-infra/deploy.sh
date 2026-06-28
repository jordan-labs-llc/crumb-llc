#!/usr/bin/env bash
# Build the broker image and provision the Container App into its own resource group.
#
# Usage:
#   ./deploy.sh                                   # deploy without creds (broker idle)
#   SHOPIFY_CLIENT_ID=... SHOPIFY_CLIENT_SECRET=... SHOPIFY_CATALOG_URL=... ./deploy.sh
#   CRUMB_BROKER_KEY=... ./deploy.sh              # also require an x-broker-key header
#
# Secrets are passed via env (never committed) and seeded into Key Vault.
set -euo pipefail

RG="${RG:-rg-crumb-agent}"
LOCATION="${LOCATION:-eastus}"
ACR="${ACR:-acrcrumbprod}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
API_DIR="${API_DIR:-../crumb-llc-api}"

echo "==> Ensuring resource group ${RG} (${LOCATION})"
az group create -n "$RG" -l "$LOCATION" -o none

echo "==> Building + pushing image via ACR Tasks (no local Docker needed)"
az acr build --registry "$ACR" --image "crumb-agent:${IMAGE_TAG}" "$API_DIR" -o none

EXTRA=()
if [[ -n "${SHOPIFY_CLIENT_ID:-}" && -n "${SHOPIFY_CLIENT_SECRET:-}" ]]; then
  echo "==> Seeding Shopify credentials into Key Vault"
  EXTRA+=(shopifyClientId="$SHOPIFY_CLIENT_ID" shopifyClientSecret="$SHOPIFY_CLIENT_SECRET")
fi
[[ -n "${SHOPIFY_CATALOG_URL:-}" ]] && EXTRA+=(shopifyCatalogUrl="$SHOPIFY_CATALOG_URL")
[[ -n "${CRUMB_BROKER_KEY:-}" ]] && EXTRA+=(brokerKey="$CRUMB_BROKER_KEY")

echo "==> Deploying main.bicep"
az deployment group create \
  -g "$RG" \
  -f main.bicep \
  -p environments/dev.bicepparam \
  -p imageTag="$IMAGE_TAG" \
  ${EXTRA:+-p "${EXTRA[@]}"} \
  -o table

echo "==> Outputs"
az deployment group show -g "$RG" -n main --query properties.outputs -o jsonc 2>/dev/null || true
