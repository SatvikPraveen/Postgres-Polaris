-- File: sql/99_capstones/real_time_monitoring_views.sql
-- Purpose: LISTEN/NOTIFY + live dashboards for real-time city monitoring

-- =============================================================================
-- REAL-TIME MONITORING INFRASTRUCTURE
-- =============================================================================

-- Create schema for real-time monitoring
CREATE SCHEMA IF NOT EXISTS realtime_monitoring;

-- Real-time event streams
CREATE TABLE realtime_monitoring.event_streams (
    stream_id BIGSERIAL PRIMARY KEY,
    stream_name TEXT NOT NULL UNIQUE,
    stream_description TEXT,
    event_types TEXT[], -- Array of event types this stream handles
    is_active BOOLEAN DEFAULT TRUE,
    retention_hours INTEGER DEFAULT 24, -- How long to keep events
    max_events_per_minute INTEGER DEFAULT 1000, -- Rate limiting
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Live events for real-time processing
CREATE TABLE realtime_monitoring.live_events (
    event_id BIGSERIAL PRIMARY KEY,
    stream_name TEXT NOT NULL,
    event_type TEXT NOT NULL,
    event_data JSONB NOT NULL,
    event_timestamp TIMESTAMPTZ DEFAULT NOW(),
    processed BOOLEAN DEFAULT FALSE,
    processing_notes TEXT,
    INDEX (stream_name, event_timestamp DESC),
    INDEX (event_type, event_timestamp DESC),
    INDEX (processed, event_timestamp DESC)
);

-- Real-time metrics aggregates
CREATE TABLE realtime_monitoring.metrics_snapshots (
    snapshot_id BIGSERIAL PRIMARY KEY,
    metric_category TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    metric_value NUMERIC,
    metric_metadata JSONB,
    snapshot_timestamp TIMESTAMPTZ DEFAULT NOW(),
    INDEX (metric_category, snapshot_timestamp DESC),
    INDEX (metric_name, snapshot_timestamp DESC)
);

-- Dashboard subscriptions for real-time updates
CREATE TABLE realtime_monitoring.dashboard_subscriptions (
    subscription_id BIGSERIAL PRIMARY KEY,
    dashboard_name TEXT NOT NULL,
    user_identifier TEXT, -- Session ID or user ID
    subscribed_metrics TEXT[], -- Array of metric names to watch
    notification_channel TEXT, -- NOTIFY channel to use
    subscription_filters JSONB, -- Additional filtering criteria
    last_activity TIMESTAMPTZ DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE
);

-- =============================================================================
-- REAL-TIME EVENT PROCESSING FUNCTIONS
-- =============================================================================

-- Process incoming real-time events
CREATE OR REPLACE FUNCTION realtime_monitoring.process_live_event(
    stream_name TEXT,
    event_type TEXT,
    event_data JSONB
)
RETURNS BIGINT AS $$
DECLARE
    event_id BIGINT;
    stream_config RECORD;
    current_rate INTEGER;
    notification_payload JSONB;
BEGIN
    -- Check if stream exists and is active
    SELECT * INTO stream_config
    FROM realtime_monitoring.event_streams
    WHERE realtime_monitoring.event_streams.stream_name = process_live_event.stream_name
    AND is_active = TRUE;

    IF stream_config IS NULL THEN
        RAISE EXCEPTION 'Stream % not found or inactive', stream_name;
    END IF;

    -- Check event type is supported
    IF NOT (event_type = ANY(stream_config.event_types)) THEN
        RAISE EXCEPTION 'Event type % not supported by stream %', event_type, stream_name;
    END IF;

    -- Check rate limiting
    SELECT COUNT(*) INTO current_rate
    FROM realtime_monitoring.live_events
    WHERE realtime_monitoring.live_events.stream_name = process_live_event.stream_name
    AND event_timestamp >= NOW() - INTERVAL '1 minute';

    IF current_rate >= stream_config.max_events_per_minute THEN
        RAISE EXCEPTION 'Rate limit exceeded for stream %', stream_name;
    END IF;

    -- Insert event
    INSERT INTO realtime_monitoring.live_events (stream_name, event_type, event_data)
    VALUES (stream_name, event_type, event_data)
    RETURNING live_events.event_id INTO event_id;

    -- Build notification payload
    notification_payload := json_build_object(
        'event_id', event_id,
        'stream_name', stream_name,
        'event_type', event_type,
        'event_data', event_data,
        'timestamp', NOW()
    );

    -- Send real-time notifications
    PERFORM pg_notify('realtime_events', notification_payload::TEXT);
    PERFORM pg_notify('stream_' || stream_name, notification_payload::TEXT);
    PERFORM pg_notify('event_' || event_type, notification_payload::TEXT);

    -- Process specific event types
    CASE event_type
        WHEN 'citizen_registration' THEN
            PERFORM realtime_monitoring.update_population_metrics();
        WHEN 'permit_application' THEN
            PERFORM realtime_monitoring.update_permit_metrics();
        WHEN 'order_placed' THEN
            PERFORM realtime_monitoring.update_commerce_metrics();
        WHEN 'system_alert' THEN
            PERFORM realtime_monitoring.handle_system_alert(event_data);
        WHEN 'quality_issue' THEN
            PERFORM realtime_monitoring.handle_quality_alert(event_data);
        ELSE
            -- Generic event processing
            NULL;
    END CASE;

    RETURN event_id;
END;
$ LANGUAGE plpgsql;

-- Update population metrics in real-time
CREATE OR REPLACE FUNCTION realtime_monitoring.update_population_metrics()
RETURNS VOID AS $
DECLARE
    active_count INTEGER;
    new_registrations_today INTEGER;
    snapshot_data JSONB;
BEGIN
    -- Calculate current metrics
    SELECT COUNT(*) INTO active_count
    FROM civics.citizens WHERE status = 'active';

    SELECT COUNT(*) INTO new_registrations_today
    FROM civics.citizens WHERE registered_date = CURRENT_DATE;

    snapshot_data := json_build_object(
        'active_citizens', active_count,
        'new_today', new_registrations_today,
        'updated_at', NOW()
    );

    -- Store snapshot
    INSERT INTO realtime_monitoring.metrics_snapshots (
        metric_category, metric_name, metric_value, metric_metadata
    ) VALUES (
        'population', 'active_citizens', active_count, snapshot_data
    );

    -- Send live update
    PERFORM pg_notify('population_metrics', snapshot_data::TEXT);
END;
$ LANGUAGE plpgsql;

-- Update permit processing metrics
CREATE OR REPLACE FUNCTION realtime_monitoring.update_permit_metrics()
RETURNS VOID AS $
DECLARE
    pending_count INTEGER;
    processed_today INTEGER;
    avg_processing_time NUMERIC;
    snapshot_data JSONB;
BEGIN
    SELECT COUNT(*) INTO pending_count
    FROM civics.permit_applications WHERE status = 'pending';

    SELECT COUNT(*) INTO processed_today
    FROM civics.permit_applications
    WHERE approved_date = CURRENT_DATE OR (status = 'rejected' AND last_updated::DATE = CURRENT_DATE);

    SELECT AVG(EXTRACT(days FROM (approved_date - submitted_date))) INTO avg_processing_time
    FROM civics.permit_applications
    WHERE approved_date >= CURRENT_DATE - INTERVAL '30 days';

    snapshot_data := json_build_object(
        'pending_permits', pending_count,
        'processed_today', processed_today,
        'avg_processing_days', ROUND(avg_processing_time, 1),
        'updated_at', NOW()
    );

    INSERT INTO realtime_monitoring.metrics_snapshots (
        metric_category, metric_name, metric_value, metric_metadata
    ) VALUES (
        'permits', 'pending_permits', pending_count, snapshot_data
    );

    PERFORM pg_notify('permit_metrics', snapshot_data::TEXT);
END;
$ LANGUAGE plpgsql;

-- Update commerce metrics in real-time
CREATE OR REPLACE FUNCTION realtime_monitoring.update_commerce_metrics()
RETURNS VOID AS $
DECLARE
    daily_revenue NUMERIC;
    daily_orders INTEGER;
    active_merchants INTEGER;
    snapshot_data JSONB;
BEGIN
    SELECT COALESCE(SUM(total_amount), 0), COUNT(*)
    INTO daily_revenue, daily_orders
    FROM commerce.orders WHERE order_date = CURRENT_DATE;

    SELECT COUNT(*) INTO active_merchants
    FROM commerce.merchants WHERE status = 'active';

    snapshot_data := json_build_object(
        'daily_revenue', daily_revenue,
        'daily_orders', daily_orders,
        'active_merchants', active_merchants,
        'avg_order_value', CASE WHEN daily_orders > 0 THEN ROUND(daily_revenue / daily_orders, 2) ELSE 0 END,
        'updated_at', NOW()
    );

    INSERT INTO realtime_monitoring.metrics_snapshots (
        metric_category, metric_name, metric_value, metric_metadata
    ) VALUES (
        'commerce', 'daily_revenue', daily_revenue, snapshot_data
    );

    PERFORM pg_notify('commerce_metrics', snapshot_data::TEXT);
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- REAL-TIME ALERT PROCESSING
-- =============================================================================

-- Handle system alerts with escalation
CREATE OR REPLACE FUNCTION realtime_monitoring.handle_system_alert(alert_data JSONB)
RETURNS VOID AS $
DECLARE
    alert_severity TEXT;
    alert_type TEXT;
    escalation_needed BOOLEAN := FALSE;
BEGIN
    alert_severity := alert_data->>'severity';
    alert_type := alert_data->>'alert_type';

    -- Determine if escalation is needed
    IF alert_severity IN ('critical', 'high') THEN
        escalation_needed := TRUE;
    END IF;

    -- Send targeted notifications based on alert type
    CASE alert_type
        WHEN 'database_performance' THEN
            PERFORM pg_notify('dba_alerts', alert_data::TEXT);
        WHEN 'security_breach' THEN
            PERFORM pg_notify('security_alerts', alert_data::TEXT);
        WHEN 'service_outage' THEN
            PERFORM pg_notify('ops_alerts', alert_data::TEXT);
        ELSE
            PERFORM pg_notify('general_alerts', alert_data::TEXT);
    END CASE;

    -- Escalation notifications
    IF escalation_needed THEN
        PERFORM pg_notify('escalation_alerts',
            (alert_data || json_build_object('escalated_at', NOW()))::TEXT
        );
    END IF;
END;
$ LANGUAGE plpgsql;

-- Handle data quality alerts
CREATE OR REPLACE FUNCTION realtime_monitoring.handle_quality_alert(alert_data JSONB)
RETURNS VOID AS $
BEGIN
    -- Send to data quality monitoring channel
    PERFORM pg_notify('data_quality_alerts', alert_data::TEXT);

    -- If critical quality issue, also send to general alerts
    IF (alert_data->>'severity') = 'critical' THEN
        PERFORM pg_notify('general_alerts',
            (alert_data || json_build_object('alert_source', 'data_quality'))::TEXT
        );
    END IF;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- LIVE DASHBOARD VIEWS
-- =============================================================================

-- Real-time city operations dashboard
CREATE OR REPLACE VIEW realtime_monitoring.live_city_dashboard AS
WITH latest_snapshots AS (
    SELECT DISTINCT ON (metric_category, metric_name)
        metric_category,
        metric_name,
        metric_value,
        metric_metadata,
        snapshot_timestamp
    FROM realtime_monitoring.metrics_snapshots
    WHERE snapshot_timestamp >= NOW() - INTERVAL '1 hour'
    ORDER BY metric_category, metric_name, snapshot_timestamp DESC
),
current_alerts AS (
    SELECT
        COUNT(*) as active_alerts,
        COUNT(*) FILTER (WHERE event_data->>'severity' = 'critical') as critical_alerts,
        COUNT(*) FILTER (WHERE event_data->>'severity' = 'high') as high_alerts
    FROM realtime_monitoring.live_events
    WHERE event_type = 'system_alert'
    AND event_timestamp >= NOW() - INTERVAL '1 hour'
    AND NOT processed
),
recent_activity AS (
    SELECT
        event_type,
        COUNT(*) as event_count,
        MAX(event_timestamp) as latest_event
    FROM realtime_monitoring.live_events
    WHERE event_timestamp >= NOW() - INTERVAL '15 minutes'
    GROUP BY event_type
)
SELECT
    'Population' as dashboard_section,
    (SELECT metric_value FROM latest_snapshots WHERE metric_name = 'active_citizens') as current_value,
    (SELECT (metric_metadata->>'new_today')::INTEGER FROM latest_snapshots WHERE metric_name = 'active_citizens') as daily_change,
    (SELECT COUNT(*) FROM recent_activity WHERE event_type = 'citizen_registration') as recent_activity_count,
    NOW() as last_updated

UNION ALL

SELECT
    'Permits',
    (SELECT metric_value FROM latest_snapshots WHERE metric_name = 'pending_permits'),
    (SELECT (metric_metadata->>'processed_today')::INTEGER FROM latest_snapshots WHERE metric_name = 'pending_permits'),
    (SELECT COUNT(*) FROM recent_activity WHERE event_type = 'permit_application'),
    NOW()

UNION ALL

SELECT
    'Commerce',
    (SELECT metric_value FROM latest_snapshots WHERE metric_name = 'daily_revenue'),
    (SELECT (metric_metadata->>'daily_orders')::INTEGER FROM latest_snapshots WHERE metric_name = 'daily_revenue'),
    (SELECT COUNT(*) FROM recent_activity WHERE event_type = 'order_placed'),
    NOW()

UNION ALL

SELECT
    'System Health',
    (SELECT active_alerts FROM current_alerts),
    (SELECT critical_alerts FROM current_alerts),
    (SELECT COUNT(*) FROM recent_activity WHERE event_type = 'system_alert'),
    NOW();

-- Real-time service performance view
CREATE OR REPLACE VIEW realtime_monitoring.live_service_performance AS
WITH service_metrics AS (
    SELECT
        event_data->>'service_name' as service_name,
        AVG((event_data->>'response_time_ms')::NUMERIC) as avg_response_time,
        COUNT(*) as request_count,
        COUNT(*) FILTER (WHERE (event_data->>'status_code')::INTEGER >= 400) as error_count,
        MAX(event_timestamp) as latest_request
    FROM realtime_monitoring.live_events
    WHERE event_type = 'service_request'
    AND event_timestamp >= NOW() - INTERVAL '5 minutes'
    GROUP BY event_data->>'service_name'
)
SELECT
    service_name,
    ROUND(avg_response_time, 0) as avg_response_time_ms,
    request_count,
    error_count,
    ROUND((request_count - error_count)::NUMERIC / NULLIF(request_count, 0) * 100, 2) as success_rate_percent,
    CASE
        WHEN avg_response_time > 2000 THEN 'SLOW'
        WHEN error_count::NUMERIC / NULLIF(request_count, 0) > 0.05 THEN 'ERROR_PRONE'
        ELSE 'HEALTHY'
    END as service_status,
    latest_request
FROM service_metrics
ORDER BY request_count DESC;

-- =============================================================================
-- REAL-TIME NOTIFICATION MANAGEMENT
-- =============================================================================

-- Subscribe to real-time dashboard updates
CREATE OR REPLACE FUNCTION realtime_monitoring.subscribe_to_dashboard(
    dashboard_name TEXT,
    user_identifier TEXT,
    metrics_to_watch TEXT[] DEFAULT NULL
)
RETURNS TEXT AS $
DECLARE
    notification_channel TEXT;
    subscription_id BIGINT;
BEGIN
    -- Generate unique notification channel
    notification_channel := 'dashboard_' || dashboard_name || '_' ||
                          regexp_replace(user_identifier, '[^a-zA-Z0-9_]', '_', 'g');

    -- Create or update subscription
    INSERT INTO realtime_monitoring.dashboard_subscriptions (
        dashboard_name, user_identifier, subscribed_metrics, notification_channel
    ) VALUES (
        dashboard_name, user_identifier, COALESCE(metrics_to_watch, ARRAY[]::TEXT[]), notification_channel
    ) ON CONFLICT (dashboard_name, user_identifier)
    DO UPDATE SET
        subscribed_metrics = EXCLUDED.subscribed_metrics,
        notification_channel = EXCLUDED.notification_channel,
        last_activity = NOW(),
        is_active = TRUE
    RETURNING subscription_subscriptions.subscription_id INTO subscription_id;

    -- Return the channel name for the client to listen on
    RETURN notification_channel;
END;
$ LANGUAGE plpgsql;

-- Send targeted dashboard updates
CREATE OR REPLACE FUNCTION realtime_monitoring.send_dashboard_update(
    dashboard_name TEXT,
    update_data JSONB
)
RETURNS INTEGER AS $
DECLARE
    subscription_record RECORD;
    notifications_sent INTEGER := 0;
    update_payload JSONB;
BEGIN
    update_payload := update_data || json_build_object(
        'dashboard_name', dashboard_name,
        'timestamp', NOW()
    );

    -- Send to all active subscribers of this dashboard
    FOR subscription_record IN
        SELECT notification_channel, subscribed_metrics
        FROM realtime_monitoring.dashboard_subscriptions
        WHERE realtime_monitoring.dashboard_subscriptions.dashboard_name = send_dashboard_update.dashboard_name
        AND is_active = TRUE
        AND last_activity >= NOW() - INTERVAL '1 hour' -- Only active sessions
    LOOP
        -- Send notification
        PERFORM pg_notify(subscription_record.notification_channel, update_payload::TEXT);
        notifications_sent := notifications_sent + 1;
    END LOOP;

    -- Also send to general dashboard channel
    PERFORM pg_notify('dashboard_' || dashboard_name, update_payload::TEXT);

    RETURN notifications_sent;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- AUTOMATED REAL-TIME TRIGGERS
-- =============================================================================

-- Trigger for real-time citizen events
CREATE OR REPLACE FUNCTION realtime_monitoring.citizen_realtime_trigger()
RETURNS TRIGGER AS $
DECLARE
    event_data JSONB;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_data := json_build_object(
            'citizen_id', NEW.citizen_id,
            'operation', 'registration',
            'city', NEW.city,
            'registration_date', NEW.registered_date
        );

        PERFORM realtime_monitoring.process_live_event(
            'citizen_events', 'citizen_registration', event_data
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$ LANGUAGE plpgsql;

-- Trigger for real-time permit events
CREATE OR REPLACE FUNCTION realtime_monitoring.permit_realtime_trigger()
RETURNS TRIGGER AS $
DECLARE
    event_data JSONB;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_data := json_build_object(
            'application_id', NEW.application_id,
            'operation', 'application_submitted',
            'permit_type', NEW.permit_type,
            'citizen_id', NEW.citizen_id,
            'estimated_cost', NEW.estimated_cost
        );

        PERFORM realtime_monitoring.process_live_event(
            'permit_events', 'permit_application', event_data
        );

    ELSIF TG_OP = 'UPDATE' AND OLD.status != NEW.status THEN
        event_data := json_build_object(
            'application_id', NEW.application_id,
            'operation', 'status_change',
            'old_status', OLD.status,
            'new_status', NEW.status,
            'permit_type', NEW.permit_type
        );

        PERFORM realtime_monitoring.process_live_event(
            'permit_events', 'permit_status_change', event_data
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$ LANGUAGE plpgsql;

-- Trigger for real-time order events
CREATE OR REPLACE FUNCTION realtime_monitoring.order_realtime_trigger()
RETURNS TRIGGER AS $
DECLARE
    event_data JSONB;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_data := json_build_object(
            'order_id', NEW.order_id,
            'operation', 'order_placed',
            'merchant_id', NEW.merchant_id,
            'customer_id', NEW.customer_citizen_id,
            'total_amount', NEW.total_amount,
            'order_date', NEW.order_date
        );

        PERFORM realtime_monitoring.process_live_event(
            'commerce_events', 'order_placed', event_data
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$ LANGUAGE plpgsql;

-- Create triggers on main tables
DROP TRIGGER IF EXISTS realtime_citizen_trigger ON civics.citizens;
CREATE TRIGGER realtime_citizen_trigger
    AFTER INSERT ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION realtime_monitoring.citizen_realtime_trigger();

DROP TRIGGER IF EXISTS realtime_permit_trigger ON civics.permit_applications;
CREATE TRIGGER realtime_permit_trigger
    AFTER INSERT OR UPDATE ON civics.permit_applications
    FOR EACH ROW EXECUTE FUNCTION realtime_monitoring.permit_realtime_trigger();

DROP TRIGGER IF EXISTS realtime_order_trigger ON commerce.orders;
CREATE TRIGGER realtime_order_trigger
    AFTER INSERT ON commerce.orders
    FOR EACH ROW EXECUTE FUNCTION realtime_monitoring.order_realtime_trigger();

-- =============================================================================
-- MAINTENANCE AND CLEANUP
-- =============================================================================

-- Clean up old events and snapshots
CREATE OR REPLACE FUNCTION realtime_monitoring.cleanup_old_events()
RETURNS INTEGER AS $
DECLARE
    deleted_events INTEGER := 0;
    deleted_snapshots INTEGER := 0;
    stream_record RECORD;
BEGIN
    -- Clean up events based on stream retention policies
    FOR stream_record IN
        SELECT stream_name, retention_hours
        FROM realtime_monitoring.event_streams
        WHERE is_active = TRUE
    LOOP
        DELETE FROM realtime_monitoring.live_events
        WHERE stream_name = stream_record.stream_name
        AND event_timestamp < NOW() - (stream_record.retention_hours || ' hours')::INTERVAL;

        GET DIAGNOSTICS deleted_events = deleted_events + ROW_COUNT;
    END LOOP;

    -- Clean up old metric snapshots (keep 7 days)
    DELETE FROM realtime_monitoring.metrics_snapshots
    WHERE snapshot_timestamp < NOW() - INTERVAL '7 days';

    GET DIAGNOSTICS deleted_snapshots = ROW_COUNT;

    -- Clean up inactive dashboard subscriptions
    DELETE FROM realtime_monitoring.dashboard_subscriptions
    WHERE last_activity < NOW() - INTERVAL '24 hours';

    RETURN deleted_events + deleted_snapshots;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- SETUP AND INITIALIZATION
-- =============================================================================

-- Initialize real-time monitoring streams
CREATE OR REPLACE FUNCTION realtime_monitoring.setup_monitoring_streams()
RETURNS TEXT AS $
DECLARE
    streams_created INTEGER := 0;
BEGIN
    -- Citizen events stream
    INSERT INTO realtime_monitoring.event_streams (
        stream_name, stream_description, event_types, retention_hours, max_events_per_minute
    ) VALUES (
        'citizen_events', 'Citizen registration and profile changes',
        ARRAY['citizen_registration', 'citizen_update', 'citizen_deactivation'], 48, 500
    ) ON CONFLICT (stream_name) DO NOTHING;
    streams_created := streams_created + 1;

    -- Permit events stream
    INSERT INTO realtime_monitoring.event_streams (
        stream_name, stream_description, event_types, retention_hours, max_events_per_minute
    ) VALUES (
        'permit_events', 'Permit applications and status changes',
        ARRAY['permit_application', 'permit_status_change', 'permit_approval'], 72, 300
    ) ON CONFLICT (stream_name) DO NOTHING;
    streams_created := streams_created + 1;

    -- Commerce events stream
    INSERT INTO realtime_monitoring.event_streams (
        stream_name, stream_description, event_types, retention_hours, max_events_per_minute
    ) VALUES (
        'commerce_events', 'Orders, payments, and merchant activity',
        ARRAY['order_placed', 'order_updated', 'payment_processed'], 24, 1000
    ) ON CONFLICT (stream_name) DO NOTHING;
    streams_created := streams_created + 1;

    -- System events stream
    INSERT INTO realtime_monitoring.event_streams (
        stream_name, stream_description, event_types, retention_hours, max_events_per_minute
    ) VALUES (
        'system_events', 'System alerts, performance metrics, and health checks',
        ARRAY['system_alert', 'performance_metric', 'health_check', 'service_request'], 168, 2000
    ) ON CONFLICT (stream_name) DO NOTHING;
    streams_created := streams_created + 1;

    -- Data quality events stream
    INSERT INTO realtime_monitoring.event_streams (
        stream_name, stream_description, event_types, retention_hours, max_events_per_minute
    ) VALUES (
        'quality_events', 'Data quality issues and resolution tracking',
        ARRAY['quality_issue', 'quality_resolution', 'data_validation'], 120, 200
    ) ON CONFLICT (stream_name) DO NOTHING;
    streams_created := streams_created + 1;

    RETURN 'Initialized ' || streams_created || ' real-time monitoring streams';
END;
$ LANGUAGE plpgsql;

-- Generate test events for demonstration
CREATE OR REPLACE FUNCTION realtime_monitoring.generate_test_events()
RETURNS TEXT AS $
DECLARE
    events_generated INTEGER := 0;
BEGIN
    -- Generate sample citizen registration event
    PERFORM realtime_monitoring.process_live_event(
        'citizen_events',
        'citizen_registration',
        json_build_object(
            'citizen_id', 999999,
            'operation', 'registration',
            'city', 'Test City',
            'registration_date', NOW()
        )
    );
    events_generated := events_generated + 1;

    -- Generate sample permit application event
    PERFORM realtime_monitoring.process_live_event(
        'permit_events',
        'permit_application',
        json_build_object(
            'application_id', 888888,
            'operation', 'application_submitted',
            'permit_type', 'building',
            'citizen_id', 999999,
            'estimated_cost', 5000
        )
    );
    events_generated := events_generated + 1;

    -- Generate sample commerce event
    PERFORM realtime_monitoring.process_live_event(
        'commerce_events',
        'order_placed',
        json_build_object(
            'order_id', 777777,
            'operation', 'order_placed',
            'merchant_id', 1,
            'customer_id', 999999,
            'total_amount', 99.99,
            'order_date', NOW()
        )
    );
    events_generated := events_generated + 1;

    -- Generate sample system alert
    PERFORM realtime_monitoring.process_live_event(
        'system_events',
        'system_alert',
        json_build_object(
            'alert_type', 'database_performance',
            'severity', 'medium',
            'message', 'Database query response time elevated',
            'metric_value', 1200,
            'threshold', 1000
        )
    );
    events_generated := events_generated + 1;

    RETURN 'Generated ' || events_generated || ' test events for real-time monitoring demonstration';
END;
$ LANGUAGE plpgsql;
