-- File: sql/11_perf_tuning/stats_and_autovacuum.sql
-- Purpose: Planner statistics (pg_stats, n_distinct, statistics targets,
--          extended statistics on correlated columns and expressions) and
--          autovacuum/autoanalyze tuning (thresholds, per-table settings, monitoring).
--
-- Idempotent and non-destructive: experiments run on a module-owned copy of the
-- sensor readings (analytics.stats_lab). Base tables are only read; the optional
-- maintenance helpers default to dry-run and only print commands.
--
-- Why statistics matter: every plan choice (index vs seq scan, join order, hash vs
-- nested loop, memory sizing) is driven by row-count estimates computed from
-- pg_statistic. The planner assumes columns are independent unless extended
-- statistics tell it otherwise, and that assumption is the classic source of
-- 10x-100x misestimates.

-- Older revisions of this file created these functions with other result shapes.
DROP FUNCTION IF EXISTS analytics.check_table_statistics();
DROP FUNCTION IF EXISTS analytics.tune_autovacuum_parameters();
DROP FUNCTION IF EXISTS analytics.smart_analyze_tables();

-- =============================================================================
-- 0. LAB SETUP
-- =============================================================================
\echo '== 0. Lab setup: analytics.stats_lab (copy of mobility.sensor_readings)'

DROP TABLE IF EXISTS analytics.stats_lab;
CREATE TABLE analytics.stats_lab WITH (autovacuum_enabled = off) AS   -- we ANALYZE explicitly
SELECT reading_id, sensor_code, sensor_type, unit_of_measure, latitude, longitude,
       reading_time, reading_value, data_quality_score
FROM mobility.sensor_readings
ORDER BY reading_id;
ALTER TABLE analytics.stats_lab ADD PRIMARY KEY (reading_id);
ANALYZE analytics.stats_lab;

-- Helper: estimated vs actual rows of a query's top plan node (runs the query).
-- For trusted, hand-written SQL only: the text is executed as-is.
CREATE OR REPLACE FUNCTION analytics.row_estimate(p_sql text)
RETURNS TABLE (top_node text, estimated_rows bigint, actual_rows bigint, misestimate_factor numeric)
LANGUAGE plpgsql AS $$
DECLARE
    plan jsonb;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) ' || p_sql INTO plan;
    plan := plan -> 0 -> 'Plan';
    top_node       := plan ->> 'Node Type';
    estimated_rows := (plan ->> 'Plan Rows')::bigint;
    -- PG 18 reports Actual Rows as a per-loop average with decimals; go via numeric.
    actual_rows    := round((plan ->> 'Actual Rows')::numeric * (plan ->> 'Actual Loops')::numeric)::bigint;
    -- symmetric "how many times off" (1.0 = perfect), as used in plan-quality research
    misestimate_factor := round(greatest(greatest(estimated_rows, 1)::numeric / greatest(actual_rows, 1),
                                         greatest(actual_rows, 1)::numeric / greatest(estimated_rows, 1)), 1);
    RETURN NEXT;
END $$;
COMMENT ON FUNCTION analytics.row_estimate(text) IS
'Runs EXPLAIN (ANALYZE, FORMAT JSON) on trusted SQL and returns estimated vs actual rows of the top plan node.';

-- =============================================================================
-- 1. IS THERE ANY STATISTICS AT ALL? (pg_stat_user_tables vs pg_stats)
-- =============================================================================
\echo '== 1. Statistics freshness per table'

-- Two different things are often confused:
--   * pg_statistic / pg_stats: the planner's column statistics (written by ANALYZE,
--     persisted in the catalog, copied by CREATE DATABASE ... TEMPLATE).
--   * pg_stat_user_tables: cumulative activity counters (n_live_tup, last_analyze,
--     n_mod_since_analyze). These are NOT copied to a cloned database and are
--     reset after a crash, so "never analyzed" there does not mean "no stats".
CREATE OR REPLACE FUNCTION analytics.check_table_statistics()
RETURNS TABLE (schema_table text, has_planner_stats boolean, last_analyzed timestamptz,
               days_since_analyze numeric, n_live_tup bigint, n_mod_since_analyze bigint,
               statistics_health text)
