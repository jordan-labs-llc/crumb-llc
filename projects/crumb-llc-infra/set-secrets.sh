#!/usr/bin/env bash
# Write the broker's secrets into Key Vault, out-of-band from any deployment.
#
# Values are read interactively (not echoed, not stored in this script, not on the
# deploy command line, not in shell history). The Container App reads them at runtime via
# its managed identity — Bicep only references them by name.
#
# Run this AFTER deploy.sh has created the Key Vault, then redeploy with ENABLE_SHOPIFY=true.
set -euo pipefail

RG="${RG:-rg-crumb-agent}"
KV="${KV:-$(az keyvault list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)}"

if [[ -z "$KV" ]]; then
  echo "No Key Vault found in ${RG}. Run ./deploy.sh first to create it." >&2
  exit 1
fi

echo "Writing secrets to Key Vault: ${KV}"
echo "(input is hidden; values are not echoed or logged)"

read -rsp "SHOPIFY_UCP_CLIENT_ID:     " CLIENT_ID; echo
read -rsp "SHOPIFY_UCP_CLIENT_SECRET: " CLIENT_SECRET; echo
read -rsp "CRUMB_BROKER_KEY (optional, blank to skip): " BROKER_KEY; echo

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "client id and secret are required." >&2
  exit 1
fi

az keyvault secret set --vault-name "$KV" --name shopify-ucp-client-id \
  --value "$CLIENT_ID" -o none
az keyvault secret set --vault-name "$KV" --name shopify-ucp-client-secret \
  --value "$CLIENT_SECRET" -o none
echo "✓ set shopify-ucp-client-id, shopify-ucp-client-secret"

if [[ -n "$BROKER_KEY" ]]; then
  az keyvault secret set --vault-name "$KV" --name crumb-broker-key \
    --value "$BROKER_KEY" -o none
  echo "✓ set crumb-broker-key  → deploy with ENABLE_BROKER_KEY=true"
fi

echo
echo "Next: wire the references and roll the app:"
echo "  ENABLE_SHOPIFY=true${BROKER_KEY:+ ENABLE_BROKER_KEY=true} ./deploy.sh"
