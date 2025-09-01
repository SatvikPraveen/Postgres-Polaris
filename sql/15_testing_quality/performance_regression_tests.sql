-- File: sql/15_testing_quality/performance_regression_tests.sql
-- Purpose: before/after plan comparisons for performance testing

-- =============================================================================
-- PERFORMANCE TESTING INFRASTRUCTURE
-- =============================================================================

-- Create schema for performance monitoring
CREATE SCHEMA IF NOT EXISTS performance;

-- Query performance baseline
CREATE TABLE performance.query_baselines (
    baseline_id BIGSERIAL PRIMARY KEY,
    test_name TEXT NOT NULL,
    query_text TEXT NOT NULL,
    baseline_execution_time_ms INTEGER NOT NULL,
    baseline_plan_hash TEXT,
    baseline_plan_text TEXT,
    baseline_cost NUMERIC,
    baseline_rows BIGINT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by TEXT DEFAULT current_user,
    is_active BOOLEAN DEFAULT TRUE
);

-- Performance test results
CREATE TABLE performance.test_results (
    result_id BIGSERIAL PRIMARY KEY,
    baseline_id BIGINT REFERENCES performance.query_baselines(baseline_id),
    test_name TEXT NOT NULL,
    execution_time_ms INTEGER NOT NULL,
    plan_hash TEXT,
    plan_text TEXT,
    estimated_cost NUMERIC,
    actual_rows BIGINT,
    performance_ratio NUMERIC GENERATED ALWAYS AS (
        execution_time_ms::NUMERIC / (SELECT baseline_execution_time_ms FROM performance.query_baselines qb WHERE qb.baseline_id = test_results.baseline_id)
    ) STORED,
    test_status TEXT CHECK (test_status IN ('pass', 'warning', 'fail', 'error')) DEFAULT 'pass',
    test_notes TEXT,
    executed_at TIMESTAMPTZ DEFAULT NOW()
);