LANGUAGE sql STABLE AS $$
    SELECT s.schemaname || '.' || s.relname,
           EXISTS (SELECT 1 FROM pg_stats ps WHERE ps.schemaname = s.schemaname AND ps.tablename = s.relname),
           greatest(s.last_analyze, s.last_autoanalyze),
           round(extract(epoch FROM now() - greatest(s.last_analyze, s.last_autoanalyze)) / 86400, 1),
           s.n_live_tup, s.n_mod_since_analyze,
           CASE
               WHEN NOT EXISTS (SELECT 1 FROM pg_stats ps WHERE ps.schemaname = s.schemaname AND ps.tablename = s.relname)
                    THEN 'NO PLANNER STATS - run ANALYZE'
               WHEN s.n_mod_since_analyze > 0.1 * greatest(s.n_live_tup, 1) + 50
                    THEN 'STALE - >10% modified since last analyze'
               ELSE 'OK'
           END
    FROM pg_stat_user_tables s
    WHERE s.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics');
$$;

SELECT * FROM analytics.check_table_statistics()
ORDER BY statistics_health, schema_table
LIMIT 10;

-- =============================================================================
-- 2. COLUMN STATISTICS: what ANALYZE actually stores
-- =============================================================================
\echo '== 2. pg_stats for civics.citizens'

-- n_distinct > 0: absolute count; < 0: fraction of rows (-1 = unique).
-- correlation: physical vs logical order (+-1 makes index range scans cheap).
SELECT attname, null_frac, avg_width, n_distinct,
       round(correlation::numeric, 3) AS correlation,
       cardinality(most_common_vals::text::text[]) AS n_mcv,
       cardinality(histogram_bounds::text::text[]) AS n_histogram_bounds
FROM pg_stats
WHERE schemaname = 'civics' AND tablename = 'citizens'
ORDER BY attname;

-- The most common values of a skewed column, with their frequencies.
SELECT v AS status, round(f::numeric, 4) AS frequency
FROM pg_stats,
     unnest(most_common_vals::text::text[], most_common_freqs) AS m(v, f)
WHERE schemaname = 'civics' AND tablename = 'citizens' AND attname = 'status'
ORDER BY f DESC;

-- n_distinct estimate vs truth on the lab table (ANALYZE samples 300 x target rows).
SELECT s.attname, s.n_distinct AS stored_n_distinct,
       round(CASE WHEN s.n_distinct < 0 THEN -s.n_distinct * c.reltuples ELSE s.n_distinct END) AS estimated,
       CASE s.attname
           WHEN 'sensor_code'     THEN (SELECT count(DISTINCT sensor_code)     FROM analytics.stats_lab)
           WHEN 'sensor_type'     THEN (SELECT count(DISTINCT sensor_type)     FROM analytics.stats_lab)
           WHEN 'unit_of_measure' THEN (SELECT count(DISTINCT unit_of_measure) FROM analytics.stats_lab)
           WHEN 'reading_value'   THEN (SELECT count(DISTINCT reading_value)   FROM analytics.stats_lab)
       END AS actual
FROM pg_stats s
JOIN pg_class c ON c.oid = 'analytics.stats_lab'::regclass
WHERE s.schemaname = 'analytics' AND s.tablename = 'stats_lab'
  AND s.attname IN ('sensor_code', 'sensor_type', 'unit_of_measure', 'reading_value')
ORDER BY s.attname;
-- For high-cardinality columns the sample-based estimate can be far off; fix it with
--   ALTER TABLE ... ALTER COLUMN ... SET (n_distinct = <count or negative fraction>);  then ANALYZE.

