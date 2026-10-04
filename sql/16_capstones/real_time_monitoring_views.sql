-- =============================================================================
-- File: sql/16_capstones/real_time_monitoring_views.sql
-- Capstone: an operational monitoring layer built from PostgreSQL's own
--           statistics views, plus data-freshness checks and NOTIFY alerts
-- =============================================================================
-- What this capstone teaches
--   * Where live operational truth lives: pg_stat_activity, pg_locks +
--     pg_blocking_pids(), pg_stat_statements, pg_stat_io (PostgreSQL 16+),
--     pg_stat_user_tables / pg_statio_user_tables, pg_stat_database,
--     pg_replication_slots / pg_stat_replication, pg_database.datfrozenxid.
--   * Turning raw counters into decisions: ratios, ages, thresholds and a
--     single traffic-light health view.
--   * Version / extension guards (server_version_num, pg_extension) so the same
--     script runs on any server.
--   * Data freshness: how stale is each base table relative to the dataset's
--     reference clock meta.as_of() (the generated data ends there; wall-clock
--     now() would make everything look a year old).
--   * Snapshots for trending, LISTEN/NOTIFY for push alerts, and optional
--     pg_cron scheduling (skipped with a NOTICE where pg_cron is absent).
--
-- Statistics views describe the whole cluster or the current database; the
-- numbers you see depend on what else ran. That is the point: rerun the
-- queries while other sessions are busy.
-- All objects live in schema monitoring and are created idempotently.
-- =============================================================================

\echo '== 0. Schema'
CREATE SCHEMA IF NOT EXISTS monitoring;
COMMENT ON SCHEMA monitoring IS 'Capstone 16: operational monitoring views and data-freshness checks.';

-- -----------------------------------------------------------------------------
-- 1. Sessions: who is connected and what are they doing?
-- -----------------------------------------------------------------------------
-- Teaches: pg_stat_activity columns that matter. state 'idle in transaction'
-- holds snapshots and locks (blocks VACUUM cleanup); xact_age and state_age
-- reveal it. wait_event_type/wait_event say WHY a backend is not on CPU.
\echo '== 1. Session activity'
CREATE OR REPLACE VIEW monitoring.session_activity AS
SELECT a.pid,
       a.usename,
       a.datname,
       a.application_name,
       a.client_addr,
       a.backend_type,
       a.state,
       a.wait_event_type,
       a.wait_event,
       now() - a.backend_start               AS connection_age,
       now() - a.xact_start                  AS xact_age,
       now() - a.query_start                 AS query_age,
       now() - a.state_change                AS state_age,
       age(a.backend_xmin)                   AS xmin_age_xids,
       left(regexp_replace(a.query, '\s+', ' ', 'g'), 120) AS query_head
FROM pg_stat_activity a
WHERE a.pid <> pg_backend_pid();

-- Summary by backend type and state (client backends plus background workers).
SELECT backend_type, coalesce(state, '-') AS state, count(*) AS sessions,
       max(xact_age) AS oldest_xact
FROM monitoring.session_activity
GROUP BY backend_type, state
ORDER BY backend_type, state;

-- Problem sessions: long transactions or idle-in-transaction beyond a limit.
CREATE OR REPLACE VIEW monitoring.problem_sessions AS
SELECT pid, usename, datname, state, xact_age, state_age, wait_event_type, wait_event, query_head,
       CASE WHEN state = 'idle in transaction' AND state_age > interval '5 minutes' THEN 'idle in transaction > 5 min'
            WHEN state = 'active' AND query_age > interval '5 minutes'              THEN 'query running > 5 min'
            WHEN xact_age > interval '1 hour'                                       THEN 'transaction open > 1 h'
       END AS problem
FROM monitoring.session_activity
WHERE backend_type = 'client backend'
  AND (   (state = 'idle in transaction' AND state_age > interval '5 minutes')
       OR (state = 'active' AND query_age > interval '5 minutes')
       OR xact_age > interval '1 hour');

SELECT count(*) AS problem_sessions FROM monitoring.problem_sessions;

