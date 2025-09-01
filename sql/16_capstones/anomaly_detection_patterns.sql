-- File: sql/99_capstones/anomaly_detection_patterns.sql
-- Purpose: windows + stats + outlier detection for fraud and anomaly detection

-- =============================================================================
-- ANOMALY DETECTION INFRASTRUCTURE
-- =============================================================================

-- Create schema for anomaly detection
CREATE SCHEMA IF NOT EXISTS anomaly_detection;

-- Anomaly detection models and rules
CREATE TABLE anomaly_detection.detection_rules (
    rule_id BIGSERIAL PRIMARY KEY,
    rule_name TEXT NOT NULL UNIQUE,
    rule_description TEXT,
    rule_category TEXT CHECK (rule_category IN ('statistical', 'pattern', 'behavioral', 'temporal')),
    detection_query TEXT NOT NULL,
    threshold_value NUMERIC,
    severity_level TEXT CHECK (severity_level IN ('low', 'medium', 'high', 'critical')) DEFAULT 'medium',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Detected anomalies log
CREATE TABLE anomaly_detection.anomalies_detected (
    anomaly_id BIGSERIAL PRIMARY KEY,
    rule_id BIGINT REFERENCES anomaly_detection.detection_rules(rule_id),
-- Detected anomalies log
CREATE TABLE anomaly_detection.anomalies_detected (
    anomaly_id BIGSERIAL PRIMARY KEY,
    rule_id BIGINT REFERENCES anomaly_detection.detection_rules(rule_id),
    entity_type TEXT NOT NULL, -- 'citizen', 'merchant', 'permit', 'order'
    entity_id BIGINT NOT NULL,
    anomaly_score NUMERIC,
    anomaly_details JSONB,
    detected_at TIMESTAMPTZ DEFAULT NOW(),
    investigated_at TIMESTAMPTZ,
    resolution_status TEXT CHECK (resolution_status IN ('pending', 'false_positive', 'confirmed', 'resolved')) DEFAULT 'pending',
    investigation_notes TEXT,
    INDEX (entity_type, entity_id),
    INDEX (detected_at DESC),
    INDEX (resolution_status)
);

-- Statistical baselines for anomaly detection
CREATE TABLE anomaly_detection.statistical_baselines (
    baseline_id BIGSERIAL PRIMARY KEY,
    metric_name TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    time_period TEXT, -- 'daily', 'weekly', 'monthly'
    baseline_mean NUMERIC,
    baseline_stddev NUMERIC,
    baseline_median NUMERIC,
    baseline_q1 NUMERIC,
    baseline_q3 NUMERIC,
    sample_size INTEGER,
    calculated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(metric_name, entity_type, time_period)
);

-- =============================================================================
-- STATISTICAL ANOMALY DETECTION FUNCTIONS
-- =============================================================================

-- Calculate statistical baselines
CREATE OR REPLACE FUNCTION anomaly_detection.calculate_statistical_baselines()
RETURNS VOID AS $
BEGIN
    -- Transaction amount baselines for orders
    INSERT INTO anomaly_detection.statistical_baselines (
        metric_name, entity_type, time_period, baseline_mean, baseline_stddev,
        baseline_median, baseline_q1, baseline_q3, sample_size
    )
    SELECT
        'transaction_amount',
        'order',
        'daily',
        AVG(total_amount),
        STDDEV(total_amount),
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_amount),
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY total_amount),
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_amount),
        COUNT(*)
    FROM commerce.orders
    WHERE order_date >= CURRENT_DATE - INTERVAL '90 days'
    ON CONFLICT (metric_name, entity_type, time_period)
    DO UPDATE SET
        baseline_mean = EXCLUDED.baseline_mean,
        baseline_stddev = EXCLUDED.baseline_stddev,
        baseline_median = EXCLUDED.baseline_median,
        baseline_q1 = EXCLUDED.baseline_q1,
        baseline_q3 = EXCLUDED.baseline_q3,
        sample_size = EXCLUDED.sample_size,
        calculated_at = NOW();

    -- Permit cost baselines
    INSERT INTO anomaly_detection.statistical_baselines (
        metric_name, entity_type, time_period, baseline_mean, baseline_stddev,
        baseline_median, baseline_q1, baseline_q3, sample_size
    )
    SELECT
        'permit_cost',
        'permit',
        'monthly',
        AVG(estimated_cost),
        STDDEV(estimated_cost),
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY estimated_cost),
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY estimated_cost),
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY estimated_cost),
        COUNT(*)
    FROM civics.permit_applications
    WHERE submitted_date >= CURRENT_DATE - INTERVAL '1 year'
    AND estimated_cost IS NOT NULL
    ON CONFLICT (metric_name, entity_type, time_period)
    DO UPDATE SET
        baseline_mean = EXCLUDED.baseline_mean,
        baseline_stddev = EXCLUDED.baseline_stddev,
        baseline_median = EXCLUDED.baseline_median,
        baseline_q1 = EXCLUDED.baseline_q1,
        baseline_q3 = EXCLUDED.baseline_q3,
        sample_size = EXCLUDED.sample_size,
        calculated_at = NOW();
