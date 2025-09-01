-- File: sql/08_partitioning_timeseries/declarative_partitioning.sql
-- Purpose: Range/list partitioning on time/tenant for large tables

-- =============================================================================
-- TIME-BASED RANGE PARTITIONING
-- =============================================================================

-- Create partitioned table for sensor readings
CREATE TABLE mobility.sensor_readings_partitioned (
    reading_id BIGSERIAL,
    sensor_code VARCHAR(50) NOT NULL,
    sensor_type mobility.sensor_type NOT NULL,
    latitude DECIMAL(10,8) NOT NULL,
    longitude DECIMAL(11,8) NOT NULL,
    location_description VARCHAR(200),
    reading_value NUMERIC(12,4) NOT NULL,
    unit_of_measure VARCHAR(20) NOT NULL,
    reading_time TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    data_quality_score DECIMAL(3,2),
    calibration_date DATE,
    weather_conditions VARCHAR(100),
    special_events VARCHAR(200),
    raw_data JSONB,
    -- Partition key must be included in primary key
    PRIMARY KEY (reading_id, reading_time)
) PARTITION BY RANGE (reading_time);

-- Create monthly partitions for sensor readings
CREATE TABLE mobility.sensor_readings_2024_01 PARTITION OF mobility.sensor_readings_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE mobility.sensor_readings_2024_02 PARTITION OF mobility.sensor_readings_partitioned
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE TABLE mobility.sensor_readings_2024_03 PARTITION OF mobility.sensor_readings_partitioned
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

CREATE TABLE mobility.sensor_readings_2024_12 PARTITION OF mobility.sensor_readings_partitioned
    FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

CREATE TABLE mobility.sensor_readings_2025_01 PARTITION OF mobility.sensor_readings_partitioned
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

-- Create default partition for future data
CREATE TABLE mobility.sensor_readings_default PARTITION OF mobility.sensor_readings_partitioned
    DEFAULT;

-- =============================================================================
-- MULTI-LEVEL PARTITIONING (RANGE + LIST)
-- =============================================================================

-- Create partitioned audit table by time and operation type
CREATE TABLE audit.table_changes_partitioned (
    audit_id BIGSERIAL,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    operation_type TEXT NOT NULL,
    row_data JSONB,
    changed_fields JSONB,
    old_values JSONB,
    new_values JSONB,
    changed_by TEXT,
    changed_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    session_user_name TEXT DEFAULT SESSION_USER,
    client_addr INET DEFAULT INET_CLIENT_ADDR(),
    application_name TEXT DEFAULT current_setting('application_name', true),
    PRIMARY KEY (audit_id, changed_at, operation_type)
) PARTITION BY RANGE (changed_at);

-- Create monthly partitions, then subpartition by operation type
CREATE TABLE audit.table_changes_2024_12 PARTITION OF audit.table_changes_partitioned
    FOR VALUES FROM ('2024-12-01') TO ('2025-01-01')
    PARTITION BY LIST (operation_type);

-- Sub-partitions for December 2024
CREATE TABLE audit.table_changes_2024_12_insert PARTITION OF audit.table_changes_2024_12
    FOR VALUES IN ('INSERT');

CREATE TABLE audit.table_changes_2024_12_update PARTITION OF audit.table_changes_2024_12
    FOR VALUES IN ('UPDATE');

CREATE TABLE audit.table_changes_2024_12_delete PARTITION OF audit.table_changes_2024_12
    FOR VALUES IN ('DELETE');

CREATE TABLE audit.table_changes_2024_12_other PARTITION OF audit.table_changes_2024_12
    DEFAULT;

-- Create 2025 partitions
CREATE TABLE audit.table_changes_2025_01 PARTITION OF audit.table_changes_partitioned
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01')
    PARTITION BY LIST (operation_type);

CREATE TABLE audit.table_changes_2025_01_insert PARTITION OF audit.table_changes_2025_01
    FOR VALUES IN ('INSERT');

CREATE TABLE audit.table_changes_2025_01_update PARTITION OF audit.table_changes_2025_01
    FOR VALUES IN ('UPDATE');

CREATE TABLE audit.table_changes_2025_01_delete PARTITION OF audit.table_changes_2025_01
    FOR VALUES IN ('DELETE');

CREATE TABLE audit.table_changes_2025_01_other PARTITION OF audit.table_changes_2025_01
    DEFAULT;

-- =============================================================================
-- TENANT-BASED LIST PARTITIONING
-- =============================================================================

-- Create partitioned business data by business type
CREATE TABLE commerce.orders_partitioned (
    order_id BIGSERIAL,
    merchant_id BIGINT NOT NULL,
    customer_citizen_id BIGINT,
    business_type commerce.business_type NOT NULL,
    order_number VARCHAR(50) UNIQUE NOT NULL,
    order_date TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    status commerce.order_status DEFAULT 'pending' NOT NULL,
    subtotal NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    tax_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    tip_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    delivery_address VARCHAR(500),
    delivery_instructions TEXT,
    estimated_delivery TIMESTAMPTZ,
    actual_delivery TIMESTAMPTZ,
    order_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    PRIMARY KEY (order_id, business_type)
) PARTITION BY LIST (business_type);

