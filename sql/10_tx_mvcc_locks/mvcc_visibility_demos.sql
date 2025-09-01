-- File: sql/10_tx_mvcc_locks/mvcc_visibility_demos.sql
-- Purpose: MVCC visibility, hint bits, bloat illustrations and vacuum demos

-- =============================================================================
-- MVCC VISIBILITY DEMONSTRATIONS
-- =============================================================================

-- Create demo table to show MVCC behavior
CREATE TEMP TABLE mvcc_demo (
    id SERIAL PRIMARY KEY,
    data TEXT,
    version INTEGER DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Function to demonstrate snapshot isolation
CREATE OR REPLACE FUNCTION analytics.demo_snapshot_isolation()
RETURNS TABLE(
    step TEXT,
    transaction_id BIGINT,
    snapshot_time TIMESTAMPTZ,
    visible_rows INTEGER,
    row_data TEXT[]
) AS $$
DECLARE
    initial_txid BIGINT;
    step_counter INTEGER := 1;
BEGIN
    -- Get current transaction ID
    initial_txid := txid_current();

    -- Insert initial data
    INSERT INTO mvcc_demo (data) VALUES ('Row 1'), ('Row 2'), ('Row 3');

    -- Step 1: Show initial state
    RETURN QUERY
    SELECT
        ('Step ' || step_counter || ': Initial state')::TEXT,
        initial_txid,
        NOW(),
        COUNT(*)::INTEGER,
        array_agg(data ORDER BY id)
    FROM mvcc_demo;

    step_counter := step_counter + 1;

    -- Step 2: Update a row (creates new version)
    UPDATE mvcc_demo SET data = 'Row 1 Updated', version = 2 WHERE id = 1;

    RETURN QUERY
    SELECT
        ('Step ' || step_counter || ': After update')::TEXT,
        txid_current(),
        NOW(),
        COUNT(*)::INTEGER,
        array_agg(data ORDER BY id)
    FROM mvcc_demo;

    step_counter := step_counter + 1;

    -- Step 3: Delete a row (marks as deleted)
    DELETE FROM mvcc_demo WHERE id = 2;

    RETURN QUERY
    SELECT
        ('Step ' || step_counter || ': After delete')::TEXT,
        txid_current(),
        NOW(),
        COUNT(*)::INTEGER,
        array_agg(data ORDER BY id)
    FROM mvcc_demo;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TRANSACTION ID AND SYSTEM COLUMNS ANALYSIS
-- =============================================================================

-- Function to show system columns (xmin, xmax, ctid)
CREATE OR REPLACE FUNCTION analytics.show_system_columns(table_name TEXT)
RETURNS TABLE(
    physical_location TID,
    insert_txid BIGINT,
    delete_txid BIGINT,
    row_data TEXT,
    is_visible_now BOOLEAN
) AS $$
DECLARE
    query_sql TEXT;
BEGIN
    -- Build dynamic query to show system columns
    query_sql := format('
        SELECT
            ctid as physical_location,
            xmin::text::bigint as insert_txid,
            CASE WHEN xmax = 0 THEN NULL ELSE xmax::text::bigint END as delete_txid,
            %I::text as row_data,
            CASE WHEN xmax = 0 OR xmax::text::bigint > txid_current() THEN true ELSE false END as is_visible_now
        FROM %I
        ORDER BY ctid',
        'data', table_name  -- Assuming 'data' column exists
    );

    RETURN QUERY EXECUTE query_sql;
END;
$$ LANGUAGE plpgsql;

-- Demonstrate tuple visibility with explicit transaction IDs
CREATE OR REPLACE FUNCTION analytics.demo_tuple_visibility()
RETURNS TABLE(
    demo_step TEXT,
    tuple_ctid TID,
    xmin_txid TEXT,
    xmax_txid TEXT,
    visibility_status TEXT,
    data_content TEXT
) AS $$
BEGIN
    -- Create demo table with system column access
    CREATE TEMP TABLE visibility_demo (
        id SERIAL PRIMARY KEY,
        content TEXT,
        modified_at TIMESTAMPTZ DEFAULT NOW()
    );

    -- Insert initial data
    INSERT INTO visibility_demo (content) VALUES
        ('Original content 1'),
        ('Original content 2'),
        ('Original content 3');

    -- Show initial state
    RETURN QUERY
    SELECT
        'Initial Insert'::TEXT as demo_step,
        ctid,
        xmin::TEXT,
        CASE WHEN xmax::TEXT = '0' THEN 'NULL' ELSE xmax::TEXT END,
        CASE WHEN xmax::TEXT = '0' THEN 'VISIBLE' ELSE 'DELETED' END,
        content
    FROM visibility_demo
    ORDER BY id;

    -- Update one row (creates new tuple, marks old as deleted)
    UPDATE visibility_demo
    SET content = 'Updated content 1', modified_at = NOW()
    WHERE id = 1;

    -- Show state after update
    RETURN QUERY
    SELECT
        'After Update'::TEXT as demo_step,
        ctid,
        xmin::TEXT,
        CASE WHEN xmax::TEXT = '0' THEN 'NULL' ELSE xmax::TEXT END,
        CASE WHEN xmax::TEXT = '0' THEN 'VISIBLE' ELSE 'DELETED' END,
        content
    FROM visibility_demo
    ORDER BY id;

    -- Delete one row
    DELETE FROM visibility_demo WHERE id = 2;

    -- Show final state (deleted row still physically present but marked deleted)
    RETURN QUERY
    SELECT
        'After Delete'::TEXT as demo_step,
        ctid,
        xmin::TEXT,
        CASE WHEN xmax::TEXT = '0' THEN 'NULL' ELSE xmax::TEXT END,
        CASE WHEN xmax::STRING = '0' THEN 'VISIBLE' ELSE 'DELETED' END,
        COALESCE(content, '[DELETED]')
    FROM visibility_demo
    ORDER BY id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BLOAT ANALYSIS AND DEMONSTRATION
-- =============================================================================

-- Function to create bloated table for demonstration
CREATE OR REPLACE FUNCTION analytics.create_bloat_demo()
RETURNS TEXT AS $$
DECLARE
    i INTEGER;
    initial_size BIGINT;
    final_size BIGINT;
    bloat_ratio NUMERIC;
BEGIN
    -- Create table for bloat demonstration
    CREATE TABLE analytics.bloat_demo_table (
        id SERIAL PRIMARY KEY,
        data TEXT,
        filler CHAR(100) DEFAULT 'X',
        updated_at TIMESTAMPTZ DEFAULT NOW()
    );

    -- Insert initial data
    INSERT INTO analytics.bloat_demo_table (data)
    SELECT 'Initial data ' || generate_series(1, 10000);

    initial_size := pg_relation_size('analytics.bloat_demo_table');

    -- Create bloat by repeatedly updating all rows
    FOR i IN 1..5 LOOP
        UPDATE analytics.bloat_demo_table
        SET data = 'Updated ' || i || ' times: ' || data,
            updated_at = NOW();
    END LOOP;

    final_size := pg_relation_size('analytics.bloat_demo_table');
    bloat_ratio := final_size::NUMERIC / initial_size;

    RETURN format('Bloat demo created: Initial size: %s, Final size: %s, Bloat ratio: %sx',
                  pg_size_pretty(initial_size),
                  pg_size_pretty(final_size),
                  ROUND(bloat_ratio, 2));
END;
$$ LANGUAGE plpgsql;

-- Function to analyze table bloat
CREATE OR REPLACE FUNCTION analytics.analyze_table_bloat(
    schema_name TEXT DEFAULT 'public',
    table_name TEXT DEFAULT 'bloat_demo_table'
)
RETURNS TABLE(
    table_name TEXT,
    live_tuples BIGINT,
    dead_tuples BIGINT,
    table_size TEXT,
    bloat_percentage NUMERIC,
    vacuum_recommended BOOLEAN,
    pages_total BIGINT,
    pages_free BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (schema_name || '.' || t.table_name)::TEXT,
        pg_stat_get_live_tuples(c.oid) as live_tuples,
        pg_stat_get_dead_tuples(c.oid) as dead_tuples,
        pg_size_pretty(pg_relation_size(c.oid))::TEXT as table_size,
        CASE
            WHEN pg_stat_get_live_tuples(c.oid) > 0
            THEN ROUND(pg_stat_get_dead_tuples(c.oid) * 100.0 /
                      (pg_stat_get_live_tuples(c.oid) + pg_stat_get_dead_tuples(c.oid)), 2)
            ELSE 0
        END as bloat_percentage,
        (pg_stat_get_dead_tuples(c.oid) > pg_stat_get_live_tuples(c.oid) * 0.2) as vacuum_recommended,
        (pg_relation_size(c.oid) / 8192) as pages_total,
        0::BIGINT as pages_free  -- Simplified
    FROM information_schema.tables t
    JOIN pg_class c ON c.relname = t.table_name
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = t.table_schema
    WHERE t.table_schema = schema_name
        AND (table_name IS NULL OR t.table_name = table_name)
        AND t.table_type = 'BASE TABLE'
    ORDER BY bloat_percentage DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- VACUUM DEMONSTRATIONS
-- =============================================================================

-- Function to demonstrate vacuum effects
CREATE OR REPLACE FUNCTION analytics.demo_vacuum_effects()
RETURNS TABLE(
    operation TEXT,
    dead_tuples_before BIGINT,
    table_size_before TEXT,
    dead_tuples_after BIGINT,
    table_size_after TEXT,
    space_reclaimed TEXT,
    duration_ms NUMERIC
) AS $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    dead_before BIGINT;
    dead_after BIGINT;
    size_before BIGINT;
    size_after BIGINT;
BEGIN
    -- Ensure bloat demo table exists
    PERFORM analytics.create_bloat_demo();

    -- Get initial stats
    SELECT pg_stat_get_dead_tuples(oid), pg_relation_size(oid)
    INTO dead_before, size_before
    FROM pg_class WHERE relname = 'bloat_demo_table';

    -- VACUUM (not FULL)
    start_time := clock_timestamp();
    VACUUM analytics.bloat_demo_table;
    end_time := clock_timestamp();

    SELECT pg_stat_get_dead_tuples(oid), pg_relation_size(oid)
    INTO dead_after, size_after
    FROM pg_class WHERE relname = 'bloat_demo_table';

    RETURN QUERY SELECT
        'VACUUM'::TEXT,
        dead_before,
        pg_size_pretty(size_before)::TEXT,
        dead_after,
        pg_size_pretty(size_after)::TEXT,
        CASE WHEN size_after < size_before
             THEN pg_size_pretty(size_before - size_after)::TEXT
             ELSE 'No space reclaimed' END,
        EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;

    -- Create more bloat
    UPDATE analytics.bloat_demo_table SET data = 'More bloat: ' || data;

    -- Get stats before VACUUM FULL
    SELECT pg_stat_get_dead_tuples(oid), pg_relation_size(oid)
    INTO dead_before, size_before
    FROM pg_class WHERE relname = 'bloat_demo_table';

    -- VACUUM FULL
    start_time := clock_timestamp();
    VACUUM FULL analytics.bloat_demo_table;
    end_time := clock_timestamp();

    SELECT pg_stat_get_dead_tuples(oid), pg_relation_size(oid)
    INTO dead_after, size_after
    FROM pg_class WHERE relname = 'bloat_demo_table';

    RETURN QUERY SELECT
        'VACUUM FULL'::TEXT,
        dead_before,
        pg_size_pretty(size_before)::TEXT,
        dead_after,
        pg_size_pretty(size_after)::TEXT,
        pg_size_pretty(size_before - size_after)::TEXT,
        EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;

    -- Cleanup
    DROP TABLE analytics.bloat_demo_table;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- AUTOVACUUM MONITORING
-- =============================================================================

-- Function to check autovacuum settings and activity
CREATE OR REPLACE FUNCTION analytics.check_autovacuum_status()
RETURNS TABLE(
    table_name TEXT,
    last_vacuum TIMESTAMPTZ,
    last_autovacuum TIMESTAMPTZ,
    last_analyze TIMESTAMPTZ,
    last_autoanalyze TIMESTAMPTZ,
    vacuum_count BIGINT,
    autovacuum_count BIGINT,
    n_live_tup BIGINT,
    n_dead_tup BIGINT,
    autovacuum_threshold BIGINT,
    needs_vacuum BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (schemaname || '.' || relname)::TEXT as table_name,
        last_vacuum,
        last_autovacuum,
        last_analyze,
        last_autoanalyze,
        vacuum_count,
        autovacuum_count,
        n_live_tup,
        n_dead_tup,
        -- Simplified autovacuum threshold calculation
        (50 + 0.2 * n_live_tup)::BIGINT as autovacuum_threshold,
        (n_dead_tup > (50 + 0.2 * n_live_tup)) as needs_vacuum
    FROM pg_stat_user_tables
    WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics')
    ORDER BY n_dead_tup DESC, n_live_tup DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- HINT BITS DEMONSTRATION
-- =============================================================================

-- Function to show hint bit effects (simplified demonstration)
CREATE OR REPLACE FUNCTION analytics.demo_hint_bits()
RETURNS TEXT AS $$
DECLARE
    result TEXT := 'Hint bits demonstration:' || E'\n';
BEGIN
    -- Create table for hint bit demo
    CREATE TEMP TABLE hint_bits_demo (
        id SERIAL PRIMARY KEY,
        data TEXT,
        created_txid BIGINT DEFAULT txid_current()
    );

    -- Insert data in current transaction
    INSERT INTO hint_bits_demo (data)
    SELECT 'Data row ' || generate_series(1, 1000);

    result := result || 'Created 1000 rows in transaction ' || txid_current() || E'\n';

    -- Commit transaction (hint bits will be set on next access)
    -- Note: In real scenario, hint bits are set when tuples are accessed
    -- after their creating/deleting transactions commit

    result := result || 'Hint bits help avoid repeated transaction status lookups' || E'\n';
    result := result || 'They are set automatically during tuple access after commit' || E'\n';

    -- Show transaction status functions that hint bits help optimize
    result := result || 'Current transaction: ' || txid_current() || E'\n';
    result := result || 'Transaction visible: ' || txid_visible_in_snapshot(txid_current(), txid_current_snapshot()) || E'\n';

    RETURN result;
END;
$$ LANGUAGE plpgsql;
