-- File: sql/14_async_patterns/pg_cron_scheduled_jobs.sql
-- Purpose: scheduled refreshes + maintenance using pg_cron

-- =============================================================================
-- PG_CRON EXTENSION SETUP
-- =============================================================================

-- Enable pg_cron extension (requires superuser)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Note: pg_cron requires configuration in postgresql.conf:
-- shared_preload_libraries = 'pg_cron'
-- cron.database_name = 'smart_city'

-- Create schema for job management
CREATE SCHEMA IF NOT EXISTS job_scheduler;

-- Job execution log
CREATE TABLE job_scheduler.job_execution_log (
    execution_id BIGSERIAL PRIMARY KEY,
    job_name TEXT NOT NULL,
    cron_job_id BIGINT, -- pg_cron job id
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    duration_seconds INTEGER GENERATED ALWAYS AS (EXTRACT(epoch FROM (completed_at - started_at))) STORED,
    status TEXT CHECK (status IN ('running', 'completed', 'failed', 'cancelled')) DEFAULT 'running',
    rows_affected INTEGER,
    error_message TEXT,
    execution_details JSONB
);

-- Job configuration table
CREATE TABLE job_scheduler.scheduled_jobs (
    job_id BIGSERIAL PRIMARY KEY,
    job_name TEXT NOT NULL UNIQUE,
    job_description TEXT,
    cron_schedule TEXT NOT NULL, -- '0 2 * * *' format
    job_command TEXT NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    last_run TIMESTAMPTZ,
    next_run TIMESTAMPTZ,
    total_executions BIGINT DEFAULT 0,
    successful_executions BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by TEXT DEFAULT current_user
);

-- =============================================================================
-- JOB EXECUTION TRACKING FUNCTIONS
-- =============================================================================