-- -----------------------------------------------------------------------------
-- 2. Lock waits: who blocks whom?
-- -----------------------------------------------------------------------------
-- Teaches: pg_blocking_pids(pid) (9.6+) returns the PIDs holding (or queued
-- ahead for) the lock a backend waits on, including parallel-group logic, so
-- you do not have to self-join pg_locks by hand. A blocking chain's root is a
-- blocker that is not itself blocked.
\echo '== 2. Lock waits'
CREATE OR REPLACE VIEW monitoring.lock_waits AS
SELECT w.pid                                  AS waiting_pid,
       w.usename                              AS waiting_user,
       now() - w.query_start                  AS waiting_for,
       w.wait_event_type || ':' || w.wait_event AS wait,
       left(w.query, 80)                      AS waiting_query,
       b.pid                                  AS blocking_pid,
       b.usename                              AS blocking_user,
       b.state                                AS blocking_state,
       now() - b.xact_start                   AS blocking_xact_age,
       left(b.query, 80)                      AS blocking_query,
       cardinality(pg_blocking_pids(b.pid)) = 0 AS blocker_is_root
FROM pg_stat_activity w
CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid)
JOIN pg_stat_activity b ON b.pid = bp.pid
WHERE w.wait_event_type = 'Lock';

SELECT count(*) AS waiting_backends FROM monitoring.lock_waits;

-- Seeing a lock wait needs two sessions. Try it by hand (after this file ran):
--   [Session A]  BEGIN; LOCK TABLE monitoring.metric_snapshots IN ACCESS EXCLUSIVE MODE;
--   [Session B]  SELECT count(*) FROM monitoring.metric_snapshots;     -- blocks
--   [Session A]  SELECT * FROM monitoring.lock_waits;                  -- shows B waiting on A
--   [Session A]  ROLLBACK;                                             -- B proceeds
-- In a script, never wait: use SET lock_timeout or NOWAIT. A single-session
-- demonstration of the guard (nothing else holds this lock, so it succeeds):
BEGIN;
SET LOCAL lock_timeout = '200ms';
LOCK TABLE pg_catalog.pg_class IN ACCESS SHARE MODE NOWAIT;
SELECT mode, granted FROM pg_locks
WHERE pid = pg_backend_pid() AND relation = 'pg_catalog.pg_class'::regclass;
ROLLBACK;

-- -----------------------------------------------------------------------------
-- 3. Statement statistics (pg_stat_statements), guarded
-- -----------------------------------------------------------------------------
-- Teaches: the extension must be in shared_preload_libraries AND created in the
-- database. Rank by total_exec_time (where the server's time goes), then look
-- at mean time and cache hit ratio per statement. Columns used here exist in
-- PG 13-17 (PG17 renamed blk_read_time to shared_blk_read_time, so avoid it).
\echo '== 3. Top statements (pg_stat_statements)'
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        EXECUTE $v$
        CREATE OR REPLACE VIEW monitoring.top_statements AS
        SELECT s.queryid,
               s.calls,
               round(s.total_exec_time::numeric, 1)                        AS total_ms,
               round(s.mean_exec_time::numeric, 2)                         AS mean_ms,
               round((100 * s.total_exec_time / nullif(sum(s.total_exec_time) OVER (), 0))::numeric, 1) AS pct_of_total,
               s.rows,
               round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1) AS hit_pct,
               s.temp_blks_written,
               left(regexp_replace(s.query, '\s+', ' ', 'g'), 80)          AS query_head
        FROM pg_stat_statements s
        WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        $v$;
    ELSE
        RAISE NOTICE 'pg_stat_statements not installed in %; skipping monitoring.top_statements', current_database();
    END IF;
END
$$;

SELECT calls, total_ms, mean_ms, pct_of_total, hit_pct, query_head
FROM monitoring.top_statements
ORDER BY total_ms DESC, queryid
LIMIT 5;

