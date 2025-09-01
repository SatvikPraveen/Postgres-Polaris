-- File: sql/14_async_patterns/listen_notify_pubsub.sql
-- Purpose: pub/sub inside Postgres + triggers for real-time notifications

-- =============================================================================
-- PUB/SUB INFRASTRUCTURE SETUP
-- =============================================================================

-- Create schema for async messaging
CREATE SCHEMA IF NOT EXISTS messaging;

-- Message queue table for persistent messages
CREATE TABLE messaging.message_queue (
    message_id BIGSERIAL PRIMARY KEY,
    channel_name TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload JSONB,
    sender_id TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    status TEXT CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'dead_letter')) DEFAULT 'pending',
    error_message TEXT
);

-- Channel subscribers table
CREATE TABLE messaging.channel_subscribers (
    subscription_id BIGSERIAL PRIMARY KEY,
    channel_name TEXT NOT NULL,
    subscriber_id TEXT NOT NULL,
    subscription_type TEXT CHECK (subscription_type IN ('live', 'persistent', 'both')) DEFAULT 'live',
    is_active BOOLEAN DEFAULT TRUE,
    last_activity TIMESTAMPTZ DEFAULT NOW(),
    filter_conditions JSONB, -- Optional message filtering
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(channel_name, subscriber_id)
);

-- Notification history for auditing
CREATE TABLE messaging.notification_log (
    log_id BIGSERIAL PRIMARY KEY,
    channel_name TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload JSONB,
    notification_sent_at TIMESTAMPTZ DEFAULT NOW(),
    subscriber_count INTEGER DEFAULT 0,
    delivery_method TEXT CHECK (delivery_method IN ('notify', 'queue', 'both')) DEFAULT 'notify'
);

-- =============================================================================
-- CORE MESSAGING FUNCTIONS
-- =============================================================================

