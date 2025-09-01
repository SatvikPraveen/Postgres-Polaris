-- File: sql/03_dml_queries/practice_selects.sql
-- Purpose: SELECT queries, GROUPING SETS, ROLLUP, CUBE examples

-- =============================================================================
-- BASIC SELECT PATTERNS
-- =============================================================================

-- Simple projections with filtering
SELECT first_name, last_name, email, zip_code
FROM civics.citizens
WHERE status = 'active'
ORDER BY last_name, first_name;

-- Date range queries
SELECT complaint_number, subject, category, submitted_at
FROM documents.complaint_records
WHERE submitted_at >= CURRENT_DATE - INTERVAL '30 days'
    AND status != 'resolved'
ORDER BY priority_level, submitted_at DESC;

-- Pattern matching and text searches
SELECT business_name, contact_email, business_type
FROM commerce.merchants
WHERE business_name ILIKE '%tech%'
    OR business_name ILIKE '%software%'
    AND is_active = true;

-- =============================================================================
-- JOINS AND RELATIONSHIPS
-- =============================================================================

-- Inner joins with aggregation
SELECT
    c.first_name || ' ' || c.last_name as citizen_name,
    c.email,
    COUNT(p.permit_id) as total_permits,
    SUM(p.fee_amount) as total_fees
FROM civics.citizens c
INNER JOIN civics.permit_applications p ON c.citizen_id = p.citizen_id
WHERE p.application_date >= '2024-01-01'
GROUP BY c.citizen_id, c.first_name, c.last_name, c.email
HAVING COUNT(p.permit_id) > 1
ORDER BY total_permits DESC;

-- Left joins to find missing relationships
SELECT
    c.first_name || ' ' || c.last_name as citizen_name,
    c.email,
    COALESCE(COUNT(o.order_id), 0) as order_count
FROM civics.citizens c
LEFT JOIN commerce.orders o ON c.citizen_id = o.customer_citizen_id
WHERE c.status = 'active'
GROUP BY c.citizen_id, c.first_name, c.last_name, c.email
ORDER BY order_count DESC;

-- Multi-table joins with geospatial data
SELECT
    poi.name,
    poi.category,
    nb.neighborhood_name,
    poi.average_rating,
    poi.street_address
FROM geo.points_of_interest poi
JOIN geo.neighborhood_boundaries nb ON poi.neighborhood_id = nb.neighborhood_id
WHERE poi.category = 'restaurant'
    AND poi.is_active = true
    AND poi.average_rating >= 4.0
ORDER BY poi.average_rating DESC, poi.name;

-- =============================================================================
-- AGGREGATE FUNCTIONS AND WINDOW FUNCTIONS
-- =============================================================================

-- Revenue analysis with ranking
SELECT
    m.business_name,
    m.business_type,
    COUNT(o.order_id) as total_orders,
    SUM(o.total_amount) as total_revenue,
    AVG(o.total_amount) as avg_order_value,
    RANK() OVER (PARTITION BY m.business_type ORDER BY SUM(o.total_amount) DESC) as revenue_rank
FROM commerce.merchants m
JOIN commerce.orders o ON m.merchant_id = o.merchant_id
WHERE o.order_date >= '2024-01-01'
    AND o.status = 'delivered'
GROUP BY m.merchant_id, m.business_name, m.business_type
ORDER BY total_revenue DESC;

-- Running totals and moving averages
SELECT
    order_date::date,
    COUNT(*) as daily_orders,
    SUM(total_amount) as daily_revenue,
    SUM(COUNT(*)) OVER (ORDER BY order_date::date) as cumulative_orders,
    AVG(SUM(total_amount)) OVER (ORDER BY order_date::date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) as weekly_avg_revenue
FROM commerce.orders
WHERE order_date >= '2024-12-01'
GROUP BY order_date::date
ORDER BY order_date::date;

-- =============================================================================
-- GROUPING SETS, ROLLUP, AND CUBE
-- =============================================================================

-- ROLLUP for hierarchical aggregations (tax collection analysis)
SELECT
    tax_type,
    tax_year,
    payment_status,
    COUNT(*) as payment_count,
    SUM(assessment_amount) as total_assessed,
    SUM(amount_paid) as total_collected
FROM civics.tax_payments
WHERE tax_year >= 2023
GROUP BY ROLLUP(tax_type, tax_year, payment_status)
ORDER BY tax_type NULLS LAST, tax_year NULLS LAST, payment_status NULLS LAST;

-- CUBE for all possible combinations (permit analysis)
SELECT
    permit_type,
    status,
    EXTRACT(YEAR FROM application_date) as application_year,
    COUNT(*) as permit_count,
    AVG(fee_amount) as avg_fee
FROM civics.permit_applications
WHERE application_date >= '2022-01-01'
GROUP BY CUBE(permit_type, status, EXTRACT(YEAR FROM application_date))
ORDER BY permit_type NULLS LAST, status NULLS LAST, application_year NULLS LAST;

-- GROUPING SETS for specific combinations (mobility usage patterns)
SELECT
    trip_mode,
    EXTRACT(HOUR FROM start_time) as trip_hour,
    EXTRACT(DOW FROM start_time) as day_of_week,
    COUNT(*) as trip_count,
    AVG(distance_km) as avg_distance
