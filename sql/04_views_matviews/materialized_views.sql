-- File: sql/04_views_matviews/materialized_views.sql
-- Purpose: Materialized views for expensive queries with REFRESH strategies
--          (plain vs CONCURRENTLY, unique-index requirement, refresh logging).
--
-- Idempotent: every materialized view is dropped (IF EXISTS) and rebuilt, so
-- definition changes are always applied on re-run. Standalone: base data only.
-- Recency windows are anchored on meta.as_of(), the dataset's reference "now".
--
-- Key facts:
--   * A materialized view stores the query RESULT; it is stale until REFRESHed.
--     PostgreSQL has no built-in incremental refresh: every REFRESH recomputes
--     the whole query.
--   * REFRESH MATERIALIZED VIEW takes an ACCESS EXCLUSIVE lock - readers block
--     for the duration.
--   * REFRESH ... CONCURRENTLY builds the new result on the side and applies a
--     diff, so readers are not blocked. It requires
--       (1) at least one UNIQUE index on plain columns (no WHERE clause, no
--           expressions) covering all rows, and
--       (2) the matview to be already populated (not WITH NO DATA).
--     It is slower than a plain refresh when most rows change.

\echo '== materialized_views =='

CREATE SCHEMA IF NOT EXISTS analytics;

-- Clean rebuild of the objects this module owns (no CASCADE: if somebody
-- built objects on top of these, we want to know rather than drop them).
DROP VIEW IF EXISTS analytics.v_matview_refresh_schedule;
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_daily_city_metrics;
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_monthly_business_performance;
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_mobility_patterns;
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_neighborhood_demographics;

-- =============================================================================
-- DAILY CITY METRICS (refreshed nightly)
-- A date spine (generate_series) LEFT JOINed to PRE-AGGREGATED per-day counts:
-- each derived table has one row per day, so the joins never fan out.
-- =============================================================================

CREATE MATERIALIZED VIEW analytics.mv_daily_city_metrics AS
SELECT
    metric_date,
    -- Citizen services
    new_citizens,
    permit_applications,
    tax_payments_made,
    complaints_submitted,
    complaints_resolved,
    -- Business activity
    new_business_licenses,
    total_orders,
    daily_revenue,
    order_amount_outliers,
    -- Transportation
    total_trips,
    inventory_snapshots,
    -- Calculated KPIs
    ROUND(complaints_resolved::NUMERIC / NULLIF(complaints_submitted, 0) * 100, 1) AS daily_complaint_resolution_rate,
    ROUND(daily_revenue / NULLIF(total_orders, 0), 2) AS avg_order_value
