-- File: sql/04_views_matviews/materialized_views.sql
-- Purpose: Materialized views for expensive queries with REFRESH strategies

-- =============================================================================
-- DAILY CITY METRICS (Refreshed nightly)
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
    -- Transportation
    total_trips,
    station_utilizations,
    -- Calculated KPIs
    ROUND(complaints_resolved::NUMERIC / NULLIF(complaints_submitted, 0) * 100, 1) as daily_complaint_resolution_rate,
    ROUND(daily_revenue / NULLIF(total_orders, 0), 2) as avg_order_value
FROM (
    SELECT
        gs.metric_date,
        COALESCE(citizens.new_citizens, 0) as new_citizens,
        COALESCE(permits.permit_applications, 0) as permit_applications,
        COALESCE(taxes.tax_payments_made, 0) as tax_payments_made,
        COALESCE(complaints_sub.complaints_submitted, 0) as complaints_submitted,
        COALESCE(complaints_res.complaints_resolved, 0) as complaints_resolved,
        COALESCE(licenses.new_business_licenses, 0) as new_business_licenses,
        COALESCE(orders.total_orders, 0) as total_orders,
        COALESCE(orders.daily_revenue, 0) as daily_revenue,
        COALESCE(trips.total_trips, 0) as total_trips,
        COALESCE(stations.station_utilizations, 0) as station_utilizations
    FROM generate_series(
        CURRENT_DATE - INTERVAL '90 days',
        CURRENT_DATE,
        INTERVAL '1 day'
    ) gs(metric_date)
    LEFT JOIN (
        SELECT registered_date::date as metric_date, COUNT(*) as new_citizens
        FROM civics.citizens
        GROUP BY registered_date::date
    ) citizens ON gs.metric_date = citizens.metric_date
    LEFT JOIN (
        SELECT application_date::date as metric_date, COUNT(*) as permit_applications
        FROM civics.permit_applications
        GROUP BY application_date::date
    ) permits ON gs.metric_date = permits.metric_date
    LEFT JOIN (
        SELECT payment_date::date as metric_date, COUNT(*) as tax_payments_made
        FROM civics.tax_payments
        WHERE payment_date IS NOT NULL
        GROUP BY payment_date::date
    ) taxes ON gs.metric_date = taxes.metric_date
    LEFT JOIN (
        SELECT submitted_at::date as metric_date, COUNT(*) as complaints_submitted
        FROM documents.complaint_records
        GROUP BY submitted_at::date
    ) complaints_sub ON gs.metric_date = complaints_sub.metric_date
    LEFT JOIN (
        SELECT resolved_at::date as metric_date, COUNT(*) as complaints_resolved
        FROM documents.complaint_records
        WHERE resolved_at IS NOT NULL
        GROUP BY resolved_at::date
    ) complaints_res ON gs.metric_date = complaints_res.metric_date
    LEFT JOIN (
        SELECT issue_date::date as metric_date, COUNT(*) as new_business_licenses
        FROM commerce.business_licenses
        WHERE issue_date IS NOT NULL
        GROUP BY issue_date::date
    ) licenses ON gs.metric_date = licenses.metric_date
    LEFT JOIN (
        SELECT order_date::date as metric_date, COUNT(*) as total_orders, SUM(total_amount) as daily_revenue
        FROM commerce.orders
        WHERE status IN ('delivered', 'completed')
        GROUP BY order_date::date
    ) orders ON gs.metric_date = orders.metric_date
    LEFT JOIN (
        SELECT start_time::date as metric_date, COUNT(*) as total_trips
        FROM mobility.trip_segments
        GROUP BY start_time::date
    ) trips ON gs.metric_date = trips.metric_date
    LEFT JOIN (
        SELECT recorded_at::date as metric_date, COUNT(*) as station_utilizations
        FROM mobility.station_inventory
        GROUP BY recorded_at::date
    ) stations ON gs.metric_date = stations.metric_date
) daily_data
ORDER BY metric_date DESC;

