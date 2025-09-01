-- File: sql/13_backup_replication/logical_replication_demo.sql
-- Purpose: Publisher/subscriber logical replication setup and demos

-- =============================================================================
-- PUBLICATION SETUP (ON SOURCE/PUBLISHER DATABASE)
-- =============================================================================

-- Create publication for all city data
CREATE PUBLICATION city_data_pub FOR ALL TABLES;

-- Create publication for specific schemas
CREATE PUBLICATION civic_services_pub FOR TABLES IN SCHEMA civics;
CREATE PUBLICATION business_data_pub FOR TABLES IN SCHEMA commerce;

-- Create publication for specific tables
CREATE PUBLICATION critical_data_pub FOR TABLE
    civics.citizens,
    civics.tax_payments,
    commerce.merchants,
    documents.complaint_records;

-- Publication with WHERE clause (filtered replication)
CREATE PUBLICATION active_citizens_pub FOR TABLE civics.citizens
    WHERE (status = 'active');

-- Publication excluding certain columns
CREATE PUBLICATION public_citizen_data FOR TABLE civics.citizens (
    citizen_id, first_name, last_name, city, state, zip_code, status
);

-- =============================================================================
-- SUBSCRIPTION SETUP (ON TARGET/SUBSCRIBER DATABASE)
-- =============================================================================

-- Create subscription to replicate all city data
-- Note: This would be run on the subscriber database
/*
CREATE SUBSCRIPTION city_data_sub
    CONNECTION 'host=publisher-db.example.com port=5432 user=replication_user dbname=city_data password=secure_password'
    PUBLICATION city_data_pub
    WITH (copy_data = true, create_slot = true);
*/

-- Create subscription for specific publication
/*
CREATE SUBSCRIPTION civic_services_sub
    CONNECTION 'host=source-server.example.com port=5432 user=repl_user dbname=polaris_city'
    PUBLICATION civic_services_pub
    WITH (
        copy_data = true,
        create_slot = true,
        slot_name = 'civic_services_slot',
        synchronous_commit = 'remote_apply'
    );
*/

-- =============================================================================
-- REPLICATION MONITORING FUNCTIONS
-- =============================================================================

-- Function to monitor replication status
CREATE OR REPLACE FUNCTION analytics.check_replication_status()
RETURNS TABLE(
    pub_name TEXT,
    sub_name TEXT,
    replication_state TEXT,
    last_msg_send_time TIMESTAMPTZ,
    last_msg_receipt_time TIMESTAMPTZ,
    latest_end_lsn TEXT,
    lag_seconds NUMERIC,
    sync_status TEXT
) AS $$
BEGIN
    -- Check publication status
    RETURN QUERY
    SELECT
        p.pubname::TEXT,
        NULL::TEXT as sub_name,
        'PUBLISHER'::TEXT as replication_state,
        NOW() as last_msg_send_time,
        NULL::TIMESTAMPTZ as last_msg_receipt_time,
        pg_current_wal_lsn()::TEXT as latest_end_lsn,
        0::NUMERIC as lag_seconds,
        'ACTIVE'::TEXT as sync_status
    FROM pg_publication p
    WHERE p.pubname LIKE '%city%' OR p.pubname LIKE '%civic%';

    -- Check subscription status (would show results on subscriber)
    /*
    RETURN QUERY
    SELECT
        NULL::TEXT as pub_name,
        s.subname::TEXT,
        'SUBSCRIBER'::TEXT,
        NULL::TIMESTAMPTZ,
        ss.last_msg_receipt_time,
        ss.latest_end_lsn::TEXT,
        EXTRACT(EPOCH FROM (NOW() - ss.last_msg_receipt_time))::NUMERIC,
        CASE ss.state
            WHEN 'r' THEN 'READY'
            WHEN 's' THEN 'STREAMING'
            WHEN 'i' THEN 'INITIALIZE'
            WHEN 'd' THEN 'DATA_SYNC'
            ELSE 'UNKNOWN'
        END::TEXT
    FROM pg_subscription s
    JOIN pg_subscription_stats ss ON s.oid = ss.subid;
    */
END;
$$ LANGUAGE plpgsql;

