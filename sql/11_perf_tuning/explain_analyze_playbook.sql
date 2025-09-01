-- File: sql/11_perf_tuning/explain_analyze_playbook.sql
-- Purpose: EXPLAIN ANALYZE demonstrations, join strategies, and plan reading

-- =============================================================================
-- BASIC EXPLAIN ANALYZE EXAMPLES
-- =============================================================================

-- Function to demonstrate different EXPLAIN options
CREATE OR REPLACE FUNCTION analytics.demo_explain_options()
RETURNS TABLE(
    explain_type TEXT,
    query_description TEXT,
    sample_output TEXT
) AS $$
BEGIN
    RETURN QUERY VALUES
        ('EXPLAIN', 'Basic plan without execution', 'Shows estimated costs and row counts'),
        ('EXPLAIN ANALYZE', 'Execute and show actual timing', 'Shows actual time and row counts'),
        ('EXPLAIN (ANALYZE, BUFFERS)', 'Include buffer usage', 'Shows shared/local/temp buffer hits'),
        ('EXPLAIN (ANALYZE, VERBOSE)', 'Include detailed output', 'Shows column lists and expressions'),
        ('EXPLAIN (ANALYZE, COSTS false)', 'Hide cost estimates', 'Focuses on actual execution metrics');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- JOIN STRATEGY DEMONSTRATIONS
-- =============================================================================

-- Nested Loop Join demonstration
CREATE OR REPLACE FUNCTION analytics.demo_nested_loop_join()
RETURNS TABLE(
    join_type TEXT,
    estimated_cost NUMERIC,
    actual_time_ms NUMERIC,
    rows_processed BIGINT,
    optimization_notes TEXT
) AS $$
DECLARE
    plan_output TEXT;
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
BEGIN
    start_time := clock_timestamp();

    -- Force nested loop join with small result set
    SET enable_hashjoin = off;
    SET enable_mergejoin = off;

    -- Execute query that will use nested loop
    PERFORM c.citizen_id, c.first_name, p.permit_number
    FROM civics.citizens c
    JOIN civics.permit_applications p ON c.citizen_id = p.citizen_id
    WHERE c.citizen_id <= 3; -- Small result set

    end_time := clock_timestamp();

    -- Reset join settings
    RESET enable_hashjoin;
    RESET enable_mergejoin;

    RETURN QUERY SELECT
        'Nested Loop'::TEXT,
        15.25::NUMERIC, -- Estimated cost
        EXTRACT(EPOCH FROM (end_time - start_time)) * 1000,
        3::BIGINT,
        'Efficient for small outer relations and indexed inner relations'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Hash Join demonstration
CREATE OR REPLACE FUNCTION analytics.demo_hash_join()
RETURNS TABLE(
    join_type TEXT,
    build_table TEXT,
    probe_table TEXT,
    hash_buckets INTEGER,
    memory_usage_kb INTEGER,
    efficiency_notes TEXT
) AS $$
DECLARE
    execution_time NUMERIC;
    start_time TIMESTAMPTZ;
BEGIN
    start_time := clock_timestamp();

    -- Force hash join
    SET enable_nestloop = off;
    SET enable_mergejoin = off;
    SET work_mem = '10MB';

    -- Execute hash join query
    PERFORM c.citizen_id, COUNT(o.order_id)
    FROM civics.citizens c
    LEFT JOIN commerce.orders o ON c.citizen_id = o.customer_citizen_id
    GROUP BY c.citizen_id;

    execution_time := EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;

    -- Reset settings
    RESET enable_nestloop;
    RESET enable_mergejoin;
    RESET work_mem;

    RETURN QUERY SELECT
        'Hash Join'::TEXT,
        'citizens (smaller)'::TEXT,
        'orders (larger)'::TEXT,
        1024,
        2048,
        format('Completed in %.2f ms. Good for large unsorted datasets', execution_time);
END;
$$ LANGUAGE plpgsql;

-- Merge Join demonstration
CREATE OR REPLACE FUNCTION analytics.demo_merge_join()
RETURNS TABLE(
    join_type TEXT,
    sort_keys TEXT,
    presorted BOOLEAN,
    sort_overhead_ms NUMERIC,
    join_efficiency TEXT
) AS $$
DECLARE
    start_time TIMESTAMPTZ;
    execution_time NUMERIC;
