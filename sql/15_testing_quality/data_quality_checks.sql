-- File: sql/15_testing_quality/data_quality_checks.sql
-- Purpose: a reusable, rule-driven data-quality (DQ) framework.
--
-- What this module teaches
--   1. Rules as DATA: each check is a row in a registry (data_quality.dq_rules) holding
--      a SQL snippet, a quality dimension, a severity and a pass threshold. Adding a check
--      is an INSERT, not a new function.
--   2. One runner (data_quality.run_rules) executes every rule with dynamic SQL, times it
--      with clock_timestamp(), isolates failures per rule (a broken rule records an error
--      instead of aborting the run) and appends results to a history table.
--   3. The classic DQ dimensions: completeness, validity, uniqueness, referential
--      integrity, timeliness (relative to meta.as_of(), never now()) and distribution drift
--      (Population Stability Index).
--   4. Statistical checks: a robust z-score (median / MAD) outlier rule on
--      commerce.orders.total_amount, evaluated against the labelled anomalies in
--      meta.ground_truth (precision / recall / F1).
--   5. A landing-zone gate: rules run against a module-owned staging table with injected
--      defects, bad rows are quarantined, and the rules are re-run.
--
-- Standalone and idempotent: depends only on the base dataset; safe to run repeatedly.
-- It never modifies base tables (all writes go to the module-owned data_quality schema).

\echo '== 15 / data_quality_checks: rule-driven data-quality framework =='

CREATE SCHEMA IF NOT EXISTS data_quality;
COMMENT ON SCHEMA data_quality IS 'Module 15: rule registry, runner, results history and DQ helpers.';

-- =============================================================================
-- 1. REGISTRY AND RESULT TABLES
-- =============================================================================
-- Contract for a rule's check_sql: it must return exactly ONE row with three columns
--     failed  bigint   -- how many units (rows, groups, sensors...) violate the rule
--     total   bigint   -- how many units were examined
--     metric  numeric  -- an optional scalar (lag in hours, PSI, max z ...)
-- A rule PASSES when failed/total <= max_failed_ratio AND (max_metric IS NULL OR metric <= max_metric).
-- Optional sample_sql returns (record_id text, detail text) for a few offending rows; the
-- runner stores them in data_quality.quality_issues for triage.

CREATE TABLE IF NOT EXISTS data_quality.dq_rules (
    rule_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_name         text NOT NULL UNIQUE,
    suite             text NOT NULL DEFAULT 'production',   -- group of rules run together
    dimension         text NOT NULL CHECK (dimension IN (
                          'completeness', 'validity', 'uniqueness', 'referential_integrity',
                          'timeliness', 'distribution_drift', 'statistical_outlier')),
    target_table      text NOT NULL,          -- what the rule is about (used for filtering)
    target_column     text,
    description       text NOT NULL,
    check_sql         text NOT NULL,
    sample_sql        text,
    max_failed_ratio  numeric NOT NULL DEFAULT 0 CHECK (max_failed_ratio BETWEEN 0 AND 1),
    max_metric        numeric,
    severity          text NOT NULL DEFAULT 'medium'
                          CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    is_active         boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

-- One row per invocation of the runner.
CREATE TABLE IF NOT EXISTS data_quality.dq_runs (
    run_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at   timestamptz,
    data_as_of    timestamptz,                -- the dataset's reference "now" (meta.as_of())
    filter_note   text,
    rules_run     integer,
    rules_failed  integer,
    rules_errored integer
);

-- One row per rule per run: the history you trend and alert on.
CREATE TABLE IF NOT EXISTS data_quality.dq_results (
    result_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        bigint NOT NULL REFERENCES data_quality.dq_runs (run_id) ON DELETE CASCADE,
    rule_id       integer NOT NULL REFERENCES data_quality.dq_rules (rule_id) ON DELETE CASCADE,
    executed_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    failed_count  bigint,
    total_count   bigint,
    failed_ratio  numeric GENERATED ALWAYS AS (
                      CASE WHEN total_count > 0 THEN failed_count::numeric / total_count END) STORED,
    metric        numeric,
    passed        boolean NOT NULL,
    duration_ms   numeric(12,3),
    error_message text
);
CREATE INDEX IF NOT EXISTS idx_dq_results_rule_time ON data_quality.dq_results (rule_id, executed_at DESC);

-- Row-level samples of offending records (open until a later run no longer sees them).
-- detected_at / resolved_at are also read by sql/16_capstones/citywide_analytics_dashboard.sql.
CREATE TABLE IF NOT EXISTS data_quality.quality_issues (
    issue_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id            bigint REFERENCES data_quality.dq_runs (run_id) ON DELETE CASCADE,
    check_name        text NOT NULL,
    issue_type        text NOT NULL,          -- the rule's dimension
    table_name        text NOT NULL,
    column_name       text,
    record_id         text,
    issue_description text NOT NULL,
    severity          text NOT NULL DEFAULT 'medium',
    detected_at       timestamptz NOT NULL DEFAULT now(),
    resolved_at       timestamptz,
    resolution_notes  text
);
CREATE INDEX IF NOT EXISTS idx_quality_issues_open
    ON data_quality.quality_issues (check_name) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_quality_issues_detected_at ON data_quality.quality_issues (detected_at);

-- =============================================================================
-- 2. STATISTICAL HELPERS
-- =============================================================================

-- 2a. Population Stability Index between a reference and a current sample.
--     Buckets are the reference deciles (quantile binning), empty bins are floored at
--     1e-4 so ln() stays finite. Rule of thumb: < 0.10 stable, 0.10-0.25 moderate shift,
--     > 0.25 significant shift.
CREATE OR REPLACE FUNCTION data_quality.psi(ref numeric[], cur numeric[], n_buckets integer DEFAULT 10)
RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    WITH r AS (SELECT unnest(ref) AS x),
         c AS (SELECT unnest(cur) AS x),
         edges AS (                         -- interior cut points: the 1/n .. (n-1)/n quantiles
             SELECT percentile_disc(
                        ARRAY(SELECT g::float8 / n_buckets FROM generate_series(1, n_buckets - 1) g))
                    WITHIN GROUP (ORDER BY x) AS e
             FROM r),
         rb AS (SELECT width_bucket(x, e) AS b, count(*)::numeric AS n FROM r, edges GROUP BY 1),
         cb AS (SELECT width_bucket(x, e) AS b, count(*)::numeric AS n FROM c, edges GROUP BY 1),
         p AS (
             SELECT greatest(coalesce(rb.n, 0) / (SELECT sum(n) FROM rb), 1e-4) AS pr,
                    greatest(coalesce(cb.n, 0) / (SELECT sum(n) FROM cb), 1e-4) AS pc
             FROM rb FULL JOIN cb USING (b))
    SELECT round(sum((pc - pr) * ln(pc / pr)), 4) FROM p
$$;
COMMENT ON FUNCTION data_quality.psi(numeric[], numeric[], integer)
    IS 'Population Stability Index of cur vs ref using reference-quantile bins.';

-- 2b. Robust z-score for order amounts.
--     Why robust? Order amounts are heavy-tailed and the outliers themselves inflate the
--     mean and standard deviation, which masks them. The median and the Median Absolute
--     Deviation (MAD) barely move when a few extreme values are added.
--         robust_z = 0.6745 * (x - median) / MAD      (0.6745 makes MAD comparable to sigma)
--     We work on ln(amount) and compare each order with ITS OWN MERCHANT's typical basket:
--     a 20x order is unremarkable for a caterer but extreme for a coffee shop.
CREATE OR REPLACE FUNCTION data_quality.order_amount_robust_z()
RETURNS TABLE (order_id bigint, merchant_id bigint, total_amount numeric,
               merchant_median numeric, robust_z numeric)
LANGUAGE sql STABLE AS $$
    WITH l AS (
        SELECT o.order_id, o.merchant_id, o.total_amount, ln(o.total_amount) AS x
        FROM commerce.orders o
        WHERE o.total_amount > 0),
    med AS (
        SELECT l.merchant_id,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY l.x) AS m
        FROM l GROUP BY l.merchant_id),
    mad AS (
        SELECT l.merchant_id,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(l.x - med.m)) AS mad
        FROM l JOIN med USING (merchant_id) GROUP BY l.merchant_id)
    SELECT l.order_id, l.merchant_id, l.total_amount,
           round(exp(med.m)::numeric, 2),
           round((0.6745 * (l.x - med.m) / nullif(mad.mad, 0))::numeric, 3)
    FROM l JOIN med USING (merchant_id) JOIN mad USING (merchant_id)
