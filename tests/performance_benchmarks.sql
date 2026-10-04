-- Location: /tests/performance_benchmarks.sql
-- =============================================================================
-- PERFORMANCE BENCHMARKS (report, not pass/fail)
-- =============================================================================
-- What it teaches:
--   * how to read EXPLAIN (ANALYZE, BUFFERS) for representative workload shapes
--     (PK lookup, range scan, join + aggregate, window, time series, full-text,
--     JSONB containment, KNN, geodesic radius, spatial join, anti-join),
--   * how to turn EXPLAIN (FORMAT JSON) into a compact, comparable benchmark
--     table (best-of-N execution time, plan root, buffer hits/reads, target),
--   * where to look next: pg_stat_statements, index usage, cache hit ratios.
--
-- Timings depend on hardware and cache state, so this script never fails on a
-- slow query: it REPORTS whether each query met its target. Correctness lives
-- in the pgTAP suites (schema_validation / data_integrity_checks /
-- regression_tests).
--
-- Recency windows are anchored on meta.as_of() (the dataset's "now"), not now():
-- the generated data ends on 2025-12-31.
--
-- Run: psql -X -v ON_ERROR_STOP=1 -d <db> -f /tests/performance_benchmarks.sql
-- Read-only: creates only a temporary function.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== Performance benchmarks ==='
SELECT current_database() AS database, version() AS server, meta.as_of() AS dataset_as_of;

-- Fresh planner statistics make the plans below representative.
ANALYZE civics.citizens, commerce.orders, commerce.merchants, commerce.order_items,
        mobility.sensor_readings, mobility.stations, documents.complaint_records,
        documents.policy_documents, geo.points_of_interest, geo.neighborhood_boundaries;

-- -----------------------------------------------------------------------------
-- 1. Full plans for four archetypal queries
--    BUFFERS: shared hit = page found in shared_buffers, read = fetched from
--    the OS/disk. SERIALIZE (PG17) also measures the cost of producing the
--    output rows for the client.
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- 1a. Primary-key lookup (expect Index Scan on citizens_pkey, < 1 ms) ---'
EXPLAIN (ANALYZE, BUFFERS, SERIALIZE, COSTS OFF)
SELECT citizen_id, first_name, last_name, email FROM civics.citizens WHERE citizen_id = 4242;

\echo ''
\echo '--- 1b. Last 7 days of orders (expect Index/Bitmap scan on idx_orders_date) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), sum(total_amount)
FROM commerce.orders
WHERE order_date >= meta.as_of() - interval '7 days';

\echo ''
\echo '--- 1c. Full-text search (expect Bitmap Index Scan on GIN idx_complaints_search) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT complaint_id, subject
FROM documents.complaint_records
WHERE search_vector @@ to_tsquery('english', 'power & outage')
ORDER BY submitted_at DESC
LIMIT 10;

\echo ''
\echo '--- 1d. KNN: 5 nearest POIs (expect Index Scan using GiST idx_pois_geom with ORDER BY <->) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT poi_id, name,
       round(ST_Distance(location_geom::geography,
                         ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)::geography)) AS metres
FROM geo.points_of_interest
ORDER BY location_geom <-> ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)
LIMIT 5;

-- -----------------------------------------------------------------------------
-- 2. Benchmark table: every query runs N times; best execution time is kept.
--    pg_temp.bench() parses EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.bench(label text, q text, target numeric, runs int DEFAULT 3)
RETURNS TABLE (benchmark text, plan_root text, rows_out bigint, best_ms numeric,
               planning_ms numeric, shared_hit bigint, shared_read bigint,
               target_ms numeric, verdict text)
LANGUAGE plpgsql AS $$
DECLARE
    j json;
    t numeric;
    i int;
