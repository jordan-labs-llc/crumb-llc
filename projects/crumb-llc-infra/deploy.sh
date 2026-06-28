#!/usr/bin/env bash
# Build the broker image and provision the Container App. Carries NO secrets — secret
# values live in Key Vault (see set-secrets.sh) and resolve at runtime via managed identity.
#
# Usage:
#   ./deploy.sh                                  # deploy (idle until secrets are set + enabled)
#   ENABLE_SHOPIFY=true ./deploy.sh              # wire the Shopify Key Vault references
#   ENABLE_SHOPIFY=true ENABLE_BROKER_KEY=true ./deploy.sh
#
# Non-secret config (catalog URL, version) lives in environments/dev.bicepparam.
set -euo pipefail

RG="${RG:-rg-crumb-agent}"
LOCATION="${LOCATION:-eastus}"
ACR="${ACR:-acrcrumbprod}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
API_DIR="${API_DIR:-../crumb-llc-api}"
ENABLE_SHOPIFY="${ENABLE_SHOPIFY:-false}"
ENABLE_BROKER_KEY="${ENABLE_BROKER_KEY:-false}"

echo "==> Ensuring resource group ${RG} (${LOCATION})"
az group create -n "$RG" -l "$LOCATION" -o none

echo "==> Building + pushing image via ACR Tasks (no local Docker needed)"
az acr build --registry "$ACR" --image "crumb-agent:${IMAGE_TAG}" "$API_DIR" -o none

echo "==> Deploying main.bicep (enableShopify=${ENABLE_SHOPIFY}, enableBrokerKey=${ENABLE_BROKER_KEY})"
az deployment group create \
  -g "$RG" \
  -f main.bicep \
  -p environments/dev.bicepparam \
  -p imageTag="$IMAGE_TAG" \
  -p enableShopify="$ENABLE_SHOPIFY" \
  -p enableBrokerKey="$ENABLE_BROKER_KEY" \
  -o table

echo "==> Outputs"
az deployment group show -g "$RG" -n main --query properties.outputs -o jsonc 2>/dev/null || true