-- Performance regression thresholds
CREATE TABLE performance.regression_thresholds (
    threshold_id BIGSERIAL PRIMARY KEY,
    test_category TEXT NOT NULL,
    warning_threshold NUMERIC DEFAULT 1.2, -- 20% slower = warning
    failure_threshold NUMERIC DEFAULT 2.0, -- 100% slower = failure
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- PERFORMANCE TEST UTILITIES
-- =============================================================================

-- Execute and measure query performance
CREATE OR REPLACE FUNCTION performance.measure_query_performance(
    test_name TEXT,
    query_text TEXT,
    iterations INTEGER DEFAULT 3
)
RETURNS TABLE(
    avg_execution_time_ms INTEGER,
    min_execution_time_ms INTEGER,
    max_execution_time_ms INTEGER,
    plan_hash TEXT,
    plan_text TEXT,
    estimated_cost NUMERIC,
    actual_rows BIGINT
) AS $$
DECLARE
    i INTEGER;
    start_time TIMESTAMPTZ;
    execution_time INTEGER;
    execution_times INTEGER[] := '{}';
    plan_info RECORD;
BEGIN
    -- Get query plan first
    EXECUTE 'EXPLAIN (FORMAT JSON, ANALYZE, BUFFERS) ' || query_text
    INTO plan_info;

    -- Extract plan information
    SELECT
        md5(query_text || plan_info::TEXT) as hash,
        plan_info::TEXT as plan,
        (plan_info::JSON->0->'Plan'->>'Total Cost')::NUMERIC as cost,
        (plan_info::JSON->0->'Plan'->>'Actual Rows')::BIGINT as rows
    INTO plan_hash, plan_text, estimated_cost, actual_rows;

    -- Run performance iterations
    FOR i IN 1..iterations LOOP
        start_time := clock_timestamp();
        EXECUTE query_text;
        execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;
        execution_times := execution_times || execution_time;
    END LOOP;

    -- Calculate statistics
    RETURN QUERY SELECT
        (SELECT AVG(unnest)::INTEGER FROM unnest(execution_times)) as avg_execution_time_ms,
        (SELECT MIN(unnest) FROM unnest(execution_times)) as min_execution_time_ms,
        (SELECT MAX(unnest) FROM unnest(execution_times)) as max_execution_time_ms,
        plan_hash,
        plan_text,
        estimated_cost,
        actual_rows;
END;
$$ LANGUAGE plpgsql;

-- Create performance baseline
CREATE OR REPLACE FUNCTION performance.create_baseline(
    test_name TEXT,
    query_text TEXT,
    iterations INTEGER DEFAULT 5
)
RETURNS BIGINT AS $$
DECLARE
    baseline_id BIGINT;
    perf_result RECORD;
BEGIN
    -- Measure current performance
    SELECT * INTO perf_result
    FROM performance.measure_query_performance(test_name, query_text, iterations)
    LIMIT 1;

    -- Create baseline
    INSERT INTO performance.query_baselines (
        test_name, query_text, baseline_execution_time_ms,
        baseline_plan_hash, baseline_plan_text,
        baseline_cost, baseline_rows
    ) VALUES (
        test_name, query_text, perf_result.avg_execution_time_ms,
        perf_result.plan_hash, perf_result.plan_text,
        perf_result.estimated_cost, perf_result.actual_rows
    ) RETURNING query_baselines.baseline_id INTO baseline_id;

    RETURN baseline_id;
END;
$$ LANGUAGE plpgsql;

-- Run performance test against baseline
CREATE OR REPLACE FUNCTION performance.run_performance_test(
    test_name TEXT,
    iterations INTEGER DEFAULT 3
)
RETURNS TABLE(
    result_id BIGINT,
    baseline_execution_ms INTEGER,
    current_execution_ms INTEGER,
    performance_ratio NUMERIC,
    test_status TEXT,
    plan_changed BOOLEAN
) AS $$
DECLARE
    baseline_record RECORD;
    perf_result RECORD;
    test_status TEXT;
    plan_changed BOOLEAN;
    warning_threshold NUMERIC := 1.2;
    failure_threshold NUMERIC := 2.0;
    result_id BIGINT;
BEGIN
    -- Get baseline
    SELECT * INTO baseline_record
    FROM performance.query_baselines
    WHERE performance.query_baselines.test_name = run_performance_test.test_name
    AND is_active = TRUE
    ORDER BY created_at DESC
    LIMIT 1;

    IF baseline_record IS NULL THEN
        RAISE EXCEPTION 'No baseline found for test: %', test_name;
    END IF;

    -- Get thresholds
    SELECT rt.warning_threshold, rt.failure_threshold
    INTO warning_threshold, failure_threshold
    FROM performance.regression_thresholds rt
    WHERE rt.test_category = 'general'
    LIMIT 1;

    -- Measure current performance
    SELECT * INTO perf_result
    FROM performance.measure_query_performance(
        test_name,
        baseline_record.query_text,
        iterations
    ) LIMIT 1;

    -- Determine test status
    IF perf_result.avg_execution_time_ms::NUMERIC / baseline_record.baseline_execution_time_ms >= failure_threshold THEN
        test_status := 'fail';
    ELSIF perf_result.avg_execution_time_ms::NUMERIC / baseline_record.baseline_execution_time_ms >= warning_threshold THEN
        test_status := 'warning';
    ELSE
        test_status := 'pass';
    END IF;

    -- Check if plan changed
    plan_changed := (perf_result.plan_hash != baseline_record.baseline_plan_hash);

    -- Record test result
    INSERT INTO performance.test_results (
        baseline_id, test_name, execution_time_ms,
        plan_hash, plan_text, estimated_cost, actual_rows,
        test_status, test_notes
    ) VALUES (
        baseline_record.baseline_id, test_name, perf_result.avg_execution_time_ms,
        perf_result.plan_hash, perf_result.plan_text,
        perf_result.estimated_cost, perf_result.actual_rows,
        test_status, CASE WHEN plan_changed THEN 'Plan changed' ELSE NULL END
    ) RETURNING test_results.result_id INTO result_id;

    RETURN QUERY SELECT
        result_id,
        baseline_record.baseline_execution_time_ms,
        perf_result.avg_execution_time_ms,
        perf_result.avg_execution_time_ms::NUMERIC / baseline_record.baseline_execution_time_ms,
        test_status,
        plan_changed;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PREDEFINED PERFORMANCE TESTS
-- =============================================================================

-- Citizen lookup performance test
CREATE OR REPLACE FUNCTION performance.test_citizen_lookup()
RETURNS VOID AS $$
BEGIN
    PERFORM performance.run_performance_test('citizen_lookup_by_email');
END;
$$ LANGUAGE plpgsql;

-- Complex analytics query test
CREATE OR REPLACE FUNCTION performance.test_analytics_queries()
RETURNS VOID AS $$
BEGIN
    PERFORM performance.run_performance_test('citizen_demographics_summary');
    PERFORM performance.run_performance_test('permit_trend_analysis');
    PERFORM performance.run_performance_test('commerce_performance_summary');
END;
$$ LANGUAGE plpgsql;

-- Join performance tests
CREATE OR REPLACE FUNCTION performance.test_join_performance()
RETURNS VOID AS $$
BEGIN
    PERFORM performance.run_performance_test('citizen_permit_join');
    PERFORM performance.run_performance_test('merchant_order_join');
    PERFORM performance.run_performance_test('multi_table_analytics_join');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PERFORMANCE TEST SETUP
-- =============================================================================

-- Setup standard performance test baselines
CREATE OR REPLACE FUNCTION performance.setup_performance_baselines()
RETURNS TEXT AS $$
DECLARE
    baseline_count INTEGER := 0;
    result_msg TEXT;
BEGIN
    -- Citizen lookup by email
    PERFORM performance.create_baseline(
        'citizen_lookup_by_email',
        'SELECT * FROM civics.citizens WHERE email = ''john.doe@email.com'' LIMIT 1'
    );
    baseline_count := baseline_count + 1;

    -- Citizen demographics summary
    PERFORM performance.create_baseline(
        'citizen_demographics_summary',
        'SELECT
            city,
            COUNT(*) as citizen_count,
            AVG(EXTRACT(year FROM age(date_of_birth))) as avg_age,
            COUNT(*) FILTER (WHERE status = ''active'') as active_count
        FROM civics.citizens
        WHERE status IN (''active'', ''inactive'')
        GROUP BY city
        ORDER BY citizen_count DESC'
    );
    baseline_count := baseline_count + 1;

    -- Permit trend analysis
    PERFORM performance.create_baseline(
        'permit_trend_analysis',
        'SELECT
            DATE_TRUNC(''month'', submitted_date) as month,
            permit_type,
            COUNT(*) as applications,
            COUNT(*) FILTER (WHERE status = ''approved'') as approved,
            AVG(estimated_cost) as avg_cost
        FROM civics.permit_applications
        WHERE submitted_date >= CURRENT_DATE - INTERVAL ''1 year''
        GROUP BY DATE_TRUNC(''month'', submitted_date), permit_type
        ORDER BY month DESC, applications DESC'
    );
    baseline_count := baseline_count + 1;

    -- Commerce performance summary
    PERFORM performance.create_baseline(
        'commerce_performance_summary',
        'SELECT
            m.business_name,
            COUNT(o.order_id) as total_orders,
            SUM(o.total_amount) as total_revenue,
            AVG(o.total_amount) as avg_order_value
        FROM commerce.merchants m
        LEFT JOIN commerce.orders o ON m.merchant_id = o.merchant_id
        WHERE o.order_date >= CURRENT_DATE - INTERVAL ''3 months''
        GROUP BY m.merchant_id, m.business_name
        ORDER BY total_revenue DESC NULLS LAST'
    );
    baseline_count := baseline_count + 1;

    -- Citizen-permit join
    PERFORM performance.create_baseline(
        'citizen_permit_join',
        'SELECT
            c.first_name, c.last_name, c.city,
            COUNT(pa.application_id) as permit_count,
            SUM(pa.estimated_cost) as total_estimated_cost
        FROM civics.citizens c
        LEFT JOIN civics.permit_applications pa ON c.citizen_id = pa.citizen_id
        WHERE c.status = ''active''
        GROUP BY c.citizen_id, c.first_name, c.last_name, c.city
        HAVING COUNT(pa.application_id) > 0
        ORDER BY permit_count DESC'
    );
    baseline_count := baseline_count + 1;

    -- Merchant-order join
    PERFORM performance.create_baseline(
        'merchant_order_join',
        'SELECT
            m.business_name,
            c.first_name || '' '' || c.last_name as customer_name,
            o.order_date,
            o.total_amount,
            o.order_status
        FROM commerce.orders o
        JOIN commerce.merchants m ON o.merchant_id = m.merchant_id
        JOIN civics.citizens c ON o.customer_citizen_id = c.citizen_id
        WHERE o.order_date >= CURRENT_DATE - INTERVAL ''1 month''
        ORDER BY o.order_date DESC'
    );
    baseline_count := baseline_count + 1;

    -- Multi-table analytics join
    PERFORM performance.create_baseline(
        'multi_table_analytics_join',
        'SELECT
            c.city,
            COUNT(DISTINCT c.citizen_id) as citizens,
            COUNT(DISTINCT pa.application_id) as permits,
            COUNT(DISTINCT o.order_id) as orders,
            SUM(o.total_amount) as total_commerce_value
        FROM civics.citizens c
        LEFT JOIN civics.permit_applications pa ON c.citizen_id = pa.citizen_id
        LEFT JOIN commerce.orders o ON c.citizen_id = o.customer_citizen_id
        WHERE c.status = ''active''
        GROUP BY c.city
        ORDER BY citizens DESC'
    );
    baseline_count := baseline_count + 1;

    -- Insert default thresholds
    INSERT INTO performance.regression_thresholds (test_category, warning_threshold, failure_threshold)
    VALUES ('general', 1.2, 2.0)
    ON CONFLICT DO NOTHING;

    result_msg := 'Created ' || baseline_count || ' performance test baselines';
    RETURN result_msg;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PERFORMANCE REGRESSION MONITORING
-- =============================================================================

-- Run all performance regression tests
CREATE OR REPLACE FUNCTION performance.run_regression_suite()
RETURNS TABLE(
    test_name TEXT,
    baseline_time_ms INTEGER,
    current_time_ms INTEGER,
    performance_ratio NUMERIC,
    status TEXT,
    plan_changed BOOLEAN,
    recommendation TEXT
) AS $$
DECLARE
    test_names TEXT[] := ARRAY[
        'citizen_lookup_by_email',
        'citizen_demographics_summary',
        'permit_trend_analysis',
        'commerce_performance_summary',
        'citizen_permit_join',
        'merchant_order_join',
        'multi_table_analytics_join'
    ];
    test_name_item TEXT;
    test_result RECORD;
BEGIN
    FOREACH test_name_item IN ARRAY test_names LOOP
        BEGIN
            SELECT * INTO test_result
            FROM performance.run_performance_test(test_name_item, 3)
            LIMIT 1;

            RETURN QUERY SELECT
                test_name_item,
                test_result.baseline_execution_ms,
                test_result.current_execution_ms,
                test_result.performance_ratio,
                test_result.test_status,
                test_result.plan_changed,
                CASE
                    WHEN test_result.test_status = 'fail' THEN 'CRITICAL: Investigate query plan and indexes'
                    WHEN test_result.test_status = 'warning' THEN 'Monitor: Performance degraded'
                    WHEN test_result.plan_changed THEN 'Review: Query plan changed'
                    ELSE 'OK: Performance within acceptable range'
                END as recommendation;

        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                test_name_item,
                NULL::INTEGER,
                NULL::INTEGER,
                NULL::NUMERIC,
                'error'::TEXT,
                NULL::BOOLEAN,
                'ERROR: ' || SQLERRM;
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INDEX EFFECTIVENESS ANALYSIS
-- =============================================================================

-- Analyze index usage and effectiveness
CREATE OR REPLACE FUNCTION performance.analyze_index_effectiveness()
RETURNS TABLE(
    schema_name NAME,
    table_name NAME,
    index_name NAME,
    index_scans BIGINT,
    tuples_read BIGINT,
    tuples_fetched BIGINT,
    index_size TEXT,
    usage_ratio NUMERIC,
    recommendation TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        schemaname::NAME,
        tablename::NAME,
        indexname::NAME,
        idx_scan as index_scans,
        idx_tup_read as tuples_read,
        idx_tup_fetch as tuples_fetched,
        pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
        CASE
            WHEN idx_scan > 0 THEN ROUND((idx_tup_fetch::NUMERIC / idx_tup_read) * 100, 2)
            ELSE 0
        END as usage_ratio,
        CASE
            WHEN idx_scan = 0 THEN 'Consider dropping - unused index'
            WHEN idx_tup_read > idx_tup_fetch * 100 THEN 'Low efficiency - review index design'
            WHEN idx_scan < 100 THEN 'Low usage - monitor or consider dropping'
            ELSE 'Good usage pattern'
        END as recommendation
    FROM pg_stat_user_indexes
    WHERE schemaname IN ('civics', 'commerce', 'documents', 'analytics')
    ORDER BY idx_scan DESC, pg_relation_size(indexrelid) DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- QUERY PLAN COMPARISON
-- =============================================================================

-- Compare query plans between baseline and current
CREATE OR REPLACE FUNCTION performance.compare_query_plans(
    test_name TEXT
)
RETURNS TABLE(
    comparison_aspect TEXT,
    baseline_value TEXT,
    current_value TEXT,
    difference TEXT,
    impact TEXT
) AS $$
DECLARE
    baseline_record RECORD;
    current_record RECORD;
BEGIN
    -- Get baseline
    SELECT * INTO baseline_record
    FROM performance.query_baselines
    WHERE performance.query_baselines.test_name = compare_query_plans.test_name
    AND is_active = TRUE
    ORDER BY created_at DESC
    LIMIT 1;

    -- Get latest test result
    SELECT * INTO current_record
    FROM performance.test_results tr
    JOIN performance.query_baselines qb ON tr.baseline_id = qb.baseline_id
    WHERE qb.test_name = compare_query_plans.test_name
    ORDER BY tr.executed_at DESC
    LIMIT 1;

    IF baseline_record IS NULL OR current_record IS NULL THEN
        RETURN QUERY SELECT
            'Error'::TEXT,
            'No data available'::TEXT,
            'No data available'::TEXT,
            'N/A'::TEXT,
            'Run baseline and test first'::TEXT;
        RETURN;
    END IF;

    -- Compare execution time
    RETURN QUERY SELECT
        'Execution Time'::TEXT,
        baseline_record.baseline_execution_time_ms || ' ms',
        current_record.execution_time_ms || ' ms',
        CASE
            WHEN current_record.execution_time_ms > baseline_record.baseline_execution_time_ms
            THEN '+' || (current_record.execution_time_ms - baseline_record.baseline_execution_time_ms) || ' ms'
            ELSE (current_record.execution_time_ms - baseline_record.baseline_execution_time_ms) || ' ms'
        END,
        CASE
            WHEN current_record.performance_ratio > 2.0 THEN 'Critical regression'
            WHEN current_record.performance_ratio > 1.2 THEN 'Performance warning'
            WHEN current_record.performance_ratio < 0.8 THEN 'Performance improvement'
            ELSE 'Acceptable'
        END;

    -- Compare estimated cost
    RETURN QUERY SELECT
        'Estimated Cost'::TEXT,
        COALESCE(baseline_record.baseline_cost::TEXT, 'Unknown'),
        COALESCE(current_record.estimated_cost::TEXT, 'Unknown'),
        CASE
            WHEN baseline_record.baseline_cost IS NOT NULL AND current_record.estimated_cost IS NOT NULL
            THEN (current_record.estimated_cost - baseline_record.baseline_cost)::TEXT
            ELSE 'Cannot compare'
        END,
        CASE
            WHEN baseline_record.baseline_cost IS NOT NULL AND current_record.estimated_cost IS NOT NULL
            THEN
                CASE
                    WHEN current_record.estimated_cost > baseline_record.baseline_cost * 2 THEN 'Cost increased significantly'
                    WHEN current_record.estimated_cost < baseline_record.baseline_cost * 0.5 THEN 'Cost improved significantly'
                    ELSE 'Cost change within normal range'
                END
            ELSE 'No cost comparison available'
        END;

    -- Compare row counts
    RETURN QUERY SELECT
        'Actual Rows'::TEXT,
        COALESCE(baseline_record.baseline_rows::TEXT, 'Unknown'),
        COALESCE(current_record.actual_rows::TEXT, 'Unknown'),
        CASE
            WHEN baseline_record.baseline_rows IS NOT NULL AND current_record.actual_rows IS NOT NULL
            THEN (current_record.actual_rows - baseline_record.baseline_rows)::TEXT
            ELSE 'Cannot compare'
        END,
        'Data volume comparison';

    -- Plan change status
    RETURN QUERY SELECT
        'Query Plan'::TEXT,
        'Baseline plan',
        'Current plan',
        CASE
            WHEN baseline_record.baseline_plan_hash = current_record.plan_hash THEN 'Unchanged'
            ELSE 'Plan changed'
        END,
        CASE
            WHEN baseline_record.baseline_plan_hash = current_record.plan_hash THEN 'Same optimization path'
            ELSE 'Different execution strategy - review plan details'
        END;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PERFORMANCE REPORTING
-- =============================================================================

-- Generate comprehensive performance report
CREATE OR REPLACE FUNCTION performance.generate_performance_report()
RETURNS TABLE(
    report_section TEXT,
    metric_name TEXT,
    metric_value TEXT,
    status TEXT,
    details TEXT
) AS $$
BEGIN
    -- Test suite summary
    RETURN QUERY
    SELECT
        'Test Suite Summary'::TEXT as report_section,
        'Total Tests'::TEXT as metric_name,
        COUNT(DISTINCT test_name)::TEXT as metric_value,
        'INFO'::TEXT as status,
        'Performance regression tests configured' as details
    FROM performance.query_baselines WHERE is_active = TRUE;

    -- Recent test results
    RETURN QUERY
    SELECT
        'Recent Results'::TEXT,
        'Tests Run (24h)'::TEXT,
        COUNT(*)::TEXT,
        'INFO'::TEXT,
        'Performance tests executed in last 24 hours'
    FROM performance.test_results
    WHERE executed_at >= NOW() - INTERVAL '24 hours';

    -- Performance regression summary
    RETURN QUERY
    SELECT
        'Regression Analysis'::TEXT,
        test_status || ' Tests' as metric_name,
        COUNT(*)::TEXT,
        CASE test_status
            WHEN 'fail' THEN 'CRITICAL'
            WHEN 'warning' THEN 'WARNING'
            ELSE 'OK'
        END,
        'Tests with ' || test_status || ' status in last 24h'
    FROM performance.test_results
    WHERE executed_at >= NOW() - INTERVAL '24 hours'
    GROUP BY test_status;

    -- Index effectiveness
    RETURN QUERY
    SELECT
        'Index Analysis'::TEXT,
        'Unused Indexes'::TEXT,
        COUNT(*)::TEXT,
        CASE WHEN COUNT(*) > 0 THEN 'WARNING' ELSE 'OK' END,
        'Indexes with zero scans - consider for removal'
    FROM pg_stat_user_indexes
    WHERE schemaname IN ('civics', 'commerce', 'documents')
    AND idx_scan = 0;

    -- Worst performing tests
    RETURN QUERY
    SELECT
        'Performance Issues'::TEXT,
        test_name,
        'Ratio: ' || ROUND(performance_ratio, 2)::TEXT,
        'WARNING'::TEXT,
        'Slowest performing test in recent runs'
    FROM performance.test_results
    WHERE executed_at >= NOW() - INTERVAL '7 days'
    AND test_status IN ('warning', 'fail')
    ORDER BY performance_ratio DESC
    LIMIT 5;
END;
$$ LANGUAGE plpgsql;