$$;
COMMENT ON FUNCTION data_quality.order_amount_robust_z()
    IS 'Per-merchant robust z-score (median/MAD on ln(total_amount)) for every order.';

-- =============================================================================
-- 3. THE RUNNER
-- =============================================================================
-- Notes on PL/pgSQL that the old version of this file got wrong:
--   * GET DIAGNOSTICS only ASSIGNS a status item:  GET DIAGNOSTICS v_n = ROW_COUNT;
--     It cannot take an expression ("GET DIAGNOSTICS n = n + ROW_COUNT" is a syntax
--     error). Read into a variable, then accumulate: v_total := v_total + v_n;
--   * A BEGIN ... EXCEPTION block creates a subtransaction, so a failing rule rolls back
--     only its own work and the loop continues.
CREATE OR REPLACE FUNCTION data_quality.run_rules(
    p_suite        text DEFAULT 'production',  -- rule group; NULL = all suites
    p_dimension    text DEFAULT NULL,      -- run only one dimension
    p_target_table text DEFAULT NULL,      -- run only rules about one table
    p_note         text DEFAULT NULL)
RETURNS TABLE (rule_name text, dimension text, severity text, failed bigint, total bigint,
               failed_pct numeric, metric numeric, passed boolean, duration_ms numeric,
               error text)
LANGUAGE plpgsql AS $$
DECLARE
    r         data_quality.dq_rules%ROWTYPE;
    v_run_id  bigint;
    v_t0      timestamptz;
    v_failed  bigint;
    v_total   bigint;
    v_metric  numeric;
    v_passed  boolean;
    v_err     text;
    v_ms      numeric;
    v_n       bigint;
    v_samples bigint := 0;
    v_run     integer := 0;
    v_bad     integer := 0;
    v_errs    integer := 0;
