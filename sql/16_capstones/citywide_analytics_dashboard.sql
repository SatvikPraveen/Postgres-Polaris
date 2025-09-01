-- File: sql/99_capstones/citywide_analytics_dashboard.sql
-- Purpose: KPI views + matviews for comprehensive city analytics dashboard

-- =============================================================================
-- CITYWIDE ANALYTICS INFRASTRUCTURE
-- =============================================================================

-- Create schema for dashboard analytics
CREATE SCHEMA IF NOT EXISTS dashboard;

-- Dashboard configuration
CREATE TABLE dashboard.kpi_definitions (
    kpi_id BIGSERIAL PRIMARY KEY,
    kpi_name TEXT NOT NULL UNIQUE,
    kpi_description TEXT,
    kpi_category TEXT,
    calculation_query TEXT NOT NULL,
    target_value NUMERIC,
    warning_threshold NUMERIC,
    critical_threshold NUMERIC,
    unit_of_measure TEXT,
    refresh_frequency INTERVAL DEFAULT '1 hour',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- KPI historical values
CREATE TABLE dashboard.kpi_history (
    history_id BIGSERIAL PRIMARY KEY,
    kpi_id BIGINT REFERENCES dashboard.kpi_definitions(kpi_id),
    calculated_value NUMERIC,
    calculation_timestamp TIMESTAMPTZ DEFAULT NOW(),
    calculation_notes TEXT,
    INDEX (kpi_id, calculation_timestamp DESC)
);

-- =============================================================================
-- CORE CITY METRICS MATERIALIZED VIEWS
-- =============================================================================

-- Citywide population and demographics
CREATE MATERIALIZED VIEW dashboard.population_demographics AS
SELECT
    -- Geographic distribution
    city,
    state_province,
    COUNT(*) as total_citizens,
    COUNT(*) FILTER (WHERE status = 'active') as active_citizens,
    COUNT(*) FILTER (WHERE status = 'inactive') as inactive_citizens,

    -- Age demographics
    ROUND(AVG(EXTRACT(year FROM age(date_of_birth)))) as avg_age,
    COUNT(*) FILTER (WHERE EXTRACT(year FROM age(date_of_birth)) < 18) as under_18,
    COUNT(*) FILTER (WHERE EXTRACT(year FROM age(date_of_birth)) BETWEEN 18 AND 65) as working_age,
    COUNT(*) FILTER (WHERE EXTRACT(year FROM age(date_of_birth)) > 65) as senior_citizens,

    -- Registration trends
    MIN(registered_date) as first_registration,
    MAX(registered_date) as latest_registration,
    COUNT(*) FILTER (WHERE registered_date >= CURRENT_DATE - INTERVAL '30 days') as new_registrations_30d,
    COUNT(*) FILTER (WHERE registered_date >= CURRENT_DATE - INTERVAL '90 days') as new_registrations_90d,

    -- Economic indicators
    COUNT(*) FILTER (WHERE income_level = 'high') as high_income_count,
    COUNT(*) FILTER (WHERE income_level = 'medium') as medium_income_count,
    COUNT(*) FILTER (WHERE income_level = 'low') as low_income_count,

    -- Data quality metrics
    COUNT(*) FILTER (WHERE email IS NOT NULL) as citizens_with_email,
    COUNT(*) FILTER (WHERE phone IS NOT NULL) as citizens_with_phone,
    ROUND((COUNT(*) FILTER (WHERE email IS NOT NULL)::NUMERIC / COUNT(*)) * 100, 1) as email_completion_rate,

    NOW() as last_updated
FROM civics.citizens
GROUP BY city, state_province
WITH DATA;

-- Create indexes on materialized view
CREATE INDEX idx_population_demographics_city ON dashboard.population_demographics(city);
CREATE INDEX idx_population_demographics_total ON dashboard.population_demographics(total_citizens DESC);

-- Permit and licensing activity
CREATE MATERIALIZED VIEW dashboard.permit_activity_summary AS
SELECT
    -- Temporal analysis
    DATE_TRUNC('month', submitted_date) as month,
    permit_type,

    -- Volume metrics
    COUNT(*) as total_applications,
    COUNT(*) FILTER (WHERE status = 'pending') as pending_applications,
    COUNT(*) FILTER (WHERE status = 'under_review') as under_review_applications,
    COUNT(*) FILTER (WHERE status = 'approved') as approved_applications,
    COUNT(*) FILTER (WHERE status = 'rejected') as rejected_applications,

    -- Financial metrics
    SUM(estimated_cost) FILTER (WHERE estimated_cost IS NOT NULL) as total_estimated_value,
    SUM(final_cost) FILTER (WHERE final_cost IS NOT NULL) as total_final_value,
    AVG(estimated_cost) FILTER (WHERE estimated_cost IS NOT NULL) as avg_estimated_cost,
    AVG(final_cost) FILTER (WHERE final_cost IS NOT NULL) as avg_final_cost,

    -- Processing efficiency
    AVG(EXTRACT(days FROM (approved_date - submitted_date))) FILTER (WHERE approved_date IS NOT NULL) as avg_processing_days,
    COUNT(*) FILTER (WHERE approved_date IS NOT NULL AND (approved_date - submitted_date) <= INTERVAL '30 days') as fast_approvals,
    COUNT(*) FILTER (WHERE approved_date IS NOT NULL AND (approved_date - submitted_date) > INTERVAL '90 days') as slow_approvals,

    -- Quality metrics
    ROUND((COUNT(*) FILTER (WHERE status = 'approved')::NUMERIC / NULLIF(COUNT(*) FILTER (WHERE status IN ('approved', 'rejected')), 0)) * 100, 1) as approval_rate,

    NOW() as last_updated
FROM civics.permit_applications
WHERE submitted_date >= CURRENT_DATE - INTERVAL '2 years'
GROUP BY DATE_TRUNC('month', submitted_date), permit_type
WITH DATA;

-- Create indexes
CREATE INDEX idx_permit_activity_month ON dashboard.permit_activity_summary(month DESC);
CREATE INDEX idx_permit_activity_type ON dashboard.permit_activity_summary(permit_type);

-- Economic activity and commerce
CREATE MATERIALIZED VIEW dashboard.economic_activity_summary AS
SELECT
    -- Temporal grouping
    DATE_TRUNC('month', o.order_date) as month,
    m.business_type,
    c.city as customer_city,

    -- Volume metrics
    COUNT(DISTINCT m.merchant_id) as active_merchants,
    COUNT(DISTINCT o.customer_citizen_id) as unique_customers,
    COUNT(o.order_id) as total_orders,

    -- Financial metrics
    SUM(o.total_amount) as total_revenue,
    SUM(o.tax_amount) as total_tax_collected,
    AVG(o.total_amount) as avg_order_value,
    MEDIAN(o.total_amount) as median_order_value,

    -- Business health indicators
    COUNT(*) FILTER (WHERE o.order_status = 'completed') as completed_orders,
    COUNT(*) FILTER (WHERE o.order_status = 'cancelled') as cancelled_orders,
    COUNT(*) FILTER (WHERE o.order_status = 'refunded') as refunded_orders,
    ROUND((COUNT(*) FILTER (WHERE o.order_status = 'completed')::NUMERIC / COUNT(*)) * 100, 1) as completion_rate,

    -- Geographic distribution
    COUNT(DISTINCT c.city) as cities_served,

    NOW() as last_updated
FROM commerce.orders o
JOIN commerce.merchants m ON o.merchant_id = m.merchant_id
JOIN civics.citizens c ON o.customer_citizen_id = c.citizen_id
WHERE o.order_date >= CURRENT_DATE - INTERVAL '2 years'
GROUP BY DATE_TRUNC('month', o.order_date), m.business_type, c.city
WITH DATA;

-- Create indexes
CREATE INDEX idx_economic_activity_month ON dashboard.economic_activity_summary(month DESC);
CREATE INDEX idx_economic_activity_revenue ON dashboard.economic_activity_summary(total_revenue DESC NULLS LAST);

-- Civic engagement metrics
CREATE MATERIALIZED VIEW dashboard.civic_engagement_summary AS
SELECT
    DATE_TRUNC('month', vr.election_date) as election_month,
    vr.election_type,
    c.city,

    -- Participation metrics
    COUNT(DISTINCT vr.citizen_id) as total_voters,
    COUNT(DISTINCT c.citizen_id) FILTER (WHERE c.status = 'active') as eligible_voters_in_city,
    ROUND((COUNT(DISTINCT vr.citizen_id)::NUMERIC /
           NULLIF(COUNT(DISTINCT c.citizen_id) FILTER (WHERE c.status = 'active'), 0)) * 100, 1) as participation_rate,

    -- Demographics of voters
    COUNT(*) FILTER (WHERE EXTRACT(year FROM age(c.date_of_birth)) < 30) as young_voters,
    COUNT(*) FILTER (WHERE EXTRACT(year FROM age(c.date_of_birth)) BETWEEN 30 AND 50) as middle_age_voters,
    COUNT(*) FILTER (WHERE EXTRACT(year FROM age(c.date_of_birth)) > 50) as senior_voters,

    -- Engagement trends
    COUNT(*) FILTER (WHERE vr.vote_method = 'in_person') as in_person_votes,
    COUNT(*) FILTER (WHERE vr.vote_method = 'absentee') as absentee_votes,
    COUNT(*) FILTER (WHERE vr.vote_method = 'early') as early_votes,

    NOW() as last_updated
FROM civics.voting_records vr
JOIN civics.citizens c ON vr.citizen_id = c.citizen_id
WHERE vr.election_date >= CURRENT_DATE - INTERVAL '4 years'
GROUP BY DATE_TRUNC('month', vr.election_date), vr.election_type, c.city
WITH DATA;

-- Service delivery performance
CREATE MATERIALIZED VIEW dashboard.service_delivery_performance AS
SELECT
    'permits' as service_type,
    DATE_TRUNC('week', submitted_date) as week,

    -- Volume metrics
    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE status = 'completed' OR status = 'approved') as completed_requests,
    COUNT(*) FILTER (WHERE status = 'pending') as pending_requests,

    -- Timeliness metrics
    AVG(EXTRACT(days FROM (COALESCE(approved_date, NOW()) - submitted_date))) as avg_processing_days,
    COUNT(*) FILTER (WHERE (COALESCE(approved_date, NOW()) - submitted_date) <= INTERVAL '5 days') as fast_processing,
    COUNT(*) FILTER (WHERE (COALESCE(approved_date, NOW()) - submitted_date) > INTERVAL '30 days') as slow_processing,

    -- Quality metrics
    ROUND((COUNT(*) FILTER (WHERE status = 'approved')::NUMERIC /
           NULLIF(COUNT(*) FILTER (WHERE status IN ('approved', 'rejected')), 0)) * 100, 1) as success_rate,

    NOW() as last_updated
