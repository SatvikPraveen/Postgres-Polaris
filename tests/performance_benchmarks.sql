-- Location: /tests/performance_benchmarks.sql
-- Standard queries with expected plan types and performance targets

\set ON_ERROR_STOP on
\timing on

-- Performance test configuration
SELECT 'Starting performance benchmarks...' as status;

-- Warm up cache
SELECT 'Warming up cache...' as status;
SELECT COUNT(*) FROM citizens;
SELECT COUNT(*) FROM merchants;
SELECT COUNT(*) FROM orders;
SELECT COUNT(*) FROM trips;

-- Test 1: Simple primary key lookup (Target: <1ms)
\echo 'Test 1: Primary key lookup performance'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM citizens WHERE citizen_id = 1;

-- Test 2: Email lookup (should use index if available)
\echo 'Test 2: Email lookup performance'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM citizens WHERE email = 'alice.johnson@email.com';

-- Test 3: Range query on dates (Target: <10ms)
\echo 'Test 3: Date range query performance'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
WHERE order_date >= '2024-01-01'
AND order_date < '2024-02-01';

-- Test 4: Simple join performance (Target: <50ms)
\echo 'Test 4: Two-table join performance'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, o.total_amount, o.order_date
FROM citizens c
JOIN orders o ON c.citizen_id = o.customer_id
WHERE o.order_date >= '2024-01-01'
LIMIT 100;

-- Test 5: Aggregation query (Target: <100ms)
\echo 'Test 5: Aggregation performance'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    COUNT(*) as order_count,
    SUM(total_amount) as total_revenue,
    AVG(total_amount) as avg_order_value
FROM orders
WHERE status = 'completed';

-- Test 6: Complex join with grouping (Target: <200ms)
\echo 'Test 6: Complex aggregation with joins'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    m.category,
    COUNT(o.order_id) as order_count,
    SUM(o.total_amount) as revenue,
    AVG(o.total_amount) as avg_order
FROM merchants m
JOIN orders o ON m.merchant_id = o.merchant_id
WHERE o.status = 'completed'
GROUP BY m.category
ORDER BY revenue DESC;

-- Test 7: Text search performance (if full-text search available)
\echo 'Test 7: Text search performance'
BEGIN;
-- Try different search approaches
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM citizens WHERE name ILIKE '%johnson%';

-- If documents table exists with JSONB
DO $$
BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'documents') THEN
        PERFORM 1 FROM (
            EXPLAIN (ANALYZE, BUFFERS)
            SELECT * FROM documents
            WHERE data->>'type' = 'complaint'
            LIMIT 10
        ) as x;
    END IF;
END $$;
ROLLBACK;

-- Test 8: Window function performance
\echo 'Test 8: Window function performance'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    customer_id,
    order_date,
    total_amount,
    SUM(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY order_date
        ROWS UNBOUNDED PRECEDING
    ) as running_total
FROM orders
ORDER BY customer_id, order_date;

-- Test 9: Subquery performance
\echo 'Test 9: Subquery vs JOIN performance'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.*
FROM citizens c
WHERE EXISTS (
    SELECT 1 FROM orders o
    WHERE o.customer_id = c.citizen_id
    AND o.total_amount > 100
);

-- Alternative with JOIN for comparison
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT c.*
FROM citizens c
JOIN orders o ON c.citizen_id = o.customer_id
WHERE o.total_amount > 100;

-- Test 10: Spatial query performance (if PostGIS available)
DO $$
DECLARE
    postgis_available boolean;
BEGIN
    SELECT EXISTS (SELECT FROM pg_extension WHERE extname = 'postgis') INTO postgis_available;

    IF postgis_available THEN
        RAISE NOTICE 'Test 10: Spatial query performance';

        -- Check if spatial table exists
        IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'spatial_features') THEN
            PERFORM 1 FROM (
                EXPLAIN (ANALYZE, BUFFERS)
                SELECT * FROM spatial_features
                WHERE ST_DWithin(
                    geometry,
                    ST_GeomFromText('POINT(-89.65 39.78)', 4326),
                    0.01
                )
            ) as x;
        ELSE
            RAISE NOTICE 'No spatial tables found for spatial performance test';
        END IF;
    ELSE
        RAISE NOTICE 'PostGIS not available - skipping spatial performance test';
    END IF;
END $$;

-- Performance analysis and recommendations
\echo 'Performance Analysis Summary'

-- Show slow queries from pg_stat_statements if available
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RAISE NOTICE 'Top 5 slowest queries (if statistics available):';
        FOR rec IN
            SELECT
                ROUND(mean_exec_time::numeric, 2) as avg_time_ms,
                calls,
                LEFT(query, 60) as query_snippet
            FROM pg_stat_statements
            WHERE calls > 1
            ORDER BY mean_exec_time DESC
            LIMIT 5
        LOOP
            RAISE NOTICE '  %.2f ms (% calls): %...', rec.avg_time_ms, rec.calls, rec.query_snippet;
        END LOOP;
    ELSE
        RAISE NOTICE 'pg_stat_statements extension not available';
    END IF;
END $$;

-- Index usage analysis
SELECT
    'Index Usage Analysis' as analysis_type,
    schemaname,
    tablename,
    indexname,
    idx_scan as scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    CASE
        WHEN idx_scan = 0 THEN 'UNUSED'
        WHEN idx_scan < 10 THEN 'LOW_USAGE'
        ELSE 'ACTIVE'
    END as usage_status
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY idx_scan DESC;

