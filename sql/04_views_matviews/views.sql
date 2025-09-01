-- File: sql/04_views_matviews/views.sql
-- Purpose: Clean view layer with comments for business logic abstraction

-- =============================================================================
-- CITIZEN-FOCUSED VIEWS
-- =============================================================================

-- Active citizens with complete profile information
CREATE VIEW analytics.v_active_citizens AS
SELECT
    c.citizen_id,
    c.first_name || ' ' || c.last_name as full_name,
    c.email,
    c.phone,
    c.street_address,
    c.zip_code,
    c.registered_date,
    EXTRACT(YEAR FROM AGE(c.date_of_birth)) as age,
    -- Aggregate related information
    COALESCE(permit_count, 0) as active_permits,
    COALESCE(tax_balance, 0) as outstanding_tax_balance,
    COALESCE(complaint_count, 0) as open_complaints
FROM civics.citizens c
LEFT JOIN (
    SELECT citizen_id, COUNT(*) as permit_count
    FROM civics.permit_applications
    WHERE status IN ('approved', 'pending')
    GROUP BY citizen_id
) permits ON c.citizen_id = permits.citizen_id
LEFT JOIN (
    SELECT citizen_id, SUM(amount_due - amount_paid) as tax_balance
    FROM civics.tax_payments
    WHERE payment_status != 'paid'
    GROUP BY citizen_id
) taxes ON c.citizen_id = taxes.citizen_id
LEFT JOIN (
    SELECT reporter_citizen_id, COUNT(*) as complaint_count
    FROM documents.complaint_records
    WHERE status NOT IN ('resolved', 'archived')
    GROUP BY reporter_citizen_id
) complaints ON c.citizen_id = complaints.reporter_citizen_id
WHERE c.status = 'active';

COMMENT ON VIEW analytics.v_active_citizens IS
'Complete citizen profiles with summary of related city services and obligations';

-- Citizens with service issues (overdue taxes, open complaints, etc.)
CREATE VIEW analytics.v_citizens_with_issues AS
SELECT
    c.citizen_id,
    c.first_name || ' ' || c.last_name as full_name,
    c.email,
    c.phone,
    CASE
        WHEN tax_balance > 0 THEN 'Outstanding Taxes'
        WHEN open_complaints > 0 THEN 'Open Complaints'
        WHEN overdue_permits > 0 THEN 'Overdue Permits'
        ELSE 'Other'
    END as issue_type,
    COALESCE(tax_balance, 0) as tax_balance_due,
    COALESCE(open_complaints, 0) as open_complaints,
    COALESCE(overdue_permits, 0) as overdue_permits
FROM civics.citizens c
LEFT JOIN (
    SELECT citizen_id, SUM(amount_due - amount_paid) as tax_balance
    FROM civics.tax_payments
    WHERE payment_status = 'overdue'
    GROUP BY citizen_id
) overdue_taxes ON c.citizen_id = overdue_taxes.citizen_id
LEFT JOIN (
    SELECT reporter_citizen_id, COUNT(*) as open_complaints
    FROM documents.complaint_records
    WHERE status NOT IN ('resolved', 'archived')
        AND submitted_at < CURRENT_DATE - INTERVAL '30 days'
    GROUP BY reporter_citizen_id
) old_complaints ON c.citizen_id = old_complaints.reporter_citizen_id
LEFT JOIN (
    SELECT citizen_id, COUNT(*) as overdue_permits
    FROM civics.permit_applications
    WHERE status = 'pending'
        AND application_date < CURRENT_DATE - INTERVAL '90 days'
    GROUP BY citizen_id
) old_permits ON c.citizen_id = old_permits.citizen_id
WHERE (tax_balance > 0 OR open_complaints > 0 OR overdue_permits > 0)
    AND c.status = 'active';

COMMENT ON VIEW analytics.v_citizens_with_issues IS
'Citizens requiring follow-up for overdue obligations or lengthy open cases';

-- =============================================================================
-- BUSINESS AND COMMERCE VIEWS
-- =============================================================================