FROM (
    SELECT
        gs.metric_date::date                                 AS metric_date,
        COALESCE(citizens.new_citizens, 0)                   AS new_citizens,
        COALESCE(permits.permit_applications, 0)             AS permit_applications,
        COALESCE(taxes.tax_payments_made, 0)                 AS tax_payments_made,
        COALESCE(complaints_sub.complaints_submitted, 0)     AS complaints_submitted,
        COALESCE(complaints_res.complaints_resolved, 0)      AS complaints_resolved,
        COALESCE(licenses.new_business_licenses, 0)          AS new_business_licenses,
        COALESCE(orders.total_orders, 0)                     AS total_orders,
        COALESCE(orders.daily_revenue, 0)                    AS daily_revenue,
        COALESCE(orders.order_amount_outliers, 0)            AS order_amount_outliers,
        COALESCE(trips.total_trips, 0)                       AS total_trips,
        COALESCE(stations.inventory_snapshots, 0)            AS inventory_snapshots
    FROM generate_series(
        meta.as_of()::date - 89,
        meta.as_of()::date,
        INTERVAL '1 day'
    ) gs(metric_date)
    LEFT JOIN (
        SELECT registered_date::date AS metric_date, COUNT(*) AS new_citizens
        FROM civics.citizens
        GROUP BY 1
    ) citizens ON gs.metric_date = citizens.metric_date
    LEFT JOIN (
        SELECT application_date::date AS metric_date, COUNT(*) AS permit_applications
        FROM civics.permit_applications
        GROUP BY 1
    ) permits ON gs.metric_date = permits.metric_date
    LEFT JOIN (
        SELECT payment_date::date AS metric_date, COUNT(*) AS tax_payments_made
        FROM civics.tax_payments
        WHERE payment_date IS NOT NULL
        GROUP BY 1
    ) taxes ON gs.metric_date = taxes.metric_date
    LEFT JOIN (
        SELECT submitted_at::date AS metric_date, COUNT(*) AS complaints_submitted
        FROM documents.complaint_records
        GROUP BY 1
    ) complaints_sub ON gs.metric_date = complaints_sub.metric_date
    LEFT JOIN (
        SELECT resolved_at::date AS metric_date, COUNT(*) AS complaints_resolved
        FROM documents.complaint_records
        WHERE resolved_at IS NOT NULL
        GROUP BY 1
    ) complaints_res ON gs.metric_date = complaints_res.metric_date
    LEFT JOIN (
        SELECT issue_date AS metric_date, COUNT(*) AS new_business_licenses
        FROM commerce.business_licenses
        WHERE issue_date IS NOT NULL
        GROUP BY 1
    ) licenses ON gs.metric_date = licenses.metric_date
    LEFT JOIN (
        -- order_status has no 'completed': count shipped + delivered as fulfilled
        SELECT o.order_date::date AS metric_date,
               COUNT(*)            AS total_orders,
               SUM(o.total_amount) AS daily_revenue,
               COUNT(gt.entity_id) AS order_amount_outliers   -- labelled anomalies (meta.ground_truth)
        FROM commerce.orders o
        LEFT JOIN meta.ground_truth gt
               ON gt.entity = 'commerce.orders' AND gt.entity_id = o.order_id
              AND gt.label = 'order_amount_outlier'
        WHERE o.status IN ('shipped', 'delivered')
        GROUP BY 1
    ) orders ON gs.metric_date = orders.metric_date
    LEFT JOIN (
        SELECT start_time::date AS metric_date, COUNT(*) AS total_trips
        FROM mobility.trip_segments
        GROUP BY 1
    ) trips ON gs.metric_date = trips.metric_date
    LEFT JOIN (
        SELECT recorded_at::date AS metric_date, COUNT(*) AS inventory_snapshots
        FROM mobility.station_inventory
        GROUP BY 1
    ) stations ON gs.metric_date = stations.metric_date
) daily_data;
-- (no ORDER BY: row order of a matview is not guaranteed after REFRESH CONCURRENTLY anyway)

-- The UNIQUE index is what makes REFRESH ... CONCURRENTLY possible
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_daily_city_metrics_date ON analytics.mv_daily_city_metrics (metric_date);
COMMENT ON MATERIALIZED VIEW analytics.mv_daily_city_metrics IS
'Daily city-wide operational metrics (last 90 days) for dashboards. Refresh nightly (CONCURRENTLY).';

-- =============================================================================
-- MONTHLY BUSINESS PERFORMANCE (refreshed monthly)
-- Aggregate first (CTE), then apply window functions on the monthly rows:
-- easier to read than nesting LAG(SUM(...)) and avoids referencing ungrouped
-- columns inside window clauses.
-- =============================================================================

CREATE MATERIALIZED VIEW analytics.mv_monthly_business_performance AS
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', o.order_date)::date AS business_month,
        m.merchant_id,
        m.business_name,
        m.business_type,
        COUNT(o.order_id)                       AS monthly_orders,
        SUM(o.total_amount)                     AS monthly_revenue,
        COUNT(DISTINCT o.customer_citizen_id)   AS unique_customers,
        ROUND(AVG(o.total_amount), 2)           AS avg_order_value
    FROM commerce.merchants m
    JOIN commerce.orders o ON m.merchant_id = o.merchant_id
        AND o.status IN ('shipped', 'delivered')
        AND o.order_date >= DATE_TRUNC('month', meta.as_of() - INTERVAL '24 months')
    WHERE m.is_active = true
    GROUP BY 1, m.merchant_id
),
with_trends AS (
    SELECT
        monthly.*,
        LAG(monthly_orders)  OVER w AS prev_month_orders,
        LAG(monthly_revenue) OVER w AS prev_month_revenue,
        ROUND((monthly_orders - LAG(monthly_orders) OVER w) * 100.0
              / NULLIF(LAG(monthly_orders) OVER w, 0), 1)   AS month_over_month_order_growth,
        ROUND((monthly_revenue - LAG(monthly_revenue) OVER w) * 100.0
              / NULLIF(LAG(monthly_revenue) OVER w, 0), 1)  AS month_over_month_revenue_growth,
        SUM(monthly_orders)  OVER ytd AS ytd_orders,
        SUM(monthly_revenue) OVER ytd AS ytd_revenue
    FROM monthly
    WINDOW w   AS (PARTITION BY merchant_id ORDER BY business_month),
           ytd AS (PARTITION BY merchant_id, DATE_TRUNC('year', business_month) ORDER BY business_month)
)
SELECT
    *,
    RANK() OVER (PARTITION BY business_month, business_type ORDER BY monthly_revenue DESC) AS revenue_rank_by_type,
    RANK() OVER (PARTITION BY business_month ORDER BY monthly_revenue DESC)                AS overall_revenue_rank