CREATE UNIQUE INDEX ON analytics.mv_daily_city_metrics (metric_date);
COMMENT ON MATERIALIZED VIEW analytics.mv_daily_city_metrics IS
'Daily city-wide operational metrics aggregated for dashboard and reporting. Refresh nightly.';

-- =============================================================================
-- MONTHLY BUSINESS PERFORMANCE (Refreshed monthly)
-- =============================================================================

CREATE MATERIALIZED VIEW analytics.mv_monthly_business_performance AS
SELECT
    business_month,
    merchant_id,
    business_name,
    business_type,
    monthly_orders,
    monthly_revenue,
    unique_customers,
    avg_order_value,
    prev_month_orders,
    prev_month_revenue,
    month_over_month_order_growth,
    month_over_month_revenue_growth,
    ytd_orders,
    ytd_revenue,
    -- Rankings
    RANK() OVER (PARTITION BY business_month, business_type ORDER BY monthly_revenue DESC) as revenue_rank_by_type,
    RANK() OVER (PARTITION BY business_month ORDER BY monthly_revenue DESC) as overall_revenue_rank
FROM (
    SELECT
        DATE_TRUNC('month', o.order_date) as business_month,
        m.merchant_id,
        m.business_name,
        m.business_type,
        COUNT(o.order_id) as monthly_orders,
        SUM(o.total_amount) as monthly_revenue,
        COUNT(DISTINCT o.customer_citizen_id) as unique_customers,
        ROUND(AVG(o.total_amount), 2) as avg_order_value,
        LAG(COUNT(o.order_id)) OVER (PARTITION BY m.merchant_id ORDER BY DATE_TRUNC('month', o.order_date)) as prev_month_orders,
        LAG(SUM(o.total_amount)) OVER (PARTITION BY m.merchant_id ORDER BY DATE_TRUNC('month', o.order_date)) as prev_month_revenue,
        ROUND(
            (COUNT(o.order_id) - LAG(COUNT(o.order_id)) OVER (PARTITION BY m.merchant_id ORDER BY DATE_TRUNC('month', o.order_date))) * 100.0 /
            NULLIF(LAG(COUNT(o.order_id)) OVER (PARTITION BY m.merchant_id ORDER BY DATE_TRUNC('month', o.order_date)), 0), 1
        ) as month_over_month_order_growth,
        ROUND(
            (SUM(o.total_amount) - LAG(SUM(o.total_amount)) OVER (PARTITION BY m.merchant_id ORDER BY DATE_TRUNC('month', o.order_date))) * 100.0 /
            NULLIF(LAG(SUM(o.total_amount)) OVER (PARTITION BY m.merchant_id ORDER BY DATE_TRUNC('month', o.order_date)), 0), 1
        ) as month_over_month_revenue_growth,
        SUM(COUNT(o.order_id)) OVER (PARTITION BY m.merchant_id, EXTRACT(YEAR FROM o.order_date) ORDER BY DATE_TRUNC('month', o.order_date)) as ytd_orders,
        SUM(SUM(o.total_amount)) OVER (PARTITION BY m.merchant_id, EXTRACT(YEAR FROM o.order_date) ORDER BY DATE_TRUNC('month', o.order_date)) as ytd_revenue
    FROM commerce.merchants m
    LEFT JOIN commerce.orders o ON m.merchant_id = o.merchant_id
        AND o.status IN ('delivered', 'completed')
        AND o.order_date >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '24 months')
    WHERE m.is_active = true
    GROUP BY m.merchant_id, m.business_name, m.business_type, DATE_TRUNC('month', o.order_date)
) monthly_data
WHERE business_month IS NOT NULL
ORDER BY business_month DESC, monthly_revenue DESC;

CREATE UNIQUE INDEX ON analytics.mv_monthly_business_performance (business_month, merchant_id);
CREATE INDEX ON analytics.mv_monthly_business_performance (business_type, business_month);
COMMENT ON MATERIALIZED VIEW analytics.mv_monthly_business_performance IS
'Monthly business performance with growth trends and rankings. Refresh monthly.';

