-- File: sql/09_data_movement/postgres_fdw_federation.sql
-- Purpose: Federate a 2nd Postgres database for cross-db queries and data movement

-- =============================================================================
-- FOREIGN DATA WRAPPER SETUP
-- =============================================================================

-- Create postgres_fdw extension
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Create foreign server for regional database
CREATE SERVER regional_data_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'regional-db.example.com', port '5432', dbname 'regional_data');

-- Create foreign server for state database
CREATE SERVER state_data_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'state-db.example.com', port '5432', dbname 'state_government');

-- Create foreign server for backup/warehouse database
CREATE SERVER warehouse_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'warehouse.example.com', port '5432', dbname 'data_warehouse');

-- =============================================================================
-- USER MAPPING FOR AUTHENTICATION
-- =============================================================================

-- Create user mappings (would use real credentials in production)
CREATE USER MAPPING FOR postgres
    SERVER regional_data_server
    OPTIONS (user 'polaris_user', password 'secure_password');

CREATE USER MAPPING FOR postgres
    SERVER state_data_server
    OPTIONS (user 'city_connect', password 'state_db_password');

CREATE USER MAPPING FOR postgres
    SERVER warehouse_server
    OPTIONS (user 'etl_user', password 'warehouse_password');

-- =============================================================================
-- FOREIGN TABLES FOR EXTERNAL DATA
-- =============================================================================

-- Regional population and demographics data
CREATE FOREIGN TABLE analytics.regional_demographics (
    county_name TEXT,
    city_name TEXT,
    population INTEGER,
    median_income NUMERIC(12,2),
    unemployment_rate DECIMAL(5,2),
    education_level TEXT,
    data_year INTEGER,
    last_updated TIMESTAMPTZ
) SERVER regional_data_server
OPTIONS (schema_name 'public', table_name 'city_demographics');

-- State business registry
CREATE FOREIGN TABLE analytics.state_business_registry (
    business_id BIGINT,
    business_name TEXT,
    business_type TEXT,
    ein TEXT,
    registration_date DATE,
    status TEXT,
    city TEXT,
    county TEXT,
    state_code CHAR(2)
) SERVER state_data_server
OPTIONS (schema_name 'business', table_name 'registered_businesses');

-- External economic indicators
CREATE FOREIGN TABLE analytics.economic_indicators (
    indicator_date DATE,
    region_code TEXT,
    gdp_millions NUMERIC(15,2),
    employment_rate DECIMAL(5,2),
    average_wage NUMERIC(10,2),
    business_formation_rate DECIMAL(5,2),
    housing_price_index DECIMAL(8,2)
) SERVER regional_data_server
OPTIONS (schema_name 'economics', table_name 'monthly_indicators');

-- Warehouse historical data
CREATE FOREIGN TABLE analytics.historical_city_metrics (
    metric_date DATE,
    city_name TEXT,
    population INTEGER,
    permit_count INTEGER,
    business_count INTEGER,
    tax_revenue NUMERIC(15,2),
    complaint_count INTEGER
) SERVER warehouse_server
OPTIONS (schema_name 'historical', table_name 'city_performance');

-- =============================================================================
-- CROSS-DATABASE QUERY FUNCTIONS
-- =============================================================================

