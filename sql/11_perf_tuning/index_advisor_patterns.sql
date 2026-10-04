-- File: sql/11_perf_tuning/index_advisor_patterns.sql
-- Purpose: Index hygiene and advice: unused, duplicate/redundant and missing
--          foreign-key indexes from the catalogs and statistics views, then
--          "what if" analysis with HypoPG (hypothetical indexes, hidden indexes)
--          before building anything, and covering-index checks.
--
-- Idempotent and non-destructive: advisor functions only RETURN DDL text. The one
-- real index built for validation is created inside a transaction that is rolled back.
-- HypoPG objects live only in this session's memory and are reset at the end.
--
-- Caveat for every usage-based rule: pg_stat_user_indexes counters start at zero
-- after a stats reset, a crash, or (as in this lab) when the database is cloned
-- from a template. "Never scanned" is only meaningful after a representative
-- period of production traffic, and must be checked on every replica too.

-- Older revisions of this file created functions with other result shapes.
DROP FUNCTION IF EXISTS analytics.detect_unused_indexes();
DROP FUNCTION IF EXISTS analytics.detect_redundant_indexes();
DROP FUNCTION IF EXISTS analytics.comprehensive_index_advisor();
DROP FUNCTION IF EXISTS analytics.analyze_index_selectivity();
DROP FUNCTION IF EXISTS analytics.identify_covering_opportunities();
DROP FUNCTION IF EXISTS analytics.generate_index_maintenance_plan();
DROP FUNCTION IF EXISTS analytics.execute_index_recommendations(boolean, text);

-- =============================================================================
-- 1. UNUSED INDEXES
-- =============================================================================
\echo '== 1. Unused indexes'

CREATE OR REPLACE FUNCTION analytics.detect_unused_indexes(p_min_bytes bigint DEFAULT 0)
RETURNS TABLE (index_name text, table_name text, index_size text, idx_scan bigint,
               last_idx_scan timestamptz, recommendation text, suggested_ddl text)
LANGUAGE sql STABLE AS $$
    SELECT s.schemaname || '.' || s.indexrelname,
           s.schemaname || '.' || s.relname,
           pg_size_pretty(pg_relation_size(s.indexrelid)),
           s.idx_scan,
           s.last_idx_scan,                                    -- PG16+
           CASE WHEN s.idx_scan = 0 THEN 'never scanned since stats reset: candidate to drop'
                ELSE 'rarely scanned: review' END,
           format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I;', s.schemaname, s.indexrelname)
    FROM pg_stat_user_indexes s
    JOIN pg_index i ON i.indexrelid = s.indexrelid
    WHERE s.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
      AND NOT i.indisunique            -- unique/PK indexes enforce constraints even if never scanned
      AND NOT i.indisexclusion         -- so do exclusion constraints
      AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid)
      AND s.idx_scan < 10
      AND pg_relation_size(s.indexrelid) >= p_min_bytes;
$$;
COMMENT ON FUNCTION analytics.detect_unused_indexes(bigint) IS
'Non-constraint indexes with fewer than 10 scans since the last stats reset, with DROP INDEX CONCURRENTLY DDL.';

-- How long have the counters been collecting? (NULL = never reset since the
-- database was created or the server last crashed: on this fresh clone, minutes.)
SELECT s.stats_reset AS index_stats_since, now() - s.stats_reset AS observation_window
FROM pg_stat_database s WHERE s.datname = current_database();

SELECT index_name, index_size, idx_scan, recommendation
FROM analytics.detect_unused_indexes()
ORDER BY pg_relation_size(index_name::regclass) DESC, index_name
LIMIT 8;

-- =============================================================================
-- 2. DUPLICATE AND REDUNDANT INDEXES
-- =============================================================================
\echo '== 2. Duplicate and redundant (prefix) indexes'

-- Exact duplicate: same table, access method, key columns, opclasses, collations,
-- expressions and predicate. Prefix-redundant: a non-unique btree whose keys are a
-- leading prefix of another btree on the same table (with the same predicate).
CREATE OR REPLACE FUNCTION analytics.detect_redundant_indexes()
RETURNS TABLE (table_name text, redundant_index text, covered_by text,
               redundant_def text, covering_def text, kind text, suggested_ddl text)
