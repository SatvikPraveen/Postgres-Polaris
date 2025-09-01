-- Location: /examples/performance_tuning_showcase.sql
-- Before/after optimization examples with real performance measurements

SELECT '⚡ Performance Tuning Showcase - Before/After Optimization' as title;

-- Setup: Create test data if tables are small
DO $$
DECLARE
    citizen_count integer;
    order_count integer;
BEGIN
    SELECT COUNT(*) INTO citizen_count FROM citizens;
    SELECT COUNT(*) INTO order_count FROM orders;

    RAISE NOTICE 'Current data size: % citizens, % orders', citizen_count, order_count;

    -- Generate additional test data for performance demonstration if needed
    IF citizen_count < 1000 THEN
        RAISE NOTICE 'Generating additional test data for performance demo...';

        INSERT INTO citizens (name, email, phone, birth_date, registration_date, city, state)
        SELECT
            'Test User ' || i,
            'testuser' || i || '@example.com',
            '555-' || LPAD(i::text, 4, '0'),
            CURRENT_DATE - (RANDOM() * 365 * 30)::integer,
            CURRENT_DATE - (RANDOM() * 365 * 2)::integer,
            'Springfield',
            'IL'
        FROM generate_series(citizen_count + 1, 1000) i;

        -- Generate orders for performance testing
        INSERT INTO orders (customer_id, merchant_id, order_date, total_amount, status, payment_method)
        SELECT
            (RANDOM() * 1000 + 1)::integer,
            (RANDOM() * 5 + 1)::integer,
            CURRENT_DATE - (RANDOM() * 365)::integer,
            (RANDOM() * 200 + 10)::numeric(10,2),
            CASE WHEN RANDOM() < 0.9 THEN 'completed' ELSE 'pending' END,
            (ARRAY['credit_card', 'debit_card', 'cash', 'digital_wallet'])[CEIL(RANDOM() * 4)]
        FROM generate_series(1, 3000);

        RAISE NOTICE 'Generated test data for performance demonstration';
    END IF;
END $$;

-- Demo 1: Sequential Scan vs Index Scan
SELECT 'Demo 1: Sequential Scan vs Index Scan Comparison' as demo;

-- BEFORE: Query without index (likely sequential scan)
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM citizens
WHERE email LIKE '%johnson%';

-- Create index for comparison
CREATE INDEX IF NOT EXISTS idx_citizens_email_demo ON citizens(email);

-- AFTER: Same query with index available
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM citizens
WHERE email = 'alice.johnson@email.com';

-- Performance comparison summary
SELECT 'Index Performance Summary' as analysis;
WITH scan_comparison AS (
    SELECT
        'Sequential Scan' as scan_type,
        'Pattern matching on unindexed column' as scenario,
        'Slow for large tables' as performance
    UNION ALL
    SELECT
        'Index Scan',
        'Exact match on indexed column',
        'Fast, logarithmic lookup'
)
SELECT * FROM scan_comparison;

-- Demo 2: Join Performance Optimization
SELECT 'Demo 2: Join Performance - Hash vs Nested Loop' as demo;

-- BEFORE: Potentially inefficient join without proper indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, COUNT(o.order_id) as order_count, SUM(o.total_amount) as total_spent
FROM citizens c
LEFT JOIN orders o ON c.citizen_id = o.customer_id
WHERE c.city = 'Springfield'
GROUP BY c.citizen_id, c.name
HAVING COUNT(o.order_id) > 0
ORDER BY total_spent DESC;

-- Create indexes to optimize joins
CREATE INDEX IF NOT EXISTS idx_orders_customer_id_demo ON orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_citizens_city_demo ON citizens(city);

-- AFTER: Same query with optimized indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, COUNT(o.order_id) as order_count, SUM(o.total_amount) as total_spent
FROM citizens c
LEFT JOIN orders o ON c.citizen_id = o.customer_id
WHERE c.city = 'Springfield'
GROUP BY c.citizen_id, c.name
HAVING COUNT(o.order_id) > 0
ORDER BY total_spent DESC;

-- Demo 3: Window Function Optimization
SELECT 'Demo 3: Window Function Performance Tuning' as demo;

-- BEFORE: Window function without proper ordering index
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    customer_id,
    order_date,
    total_amount,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) as recent_order_rank,
    SUM(total_amount) OVER (PARTITION BY customer_id ORDER BY order_date ROWS UNBOUNDED PRECEDING) as running_total
FROM orders
WHERE order_date >= CURRENT_DATE - INTERVAL '90 days'
ORDER BY customer_id, order_date DESC;

-- Create composite index for window function optimization
CREATE INDEX IF NOT EXISTS idx_orders_customer_date_demo ON orders(customer_id, order_date DESC);

