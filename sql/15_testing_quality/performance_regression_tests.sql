-- File: sql/15_testing_quality/performance_regression_tests.sql
-- Purpose: query-performance regression testing inside PostgreSQL.
--
-- What this module teaches
--   1. Measure, don't guess: run each benchmark query N times (after warm-up) and keep the
--      whole sample. Report the MEDIAN (robust to one slow outlier) and the P95 (the tail
--      users feel), never a single run or the mean alone.
--   2. Two timing methods:
--        'explain' - EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) -> "Execution Time".
--                    Server-side executor time only; excludes parse/plan and sending rows.
--        'clock'   - clock_timestamp() around EXECUTE in PL/pgSQL, wrapping the query in
--                    SELECT count(*) so every row is produced. Includes planning.
--   3. Plan-shape regression: store the plan's node tree (node type + index + relation) from
--      EXPLAIN (FORMAT JSON). A changed shape is often the CAUSE of a timing regression and
--      is deterministic, so it is a far less noisy CI signal than wall-clock time.
--   4. A baseline table + a comparison function that flags regressions only when BOTH the
--      relative threshold (e.g. 1.5x median) AND an absolute floor (e.g. +2 ms) are
--      exceeded, so sub-millisecond jitter on fast queries does not page anyone.
--   5. A controlled experiment: drop an index on a module-owned copy of commerce.orders and
--      watch the suite flag the regression and the plan change, then restore it.
--
-- Standalone and idempotent. It never modifies base tables: the regression experiment runs
-- on performance.orders_bench, a module-owned copy.
--
-- Fixed from the previous version of this file:
--   * "cannot use subquery in column generation expression": a GENERATED column may only
--     reference columns of its own row. The baseline/current ratio is now computed by the
--     comparison function (and exposed by a view) instead of a generated column.
--   * pg_stat_user_indexes has columns relname / indexrelname (not tablename / indexname),
--     and the usage ratio divided by idx_tup_read without guarding against zero.
--   * Recency filters used CURRENT_DATE against a dataset that ends at meta.as_of().

\echo '== 15 / performance_regression_tests: baselines, percentiles and plan-shape checks =='

CREATE SCHEMA IF NOT EXISTS performance;
COMMENT ON SCHEMA performance IS 'Module 15: benchmark registry, timing baselines and regression checks.';

-- =============================================================================
-- 1. TABLES
-- =============================================================================

-- The benchmark registry: one row per query we care about.
CREATE TABLE IF NOT EXISTS performance.benchmark_queries (
    query_name   text PRIMARY KEY,
    category     text NOT NULL DEFAULT 'general',
    description  text,
    query_text   text NOT NULL,
    is_active    boolean NOT NULL DEFAULT true
);

-- Regression thresholds per category. Relative ratios catch proportional slowdowns; the
-- absolute floors stop micro-second jitter on fast queries (and the naturally noisy tail
-- of a 15-run sample) from being reported. Analytics queries get wider floors.
CREATE TABLE IF NOT EXISTS performance.thresholds (
    category             text PRIMARY KEY,
    max_median_ratio     numeric NOT NULL DEFAULT 1.5,   -- current median / baseline median
    min_median_delta_ms  numeric NOT NULL DEFAULT 2.0,   -- ... and at least this much slower
    max_p95_ratio        numeric NOT NULL DEFAULT 2.5,
    min_p95_delta_ms     numeric NOT NULL DEFAULT 10.0,
    fail_on_plan_change  boolean NOT NULL DEFAULT false
);
INSERT INTO performance.thresholds AS t
    (category, max_median_ratio, min_median_delta_ms, max_p95_ratio, min_p95_delta_ms, fail_on_plan_change)
VALUES ('general',   1.5,  2.0, 2.5,  10.0, false),
       ('lookup',    1.5,  2.0, 2.5,  10.0, true),   -- a point lookup must keep its index plan
       ('analytics', 1.5, 25.0, 2.5, 100.0, false)
ON CONFLICT (category) DO UPDATE
    SET max_median_ratio = EXCLUDED.max_median_ratio, min_median_delta_ms = EXCLUDED.min_median_delta_ms,
        max_p95_ratio = EXCLUDED.max_p95_ratio, min_p95_delta_ms = EXCLUDED.min_p95_delta_ms,
        fail_on_plan_change = EXCLUDED.fail_on_plan_change;