-- -----------------------------------------------------------------------------
-- 4. I/O by backend type (pg_stat_io, PostgreSQL 16+)
-- -----------------------------------------------------------------------------
-- Teaches: pg_stat_io splits I/O by backend_type x object x context. High
-- 'evictions' for client backends in the 'normal' context means shared_buffers
-- pressure; 'bulkread'/'vacuum' contexts use small ring buffers on purpose.
-- Multiply counts by op_bytes (8 kB) for volume.
\echo '== 4. pg_stat_io (PG16+)'
DO $$
BEGIN
    IF current_setting('server_version_num')::int >= 160000 THEN
        EXECUTE $v$
        CREATE OR REPLACE VIEW monitoring.io_by_backend AS
        SELECT backend_type, object, context,
               coalesce(reads, 0)     AS reads,
               coalesce(writes, 0)    AS writes,
               coalesce(extends, 0)   AS extends,
               coalesce(hits, 0)      AS hits,
               coalesce(evictions, 0) AS evictions,
               pg_size_pretty((coalesce(reads, 0) + coalesce(writes, 0)) * op_bytes) AS read_write_volume,
               round(100.0 * hits / nullif(hits + reads, 0), 2)                      AS hit_pct
        FROM pg_stat_io
        WHERE coalesce(reads, 0) + coalesce(writes, 0) + coalesce(hits, 0) + coalesce(extends, 0) > 0
        $v$;
    ELSE
        RAISE NOTICE 'pg_stat_io needs PostgreSQL 16+ (this is %); skipping', current_setting('server_version');
    END IF;
END
$$;

SELECT backend_type, object, context, reads, writes, hits, evictions, hit_pct
FROM monitoring.io_by_backend
ORDER BY reads + writes DESC, backend_type, object, context
LIMIT 6;

-- -----------------------------------------------------------------------------
-- 5. Cache hit ratios
-- -----------------------------------------------------------------------------
-- Teaches: database-wide buffer hit ratio from pg_stat_database and per-table
-- heap/index hit ratios from pg_statio_user_tables. "Hit" means found in
-- shared_buffers; a miss may still be served by the OS page cache, so < 99%
-- is a hint, not proof, of a problem.
\echo '== 5. Cache hit ratios'
CREATE OR REPLACE VIEW monitoring.cache_hit_ratio AS
SELECT d.datname,
       d.blks_hit, d.blks_read,
       round(100.0 * d.blks_hit / nullif(d.blks_hit + d.blks_read, 0), 2) AS hit_pct,
       d.temp_files, pg_size_pretty(d.temp_bytes) AS temp_bytes,
       d.deadlocks, d.conflicts, d.xact_commit, d.xact_rollback
FROM pg_stat_database d
WHERE d.datname = current_database();

CREATE OR REPLACE VIEW monitoring.table_cache_hit AS
SELECT s.schemaname, s.relname,
       s.heap_blks_hit, s.heap_blks_read,
       round(100.0 * s.heap_blks_hit / nullif(s.heap_blks_hit + s.heap_blks_read, 0), 2) AS heap_hit_pct,
       round(100.0 * s.idx_blks_hit  / nullif(s.idx_blks_hit  + s.idx_blks_read, 0), 2)  AS idx_hit_pct
FROM pg_statio_user_tables s;

SELECT datname, hit_pct, temp_files, temp_bytes, deadlocks FROM monitoring.cache_hit_ratio;

SELECT schemaname, relname, heap_blks_read, heap_hit_pct, idx_hit_pct
FROM monitoring.table_cache_hit
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
ORDER BY heap_blks_read DESC, schemaname, relname
LIMIT 5;

-- -----------------------------------------------------------------------------
-- 6. Table health: dead tuples, bloat proxy, vacuum/analyze recency, XID age
-- -----------------------------------------------------------------------------
-- Teaches: autovacuum triggers when
--   n_dead_tup > autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * reltuples
-- (per-table reloptions override the GUCs; this view uses the global values).
-- age(relfrozenxid) counts transactions since the table was last fully frozen;
-- at autovacuum_freeze_max_age (default 200M) an anti-wraparound vacuum is
-- forced. Exact bloat needs pgstattuple (expensive: reads the whole table), so
-- the view uses dead-tuple ratio as a cheap proxy and section 6b shows
-- pgstattuple_approx on one table.
\echo '== 6. Table health (dead tuples, vacuum age, wraparound)'
CREATE OR REPLACE VIEW monitoring.table_health AS
SELECT s.schemaname, s.relname,
       s.n_live_tup, s.n_dead_tup,
       round(100.0 * s.n_dead_tup / nullif(s.n_live_tup + s.n_dead_tup, 0), 2)          AS dead_pct,
       (current_setting('autovacuum_vacuum_threshold')::float8
        + current_setting('autovacuum_vacuum_scale_factor')::float8 * greatest(c.reltuples, 0))::bigint
                                                                                          AS autovacuum_trigger_at,
       s.n_mod_since_analyze,
       greatest(s.last_vacuum, s.last_autovacuum)                                         AS last_vacuumed,
       greatest(s.last_analyze, s.last_autoanalyze)                                       AS last_analyzed,
       s.vacuum_count + s.autovacuum_count                                                AS vacuums,
       age(c.relfrozenxid)                                                                AS xid_age,
       round((100.0 * age(c.relfrozenxid) / current_setting('autovacuum_freeze_max_age')::float8)::numeric, 2)
                                                                                          AS pct_to_forced_freeze,
       pg_size_pretty(pg_total_relation_size(c.oid))                                      AS total_size,
       pg_total_relation_size(c.oid)                                                      AS total_bytes,
       s.seq_scan, s.idx_scan
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid;

