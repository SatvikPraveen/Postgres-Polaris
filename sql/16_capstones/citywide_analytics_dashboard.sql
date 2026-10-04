-- =============================================================================
-- File: sql/16_capstones/citywide_analytics_dashboard.sql
-- Capstone: a citywide KPI dashboard with verifiable analytics
-- =============================================================================
-- What this capstone teaches
--   * KPI views anchored on meta.as_of() (the dataset's reference "now"), so the
--     dashboard is reproducible instead of drifting with the wall clock.
--   * Period-over-period comparison with FILTER, and a long KPI format that a
--     BI tool can pivot.
--   * A materialized view with a UNIQUE index so it can be refreshed
--     CONCURRENTLY (readers are never blocked).
--   * Service-equity analysis: a within-category (fixed-effects) OLS slope of
--     ln(resolution days) on standardised neighbourhood income, computed with
--     regr_slope / regr_sxx / regr_syy, with a standard error and a 95% CI,
--     compared to the TRUE planted value in meta.planted_effects.
--   * A second planted effect (peak/off-peak transit delay ratio) as a sanity check.
--   * Cohort retention for orders (first-order month x months since).
--   * ROLLUP / GROUPING SETS / GROUPING() for subtotal reports.
--
-- Everything lives in schema dashboard and is created idempotently.
-- =============================================================================

\echo '== 0. Schema'
CREATE SCHEMA IF NOT EXISTS dashboard;
COMMENT ON SCHEMA dashboard IS 'Capstone 16: citywide KPI views, equity analysis and cohort reports.';

-- -----------------------------------------------------------------------------
-- 1. KPI definitions (metadata) and the 30-day KPI snapshot view
-- -----------------------------------------------------------------------------
-- Teaches: keep KPI metadata (owner, direction of "good") in a table, compute
-- values in a view. Current window = (as_of - 30 days, as_of]; previous window
-- = the 30 days before that. FILTER lets one scan produce both periods.
\echo '== 1. KPI definitions and 30-day snapshot'
CREATE TABLE IF NOT EXISTS dashboard.kpi_definitions (
    kpi_name        text PRIMARY KEY,
    domain          text NOT NULL,
    unit            text NOT NULL,
    higher_is_better boolean NOT NULL,
    description     text NOT NULL
);
INSERT INTO dashboard.kpi_definitions VALUES
    ('orders',                   'commerce',  'count', true,  'Orders placed'),
    ('gross_merchandise_value',  'commerce',  'USD',   true,  'Sum of total_amount, excluding cancelled/refunded'),
    ('avg_order_value',          'commerce',  'USD',   true,  'GMV / non-cancelled orders'),
    ('cancel_refund_rate',       'commerce',  'ratio', false, 'Share of orders cancelled or refunded'),
    ('permit_applications',      'civics',    'count', true,  'Permit applications received'),
    ('permit_approval_rate',     'civics',    'ratio', true,  'Approved / decided (approved + denied)'),
    ('complaints_received',      'documents', 'count', false, 'Service complaints submitted'),
    ('median_resolution_days',   'documents', 'days',  false, 'Median days submitted -> resolved, for complaints resolved in the window'),
    ('trips',                    'mobility',  'count', true,  'Distinct trips started'),
    ('transit_mean_delay_min',   'mobility',  'min',   false, 'Mean delay of bus and rail segments')
ON CONFLICT (kpi_name) DO UPDATE
    SET domain = EXCLUDED.domain, unit = EXCLUDED.unit,
        higher_is_better = EXCLUDED.higher_is_better, description = EXCLUDED.description;

CREATE OR REPLACE VIEW dashboard.kpi_snapshot_30d AS
WITH w AS (
    SELECT meta.as_of() AS t1, meta.as_of() - interval '30 days' AS t0, meta.as_of() - interval '60 days' AS tm
),
commerce AS (
    SELECT
        count(*) FILTER (WHERE o.order_date >  w.t0)                                         AS orders_cur,
        count(*) FILTER (WHERE o.order_date <= w.t0)                                         AS orders_prev,
        sum(o.total_amount) FILTER (WHERE o.order_date >  w.t0 AND o.status NOT IN ('cancelled','refunded')) AS gmv_cur,
        sum(o.total_amount) FILTER (WHERE o.order_date <= w.t0 AND o.status NOT IN ('cancelled','refunded')) AS gmv_prev,
        count(*) FILTER (WHERE o.order_date >  w.t0 AND o.status NOT IN ('cancelled','refunded'))           AS ok_cur,
        count(*) FILTER (WHERE o.order_date <= w.t0 AND o.status NOT IN ('cancelled','refunded'))           AS ok_prev
    FROM commerce.orders o, w
    WHERE o.order_date > w.tm AND o.order_date <= w.t1
),
permits AS (
    SELECT
        count(*) FILTER (WHERE p.application_date >  w.t0)                                   AS apps_cur,
        count(*) FILTER (WHERE p.application_date <= w.t0)                                   AS apps_prev,
        count(*) FILTER (WHERE p.application_date >  w.t0 AND p.status = 'approved')         AS appr_cur,
        count(*) FILTER (WHERE p.application_date <= w.t0 AND p.status = 'approved')         AS appr_prev,
        count(*) FILTER (WHERE p.application_date >  w.t0 AND p.status IN ('approved','denied')) AS dec_cur,
        count(*) FILTER (WHERE p.application_date <= w.t0 AND p.status IN ('approved','denied')) AS dec_prev
    FROM civics.permit_applications p, w
    WHERE p.application_date > w.tm AND p.application_date <= w.t1
),
complaints AS (
    SELECT
        (SELECT count(*) FROM documents.complaint_records c WHERE c.submitted_at >  w.t0 AND c.submitted_at <= w.t1) AS recv_cur,
        (SELECT count(*) FROM documents.complaint_records c WHERE c.submitted_at >  w.tm AND c.submitted_at <= w.t0) AS recv_prev,
        (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM c.resolved_at - c.submitted_at) / 86400)
           FROM documents.complaint_records c WHERE c.resolved_at >  w.t0 AND c.resolved_at <= w.t1) AS med_cur,
        (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM c.resolved_at - c.submitted_at) / 86400)
           FROM documents.complaint_records c WHERE c.resolved_at >  w.tm AND c.resolved_at <= w.t0) AS med_prev
    FROM w
),
mobility AS (
    SELECT
        count(DISTINCT t.trip_id) FILTER (WHERE t.start_time >  w.t0)                        AS trips_cur,
        count(DISTINCT t.trip_id) FILTER (WHERE t.start_time <= w.t0)                        AS trips_prev,
        avg(t.delay_minutes) FILTER (WHERE t.start_time >  w.t0 AND t.trip_mode IN ('bus','rail')) AS delay_cur,
        avg(t.delay_minutes) FILTER (WHERE t.start_time <= w.t0 AND t.trip_mode IN ('bus','rail')) AS delay_prev
    FROM mobility.trip_segments t, w
    WHERE t.start_time > w.tm AND t.start_time <= w.t1
)
SELECT d.domain, k.kpi_name, d.unit,
       round(k.cur::numeric, 3)  AS current_30d,
       round(k.prev::numeric, 3) AS previous_30d,
       round(100 * (k.cur - k.prev)::numeric / nullif(k.prev, 0)::numeric, 1) AS pct_change,
       CASE WHEN k.cur IS NULL OR k.prev IS NULL OR k.cur = k.prev THEN 'flat'
            WHEN (k.cur > k.prev) = d.higher_is_better THEN 'improving'
            ELSE 'worsening' END AS trend