-- Generated columns may only call IMMUTABLE functions. array_to_string() is STABLE in
-- general (it calls element output functions), but for text[] it is deterministic, so we
-- wrap it in a function we declare IMMUTABLE. Only do this when it is genuinely true.
CREATE OR REPLACE FUNCTION performance.shape_hash(p_shape text[])
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT md5(array_to_string(p_shape, '|')) $$;

-- Every measurement (baseline or check) lands here: the raw history.
CREATE TABLE IF NOT EXISTS performance.measurements (
    measurement_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    query_name     text NOT NULL REFERENCES performance.benchmark_queries (query_name) ON DELETE CASCADE,
    purpose        text NOT NULL CHECK (purpose IN ('baseline', 'check')),
    label          text,                              -- e.g. git sha, release, "after VACUUM"
    method         text NOT NULL CHECK (method IN ('explain', 'clock')),
    measured_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    n_runs         integer NOT NULL,
    samples_ms     numeric[] NOT NULL,
    median_ms      numeric(12,3) NOT NULL,
    p95_ms         numeric(12,3) NOT NULL,
    mean_ms        numeric(12,3) NOT NULL,
    stddev_ms      numeric(12,3),
    min_ms         numeric(12,3) NOT NULL,
    max_ms         numeric(12,3) NOT NULL,
    planning_ms    numeric(12,3),
    total_cost     numeric,
    plan_rows      numeric,
    plan_shape     text[] NOT NULL,
    plan_hash      text GENERATED ALWAYS AS (performance.shape_hash(plan_shape)) STORED,
    server_version text NOT NULL DEFAULT current_setting('server_version')
);
-- (plan_hash IS a legal generated column: it only reads plan_shape from the same row,
--  through an immutable function.)

