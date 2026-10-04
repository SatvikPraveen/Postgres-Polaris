-- File: sql/13_backup_replication/backup_restore_playbook.sql
-- Purpose: logical backups with pg_dump / pg_restore / psql, plus SQL-side bookkeeping
--
-- What this module teaches
--   1. Logical (pg_dump) vs physical (pg_basebackup) backups and when to use which
--   2. pg_dump formats (plain / custom / directory / tar), selective dumps, parallel dumps,
--      PG16+ compression (lz4, zstd), PG17 --filter files
--   3. What pg_dump does NOT include: roles and tablespaces (use pg_dumpall --globals-only)
--   4. Restores: pg_restore --list / --use-list, --clean --if-exists, --jobs, --single-transaction
--   5. A small backup catalogue in SQL: job logging, size estimates, retention, reporting
--
-- Shell commands are kept in comments because they run outside the database.  They are
-- written for this repo's Docker setup (container polaris-db, superuser polaris).

\echo '== 13 / backup & restore playbook =='

-- =============================================================================
-- 1. BACKUP CATALOGUE (module-owned schema)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS backup_mgmt;

CREATE TABLE IF NOT EXISTS backup_mgmt.backup_jobs (
    job_id           BIGSERIAL PRIMARY KEY,
    job_name         TEXT NOT NULL,
    backup_type      TEXT CHECK (backup_type IN ('full', 'schema_only', 'data_only', 'custom', 'globals', 'physical', 'incremental')),
    database_name    TEXT NOT NULL,
    file_path        TEXT,
    file_size_bytes  BIGINT,
    start_time       TIMESTAMPTZ,
    end_time         TIMESTAMPTZ,
    -- timestamptz - timestamptz is immutable, so a stored generated column is allowed
    duration_seconds NUMERIC GENERATED ALWAYS AS (EXTRACT(epoch FROM (end_time - start_time))) STORED,
    status           TEXT CHECK (status IN ('running', 'completed', 'failed', 'cancelled', 'expired')) DEFAULT 'running',
    server_version   TEXT,
    compression      TEXT,              -- e.g. 'gzip:9', 'zstd:3', 'lz4', 'none'
    error_message    TEXT,
    created_by       TEXT DEFAULT current_user
);

CREATE TABLE IF NOT EXISTS backup_mgmt.backup_schedule (
    schedule_id    BIGSERIAL PRIMARY KEY,
    schedule_name  TEXT NOT NULL UNIQUE,
    backup_type    TEXT NOT NULL,
    cron_schedule  TEXT NOT NULL,       -- '0 2 * * *' = daily at 02:00
    retention_days INTEGER DEFAULT 30,
    compression    TEXT DEFAULT 'zstd:3',
    is_active      BOOLEAN DEFAULT TRUE,
    last_run       TIMESTAMPTZ,
    next_run       TIMESTAMPTZ,
    created_at     TIMESTAMPTZ DEFAULT now()
);

INSERT INTO backup_mgmt.backup_schedule (schedule_name, backup_type, cron_schedule, retention_days, compression)
VALUES ('nightly_full',      'custom',      '0 2 * * *', 30,  'zstd:3'),
       ('weekly_globals',    'globals',     '0 3 * * 0', 90,  'none'),
       ('hourly_schema_ddl', 'schema_only', '0 * * * *', 7,   'none')
ON CONFLICT (schedule_name) DO NOTHING;

