-- File: sql/11_perf_tuning/explain_analyze_playbook.sql
-- Purpose: Reading and measuring plans on PostgreSQL 17: EXPLAIN options
--          (ANALYZE, BUFFERS, SETTINGS, WAL, SERIALIZE, MEMORY), scan and join
--          strategies, sorts and memory, misestimates and sargability, plus
--          pg_stat_statements and auto_explain for finding what to tune.
--
-- Idempotent; reads base tables only. Write-cost demos run on a module-owned
-- table (analytics.explain_lab_payments). All planner GUC changes use SET LOCAL
-- inside a transaction so nothing leaks into the rest of the session.
-- Timings and buffer counts vary run to run; plan shapes are what to compare.
-- Recency filters are anchored on meta.as_of() (the dataset's "now").

-- Older revisions of this file created these functions with other result shapes.
DROP FUNCTION IF EXISTS analytics.analyze_plan_patterns();
DROP FUNCTION IF EXISTS analytics.identify_slow_patterns();

-- =============================================================================
-- 0. HELPER: a plan as rows (EXPLAIN ... FORMAT JSON, walked recursively)
-- =============================================================================
\echo '== 0. Helper analytics.explain_nodes()'

-- Executes trusted, hand-written SQL under EXPLAIN (ANALYZE, BUFFERS) and returns
-- one row per plan node with estimates vs actuals: the core of plan debugging.
CREATE OR REPLACE FUNCTION analytics.explain_nodes(p_sql text)
RETURNS TABLE (node_id int, depth int, node text, relation text,
               est_rows numeric, actual_rows numeric, loops numeric,
               off_by numeric, shared_hit bigint, shared_read bigint, total_ms numeric)
LANGUAGE plpgsql AS $$
DECLARE
    plan jsonb;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO plan;
    RETURN QUERY
    WITH RECURSIVE walk(n, d, path) AS (
        SELECT plan -> 0 -> 'Plan', 0, ARRAY[0]
        UNION ALL
        SELECT c.child, w.d + 1, w.path || c.ord::int
        FROM walk w
        CROSS JOIN LATERAL jsonb_array_elements(w.n -> 'Plans') WITH ORDINALITY AS c(child, ord)
    )
    SELECT (row_number() OVER (ORDER BY path))::int,
           d,
           repeat('  ', d) || (n ->> 'Node Type')
               || COALESCE(' (' || (n ->> 'Join Type') || ')', '')
               || COALESCE(' [' || (n ->> 'Index Name') || ']', ''),
           n ->> 'Relation Name',
           (n ->> 'Plan Rows')::numeric,
           (n ->> 'Actual Rows')::numeric,                          -- per loop
           (n ->> 'Actual Loops')::numeric,
           round(greatest((n ->> 'Plan Rows')::numeric, 1) / greatest((n ->> 'Actual Rows')::numeric, 1), 2),
           (n ->> 'Shared Hit Blocks')::bigint,
           (n ->> 'Shared Read Blocks')::bigint,
           round((n ->> 'Actual Total Time')::numeric * (n ->> 'Actual Loops')::numeric, 2)
    FROM walk
    ORDER BY path;
END $$;
COMMENT ON FUNCTION analytics.explain_nodes(text) IS
'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) of trusted SQL as one row per plan node: estimates vs actuals, buffers, time.';

-- =============================================================================
-- 1. EXPLAIN OPTIONS CHEAT SHEET
-- =============================================================================
\echo '== 1. EXPLAIN options'

SELECT * FROM (VALUES
    ('EXPLAIN',              'Plan + estimated cost/rows only; nothing is executed'),
    ('ANALYZE',              'Executes the statement; adds actual time, rows, loops (wrap DML in BEGIN/ROLLBACK)'),
    ('BUFFERS',              'Shared/local/temp blocks hit/read/dirtied/written per node; planning buffers too'),
    ('SETTINGS',             'Lists non-default planner-relevant settings (PG12+)'),
    ('WAL',                  'WAL records, full-page images and bytes generated (PG13+), for writes'),
    ('SERIALIZE',            'PG17: also converts the result to wire format (detoasting!) and reports its cost'),
    ('MEMORY',               'PG17: memory used by the planner'),
    ('GENERIC_PLAN',         'PG16: plan a query with $1 parameters without values'),
    ('TIMING OFF',           'Keep row counts, skip per-node clock calls (cheaper on slow clocks)'),
    ('FORMAT JSON',          'Machine-readable; feed it to tools or to SQL as in explain_nodes()')
) AS t(option, what_it_adds);

-- =============================================================================
-- 2. THE FULL PG17 TOOLKIT ON ONE QUERY
-- =============================================================================
\echo '== 2. EXPLAIN (ANALYZE, BUFFERS, SETTINGS, WAL, SERIALIZE, MEMORY)'

-- Top merchants by revenue over the last 30 days of data.
BEGIN;
SET LOCAL work_mem = '8MB';            -- shows up under "Settings:"
SET LOCAL random_page_cost = 1.1;      -- SSD-style costing; also listed
EXPLAIN (ANALYZE, BUFFERS, SETTINGS, WAL, SERIALIZE, MEMORY)
SELECT m.merchant_id, m.business_name, count(*) AS orders, sum(o.total_amount) AS revenue
FROM commerce.orders o
JOIN commerce.merchants m ON m.merchant_id = o.merchant_id
WHERE o.order_date >= meta.as_of() - interval '30 days'
  AND o.status <> 'cancelled'
GROUP BY m.merchant_id, m.business_name
ORDER BY revenue DESC
LIMIT 10;
COMMIT;
-- How to read it: start at the most indented node; compare "rows=" estimate with
-- "actual ... rows=" (per loop, multiply by loops); look for big gaps, then for the
-- node where time or buffers jump. "Buffers: shared read" = came from disk/OS cache.

-- =============================================================================
-- 3. WAL AND SERIALIZE: costs plain EXPLAIN ANALYZE hides
-- =============================================================================
\echo '== 3a. WAL generated by an UPDATE (module-owned copy of payments)'

DROP TABLE IF EXISTS analytics.explain_lab_payments;
CREATE TABLE analytics.explain_lab_payments AS
SELECT * FROM commerce.payments ORDER BY payment_id;
ALTER TABLE analytics.explain_lab_payments ADD PRIMARY KEY (payment_id);
VACUUM (ANALYZE) analytics.explain_lab_payments;
CHECKPOINT;   -- the next change to each page after a checkpoint writes a full-page image (FPI)

BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL, COSTS OFF)
UPDATE analytics.explain_lab_payments SET failure_reason = failure_reason WHERE payment_id <= 5000;
-- Same rows again in the same transaction: no FPIs this time, so fewer WAL bytes.
EXPLAIN (ANALYZE, BUFFERS, WAL, COSTS OFF)
UPDATE analytics.explain_lab_payments SET failure_reason = failure_reason WHERE payment_id <= 5000;
ROLLBACK;

