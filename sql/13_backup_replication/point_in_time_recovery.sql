-- File: sql/13_backup_replication/point_in_time_recovery.sql
-- Purpose: WAL, base backups and point-in-time recovery (PITR): the SQL-visible parts
--
-- What this module teaches
--   1. PITR = a physical base backup + every WAL segment written since, replayed up to a target
--   2. The WAL position functions: pg_current_wal_lsn, pg_walfile_name(_offset), pg_wal_lsn_diff
--   3. Named recovery targets with pg_create_restore_point
--   4. The low-level backup API pg_backup_start / pg_backup_stop (PG15+ names; the old
--      pg_start_backup / exclusive mode were removed)
--   5. Monitoring archiving: pg_stat_archiver, pg_stat_wal
--   6. Modern recovery configuration: settings in postgresql.conf + recovery.signal
--      (recovery.conf was removed in PG12; promote_trigger_file was removed in PG16)
--   7. PG17 incremental backups: summarize_wal + pg_basebackup --incremental + pg_combinebackup
--
-- Shell / server steps are in comments.  Every SQL statement here is safe to run on a live
-- cluster: it forces at most one checkpoint (pg_backup_start with fast => true) and writes
-- a few WAL records.

\echo '== 13 / point-in-time recovery =='

-- =============================================================================
-- 1. MODULE-OWNED BOOKKEEPING
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS wal_mgmt;

CREATE TABLE IF NOT EXISTS wal_mgmt.archive_status (
    status_id        BIGSERIAL PRIMARY KEY,
    wal_file_name    TEXT NOT NULL,
    archive_start    TIMESTAMPTZ DEFAULT now(),
    archive_end      TIMESTAMPTZ,
    archive_location TEXT,
    file_size_bytes  BIGINT,
    checksum         TEXT,
    status           TEXT CHECK (status IN ('pending', 'archived', 'failed', 'verified')) DEFAULT 'pending',
    error_message    TEXT
);

-- Restore points and planned recoveries
CREATE TABLE IF NOT EXISTS wal_mgmt.recovery_sessions (
    recovery_id          BIGSERIAL PRIMARY KEY,
    session_name         TEXT NOT NULL,
    recovery_type        TEXT CHECK (recovery_type IN ('pitr', 'full', 'incremental', 'restore_point')) DEFAULT 'pitr',
    target_time          TIMESTAMPTZ,
    target_lsn           PG_LSN,
    target_name          TEXT,
    wal_file             TEXT,
    base_backup_location TEXT,
    wal_archive_location TEXT,
    start_time           TIMESTAMPTZ DEFAULT now(),
    end_time             TIMESTAMPTZ,
    status               TEXT CHECK (status IN ('preparing', 'restoring', 'completed', 'failed')) DEFAULT 'preparing',
    notes                TEXT
);

-- =============================================================================
-- 2. CONFIGURATION CHECK
-- =============================================================================
-- PITR needs wal_level >= replica, archive_mode = on and a working archive_command or
-- archive_library.  This lab runs wal_level = logical with archiving OFF, so the check
-- reports NEEDS_CHANGE for archiving: that is expected here.
CREATE OR REPLACE FUNCTION wal_mgmt.check_wal_config()
RETURNS TABLE(setting_name TEXT, current_value TEXT, recommended_value TEXT, status TEXT, description TEXT)
LANGUAGE sql STABLE AS $$
    WITH s AS (SELECT name, setting, unit FROM pg_settings),
    rules(name, recommended, ok_expr, description) AS (VALUES
        ('wal_level',         'replica or logical', NULL, 'WAL detail level; minimal cannot be used for PITR'),
        ('archive_mode',      'on',                 NULL, 'Hand completed WAL segments to the archiver'),
        ('archive_command',   'test ! -f /archive/%f && cp %p /archive/%f', NULL, 'Shell command per segment (must fail if the file exists)'),
        ('archive_library',   '(empty or a module)', NULL, 'PG15+: archive via a loadable module instead of a shell command'),
        ('archive_timeout',   '60 .. 300 s',        NULL, 'Force a segment switch so quiet systems still archive (bounds data loss)'),
        ('summarize_wal',     'on (PG17, for incremental backups)', NULL, 'WAL summarizer needed by pg_basebackup --incremental'),
        ('max_wal_size',      '>= 1GB',             NULL, 'Checkpoint distance'),
        ('checkpoint_timeout','5min .. 30min',      NULL, 'Maximum time between checkpoints'),
        ('wal_keep_size',     'as needed',          NULL, 'Extra WAL kept in pg_wal for lagging standbys'),
        ('max_slot_wal_keep_size', 'set a cap',     NULL, 'Upper bound on WAL retained by replication slots (-1 = unlimited!)')
    )
    SELECT r.name,
           s.setting || COALESCE(' ' || s.unit, ''),
           r.recommended,
           CASE r.name
               WHEN 'wal_level'      THEN CASE WHEN s.setting IN ('replica', 'logical') THEN 'OK' ELSE 'NEEDS_CHANGE' END
               WHEN 'archive_mode'   THEN CASE WHEN s.setting IN ('on', 'always') THEN 'OK' ELSE 'NEEDS_CHANGE' END
               WHEN 'archive_command' THEN CASE WHEN s.setting NOT IN ('', '(disabled)') THEN 'OK'
                                               WHEN (SELECT setting FROM s s2 WHERE s2.name = 'archive_library') <> '' THEN 'OK (library)'
                                               ELSE 'NEEDS_CHANGE' END
               WHEN 'summarize_wal'  THEN CASE WHEN s.setting = 'on' THEN 'OK' ELSE 'OPTIONAL' END
               WHEN 'max_slot_wal_keep_size' THEN CASE WHEN s.setting = '-1' THEN 'REVIEW' ELSE 'OK' END
               ELSE 'INFO'
           END,
           r.description
    FROM rules r JOIN s ON s.name = r.name