LANGUAGE sql STABLE AS $$
    WITH idx AS (
        SELECT i.indexrelid, i.indrelid, c.relam, i.indisunique, i.indisprimary,
               i.indkey::int2[]           AS keys,
               i.indclass::oid[]          AS opclasses,
               i.indcollation::oid[]      AS collations,
               i.indnkeyatts,
               COALESCE(pg_get_expr(i.indexprs, i.indrelid), '') AS exprs,
               COALESCE(pg_get_expr(i.indpred,  i.indrelid), '') AS pred,
               (SELECT conname FROM pg_constraint k WHERE k.conindid = i.indexrelid LIMIT 1) AS constraint_name
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    )
    -- one row per redundant index, naming the strongest index that covers it
    SELECT DISTINCT ON (a.indexrelid)
           a.indrelid::regclass::text,
           a.indexrelid::regclass::text,
           b.indexrelid::regclass::text,
           pg_get_indexdef(a.indexrelid),
           pg_get_indexdef(b.indexrelid),
           CASE WHEN a.keys = b.keys THEN 'EXACT DUPLICATE' ELSE 'PREFIX REDUNDANT' END,
           CASE WHEN a.constraint_name IS NOT NULL
                THEN format('ALTER TABLE %s DROP CONSTRAINT %I;  -- check dependent FKs first',
                            a.indrelid::regclass, a.constraint_name)
                ELSE format('DROP INDEX CONCURRENTLY IF EXISTS %s;', a.indexrelid::regclass)
           END
    FROM idx a
    JOIN idx b ON b.indrelid = a.indrelid
              AND b.indexrelid <> a.indexrelid
              AND b.relam = a.relam
              AND b.exprs = a.exprs
              AND b.pred  = a.pred
    WHERE a.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
      AND a.exprs = ''
      AND (
            -- exact duplicate: report the "weaker" one (non-unique before unique, then higher oid)
            (a.keys = b.keys AND a.opclasses = b.opclasses AND a.collations = b.collations
             AND (NOT a.indisprimary)
             AND ((b.indisunique AND NOT a.indisunique)
                  OR (a.indisunique = b.indisunique AND (b.indisprimary OR a.indexrelid > b.indexrelid))))
         OR
            -- strict prefix: a's key columns lead b's key columns
            (NOT a.indisunique
             AND a.indnkeyatts < b.indnkeyatts
             AND a.keys[0:a.indnkeyatts - 1] = b.keys[0:a.indnkeyatts - 1]
             AND a.opclasses = b.opclasses[1:a.indnkeyatts])
          )
    ORDER BY a.indexrelid, b.indisprimary DESC, b.indisunique DESC, b.indexrelid;
$$;
COMMENT ON FUNCTION analytics.detect_redundant_indexes() IS
'Exact-duplicate and leading-prefix-redundant btree indexes, with the DDL to remove the weaker one.';

SELECT kind, redundant_index, covered_by, suggested_ddl
FROM analytics.detect_redundant_indexes()
ORDER BY kind, table_name, redundant_index;

-- =============================================================================
-- 3. FOREIGN KEYS WITHOUT A SUPPORTING INDEX
-- =============================================================================
\echo '== 3. Foreign keys without an index on the referencing columns'

-- Without an index on the referencing side, every DELETE/UPDATE of a parent key
-- scans the whole child table (and holds locks meanwhile), and joins from the
-- parent to its children cannot use an index. An index "supports" the FK when its
-- leading key columns are exactly the FK columns (in any order).
CREATE OR REPLACE FUNCTION analytics.detect_missing_fk_indexes()
RETURNS TABLE (table_name text, fk_name text, fk_columns text, referenced_table text,
               child_rows bigint, suggested_ddl text)
LANGUAGE sql STABLE AS $$
    SELECT c.conrelid::regclass::text,
           c.conname,
           (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord)
            FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum),
           c.confrelid::regclass::text,
           greatest(t.reltuples, 0)::bigint,
           format('CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON %s (%s);',
                  left('idx_' || t.relname || '_' ||
                       (SELECT string_agg(a.attname, '_' ORDER BY k.ord)
                        FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
                        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum), 63),
                  c.conrelid::regclass,
                  (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord)
                   FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
                   JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum))
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE c.contype = 'f'
      AND n.nspname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND i.indpred IS NULL
            AND i.indnkeyatts >= cardinality(c.conkey)
            -- the first n key columns, as a set, equal the FK columns
            -- (schema-qualified operators: the intarray extension adds ambiguous ones)
            AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] OPERATOR(pg_catalog.@>) c.conkey
            AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] OPERATOR(pg_catalog.<@) c.conkey);
$$;
COMMENT ON FUNCTION analytics.detect_missing_fk_indexes() IS
'Foreign keys whose referencing columns are not the leading columns of any non-partial index.';

SELECT table_name, fk_columns, referenced_table, child_rows, suggested_ddl
FROM analytics.detect_missing_fk_indexes()
ORDER BY child_rows DESC, table_name, fk_name;

-- =============================================================================
-- 4. TABLES THAT LOOK LIKE THEY NEED AN INDEX (scan statistics)
-- =============================================================================
\echo '== 4. Sequential-scan-heavy tables'

