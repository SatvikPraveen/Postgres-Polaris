-- File: sql/04_views_matviews/views.sql
-- Purpose: Clean view layer with comments for business logic abstraction
--
-- Idempotent (CREATE OR REPLACE VIEW) and standalone (base data only).
-- Conventions used in this lesson:
--   * Recency windows use meta.as_of() - the dataset's reference "now" - so the
--     views return data for the synthetic city. In a live system you would use
--     now()/CURRENT_DATE in exactly the same places.
--   * Views do not carry ORDER BY: callers sort. (An ORDER BY inside a view is
--     extra work that is silently discarded whenever the caller re-sorts.)
--   * CREATE OR REPLACE VIEW can only ADD columns at the end; renaming or
--     re-typing a column needs DROP VIEW + CREATE VIEW.

\echo '== views =='

CREATE SCHEMA IF NOT EXISTS analytics;

-- =============================================================================
-- CITIZEN-FOCUSED VIEWS
-- =============================================================================

-- Active citizens with complete profile information. Each related table is
-- PRE-AGGREGATED in a derived table before the join, so the joins are 1:1 and
-- counts are not multiplied by each other (the classic fan-out bug).
CREATE OR REPLACE VIEW analytics.v_active_citizens AS
SELECT
    c.citizen_id,
    c.first_name || ' ' || c.last_name AS full_name,
    c.email,
    c.phone,
    c.street_address,
    c.zip_code,
    c.registered_date,
    EXTRACT(YEAR FROM AGE(meta.as_of(), c.date_of_birth))::int AS age,
    -- Aggregate related information
    COALESCE(permits.permit_count, 0)       AS active_permits,
    COALESCE(taxes.tax_balance, 0)          AS outstanding_tax_balance,
    COALESCE(complaints.complaint_count, 0) AS open_complaints
FROM civics.citizens c
LEFT JOIN (
    SELECT citizen_id, COUNT(*) AS permit_count
    FROM civics.permit_applications
    WHERE status IN ('approved', 'pending')
    GROUP BY citizen_id
) permits ON c.citizen_id = permits.citizen_id
LEFT JOIN (
    SELECT citizen_id, SUM(amount_due - amount_paid) AS tax_balance
    FROM civics.tax_payments
    WHERE payment_status <> 'paid'
    GROUP BY citizen_id
) taxes ON c.citizen_id = taxes.citizen_id
LEFT JOIN (
    SELECT reporter_citizen_id, COUNT(*) AS complaint_count
    FROM documents.complaint_records
    WHERE status NOT IN ('resolved', 'archived', 'rejected')
    GROUP BY reporter_citizen_id
) complaints ON c.citizen_id = complaints.reporter_citizen_id
WHERE c.status = 'active';

COMMENT ON VIEW analytics.v_active_citizens IS
'Complete citizen profiles with summary of related city services and obligations';

-- Citizens with service issues (overdue taxes, long-open complaints, stale permits).
-- issue_type reports the FIRST matching issue in priority order.
CREATE OR REPLACE VIEW analytics.v_citizens_with_issues AS
SELECT
    c.citizen_id,
    c.first_name || ' ' || c.last_name AS full_name,
    c.email,
    c.phone,
    CASE
        WHEN overdue_taxes.tax_balance > 0      THEN 'Outstanding Taxes'
        WHEN old_complaints.open_complaints > 0 THEN 'Open Complaints'
        WHEN old_permits.overdue_permits > 0    THEN 'Overdue Permits'
        ELSE 'Other'
    END AS issue_type,
    COALESCE(overdue_taxes.tax_balance, 0)      AS tax_balance_due,
    COALESCE(old_complaints.open_complaints, 0) AS open_complaints,
    COALESCE(old_permits.overdue_permits, 0)    AS overdue_permits
FROM civics.citizens c
LEFT JOIN (
    SELECT citizen_id, SUM(amount_due - amount_paid) AS tax_balance
    FROM civics.tax_payments
    WHERE payment_status = 'overdue'
    GROUP BY citizen_id
) overdue_taxes ON c.citizen_id = overdue_taxes.citizen_id
LEFT JOIN (
    SELECT reporter_citizen_id, COUNT(*) AS open_complaints
    FROM documents.complaint_records
    WHERE status NOT IN ('resolved', 'archived', 'rejected')
        AND submitted_at < meta.as_of() - INTERVAL '30 days'
    GROUP BY reporter_citizen_id
) old_complaints ON c.citizen_id = old_complaints.reporter_citizen_id
LEFT JOIN (
    SELECT citizen_id, COUNT(*) AS overdue_permits
    FROM civics.permit_applications
    WHERE status = 'pending'
        AND application_date < meta.as_of() - INTERVAL '90 days'
    GROUP BY citizen_id
) old_permits ON c.citizen_id = old_permits.citizen_id
WHERE (overdue_taxes.tax_balance > 0 OR old_complaints.open_complaints > 0 OR old_permits.overdue_permits > 0)
    AND c.status = 'active';