FROM civics.permit_applications
WHERE submitted_date >= CURRENT_DATE - INTERVAL '1 year'
GROUP BY DATE_TRUNC('week', submitted_date)

UNION ALL

SELECT
    'complaints' as service_type,
    DATE_TRUNC('week', cr.submitted_date) as week,

    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE cr.status = 'resolved') as completed_requests,
    COUNT(*) FILTER (WHERE cr.status = 'open') as pending_requests,

    AVG(EXTRACT(days FROM (COALESCE(cr.resolved_date, NOW()) - cr.submitted_date))) as avg_processing_days,
    COUNT(*) FILTER (WHERE (COALESCE(cr.resolved_date, NOW()) - cr.submitted_date) <= INTERVAL '3 days') as fast_processing,
    COUNT(*) FILTER (WHERE (COALESCE(cr.resolved_date, NOW()) - cr.submitted_date) > INTERVAL '14 days') as slow_processing,

    ROUND((COUNT(*) FILTER (WHERE cr.status = 'resolved')::NUMERIC / COUNT(*)) * 100, 1) as success_rate,

    NOW() as last_updated
FROM documents.complaint_records cr
WHERE cr.submitted_date >= CURRENT_DATE - INTERVAL '1 year'
GROUP BY DATE_TRUNC('week', cr.submitted_date)
WITH DATA;