-- High seq_tup_read per seq_scan on a big table usually means a missing index
-- (or a report that legitimately reads everything). pg_stat_statements tells you
-- which queries; HypoPG (next section) tells you whether an index would help.
SELECT schemaname || '.' || relname AS table_name,
       seq_scan, seq_tup_read,
       seq_tup_read / NULLIF(seq_scan, 0) AS avg_rows_per_seq_scan,
       idx_scan,
       pg_size_pretty(pg_table_size(relid)) AS size
FROM pg_stat_user_tables
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
ORDER BY seq_tup_read DESC, table_name
LIMIT 6;

-- =============================================================================
-- 5. HYPOPG: EVALUATE A CANDIDATE INDEX BEFORE BUILDING IT
-- =============================================================================
\echo '== 5. HypoPG what-if analysis'

CREATE EXTENSION IF NOT EXISTS hypopg;
SELECT hypopg_reset();

-- Helper: planner cost and chosen access paths of a query (plain EXPLAIN, which is
-- what HypoPG influences; EXPLAIN ANALYZE would execute without the fake index).
CREATE OR REPLACE FUNCTION analytics.plan_cost(p_sql text)
RETURNS TABLE (total_cost numeric, est_rows numeric, access_paths text)
LANGUAGE plpgsql AS $$
DECLARE
    plan jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || p_sql INTO plan;
    total_cost := (plan -> 0 -> 'Plan' ->> 'Total Cost')::numeric;
    est_rows   := (plan -> 0 -> 'Plan' ->> 'Plan Rows')::numeric;
    SELECT string_agg(DISTINCT (n ->> 'Node Type') || COALESCE(' using ' || (n ->> 'Index Name'), ''), '; ')
    INTO access_paths
    FROM jsonb_path_query(plan, 'strict $.**') AS n
    WHERE jsonb_typeof(n) = 'object' AND n ? 'Node Type'
      AND (n ->> 'Node Type') LIKE '%Scan%';
    RETURN NEXT;
END $$;
COMMENT ON FUNCTION analytics.plan_cost(text) IS
'Total cost, estimated rows and scan nodes of EXPLAIN (FORMAT JSON) for trusted SQL; reacts to HypoPG indexes.';

-- Workload: data-quality triage. Sensor dropouts are written with quality 0.25,
-- so "quality < 0.3" should return exactly the labelled dropouts in meta.ground_truth.
SELECT (SELECT count(*) FROM mobility.sensor_readings WHERE data_quality_score < 0.3) AS low_quality_rows,
       (SELECT count(*) FROM meta.ground_truth
        WHERE entity = 'mobility.sensor_readings' AND label = 'dropout')             AS labelled_dropouts;

CREATE TEMP TABLE IF NOT EXISTS hypo_results (ord int, scenario text, total_cost numeric,
                                              est_rows numeric, access_paths text, est_index_size text);
TRUNCATE hypo_results;

\set hypo_query 'SELECT reading_id, sensor_code, reading_time FROM mobility.sensor_readings WHERE data_quality_score < 0.3'

INSERT INTO hypo_results
SELECT 1, 'no index (today)', total_cost, est_rows, access_paths, NULL
FROM analytics.plan_cost(:'hypo_query');

-- Candidate A: plain btree on the column.
SELECT indexrelid AS hypo_a FROM hypopg_create_index(
    'CREATE INDEX ON mobility.sensor_readings (data_quality_score)') \gset
INSERT INTO hypo_results
SELECT 2, 'A: btree (data_quality_score)', total_cost, est_rows, access_paths,
       pg_size_pretty(hypopg_relation_size(:hypo_a))
FROM analytics.plan_cost(:'hypo_query');
SELECT hypopg_drop_index(:hypo_a);

-- Candidate B: partial index covering only the rows triage ever asks for.
SELECT indexrelid AS hypo_b FROM hypopg_create_index(
    'CREATE INDEX ON mobility.sensor_readings (data_quality_score) WHERE data_quality_score < 0.5') \gset
INSERT INTO hypo_results
SELECT 3, 'B: partial btree WHERE quality < 0.5', total_cost, est_rows, access_paths,
       pg_size_pretty(hypopg_relation_size(:hypo_b))
FROM analytics.plan_cost(:'hypo_query');

SELECT scenario, round(total_cost, 1) AS total_cost, est_rows, access_paths, est_index_size
FROM hypo_results ORDER BY ord;
SELECT hypopg_reset();

-- Validate the winner for real, then throw it away (CREATE INDEX is transactional).
BEGIN;
CREATE INDEX hypo_validation_idx ON mobility.sensor_readings (data_quality_score)
    WHERE data_quality_score < 0.5;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT reading_id, sensor_code, reading_time FROM mobility.sensor_readings WHERE data_quality_score < 0.3;
