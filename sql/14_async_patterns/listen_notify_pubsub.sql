-- File: sql/14_async_patterns/listen_notify_pubsub.sql
-- Purpose: pub/sub inside PostgreSQL with LISTEN / NOTIFY, plus trigger-driven events
--
-- What this module teaches
--   1. LISTEN / NOTIFY / pg_notify semantics: delivered only on COMMIT, never on ROLLBACK,
--      identical notifications in one transaction are collapsed, no delivery to sessions
--      that are not listening at that moment (fire-and-forget)
--   2. Limits: payload < 8000 bytes, channel names are identifiers (max 63 bytes),
--      a shared 8 GB queue (pg_notification_queue_usage) that a stalled listener can fill
--   3. Durable messaging = a table (outbox) + NOTIFY as a wake-up signal; consumers claim
--      rows with FOR UPDATE SKIP LOCKED
--   4. Row-level vs statement-level (transition table) triggers that publish events
--
-- psql prints 'Asynchronous notification "..." received' lines because this session LISTENs.
-- Safety: triggers are attached only to the module-owned tables messaging.permit_requests and
-- messaging.orders_feed; base tables are never modified.

\echo '== 14 / LISTEN / NOTIFY =='

-- =============================================================================
-- 1. MESSAGING TABLES (module-owned)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS messaging;

-- Durable outbox / queue
CREATE TABLE IF NOT EXISTS messaging.message_queue (
    message_id    BIGSERIAL PRIMARY KEY,
    channel_name  TEXT NOT NULL,
    event_type    TEXT NOT NULL,
    payload       JSONB,
    sender_id     TEXT,
    created_at    TIMESTAMPTZ DEFAULT now(),
    processed_at  TIMESTAMPTZ,
    retry_count   INTEGER DEFAULT 0,
    max_retries   INTEGER DEFAULT 3,
    status        TEXT CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'dead_letter')) DEFAULT 'pending',
    error_message TEXT
);
CREATE INDEX IF NOT EXISTS idx_message_queue_pending
    ON messaging.message_queue (channel_name, created_at) WHERE status = 'pending';

-- Logical subscriber registry (who SHOULD be listening; LISTEN itself is per-connection)
CREATE TABLE IF NOT EXISTS messaging.channel_subscribers (
    subscription_id   BIGSERIAL PRIMARY KEY,
    channel_name      TEXT NOT NULL,
    subscriber_id     TEXT NOT NULL,
    subscription_type TEXT CHECK (subscription_type IN ('live', 'persistent', 'both')) DEFAULT 'live',
    is_active         BOOLEAN DEFAULT TRUE,
    last_activity     TIMESTAMPTZ DEFAULT now(),
    filter_conditions JSONB,
    created_at        TIMESTAMPTZ DEFAULT now(),
    UNIQUE (channel_name, subscriber_id)
);

-- Audit of what was sent
CREATE TABLE IF NOT EXISTS messaging.notification_log (
    log_id               BIGSERIAL PRIMARY KEY,
    channel_name         TEXT NOT NULL,
    event_type           TEXT NOT NULL,
    payload              JSONB,
    notification_sent_at TIMESTAMPTZ DEFAULT now(),
    subscriber_count     INTEGER DEFAULT 0,
    delivery_method      TEXT CHECK (delivery_method IN ('notify', 'queue', 'both', 'pointer')) DEFAULT 'notify'
);

-- =============================================================================
-- 2. RAW LISTEN / NOTIFY SEMANTICS
-- =============================================================================
LISTEN polaris_demo;

\echo '-- (a) NOTIFY and pg_notify(): delivered at commit (autocommit here)'
NOTIFY polaris_demo, 'hello via NOTIFY';
SELECT pg_notify('polaris_demo', 'hello via pg_notify (channel and payload can be expressions)');

\echo '-- (b) ROLLBACK: nothing is delivered'
BEGIN;
SELECT pg_notify('polaris_demo', 'this is never delivered');
ROLLBACK;

\echo '-- (c) duplicates in one transaction collapse to one notification; delivery order = send order'
BEGIN;
SELECT pg_notify('polaris_demo', 'dup');
SELECT pg_notify('polaris_demo', 'dup');
SELECT pg_notify('polaris_demo', 'second distinct message');
COMMIT;

