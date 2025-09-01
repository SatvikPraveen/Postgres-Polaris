-- File: sql/11_perf_tuning/index_advisor_patterns.sql
-- Purpose: Anti-patterns → fixes, automated index recommendations

-- =============================================================================
-- INDEX ANTI-PATTERNS DETECTION
-- =============================================================================

-- Function to detect unused indexes
CREATE OR REPLACE FUNCTION analytics.detect_unused_indexes()
RETURNS TABLE(
    schema_name TEXT,
    table_name TEXT,
    index_name TEXT,
    index_size TEXT,
    scans_count BIGINT,
    recommendation TEXT,
    drop_command TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        schemaname::TEXT,
        relname::TEXT,
        indexrelname::TEXT,
        pg_size_pretty(pg_relation_size(indexrelid))::TEXT,
        idx_scan,
        CASE
            WHEN idx_scan = 0 AND indexrelname NOT LIKE '%_pkey' THEN 'DROP - Never used'
            WHEN idx_scan < 10 AND pg_relation_size(indexrelid) > 10485760 THEN 'REVIEW - Rarely used, large size'
            ELSE 'KEEP - Adequately used'
        END::TEXT,
        CASE
            WHEN idx_scan = 0 AND indexrelname NOT LIKE '%_pkey'
            THEN format('DROP INDEX IF EXISTS %I.%I;', schemaname, indexrelname)
            ELSE NULL
        END::TEXT
    FROM pg_stat_user_indexes
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    ORDER BY idx_scan, pg_relation_size(indexrelid) DESC;
END;
$$ LANGUAGE plpgsql;

-- Function to detect duplicate/redundant indexes
CREATE OR REPLACE FUNCTION analytics.detect_redundant_indexes()
RETURNS TABLE(
    schema_table TEXT,
    index1_name TEXT,
    index2_name TEXT,
    index1_columns TEXT,
    index2_columns TEXT,
    redundancy_type TEXT,
    recommendation TEXT
) AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT DISTINCT
            i1.schemaname || '.' || i1.tablename as table_name,
            i1.indexname as idx1_name,
            i2.indexname as idx2_name,
            i1.indexdef as idx1_def,
            i2.indexdef as idx2_def
        FROM pg_indexes i1
        JOIN pg_indexes i2 ON i1.tablename = i2.tablename
            AND i1.schemaname = i2.schemaname
            AND i1.indexname < i2.indexname
        WHERE i1.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
            AND i1.indexname NOT LIKE '%_pkey'
            AND i2.indexname NOT LIKE '%_pkey'
    LOOP
        -- Extract column lists (simplified)
        DECLARE
            cols1 TEXT := substring(rec.idx1_def from '\(([^)]+)\)');
            cols2 TEXT := substring(rec.idx2_def from '\(([^)]+)\)');
        BEGIN
            -- Check for redundancy patterns
            IF cols1 = cols2 THEN
                RETURN QUERY SELECT
                    rec.table_name,
                    rec.idx1_name,
                    rec.idx2_name,
                    cols1,
                    cols2,
                    'EXACT_DUPLICATE'::TEXT,
                    'Drop one of the duplicate indexes'::TEXT;
            ELSIF position(cols1 in cols2) = 1 THEN
                RETURN QUERY SELECT
                    rec.table_name,
                    rec.idx1_name,
                    rec.idx2_name,
                    cols1,
                    cols2,
                    'PREFIX_REDUNDANT'::TEXT,
                    format('Consider dropping %s as %s covers its columns', rec.idx1_name, rec.idx2_name)::TEXT;
            END IF;
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- MISSING INDEX DETECTION
-- =============================================================================

-- Function to suggest missing indexes based on query patterns
CREATE OR REPLACE FUNCTION analytics.suggest_missing_indexes()
RETURNS TABLE(
    schema_table TEXT,
    suggested_index TEXT,
    reasoning TEXT,
    estimated_benefit TEXT,
    create_command TEXT
) AS $$
BEGIN
    -- Foreign key columns without indexes
    RETURN QUERY
    WITH fk_without_indexes AS (
        SELECT
            n.nspname as schema_name,
            t.relname as table_name,
            a.attname as column_name
        FROM pg_constraint c
        JOIN pg_class t ON c.conrelid = t.oid
        JOIN pg_namespace n ON t.relnamespace = n.oid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(c.conkey)
        WHERE c.contype = 'f'  -- Foreign key
        AND n.nspname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND NOT EXISTS (
            SELECT 1 FROM pg_index i
            JOIN pg_class ic ON i.indexrelid = ic.oid
            WHERE i.indrelid = t.oid
            AND a.attnum = ANY(i.indkey)
        )
    )
    SELECT
        (schema_name || '.' || table_name)::TEXT,
        ('idx_' || table_name || '_' || column_name)::TEXT,
        'Foreign key column without index - impacts JOIN performance'::TEXT,
        'HIGH - Significant improvement for JOINs'::TEXT,
        format('CREATE INDEX idx_%s_%s ON %I.%I (%I);',
               table_name, column_name, schema_name, table_name, column_name)::TEXT
    FROM fk_without_indexes

    UNION ALL

    -- Frequently filtered columns without indexes
    SELECT
        'civics.citizens'::TEXT,
        'idx_citizens_status_active'::TEXT,
        'Status column frequently filtered, partial index more efficient'::TEXT,
        'MEDIUM - Faster status-based queries'::TEXT,
        'CREATE INDEX idx_citizens_status_active ON civics.citizens (citizen_id) WHERE status = ''active'';'::TEXT
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'citizens'
        AND indexname LIKE '%status%'
    )

    UNION ALL

    -- Date range queries without indexes
    SELECT
        'documents.complaint_records'::TEXT,
        'idx_complaints_submitted_date'::TEXT,
        'Date column used for range queries and reporting'::TEXT,
        'MEDIUM - Faster date range queries'::TEXT,
        'CREATE INDEX idx_complaints_submitted_date ON documents.complaint_records (submitted_at DESC);'::TEXT
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'complaint_records'
        AND indexdef LIKE '%submitted_at%'
    )

    ORDER BY estimated_benefit;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INDEX OPTIMIZATION PATTERNS