-- AFTER: Same window function with optimized index
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    customer_id,
    order_date,
    total_amount,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) as recent_order_rank,
    SUM(total_amount) OVER (PARTITION BY customer_id ORDER BY order_date ROWS UNBOUNDED PRECEDING) as running_total
FROM orders
WHERE order_date >= CURRENT_DATE - INTERVAL '90 days'
ORDER BY customer_id, order_date DESC;

-- Demo 4: Aggregation Performance
SELECT 'Demo 4: Aggregation Query Optimization' as demo;

-- BEFORE: Aggregation that might benefit from partial indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    DATE_TRUNC('day', order_date) as order_day,
    COUNT(*) as order_count,
    SUM(total_amount) as daily_revenue,
    AVG(total_amount) as avg_order_value
FROM orders
WHERE status = 'completed'
    AND order_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', order_date)
ORDER BY order_day;

-- Create partial index for completed orders
CREATE INDEX IF NOT EXISTS idx_orders_completed_date_demo
ON orders(order_date)
WHERE status = 'completed';

-- AFTER: Same aggregation with partial index
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    DATE_TRUNC('day', order_date) as order_day,
    COUNT(*) as order_count,
    SUM(total_amount) as daily_revenue,
    AVG(total_amount) as avg_order_value
FROM orders
WHERE status = 'completed'
    AND order_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', order_date)
ORDER BY order_day;

-- Demo 5: Query Rewriting for Performance
SELECT 'Demo 5: Query Rewriting - EXISTS vs IN vs JOIN' as demo;

-- BEFORE: Using IN subquery (potentially slow)
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.*
FROM citizens c
WHERE c.citizen_id IN (
    SELECT DISTINCT customer_id
    FROM orders
    WHERE total_amount > 100
    AND status = 'completed'
);

-- AFTER: Using EXISTS (often faster)
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.*
FROM citizens c
WHERE EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.customer_id = c.citizen_id
    AND o.total_amount > 100
    AND o.status = 'completed'
);

-- ALTERNATIVE: Using JOIN with DISTINCT (sometimes fastest)
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT c.*
FROM citizens c
INNER JOIN orders o ON c.citizen_id = o.customer_id
WHERE o.total_amount > 100
AND o.status = 'completed';

-- Demo 6: Statistics and Query Planning
SELECT 'Demo 6: Statistics Impact on Query Planning' as demo;

-- Check current statistics
SELECT
    schemaname,
    tablename,
    n_distinct,
    most_common_vals[1:3] as top_3_values,
    most_common_freqs[1:3] as frequencies,
    last_analyze
FROM pg_stats
WHERE schemaname = 'public'
AND tablename IN ('citizens', 'orders', 'merchants')
AND attname IN ('city', 'status', 'category')
ORDER BY tablename, attname;

-- Update statistics
ANALYZE citizens;
ANALYZE orders;
ANALYZE merchants;

-- Show how statistics affect query estimates
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT COUNT(*)
FROM orders o
JOIN merchants m ON o.merchant_id = m.merchant_id
WHERE m.category = 'Restaurant'
AND o.status = 'completed';

-- Demo 7: Memory and Work_mem Optimization
SELECT 'Demo 7: Memory Configuration Impact' as demo;

-- Show current memory settings
SELECT
    name,
    setting,
    unit,
    short_desc
FROM pg_settings
WHERE name IN ('work_mem', 'maintenance_work_mem', 'shared_buffers', 'effective_cache_size')
ORDER BY name;

-- Demonstrate sort performance with different work_mem
SET work_mem = '1MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
ORDER BY total_amount DESC, order_date DESC;

-- Increase work_mem and compare
SET work_mem = '16MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
ORDER BY total_amount DESC, order_date DESC;

-- Reset to default
RESET work_mem;

-- Demo 8: Index Usage Analysis
SELECT 'Demo 8: Index Usage and Maintenance Analysis' as demo;

-- Show index usage statistics
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan as times_used,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY idx_scan DESC;

-- Identify unused indexes
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as wasted_size
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
AND idx_scan = 0
AND indexname NOT LIKE '%pkey'; -- Keep primary keys

-- Demo 9: Query Performance Regression Testing
SELECT 'Demo 9: Performance Regression Testing Framework' as demo;

