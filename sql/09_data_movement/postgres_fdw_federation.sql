-- File: sql/09_data_movement/postgres_fdw_federation.sql
-- Purpose: Federate a second PostgreSQL database with postgres_fdw: servers, user
--          mappings, IMPORT FOREIGN SCHEMA, push-down (EXPLAIN VERBOSE "Remote SQL"),
--          pulling and pushing data, transactional behaviour, and monitoring.
--
-- Setup used here: a LOOPBACK server pointing at the database `polaris_test` in the
-- same container (host 'localhost'). The "remote" side is a module-owned schema
-- fdw_demo inside polaris_test that pretends to be a regional / state data hub.
-- In production the server would be another host:
--   CREATE SERVER regional_data_server FOREIGN DATA WRAPPER postgres_fdw
--       OPTIONS (host 'regional-db.example.com', port '5432', dbname 'regional_data',
--                sslmode 'verify-full');
--
-- Idempotent: remote objects are created IF NOT EXISTS under an advisory lock; local
-- objects (server, mapping, schema fdw_remote) are created IF NOT EXISTS / rebuilt.
-- Requires psql (uses \connect, \getenv, \gset).

\set ON_ERROR_STOP on
SELECT current_database() AS home_db \gset

-- Password for the user mapping: $POSTGRES_PASSWORD if set, else the dev default.
\getenv fdw_password POSTGRES_PASSWORD
\if :{?fdw_password}
\else
\set fdw_password polaris_dev_only
\endif

-- =============================================================================
-- 1. PREPARE THE "REMOTE" DATABASE (schema fdw_demo in polaris_test)
-- =============================================================================
\echo '== 1. Remote side: fdw_demo schema in polaris_test =='
\connect polaris_test
BEGIN;
-- Several sessions may run this file at once; serialise the setup.
SELECT pg_advisory_xact_lock(hashtext('polaris.fdw_demo.setup'));
CREATE SCHEMA IF NOT EXISTS fdw_demo;

CREATE TABLE IF NOT EXISTS fdw_demo.regional_demographics (
    county_name       text    NOT NULL,
    city_name         text    NOT NULL,
    population        integer NOT NULL,
    median_income     numeric(12,2),
    unemployment_rate numeric(5,2),
    data_year         integer NOT NULL,
    last_updated      timestamptz NOT NULL DEFAULT '2025-12-01 00:00+00',
    PRIMARY KEY (city_name, data_year)
);
INSERT INTO fdw_demo.regional_demographics (county_name, city_name, population, median_income, unemployment_rate, data_year)
VALUES ('Dallas',  'Dallas',      1302868, 63985, 4.1, 2025),
       ('Dallas',  'Garland',      246018, 67430, 3.9, 2025),
       ('Dallas',  'Irving',       256684, 72430, 3.6, 2025),
       ('Collin',  'Plano',        289547, 101370, 3.2, 2025),
       ('Collin',  'Frisco',       225007, 133970, 2.9, 2025),
       ('Denton',  'Denton',       150353, 59870, 3.8, 2025),
       ('Tarrant', 'Arlington',    398431, 70740, 4.0, 2025),
       ('Dallas',  'Dallas',      1299544, 61200, 4.4, 2024),
       ('Collin',  'Plano',        288253, 98900, 3.4, 2024)
ON CONFLICT DO NOTHING;

-- State business registry: EINs follow the city's merchant tax_id pattern 75-000NNNN.
-- Every 25th merchant is missing from the registry; every 40th is 'revoked'.
CREATE TABLE IF NOT EXISTS fdw_demo.state_business_registry (
    ein               text PRIMARY KEY,
    business_name     text NOT NULL,
    status            text NOT NULL,
    registration_date date NOT NULL,
    county            text NOT NULL DEFAULT 'Collin',
    state_code        char(2) NOT NULL DEFAULT 'TX'
);
INSERT INTO fdw_demo.state_business_registry (ein, business_name, status, registration_date)
SELECT format('75-%s', lpad(g::text, 7, '0')),
       'Registered entity ' || g,
       CASE WHEN g % 40 = 0 THEN 'revoked' ELSE 'active' END,
       DATE '2015-01-01' + (g * 7)
FROM generate_series(1, 500) AS g
WHERE g % 25 <> 0
ON CONFLICT DO NOTHING;