-- Active businesses with current license status
CREATE VIEW analytics.v_active_businesses AS
SELECT
    m.merchant_id,
    m.business_name,
    m.business_type,
    m.contact_email,
    m.contact_phone,
    m.business_address,
    m.zip_code,
    -- License information
    COUNT(bl.license_id) as total_licenses,
    COUNT(bl.license_id) FILTER (WHERE bl.status = 'active') as active_licenses,
    COUNT(bl.license_id) FILTER (WHERE bl.expiration_date <= CURRENT_DATE + INTERVAL '90 days') as expiring_soon,
    -- Business metrics
    m.annual_revenue,
    m.employee_count,
    m.registration_date,
    -- Owner information
    CASE WHEN c.citizen_id IS NOT NULL
         THEN c.first_name || ' ' || c.last_name
         ELSE 'Non-resident' END as owner_name
FROM commerce.merchants m
LEFT JOIN commerce.business_licenses bl ON m.merchant_id = bl.merchant_id
LEFT JOIN civics.citizens c ON m.owner_citizen_id = c.citizen_id
WHERE m.is_active = true
GROUP BY m.merchant_id, m.business_name, m.business_type, m.contact_email,
         m.contact_phone, m.business_address, m.zip_code, m.annual_revenue,
         m.employee_count, m.registration_date, c.first_name, c.last_name, c.citizen_id;

COMMENT ON VIEW analytics.v_active_businesses IS
'Active businesses with license status and owner information for compliance monitoring';

-- Monthly business performance metrics
CREATE VIEW analytics.v_monthly_business_metrics AS
SELECT
    m.merchant_id,
    m.business_name,
    m.business_type,
    DATE_TRUNC('month', o.order_date) as metrics_month,
    COUNT(o.order_id) as monthly_orders,
    COUNT(DISTINCT o.customer_citizen_id) as unique_customers,
    SUM(o.total_amount) as monthly_revenue,
    AVG(o.total_amount) as avg_order_value,
    -- Growth metrics
    LAG(COUNT(o.order_id)) OVER (
        PARTITION BY m.merchant_id
        ORDER BY DATE_TRUNC('month', o.order_date)
    ) as prev_month_orders,
    LAG(SUM(o.total_amount)) OVER (
        PARTITION BY m.merchant_id
        ORDER BY DATE_TRUNC('month', o.order_date)
    ) as prev_month_revenue
FROM commerce.merchants m
LEFT JOIN commerce.orders o ON m.merchant_id = o.merchant_id
    AND o.status IN ('delivered', 'completed')
    AND o.order_date >= CURRENT_DATE - INTERVAL '24 months'
WHERE m.is_active = true
GROUP BY m.merchant_id, m.business_name, m.business_type, DATE_TRUNC('month', o.order_date)
ORDER BY m.merchant_id, metrics_month;

COMMENT ON VIEW analytics.v_monthly_business_metrics IS
'Monthly performance tracking for businesses with growth trend analysis';

-- =============================================================================
-- MOBILITY AND TRANSPORTATION VIEWS
-- =============================================================================

-- Station status dashboard
CREATE VIEW analytics.v_station_dashboard AS
SELECT
    s.station_id,
    s.station_code,
    s.station_name,
    s.station_type,
    s.neighborhood,
    s.total_capacity,
    s.status as station_status,
    -- Current inventory (latest reading)
    COALESCE(latest.available_count, 0) as current_available,
    COALESCE(latest.in_use_count, 0) as current_in_use,
    COALESCE(latest.maintenance_count, 0) as current_maintenance,
    -- Utilization metrics
    CASE WHEN s.total_capacity > 0
         THEN ROUND(COALESCE(latest.in_use_count, 0) * 100.0 / s.total_capacity, 1)
         ELSE 0 END as current_utilization_pct,
    latest.recorded_at as last_updated,
    -- Maintenance indicators
    s.next_maintenance_due,
    CASE WHEN s.next_maintenance_due <= CURRENT_DATE + INTERVAL '7 days'
         THEN 'Due Soon'
         ELSE 'Current' END as maintenance_status
