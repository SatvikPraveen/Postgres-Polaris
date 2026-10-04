-- File: sql/05_functions_triggers/event_triggers.sql
-- Purpose: DDL auditing and DDL guard rails with event triggers.
--
-- Event triggers are DATABASE-WIDE (they fire for every DDL statement in the
-- database, from every session) and require superuser to create. A buggy one
-- can block all DDL. This lesson therefore:
--   1. creates the log table and trigger functions permanently,
--   2. creates the event triggers, exercises them on module-owned objects,
--   3. DROPS the event triggers at the end so later modules run unaffected.
-- To keep DDL auditing on in your own environment, re-run section 3 only.
--
-- Escape hatch if an event trigger ever locks you out of DDL:
--   PostgreSQL 17+:  SET event_triggers = off;   (superuser, per session)
--   older versions:  restart in single-user mode, where event triggers are off.

\echo '== 05 event_triggers: setup =='

-- Start clean (also makes the file safe to re-run after an interrupted run).
DROP EVENT TRIGGER IF EXISTS ddl_audit_trigger;
DROP EVENT TRIGGER IF EXISTS drop_audit_trigger;
DROP EVENT TRIGGER IF EXISTS ddl_guard_trigger;
DROP EVENT TRIGGER IF EXISTS table_rewrite_trigger;
DROP EVENT TRIGGER IF EXISTS ddl_authorization_trigger;

-- =============================================================================
-- 1. DDL AUDIT LOG TABLE (module-owned)
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.ddl_events (
    event_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type       TEXT NOT NULL,          -- ddl_command_end / sql_drop / table_rewrite / maintenance
    event_tag        TEXT NOT NULL,          -- e.g. CREATE TABLE, ALTER TABLE, DROP INDEX
    schema_name      TEXT,
    object_name      TEXT,                   -- fully qualified object identity
    object_type      TEXT,
    command          TEXT,                   -- command tag of the sub-command
    query_text       TEXT,                   -- top-level statement text
    user_name        TEXT NOT NULL,
    client_addr      INET,
    event_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    backend_pid      INTEGER     NOT NULL DEFAULT pg_backend_pid(),
    transaction_id   XID8        NOT NULL DEFAULT pg_current_xact_id(),
    application_name TEXT
);

COMMENT ON TABLE audit.ddl_events IS
'DDL audit log written by the event-trigger functions in sql/05_functions_triggers/event_triggers.sql.';

CREATE INDEX IF NOT EXISTS idx_ddl_events_time   ON audit.ddl_events (event_time);
CREATE INDEX IF NOT EXISTS idx_ddl_events_object ON audit.ddl_events (schema_name, object_name);
CREATE INDEX IF NOT EXISTS idx_ddl_events_type   ON audit.ddl_events (event_type, event_tag);

-- =============================================================================
-- 2. EVENT TRIGGER FUNCTIONS
-- =============================================================================
-- Events (PostgreSQL 17):
--   login             - after a successful login (new in 17; see note below)
--   ddl_command_start - before the command runs; no object info available yet
--   ddl_command_end   - after it ran; pg_event_trigger_ddl_commands() lists
--                       every object created/altered (one row per sub-command)
--   sql_drop          - after objects are dropped; pg_event_trigger_dropped_objects()
--   table_rewrite     - before a table is rewritten (ALTER TYPE, VOLATILE
--                       DEFAULT...); pg_event_trigger_table_rewrite_oid()/_reason()
-- An exception raised in any of them aborts the DDL statement.
-- Event triggers do NOT fire for DDL on shared objects (databases, roles,
-- tablespaces) nor for commands on event triggers themselves.

-- Log every created/altered object.
CREATE OR REPLACE FUNCTION audit.log_ddl_command()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        -- Skip temporary objects and our own log table to avoid noise.
        CONTINUE WHEN obj.in_extension OR obj.schema_name LIKE 'pg_temp%';
        INSERT INTO audit.ddl_events (event_type, event_tag, schema_name, object_name,
                                      object_type, command, query_text, user_name,
                                      client_addr, application_name)
        VALUES (TG_EVENT, TG_TAG, obj.schema_name, obj.object_identity,
                obj.object_type, obj.command_tag, left(current_query(), 1000), session_user,
                inet_client_addr(), current_setting('application_name', true));
    END LOOP;
