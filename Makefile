# PostgreSQL Polaris - Main Orchestration Makefile
# Location: /Makefile

.PHONY: help bootstrap up down restart psql reset test bench clean logs status

# Default target
help: ## Show this help message
	@echo "PostgreSQL Polaris - Learning Environment"
	@echo ""
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Initialize the project (first-time setup)
	@echo "🚀 Bootstrapping PostgreSQL Polaris..."
	@if [ ! -f docker/.env ]; then cp docker/.env.example docker/.env; fi
	@if [ ! -f .env ]; then cp .env.example .env; fi
	@docker-compose -f docker/docker-compose.yml pull
	@echo "✅ Bootstrap complete! Run 'make up' to start the environment."

up: ## Start the database and admin UI
	@echo "🌟 Starting PostgreSQL Polaris environment..."
	@docker-compose -f docker/docker-compose.yml up -d
	@echo "⏳ Waiting for database to be ready..."
	@sleep 10
	@echo "✅ Environment ready!"
	@echo "   Database: localhost:5432"
	@echo "   Adminer:  http://localhost:8080"
	@echo "   Connect:  make psql"

down: ## Stop all containers
	@echo "🛑 Stopping PostgreSQL Polaris..."
	@docker-compose -f docker/docker-compose.yml down

restart: down up ## Restart all containers

psql: ## Connect to PostgreSQL with psql client
	@echo "🔗 Connecting to PostgreSQL..."
	@docker exec -it polaris-db psql -U polaris -d polaris

psql-root: ## Connect as postgres superuser
	@docker exec -it polaris-db psql -U postgres -d polaris

logs: ## Show container logs
	@docker-compose -f docker/docker-compose.yml logs -f

status: ## Show container status
	@docker-compose -f docker/docker-compose.yml ps

# Data Management
reset: ## Reset database to clean state (WARNING: destroys all data)
	@echo "⚠️  This will destroy all data. Continue? [y/N]" && read ans && [ $${ans:-N} = y ]
	@echo "🗑️  Resetting database..."
	@docker-compose -f docker/docker-compose.yml down -v
	@docker-compose -f docker/docker-compose.yml up -d
	@sleep 10
	@echo "✅ Database reset complete!"

load-data: ## Load sample data into database
	@echo "📊 Loading sample data..."
	@./scripts/load_sample_data.sh

# Module Execution
run-module: ## Run specific SQL module (usage: make run-module MODULE=01_schema_design/civics.sql)
	@if [ -z "$(MODULE)" ]; then echo "❌ Usage: make run-module MODULE=path/to/file.sql"; exit 1; fi
	@echo "🏃 Running module: $(MODULE)"
	@./scripts/run_sql.sh sql/$(MODULE)

run-init: ## Run initialization scripts
	@echo "🔧 Running initialization..."
	@for file in sql/00_init/*.sql; do \
		echo "Running $$file..."; \
		./scripts/run_sql.sh $$file; \
	done

run-examples: ## Run quick demo examples
	@echo "🎯 Running example demonstrations..."
	@./scripts/run_sql.sh examples/quick_demo.sql

# Testing and Validation
test: ## Run all validation tests
	@echo "🧪 Running validation tests..."
	@./scripts/run_sql.sh tests/schema_validation.sql
	@./scripts/run_sql.sh tests/data_integrity_checks.sql
	@./scripts/run_sql.sh tests/regression_tests.sql
	@echo "✅ All tests passed!"

test-schema: ## Validate schema structure
	@./scripts/run_sql.sh tests/schema_validation.sql

test-data: ## Check data integrity
	@./scripts/run_sql.sh tests/data_integrity_checks.sql

bench: ## Run performance benchmarks
	@echo "⚡ Running performance benchmarks..."
	@./scripts/run_sql.sh tests/performance_benchmarks.sql

# Development Helpers
backup: ## Create database backup
	@echo "💾 Creating backup..."
	@./scripts/backup_demo.sh

shell: ## Open shell in database container
	@docker exec -it polaris-db bash

adminer: ## Open Adminer in browser (requires xdg-open/open command)
	@echo "🌐 Opening Adminer..."
	@command -v xdg-open >/dev/null && xdg-open http://localhost:8080 || \
	 command -v open >/dev/null && open http://localhost:8080 || \
	 echo "Please open http://localhost:8080 manually"

# Cleanup
clean: ## Clean up containers and volumes
	@echo "🧹 Cleaning up..."
	@docker-compose -f docker/docker-compose.yml down -v --remove-orphans
	@docker system prune -f

clean-all: ## Deep clean (remove images too)
	@echo "🧹 Deep cleaning..."
	@docker-compose -f docker/docker-compose.yml down -v --remove-orphans --rmi all
	@docker system prune -a -f

# Documentation
docs: ## Generate/update documentation
	@echo "📚 Updating documentation..."
	@echo "Documentation available in docs/ directory"

# Module-specific shortcuts
schema: ## Run schema design modules
	@make run-module MODULE=01_schema_design/civics.sql
	@make run-module MODULE=01_schema_design/commerce.sql
	@make run-module MODULE=01_schema_design/mobility.sql
	@make run-module MODULE=01_schema_design/geo.sql

constraints: ## Run constraint and indexing modules
	@make run-module MODULE=02_constraints_indexes/constraints.sql
	@make run-module MODULE=02_constraints_indexes/indexing_basics.sql

queries: ## Run query practice modules
	@make run-module MODULE=03_dml_queries/seed_data.sql
	@make run-module MODULE=03_dml_queries/practice_selects.sql

# Environment info
info: ## Show environment information
	@echo "PostgreSQL Polaris Environment Info"
	@echo "===================================="
	@echo "Docker Compose File: docker/docker-compose.yml"
	@echo "Database Container: polaris-db"
	@echo "Admin Container: polaris-adminer"
	@echo ""
	@echo "Ports:"
	@echo "  PostgreSQL: 5432"
	@echo "  Adminer: 8080"
	@echo ""
	@echo "Default Credentials:"
	@echo "  Database: polaris"
	@echo "  Username: polaris"
	@echo "  Password: polar_star_2024"
	@echo ""
	@echo "Quick Commands:"
	@echo "  Connect: make psql"
	@echo "  Reset: make reset"
	@echo "  Test: make test"