-- Table statistics
SELECT
    'Table Statistics' as analysis_type,
    schemaname,
    relname as tablename,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_tup_del as deletes,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    CASE
        WHEN n_live_tup > 0 THEN ROUND((n_dead_tup::float / n_live_tup * 100)::numeric, 1)
        ELSE 0
    END as dead_tuple_pct
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;

-- Buffer cache analysis
SELECT
    'Buffer Cache Analysis' as analysis_type,
    schemaname,
    relname,
    heap_blks_read,
    heap_blks_hit,
    CASE
        WHEN (heap_blks_hit + heap_blks_read) > 0
        THEN ROUND((heap_blks_hit::float / (heap_blks_hit + heap_blks_read) * 100)::numeric, 1)
        ELSE 0
    END as cache_hit_ratio
FROM pg_statio_user_tables
WHERE schemaname = 'public'
AND (heap_blks_hit + heap_blks_read) > 0
ORDER BY cache_hit_ratio ASC;

-- Connection and activity summary
SELECT
    'Database Activity Summary' as summary_type,
    COUNT(*) as total_connections,
    COUNT(CASE WHEN state = 'active' THEN 1 END) as active_queries,
    COUNT(CASE WHEN state = 'idle' THEN 1 END) as idle_connections,
    COUNT(CASE WHEN state = 'idle in transaction' THEN 1 END) as idle_in_transaction
FROM pg_stat_activity;

-- Performance recommendations
DO $$
DECLARE
    unused_indexes integer;
    tables_needing_vacuum integer;
    low_cache_hit_tables integer;
BEGIN
    -- Count unused indexes
    SELECT COUNT(*) INTO unused_indexes
    FROM pg_stat_user_indexes
    WHERE schemaname = 'public' AND idx_scan = 0;

    -- Count tables with high dead tuple percentage
    SELECT COUNT(*) INTO tables_needing_vacuum
    FROM pg_stat_user_tables
    WHERE schemaname = 'public'
    AND n_live_tup > 0
    AND (n_dead_tup::float / n_live_tup) > 0.1;

    -- Count tables with low cache hit ratio
    SELECT COUNT(*) INTO low_cache_hit_tables
    FROM pg_statio_user_tables
    WHERE schemaname = 'public'
    AND (heap_blks_hit + heap_blks_read) > 100
    AND (heap_blks_hit::float / (heap_blks_hit + heap_blks_read)) < 0.9;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'PERFORMANCE RECOMMENDATIONS';
    RAISE NOTICE '========================================';

    IF unused_indexes > 0 THEN
        RAISE NOTICE '⚠️  Consider dropping % unused indexes', unused_indexes;
    ELSE
        RAISE NOTICE '✓ All indexes are being used';
    END IF;

    IF tables_needing_vacuum > 0 THEN
        RAISE NOTICE '⚠️  Consider VACUUM ANALYZE on % tables with high dead tuple ratio', tables_needing_vacuum;
    ELSE
        RAISE NOTICE '✓ Tables have acceptable dead tuple ratios';
    END IF;

    IF low_cache_hit_tables > 0 THEN
        RAISE NOTICE '⚠️  % tables have low cache hit ratios - consider more memory or better indexes', low_cache_hit_tables;
    ELSE
        RAISE NOTICE '✓ Good cache hit ratios across all tables';
    END IF;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'General recommendations:';
    RAISE NOTICE '• Run ANALYZE regularly to update query planner statistics';
    RAISE NOTICE '• Monitor pg_stat_statements for slow queries';
    RAISE NOTICE '• Consider partitioning for large time-series tables';
    RAISE NOTICE '• Add indexes for frequently filtered columns';
    RAISE NOTICE '• Use EXPLAIN ANALYZE to verify query performance';
    RAISE NOTICE '========================================';
END $$;

-- Performance target validation
DO $$
DECLARE
    current_db_size text;
    shared_buffers text;
    work_mem text;
    effective_cache_size text;
BEGIN
    -- Get current database size
    SELECT pg_size_pretty(pg_database_size(current_database())) INTO current_db_size;

    -- Get key configuration parameters
    SELECT setting FROM pg_settings WHERE name = 'shared_buffers' INTO shared_buffers;
    SELECT setting FROM pg_settings WHERE name = 'work_mem' INTO work_mem;
    SELECT setting FROM pg_settings WHERE name = 'effective_cache_size' INTO effective_cache_size;

    RAISE NOTICE 'Database Configuration:';
    RAISE NOTICE '  Database size: %', current_db_size;
    RAISE NOTICE '  shared_buffers: %', shared_buffers;
    RAISE NOTICE '  work_mem: %', work_mem;
    RAISE NOTICE '  effective_cache_size: %', effective_cache_size;
    RAISE NOTICE '';
    RAISE NOTICE 'Performance Targets:';
    RAISE NOTICE '  • Primary key lookups: <1ms';
    RAISE NOTICE '  • Indexed searches: <10ms';
    RAISE NOTICE '  • Simple joins: <50ms';
    RAISE NOTICE '  • Complex aggregations: <200ms';
    RAISE NOTICE '  • Cache hit ratio: >90%%';
    RAISE NOTICE '';
    RAISE NOTICE '✅ Performance benchmark completed!';
    RAISE NOTICE '📊 Review EXPLAIN ANALYZE output above for detailed timing';
END $$;

SELECT 'Performance benchmarks completed' as status;