BEGIN
    INSERT INTO data_quality.dq_runs (data_as_of, filter_note)
    VALUES (meta.as_of(),
            concat_ws(' ', p_note, 'suite=' || p_suite,
                      'dimension=' || p_dimension, 'table=' || p_target_table))
    RETURNING dq_runs.run_id INTO v_run_id;

    FOR r IN
        SELECT * FROM data_quality.dq_rules q
        WHERE q.is_active
          AND (p_suite IS NULL OR q.suite = p_suite)
          AND (p_dimension IS NULL OR q.dimension = p_dimension)
          AND (p_target_table IS NULL OR q.target_table = p_target_table)
        ORDER BY q.rule_id
    LOOP
        v_t0 := clock_timestamp();
        v_err := NULL;
        BEGIN
            EXECUTE r.check_sql INTO STRICT v_failed, v_total, v_metric;
            v_passed := coalesce(v_failed::numeric / nullif(v_total, 0), 0) <= r.max_failed_ratio
                        AND (r.max_metric IS NULL OR coalesce(v_metric <= r.max_metric, false));
        EXCEPTION WHEN OTHERS THEN
            v_err := SQLSTATE || ': ' || SQLERRM;
            v_failed := NULL; v_total := NULL; v_metric := NULL; v_passed := false;
        END;
        v_ms := round((extract(epoch FROM clock_timestamp() - v_t0) * 1000)::numeric, 3);

        INSERT INTO data_quality.dq_results
            (run_id, rule_id, failed_count, total_count, metric, passed, duration_ms, error_message)
        VALUES (v_run_id, r.rule_id, v_failed, v_total, v_metric, v_passed, v_ms, v_err);

        -- Issue samples: close what was open for this rule, then record the current offenders.
        UPDATE data_quality.quality_issues qi
           SET resolved_at = now(),
               resolution_notes = 'superseded by run ' || v_run_id
         WHERE qi.check_name = r.rule_name AND qi.resolved_at IS NULL;

        IF NOT v_passed AND v_err IS NULL AND r.sample_sql IS NOT NULL THEN
            EXECUTE format(
                'INSERT INTO data_quality.quality_issues
                     (run_id, check_name, issue_type, table_name, column_name, record_id,
                      issue_description, severity)
                 SELECT %s, %L, %L, %L, %L, s.record_id::text, s.detail::text, %L
                 FROM (%s) AS s(record_id, detail)
                 LIMIT 10',
                v_run_id, r.rule_name, r.dimension, r.target_table, r.target_column,
                r.severity, r.sample_sql);
            GET DIAGNOSTICS v_n = ROW_COUNT;      -- assign first ...
            v_samples := v_samples + v_n;         -- ... then accumulate
        END IF;

        v_run  := v_run + 1;
        v_bad  := v_bad + (NOT v_passed)::int;
        v_errs := v_errs + (v_err IS NOT NULL)::int;

        rule_name := r.rule_name; dimension := r.dimension; severity := r.severity;
        failed := v_failed; total := v_total;
        failed_pct := round(100 * v_failed::numeric / nullif(v_total, 0), 3);
        metric := round(v_metric, 4); passed := v_passed; duration_ms := v_ms; error := v_err;
        RETURN NEXT;
    END LOOP;

    UPDATE data_quality.dq_runs
       SET finished_at = clock_timestamp(), rules_run = v_run,
           rules_failed = v_bad, rules_errored = v_errs
     WHERE dq_runs.run_id = v_run_id;

    RAISE NOTICE 'DQ run %: % rules, % failed (% errored), % issue samples recorded',
                 v_run_id, v_run, v_bad, v_errs, v_samples;
END;
$$;

-- Helper to register / refresh a rule idempotently (ON CONFLICT keeps rule_id stable,
-- so result history survives a change of definition).
CREATE OR REPLACE FUNCTION data_quality.upsert_rule(
    p_rule_name text, p_dimension text, p_target_table text, p_target_column text,
    p_description text, p_check_sql text, p_sample_sql text DEFAULT NULL,
    p_max_failed_ratio numeric DEFAULT 0, p_max_metric numeric DEFAULT NULL,
    p_severity text DEFAULT 'medium', p_suite text DEFAULT 'production')
RETURNS integer
LANGUAGE sql AS $$
    INSERT INTO data_quality.dq_rules AS q
        (rule_name, suite, dimension, target_table, target_column, description, check_sql,
         sample_sql, max_failed_ratio, max_metric, severity)
    VALUES (p_rule_name, p_suite, p_dimension, p_target_table, p_target_column, p_description,
            p_check_sql, p_sample_sql, p_max_failed_ratio, p_max_metric, p_severity)
    ON CONFLICT (rule_name) DO UPDATE
        SET suite = EXCLUDED.suite, dimension = EXCLUDED.dimension, target_table = EXCLUDED.target_table,
            target_column = EXCLUDED.target_column, description = EXCLUDED.description,
            check_sql = EXCLUDED.check_sql, sample_sql = EXCLUDED.sample_sql,
            max_failed_ratio = EXCLUDED.max_failed_ratio, max_metric = EXCLUDED.max_metric,
            severity = EXCLUDED.severity, updated_at = now()
    RETURNING q.rule_id
$$;

-- =============================================================================
-- 4. RULES FOR THE PRODUCTION TABLES
-- =============================================================================
-- Many of these are ALSO enforced by constraints. That is deliberate: constraints guard
-- writes, DQ rules measure what is actually stored (constraints can be NOT VALID, disabled
-- during bulk loads, or absent in replicas / warehouses fed from this database).