\echo '-- (d) limits: payload must be shorter than 8000 bytes'
DO $$
BEGIN
    PERFORM pg_notify('polaris_demo', repeat('x', 8000));
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'payload of 8000 bytes rejected: %', SQLERRM;
END $$;

DO $$
BEGIN
    PERFORM pg_notify(repeat('c', 64), 'x');
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE '64-byte channel name rejected: %', SQLERRM;
END $$;

-- Fraction of the shared notification queue in use (a listener that never reads makes this grow)
SELECT pg_notification_queue_usage() AS queue_usage_fraction;
SELECT pg_listening_channels() AS this_session_listens_on;

-- =============================================================================
-- 3. CORE MESSAGING FUNCTIONS
-- =============================================================================
-- Send a message: always NOTIFY (cheap, and LISTEN is per-connection anyway), optionally persist.
-- Payloads that would exceed the NOTIFY limit are persisted and only a pointer is sent.
CREATE OR REPLACE FUNCTION messaging.notify_channel(
    channel_name    TEXT,
    event_type      TEXT,
    payload         JSONB DEFAULT NULL,
    sender_id       TEXT DEFAULT NULL,
    persist_message BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    v_message_id   BIGINT;
    v_subscribers  INTEGER;
    v_notification TEXT;
    v_method       TEXT := CASE WHEN persist_message THEN 'both' ELSE 'notify' END;
BEGIN
    v_notification := jsonb_build_object(
        'event_type', event_type, 'payload', payload,
        'sender_id', sender_id, 'sent_at', now())::TEXT;

    IF octet_length(v_notification) >= 7900 THEN
        persist_message := TRUE;   -- too big for NOTIFY: claim-check pattern
        v_method := 'pointer';
    END IF;

    IF persist_message THEN
        INSERT INTO messaging.message_queue (channel_name, event_type, payload, sender_id)
        VALUES (channel_name, event_type, payload, sender_id)
        RETURNING message_id INTO v_message_id;
    END IF;

    IF v_method = 'pointer' THEN
        v_notification := jsonb_build_object('event_type', event_type, 'message_id', v_message_id,
                                             'note', 'payload too large, fetch from messaging.message_queue')::TEXT;
    END IF;

    PERFORM pg_notify(channel_name, v_notification);

    SELECT count(*) INTO v_subscribers
    FROM messaging.channel_subscribers cs
    WHERE cs.channel_name = channel_name AND cs.is_active;

    INSERT INTO messaging.notification_log (channel_name, event_type, payload, subscriber_count, delivery_method)
    VALUES (channel_name, event_type, payload, v_subscribers, v_method);

    RETURN COALESCE(v_message_id, 0);
END $$;

CREATE OR REPLACE FUNCTION messaging.subscribe_to_channel(
    channel_name      TEXT,
    subscriber_id     TEXT,
    subscription_type TEXT DEFAULT 'live',
    filter_conditions JSONB DEFAULT NULL
)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO messaging.channel_subscribers AS cs (channel_name, subscriber_id, subscription_type, filter_conditions)
    VALUES (channel_name, subscriber_id, subscription_type, filter_conditions)
    -- name the constraint: the bare column list would clash with the parameter names
    ON CONFLICT ON CONSTRAINT channel_subscribers_channel_name_subscriber_id_key DO UPDATE
    SET subscription_type = EXCLUDED.subscription_type,
        filter_conditions = EXCLUDED.filter_conditions,
        is_active         = TRUE,
        last_activity     = now();
    RETURN TRUE;
EXCEPTION WHEN check_violation THEN
    RETURN FALSE;   -- invalid subscription_type
END $$;

-- Consumer: claim pending messages with SKIP LOCKED so parallel workers never get the same row,
-- re-publish them, and record the outcome.  Failed messages are retried, then dead-lettered.
CREATE OR REPLACE FUNCTION messaging.process_queue_messages(
    channel_name TEXT DEFAULT NULL,
    batch_size   INTEGER DEFAULT 100
)
RETURNS TABLE(message_id BIGINT, channel TEXT, event_type TEXT, processing_result TEXT)
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    msg RECORD;
BEGIN
    FOR msg IN
        SELECT mq.message_id, mq.channel_name, mq.event_type, mq.payload, mq.sender_id
        FROM messaging.message_queue mq
        WHERE (channel_name IS NULL OR mq.channel_name = channel_name)
          AND mq.status = 'pending'
        ORDER BY mq.created_at, mq.message_id
        LIMIT batch_size
        FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            PERFORM pg_notify(msg.channel_name,
                              jsonb_build_object('event_type', msg.event_type, 'payload', msg.payload,
                                                 'message_id', msg.message_id)::TEXT);
            UPDATE messaging.message_queue q
            SET status = 'completed', processed_at = now()
            WHERE q.message_id = msg.message_id;

            message_id := msg.message_id; channel := msg.channel_name;
            event_type := msg.event_type; processing_result := 'SUCCESS';
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            UPDATE messaging.message_queue q
            SET status = CASE WHEN q.retry_count + 1 >= q.max_retries THEN 'dead_letter' ELSE 'pending' END,
                retry_count = q.retry_count + 1,
                error_message = SQLERRM
            WHERE q.message_id = msg.message_id;

            message_id := msg.message_id; channel := msg.channel_name;
            event_type := msg.event_type; processing_result := 'FAILED: ' || SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END $$;

-- =============================================================================
-- 4. TRIGGER-DRIVEN EVENTS ON MODULE-OWNED TABLES
-- =============================================================================
-- A working copy of 200 permit applications (the base table is not touched)
DROP TABLE IF EXISTS messaging.permit_requests;
CREATE TABLE messaging.permit_requests AS
SELECT permit_id, citizen_id, permit_type::TEXT AS permit_type, status::TEXT AS status,
       application_date, fee_amount
FROM civics.permit_applications
WHERE status = 'pending'
ORDER BY permit_id
LIMIT 200;
ALTER TABLE messaging.permit_requests ADD PRIMARY KEY (permit_id);

-- Row-level trigger: one compact event per changed row.  Send keys and changed fields,
-- not to_jsonb(NEW): whole rows quickly exceed the 8000-byte limit and leak columns.
CREATE OR REPLACE FUNCTION messaging.permit_events_notify()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM messaging.notify_channel('permit_events', 'application_submitted',
            jsonb_build_object('permit_id', NEW.permit_id, 'permit_type', NEW.permit_type,
                               'citizen_id', NEW.citizen_id), 'permit_system');
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        PERFORM messaging.notify_channel('permit_events', 'status_changed',
            jsonb_build_object('permit_id', NEW.permit_id, 'old_status', OLD.status,
                               'new_status', NEW.status), 'permit_system');
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM messaging.notify_channel('permit_events', 'application_withdrawn',
            jsonb_build_object('permit_id', OLD.permit_id), 'permit_system');
    END IF;
    RETURN NULL;   -- AFTER trigger: return value ignored
END $$;

CREATE OR REPLACE TRIGGER permit_change_notify
    AFTER INSERT OR UPDATE OF status OR DELETE ON messaging.permit_requests
    FOR EACH ROW EXECUTE FUNCTION messaging.permit_events_notify();

-- Statement-level trigger with a transition table: ONE summary event per statement, however
-- many rows it touched.  Much cheaper for bulk loads than a notification per row.
DROP TABLE IF EXISTS messaging.orders_feed;
CREATE TABLE messaging.orders_feed (
    order_id     BIGINT PRIMARY KEY,
    merchant_id  BIGINT NOT NULL,
    status       TEXT NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL,
    order_date   TIMESTAMPTZ NOT NULL
);

CREATE OR REPLACE FUNCTION messaging.orders_batch_notify()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    summary JSONB;
BEGIN
    SELECT jsonb_build_object('rows', count(*),
                              'merchants', count(DISTINCT merchant_id),
                              'total_amount', COALESCE(sum(total_amount), 0),
                              'max_order_id', max(order_id))
    INTO summary
    FROM new_orders;

    IF (summary->>'rows')::INT > 0 THEN
        PERFORM messaging.notify_channel('order_batches', 'orders_loaded', summary, 'order_system');
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER orders_batch_notify
    AFTER INSERT ON messaging.orders_feed
    REFERENCING NEW TABLE AS new_orders
    FOR EACH STATEMENT EXECUTE FUNCTION messaging.orders_batch_notify();

-- =============================================================================
-- 5. EVENTS IN ACTION
-- =============================================================================
-- Reset this demo's channels so reruns print the same output
DELETE FROM messaging.notification_log    WHERE channel_name IN ('permit_events', 'order_batches', 'work_items', 'dashboard_stats');
DELETE FROM messaging.message_queue       WHERE channel_name IN ('permit_events', 'order_batches', 'work_items', 'dashboard_stats');
DELETE FROM messaging.channel_subscribers WHERE channel_name IN ('permit_events', 'order_batches');

LISTEN permit_events;
LISTEN order_batches;

SELECT messaging.subscribe_to_channel('permit_events', 'permit_dashboard');
SELECT messaging.subscribe_to_channel('order_batches', 'finance_service', 'both');

\echo '-- row-level events: approve 3 permits in one transaction -> 3 notifications at COMMIT'
BEGIN;
UPDATE messaging.permit_requests SET status = 'approved'
WHERE permit_id IN (SELECT permit_id FROM messaging.permit_requests WHERE status = 'pending'
                    ORDER BY permit_id LIMIT 3);
COMMIT;

\echo '-- statement-level event: load 500 December orders -> exactly 1 notification'
INSERT INTO messaging.orders_feed
SELECT order_id, merchant_id, status::TEXT, total_amount, order_date
FROM commerce.orders
WHERE order_date >= meta.as_of() - interval '31 days'
ORDER BY order_id
LIMIT 500
ON CONFLICT (order_id) DO NOTHING;

\echo '-- an oversized payload is persisted and only a pointer is notified'
SELECT messaging.notify_channel('order_batches', 'bulk_export',
                                jsonb_build_object('blob', repeat('y', 9000)), 'export_job') > 0
       AS persisted_with_pointer;

SELECT channel_name, event_type, delivery_method, subscriber_count,
       left(payload::TEXT, 60) AS payload_start
FROM messaging.notification_log
WHERE channel_name IN ('permit_events', 'order_batches')
ORDER BY log_id DESC
LIMIT 6;

-- =============================================================================
-- 6. DURABLE QUEUE: persist, then consume with SKIP LOCKED
-- =============================================================================
\echo '-- persisted messages survive a disconnected listener; a worker drains them later'
SELECT messaging.notify_channel('work_items', 'resize_image', jsonb_build_object('image_id', g), 'uploader', TRUE)
FROM generate_series(1, 3) g;

SELECT * FROM messaging.process_queue_messages('work_items', 10) ORDER BY message_id;

SELECT status, count(*) FROM messaging.message_queue
WHERE channel_name = 'work_items' GROUP BY status ORDER BY status;

-- =============================================================================
-- 7. CHANNEL MANAGEMENT, HEALTH, CLEANUP
-- =============================================================================
CREATE OR REPLACE FUNCTION messaging.list_active_channels()
RETURNS TABLE(channel_name TEXT, subscriber_count BIGINT, last_message_at TIMESTAMPTZ,
              total_messages BIGINT, active_subscribers TEXT[])
LANGUAGE sql STABLE AS $$
    SELECT cs.channel_name,
           count(*) FILTER (WHERE cs.is_active),
           (SELECT max(nl.notification_sent_at) FROM messaging.notification_log nl WHERE nl.channel_name = cs.channel_name),
           (SELECT count(*) FROM messaging.notification_log nl WHERE nl.channel_name = cs.channel_name),
           array_agg(cs.subscriber_id ORDER BY cs.subscriber_id) FILTER (WHERE cs.is_active)
    FROM messaging.channel_subscribers cs
    GROUP BY cs.channel_name
    HAVING count(*) FILTER (WHERE cs.is_active) > 0
    ORDER BY 2 DESC, 1
$$;

CREATE OR REPLACE FUNCTION messaging.cleanup_old_notifications(retention_days INTEGER DEFAULT 30)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM messaging.notification_log
    WHERE notification_sent_at < now() - make_interval(days => retention_days);
    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    DELETE FROM messaging.message_queue
    WHERE status = 'completed' AND processed_at < now() - make_interval(days => retention_days);
    RETURN deleted_count;
END $$;

CREATE OR REPLACE FUNCTION messaging.health_check()
RETURNS TABLE(component TEXT, status TEXT, metric_value TEXT, last_check TIMESTAMPTZ)
LANGUAGE sql STABLE AS $$
    SELECT 'Active subscribers', CASE WHEN count(*) > 0 THEN 'OK' ELSE 'WARNING' END, count(*)::TEXT, now()
    FROM messaging.channel_subscribers WHERE is_active
    UNION ALL
    SELECT 'Pending messages',
           CASE WHEN count(*) = 0 THEN 'OK' WHEN count(*) < 100 THEN 'WARNING' ELSE 'CRITICAL' END,
           count(*)::TEXT, now()
    FROM messaging.message_queue WHERE status = 'pending'
    UNION ALL
    SELECT 'Failed / dead-letter messages', CASE WHEN count(*) > 0 THEN 'WARNING' ELSE 'OK' END, count(*)::TEXT, now()
    FROM messaging.message_queue WHERE status IN ('failed', 'dead_letter')
    UNION ALL
    SELECT 'Notifications in the last hour', 'INFO', count(*)::TEXT, now()
    FROM messaging.notification_log WHERE notification_sent_at >= now() - interval '1 hour'
    UNION ALL
    SELECT 'NOTIFY queue usage',
           CASE WHEN pg_notification_queue_usage() > 0.5 THEN 'CRITICAL' ELSE 'OK' END,
           round(pg_notification_queue_usage()::NUMERIC * 100, 4)::TEXT || '%', now()
$$;

SELECT channel_name, subscriber_count, total_messages, active_subscribers
FROM messaging.list_active_channels();
SELECT component, status, metric_value FROM messaging.health_check();

-- Dashboard snapshot, published to 'dashboard_stats'.  Business metrics use the dataset
-- clock meta.as_of(); messaging metrics use wall-clock time.
CREATE OR REPLACE FUNCTION messaging.get_realtime_stats()
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    stats JSONB;
BEGIN
    SELECT jsonb_build_object(
        'active_citizens',    (SELECT count(*) FROM civics.citizens WHERE status = 'active'),
        'pending_permits',    (SELECT count(*) FROM civics.permit_applications WHERE status = 'pending'),
        'orders_last_7_days', (SELECT count(*) FROM commerce.orders
                               WHERE order_date >  meta.as_of() - interval '7 days'
                                 AND order_date <= meta.as_of()),
        'messages_last_hour', (SELECT count(*) FROM messaging.notification_log
                               WHERE notification_sent_at >= now() - interval '1 hour'),
        'active_channels',    (SELECT count(DISTINCT channel_name) FROM messaging.channel_subscribers WHERE is_active),
        'as_of',              meta.as_of(),
        'last_updated',       now())
    INTO stats;

    PERFORM messaging.notify_channel('dashboard_stats', 'stats_update', stats, 'stats_system');
    RETURN stats;
END $$;

SELECT jsonb_pretty(messaging.get_realtime_stats() - 'last_updated') AS dashboard_stats;

-- =============================================================================
-- 8. CLIENT-SIDE PATTERNS (reference)
-- =============================================================================
-- psql:      LISTEN permit_events;   then any command (or \watch) shows queued notifications
-- Python:    psycopg 3:  conn = psycopg.connect(..., autocommit=True)
--                         conn.execute("LISTEN permit_events")
--                         for n in conn.notifies(): print(n.channel, n.payload)
-- Node:      pg:  client.query('LISTEN permit_events'); client.on('notification', m => ...)
-- Rules:     * listen on a dedicated connection that is NOT in a transaction-mode pool
--              (PgBouncer transaction pooling drops LISTEN state)
--            * after reconnecting, re-LISTEN and then re-read the outbox table: notifications
--              sent while you were away are gone
--            * NOTIFY takes a global lock at commit; extremely high NOTIFY rates serialize commits

-- Leave the session clean
UNLISTEN *;
\echo '== LISTEN/NOTIFY module complete =='