-- Monthly economic indicators for the region (deterministic)
CREATE TABLE IF NOT EXISTS fdw_demo.economic_indicators (
    indicator_date          date PRIMARY KEY,
    region_code             text NOT NULL DEFAULT 'DFW',
    employment_rate         numeric(5,2) NOT NULL,
    average_wage            numeric(10,2) NOT NULL,
    business_formation_rate numeric(5,2) NOT NULL
);
INSERT INTO fdw_demo.economic_indicators (indicator_date, employment_rate, average_wage, business_formation_rate)
SELECT d::date,
       95.5 + (extract(month FROM d)::int % 3) * 0.2,
       5600 + extract(month FROM d)::int * 12.5,
       1.8 + (extract(month FROM d)::int % 4) * 0.1
FROM generate_series(DATE '2025-01-01', DATE '2025-12-01', interval '1 month') AS d
ON CONFLICT DO NOTHING;

-- Write target for the "sync to warehouse" demo; keyed by the source database so
-- each client database owns (and replaces) only its own rows.
CREATE TABLE IF NOT EXISTS fdw_demo.city_daily_metrics (
    source_db       text NOT NULL,
    metric_date     date NOT NULL,
    city_name       text NOT NULL,
    permit_count    integer,
    complaint_count integer,
    tax_revenue     numeric(15,2),
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_db, metric_date)
);
COMMIT;
ANALYZE fdw_demo.regional_demographics;
ANALYZE fdw_demo.state_business_registry;
ANALYZE fdw_demo.economic_indicators;

\connect :home_db

-- =============================================================================
-- 2. SERVER, USER MAPPING, FOREIGN TABLES
-- =============================================================================
\echo '== 2. Foreign server, user mapping, IMPORT FOREIGN SCHEMA =='
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Server options worth knowing:
--   fetch_size          rows per FETCH from the remote cursor (default 100)
--   batch_size          rows per remote INSERT batch (PG14+, default 1)
--   use_remote_estimate ask the remote for EXPLAIN costs (better join plans, extra round trip)
--   async_capable       scan several foreign partitions concurrently (PG14+)
--   parallel_commit     commit remote transactions in parallel (PG15+)
CREATE SERVER IF NOT EXISTS polaris_loopback
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5432', dbname 'polaris_test',
             fetch_size '1000', batch_size '100', application_name 'postgres_fdw_polaris');

-- Credentials live in the user mapping (visible only to the owner/superusers via
-- pg_user_mappings). Non-superusers MUST supply a password; never rely on trust auth.
CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER polaris_loopback
    OPTIONS (user 'polaris', password :'fdw_password');
-- keep the password current on re-runs
ALTER USER MAPPING FOR CURRENT_USER SERVER polaris_loopback
    OPTIONS (SET password :'fdw_password');

SELECT srvname, srvoptions FROM pg_foreign_server WHERE srvname = 'polaris_loopback';
SELECT srvname, usename,
       (SELECT array_agg(o) FROM unnest(umoptions) o WHERE o NOT LIKE 'password=%') AS options_without_password
FROM pg_user_mappings WHERE srvname = 'polaris_loopback';

-- IMPORT FOREIGN SCHEMA creates foreign tables matching the remote definitions.
-- Gotcha: by default column DEFAULTs are NOT imported (import_default false), so an
-- INSERT that omits a NOT NULL column with a remote default sends NULL and fails.
-- import_default 'true' copies the defaults (they are evaluated locally).
DROP SCHEMA IF EXISTS fdw_remote CASCADE;
CREATE SCHEMA fdw_remote;
IMPORT FOREIGN SCHEMA fdw_demo
    LIMIT TO (regional_demographics, state_business_registry, economic_indicators, city_daily_metrics)
    FROM SERVER polaris_loopback INTO fdw_remote
    OPTIONS (import_default 'true');

-- A hand-written foreign table can rename columns and select a subset.
CREATE FOREIGN TABLE fdw_remote.registry_status (
    tax_id text OPTIONS (column_name 'ein'),
    status text
) SERVER polaris_loopback OPTIONS (schema_name 'fdw_demo', table_name 'state_business_registry');

SELECT foreign_table_schema, foreign_table_name
FROM information_schema.foreign_tables
WHERE foreign_server_name = 'polaris_loopback'
ORDER BY 2;

-- Local planner statistics for foreign tables come from ANALYZE (samples remote rows).
ANALYZE fdw_remote.regional_demographics;
ANALYZE fdw_remote.state_business_registry;