SELECT count(*) AS production_rules_registered FROM (
-- ---- completeness: are required values present? -------------------------------------
SELECT data_quality.upsert_rule(
    'citizens_home_geom_present', 'completeness', 'civics.citizens', 'home_geom',
    'Every citizen should be geocoded (home_geom NOT NULL).',
    $q$SELECT count(*) FILTER (WHERE home_geom IS NULL), count(*), NULL::numeric FROM civics.citizens$q$,
    $q$SELECT citizen_id, 'home_geom is NULL' FROM civics.citizens WHERE home_geom IS NULL ORDER BY citizen_id$q$,
    0, NULL, 'high')
UNION ALL
SELECT data_quality.upsert_rule(
    'orders_delivery_address_present', 'completeness', 'commerce.orders', 'delivery_address',
    'Share of orders without a delivery address. Tolerated up to 65% because pickup orders '
    'legitimately have none; the rule catches a sudden jump, not the steady state.',
    $q$SELECT count(*) FILTER (WHERE delivery_address IS NULL OR delivery_address = ''), count(*), NULL::numeric
       FROM commerce.orders$q$,
    NULL, 0.65, NULL, 'low')
UNION ALL
SELECT data_quality.upsert_rule(
    'delivered_orders_have_payment', 'completeness', 'commerce.orders', NULL,
    'Every delivered order should have at least one payment row.',
    $q$SELECT count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM commerce.payments p WHERE p.order_id = o.order_id)),
              count(*), NULL::numeric
       FROM commerce.orders o WHERE o.status = 'delivered'$q$,
    $q$SELECT o.order_id, 'delivered without payment' FROM commerce.orders o
       WHERE o.status = 'delivered'
         AND NOT EXISTS (SELECT 1 FROM commerce.payments p WHERE p.order_id = o.order_id)
       ORDER BY o.order_id$q$,
    0, NULL, 'high')
-- ---- validity: do values obey format, range and cross-field rules? ------------------
UNION ALL
SELECT data_quality.upsert_rule(
    'citizens_zip_matches_neighbourhood', 'validity', 'civics.citizens', 'zip_code',
    'zip_code ''751NN'' encodes the neighbourhood; it must match the polygon that contains home_geom.',
    $q$SELECT count(*) FILTER (WHERE nb.neighborhood_id IS DISTINCT FROM substr(c.zip_code, 4, 2)::int),
              count(*), NULL::numeric
       FROM civics.citizens c
       LEFT JOIN geo.neighborhood_boundaries nb ON ST_Covers(nb.boundary_geom, c.home_geom)$q$,
    $q$SELECT c.citizen_id, 'zip ' || c.zip_code || ' vs polygon ' || coalesce(nb.neighborhood_id::text, 'none')
       FROM civics.citizens c
       LEFT JOIN geo.neighborhood_boundaries nb ON ST_Covers(nb.boundary_geom, c.home_geom)
       WHERE nb.neighborhood_id IS DISTINCT FROM substr(c.zip_code, 4, 2)::int ORDER BY c.citizen_id$q$,
    0, NULL, 'medium')
UNION ALL
SELECT data_quality.upsert_rule(
    'orders_subtotal_equals_items', 'validity', 'commerce.orders', 'subtotal',
    'Order subtotal must equal the sum of its line items (cross-table consistency).',
    $q$SELECT count(*) FILTER (WHERE abs(o.subtotal - coalesce(i.s, 0)) >= 0.01), count(*), NULL::numeric
       FROM commerce.orders o
       LEFT JOIN (SELECT order_id, sum(line_total) AS s FROM commerce.order_items GROUP BY order_id) i
              USING (order_id)$q$,
    NULL, 0, NULL, 'high')
UNION ALL
SELECT data_quality.upsert_rule(
    'no_events_after_as_of', 'validity', 'commerce.orders', 'order_date',
    'No order may be dated after the dataset reference time meta.as_of().',
    $q$SELECT count(*) FILTER (WHERE order_date > meta.as_of()), count(*), NULL::numeric FROM commerce.orders$q$,
    $q$SELECT order_id, order_date::text FROM commerce.orders WHERE order_date > meta.as_of() ORDER BY order_id$q$,
    0, NULL, 'critical')
UNION ALL
SELECT data_quality.upsert_rule(
    'sensor_dropouts', 'validity', 'mobility.sensor_readings', 'reading_value',
    'A reading of exactly 0 with a low quality score is a sensor dropout, not a measurement. '
    'Tolerated up to 0.5% of readings (planted rate is 0.2%).',
    $q$SELECT count(*) FILTER (WHERE reading_value = 0 AND data_quality_score < 0.5), count(*), NULL::numeric
       FROM mobility.sensor_readings$q$,
    $q$SELECT reading_id, sensor_code || ' @ ' || reading_time FROM mobility.sensor_readings
       WHERE reading_value = 0 AND data_quality_score < 0.5 ORDER BY reading_id$q$,
    0.005, NULL, 'low')
-- ---- uniqueness: business keys the schema does not fully protect --------------------
UNION ALL
SELECT data_quality.upsert_rule(
    'citizens_email_unique_ci', 'uniqueness', 'civics.citizens', 'email',
    'The UNIQUE constraint on email is case-sensitive; Bob@x.org and bob@x.org would both pass. '
    'Count case-insensitive duplicate groups.',
    $q$SELECT count(*) FILTER (WHERE n > 1), count(*), NULL::numeric
       FROM (SELECT lower(email) AS e, count(*) AS n FROM civics.citizens GROUP BY 1) s$q$,
    $q$SELECT string_agg(citizen_id::text, ',' ORDER BY citizen_id), lower(email)
       FROM civics.citizens GROUP BY lower(email) HAVING count(*) > 1 ORDER BY 2$q$,
    0, NULL, 'high')
UNION ALL
SELECT data_quality.upsert_rule(
    'citizens_probable_duplicates', 'uniqueness', 'civics.citizens', 'first_name,last_name,date_of_birth',
    'Same first name, last name and birth date is a probable duplicate person.',
    $q$SELECT count(*) FILTER (WHERE n > 1), count(*), NULL::numeric
       FROM (SELECT first_name, last_name, date_of_birth, count(*) AS n
             FROM civics.citizens GROUP BY 1, 2, 3) s$q$,
    NULL, 0, NULL, 'medium')