END;
$$;

-- Log dropped objects (fires once per DROP statement; lists dependents too).
CREATE OR REPLACE FUNCTION audit.log_dropped_objects()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP
        CONTINUE WHEN obj.is_temporary;
        INSERT INTO audit.ddl_events (event_type, event_tag, schema_name, object_name,
                                      object_type, command, query_text, user_name,
                                      client_addr, application_name)
        VALUES (TG_EVENT, TG_TAG, obj.schema_name, obj.object_identity,
                obj.object_type, CASE WHEN obj.original THEN 'original' ELSE 'dependent' END,
                left(current_query(), 1000), session_user,
                inet_client_addr(), current_setting('application_name', true));
    END LOOP;
END;
$$;

-- Log table rewrites: these take an ACCESS EXCLUSIVE lock for the whole
-- rewrite, so knowing when they happen matters on big tables.
-- Reason bits: 1 = persistence change (SET LOGGED/UNLOGGED), 2 = column
-- default needs evaluation (e.g. volatile DEFAULT), 4 = column type change,
-- 8 = access method change.
CREATE OR REPLACE FUNCTION audit.log_table_rewrite()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    INSERT INTO audit.ddl_events (event_type, event_tag, object_name, object_type,
                                  command, query_text, user_name)
    VALUES (TG_EVENT, TG_TAG, pg_event_trigger_table_rewrite_oid()::regclass::text, 'table',
            'rewrite reason bits=' || pg_event_trigger_table_rewrite_reason(),
            left(current_query(), 1000), session_user);
END;
$$;

-- GUARD: forbid dropping tables/views/functions in the core data schemas
-- unless the session explicitly opts in with  SET polaris.allow_core_drop = on.
-- Fixed bug from the older version: it called pg_event_trigger_ddl_commands()
-- from a ddl_command_start trigger, which is only allowed in ddl_command_end.
-- sql_drop runs after the objects are gone but still inside the transaction,
-- so raising here undoes the DROP.
CREATE OR REPLACE FUNCTION audit.prevent_unauthorized_ddl()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    obj RECORD;
    protected_schemas CONSTANT TEXT[] := ARRAY['civics', 'commerce', 'mobility', 'geo', 'documents'];
BEGIN
    IF COALESCE(current_setting('polaris.allow_core_drop', true), 'off') = 'on' THEN
        RETURN;
    END IF;

    FOR obj IN
        SELECT * FROM pg_event_trigger_dropped_objects()
        WHERE original
          AND schema_name = ANY (protected_schemas)
          AND object_type IN ('table', 'view', 'materialized view', 'function', 'type')
    LOOP
        RAISE EXCEPTION 'DROP of % % is blocked by event trigger ddl_guard_trigger', obj.object_type, obj.object_identity
            USING ERRCODE = 'insufficient_privilege',
                  HINT = 'SET polaris.allow_core_drop = on in this session if the drop is intended';
    END LOOP;
END;
$$;

\echo '== 05 event_triggers: create event triggers and exercise them =='

-- =============================================================================
-- 3. CREATE EVENT TRIGGERS
-- =============================================================================

CREATE EVENT TRIGGER ddl_audit_trigger
    ON ddl_command_end
    EXECUTE FUNCTION audit.log_ddl_command();

CREATE EVENT TRIGGER drop_audit_trigger
    ON sql_drop
    EXECUTE FUNCTION audit.log_dropped_objects();

CREATE EVENT TRIGGER table_rewrite_trigger
    ON table_rewrite
    WHEN TAG IN ('ALTER TABLE')
    EXECUTE FUNCTION audit.log_table_rewrite();

-- Filtered with WHEN TAG so the function only runs for DROP commands.
CREATE EVENT TRIGGER ddl_guard_trigger
    ON sql_drop
    WHEN TAG IN ('DROP TABLE', 'DROP VIEW', 'DROP MATERIALIZED VIEW', 'DROP FUNCTION', 'DROP TYPE')
    EXECUTE FUNCTION audit.prevent_unauthorized_ddl();

SELECT evtname, evtevent, evtfoid::regproc AS function, evtenabled, evttags
FROM pg_event_trigger
ORDER BY evtname;

-- =============================================================================
-- 4. EXERCISE THEM ON MODULE-OWNED OBJECTS
-- =============================================================================

