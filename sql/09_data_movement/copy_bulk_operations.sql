-- File: sql/09_data_movement/copy_bulk_operations.sql
-- Purpose: COPY in all its forms (server-side files, PROGRAM, STDOUT, \copy), CSV/HEADER
--          imports of messy files, PG17 ON_ERROR, file_fdw, staged validation, MERGE
--          upserts, and bulk-load performance techniques.
--
-- Inputs: the repo's data/ directory is mounted read-only in the container at /data.
-- Those files are small hand-written samples (a fictional "Springfield, IL"), each with
-- its own quirks, so we inspect them first and load into module-owned staging tables:
--   /data/seeds.csv          4 CSV sections (citizens, merchants, orders, trips), each
--                            preceded by "# ..." comment lines and separated by blanks
--   /data/timeseries.csv     one clean CSV with a header (67 sensor readings)
--   /data/documents.jsonb    JSON-lines with // comments and blank lines
--   /data/boundaries.geojson a single multi-line GeoJSON FeatureCollection
--
-- Server-side COPY (... FROM '/path' / TO '/path' / PROGRAM) runs as the database
-- server's OS user and needs superuser or the roles pg_read_server_files /
-- pg_write_server_files / pg_execute_server_program. polaris is a superuser here.
-- Client-side alternative: psql's \copy reads/writes files on YOUR machine:
--   \copy staging.sensor_timeseries FROM 'data/timeseries.csv' WITH (FORMAT csv, HEADER)
--   \copy (SELECT * FROM civics.citizens LIMIT 10) TO 'citizens.csv' WITH (FORMAT csv, HEADER)
-- \copy is the same COPY protocol (FROM STDIN / TO STDOUT) driven by psql.
--
-- Idempotent: everything lives in schema "staging" and is dropped/recreated; changes
-- to base tables only happen inside transactions that are rolled back.

\echo '== 0. Module-owned staging schema =='
CREATE SCHEMA IF NOT EXISTS staging;
DROP TABLE IF EXISTS staging.seed_lines, staging.seed_citizens, staging.seed_merchants,
                     staging.seed_orders, staging.seed_transit_trips, staging.sensor_timeseries,
                     staging.sensor_timeseries_strict, staging.document_lines, staging.documents,
                     staging.boundary_features, staging.sensor_readings_import,
                     staging.tax_updates, staging.bulk_load_demo, staging.freeze_demo CASCADE;
DROP FOREIGN TABLE IF EXISTS staging.ext_timeseries, staging.ext_seed_orders;

-- =============================================================================
-- 1. INSPECT A MESSY FILE: LOAD RAW LINES
-- =============================================================================
\echo '== 1. Raw line load: what does seeds.csv actually contain? =='
-- Trick: COPY in CSV mode with a delimiter and quote character that never occur in
-- the file puts each physical line into one text column. The identity column
-- records the line order (COPY reads the file sequentially).
CREATE TABLE staging.seed_lines (
    line_no bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line    text
);
COPY staging.seed_lines (line) FROM '/data/seeds.csv'
    WITH (FORMAT csv, DELIMITER E'\x01', QUOTE E'\x02');

-- Section headers are "# XXX DATA" lines; the next line is the CSV header.
SELECT line_no, line
FROM staging.seed_lines
WHERE line LIKE '# %DATA' OR line_no IN (SELECT line_no + 1 FROM staging.seed_lines WHERE line LIKE '# %DATA')
ORDER BY line_no;

-- Rows per section via a running count of section markers (a "gaps and islands" idiom)
SELECT section, count(*) FILTER (WHERE line !~ '^#' AND line IS NOT NULL) - 1 AS data_rows
FROM (
    SELECT line,
           max(CASE WHEN line LIKE '# %DATA' THEN line END) OVER (ORDER BY line_no) AS section
    FROM staging.seed_lines
) s
WHERE section IS NOT NULL
GROUP BY section
ORDER BY min(section);