-- ---- referential integrity: anti-joins catch orphans even where no FK exists --------
UNION ALL
SELECT data_quality.upsert_rule(
    'orders_customer_exists', 'referential_integrity', 'commerce.orders', 'customer_citizen_id',
    'Every order customer must exist in civics.citizens.',
    $q$SELECT count(*) FILTER (WHERE o.customer_citizen_id IS NOT NULL AND c.citizen_id IS NULL), count(*), NULL::numeric
       FROM commerce.orders o LEFT JOIN civics.citizens c ON c.citizen_id = o.customer_citizen_id$q$,
    NULL, 0, NULL, 'critical')
UNION ALL
SELECT data_quality.upsert_rule(
    'pois_neighbourhood_consistent', 'referential_integrity', 'geo.points_of_interest', 'neighborhood_id',
    'Spatial referential integrity: the stored neighborhood_id must be the polygon that contains the POI.',
    $q$SELECT count(*) FILTER (WHERE nb.neighborhood_id IS DISTINCT FROM p.neighborhood_id), count(*), NULL::numeric
       FROM geo.points_of_interest p
       LEFT JOIN geo.neighborhood_boundaries nb ON ST_Covers(nb.boundary_geom, p.location_geom)$q$,
    NULL, 0, NULL, 'medium')
-- ---- timeliness: freshness relative to the dataset clock, not the wall clock --------
UNION ALL
SELECT data_quality.upsert_rule(
    'orders_freshness_hours', 'timeliness', 'commerce.orders', 'order_date',
    'Hours between meta.as_of() and the newest order. SLA: 7 days (orders load weekly).',
    $q$SELECT 0::bigint, 1::bigint,
              round(extract(epoch FROM meta.as_of() - max(order_date)) / 3600, 2) FROM commerce.orders$q$,
    NULL, 0, 168, 'high')
UNION ALL
SELECT data_quality.upsert_rule(
    'sensor_freshness_by_sensor', 'timeliness', 'mobility.sensor_readings', 'reading_time',
    'Sensors whose newest reading is more than 2 hours older than meta.as_of(). Metric = worst lag (h).',
    $q$SELECT count(*) FILTER (WHERE lag_h > 2), count(*), max(lag_h)
       FROM (SELECT sensor_code, extract(epoch FROM meta.as_of() - max(reading_time)) / 3600 AS lag_h
             FROM mobility.sensor_readings GROUP BY sensor_code) s$q$,
    $q$SELECT sensor_code, 'last reading ' || max(reading_time) FROM mobility.sensor_readings
       GROUP BY sensor_code HAVING meta.as_of() - max(reading_time) > interval '2 hours' ORDER BY 1$q$,
    0, NULL, 'medium')
-- ---- distribution drift: has the shape of the data changed? -------------------------
UNION ALL
SELECT data_quality.upsert_rule(
    'orders_amount_psi_30d', 'distribution_drift', 'commerce.orders', 'total_amount',
    'PSI of total_amount: last 30 days vs the 90 days before. Fail above 0.25.',
    $q$SELECT 0::bigint, 1::bigint, data_quality.psi(
           ARRAY(SELECT total_amount FROM commerce.orders
                 WHERE order_date >= meta.as_of() - interval '120 days'
                   AND order_date <  meta.as_of() - interval '30 days'),
           ARRAY(SELECT total_amount FROM commerce.orders
                 WHERE order_date >= meta.as_of() - interval '30 days'))$q$,
    NULL, 0, 0.25, 'medium')
UNION ALL
SELECT data_quality.upsert_rule(
    'orders_cancel_rate_shift', 'distribution_drift', 'commerce.orders', 'status',
    'Absolute change (percentage points) in the cancelled+refunded share, last 30 days vs prior 90. Fail above 3 pp.',
    $q$WITH w AS (
           SELECT order_date >= meta.as_of() - interval '30 days' AS recent,
                  avg((status IN ('cancelled', 'refunded'))::int) AS rate
           FROM commerce.orders
           WHERE order_date >= meta.as_of() - interval '120 days'
           GROUP BY 1)
       SELECT 0::bigint, 1::bigint,
              round(100 * abs(max(rate) FILTER (WHERE recent) - max(rate) FILTER (WHERE NOT recent)), 3)
       FROM w$q$,
    NULL, 0, 3, 'medium')
-- ---- statistical outliers -----------------------------------------------------------
UNION ALL
SELECT data_quality.upsert_rule(
    'orders_amount_robust_z', 'statistical_outlier', 'commerce.orders', 'total_amount',
    'Orders whose per-merchant robust z-score of ln(total_amount) exceeds 3.5. '
    'Tolerated up to 0.5% of orders; metric = largest z.',
    $q$SELECT count(*) FILTER (WHERE robust_z > 3.5), count(*), max(robust_z)
       FROM data_quality.order_amount_robust_z()$q$,
    $q$SELECT order_id, format('amount %s vs merchant median %s (z=%s)', total_amount, merchant_median, robust_z)
       FROM data_quality.order_amount_robust_z() WHERE robust_z > 3.5 ORDER BY robust_z DESC, order_id$q$,
    0.005, NULL, 'medium')
) AS registered;