-- =============================================================================
-- REAL-TIME KPI VIEWS
-- =============================================================================

-- Executive dashboard summary
CREATE OR REPLACE VIEW dashboard.executive_summary AS
SELECT
    -- Population metrics
    (SELECT COUNT(*) FROM civics.citizens WHERE status = 'active') as total_active_citizens,
    (SELECT COUNT(*) FROM civics.citizens WHERE registered_date >= CURRENT_DATE - INTERVAL '30 days') as new_citizens_30d,

    -- Economic indicators
    (SELECT COUNT(*) FROM commerce.merchants WHERE status = 'active') as active_businesses,
    (SELECT COALESCE(SUM(total_amount), 0) FROM commerce.orders WHERE order_date >= DATE_TRUNC('month', CURRENT_DATE)) as monthly_commerce_volume,
    (SELECT COALESCE(SUM(tax_amount), 0) FROM commerce.orders WHERE order_date >= DATE_TRUNC('month', CURRENT_DATE)) as monthly_tax_collected,

    -- Service delivery
    (SELECT COUNT(*) FROM civics.permit_applications WHERE status = 'pending') as pending_permits,
    (SELECT COUNT(*) FROM documents.complaint_records WHERE status = 'open') as open_complaints,
    (SELECT ROUND(AVG(EXTRACT(days FROM (approved_date - submitted_date)))) FROM civics.permit_applications WHERE approved_date >= CURRENT_DATE - INTERVAL '30 days') as avg_permit_processing_days,

    -- System health
    (SELECT COUNT(*) FROM messaging.message_queue WHERE status = 'pending') as pending_messages,
    (SELECT COUNT(*) FROM data_quality.quality_issues WHERE detected_at >= CURRENT_DATE AND resolved_at IS NULL) as open_data_quality_issues,

    NOW() as report_timestamp;