$$;

\echo '-- WAL / archiving configuration'
SELECT * FROM wal_mgmt.check_wal_config();

-- =============================================================================
-- 3. WAL POSITIONS AND SEGMENT NAMES
-- =============================================================================
-- An LSN is a byte position in the WAL stream; pg_walfile_name maps it to the 16 MB segment
-- file (timeline + log + segment) that a restore needs.
SELECT pg_current_wal_lsn()                                  AS current_lsn,
       pg_walfile_name(pg_current_wal_lsn())                 AS current_segment,
       (pg_walfile_name_offset(pg_current_wal_lsn())).file_offset AS byte_offset_in_segment,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) AS wal_written_since_initdb,
       current_setting('wal_segment_size')                   AS segment_size;

-- How much WAL does an operation generate?  Measure LSN before and after.
CREATE TABLE IF NOT EXISTS wal_mgmt.pitr_demo (
    id         INTEGER PRIMARY KEY,
    payload    TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
TRUNCATE wal_mgmt.pitr_demo;   -- module-owned table only

SELECT pg_current_wal_insert_lsn() AS lsn_before \gset
INSERT INTO wal_mgmt.pitr_demo (id, payload)
SELECT g, repeat(md5(g::TEXT), 4) FROM generate_series(1, 5000) g;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :'lsn_before')) AS wal_for_5000_inserts;

-- Cluster-wide WAL statistics (PG14+); wal_fpi = full-page images after each checkpoint
SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal_bytes, wal_buffers_full, stats_reset
FROM pg_stat_wal;

-- Last checkpoint: REDO LSN is where crash recovery (and a base backup) starts replaying
SELECT checkpoint_lsn, redo_lsn, redo_wal_file, timeline_id, checkpoint_time
FROM pg_control_checkpoint();

-- =============================================================================
-- 4. NAMED RESTORE POINTS: an "oops" scenario
-- =============================================================================
-- Before risky maintenance, drop a named marker into WAL.  If the change goes wrong,
-- recover with recovery_target_name = '<name>' instead of guessing a timestamp.
CREATE OR REPLACE FUNCTION wal_mgmt.create_recovery_point(
    point_name  TEXT,
    description TEXT DEFAULT NULL,
    switch_wal  BOOLEAN DEFAULT false   -- true: close the segment so it is archived right away
)
RETURNS TABLE(recovery_point_name TEXT, lsn_position PG_LSN, created_at TIMESTAMPTZ, wal_filename TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_lsn PG_LSN;
BEGIN
    v_lsn := pg_create_restore_point(point_name);      -- needs wal_level >= replica
    IF switch_wal THEN
        PERFORM pg_switch_wal();
    END IF;

    INSERT INTO wal_mgmt.recovery_sessions
        (session_name, recovery_type, target_lsn, target_name, wal_file, notes, status, end_time)
    VALUES
        (point_name, 'restore_point', v_lsn, point_name, pg_walfile_name(v_lsn),
         COALESCE(description, 'Manual restore point'), 'completed', now());

    RETURN QUERY SELECT point_name, v_lsn, now(), pg_walfile_name(v_lsn);
END $$;

\echo '-- restore point before a destructive change (module-owned table)'
SELECT * FROM wal_mgmt.create_recovery_point('before_pitr_demo_delete', 'about to purge pitr_demo rows');

SELECT pg_current_wal_insert_lsn() AS lsn_before_delete \gset
DELETE FROM wal_mgmt.pitr_demo WHERE id % 2 = 0;          -- the "accident"
SELECT count(*) AS rows_left_after_accident,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :'lsn_before_delete')) AS wal_of_the_delete
FROM wal_mgmt.pitr_demo;