-- The active baseline per query: exactly one, enforced by a partial unique index.
CREATE TABLE IF NOT EXISTS performance.baselines (
    query_name     text NOT NULL REFERENCES performance.benchmark_queries (query_name) ON DELETE CASCADE,
    measurement_id bigint NOT NULL REFERENCES performance.measurements (measurement_id) ON DELETE CASCADE,
    is_active      boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_baselines_active
    ON performance.baselines (query_name) WHERE is_active;

-- Verdicts of every comparison.
CREATE TABLE IF NOT EXISTS performance.regression_results (
    result_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    query_name        text NOT NULL,
    baseline_id       bigint NOT NULL REFERENCES performance.measurements (measurement_id) ON DELETE CASCADE,
    check_id          bigint NOT NULL REFERENCES performance.measurements (measurement_id) ON DELETE CASCADE,
    median_ratio      numeric(10,3),
    p95_ratio         numeric(10,3),
    plan_changed      boolean NOT NULL,
    verdict           text NOT NULL,
    checked_at        timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- =============================================================================
-- 2. HELPERS: plan shape and timing
-- =============================================================================

-- 2a. Flatten EXPLAIN (FORMAT JSON) into an ordered array of node labels.
--     A recursive CTE walks "Plan" -> "Plans"[] and records each node's depth-first path,
--     so the array order is deterministic. Each label is indented by depth.
CREATE OR REPLACE FUNCTION performance.plan_shape(p_explain jsonb)
RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
    WITH RECURSIVE node(n, path) AS (
        SELECT p_explain -> 0 -> 'Plan', ARRAY[1]
        UNION ALL
        SELECT c.value, node.path || c.ord::int
        FROM node, jsonb_array_elements(node.n -> 'Plans') WITH ORDINALITY AS c(value, ord)
    )
    SELECT array_agg(
               repeat('  ', cardinality(path) - 1)
               || (n ->> 'Node Type')
               || coalesce(' using ' || (n ->> 'Index Name'), '')
               || coalesce(' on ' || (n ->> 'Relation Name'), '')
           ORDER BY path)
    FROM node
$$;
COMMENT ON FUNCTION performance.plan_shape(jsonb)
    IS 'Depth-first list of plan nodes (type, index, relation) from EXPLAIN (FORMAT JSON).';

-- 2b. Run a query N times and summarise. Returns the raw sample too.
CREATE OR REPLACE FUNCTION performance.time_query(
    p_sql    text,
    p_runs   integer DEFAULT 15,
    p_warmup integer DEFAULT 2,
    p_method text    DEFAULT 'explain')
RETURNS TABLE (samples_ms numeric[], median_ms numeric, p95_ms numeric, mean_ms numeric,
               stddev_ms numeric, min_ms numeric, max_ms numeric, planning_ms numeric,
               total_cost numeric, plan_rows numeric, plan_shape text[])
LANGUAGE plpgsql AS $$
DECLARE
    v_json    json;
    v_plan    jsonb;
    v_t0      timestamptz;
    v_ms      numeric;
    v_plan_ms numeric[] := '{}';
    v_samples numeric[] := '{}';
    v_dummy   bigint;
BEGIN
    IF p_method NOT IN ('explain', 'clock') THEN
        RAISE EXCEPTION 'unknown method %, use explain or clock', p_method;
    END IF;

    -- The plan we store: plain EXPLAIN (no ANALYZE) is enough for the shape and cost.
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || p_sql INTO v_json;
    v_plan := v_json::jsonb;

    FOR i IN 1 .. p_warmup + p_runs LOOP
        IF p_method = 'explain' THEN
            -- TIMING OFF: no per-node clock calls, so the overhead stays small.
            EXECUTE 'EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) ' || p_sql INTO v_json;
            v_ms := (v_json::jsonb -> 0 ->> 'Execution Time')::numeric;
            IF i > p_warmup THEN
                v_plan_ms := v_plan_ms || (v_json::jsonb -> 0 ->> 'Planning Time')::numeric;
            END IF;
        ELSE
            v_t0 := clock_timestamp();
            EXECUTE 'SELECT count(*) FROM (' || p_sql || ') AS q' INTO v_dummy;
            v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
        END IF;
        IF i > p_warmup THEN                     -- warm-up runs fill the cache, then are discarded
            v_samples := v_samples || round(v_ms, 3);
        END IF;
    END LOOP;

    RETURN QUERY
    SELECT v_samples,
           round(percentile_cont(0.50) WITHIN GROUP (ORDER BY s)::numeric, 3),
           round(percentile_cont(0.95) WITHIN GROUP (ORDER BY s)::numeric, 3),
           round(avg(s), 3), round(stddev_samp(s), 3), min(s), max(s),
           (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY p)::numeric, 3) FROM unnest(v_plan_ms) p),
           (v_plan -> 0 -> 'Plan' ->> 'Total Cost')::numeric,
           (v_plan -> 0 -> 'Plan' ->> 'Plan Rows')::numeric,
           performance.plan_shape(v_plan)
    FROM unnest(v_samples) AS s;
END;
$$;

-- 2c. Measure a registered query and store the measurement.
CREATE OR REPLACE FUNCTION performance.measure(
    p_query_name text,
    p_purpose    text    DEFAULT 'check',
    p_runs       integer DEFAULT 15,
    p_label      text    DEFAULT NULL,
    p_method     text    DEFAULT 'explain')
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_sql text;
    t     record;
    v_id  bigint;
BEGIN
    SELECT query_text INTO STRICT v_sql
    FROM performance.benchmark_queries WHERE query_name = p_query_name;

    SELECT * INTO t FROM performance.time_query(v_sql, p_runs, 2, p_method);

    INSERT INTO performance.measurements
        (query_name, purpose, label, method, n_runs, samples_ms, median_ms, p95_ms, mean_ms,
         stddev_ms, min_ms, max_ms, planning_ms, total_cost, plan_rows, plan_shape)
    VALUES (p_query_name, p_purpose, p_label, p_method, p_runs, t.samples_ms, t.median_ms, t.p95_ms,
            t.mean_ms, t.stddev_ms, t.min_ms, t.max_ms, t.planning_ms, t.total_cost, t.plan_rows,
            t.plan_shape)
    RETURNING measurement_id INTO v_id;
    RETURN v_id;
END;
$$;

