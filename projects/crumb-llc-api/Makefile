# Crumb UCP broker — dev tasks.
#
# Picks the newest available Python (3.11+ required for the FastAPI/Pydantic models).
PYTHON ?= $(shell command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3)
PY := .venv/bin/python
RG ?= rg-crumb-agent
QUERY ?=

.DEFAULT_GOAL := help
.PHONY: help install test run verify verify-kv smoke health clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.venv:
	$(PYTHON) -m venv .venv
	.venv/bin/pip install -q --upgrade pip
	.venv/bin/pip install -q -r requirements.txt pytest

install: .venv ## Create the venv and install dependencies

test: .venv ## Run unit tests
	$(PY) -m pytest -q

run: .venv ## Run the broker locally (uvicorn --reload on :8000)
	$(PY) -m uvicorn server:app --reload --port 8000

verify: .venv ## Verify Shopify catalog using .env creds (QUERY="...")
	$(PY) scripts/verify_catalog.py $(QUERY)

verify-kv: .venv ## Verify using the client id/secret stored in Key Vault (RG=...)
	@KV=$$(az keyvault list -g $(RG) --query "[0].name" -o tsv); \
	if [ -z "$$KV" ]; then echo "✗ no Key Vault in $(RG)"; exit 1; fi; \
	echo "→ pulling client id/secret from $$KV"; \
	SHOPIFY_UCP_CLIENT_ID="$$(az keyvault secret show --vault-name $$KV -n shopify-ucp-client-id --query value -o tsv)" \
	SHOPIFY_UCP_CLIENT_SECRET="$$(az keyvault secret show --vault-name $$KV -n shopify-ucp-client-secret --query value -o tsv)" \
	$(PY) scripts/verify_catalog.py $(QUERY)

smoke: .venv ## Smoke-test the deployed broker end-to-end (BROKER=https://...)
	$(PY) scripts/smoke_broker.py $(QUERY)

health: ## Curl the broker health endpoint (BROKER=https://...)
	@curl -fsS "$${BROKER:?set BROKER=https://...}/healthz" && echo

clean: ## Remove the venv and caches
	rm -rf .venv .pytest_cache .ruff_cache
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
