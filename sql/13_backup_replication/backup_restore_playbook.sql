-- File: sql/13_backup_replication/backup_restore_playbook.sql
-- Purpose: pg_dump/pg_restore/psql flows with executable examples

-- =============================================================================
-- BACKUP STRATEGY OVERVIEW
-- =============================================================================

-- Create backup management schema
CREATE SCHEMA IF NOT EXISTS backup_mgmt;

-- Backup metadata table
CREATE TABLE backup_mgmt.backup_jobs (
    job_id BIGSERIAL PRIMARY KEY,
    job_name TEXT NOT NULL,
    backup_type TEXT CHECK (backup_type IN ('full', 'schema_only', 'data_only', 'custom', 'incremental')),
    database_name TEXT NOT NULL,
    file_path TEXT,
    file_size_bytes BIGINT,
    start_time TIMESTAMPTZ,
    end_time TIMESTAMPTZ,
    duration_seconds INTEGER GENERATED ALWAYS AS (EXTRACT(epoch FROM (end_time - start_time))) STORED,
    status TEXT CHECK (status IN ('running', 'completed', 'failed', 'cancelled')) DEFAULT 'running',
    pg_dump_version TEXT,
    compression_used BOOLEAN DEFAULT FALSE,
    error_message TEXT,
    created_by TEXT DEFAULT current_user
);

