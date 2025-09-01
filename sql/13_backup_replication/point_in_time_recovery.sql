-- File: sql/13_backup_replication/point_in_time_recovery.sql
-- Purpose: WAL archiving demo queries and PITR procedures

-- =============================================================================
-- WAL ARCHIVING SETUP AND MONITORING
-- =============================================================================

-- Create schema for WAL management
CREATE SCHEMA IF NOT EXISTS wal_mgmt;

-- WAL archive monitoring table
CREATE TABLE wal_mgmt.archive_status (
    status_id BIGSERIAL PRIMARY KEY,
    wal_file_name TEXT NOT NULL,
    archive_start TIMESTAMPTZ DEFAULT NOW(),
    archive_end TIMESTAMPTZ,
    archive_location TEXT,
    file_size_bytes BIGINT,
    checksum TEXT,
    status TEXT CHECK (status IN ('pending', 'archived', 'failed', 'verified')) DEFAULT 'pending',
    error_message TEXT
);

-- Recovery tracking table
CREATE TABLE wal_mgmt.recovery_sessions (
    recovery_id BIGSERIAL PRIMARY KEY,
    session_name TEXT NOT NULL,
    recovery_type TEXT CHECK (recovery_type IN ('pitr', 'full', 'incremental')) DEFAULT 'pitr',
    target_time TIMESTAMPTZ,
    target_lsn PG_LSN,
    base_backup_location TEXT,
    wal_archive_location TEXT,
    start_time TIMESTAMPTZ DEFAULT NOW(),
    end_time TIMESTAMPTZ,
    status TEXT CHECK (status IN ('preparing', 'restoring', 'completed', 'failed')) DEFAULT 'preparing',
    recovery_progress INTEGER DEFAULT 0, -- percentage
    notes TEXT
);

-- =============================================================================
-- WAL ARCHIVING CONFIGURATION QUERIES
-- =============================================================================

