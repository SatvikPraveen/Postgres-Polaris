-- File: sql/05_functions_triggers/event_triggers.sql
-- Purpose: DDL auditing demos with event triggers

-- =============================================================================
-- DDL AUDIT INFRASTRUCTURE
-- =============================================================================

-- Table to log DDL events
CREATE TABLE IF NOT EXISTS audit.ddl_events (
    event_id BIGSERIAL PRIMARY KEY,
    event_type TEXT NOT NULL,
    event_tag TEXT NOT NULL,
    schema_name TEXT,
    object_name TEXT,
    object_type TEXT,
    command TEXT,
    user_name TEXT NOT NULL,
    client_addr INET,
    event_time TIMESTAMPTZ DEFAULT NOW(),
    session_id TEXT,
    application_name TEXT
);

CREATE INDEX idx_ddl_events_time ON audit.ddl_events(event_time);
CREATE INDEX idx_ddl_events_object ON audit.ddl_events(schema_name, object_name);
CREATE INDEX idx_ddl_events_type ON audit.ddl_events(event_type, event_tag);

-- =============================================================================
-- EVENT TRIGGER FUNCTIONS
-- =============================================================================

-- Log DDL commands
CREATE OR REPLACE FUNCTION audit.log_ddl_command()
RETURNS event_trigger AS $$
DECLARE
    obj RECORD;
    cmd_record RECORD;