END;
$ LANGUAGE plpgsql;

-- Detect statistical outliers using z-score and IQR methods
CREATE OR REPLACE FUNCTION anomaly_detection.detect_statistical_outliers()
RETURNS INTEGER AS $
DECLARE
    anomalies_found INTEGER := 0;
    baseline_record RECORD;
    outlier_record RECORD;
    z_score NUMERIC;
    iqr_lower NUMERIC;
    iqr_upper NUMERIC;
BEGIN
    -- Clear recent anomalies for fresh analysis
    DELETE FROM anomaly_detection.anomalies_detected
    WHERE detected_at >= CURRENT_DATE
    AND rule_id IN (SELECT rule_id FROM anomaly_detection.detection_rules WHERE rule_category = 'statistical');

    -- Check transaction amount outliers
    SELECT * INTO baseline_record
    FROM anomaly_detection.statistical_baselines
    WHERE metric_name = 'transaction_amount' AND entity_type = 'order';

    IF baseline_record IS NOT NULL THEN
        -- Calculate IQR bounds
        iqr_lower := baseline_record.baseline_q1 - 1.5 * (baseline_record.baseline_q3 - baseline_record.baseline_q1);
        iqr_upper := baseline_record.baseline_q3 + 1.5 * (baseline_record.baseline_q3 - baseline_record.baseline_q1);

        -- Find outliers using both z-score and IQR methods
        FOR outlier_record IN
            SELECT
                order_id,
                total_amount,
                ABS(total_amount - baseline_record.baseline_mean) / NULLIF(baseline_record.baseline_stddev, 0) as z_score
            FROM commerce.orders
            WHERE order_date >= CURRENT_DATE - INTERVAL '7 days'
            AND (
                -- Z-score method (> 3 standard deviations)
                ABS(total_amount - baseline_record.baseline_mean) / NULLIF(baseline_record.baseline_stddev, 0) > 3
                OR
                -- IQR method
                total_amount < iqr_lower OR total_amount > iqr_upper
            )
        LOOP
            INSERT INTO anomaly_detection.anomalies_detected (
                rule_id, entity_type, entity_id, anomaly_score, anomaly_details
            )
            SELECT
                rule_id, 'order', outlier_record.order_id, outlier_record.z_score,
                json_build_object(
                    'transaction_amount', outlier_record.total_amount,
                    'baseline_mean', baseline_record.baseline_mean,
                    'baseline_stddev', baseline_record.baseline_stddev,
                    'z_score', outlier_record.z_score,
                    'detection_method', 'statistical_outlier'
                )
            FROM anomaly_detection.detection_rules
            WHERE rule_name = 'transaction_amount_outlier';

            anomalies_found := anomalies_found + 1;
        END LOOP;
    END IF;

    RETURN anomalies_found;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- BEHAVIORAL ANOMALY DETECTION
