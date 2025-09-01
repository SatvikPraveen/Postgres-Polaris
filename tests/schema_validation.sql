-- Location: /tests/schema_validation.sql
-- Ensure all required tables and indexes exist with proper structure

-- Test configuration
\set ON_ERROR_STOP on
\timing on

-- Start validation
SELECT 'Starting schema validation...' as status;

-- Test 1: Check core tables exist
DO $$
DECLARE
    missing_tables text[];
    expected_tables text[] := ARRAY['citizens', 'merchants', 'orders', 'trips'];
    table_name text;
    table_exists boolean;
BEGIN
    RAISE NOTICE 'Test 1: Checking core tables exist...';

    FOREACH table_name IN ARRAY expected_tables LOOP
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_schema = 'public'
            AND table_name = table_name
        ) INTO table_exists;

        IF NOT table_exists THEN
            missing_tables := array_append(missing_tables, table_name);
        END IF;
    END LOOP;

    IF array_length(missing_tables, 1) > 0 THEN
        RAISE EXCEPTION 'Missing core tables: %', array_to_string(missing_tables, ', ');
    ELSE
        RAISE NOTICE '✓ All core tables exist';
    END IF;
END $$;

-- Test 2: Validate citizens table structure
DO $$
DECLARE
    column_count integer;
    expected_columns text[] := ARRAY[
        'citizen_id', 'name', 'email', 'phone', 'birth_date',
        'registration_date', 'address_line', 'city', 'state', 'zip_code'
    ];
BEGIN
    RAISE NOTICE 'Test 2: Validating citizens table structure...';

    SELECT COUNT(*) INTO column_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND table_name = 'citizens'
    AND column_name = ANY(expected_columns);

    IF column_count < array_length(expected_columns, 1) THEN
        RAISE EXCEPTION 'Citizens table missing required columns. Found: %, Expected: %',
            column_count, array_length(expected_columns, 1);
    ELSE
        RAISE NOTICE '✓ Citizens table structure valid';
    END IF;
END $$;

-- Test 3: Validate merchants table structure
DO $$
DECLARE
    column_count integer;
    expected_columns text[] := ARRAY[
        'merchant_id', 'business_name', 'owner_name', 'category',
        'address', 'phone', 'registration_date', 'tax_id', 'status'
    ];
BEGIN
    RAISE NOTICE 'Test 3: Validating merchants table structure...';

    SELECT COUNT(*) INTO column_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND table_name = 'merchants'
    AND column_name = ANY(expected_columns);

    IF column_count < array_length(expected_columns, 1) THEN
        RAISE EXCEPTION 'Merchants table missing required columns. Found: %, Expected: %',
            column_count, array_length(expected_columns, 1);
    ELSE
        RAISE NOTICE '✓ Merchants table structure valid';
    END IF;
END $$;

-- Test 4: Check primary keys exist
DO $$
DECLARE
    missing_pks text[];
    table_name text;
    pk_exists boolean;
    expected_tables_pks text[] := ARRAY['citizens', 'merchants', 'orders', 'trips'];
BEGIN
    RAISE NOTICE 'Test 4: Checking primary keys...';

    FOREACH table_name IN ARRAY expected_tables_pks LOOP
        SELECT EXISTS (
            SELECT FROM information_schema.table_constraints tc
            WHERE tc.constraint_type = 'PRIMARY KEY'
            AND tc.table_schema = 'public'
            AND tc.table_name = table_name
        ) INTO pk_exists;

        IF NOT pk_exists THEN
            missing_pks := array_append(missing_pks, table_name);
        END IF;
    END LOOP;

    IF array_length(missing_pks, 1) > 0 THEN
        RAISE EXCEPTION 'Tables missing primary keys: %', array_to_string(missing_pks, ', ');
    ELSE
        RAISE NOTICE '✓ All primary keys exist';
    END IF;
END $$;

-- Test 5: Check foreign key relationships
DO $$
DECLARE
    fk_count integer;
BEGIN
    RAISE NOTICE 'Test 5: Checking foreign key relationships...';

    -- Check orders → citizens relationship
    SELECT COUNT(*) INTO fk_count
    FROM information_schema.referential_constraints rc
    JOIN information_schema.table_constraints tc ON rc.constraint_name = tc.constraint_name
    WHERE tc.table_name = 'orders'
    AND tc.constraint_type = 'FOREIGN KEY';

    IF fk_count = 0 THEN
        RAISE WARNING 'No foreign keys found on orders table (might be expected in early modules)';
    ELSE
        RAISE NOTICE '✓ Foreign key relationships exist (% found)', fk_count;
    END IF;
END $$;

-- Test 6: Check basic indexes exist
DO $$
DECLARE
    index_count integer;
    important_indexes text[] := ARRAY['email', 'customer_id', 'merchant_id'];
    idx text;
    idx_exists boolean;
BEGIN
    RAISE NOTICE 'Test 6: Checking important indexes...';

    FOREACH idx IN ARRAY important_indexes LOOP
        SELECT EXISTS (
            SELECT FROM pg_indexes
            WHERE schemaname = 'public'
            AND indexname ILIKE '%' || idx || '%'
        ) INTO idx_exists;

        IF idx_exists THEN
            RAISE NOTICE '✓ Index found for: %', idx;
        ELSE
            RAISE WARNING 'Index not found for: % (might be created in later modules)', idx;
        END IF;
    END LOOP;
END $$;

-- Test 7: Check data types are appropriate
DO $$
DECLARE
    wrong_types integer := 0;
