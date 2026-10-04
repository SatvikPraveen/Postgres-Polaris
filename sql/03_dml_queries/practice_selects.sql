-- File: sql/03_dml_queries/practice_selects.sql
-- Purpose: SELECT queries, joins, aggregates, FILTER, GROUPING SETS, ROLLUP, CUBE
--
-- Read-only lesson: runs against the base dataset, creates nothing.
-- "Now" for the synthetic data is meta.as_of() (2025-12-31 23:59:59 UTC); all
-- relative windows below use it instead of CURRENT_DATE / now(), otherwise
-- they would return nothing once the wall clock moves past the dataset.

\echo '== practice_selects =='

-- =============================================================================
-- BASIC SELECT PATTERNS
-- =============================================================================

\echo '-- Simple projection + filter + deterministic ORDER BY (tie-break on the key)'
SELECT first_name, last_name, email, zip_code
FROM civics.citizens
WHERE status = 'active'
ORDER BY last_name, first_name, citizen_id
LIMIT 10;

\echo '-- Date range relative to the dataset "now": open complaints from the last 30 days'
SELECT complaint_number, subject, category, priority_level, submitted_at
FROM documents.complaint_records
WHERE submitted_at >= meta.as_of() - INTERVAL '30 days'
    AND status NOT IN ('resolved', 'archived', 'rejected')
ORDER BY priority_level DESC, submitted_at DESC     -- enums sort by declaration order: low < normal < high < urgent
LIMIT 10;

\echo '-- Pattern matching: AND binds tighter than OR, so parenthesise the OR group'
-- Without the parentheses, "A OR B AND is_active" means "A OR (B AND is_active)"
-- and inactive merchants matching A would leak into the result.
SELECT business_name, contact_email, business_type
FROM commerce.merchants
WHERE (business_name ILIKE '%tech%' OR business_name ILIKE '%systems%')
    AND is_active = true
ORDER BY business_name
LIMIT 10;

-- =============================================================================
-- JOINS AND RELATIONSHIPS
-- =============================================================================

\echo '-- Inner join + GROUP BY + HAVING: citizens with more than one permit since 2024'
SELECT
    c.first_name || ' ' || c.last_name AS citizen_name,
    c.email,
    COUNT(p.permit_id) AS total_permits,
    SUM(p.fee_amount)  AS total_fees
FROM civics.citizens c
INNER JOIN civics.permit_applications p ON c.citizen_id = p.citizen_id
WHERE p.application_date >= '2024-01-01'
GROUP BY c.citizen_id          -- PK in GROUP BY => other citizen columns are functionally dependent
HAVING COUNT(p.permit_id) > 1
ORDER BY total_permits DESC, c.citizen_id
LIMIT 10;

\echo '-- Left join: COUNT(o.order_id) counts only matched rows (it is never NULL, no COALESCE needed)'
SELECT
    c.first_name || ' ' || c.last_name AS citizen_name,
    c.email,
    COUNT(o.order_id) AS order_count
FROM civics.citizens c
LEFT JOIN commerce.orders o ON c.citizen_id = o.customer_citizen_id
WHERE c.status = 'active'
GROUP BY c.citizen_id
ORDER BY order_count DESC, c.citizen_id
LIMIT 10;

\echo '-- Anti-join: active citizens who never placed an order (NOT EXISTS is NULL-safe, unlike NOT IN)'
SELECT COUNT(*) AS active_citizens_without_orders
FROM civics.citizens c
WHERE c.status = 'active'
  AND NOT EXISTS (SELECT 1 FROM commerce.orders o WHERE o.customer_citizen_id = c.citizen_id);

\echo '-- Multi-table join with geospatial reference data'
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
ORDER BY poi.average_rating DESC, poi.name, poi.poi_id
LIMIT 10;

-- =============================================================================
-- AGGREGATE FUNCTIONS AND WINDOW FUNCTIONS OVER AGGREGATES
-- =============================================================================

\echo '-- Revenue per merchant, ranked within business_type (window over an aggregate)'
SELECT
    m.business_name,
    m.business_type,
    COUNT(o.order_id)              AS total_orders,
    SUM(o.total_amount)            AS total_revenue,
    ROUND(AVG(o.total_amount), 2)  AS avg_order_value,
    RANK() OVER (PARTITION BY m.business_type ORDER BY SUM(o.total_amount) DESC) AS revenue_rank
FROM commerce.merchants m
JOIN commerce.orders o ON m.merchant_id = o.merchant_id
WHERE o.order_date >= '2025-01-01'
    AND o.status = 'delivered'
GROUP BY m.merchant_id
ORDER BY total_revenue DESC, m.merchant_id
LIMIT 10;