SELECT schemaname, relname, n_live_tup, n_dead_tup, dead_pct, autovacuum_trigger_at,
       last_vacuumed IS NOT NULL AS vacuumed, xid_age, total_size
FROM monitoring.table_health
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
ORDER BY n_dead_tup DESC, total_bytes DESC, schemaname, relname
LIMIT 6;
-- On a freshly cloned database the cumulative statistics start empty
-- (n_live_tup = 0, never vacuumed): stats are per cluster, not copied by
-- CREATE DATABASE ... TEMPLATE. ANALYZE or normal traffic fills them in.

-- Database-level wraparound headroom (the number that pages DBAs at 3 am).
CREATE OR REPLACE VIEW monitoring.xid_wraparound AS
SELECT datname, age(datfrozenxid) AS xid_age,
       round(100.0 * age(datfrozenxid) / 2147483647, 3) AS pct_of_hard_limit,
       mxid_age(datminmxid) AS multixact_age
FROM pg_database;

SELECT * FROM monitoring.xid_wraparound WHERE datname = current_database();

-- 6b. Exact-ish bloat for one table with pgstattuple_approx (visibility-map
-- assisted, much cheaper than pgstattuple). Guarded on the extension.
DO $$
DECLARE r record;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple') THEN
        SELECT * INTO r FROM pgstattuple_approx('mobility.sensor_readings'::regclass);
        RAISE NOTICE 'sensor_readings: table_len=% approx_tuple_pct=% dead_tuple_pct=% approx_free_pct=%',
            pg_size_pretty(r.table_len), round(r.approx_tuple_percent::numeric, 1),
            round(r.dead_tuple_percent::numeric, 1), round(r.approx_free_percent::numeric, 1);
    ELSE
        RAISE NOTICE 'pgstattuple not installed; skipping bloat estimate';
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 7. Replication: slots and standbys
-- -----------------------------------------------------------------------------
-- Teaches: an inactive replication slot pins WAL forever (disk fills). Watch
-- retained WAL = current LSN - restart_lsn, and wal_status ('lost' = broken).
-- pg_stat_replication shows lag per connected standby. Both are empty on a
-- stand-alone lab server, which is the correct reading, not an error.
\echo '== 7. Replication slots and standbys'
CREATE OR REPLACE VIEW monitoring.replication_slots AS
SELECT slot_name, slot_type, database, active, active_pid, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)                  AS retained_wal_bytes,
       safe_wal_size
FROM pg_replication_slots;

CREATE OR REPLACE VIEW monitoring.replication_standbys AS
SELECT application_name, client_addr, state, sync_state,
       write_lag, flush_lag, replay_lag,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_bytes_behind
FROM pg_stat_replication;

SELECT (SELECT count(*) FROM monitoring.replication_slots)                     AS slots,
       (SELECT count(*) FROM monitoring.replication_slots WHERE NOT active)    AS inactive_slots,
       (SELECT count(*) FROM monitoring.replication_standbys)                  AS standbys,
       pg_is_in_recovery()                                                     AS is_standby;

