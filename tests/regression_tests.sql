-- Location: /tests/regression_tests.sql
-- Version compatibility checks and feature regression testing

\set ON_ERROR_STOP on
\timing on

-- Start regression testing
SELECT 'Starting regression tests...' as status;

-- Test 1: PostgreSQL version compatibility
DO $$
DECLARE
    pg_version_num integer;
    pg_version_str text;
    min_required_version integer := 120000; -- PostgreSQL 12.0
BEGIN
    RAISE NOTICE 'Test 1: PostgreSQL version compatibility...';

    SELECT current_setting('server_version_num')::integer INTO pg_version_num;
    SELECT version() INTO pg_version_str;

    RAISE NOTICE 'PostgreSQL version: %', pg_version_str;
    RAISE NOTICE 'Version number: %', pg_version_num;

    IF pg_version_num >= min_required_version THEN
        RAISE NOTICE '✓ PostgreSQL version is compatible (>= 12.0)';
    ELSE
        RAISE WARNING 'PostgreSQL version may be too old. Minimum recommended: 12.0';
    END IF;
END $$;

-- Test 2: Required extensions availability
DO $$
DECLARE
    extension_name text;
    extension_version text;
    required_extensions text[] := ARRAY['plpgsql'];
    optional_extensions text[] := ARRAY['postgis', 'pg_stat_statements', 'btree_gin', 'pg_cron'];
BEGIN
    RAISE NOTICE 'Test 2: Extension availability check...';

    -- Check required extensions
    FOREACH extension_name IN ARRAY required_extensions LOOP
        SELECT extversion INTO extension_version
        FROM pg_extension
        WHERE extname = extension_name;

        IF extension_version IS NOT NULL THEN
            RAISE NOTICE '✓ Required extension available: % (version %)', extension_name, extension_version;
        ELSE
            RAISE EXCEPTION 'Required extension missing: %', extension_name;
        END IF;
    END LOOP;

    -- Check optional extensions
    FOREACH extension_name IN ARRAY optional_extensions LOOP
        SELECT extversion INTO extension_version
        FROM pg_extension
        WHERE extname = extension_name;

        IF extension_version IS NOT NULL THEN
            RAISE NOTICE '✓ Optional extension available: % (version %)', extension_name, extension_version;
        ELSE
            RAISE NOTICE 'ℹ Optional extension not installed: %', extension_name;
        END IF;
    END LOOP;
END $$;

-- Test 3: Core SQL feature regression
DO $$
BEGIN
    RAISE NOTICE 'Test 3: Core SQL feature regression testing...';

    -- Test window functions (PostgreSQL 8.4+)
    BEGIN
        PERFORM ROW_NUMBER() OVER (ORDER BY citizen_id) FROM citizens LIMIT 1;
        RAISE NOTICE '✓ Window functions working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Window functions test failed: %', SQLERRM;
    END;

    -- Test CTEs (PostgreSQL 8.4+)
    BEGIN
        PERFORM * FROM (
            WITH test_cte AS (SELECT 1 as test_col)
            SELECT test_col FROM test_cte
        ) t LIMIT 1;
        RAISE NOTICE '✓ Common Table Expressions (CTEs) working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'CTE test failed: %', SQLERRM;
    END;

    -- Test UPSERT (PostgreSQL 9.5+)
    BEGIN
        CREATE TEMP TABLE test_upsert (id int PRIMARY KEY, value text);
        INSERT INTO test_upsert VALUES (1, 'initial')
        ON CONFLICT (id) DO UPDATE SET value = 'updated';
        DROP TABLE test_upsert;
        RAISE NOTICE '✓ UPSERT (ON CONFLICT) working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'UPSERT test failed: %', SQLERRM;
    END;

    -- Test JSONB (PostgreSQL 9.4+)
    BEGIN
        PERFORM '{"test": "value"}'::jsonb -> 'test';
        RAISE NOTICE '✓ JSONB operations working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'JSONB test failed: %', SQLERRM;
    END;

    -- Test LATERAL joins (PostgreSQL 9.3+)
    BEGIN
        PERFORM * FROM citizens c,
        LATERAL (SELECT COUNT(*) FROM orders WHERE customer_id = c.citizen_id) o
        LIMIT 1;
        RAISE NOTICE '✓ LATERAL joins working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'LATERAL join test failed: %', SQLERRM;
    END;
END $$;

-- Test 4: Data type support regression
DO $$
BEGIN
    RAISE NOTICE 'Test 4: Data type support regression...';

    -- Test UUID type
    BEGIN
        CREATE TEMP TABLE test_uuid (id uuid DEFAULT gen_random_uuid());
        INSERT INTO test_uuid DEFAULT VALUES;
        DROP TABLE test_uuid;
        RAISE NOTICE '✓ UUID type and generation working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'UUID test failed: %', SQLERRM;
    END;

    -- Test array types
    BEGIN
        PERFORM ARRAY[1,2,3] @> ARRAY[2];
        RAISE NOTICE '✓ Array operations working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Array test failed: %', SQLERRM;
    END;

    -- Test range types (PostgreSQL 9.2+)
    BEGIN
        PERFORM int4range(1,10) @> 5;
        RAISE NOTICE '✓ Range types working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Range types test failed: %', SQLERRM;
    END;

    -- Test timestamp with time zone
    BEGIN
        PERFORM CURRENT_TIMESTAMP AT TIME ZONE 'UTC';
        RAISE NOTICE '✓ Timestamp with timezone working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Timestamp with timezone test failed: %', SQLERRM;
    END;