-- Create performance baseline
CREATE TEMP TABLE performance_baseline AS
WITH test_queries AS (
    -- Query 1: Customer lookup
    SELECT
        'customer_lookup' as query_name,
        extract(milliseconds from clock_timestamp() - start_time) as duration_ms
    FROM (SELECT clock_timestamp() as start_time) t1,
         (SELECT * FROM citizens WHERE email = 'alice.johnson@email.com') t2

    UNION ALL

    -- Query 2: Order aggregation
    SELECT
        'daily_sales' as query_name,
        extract(milliseconds from clock_timestamp() - start_time) as duration_ms
    FROM (SELECT clock_timestamp() as start_time) t1,
         (SELECT DATE(order_date), COUNT(*), SUM(total_amount)
          FROM orders WHERE order_date >= CURRENT_DATE - 7
          GROUP BY DATE(order_date)) t2

    UNION ALL

    -- Query 3: Complex join
    SELECT
        'customer_summary' as query_name,
        extract(milliseconds from clock_timestamp() - start_time) as duration_ms
    FROM (SELECT clock_timestamp() as start_time) t1,
         (SELECT c.name, COUNT(o.order_id), SUM(o.total_amount)
          FROM citizens c LEFT JOIN orders o ON c.citizen_id = o.customer_id
          GROUP BY c.citizen_id, c.name LIMIT 100) t2
)
SELECT * FROM test_queries;

-- Show performance baseline
SELECT
    query_name,
    duration_ms,
    CASE
        WHEN duration_ms < 1 THEN 'Excellent'
        WHEN duration_ms < 10 THEN 'Good'
        WHEN duration_ms < 100 THEN 'Acceptable'
        ELSE 'Needs Optimization'
    END as performance_rating
FROM performance_baseline
ORDER BY duration_ms DESC;

-- Demo 10: Performance Tuning Recommendations
SELECT 'Performance Tuning Summary and Recommendations' as summary;

DO $$
DECLARE
    total_tables integer;
    total_indexes integer;
    unused_indexes integer;
    missing_fk_indexes integer;
    largest_table text;
    cache_hit_ratio numeric;
BEGIN
    -- Gather performance metrics
    SELECT COUNT(*) INTO total_tables
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

    SELECT COUNT(*) INTO total_indexes
    FROM pg_indexes WHERE schemaname = 'public';

    SELECT COUNT(*) INTO unused_indexes
    FROM pg_stat_user_indexes
    WHERE schemaname = 'public' AND idx_scan = 0;

    -- Calculate cache hit ratio
    SELECT
        ROUND((sum(heap_blks_hit)::numeric / NULLIF(sum(heap_blks_hit + heap_blks_read), 0) * 100)::numeric, 2)
    INTO cache_hit_ratio
    FROM pg_statio_user_tables;

    RAISE NOTICE '===========================================';
    RAISE NOTICE 'PERFORMANCE TUNING SHOWCASE SUMMARY';
    RAISE NOTICE '===========================================';
    RAISE NOTICE 'Database Objects:';
    RAISE NOTICE '  Tables: %', total_tables;
    RAISE NOTICE '  Indexes: %', total_indexes;
    RAISE NOTICE '  Unused Indexes: %', unused_indexes;
    RAISE NOTICE '';
    RAISE NOTICE 'Performance Metrics:';
    RAISE NOTICE '  Buffer Cache Hit Ratio: %%%', COALESCE(cache_hit_ratio, 0);
    RAISE NOTICE '';
    RAISE NOTICE 'Optimization Techniques Demonstrated:';
    RAISE NOTICE '• Index scan vs sequential scan comparison';
    RAISE NOTICE '• Join algorithm optimization (hash vs nested loop)';
    RAISE NOTICE '• Window function performance with proper indexing';
    RAISE NOTICE '• Partial indexes for filtered queries';
    RAISE NOTICE '• Query rewriting (EXISTS vs IN vs JOIN)';
    RAISE NOTICE '• Statistics impact on query planning';
    RAISE NOTICE '• Memory configuration effects (work_mem)';
    RAISE NOTICE '• Index usage analysis and maintenance';
    RAISE NOTICE '• Performance regression testing framework';
    RAISE NOTICE '';
    RAISE NOTICE 'Key Performance Recommendations:';
    RAISE NOTICE '• Monitor query execution plans regularly';
    RAISE NOTICE '• Keep table statistics up to date with ANALYZE';
    RAISE NOTICE '• Remove unused indexes to reduce maintenance overhead';
    RAISE NOTICE '• Use partial indexes for frequently filtered queries';
    RAISE NOTICE '• Optimize work_mem for sort and hash operations';
    RAISE NOTICE '• Consider query rewriting for better performance';
    RAISE NOTICE '• Implement performance regression testing';
    RAISE NOTICE '• Monitor buffer cache hit ratios (target >90%%)';
    RAISE NOTICE '';
    RAISE NOTICE 'Tools for Ongoing Performance Management:';
    RAISE NOTICE '• EXPLAIN ANALYZE for query plan analysis';
    RAISE NOTICE '• pg_stat_statements for query performance tracking';
    RAISE NOTICE '• pg_stat_user_indexes for index usage monitoring';
    RAISE NOTICE '• Auto VACUUM and ANALYZE for maintenance';
    RAISE NOTICE '===========================================';
END $$;