FROM mobility.stations s
LEFT JOIN (
    SELECT DISTINCT ON (station_id)
        station_id, available_count, in_use_count, maintenance_count, recorded_at
    FROM mobility.station_inventory
    ORDER BY station_id, recorded_at DESC
) latest ON s.station_id = latest.station_id;

COMMENT ON VIEW analytics.v_station_dashboard IS
'Real-time station status with current inventory and maintenance tracking';

-- Trip patterns summary
CREATE VIEW analytics.v_trip_patterns AS
SELECT
    trip_mode,
    COUNT(*) as total_trips,
    COUNT(DISTINCT user_id) as unique_users,
    AVG(distance_km) as avg_distance_km,
    AVG(duration_minutes) as avg_duration_min,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY distance_km) as median_distance_km,
    SUM(fare_paid) as total_fare_revenue,
    -- Time patterns
    MODE() WITHIN GROUP (ORDER BY EXTRACT(HOUR FROM start_time)) as peak_hour,
    MODE() WITHIN GROUP (ORDER BY EXTRACT(DOW FROM start_time)) as peak_day_of_week,
    -- Popular routes
    (SELECT s1.station_name || ' → ' || s2.station_name
     FROM mobility.trip_segments ts2
     JOIN mobility.stations s1 ON ts2.start_station_id = s1.station_id
     JOIN mobility.stations s2 ON ts2.end_station_id = s2.station_id
     WHERE ts2.trip_mode = ts.trip_mode
       AND ts2.start_station_id IS NOT NULL
       AND ts2.end_station_id IS NOT NULL
     GROUP BY s1.station_name, s2.station_name
     ORDER BY COUNT(*) DESC
     LIMIT 1) as most_popular_route
FROM mobility.trip_segments ts
WHERE start_time >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY trip_mode
ORDER BY total_trips DESC;

COMMENT ON VIEW analytics.v_trip_patterns IS
'Aggregate trip patterns by mode with usage statistics and popular routes';

-- =============================================================================
-- CIVIC ENGAGEMENT VIEWS
-- =============================================================================

-- Permit processing performance
CREATE VIEW analytics.v_permit_processing AS
SELECT
    permit_type,
    status,
    COUNT(*) as permit_count,
    AVG(EXTRACT(EPOCH FROM (COALESCE(approval_date, CURRENT_TIMESTAMP) - application_date))/86400) as avg_processing_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (COALESCE(approval_date, CURRENT_TIMESTAMP) - application_date))/86400) as median_processing_days,
    COUNT(*) FILTER (WHERE application_date >= CURRENT_DATE - INTERVAL '30 days') as recent_applications,
    SUM(fee_amount) as total_fees_assessed,
    SUM(fee_paid) as total_fees_collected,
    ROUND(SUM(fee_paid) * 100.0 / NULLIF(SUM(fee_amount), 0), 1) as collection_rate_pct
FROM civics.permit_applications
WHERE application_date >= CURRENT_DATE - INTERVAL '1 year'
GROUP BY permit_type, status
ORDER BY permit_type, status;

COMMENT ON VIEW analytics.v_permit_processing IS
'Permit processing metrics including timing, volume, and fee collection rates';

-- Complaint resolution tracking
CREATE VIEW analytics.v_complaint_resolution AS
SELECT
    category,
    priority_level,
    COUNT(*) as total_complaints,
    COUNT(*) FILTER (WHERE status = 'resolved') as resolved_count,
    COUNT(*) FILTER (WHERE status IN ('submitted', 'under_review')) as pending_count,
    ROUND(COUNT(*) FILTER (WHERE status = 'resolved') * 100.0 / COUNT(*), 1) as resolution_rate_pct,
    AVG(EXTRACT(EPOCH FROM (resolved_at - submitted_at))/86400) FILTER (WHERE resolved_at IS NOT NULL) as avg_resolution_days,
    COUNT(*) FILTER (WHERE submitted_at >= CURRENT_DATE - INTERVAL '30 days') as recent_complaints,
    -- Geographic distribution
    (SELECT nb.neighborhood_name
     FROM documents.complaint_records cr2
     JOIN geo.neighborhood_boundaries nb ON cr2.neighborhood_id = nb.neighborhood_id
     WHERE cr2.category = cr.category
     GROUP BY nb.neighborhood_name
     ORDER BY COUNT(*) DESC
     LIMIT 1) as most_common_neighborhood