-- Send notification to channel
CREATE OR REPLACE FUNCTION messaging.notify_channel(
    channel_name TEXT,
    event_type TEXT,
    payload JSONB DEFAULT NULL,
    sender_id TEXT DEFAULT NULL,
    persist_message BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT AS $$
DECLARE
    message_id BIGINT;
    subscriber_count INTEGER;
    notification_payload TEXT;
BEGIN
    -- Build notification payload
    notification_payload := json_build_object(
        'event_type', event_type,
        'payload', payload,
        'sender_id', sender_id,
        'timestamp', NOW()
    )::TEXT;

    -- Count active subscribers
    SELECT COUNT(*) INTO subscriber_count
    FROM messaging.channel_subscribers
    WHERE messaging.channel_subscribers.channel_name = notify_channel.channel_name
    AND is_active = TRUE;

    -- Send live notification
    IF subscriber_count > 0 THEN
        PERFORM pg_notify(channel_name, notification_payload);
    END IF;

    -- Persist message if requested
    IF persist_message THEN
        INSERT INTO messaging.message_queue (
            channel_name, event_type, payload, sender_id
        ) VALUES (
            channel_name, event_type, payload, sender_id
        ) RETURNING messaging.message_queue.message_id INTO message_id;
    END IF;

    -- Log notification
    INSERT INTO messaging.notification_log (
        channel_name, event_type, payload, subscriber_count,
        delivery_method
    ) VALUES (
        channel_name, event_type, payload, subscriber_count,
        CASE WHEN persist_message THEN 'both' ELSE 'notify' END
    );

    RETURN COALESCE(message_id, 0);
END;
$$ LANGUAGE plpgsql;

-- Subscribe to channel
CREATE OR REPLACE FUNCTION messaging.subscribe_to_channel(
    channel_name TEXT,
    subscriber_id TEXT,
    subscription_type TEXT DEFAULT 'live',
    filter_conditions JSONB DEFAULT NULL
)
RETURNS BOOLEAN AS $$
BEGIN
    INSERT INTO messaging.channel_subscribers (
        channel_name, subscriber_id, subscription_type, filter_conditions
    ) VALUES (
        channel_name, subscriber_id, subscription_type, filter_conditions
    ) ON CONFLICT (channel_name, subscriber_id)
    DO UPDATE SET
        subscription_type = EXCLUDED.subscription_type,
        filter_conditions = EXCLUDED.filter_conditions,
        is_active = TRUE,
        last_activity = NOW();

    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Process queued messages
CREATE OR REPLACE FUNCTION messaging.process_queue_messages(
    channel_name TEXT DEFAULT NULL,
    batch_size INTEGER DEFAULT 100
)
RETURNS TABLE(
    message_id BIGINT,
    channel TEXT,
    event_type TEXT,
    processing_result TEXT
) AS $$
DECLARE
    msg_record RECORD;
BEGIN
    -- Get pending messages
    FOR msg_record IN
        SELECT mq.message_id, mq.channel_name, mq.event_type, mq.payload, mq.sender_id
        FROM messaging.message_queue mq
        WHERE (channel_name IS NULL OR mq.channel_name = process_queue_messages.channel_name)
        AND status = 'pending'
        ORDER BY created_at
        LIMIT batch_size
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Mark as processing
        UPDATE messaging.message_queue
        SET status = 'processing', processed_at = NOW()
        WHERE messaging.message_queue.message_id = msg_record.message_id;

        -- Send notification
        BEGIN
            PERFORM messaging.notify_channel(
                msg_record.channel_name,
                msg_record.event_type,
                msg_record.payload,
                msg_record.sender_id,
                FALSE
            );

            -- Mark as completed
            UPDATE messaging.message_queue
            SET status = 'completed'
            WHERE messaging.message_queue.message_id = msg_record.message_id;

            RETURN QUERY SELECT
                msg_record.message_id,
                msg_record.channel_name,
                msg_record.event_type,
                'SUCCESS'::TEXT;

        EXCEPTION WHEN OTHERS THEN
            -- Handle failure
            UPDATE messaging.message_queue
            SET status = CASE
                WHEN retry_count >= max_retries THEN 'dead_letter'
                ELSE 'failed'
            END,
            retry_count = retry_count + 1,
            error_message = SQLERRM
            WHERE messaging.message_queue.message_id = msg_record.message_id;

            RETURN QUERY SELECT
                msg_record.message_id,
                msg_record.channel_name,
                msg_record.event_type,
                'FAILED: ' || SQLERRM;
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TRIGGER-BASED NOTIFICATIONS
-- =============================================================================

-- Generic notification trigger function
CREATE OR REPLACE FUNCTION messaging.table_change_notify()
RETURNS TRIGGER AS $$
DECLARE
    channel_name TEXT;
    event_type TEXT;
    payload JSONB;
    table_config JSONB;
BEGIN
    -- Build channel name from schema and table
    channel_name := TG_TABLE_SCHEMA || '_' || TG_TABLE_NAME || '_changes';

    -- Determine event type
    event_type := CASE TG_OP
        WHEN 'INSERT' THEN 'created'
        WHEN 'UPDATE' THEN 'updated'
        WHEN 'DELETE' THEN 'deleted'
        ELSE 'changed'
    END;

    -- Build payload based on operation
    payload := CASE TG_OP
        WHEN 'INSERT' THEN
            json_build_object(
                'operation', 'INSERT',
                'table', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
                'new_data', to_jsonb(NEW)
            )
        WHEN 'UPDATE' THEN
            json_build_object(
                'operation', 'UPDATE',
                'table', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
                'old_data', to_jsonb(OLD),
                'new_data', to_jsonb(NEW)
            )
        WHEN 'DELETE' THEN
            json_build_object(
                'operation', 'DELETE',
                'table', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
                'old_data', to_jsonb(OLD)
            )
    END;

    -- Send notification
    PERFORM messaging.notify_channel(
        channel_name,
        event_type,
        payload,
        current_user,
        FALSE  -- Don't persist by default
    );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BUSINESS EVENT TRIGGERS
-- =============================================================================

-- Citizen registration notification
CREATE OR REPLACE FUNCTION messaging.citizen_events_notify()
RETURNS TRIGGER AS $$
BEGIN
    -- New citizen registration
    IF TG_OP = 'INSERT' THEN
        PERFORM messaging.notify_channel(
            'citizen_registrations',
            'new_citizen',
            json_build_object(
                'citizen_id', NEW.citizen_id,
                'name', NEW.first_name || ' ' || NEW.last_name,
                'email', NEW.email,
                'city', NEW.city,
                'registered_date', NEW.registered_date
            ),
            'registration_system'
        );
    END IF;

    -- Status changes
    IF TG_OP = 'UPDATE' AND OLD.status != NEW.status THEN
        PERFORM messaging.notify_channel(
            'citizen_status_changes',
            'status_changed',
            json_build_object(
                'citizen_id', NEW.citizen_id,
                'name', NEW.first_name || ' ' || NEW.last_name,
                'old_status', OLD.status,
                'new_status', NEW.status,
                'changed_at', NOW()
            ),
            current_user
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Order processing notifications
CREATE OR REPLACE FUNCTION messaging.order_events_notify()
RETURNS TRIGGER AS $$
DECLARE
    merchant_name TEXT;
BEGIN
    -- Get merchant name
    SELECT business_name INTO merchant_name
    FROM commerce.merchants
    WHERE merchant_id = COALESCE(NEW.merchant_id, OLD.merchant_id);

    -- New order
    IF TG_OP = 'INSERT' THEN
        PERFORM messaging.notify_channel(
            'new_orders',
            'order_created',
            json_build_object(
                'order_id', NEW.order_id,
                'merchant_id', NEW.merchant_id,
                'merchant_name', merchant_name,
                'customer_id', NEW.customer_citizen_id,
                'total_amount', NEW.total_amount,
                'order_date', NEW.order_date
            ),
            'order_system'
        );

        -- Notify merchant specifically
        PERFORM messaging.notify_channel(
            'merchant_' || NEW.merchant_id || '_orders',
            'new_order',
            json_build_object(
                'order_id', NEW.order_id,
                'customer_id', NEW.customer_citizen_id,
                'total_amount', NEW.total_amount,
                'items_count', 1  -- Would need order_items join for real count
            ),
            'order_system'
        );
    END IF;

    -- Order status changes
    IF TG_OP = 'UPDATE' AND OLD.order_status != NEW.order_status THEN
        PERFORM messaging.notify_channel(
            'order_status_updates',
            'status_updated',
            json_build_object(
                'order_id', NEW.order_id,
                'old_status', OLD.order_status,
                'new_status', NEW.order_status,
                'customer_id', NEW.customer_citizen_id,
                'updated_at', NOW()
            ),
            current_user
        );

        -- Notify customer
        PERFORM messaging.notify_channel(
            'customer_' || NEW.customer_citizen_id || '_orders',
            'order_status_changed',
            json_build_object(
                'order_id', NEW.order_id,
                'new_status', NEW.order_status,
                'merchant_name', merchant_name
            ),
            'order_system'
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Permit application notifications
CREATE OR REPLACE FUNCTION messaging.permit_events_notify()
RETURNS TRIGGER AS $$
BEGIN
    -- New permit application
    IF TG_OP = 'INSERT' THEN
        PERFORM messaging.notify_channel(
            'permit_applications',
            'application_submitted',
            json_build_object(
                'application_id', NEW.application_id,
                'permit_type', NEW.permit_type,
                'citizen_id', NEW.citizen_id,
                'submitted_date', NEW.submitted_date,
                'priority', CASE
                    WHEN NEW.permit_type IN ('emergency_repair', 'urgent_maintenance') THEN 'high'
                    ELSE 'normal'
                END
            ),
            'permit_system'
        );
    END IF;

    -- Status updates
    IF TG_OP = 'UPDATE' AND OLD.status != NEW.status THEN
        PERFORM messaging.notify_channel(
            'permit_status_updates',
            'status_changed',
            json_build_object(
                'application_id', NEW.application_id,
                'permit_type', NEW.permit_type,
                'citizen_id', NEW.citizen_id,
                'old_status', OLD.status,
                'new_status', NEW.status,
                'updated_at', NOW()
            ),
            current_user
        );

        -- Notify applicant
        PERFORM messaging.notify_channel(
            'citizen_' || NEW.citizen_id || '_permits',
            'permit_status_update',
            json_build_object(
                'application_id', NEW.application_id,
                'permit_type', NEW.permit_type,
                'new_status', NEW.status
            ),
            'permit_system'
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- CREATE TRIGGERS ON MAIN TABLES
-- =============================================================================

-- Citizens table triggers
DROP TRIGGER IF EXISTS citizen_change_notify ON civics.citizens;
CREATE TRIGGER citizen_change_notify
    AFTER INSERT OR UPDATE OR DELETE ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION messaging.citizen_events_notify();

-- Orders table triggers
DROP TRIGGER IF EXISTS order_change_notify ON commerce.orders;
CREATE TRIGGER order_change_notify
    AFTER INSERT OR UPDATE OR DELETE ON commerce.orders
    FOR EACH ROW EXECUTE FUNCTION messaging.order_events_notify();

-- Permit applications triggers
DROP TRIGGER IF EXISTS permit_change_notify ON civics.permit_applications;
CREATE TRIGGER permit_change_notify
    AFTER INSERT OR UPDATE OR DELETE ON civics.permit_applications
    FOR EACH ROW EXECUTE FUNCTION messaging.permit_events_notify();

-- Generic change tracking for all tables (commented out by default)
-- DROP TRIGGER IF EXISTS generic_change_notify ON civics.neighborhoods;
-- CREATE TRIGGER generic_change_notify
--     AFTER INSERT OR UPDATE OR DELETE ON civics.neighborhoods
--     FOR EACH ROW EXECUTE FUNCTION messaging.table_change_notify();

-- =============================================================================
-- CHANNEL MANAGEMENT FUNCTIONS
-- =============================================================================

-- List all active channels
CREATE OR REPLACE FUNCTION messaging.list_active_channels()
RETURNS TABLE(
    channel_name TEXT,
    subscriber_count BIGINT,
    last_message_at TIMESTAMPTZ,
    total_messages BIGINT,
    active_subscribers TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        cs.channel_name,
        COUNT(*) FILTER (WHERE cs.is_active = TRUE) as subscriber_count,
        MAX(nl.notification_sent_at) as last_message_at,
        COUNT(DISTINCT nl.log_id) as total_messages,
        ARRAY_AGG(cs.subscriber_id ORDER BY cs.subscriber_id) FILTER (WHERE cs.is_active = TRUE) as active_subscribers
    FROM messaging.channel_subscribers cs
    LEFT JOIN messaging.notification_log nl ON cs.channel_name = nl.channel_name
    GROUP BY cs.channel_name
    HAVING COUNT(*) FILTER (WHERE cs.is_active = TRUE) > 0
    ORDER BY subscriber_count DESC, last_message_at DESC NULLS LAST;
END;
$$ LANGUAGE plpgsql;

-- Clean up old notification logs
CREATE OR REPLACE FUNCTION messaging.cleanup_old_notifications(
    retention_days INTEGER DEFAULT 30
)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM messaging.notification_log
    WHERE notification_sent_at < (NOW() - (retention_days || ' days')::INTERVAL);

    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    -- Also clean up old processed queue messages
    DELETE FROM messaging.message_queue
    WHERE status = 'completed'
    AND processed_at < (NOW() - (retention_days || ' days')::INTERVAL);

    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- MONITORING AND HEALTH CHECKS
-- =============================================================================

-- Monitor messaging system health
CREATE OR REPLACE FUNCTION messaging.health_check()
RETURNS TABLE(
    component TEXT,
    status TEXT,
    metric_value TEXT,
    last_check TIMESTAMPTZ
) AS $$
BEGIN
    -- Active subscribers
    RETURN QUERY
    SELECT
        'Active Subscribers'::TEXT as component,
        CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'WARNING' END as status,
        COUNT(*)::TEXT as metric_value,
        NOW() as last_check
    FROM messaging.channel_subscribers WHERE is_active = TRUE;

    -- Pending messages
    RETURN QUERY
    SELECT
        'Pending Messages'::TEXT,
        CASE
            WHEN COUNT(*) = 0 THEN 'OK'
            WHEN COUNT(*) < 100 THEN 'WARNING'
            ELSE 'CRITICAL'
        END,
        COUNT(*)::TEXT,
        NOW()
    FROM messaging.message_queue WHERE status = 'pending';

    -- Failed messages
    RETURN QUERY
    SELECT
        'Failed Messages'::TEXT,
        CASE WHEN COUNT(*) > 0 THEN 'WARNING' ELSE 'OK' END,
        COUNT(*)::TEXT,
        NOW()
    FROM messaging.message_queue WHERE status IN ('failed', 'dead_letter');

    -- Message throughput (last hour)
    RETURN QUERY
    SELECT
        'Messages/Hour'::TEXT,
        'INFO'::TEXT,
        COUNT(*)::TEXT,
        NOW()
    FROM messaging.notification_log
    WHERE notification_sent_at >= NOW() - INTERVAL '1 hour';
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DEMO AND TESTING FUNCTIONS
-- =============================================================================

-- Demo the pub/sub system
CREATE OR REPLACE FUNCTION messaging.demo_pubsub_system()
RETURNS TABLE(
    step_description TEXT,
    action_result TEXT,
    example_usage TEXT
) AS $$
DECLARE
    test_citizen_id BIGINT;
    message_id BIGINT;
BEGIN
    -- Step 1: Subscribe to channels
    PERFORM messaging.subscribe_to_channel('demo_channel', 'test_subscriber_1');
    PERFORM messaging.subscribe_to_channel('citizen_registrations', 'admin_dashboard');

    RETURN QUERY SELECT
        'Channel Subscriptions Created'::TEXT as step_description,
        'SUCCESS'::TEXT as action_result,
        'LISTEN demo_channel; -- In your client'::TEXT as example_usage;

    -- Step 2: Send test notification
    message_id := messaging.notify_channel(
        'demo_channel',
        'test_event',
        json_build_object(
            'message', 'Hello from pub/sub system!',
            'timestamp', NOW(),
            'test_data', json_build_array(1, 2, 3)
        ),
        'demo_system'
    );

    RETURN QUERY SELECT
        'Test Notification Sent'::TEXT,
        'Message sent to demo_channel'::TEXT,
        'Check your LISTEN connection for the message'::TEXT;

    -- Step 3: Create test citizen (triggers notification)
    INSERT INTO civics.citizens (
        first_name, last_name, email, phone,
        street_address, city, state_province, postal_code,
        date_of_birth, status
    ) VALUES (
        'Demo', 'Citizen', 'demo@pubsub.test', '555-DEMO-TEST',
        '123 Demo St', 'Demo City', 'DS', '12345',
        '1990-01-01', 'active'
    ) RETURNING citizen_id INTO test_citizen_id;

    RETURN QUERY SELECT
        'Citizen Created (Triggered Notification)'::TEXT,
        'Citizen ID: ' || test_citizen_id::TEXT,
        'LISTEN citizen_registrations; -- To see this event'::TEXT;

    -- Step 4: Show active channels
    RETURN QUERY SELECT
        'Active Channels Summary'::TEXT,
        (SELECT COUNT(DISTINCT channel_name)::TEXT FROM messaging.channel_subscribers WHERE is_active = TRUE),
        'SELECT * FROM messaging.list_active_channels();'::TEXT;

    -- Cleanup test data
    DELETE FROM civics.citizens WHERE citizen_id = test_citizen_id;

    RETURN QUERY SELECT
        'Demo Cleanup Complete'::TEXT,
        'Test citizen removed'::TEXT,
        'Demo complete - channels still active for testing'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Real-time dashboard data function
CREATE OR REPLACE FUNCTION messaging.get_realtime_stats()
RETURNS JSONB AS $$
DECLARE
    stats JSONB;
BEGIN
    SELECT json_build_object(
        'active_citizens', (SELECT COUNT(*) FROM civics.citizens WHERE status = 'active'),
        'pending_permits', (SELECT COUNT(*) FROM civics.permit_applications WHERE status = 'pending'),
        'orders_today', (SELECT COUNT(*) FROM commerce.orders WHERE order_date::DATE = CURRENT_DATE),
        'messages_last_hour', (SELECT COUNT(*) FROM messaging.notification_log WHERE notification_sent_at >= NOW() - INTERVAL '1 hour'),
        'active_channels', (SELECT COUNT(DISTINCT channel_name) FROM messaging.channel_subscribers WHERE is_active = TRUE),
        'last_updated', NOW()
    ) INTO stats;

    -- Send stats update notification
    PERFORM messaging.notify_channel(
        'dashboard_stats',
        'stats_update',
        stats,
        'stats_system'
    );

    RETURN stats;
END;
$$ LANGUAGE plpgsql;