FROM commerce c, permits p, complaints q, mobility m
CROSS JOIN LATERAL (VALUES
    ('orders',                  c.orders_cur::float8,                   c.orders_prev::float8),
    ('gross_merchandise_value', c.gmv_cur::float8,                      c.gmv_prev::float8),
    ('avg_order_value',         (c.gmv_cur / nullif(c.ok_cur, 0))::float8, (c.gmv_prev / nullif(c.ok_prev, 0))::float8),
    ('cancel_refund_rate',      1 - c.ok_cur::float8 / nullif(c.orders_cur, 0), 1 - c.ok_prev::float8 / nullif(c.orders_prev, 0)),
    ('permit_applications',     p.apps_cur::float8,                     p.apps_prev::float8),
    ('permit_approval_rate',    p.appr_cur::float8 / nullif(p.dec_cur, 0), p.appr_prev::float8 / nullif(p.dec_prev, 0)),
    ('complaints_received',     q.recv_cur::float8,                     q.recv_prev::float8),
    ('median_resolution_days',  q.med_cur,                              q.med_prev),
    ('trips',                   m.trips_cur::float8,                    m.trips_prev::float8),
    ('transit_mean_delay_min',  m.delay_cur::float8,                    m.delay_prev::float8)
) AS k(kpi_name, cur, prev)
JOIN dashboard.kpi_definitions d USING (kpi_name);