\echo '-- Running totals and a 7-day moving average (December 2025)'
SELECT
    order_date::date                                       AS day,
    COUNT(*)                                               AS daily_orders,
    SUM(total_amount)                                      AS daily_revenue,
    SUM(COUNT(*)) OVER w                                   AS cumulative_orders,
    ROUND(AVG(SUM(total_amount)) OVER (w ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS moving_avg_7d_revenue
FROM commerce.orders
WHERE order_date >= '2025-12-01'
GROUP BY order_date::date
WINDOW w AS (ORDER BY order_date::date)
ORDER BY day
LIMIT 10;

-- =============================================================================
-- GROUPING SETS, ROLLUP, AND CUBE
-- GROUPING(col) returns 1 when the column is rolled up in that row, which
-- distinguishes a subtotal NULL from a genuine NULL value in the data.
-- =============================================================================

\echo '-- ROLLUP: tax_type > tax_year > payment_status with subtotals and a grand total'
SELECT
    CASE WHEN GROUPING(tax_type) = 1 THEN '(all types)' ELSE tax_type::text END        AS tax_type,
    CASE WHEN GROUPING(tax_year) = 1 THEN '(all years)' ELSE tax_year::text END        AS tax_year,
    CASE WHEN GROUPING(payment_status) = 1 THEN '(all)' ELSE payment_status::text END  AS payment_status,
    COUNT(*)               AS payment_count,
    SUM(assessment_amount) AS total_assessed,
    SUM(amount_paid)       AS total_collected
FROM civics.tax_payments
WHERE tax_year >= 2024 AND tax_type IN ('property', 'vehicle')
GROUP BY ROLLUP (tax_type, tax_year, payment_status)
ORDER BY GROUPING(tax_type), tax_type, GROUPING(tax_year), tax_year,
         GROUPING(payment_status), payment_status;

\echo '-- CUBE: every combination of permit_type x status x year (showing the 2-D subtotals only)'
SELECT
    permit_type,
    status,
    EXTRACT(YEAR FROM application_date) AS application_year,
    COUNT(*)                   AS permit_count,
    ROUND(AVG(fee_amount), 2)  AS avg_fee,
    GROUPING(permit_type, status, EXTRACT(YEAR FROM application_date)) AS grouping_mask
FROM civics.permit_applications
WHERE application_date >= '2023-01-01'
GROUP BY CUBE (permit_type, status, EXTRACT(YEAR FROM application_date))
-- mask bit set = column rolled up; 4 = permit_type rolled up (status x year)
HAVING GROUPING(permit_type, status, EXTRACT(YEAR FROM application_date)) IN (4, 7)
ORDER BY grouping_mask, status NULLS LAST, application_year NULLS LAST;

\echo '-- GROUPING SETS: chosen combinations only (trip mode, mode x hour-band, overall), last 30 days'
SELECT
    trip_mode,
    CASE WHEN EXTRACT(HOUR FROM start_time) BETWEEN 7 AND 8          -- 07:00-08:59
           OR EXTRACT(HOUR FROM start_time) BETWEEN 16 AND 18        -- 16:00-18:59
         THEN 'peak' ELSE 'off-peak' END AS hour_band,
    COUNT(*)                     AS trip_count,
    ROUND(AVG(distance_km), 2)   AS avg_distance_km
FROM mobility.trip_segments
WHERE start_time >= meta.as_of() - INTERVAL '30 days'
  AND trip_mode IN ('bus', 'rail', 'cycling')
GROUP BY GROUPING SETS (
    (trip_mode),
    (trip_mode, 2),       -- positional reference to the hour_band expression
    ()
)
ORDER BY trip_mode NULLS LAST, hour_band NULLS FIRST;

-- =============================================================================
-- ADVANCED AGGREGATION PATTERNS
-- =============================================================================

\echo '-- Conditional aggregation with FILTER (complaint resolution metrics, last year)'
SELECT
    category,
    COUNT(*)                                                       AS total_complaints,
    COUNT(*) FILTER (WHERE status = 'resolved')                    AS resolved_count,
    COUNT(*) FILTER (WHERE status IN ('submitted', 'under_review')) AS pending_count,
    COUNT(*) FILTER (WHERE priority_level = 'urgent')              AS urgent_count,
    ROUND(COUNT(*) FILTER (WHERE status = 'resolved') * 100.0 / COUNT(*), 1) AS resolution_rate_pct,
    ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - submitted_at)) / 86400)
          FILTER (WHERE resolved_at IS NOT NULL), 1)               AS avg_resolution_days
FROM documents.complaint_records
WHERE submitted_at >= meta.as_of() - INTERVAL '1 year'
GROUP BY category
ORDER BY total_complaints DESC, category;

\echo '-- Cohort counts: citizen registrations per month with running total and share'
SELECT
    DATE_TRUNC('month', registered_date)                                    AS registration_month,
    COUNT(*)                                                                AS new_citizens,
    SUM(COUNT(*)) OVER (ORDER BY DATE_TRUNC('month', registered_date))      AS cumulative_citizens,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)                      AS pct_of_total
FROM civics.citizens
WHERE registered_date >= '2025-01-01'
GROUP BY DATE_TRUNC('month', registered_date)
ORDER BY registration_month;