-- =============================================================================
-- 2. BACKUP COMMAND TEMPLATES (shell, run from the host)
-- =============================================================================
-- Logical backups (pg_dump) are consistent snapshots of ONE database taken from a single
-- REPEATABLE READ transaction; they do not block writers.  They are portable across major
-- versions and architectures but restore by replaying SQL (slow for big DBs, indexes rebuilt).
/*
# Full database, custom format (compressed, selective restore possible, needed for pg_restore)
docker exec polaris-db pg_dump -U polaris -d polaris \
  --format=custom --compress=zstd:3 --verbose \
  --file=/tmp/polaris_full_$(date +%Y%m%d_%H%M%S).dump
# (--compress=zstd / lz4 need PG16+ pg_dump; older versions only support gzip levels 0-9)

# Copy it out of the container
docker cp polaris-db:/tmp/polaris_full_20251231_020000.dump ./backups/

# Or stream straight to the host (no file inside the container)
docker exec polaris-db pg_dump -U polaris -d polaris -Fc > ./backups/polaris_full.dump

# Schema only (DDL), plain SQL - good for code review / diffing
docker exec polaris-db pg_dump -U polaris -d polaris --schema-only --format=plain > ./backups/polaris_schema.sql

# Data only
docker exec polaris-db pg_dump -U polaris -d polaris --data-only -Fc > ./backups/polaris_data.dump

# One schema / specific tables (patterns are schema-qualified)
docker exec polaris-db pg_dump -U polaris -d polaris -Fc --schema=civics > ./backups/civics.dump
docker exec polaris-db pg_dump -U polaris -d polaris -Fc \
  --table=civics.citizens --table=geo.neighborhood_boundaries > ./backups/core_tables.dump

# Large database: directory format + parallel workers (-j only works with -Fd)
docker exec polaris-db pg_dump -U polaris -d polaris \
  --format=directory --jobs=4 --compress=zstd:3 --file=/tmp/polaris_dir

# Exclusions (quote patterns so the shell does not expand them)
docker exec polaris-db pg_dump -U polaris -d polaris -Fc \
  --exclude-table='*_log' --exclude-table='*.temp_*' --exclude-schema=synth \
  --exclude-table-data='audit.*' > ./backups/polaris_lean.dump

# PG17: put include/exclude rules in a file
#   filter.txt:   include table civics.*
#                 exclude table_data audit.*
docker exec -i polaris-db pg_dump -U polaris -d polaris -Fc --filter=- < filter.txt > ./backups/filtered.dump

# ROLES ARE NOT IN pg_dump!  Users, groups, passwords and memberships are cluster-global.
docker exec polaris-db pg_dumpall -U polaris --globals-only > ./backups/globals.sql
*/

-- =============================================================================
-- 3. RESTORE COMMAND TEMPLATES (shell)
-- =============================================================================
/*
# Restore into a NEW database (restore globals first so owners/grants resolve)
docker exec -i polaris-db psql -U polaris -d postgres < ./backups/globals.sql
docker exec polaris-db createdb -U polaris polaris_restored
docker exec -i polaris-db pg_restore -U polaris -d polaris_restored --verbose --jobs=4 < ./backups/polaris_full.dump
#   note: --jobs needs a seekable file, so for parallel restore docker cp the dump in first
#   and pass the path instead of stdin.

# Restore over an existing database (drops objects first; all-or-nothing)
pg_restore -U polaris -d polaris --clean --if-exists --single-transaction /tmp/polaris_full.dump

# Inspect / edit the table of contents, then restore only what you kept
pg_restore --list /tmp/polaris_full.dump > toc.list
#   ... comment out lines with ';' ...
pg_restore -U polaris -d polaris_restored --use-list=toc.list /tmp/polaris_full.dump

# One table back from a full dump (-n schema AND -t table name)
pg_restore -U polaris -d polaris_restored -n civics -t citizens /tmp/polaris_full.dump

# Data-only restore into existing tables; --disable-triggers needs superuser and also
# skips FK checks, so validate afterwards
pg_restore -U polaris -d polaris_restored --data-only --disable-triggers /tmp/polaris_data.dump

# Plain-format dumps are restored with psql, stopping at the first error
psql -U polaris -d polaris_restored -v ON_ERROR_STOP=1 --single-transaction -f polaris_schema.sql

# After any restore: refresh planner statistics (pg_dump does not carry them)
vacuumdb -U polaris -d polaris_restored --analyze-in-stages
*/
-- Physical backups (pg_basebackup) copy the whole cluster and enable point-in-time
-- recovery; see point_in_time_recovery.sql.