-- =============================================================================
-- MOBILITY USAGE PATTERNS (Refreshed weekly)
-- =============================================================================

CREATE MATERIALIZED VIEW analytics.mv_mobility_patterns AS
SELECT
    pattern_week,
    trip_mode,
    hour_of_day,
    day_of_week,
    total_trips,
    unique_users,
    avg_distance_km,
    avg_duration_minutes,
    total_fare_revenue,
    -- Popular stations
    most_popular_start_station,
    most_popular_end_station,
    -- Usage intensity
    ROUND(total_trips * 100.0 / SUM(total_trips) OVER (PARTITION BY pattern_week), 2) as mode_share_pct,
    NTILE(4) OVER (PARTITION BY pattern_week ORDER BY total_trips) as usage_quartile
FROM (
    SELECT
        DATE_TRUNC('week', ts.start_time) as pattern_week,
        ts.trip_mode,
        EXTRACT(HOUR FROM ts.start_time) as hour_of_day,
        EXTRACT(DOW FROM ts.start_time) as day_of_week,
        COUNT(*) as total_trips,
        COUNT(DISTINCT ts.user_id) as unique_users,
        AVG(ts.distance_km) as avg_distance_km,
        AVG(ts.duration_minutes) as avg_duration_minutes,
        SUM(COALESCE(ts.fare_paid, 0)) as total_fare_revenue,
        -- Most popular start station
        (SELECT s.station_name
         FROM mobility.trip_segments ts2
         JOIN mobility.stations s ON ts2.start_station_id = s.station_id
         WHERE ts2.trip_mode = ts.trip_mode
           AND DATE_TRUNC('week', ts2.start_time) = DATE_TRUNC('week', ts.start_time)
         GROUP BY s.station_name
         ORDER BY COUNT(*) DESC
         LIMIT 1) as most_popular_start_station,
        -- Most popular end station
        (SELECT s.station_name
         FROM mobility.trip_segments ts2
         JOIN mobility.stations s ON ts2.end_station_id = s.station_id
         WHERE ts2.trip_mode = ts.trip_mode
           AND DATE_TRUNC('week', ts2.start_time) = DATE_TRUNC('week', ts.start_time)
         GROUP BY s.station_name
         ORDER BY COUNT(*) DESC
         LIMIT 1) as most_popular_end_station
    FROM mobility.trip_segments ts
    WHERE ts.start_time >= DATE_TRUNC('week', CURRENT_DATE - INTERVAL '12 weeks')
    GROUP BY DATE_TRUNC('week', ts.start_time), ts.trip_mode,
             EXTRACT(HOUR FROM ts.start_time), EXTRACT(DOW FROM ts.start_time)
) pattern_data
ORDER BY pattern_week DESC, total_trips DESC;

CREATE INDEX ON analytics.mv_mobility_patterns (pattern_week, trip_mode);
CREATE INDEX ON analytics.mv_mobility_patterns (trip_mode, hour_of_day);
COMMENT ON MATERIALIZED VIEW analytics.mv_mobility_patterns IS
'Weekly mobility usage patterns by mode, time, and location. Refresh weekly.';

-- =============================================================================
-- NEIGHBORHOOD DEMOGRAPHICS (Refreshed quarterly)
-- =============================================================================

CREATE MATERIALIZED VIEW analytics.mv_neighborhood_demographics AS
SELECT
    nb.neighborhood_id,
    nb.neighborhood_name,
    nb.population_estimate,
    nb.area_sq_km,
    nb.city_council_district,
    -- Resident metrics
    active_residents,
    avg_resident_age,
    resident_density_per_sq_km,
    -- Service activity
    permits_per_capita,
    complaints_per_capita,
    tax_compliance_rate,
    -- Business activity
    businesses_per_sq_km,
    pois_per_sq_km,
    -- Transportation
    mobility_stations_count,
    trips_per_resident_per_month,
    -- Demographics calculated
    ROUND(active_residents::NUMERIC / nb.area_sq_km, 1) as calculated_density,
    CASE
        WHEN active_residents > 1000 AND businesses_per_sq_km > 5 THEN 'Urban Core'
        WHEN active_residents > 500 THEN 'Residential'
        WHEN businesses_per_sq_km > 2 THEN 'Commercial'
        ELSE 'Mixed Use'
    END as neighborhood_type
