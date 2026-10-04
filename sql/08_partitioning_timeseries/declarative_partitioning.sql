-- File: sql/08_partitioning_timeseries/declarative_partitioning.sql
-- Purpose: Range / list / hash partitioning, partition pruning, default partitions,
--          ATTACH / DETACH (CONCURRENTLY), and pg_partman 5.x automation.
--
-- The base table mobility.sensor_readings is NOT modified. Every partitioned table
-- here is a module-owned copy, dropped and rebuilt at the top of each section so the
-- script is idempotent:
--   mobility.sensor_readings_part        RANGE (reading_time), monthly, + DEFAULT
--   audit.table_changes_partitioned      RANGE (changed_at) -> LIST (operation_type)
--   commerce.orders_by_type              LIST (business_type)
--   civics.citizens_hashed               HASH (citizen_id), 4 ways
--   mobility.sensor_readings_partman     RANGE (reading_time), managed by pg_partman 5.x
--
-- Sensor data spans 2025-10-03 .. 2025-12-31 (meta.as_of() = 2025-12-31 23:59:59 UTC).

\echo '== 0. Clean up module-owned objects from a previous run =='
DROP TABLE IF EXISTS mobility.sensor_readings_part CASCADE;
DROP TABLE IF EXISTS mobility.sensor_readings_part_2025_10_detached;   -- left over by the DETACH demo
DROP TABLE IF EXISTS mobility.sensor_readings_part_2026_02_staging;
DROP TABLE IF EXISTS audit.table_changes_partitioned CASCADE;
DROP TABLE IF EXISTS commerce.orders_by_type CASCADE;
DROP TABLE IF EXISTS civics.citizens_hashed CASCADE;

-- =============================================================================
-- 1. TIME-BASED RANGE PARTITIONING
-- =============================================================================
\echo '== 1. Range-partitioned copy of mobility.sensor_readings =='
-- What teaches:
--   * PARTITION BY RANGE (reading_time); bounds are [FROM, TO) - lower inclusive,
--     upper exclusive - so consecutive months never overlap.
--   * A PRIMARY KEY / UNIQUE constraint on a partitioned table must include the
--     partition key (uniqueness is enforced per partition).
--   * Indexes created on the parent are created on (and automatically attached to)
--     every partition, current and future.
CREATE TABLE mobility.sensor_readings_part (
    reading_id           bigint        NOT NULL,
    sensor_code          varchar(50)   NOT NULL,
    sensor_type          mobility.sensor_type NOT NULL,
    latitude             numeric(10,8) NOT NULL,
    longitude            numeric(11,8) NOT NULL,
    location_description varchar(200),
    reading_value        numeric(12,4) NOT NULL,
    unit_of_measure      varchar(20)   NOT NULL,
    reading_time         timestamptz   NOT NULL,
    data_quality_score   numeric(3,2),
    calibration_date     date,
    weather_conditions   varchar(100),
    special_events       varchar(200),
    raw_data             jsonb,
    PRIMARY KEY (reading_id, reading_time)
) PARTITION BY RANGE (reading_time);

CREATE TABLE mobility.sensor_readings_part_2025_10 PARTITION OF mobility.sensor_readings_part
    FOR VALUES FROM ('2025-10-01 00:00+00') TO ('2025-11-01 00:00+00');
CREATE TABLE mobility.sensor_readings_part_2025_11 PARTITION OF mobility.sensor_readings_part
    FOR VALUES FROM ('2025-11-01 00:00+00') TO ('2025-12-01 00:00+00');
CREATE TABLE mobility.sensor_readings_part_2025_12 PARTITION OF mobility.sensor_readings_part
    FOR VALUES FROM ('2025-12-01 00:00+00') TO ('2026-01-01 00:00+00');
-- A pre-created "future" partition (empty for now)
CREATE TABLE mobility.sensor_readings_part_2026_01 PARTITION OF mobility.sensor_readings_part
    FOR VALUES FROM ('2026-01-01 00:00+00') TO ('2026-02-01 00:00+00');