-- =============================================================================
-- 2. COPY FROM PROGRAM: PRE-FILTER ONE SECTION, PARSE IT AS REAL CSV
-- =============================================================================
\echo '== 2. COPY ... FROM PROGRAM to extract each CSV section =='
-- The awk filter prints only the lines of one section (from its "# X DATA" marker to
-- the next "#" line, skipping blanks); COPY then applies full CSV parsing (quotes,
-- HEADER). FROM PROGRAM requires superuser or pg_execute_server_program.
CREATE TABLE staging.seed_citizens (
    citizen_id        integer PRIMARY KEY,
    name              text,
    email             text,
    phone             text,
    birth_date        date,
    registration_date date,
    address_line      text,
    city              text,
    state             text,
    zip_code          text,
    latitude          numeric(9,6),
    longitude         numeric(9,6)
);
COPY staging.seed_citizens FROM PROGRAM
    'awk ''/^# CITIZENS DATA/{f=1;next} /^#/{f=0} f && NF'' /data/seeds.csv'
    WITH (FORMAT csv, HEADER true);

CREATE TABLE staging.seed_merchants (
    merchant_id       integer PRIMARY KEY,
    business_name     text,
    owner_name        text,
    category          text,
    address           text,
    phone             text,
    registration_date date,
    tax_id            text,
    status            text
);
COPY staging.seed_merchants FROM PROGRAM
    'awk ''/^# MERCHANTS DATA/{f=1;next} /^#/{f=0} f && NF'' /data/seeds.csv'
    WITH (FORMAT csv, HEADER true);

CREATE TABLE staging.seed_orders (
    order_id         integer PRIMARY KEY,
    customer_id      integer,
    merchant_id      integer,
    order_date       date,
    total_amount     numeric(12,2),
    status           text,
    payment_method   text,
    delivery_address text
);
COPY staging.seed_orders FROM PROGRAM
    'awk ''/^# ORDERS DATA/{f=1;next} /^#/{f=0} f && NF'' /data/seeds.csv'
    WITH (FORMAT csv, HEADER true);

-- HEADER MATCH (PG15+) also checks that the header names equal the column names,
-- catching column-order mistakes instead of silently loading shifted data.
CREATE TABLE staging.seed_transit_trips (
    trip_id         integer PRIMARY KEY,
    route_id        integer,
    vehicle_id      text,
    start_station   text,
    end_station     text,
    departure_time  time,
    arrival_time    time,
    passenger_count integer,
    fare_amount     numeric(6,2),
    trip_date       date
);
COPY staging.seed_transit_trips FROM PROGRAM
    'awk ''/^# TRANSIT TRIPS DATA/{f=1;next} /^#/{f=0} f && NF'' /data/seeds.csv'
    WITH (FORMAT csv, HEADER match);

SELECT 'seed_citizens' AS staging_table, count(*) FROM staging.seed_citizens
UNION ALL SELECT 'seed_merchants', count(*) FROM staging.seed_merchants
UNION ALL SELECT 'seed_orders', count(*) FROM staging.seed_orders
UNION ALL SELECT 'seed_transit_trips', count(*) FROM staging.seed_transit_trips
ORDER BY 1;

-- =============================================================================
-- 3. A CLEAN CSV: HEADER, WHERE FILTER, ON_ERROR (PG17)
-- =============================================================================
\echo '== 3. timeseries.csv: typed load, COPY ... WHERE, ON_ERROR ignore =='
CREATE TABLE staging.sensor_timeseries (
    reading_ts       timestamp,          -- file has no zone; interpret explicitly later
    sensor_id        text,
    sensor_type      text,
    location_id      integer,
    measurement_type text,
    value            numeric,
    unit             text,
    quality_score    numeric(3,2),
    battery_level    integer,
    status           text
);
COPY staging.sensor_timeseries FROM '/data/timeseries.csv' WITH (FORMAT csv, HEADER true);

SELECT sensor_type, count(*) AS readings, min(reading_ts) AS first_ts, max(reading_ts) AS last_ts
FROM staging.sensor_timeseries
GROUP BY sensor_type
ORDER BY sensor_type;

-- COPY ... WHERE (PG12+) filters rows during the load (no second pass needed)
TRUNCATE staging.sensor_timeseries;
COPY staging.sensor_timeseries FROM '/data/timeseries.csv'
    WITH (FORMAT csv, HEADER true)
    WHERE sensor_type IN ('traffic_counter', 'air_quality');