-- Each statement below is logged by ddl_audit_trigger / drop_audit_trigger.
DROP TABLE IF EXISTS analytics.et_demo_scratch;   -- analytics is not protected
CREATE TABLE analytics.et_demo_scratch (
    id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note TEXT
);
INSERT INTO analytics.et_demo_scratch (note) SELECT 'row ' || g FROM generate_series(1, 100) g;
CREATE INDEX et_demo_scratch_note_idx ON analytics.et_demo_scratch (note);
ALTER TABLE analytics.et_demo_scratch ADD COLUMN amount NUMERIC DEFAULT 0;         -- no rewrite (fast default, PG11+)
ALTER TABLE analytics.et_demo_scratch ALTER COLUMN id TYPE BIGINT;                  -- rewrite -> table_rewrite fires
DROP INDEX analytics.et_demo_scratch_note_idx;

-- The guard: dropping a table in a protected schema is refused...
CREATE TABLE IF NOT EXISTS documents.et_guard_demo (id INTEGER);
DO $$
BEGIN
    DROP TABLE documents.et_guard_demo;
    RAISE NOTICE 'unexpected: drop was allowed';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Guard worked: %', SQLERRM;
END;
$$;
SELECT to_regclass('documents.et_guard_demo') IS NOT NULL AS still_exists_after_blocked_drop;

-- ...unless the session explicitly opts in.
SET polaris.allow_core_drop = on;
DROP TABLE documents.et_guard_demo;
RESET polaris.allow_core_drop;

DROP TABLE analytics.et_demo_scratch;

-- What was logged by this run (latest backend only).
SELECT event_type, event_tag, object_type, object_name, command
FROM audit.ddl_events
WHERE backend_pid = pg_backend_pid()
  AND event_time >= now() - interval '1 hour'
  AND (object_name LIKE '%et_demo_scratch%' OR object_name LIKE '%et_guard_demo%')
ORDER BY event_id;

-- =============================================================================
-- 5. DDL AUDIT ANALYSIS FUNCTIONS
-- =============================================================================
-- These report on audit rows stamped with now(), so wall-clock windows are
-- correct here (meta.as_of() is only for the synthetic dataset).

-- Earlier versions had different signatures / result columns.
DROP FUNCTION IF EXISTS audit.analyze_ddl_patterns();
DROP FUNCTION IF EXISTS audit.get_ddl_audit_stats();

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
)
LANGUAGE sql
STABLE
AS $$
    SELECT de.event_time, de.event_tag, de.object_name, de.object_type, de.user_name, de.schema_name
    FROM audit.ddl_events de
    WHERE de.event_time >= now() - make_interval(hours => hours_back)
      AND (schema_filter IS NULL OR de.schema_name = schema_filter)
      AND de.event_type IN ('ddl_command_end', 'sql_drop', 'table_rewrite')
    ORDER BY de.event_time DESC, de.event_id DESC;
$$;

CREATE OR REPLACE FUNCTION audit.analyze_ddl_patterns(days_back INTEGER DEFAULT 30)
RETURNS TABLE(
    event_tag TEXT,
    frequency BIGINT,
    unique_users BIGINT,
    most_active_user TEXT,
    most_recent TIMESTAMPTZ,
    affected_schemas TEXT[]
)
LANGUAGE sql
STABLE
AS $$
    SELECT de.event_tag,
           count(*),
           count(DISTINCT de.user_name),
           mode() WITHIN GROUP (ORDER BY de.user_name),
           max(de.event_time),
           array_agg(DISTINCT de.schema_name ORDER BY de.schema_name)
               FILTER (WHERE de.schema_name IS NOT NULL)
    FROM audit.ddl_events de
    WHERE de.event_time >= now() - make_interval(days => days_back)
      AND de.event_type <> 'maintenance'
    GROUP BY de.event_tag
    ORDER BY count(*) DESC, de.event_tag;
$$;