-- =============================================================================
-- 4. SIZE ESTIMATION BEFORE A BACKUP
-- =============================================================================
-- On-disk size includes indexes and dead tuples; a dump contains only live rows and
-- index DEFINITIONS, so it is usually much smaller.  The 0.3 factor is a rough guess for
-- compressed custom-format output.
CREATE OR REPLACE FUNCTION backup_mgmt.estimate_backup_size(
    p_schemas TEXT[] DEFAULT ARRAY['civics', 'commerce', 'documents', 'mobility', 'geo', 'analytics']
)
RETURNS TABLE(
    schema_name NAME,
    table_name NAME,
    est_rows BIGINT,
    table_size TEXT,
    indexes_size TEXT,
    total_size TEXT,
    estimated_dump_size TEXT
) LANGUAGE sql STABLE AS $$
    SELECT n.nspname,
           c.relname,
           GREATEST(c.reltuples, 0)::BIGINT,                         -- planner estimate, no scan
           pg_size_pretty(pg_table_size(c.oid)),
           pg_size_pretty(pg_indexes_size(c.oid)),
           pg_size_pretty(pg_total_relation_size(c.oid)),
           pg_size_pretty((pg_table_size(c.oid) * 0.3)::BIGINT)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'm')
      AND n.nspname = ANY (p_schemas)
    ORDER BY pg_total_relation_size(c.oid) DESC, n.nspname, c.relname
$$;

\echo '-- largest relations (top 8)'
SELECT * FROM backup_mgmt.estimate_backup_size() LIMIT 8;

SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size_on_disk;