SELECT * FROM dashboard.kpi_snapshot_30d ORDER BY domain, kpi_name;

-- -----------------------------------------------------------------------------
-- 2. Monthly activity matview, refreshable CONCURRENTLY
-- -----------------------------------------------------------------------------
-- Teaches: REFRESH MATERIALIZED VIEW CONCURRENTLY needs a UNIQUE index that
-- covers all rows (no WHERE clause, no expressions that could be NULL-ish).
-- generate_series over months gives a dense calendar so empty months show 0.
\echo '== 2. Monthly activity matview'
DROP MATERIALIZED VIEW IF EXISTS dashboard.monthly_activity;
CREATE MATERIALIZED VIEW dashboard.monthly_activity AS
WITH months AS (
    SELECT generate_series(date_trunc('month', meta.as_of() - interval '11 months'),
                           date_trunc('month', meta.as_of()), interval '1 month') AS month
)
SELECT m.month::date AS month,
       (SELECT count(*) FROM commerce.orders o
         WHERE o.order_date >= m.month AND o.order_date < m.month + interval '1 month')              AS orders,
       (SELECT coalesce(sum(o.total_amount), 0) FROM commerce.orders o
         WHERE o.order_date >= m.month AND o.order_date < m.month + interval '1 month'
           AND o.status NOT IN ('cancelled','refunded'))                                             AS gmv,
       (SELECT count(*) FROM civics.permit_applications p
         WHERE p.application_date >= m.month AND p.application_date < m.month + interval '1 month')  AS permits,
       (SELECT count(*) FROM documents.complaint_records c
         WHERE c.submitted_at >= m.month AND c.submitted_at < m.month + interval '1 month')          AS complaints,
       (SELECT count(DISTINCT t.trip_id) FROM mobility.trip_segments t
         WHERE t.start_time >= m.month AND t.start_time < m.month + interval '1 month')              AS trips
FROM months m;
CREATE UNIQUE INDEX monthly_activity_month_uq ON dashboard.monthly_activity (month);
REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard.monthly_activity;

-- Month-over-month growth with LAG; trips only exist for the last ~6 months.
SELECT month, orders, round(gmv) AS gmv,
       round(100.0 * (orders - lag(orders) OVER (ORDER BY month)) / nullif(lag(orders) OVER (ORDER BY month), 0), 1) AS orders_mom_pct,
       permits, complaints, trips
FROM dashboard.monthly_activity
ORDER BY month;