-- =============================================================================
-- 3. PUSH-DOWN: WHAT RUNS REMOTELY?
-- =============================================================================
\echo '== 3. EXPLAIN VERBOSE shows the Remote SQL =='
-- (a) WHERE, ORDER BY and LIMIT are shipped to the remote server
EXPLAIN (VERBOSE, COSTS OFF)
SELECT city_name, population
FROM fdw_remote.regional_demographics
WHERE data_year = 2025 AND population > 200000
ORDER BY population DESC
LIMIT 3;

-- (b) aggregates can be pushed down too ("Relations: Aggregate on ..."): GROUP BY runs
--     remotely and only the groups travel. It is a cost decision: for a 7-row table
--     the planner may prefer fetching rows and aggregating locally.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT status, count(*), min(registration_date)
FROM fdw_remote.state_business_registry
GROUP BY status;

-- (c) a join between two foreign tables on the same server is pushed down as one query
EXPLAIN (VERBOSE, COSTS OFF)
SELECT r.county_name, count(*)
FROM fdw_remote.state_business_registry b
JOIN fdw_remote.regional_demographics r ON r.county_name = b.county
WHERE r.data_year = 2025
GROUP BY r.county_name;

-- (d) a join with a LOCAL table cannot be pushed: rows are fetched and joined here.
--     Only built-in immutable functions/operators are shipped; a non-shippable
--     expression (here a user function) stays in a local Filter.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT m.business_name, b.status
FROM commerce.merchants m
JOIN fdw_remote.state_business_registry b ON b.ein = m.tax_id
WHERE meta.as_of() > b.registration_date;

-- =============================================================================
-- 4. FEDERATED QUERIES
-- =============================================================================
\echo '== 4. Cross-database queries =='
-- Compare Polaris City with the region (local aggregates + remote averages)
DROP FUNCTION IF EXISTS analytics.compare_with_regional_averages();
CREATE OR REPLACE FUNCTION analytics.compare_with_regional_averages(p_year integer DEFAULT 2025)
RETURNS TABLE(metric_name text, polaris_city_value numeric, regional_average numeric,
              regional_min numeric, regional_max numeric, performance_vs_region text)
LANGUAGE sql
STABLE
AS $$
    WITH local_metrics(metric, local_value) AS (
        SELECT 'Population', sum(population_estimate)::numeric FROM geo.neighborhood_boundaries
        UNION ALL
        SELECT 'Median household income',
               (percentile_cont(0.5) WITHIN GROUP (ORDER BY median_income))::numeric
        FROM geo.neighborhood_boundaries
    ),
    regional(metric, avg_v, min_v, max_v) AS (
        SELECT 'Population', avg(population), min(population), max(population)
        FROM fdw_remote.regional_demographics WHERE data_year = p_year
        UNION ALL
        SELECT 'Median household income', avg(median_income), min(median_income), max(median_income)
        FROM fdw_remote.regional_demographics WHERE data_year = p_year
    )
    SELECT l.metric, round(l.local_value, 0), round(r.avg_v, 0), round(r.min_v, 0), round(r.max_v, 0),
           CASE WHEN l.local_value > r.avg_v THEN 'Above average'
                WHEN l.local_value < r.avg_v THEN 'Below average'
                ELSE 'At average' END
    FROM local_metrics l
    JOIN regional r USING (metric)
    ORDER BY l.metric;
$$;

SELECT * FROM analytics.compare_with_regional_averages();

-- Validate local merchants against the state registry (local LEFT JOIN remote)
DROP FUNCTION IF EXISTS commerce.validate_businesses_with_state_registry();
CREATE OR REPLACE FUNCTION commerce.validate_businesses_with_state_registry()
RETURNS TABLE(local_business_name text, local_tax_id text, state_registry_status text,
              registration_match boolean, recommendation text)
LANGUAGE sql
STABLE
AS $$
    SELECT m.business_name::text,
           m.tax_id::text,
           coalesce(r.status, 'NOT_FOUND'),
           r.tax_id IS NOT NULL,
           CASE WHEN r.tax_id IS NULL      THEN 'Verify state business registration'
                WHEN r.status <> 'active'  THEN 'Check state registration status'
                ELSE 'Registration validated' END
    FROM commerce.merchants m
    LEFT JOIN fdw_remote.registry_status r ON r.tax_id = m.tax_id
    WHERE m.is_active
    ORDER BY m.merchant_id;
$$;

SELECT recommendation, count(*) AS merchants
FROM commerce.validate_businesses_with_state_registry()
GROUP BY recommendation
ORDER BY merchants DESC, recommendation;