-- =============================================================================
-- 5. JOB LOGGING
-- =============================================================================
CREATE OR REPLACE FUNCTION backup_mgmt.log_backup_start(
    job_name      TEXT,
    backup_type   TEXT,
    database_name TEXT DEFAULT current_database(),
    file_path     TEXT DEFAULT NULL,
    compression   TEXT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_job_id BIGINT;
BEGIN
    INSERT INTO backup_mgmt.backup_jobs
        (job_name, backup_type, database_name, file_path, start_time, server_version, compression)
    VALUES
        (job_name, backup_type, database_name, file_path, clock_timestamp(),
         current_setting('server_version'), compression)
    RETURNING backup_jobs.job_id INTO v_job_id;
    RETURN v_job_id;
END $$;

CREATE OR REPLACE FUNCTION backup_mgmt.log_backup_complete(
    job_id          BIGINT,
    file_size_bytes BIGINT DEFAULT NULL,
    status          TEXT DEFAULT 'completed',
    error_message   TEXT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    UPDATE backup_mgmt.backup_jobs b
    SET end_time        = clock_timestamp(),
        file_size_bytes = log_backup_complete.file_size_bytes,
        status          = log_backup_complete.status,
        error_message   = log_backup_complete.error_message
    WHERE b.job_id = log_backup_complete.job_id;
END $$;

-- =============================================================================
-- 6. RETENTION
-- =============================================================================
-- SQL can only mark catalogue rows; deleting files is the job of the backup script.
CREATE OR REPLACE FUNCTION backup_mgmt.cleanup_old_backups(retention_days INTEGER DEFAULT 30)
RETURNS TABLE(cleanup_action TEXT, job_count BIGINT, total_size_freed TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_size  BIGINT;
    v_count BIGINT;
BEGIN
    WITH expired AS (
        UPDATE backup_mgmt.backup_jobs
        SET status = 'expired'
        WHERE end_time < now() - make_interval(days => retention_days)
          AND status = 'completed'
        RETURNING file_size_bytes
    )
    SELECT count(*), COALESCE(sum(file_size_bytes), 0) INTO v_count, v_size FROM expired;

    RETURN QUERY SELECT 'Marked expired'::TEXT, v_count, pg_size_pretty(v_size);
    RETURN QUERY SELECT 'Action required'::TEXT, 0::BIGINT, 'Delete the files with an external script'::TEXT;
END $$;

-- =============================================================================
-- 7. POST-RESTORE VERIFICATION
-- =============================================================================
-- Exact row counts per table (run on source and restored DB, then diff the output).
-- pg_stat counters are NOT reliable for this: they reset and are not restored.
CREATE OR REPLACE FUNCTION backup_mgmt.compare_table_counts(
    p_schemas TEXT[] DEFAULT ARRAY['civics', 'commerce', 'documents', 'mobility', 'geo']
)
RETURNS TABLE(schema_name NAME, table_name NAME, exact_count BIGINT, size_class TEXT)
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT n.nspname, c.relname
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname = ANY (p_schemas)
        ORDER BY n.nspname, c.relname
    LOOP
        schema_name := r.nspname;
        table_name  := r.relname;
        EXECUTE format('SELECT count(*) FROM %I.%I', r.nspname, r.relname) INTO exact_count;
        size_class := CASE WHEN exact_count = 0 THEN 'empty'
                           WHEN exact_count < 1000 THEN 'small'
                           WHEN exact_count < 100000 THEN 'medium'
                           ELSE 'large' END;
        RETURN NEXT;
    END LOOP;
END $$;

\echo '-- exact row counts (civics + commerce)'
SELECT * FROM backup_mgmt.compare_table_counts(ARRAY['civics', 'commerce']);

-- A content fingerprint catches changed values that row counts miss.
SELECT 'civics.citizens' AS table_name,
       md5(string_agg(md5(c::TEXT), '' ORDER BY citizen_id)) AS content_fingerprint
FROM civics.citizens c;

-- =============================================================================
-- 8. SCRIPT GENERATOR
-- =============================================================================
CREATE OR REPLACE FUNCTION backup_mgmt.generate_backup_scripts(backup_scenario TEXT DEFAULT 'production')
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    s   TEXT;
    ext TEXT := CASE backup_scenario WHEN 'development' THEN 'sql' ELSE 'dump' END;
BEGIN
    s := '#!/usr/bin/env bash' || E'\n'
      || '# Generated backup script for: ' || backup_scenario || E'\n'
      || 'set -euo pipefail' || E'\n\n'
      || 'DB_HOST=${DB_HOST:-localhost}; DB_PORT=${DB_PORT:-5432}; DB_USER=${DB_USER:-polaris}' || E'\n'
      || 'DB_NAME=${DB_NAME:-' || current_database() || '}; BACKUP_DIR=${BACKUP_DIR:-/backups}' || E'\n'
      || 'TIMESTAMP=$(date +%Y%m%d_%H%M%S)' || E'\n'
      || 'OUT="$BACKUP_DIR/${DB_NAME}_' || backup_scenario || '_$TIMESTAMP.' || ext || '"' || E'\n\n';

    s := s || CASE backup_scenario
        WHEN 'production' THEN
            'pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \' || E'\n'
         || '  --format=custom --compress=zstd:3 \' || E'\n'
         || '  --exclude-table-data=''*_log'' --file="$OUT"' || E'\n'
         || 'pg_dumpall -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" --globals-only > "${OUT%.dump}_globals.sql"' || E'\n'
        WHEN 'development' THEN
            'pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \' || E'\n'
         || '  --format=plain --schema-only --file="$OUT"' || E'\n'
        WHEN 'migration' THEN
            'pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \' || E'\n'
         || '  --format=custom --data-only \' || E'\n'
         || '  --exclude-table=''*_temp'' --exclude-table=''*_staging'' --file="$OUT"' || E'\n'
        ELSE
            'pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --format=custom --file="$OUT"' || E'\n'
        END;

    s := s || E'\n# Verify: the file exists, is non-empty, and (for archives) has a readable TOC\n'
      || 'test -s "$OUT" || { echo "Backup failed: $OUT missing or empty" >&2; exit 1; }' || E'\n'
      || CASE WHEN ext = 'dump' THEN 'pg_restore --list "$OUT" > /dev/null' || E'\n' ELSE '' END
      || 'ls -lh "$OUT"' || E'\n';
    RETURN s;
END $$;

\echo '-- generated production script'
SELECT backup_mgmt.generate_backup_scripts('production') AS script;

-- Validation checklist (the real checks run in the shell; the only proof of a backup is a test restore)
CREATE OR REPLACE FUNCTION backup_mgmt.validate_backup(backup_file_path TEXT, backup_format TEXT DEFAULT 'custom')
RETURNS TABLE(step INTEGER, validation_step TEXT, command TEXT)
LANGUAGE sql IMMUTABLE AS $$
    SELECT * FROM (VALUES
        (1, 'File exists and is non-empty', 'test -s ' || backup_file_path),
        (2, 'Archive TOC readable',
            CASE WHEN backup_format IN ('custom', 'directory', 'tar')
                 THEN 'pg_restore --list ' || backup_file_path || ' | head'
                 ELSE 'head -n 20 ' || backup_file_path END),
        (3, 'Test restore into a scratch database',
            'createdb restore_test && pg_restore -d restore_test --exit-on-error ' || backup_file_path),
        (4, 'Compare row counts / fingerprints',
            'psql -d restore_test -c "SELECT * FROM backup_mgmt.compare_table_counts()"'),
        (5, 'Drop the scratch database', 'dropdb restore_test')
    ) v(step, validation_step, command)
$$;

SELECT * FROM backup_mgmt.validate_backup('/tmp/polaris_full.dump');

-- =============================================================================
-- 9. REPORTING (demo with simulated jobs, rolled back)
-- =============================================================================
CREATE OR REPLACE FUNCTION backup_mgmt.backup_status_report(days_back INTEGER DEFAULT 7)
RETURNS TABLE(report_section TEXT, metric_name TEXT, metric_value TEXT, status_indicator TEXT)
LANGUAGE sql STABLE AS $$
    WITH recent AS (
        SELECT * FROM backup_mgmt.backup_jobs
        WHERE start_time >= now() - make_interval(days => days_back)
    )
    SELECT 'Recent Backups', 'Total backups (last ' || days_back || ' days)',
           count(*)::TEXT, CASE WHEN count(*) > 0 THEN 'OK' ELSE 'WARNING' END
    FROM recent
    UNION ALL
    SELECT 'Recent Backups', 'Success rate',
           COALESCE(round(100.0 * count(*) FILTER (WHERE status = 'completed') / NULLIF(count(*), 0), 1)::TEXT || '%', 'n/a'),
           CASE WHEN count(*) = 0 THEN 'NO DATA'
                WHEN 100.0 * count(*) FILTER (WHERE status = 'completed') / count(*) >= 95 THEN 'OK'
                WHEN 100.0 * count(*) FILTER (WHERE status = 'completed') / count(*) >= 80 THEN 'WARNING'
                ELSE 'CRITICAL' END
    FROM recent
    UNION ALL
    SELECT 'Recent Backups', 'Hours since last successful backup',
           COALESCE(round(extract(epoch FROM now() - max(end_time)) / 3600, 1)::TEXT, 'never'),
           CASE WHEN max(end_time) > now() - interval '26 hours' THEN 'OK' ELSE 'CRITICAL' END
    FROM recent WHERE status = 'completed'
    UNION ALL
    SELECT 'Storage', 'Average backup size',
           COALESCE(pg_size_pretty(avg(file_size_bytes)::BIGINT), 'n/a'), 'INFO'
    FROM recent WHERE status = 'completed' AND file_size_bytes IS NOT NULL
    UNION ALL
    SELECT 'Storage', 'Total retained',
           COALESCE(pg_size_pretty(sum(file_size_bytes)), '0 bytes'), 'INFO'
    FROM backup_mgmt.backup_jobs WHERE status = 'completed'
$$;

\echo '-- simulated backup runs and report (rolled back)'
BEGIN;
DO $$
DECLARE j BIGINT;
BEGIN
    j := backup_mgmt.log_backup_start('nightly_full', 'custom', current_database(), '/backups/n1.dump', 'zstd:3');
    PERFORM backup_mgmt.log_backup_complete(j, 52428800);
    j := backup_mgmt.log_backup_start('nightly_full', 'custom', current_database(), '/backups/n2.dump', 'zstd:3');
    PERFORM backup_mgmt.log_backup_complete(j, NULL, 'failed', 'pg_dump: error: connection to server lost');
    j := backup_mgmt.log_backup_start('weekly_globals', 'globals', current_database(), '/backups/g1.sql', 'none');
    PERFORM backup_mgmt.log_backup_complete(j, 4096);
    -- an old completed backup that retention should expire
    INSERT INTO backup_mgmt.backup_jobs (job_name, backup_type, database_name, start_time, end_time, status, file_size_bytes)
    VALUES ('nightly_full', 'custom', current_database(), now() - interval '40 days',
            now() - interval '40 days' + interval '3 minutes', 'completed', 50000000);
END $$;
SELECT job_name, backup_type, status, file_size_bytes, duration_seconds IS NOT NULL AS has_duration
FROM backup_mgmt.backup_jobs ORDER BY job_id;
SELECT * FROM backup_mgmt.backup_status_report(7);
SELECT * FROM backup_mgmt.cleanup_old_backups(30);
ROLLBACK;

\echo '== backup playbook complete =='