SELECT count(*) AS rows_after_where_filter FROM staging.sensor_timeseries;

-- Bad input: write a small file with two malformed rows, then load it two ways.
COPY (
    VALUES ('2025-12-01 08:00:00', 'TRF001', '120',  '0.95'),
           ('2025-12-01 09:00:00', 'TRF001', 'n/a',  '0.95'),   -- bad numeric
           ('not-a-timestamp',     'TRF001', '130',  '0.90'),   -- bad timestamp
           ('2025-12-01 11:00:00', 'TRF001', '140',  '0.97')
) TO '/tmp/polaris_bad_readings.csv' WITH (FORMAT csv, HEADER true);

CREATE TABLE staging.sensor_timeseries_strict (
    reading_ts    timestamp NOT NULL,
    sensor_id     text NOT NULL,
    value         numeric NOT NULL,
    quality_score numeric(3,2)
);

-- (a) default ON_ERROR stop: one bad row aborts the whole COPY (nothing is loaded)
DO $$
BEGIN
    COPY staging.sensor_timeseries_strict FROM '/tmp/polaris_bad_readings.csv' WITH (FORMAT csv, HEADER true);
EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format THEN
    RAISE NOTICE 'COPY aborted, 0 rows loaded: %', SQLERRM;
END;
$$;

-- (b) PG17: ON_ERROR ignore skips rows with data-type conversion errors;
--     LOG_VERBOSITY verbose emits one NOTICE per skipped row.
COPY staging.sensor_timeseries_strict FROM '/tmp/polaris_bad_readings.csv'
    WITH (FORMAT csv, HEADER true, ON_ERROR ignore, LOG_VERBOSITY verbose);
SELECT * FROM staging.sensor_timeseries_strict ORDER BY reading_ts;
-- Note: ON_ERROR only covers type-input errors. Constraint violations (NOT NULL,
-- CHECK, UNIQUE) still abort the COPY - load into a permissive staging table first.

-- =============================================================================
-- 4. NON-CSV FILES: JSON LINES AND A WHOLE-FILE GEOJSON DOCUMENT
-- =============================================================================
\echo '== 4. documents.jsonb (JSON lines) and boundaries.geojson =='
CREATE TABLE staging.document_lines (
    line_no bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line    text
);
-- Again: one line per row, no CSV quoting, so backslashes/quotes in JSON survive.
COPY staging.document_lines (line) FROM '/data/documents.jsonb'
    WITH (FORMAT csv, DELIMITER E'\x01', QUOTE E'\x02');

-- Keep only JSON lines; pg_input_is_valid (PG16+) checks castability without erroring.
CREATE TABLE staging.documents AS
SELECT line_no, line::jsonb AS doc
FROM staging.document_lines
WHERE line ~ '^\s*\{' AND pg_input_is_valid(line, 'jsonb');

SELECT doc ->> 'type' AS doc_type, count(*) AS docs,
       count(*) FILTER (WHERE doc ? 'tags') AS with_tags
FROM staging.documents
GROUP BY 1
ORDER BY 1;

-- Whole-file read: pg_read_file (superuser / pg_read_server_files) returns the text,
-- which we cast to jsonb and explode into features with PostGIS geometries.
CREATE TABLE staging.boundary_features AS
SELECT (f.ordinality)::int                                 AS feature_no,
       f.feature -> 'properties' ->> 'name'                AS name,
       f.feature -> 'properties' ->> 'type'                AS feature_type,
       f.feature -> 'properties'                           AS properties,
       ST_SetSRID(ST_GeomFromGeoJSON(f.feature -> 'geometry'), 4326) AS geom
FROM jsonb_array_elements(pg_read_file('/data/boundaries.geojson')::jsonb -> 'features')
     WITH ORDINALITY AS f(feature, ordinality);

SELECT feature_type, GeometryType(geom) AS geom_type, count(*) AS features,
       round(sum(CASE WHEN GeometryType(geom) = 'POLYGON' THEN ST_Area(geom::geography) / 1e6 END)::numeric, 2) AS area_sq_km,
       round(sum(CASE WHEN GeometryType(geom) = 'LINESTRING' THEN ST_Length(geom::geography) / 1e3 END)::numeric, 2) AS length_km