-- =============================================================================
-- 3. STATISTICS TARGET: more MCVs and histogram buckets per column
-- =============================================================================
\echo '== 3. Raising the statistics target of one column'

-- PostgreSQL 17: attstattarget is NULL when the column uses default_statistics_target.
SELECT a.attname, a.attstattarget, current_setting('default_statistics_target') AS default_target
FROM pg_attribute a
WHERE a.attrelid = 'analytics.stats_lab'::regclass AND a.attname = 'reading_value';

ALTER TABLE analytics.stats_lab ALTER COLUMN reading_value SET STATISTICS 500;
ANALYZE analytics.stats_lab (reading_value);

SELECT a.attname, a.attstattarget,
       cardinality(s.histogram_bounds::text::text[]) AS n_histogram_bounds   -- was 101, now up to 501
FROM pg_attribute a
JOIN pg_stats s ON s.schemaname = 'analytics' AND s.tablename = 'stats_lab' AND s.attname = a.attname
WHERE a.attrelid = 'analytics.stats_lab'::regclass AND a.attname = 'reading_value';
-- Raise targets only for columns with skew/range queries that misestimate: bigger
-- targets mean slower ANALYZE and planning. Reset with SET STATISTICS DEFAULT (PG17) or -1.
ALTER TABLE analytics.stats_lab ALTER COLUMN reading_value SET STATISTICS DEFAULT;

-- =============================================================================
-- 4. EXTENDED STATISTICS ON CORRELATED COLUMNS (before / after)
-- =============================================================================
\echo '== 4. Extended statistics: dependencies, ndistinct, mcv, expressions'

-- In this dataset sensor_type determines unit_of_measure, and sensor_code
-- determines both. The planner multiplies selectivities as if they were
-- independent, so it underestimates filters and overestimates GROUP BY groups.
DROP STATISTICS IF EXISTS analytics.stats_lab_sensor_ext;
DROP STATISTICS IF EXISTS analytics.stats_lab_dow_ext;
ANALYZE analytics.stats_lab;

CREATE TEMP TABLE IF NOT EXISTS ext_stats_probe (
    ord int, scenario text, sql text, phase text,
    estimated_rows bigint, actual_rows bigint, misestimate_factor numeric);
TRUNCATE ext_stats_probe;

CREATE TEMP TABLE IF NOT EXISTS ext_stats_queries (ord int, scenario text, sql text);
TRUNCATE ext_stats_queries;
INSERT INTO ext_stats_queries VALUES
    (1, 'dependencies: type AND unit (functionally dependent)',
        $q$SELECT * FROM analytics.stats_lab WHERE sensor_type = 'noise' AND unit_of_measure = 'dB'$q$),
    (2, 'dependencies: code AND type AND unit',
        $q$SELECT * FROM analytics.stats_lab WHERE sensor_code = 'NOI-001' AND sensor_type = 'noise' AND unit_of_measure = 'dB'$q$),
    (3, 'ndistinct: GROUP BY code, type, unit',
        $q$SELECT sensor_code, sensor_type, unit_of_measure, count(*) FROM analytics.stats_lab GROUP BY 1, 2, 3$q$),
    (4, 'mcv: impossible combination (type = noise AND unit <> dB)',
        $q$SELECT * FROM analytics.stats_lab WHERE sensor_type = 'noise' AND unit_of_measure <> 'dB'$q$),
    (5, 'expression stats: day of week = Sunday',
        $q$SELECT * FROM analytics.stats_lab WHERE extract(dow FROM reading_time AT TIME ZONE 'UTC') = 0$q$);

INSERT INTO ext_stats_probe
SELECT q.ord, q.scenario, q.sql, '1 before', e.estimated_rows, e.actual_rows, e.misestimate_factor
FROM ext_stats_queries q CROSS JOIN LATERAL analytics.row_estimate(q.sql) e;