FROM documents.complaint_records cr
WHERE submitted_at >= CURRENT_DATE - INTERVAL '1 year'
GROUP BY category, priority_level
ORDER BY total_complaints DESC, priority_level;

COMMENT ON VIEW analytics.v_complaint_resolution IS
'Complaint resolution metrics by category and priority with geographic insights';

-- =============================================================================
-- GEOGRAPHIC AND NEIGHBORHOOD VIEWS
-- =============================================================================

-- Neighborhood activity summary
CREATE VIEW analytics.v_neighborhood_activity AS
SELECT
    nb.neighborhood_id,
    nb.neighborhood_name,
    nb.population_estimate,
    nb.city_council_district,
    -- Resident activity
    COALESCE(resident_count, 0) as active_residents,
    COALESCE(complaint_count, 0) as recent_complaints,
    COALESCE(permit_count, 0) as recent_permits,
    -- Business activity
    COALESCE(business_count, 0) as active_businesses,
    COALESCE(poi_count, 0) as points_of_interest,
    -- Transportation
    COALESCE(station_count, 0) as mobility_stations,
    COALESCE(trip_count, 0) as recent_trips
FROM geo.neighborhood_boundaries nb
LEFT JOIN (
    SELECT zip_code, COUNT(*) as resident_count
    FROM civics.citizens
    WHERE status = 'active'
    GROUP BY zip_code
) residents ON nb.neighborhood_name = residents.zip_code -- Simplified join
LEFT JOIN (
    SELECT neighborhood_id, COUNT(*) as complaint_count
    FROM documents.complaint_records
    WHERE submitted_at >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY neighborhood_id
) complaints ON nb.neighborhood_id = complaints.neighborhood_id
LEFT JOIN (
    SELECT
        (SELECT neighborhood_id FROM geo.neighborhood_boundaries
         WHERE ST_Contains(boundary_geom, ST_SetSRID(ST_Point(-96.8040, 32.9855), 4326)) LIMIT 1) as neighborhood_id,
        COUNT(*) as permit_count
    FROM civics.permit_applications
    WHERE application_date >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY neighborhood_id
) permits ON nb.neighborhood_id = permits.neighborhood_id
LEFT JOIN (
    SELECT neighborhood_id, COUNT(*) as business_count
    FROM commerce.merchants
    WHERE is_active = true
    GROUP BY (SELECT neighborhood_id FROM geo.neighborhood_boundaries LIMIT 1) -- Simplified
) businesses ON nb.neighborhood_id = businesses.neighborhood_id
LEFT JOIN (
    SELECT neighborhood_id, COUNT(*) as poi_count
    FROM geo.points_of_interest
    WHERE is_active = true
    GROUP BY neighborhood_id
) pois ON nb.neighborhood_id = pois.neighborhood_id
LEFT JOIN (
    SELECT neighborhood, COUNT(*) as station_count
    FROM mobility.stations
    GROUP BY neighborhood
) stations ON nb.neighborhood_name = stations.neighborhood
LEFT JOIN (
    SELECT
        (SELECT neighborhood_id FROM geo.neighborhood_boundaries LIMIT 1) as neighborhood_id,
        COUNT(*) as trip_count
    FROM mobility.trip_segments
    WHERE start_time >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY neighborhood_id
) trips ON nb.neighborhood_id = trips.neighborhood_id;

COMMENT ON VIEW analytics.v_neighborhood_activity IS
'Comprehensive neighborhood activity metrics across all city services and systems';