-- =============================================================================

-- Detect unusual citizen behavior patterns
CREATE OR REPLACE FUNCTION anomaly_detection.detect_citizen_behavioral_anomalies()
RETURNS INTEGER AS $
DECLARE
    anomalies_found INTEGER := 0;
    citizen_record RECORD;
BEGIN
    -- Multiple permit applications in short time (potential fraud)
    FOR citizen_record IN
        SELECT
            citizen_id,
            COUNT(*) as permit_count,
            MIN(submitted_date) as first_permit,
            MAX(submitted_date) as last_permit,
            SUM(estimated_cost) as total_estimated_cost
        FROM civics.permit_applications
        WHERE submitted_date >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY citizen_id
        HAVING COUNT(*) >= 5 -- 5+ permits in 30 days
        OR SUM(estimated_cost) > 50000 -- High total cost
    LOOP
        INSERT INTO anomaly_detection.anomalies_detected (
            rule_id, entity_type, entity_id, anomaly_score, anomaly_details
        )
        SELECT
            rule_id, 'citizen', citizen_record.citizen_id, citizen_record.permit_count,
            json_build_object(
                'permit_count', citizen_record.permit_count,
                'total_cost', citizen_record.total_estimated_cost,
                'time_span_days', EXTRACT(days FROM citizen_record.last_permit - citizen_record.first_permit),
                'detection_reason', 'excessive_permit_activity'
            )
        FROM anomaly_detection.detection_rules
        WHERE rule_name = 'excessive_permit_applications';

        anomalies_found := anomalies_found + 1;
    END LOOP;

    -- Unusual voting patterns
    FOR citizen_record IN
        SELECT
            vr.citizen_id,
            COUNT(DISTINCT vr.election_date) as elections_voted,
            COUNT(DISTINCT vr.vote_method) as different_methods,
            c.registered_date,
            MIN(vr.election_date) as first_vote
        FROM civics.voting_records vr
        JOIN civics.citizens c ON vr.citizen_id = c.citizen_id
        WHERE vr.election_date >= CURRENT_DATE - INTERVAL '2 years'
        GROUP BY vr.citizen_id, c.registered_date
        HAVING
            -- Voted immediately after registration (suspicious)
            MIN(vr.election_date) - c.registered_date < INTERVAL '7 days'
            OR
            -- Used multiple voting methods (potential identity issues)
            COUNT(DISTINCT vr.vote_method) > 2
    LOOP
        INSERT INTO anomaly_detection.anomalies_detected (
            rule_id, entity_type, entity_id, anomaly_score, anomaly_details
        )
        SELECT
            rule_id, 'citizen', citizen_record.citizen_id,
            CASE WHEN citizen_record.different_methods > 2 THEN 3 ELSE 2 END,
            json_build_object(
                'elections_voted', citizen_record.elections_voted,
                'voting_methods_used', citizen_record.different_methods,
                'days_registration_to_first_vote', EXTRACT(days FROM citizen_record.first_vote - citizen_record.registered_date),
                'detection_reason', 'suspicious_voting_pattern'
            )
        FROM anomaly_detection.detection_rules
        WHERE rule_name = 'suspicious_voting_behavior';

        anomalies_found := anomalies_found + 1;
    END LOOP;

    RETURN anomalies_found;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- TEMPORAL PATTERN ANOMALY DETECTION
-- =============================================================================

-- Detect time-based anomalies using window functions
CREATE OR REPLACE FUNCTION anomaly_detection.detect_temporal_anomalies()
RETURNS INTEGER AS $
DECLARE
    anomalies_found INTEGER := 0;
    temporal_record RECORD;
