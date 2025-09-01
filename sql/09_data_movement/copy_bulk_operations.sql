-- File: sql/09_data_movement/copy_bulk_operations.sql
-- Purpose: COPY tricks, CSV/HEADER imports, and file_fdw for bulk data operations

-- =============================================================================
-- BASIC COPY OPERATIONS
-- =============================================================================

-- Export citizens data to CSV with headers
COPY (
    SELECT
        citizen_id, first_name, last_name, email, phone,
        street_address, city, state, zip_code,
        DATE(date_of_birth) as birth_date,
        status, DATE(registered_date) as registration_date
    FROM civics.citizens
    WHERE status = 'active'
    ORDER BY citizen_id
) TO '/tmp/active_citizens.csv' WITH (FORMAT CSV, HEADER true, DELIMITER ',');

-- Import citizens from CSV with error handling
CREATE TEMP TABLE citizens_import_staging (
    citizen_id BIGINT,
    first_name TEXT,
    last_name TEXT,
    email TEXT,
    phone TEXT,
    street_address TEXT,
    city TEXT,
    state TEXT,
    zip_code TEXT,
    birth_date DATE,
    status TEXT,
    registration_date DATE,
    import_timestamp TIMESTAMPTZ DEFAULT NOW()
);

-- COPY with error tolerance (PostgreSQL 14+)
-- COPY citizens_import_staging FROM '/path/to/citizens.csv' WITH (FORMAT CSV, HEADER true, ON_ERROR ignore);

-- =============================================================================
-- ADVANCED COPY OPTIONS
-- =============================================================================

-- Function to perform bulk import with validation
CREATE OR REPLACE FUNCTION analytics.bulk_import_citizens(
    file_path TEXT,
    validate_only BOOLEAN DEFAULT false
)
RETURNS TABLE(
    import_status TEXT,
    total_rows BIGINT,
    successful_imports BIGINT,
    validation_errors BIGINT,
    error_details TEXT[]
) AS $$
DECLARE
    staging_count BIGINT;
    valid_count BIGINT;
    error_list TEXT[] := '{}';
    sql_command TEXT;
BEGIN
    -- Create temporary staging table
    DROP TABLE IF EXISTS temp_citizen_import;
    CREATE TEMP TABLE temp_citizen_import (
        first_name TEXT,
        last_name TEXT,
        email TEXT,
        phone TEXT,
        street_address TEXT,
        zip_code TEXT,
        birth_date DATE,
        error_notes TEXT
    );

    -- Import data (would use dynamic SQL in production)
    -- COPY temp_citizen_import FROM file_path WITH (FORMAT CSV, HEADER true);

    -- For demo, insert sample data
    INSERT INTO temp_citizen_import VALUES
        ('John', 'Doe', 'john.doe@example.com', '214-555-0001', '123 Test St', '75001', '1985-01-01', NULL),
        ('Jane', 'Smith', '', '214-555-0002', '456 Demo Ave', '75002', '1990-02-02', 'Missing email'),  -- Invalid
        ('Bob', 'Jones', 'bob@test.com', '214-555-0003', '789 Sample Rd', 'INVALID', '2050-01-01', 'Invalid zip and future birth date'); -- Invalid

    GET DIAGNOSTICS staging_count = ROW_COUNT;

    -- Validation pass
    UPDATE temp_citizen_import SET error_notes =
        CASE
            WHEN email IS NULL OR email = '' THEN 'Missing email address'
            WHEN email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN 'Invalid email format'
            WHEN zip_code !~ '^\d{5}(-\d{4})?$' THEN 'Invalid ZIP code format'
            WHEN birth_date > CURRENT_DATE THEN 'Birth date cannot be in the future'
            WHEN birth_date < '1900-01-01' THEN 'Birth date too far in the past'
            ELSE NULL
        END
    WHERE error_notes IS NULL;

    SELECT COUNT(*) FROM temp_citizen_import WHERE error_notes IS NULL INTO valid_count;

    -- Collect error details
    SELECT array_agg(first_name || ' ' || last_name || ': ' || error_notes)
    FROM temp_citizen_import
    WHERE error_notes IS NOT NULL
    INTO error_list;

    -- If not validation-only, perform actual import
    IF NOT validate_only AND valid_count > 0 THEN
        INSERT INTO civics.citizens (
            first_name, last_name, email, phone, street_address,
            zip_code, date_of_birth, status, registered_date
        )
        SELECT
            first_name, last_name, email, phone, street_address,
            zip_code, birth_date, 'active', NOW()
        FROM temp_citizen_import
        WHERE error_notes IS NULL;
    END IF;

    RETURN QUERY SELECT
        CASE WHEN validate_only THEN 'VALIDATION_ONLY' ELSE 'IMPORT_COMPLETE' END::TEXT,
        staging_count,
        valid_count,
        (staging_count - valid_count),
        error_list;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- FILE_FDW FOR EXTERNAL FILE ACCESS
-- =============================================================================

-- Create file_fdw extension and server
CREATE EXTENSION IF NOT EXISTS file_fdw;