\echo '== 3b. SERIALIZE: the cost of sending wide/TOASTed columns to the client'
-- Plain EXPLAIN ANALYZE never detoasts or converts output, so it under-reports
-- queries that return big jsonb/text. SERIALIZE measures that work (PG17).
EXPLAIN (ANALYZE, SERIALIZE TEXT, COSTS OFF, TIMING OFF)
SELECT complaint_id, description, metadata, resolution_actions
FROM documents.complaint_records;
EXPLAIN (ANALYZE, SERIALIZE TEXT, COSTS OFF, TIMING OFF)
SELECT complaint_id
FROM documents.complaint_records;

-- =============================================================================
-- 4. SCAN STRATEGIES
-- =============================================================================
\echo '== 4. Seq Scan / Index Scan / Index Only Scan / Bitmap Heap Scan'

-- Low selectivity -> Seq Scan (reading everything sequentially is cheapest).
EXPLAIN (COSTS OFF) SELECT * FROM commerce.orders WHERE status <> 'cancelled';
-- Single row by key -> Index Scan.
EXPLAIN (COSTS OFF) SELECT * FROM commerce.orders WHERE order_id = 4242;
-- Only indexed columns needed -> Index Only Scan; "Heap Fetches" counts pages whose
-- visibility-map bit was not set (VACUUM sets them).
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT order_date FROM commerce.orders
WHERE order_date >= meta.as_of() - interval '7 days';
-- Medium selectivity or OR/AND of indexes -> Bitmap Index Scan(s) + Bitmap Heap Scan.
EXPLAIN (COSTS OFF)
SELECT * FROM commerce.orders WHERE customer_citizen_id = 17 OR merchant_id = 3;