-- Department performance dashboard
CREATE OR REPLACE VIEW dashboard.department_performance AS
SELECT
    'Permits & Licensing' as department,

    -- Volume metrics
    (SELECT COUNT(*) FROM civics.permit_applications WHERE submitted_date >= DATE_TRUNC('month', CURRENT_DATE)) as monthly_volume,
    (SELECT COUNT(*) FROM civics.permit_applications WHERE submitted_date >= CURRENT_DATE - INTERVAL '7 days') as weekly_volume,

    -- Performance metrics
    (SELECT ROUND(AVG(EXTRACT(days FROM (approved_date - submitted_date))))
     FROM civics.permit_applications
     WHERE approved_date >= CURRENT_DATE - INTERVAL '30 days') as avg_processing_time,

    (SELECT ROUND((COUNT(*) FILTER (WHERE status = 'approved')::NUMERIC /
                   NULLIF(COUNT(*) FILTER (WHERE status IN ('approved', 'rejected')), 0)) * 100, 1)
     FROM civics.permit_applications
     WHERE submitted_date >= CURRENT_DATE - INTERVAL '30 days') as approval_rate,

    -- Backlog
    (SELECT COUNT(*) FROM civics.permit_applications WHERE status = 'pending') as current_backlog,

    -- Efficiency indicator
    CASE
        WHEN (SELECT COUNT(*) FROM civics.permit_applications WHERE status = 'pending') > 100 THEN 'High Backlog'
        WHEN (SELECT ROUND(AVG(EXTRACT(days FROM (approved_date - submitted_date))))
              FROM civics.permit_applications
              WHERE approved_date >= CURRENT_DATE - INTERVAL '30 days') > 30 THEN 'Slow Processing'
        ELSE 'On Track'
    END as performance_status