FROM with_trends;

CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_monthly_business_perf ON analytics.mv_monthly_business_performance (business_month, merchant_id);
CREATE INDEX IF NOT EXISTS ix_mv_monthly_business_perf_type ON analytics.mv_monthly_business_performance (business_type, business_month);
COMMENT ON MATERIALIZED VIEW analytics.mv_monthly_business_performance IS
'Monthly business performance with growth trends and rankings. Refresh monthly.';

-- =============================================================================
-- MOBILITY USAGE PATTERNS (refreshed weekly)
-- The original version used correlated subqueries per group to find the most
-- popular station; besides being slow, they referenced an ungrouped column.
-- Compute "top station per (week, mode)" once with DISTINCT ON and join it.
-- =============================================================================

CREATE MATERIALIZED VIEW analytics.mv_mobility_patterns AS
WITH trips AS (
    SELECT *, DATE_TRUNC('week', start_time)::date AS pattern_week
    FROM mobility.trip_segments
    WHERE start_time >= DATE_TRUNC('week', meta.as_of() - INTERVAL '12 weeks')
),
top_start AS (
    SELECT DISTINCT ON (t.pattern_week, t.trip_mode)
           t.pattern_week, t.trip_mode, s.station_name
    FROM trips t
    JOIN mobility.stations s ON s.station_id = t.start_station_id
    GROUP BY t.pattern_week, t.trip_mode, s.station_name
    ORDER BY t.pattern_week, t.trip_mode, COUNT(*) DESC, s.station_name
),
top_end AS (
    SELECT DISTINCT ON (t.pattern_week, t.trip_mode)
           t.pattern_week, t.trip_mode, s.station_name
    FROM trips t
    JOIN mobility.stations s ON s.station_id = t.end_station_id
    GROUP BY t.pattern_week, t.trip_mode, s.station_name
    ORDER BY t.pattern_week, t.trip_mode, COUNT(*) DESC, s.station_name
),
pattern_data AS (
    SELECT
        pattern_week,
        trip_mode,
        EXTRACT(HOUR FROM start_time)::int   AS hour_of_day,
        EXTRACT(ISODOW FROM start_time)::int AS iso_day_of_week,
        COUNT(*)                             AS total_trips,
        COUNT(DISTINCT user_id)              AS unique_users,
        ROUND(AVG(distance_km), 2)           AS avg_distance_km,
        ROUND(AVG(duration_minutes), 1)      AS avg_duration_minutes,
        ROUND(AVG(delay_minutes), 2)         AS avg_delay_minutes,
        SUM(COALESCE(fare_paid, 0))          AS total_fare_revenue
    FROM trips
    GROUP BY 1, 2, 3, 4
)
SELECT
    p.*,
    ts.station_name AS most_popular_start_station,   -- for the whole (week, mode)
    te.station_name AS most_popular_end_station,
    -- Share of all trips in that week that fall into this (mode, hour, day) cell
    ROUND(p.total_trips * 100.0 / SUM(p.total_trips) OVER (PARTITION BY p.pattern_week), 3) AS share_of_week_pct,
    NTILE(4) OVER (PARTITION BY p.pattern_week ORDER BY p.total_trips) AS usage_quartile
FROM pattern_data p
LEFT JOIN top_start ts USING (pattern_week, trip_mode)
LEFT JOIN top_end   te USING (pattern_week, trip_mode);

CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_mobility_patterns
    ON analytics.mv_mobility_patterns (pattern_week, trip_mode, hour_of_day, iso_day_of_week);