-- Backup schedule table
CREATE TABLE backup_mgmt.backup_schedule (
    schedule_id BIGSERIAL PRIMARY KEY,
    schedule_name TEXT NOT NULL,
    backup_type TEXT NOT NULL,
    cron_schedule TEXT NOT NULL, -- '0 2 * * *' for daily 2 AM
    retention_days INTEGER DEFAULT 30,
    compression BOOLEAN DEFAULT TRUE,
    is_active BOOLEAN DEFAULT TRUE,
    last_run TIMESTAMPTZ,
    next_run TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- BACKUP COMMAND TEMPLATES (Shell Commands)
-- =============================================================================

/*
-- Full database backup (binary format, compressed)
pg_dump -h localhost -p 5432 -U postgres -d smart_city \
  --format=custom --compress=9 --verbose \
  --file=/backups/smart_city_full_$(date +%Y%m%d_%H%M%S).backup

-- Schema-only backup
pg_dump -h localhost -p 5432 -U postgres -d smart_city \
  --schema-only --format=plain \
  --file=/backups/smart_city_schema_$(date +%Y%m%d_%H%M%S).sql

-- Data-only backup
pg_dump -h localhost -p 5432 -U postgres -d smart_city \
  --data-only --format=custom --compress=9 \
  --file=/backups/smart_city_data_$(date +%Y%m%d_%H%M%S).backup

-- Specific schema backup
pg_dump -h localhost -p 5432 -U postgres -d smart_city \
  --schema=civics --format=custom --compress=9 \
  --file=/backups/civics_schema_$(date +%Y%m%d_%H%M%S).backup

-- Specific tables backup
pg_dump -h localhost -p 5432 -U postgres -d smart_city \
  --table=civics.citizens --table=civics.neighborhoods \
  --format=custom --compress=9 \
  --file=/backups/core_tables_$(date +%Y%m%d_%H%M%S).backup

-- Large database backup with parallel jobs
pg_dump -h localhost -p 5432 -U postgres -d smart_city \
  --format=directory --jobs=4 --compress=9 \
  --file=/backups/smart_city_parallel_$(date +%Y%m%d_%H%M%S)

-- Backup with custom options
pg_dump -h localhost -p 5432 -U postgres -d smart_city \
  --format=custom --compress=9 --verbose \
  --exclude-table=temp_* --exclude-table=*_log \
  --exclude-schema=staging \
  --file=/backups/smart_city_production_$(date +%Y%m%d_%H%M%S).backup
*/

-- =============================================================================
-- RESTORE COMMAND TEMPLATES (Shell Commands)
-- =============================================================================

/*
-- Full database restore (creates new database)
createdb -h localhost -p 5432 -U postgres smart_city_restored
pg_restore -h localhost -p 5432 -U postgres -d smart_city_restored \
  --verbose --clean --if-exists \
  /backups/smart_city_full_20241128_020000.backup

-- Restore into existing database (careful!)
pg_restore -h localhost -p 5432 -U postgres -d smart_city \
  --verbose --clean --if-exists --single-transaction \
  /backups/smart_city_full_20241128_020000.backup

-- Schema-only restore
psql -h localhost -p 5432 -U postgres -d smart_city_new \
  -f /backups/smart_city_schema_20241128_020000.sql

-- Data-only restore
pg_restore -h localhost -p 5432 -U postgres -d smart_city \
  --verbose --data-only --disable-triggers \
  /backups/smart_city_data_20241128_020000.backup

-- Selective table restore
pg_restore -h localhost -p 5432 -U postgres -d smart_city \
  --verbose --table=citizens --table=neighborhoods \
  /backups/smart_city_full_20241128_020000.backup

-- Parallel restore (faster for large databases)
pg_restore -h localhost -p 5432 -U postgres -d smart_city_restored \
  --verbose --jobs=4 --clean --if-exists \
  /backups/smart_city_parallel_20241128_020000

-- Point-in-time restore (requires WAL archives)
pg_basebackup -h localhost -p 5432 -U postgres \
  --pgdata=/restore/base_backup --format=tar --gzip \
  --checkpoint=fast --label="restore_point_$(date +%Y%m%d_%H%M%S)"
*/

-- =============================================================================
-- BACKUP VALIDATION FUNCTIONS
-- =============================================================================

-- Function to validate backup file integrity
CREATE OR REPLACE FUNCTION backup_mgmt.validate_backup(
    backup_file_path TEXT,
    backup_type TEXT DEFAULT 'custom'
)
RETURNS TABLE(
    validation_step TEXT,
    status TEXT,
    details TEXT
) AS $$
DECLARE
    cmd_output TEXT;
BEGIN
    -- Note: These would need to be implemented via external scripts
    -- or stored procedures with appropriate permissions

    -- Step 1: File existence check
    RETURN QUERY SELECT
        'File Existence'::TEXT as validation_step,
        'INFO'::TEXT as status,
        'Backup file path: ' || backup_file_path as details;

    -- Step 2: File size check
    RETURN QUERY SELECT
        'File Size Check'::TEXT as validation_step,
        'INFO'::TEXT as status,
        'Use: du -h ' || backup_file_path as details;

    -- Step 3: pg_restore list test (for custom format)
    IF backup_type = 'custom' THEN
        RETURN QUERY SELECT
            'Backup Contents List'::TEXT as validation_step,
            'INFO'::TEXT as status,
            'Use: pg_restore --list ' || backup_file_path as details;
    END IF;

    -- Step 4: Test restore to temp database
    RETURN QUERY SELECT
        'Test Restore'::TEXT as validation_step,
        'RECOMMENDED'::TEXT as status,
        'Create test database and restore to validate' as details;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BACKUP SIZE ESTIMATION
-- =============================================================================

-- Estimate backup size before running
CREATE OR REPLACE FUNCTION backup_mgmt.estimate_backup_size()
RETURNS TABLE(
    schema_name NAME,
    table_name NAME,
    row_count BIGINT,
    table_size TEXT,
    indexes_size TEXT,
    total_size TEXT,
    estimated_compressed_size TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        schemaname::NAME,
        tablename::NAME,
        COALESCE(n_tup_ins - n_tup_del, 0) as row_count,
        pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
        pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) as indexes_size,
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
        pg_size_pretty((pg_total_relation_size(schemaname||'.'||tablename) * 0.3)::BIGINT) as estimated_compressed_size
    FROM pg_tables t
    LEFT JOIN pg_stat_user_tables s ON t.schemaname = s.schemaname AND t.tablename = s.relname
    WHERE t.schemaname IN ('civics', 'commerce', 'documents', 'analytics')
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BACKUP MONITORING AND LOGGING
-- =============================================================================

-- Function to log backup start
CREATE OR REPLACE FUNCTION backup_mgmt.log_backup_start(
    job_name TEXT,
    backup_type TEXT,
    database_name TEXT,
    file_path TEXT DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
    job_id BIGINT;
BEGIN
    INSERT INTO backup_mgmt.backup_jobs (
        job_name,
        backup_type,
        database_name,
        file_path,
        start_time,
        pg_dump_version
    ) VALUES (
        job_name,
        backup_type,
        database_name,
        file_path,
        NOW(),
        (SELECT setting FROM pg_settings WHERE name = 'server_version')
    ) RETURNING backup_jobs.job_id INTO job_id;

    RETURN job_id;
END;
$$ LANGUAGE plpgsql;

-- Function to log backup completion
CREATE OR REPLACE FUNCTION backup_mgmt.log_backup_complete(
    job_id BIGINT,
    file_size_bytes BIGINT DEFAULT NULL,
    status TEXT DEFAULT 'completed',
    error_message TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE backup_mgmt.backup_jobs
    SET
        end_time = NOW(),
        file_size_bytes = log_backup_complete.file_size_bytes,
        status = log_backup_complete.status,
        error_message = log_backup_complete.error_message
    WHERE backup_jobs.job_id = log_backup_complete.job_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BACKUP RETENTION MANAGEMENT
-- =============================================================================

-- Function to clean old backups based on retention policy
CREATE OR REPLACE FUNCTION backup_mgmt.cleanup_old_backups(
    retention_days INTEGER DEFAULT 30
)
RETURNS TABLE(
    cleanup_action TEXT,
    job_count BIGINT,
    total_size_freed TEXT
) AS $$
DECLARE
    total_size BIGINT := 0;
    job_count BIGINT := 0;
BEGIN
    -- Calculate total size of old backups
    SELECT
        COUNT(*),
        COALESCE(SUM(file_size_bytes), 0)
    INTO job_count, total_size
    FROM backup_mgmt.backup_jobs
    WHERE end_time < (NOW() - (retention_days || ' days')::INTERVAL)
    AND status = 'completed';

    -- Mark old jobs for cleanup (don't actually delete files from SQL)
    UPDATE backup_mgmt.backup_jobs
    SET status = 'expired'
    WHERE end_time < (NOW() - (retention_days || ' days')::INTERVAL)
    AND status = 'completed';

    RETURN QUERY SELECT
        'Marked for cleanup'::TEXT as cleanup_action,
        job_count,
        pg_size_pretty(total_size) as total_size_freed;

    RETURN QUERY SELECT
        'Action required'::TEXT as cleanup_action,
        0::BIGINT as job_count,
        'Use external script to delete actual files'::TEXT as total_size_freed;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BACKUP COMPARISON AND VERIFICATION
-- =============================================================================

-- Compare table row counts between databases
CREATE OR REPLACE FUNCTION backup_mgmt.compare_table_counts(
    source_db TEXT DEFAULT current_database()
)
RETURNS TABLE(
    schema_name NAME,
    table_name NAME,
    source_count BIGINT,
    comparison_notes TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        schemaname::NAME,
        tablename::NAME,
        COALESCE(n_tup_ins - n_tup_del, 0) as source_count,
        CASE
            WHEN COALESCE(n_tup_ins - n_tup_del, 0) = 0 THEN 'Empty table'
            WHEN COALESCE(n_tup_ins - n_tup_del, 0) < 1000 THEN 'Small table'
            WHEN COALESCE(n_tup_ins - n_tup_del, 0) < 100000 THEN 'Medium table'
            ELSE 'Large table'
        END as comparison_notes
    FROM pg_tables t
    LEFT JOIN pg_stat_user_tables s ON t.schemaname = s.schemaname AND t.tablename = s.relname
    WHERE t.schemaname IN ('civics', 'commerce', 'documents', 'analytics')
    ORDER BY source_count DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SAMPLE BACKUP SCRIPTS GENERATOR
-- =============================================================================

-- Generate backup scripts for different scenarios
CREATE OR REPLACE FUNCTION backup_mgmt.generate_backup_scripts(
    backup_scenario TEXT DEFAULT 'production'
)
RETURNS TEXT AS $$
DECLARE
    script_content TEXT;
    timestamp_suffix TEXT := '$(date +%Y%m%d_%H%M%S)';
BEGIN
    script_content := '#!/bin/bash' || E'\n';
    script_content := script_content || '# Generated backup script for: ' || backup_scenario || E'\n';
    script_content := script_content || '# Generated at: ' || NOW()::TEXT || E'\n\n';

    script_content := script_content || 'set -e  # Exit on error' || E'\n';
    script_content := script_content || 'set -u  # Exit on undefined variable' || E'\n\n';

    script_content := script_content || '# Database connection parameters' || E'\n';
    script_content := script_content || 'DB_HOST=localhost' || E'\n';
    script_content := script_content || 'DB_PORT=5432' || E'\n';
    script_content := script_content || 'DB_USER=postgres' || E'\n';
    script_content := script_content || 'DB_NAME=smart_city' || E'\n';
    script_content := script_content || 'BACKUP_DIR=/backups' || E'\n';
    script_content := script_content || 'TIMESTAMP=' || timestamp_suffix || E'\n\n';

    CASE backup_scenario
        WHEN 'production' THEN
            script_content := script_content || '# Production full backup' || E'\n';
            script_content := script_content || 'pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME \' || E'\n';
            script_content := script_content || '  --format=custom --compress=9 --verbose \' || E'\n';
            script_content := script_content || '  --exclude-table=*_log --exclude-table=temp_* \' || E'\n';
            script_content := script_content || '  --file=$BACKUP_DIR/smart_city_prod_$TIMESTAMP.backup' || E'\n';

        WHEN 'development' THEN
            script_content := script_content || '# Development backup (schema + sample data)' || E'\n';
            script_content := script_content || 'pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME \' || E'\n';
            script_content := script_content || '  --format=plain --schema-only \' || E'\n';
            script_content := script_content || '  --file=$BACKUP_DIR/smart_city_dev_schema_$TIMESTAMP.sql' || E'\n';

        WHEN 'migration' THEN
            script_content := script_content || '# Migration backup (data only, no temp tables)' || E'\n';
            script_content := script_content || 'pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME \' || E'\n';
            script_content := script_content || '  --format=custom --compress=9 --data-only \' || E'\n';
            script_content := script_content || '  --exclude-table=*_temp --exclude-table=*_staging \' || E'\n';
            script_content := script_content || '  --file=$BACKUP_DIR/smart_city_migration_$TIMESTAMP.backup' || E'\n';

        ELSE
            script_content := script_content || '# Standard backup' || E'\n';
            script_content := script_content || 'pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME \' || E'\n';
            script_content := script_content || '  --format=custom --compress=9 --verbose \' || E'\n';
            script_content := script_content || '  --file=$BACKUP_DIR/smart_city_$TIMESTAMP.backup' || E'\n';
    END CASE;

    script_content := script_content || E'\n' || '# Verify backup was created' || E'\n';
    script_content := script_content || 'if [ -f "$BACKUP_DIR/smart_city_*_$TIMESTAMP.backup" ]; then' || E'\n';
    script_content := script_content || '    echo "Backup completed successfully"' || E'\n';
    script_content := script_content || '    ls -lh $BACKUP_DIR/smart_city_*_$TIMESTAMP.backup' || E'\n';
    script_content := script_content || 'else' || E'\n';
    script_content := script_content || '    echo "Backup failed!" >&2' || E'\n';
    script_content := script_content || '    exit 1' || E'\n';
    script_content := script_content || 'fi' || E'\n';

    RETURN script_content;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BACKUP REPORTING
-- =============================================================================

-- Generate backup status report
CREATE OR REPLACE FUNCTION backup_mgmt.backup_status_report(
    days_back INTEGER DEFAULT 7
)
RETURNS TABLE(
    report_section TEXT,
    metric_name TEXT,
    metric_value TEXT,
    status_indicator TEXT
) AS $$
BEGIN
    -- Recent backup summary
    RETURN QUERY
    SELECT
        'Recent Backups'::TEXT as report_section,
        'Total Backups (Last ' || days_back || ' days)'::TEXT as metric_name,
        COUNT(*)::TEXT as metric_value,
        CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'WARNING' END as status_indicator
    FROM backup_mgmt.backup_jobs
    WHERE start_time >= (NOW() - (days_back || ' days')::INTERVAL);

    -- Success rate
    RETURN QUERY
    SELECT
        'Recent Backups'::TEXT,
        'Success Rate'::TEXT,
        ROUND(
            (COUNT(*) FILTER (WHERE status = 'completed') * 100.0) /
            NULLIF(COUNT(*), 0), 1
        )::TEXT || '%' as metric_value,
        CASE
            WHEN COUNT(*) = 0 THEN 'NO DATA'
            WHEN (COUNT(*) FILTER (WHERE status = 'completed') * 100.0) / COUNT(*) >= 95 THEN 'OK'
            WHEN (COUNT(*) FILTER (WHERE status = 'completed') * 100.0) / COUNT(*) >= 80 THEN 'WARNING'
            ELSE 'CRITICAL'
        END as status_indicator
    FROM backup_mgmt.backup_jobs
    WHERE start_time >= (NOW() - (days_back || ' days')::INTERVAL);

    -- Average backup size
    RETURN QUERY
    SELECT
        'Storage Metrics'::TEXT,
        'Average Backup Size'::TEXT,
        pg_size_pretty(AVG(file_size_bytes)::BIGINT) as metric_value,
        'INFO'::TEXT as status_indicator
    FROM backup_mgmt.backup_jobs
    WHERE status = 'completed'
    AND file_size_bytes IS NOT NULL
    AND start_time >= (NOW() - (days_back || ' days')::INTERVAL);

    -- Total storage used
    RETURN QUERY
    SELECT
        'Storage Metrics'::TEXT,
        'Total Storage Used'::TEXT,
        pg_size_pretty(SUM(file_size_bytes)) as metric_value,
        'INFO'::TEXT as status_indicator
    FROM backup_mgmt.backup_jobs
    WHERE status = 'completed' AND file_size_bytes IS NOT NULL;
END;
$$ LANGUAGE plpgsql;
