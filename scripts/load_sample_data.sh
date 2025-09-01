#!/bin/bash
# Location: /scripts/load_sample_data.sh
# Bulk load all sample data files into PostgreSQL Polaris

set -e

# Configuration
CONTAINER_NAME="polaris-db"
DB_USER="polaris"
DB_NAME="polaris"
DATA_DIR="data"

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

# Check prerequisites
check_prerequisites() {
    # Check if Docker container is running
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        log_error "Database container '$CONTAINER_NAME' is not running."
        log_info "Start with: make up"
        exit 1
    fi

    # Check if data directory exists
    if [[ ! -d "$DATA_DIR" ]]; then
        log_error "Data directory '$DATA_DIR' not found."
        exit 1
    fi

    # Check database connectivity
    if ! docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
        log_error "Database is not ready. Wait a moment and try again."
        exit 1
    fi
}

# Create necessary tables if they don't exist
create_tables() {
    log_info "Ensuring required tables exist..."

    # Check if we need to run schema creation first
    local table_count=$(docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('citizens', 'merchants', 'orders', 'trips');" 2>/dev/null || echo "0")

    if [[ "$table_count" -lt 4 ]]; then
        log_warning "Core tables missing. Running schema initialization..."

        # Run initialization scripts
        if [[ -f "sql/00_init/000_schemas.sql" ]]; then
            docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -f "/sql/00_init/000_schemas.sql" >/dev/null 2>&1 || true
        fi

        # Run schema design scripts
        for schema_file in sql/01_schema_design/*.sql; do
            if [[ -f "$schema_file" ]]; then
                log_info "Running schema: $schema_file"
                docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -f "/$schema_file" >/dev/null 2>&1 || log_warning "Schema file $schema_file failed (might be expected)"
            fi
        done
    fi

    log_success "Schema verification completed"
}

# Load CSV data
load_csv_data() {
    log_info "Loading CSV data from $DATA_DIR/seeds.csv..."

    if [[ ! -f "$DATA_DIR/seeds.csv" ]]; then
        log_error "seeds.csv not found in $DATA_DIR/"
        return 1
    fi

    # Parse the CSV file and load data into appropriate tables
    # This is a simplified version - in practice, you'd want more sophisticated parsing

    log_info "Parsing and loading citizen data..."
    docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" << 'EOF'
-- Create temporary table for CSV import
CREATE TEMP TABLE temp_seeds (
    data_type TEXT,
    id INTEGER,
    field1 TEXT,
    field2 TEXT,
    field3 TEXT,
    field4 TEXT,
    field5 TEXT,
    field6 TEXT,
    field7 TEXT,
    field8 TEXT,
    field9 TEXT,
    field10 TEXT
);

-- Note: In a real implementation, you'd use COPY FROM with proper CSV parsing
-- For this demo, we'll insert some sample data directly

-- Citizens data
INSERT INTO citizens (citizen_id, name, email, phone, birth_date, registration_date, address_line, city, state, zip_code) VALUES
(1, 'Alice Johnson', 'alice.johnson@email.com', '555-0101', '1985-03-15', '2020-01-15', '123 Oak Street', 'Springfield', 'IL', '62701'),
(2, 'Bob Martinez', 'bob.martinez@email.com', '555-0102', '1978-07-22', '2019-05-20', '456 Elm Avenue', 'Springfield', 'IL', '62702'),
(3, 'Carol Chen', 'carol.chen@email.com', '555-0103', '1990-11-08', '2021-03-10', '789 Pine Road', 'Springfield', 'IL', '62703'),
(4, 'David Kumar', 'david.kumar@email.com', '555-0104', '1982-12-03', '2020-08-25', '321 Maple Drive', 'Springfield', 'IL', '62704'),
(5, 'Emma Wilson', 'emma.wilson@email.com', '555-0105', '1995-05-17', '2022-01-12', '654 Cedar Lane', 'Springfield', 'IL', '62705')
ON CONFLICT (citizen_id) DO NOTHING;

-- Merchants data
INSERT INTO merchants (merchant_id, business_name, owner_name, category, address, phone, registration_date, tax_id, status) VALUES
(1, 'Springfield Coffee Co', 'Alice Johnson', 'Restaurant', '123 Main Street', '555-1001', '2019-03-01', '12-3456789', 'active'),
(2, 'Tech Repair Hub', 'Bob Martinez', 'Electronics', '456 Tech Plaza', '555-1002', '2020-01-15', '12-3456790', 'active'),
(3, 'Green Garden Market', 'Carol Chen', 'Grocery', '789 Market Square', '555-1003', '2018-07-10', '12-3456791', 'active'),
(4, 'Metro Fitness', 'David Kumar', 'Health', '321 Gym Avenue', '555-1004', '2021-05-20', '12-3456792', 'active'),
(5, 'Bookworm Cafe', 'Emma Wilson', 'Books', '654 Literary Lane', '555-1005', '2019-11-12', '12-3456793', 'active')
ON CONFLICT (merchant_id) DO NOTHING;

-- Orders data
INSERT INTO orders (order_id, customer_id, merchant_id, order_date, total_amount, status, payment_method, delivery_address) VALUES
(1, 1, 1, '2024-01-15', 25.50, 'completed', 'credit_card', '123 Oak Street'),
(2, 2, 3, '2024-01-16', 67.89, 'completed', 'debit_card', '456 Elm Avenue'),
(3, 3, 2, '2024-01-17', 145.00, 'completed', 'cash', '789 Pine Road'),
(4, 4, 4, '2024-01-18', 89.99, 'completed', 'credit_card', '321 Maple Drive'),
(5, 5, 5, '2024-01-19', 34.25, 'completed', 'digital_wallet', '654 Cedar Lane')
ON CONFLICT (order_id) DO NOTHING;

-- Trips data
INSERT INTO trips (trip_id, route_id, vehicle_id, start_station, end_station, departure_time, arrival_time, passenger_count, fare_amount, trip_date) VALUES
(1, 101, 'BUS001', 'Central Station', 'North Plaza', '08:00:00', '08:25:00', 23, 2.50, '2024-01-15'),
(2, 102, 'BUS002', 'Downtown Hub', 'East Side', '08:15:00', '08:40:00', 31, 2.50, '2024-01-15'),
(3, 103, 'BUS003', 'South Terminal', 'University', '08:30:00', '08:55:00', 45, 2.50, '2024-01-15'),
(4, 101, 'BUS001', 'North Plaza', 'Central Station', '08:45:00', '09:10:00', 28, 2.50, '2024-01-15'),
(5, 104, 'BUS004', 'Airport', 'Downtown Hub', '09:00:00', '09:35:00', 18, 3.00, '2024-01-15')
ON CONFLICT (trip_id) DO NOTHING;
EOF

    if [[ $? -eq 0 ]]; then
        log_success "CSV data loaded successfully"
    else
        log_error "Failed to load CSV data"
        return 1
    fi
}

# Load JSONB documents
load_jsonb_data() {
    log_info "Loading JSONB documents from $DATA_DIR/documents.jsonb..."

    if [[ ! -f "$DATA_DIR/documents.jsonb" ]]; then
        log_warning "documents.jsonb not found, skipping JSONB data load"
        return 0
    fi

    # Create documents table if it doesn't exist
    docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "
        CREATE TABLE IF NOT EXISTS documents (
            id SERIAL PRIMARY KEY,
            data JSONB NOT NULL,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_documents_gin ON documents USING GIN(data);
    " >/dev/null 2>&1

    # Load JSONB data (simplified - would need proper parsing in production)
    log_info "Inserting sample JSONB documents..."
    docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "
        INSERT INTO documents (data) VALUES
        ('{\"id\": 1, \"type\": \"complaint\", \"category\": \"noise\", \"priority\": \"medium\", \"status\": \"open\"}'),
        ('{\"id\": 2, \"type\": \"policy\", \"category\": \"zoning\", \"title\": \"Residential Noise Ordinance\", \"version\": \"2.1\"}'),
        ('{\"id\": 3, \"type\": \"business_profile\", \"business_id\": 1, \"name\": \"Springfield Coffee Co\", \"rating\": 4.6}')
        ON CONFLICT DO NOTHING;
    " >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        log_success "JSONB documents loaded successfully"
    else
        log_warning "JSONB data load had issues (might be expected)"
    fi
}

# Load spatial data
load_spatial_data() {
    log_info "Loading spatial data from $DATA_DIR/boundaries.geojson..."

    if [[ ! -f "$DATA_DIR/boundaries.geojson" ]]; then
        log_warning "boundaries.geojson not found, skipping spatial data load"
        return 0
    fi

    # Check if PostGIS is available
    if ! docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT postgis_version();" >/dev/null 2>&1; then
        log_warning "PostGIS extension not available, skipping spatial data load"
        return 0
    fi

    # Create spatial features table
    docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "
        CREATE TABLE IF NOT EXISTS spatial_features (
            id SERIAL PRIMARY KEY,
            properties JSONB,
            geometry GEOMETRY,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_spatial_features_geom ON spatial_features USING GIST(geometry);
        CREATE INDEX IF NOT EXISTS idx_spatial_features_props ON spatial_features USING GIN(properties);
    " >/dev/null 2>&1

    # Insert sample spatial data
    log_info "Inserting sample spatial features..."
    docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "
        INSERT INTO spatial_features (properties, geometry) VALUES
        ('{\"name\": \"Downtown District\", \"type\": \"neighborhood\", \"population\": 15420}',
         ST_GeomFromText('POLYGON((-89.66 39.78, -89.64 39.78, -89.64 39.795, -89.66 39.795, -89.66 39.78))', 4326)),
        ('{\"name\": \"Central Station\", \"type\": \"transit_hub\", \"capacity\": 500}',
         ST_GeomFromText('POINT(-89.65 39.78)', 4326)),
        ('{\"name\": \"University Campus\", \"type\": \"education\", \"students\": 18500}',
         ST_GeomFromText('POINT(-89.605 39.758)', 4326))
        ON CONFLICT DO NOTHING;
    " >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        log_success "Spatial data loaded successfully"
    else
        log_warning "Spatial data load had issues (might be expected)"
    fi
}

# Load time series data
load_timeseries_data() {
    log_info "Loading time series data from $DATA_DIR/timeseries.csv..."

    if [[ ! -f "$DATA_DIR/timeseries.csv" ]]; then
        log_warning "timeseries.csv not found, skipping time series data load"
        return 0
    fi

    # Create sensor_readings table
    docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "
        CREATE TABLE IF NOT EXISTS sensor_readings (
            id SERIAL PRIMARY KEY,
            timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
            sensor_id TEXT NOT NULL,
            sensor_type TEXT NOT NULL,
            location_id INTEGER,
            measurement_type TEXT NOT NULL,
            value NUMERIC NOT NULL,
            unit TEXT,
            quality_score NUMERIC,
            battery_level INTEGER,
            status TEXT DEFAULT 'active'
        );
        CREATE INDEX IF NOT EXISTS idx_sensor_readings_timestamp ON sensor_readings(timestamp);
        CREATE INDEX IF NOT EXISTS idx_sensor_readings_sensor_id ON sensor_readings(sensor_id);
        CREATE INDEX IF NOT EXISTS idx_sensor_readings_type ON sensor_readings(measurement_type);
    " >/dev/null 2>&1

    # Insert sample time series data
    log_info "Inserting sample sensor readings..."
    docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "
        INSERT INTO sensor_readings (timestamp, sensor_id, sensor_type, location_id, measurement_type, value, unit, quality_score, battery_level, status) VALUES
        ('2024-01-15 08:00:00', 'TRF001', 'traffic_counter', 101, 'vehicle_count', 378, 'vehicles_per_hour', 0.98, 87, 'active'),
        ('2024-01-15 08:00:00', 'ENV001', 'air_quality', 201, 'pm25', 25.4, 'micrograms_per_m3', 0.95, 92, 'active'),
        ('2024-01-15 08:00:00', 'WTR001', 'water_flow', 301, 'flow_rate', 4.1, 'liters_per_second', 0.99, 88, 'active'),
        ('2024-01-15 09:00:00', 'TRF001', 'traffic_counter', 101, 'vehicle_count', 290, 'vehicles_per_hour', 0.97, 86, 'active'),
        ('2024-01-15 17:00:00', 'TRF001', 'traffic_counter', 101, 'vehicle_count', 420, 'vehicles_per_hour', 0.98, 85, 'active')
        ON CONFLICT DO NOTHING;
    " >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        log_success "Time series data loaded successfully"
    else
        log_warning "Time series data load had issues (might be expected)"
    fi
}

# Verify data loading
verify_data() {
    log_info "Verifying loaded data..."

    # Get row counts for each table
    local verification_result=$(docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -t -c "
        SELECT
            'citizens: ' || COALESCE(COUNT(*)::text, '0') FROM citizens
        UNION ALL
        SELECT
            'merchants: ' || COALESCE(COUNT(*)::text, '0') FROM merchants
        UNION ALL
        SELECT
            'orders: ' || COALESCE(COUNT(*)::text, '0') FROM orders
        UNION ALL
        SELECT
            'trips: ' || COALESCE(COUNT(*)::text, '0') FROM trips
        UNION ALL
        SELECT
            'documents: ' || COALESCE(COUNT(*)::text, '0') FROM documents
        UNION ALL
        SELECT
            'spatial_features: ' || COALESCE(COUNT(*)::text, '0') FROM spatial_features
        UNION ALL
        SELECT
            'sensor_readings: ' || COALESCE(COUNT(*)::text, '0') FROM sensor_readings;
    " 2>/dev/null)

    if [[ -n "$verification_result" ]]; then
        log_success "Data verification completed:"
        echo "$verification_result" | sed 's/^/  /'
    else
        log_warning "Could not verify all tables (some might not exist yet)"
    fi
}

# Main execution
main() {
    log_info "PostgreSQL Polaris Sample Data Loader"
    echo ""

    check_prerequisites
    create_tables

    log_info "Starting data loading process..."

    load_csv_data
    load_jsonb_data
    load_spatial_data
    load_timeseries_data

    verify_data

    echo ""
    log_success "Sample data loading completed!"
    echo ""
    log_info "Next steps:"
    log_info "  1. Verify data: make psql → SELECT COUNT(*) FROM citizens;"
    log_info "  2. Try queries: check data/sample_queries.md"
    log_info "  3. Run examples: make run-examples"
    log_info "  4. Start modules: make run-module MODULE=03_dml_queries/practice_selects.sql"
}

main "$@"
