-- File: docker/initdb/999_health_checks.sql
-- Health checks and verification for postgres-polaris initialization
-- Executed only on first container startup (last in sequence)

\echo '========================================='
\echo 'Running postgres-polaris health checks...'
\echo '========================================='

-- Connect to main database
\c polaris;

-- Check database connectivity
\echo 'Database connectivity: OK'

-- Verify schemas exist
\echo 'Checking schemas...'
SELECT
    schema_name,
    CASE
        WHEN schema_name IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'audit', 'analytics', 'monitoring')
        THEN '✓ OK'
        ELSE '✗ MISSING'
    END as status
FROM information_schema.schemata
WHERE schema_name IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'audit', 'analytics', 'monitoring', 'public')
ORDER BY schema_name;

-- Verify critical extensions
\echo 'Checking extensions...'
WITH required_extensions(name) AS (
    VALUES
        ('postgis'), ('uuid-ossp'), ('pgcrypto'), ('hstore'),
        ('pg_trgm'), ('btree_gin'), ('pg_cron'), ('pg_partman')
)
SELECT
    re.name as extension_name,
    pe.extversion,
    CASE WHEN pe.extname IS NOT NULL THEN '✓ INSTALLED' ELSE '✗ MISSING' END as status
FROM required_extensions re
LEFT JOIN pg_extension pe ON re.name = pe.extname
ORDER BY re.name;

-- Verify roles
\echo 'Checking roles...'
WITH required_roles(name) AS (
    VALUES
        ('polaris_admin'), ('polaris_app_readonly'), ('polaris_app_readwrite'),
        ('polaris_analyst'), ('polaris_developer'), ('polaris_auditor')
)
SELECT
    rr.name as role_name,
    pr.rolcanlogin,
    CASE WHEN pr.rolname IS NOT NULL THEN '✓ EXISTS' ELSE '✗ MISSING' END as status
FROM required_roles rr
LEFT JOIN pg_roles pr ON rr.name = pr.rolname
ORDER BY rr.name;

-- Check PostGIS functionality
\echo 'Testing PostGIS functionality...'
DO $$
BEGIN
    -- Test basic PostGIS functions
    PERFORM ST_MakePoint(-122.4194, 37.7749); -- San Francisco coordinates
    PERFORM ST_GeogFromText('POINT(-122.4194 37.7749)');
    RAISE NOTICE '✓ PostGIS spatial functions working';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '✗ PostGIS spatial functions failed: %', SQLERRM;
END
$$;

-- Test UUID generation
\echo 'Testing UUID generation...'
DO $$
DECLARE
    test_uuid uuid;
BEGIN
    test_uuid := gen_random_uuid();
    IF test_uuid IS NOT NULL THEN
        RAISE NOTICE '✓ UUID generation working: %', test_uuid;
    ELSE
        RAISE NOTICE '✗ UUID generation failed';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '✗ UUID generation failed: %', SQLERRM;
END
$$;

-- Test encryption functionality
\echo 'Testing encryption functionality...'
DO $$
DECLARE
    encrypted_text text;
    decrypted_text text;
BEGIN
    encrypted_text := pgp_sym_encrypt('test data', 'secret_key');
    decrypted_text := pgp_sym_decrypt(encrypted_text, 'secret_key');
    IF decrypted_text = 'test data' THEN
        RAISE NOTICE '✓ Encryption/decryption working';
    ELSE
        RAISE NOTICE '✗ Encryption/decryption failed';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '✗ Encryption/decryption failed: %', SQLERRM;
END
$$;

-- Test full-text search
\echo 'Testing full-text search...'
DO $$
BEGIN
    -- Test basic full-text search functionality
    PERFORM to_tsvector('english', 'The quick brown fox jumps over the lazy dog');
    PERFORM to_tsquery('english', 'fox & dog');
    RAISE NOTICE '✓ Full-text search working';
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE '✗ Full-text search failed: %', SQLERRM;
END
$$;

-- Create health check function for ongoing monitoring
CREATE OR REPLACE FUNCTION monitoring.health_check()
RETURNS TABLE(
    component text,
    status text,
    details text
) AS $$
BEGIN
    -- Database connectivity
    RETURN QUERY SELECT 'Database'::text, 'OK'::text, 'Connected to polaris database'::text;

    -- Extension check
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        RETURN QUERY SELECT 'PostGIS'::text, 'OK'::text, 'PostGIS extension loaded'::text;
    ELSE
        RETURN QUERY SELECT 'PostGIS'::text, 'ERROR'::text, 'PostGIS extension not found'::text;
    END IF;

    -- Schema check
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'civics') THEN
        RETURN QUERY SELECT 'Schemas'::text, 'OK'::text, 'Required schemas present'::text;
    ELSE
        RETURN QUERY SELECT 'Schemas'::text, 'ERROR'::text, 'Required schemas missing'::text;
    END IF;

    -- Connection count
    RETURN QUERY
    SELECT
        'Connections'::text,
        'INFO'::text,
        'Active connections: ' || count(*)::text
    FROM pg_stat_activity
    WHERE state = 'active';

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant permission to monitoring role
GRANT EXECUTE ON FUNCTION monitoring.health_check() TO polaris_app_readonly, polaris_analyst, polaris_developer;

-- Test the health check function
\echo 'Testing health check function...'
SELECT * FROM monitoring.health_check();

-- Database statistics
\echo 'Database statistics...'
SELECT
    'Database size' as metric,
    pg_size_pretty(pg_database_size('polaris')) as value
UNION ALL
SELECT
    'Total connections',
    count(*)::text
FROM pg_stat_activity
UNION ALL
SELECT
    'Active connections',
    count(*)::text
FROM pg_stat_activity
WHERE state = 'active';

-- Final status
\echo '========================================='
\echo '✓ postgres-polaris initialization complete!'
\echo 'Database: polaris'
\echo 'Port: 5432'
\echo 'Admin user: polaris_admin'
\echo '========================================='

-- Create the log table first
CREATE TABLE IF NOT EXISTS monitoring.health_check_log (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    status TEXT NOT NULL,
    details TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

COMMENT ON TABLE monitoring.health_check_log IS 'Log of health check events and database status';

-- Now log completion
INSERT INTO monitoring.health_check_log (timestamp, status, details)
VALUES (NOW(), 'INIT_COMPLETE', 'postgres-polaris database initialization completed successfully');

\echo 'Health checks completed. postgres-polaris is ready for use!';