COMMENT ON VIEW analytics.v_citizens_with_issues IS
'Citizens requiring follow-up for overdue obligations or lengthy open cases';

-- =============================================================================
-- BUSINESS AND COMMERCE VIEWS
-- =============================================================================

-- Active businesses with current license status. GROUP BY the primary keys
-- is enough: other columns of those tables are functionally dependent.
CREATE OR REPLACE VIEW analytics.v_active_businesses AS
SELECT
    m.merchant_id,
    m.business_name,
    m.business_type,
    m.contact_email,
    m.contact_phone,
    m.business_address,
    m.zip_code,
    -- License information
    COUNT(bl.license_id) AS total_licenses,
    COUNT(bl.license_id) FILTER (WHERE bl.status = 'active') AS active_licenses,
    COUNT(bl.license_id) FILTER (WHERE bl.status = 'active'
                                   AND bl.expiration_date <= meta.as_of()::date + 90) AS expiring_soon,
    -- Business metrics
    m.annual_revenue,
    m.employee_count,
    m.registration_date,
    -- Owner information
    CASE WHEN c.citizen_id IS NOT NULL
         THEN c.first_name || ' ' || c.last_name
         ELSE 'Non-resident' END AS owner_name
FROM commerce.merchants m
LEFT JOIN commerce.business_licenses bl ON m.merchant_id = bl.merchant_id
LEFT JOIN civics.citizens c ON m.owner_citizen_id = c.citizen_id
WHERE m.is_active = true
GROUP BY m.merchant_id, c.citizen_id;

COMMENT ON VIEW analytics.v_active_businesses IS
'Active businesses with license status and owner information for compliance monitoring';

-- Monthly business performance metrics. The join to orders is an INNER join:
-- with a LEFT join, merchants without orders would produce a bogus month = NULL row.
CREATE OR REPLACE VIEW analytics.v_monthly_business_metrics AS
SELECT
    m.merchant_id,
    m.business_name,
    m.business_type,
    DATE_TRUNC('month', o.order_date)      AS metrics_month,
    COUNT(o.order_id)                      AS monthly_orders,
    COUNT(DISTINCT o.customer_citizen_id)  AS unique_customers,
    SUM(o.total_amount)                    AS monthly_revenue,
    ROUND(AVG(o.total_amount), 2)          AS avg_order_value,
    -- Growth metrics (window functions evaluated after GROUP BY)
    LAG(COUNT(o.order_id))   OVER w        AS prev_month_orders,
    LAG(SUM(o.total_amount)) OVER w        AS prev_month_revenue
FROM commerce.merchants m
JOIN commerce.orders o ON m.merchant_id = o.merchant_id
    AND o.status IN ('shipped', 'delivered')          -- order_status has no 'completed'
    AND o.order_date >= meta.as_of() - INTERVAL '24 months'
WHERE m.is_active = true
GROUP BY m.merchant_id, DATE_TRUNC('month', o.order_date)
WINDOW w AS (PARTITION BY m.merchant_id ORDER BY DATE_TRUNC('month', o.order_date));

COMMENT ON VIEW analytics.v_monthly_business_metrics IS
'Monthly performance tracking for businesses with growth trend analysis';

-- =============================================================================
-- MOBILITY AND TRANSPORTATION VIEWS
-- =============================================================================

-- Station status dashboard: latest inventory per station via DISTINCT ON
-- (served by idx_inventory_station_time on (station_id, recorded_at)).
CREATE OR REPLACE VIEW analytics.v_station_dashboard AS
SELECT
    s.station_id,
    s.station_code,
    s.station_name,
    s.station_type,
    s.neighborhood,
    s.total_capacity,
    s.status AS station_status,
    -- Current inventory (latest reading)
    COALESCE(latest.available_count, 0)   AS current_available,
    COALESCE(latest.in_use_count, 0)      AS current_in_use,
    COALESCE(latest.maintenance_count, 0) AS current_maintenance,
    -- Utilization metrics
    CASE WHEN s.total_capacity > 0
         THEN ROUND(COALESCE(latest.in_use_count, 0) * 100.0 / s.total_capacity, 1)
         ELSE 0 END AS current_utilization_pct,
    latest.recorded_at AS last_updated,
    -- Maintenance indicators
    s.next_maintenance_due,
    CASE WHEN s.next_maintenance_due <= meta.as_of()::date + 7
         THEN 'Due Soon'
         ELSE 'Current' END AS maintenance_status
