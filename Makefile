# Convenience targets for local runs. Reads ./.env if present.
SHELL := /bin/bash
ifneq (,$(wildcard ./.env))
include ./.env
export
endif

.PHONY: help sync dry-run test-local lint

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

sync: ## Run the sync against the configured Artifactory
	@bash scripts/sync-grype-db.sh

dry-run: ## Download + verify the DB but skip the upload
	@DRY_RUN=1 bash scripts/sync-grype-db.sh

test-local: dry-run ## Alias for dry-run (no Artifactory writes)

lint: ## Shellcheck the sync script (if shellcheck is installed)
	@command -v shellcheck >/dev/null 2>&1 && shellcheck scripts/sync-grype-db.sh || echo "shellcheck not installed — skipping"
