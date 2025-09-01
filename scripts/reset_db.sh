#!/bin/bash
# Location: /scripts/reset_db.sh
# DANGER: Complete database reset - destroys all data and rebuilds from scratch

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Safety confirmation
confirm_reset() {
    echo ""
    log_warning "⚠️  DANGER: This will completely destroy all database data!"
    log_warning "⚠️  This action cannot be undone."
    log_warning "⚠️  All tables, data, and custom modifications will be lost."
    echo ""

    read -p "Are you sure you want to continue? Type 'YES' to proceed: " confirm

    if [[ "$confirm" != "YES" ]]; then
        log_info "Reset cancelled by user."
        exit 0
    fi

    log_warning "Starting reset in 5 seconds... Press Ctrl+C to cancel."
    sleep 5
}

# Check for force flag
FORCE=false
if [[ "$1" == "--force" || "$1" == "-f" ]]; then
    FORCE=true
    log_warning "Force mode enabled - skipping confirmation"
fi

# Main reset function
main() {
    log_info "PostgreSQL Polaris Database Reset Utility"

    if [[ "$FORCE" != "true" ]]; then
        confirm_reset
    fi

    log_info "Step 1: Stopping containers..."
    if ! docker-compose -f docker/docker-compose.yml down -v; then
        log_error "Failed to stop containers"
        exit 1
    fi
    log_success "Containers stopped and volumes removed"

    log_info "Step 2: Removing PostgreSQL data volumes..."
    # Remove any remaining volumes that might contain database data
    docker volume ls -q | grep -E "(polaris|postgres)" | while read volume; do
        if [[ -n "$volume" ]]; then
            log_info "Removing volume: $volume"
            docker volume rm "$volume" 2>/dev/null || true
        fi
    done

    log_info "Step 3: Cleaning up orphaned containers..."
    docker-compose -f docker/docker-compose.yml down --remove-orphans 2>/dev/null || true

    log_info "Step 4: Pulling fresh images..."
    if ! docker-compose -f docker/docker-compose.yml pull; then
        log_error "Failed to pull Docker images"
        exit 1
    fi
    log_success "Fresh images pulled"

    log_info "Step 5: Starting fresh containers..."
    if ! docker-compose -f docker/docker-compose.yml up -d; then
        log_error "Failed to start containers"
        exit 1
    fi
    log_success "Fresh containers started"

    log_info "Step 6: Waiting for database initialization..."
    # Wait for PostgreSQL to be ready
    RETRY_COUNT=0
    MAX_RETRIES=30

    while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
        if docker exec polaris-db pg_isready -U polaris -d polaris >/dev/null 2>&1; then
            log_success "Database is ready!"
            break
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))
        log_info "Waiting for database... ($RETRY_COUNT/$MAX_RETRIES)"
        sleep 2
    done

    if [[ $RETRY_COUNT -eq $MAX_RETRIES ]]; then
        log_error "Database failed to start within expected time"
        log_info "Check logs with: docker logs polaris-db"
        exit 1
    fi

    log_info "Step 7: Verifying database extensions..."
    if docker exec polaris-db psql -U polaris -d polaris -c "SELECT version();" >/dev/null 2>&1; then
        log_success "Database connection verified"
    else
        log_error "Database connection failed"
        exit 1
    fi

    # Check for PostGIS if it should be available
    if docker exec polaris-db psql -U polaris -d polaris -c "SELECT postgis_version();" >/dev/null 2>&1; then
        log_success "PostGIS extension verified"
    else
        log_warning "PostGIS extension not available (this might be expected)"
    fi

    log_info "Step 8: Database reset complete!"
    echo ""
    log_success "✅ Fresh PostgreSQL Polaris environment ready!"
    echo ""
    log_info "Next steps:"
    log_info "  1. Load sample data: make load-data"
    log_info "  2. Run initialization: make run-init"
    log_info "  3. Start learning: make run-module MODULE=01_schema_design/civics.sql"
    log_info "  4. Access web UI: http://localhost:8080"
    echo ""
    log_info "Connection details:"
    log_info "  Host: localhost"
    log_info "  Port: 5432"
    log_info "  Database: polaris"
    log_info "  Username: polaris"
    log_info "  Password: polar_star_2024"
}

# Cleanup function for interrupted execution
cleanup() {
    log_warning "Reset interrupted by user"
    log_info "You may need to run 'make down && make up' to restore a working state"
    exit 1
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