-- Log job start
CREATE OR REPLACE FUNCTION job_scheduler.log_job_start(
    job_name TEXT,
    cron_job_id BIGINT DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
    execution_id BIGINT;
BEGIN
    INSERT INTO job_scheduler.job_execution_log (
        job_name, cron_job_id, started_at
    ) VALUES (
        job_name, cron_job_id, NOW()
    ) RETURNING job_execution_log.execution_id INTO execution_id;

    -- Update job metadata
    UPDATE job_scheduler.scheduled_jobs
    SET
        last_run = NOW(),
        total_executions = total_executions + 1
    WHERE scheduled_jobs.job_name = log_job_start.job_name;

    RETURN execution_id;
END;
$$ LANGUAGE plpgsql;

-- Log job completion
CREATE OR REPLACE FUNCTION job_scheduler.log_job_complete(
    execution_id BIGINT,
    status TEXT DEFAULT 'completed',
    rows_affected INTEGER DEFAULT NULL,
    error_message TEXT DEFAULT NULL,
    execution_details JSONB DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
    job_name TEXT;
BEGIN
    -- Update execution log
    UPDATE job_scheduler.job_execution_log
    SET
        completed_at = NOW(),
        status = log_job_complete.status,
        rows_affected = log_job_complete.rows_affected,
        error_message = log_job_complete.error_message,
        execution_details = log_job_complete.execution_details
    WHERE job_execution_log.execution_id = log_job_complete.execution_id
    RETURNING job_execution_log.job_name INTO job_name;

    -- Update success counter if completed successfully
    IF status = 'completed' THEN
        UPDATE job_scheduler.scheduled_jobs
        SET successful_executions = successful_executions + 1
        WHERE scheduled_jobs.job_name = job_name;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- MATERIALIZED VIEW REFRESH JOBS
-- =============================================================================

-- Refresh analytics materialized views
CREATE OR REPLACE FUNCTION job_scheduler.refresh_analytics_views()
RETURNS VOID AS $$
DECLARE
    execution_id BIGINT;
    rows_refreshed INTEGER := 0;
    view_name TEXT;
    view_list TEXT[] := ARRAY[
        'analytics.citizen_demographics_summary',
        'analytics.neighborhood_statistics',
        'analytics.monthly_permit_trends',
        'analytics.commerce_performance_summary'
    ];
BEGIN
    execution_id := job_scheduler.log_job_start('refresh_analytics_views');

    -- Refresh each materialized view
    FOREACH view_name IN ARRAY view_list LOOP
        BEGIN
            EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', view_name);
            rows_refreshed := rows_refreshed + 1;

            -- Log individual view refresh
            PERFORM messaging.notify_channel(
                'system_jobs',
                'matview_refreshed',
                json_build_object(
                    'view_name', view_name,
                    'refreshed_at', NOW()
                ),
                'cron_scheduler'
            );
        EXCEPTION WHEN OTHERS THEN
            -- Log error but continue with other views
            PERFORM job_scheduler.log_job_complete(
                execution_id,
                'failed',
                rows_refreshed,
                'Failed on view ' || view_name || ': ' || SQLERRM
            );
            RETURN;
        END;
    END LOOP;

    PERFORM job_scheduler.log_job_complete(
        execution_id,
        'completed',
        rows_refreshed,
        NULL,
        json_build_object('views_refreshed', view_list)
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DATABASE MAINTENANCE JOBS
-- =============================================================================

-- Daily maintenance routine
CREATE OR REPLACE FUNCTION job_scheduler.daily_maintenance()
RETURNS VOID AS $$
DECLARE
    execution_id BIGINT;
    maintenance_results JSONB := '{}'::JSONB;
    deleted_logs INTEGER;
    vacuumed_tables INTEGER := 0;
    analyzed_tables INTEGER := 0;
BEGIN
    execution_id := job_scheduler.log_job_start('daily_maintenance');

    -- Clean old execution logs (keep 90 days)
    DELETE FROM job_scheduler.job_execution_log
    WHERE started_at < (NOW() - INTERVAL '90 days');
    GET DIAGNOSTICS deleted_logs = ROW_COUNT;

    maintenance_results := maintenance_results ||
        json_build_object('deleted_execution_logs', deleted_logs);

    -- Clean old notification logs
    PERFORM messaging.cleanup_old_notifications(30);
    maintenance_results := maintenance_results ||
        json_build_object('notification_cleanup', 'completed');

    -- VACUUM high-activity tables
    VACUUM ANALYZE civics.citizens;
    VACUUM ANALYZE commerce.orders;
    VACUUM ANALYZE messaging.notification_log;
    VACUUM ANALYZE messaging.message_queue;
    vacuumed_tables := 4;

    -- Update table statistics
    ANALYZE civics.permit_applications;
    ANALYZE documents.complaint_records;
    analyzed_tables := 2;

    maintenance_results := maintenance_results || json_build_object(
        'vacuumed_tables', vacuumed_tables,
        'analyzed_tables', analyzed_tables
    );

    -- Cleanup expired backup records
    PERFORM backup_mgmt.cleanup_old_backups(30);
    maintenance_results := maintenance_results ||
        json_build_object('backup_cleanup', 'completed');

    PERFORM job_scheduler.log_job_complete(
        execution_id,
        'completed',
        deleted_logs + vacuumed_tables + analyzed_tables,
        NULL,
        maintenance_results
    );

    -- Notify completion
    PERFORM messaging.notify_channel(
        'system_maintenance',
        'daily_maintenance_completed',
        maintenance_results,
        'cron_scheduler'
    );
END;
$$ LANGUAGE plpgsql;

-- Weekly statistics update
CREATE OR REPLACE FUNCTION job_scheduler.weekly_statistics_update()
RETURNS VOID AS $$
DECLARE
    execution_id BIGINT;
    stats_results JSONB := '{}'::JSONB;
BEGIN
    execution_id := job_scheduler.log_job_start('weekly_statistics_update');

    -- Refresh extended statistics
    ANALYZE;

    -- Update custom statistics tables (if they exist)
    -- This would update pre-calculated statistics for dashboards

    -- Generate weekly reports
    stats_results := json_build_object(
        'total_citizens', (SELECT COUNT(*) FROM civics.citizens WHERE status = 'active'),
        'permits_this_week', (SELECT COUNT(*) FROM civics.permit_applications
                              WHERE submitted_date >= DATE_TRUNC('week', NOW())),
        'orders_this_week', (SELECT COUNT(*) FROM commerce.orders
                            WHERE order_date >= DATE_TRUNC('week', NOW())),
        'report_generated_at', NOW()
    );

    PERFORM job_scheduler.log_job_complete(
        execution_id,
        'completed',
        1,
        NULL,
        stats_results
    );

    -- Send weekly report notification
    PERFORM messaging.notify_channel(
        'weekly_reports',
        'statistics_updated',
        stats_results,
        'cron_scheduler'
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DATA ARCHIVAL AND CLEANUP JOBS
-- =============================================================================

-- Archive old records
CREATE OR REPLACE FUNCTION job_scheduler.archive_old_data()
RETURNS VOID AS $$
DECLARE
    execution_id BIGINT;
    archive_results JSONB := '{}'::JSONB;
    archived_orders INTEGER := 0;
    archived_logs INTEGER := 0;
BEGIN
    execution_id := job_scheduler.log_job_start('archive_old_data');

    -- Archive old completed orders (older than 2 years)
    WITH archived AS (
        DELETE FROM commerce.orders
        WHERE order_status = 'completed'
        AND order_date < (NOW() - INTERVAL '2 years')
        RETURNING *
    )
    INSERT INTO archive.orders_archive SELECT * FROM archived;
    GET DIAGNOSTICS archived_orders = ROW_COUNT;

    -- Archive old system logs
    WITH archived_logs_cte AS (
        DELETE FROM messaging.notification_log
        WHERE notification_sent_at < (NOW() - INTERVAL '1 year')
        RETURNING *
    )
    INSERT INTO archive.notification_logs_archive SELECT * FROM archived_logs_cte;
    GET DIAGNOSTICS archived_logs = ROW_COUNT;

    archive_results := json_build_object(
        'archived_orders', archived_orders,
        'archived_notification_logs', archived_logs,
        'archival_date', NOW()
    );

    PERFORM job_scheduler.log_job_complete(
        execution_id,
        'completed',
        archived_orders + archived_logs,
        NULL,
        archive_results
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ALERT AND MONITORING JOBS
-- =============================================================================

-- System health monitoring
CREATE OR REPLACE FUNCTION job_scheduler.system_health_check()
RETURNS VOID AS $$
DECLARE
    execution_id BIGINT;
    health_results JSONB := '{}'::JSONB;
    alert_conditions TEXT[] := '{}';
    db_size_gb NUMERIC;
    connection_count INTEGER;
    slow_query_count INTEGER;
BEGIN
    execution_id := job_scheduler.log_job_start('system_health_check');

    -- Check database size
    SELECT ROUND(pg_database_size(current_database()) / 1024.0^3, 2) INTO db_size_gb;

    -- Check connection count
    SELECT COUNT(*) INTO connection_count FROM pg_stat_activity;

    -- Check for slow queries (running > 5 minutes)
    SELECT COUNT(*) INTO slow_query_count
    FROM pg_stat_activity
    WHERE state = 'active'
    AND query_start < NOW() - INTERVAL '5 minutes'
    AND query NOT LIKE '%pg_stat_activity%';

    -- Build health results
    health_results := json_build_object(
        'database_size_gb', db_size_gb,
        'active_connections', connection_count,
        'slow_queries', slow_query_count,
        'check_timestamp', NOW()
    );

    -- Generate alerts if needed
    IF db_size_gb > 50 THEN
        alert_conditions := alert_conditions || 'Database size > 50GB';
    END IF;

    IF connection_count > 100 THEN
        alert_conditions := alert_conditions || 'High connection count';
    END IF;

    IF slow_query_count > 0 THEN
        alert_conditions := alert_conditions || 'Slow queries detected';
    END IF;

    -- Send alerts if any conditions met
    IF array_length(alert_conditions, 1) > 0 THEN
        PERFORM messaging.notify_channel(
            'system_alerts',
            'health_check_alerts',
            health_results || json_build_object('alerts', alert_conditions),
            'health_monitor'
        );
    END IF;

    -- Always send health status
    PERFORM messaging.notify_channel(
        'system_health',
        'health_check_completed',
        health_results,
        'health_monitor'
    );

    PERFORM job_scheduler.log_job_complete(
        execution_id,
        'completed',
        1,
        NULL,
        health_results
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- JOB SCHEDULE MANAGEMENT
-- =============================================================================

-- Add scheduled job
CREATE OR REPLACE FUNCTION job_scheduler.add_scheduled_job(
    job_name TEXT,
    cron_schedule TEXT,
    job_command TEXT,
    job_description TEXT DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
    job_id BIGINT;
    cron_job_id BIGINT;
BEGIN
    -- Insert into our tracking table
    INSERT INTO job_scheduler.scheduled_jobs (
        job_name, job_description, cron_schedule, job_command
    ) VALUES (
        job_name, job_description, cron_schedule, job_command
    ) RETURNING scheduled_jobs.job_id INTO job_id;

    -- Schedule with pg_cron (commented as pg_cron may not be available)
    /*
    SELECT cron.schedule(job_name, cron_schedule, job_command) INTO cron_job_id;

    UPDATE job_scheduler.scheduled_jobs
    SET next_run = (SELECT next_run FROM cron.job WHERE jobid = cron_job_id)
    WHERE scheduled_jobs.job_id = job_id;
    */

    RETURN job_id;
END;
$$ LANGUAGE plpgsql;

-- Remove scheduled job
CREATE OR REPLACE FUNCTION job_scheduler.remove_scheduled_job(
    job_name TEXT
)
RETURNS BOOLEAN AS $$
BEGIN
    -- Remove from pg_cron
    -- PERFORM cron.unschedule(job_name);

    -- Mark as inactive in our table
    UPDATE job_scheduler.scheduled_jobs
    SET is_active = FALSE
    WHERE scheduled_jobs.job_name = remove_scheduled_job.job_name;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- JOB MONITORING AND REPORTING
-- =============================================================================

-- Get job execution statistics
CREATE OR REPLACE FUNCTION job_scheduler.get_job_statistics(
    days_back INTEGER DEFAULT 30
)
RETURNS TABLE(
    job_name TEXT,
    total_executions BIGINT,
    successful_executions BIGINT,
    failed_executions BIGINT,
    success_rate NUMERIC,
    avg_duration_seconds NUMERIC,
    last_execution TIMESTAMPTZ,
    last_status TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        jel.job_name,
        COUNT(*) as total_executions,
        COUNT(*) FILTER (WHERE status = 'completed') as successful_executions,
        COUNT(*) FILTER (WHERE status = 'failed') as failed_executions,
        ROUND(
            (COUNT(*) FILTER (WHERE status = 'completed')::NUMERIC /
             NULLIF(COUNT(*), 0)) * 100, 2
        ) as success_rate,
        ROUND(AVG(duration_seconds), 2) as avg_duration_seconds,
        MAX(started_at) as last_execution,
        (SELECT status FROM job_scheduler.job_execution_log jel2
         WHERE jel2.job_name = jel.job_name
         ORDER BY started_at DESC LIMIT 1) as last_status
    FROM job_scheduler.job_execution_log jel
    WHERE started_at >= (NOW() - (days_back || ' days')::INTERVAL)
    GROUP BY jel.job_name
    ORDER BY total_executions DESC;
END;
$$ LANGUAGE plpgsql;

-- Generate job execution report
CREATE OR REPLACE FUNCTION job_scheduler.generate_job_report()
RETURNS TABLE(
    report_section TEXT,
    metric_name TEXT,
    metric_value TEXT,
    status_indicator TEXT
) AS $$
BEGIN
    -- Active jobs
    RETURN QUERY
    SELECT
        'Job Configuration'::TEXT as report_section,
        'Active Jobs'::TEXT as metric_name,
        COUNT(*)::TEXT as metric_value,
        CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'WARNING' END as status_indicator
    FROM job_scheduler.scheduled_jobs WHERE is_active = TRUE;

    -- Executions today
    RETURN QUERY
    SELECT
        'Daily Activity'::TEXT,
        'Executions Today'::TEXT,
        COUNT(*)::TEXT,
        'INFO'::TEXT
    FROM job_scheduler.job_execution_log
    WHERE started_at::DATE = CURRENT_DATE;

    -- Success rate (last 7 days)
    RETURN QUERY
    SELECT
        'Reliability'::TEXT,
        'Success Rate (7 days)'::TEXT,
        COALESCE(
            ROUND(
                (COUNT(*) FILTER (WHERE status = 'completed')::NUMERIC /
                 NULLIF(COUNT(*), 0)) * 100, 1
            )::TEXT || '%',
            'No data'
        ),
        CASE
            WHEN COUNT(*) = 0 THEN 'NO DATA'
            WHEN (COUNT(*) FILTER (WHERE status = 'completed')::NUMERIC / COUNT(*)) >= 0.95 THEN 'OK'
            WHEN (COUNT(*) FILTER (WHERE status = 'completed')::NUMERIC / COUNT(*)) >= 0.80 THEN 'WARNING'
            ELSE 'CRITICAL'
        END
    FROM job_scheduler.job_execution_log
    WHERE started_at >= NOW() - INTERVAL '7 days';

    -- Average execution time
    RETURN QUERY
    SELECT
        'Performance'::TEXT,
        'Avg Execution Time'::TEXT,
        COALESCE(ROUND(AVG(duration_seconds), 1)::TEXT || ' seconds', 'No data'),
        'INFO'::TEXT
    FROM job_scheduler.job_execution_log
    WHERE completed_at IS NOT NULL
    AND started_at >= NOW() - INTERVAL '7 days';
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DEMO SETUP AND DEFAULT JOBS
-- =============================================================================

-- Setup default scheduled jobs
CREATE OR REPLACE FUNCTION job_scheduler.setup_default_jobs()
RETURNS TEXT AS $$
DECLARE
    result_msg TEXT := '';
BEGIN
    -- Daily maintenance at 2 AM
    PERFORM job_scheduler.add_scheduled_job(
        'daily_maintenance',
        '0 2 * * *',
        'SELECT job_scheduler.daily_maintenance();',
        'Daily database maintenance and cleanup'
    );
    result_msg := result_msg || 'Daily maintenance job added' || E'\n';

    -- Refresh analytics views every 4 hours
    PERFORM job_scheduler.add_scheduled_job(
        'refresh_analytics_views',
        '0 */4 * * *',
        'SELECT job_scheduler.refresh_analytics_views();',
        'Refresh materialized views for analytics'
    );
    result_msg := result_msg || 'Analytics refresh job added' || E'\n';

    -- Weekly statistics on Sundays at 3 AM
    PERFORM job_scheduler.add_scheduled_job(
        'weekly_statistics_update',
        '0 3 * * 0',
        'SELECT job_scheduler.weekly_statistics_update();',
        'Generate weekly statistics and reports'
    );
    result_msg := result_msg || 'Weekly statistics job added' || E'\n';

    -- Health check every 15 minutes
    PERFORM job_scheduler.add_scheduled_job(
        'system_health_check',
        '*/15 * * * *',
        'SELECT job_scheduler.system_health_check();',
        'Monitor system health and generate alerts'
    );
    result_msg := result_msg || 'Health check job added' || E'\n';

    -- Monthly archival on 1st at 1 AM
    PERFORM job_scheduler.add_scheduled_job(
        'archive_old_data',
        '0 1 1 * *',
        'SELECT job_scheduler.archive_old_data();',
        'Archive old data monthly'
    );
    result_msg := result_msg || 'Data archival job added' || E'\n';

    result_msg := result_msg || E'\n' || 'To enable pg_cron execution, uncomment the cron.schedule() calls';
    result_msg := result_msg || E'\n' || 'and ensure pg_cron extension is properly configured.';

    RETURN result_msg;
END;
$$ LANGUAGE plpgsql;