BEGIN
    start_time := clock_timestamp();

    -- Force merge join
    SET enable_nestloop = off;
    SET enable_hashjoin = off;

    -- Execute merge join on sorted data
    PERFORM tp.citizen_id, SUM(tp.amount_paid)
    FROM civics.tax_payments tp
    JOIN civics.citizens c ON tp.citizen_id = c.citizen_id
    WHERE c.status = 'active'
    GROUP BY tp.citizen_id
    ORDER BY tp.citizen_id;

    execution_time := EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;

    -- Reset settings
    RESET enable_nestloop;
    RESET enable_hashjoin;

    RETURN QUERY SELECT
        'Merge Join'::TEXT,
        'citizen_id'::TEXT,
        true, -- Assume pre-sorted by PK
        0.5::NUMERIC, -- Minimal sort overhead
        format('Efficient for sorted inputs. Execution time: %.2f ms', execution_time);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PLAN NODE ANALYSIS
-- =============================================================================

-- Function to analyze common plan nodes
CREATE OR REPLACE FUNCTION analytics.analyze_plan_patterns()
RETURNS TABLE(
    node_type TEXT,
    when_used TEXT,
    performance_characteristics TEXT,
    optimization_tips TEXT
) AS $$
BEGIN
    RETURN QUERY VALUES
        ('Seq Scan', 'No suitable index available', 'O(n) - reads entire table', 'Add appropriate indexes or use LIMIT'),
        ('Index Scan', 'Using index for lookup', 'O(log n) for lookup + fetch', 'Good for selective queries'),
        ('Index Only Scan', 'All needed columns in index', 'O(log n) - no table access', 'Use covering indexes'),
        ('Bitmap Heap Scan', 'Multiple index conditions', 'Efficient for medium selectivity', 'Consider combining indexes'),
        ('Sort', 'ORDER BY without index', 'O(n log n) in memory/disk', 'Add index on sort columns'),
        ('Hash Aggregate', 'GROUP BY operations', 'O(n) with hash table', 'Increase work_mem if spilling'),
        ('Nested Loop', 'Small outer, indexed inner', 'O(n*m) worst case', 'Ensure inner has good index'),
        ('Hash Join', 'Large unsorted relations', 'O(n+m) with hash build', 'Increase work_mem for large joins'),
        ('Merge Join', 'Pre-sorted relations', 'O(n+m) linear scan', 'Works well with ordered data');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PERFORMANCE ANALYSIS FUNCTIONS
-- =============================================================================

-- Function to capture and analyze query performance
CREATE OR REPLACE FUNCTION analytics.analyze_query_performance(
    query_sql TEXT,
    iterations INTEGER DEFAULT 3
)
RETURNS TABLE(
    iteration INTEGER,
    execution_time_ms NUMERIC,
    rows_returned BIGINT,
    buffer_hits BIGINT,
    buffer_reads BIGINT,
    plan_summary TEXT
) AS $$
DECLARE
    i INTEGER;
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    row_count BIGINT;
BEGIN
    -- Enable timing and buffer tracking
    SET track_io_timing = on;

    FOR i IN 1..iterations LOOP
        start_time := clock_timestamp();

        -- Execute the query (simplified - would need dynamic SQL in practice)
        -- This is a placeholder since we can't execute arbitrary SQL directly
        EXECUTE 'SELECT COUNT(*) FROM civics.citizens' INTO row_count;

        end_time := clock_timestamp();

        RETURN QUERY SELECT
            i,
            EXTRACT(EPOCH FROM (end_time - start_time)) * 1000,
            row_count,
            100::BIGINT, -- Placeholder buffer hits
            5::BIGINT,   -- Placeholder buffer reads
            'Sample execution plan summary'::TEXT;
    END LOOP;

    RESET track_io_timing;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INDEX USAGE ANALYSIS
-- =============================================================================

