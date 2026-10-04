-- Location: /examples/analytics_showcase.sql
-- =============================================================================
-- Analytics showcase - business-intelligence patterns in plain SQL
-- =============================================================================
-- Demos (each section says what it teaches):
--   1. Order-status funnel          - FILTER aggregates, conversion percentages
--   2. Customer lifetime value      - CTE pipeline, percentile_cont, CASE tiers
--   3. RFM segmentation             - NTILE window scoring, recency vs meta.as_of()
--   4. Weekly trend + moving avg    - date_bin, window frames (ROWS BETWEEN)
--   5. Category x quarter matrix    - GROUPING SETS / ROLLUP with GROUPING()
--   6. Cohort retention             - first-purchase cohorts, month offsets
--   7. Recovering a planted effect  - Zipf merchant popularity via regr_slope
--   8. Civic analytics              - turnout by age band (logistic effect)
--
-- Read-only. All recency uses meta.as_of() (dataset "now" = 2025-12-31 23:59:59
-- UTC); now() would return an empty window on this historical dataset.
-- Run: psql -X -v ON_ERROR_STOP=1 -d <db> -f /examples/analytics_showcase.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset null '-'

\echo ''
\echo '=== 1. Order-status funnel: how many orders reach each stage? ==='
-- An order passes pending -> confirmed -> processing -> shipped -> delivered;
-- cancelled / refunded leave the funnel. FILTER keeps it to one table scan.
SELECT count(*)                                                     AS placed,
       count(*) FILTER (WHERE status NOT IN ('pending', 'cancelled'))  AS confirmed_or_later,
       count(*) FILTER (WHERE status IN ('shipped', 'delivered', 'refunded')) AS shipped_or_later,
       count(*) FILTER (WHERE status = 'delivered')                  AS delivered,
       count(*) FILTER (WHERE status = 'cancelled')                  AS cancelled,
       count(*) FILTER (WHERE status = 'refunded')                   AS refunded,
       round(100.0 * count(*) FILTER (WHERE status = 'delivered') / count(*), 1) AS delivered_pct
FROM commerce.orders;

\echo ''
\echo '=== 2. Customer lifetime value tiers (relative to the CLV distribution) ==='
WITH clv AS (
    SELECT customer_citizen_id                         AS citizen_id,
           count(*)                                    AS orders,
           sum(total_amount)                           AS lifetime_value,
           min(order_date)                             AS first_order,
           max(order_date)                             AS last_order
    FROM commerce.orders
    WHERE customer_citizen_id IS NOT NULL
      AND status NOT IN ('cancelled', 'refunded')
    GROUP BY customer_citizen_id
), cut AS (
    SELECT percentile_cont(ARRAY[0.5, 0.9]) WITHIN GROUP (ORDER BY lifetime_value) AS p
    FROM clv
)
SELECT CASE WHEN lifetime_value >= p[2] THEN '1 top 10%'
            WHEN lifetime_value >= p[1] THEN '2 above median'
            ELSE                             '3 below median' END AS tier,
       count(*)                                              AS customers,
       round(avg(orders), 1)                                 AS avg_orders,
       round(avg(lifetime_value), 2)                         AS avg_clv,
       round(sum(lifetime_value) / sum(sum(lifetime_value)) OVER () * 100, 1) AS share_of_revenue_pct
FROM clv, cut
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== 3. RFM segmentation (Recency, Frequency, Monetary quintiles) ==='
-- Recency is measured against meta.as_of(), the dataset's "today".
WITH base AS (
    SELECT customer_citizen_id AS citizen_id,
           extract(day FROM meta.as_of() - max(order_date))::int AS days_since_last,
           count(*)                                              AS frequency,
           sum(total_amount)                                     AS monetary
    FROM commerce.orders
    WHERE customer_citizen_id IS NOT NULL AND status NOT IN ('cancelled', 'refunded')
    GROUP BY customer_citizen_id
), scored AS (
    SELECT *,
           ntile(5) OVER (ORDER BY days_since_last DESC) AS r,   -- 5 = most recent
           ntile(5) OVER (ORDER BY frequency)            AS f,
           ntile(5) OVER (ORDER BY monetary)             AS m
    FROM base
)
SELECT CASE WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Champions'
            WHEN r >= 3 AND f >= 3              THEN 'Loyal'
            WHEN r >= 4 AND f <= 2              THEN 'New / promising'
            WHEN r <= 2 AND f >= 3              THEN 'At risk'
            WHEN r <= 2                         THEN 'Hibernating'
            ELSE                                     'Needs attention' END AS segment,
       count(*)                       AS customers,
       round(avg(days_since_last))    AS avg_days_since_last,
       round(avg(frequency), 1)       AS avg_orders,
       round(avg(monetary), 2)        AS avg_spend
FROM scored
GROUP BY 1
ORDER BY customers DESC;