-- Create partitions by business type
CREATE TABLE commerce.orders_restaurant PARTITION OF commerce.orders_partitioned
    FOR VALUES IN ('restaurant');

CREATE TABLE commerce.orders_retail PARTITION OF commerce.orders_partitioned
    FOR VALUES IN ('retail');

CREATE TABLE commerce.orders_service PARTITION OF commerce.orders_partitioned
    FOR VALUES IN ('service');

CREATE TABLE commerce.orders_technology PARTITION OF commerce.orders_partitioned
    FOR VALUES IN ('technology');

CREATE TABLE commerce.orders_other PARTITION OF commerce.orders_partitioned
    FOR VALUES IN ('manufacturing', 'healthcare', 'other');

-- =============================================================================
-- PARTITION MANAGEMENT FUNCTIONS
-- =============================================================================

-- Function to create monthly sensor reading partitions
CREATE OR REPLACE FUNCTION mobility.create_sensor_partition(
    partition_year INTEGER,
    partition_month INTEGER
)
RETURNS TEXT AS $$
DECLARE
    table_name TEXT;
    start_date DATE;
    end_date DATE;
    sql_command TEXT;
BEGIN
    -- Calculate partition bounds
    start_date := make_date(partition_year, partition_month, 1);
    end_date := start_date + INTERVAL '1 month';

    -- Generate partition table name
    table_name := 'sensor_readings_' || partition_year || '_' || LPAD(partition_month::TEXT, 2, '0');

    -- Check if partition already exists
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'mobility' AND table_name = table_name
    ) THEN
        RETURN 'Partition ' || table_name || ' already exists';
    END IF;

    -- Create partition
    sql_command := format(
        'CREATE TABLE mobility.%I PARTITION OF mobility.sensor_readings_partitioned FOR VALUES FROM (%L) TO (%L)',
        table_name, start_date, end_date
    );

    EXECUTE sql_command;

    -- Create indexes on new partition
    EXECUTE format('CREATE INDEX idx_%I_sensor_time ON mobility.%I (sensor_code, reading_time DESC)', table_name, table_name);
    EXECUTE format('CREATE INDEX idx_%I_location ON mobility.%I (latitude, longitude)', table_name, table_name);

    RETURN 'Created partition ' || table_name || ' for period ' || start_date || ' to ' || end_date;
END;
$$ LANGUAGE plpgsql;

-- Function to create audit table partitions with sub-partitions
CREATE OR REPLACE FUNCTION audit.create_audit_partition(
    partition_year INTEGER,
    partition_month INTEGER
)
RETURNS TEXT AS $$
DECLARE
    table_name TEXT;
    start_date DATE;
    end_date DATE;
    sql_command TEXT;
    result TEXT := '';
BEGIN
    -- Calculate partition bounds
    start_date := make_date(partition_year, partition_month, 1);
    end_date := start_date + INTERVAL '1 month';

    -- Generate partition table name
    table_name := 'table_changes_' || partition_year || '_' || LPAD(partition_month::TEXT, 2, '0');

    -- Create main partition
    sql_command := format(
        'CREATE TABLE audit.%I PARTITION OF audit.table_changes_partitioned FOR VALUES FROM (%L) TO (%L) PARTITION BY LIST (operation_type)',
        table_name, start_date, end_date
    );
    EXECUTE sql_command;
    result := result || 'Created main partition ' || table_name || E'\n';

    -- Create sub-partitions for each operation type
    EXECUTE format('CREATE TABLE audit.%I_insert PARTITION OF audit.%I FOR VALUES IN (''INSERT'')', table_name, table_name);
    EXECUTE format('CREATE TABLE audit.%I_update PARTITION OF audit.%I FOR VALUES IN (''UPDATE'')', table_name, table_name);
    EXECUTE format('CREATE TABLE audit.%I_delete PARTITION OF audit.%I FOR VALUES IN (''DELETE'')', table_name, table_name);
    EXECUTE format('CREATE TABLE audit.%I_other PARTITION OF audit.%I DEFAULT', table_name, table_name);

    result := result || 'Created sub-partitions for INSERT, UPDATE, DELETE, and other operations';

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PARTITION PRUNING DEMONSTRATIONS
-- =============================================================================