CREATE SERVER file_server FOREIGN DATA WRAPPER file_fdw;

-- Create foreign table for CSV files
CREATE FOREIGN TABLE analytics.external_sensor_data (
    timestamp_reading TIMESTAMPTZ,
    sensor_id TEXT,
    sensor_type TEXT,
    location_lat DECIMAL(10,8),
    location_lng DECIMAL(11,8),
    measurement_value NUMERIC(12,4),
    measurement_unit TEXT,
    data_quality TEXT
) SERVER file_server
OPTIONS (filename '/tmp/sensor_data.csv', format 'csv', header 'true');

-- Create foreign table for log files
CREATE FOREIGN TABLE analytics.external_system_logs (
    log_timestamp TIMESTAMPTZ,
    log_level TEXT,
    component TEXT,
    message TEXT,
    user_id TEXT,
    session_id TEXT
) SERVER file_server
OPTIONS (filename '/var/log/application.log', format 'csv', delimiter '|');

-- Function to import external sensor data with transformation
CREATE OR REPLACE FUNCTION mobility.import_external_sensor_data()
RETURNS TEXT AS $$
DECLARE
    rows_imported BIGINT;
    rows_rejected BIGINT;
BEGIN
    -- Import valid sensor readings
    INSERT INTO mobility.sensor_readings (
        sensor_code, sensor_type, latitude, longitude,
        reading_value, unit_of_measure, reading_time,
        data_quality_score
    )
    SELECT
        esd.sensor_id,
        esd.sensor_type::mobility.sensor_type,
        esd.location_lat,
        esd.location_lng,
        esd.measurement_value,
        esd.measurement_unit,
        esd.timestamp_reading,
        CASE esd.data_quality
            WHEN 'excellent' THEN 1.0
            WHEN 'good' THEN 0.8
            WHEN 'fair' THEN 0.6
            WHEN 'poor' THEN 0.4
            ELSE 0.5
        END
    FROM analytics.external_sensor_data esd
    WHERE esd.timestamp_reading >= CURRENT_DATE - INTERVAL '1 day'
        AND esd.measurement_value IS NOT NULL
        AND esd.sensor_type IN ('traffic_counter', 'air_quality', 'noise', 'weather')
        AND esd.location_lat BETWEEN 32.0 AND 33.5
        AND esd.location_lng BETWEEN -97.5 AND -96.0;

    GET DIAGNOSTICS rows_imported = ROW_COUNT;

    -- Count rejected rows
    SELECT COUNT(*) INTO rows_rejected
    FROM analytics.external_sensor_data esd
    WHERE esd.timestamp_reading >= CURRENT_DATE - INTERVAL '1 day'
        AND (
            esd.measurement_value IS NULL OR
            esd.sensor_type NOT IN ('traffic_counter', 'air_quality', 'noise', 'weather') OR
            esd.location_lat NOT BETWEEN 32.0 AND 33.5 OR
            esd.location_lng NOT BETWEEN -97.5 AND -96.0
        );

    RETURN format('Imported %s sensor readings, rejected %s invalid records',
                  rows_imported, rows_rejected);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BULK UPDATE OPERATIONS
-- =============================================================================

-- Bulk update using COPY with temporary table
CREATE OR REPLACE FUNCTION civics.bulk_update_tax_payments(
    update_file_path TEXT DEFAULT '/tmp/tax_updates.csv'
)
RETURNS TEXT AS $$
DECLARE
    rows_updated BIGINT;
    rows_inserted BIGINT;
BEGIN
    -- Create staging table for updates
    CREATE TEMP TABLE tax_update_staging (
        citizen_id BIGINT,
        tax_year INTEGER,
        tax_type civics.tax_type,
        amount_paid NUMERIC(12,2),
        payment_date DATE,
        payment_method TEXT
    );

    -- Import updates from CSV
    -- COPY tax_update_staging FROM update_file_path WITH (FORMAT CSV, HEADER true);

    -- Demo data for testing
    INSERT INTO tax_update_staging VALUES
        (1, 2024, 'property', 2850.00, '2024-01-15', 'bank_transfer'),
        (2, 2024, 'property', 3200.00, '2024-01-20', 'check'),
        (10, 2024, 'vehicle', 150.00, '2024-03-10', 'credit_card'); -- New record

    -- Perform upsert operation
    INSERT INTO civics.tax_payments (
        citizen_id, tax_type, tax_year, assessment_amount, amount_due,
        amount_paid, payment_status, due_date, payment_date
    )
    SELECT
        tus.citizen_id,
        tus.tax_type,
        tus.tax_year,
        tus.amount_paid, -- Assuming paid amount equals assessment
        tus.amount_paid,
        tus.amount_paid,
        'paid',
        make_date(tus.tax_year, 1, 31), -- January 31st due date
        tus.payment_date
    FROM tax_update_staging tus
    ON CONFLICT (citizen_id, tax_type, tax_year) DO UPDATE SET
        amount_paid = EXCLUDED.amount_paid,
        payment_status = EXCLUDED.payment_status,
        payment_date = EXCLUDED.payment_date,
        updated_at = NOW();

    GET DIAGNOSTICS rows_inserted = ROW_COUNT;

    -- Update existing records
    WITH updated_records AS (
        UPDATE civics.tax_payments tp
        SET
            amount_paid = tus.amount_paid,
            payment_status = 'paid',
            payment_date = tus.payment_date,
            updated_at = NOW()
        FROM tax_update_staging tus
        WHERE tp.citizen_id = tus.citizen_id
            AND tp.tax_type = tus.tax_type
            AND tp.tax_year = tus.tax_year
            AND tp.payment_status != 'paid'
        RETURNING tp.tax_id
    )
    SELECT COUNT(*) INTO rows_updated FROM updated_records;

    RETURN format('Bulk tax update completed: %s new records, %s updated records',
                  rows_inserted, rows_updated);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PARALLEL COPY OPERATIONS