UNION ALL

SELECT
    'Customer Service' as department,

    (SELECT COUNT(*) FROM documents.complaint_records WHERE submitted_date >= DATE_TRUNC('month', CURRENT_DATE)) as monthly_volume,
    (SELECT COUNT(*) FROM documents.complaint_records WHERE submitted_date >= CURRENT_DATE - INTERVAL '7 days') as weekly_volume,

    (SELECT ROUND(AVG(EXTRACT(days FROM (resolved_date - submitted_date))))
     FROM documents.complaint_records
     WHERE resolved_date >= CURRENT_DATE - INTERVAL '30 days') as avg_processing_time,

    (SELECT ROUND((COUNT(*) FILTER (WHERE status = 'resolved')::NUMERIC / COUNT(*)) * 100, 1)
     FROM documents.complaint_records
     WHERE submitted_date >= CURRENT_DATE - INTERVAL '30 days') as approval_rate,

    (SELECT COUNT(*) FROM documents.complaint_records WHERE status = 'open') as current_backlog,

    CASE
        WHEN (SELECT COUNT(*) FROM documents.complaint_records WHERE status = 'open') > 50 THEN 'High Backlog'
        WHEN (SELECT ROUND(AVG(EXTRACT(days FROM (resolved_date - submitted_date))))
              FROM documents.complaint_records
              WHERE resolved_date >= CURRENT_DATE - INTERVAL '30 days') > 14 THEN 'Slow Processing'
        ELSE 'On Track'
    END as performance_status;

-- Economic development indicators
CREATE OR REPLACE VIEW dashboard.economic_indicators AS
SELECT
    -- Current month metrics
    DATE_TRUNC('month', CURRENT_DATE) as reporting_month,

    -- Business growth
    (SELECT COUNT(*) FROM commerce.merchants WHERE status = 'active') as total_active_businesses,
    (SELECT COUNT(*) FROM commerce.merchants WHERE registration_date >= DATE_TRUNC('month', CURRENT_DATE)) as new_businesses_this_month,
    (SELECT COUNT(*) FROM commerce.merchants WHERE registration_date >= CURRENT_DATE - INTERVAL '12 months') as new_businesses_12m,

    -- Commerce volume
    (SELECT COALESCE(SUM(total_amount), 0) FROM commerce.orders WHERE order_date >= DATE_TRUNC('month', CURRENT_DATE)) as monthly_sales_volume,
    (SELECT COALESCE(SUM(total_amount), 0) FROM commerce.orders WHERE order_date >= CURRENT_DATE - INTERVAL '12 months') as annual_sales_volume,
    (SELECT COALESCE(AVG(total_amount), 0) FROM commerce.orders WHERE order_date >= DATE_TRUNC('month', CURRENT_DATE)) as avg_transaction_value,

    -- Employment indicators (proxy)
    (SELECT COUNT(DISTINCT owner_citizen_id) FROM commerce.merchants WHERE status = 'active') as business_owners,
    (SELECT COUNT(*) FILTER (WHERE income_level = 'high') FROM civics.citizens WHERE status = 'active') as high_income_residents,

    -- Tax revenue
    (SELECT COALESCE(SUM(tax_amount), 0) FROM commerce.orders WHERE order_date >= DATE_TRUNC('month', CURRENT_DATE)) as monthly_tax_revenue,
    (SELECT COALESCE(SUM(tax_amount), 0) FROM commerce.orders WHERE order_date >= CURRENT_DATE - INTERVAL '12 months') as annual_tax_revenue,

    -- Growth rates
    (SELECT
        CASE
            WHEN LAG(SUM(total_amount)) OVER () > 0
            THEN ROUND(((SUM(total_amount) - LAG(SUM(total_amount)) OVER ()) / LAG(SUM(total_amount)) OVER ()) * 100, 1)
            ELSE NULL
        END
     FROM commerce.orders
     WHERE order_date >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
     AND order_date < DATE_TRUNC('month', CURRENT_DATE)) as monthly_growth_rate;