BEGIN
    RAISE NOTICE 'Test 7: Validating data types...';

    -- Check that ID columns are integer/serial
    SELECT COUNT(*) INTO wrong_types
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND column_name ILIKE '%_id'
    AND data_type NOT IN ('integer', 'bigint');

    IF wrong_types > 0 THEN
        RAISE WARNING '% ID columns have non-integer types', wrong_types;
    ELSE
        RAISE NOTICE '✓ ID columns have appropriate types';
    END IF;

    -- Check that date columns are proper date/timestamp types
    SELECT COUNT(*) INTO wrong_types
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND column_name ILIKE '%date%'
    AND data_type NOT IN ('date', 'timestamp without time zone', 'timestamp with time zone');

    IF wrong_types > 0 THEN
        RAISE WARNING '% date columns have non-date types', wrong_types;
    ELSE
        RAISE NOTICE '✓ Date columns have appropriate types';
    END IF;
END $$;

-- Test 8: Check for PostGIS extension (if spatial module loaded)
DO $$
DECLARE
    postgis_available boolean;
    spatial_tables integer;
BEGIN
    RAISE NOTICE 'Test 8: Checking PostGIS availability...';

    SELECT EXISTS (
        SELECT FROM pg_extension WHERE extname = 'postgis'
    ) INTO postgis_available;

    IF postgis_available THEN
        RAISE NOTICE '✓ PostGIS extension is installed';

        -- Check for spatial tables
        SELECT COUNT(*) INTO spatial_tables
        FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name IN ('spatial_features', 'neighborhoods', 'routes');

        IF spatial_tables > 0 THEN
            RAISE NOTICE '✓ Spatial tables found (%)', spatial_tables;
        ELSE
            RAISE NOTICE 'No spatial tables found (might not be loaded yet)';
        END IF;
    ELSE
        RAISE NOTICE 'PostGIS extension not installed (might be expected)';
    END IF;
END $$;

-- Test 9: Check JSONB tables if they exist
DO $$
DECLARE
    jsonb_tables integer;
    jsonb_indexes integer;
BEGIN
    RAISE NOTICE 'Test 9: Checking JSONB functionality...';

    SELECT COUNT(*) INTO jsonb_tables
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND data_type = 'jsonb';

    IF jsonb_tables > 0 THEN
        RAISE NOTICE '✓ JSONB columns found (%)', jsonb_tables;

        -- Check for GIN indexes on JSONB columns
        SELECT COUNT(*) INTO jsonb_indexes
        FROM pg_indexes
        WHERE schemaname = 'public'
        AND indexdef ILIKE '%gin%'
        AND indexdef ILIKE '%jsonb%';

        IF jsonb_indexes > 0 THEN
            RAISE NOTICE '✓ GIN indexes on JSONB columns found (%)', jsonb_indexes;
        ELSE
            RAISE NOTICE 'No GIN indexes on JSONB columns (might not be created yet)';
        END IF;
    ELSE
        RAISE NOTICE 'No JSONB columns found (might not be loaded yet)';
    END IF;
END $$;

-- Test 10: Check table permissions
DO $$
DECLARE
    permission_issues integer := 0;
    current_role text;
BEGIN
    RAISE NOTICE 'Test 10: Checking table permissions...';

    SELECT current_user INTO current_role;

    -- Check if current user can select from core tables
    BEGIN
        PERFORM COUNT(*) FROM citizens LIMIT 1;
        PERFORM COUNT(*) FROM merchants LIMIT 1;
        PERFORM COUNT(*) FROM orders LIMIT 1;
        PERFORM COUNT(*) FROM trips LIMIT 1;
        RAISE NOTICE '✓ Read permissions verified for user: %', current_role;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Permission issues detected for user: %', current_role;
    END;
END $$;

-- Test 11: Schema consistency check
SELECT
    'Test 11: Schema consistency summary' as test,
    COUNT(DISTINCT table_name) as total_tables,
    COUNT(CASE WHEN table_type = 'BASE TABLE' THEN 1 END) as base_tables,
    COUNT(CASE WHEN table_type = 'VIEW' THEN 1 END) as views
FROM information_schema.tables
WHERE table_schema = 'public';

-- Test 12: Index utilization check (if statistics available)
SELECT
    'Test 12: Index overview' as test,
    schemaname,
    COUNT(*) as total_indexes,
    COUNT(CASE WHEN idx_scan > 0 THEN 1 END) as used_indexes,
    COUNT(CASE WHEN idx_scan = 0 THEN 1 END) as unused_indexes
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
GROUP BY schemaname;

-- Final validation summary
DO $$
DECLARE
    table_count integer;
    index_count integer;
    constraint_count integer;
BEGIN
    SELECT COUNT(*) INTO table_count
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'public';

    SELECT COUNT(*) INTO constraint_count
    FROM information_schema.table_constraints
    WHERE table_schema = 'public';

    RAISE NOTICE '========================================';
    RAISE NOTICE 'SCHEMA VALIDATION SUMMARY';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Tables: %', table_count;
    RAISE NOTICE 'Indexes: %', index_count;
    RAISE NOTICE 'Constraints: %', constraint_count;
    RAISE NOTICE '========================================';

    IF table_count >= 4 THEN
        RAISE NOTICE '✅ Schema validation PASSED';
    ELSE
        RAISE NOTICE '⚠️  Schema validation PARTIAL (% tables found, expected at least 4)', table_count;
    END IF;
END $$;

SELECT 'Schema validation completed' as status;