-- 2d. Capture (or replace) the baseline for one query, or for all active queries.
CREATE OR REPLACE FUNCTION performance.capture_baselines(
    p_query_name text DEFAULT NULL,
    p_runs       integer DEFAULT 15,
    p_label      text DEFAULT 'baseline')
RETURNS TABLE (query_name text, median_ms numeric, p95_ms numeric, plan_nodes integer)
LANGUAGE plpgsql AS $$
DECLARE
    q    record;
    v_id bigint;
BEGIN
    FOR q IN SELECT b.query_name FROM performance.benchmark_queries b
             WHERE b.is_active AND (p_query_name IS NULL OR b.query_name = p_query_name)
             ORDER BY b.query_name
    LOOP
        v_id := performance.measure(q.query_name, 'baseline', p_runs, p_label);
        UPDATE performance.baselines b SET is_active = false
         WHERE b.query_name = q.query_name AND b.is_active;
        INSERT INTO performance.baselines (query_name, measurement_id) VALUES (q.query_name, v_id);

        RETURN QUERY
        SELECT m.query_name, m.median_ms, m.p95_ms, cardinality(m.plan_shape)
        FROM performance.measurements m WHERE m.measurement_id = v_id;
    END LOOP;
END;
$$;

-- =============================================================================
-- 3. THE COMPARISON FUNCTION
-- =============================================================================
-- Verdicts:
--   REGRESSION    median or p95 ratio over threshold AND the absolute slowdown >= floor,
--                 or (for categories with fail_on_plan_change) the plan shape changed
--   PLAN_CHANGED  timing within limits but the plan is different: review it
--   IMPROVED      median at least 1/ratio faster (consider re-baselining)
--   OK            everything within limits
CREATE OR REPLACE FUNCTION performance.check_regressions(
    p_query_name text DEFAULT NULL,
    p_runs       integer DEFAULT 15,
    p_label      text DEFAULT NULL)
RETURNS TABLE (query_name text, base_median_ms numeric, cur_median_ms numeric, median_ratio numeric,
               base_p95_ms numeric, cur_p95_ms numeric, p95_ratio numeric,
               plan_changed boolean, verdict text, nodes_removed text[], nodes_added text[])
LANGUAGE plpgsql AS $$
DECLARE
    q       record;
    b       performance.measurements%ROWTYPE;
    c       performance.measurements%ROWTYPE;
    th      performance.thresholds%ROWTYPE;
    v_cid   bigint;
    v_mr    numeric;
    v_pr    numeric;
    v_chg   boolean;
    v_verd  text;
BEGIN
    FOR q IN SELECT bq.query_name, bq.category, bl.measurement_id
             FROM performance.benchmark_queries bq
             JOIN performance.baselines bl ON bl.query_name = bq.query_name AND bl.is_active
             WHERE bq.is_active AND (p_query_name IS NULL OR bq.query_name = p_query_name)
             ORDER BY bq.query_name
    LOOP
        SELECT * INTO b FROM performance.measurements m WHERE m.measurement_id = q.measurement_id;
        SELECT * INTO th FROM performance.thresholds t WHERE t.category = q.category;
        IF NOT FOUND THEN
            SELECT * INTO th FROM performance.thresholds t WHERE t.category = 'general';
        END IF;

        v_cid := performance.measure(q.query_name, 'check', p_runs, p_label, b.method);
        SELECT * INTO c FROM performance.measurements m WHERE m.measurement_id = v_cid;

        v_mr  := round(c.median_ms / nullif(b.median_ms, 0), 3);
        v_pr  := round(c.p95_ms / nullif(b.p95_ms, 0), 3);
        v_chg := c.plan_hash IS DISTINCT FROM b.plan_hash;

        v_verd := CASE
            WHEN (v_mr > th.max_median_ratio AND c.median_ms - b.median_ms >= th.min_median_delta_ms)
              OR (v_pr > th.max_p95_ratio    AND c.p95_ms    - b.p95_ms    >= th.min_p95_delta_ms)
              OR (v_chg AND th.fail_on_plan_change)            THEN 'REGRESSION'
            WHEN v_chg                                         THEN 'PLAN_CHANGED'
            WHEN v_mr < 1 / th.max_median_ratio
             AND b.median_ms - c.median_ms >= th.min_median_delta_ms THEN 'IMPROVED'
            ELSE 'OK' END;

        INSERT INTO performance.regression_results
            (query_name, baseline_id, check_id, median_ratio, p95_ratio, plan_changed, verdict)
        VALUES (q.query_name, b.measurement_id, c.measurement_id, v_mr, v_pr, v_chg, v_verd);

        query_name := q.query_name;
        base_median_ms := b.median_ms; cur_median_ms := c.median_ms; median_ratio := v_mr;
        base_p95_ms := b.p95_ms;       cur_p95_ms := c.p95_ms;       p95_ratio := v_pr;
        plan_changed := v_chg; verdict := v_verd;
        -- shape diff, ignoring indentation: which node labels disappeared / appeared
        nodes_removed := ARRAY(SELECT ltrim(x) FROM unnest(b.plan_shape) x
                               EXCEPT SELECT ltrim(y) FROM unnest(c.plan_shape) y ORDER BY 1);
        nodes_added   := ARRAY(SELECT ltrim(y) FROM unnest(c.plan_shape) y
                               EXCEPT SELECT ltrim(x) FROM unnest(b.plan_shape) x ORDER BY 1);
        RETURN NEXT;
    END LOOP;