FROM geo.neighborhood_boundaries nb
LEFT JOIN (
    -- Aggregate all neighborhood metrics
    SELECT
        n.neighborhood_id,
        COUNT(DISTINCT c.citizen_id) as active_residents,
        ROUND(AVG(EXTRACT(YEAR FROM AGE(c.date_of_birth))), 1) as avg_resident_age,
        ROUND(COUNT(DISTINCT c.citizen_id)::NUMERIC / n.area_sq_km, 1) as resident_density_per_sq_km,
        ROUND(COUNT(DISTINCT pa.permit_id)::NUMERIC / NULLIF(COUNT(DISTINCT c.citizen_id), 0), 3) as permits_per_capita,
        ROUND(COUNT(DISTINCT cr.complaint_id)::NUMERIC / NULLIF(COUNT(DISTINCT c.citizen_id), 0), 3) as complaints_per_capita,
        ROUND(COUNT(DISTINCT tp.tax_id) FILTER (WHERE tp.payment_status = 'paid') * 100.0 /
              NULLIF(COUNT(DISTINCT tp.tax_id), 0), 1) as tax_compliance_rate,
        ROUND(COUNT(DISTINCT poi.poi_id)::NUMERIC / n.area_sq_km, 1) as pois_per_sq_km,
        COUNT(DISTINCT s.station_id) as mobility_stations_count,
        ROUND(COUNT(DISTINCT ts.trip_segment_id)::NUMERIC / NULLIF(COUNT(DISTINCT c.citizen_id), 0) / 12, 2) as trips_per_resident_per_month
    FROM geo.neighborhood_boundaries n
    LEFT JOIN civics.citizens c ON ST_Contains(n.boundary_geom,
        ST_SetSRID(ST_Point(
            CASE WHEN c.street_address LIKE '%Main%' THEN -96.8040 ELSE -96.7950 END,
            CASE WHEN c.zip_code = '75032' THEN 32.9850 ELSE 32.9800 END
        ), 4326)) -- Simplified location mapping
    LEFT JOIN civics.permit_applications pa ON c.citizen_id = pa.citizen_id
        AND pa.application_date >= CURRENT_DATE - INTERVAL '1 year'
    LEFT JOIN documents.complaint_records cr ON c.citizen_id = cr.reporter_citizen_id
        AND cr.submitted_at >= CURRENT_DATE - INTERVAL '1 year'
    LEFT JOIN civics.tax_payments tp ON c.citizen_id = tp.citizen_id
        AND tp.tax_year = EXTRACT(YEAR FROM CURRENT_DATE)
    LEFT JOIN geo.points_of_interest poi ON n.neighborhood_id = poi.neighborhood_id
        AND poi.is_active = true
    LEFT JOIN mobility.stations s ON n.neighborhood_name = s.neighborhood
    LEFT JOIN mobility.trip_segments ts ON c.citizen_id = ts.user_id
        AND ts.start_time >= CURRENT_DATE - INTERVAL '1 year'
    WHERE c.status = 'active' OR c.citizen_id IS NULL
    GROUP BY n.neighborhood_id, n.area_sq_km
) metrics ON nb.neighborhood_id = metrics.neighborhood_id
LEFT JOIN (
    SELECT
        neighborhood_name,
        ROUND(COUNT(*)::NUMERIC / AVG(area_sq_km), 1) as businesses_per_sq_km
    FROM commerce.merchants m
    JOIN geo.neighborhood_boundaries nb ON ST_Contains(nb.boundary_geom,
        ST_SetSRID(ST_Point(
            CASE WHEN m.business_address LIKE '%Innovation%' THEN -96.7850 ELSE -96.8030 END,
            32.9830
        ), 4326)) -- Simplified location mapping
    WHERE m.is_active = true
    GROUP BY neighborhood_name, area_sq_km
) businesses ON nb.neighborhood_name = businesses.neighborhood_name;

