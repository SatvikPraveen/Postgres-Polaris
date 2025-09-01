#!/bin/bash
# Location: /scripts/backup_demo.sh
# pg_dump examples with different backup strategies and options

set -e

# Configuration
CONTAINER_NAME="polaris-db"
DB_USER="polaris"
DB_NAME="polaris"
BACKUP_DIR="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Create backup directory
create_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log_info "Created backup directory: $BACKUP_DIR"
    fi
}

# Check if container is running
check_container() {
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        log_error "Database container '$CONTAINER_NAME' is not running."
        log_info "Start with: make up"
        exit 1
    fi
}

# Full database backup (custom format)
backup_full_custom() {
    local backup_file="$BACKUP_DIR/polaris_full_${TIMESTAMP}.backup"

    log_info "Creating full database backup (custom format)..."
    log_info "Output file: $backup_file"

    if docker exec "$CONTAINER_NAME" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=custom \
        --compress=9 \
        --verbose \
        --file="/tmp/backup.tmp"; then

        # Copy from container to host
        docker cp "$CONTAINER_NAME:/tmp/backup.tmp" "$backup_file"
        docker exec "$CONTAINER_NAME" rm "/tmp/backup.tmp"

        local size=$(du -h "$backup_file" | cut -f1)
        log_success "Full backup completed: $backup_file ($size)"

        # Show restore command
        log_info "Restore command:"
        echo "  docker exec -i $CONTAINER_NAME pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists < $backup_file"
    else
        log_error "Full backup failed"
        return 1
    fi
}

# Full database backup (SQL format)
backup_full_sql() {
    local backup_file="$BACKUP_DIR/polaris_full_${TIMESTAMP}.sql"

    log_info "Creating full database backup (SQL format)..."
    log_info "Output file: $backup_file"

    if docker exec "$CONTAINER_NAME" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=plain \
        --clean \
        --if-exists \
        --create \
        --verbose > "$backup_file"; then

        local size=$(du -h "$backup_file" | cut -f1)
        log_success "SQL backup completed: $backup_file ($size)"

        # Show restore command
        log_info "Restore command:"
        echo "  docker exec -i $CONTAINER_NAME psql -U $DB_USER < $backup_file"
    else
        log_error "SQL backup failed"
        return 1
    fi
}

# Schema-only backup
backup_schema_only() {
    local backup_file="$BACKUP_DIR/polaris_schema_${TIMESTAMP}.sql"

    log_info "Creating schema-only backup..."
    log_info "Output file: $backup_file"

    if docker exec "$CONTAINER_NAME" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --schema-only \
        --format=plain \
        --clean \
        --if-exists \
        --verbose > "$backup_file"; then

        local size=$(du -h "$backup_file" | cut -f1)
        log_success "Schema backup completed: $backup_file ($size)"
    else
        log_error "Schema backup failed"
        return 1
    fi
}

# Data-only backup
backup_data_only() {
    local backup_file="$BACKUP_DIR/polaris_data_${TIMESTAMP}.sql"

    log_info "Creating data-only backup..."
    log_info "Output file: $backup_file"

    if docker exec "$CONTAINER_NAME" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --data-only \
        --format=plain \
        --inserts \
        --verbose > "$backup_file"; then

        local size=$(du -h "$backup_file" | cut -f1)
        log_success "Data backup completed: $backup_file ($size)"
    else
        log_error "Data backup failed"
        return 1
    fi
}

# Table-specific backup
backup_specific_tables() {
    local backup_file="$BACKUP_DIR/polaris_tables_${TIMESTAMP}.sql"
    local tables=("citizens" "merchants" "orders" "trips")

    log_info "Creating backup of specific tables: ${tables[*]}"
    log_info "Output file: $backup_file"

    local table_args=""
    for table in "${tables[@]}"; do
        table_args="$table_args --table=$table"
    done

    if docker exec "$CONTAINER_NAME" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=plain \
        --data-only \
        --inserts \
        $table_args \
        --verbose > "$backup_file"; then

        local size=$(du -h "$backup_file" | cut -f1)
        log_success "Table backup completed: $backup_file ($size)"
    else
        log_error "Table backup failed"
        return 1
    fi
}

# Compressed backup with parallel processing
backup_parallel_compressed() {
    local backup_dir="$BACKUP_DIR/polaris_parallel_${TIMESTAMP}"

    log_info "Creating parallel compressed backup..."
    log_info "Output directory: $backup_dir"

    # Create directory format backup inside container
    if docker exec "$CONTAINER_NAME" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=directory \
        --compress=9 \
        --jobs=4 \
        --verbose \
        --file="/tmp/parallel_backup"; then

        # Copy directory from container to host
        docker cp "$CONTAINER_NAME:/tmp/parallel_backup" "$backup_dir"
        docker exec "$CONTAINER_NAME" rm -rf "/tmp/parallel_backup"

        local size=$(du -sh "$backup_dir" | cut -f1)
        log_success "Parallel backup completed: $backup_dir ($size)"

        # Show restore command
        log_info "Restore command:"
        echo "  docker cp $backup_dir $CONTAINER_NAME:/tmp/restore_backup"
        echo "  docker exec $CONTAINER_NAME pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists --jobs=4 /tmp/restore_backup"
    else
        log_error "Parallel backup failed"
        return 1
    fi
}

