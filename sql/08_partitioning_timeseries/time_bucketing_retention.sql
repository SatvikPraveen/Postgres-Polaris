-- File: sql/08_partitioning_timeseries/time_bucketing_retention.sql
-- Purpose: Weekly partitions, attach/detach/archive, retention policies driven by a
--          reference time, time-bucket aggregation (date_trunc / date_bin), exact
--          roll-ups, gap filling, and EXPLAIN-based pruning checks.
--
-- Standalone: builds its own module-owned objects (dropped and rebuilt every run):
--   mobility.sensor_readings_ts        weekly RANGE partitions, copy of mobility.sensor_readings
--   mobility.sensor_6h_aggregates      6-hour buckets, monthly RANGE partitions
--   mobility.sensor_daily_aggregates   daily roll-up of the 6-hour buckets
--   archive.sensor_readings_ts_*       partitions archived by the retention policy
--
-- "Now" for this dataset is meta.as_of() (2025-12-31 23:59:59 UTC). Retention and
-- "yesterday" logic take a reference timestamp that defaults to meta.as_of(); with
-- CURRENT_DATE they would treat every reading as months old.

\echo '== 0. Reset module-owned objects =='
DROP TABLE IF EXISTS mobility.sensor_readings_ts CASCADE;
DROP TABLE IF EXISTS mobility.sensor_6h_aggregates CASCADE;
DROP TABLE IF EXISTS mobility.sensor_daily_aggregates CASCADE;
DROP TABLE IF EXISTS mobility.sensor_readings_ts_staging;
CREATE SCHEMA IF NOT EXISTS archive;
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT c.oid::regclass AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'archive' AND c.relkind = 'r' AND c.relname LIKE 'sensor_readings_ts_%'
    LOOP
        EXECUTE format('DROP TABLE %s', r.t);
    END LOOP;
END;
$$;

-- =============================================================================
-- 1. WEEKLY PARTITIONED TIME-SERIES TABLE
-- =============================================================================
\echo '== 1. Weekly range partitions =='
CREATE TABLE mobility.sensor_readings_ts (
    reading_id         bigint        NOT NULL,
    sensor_code        varchar(50)   NOT NULL,
    sensor_type        mobility.sensor_type NOT NULL,
    reading_value      numeric(12,4) NOT NULL,
    unit_of_measure    varchar(20)   NOT NULL,
    reading_time       timestamptz   NOT NULL,
    data_quality_score numeric(3,2),
    PRIMARY KEY (reading_id, reading_time)
) PARTITION BY RANGE (reading_time);
CREATE INDEX ON mobility.sensor_readings_ts (sensor_code, reading_time);
CREATE TABLE mobility.sensor_readings_ts_default PARTITION OF mobility.sensor_readings_ts DEFAULT;