-- =============================================================================
-- 5. JOIN STRATEGIES (planner's choice, then forced alternatives)
-- =============================================================================
\echo '== 5. Nested Loop vs Hash Join vs Merge Join'

-- Same query three ways. enable_* = off does not forbid a method, it makes it
-- look prohibitively expensive: a diagnosis tool, never a production setting.
CREATE TEMP TABLE IF NOT EXISTS join_compare (strategy text, node_id int, node text, est_rows numeric,
                                              actual_rows numeric, loops numeric, shared_hit bigint, total_ms numeric);
TRUNCATE join_compare;

BEGIN;   -- planner's choice
INSERT INTO join_compare
SELECT 'planner choice', node_id, node, est_rows, actual_rows, loops, shared_hit, total_ms
FROM analytics.explain_nodes($q$
    SELECT c.zip_code, count(*) AS trips, avg(t.duration_minutes) AS avg_minutes
    FROM mobility.trip_segments t
    JOIN civics.citizens c ON c.citizen_id = t.user_id
    WHERE t.start_time >= meta.as_of() - interval '14 days'
    GROUP BY c.zip_code $q$);
COMMIT;

BEGIN;
SET LOCAL enable_hashjoin = off; SET LOCAL enable_mergejoin = off;
INSERT INTO join_compare
SELECT 'nested loop forced', node_id, node, est_rows, actual_rows, loops, shared_hit, total_ms
FROM analytics.explain_nodes($q$
    SELECT c.zip_code, count(*) AS trips, avg(t.duration_minutes) AS avg_minutes
    FROM mobility.trip_segments t
    JOIN civics.citizens c ON c.citizen_id = t.user_id
    WHERE t.start_time >= meta.as_of() - interval '14 days'
    GROUP BY c.zip_code $q$);
COMMIT;

BEGIN;
SET LOCAL enable_hashjoin = off; SET LOCAL enable_nestloop = off;
INSERT INTO join_compare
SELECT 'merge join forced', node_id, node, est_rows, actual_rows, loops, shared_hit, total_ms
FROM analytics.explain_nodes($q$
    SELECT c.zip_code, count(*) AS trips, avg(t.duration_minutes) AS avg_minutes
    FROM mobility.trip_segments t
    JOIN civics.citizens c ON c.citizen_id = t.user_id
    WHERE t.start_time >= meta.as_of() - interval '14 days'
    GROUP BY c.zip_code $q$);
COMMIT;

SELECT strategy, node, est_rows, actual_rows, loops, shared_hit
FROM join_compare ORDER BY strategy, node_id;
-- Nested Loop: cheap when the outer side is small and the inner side has an index
--   (cost ~ outer rows x index probe); loops= shows how often the inner ran.
-- Hash Join: builds a hash of the smaller input once; best for large unsorted inputs
--   (watch "Batches" > 1 = spilled because work_mem * hash_mem_multiplier was too small).
-- Merge Join: both inputs sorted on the key (by index or Sort node); good for big,
--   presorted inputs and range-ish joins.

-- =============================================================================
-- 6. SORTS, MEMORY AND INCREMENTAL SORT
-- =============================================================================
\echo '== 6. Sort spilling to disk vs in memory'

BEGIN;
SET LOCAL work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT order_id, total_amount FROM commerce.orders ORDER BY total_amount DESC, order_id;
SET LOCAL work_mem = '32MB';
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT order_id, total_amount FROM commerce.orders ORDER BY total_amount DESC, order_id;
COMMIT;
-- "external merge Disk: ...kB" + temp buffers = spilled; "quicksort Memory" = fit.

\echo '== 6b. Incremental Sort: index provides the leading sort key'
EXPLAIN (COSTS OFF)
SELECT order_id, order_date, total_amount
FROM commerce.orders
ORDER BY order_date, total_amount DESC
LIMIT 10;
-- Rows arrive ordered by order_date from idx_orders_date; only groups with equal
-- order_date need sorting by total_amount, and LIMIT stops early.

-- =============================================================================
-- 7. SARGABILITY AND MISESTIMATES: measured before/after
-- =============================================================================
\echo '== 7. Non-sargable predicate vs equivalent range predicate'

-- One calendar day (UTC), a week before the dataset's "now", written two ways.
-- Wrapping the column in a function hides it from the index and from the
-- column statistics (the planner falls back to a default 0.5% guess).
SELECT 'date_trunc(column) = day' AS variant, node, est_rows, actual_rows, total_ms
FROM analytics.explain_nodes($q$
    SELECT order_id, total_amount FROM commerce.orders
    WHERE date_trunc('day', order_date AT TIME ZONE 'UTC') = (meta.as_of() AT TIME ZONE 'UTC')::date - 7 $q$)
WHERE depth = 0
UNION ALL
SELECT 'column range [day, day+1)', node, est_rows, actual_rows, total_ms
FROM analytics.explain_nodes($q$
    SELECT order_id, total_amount FROM commerce.orders
    WHERE order_date >= ((meta.as_of() AT TIME ZONE 'UTC')::date - 7) AT TIME ZONE 'UTC'
      AND order_date <  ((meta.as_of() AT TIME ZONE 'UTC')::date - 6) AT TIME ZONE 'UTC' $q$)
WHERE depth = 0;

-- Implicit casts: comparing a varchar column with a numeric literal forces a cast
-- of the column (text = numeric is not even allowed); keep literal types aligned.
-- Correlated columns misestimate even with good per-column stats: see
-- stats_and_autovacuum.sql (CREATE STATISTICS) for the fix.

-- =============================================================================
-- 8. PLAN NODE AND ANTI-PATTERN REFERENCE
-- =============================================================================
\echo '== 8. Plan node reference'

CREATE OR REPLACE FUNCTION analytics.analyze_plan_patterns()
RETURNS TABLE (node_type text, when_used text, cost_shape text, tuning_tip text)
LANGUAGE sql IMMUTABLE AS $$
    VALUES
    ('Seq Scan',          'No usable index or low selectivity',  'O(pages), sequential I/O',          'Fine for large fractions; else add a selective index'),
    ('Index Scan',        'Selective predicate or ORDER BY',     'O(log n) per probe + random heap',  'Good for few rows; correlation affects cost'),
    ('Index Only Scan',   'All columns in the index',            'O(log n), heap only for non-all-visible pages', 'Covering index (INCLUDE) + keep tables vacuumed'),
    ('Bitmap Heap Scan',  'Medium selectivity, OR/AND of indexes','Index bitmap then heap in page order', '"lossy" blocks => raise work_mem'),
    ('Sort',              'ORDER BY/merge join without index order','O(n log n); spills beyond work_mem', 'Index on sort key or more work_mem'),
    ('Incremental Sort',  'Input already sorted by a prefix',    'Sorts small groups',                 'Multi-column index on leading keys'),
    ('HashAggregate',     'GROUP BY, unsorted input',            'O(n), memory for groups',            'Spills to disk in PG13+; watch "Disk Usage"'),
    ('Nested Loop',       'Small outer side, indexed inner',     'outer rows x inner probe',           'Wrong when outer estimate is far too low'),
    ('Hash Join',         'Large unsorted inputs, equality',     'O(n+m) + hash build',                'Batches > 1 means spill: raise work_mem/hash_mem_multiplier'),
    ('Merge Join',        'Both sides sorted on join key',       'O(n+m) after sorts',                 'Cheap with index-ordered inputs'),
    ('Memoize',           'Nested loop with repeating inner keys','Caches inner results (PG14+)',      'Check hit/miss counts in ANALYZE output'),
    ('Gather / Gather Merge','Parallel query',                    'Workers scan partitions of the work','max_parallel_workers_per_gather, table size')
$$;
SELECT * FROM analytics.analyze_plan_patterns();

CREATE OR REPLACE FUNCTION analytics.identify_slow_patterns()
RETURNS TABLE (pattern_type text, symptom_in_plan text, example_fix text, impact_level text)
LANGUAGE sql IMMUTABLE AS $$
    VALUES
    ('Function on indexed column', 'Seq Scan + Filter with function(col); rows= default guess', 'Rewrite as range on the bare column, or expression index', 'HIGH'),
    ('Correlated predicates',      'Estimate 10-100x below actual on multi-column filters', 'CREATE STATISTICS (dependencies, mcv)', 'HIGH'),
    ('N+1 queries',                'Many identical single-row statements in pg_stat_statements', 'Batch with JOIN / = ANY($1)', 'HIGH'),
    ('Type mismatch',              'Index ignored, Filter shows a cast on the column', 'Match parameter and column types', 'HIGH'),
    ('Huge OFFSET pagination',     'Limit node with large rows removed by offset', 'Keyset pagination (WHERE key > last_seen)', 'MEDIUM'),
    ('SELECT * of wide rows',      'High Serialization output in EXPLAIN (SERIALIZE)', 'Select only needed columns', 'MEDIUM'),
    ('Sort/Hash spills',           'external merge / Batches > 1 / Disk Usage', 'Raise work_mem for that query (SET LOCAL)', 'MEDIUM'),
    ('Stale statistics',           'Estimates off after bulk loads', 'ANALYZE after loads; tune autovacuum_analyze_*', 'MEDIUM')
$$;
SELECT * FROM analytics.identify_slow_patterns();

-- =============================================================================
-- 9. pg_stat_statements: WHICH queries deserve an EXPLAIN?
-- =============================================================================
\echo '== 9. pg_stat_statements top-N (this database only)'

-- Reset counters for THIS database only (other databases share the view).
SELECT pg_stat_statements_reset(0, d.oid, 0) IS NOT NULL AS reset_done
FROM pg_database d WHERE d.datname = current_database();

-- A small, repeatable workload (statements inside the DO block are tracked because
-- pg_stat_statements.track = all on this server; with 'top' only the DO would be).
DO $$
DECLARE i int; r record;
BEGIN
    FOR i IN 1..25 LOOP
        SELECT count(*), sum(total_amount) INTO r FROM commerce.orders WHERE customer_citizen_id = i;
        SELECT count(*) INTO r FROM mobility.trip_segments WHERE user_id = i AND trip_mode = 'bus';
    END LOOP;
    FOR i IN 1..5 LOOP
        SELECT count(*) INTO r FROM commerce.order_items oi JOIN commerce.orders o USING (order_id)
        WHERE o.order_date >= meta.as_of() - make_interval(days => 7 * i);
        SELECT sensor_code, avg(reading_value) AS a INTO r FROM mobility.sensor_readings
        GROUP BY sensor_code ORDER BY a DESC LIMIT 1;
    END LOOP;
END $$;

-- Top 5 by total execution time: the usual "where does the time go" list.
SELECT s.calls,
       round(s.total_exec_time::numeric, 1)  AS total_ms,
       round(s.mean_exec_time::numeric, 2)   AS mean_ms,
       s.rows,
       round(100.0 * s.shared_blks_hit / NULLIF(s.shared_blks_hit + s.shared_blks_read, 0), 1) AS cache_hit_pct,
       s.temp_blks_written,
       s.toplevel,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 70) AS query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE s.query NOT ILIKE '%pg_stat_statements%'