-- One statistics object can carry all three kinds for a column group.
CREATE STATISTICS analytics.stats_lab_sensor_ext (dependencies, ndistinct, mcv)
    ON sensor_code, sensor_type, unit_of_measure FROM analytics.stats_lab;
-- Expression statistics (PG14+): the planner otherwise guesses 0.5% for "= const"
-- on an expression. The expression must be immutable, hence AT TIME ZONE 'UTC'.
CREATE STATISTICS analytics.stats_lab_dow_ext
    ON (extract(dow FROM reading_time AT TIME ZONE 'UTC')) FROM analytics.stats_lab;
ANALYZE analytics.stats_lab;          -- extended stats are only built by ANALYZE

INSERT INTO ext_stats_probe
SELECT q.ord, q.scenario, q.sql, '2 after', e.estimated_rows, e.actual_rows, e.misestimate_factor
FROM ext_stats_queries q CROSS JOIN LATERAL analytics.row_estimate(q.sql) e;

SELECT b.scenario,
       b.actual_rows,
       b.estimated_rows AS est_before, b.misestimate_factor AS off_by_before,
       a.estimated_rows AS est_after,  a.misestimate_factor AS off_by_after
FROM ext_stats_probe b
JOIN ext_stats_probe a ON a.ord = b.ord AND a.phase = '2 after'
WHERE b.phase = '1 before'
ORDER BY b.ord;

-- What ANALYZE stored: functional-dependency degrees and group-count estimates.
SELECT statistics_name, attnames, dependencies, n_distinct
FROM pg_stats_ext
WHERE statistics_schemaname = 'analytics' AND statistics_name = 'stats_lab_sensor_ext';

SELECT m.index, m.values, round(m.frequency::numeric, 4) AS frequency
FROM pg_statistic_ext s
JOIN pg_statistic_ext_data d ON d.stxoid = s.oid
CROSS JOIN LATERAL pg_mcv_list_items(d.stxdmcv) m
WHERE s.stxname = 'stats_lab_sensor_ext'
ORDER BY m.frequency DESC, m.index
LIMIT 5;
-- Rules of thumb: add extended stats when EXPLAIN ANALYZE shows estimates off by
-- 10x+ on multi-column filters or GROUP BYs, keep column groups small (<= 4-5),
-- and remember they need ANALYZE (autoanalyze does that) to be populated.

-- =============================================================================
-- 5. AUTOVACUUM: when will it run, per table?
-- =============================================================================
\echo '== 5. Autovacuum thresholds'

SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('autovacuum', 'autovacuum_naptime', 'autovacuum_max_workers',
               'autovacuum_vacuum_threshold', 'autovacuum_vacuum_scale_factor',
               'autovacuum_vacuum_insert_threshold', 'autovacuum_vacuum_insert_scale_factor',
               'autovacuum_analyze_threshold', 'autovacuum_analyze_scale_factor',
               'autovacuum_vacuum_cost_limit', 'autovacuum_vacuum_cost_delay',
               'autovacuum_freeze_max_age', 'maintenance_work_mem', 'autovacuum_work_mem')
ORDER BY name;

-- Trigger formulas (per table; reloptions override the GUCs):
--   vacuum  when n_dead_tup          > vacuum_threshold  + vacuum_scale_factor  * reltuples
--   vacuum  when n_ins_since_vacuum  > insert_threshold  + insert_scale_factor  * reltuples (PG13+)
--   analyze when n_mod_since_analyze > analyze_threshold + analyze_scale_factor * reltuples
CREATE OR REPLACE FUNCTION analytics.autovacuum_thresholds()
RETURNS TABLE (table_name text, reltuples bigint, n_dead_tup bigint, vacuum_at bigint,
               n_ins_since_vacuum bigint, insert_vacuum_at bigint,
               n_mod_since_analyze bigint, analyze_at bigint,
               autovacuum_enabled boolean, status text)