END;
$$;

-- =============================================================================
-- 4. BENCHMARK QUERIES
-- =============================================================================
-- Recency windows use meta.as_of(), the dataset clock (the data ends 2025-12-31).
INSERT INTO performance.benchmark_queries (query_name, category, description, query_text) VALUES
('citizen_by_email', 'lookup',
 'Point lookup through the unique index on email.',
 $q$SELECT citizen_id, first_name, last_name FROM civics.citizens
    WHERE email = 'michelle.roberts.1@mail.polaris.example'$q$),
('orders_last_7d', 'lookup',
 'Range scan on idx_orders_date for the final week of the dataset.',
 $q$SELECT order_id, merchant_id, total_amount FROM commerce.orders
    WHERE order_date >= meta.as_of() - interval '7 days'$q$),
('sensor_last_day', 'lookup',
 'Latest 24 h of one sensor via the (sensor_code, reading_time DESC) index.',
 $q$SELECT reading_time, reading_value FROM mobility.sensor_readings
    WHERE sensor_code = 'TRF-001' AND reading_time >= meta.as_of() - interval '1 day'
    ORDER BY reading_time DESC$q$),
('pois_within_1km', 'lookup',
 'Geodesic radius search through geo.find_nearby_pois.',
 $q$SELECT poi_id, distance_meters FROM geo.find_nearby_pois(32.99, -96.80, 1000)$q$),
('merchant_revenue_90d', 'analytics',
 'Join + aggregate: top merchants by revenue over the last 90 days.',
 $q$SELECT m.merchant_id, m.business_name, count(*) AS orders, sum(o.total_amount) AS revenue
    FROM commerce.orders o JOIN commerce.merchants m USING (merchant_id)
    WHERE o.order_date >= meta.as_of() - interval '90 days' AND o.status = 'delivered'
    GROUP BY m.merchant_id, m.business_name
    ORDER BY revenue DESC LIMIT 20$q$)
ON CONFLICT (query_name) DO UPDATE
    SET category = EXCLUDED.category, description = EXCLUDED.description,
        query_text = EXCLUDED.query_text, is_active = true;

-- =============================================================================
-- 5. CAPTURE BASELINES, THEN CHECK AGAINST THEM
-- =============================================================================
-- Statistics first: plans (and therefore baselines) depend on them.
ANALYZE civics.citizens, commerce.orders, commerce.merchants, mobility.sensor_readings, geo.points_of_interest;

\echo '-- 5a. baselines (median / p95 of 15 runs after 2 warm-ups)'
SELECT query_name, median_ms, p95_ms, plan_nodes
FROM performance.capture_baselines(p_query_name => NULL, p_runs => 15, p_label => 'module-15 baseline')
WHERE query_name <> 'bench_orders_by_customer'
ORDER BY query_name;

