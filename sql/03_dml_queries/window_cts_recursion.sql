-- File: sql/03_dml_queries/window_cts_recursion.sql
-- Purpose: Window functions, frames, Common Table Expressions, recursive CTEs
--
-- Read-only lesson (creates nothing). Recency windows are anchored on
-- meta.as_of() - the dataset's reference "now" - not on CURRENT_DATE.
-- commerce.order_status values: pending, confirmed, processing, shipped,
-- delivered, cancelled, refunded (there is no 'completed').

\echo '== window_cts_recursion =='

-- =============================================================================
-- WINDOW FUNCTIONS - RANKING AND ORDERING
-- RANK leaves gaps after ties, DENSE_RANK does not, ROW_NUMBER is always unique
-- (add a tie-breaker to make it deterministic), PERCENT_RANK is (rank-1)/(n-1),
-- NTILE(n) splits the partition into n nearly equal buckets.
-- =============================================================================

\echo '-- Ranking merchants by 2025 delivered revenue within business type (top 3 per type)'
WITH merchant_revenue AS (
    SELECT
        m.merchant_id,
        m.business_name,
        m.business_type,
        COUNT(o.order_id)                   AS total_orders,
        COALESCE(SUM(o.total_amount), 0)    AS total_revenue   -- SUM over zero rows is NULL
    FROM commerce.merchants m
    LEFT JOIN commerce.orders o ON m.merchant_id = o.merchant_id
        AND o.status = 'delivered'
        AND o.order_date >= '2025-01-01'
    WHERE m.is_active = true
    GROUP BY m.merchant_id
),
ranked AS (
    SELECT
        business_name,
        business_type,
        total_orders,
        total_revenue,
        RANK()         OVER w_desc AS revenue_rank,
        DENSE_RANK()   OVER w_desc AS dense_revenue_rank,
        ROW_NUMBER()   OVER (PARTITION BY business_type ORDER BY total_revenue DESC, merchant_id) AS row_num,
        ROUND(PERCENT_RANK() OVER w_asc::numeric, 3) AS percentile_rank,
        NTILE(4)       OVER w_asc  AS revenue_quartile
    FROM merchant_revenue
    WINDOW w_desc AS (PARTITION BY business_type ORDER BY total_revenue DESC),
           w_asc  AS (PARTITION BY business_type ORDER BY total_revenue)
)
SELECT * FROM ranked
WHERE row_num <= 3
ORDER BY business_type, row_num;

-- =============================================================================
-- WINDOW FUNCTIONS - ANALYTICAL (offset & value) FUNCTIONS
-- =============================================================================

\echo '-- Monthly citizen registrations with LAG/LEAD/FIRST_VALUE/LAST_VALUE/NTH_VALUE'
-- LAST_VALUE needs a frame that reaches the end of the partition: with the
-- default frame (... AND CURRENT ROW) it just returns the current row.
SELECT
    registration_month::date,
    monthly_registrations,
    LAG(monthly_registrations)  OVER w AS prev_month,
    LEAD(monthly_registrations) OVER w AS next_month,
    monthly_registrations - LAG(monthly_registrations) OVER w AS month_over_month_change,
    FIRST_VALUE(monthly_registrations) OVER w AS first_month_registrations,
    LAST_VALUE(monthly_registrations)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_month_registrations,
    NTH_VALUE(monthly_registrations, 2) OVER w AS second_month_registrations   -- NULL on row 1 (frame too short)
FROM (
    SELECT
        DATE_TRUNC('month', registered_date) AS registration_month,
        COUNT(*) AS monthly_registrations
    FROM civics.citizens
    WHERE registered_date >= '2025-01-01'
    GROUP BY 1
) monthly_stats
WINDOW w AS (ORDER BY registration_month)
ORDER BY registration_month;

-- =============================================================================
-- WINDOW FRAMES - RUNNING CALCULATIONS
-- =============================================================================