-- Check current WAL settings
CREATE OR REPLACE FUNCTION wal_mgmt.check_wal_config()
RETURNS TABLE(
    setting_name TEXT,
    current_value TEXT,
    recommended_value TEXT,
    status TEXT,
    description TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        'archive_mode'::TEXT as setting_name,
        setting as current_value,
        'on'::TEXT as recommended_value,
        CASE WHEN setting = 'on' THEN 'OK' ELSE 'NEEDS_CHANGE' END as status,
        'Enables WAL archiving'::TEXT as description
    FROM pg_settings WHERE name = 'archive_mode'

    UNION ALL

    SELECT
        'archive_command'::TEXT,
        setting,
        'cp %p /archive_location/%f'::TEXT,
        CASE WHEN setting != '' THEN 'OK' ELSE 'NEEDS_CHANGE' END,
        'Command to archive WAL files'::TEXT
    FROM pg_settings WHERE name = 'archive_command'

    UNION ALL

    SELECT
        'wal_level'::TEXT,
        setting,
        'replica'::TEXT,
        CASE WHEN setting IN ('replica', 'logical') THEN 'OK' ELSE 'NEEDS_CHANGE' END,
        'WAL information level'::TEXT
    FROM pg_settings WHERE name = 'wal_level'

    UNION ALL

    SELECT
        'max_wal_size'::TEXT,
        setting,
        '1GB'::TEXT,
        'INFO'::TEXT,
        'Maximum WAL size before checkpoint'::TEXT
    FROM pg_settings WHERE name = 'max_wal_size'

    UNION ALL

    SELECT
        'checkpoint_timeout'::TEXT,
        setting,
        '5min'::TEXT,
        'INFO'::TEXT,
        'Maximum time between checkpoints'::TEXT
    FROM pg_settings WHERE name = 'checkpoint_timeout';
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- WAL MONITORING AND STATISTICS
-- =============================================================================

-- Monitor WAL generation rate
CREATE OR REPLACE FUNCTION wal_mgmt.wal_generation_stats(
    hours_back INTEGER DEFAULT 24
)
RETURNS TABLE(
    metric_name TEXT,
    metric_value TEXT,
    unit TEXT,
    trend TEXT
) AS $$
DECLARE
    current_lsn PG_LSN;
    start_time TIMESTAMPTZ;
BEGIN
    current_lsn := pg_current_wal_lsn();
    start_time := NOW() - (hours_back || ' hours')::INTERVAL;

    -- Current WAL position
    RETURN QUERY SELECT
        'Current WAL LSN'::TEXT as metric_name,
        current_lsn::TEXT as metric_value,
        'LSN'::TEXT as unit,
        'Current'::TEXT as trend;

    -- WAL segments per hour (estimated)
    RETURN QUERY SELECT
        'Est. WAL Generation Rate'::TEXT,
        '~' || (hours_back * 2)::TEXT as metric_value,  -- Rough estimate
        'segments/hour'::TEXT,
        'Estimated'::TEXT;

    -- Archive status
    RETURN QUERY
    SELECT
        'Archive Success Rate'::TEXT,
        COALESCE(
            ROUND(
                (archived_count::DECIMAL / NULLIF(archived_count + failed_count, 0)) * 100, 2
            )::TEXT || '%',
            'No data'
        ) as metric_value,
        'percentage'::TEXT,
        'Last stats reset'::TEXT
    FROM pg_stat_archiver;

    -- Last archived WAL
    RETURN QUERY
    SELECT
        'Last Archived WAL'::TEXT,
        COALESCE(last_archived_wal, 'None') as metric_value,
        'WAL filename'::TEXT,
        COALESCE(last_archived_time::TEXT, 'Never') as trend
    FROM pg_stat_archiver;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- POINT-IN-TIME RECOVERY PREPARATION
-- =============================================================================

-- Create recovery points for important operations
CREATE OR REPLACE FUNCTION wal_mgmt.create_recovery_point(
    point_name TEXT,
    description TEXT DEFAULT NULL
)
RETURNS TABLE(
    recovery_point_name TEXT,
    lsn_position PG_LSN,
    timestamp_created TIMESTAMPTZ,
    wal_filename TEXT
) AS $$
DECLARE
    current_lsn PG_LSN;
    current_wal TEXT;
BEGIN
    -- Force WAL switch to ensure point is archived
    SELECT pg_walfile_name(pg_switch_wal()) INTO current_wal;
    current_lsn := pg_current_wal_lsn();

    -- Log the recovery point
    INSERT INTO wal_mgmt.recovery_sessions (
        session_name,
        recovery_type,
        target_lsn,
        notes,
        status
    ) VALUES (
        point_name,
        'pitr',
        current_lsn,
        COALESCE(description, 'Manual recovery point'),
        'completed'
    );

    RETURN QUERY SELECT
        point_name as recovery_point_name,
        current_lsn as lsn_position,
        NOW() as timestamp_created,
        current_wal as wal_filename;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- RECOVERY SIMULATION AND TESTING
-- =============================================================================

-- Simulate recovery scenario planning
CREATE OR REPLACE FUNCTION wal_mgmt.plan_recovery_scenario(
    target_timestamp TIMESTAMPTZ,
    scenario_name TEXT DEFAULT 'test_recovery'
)
RETURNS TABLE(
    step_number INTEGER,
    step_description TEXT,
    command_template TEXT,
    estimated_time TEXT,
    prerequisites TEXT
) AS $$
BEGIN
    -- Step 1: Stop database
    RETURN QUERY SELECT
        1 as step_number,
        'Stop PostgreSQL service'::TEXT as step_description,
        'sudo systemctl stop postgresql'::TEXT as command_template,
        '< 1 minute'::TEXT as estimated_time,
        'Database access will be interrupted'::TEXT as prerequisites;

    -- Step 2: Backup current data
    RETURN QUERY SELECT
        2,
        'Backup current data directory'::TEXT,
        'cp -r /var/lib/postgresql/data /var/lib/postgresql/data_backup_' || to_char(NOW(), 'YYYYMMDDHH24MISS'),
        '5-30 minutes'::TEXT,
        'Sufficient disk space (100% of data dir)'::TEXT;

    -- Step 3: Restore base backup
    RETURN QUERY SELECT
        3,
        'Restore base backup'::TEXT,
        'tar -xzf /backups/base_backup.tar.gz -C /var/lib/postgresql/data/'::TEXT,
        '10-60 minutes'::TEXT,
        'Base backup must be older than target time'::TEXT;

    -- Step 4: Create recovery.conf
    RETURN QUERY SELECT
        4,
        'Create recovery configuration'::TEXT,
        'echo "restore_command = ''cp /archive_location/%f %p''" > /var/lib/postgresql/data/recovery.conf; ' ||
        'echo "recovery_target_time = ''' || target_timestamp || '''" >> /var/lib/postgresql/data/recovery.conf',
        '< 1 minute'::TEXT,
        'WAL archives must be accessible'::TEXT;

    -- Step 5: Start recovery
    RETURN QUERY SELECT
        5,
        'Start PostgreSQL in recovery mode'::TEXT,
        'sudo systemctl start postgresql'::TEXT,
        '5-120 minutes'::TEXT,
        'Monitor logs for recovery progress'::TEXT;

    -- Step 6: Promote if needed
    RETURN QUERY SELECT
        6,
        'Promote to normal operation'::TEXT,
        'SELECT pg_promote();  -- or create trigger file'::TEXT,
        '< 1 minute'::TEXT,
        'Only after recovery reaches target time'::TEXT;

    -- Log the scenario
    INSERT INTO wal_mgmt.recovery_sessions (
        session_name,
        recovery_type,
        target_time,
        notes
    ) VALUES (
        scenario_name,
        'pitr',
        target_timestamp,
        'Recovery scenario planned for ' || target_timestamp
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BACKUP BASE BACKUP HELPERS
-- =============================================================================

-- Generate pg_basebackup command for different scenarios
CREATE OR REPLACE FUNCTION wal_mgmt.generate_basebackup_command(
    backup_scenario TEXT DEFAULT 'standard',
    output_location TEXT DEFAULT '/backups/base_backup'
)
RETURNS TEXT AS $$
DECLARE
    command_text TEXT;
BEGIN
    command_text := 'pg_basebackup -h localhost -p 5432 -U postgres ';

    CASE backup_scenario
        WHEN 'standard' THEN
            command_text := command_text || '--pgdata=' || output_location || ' ';
            command_text := command_text || '--format=tar --gzip --progress ';
            command_text := command_text || '--checkpoint=fast ';
            command_text := command_text || '--label="standard_backup_' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '"';

        WHEN 'streaming' THEN
            command_text := command_text || '--pgdata=' || output_location || ' ';
            command_text := command_text || '--format=tar --gzip --progress ';
            command_text := command_text || '--wal-method=stream ';
            command_text := command_text || '--checkpoint=fast ';
            command_text := command_text || '--label="streaming_backup_' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '"';

        WHEN 'parallel' THEN
            command_text := command_text || '--pgdata=' || output_location || ' ';
            command_text := command_text || '--format=tar --gzip --progress ';
            command_text := command_text || '--max-rate=100M ';  -- Rate limit
            command_text := command_text || '--checkpoint=spread ';
            command_text := command_text || '--label="parallel_backup_' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '"';

        WHEN 'minimal' THEN
            command_text := command_text || '--pgdata=' || output_location || ' ';
            command_text := command_text || '--format=plain ';
            command_text := command_text || '--checkpoint=fast ';
            command_text := command_text || '--no-verify-checksums ';
            command_text := command_text || '--label="minimal_backup_' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '"';

        ELSE
            command_text := command_text || '--pgdata=' || output_location || ' ';
            command_text := command_text || '--format=tar --progress ';
            command_text := command_text || '--checkpoint=fast';
    END CASE;

    RETURN command_text;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- RECOVERY VALIDATION AND TESTING
-- =============================================================================

-- Validate recovery environment before starting
CREATE OR REPLACE FUNCTION wal_mgmt.validate_recovery_environment(
    base_backup_path TEXT,
    wal_archive_path TEXT,
    target_time TIMESTAMPTZ
)
RETURNS TABLE(
    validation_check TEXT,
    status TEXT,
    details TEXT,
    action_required TEXT
) AS $$
BEGIN
    -- Check 1: Base backup exists
    RETURN QUERY SELECT
        'Base Backup Availability'::TEXT as validation_check,
        'INFO'::TEXT as status,
        'Path: ' || base_backup_path as details,
        'Verify backup file exists and is readable'::TEXT as action_required;

    -- Check 2: WAL archive accessibility
    RETURN QUERY SELECT
        'WAL Archive Access'::TEXT,
        'INFO'::TEXT,
        'Path: ' || wal_archive_path,
        'Verify archive directory is accessible'::TEXT;

    -- Check 3: Target time reasonableness
    RETURN QUERY SELECT
        'Target Time Validation'::TEXT,
        CASE
            WHEN target_time > NOW() THEN 'ERROR'
            WHEN target_time < NOW() - INTERVAL '1 year' THEN 'WARNING'
            ELSE 'OK'
        END,
        'Target: ' || target_time || ', Current: ' || NOW(),
        CASE
            WHEN target_time > NOW() THEN 'Cannot recover to future time'
            WHEN target_time < NOW() - INTERVAL '1 year' THEN 'Very old target - ensure WAL files exist'
            ELSE 'Target time looks reasonable'
        END;

    -- Check 4: Disk space
    RETURN QUERY SELECT
        'Disk Space Check'::TEXT,
        'MANUAL'::TEXT,
        'Recovery requires space for data + WAL files',
        'Use: df -h to check available space'::TEXT;

    -- Check 5: PostgreSQL not running
    RETURN QUERY SELECT
        'PostgreSQL Status'::TEXT,
        'MANUAL'::TEXT,
        'PostgreSQL must be stopped for recovery',
        'Use: sudo systemctl stop postgresql'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- RECOVERY MONITORING
-- =============================================================================

-- Monitor recovery progress (for use during recovery)
CREATE OR REPLACE FUNCTION wal_mgmt.monitor_recovery_progress()
RETURNS TABLE(
    metric_name TEXT,
    current_value TEXT,
    status TEXT,
    notes TEXT
) AS $$
BEGIN
    -- Check if in recovery mode
    RETURN QUERY SELECT
        'Recovery Status'::TEXT as metric_name,
        CASE WHEN pg_is_in_recovery() THEN 'IN RECOVERY' ELSE 'NORMAL OPERATION' END as current_value,
        CASE WHEN pg_is_in_recovery() THEN 'ACTIVE' ELSE 'COMPLETED' END as status,
        'Database recovery mode status'::TEXT as notes;

    -- Last received WAL (only available during recovery)
    IF (SELECT pg_is_in_recovery()) THEN
        RETURN QUERY SELECT
            'Last WAL Received'::TEXT,
            pg_last_wal_receive_lsn()::TEXT,
            'INFO'::TEXT,
            'Last WAL segment received from archive'::TEXT;

        RETURN QUERY SELECT
            'Last WAL Replayed'::TEXT,
            pg_last_wal_replay_lsn()::TEXT,
            'INFO'::TEXT,
            'Last WAL segment applied to database'::TEXT;
    END IF;

    -- Current WAL position
    RETURN QUERY SELECT
        'Current WAL Position'::TEXT,
        COALESCE(pg_current_wal_lsn()::TEXT, 'Not available in recovery'),
        'INFO'::TEXT,
        'Current write-ahead log position'::TEXT;

    -- Recovery start time (if available from logs)
    RETURN QUERY SELECT
        'Recovery Info'::TEXT,
        'Check PostgreSQL logs for detailed progress',
        'MANUAL'::TEXT,
        'tail -f /var/log/postgresql/postgresql-*.log'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- AUTOMATED RECOVERY PROCEDURES
-- =============================================================================

-- Create recovery configuration template
CREATE OR REPLACE FUNCTION wal_mgmt.generate_recovery_config(
    target_time TIMESTAMPTZ DEFAULT NULL,
    target_lsn PG_LSN DEFAULT NULL,
    wal_archive_location TEXT DEFAULT '/archive_location',
    recovery_mode TEXT DEFAULT 'pitr'
)
RETURNS TEXT AS $$
DECLARE
    config_content TEXT;
BEGIN
    config_content := '# Generated recovery configuration' || E'\n';
    config_content := config_content || '# Generated at: ' || NOW() || E'\n';
    config_content := config_content || '# Recovery mode: ' || recovery_mode || E'\n\n';

    -- Basic recovery command
    config_content := config_content || '# WAL archive restore command' || E'\n';
    config_content := config_content || 'restore_command = ''cp ' || wal_archive_location || '/%f %p''' || E'\n\n';

    -- Recovery target
    IF target_time IS NOT NULL THEN
        config_content := config_content || '# Point-in-time recovery target' || E'\n';
        config_content := config_content || 'recovery_target_time = ''' || target_time || '''' || E'\n';
    ELSIF target_lsn IS NOT NULL THEN
        config_content := config_content || '# LSN-based recovery target' || E'\n';
        config_content := config_content || 'recovery_target_lsn = ''' || target_lsn || '''' || E'\n';
    END IF;

    -- Recovery behavior
    config_content := config_content || E'\n# Recovery behavior' || E'\n';
    config_content := config_content || 'recovery_target_action = ''promote''' || E'\n';
    config_content := config_content || '# recovery_target_inclusive = true' || E'\n';

    -- Optional settings
    config_content := config_content || E'\n# Optional recovery settings' || E'\n';
    config_content := config_content || '# recovery_min_apply_delay = ''5min''' || E'\n';
    config_content := config_content || '# archive_cleanup_command = ''pg_archivecleanup ' || wal_archive_location || ' %r''' || E'\n';

    RETURN config_content;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DISASTER RECOVERY PLAYBOOK
-- =============================================================================

-- Complete disaster recovery playbook
CREATE OR REPLACE FUNCTION wal_mgmt.disaster_recovery_playbook()
RETURNS TABLE(
    phase TEXT,
    step_number INTEGER,
    action_item TEXT,
    command_example TEXT,
    estimated_duration TEXT,
    critical_notes TEXT
) AS $$
BEGIN
    -- PHASE 1: ASSESSMENT
    RETURN QUERY SELECT
        'ASSESSMENT'::TEXT as phase,
        1 as step_number,
        'Assess the damage and determine recovery strategy'::TEXT as action_item,
        '# Check system status, identify failure cause'::TEXT as command_example,
        '15-30 minutes'::TEXT as estimated_duration,
        'Document everything for post-incident review'::TEXT as critical_notes;

    RETURN QUERY SELECT
        'ASSESSMENT'::TEXT,
        2,
        'Verify backup and WAL archive availability'::TEXT,
        'ls -la /backups/ && ls -la /archive_location/'::TEXT,
        '5 minutes'::TEXT,
        'Recovery impossible without these files'::TEXT;

    -- PHASE 2: PREPARATION
    RETURN QUERY SELECT
        'PREPARATION'::TEXT,
        3,
        'Stop any running PostgreSQL processes'::TEXT,
        'sudo systemctl stop postgresql'::TEXT,
        '1 minute'::TEXT,
        'Ensure clean shutdown to prevent corruption'::TEXT;

    RETURN QUERY SELECT
        'PREPARATION'::TEXT,
        4,
        'Backup current data directory (if accessible)'::TEXT,
        'mv /var/lib/postgresql/data /var/lib/postgresql/data_damaged'::TEXT,
        '5-60 minutes'::TEXT,
        'Preserve evidence and enable rollback if needed'::TEXT;

    RETURN QUERY SELECT
        'PREPARATION'::TEXT,
        5,
        'Create new data directory'::TEXT,
        'mkdir -p /var/lib/postgresql/data && chown postgres:postgres /var/lib/postgresql/data'::TEXT,
        '1 minute'::TEXT,
        'Correct permissions are critical'::TEXT;

    -- PHASE 3: RECOVERY
    RETURN QUERY SELECT
        'RECOVERY'::TEXT,
        6,
        'Restore base backup'::TEXT,
        'tar -xzf /backups/latest_base_backup.tar.gz -C /var/lib/postgresql/data/'::TEXT,
        '10-120 minutes'::TEXT,
        'Use most recent base backup before incident'::TEXT;

    RETURN QUERY SELECT
        'RECOVERY'::TEXT,
        7,
        'Create recovery configuration'::TEXT,
        'SELECT wal_mgmt.generate_recovery_config(''2024-01-01 12:00:00''::TIMESTAMPTZ)'::TEXT,
        '5 minutes'::TEXT,
        'Set target time just before incident occurred'::TEXT;

    RETURN QUERY SELECT
        'RECOVERY'::TEXT,
        8,
        'Start recovery process'::TEXT,
        'sudo systemctl start postgresql'::TEXT,
        '15-300 minutes'::TEXT,
        'Monitor logs continuously: tail -f /var/log/postgresql/*.log'::TEXT;

    -- PHASE 4: VALIDATION
    RETURN QUERY SELECT
        'VALIDATION'::TEXT,
        9,
        'Verify database accessibility'::TEXT,
        'psql -U postgres -d smart_city -c "SELECT NOW();"'::TEXT,
        '1 minute'::TEXT,
        'Basic connectivity test'::TEXT;

    RETURN QUERY SELECT
        'VALIDATION'::TEXT,
        10,
        'Check data integrity'::TEXT,
        'SELECT backup_mgmt.compare_table_counts();'::TEXT,
        '5-15 minutes'::TEXT,
        'Compare with known good counts if available'::TEXT;

    RETURN QUERY SELECT
        'VALIDATION'::TEXT,
        11,
        'Test critical application functions'::TEXT,
        '# Run application smoke tests'::TEXT,
        '10-30 minutes'::TEXT,
        'Verify business-critical operations work'::TEXT;

    -- PHASE 5: RESUMPTION
    RETURN QUERY SELECT
        'RESUMPTION'::TEXT,
        12,
        'Update application connection strings'::TEXT,
        '# Point applications to recovered database'::TEXT,
        '5-15 minutes'::TEXT,
        'Coordinate with application teams'::TEXT;

    RETURN QUERY SELECT
        'RESUMPTION'::TEXT,
        13,
        'Resume WAL archiving and backups'::TEXT,
        'SELECT wal_mgmt.check_wal_config();'::TEXT,
        '5 minutes'::TEXT,
        'Ensure continuous protection going forward'::TEXT;

    RETURN QUERY SELECT
        'RESUMPTION'::TEXT,
        14,
        'Communicate recovery completion'::TEXT,
        '# Notify stakeholders of service restoration'::TEXT,
        '15 minutes'::TEXT,
        'Include any data loss or inconsistency details'::TEXT;
END;
$$ LANGUAGE plpgsql;