FROM staging.boundary_features
GROUP BY 1, 2
ORDER BY 1;

-- =============================================================================
-- 5. EXPORTS: COPY TO STDOUT, COPY TO FILE, FORMATS
-- =============================================================================
\echo '== 5. COPY ... TO STDOUT (the protocol behind psql copy and drivers) =='
-- TO STDOUT streams to the client; psql prints it, drivers (psycopg2 copy_expert, psycopg 3 cursor.copy,
-- JDBC CopyManager) capture it. Works without any file-system privileges.
COPY (
    SELECT citizen_id, first_name, last_name, zip_code, status
    FROM civics.citizens
    ORDER BY citizen_id
    LIMIT 5
) TO STDOUT WITH (FORMAT csv, HEADER true);

-- Same data as tab-separated text with an explicit NULL marker
COPY (
    SELECT merchant_id, business_name, website
    FROM commerce.merchants
    ORDER BY merchant_id
    LIMIT 3
) TO STDOUT WITH (FORMAT text, NULL '<null>');

-- Server-side export with FORCE_QUOTE, then read it back to prove the round trip.
COPY (
    SELECT order_id, order_number, order_date, total_amount, status
    FROM commerce.orders
    WHERE order_date >= meta.as_of() - interval '7 days'
    ORDER BY order_date DESC, order_id
    LIMIT 25
) TO '/tmp/polaris_recent_orders.csv' WITH (FORMAT csv, HEADER true, FORCE_QUOTE (order_number));
SELECT left(pg_read_file('/tmp/polaris_recent_orders.csv'), 220) AS file_head;