FROM mobility.trip_segments
WHERE start_time >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY GROUPING SETS (
    (trip_mode),
    (trip_mode, EXTRACT(HOUR FROM start_time)),
    (trip_mode, EXTRACT(DOW FROM start_time)),
    ()
)
ORDER BY trip_mode NULLS LAST, trip_hour NULLS LAST, day_of_week NULLS LAST;

-- =============================================================================
-- ADVANCED AGGREGATION PATTERNS
-- =============================================================================

-- Conditional aggregation (complaint resolution metrics)
SELECT
    category,
    COUNT(*) as total_complaints,
    COUNT(*) FILTER (WHERE status = 'resolved') as resolved_count,
    COUNT(*) FILTER (WHERE status IN ('submitted', 'under_review')) as pending_count,
    COUNT(*) FILTER (WHERE priority_level = 'urgent') as urgent_count,
    ROUND(
        COUNT(*) FILTER (WHERE status = 'resolved') * 100.0 / COUNT(*), 1
    ) as resolution_rate_pct,
    AVG(
        CASE WHEN resolved_at IS NOT NULL
        THEN EXTRACT(EPOCH FROM (resolved_at - submitted_at))/86400
        END
    ) as avg_resolution_days
FROM documents.complaint_records
WHERE submitted_at >= CURRENT_DATE - INTERVAL '1 year'
GROUP BY category
ORDER BY total_complaints DESC;

-- Cohort analysis (citizen registration by month)
SELECT
    DATE_TRUNC('month', registered_date) as registration_month,
    COUNT(*) as new_citizens,
    SUM(COUNT(*)) OVER (ORDER BY DATE_TRUNC('month', registered_date)) as cumulative_citizens,
    ROUND(
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1
    ) as pct_of_total
FROM civics.citizens
WHERE registered_date >= '2024-01-01'
GROUP BY DATE_TRUNC('month', registered_date)
ORDER BY registration_month;

-- =============================================================================
-- STATISTICAL ANALYSIS QUERIES
-- =============================================================================

-- Percentiles and distribution analysis (order values)
SELECT
    m.business_name,
    COUNT(o.order_id) as order_count,
    ROUND(AVG(o.total_amount), 2) as avg_order,
    ROUND(STDDEV(o.total_amount), 2) as stddev_order,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY o.total_amount), 2) as q1_order,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY o.total_amount), 2) as median_order,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY o.total_amount), 2) as q3_order,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY o.total_amount), 2) as p95_order
FROM commerce.merchants m
JOIN commerce.orders o ON m.merchant_id = o.merchant_id
WHERE o.status = 'delivered' AND o.order_date >= '2024-01-01'
GROUP BY m.merchant_id, m.business_name
HAVING COUNT(o.order_id) >= 5
ORDER BY avg_order DESC;

-- Mode and frequency analysis (most common trip patterns)
SELECT
    trip_mode,
    COUNT(*) as frequency,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) as percentage,
    MODE() WITHIN GROUP (ORDER BY duration_minutes) as typical_duration_min,
    AVG(distance_km) as avg_distance_km
FROM mobility.trip_segments
WHERE start_time >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY trip_mode
ORDER BY frequency DESC;

-- =============================================================================
-- TIME SERIES ANALYSIS
-- =============================================================================

-- Daily, weekly, monthly aggregations with trends
SELECT
    DATE_TRUNC('week', order_date) as week_start,
    COUNT(*) as weekly_orders,
    SUM(total_amount) as weekly_revenue,
    COUNT(DISTINCT customer_citizen_id) as unique_customers,
    ROUND(SUM(total_amount) / COUNT(*), 2) as avg_order_value,
    LAG(COUNT(*)) OVER (ORDER BY DATE_TRUNC('week', order_date)) as prev_week_orders,
    CASE
        WHEN LAG(COUNT(*)) OVER (ORDER BY DATE_TRUNC('week', order_date)) IS NOT NULL
        THEN ROUND(
            (COUNT(*) - LAG(COUNT(*)) OVER (ORDER BY DATE_TRUNC('week', order_date))) * 100.0 /
            LAG(COUNT(*)) OVER (ORDER BY DATE_TRUNC('week', order_date)), 1
        )
        ELSE NULL
    END as week_over_week_growth_pct
FROM commerce.orders
WHERE order_date >= CURRENT_DATE - INTERVAL '12 weeks'
    AND status IN ('delivered', 'completed')
GROUP BY DATE_TRUNC('week', order_date)
ORDER BY week_start;

-- Seasonal patterns (complaints by day of week and hour)
SELECT
    EXTRACT(DOW FROM submitted_at) as day_of_week,
    CASE EXTRACT(DOW FROM submitted_at)
        WHEN 0 THEN 'Sunday'
        WHEN 1 THEN 'Monday'
        WHEN 2 THEN 'Tuesday'
        WHEN 3 THEN 'Wednesday'
        WHEN 4 THEN 'Thursday'
        WHEN 5 THEN 'Friday'
        WHEN 6 THEN 'Saturday'
    END as day_name,
    EXTRACT(HOUR FROM submitted_at) as hour_of_day,
    COUNT(*) as complaint_count,
    ROUND(AVG(COUNT(*)) OVER (PARTITION BY EXTRACT(DOW FROM submitted_at)), 1) as avg_for_day
FROM documents.complaint_records
WHERE submitted_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY EXTRACT(DOW FROM submitted_at), EXTRACT(HOUR FROM submitted_at)
ORDER BY day_of_week, hour_of_day;
