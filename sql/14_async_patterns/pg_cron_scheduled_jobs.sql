-- File: sql/14_async_patterns/pg_cron_scheduled_jobs.sql
-- Purpose: scheduled refreshes and maintenance with pg_cron, plus a job log you can audit
--
-- What this module teaches
--   1. pg_cron basics: cron.schedule / cron.unschedule / cron.alter_job, cron.job and
--      cron.job_run_details; schedules in cron syntax or '<n> seconds' (pg_cron 1.5+)
--   2. pg_cron runs in ONE database (cron.database_name, here: polaris); use
--      cron.schedule_in_database to run commands elsewhere
--   3. Writing job bodies: idempotent functions that log start/finish; things that cannot run
--      inside a function or transaction block (VACUUM, CREATE INDEX CONCURRENTLY,
--      REINDEX CONCURRENTLY) must be the cron command itself
--   4. Using the dataset clock meta.as_of() for business windows, now() for job timing
--
-- Portability: every cron.* call is guarded by job_scheduler.cron_available(), so this file
-- runs everywhere.  In databases without pg_cron the job bodies are executed manually once
-- to show what a scheduled run would do.  If pg_cron is present, the single demo job this file
-- schedules is unscheduled again at the end.
-- Safety: all tables touched by jobs are module-owned (schema job_scheduler).

\echo '== 14 / pg_cron scheduled jobs =='

