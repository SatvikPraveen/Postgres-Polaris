-- File: sql/15_testing_quality/data_quality_checks.sql
-- Purpose: constraint violations, orphans, duplicates detection

-- =============================================================================
-- DATA QUALITY MONITORING INFRASTRUCTURE
-- =============================================================================

-- Create schema for data quality
CREATE SCHEMA IF NOT EXISTS data_quality;

-- Data quality issues log
CREATE TABLE data_quality.quality_issues (
    issue_id BIGSERIAL PRIMARY KEY,
    check_name TEXT NOT NULL,
    issue_type TEXT CHECK (issue_type IN ('constraint_violation', 'orphan_record', 'duplicate', 'missing_data', 'invalid_format', 'referential_integrity', 'business_rule_violation')),
    table_name TEXT NOT NULL,
    column_name TEXT,
    record_id TEXT,
    issue_description TEXT NOT NULL,
    severity TEXT CHECK (severity IN ('low', 'medium', 'high', 'critical')) DEFAULT 'medium',
    detected_at TIMESTAMPTZ DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    resolution_notes TEXT,
    auto_fixable BOOLEAN DEFAULT FALSE
);

-- Data quality check definitions
CREATE TABLE data_quality.quality_checks (
    check_id BIGSERIAL PRIMARY KEY,
    check_name TEXT NOT NULL UNIQUE,
    check_description TEXT,
    check_query TEXT NOT NULL,
    check_category TEXT,
    severity_level TEXT CHECK (severity_level IN ('low', 'medium', 'high', 'critical')) DEFAULT 'medium',
    is_active BOOLEAN DEFAULT TRUE,
    check_frequency TEXT, -- 'daily', 'hourly', 'weekly'
    last_run TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Quality metrics tracking
CREATE TABLE data_quality.quality_metrics (
    metric_id BIGSERIAL PRIMARY KEY,
    metric_date DATE DEFAULT CURRENT_DATE,
    table_name TEXT NOT NULL,
    total_records BIGINT,
    valid_records BIGINT,
    invalid_records BIGINT,
    quality_score NUMERIC(5,2) GENERATED ALWAYS AS (
        CASE WHEN total_records > 0
        THEN ROUND((valid_records::NUMERIC / total_records) * 100, 2)
        ELSE 0 END
    ) STORED,
    issues_found INTEGER DEFAULT 0,
    issues_resolved INTEGER DEFAULT 0,
    calculated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(metric_date, table_name)
);

-- =============================================================================
-- CONSTRAINT VIOLATION CHECKS
-- =============================================================================

-- Check for constraint violations in citizens table
CREATE OR REPLACE FUNCTION data_quality.check_citizen_constraints()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    -- Check for invalid email formats
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'citizen_email_format',
        'invalid_format',
        'civics.citizens',
        'email',
        citizen_id::TEXT,
        'Invalid email format: ' || email,
        'medium'
    FROM civics.citizens
    WHERE email IS NOT NULL
    AND email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$';

    GET DIAGNOSTICS issues_found = ROW_COUNT;

    -- Check for invalid phone formats
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'citizen_phone_format',
        'invalid_format',
        'civics.citizens',
        'phone',
        citizen_id::TEXT,
        'Invalid phone format: ' || phone,
        'low'
    FROM civics.citizens
    WHERE phone IS NOT NULL
    AND phone !~ '^\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}$';

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    -- Check for future birth dates
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'citizen_future_birth_date',
        'invalid_format',
        'civics.citizens',
        'date_of_birth',
        citizen_id::TEXT,
        'Birth date in future: ' || date_of_birth,
        'high'
    FROM civics.citizens
    WHERE date_of_birth > CURRENT_DATE;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    -- Check for unreasonable ages (> 150 years)
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'citizen_unreasonable_age',
        'business_rule_violation',
        'civics.citizens',
        'date_of_birth',
        citizen_id::TEXT,
        'Unreasonable age: ' || EXTRACT(year FROM age(date_of_birth)) || ' years',
        'medium'
    FROM civics.citizens
    WHERE date_of_birth < (CURRENT_DATE - INTERVAL '150 years');

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- Check for permit application constraints
CREATE OR REPLACE FUNCTION data_quality.check_permit_constraints()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    -- Check for negative costs
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'permit_negative_cost',
        'business_rule_violation',
        'civics.permit_applications',
        'estimated_cost',
        application_id::TEXT,
        'Negative estimated cost: ' || estimated_cost,
        'high'
    FROM civics.permit_applications
    WHERE estimated_cost < 0;

    GET DIAGNOSTICS issues_found = ROW_COUNT;

    -- Check for start dates in the past for pending permits
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'permit_past_start_date',
        'business_rule_violation',
        'civics.permit_applications',
        'requested_start_date',
        application_id::TEXT,
        'Past start date for pending permit: ' || requested_start_date,
        'medium'
    FROM civics.permit_applications
    WHERE status = 'pending'
    AND requested_start_date < CURRENT_DATE;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    -- Check for approved permits without approval date
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'permit_missing_approval_date',
        'missing_data',
        'civics.permit_applications',
        'approved_date',
        application_id::TEXT,
        'Approved permit missing approval date',
        'medium'
    FROM civics.permit_applications
    WHERE status = 'approved'
    AND approved_date IS NULL;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ORPHANED RECORDS DETECTION
-- =============================================================================

-- Find orphaned permit applications (citizen doesn't exist)
CREATE OR REPLACE FUNCTION data_quality.check_orphaned_permits()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'orphaned_permit_applications',
        'orphan_record',
        'civics.permit_applications',
        'citizen_id',
        application_id::TEXT,
        'Permit references non-existent citizen: ' || citizen_id,
        'critical'
    FROM civics.permit_applications pa
    LEFT JOIN civics.citizens c ON pa.citizen_id = c.citizen_id
    WHERE c.citizen_id IS NULL;

    GET DIAGNOSTICS issues_found = ROW_COUNT;
    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- Find orphaned orders (merchant or customer doesn't exist)
CREATE OR REPLACE FUNCTION data_quality.check_orphaned_orders()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    -- Orphaned by missing merchant
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'orphaned_orders_merchant',
        'orphan_record',
        'commerce.orders',
        'merchant_id',
        order_id::TEXT,
        'Order references non-existent merchant: ' || merchant_id,
        'critical'
    FROM commerce.orders o
    LEFT JOIN commerce.merchants m ON o.merchant_id = m.merchant_id
    WHERE m.merchant_id IS NULL;

    GET DIAGNOSTICS issues_found = ROW_COUNT;

    -- Orphaned by missing customer
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'orphaned_orders_customer',
        'orphan_record',
        'commerce.orders',
        'customer_citizen_id',
        order_id::TEXT,
        'Order references non-existent customer: ' || customer_citizen_id,
        'critical'
    FROM commerce.orders o
    LEFT JOIN civics.citizens c ON o.customer_citizen_id = c.citizen_id
    WHERE c.citizen_id IS NULL;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;
    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- Find orphaned merchants (owner doesn't exist)
CREATE OR REPLACE FUNCTION data_quality.check_orphaned_merchants()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'orphaned_merchants',
        'orphan_record',
        'commerce.merchants',
        'owner_citizen_id',
        merchant_id::TEXT,
        'Merchant references non-existent owner: ' || owner_citizen_id,
        'high'
    FROM commerce.merchants m
    LEFT JOIN civics.citizens c ON m.owner_citizen_id = c.citizen_id
    WHERE c.citizen_id IS NULL;

    GET DIAGNOSTICS issues_found = ROW_COUNT;
    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DUPLICATE DETECTION
-- =============================================================================

-- Find duplicate citizens (same email)
CREATE OR REPLACE FUNCTION data_quality.check_duplicate_citizens()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'duplicate_citizen_email',
        'duplicate',
        'civics.citizens',
        'email',
        string_agg(citizen_id::TEXT, ', ' ORDER BY citizen_id),
        'Duplicate email address: ' || email || ' (IDs: ' || string_agg(citizen_id::TEXT, ', ' ORDER BY citizen_id) || ')',
        'high'
    FROM civics.citizens
    WHERE email IS NOT NULL
    GROUP BY email
    HAVING COUNT(*) > 1;

    GET DIAGNOSTICS issues_found = ROW_COUNT;

    -- Find potential duplicate citizens (same name + address)
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'potential_duplicate_citizens',
        'duplicate',
        'civics.citizens',
        'first_name,last_name,street_address',
        string_agg(citizen_id::TEXT, ', ' ORDER BY citizen_id),
        'Potential duplicate citizen: ' || first_name || ' ' || last_name || ' at ' || street_address,
        'medium'
    FROM civics.citizens
    WHERE first_name IS NOT NULL AND last_name IS NOT NULL AND street_address IS NOT NULL
    GROUP BY first_name, last_name, street_address
    HAVING COUNT(*) > 1;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;
    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- Find duplicate permits (same citizen, type, overlapping dates)
CREATE OR REPLACE FUNCTION data_quality.check_duplicate_permits()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'duplicate_permit_applications',
        'duplicate',
        'civics.permit_applications',
        'citizen_id,permit_type',
        string_agg(application_id::TEXT, ', ' ORDER BY application_id),
        'Duplicate permit applications for citizen ' || citizen_id || ', type: ' || permit_type,
        'medium'
    FROM civics.permit_applications
    WHERE status IN ('pending', 'under_review', 'approved')
    GROUP BY citizen_id, permit_type, requested_start_date
    HAVING COUNT(*) > 1;

    GET DIAGNOSTICS issues_found = ROW_COUNT;
    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- MISSING DATA CHECKS
-- =============================================================================

-- Check for missing required data
CREATE OR REPLACE FUNCTION data_quality.check_missing_data()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    -- Citizens missing email
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'citizen_missing_email',
        'missing_data',
        'civics.citizens',
        'email',
        citizen_id::TEXT,
        'Citizen missing email address',
        'low'
    FROM civics.citizens
    WHERE email IS NULL OR email = '';

    GET DIAGNOSTICS issues_found = ROW_COUNT;

    -- Merchants missing contact info
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'merchant_missing_contact',
        'missing_data',
        'commerce.merchants',
        'business_phone,business_email',
        merchant_id::TEXT,
        'Merchant missing contact information',
        'medium'
    FROM commerce.merchants
    WHERE (business_phone IS NULL OR business_phone = '')
    AND (business_email IS NULL OR business_email = '');

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    -- Orders missing delivery address
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'order_missing_delivery_address',
        'missing_data',
        'commerce.orders',
        'delivery_address',
        order_id::TEXT,
        'Order missing delivery address',
        'high'
    FROM commerce.orders
    WHERE delivery_address IS NULL OR delivery_address = '';

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BUSINESS RULE VALIDATION
-- =============================================================================

-- Check business logic rules
CREATE OR REPLACE FUNCTION data_quality.check_business_rules()
RETURNS INTEGER AS $$
DECLARE
    issues_found INTEGER := 0;
BEGIN
    -- Orders with zero or negative amounts
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'order_invalid_amount',
        'business_rule_violation',
        'commerce.orders',
        'total_amount',
        order_id::TEXT,
        'Order has invalid total amount: ' || total_amount,
        'high'
    FROM commerce.orders
    WHERE total_amount <= 0;

    GET DIAGNOSTICS issues_found = ROW_COUNT;

    -- Tax amount greater than total amount
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'order_tax_exceeds_total',
        'business_rule_violation',
        'commerce.orders',
        'tax_amount',
        order_id::TEXT,
        'Tax amount (' || tax_amount || ') exceeds total amount (' || total_amount || ')',
        'critical'
    FROM commerce.orders
    WHERE tax_amount > total_amount;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    -- Permits approved before submission
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'permit_approved_before_submission',
        'business_rule_violation',
        'civics.permit_applications',
        'approved_date',
        application_id::TEXT,
        'Permit approved before submission date',
        'critical'
    FROM civics.permit_applications
    WHERE approved_date IS NOT NULL
    AND approved_date < submitted_date;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    -- Citizens registered in the future
    INSERT INTO data_quality.quality_issues (
        check_name, issue_type, table_name, column_name, record_id, issue_description, severity
    )
    SELECT
        'citizen_future_registration',
        'business_rule_violation',
        'civics.citizens',
        'registered_date',
        citizen_id::TEXT,
        'Citizen registered in future: ' || registered_date,
        'critical'
    FROM civics.citizens
    WHERE registered_date > CURRENT_DATE;

    GET DIAGNOSTICS issues_found = issues_found + ROW_COUNT;

    RETURN issues_found;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COMPREHENSIVE DATA QUALITY ASSESSMENT
-- =============================================================================

-- Run all data quality checks
CREATE OR REPLACE FUNCTION data_quality.run_all_quality_checks()
RETURNS TABLE(
    check_category TEXT,
    check_function TEXT,
    issues_found INTEGER,
    execution_time_ms INTEGER,
    status TEXT
) AS $$
DECLARE
    check_functions TEXT[] := ARRAY[
        'data_quality.check_citizen_constraints',
        'data_quality.check_permit_constraints',
        'data_quality.check_orphaned_permits',
        'data_quality.check_orphaned_orders',
        'data_quality.check_orphaned_merchants',
        'data_quality.check_duplicate_citizens',
        'data_quality.check_duplicate_permits',
        'data_quality.check_missing_data',
        'data_quality.check_business_rules'
    ];
    func_name TEXT;
    start_time TIMESTAMPTZ;
    issues_count INTEGER;
    execution_time INTEGER;
BEGIN
    -- Clear issues from recent runs for fresh analysis
    DELETE FROM data_quality.quality_issues
    WHERE detected_at >= NOW() - INTERVAL '1 hour';

    FOREACH func_name IN ARRAY check_functions LOOP
        start_time := clock_timestamp();

        BEGIN
            EXECUTE 'SELECT ' || func_name || '()' INTO issues_count;
            execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

            RETURN QUERY SELECT
                split_part(func_name, '.', 2) as check_category,
                func_name as check_function,
                issues_count as issues_found,
                execution_time as execution_time_ms,
                CASE WHEN issues_count = 0 THEN 'PASS' ELSE 'ISSUES_FOUND' END as status;

        EXCEPTION WHEN OTHERS THEN
            execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

            RETURN QUERY SELECT
                split_part(func_name, '.', 2) as check_category,
                func_name as check_function,
                -1 as issues_found,
                execution_time as execution_time_ms,
                'ERROR: ' || SQLERRM as status;
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- QUALITY METRICS AND REPORTING
-- =============================================================================

-- Calculate quality metrics for all tables
CREATE OR REPLACE FUNCTION data_quality.calculate_quality_metrics()
RETURNS VOID AS $$
DECLARE
    table_name TEXT;
    total_records BIGINT;
    issues_count INTEGER;
BEGIN
    -- Calculate metrics for citizens table
    SELECT COUNT(*) INTO total_records FROM civics.citizens;

    SELECT COUNT(*) INTO issues_count
    FROM data_quality.quality_issues
    WHERE table_name = 'civics.citizens'
    AND detected_at >= CURRENT_DATE
    AND resolved_at IS NULL;

    INSERT INTO data_quality.quality_metrics (
        table_name, total_records, valid_records, invalid_records, issues_found
    ) VALUES (
        'civics.citizens',
        total_records,
        total_records - issues_count,
        issues_count,
        issues_count
    ) ON CONFLICT (metric_date, table_name) DO UPDATE SET
        total_records = EXCLUDED.total_records,
        valid_records = EXCLUDED.valid_records,
        invalid_records = EXCLUDED.invalid_records,
        issues_found = EXCLUDED.issues_found,
        calculated_at = NOW();

    -- Similar calculations for other tables
    -- Permit applications
    SELECT COUNT(*) INTO total_records FROM civics.permit_applications;
    SELECT COUNT(*) INTO issues_count
    FROM data_quality.quality_issues
    WHERE table_name = 'civics.permit_applications'
    AND detected_at >= CURRENT_DATE
    AND resolved_at IS NULL;

    INSERT INTO data_quality.quality_metrics (
        table_name, total_records, valid_records, invalid_records, issues_found
    ) VALUES (
        'civics.permit_applications', total_records, total_records - issues_count, issues_count, issues_count
    ) ON CONFLICT (metric_date, table_name) DO UPDATE SET
        total_records = EXCLUDED.total_records,
        valid_records = EXCLUDED.valid_records,
        invalid_records = EXCLUDED.invalid_records,
        issues_found = EXCLUDED.issues_found,
        calculated_at = NOW();

    -- Orders
    SELECT COUNT(*) INTO total_records FROM commerce.orders;
    SELECT COUNT(*) INTO issues_count
    FROM data_quality.quality_issues
    WHERE table_name = 'commerce.orders'
    AND detected_at >= CURRENT_DATE
    AND resolved_at IS NULL;

    INSERT INTO data_quality.quality_metrics (
        table_name, total_records, valid_records, invalid_records, issues_found
    ) VALUES (
        'commerce.orders', total_records, total_records - issues_count, issues_count, issues_count
    ) ON CONFLICT (metric_date, table_name) DO UPDATE SET
        total_records = EXCLUDED.total_records,
        valid_records = EXCLUDED.valid_records,
        invalid_records = EXCLUDED.invalid_records,
        issues_found = EXCLUDED.issues_found,
        calculated_at = NOW();

    -- Merchants
    SELECT COUNT(*) INTO total_records FROM commerce.merchants;
    SELECT COUNT(*) INTO issues_count
    FROM data_quality.quality_issues
    WHERE table_name = 'commerce.merchants'
    AND detected_at >= CURRENT_DATE
    AND resolved_at IS NULL;

    INSERT INTO data_quality.quality_metrics (
        table_name, total_records, valid_records, invalid_records, issues_found
    ) VALUES (
        'commerce.merchants', total_records, total_records - issues_count, issues_count, issues_count
    ) ON CONFLICT (metric_date, table_name) DO UPDATE SET
        total_records = EXCLUDED.total_records,
        valid_records = EXCLUDED.valid_records,
        invalid_records = EXCLUDED.invalid_records,
        issues_found = EXCLUDED.issues_found,
        calculated_at = NOW();
END;
$$ LANGUAGE plpgsql;

-- Generate data quality report
CREATE OR REPLACE FUNCTION data_quality.generate_quality_report()
RETURNS TABLE(
    report_section TEXT,
    metric_name TEXT,
    metric_value TEXT,
    status_indicator TEXT,
    details TEXT
) AS $$
BEGIN
    -- Overall quality summary
    RETURN QUERY
    SELECT
        'Quality Summary'::TEXT as report_section,
        'Total Issues Found'::TEXT as metric_name,
        COUNT(*)::TEXT as metric_value,
        CASE
            WHEN COUNT(*) = 0 THEN 'EXCELLENT'
            WHEN COUNT(*) < 10 THEN 'GOOD'
            WHEN COUNT(*) < 50 THEN 'NEEDS_ATTENTION'
            ELSE 'CRITICAL'
        END as status_indicator,
        'Issues detected in last 24 hours' as details
    FROM data_quality.quality_issues
    WHERE detected_at >= NOW() - INTERVAL '24 hours'
    AND resolved_at IS NULL;

    -- Issues by severity
    RETURN QUERY
    SELECT
        'Issues by Severity'::TEXT,
        UPPER(severity) || ' Issues' as metric_name,
        COUNT(*)::TEXT,
        CASE severity
            WHEN 'critical' THEN 'CRITICAL'
            WHEN 'high' THEN 'WARNING'
            ELSE 'INFO'
        END,
        'Severity level: ' || severity
    FROM data_quality.quality_issues
    WHERE detected_at >= NOW() - INTERVAL '24 hours'
    AND resolved_at IS NULL
    GROUP BY severity
    ORDER BY
        CASE severity
            WHEN 'critical' THEN 1
            WHEN 'high' THEN 2
            WHEN 'medium' THEN 3
            WHEN 'low' THEN 4
        END;

    -- Issues by type
    RETURN QUERY
    SELECT
        'Issues by Type'::TEXT,
        REPLACE(UPPER(issue_type), '_', ' ') as metric_name,
        COUNT(*)::TEXT,
        'INFO'::TEXT,
        'Issue type: ' || issue_type
    FROM data_quality.quality_issues
    WHERE detected_at >= NOW() - INTERVAL '24 hours'
    AND resolved_at IS NULL
    GROUP BY issue_type
    ORDER BY COUNT(*) DESC;

    -- Table quality scores
    RETURN QUERY
    SELECT
        'Table Quality Scores'::TEXT,
        table_name,
        COALESCE(quality_score::TEXT || '%', 'No data'),
        CASE
            WHEN quality_score >= 95 THEN 'EXCELLENT'
            WHEN quality_score >= 85 THEN 'GOOD'
            WHEN quality_score >= 70 THEN 'NEEDS_ATTENTION'
            ELSE 'CRITICAL'
        END,
        'Records: ' || COALESCE(total_records::TEXT, '0') || ', Issues: ' || COALESCE(issues_found::TEXT, '0')
    FROM data_quality.quality_metrics
    WHERE metric_date = CURRENT_DATE
    ORDER BY quality_score DESC NULLS LAST;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- AUTO-FIX FUNCTIONS
-- =============================================================================

-- Auto-fix simple data quality issues
CREATE OR REPLACE FUNCTION data_quality.auto_fix_issues()
RETURNS TABLE(
    issue_id BIGINT,
    check_name TEXT,
    fix_action TEXT,
    fix_status TEXT
) AS $$
DECLARE
    issue_record RECORD;
BEGIN
    -- Fix standardizable phone formats
    FOR issue_record IN
        SELECT qi.issue_id, qi.record_id
        FROM data_quality.quality_issues qi
        WHERE qi.check_name = 'citizen_phone_format'
        AND qi.resolved_at IS NULL
        AND qi.auto_fixable = FALSE
    LOOP
        -- Attempt to standardize phone number
        UPDATE civics.citizens
        SET phone = regexp_replace(
            regexp_replace(phone, '[^0-9]', '', 'g'),
            '^(\d{3})(\d{3})(\d{4})$',
            '\1-\2-\3'
        )
        WHERE citizen_id = issue_record.record_id::BIGINT
        AND length(regexp_replace(phone, '[^0-9]', '', 'g')) = 10;

        IF FOUND THEN
            UPDATE data_quality.quality_issues
            SET resolved_at = NOW(),
                resolution_notes = 'Auto-fixed: standardized phone format',
                auto_fixable = TRUE
            WHERE issue_id = issue_record.issue_id;

            RETURN QUERY SELECT
                issue_record.issue_id,
                'citizen_phone_format'::TEXT,
                'Standardized phone format'::TEXT,
                'SUCCESS'::TEXT;
        END IF;
    END LOOP;

    -- Fix missing approval dates for old approved permits
    FOR issue_record IN
        SELECT qi.issue_id, qi.record_id
        FROM data_quality.quality_issues qi
        WHERE qi.check_name = 'permit_missing_approval_date'
        AND qi.resolved_at IS NULL
    LOOP
        UPDATE civics.permit_applications
        SET approved_date = COALESCE(last_updated, submitted_date)
        WHERE application_id = issue_record.record_id::BIGINT;

        IF FOUND THEN
            UPDATE data_quality.quality_issues
            SET resolved_at = NOW(),
                resolution_notes = 'Auto-fixed: set approval date to last updated date'
            WHERE issue_id = issue_record.issue_id;

            RETURN QUERY SELECT
                issue_record.issue_id,
                'permit_missing_approval_date'::TEXT,
                'Set approval date'::TEXT,
                'SUCCESS'::TEXT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SCHEDULED QUALITY MONITORING
-- =============================================================================

-- Daily quality assessment
CREATE OR REPLACE FUNCTION data_quality.daily_quality_assessment()
RETURNS TEXT AS $$
DECLARE
    total_issues INTEGER;
    critical_issues INTEGER;
    result_msg TEXT;
BEGIN
    -- Run all quality checks
    PERFORM data_quality.run_all_quality_checks();

    -- Calculate metrics
    PERFORM data_quality.calculate_quality_metrics();

    -- Get issue counts
    SELECT COUNT(*) INTO total_issues
    FROM data_quality.quality_issues
    WHERE detected_at >= CURRENT_DATE;

    SELECT COUNT(*) INTO critical_issues
    FROM data_quality.quality_issues
    WHERE detected_at >= CURRENT_DATE
    AND severity = 'critical';

    -- Attempt auto-fixes
    PERFORM data_quality.auto_fix_issues();

    -- Build result message
    result_msg := 'Daily Quality Assessment Complete' || E'\n';
    result_msg := result_msg || 'Total issues found: ' || total_issues || E'\n';
    result_msg := result_msg || 'Critical issues: ' || critical_issues || E'\n';

    -- Send notification if critical issues found
    IF critical_issues > 0 THEN
        -- Note: This would require implementing the messaging system
        RAISE NOTICE 'CRITICAL DATA QUALITY ISSUES FOUND: % total issues, % critical', total_issues, critical_issues;
    END IF;

    RETURN result_msg;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- UTILITY VIEWS
-- =============================================================================

-- Current quality status view
CREATE OR REPLACE VIEW data_quality.current_quality_status AS
SELECT
    table_name,
    quality_score,
    total_records,
    issues_found,
    CASE
        WHEN quality_score >= 95 THEN 'EXCELLENT'
        WHEN quality_score >= 85 THEN 'GOOD'
        WHEN quality_score >= 70 THEN 'NEEDS_ATTENTION'
        ELSE 'CRITICAL'
    END as quality_grade,
    calculated_at
FROM data_quality.quality_metrics
WHERE metric_date = CURRENT_DATE
ORDER BY quality_score DESC;

-- Recent issues summary view
CREATE OR REPLACE VIEW data_quality.recent_issues_summary AS
SELECT
    issue_type,
    severity,
    COUNT(*) as issue_count,
    COUNT(*) FILTER (WHERE resolved_at IS NOT NULL) as resolved_count,
    MIN(detected_at) as first_detected,
    MAX(detected_at) as last_detected
FROM data_quality.quality_issues
WHERE detected_at >= NOW() - INTERVAL '7 days'
GROUP BY issue_type, severity
ORDER BY
    CASE severity
        WHEN 'critical' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
    END, issue_count DESC;

-- =============================================================================
-- EXAMPLE USAGE
-- =============================================================================

/*
-- Run all quality checks
SELECT * FROM data_quality.run_all_quality_checks();

-- Generate quality report
SELECT * FROM data_quality.generate_quality_report();

-- Auto-fix issues
SELECT * FROM data_quality.auto_fix_issues();

-- Daily assessment
SELECT data_quality.daily_quality_assessment();

-- View current status
SELECT * FROM data_quality.current_quality_status;

-- View recent issues
SELECT * FROM data_quality.recent_issues_summary;

-- Manual check for specific table
SELECT data_quality.check_citizen_constraints();
*/

-- =============================================================================
-- INDEX CREATION FOR PERFORMANCE
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_quality_issues_detected_at ON data_quality.quality_issues(detected_at);
CREATE INDEX IF NOT EXISTS idx_quality_issues_table_name ON data_quality.quality_issues(table_name);
CREATE INDEX IF NOT EXISTS idx_quality_issues_severity ON data_quality.quality_issues(severity);
CREATE INDEX IF NOT EXISTS idx_quality_issues_resolved ON data_quality.quality_issues(resolved_at) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_quality_metrics_date_table ON data_quality.quality_metrics(metric_date, table_name);

-- Grant permissions
GRANT USAGE ON SCHEMA data_quality TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA data_quality TO PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA data_quality TO PUBLIC;