-- Function to check replication lag
CREATE OR REPLACE FUNCTION analytics.check_replication_lag()
RETURNS TABLE(
    publication_name TEXT,
    subscription_name TEXT,
    lag_bytes BIGINT,
    lag_seconds NUMERIC,
    status TEXT,
    recommendation TEXT
) AS $$
BEGIN
    -- This would be more meaningful on a subscriber database
    RETURN QUERY
    SELECT
        p.pubname::TEXT,
        'N/A (Publisher)'::TEXT,
        0::BIGINT,
        0::NUMERIC,
        'ACTIVE'::TEXT,
        'Monitor subscriber for actual lag metrics'::TEXT
    FROM pg_publication p
    WHERE p.pubname IN ('city_data_pub', 'civic_services_pub', 'business_data_pub');

    -- On subscriber, you would query:
    /*
    RETURN QUERY
    SELECT
        pub.pubname::TEXT,
        sub.subname::TEXT,
        pg_wal_lsn_diff(pg_current_wal_lsn(), ss.latest_end_lsn) as lag_bytes,
        EXTRACT(EPOCH FROM (NOW() - ss.last_msg_receipt_time))::NUMERIC as lag_seconds,
        CASE
            WHEN ss.state = 's' THEN 'STREAMING'
            WHEN ss.state = 'r' THEN 'READY'
            ELSE 'ISSUE'
        END::TEXT,
        CASE
            WHEN EXTRACT(EPOCH FROM (NOW() - ss.last_msg_receipt_time)) > 300 THEN 'Check network connectivity'
            WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), ss.latest_end_lsn) > 1048576 THEN 'High lag detected'
            ELSE 'Replication healthy'
        END::TEXT
    FROM pg_subscription sub
    JOIN pg_subscription_stats ss ON sub.oid = ss.subid
    JOIN pg_publication pub ON true; -- Simplified join
    */
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- REPLICATION CONFLICT RESOLUTION
-- =============================================================================

-- Function to handle replication conflicts
CREATE OR REPLACE FUNCTION analytics.handle_replication_conflicts()
RETURNS TABLE(
    conflict_type TEXT,
    table_name TEXT,
    conflict_time TIMESTAMPTZ,
    resolution_action TEXT,
    conflict_details JSONB
) AS $$
BEGIN
    -- This is a demonstration of conflict types and resolutions
    -- Actual conflicts would be logged in pg_subscription_errors (PostgreSQL 14+)

    RETURN QUERY
    VALUES
        ('UNIQUE_VIOLATION', 'civics.citizens', NOW() - INTERVAL '1 hour',
         'Skip conflicting row', '{"duplicate_key": "email", "action": "skip"}'),
        ('FOREIGN_KEY_VIOLATION', 'civics.permit_applications', NOW() - INTERVAL '30 minutes',
         'Create missing parent record', '{"missing_citizen_id": 12345, "action": "create_parent"}'),
        ('UPDATE_CONFLICT', 'commerce.orders', NOW() - INTERVAL '15 minutes',
         'Use subscriber version', '{"field": "status", "publisher": "completed", "subscriber": "cancelled"}');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SELECTIVE REPLICATION PATTERNS
-- =============================================================================

-- Create publication for recent data only
CREATE PUBLICATION recent_activity_pub FOR TABLE
    civics.permit_applications WHERE (application_date >= CURRENT_DATE - INTERVAL '30 days'),
    documents.complaint_records WHERE (submitted_at >= CURRENT_DATE - INTERVAL '30 days'),
    commerce.orders WHERE (order_date >= CURRENT_DATE - INTERVAL '30 days');

-- Create publication excluding sensitive columns
CREATE PUBLICATION anonymized_citizens_pub FOR TABLE civics.citizens (
    citizen_id, first_name, last_name, city, state, zip_code,
    status, registered_date, created_at, updated_at
);

-- Create publication for audit data only
CREATE PUBLICATION audit_trail_pub FOR TABLES IN SCHEMA audit;

-- =============================================================================
-- REPLICATION ADMINISTRATION FUNCTIONS
-- =============================================================================

-- Function to add table to existing publication
CREATE OR REPLACE FUNCTION analytics.add_table_to_publication(
    pub_name TEXT,
    schema_name TEXT,
    table_name TEXT
)
RETURNS TEXT AS $$
DECLARE
    sql_command TEXT;
BEGIN
    sql_command := format('ALTER PUBLICATION %I ADD TABLE %I.%I',
                         pub_name, schema_name, table_name);

    EXECUTE sql_command;

    RETURN format('Added table %s.%s to publication %s',
                  schema_name, table_name, pub_name);
END;
$$ LANGUAGE plpgsql;

-- Function to remove table from publication
CREATE OR REPLACE FUNCTION analytics.remove_table_from_publication(
    pub_name TEXT,
    schema_name TEXT,
    table_name TEXT
)
RETURNS TEXT AS $$
DECLARE
    sql_command TEXT;
BEGIN
    sql_command := format('ALTER PUBLICATION %I DROP TABLE %I.%I',
                         pub_name, schema_name, table_name);

    EXECUTE sql_command;

    RETURN format('Removed table %s.%s from publication %s',
                  schema_name, table_name, pub_name);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- REPLICATION TESTING UTILITIES
-- =============================================================================