# Exclude large tables backup
backup_exclude_tables() {
    local backup_file="$BACKUP_DIR/polaris_exclude_${TIMESTAMP}.sql"
    local exclude_tables=("sensor_readings" "audit_log" "temp_data")

    log_info "Creating backup excluding large tables: ${exclude_tables[*]}"
    log_info "Output file: $backup_file"

    local exclude_args=""
    for table in "${exclude_tables[@]}"; do
        exclude_args="$exclude_args --exclude-table=$table"
    done

    if docker exec "$CONTAINER_NAME" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=plain \
        --clean \
        --if-exists \
        $exclude_args \
        --verbose > "$backup_file"; then

        local size=$(du -h "$backup_file" | cut -f1)
        log_success "Selective backup completed: $backup_file ($size)"
    else
        log_error "Selective backup failed"
        return 1
    fi
}

# Demonstrate restore process
demo_restore() {
    local latest_backup=$(ls -t "$BACKUP_DIR"/*.backup 2>/dev/null | head -n1)

    if [[ -z "$latest_backup" ]]; then
        log_warning "No custom format backup found for restore demo"
        return 0
    fi

    log_info "Demonstrating restore process with: $latest_backup"

    # Create a test database for restore demo
    log_info "Creating test database for restore..."
    if docker exec "$CONTAINER_NAME" createdb -U "$DB_USER" polaris_restore_test 2>/dev/null; then
        log_success "Test database created"
    else
        log_warning "Test database might already exist"
    fi

    # Copy backup file to container
    docker cp "$latest_backup" "$CONTAINER_NAME:/tmp/restore_demo.backup"

    # Perform restore
    log_info "Restoring backup to test database..."
    if docker exec "$CONTAINER_NAME" pg_restore \
        -U "$DB_USER" \
        -d polaris_restore_test \
        --clean \
        --if-exists \
        --verbose \
        /tmp/restore_demo.backup; then

        log_success "Restore completed successfully"

        # Verify restore
        local table_count=$(docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d polaris_restore_test -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")
        log_info "Restored database contains $table_count tables"

        # Cleanup
        log_info "Cleaning up test database..."
        docker exec "$CONTAINER_NAME" dropdb -U "$DB_USER" polaris_restore_test
        docker exec "$CONTAINER_NAME" rm /tmp/restore_demo.backup
        log_success "Cleanup completed"
    else
        log_error "Restore failed"
        # Cleanup on failure
        docker exec "$CONTAINER_NAME" dropdb -U "$DB_USER" polaris_restore_test 2>/dev/null || true
        docker exec "$CONTAINER_NAME" rm /tmp/restore_demo.backup 2>/dev/null || true
        return 1
    fi
}

# Show backup information
show_backup_info() {
    log_info "Backup directory contents:"
    if [[ -d "$BACKUP_DIR" ]]; then
        ls -lh "$BACKUP_DIR" | grep -v "^total" || log_warning "No backup files found"
    else
        log_warning "Backup directory does not exist"
    fi
}

# Main function with menu
main() {
    log_info "PostgreSQL Polaris Backup Demo"
    echo ""

    check_container
    create_backup_dir

    if [[ $# -eq 0 ]]; then
        echo "Available backup types:"
        echo "  1. full-custom     - Full backup in custom format (recommended)"
        echo "  2. full-sql        - Full backup in SQL format"
        echo "  3. schema-only     - Schema without data"
        echo "  4. data-only       - Data without schema"
        echo "  5. tables          - Specific tables only"
        echo "  6. parallel        - Parallel compressed backup"
        echo "  7. exclude         - Exclude large tables"
        echo "  8. restore-demo    - Demonstrate restore process"
        echo "  9. all             - Run all backup types"
        echo "  info              - Show existing backups"
        echo ""
        read -p "Select backup type (1-9, info, or 'all'): " choice
    else
        choice="$1"
    fi

    case "$choice" in
        1|full-custom)
            backup_full_custom
            ;;
        2|full-sql)
            backup_full_sql
            ;;
        3|schema-only)
            backup_schema_only
            ;;
        4|data-only)
            backup_data_only
            ;;
        5|tables)
            backup_specific_tables
            ;;
        6|parallel)
            backup_parallel_compressed
            ;;
        7|exclude)
            backup_exclude_tables
            ;;
        8|restore-demo)
            demo_restore
            ;;
        9|all)
            log_info "Running all backup types..."
            backup_full_custom
            backup_full_sql
            backup_schema_only
            backup_data_only
            backup_specific_tables
            backup_parallel_compressed
            backup_exclude_tables
            demo_restore
            ;;
        info)
            show_backup_info
            ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac

    echo ""
    show_backup_info

    log_success "Backup demo completed!"
    log_info "Learn more about PostgreSQL backup strategies in Module 13"
}

main "$@"