-- =============================================================================

-- Function to analyze index selectivity and effectiveness
CREATE OR REPLACE FUNCTION analytics.analyze_index_selectivity()
RETURNS TABLE(
    schema_table TEXT,
    index_name TEXT,
    index_scans BIGINT,
    tuples_read BIGINT,
    tuples_fetched BIGINT,
    selectivity_ratio NUMERIC,
    effectiveness_score TEXT,
    optimization_suggestion TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (pui.schemaname || '.' || pui.relname)::TEXT,
        pui.indexrelname::TEXT,
        pui.idx_scan,
        pui.idx_tup_read,
        pui.idx_tup_fetch,
        CASE
            WHEN pui.idx_tup_read > 0
            THEN ROUND(pui.idx_tup_fetch::NUMERIC / pui.idx_tup_read, 4)
            ELSE 0
        END,
        CASE
            WHEN pui.idx_scan = 0 THEN 'UNUSED'
            WHEN pui.idx_tup_read = 0 THEN 'NO_DATA'
            WHEN pui.idx_tup_fetch::NUMERIC / pui.idx_tup_read > 0.01 THEN 'POOR_SELECTIVITY'
            WHEN pui.idx_tup_fetch::NUMERIC / pui.idx_tup_read > 0.001 THEN 'FAIR_SELECTIVITY'
            ELSE 'GOOD_SELECTIVITY'
        END::TEXT,
        CASE
            WHEN pui.idx_scan = 0 THEN 'Consider dropping if consistently unused'
            WHEN pui.idx_tup_fetch::NUMERIC / pui.idx_tup_read > 0.01 THEN 'Review query patterns or add WHERE conditions'
            WHEN pui.idx_scan < 10 AND pg_relation_size(pui.indexrelid) > 50000000 THEN 'Large rarely-used index - review necessity'
            ELSE 'Index performing well'
        END::TEXT
    FROM pg_stat_user_indexes pui
    WHERE pui.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    ORDER BY
        CASE WHEN pui.idx_scan = 0 THEN 1 ELSE 0 END,
        pui.idx_tup_fetch::NUMERIC / NULLIF(pui.idx_tup_read, 0) DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COVERING INDEX OPPORTUNITIES
-- =============================================================================

-- Function to identify covering index opportunities
CREATE OR REPLACE FUNCTION analytics.identify_covering_opportunities()
RETURNS TABLE(
    schema_table TEXT,
    base_index TEXT,
    frequently_selected_columns TEXT,
    suggested_covering_index TEXT,
    potential_benefit TEXT
) AS $$
BEGIN
    RETURN QUERY
    -- Based on common query patterns, suggest covering indexes
    VALUES
        ('civics.citizens', 'idx_citizens_email', 'first_name, last_name, phone',
         'CREATE INDEX idx_citizens_email_covering ON civics.citizens (email) INCLUDE (first_name, last_name, phone);',
         'Avoid heap lookups for user profile queries'),

        ('civics.permit_applications', 'idx_permits_citizen', 'permit_number, status, application_date',
         'CREATE INDEX idx_permits_citizen_covering ON civics.permit_applications (citizen_id) INCLUDE (permit_number, status, application_date);',
         'Faster permit history lookups without heap access'),

        ('commerce.orders', 'idx_orders_customer', 'order_date, total_amount, status',
         'CREATE INDEX idx_orders_customer_covering ON commerce.orders (customer_citizen_id) INCLUDE (order_date, total_amount, status);',
         'Improved order history performance'),

        ('documents.complaint_records', 'idx_complaints_status', 'complaint_number, subject, submitted_at',
         'CREATE INDEX idx_complaints_status_covering ON documents.complaint_records (status) INCLUDE (complaint_number, subject, submitted_at);',
         'Faster complaint dashboard queries');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- AUTOMATED INDEX ADVISOR
-- =============================================================================

-- Comprehensive index advisor function
CREATE OR REPLACE FUNCTION analytics.comprehensive_index_advisor()
RETURNS TABLE(
    category TEXT,
    priority INTEGER,
    schema_table TEXT,
    issue_description TEXT,
    recommendation TEXT,
    sql_command TEXT,
    estimated_impact TEXT
) AS $$
BEGIN
    -- High Priority: Unused indexes
    RETURN QUERY
    SELECT
        'UNUSED_INDEX'::TEXT,
        1,
        (schemaname || '.' || relname)::TEXT,
        format('Index %s has never been used (%s)', indexrelname, pg_size_pretty(pg_relation_size(indexrelid))),
        'Drop unused index to save space and maintenance overhead'::TEXT,
        format('DROP INDEX IF EXISTS %I.%I;', schemaname, indexrelname)::TEXT,
        'HIGH - Immediate space savings'::TEXT
    FROM pg_stat_user_indexes
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND idx_scan = 0
        AND indexrelname NOT LIKE '%_pkey'
        AND pg_relation_size(indexrelid) > 1048576  -- > 1MB

    UNION ALL

    -- Medium Priority: Missing FK indexes
    SELECT
        'MISSING_FK_INDEX'::TEXT,
        2,
        (n.nspname || '.' || t.relname)::TEXT,
        format('Foreign key column %s lacks index', a.attname),
        'Create index on foreign key column for better JOIN performance'::TEXT,
        format('CREATE INDEX idx_%s_%s ON %I.%I (%I);',
               t.relname, a.attname, n.nspname, t.relname, a.attname)::TEXT,
        'HIGH - Significant JOIN improvement'::TEXT
    FROM pg_constraint c
    JOIN pg_class t ON c.conrelid = t.oid
    JOIN pg_namespace n ON t.relnamespace = n.oid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(c.conkey)
    WHERE c.contype = 'f'
        AND n.nspname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND NOT EXISTS (
            SELECT 1 FROM pg_index i
            WHERE i.indrelid = t.oid AND a.attnum = ANY(i.indkey)
        )

    UNION ALL

    -- Low Priority: Large rarely used indexes
    SELECT
        'RARELY_USED_LARGE_INDEX'::TEXT,
        3,
        (schemaname || '.' || relname)::TEXT,
        format('Large index %s (%s) used only %s times',
               indexrelname, pg_size_pretty(pg_relation_size(indexrelid)), idx_scan),
        'Review if index is still needed or can be optimized'::TEXT,
        format('-- Review usage: %s', indexrelname)::TEXT,
        'MEDIUM - Space optimization'::TEXT
    FROM pg_stat_user_indexes
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND idx_scan > 0 AND idx_scan < 100
        AND pg_relation_size(indexrelid) > 10485760  -- > 10MB
        AND indexrelname NOT LIKE '%_pkey'

    ORDER BY priority, estimated_impact DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INDEX MAINTENANCE RECOMMENDATIONS
-- =============================================================================

-- Function to generate index maintenance plan
CREATE OR REPLACE FUNCTION analytics.generate_index_maintenance_plan()
RETURNS TABLE(
    maintenance_type TEXT,
    table_name TEXT,
    index_name TEXT,
    current_size TEXT,
    bloat_estimate TEXT,
    recommended_action TEXT,
    maintenance_command TEXT,
    maintenance_window TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH index_bloat AS (
        SELECT
            schemaname,
            relname,
            indexrelname,
            pg_relation_size(indexrelid) as index_size,
            -- Simplified bloat estimation
            CASE
                WHEN pg_relation_size(indexrelid) > 100000000 THEN 'HIGH'
                WHEN pg_relation_size(indexrelid) > 10000000 THEN 'MEDIUM'
                ELSE 'LOW'
            END as bloat_level
        FROM pg_stat_user_indexes
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    )
    SELECT
        'REINDEX'::TEXT,
        (schemaname || '.' || relname)::TEXT,
        indexrelname::TEXT,
        pg_size_pretty(index_size)::TEXT,
        bloat_level::TEXT,
        CASE bloat_level
            WHEN 'HIGH' THEN 'REINDEX CONCURRENTLY during maintenance window'
            WHEN 'MEDIUM' THEN 'Schedule REINDEX during low-traffic period'
            ELSE 'Monitor, no immediate action needed'
        END::TEXT,
        CASE bloat_level
            WHEN 'HIGH' THEN format('REINDEX INDEX CONCURRENTLY %I.%I;', schemaname, indexrelname)
            WHEN 'MEDIUM' THEN format('REINDEX INDEX %I.%I;', schemaname, indexrelname)
            ELSE '-- No action needed'
        END::TEXT,
        CASE bloat_level
            WHEN 'HIGH' THEN 'Weekend maintenance window'
            WHEN 'MEDIUM' THEN 'Off-peak hours'
            ELSE 'Any time'
        END::TEXT
    FROM index_bloat
    WHERE bloat_level IN ('HIGH', 'MEDIUM')
    ORDER BY
        CASE bloat_level WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
        index_size DESC;
END;
$$ LANGUAGE plpgsql;

-- Function to execute index recommendations (with dry-run mode)
CREATE OR REPLACE FUNCTION analytics.execute_index_recommendations(
    dry_run BOOLEAN DEFAULT true,
    category_filter TEXT DEFAULT NULL
)
RETURNS TEXT AS $$
DECLARE
    rec RECORD;
    result TEXT := 'Index recommendation execution:' || E'\n';
    executed_count INTEGER := 0;
BEGIN
    FOR rec IN
        SELECT * FROM analytics.comprehensive_index_advisor()
        WHERE category_filter IS NULL OR category = category_filter
        AND priority <= 2  -- Only execute high and medium priority
        ORDER BY priority
    LOOP
        IF dry_run THEN
            result := result || format('[DRY RUN] %s: %s', rec.category, rec.sql_command) || E'\n';
        ELSE
            BEGIN
                EXECUTE rec.sql_command;
                result := result || format('[EXECUTED] %s: %s', rec.category, rec.sql_command) || E'\n';
                executed_count := executed_count + 1;
            EXCEPTION WHEN OTHERS THEN
                result := result || format('[ERROR] %s: %s - %s', rec.category, rec.sql_command, SQLERRM) || E'\n';
            END;
        END IF;
    END LOOP;

    result := result || format('Processed recommendations. %s executed.',
                              CASE WHEN dry_run THEN 0 ELSE executed_count END);

    RETURN result;
END;
$$ LANGUAGE plpgsql;