SELECT * FROM commerce.validate_businesses_with_state_registry()
WHERE NOT registration_match OR state_registry_status <> 'active'
LIMIT 5;

-- =============================================================================
-- 5. MOVING DATA: PULL (remote -> local) AND PUSH (local -> remote)
-- =============================================================================
\echo '== 5. Pull reference data, push daily metrics =='
-- Pull: materialise remote reference data locally (cache for fast joins).
DROP FUNCTION IF EXISTS analytics.update_regional_benchmarks();
CREATE OR REPLACE FUNCTION analytics.update_regional_benchmarks()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows integer;
    v_year integer;
BEGIN
    CREATE TABLE IF NOT EXISTS analytics.regional_benchmarks (
        benchmark_year         integer,
        county_name            text,
        population_benchmark   integer,
        income_benchmark       numeric(12,2),
        unemployment_benchmark numeric(5,2),
        updated_at             timestamptz DEFAULT now(),
        PRIMARY KEY (benchmark_year, county_name)
    );

    SELECT max(data_year) INTO v_year FROM fdw_remote.regional_demographics;

    -- MERGE ... with a foreign table as the SOURCE is fine (the target is local).
    MERGE INTO analytics.regional_benchmarks b
    USING (
        SELECT data_year, county_name, avg(population)::int AS pop,
               avg(median_income) AS inc, avg(unemployment_rate) AS unemp
        FROM fdw_remote.regional_demographics
        WHERE data_year = v_year
        GROUP BY data_year, county_name
    ) s ON b.benchmark_year = s.data_year AND b.county_name = s.county_name
    WHEN MATCHED THEN UPDATE SET population_benchmark = s.pop, income_benchmark = s.inc,
                                 unemployment_benchmark = s.unemp, updated_at = now()
    WHEN NOT MATCHED THEN INSERT (benchmark_year, county_name, population_benchmark, income_benchmark, unemployment_benchmark)
                          VALUES (s.data_year, s.county_name, s.pop, s.inc, s.unemp);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN format('Merged %s county benchmarks for %s', v_rows, v_year);
END;
$$;

SELECT analytics.update_regional_benchmarks();
SELECT benchmark_year, county_name, population_benchmark, income_benchmark
FROM analytics.regional_benchmarks ORDER BY benchmark_year, county_name;