-- =============================================================================
-- 5. RUN THE PRODUCTION RULES
-- =============================================================================
-- The 'production' suite (staging rules live in suite 'staging_gate', section 7).
-- Expect most to pass on the clean base; the
-- outlier and dropout rules report findings but stay inside their tolerance.
\echo '-- 5. production rule run'
SELECT rule_name, dimension, failed, total, failed_pct, metric, passed, error
FROM data_quality.run_rules(p_note => 'production')
ORDER BY dimension, rule_name;

-- =============================================================================
-- 6. EVALUATING A STATISTICAL RULE AGAINST GROUND TRUTH
-- =============================================================================
-- The generator injected 15-25x amounts into ~0.2% of orders and labelled them in
-- meta.ground_truth (label 'order_amount_outlier'). That lets us measure the detector:
--   precision = flagged AND labelled / flagged      (how many alerts are real)
--   recall    = flagged AND labelled / labelled     (how many real outliers we catch)
\echo '-- 6a. robust z (per merchant) vs naive z (global mean/sd): precision / recall by threshold'
WITH truth AS (
    SELECT entity_id AS order_id FROM meta.ground_truth
    WHERE entity = 'commerce.orders' AND label = 'order_amount_outlier'),
naive AS (                                     -- the textbook z-score on raw amounts
    SELECT order_id, (total_amount - avg(total_amount) OVER ()) / stddev_pop(total_amount) OVER () AS z
    FROM commerce.orders),
scored AS (
    SELECT 'robust_z (merchant, log)' AS method, order_id, robust_z AS z FROM data_quality.order_amount_robust_z()
    UNION ALL
    SELECT 'naive_z (global, raw)', order_id, z FROM naive),
sweep AS (
    SELECT s.method, t.thr,
           count(*) FILTER (WHERE s.z > t.thr)                               AS flagged,
           count(*) FILTER (WHERE s.z > t.thr AND tr.order_id IS NOT NULL)   AS true_pos,
           (SELECT count(*) FROM truth)                                      AS labelled
    FROM scored s
    CROSS JOIN (VALUES (2.5), (3.0), (3.5), (5.0)) AS t(thr)
    LEFT JOIN truth tr USING (order_id)
    GROUP BY s.method, t.thr)
SELECT method, thr, flagged, true_pos, labelled,
       round(true_pos::numeric / nullif(flagged, 0), 3)  AS precision,
       round(true_pos::numeric / labelled, 3)            AS recall,
       round(2.0 * true_pos / nullif(flagged + labelled, 0), 3) AS f1
FROM sweep
ORDER BY method DESC, thr;
-- Reading the table: the naive z-score is dominated by the heavy right tail (big but
-- legitimate merchants), so it flags thousands of normal orders. Conditioning on the
-- merchant and using median/MAD on the log scale gives high precision at 3.5 but modest
-- recall: an injected 15-25x order from a merchant whose baskets already vary a lot is
-- not "extreme" for that merchant. Lowering the threshold trades precision for recall.

\echo '-- 6b. the sensor_dropouts validity rule vs labelled dropouts'
WITH flagged AS (
    SELECT reading_id FROM mobility.sensor_readings
    WHERE reading_value = 0 AND data_quality_score < 0.5),
truth AS (
    SELECT entity_id AS reading_id FROM meta.ground_truth
    WHERE entity = 'mobility.sensor_readings' AND label = 'dropout')
SELECT (SELECT count(*) FROM flagged)                       AS flagged,
       (SELECT count(*) FROM truth)                         AS labelled,
       (SELECT count(*) FROM flagged JOIN truth USING (reading_id)) AS true_pos;

-- =============================================================================
-- 7. LANDING-ZONE GATE: RULES ON A STAGING TABLE WITH INJECTED DEFECTS
-- =============================================================================
-- Real pipelines land raw data in an unconstrained staging table, run DQ rules, quarantine
-- what fails and only then merge into the constrained production table. We simulate a
-- 30-day batch, copied from commerce.orders (module-owned, rebuilt on every run), then inject
-- one defect of each kind.
\echo '-- 7. staging gate'
DROP TABLE IF EXISTS data_quality.stg_orders_landing;
CREATE TABLE data_quality.stg_orders_landing AS
SELECT order_id, merchant_id, customer_citizen_id, order_number, order_date,
       status::text AS status, subtotal, tax_amount, tip_amount, total_amount
FROM commerce.orders
WHERE order_date >= meta.as_of() - interval '30 days'
ORDER BY order_id;

CREATE TABLE IF NOT EXISTS data_quality.stg_orders_quarantine (
    LIKE data_quality.stg_orders_landing,
    quarantined_at timestamptz NOT NULL DEFAULT now(),
    reason text NOT NULL
);
TRUNCATE data_quality.stg_orders_quarantine;     -- module-owned table: safe to reset

-- Inject defects deterministically (lowest order_ids of the batch).
WITH b AS (SELECT order_id, row_number() OVER (ORDER BY order_id) AS rn FROM data_quality.stg_orders_landing)
UPDATE data_quality.stg_orders_landing s SET
    customer_citizen_id = CASE WHEN b.rn BETWEEN 1  AND 8  THEN NULL          ELSE s.customer_citizen_id END,
    merchant_id         = CASE WHEN b.rn BETWEEN 9  AND 11 THEN 999999        ELSE s.merchant_id END,
    order_date          = CASE WHEN b.rn BETWEEN 12 AND 14 THEN meta.as_of() + interval '3 days'
                               ELSE s.order_date END,
    total_amount        = CASE WHEN b.rn BETWEEN 15 AND 19 THEN s.total_amount + 10
                               WHEN b.rn BETWEEN 20 AND 21 THEN -5
                               ELSE s.total_amount END