ORDER BY s.total_exec_time DESC
LIMIT 5;

-- Other useful orderings: mean_exec_time (slow individually), calls (chatty / N+1),
-- shared_blks_read (I/O heavy), temp_blks_written (spills), wal_bytes (write heavy).
-- Join live sessions to their statistics via query_id (PG14+):
SELECT a.pid, a.state, a.query_id, s.calls, round(s.mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_activity a
LEFT JOIN pg_stat_statements s ON s.queryid = a.query_id AND s.dbid = a.datid AND s.userid = a.usesysid AND s.toplevel
WHERE a.datname = current_database() AND a.state = 'active'
LIMIT 5;

-- =============================================================================
-- 10. auto_explain: plans of slow statements, captured automatically
-- =============================================================================
\echo '== 10. auto_explain (session-level demo; plans printed as NOTICE)'

-- In production: shared_preload_libraries or session_preload_libraries, with
-- auto_explain.log_min_duration = '500ms' and log_analyze = on (log_timing = off
-- if the clock is slow). Here we load it into this session only and send the plan
-- to the client instead of the server log.
DO $$
BEGIN
    EXECUTE 'LOAD ''auto_explain''';
    PERFORM set_config('auto_explain.log_level', 'notice', false);
    PERFORM set_config('auto_explain.log_analyze', 'on', false);
    PERFORM set_config('auto_explain.log_timing', 'off', false);
    PERFORM set_config('auto_explain.log_min_duration', '0', false);   -- last: enables logging
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'auto_explain not available (%), skipping', SQLERRM;
END $$;

SELECT count(*) AS citizens_in_zip_75105 FROM civics.citizens WHERE zip_code = '75105';

-- Switch it off again for the rest of the session.
SELECT set_config('auto_explain.log_min_duration', '-1', false) AS auto_explain_min_duration;