\echo ''
\echo '=== 4. Weekly revenue, last 12 weeks, with a 4-week moving average ==='
-- date_bin (PG14+) buckets into fixed-width bins anchored on any origin.
WITH weekly AS (
    SELECT date_bin('7 days', order_date, meta.as_of() - interval '84 days') AS week_start,
           count(*)          AS orders,
           sum(total_amount) AS revenue
    FROM commerce.orders
    WHERE order_date > meta.as_of() - interval '84 days'
      AND status NOT IN ('cancelled', 'refunded')
    GROUP BY 1
)
SELECT week_start::date,
       orders,
       revenue,
       round(avg(revenue) OVER (ORDER BY week_start ROWS BETWEEN 3 PRECEDING AND CURRENT ROW), 2) AS moving_avg_4w,
       round(100.0 * (revenue / lag(revenue) OVER (ORDER BY week_start) - 1), 1)                  AS wow_pct
FROM weekly
ORDER BY week_start;

\echo ''
\echo '=== 5. Category x quarter matrix with subtotals (ROLLUP) ==='
-- GROUPING(col) = 1 marks a subtotal row produced by ROLLUP.
SELECT CASE WHEN grouping(m.business_type) = 1 THEN 'ALL TYPES' ELSE m.business_type::text END AS business_type,
       CASE WHEN grouping(q.quarter) = 1 THEN 'FY'        ELSE q.quarter END            AS period,
       count(*)                     AS orders,
       sum(o.total_amount)          AS revenue,
       round(avg(o.total_amount), 2) AS avg_ticket
FROM commerce.orders o
JOIN commerce.merchants m USING (merchant_id)
CROSS JOIN LATERAL (SELECT 'Q' || extract(quarter FROM o.order_date)::int AS quarter) q
WHERE o.order_date >= date_trunc('year', meta.as_of())
  AND o.status NOT IN ('cancelled', 'refunded')
  AND m.business_type IN ('technology', 'restaurant', 'retail')   -- keep the matrix compact
GROUP BY ROLLUP (m.business_type, q.quarter)
ORDER BY grouping(m.business_type), m.business_type, grouping(q.quarter), q.quarter;

\echo ''
\echo '=== 6. Cohort retention: % of each first-purchase cohort still ordering N months later ==='
WITH firsts AS (
    SELECT customer_citizen_id AS cid, date_trunc('month', min(order_date)) AS cohort
    FROM commerce.orders
    WHERE customer_citizen_id IS NOT NULL
    GROUP BY 1
), activity AS (
    SELECT DISTINCT f.cohort,
           f.cid,
           (extract(year FROM age(date_trunc('month', o.order_date), f.cohort)) * 12
            + extract(month FROM age(date_trunc('month', o.order_date), f.cohort)))::int AS month_offset
    FROM firsts f
    JOIN commerce.orders o ON o.customer_citizen_id = f.cid
)
SELECT cohort::date,
       count(DISTINCT cid)                                                           AS cohort_size,
       round(100.0 * count(DISTINCT cid) FILTER (WHERE month_offset = 1) / count(DISTINCT cid), 1) AS m1_pct,
       round(100.0 * count(DISTINCT cid) FILTER (WHERE month_offset = 3) / count(DISTINCT cid), 1) AS m3_pct,
       round(100.0 * count(DISTINCT cid) FILTER (WHERE month_offset = 6) / count(DISTINCT cid), 1) AS m6_pct
FROM activity
WHERE cohort >= date_trunc('year', meta.as_of())
  AND cohort <  date_trunc('year', meta.as_of()) + interval '6 months'
GROUP BY cohort
ORDER BY cohort;

\echo ''
\echo '=== 7. Planted effect: merchant popularity follows a power law (Zipf) ==='
-- If orders(rank) ~ rank^(-s), then ln(orders) = c - s * ln(rank):
-- the regression slope on a log-log scale recovers -s.
WITH ranked AS (
    SELECT merchant_id, count(*) AS orders,
           row_number() OVER (ORDER BY count(*) DESC, merchant_id) AS rnk
    FROM commerce.orders
    GROUP BY merchant_id
)
SELECT round(-regr_slope(ln(orders), ln(rnk))::numeric, 3)                       AS recovered_exponent,
       (SELECT true_value FROM meta.planted_effects
        WHERE effect = 'merchant_popularity_zipf_exponent')                      AS planted_exponent,
       round(regr_r2(ln(orders), ln(rnk))::numeric, 3)                           AS r_squared,
       round(100.0 * sum(orders) FILTER (WHERE rnk <= 50) / sum(orders), 1)      AS top50_share_pct
FROM ranked
WHERE rnk <= 200;          -- the head of the distribution, before small-count noise

\echo ''
\echo '=== 8. Civic analytics: turnout by age band (planted: +0.035 logit per year) ==='
WITH elig AS (
    SELECT c.citizen_id,
           width_bucket(extract(year FROM age(meta.as_of(), c.date_of_birth::timestamptz)), 18, 88, 7) AS band,
           EXISTS (SELECT 1 FROM civics.voting_records v WHERE v.citizen_id = c.citizen_id) AS voted
    FROM civics.citizens c
    WHERE c.date_of_birth <= (meta.as_of() - interval '18 years')::date
)
SELECT (18 + (band - 1) * 10) || '-' || (17 + band * 10) AS age_band,
       count(*)                                          AS citizens,
       round(100.0 * count(*) FILTER (WHERE voted) / count(*), 1) AS voted_in_any_election_pct
FROM elig
WHERE band BETWEEN 1 AND 7
GROUP BY band
ORDER BY band;