BEGIN
    -- Detect unusual time patterns in orders (off-hours activity)
    FOR temporal_record IN
        WITH hourly_patterns AS (
            SELECT
                merchant_id,
                EXTRACT(hour FROM order_date) as order_hour,
                COUNT(*) as order_count,
                -- Calculate merchant's typical busy hours
                AVG(COUNT(*)) OVER (PARTITION BY merchant_id) as avg_hourly_orders,
                STDDEV(COUNT(*)) OVER (PARTITION BY merchant_id) as stddev_hourly_orders
            FROM commerce.orders
            WHERE order_date >= CURRENT_DATE - INTERVAL '30 days'
            GROUP BY merchant_id, EXTRACT(hour FROM order_date)
        )
        SELECT
            merchant_id,
            order_hour,
            order_count,
            avg_hourly_orders,
            (order_count - avg_hourly_orders) / NULLIF(stddev_hourly_orders, 0) as z_score
        FROM hourly_patterns
        WHERE
            -- Unusual activity (> 3 std deviations from merchant's norm)
            ABS((order_count - avg_hourly_orders) / NULLIF(stddev_hourly_orders, 0)) > 3
            AND
            -- During off-hours (midnight to 6 AM)
            order_hour BETWEEN 0 AND 6
    LOOP
        INSERT INTO anomaly_detection.anomalies_detected (
            rule_id, entity_type, entity_id, anomaly_score, anomaly_details
        )
        SELECT
            rule_id, 'merchant', temporal_record.merchant_id, ABS(temporal_record.z_score),
            json_build_object(
                'unusual_hour', temporal_record.order_hour,
                'order_count', temporal_record.order_count,
                'typical_hourly_average', temporal_record.avg_hourly_orders,
                'z_score', temporal_record.z_score,
                'detection_reason', 'off_hours_activity_spike'
            )
        FROM anomaly_detection.detection_rules
        WHERE rule_name = 'unusual_time_patterns';

        anomalies_found := anomalies_found + 1;
    END LOOP;

    -- Detect rapid sequence patterns (potential automated activity)
    FOR temporal_record IN
        WITH order_sequences AS (
            SELECT
                merchant_id,
                customer_citizen_id,
                order_date,
                LAG(order_date) OVER (PARTITION BY merchant_id, customer_citizen_id ORDER BY order_date) as prev_order,
                EXTRACT(seconds FROM order_date - LAG(order_date) OVER (PARTITION BY merchant_id, customer_citizen_id ORDER BY order_date)) as seconds_between
            FROM commerce.orders
            WHERE order_date >= CURRENT_DATE - INTERVAL '7 days'
        ),
        rapid_sequences AS (
            SELECT
                merchant_id,
                customer_citizen_id,
                COUNT(*) as rapid_order_count,
                MIN(seconds_between) as min_seconds_between,
                AVG(seconds_between) as avg_seconds_between
            FROM order_sequences
            WHERE seconds_between IS NOT NULL
            AND seconds_between < 60 -- Orders within 60 seconds
            GROUP BY merchant_id, customer_citizen_id
            HAVING COUNT(*) >= 3 -- At least 3 rapid orders
        )
        SELECT * FROM rapid_sequences
    LOOP
        INSERT INTO anomaly_detection.anomalies_detected (
            rule_id, entity_type, entity_id, anomaly_score, anomaly_details
        )
        SELECT
            rule_id, 'order', temporal_record.customer_citizen_id, temporal_record.rapid_order_count,
            json_build_object(
                'merchant_id', temporal_record.merchant_id,
                'rapid_order_count', temporal_record.rapid_order_count,
                'min_seconds_between', temporal_record.min_seconds_between,
                'avg_seconds_between', temporal_record.avg_seconds_between,
                'detection_reason', 'rapid_sequence_ordering'
            )
        FROM anomaly_detection.detection_rules
        WHERE rule_name = 'rapid_sequence_activity';

        anomalies_found := anomalies_found + 1;
    END LOOP;

    RETURN anomalies_found;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- NETWORK ANALYSIS FOR FRAUD DETECTION
-- =============================================================================

-- Detect connected suspicious activity
CREATE OR REPLACE FUNCTION anomaly_detection.detect_network_anomalies()
RETURNS INTEGER AS $
DECLARE
    anomalies_found INTEGER := 0;
    network_record RECORD;
BEGIN
    -- Detect address-based connections (multiple citizens at same address)
    FOR network_record IN
        SELECT
            street_address,
            city,
            COUNT(DISTINCT citizen_id) as citizen_count,
            ARRAY_AGG(citizen_id ORDER BY citizen_id) as citizen_ids,
            COUNT(DISTINCT email) as unique_emails,
            COUNT(DISTINCT phone) as unique_phones
        FROM civics.citizens
        WHERE status = 'active'
        AND street_address IS NOT NULL
        GROUP BY street_address, city
        HAVING COUNT(DISTINCT citizen_id) > 10 -- More than 10 citizens at one address
        OR (COUNT(DISTINCT citizen_id) > 3 AND COUNT(DISTINCT email) = 1) -- Multiple citizens, same email
    LOOP
        -- Create anomaly for each citizen in the suspicious network
        INSERT INTO anomaly_detection.anomalies_detected (
            rule_id, entity_type, entity_id, anomaly_score, anomaly_details
        )
        SELECT
            dr.rule_id, 'citizen', unnest(network_record.citizen_ids),
            network_record.citizen_count,
            json_build_object(
                'address', network_record.street_address,
                'total_citizens_at_address', network_record.citizen_count,
                'unique_emails', network_record.unique_emails,
                'unique_phones', network_record.unique_phones,
                'detection_reason', 'suspicious_address_clustering'
            )
        FROM anomaly_detection.detection_rules dr
        WHERE dr.rule_name = 'address_clustering_anomaly';

        anomalies_found := anomalies_found + array_length(network_record.citizen_ids, 1);
    END LOOP;

    -- Detect merchant-customer relationship anomalies
    FOR network_record IN
        WITH merchant_customer_patterns AS (
            SELECT
                o.merchant_id,
                o.customer_citizen_id,
                COUNT(*) as order_count,
                SUM(o.total_amount) as total_spent,
                MIN(o.order_date) as first_order,
                MAX(o.order_date) as last_order,
                -- Check if customer and merchant owner are same person
                CASE WHEN o.customer_citizen_id = m.owner_citizen_id THEN TRUE ELSE FALSE END as self_dealing
            FROM commerce.orders o
            JOIN commerce.merchants m ON o.merchant_id = m.merchant_id
            WHERE o.order_date >= CURRENT_DATE - INTERVAL '90 days'
            GROUP BY o.merchant_id, o.customer_citizen_id, m.owner_citizen_id
        )
        SELECT
            merchant_id,
            customer_citizen_id,
            order_count,
            total_spent,
            self_dealing
        FROM merchant_customer_patterns
        WHERE
            self_dealing = TRUE -- Self-dealing detected
            OR
            (order_count > 20 AND total_spent > 10000) -- Unusually high activity
    LOOP
        INSERT INTO anomaly_detection.anomalies_detected (
            rule_id, entity_type, entity_id, anomaly_score, anomaly_details
        )
        SELECT
            rule_id, 'merchant', network_record.merchant_id,
            CASE WHEN network_record.self_dealing THEN 5 ELSE 3 END,
            json_build_object(
                'customer_citizen_id', network_record.customer_citizen_id,
                'order_count', network_record.order_count,
                'total_spent', network_record.total_spent,
                'self_dealing', network_record.self_dealing,
                'detection_reason', CASE WHEN network_record.self_dealing THEN 'self_dealing' ELSE 'excessive_customer_activity' END
            )
        FROM anomaly_detection.detection_rules
        WHERE rule_name = 'merchant_customer_anomaly';

        anomalies_found := anomalies_found + 1;
    END LOOP;

    RETURN anomalies_found;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- COMPREHENSIVE ANOMALY DETECTION RUNNER
-- =============================================================================

-- Run all anomaly detection algorithms
CREATE OR REPLACE FUNCTION anomaly_detection.run_full_anomaly_scan()
RETURNS TABLE(
    detection_category TEXT,
    anomalies_found INTEGER,
    execution_time_ms INTEGER,
    status TEXT
) AS $
DECLARE
    start_time TIMESTAMPTZ;
    anomaly_count INTEGER;
    execution_time INTEGER;
BEGIN
    -- Update statistical baselines first
    start_time := clock_timestamp();
    PERFORM anomaly_detection.calculate_statistical_baselines();
    execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

    RETURN QUERY SELECT
        'Statistical Baselines Update'::TEXT,
        0,
        execution_time,
        'COMPLETED'::TEXT;

    -- Statistical outlier detection
    start_time := clock_timestamp();
    anomaly_count := anomaly_detection.detect_statistical_outliers();
    execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

    RETURN QUERY SELECT
        'Statistical Outliers'::TEXT,
        anomaly_count,
        execution_time,
        CASE WHEN anomaly_count > 0 THEN 'ANOMALIES_FOUND' ELSE 'CLEAN' END;

    -- Behavioral anomaly detection
    start_time := clock_timestamp();
    anomaly_count := anomaly_detection.detect_citizen_behavioral_anomalies();
    execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

    RETURN QUERY SELECT
        'Behavioral Anomalies'::TEXT,
        anomaly_count,
        execution_time,
        CASE WHEN anomaly_count > 0 THEN 'ANOMALIES_FOUND' ELSE 'CLEAN' END;

    -- Temporal pattern detection
    start_time := clock_timestamp();
    anomaly_count := anomaly_detection.detect_temporal_anomalies();
    execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

    RETURN QUERY SELECT
        'Temporal Patterns'::TEXT,
        anomaly_count,
        execution_time,
        CASE WHEN anomaly_count > 0 THEN 'ANOMALIES_FOUND' ELSE 'CLEAN' END;

    -- Network analysis
    start_time := clock_timestamp();
    anomaly_count := anomaly_detection.detect_network_anomalies();
    execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

    RETURN QUERY SELECT
        'Network Analysis'::TEXT,
        anomaly_count,
        execution_time,
        CASE WHEN anomaly_count > 0 THEN 'ANOMALIES_FOUND' ELSE 'CLEAN' END;

    -- Send summary notification
    PERFORM messaging.notify_channel(
        'anomaly_detection',
        'full_scan_completed',
        json_build_object(
            'total_anomalies', (SELECT COUNT(*) FROM anomaly_detection.anomalies_detected WHERE detected_at >= CURRENT_DATE),
            'scan_timestamp', NOW()
        ),
        'anomaly_detection_system'
    );
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- ANOMALY INVESTIGATION AND REPORTING
-- =============================================================================

-- Generate anomaly investigation report
CREATE OR REPLACE FUNCTION anomaly_detection.generate_anomaly_report(
    days_back INTEGER DEFAULT 7
)
RETURNS TABLE(
    report_section TEXT,
    anomaly_count INTEGER,
    severity_level TEXT,
    details TEXT
) AS $
BEGIN
    -- Summary by severity
    RETURN QUERY
    SELECT
        'Severity Summary'::TEXT as report_section,
        COUNT(*)::INTEGER as anomaly_count,
        COALESCE(dr.severity_level, 'unknown') as severity_level,
        'Anomalies detected in last ' || days_back || ' days'
    FROM anomaly_detection.anomalies_detected ad
    LEFT JOIN anomaly_detection.detection_rules dr ON ad.rule_id = dr.rule_id
    WHERE ad.detected_at >= CURRENT_DATE - (days_back || ' days')::INTERVAL
    GROUP BY dr.severity_level
    ORDER BY
        CASE dr.severity_level
            WHEN 'critical' THEN 1
            WHEN 'high' THEN 2
            WHEN 'medium' THEN 3
            WHEN 'low' THEN 4
            ELSE 5
        END;

    -- Summary by entity type
    RETURN QUERY
    SELECT
        'Entity Type Summary'::TEXT,
        COUNT(*)::INTEGER,
        entity_type,
        'Anomalies by entity type'
    FROM anomaly_detection.anomalies_detected
    WHERE detected_at >= CURRENT_DATE - (days_back || ' days')::INTERVAL
    GROUP BY entity_type
    ORDER BY COUNT(*) DESC;

    -- Pending investigations
    RETURN QUERY
    SELECT
        'Investigation Status'::TEXT,
        COUNT(*)::INTEGER,
        resolution_status,
        'Current investigation status'
    FROM anomaly_detection.anomalies_detected
    WHERE detected_at >= CURRENT_DATE - (days_back || ' days')::INTERVAL
    GROUP BY resolution_status
    ORDER BY COUNT(*) DESC;

    -- Top anomaly patterns
    RETURN QUERY
    SELECT
        'Top Detection Rules'::TEXT,
        COUNT(*)::INTEGER,
        dr.rule_name,
        'Most frequently triggered detection rules'
    FROM anomaly_detection.anomalies_detected ad
    JOIN anomaly_detection.detection_rules dr ON ad.rule_id = dr.rule_id
    WHERE ad.detected_at >= CURRENT_DATE - (days_back || ' days')::INTERVAL
    GROUP BY dr.rule_name
    ORDER BY COUNT(*) DESC
    LIMIT 10;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- SETUP AND INITIALIZATION
-- =============================================================================

-- Initialize anomaly detection rules
CREATE OR REPLACE FUNCTION anomaly_detection.setup_detection_rules()
RETURNS TEXT AS $
DECLARE
    rules_created INTEGER := 0;
BEGIN
    -- Statistical outlier rules
    INSERT INTO anomaly_detection.detection_rules (
        rule_name, rule_description, rule_category, detection_query,
        threshold_value, severity_level
    ) VALUES
    ('transaction_amount_outlier', 'Detects transactions with unusual amounts', 'statistical',
     'Statistical analysis of transaction amounts', 3.0, 'medium'),
    ('permit_cost_outlier', 'Detects permits with unusual cost estimates', 'statistical',
     'Statistical analysis of permit costs', 3.0, 'medium')
    ON CONFLICT (rule_name) DO NOTHING;

    rules_created := rules_created + 2;

    -- Behavioral anomaly rules
    INSERT INTO anomaly_detection.detection_rules (
        rule_name, rule_description, rule_category, detection_query,
        threshold_value, severity_level
    ) VALUES
    ('excessive_permit_applications', 'Multiple permit applications in short time', 'behavioral',
     'Count of permits per citizen per time period', 5.0, 'high'),
    ('suspicious_voting_behavior', 'Unusual voting patterns', 'behavioral',
     'Analysis of voting behavior patterns', 2.0, 'medium')
    ON CONFLICT (rule_name) DO NOTHING;

    rules_created := rules_created + 2;

    -- Temporal pattern rules
    INSERT INTO anomaly_detection.detection_rules (
        rule_name, rule_description, rule_category, detection_query,
        threshold_value, severity_level
    ) VALUES
    ('unusual_time_patterns', 'Activity during unusual hours', 'temporal',
     'Time-based activity pattern analysis', 3.0, 'medium'),
    ('rapid_sequence_activity', 'Rapid sequence of actions', 'temporal',
     'Detection of automated/bot-like behavior', 3.0, 'high')
    ON CONFLICT (rule_name) DO NOTHING;

    rules_created := rules_created + 2;

    -- Network analysis rules
    INSERT INTO anomaly_detection.detection_rules (
        rule_name, rule_description, rule_category, detection_query,
        threshold_value, severity_level
    ) VALUES
    ('address_clustering_anomaly', 'Multiple entities at same address', 'pattern',
     'Network analysis of address connections', 10.0, 'high'),
    ('merchant_customer_anomaly', 'Suspicious merchant-customer relationships', 'pattern',
     'Analysis of trading relationships', 3.0, 'critical')
    ON CONFLICT (rule_name) DO NOTHING;

    rules_created := rules_created + 2;

    RETURN 'Initialized ' || rules_created || ' anomaly detection rules';
END;
$ LANGUAGE plpgsql;