-- =============================================================================
-- 0. IS pg_cron AVAILABLE HERE?
-- =============================================================================
-- Server-side setup (already done in this lab's postgresql.conf):
--   shared_preload_libraries = 'pg_cron'
--   cron.database_name       = 'polaris'      -- the only DB where CREATE EXTENSION pg_cron works
--   cron.use_background_workers = on          -- optional: no libpq connections needed
CREATE SCHEMA IF NOT EXISTS job_scheduler;

CREATE OR REPLACE FUNCTION job_scheduler.cron_available()
RETURNS BOOLEAN LANGUAGE sql STABLE AS
$$ SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') $$;

SELECT current_database()                                   AS this_database,
       current_setting('cron.database_name', true)          AS cron_database,
       job_scheduler.cron_available()                       AS pg_cron_installed_here,
       (SELECT default_version FROM pg_available_extensions WHERE name = 'pg_cron') AS pg_cron_version_available;

DO $$
BEGIN
    IF NOT job_scheduler.cron_available() THEN
        RAISE NOTICE 'pg_cron is not installed in database "%" (it lives in "%"): cron.* calls will be skipped, job bodies run manually instead',
            current_database(), COALESCE(current_setting('cron.database_name', true), 'postgres');
    END IF;
END $$;

-- =============================================================================
-- 1. JOB REGISTRY AND EXECUTION LOG
-- =============================================================================
CREATE TABLE IF NOT EXISTS job_scheduler.job_execution_log (
    execution_id      BIGSERIAL PRIMARY KEY,
    job_name          TEXT NOT NULL,
    cron_job_id       BIGINT,
    started_at        TIMESTAMPTZ DEFAULT clock_timestamp(),
    completed_at      TIMESTAMPTZ,
    duration_seconds  NUMERIC GENERATED ALWAYS AS (EXTRACT(epoch FROM (completed_at - started_at))) STORED,
    status            TEXT CHECK (status IN ('running', 'completed', 'failed', 'cancelled')) DEFAULT 'running',
    rows_affected     BIGINT,
    error_message     TEXT,
    execution_details JSONB
);

CREATE TABLE IF NOT EXISTS job_scheduler.scheduled_jobs (
    job_id                BIGSERIAL PRIMARY KEY,
    job_name              TEXT NOT NULL UNIQUE,
    job_description       TEXT,
    cron_schedule         TEXT NOT NULL,      -- '0 2 * * *' or '30 seconds'
    job_command           TEXT NOT NULL,
    cron_job_id           BIGINT,             -- cron.job.jobid when actually scheduled
    is_active             BOOLEAN DEFAULT TRUE,
    last_run              TIMESTAMPTZ,
    total_executions      BIGINT DEFAULT 0,
    successful_executions BIGINT DEFAULT 0,
    created_at            TIMESTAMPTZ DEFAULT now(),
    created_by            TEXT DEFAULT current_user
);

CREATE OR REPLACE FUNCTION job_scheduler.log_job_start(job_name TEXT, cron_job_id BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO job_scheduler.job_execution_log (job_name, cron_job_id)
    VALUES (job_name, cron_job_id)
    RETURNING execution_id INTO v_id;

    UPDATE job_scheduler.scheduled_jobs s
    SET last_run = now(), total_executions = s.total_executions + 1
    WHERE s.job_name = job_name;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION job_scheduler.log_job_complete(
    execution_id      BIGINT,
    status            TEXT DEFAULT 'completed',
    rows_affected     BIGINT DEFAULT NULL,
    error_message     TEXT DEFAULT NULL,
    execution_details JSONB DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    v_job TEXT;
BEGIN
    UPDATE job_scheduler.job_execution_log l
    SET completed_at = clock_timestamp(), status = status, rows_affected = rows_affected,
        error_message = error_message, execution_details = execution_details
    WHERE l.execution_id = execution_id
    RETURNING l.job_name INTO v_job;

    IF status = 'completed' THEN
        UPDATE job_scheduler.scheduled_jobs s
        SET successful_executions = s.successful_executions + 1
        WHERE s.job_name = v_job;
    END IF;
END $$;

-- =============================================================================
-- 2. JOB BODIES
-- =============================================================================
-- (a) Materialized view refresh.  Module-owned matview with a UNIQUE index, which
--     REFRESH ... CONCURRENTLY requires (readers are not blocked during the refresh).
CREATE MATERIALIZED VIEW IF NOT EXISTS job_scheduler.mv_daily_order_totals AS
SELECT date_trunc('day', order_date)::DATE AS order_day,
       count(*)                            AS orders,
       sum(total_amount)                   AS revenue
FROM commerce.orders
GROUP BY 1;
CREATE UNIQUE INDEX IF NOT EXISTS mv_daily_order_totals_day ON job_scheduler.mv_daily_order_totals (order_day);

CREATE OR REPLACE FUNCTION job_scheduler.refresh_analytics_views(
    view_list REGCLASS[] DEFAULT ARRAY['job_scheduler.mv_daily_order_totals'::REGCLASS]
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_exec      BIGINT := job_scheduler.log_job_start('refresh_analytics_views');
    v_view      REGCLASS;
    v_refreshed INTEGER := 0;
BEGIN
    FOREACH v_view IN ARRAY view_list LOOP
        -- %s with a regclass prints a correctly quoted, schema-qualified name
        -- (%I would turn 'schema.view' into one quoted identifier "schema.view")
        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %s', v_view);
        v_refreshed := v_refreshed + 1;
        PERFORM pg_notify('system_jobs', json_build_object('event', 'matview_refreshed', 'view', v_view::TEXT)::TEXT);
    END LOOP;
    PERFORM job_scheduler.log_job_complete(v_exec, 'completed', v_refreshed, NULL,
                                           jsonb_build_object('views', view_list::TEXT[]));
EXCEPTION WHEN OTHERS THEN
    -- the failure path writes its own log row (the started row was rolled back with the error)
    PERFORM job_scheduler.log_job_complete(job_scheduler.log_job_start('refresh_analytics_views'),
                                           'failed', v_refreshed, SQLERRM);
END $$;

-- (b) Daily maintenance.  ANALYZE is allowed inside a function; VACUUM is NOT (it cannot run
--     in a transaction block), so VACUUM is scheduled as its own cron command instead:
--     SELECT cron.schedule('nightly_vacuum', '30 2 * * *', 'VACUUM (ANALYZE) commerce.orders');
CREATE OR REPLACE FUNCTION job_scheduler.daily_maintenance()
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_exec    BIGINT := job_scheduler.log_job_start('daily_maintenance');
    v_deleted BIGINT;
BEGIN
    DELETE FROM job_scheduler.job_execution_log WHERE started_at < now() - interval '90 days';
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    ANALYZE job_scheduler.job_execution_log;
    ANALYZE job_scheduler.order_events;

    PERFORM job_scheduler.log_job_complete(v_exec, 'completed', v_deleted, NULL,
        jsonb_build_object('deleted_execution_logs', v_deleted, 'analyzed_tables', 2));
    PERFORM pg_notify('system_maintenance', json_build_object('event', 'daily_maintenance_completed')::TEXT);
END $$;

-- (c) Weekly statistics: business windows come from the dataset clock, not now().
CREATE OR REPLACE FUNCTION job_scheduler.weekly_statistics_update()
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_exec  BIGINT := job_scheduler.log_job_start('weekly_statistics_update');
    v_week  TIMESTAMPTZ := meta.as_of() - interval '7 days';   -- rolling week ending at the dataset clock
    v_stats JSONB;
BEGIN
    v_stats := jsonb_build_object(
        'window_start',       v_week,
        'active_citizens',    (SELECT count(*) FROM civics.citizens WHERE status = 'active'),
        'permits_this_week',  (SELECT count(*) FROM civics.permit_applications
                               WHERE application_date >= v_week AND application_date <= meta.as_of()),
        'orders_this_week',   (SELECT count(*) FROM commerce.orders
                               WHERE order_date >= v_week AND order_date <= meta.as_of()),
        'complaints_this_week', (SELECT count(*) FROM documents.complaint_records
                               WHERE submitted_at >= v_week AND submitted_at <= meta.as_of()));
    PERFORM job_scheduler.log_job_complete(v_exec, 'completed', 1, NULL, v_stats);
    PERFORM pg_notify('weekly_reports', v_stats::TEXT);
    RETURN v_stats;
END $$;

-- (d) Archival: move old rows from a hot table to an archive table in one statement.
--     Module-owned copies; the base commerce.orders is never deleted from.
DROP TABLE IF EXISTS job_scheduler.order_events, job_scheduler.order_events_archive;
CREATE TABLE job_scheduler.order_events (
    order_id     BIGINT PRIMARY KEY,
    status       TEXT NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL,
    order_date   TIMESTAMPTZ NOT NULL
);
INSERT INTO job_scheduler.order_events
SELECT order_id, status::TEXT, total_amount, order_date FROM commerce.orders ORDER BY order_id;
CREATE TABLE job_scheduler.order_events_archive (LIKE job_scheduler.order_events INCLUDING ALL);

CREATE OR REPLACE FUNCTION job_scheduler.archive_old_data(keep INTERVAL DEFAULT '1 year')
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_exec  BIGINT := job_scheduler.log_job_start('archive_old_data');
    v_moved BIGINT;
BEGIN
    WITH moved AS (
        DELETE FROM job_scheduler.order_events
        WHERE status IN ('delivered', 'cancelled', 'refunded')
          AND order_date < meta.as_of() - keep
        RETURNING *
    )
    INSERT INTO job_scheduler.order_events_archive SELECT * FROM moved;
    GET DIAGNOSTICS v_moved = ROW_COUNT;

    PERFORM job_scheduler.log_job_complete(v_exec, 'completed', v_moved, NULL,
        jsonb_build_object('archived_orders', v_moved, 'cutoff', meta.as_of() - keep));
    RETURN v_moved;
END $$;

-- (e) Health check: wall-clock metrics, alerts via NOTIFY.
CREATE OR REPLACE FUNCTION job_scheduler.system_health_check()
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_exec   BIGINT := job_scheduler.log_job_start('system_health_check');
    v_health JSONB;
    v_alerts TEXT[] := '{}';
BEGIN
    SELECT jsonb_build_object(
        'database_size_mb',    round(pg_database_size(current_database()) / 1024.0 ^ 2, 1),
        'connections',         (SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()),
        'long_running_queries',(SELECT count(*) FROM pg_stat_activity
                                WHERE state = 'active' AND query_start < now() - interval '5 minutes'
                                  AND pid <> pg_backend_pid()),
        'idle_in_transaction', (SELECT count(*) FROM pg_stat_activity
                                WHERE state = 'idle in transaction' AND state_change < now() - interval '5 minutes'))
    INTO v_health;

    IF (v_health->>'database_size_mb')::NUMERIC > 50 * 1024 THEN v_alerts := v_alerts || 'database > 50 GB'::TEXT; END IF;
    IF (v_health->>'connections')::INT > 100            THEN v_alerts := v_alerts || 'high connection count'::TEXT; END IF;
    IF (v_health->>'long_running_queries')::INT > 0     THEN v_alerts := v_alerts || 'long-running queries'::TEXT; END IF;
    IF (v_health->>'idle_in_transaction')::INT > 0      THEN v_alerts := v_alerts || 'idle-in-transaction sessions'::TEXT; END IF;

    v_health := v_health || jsonb_build_object('alerts', to_jsonb(v_alerts));
    IF cardinality(v_alerts) > 0 THEN
        PERFORM pg_notify('system_alerts', v_health::TEXT);
    END IF;
    PERFORM job_scheduler.log_job_complete(v_exec, 'completed', 1, NULL, v_health);
    RETURN v_health;
END $$;

-- =============================================================================
-- 3. SCHEDULE MANAGEMENT (registry + guarded pg_cron calls)
-- =============================================================================
-- Registers the job; schedules it in pg_cron only when asked AND pg_cron is installed.
-- cron.schedule with an existing job name updates that job (idempotent).
CREATE OR REPLACE FUNCTION job_scheduler.add_scheduled_job(
    job_name        TEXT,
    cron_schedule   TEXT,
    job_command     TEXT,
    job_description TEXT DEFAULT NULL,
    schedule_now    BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    v_id      BIGINT;
    v_cron_id BIGINT;
BEGIN
    INSERT INTO job_scheduler.scheduled_jobs AS s (job_name, job_description, cron_schedule, job_command)
    VALUES (job_name, job_description, cron_schedule, job_command)
    ON CONFLICT ON CONSTRAINT scheduled_jobs_job_name_key DO UPDATE
    SET job_description = EXCLUDED.job_description,
        cron_schedule   = EXCLUDED.cron_schedule,
        job_command     = EXCLUDED.job_command,
        is_active       = TRUE
    RETURNING s.job_id INTO v_id;

    IF schedule_now THEN
        IF job_scheduler.cron_available() THEN
            -- dynamic SQL so this function compiles even where the cron schema does not exist
            EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_cron_id USING job_name, cron_schedule, job_command;
            UPDATE job_scheduler.scheduled_jobs s SET cron_job_id = v_cron_id WHERE s.job_id = v_id;
        ELSE
            RAISE NOTICE 'pg_cron not installed here: job "%" registered but not scheduled', job_name;
        END IF;
    END IF;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION job_scheduler.remove_scheduled_job(job_name TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    v_exists BOOLEAN;
BEGIN
    IF job_scheduler.cron_available() THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM cron.job WHERE jobname = $1)' INTO v_exists USING job_name;
        IF v_exists THEN
            EXECUTE 'SELECT cron.unschedule($1)' USING job_name;
        END IF;
    END IF;

    UPDATE job_scheduler.scheduled_jobs s
    SET is_active = FALSE, cron_job_id = NULL
    WHERE s.job_name = job_name;
    RETURN FOUND;
END $$;

CREATE OR REPLACE FUNCTION job_scheduler.setup_default_jobs(schedule_now BOOLEAN DEFAULT FALSE)
RETURNS TABLE(job_name TEXT, cron_schedule TEXT, registry_id BIGINT)
LANGUAGE sql AS $$
    SELECT v.n, v.s, job_scheduler.add_scheduled_job(v.n, v.s, v.c, v.d, schedule_now)
    FROM (VALUES
        ('daily_maintenance',        '0 2 * * *',    'SELECT job_scheduler.daily_maintenance()',        'Log cleanup + ANALYZE'),
        ('nightly_vacuum',           '30 2 * * *',   'VACUUM (ANALYZE) job_scheduler.order_events',     'VACUUM must be a top-level command'),
        ('refresh_analytics_views',  '0 */4 * * *',  'SELECT job_scheduler.refresh_analytics_views()',  'Refresh matviews every 4 hours'),
        ('weekly_statistics_update', '0 3 * * 0',    'SELECT job_scheduler.weekly_statistics_update()', 'Sunday 03:00 statistics'),
        ('system_health_check',      '*/15 * * * *', 'SELECT job_scheduler.system_health_check()',      'Every 15 minutes'),
        ('archive_old_data',         '0 1 1 * *',    'SELECT job_scheduler.archive_old_data()',         'Monthly archival on the 1st'),
        ('purge_cron_history',       '0 4 * * *',
         $c$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$c$,
         'cron.job_run_details grows forever unless purged')
    ) v(n, s, c, d)
    ORDER BY v.n
$$;

\echo '-- job registry (registered only; nothing is scheduled persistently by this file)'
SELECT * FROM job_scheduler.setup_default_jobs(FALSE);

-- =============================================================================
-- 4. pg_cron IN ACTION (only where installed) - schedule, inspect, unschedule
-- =============================================================================
DO $$
DECLARE
    v_id BIGINT;
    r    RECORD;
BEGIN
    IF NOT job_scheduler.cron_available() THEN
        RAISE NOTICE 'skipping live pg_cron demo: extension not installed in "%"', current_database();
        RETURN;
    END IF;

    -- every 30 seconds (pg_cron >= 1.5 interval syntax); unscheduled again in section 6
    EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_id
        USING 'polaris_m14_demo_health', '30 seconds', 'SELECT job_scheduler.system_health_check()';
    RAISE NOTICE 'scheduled demo job id %', v_id;

    FOR r IN EXECUTE
        'SELECT jobid, jobname, schedule, command, database, username, active
         FROM cron.job WHERE jobname = $1' USING 'polaris_m14_demo_health'
    LOOP
        RAISE NOTICE 'cron.job: id=% name=% schedule=% db=% active=%', r.jobid, r.jobname, r.schedule, r.database, r.active;
    END LOOP;

    -- change schedule in place, then pause it
    EXECUTE 'SELECT cron.alter_job(job_id := $1, schedule := $2)' USING v_id, '*/5 * * * *';
    EXECUTE 'SELECT cron.alter_job(job_id := $1, active := false)' USING v_id;

    -- recent run history of all jobs (status: starting, running, succeeded, failed)
    FOR r IN EXECUTE
        'SELECT jobid, status, return_message, start_time FROM cron.job_run_details
         ORDER BY start_time DESC NULLS LAST LIMIT 5'
    LOOP
        RAISE NOTICE 'run: job=% status=% msg=% at=%', r.jobid, r.status, r.return_message, r.start_time;
    END LOOP;
END $$;
-- Run in another database of the same cluster (pg_cron >= 1.4):
--   SELECT cron.schedule_in_database('ag_refresh', '0 * * * *',
--          'REFRESH MATERIALIZED VIEW CONCURRENTLY job_scheduler.mv_daily_order_totals', 'other_db');

-- =============================================================================
-- 5. MANUAL RUN OF EVERY JOB BODY (what a scheduled run does)
-- =============================================================================
\echo '-- executing the job bodies once'
SELECT job_scheduler.refresh_analytics_views();
SELECT job_scheduler.daily_maintenance();
SELECT jsonb_pretty(job_scheduler.weekly_statistics_update() - 'window_start') AS weekly_stats;
SELECT job_scheduler.archive_old_data('1 year') AS orders_archived;
SELECT (SELECT count(*) FROM job_scheduler.order_events) AS hot_rows,
       (SELECT count(*) FROM job_scheduler.order_events_archive) AS archived_rows;
SELECT job_scheduler.system_health_check() ? 'alerts' AS health_check_ran;

CREATE OR REPLACE FUNCTION job_scheduler.get_job_statistics(days_back INTEGER DEFAULT 30)
RETURNS TABLE(job_name TEXT, total_executions BIGINT, successful_executions BIGINT, failed_executions BIGINT,
              success_rate NUMERIC, avg_duration_seconds NUMERIC, last_execution TIMESTAMPTZ, last_status TEXT)
LANGUAGE sql STABLE AS $$
    SELECT l.job_name,
           count(*),
           count(*) FILTER (WHERE l.status = 'completed'),
           count(*) FILTER (WHERE l.status = 'failed'),
           round(100.0 * count(*) FILTER (WHERE l.status = 'completed') / NULLIF(count(*), 0), 2),
           round(avg(l.duration_seconds), 3),
           max(l.started_at),
           (array_agg(l.status ORDER BY l.started_at DESC, l.execution_id DESC))[1]
    FROM job_scheduler.job_execution_log l
    WHERE l.started_at >= now() - make_interval(days => days_back)
    GROUP BY l.job_name
    ORDER BY l.job_name
$$;

CREATE OR REPLACE FUNCTION job_scheduler.generate_job_report()
RETURNS TABLE(report_section TEXT, metric_name TEXT, metric_value TEXT, status_indicator TEXT)
LANGUAGE sql STABLE AS $$
    SELECT 'Configuration', 'Registered active jobs', count(*)::TEXT,
           CASE WHEN count(*) > 0 THEN 'OK' ELSE 'WARNING' END
    FROM job_scheduler.scheduled_jobs WHERE is_active
    UNION ALL
    SELECT 'Activity', 'Executions in the last 24h', count(*)::TEXT, 'INFO'
    FROM job_scheduler.job_execution_log WHERE started_at >= now() - interval '24 hours'
    UNION ALL
    SELECT 'Reliability', 'Success rate (7 days)',
           COALESCE(round(100.0 * count(*) FILTER (WHERE status = 'completed') / NULLIF(count(*), 0), 1)::TEXT || '%', 'no data'),
           CASE WHEN count(*) = 0 THEN 'NO DATA'
                WHEN count(*) FILTER (WHERE status = 'completed')::NUMERIC / count(*) >= 0.95 THEN 'OK'
                WHEN count(*) FILTER (WHERE status = 'completed')::NUMERIC / count(*) >= 0.80 THEN 'WARNING'
                ELSE 'CRITICAL' END
    FROM job_scheduler.job_execution_log WHERE started_at >= now() - interval '7 days'
    UNION ALL
    SELECT 'Reliability', 'Jobs stuck in running > 1h', count(*)::TEXT,
           CASE WHEN count(*) > 0 THEN 'WARNING' ELSE 'OK' END
    FROM job_scheduler.job_execution_log WHERE status = 'running' AND started_at < now() - interval '1 hour'
$$;

SELECT job_name, total_executions, successful_executions, failed_executions, last_status
FROM job_scheduler.get_job_statistics(1);
SELECT * FROM job_scheduler.generate_job_report();

-- =============================================================================
-- 6. CLEAN UP: unschedule anything this file put into pg_cron
-- =============================================================================
DO $$
DECLARE
    v_left BIGINT;
BEGIN
    IF NOT job_scheduler.cron_available() THEN
        RETURN;
    END IF;
    EXECUTE $q$SELECT count(cron.unschedule(jobid)) FROM cron.job WHERE jobname = 'polaris_m14_demo_health'$q$;
    EXECUTE $q$SELECT count(*) FROM cron.job WHERE jobname = 'polaris_m14_demo_health'$q$ INTO v_left;
    RAISE NOTICE 'demo cron jobs remaining: %', v_left;
END $$;
-- Registry rows remain (inactive jobs are harmless); to unschedule everything registered:
--   SELECT job_scheduler.remove_scheduled_job(job_name) FROM job_scheduler.scheduled_jobs;

\echo '== pg_cron module complete =='