CREATE OR REPLACE FUNCTION audit.get_ddl_audit_stats()
RETURNS TABLE(
    total_events BIGINT,
    unique_event_tags BIGINT,
    unique_users BIGINT,
    date_range TEXT,
    most_common_event TEXT,
    most_active_user TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT count(*),
           count(DISTINCT event_tag),
           count(DISTINCT user_name),
           min(event_time)::date || ' to ' || max(event_time)::date,
           mode() WITHIN GROUP (ORDER BY event_tag),
           mode() WITHIN GROUP (ORDER BY user_name)
    FROM audit.ddl_events
    WHERE event_type <> 'maintenance';
$$;

-- Retention: delete old rows and record that we did.
CREATE OR REPLACE FUNCTION audit.cleanup_ddl_audit(retention_days INTEGER DEFAULT 365)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM audit.ddl_events
    WHERE event_time < now() - make_interval(days => retention_days);
    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    INSERT INTO audit.ddl_events (event_type, event_tag, object_name, user_name, application_name)
    VALUES ('maintenance', 'AUDIT_CLEANUP',
            format('Cleaned up %s DDL audit records older than %s days', deleted_count, retention_days),
            session_user, 'audit_maintenance');
    RETURN deleted_count;
END;
$$;

-- Enable/disable the audit triggers (ALTER EVENT TRIGGER ... ENABLE/DISABLE).
-- Raises a clear error if section 3 has not been run.
CREATE OR REPLACE FUNCTION audit.toggle_ddl_auditing(enable_auditing BOOLEAN)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_trg TEXT;
BEGIN
    FOREACH v_trg IN ARRAY ARRAY['ddl_audit_trigger', 'drop_audit_trigger'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = v_trg) THEN
            RAISE EXCEPTION 'event trigger % does not exist; create it first (section 3)', v_trg;
        END IF;
        EXECUTE format('ALTER EVENT TRIGGER %I %s', v_trg, CASE WHEN enable_auditing THEN 'ENABLE' ELSE 'DISABLE' END);
    END LOOP;

    INSERT INTO audit.ddl_events (event_type, event_tag, object_name, user_name)
    VALUES ('maintenance', 'AUDIT_TOGGLE',
            CASE WHEN enable_auditing THEN 'DDL auditing enabled' ELSE 'DDL auditing disabled' END,
            session_user);
    RETURN CASE WHEN enable_auditing THEN 'DDL auditing enabled' ELSE 'DDL auditing disabled' END;
END;
$$;

-- Demonstrate toggling: DDL while disabled is not logged.
SELECT audit.toggle_ddl_auditing(false);
CREATE TABLE analytics.et_untracked (id INTEGER);
DROP TABLE analytics.et_untracked;
SELECT audit.toggle_ddl_auditing(true);
SELECT count(*) AS untracked_events_logged
FROM audit.ddl_events
WHERE object_name LIKE '%et_untracked%' AND backend_pid = pg_backend_pid();

SELECT event_tag, frequency, unique_users, affected_schemas
FROM audit.analyze_ddl_patterns()
LIMIT 10;

-- =============================================================================
-- 6. PostgreSQL 17: LOGIN EVENT TRIGGERS (shown, not installed)
-- =============================================================================
-- A login trigger runs on every new connection. A failing one blocks logins
-- for everyone except via `SET event_triggers = off` / single-user mode, so it
-- is shown here as commented reference only:
--
--   CREATE TABLE audit.logins (usr text, at timestamptz DEFAULT now(), app text);
--   CREATE FUNCTION audit.on_login() RETURNS event_trigger LANGUAGE plpgsql AS $$
--   BEGIN
--       IF pg_is_in_recovery() THEN RETURN; END IF;   -- standbys are read-only
--       INSERT INTO audit.logins(usr, app) VALUES (session_user, current_setting('application_name'));
--   END $$;
--   CREATE EVENT TRIGGER login_audit ON login EXECUTE FUNCTION audit.on_login();

\echo '== 05 event_triggers: cleanup (event triggers are database-wide) =='

-- =============================================================================
-- 7. CLEANUP: remove the database-wide event triggers
-- =============================================================================
-- The log table and functions stay for reference; the triggers go, so later
-- modules' DDL is neither slowed nor blocked by the guard.
DROP EVENT TRIGGER IF EXISTS ddl_audit_trigger;
DROP EVENT TRIGGER IF EXISTS drop_audit_trigger;
DROP EVENT TRIGGER IF EXISTS table_rewrite_trigger;
DROP EVENT TRIGGER IF EXISTS ddl_guard_trigger;

SELECT count(*) AS event_triggers_remaining FROM pg_event_trigger;
