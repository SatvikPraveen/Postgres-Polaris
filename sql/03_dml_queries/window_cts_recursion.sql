-- File: sql/03_dml_queries/window_cte_recursion.sql
-- Purpose: Window functions, frames, Common Table Expressions, recursive CTEs

-- =============================================================================
-- WINDOW FUNCTIONS - RANKING AND ORDERING
-- =============================================================================

-- Ranking merchants by revenue within business type
WITH merchant_revenue AS (
    SELECT
        m.merchant_id,
        m.business_name,
        m.business_type,
        COUNT(o.order_id) as total_orders,
        COALESCE(SUM(o.total_amount), 0) as total_revenue
    FROM commerce.merchants m
    LEFT JOIN commerce.orders o ON m.merchant_id = o.merchant_id
        AND o.status IN ('delivered', 'completed')
        AND o.order_date >= '2024-01-01'
    WHERE m.is_active = true
    GROUP BY m.merchant_id, m.business_name, m.business_type
)
SELECT
    business_name,
    business_type,
    total_orders,
    total_revenue,
    RANK() OVER (PARTITION BY business_type ORDER BY total_revenue DESC) as revenue_rank,
    DENSE_RANK() OVER (PARTITION BY business_type ORDER BY total_revenue DESC) as dense_revenue_rank,
    ROW_NUMBER() OVER (PARTITION BY business_type ORDER BY total_revenue DESC, business_name) as row_num,
    PERCENT_RANK() OVER (PARTITION BY business_type ORDER BY total_revenue) as percentile_rank,
    NTILE(4) OVER (PARTITION BY business_type ORDER BY total_revenue) as revenue_quartile
FROM merchant_revenue
ORDER BY business_type, revenue_rank;

-- =============================================================================
-- WINDOW FUNCTIONS - ANALYTICAL FUNCTIONS
-- =============================================================================