-- Catalog helper: every partition with its bounds parsed out of pg_get_expr().
-- Using the real bounds (not the table name) is what makes retention logic safe.
CREATE OR REPLACE VIEW mobility.sensor_ts_partitions AS
SELECT c.oid::regclass                                                         AS partition,
       c.relname                                                               AS partition_name,
       (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \(''([^'']+)''\)'))[1]::timestamptz AS range_start,
       (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz   AS range_end,
       pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'                          AS is_default,
       pg_total_relation_size(c.oid)                                           AS size_bytes
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'mobility.sensor_readings_ts'::regclass;

-- Idempotent "ensure the week containing ts has a partition".
-- Weeks start on Monday 00:00 UTC (date_trunc('week') is ISO weeks).
CREATE OR REPLACE FUNCTION mobility.ensure_sensor_week_partition(p_ts timestamptz)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_start timestamptz := date_trunc('week', p_ts AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    v_end   timestamptz := v_start + interval '1 week';
    v_name  text        := 'sensor_readings_ts_w' || to_char(v_start AT TIME ZONE 'UTC', 'IYYY_IW');
BEGIN
    IF to_regclass(format('mobility.%I', v_name)) IS NOT NULL THEN
        RETURN v_name || ' exists';
    END IF;
    EXECUTE format('CREATE TABLE mobility.%I PARTITION OF mobility.sensor_readings_ts FOR VALUES FROM (%L) TO (%L)',
                   v_name, v_start, v_end);
    RETURN v_name || ' created';
END;
$$;

-- One partition per week of data (2025-09-29 .. 2025-12-29 => 14 weeks)
SELECT count(*) AS weekly_partitions_created
FROM (
    SELECT mobility.ensure_sensor_week_partition(w)
    FROM generate_series(
        (SELECT date_trunc('week', min(reading_time)) FROM mobility.sensor_readings),
        (SELECT max(reading_time) FROM mobility.sensor_readings),
        interval '1 week') AS w
) s;

INSERT INTO mobility.sensor_readings_ts
SELECT reading_id, sensor_code, sensor_type, reading_value, unit_of_measure, reading_time, data_quality_score
FROM mobility.sensor_readings;
ANALYZE mobility.sensor_readings_ts;

SELECT partition, range_start, range_end,
       (SELECT count(*) FROM mobility.sensor_readings_ts t WHERE t.tableoid = p.partition) AS rows
FROM mobility.sensor_ts_partitions p
ORDER BY is_default, range_start
LIMIT 6;

-- =============================================================================
-- 2. ATTACH: LOAD OFFLINE, THEN SWAP IN
-- =============================================================================
\echo '== 2. Attach a pre-loaded partition =='
-- What teaches: load a staging table while it is NOT part of the parent (no locks on
-- the live table, no index maintenance on it), add a CHECK constraint that matches
-- the future bounds (so ATTACH skips the validation scan), then ATTACH.
CREATE OR REPLACE FUNCTION mobility.attach_sensor_week(p_week_start timestamptz, p_source regclass)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_start timestamptz := date_trunc('week', p_week_start AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    v_end   timestamptz := v_start + interval '1 week';
    v_name  text        := 'sensor_readings_ts_w' || to_char(v_start AT TIME ZONE 'UTC', 'IYYY_IW');
    v_rows  bigint;
BEGIN
    IF to_regclass(format('mobility.%I', v_name)) IS NOT NULL THEN
        RETURN format('%s already attached', v_name);
    END IF;
    EXECUTE format('CREATE TABLE mobility.%I (LIKE mobility.sensor_readings_ts INCLUDING DEFAULTS)', v_name);
    EXECUTE format('INSERT INTO mobility.%I SELECT * FROM %s WHERE reading_time >= %L AND reading_time < %L',
                   v_name, p_source, v_start, v_end);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXECUTE format('ALTER TABLE mobility.%I ADD CONSTRAINT %I CHECK (reading_time >= %L AND reading_time < %L)',
                   v_name, v_name || '_bounds', v_start, v_end);
    EXECUTE format('ALTER TABLE mobility.sensor_readings_ts ATTACH PARTITION mobility.%I FOR VALUES FROM (%L) TO (%L)',
                   v_name, v_start, v_end);
    -- The CHECK is now redundant with the partition constraint
    EXECUTE format('ALTER TABLE mobility.%I DROP CONSTRAINT %I', v_name, v_name || '_bounds');
    RETURN format('attached %s with %s rows [%s, %s)', v_name, v_rows, v_start, v_end);
END;
$$;

-- Simulate a late-arriving week of data (first week of 2026) in a staging table.
CREATE TABLE mobility.sensor_readings_ts_staging (LIKE mobility.sensor_readings_ts);
INSERT INTO mobility.sensor_readings_ts_staging
SELECT reading_id + 10000000, sensor_code, sensor_type, reading_value, unit_of_measure,
       reading_time + interval '7 days', data_quality_score
FROM mobility.sensor_readings_ts
WHERE reading_time >= '2025-12-29 00:00+00';         -- the last (partial) week, shifted forward
SELECT mobility.attach_sensor_week('2026-01-05 00:00+00', 'mobility.sensor_readings_ts_staging');
SELECT mobility.attach_sensor_week('2026-01-05 00:00+00', 'mobility.sensor_readings_ts_staging');  -- idempotent
DROP TABLE mobility.sensor_readings_ts_staging;

-- =============================================================================
-- 3. TIME BUCKETING
-- =============================================================================
\echo '== 3. Time bucketing with date_trunc and date_bin =='
-- date_trunc only knows calendar units (hour, day, week, month).
-- date_bin (PG14+) bins into ANY stride aligned to an origin: 15 min, 6 h, 10 days...
SELECT date_bin('6 hours', reading_time, TIMESTAMPTZ '2025-01-01 00:00+00') AS bucket_6h,
       count(*)                          AS readings,
       round(avg(reading_value), 1)      AS avg_vehicles_per_hour,
       max(reading_value)                AS peak
FROM mobility.sensor_readings_ts
WHERE sensor_code = 'TRF-001'
  AND reading_time >= '2025-12-01 00:00+00' AND reading_time < '2025-12-03 00:00+00'
GROUP BY 1
ORDER BY 1;

-- Hour-of-day profile on weekdays. The synthetic generator writes *local clock
-- hours* into UTC timestamps, so bucket in UTC to see the planted 07-09 and 16-19
-- rush-hour peaks (traffic up, speed down to ~70%). With real data you would use
-- AT TIME ZONE 'America/Chicago'.
SELECT extract(hour FROM reading_time AT TIME ZONE 'UTC')::int AS hour_of_day,
       round(avg(reading_value) FILTER (WHERE sensor_type = 'traffic_counter'), 0) AS avg_traffic,
       round(avg(reading_value) FILTER (WHERE sensor_type = 'speed'), 1)           AS avg_speed_mph
FROM mobility.sensor_readings_ts
WHERE extract(isodow FROM reading_time AT TIME ZONE 'UTC') <= 5
GROUP BY 1
ORDER BY 1;

-- =============================================================================
-- 4. MATERIALISED BUCKETS + EXACT ROLL-UPS
-- =============================================================================
\echo '== 4. 6-hour aggregates (partitioned) and an exact daily roll-up =='
-- What teaches: store (count, sum, sum of squares, min, max) per bucket. Those are
-- *additive*, so coarser roll-ups (daily, monthly) are exact. Averaging averages or
-- combining standard deviations directly is wrong unless buckets have equal counts.
CREATE TABLE mobility.sensor_6h_aggregates (
    bucket_start  timestamptz   NOT NULL,
    sensor_code   varchar(50)   NOT NULL,
    sensor_type   mobility.sensor_type NOT NULL,
    reading_count integer       NOT NULL,
    sum_value     numeric(18,4) NOT NULL,
    sum_sq_value  numeric(24,4) NOT NULL,
    min_value     numeric(12,4),
    max_value     numeric(12,4),
    first_reading timestamptz,
    last_reading  timestamptz,
    PRIMARY KEY (bucket_start, sensor_code)
) PARTITION BY RANGE (bucket_start);
CREATE TABLE mobility.sensor_6h_aggregates_2025_10 PARTITION OF mobility.sensor_6h_aggregates
    FOR VALUES FROM ('2025-10-01 00:00+00') TO ('2025-11-01 00:00+00');
CREATE TABLE mobility.sensor_6h_aggregates_2025_11 PARTITION OF mobility.sensor_6h_aggregates
    FOR VALUES FROM ('2025-11-01 00:00+00') TO ('2025-12-01 00:00+00');
CREATE TABLE mobility.sensor_6h_aggregates_2025_12 PARTITION OF mobility.sensor_6h_aggregates
    FOR VALUES FROM ('2025-12-01 00:00+00') TO ('2026-01-01 00:00+00');
CREATE TABLE mobility.sensor_6h_aggregates_default PARTITION OF mobility.sensor_6h_aggregates DEFAULT;

-- Upsert a time window of buckets (re-runnable: ON CONFLICT replaces the bucket).
CREATE OR REPLACE FUNCTION mobility.refresh_6h_aggregates(p_from timestamptz, p_to timestamptz)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE v_rows bigint;
BEGIN
    INSERT INTO mobility.sensor_6h_aggregates AS a
    SELECT date_bin('6 hours', reading_time, TIMESTAMPTZ '2025-01-01 00:00+00'),
           sensor_code, sensor_type,
           count(*), sum(reading_value), sum(reading_value * reading_value),
           min(reading_value), max(reading_value), min(reading_time), max(reading_time)
    FROM mobility.sensor_readings_ts
    WHERE reading_time >= p_from AND reading_time < p_to
    GROUP BY 1, 2, 3
    ON CONFLICT (bucket_start, sensor_code) DO UPDATE SET
        reading_count = EXCLUDED.reading_count,
        sum_value     = EXCLUDED.sum_value,
        sum_sq_value  = EXCLUDED.sum_sq_value,
        min_value     = EXCLUDED.min_value,
        max_value     = EXCLUDED.max_value,
        first_reading = EXCLUDED.first_reading,
        last_reading  = EXCLUDED.last_reading;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

SELECT mobility.refresh_6h_aggregates('2025-10-01 00:00+00', '2026-01-01 00:00+00') AS buckets_written;
SELECT mobility.refresh_6h_aggregates('2025-12-31 00:00+00', '2026-01-01 00:00+00') AS buckets_rewritten;

CREATE TABLE mobility.sensor_daily_aggregates (
    bucket_date   date          NOT NULL,
    sensor_code   varchar(50)   NOT NULL,
    sensor_type   mobility.sensor_type NOT NULL,
    reading_count integer       NOT NULL,
    min_value     numeric(12,4),
    max_value     numeric(12,4),
    avg_value     numeric(12,4),
    stddev_value  numeric(12,4),
    total_value   numeric(18,4),
    PRIMARY KEY (bucket_date, sensor_code)
);

-- Daily roll-up from the 6h buckets using MERGE ... RETURNING (PG17) so the caller
-- sees which rows were inserted vs updated. Days are UTC days.
CREATE OR REPLACE FUNCTION mobility.rollup_daily_aggregates(p_day date)
RETURNS TABLE(action text, rows bigint)
LANGUAGE sql
AS $$
    WITH merged AS (
        MERGE INTO mobility.sensor_daily_aggregates d
        USING (
            SELECT p_day AS bucket_date, sensor_code, sensor_type,
                   sum(reading_count)::int                      AS n,
                   min(min_value)                               AS mn,
                   max(max_value)                               AS mx,
                   sum(sum_value)                               AS s,
                   sum(sum_sq_value)                            AS ss
            FROM mobility.sensor_6h_aggregates
            WHERE bucket_start >= p_day::timestamp AT TIME ZONE 'UTC'
              AND bucket_start <  (p_day + 1)::timestamp AT TIME ZONE 'UTC'
            GROUP BY sensor_code, sensor_type
        ) src
        ON d.bucket_date = src.bucket_date AND d.sensor_code = src.sensor_code
        WHEN MATCHED THEN UPDATE SET
            reading_count = src.n, min_value = src.mn, max_value = src.mx,
            avg_value = src.s / src.n,
            stddev_value = CASE WHEN src.n > 1
                                THEN sqrt(greatest((src.ss - src.s * src.s / src.n) / (src.n - 1), 0)) END,
            total_value = src.s
        WHEN NOT MATCHED THEN INSERT
            VALUES (src.bucket_date, src.sensor_code, src.sensor_type, src.n, src.mn, src.mx,
                    src.s / src.n,
                    CASE WHEN src.n > 1 THEN sqrt(greatest((src.ss - src.s * src.s / src.n) / (src.n - 1), 0)) END,
                    src.s)
        RETURNING merge_action() AS act
    )
    SELECT act, count(*) FROM merged GROUP BY act ORDER BY act;
$$;

SELECT d::date AS day, r.*
FROM generate_series(DATE '2025-12-29', DATE '2025-12-31', interval '1 day') AS d
CROSS JOIN LATERAL mobility.rollup_daily_aggregates(d::date) r
ORDER BY day, action;
SELECT * FROM mobility.rollup_daily_aggregates(DATE '2025-12-31');   -- now all UPDATEs

-- Proof that the roll-up is exact: compare with aggregating the raw readings.
SELECT d.sensor_code,
       d.avg_value                                     AS rolled_up_avg,
       round(avg(r.reading_value), 4)                  AS raw_avg,
       d.stddev_value                                  AS rolled_up_stddev,
       round(stddev_samp(r.reading_value), 4)          AS raw_stddev
FROM mobility.sensor_daily_aggregates d
JOIN mobility.sensor_readings_ts r
  ON r.sensor_code = d.sensor_code
 AND r.reading_time >= d.bucket_date::timestamp AT TIME ZONE 'UTC'
 AND r.reading_time <  (d.bucket_date + 1)::timestamp AT TIME ZONE 'UTC'
WHERE d.bucket_date = DATE '2025-12-31'
GROUP BY d.sensor_code, d.avg_value, d.stddev_value
ORDER BY d.sensor_code
LIMIT 5;

-- =============================================================================
-- 5. GAP DETECTION AND GAP FILLING
-- =============================================================================
\echo '== 5. Gap filling with generate_series =='
-- Sensors report hourly. A generated hourly calendar LEFT JOINed to the readings
-- exposes missing hours; a window "last observation carried forward" fills them.
WITH cal AS (
    SELECT generate_series(TIMESTAMPTZ '2025-12-01 00:00+00', TIMESTAMPTZ '2025-12-31 23:00+00', interval '1 hour') AS hour
),
per_sensor AS (
    SELECT s.sensor_code, count(*) FILTER (WHERE r.reading_id IS NULL) AS missing_hours
    FROM (SELECT DISTINCT sensor_code FROM mobility.sensor_readings_ts) s
    CROSS JOIN cal
    LEFT JOIN mobility.sensor_readings_ts r
           ON r.sensor_code = s.sensor_code AND date_trunc('hour', r.reading_time) = cal.hour
    GROUP BY s.sensor_code
)
SELECT sensor_code, missing_hours
FROM per_sensor
ORDER BY missing_hours DESC, sensor_code
LIMIT 5;

-- LOCF fill for one sensor/day (SPD-005 misses two hours on 2025-12-28): count() over the non-null values builds a group id,
-- first_value within that group carries the last observation forward.
WITH cal AS (
    SELECT generate_series(TIMESTAMPTZ '2025-12-28 00:00+00', TIMESTAMPTZ '2025-12-28 23:00+00', interval '1 hour') AS hour
),
joined AS (
    SELECT cal.hour, r.reading_value
    FROM cal
    LEFT JOIN mobility.sensor_readings_ts r
           ON r.sensor_code = 'SPD-005' AND date_trunc('hour', r.reading_time) = cal.hour
),
grp AS (
    SELECT hour, reading_value, count(reading_value) OVER (ORDER BY hour) AS g FROM joined
)
SELECT hour, reading_value AS raw_value,
       first_value(reading_value) OVER (PARTITION BY g ORDER BY hour) AS locf_value,
       reading_value IS NULL AS was_missing
FROM grp
ORDER BY hour
LIMIT 24;

-- =============================================================================
-- 6. BUCKET-LEVEL ANOMALY SCREEN, VERIFIED AGAINST GROUND TRUTH
-- =============================================================================
\echo '== 6. Spikes per 6h bucket vs labelled ground truth =='
-- A 6h bucket whose max exceeds mean + 4 sd of that sensor's daily distribution is
-- flagged; meta.ground_truth tells us how many flagged buckets contain a planted spike.
-- Expect modest precision: rush-hour peaks and planted level shifts also trip a
-- global threshold. A per-hour-of-day baseline would do better (see module 16).
WITH sensor_stats AS (
    SELECT sensor_code,
           sum(sum_value) / sum(reading_count) AS mu,
           sqrt(sum(sum_sq_value) / sum(reading_count) - (sum(sum_value) / sum(reading_count)) ^ 2) AS sigma
    FROM mobility.sensor_6h_aggregates
    GROUP BY sensor_code
),
flagged AS (
    SELECT a.bucket_start, a.sensor_code
    FROM mobility.sensor_6h_aggregates a
    JOIN sensor_stats s USING (sensor_code)
    WHERE a.max_value > s.mu + 4 * s.sigma
),
labelled AS (
    SELECT DISTINCT date_bin('6 hours', r.reading_time, TIMESTAMPTZ '2025-01-01 00:00+00') AS bucket_start, r.sensor_code
    FROM meta.ground_truth gt
    JOIN mobility.sensor_readings_ts r ON r.reading_id = gt.entity_id
    WHERE gt.entity = 'mobility.sensor_readings' AND gt.label = 'spike'
)
SELECT (SELECT count(*) FROM flagged)                                   AS flagged_buckets,
       (SELECT count(*) FROM flagged f JOIN labelled l USING (bucket_start, sensor_code)) AS true_positives,
       (SELECT count(*) FROM labelled)                                  AS buckets_with_planted_spike;

-- =============================================================================
-- 7. RETENTION: DETACH AND ARCHIVE (OR DROP) OLD PARTITIONS
-- =============================================================================
\echo '== 7. Retention policy relative to meta.as_of() =='
-- Detach one partition and move it to the archive schema. In a live system prefer
--   ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY
-- run from psql/cron (it cannot run inside a function or transaction block, and not
-- while a DEFAULT partition exists). Inside a function we use the plain form.
CREATE OR REPLACE FUNCTION mobility.detach_and_archive_partition(p_partition regclass,
                                                                 p_archive_schema text DEFAULT 'archive')
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows bigint;
    v_name text := (SELECT relname FROM pg_class WHERE oid = p_partition);
BEGIN
    EXECUTE format('SELECT count(*) FROM %s', p_partition) INTO v_rows;
    EXECUTE format('ALTER TABLE mobility.sensor_readings_ts DETACH PARTITION %s', p_partition);
    EXECUTE format('ALTER TABLE %s SET SCHEMA %I', p_partition, p_archive_schema);
    RETURN format('archived %s (%s rows) to %I.%I', v_name, v_rows, p_archive_schema, v_name);
END;
$$;

-- A partition expires when its whole range ends before (reference - retention).
CREATE OR REPLACE FUNCTION mobility.apply_sensor_retention_policy(
    p_retention interval    DEFAULT interval '8 weeks',
    p_dry_run   boolean     DEFAULT true,
    p_reference timestamptz DEFAULT meta.as_of(),
    p_mode      text        DEFAULT 'archive'          -- 'archive' or 'drop'
)
RETURNS TABLE(action text, partition_name text, range_start timestamptz, range_end timestamptz,
              row_estimate bigint, size_pretty text)
LANGUAGE plpgsql
AS $$
DECLARE
    p      record;
    cutoff timestamptz := p_reference - p_retention;
BEGIN
    IF p_mode NOT IN ('archive', 'drop') THEN
        RAISE EXCEPTION 'p_mode must be archive or drop';
    END IF;
    FOR p IN
        SELECT sp.partition, sp.partition_name, sp.range_start, sp.range_end, sp.size_bytes,
               greatest(c.reltuples, 0)::bigint AS est
        FROM mobility.sensor_ts_partitions sp
        JOIN pg_class c ON c.oid = sp.partition
        WHERE NOT sp.is_default AND sp.range_end <= cutoff
        ORDER BY sp.range_start
    LOOP
        IF p_dry_run THEN
            action := 'would ' || p_mode;
        ELSIF p_mode = 'drop' THEN
            EXECUTE format('DROP TABLE %s', p.partition);   -- dropping a partition detaches it implicitly
            action := 'dropped';
        ELSE
            action := mobility.detach_and_archive_partition(p.partition);
        END IF;
        partition_name := p.partition_name;
        range_start    := p.range_start;
        range_end      := p.range_end;
        row_estimate   := p.est;
        size_pretty    := pg_size_pretty(p.size_bytes);
        RETURN NEXT;
    END LOOP;
END;
$$;

-- Dry run first, then archive for real (module-owned tables only).
SELECT * FROM mobility.apply_sensor_retention_policy(interval '8 weeks', true);
SELECT action, partition_name FROM mobility.apply_sensor_retention_policy(interval '8 weeks', false);

SELECT n.nspname AS schema, c.relname AS archived_table
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'archive' AND c.relkind = 'r' AND c.relname LIKE 'sensor_readings_ts_%'
ORDER BY 2;
SELECT min(reading_time) AS oldest_live_reading FROM mobility.sensor_readings_ts;

-- =============================================================================
-- 8. ONE MAINTENANCE ENTRY POINT
-- =============================================================================
\echo '== 8. Maintenance routine (premake + retention + aggregates) =='
-- Everything is relative to p_reference so the same routine works on this frozen
-- dataset (meta.as_of()) and, in production, on now(). Schedule it with pg_cron
-- (only installed in database polaris) or an external scheduler.
CREATE OR REPLACE FUNCTION mobility.maintain_sensor_partitions(
    p_reference timestamptz DEFAULT meta.as_of(),
    p_premake   integer     DEFAULT 2,
    p_retention interval    DEFAULT interval '8 weeks'
)
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    i integer;
    yesterday date := (p_reference AT TIME ZONE 'UTC')::date - 1;
BEGIN
    FOR i IN 0..p_premake LOOP
        RETURN NEXT 'premake: ' || mobility.ensure_sensor_week_partition(p_reference + i * interval '1 week');
    END LOOP;
    RETURN NEXT 'retention: ' || count(*) || ' partition(s) archived'
        FROM mobility.apply_sensor_retention_policy(p_retention, false, p_reference);
    RETURN NEXT 'aggregates: ' || mobility.refresh_6h_aggregates(yesterday::timestamp AT TIME ZONE 'UTC',
                                                                  (yesterday + 1)::timestamp AT TIME ZONE 'UTC')
                || ' 6h buckets refreshed for ' || yesterday;
    RETURN NEXT 'rollup: ' || coalesce(string_agg(action || '=' || rows, ', '), 'nothing')
        FROM mobility.rollup_daily_aggregates(yesterday);
END;
$$;

SELECT * FROM mobility.maintain_sensor_partitions();

-- =============================================================================
-- 9. MONITORING: HEALTH CHECK AND MEASURED PRUNING
-- =============================================================================
\echo '== 9. Partition health and EXPLAIN-measured pruning =='
CREATE OR REPLACE FUNCTION mobility.partition_health_check(p_reference timestamptz DEFAULT meta.as_of())
RETURNS TABLE(metric_name text, metric_value text, status text, recommendation text)
LANGUAGE sql
STABLE
AS $$
    WITH p AS (SELECT * FROM mobility.sensor_ts_partitions),
         d AS (SELECT count(*) AS n FROM mobility.sensor_readings_ts_default)
    SELECT 'Total partitions', count(*)::text,
           CASE WHEN count(*) > 500 THEN 'WARNING' ELSE 'OK' END,
           CASE WHEN count(*) > 500 THEN 'Many partitions slow planning; consider coarser intervals'
                ELSE 'Partition count is healthy' END
    FROM p
    UNION ALL
    SELECT 'Rows in DEFAULT partition', d.n::text,
           CASE WHEN d.n > 0 THEN 'WARNING' ELSE 'OK' END,
           CASE WHEN d.n > 0 THEN 'Create the missing partitions and move these rows out'
                ELSE 'No stray rows' END
    FROM d
    UNION ALL
    SELECT 'Weeks pre-created beyond reference',
           count(*) FILTER (WHERE range_start > p_reference)::text,
           CASE WHEN count(*) FILTER (WHERE range_start > p_reference) < 1 THEN 'WARNING' ELSE 'OK' END,
           'Keep at least one future partition so inserts never hit DEFAULT'
    FROM p WHERE NOT is_default
    UNION ALL
    SELECT 'Avg partition size', pg_size_pretty(avg(size_bytes)::bigint), 'INFO', 'Track growth over time'
    FROM p WHERE NOT is_default;
$$;

SELECT * FROM mobility.partition_health_check();

-- Count the partitions a query really touches by walking EXPLAIN (FORMAT JSON).
CREATE OR REPLACE FUNCTION mobility.partitions_scanned(p_query text)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || p_query INTO v_plan;
    RETURN (
        WITH RECURSIVE nodes(n) AS (
            SELECT v_plan -> 0 -> 'Plan'
            UNION ALL
            SELECT child FROM nodes, jsonb_array_elements(nodes.n -> 'Plans') AS child
        )
        SELECT count(DISTINCT n ->> 'Relation Name') FROM nodes
        WHERE n ->> 'Relation Name' LIKE 'sensor_readings_ts%'
    );
END;
$$;

SELECT q.label,
       mobility.partitions_scanned(q.sql)                                    AS partitions_scanned,
       (SELECT count(*) FROM mobility.sensor_ts_partitions)                  AS partitions_total
FROM (VALUES
    ('one day',            $q$SELECT count(*) FROM mobility.sensor_readings_ts WHERE reading_time >= '2025-12-15' AND reading_time < '2025-12-16'$q$),
    ('two weeks',          $q$SELECT count(*) FROM mobility.sensor_readings_ts WHERE reading_time >= '2025-12-08' AND reading_time < '2025-12-22'$q$),
    ('open-ended >= date', $q$SELECT count(*) FROM mobility.sensor_readings_ts WHERE reading_time >= '2025-12-20'$q$),
    ('no time filter',     $q$SELECT count(*) FROM mobility.sensor_readings_ts WHERE sensor_code = 'TRF-001'$q$)
) AS q(label, sql)
ORDER BY partitions_scanned, q.label;
