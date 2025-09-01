-- File: sql/11_perf_tuning/stats_and_autovacuum.sql
-- Purpose: Statistics analysis, n_distinct targets, VACUUM tuning

-- =============================================================================
-- TABLE STATISTICS ANALYSIS
-- =============================================================================

-- Function to check table statistics health
CREATE OR REPLACE FUNCTION analytics.check_table_statistics()
RETURNS TABLE(
    schema_table TEXT,
    last_analyze TIMESTAMPTZ,
    last_autoanalyze TIMESTAMPTZ,
    days_since_analyze NUMERIC,
    analyze_count BIGINT,
    autoanalyze_count BIGINT,
    n_live_tup BIGINT,
    n_dead_tup BIGINT,
    statistics_health TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (schemaname || '.' || relname)::TEXT as schema_table,
        last_analyze,
        last_autoanalyze,
        ROUND(EXTRACT(EPOCH FROM (NOW() - COALESCE(last_autoanalyze, last_analyze)))/(24*3600), 1) as days_since_analyze,
        analyze_count,
        autoanalyze_count,
        n_live_tup,
        n_dead_tup,
        CASE
            WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 'NEVER ANALYZED'
            WHEN EXTRACT(EPOCH FROM (NOW() - COALESCE(last_autoanalyze, last_analyze)))/(24*3600) > 30 THEN 'STALE STATISTICS'
            WHEN n_dead_tup > n_live_tup * 0.1 THEN 'NEEDS ANALYZE'
            ELSE 'HEALTHY'
        END::TEXT as statistics_health
    FROM pg_stat_user_tables
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    ORDER BY days_since_analyze DESC NULLS FIRST;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COLUMN STATISTICS DEEP DIVE
-- =============================================================================

-- Function to analyze column statistics and n_distinct values
CREATE OR REPLACE FUNCTION analytics.analyze_column_statistics(
    target_schema TEXT DEFAULT 'civics',
    target_table TEXT DEFAULT 'citizens'
)
RETURNS TABLE(
    column_name TEXT,
    data_type TEXT,
    n_distinct INTEGER,
    most_common_values TEXT,
    most_common_freqs TEXT,
    correlation NUMERIC,
    null_frac NUMERIC,
    avg_width INTEGER,
    histogram_bounds TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.attname::TEXT as column_name,
        format_type(a.atttypid, a.atttypmod)::TEXT as data_type,
        s.stadistinct::INTEGER as n_distinct,
        array_to_string(s.stakind1_values, ', ')::TEXT as most_common_values,
        array_to_string(s.stakind1_freqs, ', ')::TEXT as most_common_freqs,
        s.stacorrelation as correlation,
        s.stanullfrac as null_frac,
        s.stawidth as avg_width,
        array_to_string(s.stakind2_values, ', ')::TEXT as histogram_bounds
    FROM pg_attribute a
    LEFT JOIN (
        SELECT
            staattnum,
            stadistinct,
            array_to_string(most_common_vals, ',') as stakind1_values,
            array_to_string(most_common_freqs, ',') as stakind1_freqs,
            correlation,
            null_frac as stanullfrac,
            avg_width as stawidth,
            array_to_string(histogram_bounds, ',') as stakind2_values
        FROM pg_stats
        WHERE schemaname = target_schema AND tablename = target_table
    ) s ON a.attnum = s.staattnum
    JOIN pg_class c ON a.attrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = target_schema
        AND c.relname = target_table
        AND a.attnum > 0
        AND NOT a.attisdropped
    ORDER BY a.attnum;
END;
$$ LANGUAGE plpgsql;

-- Function to detect skewed data distribution
CREATE OR REPLACE FUNCTION analytics.detect_data_skew()
RETURNS TABLE(
    table_name TEXT,
    column_name TEXT,
    n_distinct INTEGER,
    actual_distinct BIGINT,
    skew_factor NUMERIC,
    skew_severity TEXT,
    recommendation TEXT
) AS $$
DECLARE
    rec RECORD;
    actual_count BIGINT;
    stats_estimate INTEGER;
    skew_ratio NUMERIC;
BEGIN
    FOR rec IN
        SELECT schemaname, tablename, attname, stadistinct
        FROM pg_stats
        WHERE schemaname IN ('civics', 'commerce', 'mobility')
            AND stadistinct != -1  -- Not unique
            AND stadistinct > 0
    LOOP
        -- Get actual distinct count
        EXECUTE format('SELECT COUNT(DISTINCT %I) FROM %I.%I',
                      rec.attname, rec.schemaname, rec.tablename)
        INTO actual_count;

        stats_estimate := rec.stadistinct;

        IF actual_count > 0 THEN
            skew_ratio := ABS(actual_count - stats_estimate)::NUMERIC / actual_count;

            RETURN QUERY SELECT
                (rec.schemaname || '.' || rec.tablename)::TEXT,
                rec.attname::TEXT,
                stats_estimate,
                actual_count,
                ROUND(skew_ratio, 3),
                CASE
                    WHEN skew_ratio > 0.5 THEN 'HIGH SKEW'
                    WHEN skew_ratio > 0.2 THEN 'MODERATE SKEW'
                    ELSE 'LOW SKEW'
                END::TEXT,
                CASE
                    WHEN skew_ratio > 0.5 THEN 'Run ANALYZE or increase statistics target'
                    WHEN skew_ratio > 0.2 THEN 'Monitor query performance'
                    ELSE 'Statistics are accurate'
                END::TEXT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- STATISTICS TARGETS OPTIMIZATION
-- =============================================================================

-- Function to set optimal statistics targets
CREATE OR REPLACE FUNCTION analytics.optimize_statistics_targets()
RETURNS TABLE(
    table_column TEXT,
    current_target INTEGER,
    recommended_target INTEGER,
    reason TEXT,
    sql_command TEXT
) AS $$
DECLARE
    rec RECORD;
    recommended INTEGER;
    current_target INTEGER;
BEGIN
    FOR rec IN
        SELECT
            schemaname, tablename, attname, n_distinct,
            correlation, null_frac,
            -- Get current statistics target
            (SELECT attstattarget FROM pg_attribute
             WHERE attrelid = (schemaname||'.'||tablename)::regclass
             AND attname = pg_stats.attname) as current_stats_target
        FROM pg_stats
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    LOOP
        current_target := COALESCE(rec.current_stats_target, 100); -- Default is 100

        -- Determine recommended target based on data characteristics
        recommended := CASE
            WHEN ABS(rec.n_distinct) > 10000 THEN 1000  -- High cardinality
            WHEN ABS(rec.n_distinct) > 1000 THEN 500    -- Medium cardinality
            WHEN ABS(rec.correlation) < -0.9 OR ABS(rec.correlation) > 0.9 THEN 250 -- High correlation
            WHEN rec.null_frac > 0.1 THEN 150           -- Many nulls
            ELSE 100                                     -- Default
        END;

        -- Only suggest changes if significantly different
        IF ABS(recommended - current_target) > 50 THEN
            RETURN QUERY SELECT
                (rec.schemaname || '.' || rec.tablename || '.' || rec.attname)::TEXT,
                current_target,
                recommended,
                CASE
                    WHEN ABS(rec.n_distinct) > 10000 THEN 'High cardinality column needs more statistics'
                    WHEN ABS(rec.correlation) < -0.9 OR ABS(rec.correlation) > 0.9 THEN 'High correlation detected'
                    WHEN rec.null_frac > 0.1 THEN 'High null fraction requires more samples'
                    ELSE 'Standard optimization'
                END::TEXT,
                format('ALTER TABLE %I.%I ALTER COLUMN %I SET STATISTICS %s;',
                       rec.schemaname, rec.tablename, rec.attname, recommended)::TEXT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- AUTOVACUUM CONFIGURATION ANALYSIS
-- =============================================================================

-- Function to analyze autovacuum settings
CREATE OR REPLACE FUNCTION analytics.analyze_autovacuum_settings()
RETURNS TABLE(
    table_name TEXT,
    table_size TEXT,
    live_tuples BIGINT,
    dead_tuples BIGINT,
    autovacuum_threshold BIGINT,
    autoanalyze_threshold BIGINT,
    last_vacuum_ago TEXT,
    vacuum_recommendation TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (schemaname || '.' || relname)::TEXT as table_name,
        pg_size_pretty(pg_relation_size(schemaname||'.'||relname))::TEXT as table_size,
        n_live_tup as live_tuples,
        n_dead_tup as dead_tuples,
        -- Default autovacuum threshold calculation
        (50 + ROUND(n_live_tup * 0.2))::BIGINT as autovacuum_threshold,
        (50 + ROUND(n_live_tup * 0.1))::BIGINT as autoanalyze_threshold,
        CASE
            WHEN last_autovacuum IS NOT NULL THEN
                EXTRACT(EPOCH FROM (NOW() - last_autovacuum))::INTEGER::TEXT || ' seconds'
            WHEN last_vacuum IS NOT NULL THEN
                EXTRACT(EPOCH FROM (NOW() - last_vacuum))::INTEGER::TEXT || ' seconds (manual)'
            ELSE 'Never vacuumed'
        END as last_vacuum_ago,
        CASE
            WHEN n_dead_tup > (50 + n_live_tup * 0.4) THEN 'URGENT: Manual VACUUM recommended'
            WHEN n_dead_tup > (50 + n_live_tup * 0.2) THEN 'Due for autovacuum'
            WHEN last_autovacuum IS NULL AND last_vacuum IS NULL THEN 'Monitor new table'
            ELSE 'Healthy'
        END::TEXT as vacuum_recommendation
    FROM pg_stat_user_tables
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    ORDER BY n_dead_tup DESC;
END;
$$ LANGUAGE plpgsql;

-- Function to tune autovacuum parameters per table
CREATE OR REPLACE FUNCTION analytics.tune_autovacuum_parameters()
RETURNS TABLE(
    table_name TEXT,
    current_settings TEXT,
    recommended_settings TEXT,
    sql_command TEXT,
    reasoning TEXT
) AS $$
DECLARE
    rec RECORD;
    table_size BIGINT;
    update_frequency TEXT;
    recommended_scale NUMERIC;
    recommended_threshold INTEGER;
BEGIN
    FOR rec IN
        SELECT schemaname, relname, n_live_tup, n_dead_tup,
               pg_relation_size(schemaname||'.'||relname) as size_bytes,
               vacuum_count, autovacuum_count,
               EXTRACT(EPOCH FROM (NOW() - COALESCE(last_autovacuum, last_vacuum)))/3600 as hours_since_vacuum
        FROM pg_stat_user_tables
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND n_live_tup > 1000  -- Focus on larger tables
    LOOP
        table_size := rec.size_bytes;

        -- Determine update frequency pattern
        update_frequency := CASE
            WHEN rec.hours_since_vacuum < 1 THEN 'Very High'
            WHEN rec.hours_since_vacuum < 24 THEN 'High'
            WHEN rec.hours_since_vacuum < 168 THEN 'Moderate' -- 1 week
            ELSE 'Low'
        END;

        -- Adjust autovacuum parameters based on characteristics
        IF update_frequency = 'Very High' AND table_size > 100000000 THEN -- 100MB
            recommended_scale := 0.05; -- More aggressive
            recommended_threshold := 100;
        ELSIF update_frequency = 'High' THEN
            recommended_scale := 0.1;
            recommended_threshold := 50;
        ELSIF table_size > 1000000000 THEN -- 1GB
            recommended_scale := 0.02; -- Less aggressive for large tables
            recommended_threshold := 200;
        ELSE
            recommended_scale := 0.2; -- Default
            recommended_threshold := 50;
        END IF;

        RETURN QUERY SELECT
            (rec.schemaname || '.' || rec.relname)::TEXT,
            'Default (scale_factor=0.2, threshold=50)'::TEXT,
            format('scale_factor=%.2f, threshold=%s', recommended_scale, recommended_threshold)::TEXT,
            format('ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = %.2f, autovacuum_vacuum_threshold = %s);',
                   rec.schemaname, rec.relname, recommended_scale, recommended_threshold)::TEXT,
            format('Table size: %s, Update frequency: %s',
                   pg_size_pretty(table_size), update_frequency)::TEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- MAINTENANCE OPERATIONS
-- =============================================================================

-- Function to perform intelligent ANALYZE on stale statistics
CREATE OR REPLACE FUNCTION analytics.smart_analyze_tables()
RETURNS TEXT AS $$
DECLARE
    rec RECORD;
    result_text TEXT := 'Smart ANALYZE results:' || E'\n';
    tables_analyzed INTEGER := 0;
BEGIN
    FOR rec IN
        SELECT schemaname, relname
        FROM pg_stat_user_tables
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND (
            last_analyze IS NULL OR
            last_autoanalyze IS NULL OR
            (n_mod_since_analyze > n_live_tup * 0.1 AND n_live_tup > 100) OR
            EXTRACT(EPOCH FROM (NOW() - COALESCE(last_autoanalyze, last_analyze)))/(24*3600) > 7
        )
        ORDER BY n_mod_since_analyze DESC
    LOOP
        -- Execute ANALYZE
        EXECUTE format('ANALYZE %I.%I', rec.schemaname, rec.relname);

        result_text := result_text || format('- Analyzed %s.%s', rec.schemaname, rec.relname) || E'\n';
        tables_analyzed := tables_analyzed + 1;
    END LOOP;

    IF tables_analyzed = 0 THEN
        result_text := result_text || 'No tables required ANALYZE' || E'\n';
    ELSE
        result_text := result_text || format('Total tables analyzed: %s', tables_analyzed) || E'\n';
    END IF;

    RETURN result_text;
END;
$$ LANGUAGE plpgsql;

-- Function to generate maintenance schedule
CREATE OR REPLACE FUNCTION analytics.generate_maintenance_schedule()
RETURNS TABLE(
    maintenance_type TEXT,
    table_name TEXT,
    priority INTEGER,
    estimated_duration TEXT,
    recommended_time TEXT,
    command TEXT
) AS $$
BEGIN
    -- High priority: Tables with excessive dead tuples
    RETURN QUERY
    SELECT
        'VACUUM'::TEXT,
        (schemaname || '.' || relname)::TEXT,
        1,
        CASE
            WHEN pg_relation_size(schemaname||'.'||relname) > 1000000000 THEN '30-60 minutes'
            WHEN pg_relation_size(schemaname||'.'||relname) > 100000000 THEN '5-15 minutes'
            ELSE '1-5 minutes'
        END::TEXT,
        'Off-peak hours'::TEXT,
        format('VACUUM ANALYZE %I.%I;', schemaname, relname)::TEXT
    FROM pg_stat_user_tables
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    AND n_dead_tup > (n_live_tup * 0.3 + 50)

    UNION ALL

    -- Medium priority: Stale statistics
    SELECT
        'ANALYZE'::TEXT,
        (schemaname || '.' || relname)::TEXT,
        2,
        '1-5 minutes'::TEXT,
        'Any time'::TEXT,
        format('ANALYZE %I.%I;', schemaname, relname)::TEXT
    FROM pg_stat_user_tables
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    AND (
        last_analyze IS NULL OR
        EXTRACT(EPOCH FROM (NOW() - last_analyze))/(24*3600) > 7
    )
    AND NOT (n_dead_tup > (n_live_tup * 0.3 + 50)) -- Not already covered by VACUUM

    ORDER BY priority, table_name;
END;
$$ LANGUAGE plpgsql;