\echo '-- Daily order metrics over the last 30 days with different frame types'
SELECT
    order_day,
    daily_orders,
    daily_revenue,
    -- Default frame with ORDER BY: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    SUM(daily_orders) OVER (ORDER BY order_day) AS cumulative_orders,

    -- ROWS frame: exactly 7 physical rows (wrong if a day is missing!)
    SUM(daily_revenue) OVER (ORDER BY order_day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_7_row_revenue,

    -- RANGE frame with an offset: 7 calendar days, robust to gaps
    ROUND(AVG(daily_orders) OVER (ORDER BY order_day
                                  RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW), 1) AS avg_orders_7_days,

    -- Centred moving average
    ROUND(AVG(daily_revenue) OVER (ORDER BY order_day ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING), 2) AS centered_7_day_avg,

    -- Empty OVER () = the whole result set
    ROUND(daily_revenue * 100.0 / SUM(daily_revenue) OVER (), 2) AS pct_of_total_revenue
FROM (
    SELECT
        order_date::date   AS order_day,       -- date (not timestamp) so RANGE offsets work on days
        COUNT(*)           AS daily_orders,
        SUM(total_amount)  AS daily_revenue
    FROM commerce.orders
    WHERE order_date >= meta.as_of() - INTERVAL '30 days'
        AND status IN ('shipped', 'delivered')
    GROUP BY 1
) daily_stats
ORDER BY order_day
LIMIT 10;

\echo '-- Frame EXCLUDE (PG 11+) and GROUPS mode: compare each day to its neighbours, not itself'
SELECT
    order_day,
    daily_orders,
    ROUND(AVG(daily_orders) OVER (ORDER BY order_day
                                  GROUPS BETWEEN 3 PRECEDING AND 3 FOLLOWING
                                  EXCLUDE CURRENT ROW), 1) AS neighbours_avg
FROM (
    SELECT order_date::date AS order_day, COUNT(*) AS daily_orders
    FROM commerce.orders
    WHERE order_date >= meta.as_of() - INTERVAL '14 days'
    GROUP BY 1
) d
ORDER BY order_day;

-- =============================================================================
-- COMMON TABLE EXPRESSIONS (CTEs) - SINGLE LEVEL, CHAINED
-- Since PG 12 non-recursive CTEs referenced once are inlined (optimisation
-- fence removed); use AS MATERIALIZED / NOT MATERIALIZED to override.
-- =============================================================================

\echo '-- Customer segmentation with chained CTEs (top 10 spenders)'
WITH customer_orders AS (
    SELECT
        c.citizen_id,
        c.first_name || ' ' || c.last_name AS customer_name,
        c.email,
        c.zip_code,
        COUNT(o.order_id)   AS total_orders,
        SUM(o.total_amount) AS total_spent,
        AVG(o.total_amount) AS avg_order_value,
        MIN(o.order_date)   AS first_order_date,
        MAX(o.order_date)   AS last_order_date
    FROM civics.citizens c
    JOIN commerce.orders o ON c.citizen_id = o.customer_citizen_id
    WHERE o.status = 'delivered'
    GROUP BY c.citizen_id
),
customer_segments AS MATERIALIZED (   -- referenced twice below: compute once
    SELECT
        *,
        CASE
            WHEN total_orders >= 10 AND avg_order_value >= 50 THEN 'VIP'
            WHEN total_orders >= 5 OR avg_order_value >= 75 THEN 'High Value'
            WHEN total_orders >= 2 THEN 'Regular'
            ELSE 'New'
        END AS customer_segment,
        meta.as_of()::date - last_order_date::date AS days_since_last_order
    FROM customer_orders
),
segment_stats AS (
    SELECT
        customer_segment,
        COUNT(*)                   AS customer_count,
        AVG(total_spent)           AS avg_total_spent,
        AVG(avg_order_value)       AS avg_order_value,
        AVG(days_since_last_order) AS avg_days_since_last_order
    FROM customer_segments
    GROUP BY customer_segment
)
SELECT
    cs.customer_name,
    cs.customer_segment,
    cs.total_orders,
    cs.total_spent,
    ROUND(cs.avg_order_value, 2) AS avg_order_value,
    cs.days_since_last_order,
    ROUND(ss.avg_total_spent, 2) AS segment_avg_spent,
    ROUND((cs.total_spent - ss.avg_total_spent) / ss.avg_total_spent * 100, 1) AS vs_segment_avg_pct
FROM customer_segments cs
JOIN segment_stats ss ON cs.customer_segment = ss.customer_segment
ORDER BY cs.total_spent DESC, cs.citizen_id
LIMIT 10;

-- =============================================================================
-- RECURSIVE CTEs - HIERARCHICAL DATA
-- =============================================================================

\echo '-- Policy supersession chains (root = a policy that supersedes nothing)'
-- PG 14+: SEARCH DEPTH FIRST builds an ordering column, CYCLE detects loops
-- (replacing the hand-written "NOT id = ANY(path)" trick).
WITH RECURSIVE policy_hierarchy AS (
    -- Anchor: roots of chains (any status - superseded versions are usually archived)
    SELECT
        policy_id,
        policy_number,
        title,
        version,
        status,
        supersedes_policy_id,
        0 AS hierarchy_level,
        policy_number AS root_policy,
        (policy_number || ' v' || version)::text AS chain
    FROM documents.policy_documents
    WHERE supersedes_policy_id IS NULL

    UNION ALL

    -- Recursive step: policies that supersede a row already found
    SELECT
        p.policy_id,
        p.policy_number,
        p.title,
        p.version,
        p.status,
        p.supersedes_policy_id,
        ph.hierarchy_level + 1,
        ph.root_policy,
        ph.chain || ' -> ' || p.policy_number || ' v' || p.version
    FROM documents.policy_documents p
    JOIN policy_hierarchy ph ON p.supersedes_policy_id = ph.policy_id
)
SEARCH DEPTH FIRST BY policy_id SET dfs_order
CYCLE policy_id SET is_cycle USING path
SELECT indented_policy_number, version, status, hierarchy_level, chain, is_cycle
FROM (
    SELECT
        REPEAT('  ', hierarchy_level) || policy_number AS indented_policy_number,
        version, status, hierarchy_level, chain, is_cycle, dfs_order,
        MAX(hierarchy_level) OVER (PARTITION BY root_policy) AS chain_depth
    FROM policy_hierarchy
) t
WHERE chain_depth > 0          -- only chains that actually have a successor
ORDER BY dfs_order
LIMIT 12;

\echo '-- Recursive date spine joined to PRE-AGGREGATED daily counts (last 14 days)'
-- Joining two detail tables to the spine directly would multiply rows
-- (complaints x orders per day) and inflate both counts. Aggregate first.
-- generate_series(start, stop, '1 day') is the idiomatic non-recursive spine.
WITH RECURSIVE date_series AS (
    SELECT (meta.as_of()::date - 13) AS series_date
    UNION ALL
    SELECT series_date + 1
    FROM date_series
    WHERE series_date < meta.as_of()::date
),
complaints_per_day AS (
    SELECT submitted_at::date AS d, COUNT(*) AS n
    FROM documents.complaint_records
    WHERE submitted_at >= meta.as_of()::date - 13
    GROUP BY 1
),
orders_per_day AS (
    SELECT order_date::date AS d, COUNT(*) AS n
    FROM commerce.orders
    WHERE order_date >= meta.as_of()::date - 13
      AND status IN ('shipped', 'delivered')
    GROUP BY 1
)
SELECT
    ds.series_date,
    TO_CHAR(ds.series_date, 'Dy')  AS day_name,
    COALESCE(c.n, 0)               AS complaints_count,
    COALESCE(o.n, 0)               AS orders_count     -- zero-filled days (orders end 2025-12-28)
FROM date_series ds
LEFT JOIN complaints_per_day c ON c.d = ds.series_date
LEFT JOIN orders_per_day o     ON o.d = ds.series_date
ORDER BY ds.series_date;

\echo '-- Recursive graph walk: road segments reachable within 3 hops of the first segment'
-- Two segments are connected when they share an endpoint (grid network).
WITH RECURSIVE reach AS (
    SELECT segment_id, 0 AS hops
    FROM geo.road_segments
    WHERE segment_id = (SELECT min(segment_id) FROM geo.road_segments)
    UNION
    SELECT r2.segment_id, reach.hops + 1
    FROM reach
    JOIN geo.road_segments r1 ON r1.segment_id = reach.segment_id
    JOIN geo.road_segments r2
      ON r2.segment_id <> r1.segment_id
     AND ST_DWithin(r2.segment_geom, r1.segment_geom, 0)      -- touching; uses the GiST index
    WHERE reach.hops < 3
)
SELECT hops, COUNT(DISTINCT segment_id) AS segments_first_reached
FROM (SELECT segment_id, MIN(hops) AS hops FROM reach GROUP BY segment_id) s
GROUP BY hops
ORDER BY hops;

-- =============================================================================
-- ADVANCED CTE PATTERNS
-- =============================================================================

\echo '-- Multi-metric weekly trends (UNION ALL of daily metrics -> weekly -> WoW %)'
WITH daily_metrics AS (
    SELECT order_date::date AS metric_date, 'orders' AS metric_type, COUNT(*) AS metric_value
    FROM commerce.orders
    WHERE order_date >= meta.as_of() - INTERVAL '90 days'
    GROUP BY 1

    UNION ALL

    SELECT submitted_at::date, 'complaints', COUNT(*)
    FROM documents.complaint_records
    WHERE submitted_at >= meta.as_of() - INTERVAL '90 days'
    GROUP BY 1

    UNION ALL

    SELECT start_time::date, 'trips', COUNT(*)
    FROM mobility.trip_segments
    WHERE start_time >= meta.as_of() - INTERVAL '90 days'
    GROUP BY 1
),
weekly_aggregates AS (
    SELECT
        DATE_TRUNC('week', metric_date)::date AS week_start,
        metric_type,
        SUM(metric_value)           AS weekly_total,
        ROUND(AVG(metric_value), 1) AS daily_avg,
        MIN(metric_value)           AS daily_min,
        MAX(metric_value)           AS daily_max
    FROM daily_metrics
    GROUP BY 1, 2
),
metric_trends AS (
    SELECT
        *,
        LAG(weekly_total) OVER w AS prev_week_total,
        ROUND((weekly_total - LAG(weekly_total) OVER w) * 100.0
              / NULLIF(LAG(weekly_total) OVER w, 0), 1) AS week_over_week_pct
    FROM weekly_aggregates
    WINDOW w AS (PARTITION BY metric_type ORDER BY week_start)
)
SELECT
    week_start,
    metric_type,
    weekly_total,
    prev_week_total,
    week_over_week_pct,
    CASE
        WHEN week_over_week_pct IS NULL THEN 'n/a'
        WHEN week_over_week_pct > 10 THEN 'Strong Growth'
        WHEN week_over_week_pct > 0 THEN 'Growth'
        WHEN week_over_week_pct > -10 THEN 'Stable'
        ELSE 'Declining'
    END AS trend_category
FROM metric_trends
WHERE week_start >= meta.as_of()::date - 28
  AND week_start + 6 <= meta.as_of()::date      -- drop the trailing partial week (it always looks like a decline)
ORDER BY week_start, metric_type;

-- =============================================================================
-- WINDOW FUNCTIONS WITH CTEs
-- =============================================================================

\echo '-- Station utilisation by hour (last 7 days): average, peak, trough and peak hour'
WITH hourly_utilization AS (
    SELECT
        s.station_id,
        s.station_name,
        s.station_type,
        EXTRACT(HOUR FROM si.recorded_at)::int AS hour_of_day,
        AVG(si.in_use_count::numeric / NULLIF(s.total_capacity, 0)) AS utilization_rate
    FROM mobility.stations s
    JOIN mobility.station_inventory si ON s.station_id = si.station_id
    WHERE si.recorded_at >= meta.as_of() - INTERVAL '7 days'
        AND s.total_capacity > 0
    GROUP BY s.station_id, hour_of_day
),
station_profile AS (
    SELECT
        station_id,
        station_name,
        station_type,
        hour_of_day,
        utilization_rate,
        AVG(utilization_rate) OVER (PARTITION BY station_id) AS avg_utilization,
        MAX(utilization_rate) OVER (PARTITION BY station_id) AS peak_utilization,
        MIN(utilization_rate) OVER (PARTITION BY station_id) AS min_utilization,
        ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY utilization_rate DESC, hour_of_day) AS rn
    FROM hourly_utilization
)
SELECT
    station_name,
    station_type,
    ROUND(avg_utilization * 100, 1)  AS avg_utilization_pct,
    ROUND(peak_utilization * 100, 1) AS peak_utilization_pct,
    ROUND(min_utilization * 100, 1)  AS min_utilization_pct,
    hour_of_day                      AS peak_hour
FROM station_profile
WHERE rn = 1          -- one row per station: its busiest hour
ORDER BY avg_utilization DESC, station_id
LIMIT 10;