FROM b WHERE b.order_id = s.order_id AND b.rn <= 21;
-- duplicate business keys: re-insert 4 rows with a new id but the same order_number
INSERT INTO data_quality.stg_orders_landing
SELECT order_id + 10000000, merchant_id, customer_citizen_id, order_number, order_date,
       status, subtotal, tax_amount, tip_amount, total_amount
FROM data_quality.stg_orders_landing ORDER BY order_id DESC LIMIT 4;
-- distribution shift: an upstream currency-conversion bug scales every amount by 1.6.
-- Each part is rounded to cents and the total rebuilt from the parts, preserving any
-- discrepancy injected above (in a SET list every expression sees the OLD row values).
-- Note how insensitive PSI is: scaling only 40% of the batch by 1.6 gives PSI ~0.03.
UPDATE data_quality.stg_orders_landing
SET subtotal     = round(subtotal * 1.6, 2),
    tax_amount   = round(tax_amount * 1.6, 2),
    tip_amount   = round(tip_amount * 1.6, 2),
    total_amount = round(subtotal * 1.6, 2) + round(tax_amount * 1.6, 2) + round(tip_amount * 1.6, 2)
                   + (total_amount - subtotal - tax_amount - tip_amount)
WHERE total_amount > 0;

SELECT count(*) AS staging_rules_registered FROM (
SELECT data_quality.upsert_rule('stg_customer_present', 'completeness', 'data_quality.stg_orders_landing',
    'customer_citizen_id', 'Staged orders must carry a customer.',
    $q$SELECT count(*) FILTER (WHERE customer_citizen_id IS NULL), count(*), NULL::numeric FROM data_quality.stg_orders_landing$q$,
    $q$SELECT order_id, 'customer_citizen_id is NULL' FROM data_quality.stg_orders_landing WHERE customer_citizen_id IS NULL ORDER BY 1$q$,
    0, NULL, 'high', p_suite => 'staging_gate')
UNION ALL
SELECT data_quality.upsert_rule('stg_amounts_valid', 'validity', 'data_quality.stg_orders_landing',
    'total_amount', 'total = subtotal + tax + tip and never negative.',
    $q$SELECT count(*) FILTER (WHERE total_amount < 0 OR abs(total_amount - (subtotal + tax_amount + tip_amount)) >= 0.01),
              count(*), NULL::numeric FROM data_quality.stg_orders_landing$q$,
    $q$SELECT order_id, format('total %s vs parts %s', total_amount, subtotal + tax_amount + tip_amount)
       FROM data_quality.stg_orders_landing
       WHERE total_amount < 0 OR abs(total_amount - (subtotal + tax_amount + tip_amount)) >= 0.01 ORDER BY 1$q$,
    0, NULL, 'critical', p_suite => 'staging_gate')
UNION ALL
SELECT data_quality.upsert_rule('stg_not_in_future', 'validity', 'data_quality.stg_orders_landing',
    'order_date', 'No staged order after meta.as_of().',
    $q$SELECT count(*) FILTER (WHERE order_date > meta.as_of()), count(*), NULL::numeric FROM data_quality.stg_orders_landing$q$,
    NULL, 0, NULL, 'critical', p_suite => 'staging_gate')
UNION ALL
SELECT data_quality.upsert_rule('stg_order_number_unique', 'uniqueness', 'data_quality.stg_orders_landing',
    'order_number', 'order_number must be unique within the batch AND must not already exist in production.',
    $q$SELECT count(*) FILTER (WHERE n > 1 OR in_prod), count(*), NULL::numeric
       FROM (SELECT s.order_number, count(*) AS n,
                    bool_or(EXISTS (SELECT 1 FROM commerce.orders o
                                    WHERE o.order_number = s.order_number AND o.order_id <> s.order_id)) AS in_prod
             FROM data_quality.stg_orders_landing s GROUP BY s.order_number) g$q$,
    NULL, 0, NULL, 'critical', p_suite => 'staging_gate')
UNION ALL
SELECT data_quality.upsert_rule('stg_merchant_exists', 'referential_integrity', 'data_quality.stg_orders_landing',
    'merchant_id', 'Staging has no FK, so check merchants with an anti-join.',
    $q$SELECT count(*) FILTER (WHERE m.merchant_id IS NULL), count(*), NULL::numeric
       FROM data_quality.stg_orders_landing s LEFT JOIN commerce.merchants m USING (merchant_id)$q$,
    $q$SELECT s.order_id, 'unknown merchant ' || s.merchant_id
       FROM data_quality.stg_orders_landing s LEFT JOIN commerce.merchants m USING (merchant_id)
       WHERE m.merchant_id IS NULL ORDER BY 1$q$,
    0, NULL, 'critical', p_suite => 'staging_gate')
UNION ALL
SELECT data_quality.upsert_rule('stg_amount_psi_vs_prod', 'distribution_drift', 'data_quality.stg_orders_landing',
    'total_amount', 'PSI of the staged batch vs the previous 90 days in production. Fail above 0.10 for a gate.',
    $q$SELECT 0::bigint, 1::bigint, data_quality.psi(
           ARRAY(SELECT total_amount FROM commerce.orders
                 WHERE order_date >= meta.as_of() - interval '120 days'
                   AND order_date <  meta.as_of() - interval '30 days'),
           ARRAY(SELECT total_amount FROM data_quality.stg_orders_landing WHERE total_amount >= 0))$q$,
    NULL, 0, 0.10, 'high', p_suite => 'staging_gate')
) AS registered;