-- =============================================================================
-- DYNAMIC KPI CALCULATION FUNCTIONS
-- =============================================================================

-- Calculate KPI value dynamically
CREATE OR REPLACE FUNCTION dashboard.calculate_kpi(kpi_name TEXT)
RETURNS NUMERIC AS $$
DECLARE
    kpi_record RECORD;
    calculated_value NUMERIC;
BEGIN
    -- Get KPI definition
    SELECT * INTO kpi_record
    FROM dashboard.kpi_definitions
    WHERE dashboard.kpi_definitions.kpi_name = calculate_kpi.kpi_name
    AND is_active = TRUE;

    IF kpi_record IS NULL THEN
        RAISE EXCEPTION 'KPI not found or inactive: %', kpi_name;
    END IF;

    -- Execute calculation query
    EXECUTE kpi_record.calculation_query INTO calculated_value;

    -- Store in history
    INSERT INTO dashboard.kpi_history (kpi_id, calculated_value)
    VALUES (kpi_record.kpi_id, calculated_value);

    RETURN calculated_value;
END;
$$ LANGUAGE plpgsql;

-- Refresh all materialized views
CREATE OR REPLACE FUNCTION dashboard.refresh_all_dashboards()
RETURNS TEXT AS $$
DECLARE
    refresh_count INTEGER := 0;
    start_time TIMESTAMPTZ := NOW();
    result_msg TEXT;
BEGIN
    -- Refresh materialized views concurrently where possible
    REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard.population_demographics;
    refresh_count := refresh_count + 1;

    REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard.permit_activity_summary;
    refresh_count := refresh_count + 1;

    REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard.economic_activity_summary;
    refresh_count := refresh_count + 1;

    REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard.civic_engagement_summary;
    refresh_count := refresh_count + 1;

    REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard.service_delivery_performance;
    refresh_count := refresh_count + 1;

    result_msg := 'Refreshed ' || refresh_count || ' dashboard views in ' ||
                  EXTRACT(seconds FROM NOW() - start_time)::INTEGER || ' seconds';

    -- Notify completion
    PERFORM messaging.notify_channel(
        'dashboard_updates',
        'materialized_views_refreshed',
        json_build_object(
            'views_refreshed', refresh_count,
            'refresh_duration_seconds', EXTRACT(seconds FROM NOW() - start_time)::INTEGER,
            'refreshed_at', NOW()
        ),
        'dashboard_system'
    );

    RETURN result_msg;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ALERTING AND MONITORING
-- =============================================================================

-- Check KPI thresholds and generate alerts
CREATE OR REPLACE FUNCTION dashboard.check_kpi_alerts()
RETURNS TABLE(
    kpi_name TEXT,
    current_value NUMERIC,
    threshold_type TEXT,
    threshold_value NUMERIC,
    alert_severity TEXT,
    alert_message TEXT
) AS $$
DECLARE
    kpi_record RECORD;
    current_value NUMERIC;
BEGIN
    FOR kpi_record IN
        SELECT * FROM dashboard.kpi_definitions WHERE is_active = TRUE
    LOOP
        -- Get most recent KPI value
        SELECT calculated_value INTO current_value
        FROM dashboard.kpi_history
        WHERE kpi_id = kpi_record.kpi_id
        ORDER BY calculation_timestamp DESC
        LIMIT 1;

        IF current_value IS NULL THEN
            CONTINUE;
        END IF;

        -- Check critical threshold
        IF kpi_record.critical_threshold IS NOT NULL AND
           current_value <= kpi_record.critical_threshold THEN
            RETURN QUERY SELECT
                kpi_record.kpi_name,
                current_value,
                'critical'::TEXT,
                kpi_record.critical_threshold,
                'CRITICAL'::TEXT,
                'KPI ' || kpi_record.kpi_name || ' is at critical level: ' || current_value;

        -- Check warning threshold
        ELSIF kpi_record.warning_threshold IS NOT NULL AND
              current_value <= kpi_record.warning_threshold THEN
            RETURN QUERY SELECT
                kpi_record.kpi_name,
                current_value,
                'warning'::TEXT,
                kpi_record.warning_threshold,
                'WARNING'::TEXT,
                'KPI ' || kpi_record.kpi_name || ' is below warning threshold: ' || current_value;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SETUP AND INITIALIZATION
