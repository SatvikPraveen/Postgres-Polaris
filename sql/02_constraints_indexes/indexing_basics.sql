-- File: sql/02_constraints_indexes/indexing_basics.sql
-- Purpose: B-tree, Hash, GIN, GiST, BRIN indexes - when to use each, and
--          EXPLAIN evidence that the planner actually picks them.
--
-- Idempotent: every CREATE uses IF NOT EXISTS / OR REPLACE, so the file can be
-- re-run safely. Standalone: depends only on the base schemas + data.
--
-- NOTE on index names: the schema files (sql/01_schema_design/*) already create
-- a set of indexes (idx_citizens_name, idx_orders_date, idx_pois_active, ...).
-- IF NOT EXISTS only checks the *name*, not the definition, so the indexes in
-- this lesson use distinct names to avoid silently "re-using" a different index.

\echo '== indexing_basics: creating lesson indexes =='

-- pg_trgm is used for the trigram GiST/GIN examples below
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- =============================================================================
-- B-TREE INDEXES (default - equality, range, sorting, prefix LIKE with C collation)
-- =============================================================================

-- Single column B-tree indexes
CREATE INDEX IF NOT EXISTS idx_citizens_last_name_btree ON civics.citizens USING btree(last_name);
CREATE INDEX IF NOT EXISTS idx_orders_order_date_btree ON commerce.orders USING btree(order_date);
CREATE INDEX IF NOT EXISTS idx_trips_start_time_btree ON mobility.trip_segments USING btree(start_time);

-- Multi-column B-tree indexes (column order matters: the index serves queries
-- that constrain a LEFT-MOST prefix of the columns; PG 18 adds skip scan, but on
-- PG 17 a predicate on only the 2nd column generally cannot use the index well)
CREATE INDEX IF NOT EXISTS idx_tax_citizen_year_btree ON civics.tax_payments USING btree(citizen_id, tax_year);
CREATE INDEX IF NOT EXISTS idx_permits_type_status_btree ON civics.permit_applications USING btree(permit_type, status);
CREATE INDEX IF NOT EXISTS idx_orders_merchant_date_btree ON commerce.orders USING btree(merchant_id, order_date DESC);

-- B-tree with DESC: a single-column index can be scanned backwards, so DESC
-- matters mainly for multi-column indexes with MIXED directions
-- (e.g. ORDER BY merchant_id, order_date DESC above).
CREATE INDEX IF NOT EXISTS idx_complaints_submitted_desc ON documents.complaint_records USING btree(submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_sensors_time_desc ON mobility.sensor_readings USING btree(reading_time DESC);

-- =============================================================================
-- HASH INDEXES (equality only; WAL-logged and crash-safe since PostgreSQL 10)
-- =============================================================================

-- Hash indexes store only a 4-byte hash per key, so they can be smaller than a
-- B-tree for long keys (emails, codes). They cannot support ranges, ORDER BY,
-- uniqueness constraints, or multi-column keys.
CREATE INDEX IF NOT EXISTS idx_citizens_email_hash ON civics.citizens USING hash(email);
CREATE INDEX IF NOT EXISTS idx_merchants_tax_id_hash ON commerce.merchants USING hash(tax_id);
CREATE INDEX IF NOT EXISTS idx_stations_code_hash ON mobility.stations USING hash(station_code);
CREATE INDEX IF NOT EXISTS idx_permits_number_hash ON civics.permit_applications USING hash(permit_number);

-- Hash indexes on low-cardinality enums are usually a POOR choice: with only a
-- handful of distinct values each bucket holds thousands of rows. Kept here as
-- a counter-example; compare its size with the B-tree idx_orders_status later.
CREATE INDEX IF NOT EXISTS idx_orders_status_hash ON commerce.orders USING hash(status);
CREATE INDEX IF NOT EXISTS idx_complaints_priority_hash ON documents.complaint_records USING hash(priority_level);

-- =============================================================================
-- GIN INDEXES (Generalized Inverted Index - JSONB, arrays, full-text, trigrams)
-- =============================================================================

-- JSONB containment (@>, ?, ?|, ?&) on whole documents
CREATE INDEX IF NOT EXISTS idx_complaints_metadata_gin ON documents.complaint_records USING gin(metadata);
CREATE INDEX IF NOT EXISTS idx_policies_content_gin ON documents.policy_documents USING gin(document_content);

-- Trigram GIN on an expression: supports ILIKE '%term%' over two text columns.
-- (A plain GIN on text would only do equality via btree_gin - useless here.)
CREATE INDEX IF NOT EXISTS idx_orders_customer_details_gin ON commerce.orders
    USING gin((COALESCE(delivery_address, '') || ' ' || COALESCE(order_notes, '')) gin_trgm_ops);

-- Array indexes (@>, &&, <@)
CREATE INDEX IF NOT EXISTS idx_pois_services_gin ON geo.points_of_interest USING gin(services_offered);
CREATE INDEX IF NOT EXISTS idx_pois_accessibility_gin ON geo.points_of_interest USING gin(accessibility_features);
CREATE INDEX IF NOT EXISTS idx_policies_tags_gin ON documents.policy_documents USING gin(tags);

-- Full-text search indexes already exist on search_vector (idx_complaints_search,
-- idx_policies_search, created in documents.sql).

-- JSONB path-specific indexes: smaller, and jsonb_path_ops is ~2-3x smaller than
-- the default jsonb_ops but supports only @> / @? / @@.
CREATE INDEX IF NOT EXISTS idx_complaints_metadata_category_gin ON documents.complaint_records USING gin((metadata->'category'));
CREATE INDEX IF NOT EXISTS idx_pois_hours_gin ON geo.points_of_interest USING gin(business_hours jsonb_path_ops);

-- =============================================================================
-- GiST INDEXES (Generalized Search Tree - geometry, ranges, nearest-neighbour)
-- =============================================================================

-- PostGIS spatial GiST indexes already exist (idx_neighborhoods_geom,
-- idx_roads_geom, idx_pois_geom - see sql/01_schema_design/geo.sql).

-- Range indexes using GiST (supports && overlap, @> containment)
CREATE INDEX IF NOT EXISTS idx_permits_date_range_gist ON civics.permit_applications
    USING gist(tstzrange(application_date, expiration_date));

CREATE INDEX IF NOT EXISTS idx_licenses_validity_range_gist ON commerce.business_licenses
    USING gist(daterange(issue_date, expiration_date));

-- Text similarity using GiST trigrams (fuzzy matching, % operator, <-> KNN ordering)
CREATE INDEX IF NOT EXISTS idx_citizens_name_similarity_gist ON civics.citizens
    USING gist((first_name || ' ' || last_name) gist_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_merchants_name_similarity_gist ON commerce.merchants
    USING gist(business_name gist_trgm_ops);

-- =============================================================================
-- BRIN INDEXES (Block Range INdex - tiny, for physically ordered data)
-- =============================================================================

-- BRIN stores min/max per block range. It only helps when the column is
-- correlated with physical row order. Check pg_stats.correlation first:
\echo '-- BRIN suitability: correlation close to +/-1 is good, near 0 is useless'
SELECT schemaname, tablename, attname, round(correlation::numeric, 3) AS correlation
FROM pg_stats
WHERE (schemaname, tablename, attname) IN (
    ('mobility', 'sensor_readings', 'reading_time'),
    ('mobility', 'station_inventory', 'recorded_at'),
    ('mobility', 'trip_segments', 'start_time'),
    ('documents', 'complaint_records', 'submitted_at'),
    ('civics', 'citizens', 'citizen_id'),
    ('commerce', 'orders', 'order_id'))
ORDER BY abs(correlation) DESC, tablename;

-- sensor_readings is append-only in time order (correlation = 1): ideal for BRIN
CREATE INDEX IF NOT EXISTS idx_sensors_time_brin ON mobility.sensor_readings USING brin(reading_time);

-- minmax_multi (PG 14+) keeps several min/max intervals per range, so a few
-- out-of-order rows (late-arriving readings) don't destroy selectivity.
CREATE INDEX IF NOT EXISTS idx_sensors_time_brin_multi ON mobility.sensor_readings
    USING brin(reading_time timestamptz_minmax_multi_ops) WITH (pages_per_range = 32);

-- BRIN on a serial key that is inserted in order
CREATE INDEX IF NOT EXISTS idx_citizens_id_brin ON civics.citizens USING brin(citizen_id);

-- Counter-examples: these columns are NOT physically ordered in this dataset
-- (correlation ~ 0 above), so each block range spans the whole time domain and
-- the BRIN index cannot exclude anything. Created so you can see the plan
-- ignore them; prefer B-tree here or CLUSTER the table first.
CREATE INDEX IF NOT EXISTS idx_inventory_time_brin ON mobility.station_inventory USING brin(recorded_at);
CREATE INDEX IF NOT EXISTS idx_trips_time_brin_256 ON mobility.trip_segments
    USING brin(start_time) WITH (pages_per_range = 256);   -- default pages_per_range is 128

-- =============================================================================
-- SPECIALIZED INDEX PATTERNS
-- =============================================================================

-- Covering indexes (INCLUDE, PG 11+) enable index-only scans for extra columns
CREATE INDEX IF NOT EXISTS idx_citizens_email_covering ON civics.citizens(email)
    INCLUDE (first_name, last_name, phone);

CREATE INDEX IF NOT EXISTS idx_orders_merchant_covering ON commerce.orders(merchant_id, order_date)
    INCLUDE (status, total_amount, customer_citizen_id);

-- Partial indexes: index only the rows queries care about (small + hot)
CREATE INDEX IF NOT EXISTS idx_permits_pending ON civics.permit_applications(application_date)
    WHERE status = 'pending';

-- order_status values: pending, confirmed, processing, shipped, delivered, cancelled, refunded
CREATE INDEX IF NOT EXISTS idx_orders_incomplete ON commerce.orders(merchant_id, order_date)
    WHERE status IN ('pending', 'confirmed', 'processing', 'shipped');

CREATE INDEX IF NOT EXISTS idx_complaints_unresolved ON documents.complaint_records(priority_level, submitted_at)
    WHERE status NOT IN ('resolved', 'archived', 'rejected');

-- (geo.sql already owns an index called idx_pois_active, hence the longer name)
CREATE INDEX IF NOT EXISTS idx_pois_active_category_nbhd ON geo.points_of_interest(category, neighborhood_id)
    WHERE is_active = true;

-- Expression indexes: the query must use the SAME expression to match
CREATE INDEX IF NOT EXISTS idx_citizens_name_lower ON civics.citizens(lower(last_name), lower(first_name));
CREATE INDEX IF NOT EXISTS idx_merchants_name_lower ON commerce.merchants(lower(business_name));

-- Index expressions and predicates must be IMMUTABLE. "Age in days" computed
-- from CURRENT_TIMESTAMP/now() changes every second, so it can NEVER be indexed:
--   CREATE INDEX ... ((EXTRACT(EPOCH FROM (now() - submitted_at))/86400)::int)  -- ERROR
-- Instead index the stored timestamp (idx_complaints_unresolved above already
-- contains submitted_at for open complaints) and compare it with a computed
-- cutoff: the cutoff is evaluated once per query, the index stays stable.

-- Refresh planner statistics so the EXPLAIN demos below are representative
ANALYZE civics.citizens, commerce.orders, commerce.merchants, documents.complaint_records,
        documents.policy_documents, geo.points_of_interest, mobility.sensor_readings,
        mobility.station_inventory, civics.permit_applications;

-- =============================================================================
-- EXPLAIN EVIDENCE: does the planner use the indexes?
-- (COSTS OFF keeps output stable across runs; look for "Index Scan",
--  "Index Only Scan", "Bitmap Index Scan" and the index name.)
-- =============================================================================

\echo '-- B-tree equality + ORDER BY on a multi-column index (expect idx_orders_merchant_date_btree / covering)'
EXPLAIN (COSTS OFF)
SELECT order_id, order_date, total_amount
FROM commerce.orders
WHERE merchant_id = 42
ORDER BY order_date DESC
LIMIT 10;

\echo '-- Covering index -> Index Only Scan (Heap Fetches: 0 after VACUUM sets the visibility map)'
VACUUM (ANALYZE) civics.citizens;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT first_name, last_name, phone
FROM civics.citizens
WHERE email = 'michelle.roberts.1@mail.polaris.example';

\echo '-- Expression index: lower(last_name) matches idx_citizens_name_lower'
EXPLAIN (COSTS OFF)
SELECT citizen_id, first_name, last_name
FROM civics.citizens
WHERE lower(last_name) = 'walker' AND lower(first_name) = 'mateo';

\echo '-- Hash index: equality only'
EXPLAIN (COSTS OFF)
SELECT merchant_id, business_name FROM commerce.merchants WHERE tax_id = '75-0000001';

\echo '-- GIN JSONB containment'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM documents.complaint_records WHERE metadata @> '{"category": "graffiti"}';

\echo '-- GIN array overlap'
EXPLAIN (COSTS OFF)
SELECT poi_id, name FROM geo.points_of_interest
WHERE accessibility_features @> ARRAY['braille_signage']::text[];

\echo '-- Trigram GiST KNN: nearest names by similarity (<-> distance operator)'
EXPLAIN (COSTS OFF)
SELECT business_name FROM commerce.merchants
ORDER BY business_name <-> 'Golden Markt'
LIMIT 5;

\echo '-- Partial index: the WHERE clause must imply the index predicate'
EXPLAIN (COSTS OFF)
SELECT permit_id, application_date FROM civics.permit_applications
WHERE status = 'pending' AND application_date >= meta.as_of() - interval '365 days';

\echo '-- Recency query against the open-complaints partial index (use meta.as_of(), not now())'
EXPLAIN (COSTS OFF)
SELECT complaint_id, submitted_at FROM documents.complaint_records
WHERE status NOT IN ('resolved', 'archived', 'rejected')
  AND submitted_at < meta.as_of() - interval '30 days';

-- With a B-tree on reading_time available the planner prefers it (it is more
-- precise). To see the BRIN plan, hide the B-trees inside a transaction that is
-- rolled back (DROP INDEX is transactional in PostgreSQL - nothing is lost).
\echo '-- B-tree available: planner picks the B-tree'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM mobility.sensor_readings
WHERE reading_time >= meta.as_of() - interval '1 day';

\echo '-- BRIN on a perfectly correlated column: Bitmap Index Scan, few heap blocks read'
BEGIN;
-- (every B-tree containing reading_time, incl. composite ones the planner can
--  still walk, plus the minmax_multi BRIN so the plain one is chosen)
DROP INDEX mobility.idx_sensors_time_desc, mobility.idx_sensors_time_only,
           mobility.idx_sensors_type_time, mobility.idx_sensors_code_time,
           mobility.idx_sensors_time_brin_multi;
-- (SELECT meta.as_of()) becomes an InitPlan evaluated once; a bare STABLE
-- function call would be re-evaluated for every row in the lossy recheck.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT round(avg(reading_value), 2) FROM mobility.sensor_readings
WHERE reading_time >= (SELECT meta.as_of()) - interval '1 day';
ROLLBACK;

-- Same query, B-tree vs BRIN sizes: BRIN is orders of magnitude smaller
\echo '-- Index sizes: B-tree vs BRIN vs Hash on comparable columns'
SELECT c.relname AS index_name, am.amname AS method, pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_am am ON am.oid = c.relam
WHERE c.relname IN ('idx_sensors_time_desc', 'idx_sensors_time_brin', 'idx_sensors_time_brin_multi',
                    'idx_orders_status', 'idx_orders_status_hash',
                    'idx_citizens_email', 'idx_citizens_email_hash')
ORDER BY c.relname;

-- =============================================================================
-- INDEX MONITORING VIEWS
-- pg_stat_user_indexes columns are relname (table) and indexrelname (index);
-- "tablename"/"indexname" exist only in pg_indexes / pg_tables.
-- =============================================================================

-- View index usage statistics (last_idx_scan is new in PG 16)
DROP VIEW IF EXISTS analytics.index_usage_stats;
CREATE VIEW analytics.index_usage_stats AS
SELECT
    schemaname,
    relname       AS table_name,
    indexrelname  AS index_name,
    idx_scan      AS scans,
    last_idx_scan,
    idx_tup_read  AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents');

COMMENT ON VIEW analytics.index_usage_stats IS 'Per-index scan counts and size for the domain schemas';

-- Find unused indexes (excluding indexes that back constraints - those are
-- needed for correctness even if never scanned)
DROP VIEW IF EXISTS analytics.unused_indexes;
CREATE VIEW analytics.unused_indexes AS
SELECT
    s.schemaname,
    s.relname      AS table_name,
    s.indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
    pg_relation_size(s.indexrelid) AS size_bytes
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
  AND s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid);

COMMENT ON VIEW analytics.unused_indexes IS 'Never-scanned, non-constraint indexes (candidates for removal)';

-- Index bloat: the old "size / tuples inserted" ratio was meaningless. For a
-- real measurement use pgstattuple's pgstatindex() on B-tree indexes:
-- avg_leaf_density well below the fillfactor (90) and high leaf_fragmentation
-- indicate bloat that REINDEX CONCURRENTLY would recover.
CREATE EXTENSION IF NOT EXISTS pgstattuple;

DROP VIEW IF EXISTS analytics.index_bloat_estimate;
CREATE VIEW analytics.index_bloat_estimate AS
SELECT
    s.schemaname,
    s.relname      AS table_name,
    s.indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS current_size,
    st.avg_leaf_density,
    st.leaf_fragmentation
FROM pg_stat_user_indexes s
JOIN pg_class c ON c.oid = s.indexrelid
JOIN pg_am am ON am.oid = c.relam AND am.amname = 'btree'
CROSS JOIN LATERAL pgstatindex(s.indexrelid) st
WHERE s.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents');

COMMENT ON VIEW analytics.index_bloat_estimate IS 'B-tree leaf density/fragmentation via pgstatindex()';

\echo '-- Bloat check for orders B-tree indexes'
SELECT index_name, current_size, avg_leaf_density, leaf_fragmentation
FROM analytics.index_bloat_estimate
WHERE table_name = 'orders'
ORDER BY index_name
LIMIT 10;

-- Statistics are accumulated in backend memory and flushed to shared memory at
-- most once per second (PG 15+). pg_stat_force_next_flush() makes the next
-- transaction end flush them, so the counters below are up to date.
SELECT pg_stat_force_next_flush();

\echo '-- Usage stats for indexes used by the EXPLAIN ANALYZE demos above'
SELECT table_name, index_name, scans > 0 AS was_scanned, size
FROM analytics.index_usage_stats
WHERE index_name IN ('idx_citizens_email_covering', 'idx_citizens_email', 'idx_sensors_time_brin',
                     'idx_sensors_time_brin_multi')
ORDER BY index_name;

-- =============================================================================
-- INDEX MAINTENANCE FUNCTIONS
-- =============================================================================

-- Reindex all tables in a schema. A function runs inside a transaction, so it
-- can only use plain REINDEX (takes locks that block writes). In production run
-- "REINDEX TABLE CONCURRENTLY schema.table" (PG 12+) from psql instead - it is
-- not allowed inside a transaction block / function.
CREATE OR REPLACE FUNCTION analytics.reindex_schema(schema_name TEXT)
RETURNS TEXT AS $$
DECLARE
    table_rec RECORD;
    result_text TEXT := '';
BEGIN
    FOR table_rec IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = schema_name
        ORDER BY tablename
    LOOP
        EXECUTE format('REINDEX TABLE %I.%I', schema_name, table_rec.tablename);
        result_text := result_text || 'Reindexed ' || schema_name || '.' || table_rec.tablename || E'\n';
    END LOOP;

    RETURN result_text;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.reindex_schema(TEXT) IS
'Plain REINDEX of every table in a schema (blocking; prefer REINDEX CONCURRENTLY from psql)';

-- Analyze index usage efficiency (scans per MB of index)
-- DROP first so a differently-shaped version from another module can't block us
DROP FUNCTION IF EXISTS analytics.analyze_index_effectiveness();
CREATE FUNCTION analytics.analyze_index_effectiveness()
RETURNS TABLE(
    schema_table TEXT,
    index_name TEXT,
    scans_per_mb NUMERIC,
    effectiveness_score TEXT
) AS $$
    WITH s AS (
        SELECT pui.schemaname, pui.relname, pui.indexrelname, pui.idx_scan,
               NULLIF(pg_relation_size(pui.indexrelid), 0) / 1024.0 / 1024.0 AS size_mb
        FROM pg_stat_user_indexes pui
        WHERE pui.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    )
    SELECT
        (s.schemaname || '.' || s.relname)::TEXT,
        s.indexrelname::TEXT,
        COALESCE(ROUND(s.idx_scan / s.size_mb, 2), 0),
        CASE
            WHEN s.idx_scan = 0 THEN 'UNUSED'
            WHEN s.idx_scan / s.size_mb > 100 THEN 'EXCELLENT'
            WHEN s.idx_scan / s.size_mb > 10 THEN 'GOOD'
            WHEN s.idx_scan / s.size_mb > 1 THEN 'FAIR'
            ELSE 'POOR'
        END
    FROM s
    ORDER BY 3 DESC NULLS LAST, 1, 2;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION analytics.analyze_index_effectiveness() IS
'Analyze index usage patterns and provide effectiveness scoring';

\echo '-- Top 5 indexes by scans per MB'
SELECT * FROM analytics.analyze_index_effectiveness() LIMIT 5;