CREATE INDEX IF NOT EXISTS ix_mv_mobility_patterns_mode_hour ON analytics.mv_mobility_patterns (trip_mode, hour_of_day);
COMMENT ON MATERIALIZED VIEW analytics.mv_mobility_patterns IS
'Weekly mobility usage patterns by mode, hour and weekday (last 12 weeks). Refresh weekly.';

-- =============================================================================
-- NEIGHBORHOOD DEMOGRAPHICS (refreshed quarterly)
-- Each metric is aggregated per neighbourhood in its own derived table and
-- then joined 1:1. (Joining citizens x permits x complaints x taxes x trips in
-- one go and fixing the explosion with COUNT(DISTINCT ...) is both wrong for
-- sums/averages and extremely slow.)
-- Residents/merchants are mapped via zip_code '751NN' -> neighbourhood NN.
-- =============================================================================

CREATE MATERIALIZED VIEW analytics.mv_neighborhood_demographics AS
WITH residents AS (
    SELECT substr(zip_code, 4, 2)::int AS neighborhood_id,
           citizen_id,
           EXTRACT(YEAR FROM AGE(meta.as_of(), date_of_birth)) AS age
    FROM civics.citizens
    WHERE status = 'active' AND zip_code LIKE '751__'
),
resident_stats AS (
    SELECT neighborhood_id, COUNT(*) AS active_residents, ROUND(AVG(age), 1) AS avg_resident_age
    FROM residents GROUP BY 1
),
permit_stats AS (
    SELECT r.neighborhood_id, COUNT(*) AS permits_last_year
    FROM civics.permit_applications pa
    JOIN residents r USING (citizen_id)
    WHERE pa.application_date >= meta.as_of() - INTERVAL '1 year'
    GROUP BY 1
),
complaint_stats AS (
    SELECT neighborhood_id, COUNT(*) AS complaints_last_year
    FROM documents.complaint_records
    WHERE submitted_at >= meta.as_of() - INTERVAL '1 year'
    GROUP BY 1
),
tax_stats AS (
    SELECT r.neighborhood_id,
           ROUND(COUNT(*) FILTER (WHERE tp.payment_status = 'paid') * 100.0 / NULLIF(COUNT(*), 0), 1) AS tax_compliance_rate
    FROM civics.tax_payments tp
    JOIN residents r USING (citizen_id)
    WHERE tp.tax_year = EXTRACT(YEAR FROM meta.as_of()) - 1      -- last complete tax year
    GROUP BY 1
),
business_stats AS (
    SELECT substr(zip_code, 4, 2)::int AS neighborhood_id, COUNT(*) AS active_businesses
    FROM commerce.merchants
    WHERE is_active = true AND zip_code LIKE '751__'
    GROUP BY 1
),
poi_stats AS (
    SELECT neighborhood_id, COUNT(*) AS active_pois
    FROM geo.points_of_interest
    WHERE is_active = true
    GROUP BY 1
),
station_stats AS (
    SELECT neighborhood, COUNT(*) AS mobility_stations_count
    FROM mobility.stations
    GROUP BY 1
),
trip_stats AS (
    -- trips by residents of the neighbourhood (user_id = citizen_id), last 3 months
    SELECT r.neighborhood_id, COUNT(*) AS trips_last_3_months
    FROM mobility.trip_segments ts
    JOIN residents r ON r.citizen_id = ts.user_id
    WHERE ts.start_time >= meta.as_of() - INTERVAL '3 months'
    GROUP BY 1
)
SELECT
    nb.neighborhood_id,
    nb.neighborhood_name,
    nb.population_estimate,
    nb.area_sq_km,
    nb.median_income,
    nb.city_council_district,
    -- Resident metrics
    COALESCE(rs.active_residents, 0)                                              AS active_residents,
    rs.avg_resident_age,
    ROUND(COALESCE(rs.active_residents, 0) / NULLIF(nb.area_sq_km, 0), 1)         AS resident_density_per_sq_km,
    -- Service activity
    ROUND(COALESCE(ps.permits_last_year, 0)::numeric / NULLIF(rs.active_residents, 0), 3)    AS permits_per_capita,
    ROUND(COALESCE(cs.complaints_last_year, 0)::numeric / NULLIF(rs.active_residents, 0), 3) AS complaints_per_capita,
    tx.tax_compliance_rate,
    -- Business activity
    ROUND(COALESCE(bs.active_businesses, 0) / NULLIF(nb.area_sq_km, 0), 2)       AS businesses_per_sq_km,
    ROUND(COALESCE(po.active_pois, 0) / NULLIF(nb.area_sq_km, 0), 2)             AS pois_per_sq_km,
    -- Transportation
    COALESCE(ss.mobility_stations_count, 0)                                       AS mobility_stations_count,
    ROUND(COALESCE(ts.trips_last_3_months, 0)::numeric / NULLIF(rs.active_residents, 0) / 3, 2) AS trips_per_resident_per_month,
    -- Classification
    CASE
        WHEN COALESCE(rs.active_residents, 0) > 500
             AND COALESCE(bs.active_businesses, 0) / NULLIF(nb.area_sq_km, 0) > 5 THEN 'Urban Core'
        WHEN COALESCE(rs.active_residents, 0) > 400 THEN 'Residential'
        WHEN COALESCE(bs.active_businesses, 0) / NULLIF(nb.area_sq_km, 0) > 2 THEN 'Commercial'
        ELSE 'Mixed Use'
    END AS neighborhood_type
