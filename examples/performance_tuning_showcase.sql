-- Location: /examples/performance_tuning_showcase.sql
-- =============================================================================
-- Performance tuning showcase - before/after with real plans
-- =============================================================================
-- Demos (each section says what it teaches):
--   1. Seq Scan -> Index Scan      - a missing index on a selective predicate
--   2. What-if indexing (HypoPG)   - test an index without building it
--   3. Composite index for "latest per group" - index order = query order
--   4. Partial index               - index only the rows a hot query touches
--   5. Query rewriting             - NOT IN vs NOT EXISTS (NULL trap, anti-join)
--   6. Extended statistics         - fixing a misestimate on correlated columns
--   7. work_mem                    - sort spilling to disk vs in memory
--   8. BRIN vs B-tree              - tiny index for naturally ordered time series
--   9. Index hygiene               - duplicate and unused indexes
--
-- Safety: every index / statistics object built here is created inside a
-- transaction that is ROLLED BACK, so the base tables end exactly as they
-- started and the script can be re-run any number of times. Recency windows
-- use meta.as_of() (the dataset "now"), not now().
-- Run: psql -X -v ON_ERROR_STOP=1 -d <db> -f /examples/performance_tuning_showcase.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset null '-'

-- Fresh statistics so the "before" plans are honest.
ANALYZE civics.citizens, commerce.orders, commerce.payments, commerce.order_items, mobility.sensor_readings;

\echo ''
\echo '=== 1. Seq Scan -> Index Scan: looking a citizen up by phone number ==='
BEGIN;
\echo '--- BEFORE (no index on phone: every row is read) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT citizen_id, first_name, last_name FROM civics.citizens WHERE phone = '(972) 555-4242';

CREATE INDEX demo_citizens_phone ON civics.citizens (phone);
\echo '--- AFTER (index scan, a handful of buffers instead of the whole table) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT citizen_id, first_name, last_name FROM civics.citizens WHERE phone = '(972) 555-4242';
ROLLBACK;

\echo ''
\echo '=== 2. What-if indexing with HypoPG: would an index on payments(processed_at) be used? ==='
-- Hypothetical indexes exist only in this session's planner; nothing is built.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'hypopg') THEN
        RAISE NOTICE 'hypopg is not installed in this database - section 2 skipped';
    END IF;
END $$;
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'hypopg') AS have_hypopg \gset
\if :have_hypopg
SELECT indexname, pg_size_pretty(hypopg_relation_size(indexrelid)) AS estimated_size
FROM hypopg_create_index('CREATE INDEX ON commerce.payments (processed_at)');
-- Plain EXPLAIN only (a hypothetical index cannot be executed), and pass the
-- cut-off as a literal: HypoPG cannot cost a predicate on an expression such as
-- meta.as_of() - interval, so we materialise it with \gset first.
SELECT meta.as_of() - interval '1 day' AS since \gset
EXPLAIN (COSTS OFF)
SELECT count(*), sum(amount) FROM commerce.payments
WHERE processed_at >= :'since';
SELECT hypopg_reset();
\endif

\echo ''
\echo '=== 3. Composite index for "latest order per customer" ==='
-- DISTINCT ON (customer) ... ORDER BY customer, order_date DESC can walk an
-- index on (customer_citizen_id, order_date DESC) instead of sorting 50k rows.
BEGIN;
\echo '--- BEFORE ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT DISTINCT ON (customer_citizen_id) customer_citizen_id, order_id, order_date
FROM commerce.orders
WHERE customer_citizen_id BETWEEN 1 AND 200
ORDER BY customer_citizen_id, order_date DESC;

CREATE INDEX demo_orders_customer_date ON commerce.orders (customer_citizen_id, order_date DESC);
\echo '--- AFTER (no Sort node: rows arrive in index order) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT DISTINCT ON (customer_citizen_id) customer_citizen_id, order_id, order_date
FROM commerce.orders
WHERE customer_citizen_id BETWEEN 1 AND 200
ORDER BY customer_citizen_id, order_date DESC;
ROLLBACK;

\echo ''
\echo '=== 4. Partial index: the failed-payments work queue ==='
-- ~1.5% of payments failed. Indexing only those rows gives a tiny index that
-- matches the hot query exactly.
BEGIN;
CREATE INDEX demo_payments_failed_full    ON commerce.payments (payment_date);
CREATE INDEX demo_payments_failed_partial ON commerce.payments (payment_date) WHERE status = 'failed';
SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE indexrelname IN ('demo_payments_failed_full', 'demo_payments_failed_partial')
ORDER BY 1;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT payment_id, order_id, failure_reason
FROM commerce.payments
WHERE status = 'failed' AND payment_date >= meta.as_of() - interval '30 days'
ORDER BY payment_date DESC
LIMIT 10;
ROLLBACK;

\echo ''
\echo '=== 5. Query rewriting: citizens who never ordered - NOT IN vs NOT EXISTS ==='
-- orders.customer_citizen_id is nullable. NOT IN (subquery containing NULL)
-- yields NULL for every row, i.e. silently returns nothing - and it cannot be
-- turned into an anti-join. NOT EXISTS is both correct and faster.
-- The base data happens to have no NULL customers, so the third column adds
-- a single NULL to the list to show the trap.
SELECT (SELECT count(*) FROM civics.citizens c
        WHERE c.citizen_id NOT IN (SELECT customer_citizen_id FROM commerce.orders))       AS not_in_rows,
       (SELECT count(*) FROM civics.citizens c
        WHERE NOT EXISTS (SELECT 1 FROM commerce.orders o
                          WHERE o.customer_citizen_id = c.citizen_id))                     AS not_exists_rows,
       (SELECT count(*) FROM civics.citizens c
        WHERE c.citizen_id NOT IN (SELECT customer_citizen_id FROM commerce.orders
                                   UNION ALL SELECT NULL))                                 AS not_in_with_one_null,
       (SELECT count(*) FROM commerce.orders WHERE customer_citizen_id IS NULL)            AS orders_with_null_customer;

EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM civics.citizens c
WHERE NOT EXISTS (SELECT 1 FROM commerce.orders o WHERE o.customer_citizen_id = c.citizen_id);

\echo ''
\echo '=== 6. Extended statistics: sensor_code determines sensor_type ==='
-- The planner assumes independent columns and multiplies selectivities, so it
-- underestimates "code = X AND type = Y". A dependencies statistic fixes it.
BEGIN;
\echo '--- BEFORE: estimated rows vs actual rows ---'
EXPLAIN (ANALYZE, COSTS ON, TIMING OFF, SUMMARY OFF)
SELECT * FROM mobility.sensor_readings WHERE sensor_code = 'AQI-001' AND sensor_type = 'air_quality';

CREATE STATISTICS demo_sensor_code_type (dependencies) ON sensor_code, sensor_type FROM mobility.sensor_readings;
ANALYZE mobility.sensor_readings;   -- allowed inside a transaction; rolled back with it
\echo '--- AFTER: the estimate now matches reality ---'
EXPLAIN (ANALYZE, COSTS ON, TIMING OFF, SUMMARY OFF)
SELECT * FROM mobility.sensor_readings WHERE sensor_code = 'AQI-001' AND sensor_type = 'air_quality';
ROLLBACK;

\echo ''
\echo '=== 7. work_mem: the same sort on disk vs in memory ==='
BEGIN;
SET LOCAL work_mem = '64kB';
\echo '--- work_mem = 64kB: external merge (spills to temp files) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT item_id, line_total FROM commerce.order_items ORDER BY line_total DESC, item_id OFFSET 100000 LIMIT 5;
SET LOCAL work_mem = '64MB';
\echo '--- work_mem = 64MB: quicksort in memory ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT item_id, line_total FROM commerce.order_items ORDER BY line_total DESC, item_id OFFSET 100000 LIMIT 5;
ROLLBACK;

\echo ''
\echo '=== 8. BRIN vs B-tree on an append-ordered time column ==='
-- reading_time is physically ordered (correlation ~1), so a BRIN index of
-- block ranges is a tiny fraction of the B-tree and still prunes well.
-- minmax_multi (PG14+) tolerates a few out-of-order outliers per range.
BEGIN;
CREATE INDEX demo_sensors_time_brin ON mobility.sensor_readings
    USING brin (reading_time timestamptz_minmax_multi_ops) WITH (pages_per_range = 16);
SELECT (SELECT correlation FROM pg_stats
        WHERE schemaname = 'mobility' AND tablename = 'sensor_readings' AND attname = 'reading_time') AS correlation,
       pg_size_pretty(pg_relation_size('mobility.idx_sensors_time_only')) AS btree_size,
       pg_size_pretty(pg_relation_size('mobility.demo_sensors_time_brin')) AS brin_size;
SET LOCAL enable_indexscan = off;      -- let the BRIN bitmap path show itself
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), avg(reading_value) FROM mobility.sensor_readings
WHERE reading_time >= meta.as_of() - interval '1 day';
ROLLBACK;

\echo ''
\echo '=== 9. Index hygiene: duplicate indexes (same table, same definition) ==='
-- Duplicates cost write amplification and memory for zero read benefit.
SELECT a.indrelid::regclass AS table_name,
       a.indexrelid::regclass AS index_a,
       b.indexrelid::regclass AS index_b,
       pg_size_pretty(pg_relation_size(b.indexrelid)) AS wasted
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid
               AND a.indexrelid < b.indexrelid
               AND a.indkey::text = b.indkey::text
               AND a.indclass::text = b.indclass::text
               AND coalesce(pg_get_expr(a.indpred, a.indrelid), '') = coalesce(pg_get_expr(b.indpred, b.indrelid), '')
               AND coalesce(pg_get_expr(a.indexprs, a.indrelid), '') = coalesce(pg_get_expr(b.indexprs, b.indrelid), '')
JOIN pg_class c ON c.oid = a.indrelid
WHERE c.relnamespace::regnamespace::text IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
ORDER BY 1, 2;

\echo ''
\echo '--- largest never-scanned indexes since the last stats reset ---'
SELECT schemaname || '.' || relname AS table_name, indexrelname AS index_name, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
  AND idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 5;

-- Take-aways:
--   * Read plans with BUFFERS: buffers touched is a hardware-independent cost.
--   * Index the predicate you actually run (composite order, partial WHERE).
--   * Try ideas with HypoPG / BEGIN ... ROLLBACK before building for real
--     (and use CREATE INDEX CONCURRENTLY on a live system).
--   * Fix estimates (ANALYZE, extended statistics) before reaching for hints.
--   * Prefer NOT EXISTS over NOT IN for anti-joins.
--   * Right-size work_mem per query (SET LOCAL), not globally.
--   * BRIN for huge, naturally ordered tables; drop duplicate/unused indexes.