-- Citizen registration trends with analytical functions
SELECT
    registration_month,
    monthly_registrations,
    LAG(monthly_registrations, 1) OVER (ORDER BY registration_month) as prev_month,
    LEAD(monthly_registrations, 1) OVER (ORDER BY registration_month) as next_month,
    monthly_registrations - LAG(monthly_registrations, 1) OVER (ORDER BY registration_month) as month_over_month_change,
    FIRST_VALUE(monthly_registrations) OVER (ORDER BY registration_month) as first_month_registrations,
    LAST_VALUE(monthly_registrations) OVER (ORDER BY registration_month ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as last_month_registrations,
    NTH_VALUE(monthly_registrations, 2) OVER (ORDER BY registration_month) as second_month_registrations
FROM (
    SELECT
        DATE_TRUNC('month', registered_date) as registration_month,
        COUNT(*) as monthly_registrations
    FROM civics.citizens
    WHERE registered_date >= '2024-01-01'
    GROUP BY DATE_TRUNC('month', registered_date)
) monthly_stats
ORDER BY registration_month;

-- =============================================================================
-- WINDOW FRAMES - RUNNING CALCULATIONS
-- =============================================================================

-- Daily order metrics with various frame specifications
SELECT
    order_date::date,
    daily_orders,
    daily_revenue,
    -- Default frame: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    SUM(daily_orders) OVER (ORDER BY order_date::date) as cumulative_orders,

    -- Explicit ROWS frame - exactly N rows
    SUM(daily_revenue) OVER (
        ORDER BY order_date::date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) as rolling_7_day_revenue,

    -- RANGE frame - based on date values
    AVG(daily_orders) OVER (
        ORDER BY order_date::date
        RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
    ) as avg_orders_7_days,

    -- Moving average with centered window
    AVG(daily_revenue) OVER (
        ORDER BY order_date::date
        ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING
    ) as centered_7_day_avg,

    -- Percentage of total using full frame
    ROUND(
        daily_revenue * 100.0 / SUM(daily_revenue) OVER (
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ), 2
    ) as pct_of_total_revenue
FROM (
    SELECT
        order_date::date,
        COUNT(*) as daily_orders,
        SUM(total_amount) as daily_revenue
    FROM commerce.orders
    WHERE order_date >= CURRENT_DATE - INTERVAL '30 days'
        AND status IN ('delivered', 'completed')
    GROUP BY order_date::date
) daily_stats
ORDER BY order_date::date;

-- =============================================================================
-- COMMON TABLE EXPRESSIONS (CTEs) - SINGLE LEVEL
-- =============================================================================

-- Complex customer analysis using multiple CTEs
WITH customer_orders AS (
    SELECT
        c.citizen_id,
        c.first_name || ' ' || c.last_name as customer_name,
        c.email,
        c.zip_code,
        COUNT(o.order_id) as total_orders,
        SUM(o.total_amount) as total_spent,
        AVG(o.total_amount) as avg_order_value,
        MIN(o.order_date) as first_order_date,
        MAX(o.order_date) as last_order_date
    FROM civics.citizens c
    JOIN commerce.orders o ON c.citizen_id = o.customer_citizen_id
    WHERE o.status IN ('delivered', 'completed')
    GROUP BY c.citizen_id, c.first_name, c.last_name, c.email, c.zip_code
),
customer_segments AS (
    SELECT
        *,
        CASE
            WHEN total_orders >= 10 AND avg_order_value >= 50 THEN 'VIP'
            WHEN total_orders >= 5 OR avg_order_value >= 75 THEN 'High Value'
            WHEN total_orders >= 2 THEN 'Regular'
            ELSE 'New'
        END as customer_segment,
        CURRENT_DATE - last_order_date::date as days_since_last_order
    FROM customer_orders
),
segment_stats AS (
    SELECT
        customer_segment,
        COUNT(*) as customer_count,
        AVG(total_spent) as avg_total_spent,
        AVG(avg_order_value) as avg_order_value,
        AVG(days_since_last_order) as avg_days_since_last_order
    FROM customer_segments
    GROUP BY customer_segment
)
SELECT
    cs.customer_name,
    cs.email,
    cs.customer_segment,
    cs.total_orders,
    cs.total_spent,
    cs.avg_order_value,
    cs.days_since_last_order,
    ss.avg_total_spent as segment_avg_spent,
    ROUND((cs.total_spent - ss.avg_total_spent) / ss.avg_total_spent * 100, 1) as vs_segment_avg_pct
FROM customer_segments cs
JOIN segment_stats ss ON cs.customer_segment = ss.customer_segment
ORDER BY cs.total_spent DESC;

-- =============================================================================
-- RECURSIVE CTEs - HIERARCHICAL DATA
-- =============================================================================

-- Policy document hierarchy (policies that supersede other policies)
WITH RECURSIVE policy_hierarchy AS (
    -- Base case: root policies (not superseding others)
    SELECT
        policy_id,
        policy_number,
        title,
        version,
        supersedes_policy_id,
        0 as hierarchy_level,
        ARRAY[policy_id] as path,
        policy_number as root_policy
    FROM documents.policy_documents
    WHERE supersedes_policy_id IS NULL
        AND status = 'published'

    UNION ALL

    -- Recursive case: policies that supersede others
    SELECT
        p.policy_id,
        p.policy_number,
        p.title,
        p.version,
        p.supersedes_policy_id,
        ph.hierarchy_level + 1,
        ph.path || p.policy_id,
        ph.root_policy
    FROM documents.policy_documents p
    JOIN policy_hierarchy ph ON p.supersedes_policy_id = ph.policy_id
    WHERE NOT p.policy_id = ANY(ph.path) -- Prevent infinite loops
        AND ph.hierarchy_level < 10 -- Safety limit
)
SELECT
    REPEAT('  ', hierarchy_level) || policy_number as indented_policy_number,
    title,
    version,
    hierarchy_level,
    root_policy,
    array_to_string(path, ' -> ') as policy_path
FROM policy_hierarchy
ORDER BY root_policy, hierarchy_level, policy_number;

-- Recursive date series generation
WITH RECURSIVE date_series AS (
    SELECT CURRENT_DATE - INTERVAL '30 days' as series_date

    UNION ALL

    SELECT series_date + INTERVAL '1 day'
    FROM date_series
    WHERE series_date < CURRENT_DATE
)
SELECT
    ds.series_date,
    EXTRACT(DOW FROM ds.series_date) as day_of_week,
    COALESCE(COUNT(cr.complaint_id), 0) as complaints_count,
    COALESCE(COUNT(o.order_id), 0) as orders_count
FROM date_series ds
LEFT JOIN documents.complaint_records cr ON ds.series_date = cr.submitted_at::date
LEFT JOIN commerce.orders o ON ds.series_date = o.order_date::date
    AND o.status IN ('delivered', 'completed')
GROUP BY ds.series_date
ORDER BY ds.series_date;

-- =============================================================================
-- ADVANCED CTE PATTERNS
-- =============================================================================

-- Multi-level aggregation with CTEs
WITH daily_metrics AS (
    SELECT
        order_date::date as metric_date,
        'orders' as metric_type,
        COUNT(*) as metric_value
    FROM commerce.orders
    WHERE order_date >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY order_date::date

    UNION ALL

    SELECT
        submitted_at::date as metric_date,
        'complaints' as metric_type,
        COUNT(*) as metric_value
    FROM documents.complaint_records
    WHERE submitted_at >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY submitted_at::date

    UNION ALL

    SELECT
        start_time::date as metric_date,
        'trips' as metric_type,
        COUNT(*) as metric_value
    FROM mobility.trip_segments
    WHERE start_time >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY start_time::date
),
weekly_aggregates AS (
    SELECT
        DATE_TRUNC('week', metric_date) as week_start,
        metric_type,
        SUM(metric_value) as weekly_total,
        AVG(metric_value) as daily_avg,
        MIN(metric_value) as daily_min,
        MAX(metric_value) as daily_max
    FROM daily_metrics
    GROUP BY DATE_TRUNC('week', metric_date), metric_type
),
metric_trends AS (
    SELECT
        *,
        LAG(weekly_total) OVER (PARTITION BY metric_type ORDER BY week_start) as prev_week_total,
        ROUND(
            (weekly_total - LAG(weekly_total) OVER (PARTITION BY metric_type ORDER BY week_start)) * 100.0 /
            NULLIF(LAG(weekly_total) OVER (PARTITION BY metric_type ORDER BY week_start), 0), 1
        ) as week_over_week_pct
    FROM weekly_aggregates
)
SELECT
    week_start,
    metric_type,
    weekly_total,
    prev_week_total,
    week_over_week_pct,
    CASE
        WHEN week_over_week_pct > 10 THEN 'Strong Growth'
        WHEN week_over_week_pct > 0 THEN 'Growth'
        WHEN week_over_week_pct > -10 THEN 'Stable'
        ELSE 'Declining'
    END as trend_category
FROM metric_trends
WHERE week_start >= CURRENT_DATE - INTERVAL '8 weeks'
ORDER BY week_start, metric_type;

-- =============================================================================
-- WINDOW FUNCTIONS WITH CTEs
-- =============================================================================

-- Station utilization analysis with window functions
WITH hourly_utilization AS (
    SELECT
        s.station_id,
        s.station_name,
        s.station_type,
        EXTRACT(HOUR FROM si.recorded_at) as hour_of_day,
        AVG(si.in_use_count::numeric / NULLIF(s.total_capacity, 0)) as utilization_rate
    FROM mobility.stations s
    JOIN mobility.station_inventory si ON s.station_id = si.station_id
    WHERE si.recorded_at >= CURRENT_DATE - INTERVAL '7 days'
        AND s.total_capacity > 0
    GROUP BY s.station_id, s.station_name, s.station_type, EXTRACT(HOUR FROM si.recorded_at)
),
station_rankings AS (
    SELECT
        station_name,
        station_type,
        hour_of_day,
        utilization_rate,
        RANK() OVER (PARTITION BY station_type, hour_of_day ORDER BY utilization_rate DESC) as hourly_rank,
        AVG(utilization_rate) OVER (PARTITION BY station_id) as avg_daily_utilization,
        MAX(utilization_rate) OVER (PARTITION BY station_id) as peak_utilization,
        MIN(utilization_rate) OVER (PARTITION BY station_id) as min_utilization
    FROM hourly_utilization
)
SELECT
    station_name,
    station_type,
    ROUND(avg_daily_utilization * 100, 1) as avg_utilization_pct,
    ROUND(peak_utilization * 100, 1) as peak_utilization_pct,
    ROUND(min_utilization * 100, 1) as min_utilization_pct,
    (SELECT hour_of_day FROM station_rankings sr2
     WHERE sr2.station_name = sr.station_name
     ORDER BY sr2.utilization_rate DESC LIMIT 1) as peak_hour
FROM station_rankings sr
WHERE hourly_rank = 1
GROUP BY station_name, station_type, avg_daily_utilization, peak_utilization, min_utilization
ORDER BY avg_daily_utilization DESC;