FROM mobility.stations s
LEFT JOIN (
    SELECT DISTINCT ON (station_id)
        station_id, available_count, in_use_count, maintenance_count, recorded_at
    FROM mobility.station_inventory
    ORDER BY station_id, recorded_at DESC
) latest ON s.station_id = latest.station_id;

COMMENT ON VIEW analytics.v_station_dashboard IS
'Real-time station status with current inventory and maintenance tracking';

-- Trip patterns summary (last 30 days)
CREATE OR REPLACE VIEW analytics.v_trip_patterns AS
SELECT
    trip_mode,
    COUNT(*)                                                    AS total_trips,
    COUNT(DISTINCT user_id)                                     AS unique_users,
    ROUND(AVG(distance_km), 2)                                  AS avg_distance_km,
    ROUND(AVG(duration_minutes), 1)                             AS avg_duration_min,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY distance_km)    AS median_distance_km,
    SUM(fare_paid)                                              AS total_fare_revenue,
    -- Time patterns
    MODE() WITHIN GROUP (ORDER BY EXTRACT(HOUR FROM start_time))   AS peak_hour,
    MODE() WITHIN GROUP (ORDER BY EXTRACT(ISODOW FROM start_time)) AS peak_iso_day_of_week,
    -- Most popular station-to-station route in the same window
    (SELECT s1.station_name || ' -> ' || s2.station_name
     FROM mobility.trip_segments ts2
     JOIN mobility.stations s1 ON ts2.start_station_id = s1.station_id
     JOIN mobility.stations s2 ON ts2.end_station_id = s2.station_id
     WHERE ts2.trip_mode = ts.trip_mode
       AND ts2.start_time >= meta.as_of() - INTERVAL '30 days'
     GROUP BY s1.station_name, s2.station_name
     ORDER BY COUNT(*) DESC, s1.station_name, s2.station_name
     LIMIT 1) AS most_popular_route
FROM mobility.trip_segments ts
WHERE start_time >= meta.as_of() - INTERVAL '30 days'
GROUP BY trip_mode;

COMMENT ON VIEW analytics.v_trip_patterns IS
'Aggregate trip patterns by mode (last 30 days) with usage statistics and popular routes';

-- =============================================================================
-- CIVIC ENGAGEMENT VIEWS
-- =============================================================================

-- Permit processing performance (last year). Undecided permits are aged up
-- to the dataset "now".
CREATE OR REPLACE VIEW analytics.v_permit_processing AS
SELECT
    permit_type,
    status,
    COUNT(*) AS permit_count,
    ROUND(AVG(EXTRACT(EPOCH FROM (COALESCE(approval_date, meta.as_of()) - application_date)) / 86400), 1) AS avg_processing_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (COALESCE(approval_date, meta.as_of()) - application_date)) / 86400) AS median_processing_days,
    COUNT(*) FILTER (WHERE application_date >= meta.as_of() - INTERVAL '30 days') AS recent_applications,
    SUM(fee_amount) AS total_fees_assessed,
    SUM(fee_paid)   AS total_fees_collected,
    ROUND(SUM(fee_paid) * 100.0 / NULLIF(SUM(fee_amount), 0), 1) AS collection_rate_pct
FROM civics.permit_applications
WHERE application_date >= meta.as_of() - INTERVAL '1 year'
GROUP BY permit_type, status;

COMMENT ON VIEW analytics.v_permit_processing IS
'Permit processing metrics including timing, volume, and fee collection rates';

-- Complaint resolution tracking (last year)
CREATE OR REPLACE VIEW analytics.v_complaint_resolution AS
SELECT
    category,
    priority_level,
    COUNT(*) AS total_complaints,
    COUNT(*) FILTER (WHERE status = 'resolved') AS resolved_count,
    COUNT(*) FILTER (WHERE status IN ('submitted', 'under_review')) AS pending_count,
    ROUND(COUNT(*) FILTER (WHERE status = 'resolved') * 100.0 / COUNT(*), 1) AS resolution_rate_pct,
    ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - submitted_at)) / 86400)
          FILTER (WHERE resolved_at IS NOT NULL), 1) AS avg_resolution_days,
    COUNT(*) FILTER (WHERE submitted_at >= meta.as_of() - INTERVAL '30 days') AS recent_complaints,
    -- Geographic distribution
    (SELECT nb.neighborhood_name
     FROM documents.complaint_records cr2
     JOIN geo.neighborhood_boundaries nb ON cr2.neighborhood_id = nb.neighborhood_id
     WHERE cr2.category = cr.category
       AND cr2.submitted_at >= meta.as_of() - INTERVAL '1 year'
     GROUP BY nb.neighborhood_name
     ORDER BY COUNT(*) DESC, nb.neighborhood_name
     LIMIT 1) AS most_common_neighborhood