\echo '-- 5b. the stored plan shape of one baseline'
SELECT unnest(m.plan_shape) AS plan_node
FROM performance.baselines b JOIN performance.measurements m USING (measurement_id)
WHERE b.query_name = 'merchant_revenue_90d' AND b.is_active;

-- Nothing changed, so every verdict should be OK. On a busy machine timings still move
-- (a 15-run p95 is especially noisy); that is exactly what the absolute floors absorb.
\echo '-- 5c. immediate re-check: expect OK'
SELECT query_name, base_median_ms, cur_median_ms, median_ratio, p95_ratio, plan_changed, verdict
FROM performance.check_regressions(p_label => 'no change')
WHERE query_name <> 'bench_orders_by_customer'
ORDER BY query_name;

-- =============================================================================
-- 6. CONTROLLED EXPERIMENT: A MIGRATION DROPS AN INDEX
-- =============================================================================
-- Module-owned copy of commerce.orders so the base table is never touched.
\echo '-- 6. regression experiment on performance.orders_bench'
DROP TABLE IF EXISTS performance.orders_bench CASCADE;
CREATE TABLE performance.orders_bench AS
SELECT order_id, merchant_id, customer_citizen_id, order_date, status, total_amount
FROM commerce.orders;
ALTER TABLE performance.orders_bench ADD PRIMARY KEY (order_id);
CREATE INDEX idx_orders_bench_customer ON performance.orders_bench (customer_citizen_id);
ANALYZE performance.orders_bench;

INSERT INTO performance.benchmark_queries (query_name, category, description, query_text) VALUES
('bench_orders_by_customer', 'lookup',
 'All orders of one customer (index on customer_citizen_id). Category lookup: a plan change
  alone is a regression, so the verdict does not depend on how fast this machine scans.',
 $q$SELECT order_id, order_date, total_amount FROM performance.orders_bench
    WHERE customer_citizen_id = 4242 ORDER BY order_date$q$)
ON CONFLICT (query_name) DO UPDATE
    SET category = EXCLUDED.category, description = EXCLUDED.description,
        query_text = EXCLUDED.query_text, is_active = true;

SELECT query_name, median_ms, p95_ms, plan_nodes
FROM performance.capture_baselines('bench_orders_by_customer', 15, 'with index');

-- "Release 2" drops the index (a cleanup script thought it was unused) ...
DROP INDEX performance.idx_orders_bench_customer;

\echo '-- 6a. after DROP INDEX: expect REGRESSION with Seq Scan replacing the index scan'
SELECT query_name, base_median_ms, cur_median_ms, median_ratio, plan_changed, verdict,
       nodes_removed, nodes_added
FROM performance.check_regressions('bench_orders_by_customer', 15, 'index dropped');

-- ... and the fix restores it.
CREATE INDEX idx_orders_bench_customer ON performance.orders_bench (customer_citizen_id);
ANALYZE performance.orders_bench;

\echo '-- 6b. after re-creating the index: expect OK again'
SELECT query_name, base_median_ms, cur_median_ms, median_ratio, plan_changed, verdict
FROM performance.check_regressions('bench_orders_by_customer', 15, 'index restored');

-- Same experiment without DDL: planner switches simulate "the index became unusable".
-- SET only affects this session; RESET puts it back.
SET enable_indexscan = off;
SET enable_bitmapscan = off;
\echo '-- 6c. index scans disabled by planner settings: the lookup category fails on plan change alone'
SELECT query_name, median_ratio, plan_changed, verdict, nodes_added
FROM performance.check_regressions('citizen_by_email', 15, 'enable_indexscan=off');
RESET enable_indexscan;
RESET enable_bitmapscan;