FROM geo.neighborhood_boundaries nb
LEFT JOIN resident_stats  rs ON rs.neighborhood_id = nb.neighborhood_id
LEFT JOIN permit_stats    ps ON ps.neighborhood_id = nb.neighborhood_id
LEFT JOIN complaint_stats cs ON cs.neighborhood_id = nb.neighborhood_id
LEFT JOIN tax_stats       tx ON tx.neighborhood_id = nb.neighborhood_id
LEFT JOIN business_stats  bs ON bs.neighborhood_id = nb.neighborhood_id
LEFT JOIN poi_stats       po ON po.neighborhood_id = nb.neighborhood_id
LEFT JOIN station_stats   ss ON ss.neighborhood    = nb.neighborhood_name
LEFT JOIN trip_stats      ts ON ts.neighborhood_id = nb.neighborhood_id;

COMMENT ON MATERIALIZED VIEW analytics.mv_neighborhood_demographics IS
'Comprehensive neighborhood demographics and activity metrics. Refresh quarterly.';

-- =============================================================================
-- REFRESH CONCURRENTLY NEEDS A UNIQUE INDEX
-- mv_neighborhood_demographics has no unique index yet, so a concurrent
-- refresh fails (SQLSTATE 55000). Caught here so the script continues.
-- =============================================================================

\echo '-- REFRESH CONCURRENTLY without a unique index -> error (caught)'
DO $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_neighborhood_demographics;
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'Expected failure: %', SQLERRM;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_neighborhood_demographics ON analytics.mv_neighborhood_demographics (neighborhood_id);

\echo '-- ... and with the unique index in place it succeeds'
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_neighborhood_demographics;

-- =============================================================================
-- STALENESS DEMO (inside a transaction that is rolled back)
-- A matview does not see base-table changes until it is refreshed.
-- =============================================================================

\echo '-- Staleness: change base data, matview unchanged until REFRESH CONCURRENTLY (all rolled back)'
BEGIN;
SELECT metric_date, total_orders, daily_revenue
FROM analytics.mv_daily_city_metrics WHERE metric_date = DATE '2025-12-20';

-- Mark the cancelled orders of that day as delivered
UPDATE commerce.orders SET status = 'delivered'
WHERE order_date >= TIMESTAMPTZ '2025-12-20 00:00:00+00'
  AND order_date <  TIMESTAMPTZ '2025-12-21 00:00:00+00'
  AND status = 'cancelled';

SELECT metric_date, total_orders, daily_revenue, 'stale' AS note
FROM analytics.mv_daily_city_metrics WHERE metric_date = DATE '2025-12-20';

REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_daily_city_metrics;

SELECT metric_date, total_orders, daily_revenue, 'refreshed' AS note
FROM analytics.mv_daily_city_metrics WHERE metric_date = DATE '2025-12-20';
ROLLBACK;

-- =============================================================================
-- REFRESH MANAGEMENT: log table + functions
-- PostgreSQL does not record when a matview was last refreshed, so we log it.
-- =============================================================================

CREATE TABLE IF NOT EXISTS analytics.matview_refresh_log (
    log_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matview       regclass    NOT NULL,
    refreshed_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
    duration_ms   numeric(12, 2) NOT NULL,
    was_concurrent boolean    NOT NULL
);

COMMENT ON TABLE analytics.matview_refresh_log IS
'One row per refresh performed by analytics.refresh_materialized_views()';