-- Export helper: masks PII unless asked otherwise. Fixed file name keeps reruns idempotent.
CREATE OR REPLACE FUNCTION analytics.export_citizen_report(
    include_sensitive boolean DEFAULT false,
    file_path         text    DEFAULT '/tmp/polaris_citizen_report.csv'
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    export_query text;
    row_count    bigint;
BEGIN
    IF include_sensitive THEN
        export_query := $q$
            SELECT c.citizen_id, c.first_name, c.last_name, c.email, c.phone, c.zip_code,
                   count(pa.permit_id) AS permit_count
            FROM civics.citizens c
            LEFT JOIN civics.permit_applications pa ON pa.citizen_id = c.citizen_id
            WHERE c.status = 'active'
            GROUP BY c.citizen_id
            ORDER BY c.citizen_id$q$;
    ELSE
        export_query := $q$
            SELECT c.citizen_id,
                   left(c.first_name, 1) || '.'                          AS first_initial,
                   left(c.email, 2) || '***@' || split_part(c.email, '@', 2) AS masked_email,
                   c.zip_code,
                   date_part('year', age(meta.as_of(), c.date_of_birth))::int AS age_years,
                   count(pa.permit_id) AS permit_count
            FROM civics.citizens c
            LEFT JOIN civics.permit_applications pa ON pa.citizen_id = c.citizen_id
            WHERE c.status = 'active'
            GROUP BY c.citizen_id
            ORDER BY c.citizen_id$q$;
    END IF;

    EXECUTE format('COPY (%s) TO %L WITH (FORMAT csv, HEADER true)', export_query, file_path);
    GET DIAGNOSTICS row_count = ROW_COUNT;      -- COPY reports its row count

    RETURN format('Exported %s citizen records to %s (sensitive data %s)',
                  row_count, file_path, CASE WHEN include_sensitive THEN 'included' ELSE 'masked' END);
END;
$$;

SELECT analytics.export_citizen_report();
SELECT split_part(pg_read_file('/tmp/polaris_citizen_report.csv'), E'\n', 2) AS first_data_line;

-- =============================================================================
-- 6. file_fdw: QUERY FILES IN PLACE
-- =============================================================================
\echo '== 6. file_fdw foreign tables over /data files =='
-- A foreign table re-reads the file on every scan: handy for "query before load".
CREATE EXTENSION IF NOT EXISTS file_fdw;
CREATE SERVER IF NOT EXISTS file_server FOREIGN DATA WRAPPER file_fdw;

CREATE FOREIGN TABLE staging.ext_timeseries (
    reading_ts       timestamp,
    sensor_id        text,
    sensor_type      text,
    location_id      integer,
    measurement_type text,
    value            numeric,
    unit             text,
    quality_score    numeric(3,2),
    battery_level    integer,
    status           text
) SERVER file_server
OPTIONS (filename '/data/timeseries.csv', format 'csv', header 'true');

-- file_fdw can also read a program's output (same privilege as COPY FROM PROGRAM)
CREATE FOREIGN TABLE staging.ext_seed_orders (
    order_id         integer,
    customer_id      integer,
    merchant_id      integer,
    order_date       date,
    total_amount     numeric(12,2),
    status           text,
    payment_method   text,
    delivery_address text
) SERVER file_server
OPTIONS (program 'awk ''/^# ORDERS DATA/{f=1;next} /^#/{f=0} f && NF'' /data/seeds.csv',
         format 'csv', header 'true');

SELECT sensor_type, count(*) AS readings, round(avg(quality_score), 3) AS avg_quality,
       min(battery_level) AS min_battery
FROM staging.ext_timeseries
GROUP BY sensor_type
ORDER BY sensor_type;

SELECT status, count(*), sum(total_amount) FROM staging.ext_seed_orders GROUP BY status ORDER BY status;

-- Map external readings onto the city's sensor model, rejecting what does not fit.
CREATE TABLE staging.sensor_readings_import (LIKE mobility.sensor_readings INCLUDING DEFAULTS);

CREATE OR REPLACE FUNCTION staging.import_external_sensor_data()
RETURNS TABLE(outcome text, sensor_type text, rows bigint)
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE staging.sensor_readings_import;

    INSERT INTO staging.sensor_readings_import
           (sensor_code, sensor_type, latitude, longitude, reading_value, unit_of_measure,
            reading_time, data_quality_score, raw_data)
    SELECT e.sensor_id,
           e.sensor_type::mobility.sensor_type,
           32.98, -96.80,                                -- sample has location ids, not coordinates
           e.value,
           e.unit,
           e.reading_ts AT TIME ZONE 'America/Chicago',  -- file times are local wall-clock
           e.quality_score,
           jsonb_build_object('location_id', e.location_id, 'battery', e.battery_level, 'source', 'timeseries.csv')
    FROM staging.ext_timeseries e
    WHERE e.value IS NOT NULL
      AND e.sensor_type = ANY (enum_range(NULL::mobility.sensor_type)::text[]);

    RETURN QUERY
    SELECT 'imported', i.sensor_type::text, count(*) FROM staging.sensor_readings_import i GROUP BY i.sensor_type
    UNION ALL
    SELECT 'rejected: unknown sensor_type', e.sensor_type, count(*)
    FROM staging.ext_timeseries e
    WHERE NOT (e.sensor_type = ANY (enum_range(NULL::mobility.sensor_type)::text[]))
    GROUP BY e.sensor_type
    ORDER BY 1, 2;
END;
$$;

SELECT * FROM staging.import_external_sensor_data();

-- =============================================================================
-- 7. STAGE, VALIDATE, THEN LOAD (ROLLED BACK)
-- =============================================================================
\echo '== 7. Validate staged citizens, then load inside a rolled-back transaction =='
CREATE OR REPLACE FUNCTION analytics.bulk_import_citizens(validate_only boolean DEFAULT true)
RETURNS TABLE(import_status text, total_rows bigint, valid_rows bigint, invalid_rows bigint, error_details text[])
LANGUAGE plpgsql
AS $$
DECLARE
    v_total bigint;
    v_valid bigint;
    v_errors text[];
BEGIN
    -- Validation rules mirror the target's CHECK constraints, plus duplicate detection.
    CREATE TEMP TABLE IF NOT EXISTS tmp_citizen_validation (citizen_id int, error_note text) ON COMMIT DROP;
    TRUNCATE tmp_citizen_validation;
    INSERT INTO tmp_citizen_validation
    SELECT s.citizen_id,
           CASE
               WHEN s.email IS NULL OR s.email = ''                                  THEN 'missing email'
               WHEN s.email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'     THEN 'invalid email format'
               WHEN EXISTS (SELECT 1 FROM civics.citizens c WHERE c.email = s.email) THEN 'email already registered'
               WHEN s.zip_code !~ '^\d{5}(-\d{4})?$'                                 THEN 'invalid ZIP code'
               WHEN s.birth_date > CURRENT_DATE OR s.birth_date < DATE '1900-01-01'  THEN 'implausible birth date'
               WHEN s.name !~ '\S+\s+\S+'                                            THEN 'name must be "first last"'
           END
    FROM staging.seed_citizens s;

    SELECT count(*), count(*) FILTER (WHERE error_note IS NULL),
           array_agg(citizen_id || ': ' || error_note ORDER BY citizen_id) FILTER (WHERE error_note IS NOT NULL)
      INTO v_total, v_valid, v_errors
      FROM tmp_citizen_validation;

    IF NOT validate_only THEN
        INSERT INTO civics.citizens (first_name, last_name, date_of_birth, email, phone,
                                     street_address, city, state, zip_code, home_geom, status, registered_date)
        SELECT split_part(s.name, ' ', 1), substr(s.name, strpos(s.name, ' ') + 1), s.birth_date, s.email, s.phone,
               s.address_line, s.city, s.state, s.zip_code,
               ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326), 'active', s.registration_date
        FROM staging.seed_citizens s
        JOIN tmp_citizen_validation v USING (citizen_id)
        WHERE v.error_note IS NULL;
    END IF;

    RETURN QUERY SELECT CASE WHEN validate_only THEN 'VALIDATION_ONLY' ELSE 'IMPORTED' END,
                        v_total, v_valid, v_total - v_valid, coalesce(v_errors, '{}');