-- Function to test replication by inserting test data
CREATE OR REPLACE FUNCTION analytics.test_replication_with_data()
RETURNS TEXT AS $$
DECLARE
    test_citizen_id BIGINT;
    result TEXT := 'Replication test results:' || E'\n';
BEGIN
    -- Insert test citizen
    INSERT INTO civics.citizens (
        first_name, last_name, email, phone, street_address, zip_code, date_of_birth
    ) VALUES (
        'Replication', 'Test', 'reptest@example.com', '214-555-TEST',
        '123 Test Replication St', '75000', '1990-01-01'
    ) RETURNING citizen_id INTO test_citizen_id;

    result := result || format('- Inserted test citizen ID: %s', test_citizen_id) || E'\n';

    -- Insert related permit application
    INSERT INTO civics.permit_applications (
        citizen_id, permit_type, permit_number, description, fee_amount
    ) VALUES (
        test_citizen_id, 'building', 'REPL-TEST-001', 'Replication test permit', 100.00
    );

    result := result || '- Inserted related permit application' || E'\n';

    -- Update the citizen record
    UPDATE civics.citizens
    SET phone = '214-555-UPDT'
    WHERE citizen_id = test_citizen_id;

    result := result || '- Updated citizen phone number' || E'\n';

    result := result || 'Check subscriber database for replicated data' || E'\n';
    result := result || 'Test citizen email: reptest@example.com';

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Function to cleanup test data
CREATE OR REPLACE FUNCTION analytics.cleanup_replication_test_data()
RETURNS TEXT AS $$
DECLARE
    deleted_permits INTEGER;
    deleted_citizens INTEGER;
BEGIN
    -- Delete test permits
    DELETE FROM civics.permit_applications
    WHERE permit_number LIKE 'REPL-TEST-%';
    GET DIAGNOSTICS deleted_permits = ROW_COUNT;

    -- Delete test citizens
    DELETE FROM civics.citizens
    WHERE email LIKE '%reptest@example.com%' OR first_name = 'Replication';
    GET DIAGNOSTICS deleted_citizens = ROW_COUNT;

    RETURN format('Cleaned up %s test permits and %s test citizens',
                  deleted_permits, deleted_citizens);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- REPLICATION PERFORMANCE MONITORING
-- =============================================================================

-- Function to analyze publication performance
CREATE OR REPLACE FUNCTION analytics.analyze_publication_performance()
RETURNS TABLE(
    publication_name TEXT,
    table_count INTEGER,
    estimated_daily_changes BIGINT,
    replication_overhead TEXT,
    optimization_suggestions TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH pub_tables AS (
        SELECT
            p.pubname,
            COUNT(*) as table_count,
            -- Estimate daily changes based on recent activity
            SUM(COALESCE(
                (SELECT n_tup_ins + n_tup_upd + n_tup_del
                 FROM pg_stat_user_tables
                 WHERE schemaname = pt.schemaname
                   AND relname = pt.tablename), 0
            )) as total_changes
        FROM pg_publication p
        LEFT JOIN pg_publication_tables pt ON p.pubname = pt.pubname
        GROUP BY p.pubname
    )
    SELECT
        pubname::TEXT,
        table_count::INTEGER,
        total_changes,
        CASE
            WHEN total_changes > 100000 THEN 'HIGH - Consider selective replication'
            WHEN total_changes > 10000 THEN 'MEDIUM - Monitor bandwidth usage'
            ELSE 'LOW - Minimal overhead'
        END::TEXT,
        CASE
            WHEN total_changes > 100000 THEN 'Use filtered publications or separate high-change tables'
            WHEN table_count > 20 THEN 'Consider splitting into multiple publications'
            ELSE 'Current setup is optimal'
        END::TEXT
    FROM pub_tables
    ORDER BY total_changes DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- FAILOVER PREPARATION
-- =============================================================================

-- Function to prepare for failover scenario
CREATE OR REPLACE FUNCTION analytics.prepare_for_failover()
RETURNS TEXT AS $$
DECLARE
    result TEXT := 'Failover preparation checklist:' || E'\n';
BEGIN
    result := result || '- Current WAL position: ' || pg_current_wal_lsn() || E'\n';
    result := result || '- Active publications: ' ||
              (SELECT COUNT(*)::TEXT FROM pg_publication) || E'\n';
    result := result || '- Replication slots: ' ||
              (SELECT COUNT(*)::TEXT FROM pg_replication_slots WHERE active = true) || E'\n';
    result := result || '- Last checkpoint: ' ||
              (SELECT checkpoint_time FROM pg_control_checkpoint()) || E'\n';

    -- Force checkpoint for consistent state
    CHECKPOINT;
    result := result || '- Forced checkpoint completed' || E'\n';

    result := result || E'\nFailover readiness: PREPARED';

    RETURN result;
END;
$$ LANGUAGE plpgsql;