-- Refresh matching matviews; uses CONCURRENTLY when allowed (populated and a
-- usable unique index exists), otherwise a plain (blocking) refresh.
-- Note: REFRESH CONCURRENTLY is allowed inside a function/transaction (unlike
-- CREATE INDEX CONCURRENTLY), but all refreshes in one call share a transaction.
DROP FUNCTION IF EXISTS analytics.refresh_materialized_views(TEXT);
DROP FUNCTION IF EXISTS analytics.refresh_materialized_views(TEXT, BOOLEAN);
CREATE FUNCTION analytics.refresh_materialized_views(
    view_pattern TEXT DEFAULT '%',
    prefer_concurrent BOOLEAN DEFAULT true)
RETURNS TEXT AS $$
DECLARE
    view_record RECORD;
    refresh_log TEXT := '';
    t0          TIMESTAMPTZ;
    elapsed_ms  NUMERIC;
    use_conc    BOOLEAN;
BEGIN
    FOR view_record IN
        SELECT c.oid, mv.schemaname, mv.matviewname, mv.ispopulated
        FROM pg_matviews mv
        JOIN pg_class c ON c.oid = format('%I.%I', mv.schemaname, mv.matviewname)::regclass
        WHERE mv.schemaname = 'analytics'
          AND mv.matviewname LIKE view_pattern
        ORDER BY mv.matviewname
    LOOP
        use_conc := prefer_concurrent AND view_record.ispopulated AND EXISTS (
            SELECT 1 FROM pg_index i
            WHERE i.indrelid = view_record.oid
              AND i.indisunique AND i.indisvalid
              AND i.indpred IS NULL AND i.indexprs IS NULL);

        t0 := clock_timestamp();
        EXECUTE format('REFRESH MATERIALIZED VIEW %s %I.%I',
                       CASE WHEN use_conc THEN 'CONCURRENTLY' ELSE '' END,
                       view_record.schemaname, view_record.matviewname);
        elapsed_ms := round((EXTRACT(EPOCH FROM clock_timestamp() - t0) * 1000)::numeric, 2);

        INSERT INTO analytics.matview_refresh_log (matview, duration_ms, was_concurrent)
        VALUES (view_record.oid, elapsed_ms, use_conc);

        refresh_log := refresh_log || format('Refreshed %I.%I (%s)%s',
            view_record.schemaname, view_record.matviewname,
            CASE WHEN use_conc THEN 'concurrently' ELSE 'blocking' END, E'\n');
    END LOOP;

    RETURN COALESCE(NULLIF(refresh_log, ''), 'No matching materialized views found');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.refresh_materialized_views(TEXT, BOOLEAN) IS
'Refresh matviews matching a LIKE pattern (CONCURRENTLY when possible) and log each refresh';

-- Status: last logged refresh, size, exact row count, and whether CONCURRENTLY is possible
DROP FUNCTION IF EXISTS analytics.materialized_view_status();
CREATE FUNCTION analytics.materialized_view_status()
RETURNS TABLE(
    view_name TEXT,
    is_populated BOOLEAN,
    last_refresh TIMESTAMPTZ,
    last_refresh_ms NUMERIC,
    size_pretty TEXT,
    row_count BIGINT,
    can_refresh_concurrently BOOLEAN
) AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT c.oid, mv.schemaname, mv.matviewname, mv.ispopulated
        FROM pg_matviews mv
        JOIN pg_class c ON c.oid = format('%I.%I', mv.schemaname, mv.matviewname)::regclass
        WHERE mv.schemaname = 'analytics'
        ORDER BY mv.matviewname
    LOOP
        view_name    := r.schemaname || '.' || r.matviewname;
        is_populated := r.ispopulated;
        SELECT l.refreshed_at, l.duration_ms INTO last_refresh, last_refresh_ms
        FROM analytics.matview_refresh_log l
        WHERE l.matview = r.oid
        ORDER BY l.refreshed_at DESC
        LIMIT 1;
        size_pretty := pg_size_pretty(pg_total_relation_size(r.oid));
        IF r.ispopulated THEN
            EXECUTE format('SELECT count(*) FROM %I.%I', r.schemaname, r.matviewname) INTO row_count;
        ELSE
            row_count := NULL;   -- selecting from an unpopulated matview raises an error
        END IF;
        can_refresh_concurrently := r.ispopulated AND EXISTS (
            SELECT 1 FROM pg_index i
            WHERE i.indrelid = r.oid AND i.indisunique AND i.indisvalid
              AND i.indpred IS NULL AND i.indexprs IS NULL);
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.materialized_view_status() IS
'Status of analytics matviews: populated flag, last logged refresh, size, row count, CONCURRENTLY eligibility';