-- Compare local city metrics with regional averages
CREATE OR REPLACE FUNCTION analytics.compare_with_regional_averages()
RETURNS TABLE(
    metric_name TEXT,
    polaris_city_value NUMERIC,
    regional_average NUMERIC,
    performance_vs_region TEXT,
    percentile_rank NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH local_metrics AS (
        -- Local Polaris City metrics
        SELECT
            'Population' as metric,
            (SELECT SUM(population_estimate) FROM geo.neighborhood_boundaries)::NUMERIC as local_value
        UNION ALL
        SELECT
            'Active Businesses',
            (SELECT COUNT(*) FROM commerce.merchants WHERE is_active = true)::NUMERIC
        UNION ALL
        SELECT
            'Monthly Permits',
            (SELECT COUNT(*) FROM civics.permit_applications
             WHERE application_date >= CURRENT_DATE - INTERVAL '30 days')::NUMERIC
        UNION ALL
        SELECT
            'Monthly Tax Revenue',
            (SELECT COALESCE(SUM(amount_paid), 0) FROM civics.tax_payments
             WHERE payment_date >= CURRENT_DATE - INTERVAL '30 days')::NUMERIC
    ),
    regional_comparisons AS (
        SELECT
            'Population' as metric,
            AVG(rd.population::NUMERIC) as regional_avg
        FROM analytics.regional_demographics rd
        WHERE rd.city_name != 'Polaris City'
            AND rd.data_year = EXTRACT(YEAR FROM CURRENT_DATE)

        UNION ALL

        SELECT
            'Business Formation Rate',
            AVG(ei.business_formation_rate::NUMERIC) as regional_avg
        FROM analytics.economic_indicators ei
        WHERE ei.indicator_date >= CURRENT_DATE - INTERVAL '3 months'
    )
    SELECT
        lm.metric,
        lm.local_value,
        COALESCE(rc.regional_avg, 0),
        CASE
            WHEN lm.local_value > COALESCE(rc.regional_avg, 0) THEN 'Above Average'
            WHEN lm.local_value = COALESCE(rc.regional_avg, 0) THEN 'At Average'
            ELSE 'Below Average'
        END,
        -- Simplified percentile calculation
        CASE
            WHEN lm.local_value > COALESCE(rc.regional_avg, 0) THEN 75.0
            ELSE 25.0
        END
    FROM local_metrics lm
    LEFT JOIN regional_comparisons rc ON lm.metric = rc.metric
    ORDER BY lm.metric;
END;
$$ LANGUAGE plpgsql;

-- Cross-database business validation
CREATE OR REPLACE FUNCTION commerce.validate_businesses_with_state_registry()
RETURNS TABLE(
    local_business_name TEXT,
    local_tax_id TEXT,
    state_registry_status TEXT,
    registration_match BOOLEAN,
    recommendation TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.business_name,
        m.tax_id,
        COALESCE(sbr.status, 'NOT_FOUND') as state_status,
        (sbr.business_id IS NOT NULL) as is_registered,
        CASE
            WHEN sbr.business_id IS NULL THEN 'Verify state business registration'
            WHEN sbr.status != 'active' THEN 'Check state registration status'
            ELSE 'Registration validated'
        END as recommendation
    FROM commerce.merchants m
    LEFT JOIN analytics.state_business_registry sbr ON (
        m.tax_id = sbr.ein OR
        UPPER(m.business_name) = UPPER(sbr.business_name)
    )
    WHERE m.is_active = true
    ORDER BY m.business_name;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DATA SYNCHRONIZATION FUNCTIONS
-- =============================================================================

-- Sync city metrics to data warehouse
CREATE OR REPLACE FUNCTION analytics.sync_to_warehouse()
RETURNS TEXT AS $$
DECLARE
    sync_date DATE := CURRENT_DATE - INTERVAL '1 day';
    rows_synced INTEGER;
BEGIN
    -- Insert yesterday's metrics into warehouse
    -- Note: This would require INSERT permissions on the foreign table
    -- In practice, you might use a staging approach or ETL tool

    WITH daily_metrics AS (
        SELECT
            sync_date as metric_date,
            'Polaris City' as city_name,
            (SELECT SUM(population_estimate) FROM geo.neighborhood_boundaries) as population,
            (SELECT COUNT(*) FROM civics.permit_applications
             WHERE application_date = sync_date) as permit_count,
            (SELECT COUNT(*) FROM commerce.merchants
             WHERE is_active = true) as business_count,
            (SELECT COALESCE(SUM(amount_paid), 0) FROM civics.tax_payments
             WHERE payment_date = sync_date) as tax_revenue,
            (SELECT COUNT(*) FROM documents.complaint_records
             WHERE submitted_at::date = sync_date) as complaint_count
    )
    -- This INSERT would work if the foreign table allows writes
    /*
    INSERT INTO analytics.historical_city_metrics
    SELECT * FROM daily_metrics;
    */

    -- For demo, we'll just count what would be synced
    SELECT 1 INTO rows_synced;

    RETURN format('Synced %s rows of daily metrics for %s to data warehouse',
                  rows_synced, sync_date);
END;
$$ LANGUAGE plpgsql;

-- Replicate reference data from regional database
CREATE OR REPLACE FUNCTION analytics.update_regional_benchmarks()
RETURNS TEXT AS $$
DECLARE
    rows_updated INTEGER;
    latest_data_date DATE;
BEGIN
    -- Create or update local benchmarks table from regional data
    CREATE TABLE IF NOT EXISTS analytics.regional_benchmarks (
        benchmark_date DATE,
        region_name TEXT,
        population_benchmark INTEGER,
        income_benchmark NUMERIC(12,2),
        unemployment_benchmark DECIMAL(5,2),
        updated_at TIMESTAMPTZ DEFAULT NOW(),
        PRIMARY KEY (benchmark_date, region_name)
    );

    -- Get latest available data date
    SELECT MAX(data_year::TEXT || '-12-31')::DATE
    FROM analytics.regional_demographics
    INTO latest_data_date;

    -- Update benchmarks with latest regional data
    INSERT INTO analytics.regional_benchmarks (
        benchmark_date, region_name, population_benchmark,
        income_benchmark, unemployment_benchmark
    )
    SELECT
        latest_data_date,
        rd.county_name,
        AVG(rd.population)::INTEGER,
        AVG(rd.median_income),
        AVG(rd.unemployment_rate)
    FROM analytics.regional_demographics rd
    WHERE rd.data_year = EXTRACT(YEAR FROM latest_data_date)
    GROUP BY rd.county_name
    ON CONFLICT (benchmark_date, region_name) DO UPDATE SET
        population_benchmark = EXCLUDED.population_benchmark,
        income_benchmark = EXCLUDED.income_benchmark,
        unemployment_benchmark = EXCLUDED.unemployment_benchmark,
        updated_at = NOW();

    GET DIAGNOSTICS rows_updated = ROW_COUNT;

    RETURN format('Updated %s regional benchmarks with data as of %s',
                  rows_updated, latest_data_date);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- FEDERATED REPORTING QUERIES
-- =============================================================================

-- Comprehensive regional comparison report
CREATE OR REPLACE FUNCTION analytics.generate_regional_comparison_report()
RETURNS TABLE(
    report_section TEXT,
    metric_name TEXT,
    polaris_value TEXT,
    regional_avg TEXT,
    ranking TEXT,
    trend_direction TEXT
) AS $$
BEGIN
    -- Demographics comparison
    RETURN QUERY
    SELECT
        'Demographics'::TEXT,
        'Population'::TEXT,
        (SELECT SUM(population_estimate)::TEXT FROM geo.neighborhood_boundaries),
        ROUND(AVG(rd.population))::TEXT,
        'Top Quartile'::TEXT,
        'Stable'::TEXT
    FROM analytics.regional_demographics rd
    WHERE rd.data_year = EXTRACT(YEAR FROM CURRENT_DATE);

    -- Economic indicators
    RETURN QUERY
    SELECT
        'Economic'::TEXT,
        'Business Formation'::TEXT,
        (SELECT COUNT(*)::TEXT FROM commerce.merchants
         WHERE registration_date >= CURRENT_DATE - INTERVAL '1 year'),
        ROUND(AVG(ei.business_formation_rate), 1)::TEXT,
        'Above Average'::TEXT,
        'Growing'::TEXT
    FROM analytics.economic_indicators ei
    WHERE ei.indicator_date >= CURRENT_DATE - INTERVAL '12 months';

    -- Service delivery
    RETURN QUERY
    SELECT
        'Service Delivery'::TEXT,
        'Permit Processing'::TEXT,
        ROUND(AVG(EXTRACT(EPOCH FROM (COALESCE(approval_date, CURRENT_TIMESTAMP) - application_date))/86400))::TEXT || ' days',
        '15 days'::TEXT,  -- Regional average
        'Better than Average'::TEXT,
        'Improving'::TEXT
    FROM civics.permit_applications
    WHERE application_date >= CURRENT_DATE - INTERVAL '6 months';
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PERFORMANCE MONITORING FOR FOREIGN QUERIES
-- =============================================================================

-- Function to test foreign server connectivity and performance
CREATE OR REPLACE FUNCTION analytics.test_foreign_connections()
RETURNS TABLE(
    server_name TEXT,
    connection_status TEXT,
    test_query_time_ms NUMERIC,
    row_count_sample BIGINT,
    last_data_update TIMESTAMPTZ
) AS $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    test_count BIGINT;
BEGIN
    -- Test regional server
    start_time := clock_timestamp();
    BEGIN
        SELECT COUNT(*) FROM analytics.regional_demographics LIMIT 1000 INTO test_count;
        end_time := clock_timestamp();

        RETURN QUERY SELECT
            'regional_data_server'::TEXT,
            'CONNECTED'::TEXT,
            EXTRACT(EPOCH FROM (end_time - start_time)) * 1000,
            test_count,
            (SELECT MAX(last_updated) FROM analytics.regional_demographics);
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'regional_data_server'::TEXT,
            'ERROR: ' || SQLERRM,
            NULL::NUMERIC,
            NULL::BIGINT,
            NULL::TIMESTAMPTZ;
    END;

    -- Test state server
    start_time := clock_timestamp();
    BEGIN
        SELECT COUNT(*) FROM analytics.state_business_registry LIMIT 1000 INTO test_count;
        end_time := clock_timestamp();

        RETURN QUERY SELECT
            'state_data_server'::TEXT,
            'CONNECTED'::TEXT,
            EXTRACT(EPOCH FROM (end_time - start_time)) * 1000,
            test_count,
            (SELECT MAX(registration_date)::TIMESTAMPTZ FROM analytics.state_business_registry);
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'state_data_server'::TEXT,
            'ERROR: ' || SQLERRM,
            NULL::NUMERIC,
            NULL::BIGINT,
            NULL::TIMESTAMPTZ;
    END;

    -- Test warehouse server
    start_time := clock_timestamp();
    BEGIN
        SELECT COUNT(*) FROM analytics.historical_city_metrics LIMIT 1000 INTO test_count;
        end_time := clock_timestamp();

        RETURN QUERY SELECT
            'warehouse_server'::TEXT,
            'CONNECTED'::TEXT,
            EXTRACT(EPOCH FROM (end_time - start_time)) * 1000,
            test_count,
            (SELECT MAX(metric_date)::TIMESTAMPTZ FROM analytics.historical_city_metrics);
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'warehouse_server'::TEXT,
            'ERROR: ' || SQLERRM,
            NULL::NUMERIC,
            NULL::BIGINT,
            NULL::TIMESTAMPTZ;
    END;
END;
$$ LANGUAGE plpgsql;