-- DEFAULT partition catches rows that match no other partition
CREATE TABLE mobility.sensor_readings_part_default PARTITION OF mobility.sensor_readings_part DEFAULT;

CREATE INDEX ON mobility.sensor_readings_part (sensor_code, reading_time DESC);
CREATE INDEX ON mobility.sensor_readings_part (sensor_type, reading_time DESC);

-- Rows are routed to the right partition automatically on INSERT.
INSERT INTO mobility.sensor_readings_part
SELECT reading_id, sensor_code, sensor_type, latitude, longitude, location_description,
       reading_value, unit_of_measure, reading_time, data_quality_score, calibration_date,
       weather_conditions, special_events, raw_data
FROM mobility.sensor_readings;
ANALYZE mobility.sensor_readings_part;

-- tableoid::regclass tells you which partition physically holds each row
SELECT tableoid::regclass AS partition, count(*) AS rows,
       min(reading_time) AS first_reading, max(reading_time) AS last_reading
FROM mobility.sensor_readings_part
GROUP BY tableoid
ORDER BY first_reading NULLS LAST;

-- Catalog view of the partition tree (PG12+): pg_partition_tree + bounds
SELECT pt.relid::regclass                                      AS partition,
       pt.isleaf,
       pt.level,
       pg_get_expr(c.relpartbound, c.oid)                      AS bounds,
       pg_size_pretty(pg_total_relation_size(pt.relid))        AS total_size
FROM pg_partition_tree('mobility.sensor_readings_part') pt
JOIN pg_class c ON c.oid = pt.relid
ORDER BY pt.level, pt.relid::regclass::text;

-- =============================================================================
-- 2. PARTITION PRUNING
-- =============================================================================
\echo '== 2. Partition pruning (plan-time and run-time) =='
-- What teaches: the planner skips partitions whose bounds cannot match the WHERE clause.
-- (a) Plan-time pruning with constants: only the December partition appears in the plan.
EXPLAIN (COSTS OFF)
SELECT count(*), avg(reading_value)
FROM mobility.sensor_readings_part
WHERE reading_time >= '2025-12-01 00:00+00' AND reading_time < '2025-12-08 00:00+00';

-- (b) A range spanning two months touches exactly two partitions.
EXPLAIN (COSTS OFF)
SELECT count(*)
FROM mobility.sensor_readings_part
WHERE reading_time >= '2025-11-15 00:00+00' AND reading_time < '2025-12-15 00:00+00';

-- (c) Run-time (executor) pruning: meta.as_of() is STABLE, so its value is not known
--     at plan time. The plan lists all partitions but EXPLAIN ANALYZE reports
--     "Subplans Removed: N" - they were pruned at executor start-up.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM mobility.sensor_readings_part
WHERE reading_time >= meta.as_of() - interval '7 days';