BEGIN
    benchmark := label;
    target_ms := target;
    best_ms := NULL;
    FOR i IN 1..runs LOOP
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || q INTO j;
        t := (j->0->>'Execution Time')::numeric;
        IF best_ms IS NULL OR t < best_ms THEN
            best_ms     := round(t, 3);
            planning_ms := round((j->0->>'Planning Time')::numeric, 3);
            plan_root   := j->0->'Plan'->>'Node Type';
            rows_out    := round((j->0->'Plan'->>'Actual Rows')::numeric)::bigint;  -- PG 18 emits decimals
            shared_hit  := (j->0->'Plan'->>'Shared Hit Blocks')::bigint;
            shared_read := (j->0->'Plan'->>'Shared Read Blocks')::bigint;
        END IF;
    END LOOP;
    verdict := CASE WHEN best_ms <= target THEN 'ok' ELSE 'SLOW' END;
    RETURN NEXT;
END $$;

\echo ''
\echo '--- 2. Benchmark summary (best of 3 runs; verdict compares with target) ---'
SELECT * FROM (
          SELECT * FROM pg_temp.bench('01 PK lookup (citizens)',
              $q$SELECT * FROM civics.citizens WHERE citizen_id = 4242$q$, 1)
UNION ALL SELECT * FROM pg_temp.bench('02 unique email lookup',
              $q$SELECT citizen_id FROM civics.citizens
                 WHERE email = (SELECT email FROM civics.citizens WHERE citizen_id = 777)$q$, 1)
UNION ALL SELECT * FROM pg_temp.bench('03 orders, last 7 days',
              $q$SELECT count(*), sum(total_amount) FROM commerce.orders
                 WHERE order_date >= meta.as_of() - interval '7 days'$q$, 10)
UNION ALL SELECT * FROM pg_temp.bench('04 revenue by business type, 30 d',
              $q$SELECT m.business_type, count(*), sum(o.total_amount)
                 FROM commerce.orders o JOIN commerce.merchants m USING (merchant_id)
                 WHERE o.order_date >= meta.as_of() - interval '30 days'
                 GROUP BY m.business_type$q$, 50)
UNION ALL SELECT * FROM pg_temp.bench('05 window: top merchant per type',
              $q$SELECT * FROM (
                   SELECT m.business_type, m.merchant_id, sum(o.total_amount) AS revenue,
                          rank() OVER (PARTITION BY m.business_type ORDER BY sum(o.total_amount) DESC) AS rk
                   FROM commerce.orders o JOIN commerce.merchants m USING (merchant_id)
                   GROUP BY m.business_type, m.merchant_id) s WHERE rk = 1$q$, 200)
UNION ALL SELECT * FROM pg_temp.bench('06 sensor hourly avg, 24 h',
              $q$SELECT date_trunc('hour', reading_time) AS h, avg(reading_value)
                 FROM mobility.sensor_readings
                 WHERE sensor_code = 'AQI-001' AND reading_time >= meta.as_of() - interval '24 hours'
                 GROUP BY 1 ORDER BY 1$q$, 10)
UNION ALL SELECT * FROM pg_temp.bench('07 full-text (GIN tsvector)',
              $q$SELECT complaint_id FROM documents.complaint_records
                 WHERE search_vector @@ to_tsquery('english', 'power & outage')$q$, 20)
UNION ALL SELECT * FROM pg_temp.bench('08 JSONB containment (GIN)',
              $q$SELECT count(*) FROM documents.complaint_records
                 WHERE metadata @> '{"category": "utilities", "utility_type": "power"}'$q$, 20)
UNION ALL SELECT * FROM pg_temp.bench('09 KNN 5 nearest POIs (GiST)',
              $q$SELECT poi_id FROM geo.points_of_interest
                 ORDER BY location_geom <-> ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326) LIMIT 5$q$, 5)
UNION ALL SELECT * FROM pg_temp.bench('10 geodesic radius: POIs in 1 km',
              $q$SELECT count(*) FROM geo.points_of_interest
                 WHERE ST_DWithin(location_geom::geography,
                                  ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)::geography, 1000)$q$, 20)