-- =============================================================================
-- 7. TIMING METHODS COMPARED
-- =============================================================================
-- clock_timestamp() includes planning and PL/pgSQL overhead; EXPLAIN ANALYZE reports only
-- executor time. Compare both on the same query; never mix methods within one baseline
-- (check_regressions re-measures with the baseline's method for that reason).
\echo '-- 7. explain vs clock timing for the same query'
SELECT 'explain' AS method, median_ms, p95_ms, planning_ms
FROM performance.time_query((SELECT query_text FROM performance.benchmark_queries
                             WHERE query_name = 'merchant_revenue_90d'), 10, 2, 'explain')
UNION ALL
SELECT 'clock', median_ms, p95_ms, NULL
FROM performance.time_query((SELECT query_text FROM performance.benchmark_queries
                             WHERE query_name = 'merchant_revenue_90d'), 10, 2, 'clock');

-- =============================================================================
-- 8. REPORTING VIEWS
-- =============================================================================

-- Latest verdict per query with ratios computed at read time (the replacement for the old
-- generated column that tried to use a subquery).
CREATE OR REPLACE VIEW performance.latest_verdicts AS
SELECT DISTINCT ON (r.query_name)
       r.query_name, r.checked_at, r.verdict, r.median_ratio, r.p95_ratio, r.plan_changed,
       b.median_ms AS base_median_ms, c.median_ms AS cur_median_ms,
       b.p95_ms    AS base_p95_ms,    c.p95_ms    AS cur_p95_ms, c.label
FROM performance.regression_results r
JOIN performance.measurements b ON b.measurement_id = r.baseline_id
JOIN performance.measurements c ON c.measurement_id = r.check_id
ORDER BY r.query_name, r.checked_at DESC, r.result_id DESC;

-- Trend of medians per query across all measurements.
CREATE OR REPLACE VIEW performance.median_trend AS
SELECT query_name, measured_at, purpose, label, method, median_ms, p95_ms, plan_hash,
       median_ms / nullif(lag(median_ms) OVER w, 0) AS ratio_vs_previous
FROM performance.measurements
WINDOW w AS (PARTITION BY query_name, method ORDER BY measured_at, measurement_id);

-- Index usage from the cumulative statistics system (columns are relname / indexrelname).
CREATE OR REPLACE VIEW performance.index_usage AS
SELECT s.schemaname, s.relname AS table_name, s.indexrelname AS index_name,
       s.idx_scan, s.idx_tup_read, s.idx_tup_fetch,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       i.indisunique OR i.indisprimary AS enforces_constraint,
       CASE
           WHEN i.indisunique OR i.indisprimary THEN 'keep: enforces a constraint'
           WHEN s.idx_scan = 0 THEN 'unused since stats reset: candidate to drop (verify on replicas first)'
           WHEN s.idx_tup_read > 100 * greatest(s.idx_tup_fetch, 1) THEN 'reads many entries per fetched row: review selectivity'
           ELSE 'in use'
       END AS assessment
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents');

\echo '-- 8. latest verdicts'
SELECT query_name, verdict, median_ratio, p95_ratio, plan_changed, label
FROM performance.latest_verdicts ORDER BY query_name;

\echo '-- 8b. largest never-scanned, non-constraint indexes (cumulative stats; varies by history)'
SELECT schemaname, table_name, index_name, index_size, assessment
FROM performance.index_usage
WHERE idx_scan = 0 AND NOT enforces_constraint
ORDER BY pg_relation_size((quote_ident(schemaname) || '.' || quote_ident(index_name))::regclass) DESC, index_name
LIMIT 5;

-- =============================================================================
-- 9. USAGE CHEAT-SHEET
-- =============================================================================
/*
-- Before a release: baseline everything (re-run after intentional changes).
SELECT * FROM performance.capture_baselines(p_label => 'v1.4.0');

-- After deploying: compare. Wire this into CI and fail the job on any REGRESSION.
SELECT * FROM performance.check_regressions(p_label => 'v1.5.0-rc1')
WHERE verdict = 'REGRESSION';

-- Inspect a plan change:
SELECT purpose, label, unnest(plan_shape) FROM performance.measurements
WHERE query_name = 'orders_last_7d' ORDER BY measurement_id DESC LIMIT 20;

-- Complementary production view: pg_stat_statements (preloaded in this image) aggregates
-- mean_exec_time / stddev_exec_time per normalised query across ALL sessions:
--   SELECT query, calls, mean_exec_time, stddev_exec_time FROM pg_stat_statements
--   ORDER BY total_exec_time DESC LIMIT 10;
-- (requires CREATE EXTENSION pg_stat_statements in the database you query from)
*/
