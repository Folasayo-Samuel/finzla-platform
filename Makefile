.PHONY: help install lint test build run fmt validate plan clean check
.DEFAULT_GOAL := help

ENV ?= dev
TF  := terraform -chdir=terraform/envs/$(ENV)

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## Install app dev dependencies
	cd app && pip install -r requirements-dev.txt

lint: ## Lint the application
	cd app && ruff check . && ruff format --check .

test: ## Run unit tests
	cd app && python -m pytest -v

verify: ## Check environment-dependent behaviour (prod hardening, 503 path)
	cd app && PYTHONPATH=. python tests/verify_behaviour.py

build: ## Build the container image
	docker build -t finzla-app:local app/

run: ## Run the container locally on :8000
	docker run --rm -p 8000:8000 -e APP_ENV=local finzla-app:local

smoke: ## Hit the endpoints of a locally running container
	@curl -fsS localhost:8000/health && echo
	@curl -fsS localhost:8000/version && echo

fmt: ## Format all Terraform
	terraform fmt -recursive terraform/

validate: ## Validate Terraform without a backend
	cd terraform/envs/$(ENV) && terraform init -backend=false && terraform validate

plan: ## Terraform plan for ENV (default dev)
	$(TF) plan

check: lint test verify fmt validate ## Everything CI would run locally

clean: ## Remove local build artifacts
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	rm -rf app/.pytest_cache app/.ruff_cache
	docker rmi finzla-app:local 2>/dev/null || true