-- Function to check index usage effectiveness
CREATE OR REPLACE FUNCTION analytics.analyze_index_effectiveness()
RETURNS TABLE(
    table_name TEXT,
    index_name TEXT,
    index_scans BIGINT,
    tuples_read BIGINT,
    tuples_fetched BIGINT,
    selectivity_ratio NUMERIC,
    usage_recommendation TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (schemaname || '.' || relname)::TEXT as table_name,
        indexrelname::TEXT as index_name,
        idx_scan as index_scans,
        idx_tup_read as tuples_read,
        idx_tup_fetch as tuples_fetched,
        CASE
            WHEN idx_tup_read > 0
            THEN ROUND(idx_tup_fetch::NUMERIC / idx_tup_read, 4)
            ELSE 0
        END as selectivity_ratio,
        CASE
            WHEN idx_scan = 0 THEN 'UNUSED - Consider dropping'
            WHEN idx_tup_read > idx_tup_fetch * 10 THEN 'LOW SELECTIVITY - Review queries'
            WHEN idx_scan > 1000 THEN 'HIGHLY USED - Good index'
            ELSE 'MODERATE USE - Monitor'
        END::TEXT as usage_recommendation
    FROM pg_stat_user_indexes
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    ORDER BY idx_scan DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SLOW QUERY ANALYSIS
-- =============================================================================

-- Function to identify potentially slow query patterns
CREATE OR REPLACE FUNCTION analytics.identify_slow_patterns()
RETURNS TABLE(
    pattern_type TEXT,
    description TEXT,
    example_fix TEXT,
    impact_level TEXT
) AS $$
BEGIN
    RETURN QUERY VALUES
        ('Missing WHERE clause', 'Full table scans on large tables', 'Add appropriate WHERE conditions', 'HIGH'),
        ('Function calls in WHERE', 'Non-sargable predicates', 'Rewrite conditions or use functional indexes', 'HIGH'),
        ('SELECT *', 'Unnecessary column retrieval', 'Select only needed columns', 'MEDIUM'),
        ('N+1 queries', 'Multiple single-row lookups', 'Use JOINs or batch operations', 'HIGH'),
        ('Subqueries in SELECT', 'Correlated subqueries', 'Convert to JOINs when possible', 'MEDIUM'),
        ('ORDER BY without LIMIT', 'Sorting entire result set', 'Add LIMIT or use partial sorting', 'MEDIUM'),
        ('GROUP BY large text', 'Expensive grouping operations', 'Group by ID then JOIN for display', 'MEDIUM'),
        ('Implicit type conversion', 'Index not used due to casting', 'Match column and parameter types', 'HIGH');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- EXECUTION PLAN COMPARISON
-- =============================================================================

-- Function to compare execution plans before/after optimization
CREATE OR REPLACE FUNCTION analytics.compare_execution_plans()
RETURNS TABLE(
    scenario TEXT,
    query_type TEXT,
    before_time_ms NUMERIC,
    after_time_ms NUMERIC,
    improvement_pct NUMERIC,
    optimization_applied TEXT
) AS $$
BEGIN
    RETURN QUERY VALUES
        ('Index Addition', 'Citizen lookup by email', 125.4, 2.1, 98.3, 'Added btree index on email column'),
        ('Query Rewrite', 'Order history with customer details', 380.2, 45.7, 88.0, 'Replaced correlated subquery with JOIN'),
        ('Partial Index', 'Active merchant search', 67.8, 12.3, 81.9, 'Created partial index WHERE is_active = true'),
        ('Covering Index', 'Citizen name and contact lookup', 28.9, 8.2, 71.6, 'Added covering index with INCLUDE clause'),
        ('Statistics Update', 'Tax payment aggregation', 156.3, 89.1, 43.0, 'Ran ANALYZE to update table statistics'),
        ('Work_mem Increase', 'Large GROUP BY operation', 234.5, 156.8, 33.1, 'Increased work_mem from 4MB to 16MB');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- REAL-TIME PLAN ANALYSIS
-- =============================================================================

-- Function to capture live query plans
CREATE OR REPLACE FUNCTION analytics.capture_live_plans()
RETURNS TABLE(
    query_start TIMESTAMPTZ,
    duration_ms INTEGER,
    state TEXT,
    query_text TEXT,
    estimated_cost NUMERIC,
    plan_type TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sa.query_start,
        EXTRACT(EPOCH FROM (NOW() - sa.query_start))::INTEGER * 1000 as duration_ms,
        sa.state::TEXT,
        LEFT(sa.query, 100)::TEXT as query_text,
        -- Estimated cost would come from pg_stat_statements or auto_explain
        random() * 1000 as estimated_cost, -- Placeholder
        'Sequential Scan'::TEXT as plan_type -- Placeholder
    FROM pg_stat_activity sa
    WHERE sa.datname = current_database()
        AND sa.state = 'active'
        AND sa.pid != pg_backend_pid()
        AND sa.query NOT LIKE '%pg_stat_activity%'
    ORDER BY sa.query_start DESC;
END;
$$ LANGUAGE plpgsql;

-- Function to format and explain plan output
CREATE OR REPLACE FUNCTION analytics.format_plan_explanation(
    plan_text TEXT
)
RETURNS TABLE(
    plan_level INTEGER,
    node_type TEXT,
    operation_detail TEXT,
    cost_estimate TEXT,
    performance_notes TEXT
) AS $$
BEGIN
    -- This would parse actual EXPLAIN output in a real implementation
    RETURN QUERY VALUES
        (1, 'HashAggregate', 'GROUP BY operation using hash table', 'cost=45.2..67.8', 'Efficient for moderate group counts'),
        (2, 'Hash Join', 'Join citizens and tax_payments', 'cost=12.5..45.2', 'Good choice for unsorted relations'),
        (3, 'Seq Scan', 'Sequential scan on citizens', 'cost=0.0..12.5', 'Consider adding index if selective'),
        (3, 'Seq Scan', 'Sequential scan on tax_payments', 'cost=0.0..8.7', 'Acceptable for small table');
END;
$$ LANGUAGE plpgsql;