FROM documents.complaint_records cr
WHERE submitted_at >= meta.as_of() - INTERVAL '1 year'
GROUP BY category, priority_level;

COMMENT ON VIEW analytics.v_complaint_resolution IS
'Complaint resolution metrics by category and priority with geographic insights';

-- =============================================================================
-- GEOGRAPHIC AND NEIGHBORHOOD VIEWS
-- =============================================================================

-- Neighbourhood activity summary. Linking rules in this dataset:
--   * citizens / merchants: zip_code '751NN' encodes neighbourhood NN
--   * complaints, POIs: carry neighborhood_id directly
--   * stations: the neighborhood text column equals neighborhood_name
--   * trips: point-in-polygon of the start coordinates (ST_Contains uses the
--     GiST index on boundary_geom)
CREATE OR REPLACE VIEW analytics.v_neighborhood_activity AS
SELECT
    nb.neighborhood_id,
    nb.neighborhood_name,
    nb.population_estimate,
    nb.city_council_district,
    -- Resident activity
    COALESCE(residents.resident_count, 0)   AS active_residents,
    COALESCE(complaints.complaint_count, 0) AS recent_complaints,
    COALESCE(permits.permit_count, 0)       AS recent_permits,
    -- Business activity
    COALESCE(businesses.business_count, 0)  AS active_businesses,
    COALESCE(pois.poi_count, 0)             AS points_of_interest,
    -- Transportation
    COALESCE(stations.station_count, 0)     AS mobility_stations,
    COALESCE(trips.trip_count, 0)           AS recent_trips
FROM geo.neighborhood_boundaries nb
LEFT JOIN (
    SELECT substr(zip_code, 4, 2)::int AS neighborhood_id, COUNT(*) AS resident_count
    FROM civics.citizens
    WHERE status = 'active' AND zip_code LIKE '751__'
    GROUP BY 1
) residents ON nb.neighborhood_id = residents.neighborhood_id
LEFT JOIN (
    SELECT neighborhood_id, COUNT(*) AS complaint_count
    FROM documents.complaint_records
    WHERE submitted_at >= meta.as_of() - INTERVAL '90 days'
    GROUP BY neighborhood_id
) complaints ON nb.neighborhood_id = complaints.neighborhood_id
LEFT JOIN (
    SELECT substr(c.zip_code, 4, 2)::int AS neighborhood_id, COUNT(*) AS permit_count
    FROM civics.permit_applications p
    JOIN civics.citizens c ON c.citizen_id = p.citizen_id
    WHERE p.application_date >= meta.as_of() - INTERVAL '90 days'
      AND c.zip_code LIKE '751__'
    GROUP BY 1
) permits ON nb.neighborhood_id = permits.neighborhood_id
LEFT JOIN (
    SELECT substr(zip_code, 4, 2)::int AS neighborhood_id, COUNT(*) AS business_count
    FROM commerce.merchants
    WHERE is_active = true AND zip_code LIKE '751__'
    GROUP BY 1
) businesses ON nb.neighborhood_id = businesses.neighborhood_id
LEFT JOIN (
    SELECT neighborhood_id, COUNT(*) AS poi_count
    FROM geo.points_of_interest
    WHERE is_active = true
    GROUP BY neighborhood_id
) pois ON nb.neighborhood_id = pois.neighborhood_id
LEFT JOIN (
    SELECT neighborhood, COUNT(*) AS station_count
    FROM mobility.stations
    GROUP BY neighborhood
) stations ON nb.neighborhood_name = stations.neighborhood
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS trip_count
    FROM mobility.trip_segments t
    WHERE t.start_time >= meta.as_of() - INTERVAL '30 days'
      AND ST_Contains(nb.boundary_geom,
                      ST_SetSRID(ST_MakePoint(t.start_longitude, t.start_latitude), 4326))
) trips ON true;

COMMENT ON VIEW analytics.v_neighborhood_activity IS
'Comprehensive neighborhood activity metrics across all city services and systems';