-- -----------------------------------------------------------------------------
-- 8. Data freshness per base table relative to meta.as_of()
-- -----------------------------------------------------------------------------
-- Teaches: freshness SLAs as data. A config table says which timestamp column
-- represents "arrival" and how often new rows are expected; a function builds
-- one max() query per table with format('%I') (safe identifier quoting) and
-- EXECUTE. Staleness is measured against meta.as_of(), the dataset's clock.
-- In production you would compare against now().
\echo '== 8. Data freshness'
CREATE TABLE IF NOT EXISTS monitoring.freshness_sla (
    table_name      regclass PRIMARY KEY,
    ts_column       name     NOT NULL,
    expected_every  interval NOT NULL,
    note            text
);
INSERT INTO monitoring.freshness_sla (table_name, ts_column, expected_every, note) VALUES
    ('mobility.sensor_readings',      'reading_time',     '1 hour',   'hourly sensor feed'),
    ('mobility.station_inventory',    'recorded_at',      '1 hour',   'dock/vehicle counts'),
    ('mobility.trip_segments',        'start_time',       '15 minutes','trip stream'),
    ('commerce.orders',               'order_date',       '1 hour',   'order stream'),
    ('commerce.payments',             'payment_date',     '1 hour',   'payment processor feed'),
    ('documents.complaint_records',   'submitted_at',     '1 day',    '311 complaints'),
    ('civics.permit_applications',    'application_date', '2 days',   'permit intake'),
    ('civics.tax_payments',           'payment_date',     '7 days',   'tax ledger'),
    ('civics.voting_records',         'voted_at',         '365 days', 'elections are rare by design')
ON CONFLICT (table_name) DO UPDATE
    SET ts_column = EXCLUDED.ts_column, expected_every = EXCLUDED.expected_every, note = EXCLUDED.note;

CREATE OR REPLACE FUNCTION monitoring.data_freshness(ref timestamptz DEFAULT meta.as_of())
RETURNS TABLE (table_name text, ts_column name, row_count bigint, latest timestamptz,
               staleness interval, expected_every interval, status text)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT f.table_name, f.ts_column, f.expected_every FROM monitoring.freshness_sla f ORDER BY f.table_name::text
    LOOP
        table_name := r.table_name::text;
        ts_column  := r.ts_column;
        expected_every := r.expected_every;
        -- reltuples is a free estimate; count(*) on big tables is not free.
        SELECT greatest(c.reltuples, 0)::bigint INTO row_count FROM pg_class c WHERE c.oid = r.table_name;
        EXECUTE format('SELECT max(%I) FROM %s WHERE %I <= $1', r.ts_column, r.table_name, r.ts_column)
            INTO latest USING ref;
        staleness := ref - latest;
        status := CASE WHEN latest IS NULL                         THEN 'EMPTY'
                       WHEN staleness <= r.expected_every          THEN 'fresh'
                       WHEN staleness <= 3 * r.expected_every      THEN 'late'
                       ELSE 'STALE' END;
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE OR REPLACE VIEW monitoring.data_freshness AS
SELECT * FROM monitoring.data_freshness();