LANGUAGE sql STABLE AS $$
    WITH opts AS (
        SELECT c.oid, n.nspname, c.relname, greatest(c.reltuples, 0)::bigint AS reltuples,
               (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_vacuum_threshold')           AS vt,
               (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_vacuum_scale_factor')        AS vsf,
               (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_vacuum_insert_threshold')    AS it,
               (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_vacuum_insert_scale_factor') AS isf,
               (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_analyze_threshold')          AS at,
               (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_analyze_scale_factor')       AS asf,
               (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_enabled')                    AS enabled
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'm')
          AND n.nspname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics')
    ), t AS (
        SELECT o.*, s.n_dead_tup, s.n_ins_since_vacuum, s.n_mod_since_analyze,
               (COALESCE(o.vt,  current_setting('autovacuum_vacuum_threshold'))::numeric
                + COALESCE(o.vsf, current_setting('autovacuum_vacuum_scale_factor'))::numeric * o.reltuples)::bigint AS vacuum_at,
               CASE WHEN COALESCE(o.it, current_setting('autovacuum_vacuum_insert_threshold'))::numeric < 0 THEN NULL
                    ELSE (COALESCE(o.it, current_setting('autovacuum_vacuum_insert_threshold'))::numeric
                          + COALESCE(o.isf, current_setting('autovacuum_vacuum_insert_scale_factor'))::numeric * o.reltuples)::bigint
               END AS insert_vacuum_at,
               (COALESCE(o.at,  current_setting('autovacuum_analyze_threshold'))::numeric
                + COALESCE(o.asf, current_setting('autovacuum_analyze_scale_factor'))::numeric * o.reltuples)::bigint AS analyze_at
        FROM opts o JOIN pg_stat_user_tables s ON s.relid = o.oid
    )
    SELECT nspname || '.' || relname, reltuples, n_dead_tup, vacuum_at,
           n_ins_since_vacuum, insert_vacuum_at, n_mod_since_analyze, analyze_at,
           COALESCE(enabled::boolean, current_setting('autovacuum')::boolean),
           CASE
               WHEN NOT COALESCE(enabled::boolean, true) THEN 'autovacuum disabled for this table'
               WHEN n_dead_tup > vacuum_at THEN 'vacuum due (dead tuples)'
               WHEN insert_vacuum_at IS NOT NULL AND n_ins_since_vacuum > insert_vacuum_at THEN 'vacuum due (inserts)'
               WHEN n_mod_since_analyze > analyze_at THEN 'analyze due'
               ELSE 'ok'
           END
    FROM t;
$$;
COMMENT ON FUNCTION analytics.autovacuum_thresholds() IS
'Per-table autovacuum/autoanalyze trigger points computed from GUCs and per-table reloptions.';

SELECT table_name, reltuples, n_dead_tup, vacuum_at, n_mod_since_analyze, analyze_at, status
FROM analytics.autovacuum_thresholds()
ORDER BY reltuples DESC, table_name
LIMIT 8;

-- =============================================================================
-- 6. PER-TABLE TUNING
-- =============================================================================
\echo '== 6. Per-table autovacuum settings'

-- With the built-in default scale factor 0.2 (this server's config uses 0.05),
-- a 100M-row table waits for 20M dead rows before autovacuum starts.
-- Large or hot tables therefore get a LOWER scale factor (more frequent, more
-- aggressive vacuums) plus a fixed threshold; tiny tables can keep the defaults.
ALTER TABLE analytics.stats_lab SET (
    autovacuum_enabled = on,
    autovacuum_vacuum_scale_factor  = 0.01,
    autovacuum_vacuum_threshold     = 1000,
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_vacuum_cost_limit    = 2000      -- let this table's vacuum work faster
);
SELECT relname, reloptions FROM pg_class WHERE oid = 'analytics.stats_lab'::regclass;
SELECT table_name, reltuples, vacuum_at, analyze_at, autovacuum_enabled
FROM analytics.autovacuum_thresholds() WHERE table_name = 'analytics.stats_lab';
ALTER TABLE analytics.stats_lab SET (autovacuum_enabled = off);   -- keep the lab quiet again

-- Recommendation generator (prints DDL, executes nothing).
CREATE OR REPLACE FUNCTION analytics.tune_autovacuum_parameters()
RETURNS TABLE (table_name text, reltuples bigint, recommended text, reasoning text)
LANGUAGE sql STABLE AS $$
    SELECT t.table_name, t.reltuples,
           CASE
               WHEN t.reltuples >= 10000000 THEN format(
                   'ALTER TABLE %s SET (autovacuum_vacuum_scale_factor = 0.005, autovacuum_vacuum_threshold = 10000, autovacuum_vacuum_insert_scale_factor = 0.01);', t.table_name)
               WHEN t.reltuples >= 1000000 THEN format(
                   'ALTER TABLE %s SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 5000);', t.table_name)
               WHEN t.n_dead_tup > t.vacuum_at THEN format('VACUUM (ANALYZE) %s;', t.table_name)
               ELSE '-- defaults are fine'
           END,
           CASE
               WHEN t.reltuples >= 1000000
                   THEN 'Large table: default 20% scale factor lets millions of dead rows pile up; vacuum more often'
               WHEN t.n_dead_tup > t.vacuum_at
                   THEN 'Over its threshold now; check autovacuum workers/cost limits if this persists'
               ELSE 'Small table: defaults trigger often enough'
           END
    FROM analytics.autovacuum_thresholds() t;
$$;

SELECT * FROM analytics.tune_autovacuum_parameters() ORDER BY reltuples DESC, table_name LIMIT 5;

-- =============================================================================
-- 7. MANUAL MAINTENANCE AND PROGRESS MONITORING
-- =============================================================================
\echo '== 7. Manual VACUUM/ANALYZE options and progress views'

-- PG16+: BUFFER_USAGE_LIMIT sizes the ring buffer; PG17's new TID store makes
-- vacuum use far less memory per dead tuple and lifts the old 1GB cap.
VACUUM (ANALYZE, BUFFER_USAGE_LIMIT '2MB') analytics.stats_lab;

-- Smart ANALYZE: list tables whose stats are missing or stale. Dry-run by default.
CREATE OR REPLACE FUNCTION analytics.smart_analyze_tables(p_dry_run boolean DEFAULT true)
RETURNS TABLE (command text, reason text, executed boolean)
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT schema_table, statistics_health FROM analytics.check_table_statistics()
        WHERE statistics_health <> 'OK'
        ORDER BY schema_table
    LOOP
        command  := format('ANALYZE %s', r.schema_table);
        reason   := r.statistics_health;
        executed := NOT p_dry_run;
        IF NOT p_dry_run THEN
            EXECUTE command;
        END IF;
        RETURN NEXT;
    END LOOP;
END $$;

SELECT * FROM analytics.smart_analyze_tables() LIMIT 5;     -- dry run

-- Running (auto)vacuums and analyzes, with phase and progress.
SELECT p.pid, p.relid::regclass AS table_name, p.phase,
       p.heap_blks_scanned, p.heap_blks_total,
       round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 1) AS pct_scanned,
       p.index_vacuum_count, p.dead_tuple_bytes                  -- dead_tuple_bytes: PG17
FROM pg_stat_progress_vacuum p;
SELECT pid, relid::regclass AS table_name, phase, sample_blks_scanned, sample_blks_total
FROM pg_stat_progress_analyze;

-- PG16+: I/O done by autovacuum and by explicit VACUUM, from pg_stat_io.
SELECT backend_type, object, context, reads, writes, extends, hits
FROM pg_stat_io
WHERE backend_type IN ('autovacuum worker', 'client backend') AND context = 'vacuum'
ORDER BY backend_type, object;

-- Exercise: UPDATE 5% of analytics.stats_lab, re-enable autovacuum on it, and
-- watch analytics.autovacuum_thresholds() and pg_stat_progress_vacuum until it runs.
