# PostgreSQL Polaris
# Run `make` or `make help` for the list of targets.

SHELL        := bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help

COMPOSE   := docker compose -f docker/docker-compose.yml
CONTAINER := polaris-db
PG_USER   := polaris
PG_DB     := polaris

SCALE ?= 1
SEED  ?= 42

.PHONY: help bootstrap up ui down restart status logs psql shell \
        build build-all module reset check reproduce test test-modules \
        bench bench-report backup lint clean nuke

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m [SCALE=n SEED=n]\n"} \
	     /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
	     /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Environment
bootstrap: ## Create .env files and build the database image
	@test -f docker/.env || cp docker/.env.example docker/.env
	@test -f .env || cp .env.example .env
	@$(COMPOSE) build
	@echo "Bootstrap complete. Next: make up"

up: ## Start PostgreSQL (first start builds the dataset, ~30 s)
	@$(COMPOSE) up -d --wait db
	@echo "PostgreSQL ready on localhost:$${POSTGRES_PORT:-5432} (db=$(PG_DB) user=$(PG_USER)). Try: make psql"

ui: ## Start Adminer (:8080) and pgAdmin (:8081) as well
	@$(COMPOSE) --profile ui up -d --wait

down: ## Stop all containers (data volume is kept)
	@$(COMPOSE) --profile ui down

restart: down up ## Restart the stack

status: ## Show container health
	@$(COMPOSE) --profile ui ps

logs: ## Follow database logs
	@$(COMPOSE) logs -f db

psql: ## Interactive psql session
	@docker exec -it $(CONTAINER) psql -U $(PG_USER) -d $(PG_DB)

shell: ## Shell inside the database container
	@docker exec -it $(CONTAINER) bash

##@ Data
build: ## Rebuild schemas and data in place (SCALE, SEED)
	@scripts/build_db.sh -s $(SCALE) -r $(SEED)

build-all: ## Rebuild and also run every module 02-16
	@scripts/build_db.sh -s $(SCALE) -r $(SEED) -m

module: ## Run one file, e.g. make module F=sql/07_geospatial/routing_nearest.sql
	@test -n "$(F)" || { echo "usage: make module F=path/to/file.sql"; exit 1; }
	@scripts/run_sql.sh "$(F)"

reset: ## Regenerate base data (keeps module objects)
	@scripts/reset_db.sh

##@ Verification
check: lint test test-modules reproduce ## Everything CI runs

test: ## pgTAP suite (schema, constraints, data invariants, regressions)
	@docker exec $(CONTAINER) pg_prove -U $(PG_USER) -d $(PG_DB) --ext .sql \
	    /tests/schema_validation.sql /tests/data_integrity_checks.sql /tests/regression_tests.sql

test-modules: ## Every module standalone + idempotent on a fresh copy
	@scripts/check_modules.sh

reproduce: ## Same seed twice under different plans -> identical fingerprints
	@scripts/reproduce.sh $(SCALE) $(SEED)

lint: ## shellcheck scripts, validate compose file
	@shellcheck -x scripts/*.sh docker/initdb/*.sh benchmarks/*.sh
	@$(COMPOSE) config --quiet
	@echo "lint ok"

##@ Benchmarks
bench: ## Run the pgbench workload suite (see benchmarks/README.md)
	@benchmarks/run.sh

bench-report: ## Summarise the latest benchmark run with confidence intervals
	@python3 benchmarks/analyze.py benchmarks/results/latest

##@ Operations
backup: ## pg_dump + restore into a scratch DB + fingerprint verification
	@scripts/backup_demo.sh

clean: ## Stop containers and delete the data volume
	@$(COMPOSE) --profile ui down -v

nuke: clean ## Also remove built images and check logs
	@docker image rm -f polaris-db:$${PG_MAJOR:-17} 2>/dev/null || true
	@rm -rf .check_logs