END;
$$;

-- Simulate a bad feed: two extra staged rows that violate the rules.
INSERT INTO staging.seed_citizens (citizen_id, name, email, phone, birth_date, registration_date,
                                   address_line, city, state, zip_code, latitude, longitude)
VALUES (11, 'Kim Novak', 'kim.novak(at)email.com', '555-0111', '1980-02-02', '2021-01-01',
        '11 Ash Street', 'Springfield', 'IL', '62711', 39.78, -89.65),
       (12, 'Leo Grant', 'leo.grant@email.com', '555-0112', '2090-01-01', '2021-01-01',
        '12 Ash Street', 'Springfield', 'IL', '627', 39.78, -89.65);

BEGIN;
SELECT * FROM analytics.bulk_import_citizens(validate_only => true);
SELECT * FROM analytics.bulk_import_citizens(validate_only => false);
SELECT count(*) AS springfield_citizens_visible_in_txn FROM civics.citizens WHERE state = 'IL';
ROLLBACK;
SELECT count(*) AS springfield_citizens_after_rollback FROM civics.citizens WHERE state = 'IL';

-- =============================================================================
-- 8. BULK UPSERT WITH MERGE ... RETURNING (PG17), ROLLED BACK
-- =============================================================================
\echo '== 8. Staged tax-payment updates applied with MERGE (rolled back) =='
-- civics.tax_payments has no UNIQUE (citizen_id, tax_type, tax_year), so
-- INSERT ... ON CONFLICT cannot target it; MERGE matches on any join condition.
CREATE TABLE staging.tax_updates (
    citizen_id   bigint,
    tax_type     civics.tax_type,
    tax_year     integer,
    amount_paid  numeric(12,2),
    payment_date date
);
-- Two pending/overdue bills paid in full plus one brand-new assessment
INSERT INTO staging.tax_updates
SELECT citizen_id, tax_type, tax_year, amount_due, DATE '2025-12-15'
FROM civics.tax_payments
WHERE payment_status IN ('pending', 'overdue')
ORDER BY tax_id
LIMIT 2;
INSERT INTO staging.tax_updates VALUES (10, 'utility', 2025, 120.00, DATE '2025-12-20');

BEGIN;
MERGE INTO civics.tax_payments t
USING staging.tax_updates s
   ON t.citizen_id = s.citizen_id AND t.tax_type = s.tax_type AND t.tax_year = s.tax_year