\echo '-- 7a. gate run on the defective batch (everything should fail)'
SELECT rule_name, dimension, failed, total, metric, passed
FROM data_quality.run_rules(p_suite => 'staging_gate', p_note => 'staging: raw batch')
ORDER BY rule_name;

\echo '-- 7b. sample offenders recorded for triage'
SELECT check_name, record_id, issue_description
FROM data_quality.quality_issues
WHERE resolved_at IS NULL AND table_name = 'data_quality.stg_orders_landing'
ORDER BY check_name, record_id
LIMIT 12;

-- Quarantine row-level failures in one statement: a data-modifying CTE moves the rows.
WITH bad AS (
    DELETE FROM data_quality.stg_orders_landing s
    WHERE s.customer_citizen_id IS NULL
       OR s.total_amount < 0
       OR abs(s.total_amount - (s.subtotal + s.tax_amount + s.tip_amount)) >= 0.01
       OR s.order_date > meta.as_of()
       OR NOT EXISTS (SELECT 1 FROM commerce.merchants m WHERE m.merchant_id = s.merchant_id)
       OR s.order_id >= 10000000                                  -- duplicate keys we created
    RETURNING s.*)
INSERT INTO data_quality.stg_orders_quarantine
SELECT bad.*, now(), 'failed row-level DQ rules' FROM bad;

\echo '-- 7c. gate re-run after quarantine: row rules pass, but the batch-level drift rule still blocks the load'
SELECT rule_name, dimension, failed, total, metric, passed
FROM data_quality.run_rules(p_suite => 'staging_gate', p_note => 'staging: after quarantine')
ORDER BY rule_name;
-- Drift is a property of the whole batch, not of any single row: no quarantine fixes it.
-- The right response is to stop the load and investigate the upstream (currency) bug.

-- =============================================================================
-- 8. REPORTING VIEWS
-- =============================================================================

-- Latest result per rule.
CREATE OR REPLACE VIEW data_quality.latest_results AS
SELECT DISTINCT ON (q.rule_id)
       q.rule_name, q.dimension, q.target_table, q.severity,
       r.executed_at, r.failed_count, r.total_count,
       round(100 * r.failed_ratio, 3) AS failed_pct, r.metric, r.passed, r.duration_ms, r.error_message
FROM data_quality.dq_rules q
JOIN data_quality.dq_results r USING (rule_id)
ORDER BY q.rule_id, r.executed_at DESC, r.result_id DESC;

-- Scorecard by dimension and table: share of rules passing on their latest run.
CREATE OR REPLACE VIEW data_quality.scorecard AS
SELECT target_table, dimension,
       count(*)                              AS rules,
       count(*) FILTER (WHERE passed)        AS passing,
       round(100.0 * count(*) FILTER (WHERE passed) / count(*), 1) AS pass_pct,
       string_agg(rule_name, ', ' ORDER BY rule_name) FILTER (WHERE NOT passed) AS failing_rules
FROM data_quality.latest_results
GROUP BY target_table, dimension;

-- Trend of one rule across runs (e.g. to alert when a metric worsens run over run).
CREATE OR REPLACE VIEW data_quality.rule_trend AS
SELECT q.rule_name, r.run_id, r.executed_at, r.failed_count, r.metric, r.passed,
       r.metric - lag(r.metric) OVER w           AS metric_change,
       r.failed_count - lag(r.failed_count) OVER w AS failed_change
FROM data_quality.dq_results r
JOIN data_quality.dq_rules q USING (rule_id)
WINDOW w AS (PARTITION BY r.rule_id ORDER BY r.executed_at, r.result_id);

\echo '-- 8. scorecard'
SELECT * FROM data_quality.scorecard ORDER BY target_table, dimension;

\echo '-- 8b. last run summaries'
SELECT run_id, filter_note, rules_run, rules_failed, rules_errored,
       round(extract(epoch FROM finished_at - started_at) * 1000) AS wall_ms
FROM data_quality.dq_runs ORDER BY run_id DESC LIMIT 3;

-- =============================================================================
-- 9. USAGE CHEAT-SHEET
-- =============================================================================
/*
-- Run everything, or one dimension, or one table:
SELECT * FROM data_quality.run_rules();                       -- suite 'production'
SELECT * FROM data_quality.run_rules(p_suite => NULL);        -- every suite
SELECT * FROM data_quality.run_rules(p_dimension => 'timeliness');
SELECT * FROM data_quality.run_rules(p_target_table => 'commerce.orders');

-- Add a rule (no new code needed):
SELECT data_quality.upsert_rule(
    'payments_amount_matches_order', 'validity', 'commerce.payments', 'amount',
    'Completed payments should not exceed the order total.',
    $q$SELECT count(*) FILTER (WHERE p.amount > o.total_amount + 0.01), count(*), NULL::numeric
       FROM commerce.payments p JOIN commerce.orders o USING (order_id)
       WHERE p.status = 'completed'$q$);

-- Disable a noisy rule without losing its history:
UPDATE data_quality.dq_rules SET is_active = false WHERE rule_name = 'orders_delivery_address_present';

-- Schedule it (only where pg_cron exists, i.e. database "polaris"):
-- SELECT cron.schedule('dq-hourly', '7 * * * *', $$SELECT count(*) FROM data_quality.run_rules()$$);
*/

GRANT USAGE ON SCHEMA data_quality TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA data_quality TO PUBLIC;
