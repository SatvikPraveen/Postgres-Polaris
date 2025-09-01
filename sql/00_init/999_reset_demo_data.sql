-- File: sql/00_init/999_reset_demo_data.sql
-- Purpose: SQL-based cleanup for demos and testing

-- =============================================================================
-- TRUNCATE ALL DATA (preserve schema structure)
-- =============================================================================

-- Disable foreign key checks temporarily
SET session_replication_role = replica;

-- Truncate in dependency order (children first, then parents)
TRUNCATE TABLE
    audit.table_changes,
    analytics.daily_metrics,
    civics.tax_payments,
    civics.permit_applications,
    civics.voting_records,
    commerce.order_items,
    commerce.payments,
    commerce.orders,
    commerce.business_licenses,
    commerce.merchants,
    mobility.trip_segments,
    mobility.sensor_readings,
    mobility.station_inventory,
    mobility.stations,
    geo.road_segments,
    geo.points_of_interest,
    geo.neighborhood_boundaries,
    documents.policy_documents,
    documents.complaint_records,
    civics.citizens
RESTART IDENTITY CASCADE;

-- Re-enable foreign key checks
SET session_replication_role = DEFAULT;

-- =============================================================================
-- RESET SEQUENCES
-- =============================================================================

-- Reset all sequences to start from 1
DO $$
DECLARE
    seq_record RECORD;
BEGIN
    FOR seq_record IN
        SELECT schemaname, sequencename
        FROM pg_sequences
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics', 'audit')
    LOOP
        EXECUTE 'ALTER SEQUENCE ' || quote_ident(seq_record.schemaname) || '.' || quote_ident(seq_record.sequencename) || ' RESTART WITH 1';
    END LOOP;
END $$;

-- =============================================================================
-- RESET MATERIALIZED VIEWS
-- =============================================================================

-- Refresh all materialized views (if any exist)
DO $$
DECLARE
    mv_record RECORD;
BEGIN
    FOR mv_record IN
        SELECT schemaname, matviewname
        FROM pg_matviews
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics')
    LOOP
        EXECUTE 'REFRESH MATERIALIZED VIEW ' || quote_ident(mv_record.schemaname) || '.' || quote_ident(mv_record.matviewname);
    END LOOP;
END $$;

-- =============================================================================
-- VACUUM AND ANALYZE
-- =============================================================================

-- Clean up space and update statistics
VACUUM ANALYZE;

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================

-- Show row counts for all tables
SELECT
    schemaname,
    tablename,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_tup_del as deletes,
    n_live_tup as live_rows,
    n_dead_tup as dead_rows
FROM pg_stat_user_tables
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics', 'audit')
ORDER BY schemaname, tablename;

-- Show sequence current values
SELECT
    schemaname,
    sequencename,
    last_value,
    start_value,
    increment_by
FROM pg_sequences
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics', 'audit')
ORDER BY schemaname, sequencename;

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Function to safely reset everything
CREATE OR REPLACE FUNCTION analytics.reset_demo_environment()
RETURNS TEXT AS $$
DECLARE
    result_text TEXT := '';
    table_count INTEGER;
    seq_count INTEGER;
BEGIN
    -- Count tables before reset
    SELECT COUNT(*) INTO table_count
    FROM information_schema.tables
    WHERE table_schema IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics', 'audit')
        AND table_type = 'BASE TABLE';

    -- Disable FK checks
    SET session_replication_role = replica;

    -- Truncate all tables
    EXECUTE 'TRUNCATE TABLE ' || (
        SELECT string_agg(quote_ident(schemaname) || '.' || quote_ident(tablename), ', ')
        FROM pg_tables
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics', 'audit')
    ) || ' RESTART IDENTITY CASCADE';

    -- Re-enable FK checks
    SET session_replication_role = DEFAULT;

    -- Reset sequences
    PERFORM
        'ALTER SEQUENCE ' || quote_ident(schemaname) || '.' || quote_ident(sequencename) || ' RESTART WITH 1'
    FROM pg_sequences
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics', 'audit');

    GET DIAGNOSTICS seq_count = ROW_COUNT;

    result_text := format('Reset complete: %s tables truncated, %s sequences reset', table_count, seq_count);

    RETURN result_text;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.reset_demo_environment() IS
'Safely reset all demo data while preserving schema structure';

SELECT 'Demo reset script loaded. Run analytics.reset_demo_environment() to execute full reset.' as status;