CREATE UNIQUE INDEX ON analytics.mv_neighborhood_demographics (neighborhood_id);
COMMENT ON MATERIALIZED VIEW analytics.mv_neighborhood_demographics IS
'Comprehensive neighborhood demographics and activity metrics. Refresh quarterly.';

-- =============================================================================
-- REFRESH MANAGEMENT FUNCTIONS
-- =============================================================================

-- Function to refresh materialized views in dependency order
CREATE OR REPLACE FUNCTION analytics.refresh_materialized_views(view_pattern TEXT DEFAULT '%')
RETURNS TEXT AS $
DECLARE
    view_record RECORD;
    refresh_log TEXT := '';
    start_time TIMESTAMP;
    end_time TIMESTAMP;
BEGIN
    FOR view_record IN
        SELECT schemaname, matviewname
        FROM pg_matviews
        WHERE schemaname = 'analytics'
            AND matviewname LIKE view_pattern
        ORDER BY matviewname
    LOOP
        start_time := clock_timestamp();

        EXECUTE 'REFRESH MATERIALIZED VIEW ' ||
                quote_ident(view_record.schemaname) || '.' ||
                quote_ident(view_record.matviewname);

        end_time := clock_timestamp();

        refresh_log := refresh_log || format(
            'Refreshed %s.%s in %s seconds' || E'\n',
            view_record.schemaname,
            view_record.matviewname,
            EXTRACT(EPOCH FROM (end_time - start_time))::NUMERIC(10,2)
        );
    END LOOP;

    RETURN COALESCE(refresh_log, 'No matching materialized views found');
END;
$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.refresh_materialized_views(TEXT) IS
'Refresh materialized views matching pattern with timing information';

-- Function to get materialized view refresh status
CREATE OR REPLACE FUNCTION analytics.materialized_view_status()
RETURNS TABLE(
    view_name TEXT,
    last_refresh TIMESTAMP,
    size_pretty TEXT,
    row_count BIGINT
) AS $
BEGIN
    RETURN QUERY
    SELECT
        (schemaname || '.' || matviewname)::TEXT as view_name,
        GREATEST(
            pg_stat_get_last_autoanalyze_time(c.oid),
            pg_stat_get_last_analyze_time(c.oid)
        ) as last_refresh,
        pg_size_pretty(pg_total_relation_size(c.oid))::TEXT as size_pretty,
        pg_stat_get_tuples_inserted(c.oid) +
        pg_stat_get_tuples_updated(c.oid) as row_count
    FROM pg_matviews mv
    JOIN pg_class c ON c.relname = mv.matviewname
    WHERE mv.schemaname = 'analytics'
    ORDER BY pg_total_relation_size(c.oid) DESC;
END;
$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.materialized_view_status() IS
'Get status information for all materialized views including size and last refresh';

-- Create refresh schedule recommendations
CREATE VIEW analytics.v_matview_refresh_schedule AS
SELECT
    'mv_daily_city_metrics' as view_name,
    'Daily at 2 AM' as recommended_schedule,
    'High' as priority,
    'Dashboard critical metrics' as purpose
UNION ALL
SELECT
    'mv_monthly_business_performance',
    'Monthly on 1st at 3 AM',
    'Medium',
    'Business reporting and analytics'
UNION ALL
SELECT
    'mv_mobility_patterns',
    'Weekly on Monday at 1 AM',
    'Medium',
    'Transportation planning'
UNION ALL
SELECT
    'mv_neighborhood_demographics',
    'Quarterly on 1st at 4 AM',
    'Low',
    'Long-term planning and analysis';

COMMENT ON VIEW analytics.v_matview_refresh_schedule IS
'Recommended refresh schedule for all materialized views based on data volatility';