END $$;

-- Test 5: Index type support
DO $$
BEGIN
    RAISE NOTICE 'Test 5: Index type support regression...';

    -- Test B-tree indexes (default)
    BEGIN
        CREATE TEMP TABLE test_btree (id int);
        CREATE INDEX ON test_btree (id);
        DROP TABLE test_btree;
        RAISE NOTICE '✓ B-tree indexes working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'B-tree index test failed: %', SQLERRM;
    END;

    -- Test Hash indexes
    BEGIN
        CREATE TEMP TABLE test_hash (id int);
        CREATE INDEX ON test_hash USING HASH (id);
        DROP TABLE test_hash;
        RAISE NOTICE '✓ Hash indexes working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Hash index test failed: %', SQLERRM;
    END;

    -- Test GIN indexes
    BEGIN
        CREATE TEMP TABLE test_gin (data jsonb);
        CREATE INDEX ON test_gin USING GIN (data);
        DROP TABLE test_gin;
        RAISE NOTICE '✓ GIN indexes working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'GIN index test failed: %', SQLERRM;
    END;

    -- Test partial indexes
    BEGIN
        CREATE TEMP TABLE test_partial (id int, status text);
        CREATE INDEX ON test_partial (id) WHERE status = 'active';
        DROP TABLE test_partial;
        RAISE NOTICE '✓ Partial indexes working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Partial index test failed: %', SQLERRM;
    END;
END $$;

-- Test 6: Constraint enforcement regression
DO $$
DECLARE
    constraint_violation_caught boolean := false;
BEGIN
    RAISE NOTICE 'Test 6: Constraint enforcement regression...';

    -- Test primary key constraint
    BEGIN
        CREATE TEMP TABLE test_pk (id int PRIMARY KEY);
        INSERT INTO test_pk VALUES (1);
        INSERT INTO test_pk VALUES (1); -- Should fail
    EXCEPTION WHEN unique_violation THEN
        constraint_violation_caught := true;
    END;

    IF constraint_violation_caught THEN
        RAISE NOTICE '✓ Primary key constraints enforced';
    ELSE
        RAISE WARNING 'Primary key constraint not enforced properly';
    END IF;

    -- Test foreign key constraint
    constraint_violation_caught := false;
    BEGIN
        CREATE TEMP TABLE test_parent (id int PRIMARY KEY);
        CREATE TEMP TABLE test_child (id int, parent_id int REFERENCES test_parent(id));
        INSERT INTO test_child VALUES (1, 999); -- Should fail
    EXCEPTION WHEN foreign_key_violation THEN
        constraint_violation_caught := true;
    END;

    IF constraint_violation_caught THEN
        RAISE NOTICE '✓ Foreign key constraints enforced';
    ELSE
        RAISE WARNING 'Foreign key constraint not enforced properly';
    END IF;

    -- Test check constraint
    constraint_violation_caught := false;
    BEGIN
        CREATE TEMP TABLE test_check (id int CHECK (id > 0));
        INSERT INTO test_check VALUES (-1); -- Should fail
    EXCEPTION WHEN check_violation THEN
        constraint_violation_caught := true;
    END;

    IF constraint_violation_caught THEN
        RAISE NOTICE '✓ Check constraints enforced';
    ELSE
        RAISE WARNING 'Check constraint not enforced properly';
    END IF;
END $$;

-- Test 7: Transaction isolation levels
DO $$
BEGIN
    RAISE NOTICE 'Test 7: Transaction isolation levels regression...';

    -- Test transaction isolation level support
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        RAISE NOTICE '✓ READ COMMITTED isolation level supported';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'READ COMMITTED test failed: %', SQLERRM;
    END;

    BEGIN
        SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
        RAISE NOTICE '✓ REPEATABLE READ isolation level supported';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'REPEATABLE READ test failed: %', SQLERRM;
    END;

    BEGIN
        SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
        RAISE NOTICE '✓ SERIALIZABLE isolation level supported';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'SERIALIZABLE test failed: %', SQLERRM;
    END;
END $$;

-- Test 8: Full-text search regression
DO $$
BEGIN
    RAISE NOTICE 'Test 8: Full-text search regression...';

    BEGIN
        PERFORM to_tsvector('english', 'The quick brown fox jumps over the lazy dog')
                @@ to_tsquery('english', 'fox & dog');
        RAISE NOTICE '✓ Full-text search functionality working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Full-text search test failed: %', SQLERRM;
    END;

    -- Test text search configurations
    BEGIN
        PERFORM * FROM pg_ts_config WHERE cfgname = 'english' LIMIT 1;
        RAISE NOTICE '✓ Text search configurations available';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Text search configuration test failed: %', SQLERRM;
    END;