BEGIN
    -- Log the DDL event
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        INSERT INTO audit.ddl_events (
            event_type, event_tag, schema_name, object_name,
            object_type, command, user_name, client_addr,
            session_id, application_name
        ) VALUES (
            'ddl_command_end',
            TG_TAG,
            obj.schema_name,
            obj.object_identity,
            obj.object_type,
            obj.command_tag,
            SESSION_USER,
            INET_CLIENT_ADDR(),
            TO_HEX(EXTRACT(EPOCH FROM NOW())::BIGINT) || '-' || TO_HEX(PG_BACKEND_PID()),
            current_setting('application_name', true)
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Log dropped objects
CREATE OR REPLACE FUNCTION audit.log_dropped_objects()
RETURNS event_trigger AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
    LOOP
        INSERT INTO audit.ddl_events (
            event_type, event_tag, schema_name, object_name,
            object_type, user_name, client_addr, session_id, application_name
        ) VALUES (
            'sql_drop',
            TG_TAG,
            obj.schema_name,
            obj.object_identity,
            obj.object_type,
            SESSION_USER,
            INET_CLIENT_ADDR(),
            TO_HEX(EXTRACT(EPOCH FROM NOW())::BIGINT) || '-' || TO_HEX(PG_BACKEND_PID()),
            current_setting('application_name', true)
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Prevent unauthorized schema changes
CREATE OR REPLACE FUNCTION audit.prevent_unauthorized_ddl()
RETURNS event_trigger AS $$
DECLARE
    allowed_users TEXT[] := ARRAY['postgres', 'admin', 'schema_owner'];
    current_user_name TEXT := SESSION_USER;
    restricted_schemas TEXT[] := ARRAY['civics', 'commerce', 'mobility', 'geo', 'documents'];
    target_schema TEXT;
BEGIN
    -- Extract schema from DDL command context
    SELECT schema_name INTO target_schema
    FROM pg_event_trigger_ddl_commands()
    LIMIT 1;

    -- Check if this is a restricted schema
    IF target_schema = ANY(restricted_schemas) AND current_user_name != ALL(allowed_users) THEN
        RAISE EXCEPTION 'DDL operations on schema "%" are restricted. User "%" is not authorized.',
            target_schema, current_user_name
        USING HINT = 'Contact database administrator for schema changes';
    END IF;

    -- Log the attempt regardless
    INSERT INTO audit.ddl_events (
        event_type, event_tag, schema_name, object_name,
        user_name, client_addr, session_id, application_name
    ) VALUES (
        'ddl_authorization_check',
        TG_TAG,
        target_schema,
        'N/A',
        SESSION_USER,
        INET_CLIENT_ADDR(),
        TO_HEX(EXTRACT(EPOCH FROM NOW())::BIGINT) || '-' || TO_HEX(PG_BACKEND_PID()),
        current_setting('application_name', true)
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- CREATE EVENT TRIGGERS
-- =============================================================================

-- Event trigger for DDL command completion
CREATE EVENT TRIGGER ddl_audit_trigger
    ON ddl_command_end
    EXECUTE FUNCTION audit.log_ddl_command();

-- Event trigger for object drops
CREATE EVENT TRIGGER drop_audit_trigger
    ON sql_drop
    EXECUTE FUNCTION audit.log_dropped_objects();

-- Event trigger for authorization (commented out - enable as needed)
-- CREATE EVENT TRIGGER ddl_authorization_trigger
--     ON ddl_command_start
--     EXECUTE FUNCTION audit.prevent_unauthorized_ddl();

-- =============================================================================
-- DDL AUDIT ANALYSIS FUNCTIONS
-- =============================================================================

-- Get recent DDL activity
CREATE OR REPLACE FUNCTION audit.get_recent_ddl_activity(
    hours_back INTEGER DEFAULT 24,
    schema_filter TEXT DEFAULT NULL
)
RETURNS TABLE(
    event_time TIMESTAMPTZ,
    event_tag TEXT,
    object_identity TEXT,
    object_type TEXT,
    user_name TEXT,
    schema_name TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        de.event_time,
        de.event_tag,
        de.object_name as object_identity,
        de.object_type,
        de.user_name,
        de.schema_name
    FROM audit.ddl_events de
    WHERE de.event_time >= NOW() - (hours_back || ' hours')::INTERVAL
        AND (schema_filter IS NULL OR de.schema_name = schema_filter)
        AND de.event_type != 'ddl_authorization_check'
    ORDER BY de.event_time DESC;
END;
$$ LANGUAGE plpgsql;

-- Analyze DDL patterns
CREATE OR REPLACE FUNCTION audit.analyze_ddl_patterns()
RETURNS TABLE(
    event_tag TEXT,
    frequency BIGINT,
    unique_users BIGINT,
    most_active_user TEXT,
    most_recent TIMESTAMPTZ,
    affected_schemas TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        de.event_tag,
        COUNT(*) as frequency,
        COUNT(DISTINCT de.user_name) as unique_users,
        MODE() WITHIN GROUP (ORDER BY de.user_name) as most_active_user,
        MAX(de.event_time) as most_recent,
        ARRAY_AGG(DISTINCT de.schema_name ORDER BY de.schema_name)
            FILTER (WHERE de.schema_name IS NOT NULL) as affected_schemas
    FROM audit.ddl_events de
    WHERE de.event_time >= CURRENT_DATE - INTERVAL '30 days'
        AND de.event_type != 'ddl_authorization_check'
    GROUP BY de.event_tag
    ORDER BY frequency DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DEMONSTRATION SCENARIOS
-- =============================================================================

-- Function to simulate DDL activity for testing
CREATE OR REPLACE FUNCTION audit.demo_ddl_activity()
RETURNS TEXT AS $$
DECLARE
    result TEXT := 'DDL Demo Activity Results:' || E'\n';
BEGIN
    -- Create a temporary table (will be logged)
    CREATE TEMP TABLE demo_temp_table (
        id SERIAL PRIMARY KEY,
        demo_data TEXT,
        created_at TIMESTAMPTZ DEFAULT NOW()
    );
    result := result || '1. Created temporary table' || E'\n';

    -- Add a column (will be logged)
    ALTER TABLE demo_temp_table ADD COLUMN extra_field INTEGER;
    result := result || '2. Added column to temp table' || E'\n';

    -- Create an index (will be logged)
    CREATE INDEX idx_demo_temp_data ON demo_temp_table(demo_data);
    result := result || '3. Created index on temp table' || E'\n';

    -- Drop the index (will be logged)
    DROP INDEX idx_demo_temp_data;
    result := result || '4. Dropped index from temp table' || E'\n';

    -- Create a view (will be logged)
    CREATE TEMP VIEW demo_temp_view AS
    SELECT id, demo_data, created_at
    FROM demo_temp_table
    WHERE created_at >= CURRENT_DATE;
    result := result || '5. Created temporary view' || E'\n';

    -- Drop the view and table (will be logged)
    DROP VIEW demo_temp_view;
    DROP TABLE demo_temp_table;
    result := result || '6. Dropped view and table' || E'\n';

    result := result || E'\nCheck audit.ddl_events table for logged events.';

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DDL AUDIT MAINTENANCE
-- =============================================================================

-- Clean up old DDL audit records
CREATE OR REPLACE FUNCTION audit.cleanup_ddl_audit(
    retention_days INTEGER DEFAULT 365
)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM audit.ddl_events
    WHERE event_time < CURRENT_DATE - (retention_days || ' days')::INTERVAL;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    -- Log the cleanup operation
    INSERT INTO audit.ddl_events (
        event_type, event_tag, object_name, user_name,
        session_id, application_name
    ) VALUES (
        'maintenance',
        'AUDIT_CLEANUP',
        format('Cleaned up %s DDL audit records older than %s days', deleted_count, retention_days),
        SESSION_USER,
        TO_HEX(EXTRACT(EPOCH FROM NOW())::BIGINT) || '-' || TO_HEX(PG_BACKEND_PID()),
        'audit_maintenance'
    );

    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Get DDL audit statistics
CREATE OR REPLACE FUNCTION audit.get_ddl_audit_stats()
RETURNS TABLE(
    total_events BIGINT,
    unique_event_types BIGINT,
    unique_users BIGINT,
    date_range TEXT,
    most_common_event TEXT,
    most_active_user TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COUNT(*) as total_events,
        COUNT(DISTINCT event_tag) as unique_event_types,
        COUNT(DISTINCT user_name) as unique_users,
        MIN(event_time)::DATE || ' to ' || MAX(event_time)::DATE as date_range,
        MODE() WITHIN GROUP (ORDER BY event_tag) as most_common_event,
        MODE() WITHIN GROUP (ORDER BY user_name) as most_active_user
    FROM audit.ddl_events
    WHERE event_type != 'maintenance';
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- EVENT TRIGGER MANAGEMENT
-- =============================================================================

-- Function to enable/disable event triggers
CREATE OR REPLACE FUNCTION audit.toggle_ddl_auditing(
    enable_auditing BOOLEAN
)
RETURNS TEXT AS $$
DECLARE
    result TEXT;
BEGIN
    IF enable_auditing THEN
        -- Enable event triggers
        ALTER EVENT TRIGGER ddl_audit_trigger ENABLE;
        ALTER EVENT TRIGGER drop_audit_trigger ENABLE;
        result := 'DDL auditing enabled';
    ELSE
        -- Disable event triggers
        ALTER EVENT TRIGGER ddl_audit_trigger DISABLE;
        ALTER EVENT TRIGGER drop_audit_trigger DISABLE;
        result := 'DDL auditing disabled';
    END IF;

    -- Log the change
    INSERT INTO audit.ddl_events (
        event_type, event_tag, object_name, user_name
    ) VALUES (
        'system_change',
        'AUDIT_TOGGLE',
        result,
        SESSION_USER
    );

    RETURN result;
END;
$$ LANGUAGE plpgsql;