-- =============================================================================

-- Initialize standard city KPIs
CREATE OR REPLACE FUNCTION dashboard.setup_standard_kpis()
RETURNS TEXT AS $$
DECLARE
    kpi_count INTEGER := 0;
BEGIN
    -- Population growth rate
    INSERT INTO dashboard.kpi_definitions (
        kpi_name, kpi_description, kpi_category, calculation_query,
        target_value, warning_threshold, unit_of_measure
    ) VALUES (
        'population_growth_rate',
        'Monthly population growth rate percentage',
        'Demographics',
        'SELECT ROUND(((COUNT(*) FILTER (WHERE registered_date >= CURRENT_DATE - INTERVAL ''30 days'')::NUMERIC /
                       NULLIF(COUNT(*) FILTER (WHERE registered_date < CURRENT_DATE - INTERVAL ''30 days''), 0)) * 100), 2)
         FROM civics.citizens WHERE status = ''active''',
        2.0, 0.5, 'percentage'
    ) ON CONFLICT (kpi_name) DO NOTHING;
    kpi_count := kpi_count + 1;

    -- Service delivery efficiency
    INSERT INTO dashboard.kpi_definitions (
        kpi_name, kpi_description, kpi_category, calculation_query,
        target_value, warning_threshold, critical_threshold, unit_of_measure
    ) VALUES (
        'permit_processing_efficiency',
        'Average permit processing time in days',
        'Service Delivery',
        'SELECT ROUND(AVG(EXTRACT(days FROM (approved_date - submitted_date))))
         FROM civics.permit_applications
         WHERE approved_date >= CURRENT_DATE - INTERVAL ''30 days''',
        15.0, 25.0, 40.0, 'days'
    ) ON CONFLICT (kpi_name) DO NOTHING;
    kpi_count := kpi_count + 1;

    -- Economic vitality
    INSERT INTO dashboard.kpi_definitions (
        kpi_name, kpi_description, kpi_category, calculation_query,
        target_value, warning_threshold, unit_of_measure
    ) VALUES (
        'monthly_commerce_volume',
        'Total monthly commerce transaction volume',
        'Economic Development',
        'SELECT COALESCE(SUM(total_amount), 0)
         FROM commerce.orders
         WHERE order_date >= DATE_TRUNC(''month'', CURRENT_DATE)',
        100000.0, 50000.0, 'currency'
    ) ON CONFLICT (kpi_name) DO NOTHING;
    kpi_count := kpi_count + 1;

    -- Civic engagement
    INSERT INTO dashboard.kpi_definitions (
        kpi_name, kpi_description, kpi_category, calculation_query,
        target_value, warning_threshold, unit_of_measure
    ) VALUES (
        'citizen_engagement_rate',
        'Percentage of active citizens with recent civic activity',
        'Civic Engagement',
        'SELECT ROUND((COUNT(DISTINCT citizen_id)::NUMERIC /
                      (SELECT COUNT(*) FROM civics.citizens WHERE status = ''active'')) * 100, 1)
         FROM (SELECT citizen_id FROM civics.permit_applications WHERE submitted_date >= CURRENT_DATE - INTERVAL ''90 days''
               UNION
               SELECT citizen_id FROM civics.voting_records WHERE election_date >= CURRENT_DATE - INTERVAL ''1 year'') engaged',
        25.0, 15.0, 'percentage'
    ) ON CONFLICT (kpi_name) DO NOTHING;
    kpi_count := kpi_count + 1;

    RETURN 'Initialized ' || kpi_count || ' standard KPIs for city dashboard';
END;
$$ LANGUAGE plpgsql;