-- To undo it you would restore the latest base backup taken BEFORE the restore point and
-- replay WAL with:
--     restore_command       = 'cp /archive/%f %p'
--     recovery_target_name  = 'before_pitr_demo_delete'
--     recovery_target_action = 'pause'      -- inspect first, then SELECT pg_wal_replay_resume();
-- The deleted rows reappear because replay stops just before the DELETE's commit record.
SELECT session_name, target_lsn, wal_file, notes
FROM wal_mgmt.recovery_sessions
WHERE recovery_type = 'restore_point'
ORDER BY recovery_id DESC
LIMIT 1;

-- =============================================================================
-- 5. LOW-LEVEL BASE BACKUP API (pg_backup_start / pg_backup_stop)
-- =============================================================================
-- pg_basebackup does all of this for you.  The low-level API exists for snapshot-based
-- tools (LVM/ZFS/EBS snapshots, rsync).  Rules: start and stop in the SAME session, copy the
-- data directory in between, and store the returned backup_label with the copy (it is NOT
-- written to the data directory any more).  fast => true forces an immediate checkpoint.
\echo '-- non-exclusive base backup (no files are copied in this demo)'
SELECT pg_backup_start(label => 'polaris_module13_demo', fast => true) AS backup_start_lsn;

--   [shell] here you would snapshot / rsync $PGDATA (excluding pg_wal/*, postmaster.pid ...)

SELECT lsn AS backup_stop_lsn,
       labelfile                           -- write this to backup_label inside the copy
FROM pg_backup_stop(wait_for_archive => false);
-- wait_for_archive => true (the default) blocks until the last needed segment is archived;
-- with archiving disabled, as here, you must ensure the WAL is copied some other way.

-- =============================================================================
-- 6. ARCHIVER MONITORING
-- =============================================================================
CREATE OR REPLACE FUNCTION wal_mgmt.wal_generation_stats()
RETURNS TABLE(metric_name TEXT, metric_value TEXT, unit TEXT, note TEXT)
LANGUAGE sql STABLE AS $$
    SELECT 'Current WAL LSN', pg_current_wal_lsn()::TEXT, 'LSN', pg_walfile_name(pg_current_wal_lsn())
    UNION ALL
    SELECT 'WAL bytes since stats reset', pg_size_pretty(wal_bytes), 'bytes',
           'per hour: ' || pg_size_pretty((wal_bytes / GREATEST(extract(epoch FROM now() - stats_reset) / 3600, 1))::BIGINT)
    FROM pg_stat_wal
    UNION ALL
    SELECT 'Archived / failed segments', archived_count || ' / ' || failed_count, 'segments',
           CASE WHEN archived_count + failed_count = 0 THEN 'archiver idle or disabled'
                ELSE round(100.0 * archived_count / (archived_count + failed_count), 2) || '% success' END
    FROM pg_stat_archiver
    UNION ALL
    SELECT 'Last archived WAL', COALESCE(last_archived_wal, 'none'), 'segment',
           COALESCE(last_archived_time::TEXT, 'never')
    FROM pg_stat_archiver
    UNION ALL
    SELECT 'Last failed WAL', COALESCE(last_failed_wal, 'none'), 'segment',
           COALESCE(last_failed_time::TEXT, 'never')
    FROM pg_stat_archiver
$$;

SELECT * FROM wal_mgmt.wal_generation_stats();

-- Files currently in pg_wal (superuser or pg_monitor) - keep the output small
SELECT count(*) AS segments_in_pg_wal, pg_size_pretty(sum(size)) AS pg_wal_size
FROM pg_ls_waldir();

-- =============================================================================
-- 7. PG17 INCREMENTAL BACKUPS
-- =============================================================================
-- With summarize_wal = on, the WAL summarizer records which blocks changed, so
-- pg_basebackup --incremental copies only those.  pg_combinebackup later reconstructs a
-- full data directory from the chain.
SELECT name, setting FROM pg_settings WHERE name IN ('summarize_wal', 'wal_summary_keep_time') ORDER BY name;
SELECT * FROM pg_get_wal_summarizer_state();
SELECT count(*) AS wal_summaries_available FROM pg_available_wal_summaries();
/*
ALTER SYSTEM SET summarize_wal = on;  SELECT pg_reload_conf();

pg_basebackup -U polaris -D /backups/full     --checkpoint=fast --wal-method=stream
pg_basebackup -U polaris -D /backups/incr1    --incremental=/backups/full/backup_manifest
pg_basebackup -U polaris -D /backups/incr2    --incremental=/backups/incr1/backup_manifest
pg_combinebackup /backups/full /backups/incr1 /backups/incr2 -o /restore/pgdata
pg_verifybackup /backups/full
*/

-- =============================================================================
-- 8. COMMAND GENERATORS
-- =============================================================================
CREATE OR REPLACE FUNCTION wal_mgmt.generate_basebackup_command(
    backup_scenario TEXT DEFAULT 'standard',
    output_location TEXT DEFAULT '/backups/base_backup'
)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT 'pg_basebackup -h localhost -p 5432 -U polaris --pgdata=' || output_location || ' '
        || CASE backup_scenario
               -- tar + compression, WAL streamed alongside so the backup is self-contained
               WHEN 'standard'    THEN '--format=tar --compress=server-zstd:3 --wal-method=stream --checkpoint=fast --progress'
               -- rate-limited, spread checkpoint: gentle on a busy primary
               WHEN 'throttled'   THEN '--format=tar --compress=gzip --wal-method=stream --max-rate=100M --checkpoint=spread'
               -- plain copy that can start directly as a standby (-R writes standby.signal + primary_conninfo)
               WHEN 'standby'     THEN '--format=plain --wal-method=stream --write-recovery-conf --slot=standby1 --create-slot --checkpoint=fast'
               -- PG17 incremental, relative to a previous manifest
               WHEN 'incremental' THEN '--incremental=/backups/full/backup_manifest --checkpoint=fast'
               ELSE '--format=tar --wal-method=stream --checkpoint=fast'
           END
        || ' --label=' || quote_literal(backup_scenario || '_' || to_char(now(), 'YYYYMMDD_HH24MISS'))
$$;

SELECT s AS scenario, wal_mgmt.generate_basebackup_command(s) AS command
FROM unnest(ARRAY['standard', 'throttled', 'standby', 'incremental']) s;

-- Recovery settings (PG12+): put them in postgresql.conf (or postgresql.auto.conf) and
-- create an empty recovery.signal file in the data directory.  Use standby.signal instead
-- to start a streaming standby.
CREATE OR REPLACE FUNCTION wal_mgmt.generate_recovery_config(
    target_time          TIMESTAMPTZ DEFAULT NULL,
    target_lsn           PG_LSN DEFAULT NULL,
    target_name          TEXT DEFAULT NULL,
    wal_archive_location TEXT DEFAULT '/archive',
    target_action        TEXT DEFAULT 'pause'
)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    c TEXT;
BEGIN
    IF num_nonnulls(target_time, target_lsn, target_name) > 1 THEN
        RAISE EXCEPTION 'specify at most one recovery target';
    END IF;

    c := '# --- append to postgresql.conf, then: touch $PGDATA/recovery.signal ---' || E'\n'
      || 'restore_command = ''cp ' || wal_archive_location || '/%f %p''' || E'\n';
    IF target_time IS NOT NULL THEN
        c := c || 'recovery_target_time = ''' || to_char(target_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC''' || E'\n';
    ELSIF target_lsn IS NOT NULL THEN
        c := c || 'recovery_target_lsn = ''' || target_lsn || '''' || E'\n';
    ELSIF target_name IS NOT NULL THEN
        c := c || 'recovery_target_name = ''' || target_name || '''' || E'\n';
    ELSE
        c := c || '# no target: replay all available WAL (full recovery)' || E'\n';
    END IF;
    c := c || 'recovery_target_action = ''' || target_action || '''   # pause | promote | shutdown' || E'\n'
           || '#recovery_target_inclusive = on   # stop after (on) or before (off) the target' || E'\n'
           || '#recovery_target_timeline = ''latest''' || E'\n'
           || '#archive_cleanup_command = ''pg_archivecleanup ' || wal_archive_location || ' %r''  # standbys only' || E'\n';
    RETURN c;
END $$;

SELECT wal_mgmt.generate_recovery_config(target_name => 'before_pitr_demo_delete') AS recovery_settings;
SELECT wal_mgmt.generate_recovery_config(target_time => meta.as_of()) AS recovery_settings_by_time;

-- =============================================================================
-- 9. RECOVERY PLANNING, VALIDATION AND MONITORING
-- =============================================================================
CREATE OR REPLACE FUNCTION wal_mgmt.plan_recovery_scenario(
    target_timestamp TIMESTAMPTZ,
    scenario_name    TEXT DEFAULT 'test_recovery'
)
RETURNS TABLE(step_number INTEGER, step_description TEXT, command_template TEXT, estimated_time TEXT, prerequisites TEXT)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO wal_mgmt.recovery_sessions (session_name, recovery_type, target_time, notes)
    VALUES (scenario_name, 'pitr', target_timestamp, 'Recovery scenario planned for ' || target_timestamp);

    RETURN QUERY VALUES
        (1, 'Stop PostgreSQL', 'docker stop polaris-db   # or: pg_ctl stop -m fast', '< 1 min', 'Clients disconnected'),
        (2, 'Keep the damaged data directory', 'mv $PGDATA $PGDATA.damaged', '1-30 min', 'Enough disk; preserves evidence and a way back'),
        (3, 'Restore the newest base backup older than the target', 'tar -xf /backups/base.tar -C $PGDATA', '10-60 min', 'Backup end < target'),
        (4, 'Configure recovery', 'SELECT wal_mgmt.generate_recovery_config(''' || target_timestamp || '''::timestamptz);  -- append to postgresql.conf', '< 1 min', 'WAL archive reachable via restore_command'),
        (5, 'Request targeted recovery', 'touch $PGDATA/recovery.signal', '< 1 min', 'Not standby.signal'),
        (6, 'Start and watch the log', 'pg_ctl start; tail -f log/postgresql-*.log', '5-120 min', 'Look for "recovery stopping before commit"'),
        (7, 'Verify data while paused, then promote', 'SELECT pg_wal_replay_resume();  -- or SELECT pg_promote();', '< 1 min', 'Recovery reached the target'),
        (8, 'Take a fresh base backup', 'pg_basebackup ... (new timeline)', '10-60 min', 'Old backups are on the previous timeline');
END $$;

CREATE OR REPLACE FUNCTION wal_mgmt.validate_recovery_environment(
    base_backup_path TEXT,
    wal_archive_path TEXT,
    target_time      TIMESTAMPTZ
)
RETURNS TABLE(validation_check TEXT, status TEXT, details TEXT, action_required TEXT)
LANGUAGE sql STABLE AS $$
    VALUES
        ('Base backup availability', 'MANUAL', 'Path: ' || base_backup_path,
         'pg_verifybackup ' || base_backup_path),
        ('WAL archive access', 'MANUAL', 'Path: ' || wal_archive_path,
         'ls ' || wal_archive_path || ' | tail; segments must be continuous from the backup start'),
        ('Target time',
         CASE WHEN target_time > now() THEN 'FAIL'
              WHEN target_time < now() - interval '1 year' THEN 'WARNING' ELSE 'OK' END,
         'Target: ' || target_time || ', now: ' || now(),
         CASE WHEN target_time > now() THEN 'Cannot recover to the future'
              WHEN target_time < now() - interval '1 year' THEN 'Very old target: check WAL retention'
              ELSE 'Target looks reasonable' END),
        ('Archiving enabled on this server',
         CASE WHEN current_setting('archive_mode') IN ('on', 'always') THEN 'OK' ELSE 'FAIL' END,
         'archive_mode = ' || current_setting('archive_mode'),
         'Without archived WAL only the base backup itself can be restored'),
        ('Disk space', 'MANUAL', 'Need room for data directory + replayed WAL', 'df -h')
$$;

CREATE OR REPLACE FUNCTION wal_mgmt.monitor_recovery_progress()
RETURNS TABLE(metric_name TEXT, current_value TEXT, status TEXT, notes TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY SELECT 'Recovery status'::TEXT,
        CASE WHEN pg_is_in_recovery() THEN 'IN RECOVERY' ELSE 'NORMAL OPERATION' END,
        CASE WHEN pg_is_in_recovery() THEN 'ACTIVE' ELSE 'COMPLETED' END,
        'pg_is_in_recovery()'::TEXT;

    IF pg_is_in_recovery() THEN
        -- pg_current_wal_lsn() raises an error during recovery, so only call these here
        RETURN QUERY SELECT 'Last WAL received'::TEXT, pg_last_wal_receive_lsn()::TEXT, 'INFO'::TEXT, 'streaming only'::TEXT;
        RETURN QUERY SELECT 'Last WAL replayed'::TEXT, pg_last_wal_replay_lsn()::TEXT, 'INFO'::TEXT, 'applied so far'::TEXT;
        RETURN QUERY SELECT 'Last replayed commit time'::TEXT, pg_last_xact_replay_timestamp()::TEXT, 'INFO'::TEXT, 'compare with the target'::TEXT;
        RETURN QUERY SELECT 'Replay paused'::TEXT, pg_get_wal_replay_pause_state(), 'INFO'::TEXT, 'pg_wal_replay_resume() to continue'::TEXT;
    ELSE
        RETURN QUERY SELECT 'Current WAL position'::TEXT, pg_current_wal_lsn()::TEXT, 'INFO'::TEXT,
            pg_walfile_name(pg_current_wal_lsn());
        RETURN QUERY SELECT 'Timeline'::TEXT, timeline_id::TEXT, 'INFO'::TEXT, 'increments after every PITR / promotion'::TEXT
            FROM pg_control_checkpoint();
    END IF;
END $$;

\echo '-- recovery plan, validation and status (plan logging rolled back)'
BEGIN;
SELECT step_number, step_description, command_template
FROM wal_mgmt.plan_recovery_scenario(meta.as_of(), 'demo_plan');
ROLLBACK;

SELECT * FROM wal_mgmt.validate_recovery_environment('/backups/full', '/archive', now() - interval '2 hours');
SELECT * FROM wal_mgmt.monitor_recovery_progress();

-- =============================================================================
-- 10. DISASTER RECOVERY PLAYBOOK (reference table)
-- =============================================================================
CREATE OR REPLACE FUNCTION wal_mgmt.disaster_recovery_playbook()
RETURNS TABLE(phase TEXT, step_number INTEGER, action_item TEXT, command_example TEXT, estimated_duration TEXT, critical_notes TEXT)
LANGUAGE sql IMMUTABLE AS $$
    VALUES
    ('ASSESSMENT',  1, 'Assess the damage and choose a strategy', '# what failed, when, which data?', '15-30 min', 'Write down the incident timeline: it gives you the recovery target'),
    ('ASSESSMENT',  2, 'Verify backups and WAL archive', 'pg_verifybackup /backups/full && ls /archive | tail', '5 min', 'No continuous WAL = no PITR'),
    ('PREPARATION', 3, 'Stop PostgreSQL', 'pg_ctl stop -m fast', '1 min', 'Prevent further writes'),
    ('PREPARATION', 4, 'Move the damaged data directory aside', 'mv $PGDATA $PGDATA.damaged', '1-60 min', 'Preserve evidence and a rollback path'),
    ('RECOVERY',    5, 'Restore the base backup', 'tar -xf /backups/base.tar -C $PGDATA  (or pg_combinebackup for PG17 incrementals)', '10-120 min', 'Ownership postgres:postgres, mode 0700'),
    ('RECOVERY',    6, 'Write recovery settings + recovery.signal', 'SELECT wal_mgmt.generate_recovery_config(target_name => ''before_x'')', '5 min', 'recovery.conf no longer exists (PG12+)'),
    ('RECOVERY',    7, 'Start and replay to the target', 'pg_ctl start; tail -f log/*', '15-300 min', 'recovery_target_action = pause lets you inspect first'),
    ('VALIDATION',  8, 'Check the data at the target', 'SELECT * FROM backup_mgmt.compare_table_counts();', '5-15 min', 'Wrong target? Stop, restore again, choose another target'),
    ('VALIDATION',  9, 'Promote', 'SELECT pg_promote();', '1 min', 'Starts a new timeline'),
    ('RESUMPTION', 10, 'Re-point applications', '# update connection strings / DNS / pooler', '5-15 min', 'Coordinate with app teams'),
    ('RESUMPTION', 11, 'Take a new base backup immediately', 'pg_basebackup ...', '10-60 min', 'Protects the new timeline'),
    ('RESUMPTION', 12, 'Communicate and review', '# post-incident review', '15 min', 'Include any data-loss window')
$$;

SELECT phase, step_number, action_item FROM wal_mgmt.disaster_recovery_playbook() ORDER BY step_number;

\echo '== PITR module complete =='