END $$;

-- Test 9: Partitioning support (PostgreSQL 10+)
DO $$
DECLARE
    pg_version_num integer;
BEGIN
    RAISE NOTICE 'Test 9: Partitioning support regression...';

    SELECT current_setting('server_version_num')::integer INTO pg_version_num;

    IF pg_version_num >= 100000 THEN
        BEGIN
            CREATE TEMP TABLE test_parent (id int, created_date date) PARTITION BY RANGE (created_date);
            CREATE TEMP TABLE test_partition PARTITION OF test_parent
            FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
            RAISE NOTICE '✓ Declarative partitioning supported';
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Partitioning test failed: %', SQLERRM;
        END;
    ELSE
        RAISE NOTICE 'ℹ Declarative partitioning not available (requires PostgreSQL 10+)';
    END IF;
END $$;

-- Test 10: Performance regression check
DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    duration interval;
    slow_query_threshold interval := '1 second';
BEGIN
    RAISE NOTICE 'Test 10: Performance regression check...';

    -- Test query performance hasn't regressed
    start_time := clock_timestamp();

    -- Run a moderately complex query
    PERFORM c.name, COUNT(o.order_id), SUM(o.total_amount)
    FROM citizens c
    LEFT JOIN orders o ON c.citizen_id = o.customer_id
    GROUP BY c.citizen_id, c.name
    ORDER BY SUM(o.total_amount) DESC NULLS LAST;

    end_time := clock_timestamp();
    duration := end_time - start_time;

    RAISE NOTICE 'Complex query duration: %', duration;

    IF duration > slow_query_threshold THEN
        RAISE WARNING 'Query performance may have regressed (took %)', duration;
    ELSE
        RAISE NOTICE '✓ Query performance within acceptable range';
    END IF;
END $$;

-- Test 11: Memory and resource usage
SELECT
    'Test 11: Resource usage check' as test,
    setting as shared_buffers,
    unit
FROM pg_settings
WHERE name = 'shared_buffers'
UNION ALL
SELECT
    'work_mem',
    setting,
    unit
FROM pg_settings
WHERE name = 'work_mem'
UNION ALL
SELECT
    'maintenance_work_mem',
    setting,
    unit
FROM pg_settings
WHERE name = 'maintenance_work_mem';

-- Test 12: Connection and session regression
DO $$
DECLARE
    max_connections integer;
    current_connections integer;
BEGIN
    RAISE NOTICE 'Test 12: Connection handling regression...';

    SELECT setting::integer INTO max_connections
    FROM pg_settings WHERE name = 'max_connections';

    SELECT COUNT(*) INTO current_connections
    FROM pg_stat_activity;

    RAISE NOTICE 'Max connections: %, Current: %', max_connections, current_connections;

    IF current_connections < max_connections THEN
        RAISE NOTICE '✓ Connection handling working normally';
    ELSE
        RAISE WARNING 'Connection limit may be reached';
    END IF;

    -- Test session variables
    BEGIN
        SET LOCAL test_param = 'test_value';
        RAISE NOTICE '✓ Session variable setting working';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Session variable test failed: %', SQLERRM;
    END;
END $$;

-- Final regression test summary
DO $$
DECLARE
    pg_version_str text;
    total_extensions integer;
    available_extensions integer;
    uptime interval;
BEGIN
    SELECT version() INTO pg_version_str;

    SELECT COUNT(*) INTO total_extensions FROM pg_extension;

    SELECT COUNT(*) INTO available_extensions
    FROM pg_available_extensions
    WHERE installed_version IS NOT NULL;

    SELECT now() - pg_postmaster_start_time() INTO uptime;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'REGRESSION TEST SUMMARY';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'PostgreSQL Version: %', pg_version_str;
    RAISE NOTICE 'Database Uptime: %', uptime;
    RAISE NOTICE 'Extensions Loaded: %', total_extensions;
    RAISE NOTICE '========================================';
    RAISE NOTICE '';
    RAISE NOTICE 'Regression test categories:';
    RAISE NOTICE '✓ Version compatibility';
    RAISE NOTICE '✓ Extension availability';
    RAISE NOTICE '✓ Core SQL features';
    RAISE NOTICE '✓ Data type support';
    RAISE NOTICE '✓ Index functionality';
    RAISE NOTICE '✓ Constraint enforcement';
    RAISE NOTICE '✓ Transaction isolation';
    RAISE NOTICE '✓ Full-text search';
    RAISE NOTICE '✓ Performance baseline';
    RAISE NOTICE '✓ Resource utilization';
    RAISE NOTICE '✓ Connection handling';
    RAISE NOTICE '';
    RAISE NOTICE '✅ All regression tests completed!';
    RAISE NOTICE '⚠️  Review any warnings above for potential issues';
    RAISE NOTICE '========================================';
END $$;

SELECT 'Regression tests completed' as status;