SELECT table_name, row_count, latest, staleness, expected_every, status
FROM monitoring.data_freshness
ORDER BY status DESC, table_name;
-- Expected finding: the commerce feeds end ~3 days before as_of (the order
-- generator's 52-week calendar stops on Sunday 2025-12-28), so orders and
-- payments are flagged STALE. That is what a freshness check is for:
-- it surfaces a feed gap that row counts alone would never show.

-- -----------------------------------------------------------------------------
-- 9. One-row health summary (traffic lights)
-- -----------------------------------------------------------------------------
-- Teaches: compose the views into a single row a dashboard tile or a
-- Prometheus exporter query can scrape.
\echo '== 9. Health summary'
CREATE OR REPLACE VIEW monitoring.health_summary AS
SELECT now()                                                                      AS checked_at,
       (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend') AS client_sessions,
       current_setting('max_connections')::int                                    AS max_connections,
       (SELECT count(*) FROM monitoring.problem_sessions)                          AS problem_sessions,
       (SELECT count(*) FROM monitoring.lock_waits)                                AS lock_waits,
       (SELECT hit_pct FROM monitoring.cache_hit_ratio)                            AS cache_hit_pct,
       (SELECT max(dead_pct) FROM monitoring.table_health WHERE n_live_tup > 1000) AS worst_dead_pct,
       (SELECT max(xid_age)  FROM monitoring.xid_wraparound)                       AS max_db_xid_age,
       (SELECT coalesce(sum(retained_wal_bytes) FILTER (WHERE NOT active), 0)
          FROM monitoring.replication_slots)                                       AS inactive_slot_wal_bytes,
       (SELECT count(*) FROM monitoring.data_freshness WHERE status IN ('STALE', 'EMPTY')) AS stale_tables,
       CASE
         WHEN (SELECT count(*) FROM monitoring.lock_waits) > 5
           OR (SELECT max(xid_age) FROM monitoring.xid_wraparound) > 1000000000     THEN 'RED'
         WHEN (SELECT count(*) FROM monitoring.problem_sessions) > 0
           OR (SELECT count(*) FROM monitoring.data_freshness WHERE status IN ('STALE', 'EMPTY')) > 0
           OR coalesce((SELECT hit_pct FROM monitoring.cache_hit_ratio), 100) < 95  THEN 'AMBER'
         ELSE 'GREEN'
       END                                                                        AS overall;

SELECT client_sessions, max_connections, problem_sessions, lock_waits, cache_hit_pct,
       worst_dead_pct, inactive_slot_wal_bytes, stale_tables, overall
FROM monitoring.health_summary;

-- -----------------------------------------------------------------------------
-- 10. Snapshots for trending, NOTIFY alerts, optional pg_cron schedule
-- -----------------------------------------------------------------------------
-- Teaches: statistics views are cumulative counters or point-in-time states;
-- trends need periodic snapshots (here a small module-owned table). Alerts are
-- pushed with pg_notify(channel, payload): any client that ran
-- LISTEN monitoring_alerts receives the JSON payload when the transaction
-- commits (psql prints it after the next command).
\echo '== 10. Snapshots and alerts'
CREATE TABLE IF NOT EXISTS monitoring.metric_snapshots (
    snapshot_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    taken_at      timestamptz NOT NULL DEFAULT now(),   -- wall clock: this is a real event
    metric        text NOT NULL,
    value         numeric,
    detail        jsonb
);
CREATE INDEX IF NOT EXISTS metric_snapshots_metric_time_idx ON monitoring.metric_snapshots (metric, taken_at DESC);

CREATE OR REPLACE FUNCTION monitoring.capture_snapshot()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    h monitoring.health_summary%ROWTYPE;
    n integer;
BEGIN
    SELECT * INTO h FROM monitoring.health_summary;
    INSERT INTO monitoring.metric_snapshots (metric, value, detail)
    VALUES ('client_sessions',  h.client_sessions,  NULL),
           ('lock_waits',       h.lock_waits,       NULL),
           ('cache_hit_pct',    h.cache_hit_pct,    NULL),
           ('worst_dead_pct',   h.worst_dead_pct,   NULL),
           ('stale_tables',     h.stale_tables,     NULL),
           ('overall',          NULL,               jsonb_build_object('status', h.overall));
    GET DIAGNOSTICS n = ROW_COUNT;
    IF h.overall <> 'GREEN' THEN
        PERFORM pg_notify('monitoring_alerts',
                          jsonb_build_object('status', h.overall, 'lock_waits', h.lock_waits,
                                             'problem_sessions', h.problem_sessions,
                                             'stale_tables', h.stale_tables,
                                             'at', h.checked_at)::text);
    END IF;
    -- retention: keep 7 days of snapshots
    DELETE FROM monitoring.metric_snapshots WHERE taken_at < now() - interval '7 days';
    RETURN n;
END
$$;

LISTEN monitoring_alerts;
SELECT monitoring.capture_snapshot() AS metrics_captured;
UNLISTEN monitoring_alerts;

SELECT metric, value, detail
FROM monitoring.metric_snapshots
WHERE taken_at = (SELECT max(taken_at) FROM monitoring.metric_snapshots)
ORDER BY metric;

-- Schedule every minute with pg_cron when it exists (only the 'polaris'
-- database has it in this lab). Elsewhere: skip with a NOTICE.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        EXECUTE $c$SELECT cron.schedule('monitoring_snapshot', '* * * * *',
                                         'SELECT monitoring.capture_snapshot()')$c$;
        RAISE NOTICE 'pg_cron job monitoring_snapshot scheduled (remove with cron.unschedule)';
    ELSE
        RAISE NOTICE 'pg_cron not installed in %; run SELECT monitoring.capture_snapshot() from an external scheduler', current_database();
    END IF;
END
$$;