-- =============================================================================

-- Function to demonstrate parallel data loading
CREATE OR REPLACE FUNCTION analytics.parallel_bulk_load_demo()
RETURNS TEXT AS $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    result TEXT;
BEGIN
    start_time := clock_timestamp();

    -- Simulate parallel loading by inserting data in chunks
    -- In production, this would use multiple COPY operations in parallel

    -- Create temporary data for demo
    CREATE TEMP TABLE bulk_load_demo AS
    SELECT
        generate_series(1, 100000) as id,
        'SENSOR_' || LPAD((generate_series(1, 100000) % 100 + 1)::TEXT, 3, '0') as sensor_code,
        'temperature'::mobility.sensor_type as sensor_type,
        32.7 + (random() * 0.6) as latitude,
        -96.8 + (random() * 0.4) as longitude,
        65.0 + (random() * 30.0) as reading_value,
        'fahrenheit' as unit_of_measure,
        NOW() - (random() * INTERVAL '30 days') as reading_time;

    -- Bulk insert with reduced logging (in production)
    INSERT INTO mobility.sensor_readings (
        sensor_code, sensor_type, latitude, longitude,
        reading_value, unit_of_measure, reading_time
    )
    SELECT
        sensor_code, sensor_type, latitude, longitude,
        reading_value, unit_of_measure, reading_time
    FROM bulk_load_demo;

    end_time := clock_timestamp();

    result := format('Bulk loaded 100,000 sensor readings in %s seconds',
                    EXTRACT(EPOCH FROM (end_time - start_time))::NUMERIC(10,2));

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DATA EXPORT UTILITIES
-- =============================================================================

-- Function to export data with custom formatting
CREATE OR REPLACE FUNCTION analytics.export_citizen_report(
    output_format TEXT DEFAULT 'csv',
    include_sensitive BOOLEAN DEFAULT false
)
RETURNS TEXT AS $$
DECLARE
    export_query TEXT;
    file_path TEXT;
    row_count BIGINT;
BEGIN
    file_path := '/tmp/citizen_report_' || to_char(NOW(), 'YYYY_MM_DD_HH24MI') || '.' || output_format;

    -- Build export query based on sensitivity
    IF include_sensitive THEN
        export_query := '
        SELECT
            c.citizen_id, c.first_name, c.last_name, c.email, c.phone,
            c.street_address, c.zip_code, c.date_of_birth,
            COUNT(pa.permit_id) as permit_count,
            COALESCE(SUM(tp.amount_due - tp.amount_paid), 0) as outstanding_balance
        FROM civics.citizens c
        LEFT JOIN civics.permit_applications pa ON c.citizen_id = pa.citizen_id
        LEFT JOIN civics.tax_payments tp ON c.citizen_id = tp.citizen_id AND tp.payment_status != ''paid''
        WHERE c.status = ''active''
        GROUP BY c.citizen_id, c.first_name, c.last_name, c.email, c.phone,
                 c.street_address, c.zip_code, c.date_of_birth
        ORDER BY c.last_name, c.first_name';
    ELSE
        export_query := '
        SELECT
            c.citizen_id, c.first_name, c.last_name,
            LEFT(c.email, POSITION(''@'' IN c.email) - 1) || ''@***'' as masked_email,
            c.zip_code,
            EXTRACT(YEAR FROM AGE(c.date_of_birth)) as age_years,
            COUNT(pa.permit_id) as permit_count
        FROM civics.citizens c
        LEFT JOIN civics.permit_applications pa ON c.citizen_id = pa.citizen_id
        WHERE c.status = ''active''
        GROUP BY c.citizen_id, c.first_name, c.last_name, c.email, c.zip_code, c.date_of_birth
        ORDER BY c.last_name, c.first_name';
    END IF;

    -- Execute export (would use COPY TO in production)
    EXECUTE 'SELECT COUNT(*) FROM (' || export_query || ') t' INTO row_count;

    -- In production: COPY (export_query) TO file_path WITH (FORMAT CSV, HEADER true);

    RETURN format('Exported %s citizen records to %s (%s format, sensitive data %s)',
                  row_count, file_path, upper(output_format),
                  CASE WHEN include_sensitive THEN 'included' ELSE 'masked' END);
END;
$$ LANGUAGE plpgsql;