-- =============================================================================
-- STATISTICAL ANALYSIS QUERIES
-- =============================================================================

\echo '-- Percentiles: percentile_cont returns double precision; cast to numeric before ROUND(x, n)'
SELECT
    m.business_name,
    COUNT(o.order_id)                                                                    AS order_count,
    ROUND(AVG(o.total_amount), 2)                                                        AS avg_order,
    ROUND(STDDEV(o.total_amount), 2)                                                     AS stddev_order,
    ROUND((PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY o.total_amount))::numeric, 2)    AS q1_order,
    ROUND((PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY o.total_amount))::numeric, 2)    AS median_order,
    ROUND((PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY o.total_amount))::numeric, 2)    AS q3_order,
    ROUND((PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY o.total_amount))::numeric, 2)    AS p95_order
FROM commerce.merchants m
JOIN commerce.orders o ON m.merchant_id = o.merchant_id
WHERE o.status = 'delivered' AND o.order_date >= '2025-01-01'
GROUP BY m.merchant_id
HAVING COUNT(o.order_id) >= 5
ORDER BY avg_order DESC, m.merchant_id
LIMIT 10;

\echo '-- MODE() and share of total (most common trip modes, last 30 days)'
SELECT
    trip_mode,
    COUNT(*)                                            AS frequency,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)  AS percentage,
    MODE() WITHIN GROUP (ORDER BY duration_minutes)     AS typical_duration_min,
    ROUND(AVG(distance_km), 2)                          AS avg_distance_km
FROM mobility.trip_segments
WHERE start_time >= meta.as_of() - INTERVAL '30 days'
GROUP BY trip_mode
ORDER BY frequency DESC, trip_mode;

\echo '-- Verifiable: weekday peak vs off-peak transit delay (planted ratio is 3.0)'
SELECT
    ROUND(AVG(delay_minutes) FILTER (WHERE is_peak), 2)      AS peak_avg_delay,
    ROUND(AVG(delay_minutes) FILTER (WHERE NOT is_peak), 2)  AS offpeak_avg_delay,
    ROUND(AVG(delay_minutes) FILTER (WHERE is_peak)
          / NULLIF(AVG(delay_minutes) FILTER (WHERE NOT is_peak), 0), 2) AS observed_ratio,
    (SELECT true_value FROM meta.planted_effects WHERE effect = 'peak_hour_bus_delay_ratio') AS planted_ratio
FROM (
    SELECT delay_minutes,
           EXTRACT(ISODOW FROM start_time) <= 5
           AND (EXTRACT(HOUR FROM start_time) BETWEEN 7 AND 8
                OR EXTRACT(HOUR FROM start_time) BETWEEN 16 AND 18) AS is_peak
    FROM mobility.trip_segments
    WHERE trip_mode IN ('bus', 'rail') AND delay_minutes IS NOT NULL
) t;

-- =============================================================================
-- TIME SERIES ANALYSIS
-- =============================================================================

\echo '-- Weekly trend with week-over-week growth (named WINDOW avoids repeating LAG)'
SELECT
    DATE_TRUNC('week', order_date)                    AS week_start,
    COUNT(*)                                          AS weekly_orders,
    SUM(total_amount)                                 AS weekly_revenue,
    COUNT(DISTINCT customer_citizen_id)               AS unique_customers,
    ROUND(SUM(total_amount) / COUNT(*), 2)            AS avg_order_value,
    LAG(COUNT(*)) OVER w                              AS prev_week_orders,
    ROUND((COUNT(*) - LAG(COUNT(*)) OVER w) * 100.0
          / NULLIF(LAG(COUNT(*)) OVER w, 0), 1)       AS week_over_week_growth_pct
FROM commerce.orders
WHERE order_date >= DATE_TRUNC('week', meta.as_of()) - INTERVAL '12 weeks'
    AND status IN ('shipped', 'delivered')            -- order_status has no 'completed' value
GROUP BY DATE_TRUNC('week', order_date)
WINDOW w AS (ORDER BY DATE_TRUNC('week', order_date))
ORDER BY week_start;

\echo '-- Seasonality: complaints by day of week and hour (last 90 days, busiest 15 slots)'
SELECT
    EXTRACT(ISODOW FROM submitted_at)      AS iso_day_of_week,   -- 1 = Monday .. 7 = Sunday
    TO_CHAR(submitted_at, 'FMDay')         AS day_name,
    EXTRACT(HOUR FROM submitted_at)        AS hour_of_day,
    COUNT(*)                               AS complaint_count,
    ROUND(AVG(COUNT(*)) OVER (PARTITION BY EXTRACT(ISODOW FROM submitted_at)), 1) AS avg_per_hour_for_day
FROM documents.complaint_records
WHERE submitted_at >= meta.as_of() - INTERVAL '90 days'
GROUP BY 1, 2, 3
ORDER BY complaint_count DESC, iso_day_of_week, hour_of_day
LIMIT 15;