-- Push: write the city's daily metrics to the remote warehouse table. postgres_fdw
-- supports INSERT/UPDATE/DELETE (and INSERT ... ON CONFLICT DO NOTHING, but not
-- DO UPDATE). We replace this database's rows for the date: DELETE + INSERT, atomically.
DROP FUNCTION IF EXISTS analytics.sync_to_warehouse();
CREATE OR REPLACE FUNCTION analytics.sync_to_warehouse(p_date date DEFAULT (meta.as_of() AT TIME ZONE 'UTC')::date - 1)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows integer;
BEGIN
    DELETE FROM fdw_remote.city_daily_metrics
    WHERE source_db = current_database() AND metric_date = p_date;

    INSERT INTO fdw_remote.city_daily_metrics (source_db, metric_date, city_name, permit_count, complaint_count, tax_revenue)
    SELECT current_database(), p_date, 'Polaris City',
           (SELECT count(*) FROM civics.permit_applications
             WHERE application_date >= p_date AND application_date < p_date + 1),
           (SELECT count(*) FROM documents.complaint_records
             WHERE submitted_at >= p_date AND submitted_at < p_date + 1),
           (SELECT coalesce(sum(amount_paid), 0) FROM civics.tax_payments
             WHERE payment_date >= p_date AND payment_date < p_date + 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN format('Synced %s row(s) of daily metrics for %s to %s', v_rows, p_date, 'polaris_test.fdw_demo.city_daily_metrics');
END;
$$;

SELECT analytics.sync_to_warehouse();
SELECT analytics.sync_to_warehouse();          -- re-run replaces, does not duplicate
SELECT metric_date, city_name, permit_count, complaint_count, tax_revenue
FROM fdw_remote.city_daily_metrics
WHERE source_db = current_database()
ORDER BY metric_date;

-- Distributed transaction semantics: the remote transaction follows the local one.
-- ROLLBACK here also rolls back the remote INSERT. (On COMMIT, postgres_fdw commits
-- remote transactions after local pre-commit; it is NOT two-phase commit, so a crash
-- in between can leave them inconsistent.)
BEGIN;
INSERT INTO fdw_remote.city_daily_metrics (source_db, metric_date, city_name, permit_count)
VALUES (current_database(), DATE '1999-12-31', 'Rollback test', 0);
SELECT count(*) AS visible_inside_txn FROM fdw_remote.city_daily_metrics
WHERE source_db = current_database() AND metric_date = DATE '1999-12-31';
ROLLBACK;
SELECT count(*) AS after_rollback FROM fdw_remote.city_daily_metrics
WHERE source_db = current_database() AND metric_date = DATE '1999-12-31';

-- =============================================================================
-- 6. FEDERATED REPORT
-- =============================================================================
\echo '== 6. Federated report =='
DROP FUNCTION IF EXISTS analytics.generate_regional_comparison_report();
CREATE OR REPLACE FUNCTION analytics.generate_regional_comparison_report()
RETURNS TABLE(report_section text, metric_name text, polaris_value text, regional_value text)
LANGUAGE sql
STABLE
AS $$
    SELECT 'Demographics', 'Population',
           (SELECT sum(population_estimate)::text FROM geo.neighborhood_boundaries),
           (SELECT round(avg(population))::text FROM fdw_remote.regional_demographics WHERE data_year = 2025)
    UNION ALL
    SELECT 'Economic', 'New merchants (12 months) / avg monthly business formation rate',
           (SELECT count(*)::text FROM commerce.merchants
             WHERE registration_date >= meta.as_of() - interval '12 months'),
           (SELECT round(avg(business_formation_rate), 2)::text || ' %' FROM fdw_remote.economic_indicators
             WHERE indicator_date >= (meta.as_of() - interval '12 months')::date)
    UNION ALL
    SELECT 'Service delivery', 'Avg permit processing days (6 months)',
           (SELECT round(avg(extract(epoch FROM approval_date - application_date) / 86400))::text
              FROM civics.permit_applications
             WHERE approval_date IS NOT NULL
               AND application_date >= meta.as_of() - interval '6 months'),
           '15 (state target)';
$$;

SELECT * FROM analytics.generate_regional_comparison_report();

-- =============================================================================
-- 7. MONITORING AND CONNECTION MANAGEMENT
-- =============================================================================
\echo '== 7. Connection checks and monitoring =='
-- Probe every postgres_fdw server we have foreign tables for, catching failures.
DROP FUNCTION IF EXISTS analytics.test_foreign_connections();
CREATE OR REPLACE FUNCTION analytics.test_foreign_connections()
RETURNS TABLE(server_name text, foreign_table text, connection_status text, row_count bigint, elapsed_ms numeric)
LANGUAGE plpgsql
AS $$
DECLARE
    r  record;
    t0 timestamptz;
BEGIN
    FOR r IN
        SELECT DISTINCT ON (s.srvname) s.srvname, format('%I.%I', n.nspname, c.relname) AS ft
        FROM pg_foreign_table f
        JOIN pg_class c ON c.oid = f.ftrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_foreign_server s ON s.oid = f.ftserver
        JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw AND w.fdwname = 'postgres_fdw'
        ORDER BY s.srvname, c.relname DESC   -- a stable, read-only table
    LOOP
        server_name := r.srvname;
        foreign_table := r.ft;
        t0 := clock_timestamp();
        BEGIN
            EXECUTE format('SELECT count(*) FROM %s', r.ft) INTO row_count;
            connection_status := 'CONNECTED';
        EXCEPTION WHEN OTHERS THEN
            connection_status := 'ERROR: ' || SQLERRM;
            row_count := NULL;
        END;
        elapsed_ms := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
        RETURN NEXT;
    END LOOP;
END;
$$;

SELECT server_name, foreign_table, connection_status, row_count FROM analytics.test_foreign_connections();

-- Cached remote connections held by THIS session (one per server + user mapping)
SELECT server_name, valid FROM postgres_fdw_get_connections() ORDER BY 1;

-- The remote side sees an ordinary client session tagged with our application_name
SELECT datname, usename, application_name, state
FROM pg_stat_activity
WHERE application_name = 'postgres_fdw_polaris'
ORDER BY pid
LIMIT 3;

-- Close cached connections (e.g. after changing server options or credentials)
SELECT postgres_fdw_disconnect_all() AS disconnected;

-- Clean-up commands (not run, so the demo objects stay available):
--   DROP SCHEMA fdw_remote CASCADE;
--   DROP USER MAPPING FOR CURRENT_USER SERVER polaris_loopback;
--   DROP SERVER polaris_loopback;
--   -- and in polaris_test:  DROP SCHEMA fdw_demo CASCADE;
