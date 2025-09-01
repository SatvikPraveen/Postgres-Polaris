#!/bin/bash
# Location: /scripts/run_sql.sh
# psql wrapper for executing SQL files from /sql paths

set -e

# Configuration
CONTAINER_NAME="polaris-db"
DB_USER="polaris"
DB_NAME="polaris"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
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

show_usage() {
    echo "Usage: $0 <sql-file-path>"
    echo ""
    echo "Examples:"
    echo "  $0 sql/01_schema_design/civics.sql"
    echo "  $0 tests/schema_validation.sql"
    echo "  $0 examples/quick_demo.sql"
    echo ""
    echo "Options:"
    echo "  -v, --verbose    Show detailed output"
    echo "  -t, --timing     Show execution timing"
    echo "  -s, --single     Use single transaction mode"
    echo "  -e, --echo       Echo all SQL commands"
    echo "  -h, --help       Show this help message"
}

# Parse arguments
VERBOSE=false
TIMING=false
SINGLE_TRANSACTION=false
ECHO_COMMANDS=false
SQL_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -t|--timing)
            TIMING=true
            shift
            ;;
        -s|--single)
            SINGLE_TRANSACTION=true
            shift
            ;;
        -e|--echo)
            ECHO_COMMANDS=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            log_error "Unknown option $1"
            show_usage
            exit 1
            ;;
        *)
            if [[ -z "$SQL_FILE" ]]; then
                SQL_FILE="$1"
            else
                log_error "Multiple SQL files specified. Use only one."
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate inputs
if [[ -z "$SQL_FILE" ]]; then
    log_error "No SQL file specified."
    show_usage
    exit 1
fi

# Check if file exists
if [[ ! -f "$SQL_FILE" ]]; then
    log_error "File not found: $SQL_FILE"
    exit 1
fi

# Check if Docker container is running
if ! docker ps | grep -q "$CONTAINER_NAME"; then
    log_error "Database container '$CONTAINER_NAME' is not running."
    log_info "Start with: make up"
    exit 1
fi

# Build psql command
PSQL_CMD="psql -U $DB_USER -d $DB_NAME"

if [[ "$VERBOSE" == "true" ]]; then
    PSQL_CMD="$PSQL_CMD -a"  # Echo all input from script
fi

if [[ "$TIMING" == "true" ]]; then
    PSQL_CMD="$PSQL_CMD -c '\timing on'"
fi

if [[ "$SINGLE_TRANSACTION" == "true" ]]; then
    PSQL_CMD="$PSQL_CMD --single-transaction"
fi

if [[ "$ECHO_COMMANDS" == "true" ]]; then
    PSQL_CMD="$PSQL_CMD --echo-all"
fi

# Get container path for SQL file
CONTAINER_SQL_PATH="/$SQL_FILE"

log_info "Executing SQL file: $SQL_FILE"
log_info "Container: $CONTAINER_NAME"
log_info "Database: $DB_NAME"
log_info "User: $DB_USER"

if [[ "$VERBOSE" == "true" ]]; then
    log_info "Command: docker exec -i $CONTAINER_NAME $PSQL_CMD -f $CONTAINER_SQL_PATH"
fi

# Execute SQL file
START_TIME=$(date +%s.%N)

if docker exec -i "$CONTAINER_NAME" $PSQL_CMD -f "$CONTAINER_SQL_PATH"; then
    END_TIME=$(date +%s.%N)
    DURATION=$(echo "$END_TIME - $START_TIME" | bc -l)
    log_success "SQL file executed successfully"

    if [[ "$TIMING" == "true" ]]; then
        log_info "Execution time: ${DURATION}s"
    fi
else
    EXIT_CODE=$?
    log_error "SQL file execution failed with exit code $EXIT_CODE"

    # Show recent logs for debugging
    if [[ "$VERBOSE" == "true" ]]; then
        log_warning "Recent database logs:"
        docker logs "$CONTAINER_NAME" --tail=20
    fi

    exit $EXIT_CODE
fi

# Optional: Show summary information
if [[ "$VERBOSE" == "true" ]]; then
    log_info "Getting connection info..."
    docker exec -i "$CONTAINER_NAME" $PSQL_CMD -c "
        SELECT
            current_database() as database,
            current_user as user,
            version() as postgres_version;
    "
fi