-- -----------------------------------------------------------------------------
-- 3. Service equity: does complaint resolution time depend on income?
-- -----------------------------------------------------------------------------
-- Teaches: estimating a planted causal-style parameter with SQL aggregates.
--   Model (the generator's truth, see meta.planted_effects):
--       ln(days_ic) = alpha_category + beta * income_z_n + noise,  beta = -0.25
--   * income_z: standardised ln(median_income) across the 24 neighbourhoods
--     (median_income = 58000 * exp(0.35 * income_z), so ln() is the right scale;
--     stddev_pop matches how the generator standardised).
--   * Within-category estimator: demean y and x inside each category, then
--     regr_slope(y_dm, x_dm). This is OLS with category fixed effects
--     (Frisch-Waugh-Lovell), removing the 6x difference in base times between
--     e.g. 'roads' (9 days) and 'animals' (1.5 days).
--   * SE(beta) = sqrt( SSE / (n - 1 - G) / Sxx ), with SSE = Syy - beta^2 * Sxx
--     and G = number of categories (fixed effects absorbed).
--   Caveats worth discussing: complaints still open at as_of are right-censored
--   (their long waits are missing), so recent submissions over-represent fast
--   resolutions. Re-estimating on complaints submitted >= 120 days before
--   as_of is a robustness check; the two samples overlap, so expect agreement
--   within about two standard errors, not identical numbers. In real data,
--   neighbourhood-level shocks would also make errors clustered by
--   neighbourhood and this naive SE optimistic (only 24 clusters!).
--   The pooled estimate is attenuated because category mix correlates with
--   income: omitting the fixed effects is a classic omitted-variable bias.
\echo '== 3. Service equity: complaint_resolution_income_gradient'
CREATE OR REPLACE VIEW dashboard.neighborhood_income_z AS
SELECT n.neighborhood_id, n.neighborhood_name, n.median_income,
       (ln(n.median_income) - avg(ln(n.median_income)) OVER ())
         / stddev_pop(ln(n.median_income)) OVER ()                     AS income_z
FROM geo.neighborhood_boundaries n
WHERE n.median_income > 0;

CREATE OR REPLACE VIEW dashboard.complaint_resolution_obs AS
SELECT c.complaint_id, c.category, c.neighborhood_id, z.income_z, c.submitted_at,
       extract(epoch FROM c.resolved_at - c.submitted_at) / 86400.0  AS days,
       ln(extract(epoch FROM c.resolved_at - c.submitted_at) / 86400.0) AS ln_days
FROM documents.complaint_records c
JOIN dashboard.neighborhood_income_z z USING (neighborhood_id)
WHERE c.status IN ('resolved', 'archived')
  AND c.resolved_at > c.submitted_at;

CREATE OR REPLACE FUNCTION dashboard.estimate_income_gradient(min_age interval DEFAULT interval '0 days')
RETURNS TABLE (estimator text, n bigint, beta numeric, std_err numeric,
               ci_low numeric, ci_high numeric, true_value numeric, truth_in_ci boolean)
LANGUAGE sql STABLE
AS $$
    WITH obs AS (
        SELECT * FROM dashboard.complaint_resolution_obs
        WHERE submitted_at <= meta.as_of() - min_age
    ),
    dm AS (
        SELECT category,
               ln_days  - avg(ln_days)  OVER (PARTITION BY category) AS y_dm,
               income_z - avg(income_z) OVER (PARTITION BY category) AS x_dm,
               ln_days, income_z
        FROM obs
    ),
    fit AS (
        SELECT 'pooled OLS (no category FE)'::text AS estimator, count(*) AS n,
               regr_slope(ln_days, income_z) AS b, regr_sxx(ln_days, income_z) AS sxx,
               regr_syy(ln_days, income_z) AS syy, 0 AS g
        FROM dm
        UNION ALL
        SELECT 'within-category OLS (category FE)', count(*),
               regr_slope(y_dm, x_dm), regr_sxx(y_dm, x_dm), regr_syy(y_dm, x_dm),
               (SELECT count(DISTINCT category) FROM obs)
        FROM dm
    ),
    se AS (
        SELECT f.*, sqrt((f.syy - f.b ^ 2 * f.sxx) / (f.n - 1 - greatest(f.g, 1)) / f.sxx) AS s
        FROM fit f
    )
    SELECT se.estimator, se.n, round(se.b::numeric, 4), round(se.s::numeric, 4),
           round((se.b - 1.96 * se.s)::numeric, 4), round((se.b + 1.96 * se.s)::numeric, 4),
           pe.true_value,
           pe.true_value BETWEEN (se.b - 1.96 * se.s)::numeric AND (se.b + 1.96 * se.s)::numeric
    FROM se
    CROSS JOIN meta.planted_effects pe
    WHERE pe.effect = 'complaint_resolution_income_gradient'
$$;

-- Estimate vs truth, all resolved complaints and the less-censored subset.
SELECT 'all resolved' AS sample, * FROM dashboard.estimate_income_gradient()
UNION ALL
SELECT 'submitted >= 120 d before as_of', * FROM dashboard.estimate_income_gradient(interval '120 days')
ORDER BY sample, estimator;

-- Interpretation in plain units: exp(beta) is the multiplicative change in
-- resolution time per +1 SD of neighbourhood income.
SELECT category, count(*) AS n,
       round(regr_slope(ln_days, income_z)::numeric, 3)                       AS beta_in_category,
       round(100 * (exp(regr_slope(ln_days, income_z)) - 1)::numeric, 1)      AS pct_change_per_sd,
       round(exp(avg(ln_days))::numeric, 2)                                   AS geo_mean_days
FROM dashboard.complaint_resolution_obs
GROUP BY category
ORDER BY n DESC, category;

-- Equity league table: income quartile vs geometric-mean resolution days,
-- adjusted for category mix (average of within-category residuals).
SELECT ntile AS income_quartile,
       count(*) AS complaints,
       round(min(median_income)) AS min_income, round(max(median_income)) AS max_income,
       round(exp(avg(ln_days - cat_mean))::numeric, 3) AS rel_time_vs_category_avg
FROM (
    SELECT o.ln_days, z.median_income,
           avg(o.ln_days) OVER (PARTITION BY o.category) AS cat_mean,
           ntile(4) OVER (ORDER BY z.income_z, o.complaint_id) AS ntile
    FROM dashboard.complaint_resolution_obs o
    JOIN dashboard.neighborhood_income_z z USING (neighborhood_id)
) q
GROUP BY ntile
ORDER BY ntile;

-- Bonus check on a second planted effect: peak/off-peak transit delay ratio
-- (peak = weekdays 07:00-08:59 and 16:00-18:59 UTC, the generator's definition).
\echo '== 3b. Planted effect check: peak_hour_bus_delay_ratio'
SELECT round((avg(delay_minutes) FILTER (WHERE is_peak)
            / avg(delay_minutes) FILTER (WHERE NOT is_peak))::numeric, 2) AS estimated_ratio,
       (SELECT true_value FROM meta.planted_effects WHERE effect = 'peak_hour_bus_delay_ratio') AS true_value,
       count(*) AS transit_segments
FROM (
    SELECT t.delay_minutes,
           extract(isodow FROM t.start_time AT TIME ZONE 'UTC') <= 5
           AND (extract(hour FROM t.start_time AT TIME ZONE 'UTC') BETWEEN 7 AND 8
             OR extract(hour FROM t.start_time AT TIME ZONE 'UTC') BETWEEN 16 AND 18) AS is_peak
    FROM mobility.trip_segments t
    WHERE t.trip_mode IN ('bus', 'rail') AND t.segment_order = 1
) s;
-- delay_minutes is stored as an integer, so the rounding nudges the ratio.

-- -----------------------------------------------------------------------------
-- 4. Cohort retention for orders
-- -----------------------------------------------------------------------------
-- Teaches: cohort = month of a customer's first order; activity = any order in
-- month k after that. One GROUP BY + FILTER pivot gives the classic triangle.
\echo '== 4. Order cohort retention (share of cohort ordering in month +k)'
CREATE OR REPLACE VIEW dashboard.order_cohort_retention AS
WITH firsts AS (
    SELECT customer_citizen_id, date_trunc('month', min(order_date)) AS cohort
    FROM commerce.orders GROUP BY customer_citizen_id
),
activity AS (
    SELECT DISTINCT o.customer_citizen_id, f.cohort,
           ((extract(year FROM date_trunc('month', o.order_date)) - extract(year FROM f.cohort)) * 12
           + extract(month FROM date_trunc('month', o.order_date)) - extract(month FROM f.cohort))::int AS k
    FROM commerce.orders o JOIN firsts f USING (customer_citizen_id)
)
-- A cell is NULL (not 0) when month +k lies after as_of: unobserved is not zero.
SELECT cohort::date AS cohort_month,
       count(*) FILTER (WHERE k = 0) AS cohort_size,
       round(count(*) FILTER (WHERE k = 1)::numeric / nullif(count(*) FILTER (WHERE k = 0), 0), 3)
           * CASE WHEN cohort + interval '1 month' <= date_trunc('month', meta.as_of()) THEN 1 END AS m1,
       round(count(*) FILTER (WHERE k = 2)::numeric / nullif(count(*) FILTER (WHERE k = 0), 0), 3)
           * CASE WHEN cohort + interval '2 months' <= date_trunc('month', meta.as_of()) THEN 1 END AS m2,
       round(count(*) FILTER (WHERE k = 3)::numeric / nullif(count(*) FILTER (WHERE k = 0), 0), 3)
           * CASE WHEN cohort + interval '3 months' <= date_trunc('month', meta.as_of()) THEN 1 END AS m3,
       round(count(*) FILTER (WHERE k = 6)::numeric / nullif(count(*) FILTER (WHERE k = 0), 0), 3)
           * CASE WHEN cohort + interval '6 months' <= date_trunc('month', meta.as_of()) THEN 1 END AS m6
FROM activity
GROUP BY cohort;

SELECT * FROM dashboard.order_cohort_retention ORDER BY cohort_month DESC LIMIT 8;

-- -----------------------------------------------------------------------------
-- 5. Subtotal reports: ROLLUP, GROUPING SETS, GROUPING()
-- -----------------------------------------------------------------------------
-- Teaches: one query, several aggregation levels. GROUPING(col) = 1 marks rows
-- where col was rolled up, which is how you label 'ALL' safely (a real NULL
-- value and a subtotal NULL are otherwise indistinguishable).
\echo '== 5a. GMV by business type x quarter with ROLLUP'
SELECT CASE WHEN GROUPING(m.business_type) = 1 THEN 'ALL TYPES' ELSE m.business_type::text END AS business_type,
       CASE WHEN GROUPING(date_trunc('quarter', o.order_date)) = 1 THEN 'ALL'
            ELSE to_char(date_trunc('quarter', o.order_date), 'YYYY-"Q"Q') END   AS quarter,
       count(*) AS orders, round(sum(o.total_amount)) AS gmv
FROM commerce.orders o
JOIN commerce.merchants m USING (merchant_id)
WHERE o.status NOT IN ('cancelled', 'refunded')
  AND o.order_date > meta.as_of() - interval '6 months'
GROUP BY ROLLUP (m.business_type, date_trunc('quarter', o.order_date))
ORDER BY GROUPING(m.business_type), m.business_type,
         GROUPING(date_trunc('quarter', o.order_date)), date_trunc('quarter', o.order_date)
LIMIT 12;

\echo '== 5b. Complaints: GROUPING SETS (category), (priority), ()'
SELECT GROUPING(category, priority_level) AS grp_bits,
       coalesce(category, '(all)')            AS category,
       coalesce(priority_level::text, '(all)') AS priority,
       count(*) AS complaints,
       round(avg(extract(epoch FROM resolved_at - submitted_at) / 86400)::numeric, 1) AS mean_days_resolved
FROM documents.complaint_records
GROUP BY GROUPING SETS ((category), (priority_level), ())
ORDER BY grp_bits, complaints DESC, category, priority;

-- -----------------------------------------------------------------------------
-- 6. Executive one-liner and maintenance
-- -----------------------------------------------------------------------------
-- Teaches: a headline view built from the other views; and a refresh function
-- (only matviews need refreshing, plain views are always current).
\echo '== 6. Executive summary'
CREATE OR REPLACE VIEW dashboard.executive_summary AS
SELECT meta.as_of() AS as_of,
       (SELECT count(*) FROM civics.citizens WHERE status = 'active')           AS active_citizens,
       (SELECT count(*) FROM commerce.merchants WHERE is_active)                AS active_merchants,
       (SELECT count(*) FROM documents.complaint_records
         WHERE status IN ('submitted', 'under_review'))                          AS open_complaints,
       (SELECT count(*) FROM dashboard.kpi_snapshot_30d WHERE trend = 'worsening') AS kpis_worsening,
       (SELECT beta FROM dashboard.estimate_income_gradient()
         WHERE estimator LIKE 'within%')                                         AS equity_gradient_beta;

SELECT * FROM dashboard.executive_summary;

CREATE OR REPLACE PROCEDURE dashboard.refresh_all()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard.monthly_activity;
    RAISE NOTICE 'dashboard.monthly_activity refreshed at %', clock_timestamp();
END;
$$;
CALL dashboard.refresh_all();