UNION ALL SELECT * FROM pg_temp.bench('11 spatial join: complaints per hood',
              $q$SELECT n.neighborhood_name, count(*)
                 FROM geo.neighborhood_boundaries n
                 JOIN documents.complaint_records c
                   ON ST_Covers(n.boundary_geom, ST_SetSRID(ST_MakePoint(c.incident_longitude, c.incident_latitude), 4326))
                 GROUP BY 1$q$, 300)
UNION ALL SELECT * FROM pg_temp.bench('12 anti-join: merchants idle 30 d',
              $q$SELECT m.merchant_id FROM commerce.merchants m
                 WHERE NOT EXISTS (SELECT 1 FROM commerce.orders o
                                   WHERE o.merchant_id = m.merchant_id
                                     AND o.order_date >= meta.as_of() - interval '30 days')$q$, 50)
) b
ORDER BY benchmark;

-- -----------------------------------------------------------------------------
-- 3. Where the time goes: workload statistics
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- 3a. Top statements by mean time (pg_stat_statements, if loaded) ---'
DO $$
DECLARE rec record;
BEGIN
    IF to_regclass('public.pg_stat_statements') IS NULL THEN
        RAISE NOTICE 'pg_stat_statements is not installed in this database - skipped';
        RETURN;
    END IF;
    FOR rec IN EXECUTE $q$
        SELECT round(mean_exec_time::numeric, 2) AS avg_ms, calls,
               left(regexp_replace(query, '\s+', ' ', 'g'), 70) AS q
        FROM pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) AND calls > 1
        ORDER BY mean_exec_time DESC LIMIT 5 $q$
    LOOP
        RAISE NOTICE '  % ms x % : %', rec.avg_ms, rec.calls, rec.q;
    END LOOP;
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'pg_stat_statements is not in shared_preload_libraries - skipped';
END $$;

\echo ''
\echo '--- 3b. Index usage on the domain schemas (least used first) ---'
SELECT schemaname, relname AS table_name, indexrelname AS index_name, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       CASE WHEN idx_scan = 0 THEN 'unused' WHEN idx_scan < 10 THEN 'low' ELSE 'active' END AS usage
FROM pg_stat_user_indexes
WHERE schemaname IN ('civics','commerce','mobility','geo','documents')
ORDER BY idx_scan, pg_relation_size(indexrelid) DESC
LIMIT 10;

\echo ''
\echo '--- 3c. Table size, dead tuples and cache hit ratio ---'
SELECT s.schemaname, s.relname AS table_name, s.n_live_tup, s.n_dead_tup,
       pg_size_pretty(pg_total_relation_size(s.relid)) AS total_size,
       round(100.0 * io.heap_blks_hit / nullif(io.heap_blks_hit + io.heap_blks_read, 0), 1) AS cache_hit_pct
FROM pg_stat_user_tables s
JOIN pg_statio_user_tables io USING (relid)
WHERE s.schemaname IN ('civics','commerce','mobility','geo','documents')
ORDER BY pg_total_relation_size(s.relid) DESC
LIMIT 10;

\echo ''
\echo '--- 3d. I/O by backend type (pg_stat_io, PG16+) ---'
SELECT backend_type, object, context, reads, hits, writes
FROM pg_stat_io
WHERE coalesce(reads, 0) + coalesce(hits, 0) + coalesce(writes, 0) > 0
ORDER BY coalesce(hits, 0) + coalesce(reads, 0) DESC
LIMIT 8;

\echo ''
\echo '--- 3e. Configuration that shapes these numbers ---'
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'effective_cache_size', 'random_page_cost',
               'effective_io_concurrency', 'max_parallel_workers_per_gather', 'jit')
ORDER BY name;

-- Targets used above (rules of thumb on a laptop, warm cache):
--   PK / unique lookups < 1 ms, KNN < 5 ms, indexed range / FTS / JSONB < 10-20 ms,
--   join + aggregate over a month < 50 ms, whole-table window / spatial join < 300 ms.
\echo ''
\echo 'Performance benchmarks completed (verdicts are informational; see pgTAP suites for correctness).'