-- Function to demonstrate partition pruning
CREATE OR REPLACE FUNCTION analytics.demo_partition_pruning()
RETURNS TABLE(
    query_description TEXT,
    execution_plan TEXT,
    partitions_scanned TEXT
) AS $$
BEGIN
    -- Insert sample data to demonstrate pruning
    INSERT INTO mobility.sensor_readings_partitioned (
        sensor_code, sensor_type, latitude, longitude, reading_value,
        unit_of_measure, reading_time
    ) VALUES
        ('DEMO_001', 'temperature', 32.9850, -96.8040, 72.5, 'fahrenheit', '2024-12-15 10:00:00'),
        ('DEMO_001', 'temperature', 32.9850, -96.8040, 73.2, 'fahrenheit', '2025-01-10 10:00:00'),
        ('DEMO_002', 'air_quality', 32.9800, -96.7950, 45.0, 'aqi', '2024-12-20 14:00:00');

    -- Query 1: Single partition (should show pruning)
    RETURN QUERY
    SELECT
        'Single month query (December 2024)'::TEXT as query_description,
        'SELECT * FROM sensor_readings_partitioned WHERE reading_time >= ''2024-12-01'' AND reading_time < ''2025-01-01'''::TEXT as execution_plan,
        'Only sensor_readings_2024_12 partition scanned'::TEXT as partitions_scanned;

    -- Query 2: Cross-partition query
    RETURN QUERY
    SELECT
        'Cross-partition query (Dec 2024 - Jan 2025)'::TEXT as query_description,
        'SELECT * FROM sensor_readings_partitioned WHERE reading_time >= ''2024-12-15'' AND reading_time < ''2025-01-15'''::TEXT as execution_plan,
        'Both sensor_readings_2024_12 and sensor_readings_2025_01 partitions scanned'::TEXT as partitions_scanned;

    -- Query 3: Full table scan
    RETURN QUERY
    SELECT
        'Full table scan (no time filter)'::TEXT as query_description,
        'SELECT COUNT(*) FROM sensor_readings_partitioned'::TEXT as execution_plan,
        'All partitions scanned'::TEXT as partitions_scanned;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PARTITION STATISTICS AND MONITORING
-- =============================================================================

-- Function to get partition information
CREATE OR REPLACE FUNCTION analytics.partition_info()
RETURNS TABLE(
    schema_name TEXT,
    parent_table TEXT,
    partition_name TEXT,
    partition_type TEXT,
    partition_key TEXT,
    partition_bounds TEXT,
    row_count BIGINT,
    size_pretty TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        pt.schemaname::TEXT as schema_name,
        pt.tablename::TEXT as parent_table,
        c.relname::TEXT as partition_name,
        CASE
            WHEN pt.partitionstrategy = 'r' THEN 'RANGE'
            WHEN pt.partitionstrategy = 'l' THEN 'LIST'
            WHEN pt.partitionstrategy = 'h' THEN 'HASH'
        END::TEXT as partition_type,
        pg_get_partkeydef(pt.oid)::TEXT as partition_key,
        pg_get_expr(c.relpartbound, c.oid, true)::TEXT as partition_bounds,
        COALESCE(pg_stat_get_tuples_inserted(c.oid) + pg_stat_get_tuples_updated(c.oid), 0) as row_count,
        pg_size_pretty(pg_total_relation_size(c.oid))::TEXT as size_pretty
    FROM pg_partitioned_tables pt
    JOIN pg_inherits i ON pt.oid = i.inhparent
    JOIN pg_class c ON i.inhrelid = c.oid
    WHERE pt.schemaname IN ('mobility', 'audit', 'commerce')
    ORDER BY pt.schemaname, pt.tablename, c.relname;
END;
$$ LANGUAGE plpgsql;

-- Function to analyze partition performance
CREATE OR REPLACE FUNCTION analytics.analyze_partition_performance()
RETURNS TABLE(
    table_name TEXT,
    total_partitions INTEGER,
    total_size TEXT,
    avg_partition_size TEXT,
    largest_partition TEXT,
    smallest_partition TEXT,
    pruning_effectiveness NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH partition_stats AS (
        SELECT
            pt.schemaname || '.' || pt.tablename as full_table_name,
            COUNT(c.relname) as partition_count,
            SUM(pg_total_relation_size(c.oid)) as total_bytes,
            AVG(pg_total_relation_size(c.oid)) as avg_bytes,
            MAX(pg_total_relation_size(c.oid)) as max_bytes,
            MIN(pg_total_relation_size(c.oid)) as min_bytes,
            -- Simple pruning effectiveness estimate
            CASE WHEN COUNT(c.relname) > 1 THEN 90.0 ELSE 0.0 END as pruning_score
        FROM pg_partitioned_tables pt
        JOIN pg_inherits i ON pt.oid = i.inhparent
        JOIN pg_class c ON i.inhrelid = c.oid
        WHERE pt.schemaname IN ('mobility', 'audit', 'commerce')
        GROUP BY pt.schemaname, pt.tablename
    )
    SELECT
        ps.full_table_name,
        ps.partition_count,
        pg_size_pretty(ps.total_bytes),
        pg_size_pretty(ps.avg_bytes::BIGINT),
        pg_size_pretty(ps.max_bytes),
        pg_size_pretty(ps.min_bytes),
        ps.pruning_score
    FROM partition_stats ps
    ORDER BY ps.total_bytes DESC;
END;
$ LANGUAGE plpgsql;