-- Recommended refresh schedule (documentation as data)
CREATE OR REPLACE VIEW analytics.v_matview_refresh_schedule AS
SELECT *
FROM (VALUES
    ('mv_daily_city_metrics',           'Daily at 02:00',           'High',   'Dashboard critical metrics'),
    ('mv_monthly_business_performance', 'Monthly on 1st at 03:00',  'Medium', 'Business reporting and analytics'),
    ('mv_mobility_patterns',            'Weekly on Monday at 01:00','Medium', 'Transportation planning'),
    ('mv_neighborhood_demographics',    'Quarterly on 1st at 04:00','Low',    'Long-term planning and analysis')
) AS s(view_name, recommended_schedule, priority, purpose);

COMMENT ON VIEW analytics.v_matview_refresh_schedule IS
'Recommended refresh schedule for all materialized views based on data volatility';

-- Scheduling: with pg_cron (installed only in database "polaris") you would run
--   SELECT cron.schedule('refresh-daily-metrics', '0 2 * * *',
--          $$SELECT analytics.refresh_materialized_views('mv_daily%')$$);
-- See sql/14_async_patterns/pg_cron_scheduled_jobs.sql.

-- =============================================================================
-- USING THE MATVIEWS
-- =============================================================================

\echo '-- Refresh everything (logs each refresh)'
SELECT analytics.refresh_materialized_views();

\echo '-- Status'
SELECT view_name, is_populated, size_pretty, row_count, can_refresh_concurrently,
       last_refresh_ms IS NOT NULL AS has_logged_refresh
FROM analytics.materialized_view_status()
ORDER BY view_name;

\echo '-- Last 7 days of city metrics'
SELECT metric_date, new_citizens, complaints_submitted, complaints_resolved,
       total_orders, daily_revenue, order_amount_outliers, total_trips
FROM analytics.mv_daily_city_metrics
ORDER BY metric_date DESC
LIMIT 7;

\echo '-- Verifiable: labelled order outliers in the 90-day window vs meta.ground_truth'
SELECT
    (SELECT SUM(order_amount_outliers) FROM analytics.mv_daily_city_metrics) AS outliers_in_matview,
    (SELECT COUNT(*)
     FROM meta.ground_truth gt
     JOIN commerce.orders o ON o.order_id = gt.entity_id
     WHERE gt.entity = 'commerce.orders' AND gt.label = 'order_amount_outlier'
       AND o.status IN ('shipped', 'delivered')
       AND o.order_date >= meta.as_of()::date - 89) AS outliers_in_ground_truth;

\echo '-- Top 5 merchants in the latest month'
SELECT business_month, business_name, business_type, monthly_orders, monthly_revenue,
       month_over_month_revenue_growth, overall_revenue_rank
FROM analytics.mv_monthly_business_performance
WHERE business_month = (SELECT max(business_month) FROM analytics.mv_monthly_business_performance)
ORDER BY overall_revenue_rank, merchant_id
LIMIT 5;

\echo '-- Bus delay by hour band from the mobility matview (planted peak/off-peak ratio = 3)'
SELECT
    CASE WHEN iso_day_of_week <= 5 AND (hour_of_day BETWEEN 7 AND 8 OR hour_of_day BETWEEN 16 AND 18)
         THEN 'weekday peak' ELSE 'off-peak' END AS band,
    SUM(total_trips) AS trips,
    ROUND(SUM(avg_delay_minutes * total_trips) / SUM(total_trips), 2) AS weighted_avg_delay
FROM analytics.mv_mobility_patterns
WHERE trip_mode = 'bus'
GROUP BY 1
ORDER BY 1;

\echo '-- Neighbourhood profile'
SELECT neighborhood_name, active_residents, avg_resident_age, complaints_per_capita,
       tax_compliance_rate, businesses_per_sq_km, trips_per_resident_per_month, neighborhood_type
FROM analytics.mv_neighborhood_demographics
ORDER BY active_residents DESC, neighborhood_id
LIMIT 8;