-- (d) A filter on a non-key column cannot prune: every partition is scanned
--     (each via its own copy of the parent's index).
EXPLAIN (COSTS OFF)
SELECT count(*) FROM mobility.sensor_readings_part WHERE sensor_code = 'SEN-001';

-- (e) Pruning can be switched off to see the difference (diagnostics only).
BEGIN;
SET LOCAL enable_partition_pruning = off;
EXPLAIN (COSTS OFF)
SELECT count(*) FROM mobility.sensor_readings_part
WHERE reading_time >= '2025-12-01 00:00+00' AND reading_time < '2025-12-08 00:00+00';
ROLLBACK;

-- (f) Partition-wise aggregation: GROUP BY that includes the partition key can be
--     computed per partition and then appended (off by default).
BEGIN;
SET LOCAL enable_partitionwise_aggregate = on;
EXPLAIN (COSTS OFF)
SELECT reading_time, count(*)
FROM mobility.sensor_readings_part
GROUP BY reading_time;
ROLLBACK;

-- =============================================================================
-- 3. DEFAULT PARTITION PITFALLS
-- =============================================================================
\echo '== 3. Default partition: catches strays, but blocks overlapping new partitions =='
-- A reading far in the future lands in the DEFAULT partition.
INSERT INTO mobility.sensor_readings_part
       (reading_id, sensor_code, sensor_type, latitude, longitude, reading_value, unit_of_measure, reading_time)
VALUES (-1, 'SEN-FUTURE', 'noise', 32.98, -96.80, 55.0, 'dB', '2026-02-14 12:00+00');

SELECT tableoid::regclass AS landed_in, reading_id, reading_time
FROM mobility.sensor_readings_part WHERE reading_id = -1;

-- Creating the February partition now FAILS: the default partition already holds a
-- row in that range. (Postgres also has to scan the default partition to check this,
-- which is why a large default partition makes adding partitions slow.)
DO $$
BEGIN
    CREATE TABLE mobility.sensor_readings_part_2026_02 PARTITION OF mobility.sensor_readings_part
        FOR VALUES FROM ('2026-02-01 00:00+00') TO ('2026-03-01 00:00+00');
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'As expected: % (SQLSTATE %)', SQLERRM, SQLSTATE;
END;
$$;

-- Fix: in one transaction, move the strays out of DEFAULT into a staging table,
-- create the partition, then put the rows back (they now route to the new partition).
BEGIN;
CREATE TABLE mobility.sensor_readings_part_2026_02_staging AS
    SELECT * FROM mobility.sensor_readings_part_default
    WHERE reading_time >= '2026-02-01 00:00+00' AND reading_time < '2026-03-01 00:00+00';
DELETE FROM mobility.sensor_readings_part_default
    WHERE reading_time >= '2026-02-01 00:00+00' AND reading_time < '2026-03-01 00:00+00';
CREATE TABLE mobility.sensor_readings_part_2026_02 PARTITION OF mobility.sensor_readings_part
    FOR VALUES FROM ('2026-02-01 00:00+00') TO ('2026-03-01 00:00+00');
INSERT INTO mobility.sensor_readings_part SELECT * FROM mobility.sensor_readings_part_2026_02_staging;
DROP TABLE mobility.sensor_readings_part_2026_02_staging;
COMMIT;

SELECT tableoid::regclass AS now_lives_in, reading_id FROM mobility.sensor_readings_part WHERE reading_id = -1;

-- =============================================================================
-- 4. ATTACH WITHOUT A LONG LOCK, DETACH CONCURRENTLY
-- =============================================================================
\echo '== 4. ATTACH PARTITION with a pre-validated CHECK; DETACH ... CONCURRENTLY =='
-- What teaches: ATTACH PARTITION must prove every row fits the bounds. If the table
-- already has a matching *validated* CHECK constraint, that scan is skipped and the
-- parent only needs a SHARE UPDATE EXCLUSIVE lock (PG12+). Load + validate first,
-- then attach, then drop the now-redundant CHECK.
CREATE TABLE mobility.sensor_readings_part_2026_03
    (LIKE mobility.sensor_readings_part INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
ALTER TABLE mobility.sensor_readings_part_2026_03
    ADD CONSTRAINT chk_2026_03_bounds
    CHECK (reading_time >= '2026-03-01 00:00+00' AND reading_time < '2026-04-01 00:00+00');
-- (bulk-load the staging table here; it is not yet visible through the parent)
ALTER TABLE mobility.sensor_readings_part
    ATTACH PARTITION mobility.sensor_readings_part_2026_03
    FOR VALUES FROM ('2026-03-01 00:00+00') TO ('2026-04-01 00:00+00');
ALTER TABLE mobility.sensor_readings_part_2026_03 DROP CONSTRAINT chk_2026_03_bounds;

-- DETACH PARTITION ... CONCURRENTLY (PG14+) only takes SHARE UPDATE EXCLUSIVE on the
-- parent, so reads and writes continue. Restrictions:
--   * cannot run inside a transaction block (psql autocommit runs it standalone here)
--   * not allowed while the parent has a DEFAULT partition
--   * if interrupted, finish with: ALTER TABLE ... DETACH PARTITION ... FINALIZE;
-- So: detach the DEFAULT partition normally, detach October concurrently, re-attach DEFAULT.
ALTER TABLE mobility.sensor_readings_part DETACH PARTITION mobility.sensor_readings_part_default;
ALTER TABLE mobility.sensor_readings_part DETACH PARTITION mobility.sensor_readings_part_2025_10 CONCURRENTLY;
ALTER TABLE mobility.sensor_readings_part ATTACH PARTITION mobility.sensor_readings_part_default DEFAULT;

-- The detached partition is now an ordinary table we can archive, dump or drop.
ALTER TABLE mobility.sensor_readings_part_2025_10 RENAME TO sensor_readings_part_2025_10_detached;
SELECT 'detached' AS state, count(*) AS rows FROM mobility.sensor_readings_part_2025_10_detached
UNION ALL
SELECT 'still in parent', count(*) FROM mobility.sensor_readings_part;

-- Re-attach it (a validated CHECK makes this fast too) so later sections see all data.
ALTER TABLE mobility.sensor_readings_part_2025_10_detached
    ADD CONSTRAINT chk_2025_10_bounds
    CHECK (reading_time >= '2025-10-01 00:00+00' AND reading_time < '2025-11-01 00:00+00');
ALTER TABLE mobility.sensor_readings_part
    ATTACH PARTITION mobility.sensor_readings_part_2025_10_detached
    FOR VALUES FROM ('2025-10-01 00:00+00') TO ('2025-11-01 00:00+00');
ALTER TABLE mobility.sensor_readings_part_2025_10_detached DROP CONSTRAINT chk_2025_10_bounds;
ALTER TABLE mobility.sensor_readings_part_2025_10_detached RENAME TO sensor_readings_part_2025_10;

-- =============================================================================
-- 5. MULTI-LEVEL PARTITIONING (RANGE -> LIST)
-- =============================================================================
\echo '== 5. Multi-level partitioning: audit log by month, then by operation =='
CREATE TABLE audit.table_changes_partitioned (
    audit_id          bigint GENERATED ALWAYS AS IDENTITY,
    schema_name       text NOT NULL,
    table_name        text NOT NULL,
    operation_type    text NOT NULL,
    row_data          jsonb,
    changed_fields    jsonb,
    old_values        jsonb,
    new_values        jsonb,
    changed_by        text,
    changed_at        timestamptz DEFAULT now() NOT NULL,
    session_user_name text DEFAULT session_user,
    client_addr       inet DEFAULT inet_client_addr(),
    application_name  text DEFAULT current_setting('application_name', true),
    -- must include both partition keys (changed_at and operation_type)
    PRIMARY KEY (audit_id, changed_at, operation_type)
) PARTITION BY RANGE (changed_at);

-- Helper that creates one month and its LIST sub-partitions (idempotent).
CREATE OR REPLACE FUNCTION audit.create_audit_partition(partition_year integer, partition_month integer)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_name  text := format('table_changes_%s_%s', partition_year, lpad(partition_month::text, 2, '0'));
    v_start timestamptz := make_timestamptz(partition_year, partition_month, 1, 0, 0, 0, 'UTC');
    v_end   timestamptz := v_start + interval '1 month';
    v_op    text;
BEGIN
    IF to_regclass(format('audit.%I', v_name)) IS NOT NULL THEN
        RETURN format('audit.%s already exists', v_name);
    END IF;
    EXECUTE format('CREATE TABLE audit.%I PARTITION OF audit.table_changes_partitioned
                    FOR VALUES FROM (%L) TO (%L) PARTITION BY LIST (operation_type)',
                   v_name, v_start, v_end);
    FOREACH v_op IN ARRAY ARRAY['insert', 'update', 'delete'] LOOP
        EXECUTE format('CREATE TABLE audit.%I PARTITION OF audit.%I FOR VALUES IN (%L)',
                       v_name || '_' || v_op, v_name, upper(v_op));
    END LOOP;
    EXECUTE format('CREATE TABLE audit.%I PARTITION OF audit.%I DEFAULT', v_name || '_other', v_name);
    RETURN format('created audit.%s with INSERT/UPDATE/DELETE/other sub-partitions', v_name);
END;
$$;

SELECT audit.create_audit_partition(2025, m) FROM generate_series(11, 12) AS m;
SELECT audit.create_audit_partition(2025, 12);   -- second call is a no-op

INSERT INTO audit.table_changes_partitioned (schema_name, table_name, operation_type, changed_by, changed_at)
VALUES ('civics', 'citizens', 'INSERT',   'demo', '2025-11-03 10:00+00'),
       ('civics', 'citizens', 'UPDATE',   'demo', '2025-12-03 11:00+00'),
       ('civics', 'citizens', 'TRUNCATE', 'demo', '2025-12-04 12:00+00');

SELECT tableoid::regclass AS leaf_partition, operation_type, changed_at
FROM audit.table_changes_partitioned
ORDER BY changed_at;

-- Pruning works on both levels:
EXPLAIN (COSTS OFF)
SELECT * FROM audit.table_changes_partitioned
WHERE changed_at >= '2025-12-01 00:00+00' AND operation_type = 'UPDATE';

-- =============================================================================
-- 6. LIST PARTITIONING (TENANT / CATEGORY)
-- =============================================================================
\echo '== 6. List partitioning of orders by merchant business_type =='
-- business_type lives on commerce.merchants; we denormalise it into the copy because
-- the partition key must be a column (or expression) of the partitioned table itself.
CREATE TABLE commerce.orders_by_type (
    order_id            bigint NOT NULL,
    merchant_id         bigint NOT NULL,
    customer_citizen_id bigint,
    business_type       commerce.business_type NOT NULL,
    order_number        varchar(50) NOT NULL,
    order_date          timestamptz NOT NULL,
    status              commerce.order_status NOT NULL,
    total_amount        numeric(12,2) NOT NULL,
    PRIMARY KEY (order_id, business_type),
    -- a global UNIQUE(order_number) is impossible; it must include the key
    UNIQUE (order_number, business_type)
) PARTITION BY LIST (business_type);

CREATE TABLE commerce.orders_by_type_restaurant PARTITION OF commerce.orders_by_type FOR VALUES IN ('restaurant');
CREATE TABLE commerce.orders_by_type_retail     PARTITION OF commerce.orders_by_type FOR VALUES IN ('retail');
CREATE TABLE commerce.orders_by_type_service    PARTITION OF commerce.orders_by_type FOR VALUES IN ('service');
CREATE TABLE commerce.orders_by_type_tech       PARTITION OF commerce.orders_by_type FOR VALUES IN ('technology');
CREATE TABLE commerce.orders_by_type_other      PARTITION OF commerce.orders_by_type
    FOR VALUES IN ('manufacturing', 'healthcare', 'other');

INSERT INTO commerce.orders_by_type
SELECT o.order_id, o.merchant_id, o.customer_citizen_id, m.business_type,
       o.order_number, o.order_date, o.status, o.total_amount
FROM commerce.orders o
JOIN commerce.merchants m USING (merchant_id);
ANALYZE commerce.orders_by_type;

SELECT tableoid::regclass AS partition, count(*) AS orders, round(sum(total_amount), 2) AS revenue
FROM commerce.orders_by_type
GROUP BY tableoid
ORDER BY orders DESC;

EXPLAIN (COSTS OFF)
SELECT count(*) FROM commerce.orders_by_type WHERE business_type IN ('retail', 'healthcare');

-- =============================================================================
-- 7. HASH PARTITIONING
-- =============================================================================
\echo '== 7. Hash partitioning spreads rows evenly when there is no natural range =='
CREATE TABLE civics.citizens_hashed (
    citizen_id bigint PRIMARY KEY,
    zip_code   varchar(10) NOT NULL,
    status     civics.civic_status NOT NULL
) PARTITION BY HASH (citizen_id);
CREATE TABLE civics.citizens_hashed_p0 PARTITION OF civics.citizens_hashed FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE civics.citizens_hashed_p1 PARTITION OF civics.citizens_hashed FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE civics.citizens_hashed_p2 PARTITION OF civics.citizens_hashed FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE civics.citizens_hashed_p3 PARTITION OF civics.citizens_hashed FOR VALUES WITH (MODULUS 4, REMAINDER 3);
INSERT INTO civics.citizens_hashed SELECT citizen_id, zip_code, status FROM civics.citizens;

SELECT tableoid::regclass AS partition, count(*) AS rows
FROM civics.citizens_hashed GROUP BY tableoid ORDER BY 1;

-- Equality on the hash key prunes to one partition; ranges cannot prune.
EXPLAIN (COSTS OFF) SELECT * FROM civics.citizens_hashed WHERE citizen_id = 42;

-- =============================================================================
-- 8. PARTITION MANAGEMENT HELPERS
-- =============================================================================
\echo '== 8. Helper to create monthly partitions (idempotent) =='
CREATE OR REPLACE FUNCTION mobility.create_sensor_partition(partition_year integer, partition_month integer)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    -- Note: naming a variable "table_name" would clash with information_schema's
    -- column of the same name (the original bug in this file); use a prefix.
    v_name  text := format('sensor_readings_part_%s_%s', partition_year, lpad(partition_month::text, 2, '0'));
    v_start timestamptz := make_timestamptz(partition_year, partition_month, 1, 0, 0, 0, 'UTC');
    v_end   timestamptz := v_start + interval '1 month';
BEGIN
    IF to_regclass(format('mobility.%I', v_name)) IS NOT NULL THEN
        RETURN format('mobility.%s already exists', v_name);
    END IF;
    -- Indexes defined on the parent are created on the new partition automatically.
    EXECUTE format('CREATE TABLE mobility.%I PARTITION OF mobility.sensor_readings_part FOR VALUES FROM (%L) TO (%L)',
                   v_name, v_start, v_end);
    RETURN format('created mobility.%s [%s, %s)', v_name, v_start, v_end);
END;
$$;

SELECT mobility.create_sensor_partition(2026, 4);
SELECT mobility.create_sensor_partition(2026, 4);   -- idempotent

-- Partition inventory: real row counts from the stats, sizes, bounds.
CREATE OR REPLACE FUNCTION analytics.partition_info(p_schemas text[] DEFAULT ARRAY['mobility', 'audit', 'commerce', 'civics'])
RETURNS TABLE(parent_table text, partition_name text, strategy text, partition_key text,
              partition_bounds text, est_rows bigint, size_pretty text)
LANGUAGE sql
STABLE
AS $$
    SELECT parent.oid::regclass::text,
           child.oid::regclass::text,
           CASE pt.partstrat WHEN 'r' THEN 'RANGE' WHEN 'l' THEN 'LIST' WHEN 'h' THEN 'HASH' END,
           pg_get_partkeydef(parent.oid),
           pg_get_expr(child.relpartbound, child.oid, true),
           -- reltuples is -1 until the table has been vacuumed/analyzed
           greatest(child.reltuples, 0)::bigint,
           pg_size_pretty(pg_total_relation_size(child.oid))
    FROM pg_partitioned_table pt
    JOIN pg_class parent ON parent.oid = pt.partrelid
    JOIN pg_namespace n  ON n.oid = parent.relnamespace
    JOIN pg_inherits i   ON i.inhparent = parent.oid
    JOIN pg_class child  ON child.oid = i.inhrelid
    WHERE n.nspname = ANY (p_schemas)
    ORDER BY 1, 2;
$$;

ANALYZE mobility.sensor_readings_part;
SELECT * FROM analytics.partition_info(ARRAY['mobility']);

-- =============================================================================
-- 9. pg_partman 5.x
-- =============================================================================
\echo '== 9. pg_partman 5.x manages a second module-owned table =='
-- What teaches: pg_partman pre-creates future partitions, keeps a DEFAULT, and
-- applies retention during run_maintenance(). In 5.x:
--   * only native declarative partitioning (trigger-based is gone)
--   * create_parent(p_parent_table, p_control, p_interval, p_type DEFAULT 'range', ...)
--     - p_interval is any interval text ('1 month', '1 week', '1 day')
--     - the old p_type => 'native' and 'daily'/'monthly' keywords no longer exist
--   * a template table (partman.template_<schema>_<table>) carries properties that
--     native partitioning cannot inherit (e.g. some unique indexes, relopts)
--   * run_maintenance_proc() (a procedure) is what you schedule, e.g. via pg_cron
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') THEN
        RAISE NOTICE 'pg_partman not installed in this database - skipping section 9';
        RETURN;
    END IF;

    -- idempotent reset: forget the config, drop the table and the template
    DELETE FROM partman.part_config WHERE parent_table = 'mobility.sensor_readings_partman';
    DROP TABLE IF EXISTS mobility.sensor_readings_partman CASCADE;
    DROP TABLE IF EXISTS partman.template_mobility_sensor_readings_partman;

    CREATE TABLE mobility.sensor_readings_partman (
        reading_id    bigint      NOT NULL,
        sensor_code   varchar(50) NOT NULL,
        sensor_type   mobility.sensor_type NOT NULL,
        reading_value numeric(12,4) NOT NULL,
        reading_time  timestamptz NOT NULL,
        PRIMARY KEY (reading_id, reading_time)
    ) PARTITION BY RANGE (reading_time);

    -- Weekly partitions starting at the first week of data. pg_partman also creates
    -- p_premake partitions ahead of the *wall-clock* now(), so the exact count of
    -- empty future partitions depends on when you run this.
    PERFORM partman.create_parent(
        p_parent_table    => 'mobility.sensor_readings_partman',
        p_control         => 'reading_time',
        p_interval        => '1 week',
        p_premake         => 2,
        p_start_partition => '2025-09-29'   -- a Monday; weekly partitions align to weeks
    );

    INSERT INTO mobility.sensor_readings_partman
    SELECT reading_id, sensor_code, sensor_type, reading_value, reading_time
    FROM mobility.sensor_readings;
END;
$$;

SELECT parent_table, control, partition_interval, partition_type, premake, retention,
       automatic_maintenance
FROM partman.part_config
WHERE parent_table = 'mobility.sensor_readings_partman';

-- How many children exist? Data weeks + premake weeks ahead of the wall clock.
SELECT count(*) AS child_partitions,
       min(partition_tablename) AS first_child,
       max(partition_tablename) AS last_child
FROM partman.show_partitions('mobility.sensor_readings_partman');

-- The data weeks (first 6 shown) and the default
SELECT partition_schemaname || '.' || partition_tablename AS partition
FROM partman.show_partitions('mobility.sensor_readings_partman')
ORDER BY partition_tablename
LIMIT 6;

-- A row outside every child goes to the default partition; check_default() reports
-- it and partition_data_time() creates the missing child and moves the row there.
INSERT INTO mobility.sensor_readings_partman VALUES (-1, 'SEN-OLD', 'noise', 40, '2025-06-15 08:00+00');
SELECT * FROM partman.check_default(p_exact_count => true);
SELECT partman.partition_data_time('mobility.sensor_readings_partman', p_batch_count => 10) AS rows_moved;
SELECT * FROM partman.check_default(p_exact_count => true);   -- empty again

-- Retention: keep 8 weeks of data, relative to the dataset's "now" (meta.as_of()),
-- not the wall clock. drop_partition_time() takes an explicit reference timestamp.
-- p_keep_table => false drops expired children; true would only detach them.
-- Run inside a transaction and roll back so the demo is repeatable.
BEGIN;
SELECT partman.drop_partition_time('mobility.sensor_readings_partman',
                                   p_retention           => interval '8 weeks',
                                   p_keep_table          => false,
                                   p_reference_timestamp => meta.as_of()) AS partitions_dropped;
SELECT min(reading_time) AS oldest_remaining FROM mobility.sensor_readings_partman;
ROLLBACK;

-- In production you would store the policy and let maintenance apply it:
--   UPDATE partman.part_config SET retention = '8 weeks', retention_keep_table = false
--    WHERE parent_table = 'mobility.sensor_readings_partman';
--   CALL partman.run_maintenance_proc();            -- schedule with pg_cron / cron
SELECT partman.run_maintenance('mobility.sensor_readings_partman');