SELECT pg_size_pretty(pg_relation_size('mobility.hypo_validation_idx')) AS real_index_size;
ROLLBACK;
-- In production build it with CREATE INDEX CONCURRENTLY (no write lock, cannot run
-- inside a transaction block, leaves an INVALID index behind if it fails).

-- =============================================================================
-- 6. HYPOPG: WHAT IF WE DROPPED AN INDEX? (hidden indexes)
-- =============================================================================
\echo '== 6. Hiding a duplicate index from the planner'

-- civics.idx_citizens_email duplicates the unique index behind citizens_email_key.
-- Hide it (session-only, nothing is dropped) and confirm lookups still use an index.
SELECT analytics.plan_cost($q$SELECT citizen_id FROM civics.citizens WHERE email = 'nobody@example.com'$q$) AS before_hiding;
SELECT hypopg_hide_index('civics.idx_citizens_email'::regclass) AS hidden;
SELECT analytics.plan_cost($q$SELECT citizen_id FROM civics.citizens WHERE email = 'nobody@example.com'$q$) AS after_hiding;
SELECT hypopg_unhide_all_indexes();

-- =============================================================================
-- 7. COVERING INDEXES (INCLUDE) FOR INDEX-ONLY SCANS
-- =============================================================================
\echo '== 7. Covering index candidate for "order history of one customer"'

\set cover_query 'SELECT order_date, total_amount FROM commerce.orders WHERE customer_citizen_id = 42 ORDER BY order_date DESC'

SELECT 'existing idx_orders_customer' AS scenario, * FROM analytics.plan_cost(:'cover_query');
SELECT indexrelid AS hypo_c FROM hypopg_create_index(
    'CREATE INDEX ON commerce.orders (customer_citizen_id, order_date DESC) INCLUDE (total_amount)') \gset
SELECT 'hypothetical (customer, order_date DESC) INCLUDE (total_amount)' AS scenario, * FROM analytics.plan_cost(:'cover_query');
SELECT pg_size_pretty(hypopg_relation_size(:hypo_c)) AS est_size;
SELECT hypopg_reset();
-- Index-only scans also need an up-to-date visibility map (VACUUM). If this index
-- were built, idx_orders_customer would become prefix-redundant (section 2).

-- =============================================================================
-- 8. INDEX HEALTH: bloat and fragmentation with pgstattuple
-- =============================================================================
\echo '== 8. B-tree density (pgstatindex) for the largest indexes'

CREATE EXTENSION IF NOT EXISTS pgstattuple;
-- avg_leaf_density far below the fillfactor (90 for btree) after heavy churn means
-- bloat: REINDEX INDEX CONCURRENTLY rebuilds it without blocking writes.
SELECT i.indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS size,
       s.avg_leaf_density, s.leaf_fragmentation, s.tree_level
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL pgstatindex(i.indexrelid) s
WHERE n.nspname IN ('commerce', 'mobility')
  AND c.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
ORDER BY pg_relation_size(i.indexrelid) DESC, index_name
LIMIT 5;

-- =============================================================================
-- 9. ONE ADVISOR REPORT (DDL text only; review and run by hand)
-- =============================================================================
\echo '== 9. Combined advisor report'

CREATE OR REPLACE FUNCTION analytics.comprehensive_index_advisor()
RETURNS TABLE (priority int, category text, object text, suggested_ddl text, rationale text)
LANGUAGE sql STABLE AS $$
    SELECT 1, 'DUPLICATE/REDUNDANT', redundant_index, suggested_ddl,
           kind || ' of ' || covered_by || ': pure write and storage overhead'
    FROM analytics.detect_redundant_indexes()
    UNION ALL
    SELECT 2, 'MISSING FK INDEX', table_name || ' (' || fk_columns || ')', suggested_ddl,
           'Parent DELETE/UPDATE scans ' || child_rows || ' child rows; parent-to-child joins cannot use an index'
    FROM analytics.detect_missing_fk_indexes()
    WHERE child_rows >= 1000
    UNION ALL
    SELECT 3, 'UNUSED INDEX', index_name, suggested_ddl,
           'Scanned ' || idx_scan || ' times since stats reset; confirm on replicas and over a full business cycle'
    FROM analytics.detect_unused_indexes(1024 * 1024);      -- ignore tiny ones
$$;
COMMENT ON FUNCTION analytics.comprehensive_index_advisor() IS
'Prioritised index advice (duplicates, missing FK indexes, unused indexes) as reviewable DDL; executes nothing.';

SELECT priority, category, object, suggested_ddl
FROM analytics.comprehensive_index_advisor()
ORDER BY priority, object
LIMIT 15;