-- =============================================================================
-- UPDATABLE VIEWS, CHECK OPTION AND SECURITY
-- A simple single-table view (no aggregates/DISTINCT/GROUP BY/joins) is
-- automatically updatable. WITH CHECK OPTION rejects writes that would make
-- the row disappear from the view. security_invoker (PG 15+) makes the view
-- check permissions/RLS as the CALLER instead of the view owner;
-- security_barrier stops leaky user functions being pushed below the view's
-- WHERE clause.
-- =============================================================================

CREATE OR REPLACE VIEW analytics.v_pending_permits
WITH (security_invoker = true, security_barrier = true) AS
SELECT permit_id, citizen_id, permit_type, permit_number, status, application_date, fee_amount, fee_paid
FROM civics.permit_applications
WHERE status = 'pending'
WITH CASCADED CHECK OPTION;

COMMENT ON VIEW analytics.v_pending_permits IS
'Updatable view of pending permits (security_invoker, CHECK OPTION)';

\echo '-- Updatable view demo (rolled back): an allowed update, then one the CHECK OPTION rejects'
BEGIN;
UPDATE analytics.v_pending_permits
SET fee_paid = fee_amount
WHERE permit_id = (SELECT min(permit_id) FROM analytics.v_pending_permits)
RETURNING permit_id, status, fee_amount, fee_paid;

DO $$
BEGIN
    UPDATE analytics.v_pending_permits
    SET status = 'approved'           -- row would leave the view
    WHERE permit_id = (SELECT min(permit_id) FROM analytics.v_pending_permits);
EXCEPTION WHEN with_check_option_violation THEN   -- SQLSTATE 44000
    RAISE NOTICE 'CHECK OPTION blocked the update: %', SQLERRM;
END
$$;
ROLLBACK;

-- =============================================================================
-- USING THE VIEWS (sorting happens here, in the caller)
-- =============================================================================

\echo '-- Citizens with the largest outstanding tax balances'
SELECT citizen_id, full_name, age, active_permits, outstanding_tax_balance, open_complaints
FROM analytics.v_active_citizens
ORDER BY outstanding_tax_balance DESC, citizen_id
LIMIT 5;

\echo '-- Follow-up queue by issue type'
SELECT issue_type, COUNT(*) AS citizens, SUM(tax_balance_due) AS total_tax_due
FROM analytics.v_citizens_with_issues
GROUP BY issue_type
ORDER BY citizens DESC;

\echo '-- Businesses with licences expiring within 90 days'
SELECT merchant_id, business_name, active_licenses, expiring_soon, owner_name
FROM analytics.v_active_businesses
WHERE expiring_soon > 0
ORDER BY merchant_id
LIMIT 5;

\echo '-- Month-over-month revenue for the top merchant'
SELECT metrics_month::date, monthly_orders, monthly_revenue, prev_month_revenue
FROM analytics.v_monthly_business_metrics
WHERE merchant_id = 1
ORDER BY metrics_month DESC
LIMIT 6;

\echo '-- Most utilised stations right now'
SELECT station_code, station_name, station_type, current_utilization_pct, last_updated, maintenance_status
FROM analytics.v_station_dashboard
ORDER BY current_utilization_pct DESC, station_id
LIMIT 5;

\echo '-- Trip patterns by mode'
SELECT trip_mode, total_trips, unique_users, avg_distance_km, peak_hour, most_popular_route
FROM analytics.v_trip_patterns
ORDER BY total_trips DESC, trip_mode;

\echo '-- Permit processing (building permits)'
SELECT permit_type, status, permit_count, avg_processing_days, collection_rate_pct
FROM analytics.v_permit_processing
WHERE permit_type = 'building'
ORDER BY status;

\echo '-- Complaint resolution for urgent complaints'
SELECT category, total_complaints, resolution_rate_pct, avg_resolution_days, most_common_neighborhood
FROM analytics.v_complaint_resolution
WHERE priority_level = 'urgent'
ORDER BY total_complaints DESC, category;

\echo '-- Neighbourhood activity (busiest 8 by recent trips)'
SELECT neighborhood_name, active_residents, recent_complaints, recent_permits,
       active_businesses, points_of_interest, mobility_stations, recent_trips
FROM analytics.v_neighborhood_activity
ORDER BY recent_trips DESC, neighborhood_id
LIMIT 8;

\echo '-- View options stored in pg_class.reloptions'
SELECT c.relname AS view_name, c.reloptions
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'analytics' AND c.relkind = 'v' AND c.relname LIKE 'v\_%'
  AND c.reloptions IS NOT NULL
ORDER BY 1;