WHEN MATCHED AND t.payment_status <> 'paid' THEN
    UPDATE SET amount_paid    = least(s.amount_paid, t.amount_due),
               payment_status = CASE WHEN s.amount_paid >= t.amount_due THEN 'paid' ELSE t.payment_status END,
               payment_date   = s.payment_date,
               updated_at     = now()
WHEN NOT MATCHED THEN
    INSERT (citizen_id, tax_type, tax_year, assessment_amount, amount_due, amount_paid,
            payment_status, due_date, payment_date)
    VALUES (s.citizen_id, s.tax_type, s.tax_year, s.amount_paid, s.amount_paid, s.amount_paid,
            'paid', make_date(s.tax_year, 12, 31), s.payment_date)
RETURNING merge_action() AS action, t.citizen_id, t.tax_type, t.tax_year, t.amount_paid, t.payment_status;
ROLLBACK;

-- =============================================================================
-- 9. BULK-LOAD PERFORMANCE TECHNIQUES
-- =============================================================================
\echo '== 9. Row-by-row INSERT vs INSERT ... SELECT vs COPY; COPY FREEZE =='
-- Timings vary by machine; the ratios are the lesson. UNLOGGED skips WAL (fast,
-- but the table is emptied after a crash and is not replicated).
CREATE UNLOGGED TABLE staging.bulk_load_demo (
    id            integer,
    sensor_code   text,
    reading_value numeric(12,4),
    reading_time  timestamptz
);

DO $$
DECLARE
    t0 timestamptz;
    i  integer;
    n  constant integer := 20000;
BEGIN
    -- (a) one INSERT statement per row (what naive ORMs do)
    t0 := clock_timestamp();
    FOR i IN 1..n LOOP
        INSERT INTO staging.bulk_load_demo VALUES (i, 'SEN-' || (i % 50), i % 997, meta.as_of() - i * interval '1 minute');
    END LOOP;
    RAISE NOTICE 'row-by-row INSERT : % rows in % ms', n, round(extract(epoch FROM clock_timestamp() - t0) * 1000);

    -- (b) one set-based INSERT ... SELECT
    TRUNCATE staging.bulk_load_demo;
    t0 := clock_timestamp();
    INSERT INTO staging.bulk_load_demo
    SELECT g, 'SEN-' || (g % 50), g % 997, meta.as_of() - g * interval '1 minute'
    FROM generate_series(1, n) g;
    RAISE NOTICE 'INSERT ... SELECT : % rows in % ms', n, round(extract(epoch FROM clock_timestamp() - t0) * 1000);

    -- (c) COPY round trip through a server file (binary format: no text parsing)
    EXECUTE 'COPY staging.bulk_load_demo TO ''/tmp/polaris_bulk_demo.bin'' WITH (FORMAT binary)';
    TRUNCATE staging.bulk_load_demo;
    t0 := clock_timestamp();
    EXECUTE 'COPY staging.bulk_load_demo FROM ''/tmp/polaris_bulk_demo.bin'' WITH (FORMAT binary)';
    RAISE NOTICE 'COPY FROM (binary): % rows in % ms', n, round(extract(epoch FROM clock_timestamp() - t0) * 1000);
END;
$$;

SELECT count(*) AS rows_loaded FROM staging.bulk_load_demo;

-- COPY FREEZE writes rows already frozen (no later anti-wraparound rewrite, all-visible
-- for index-only scans). Allowed only if the table was created or truncated in the
-- same transaction, so no other session could see it half-loaded.
BEGIN;
CREATE TABLE staging.freeze_demo (LIKE staging.bulk_load_demo);
COPY staging.freeze_demo FROM '/tmp/polaris_bulk_demo.bin' WITH (FORMAT binary, FREEZE true);
COMMIT;
SELECT count(*) AS frozen_rows,
       (SELECT all_visible FROM pg_visibility_map_summary('staging.freeze_demo')) AS all_visible_pages
FROM staging.freeze_demo;

-- Other levers for big loads (not run here):
--   * drop/disable non-essential indexes and FKs, load, then recreate (one sort per index)
--   * raise maintenance_work_mem for the index builds; max_wal_size to avoid checkpoints
--   * split the input and run several COPY sessions in parallel (one per partition)
--   * ANALYZE the table afterwards so the planner sees the new data
