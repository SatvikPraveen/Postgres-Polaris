-- File: sql/10_tx_mvcc_locks/mvcc_visibility_demos.sql
-- Purpose: MVCC from the inside: tuple headers (xmin/xmax/ctid), raw heap pages
--          (pageinspect), hint bits, dead tuples and VACUUM (pgstattuple), the
--          visibility map (pg_visibility), HOT updates and freezing.
--
-- Runs in a single session and is idempotent: every object it touches is
-- module-owned (analytics.mvcc_*) and rebuilt on each run. Base tables are only read.
-- Requires the pageinspect, pgstattuple and pg_visibility extensions (installed
-- in the base image; CREATE EXTENSION IF NOT EXISTS below is a no-op then).
--
-- Mental model:
--   * Every row version ("tuple") carries xmin (inserting xact) and xmax (deleting
--     or locking xact, 0 if none). UPDATE = mark old version dead (set xmax) +
--     insert a new version with a new ctid (block, line pointer).
--   * A snapshot decides which versions are visible; nothing is overwritten in place.
--   * Old versions become garbage only once no snapshot can see them; VACUUM
--     reclaims them, sets visibility-map bits, and freezes old xmin values.

CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_visibility;

-- =============================================================================
-- 0. LAB SETUP (module-owned table, autovacuum disabled so output is stable)
-- =============================================================================
\echo '== 0. Lab setup: analytics.mvcc_lab'

DROP TABLE IF EXISTS analytics.mvcc_lab;
CREATE TABLE analytics.mvcc_lab (
    id      integer PRIMARY KEY,
    label   text    NOT NULL,       -- indexed: updating it prevents HOT
    amount  integer NOT NULL,
    note    text                    -- not indexed: updating it allows HOT
) WITH (autovacuum_enabled = off, fillfactor = 70);  -- 30% free space per page for HOT
CREATE INDEX mvcc_lab_label_idx ON analytics.mvcc_lab (label);

-- Seed from real data so the lab is tied to the city dataset: the five oldest
-- neighbourhoods by id, using their population as the amount.
INSERT INTO analytics.mvcc_lab (id, label, amount, note)
SELECT neighborhood_id, neighborhood_name, population_estimate, 'v1'
FROM geo.neighborhood_boundaries
ORDER BY neighborhood_id
LIMIT 5;

-- Reusable helper: decode every line pointer on one heap page.
-- lp_flags: 0 = unused, 1 = normal, 2 = redirect (HOT chain head after pruning), 3 = dead.
CREATE OR REPLACE FUNCTION analytics.mvcc_page(p_rel regclass, p_blk integer DEFAULT 0)
RETURNS TABLE (lp smallint, lp_state text, t_xmin xid, t_xmax xid, t_ctid tid,
               flags text[])
LANGUAGE sql STRICT AS $$
    SELECT h.lp,
           CASE h.lp_flags WHEN 0 THEN 'unused' WHEN 1 THEN 'normal'
                           WHEN 2 THEN 'redirect->' || h.lp_off WHEN 3 THEN 'dead' END,
           h.t_xmin, h.t_xmax, h.t_ctid,
           -- keep only the flags that matter for MVCC lessons
           ARRAY(SELECT f FROM unnest(fl.raw_flags || fl.combined_flags) AS f
                 WHERE f IN ('HEAP_XMIN_COMMITTED','HEAP_XMIN_INVALID','HEAP_XMIN_FROZEN',
                             'HEAP_XMAX_COMMITTED','HEAP_XMAX_INVALID','HEAP_XMAX_LOCK_ONLY',
                             'HEAP_XMAX_EXCL_LOCK','HEAP_KEYS_UPDATED',
                             'HEAP_HOT_UPDATED','HEAP_ONLY_TUPLE','HEAP_UPDATED')
                 ORDER BY f)
    FROM heap_page_items(get_raw_page(p_rel::text, p_blk)) AS h
    LEFT JOIN LATERAL heap_tuple_infomask_flags(h.t_infomask, h.t_infomask2) AS fl ON true
    ORDER BY h.lp;
$$;
COMMENT ON FUNCTION analytics.mvcc_page(regclass, integer) IS
'Decodes a heap page with pageinspect: line pointer state, xmin/xmax, ctid chain and MVCC infomask flags.';

-- =============================================================================
-- 1. SYSTEM COLUMNS: ctid, xmin, xmax
-- =============================================================================
\echo '== 1. System columns after INSERT (xmax = 0 means "not deleted or locked")'

SELECT ctid, xmin, xmax, id, label, amount, note
FROM analytics.mvcc_lab
ORDER BY id;

-- pg_current_xact_id() (xid8, 64-bit, epoch-aware) replaces the deprecated txid_current().
-- pg_current_snapshot() shows xmin:xmax:in-progress-list for this statement.
SELECT pg_current_xact_id_if_assigned() AS xid_before_any_write,  -- NULL: reads never consume an xid
       pg_current_snapshot()            AS snapshot;

-- =============================================================================
-- 2. UPDATE = NEW TUPLE VERSION (and the old one stays on the page)
-- =============================================================================
\echo '== 2. UPDATE creates a new row version; the old version is still on the page'

BEGIN;
SELECT pg_current_xact_id() AS updating_xid;            -- assigns an xid now
UPDATE analytics.mvcc_lab SET amount = amount + 1, label = label || ' (renamed)' WHERE id = 1;
-- Inside the transaction we see only the new version (new ctid, xmin = our xid).
SELECT ctid, xmin, xmax, id, label FROM analytics.mvcc_lab WHERE id = 1;
COMMIT;

-- The raw page still holds both versions: the old one has xmax set and its
-- t_ctid points at the new version. label is indexed, so this was NOT a HOT update.
SELECT * FROM analytics.mvcc_page('analytics.mvcc_lab');

-- =============================================================================
-- 3. ROLLED-BACK DELETE: xmax is set, yet the row is still visible
-- =============================================================================
\echo '== 3. A rolled-back DELETE leaves xmax pointing at an aborted transaction'

BEGIN;
SELECT pg_current_xact_id() AS deleter_xid \gset
DELETE FROM analytics.mvcc_lab WHERE id = 2;
SELECT count(*) AS rows_visible_inside_deleting_tx FROM analytics.mvcc_lab;  -- 4
ROLLBACK;

-- Visible again, but xmax <> 0: visibility checks consult the commit log (pg_xact)
-- and find the deleter aborted. xmax alone never decides visibility.
SELECT ctid, xmin, xmax, id, label,
       pg_xact_status(:'deleter_xid'::xid8) AS deleter_status
FROM analytics.mvcc_lab WHERE id = 2;

-- =============================================================================
-- 4. ROW LOCKS ALSO LIVE IN xmax
-- =============================================================================
\echo '== 4. SELECT ... FOR UPDATE writes the locker into xmax (HEAP_XMAX_LOCK_ONLY)'

BEGIN;
SELECT id FROM analytics.mvcc_lab WHERE id = 3 FOR UPDATE;
SELECT lp, t_xmin, t_xmax, flags
FROM analytics.mvcc_page('analytics.mvcc_lab')
WHERE t_ctid = (SELECT ctid FROM analytics.mvcc_lab WHERE id = 3);
COMMIT;
-- Row locks are not kept in shared memory (pg_locks); that is why millions of
-- locked rows cost nothing in the lock table, and why FOR UPDATE dirties pages.

-- =============================================================================
-- 5. HINT BITS
-- =============================================================================
\echo '== 5. Hint bits: HEAP_XMIN_COMMITTED is set lazily by the first reader'

INSERT INTO analytics.mvcc_lab (id, label, amount, note) VALUES (100, 'hint-bit probe', 0, 'v1');

-- Right after the inserting transaction commits, nobody has checked the new
-- tuple's visibility yet, so it carries no XMIN hint. (We locate it by line pointer
-- number, without reading the table through a snapshot.)
SELECT lp, t_xmin, flags AS flags_before_first_read
FROM analytics.mvcc_page('analytics.mvcc_lab')
WHERE lp = (SELECT max(lp) FROM heap_page_items(get_raw_page('analytics.mvcc_lab', 0)));

-- The first reader looks the xid up in pg_xact, finds it committed, and caches
-- that answer in the tuple header (HEAP_XMIN_COMMITTED). Later readers skip the
-- lookup. Setting hint bits dirties the page: this is the "first SELECT after a
-- bulk load writes to disk" surprise.
SELECT count(*) AS first_read FROM analytics.mvcc_lab;

SELECT lp, t_xmin, flags AS flags_after_first_read
FROM analytics.mvcc_page('analytics.mvcc_lab')
WHERE lp = (SELECT max(lp) FROM heap_page_items(get_raw_page('analytics.mvcc_lab', 0)));

-- =============================================================================
-- 6. HOT (HEAP-ONLY TUPLE) UPDATES
-- =============================================================================
\echo '== 6. HOT updates: no indexed column changed + room on the same page'

-- pg_stat_xact_user_tables shows counters not yet flushed to the cumulative
-- stats system. Force a flush first so it reflects only the next transaction.
SELECT pg_stat_force_next_flush();
BEGIN;
UPDATE analytics.mvcc_lab SET note = 'v2' WHERE id IN (3, 4, 5);       -- note is not indexed -> HOT
UPDATE analytics.mvcc_lab SET label = 'Relabelled' WHERE id = 100;     -- indexed column -> regular update
SELECT n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0), 1) AS hot_pct
FROM pg_stat_xact_user_tables
WHERE relid = 'analytics.mvcc_lab'::regclass;
COMMIT;

-- HOT chain on the page: old version = HEAP_HOT_UPDATED, new = HEAP_ONLY_TUPLE.
-- The index still points at the old line pointer; readers follow t_ctid.
SELECT * FROM analytics.mvcc_page('analytics.mvcc_lab') WHERE flags && ARRAY['HEAP_HOT_UPDATED','HEAP_ONLY_TUPLE'];

-- Cumulative view (flushed when the backend goes idle, at most once per second
-- unless forced). Watch the HOT ratio on busy tables; lower fillfactor or drop
-- indexes on frequently-updated columns when it is poor.
SELECT pg_stat_force_next_flush();
SELECT relname, n_tup_upd, n_tup_hot_upd, n_dead_tup
FROM pg_stat_user_tables WHERE relid = 'analytics.mvcc_lab'::regclass;

-- =============================================================================
-- 7. VACUUM: dead tuples, page pruning and the visibility map
-- =============================================================================
\echo '== 7. Before VACUUM: dead versions and an empty visibility map'

SELECT tuple_count, dead_tuple_count, round(dead_tuple_percent::numeric, 1) AS dead_pct,
       round(free_percent::numeric, 1) AS free_pct
FROM pgstattuple('analytics.mvcc_lab');
SELECT * FROM pg_visibility_map_summary('analytics.mvcc_lab');

VACUUM analytics.mvcc_lab;

\echo '== 7b. After VACUUM: dead tuples gone, HOT chain heads become redirects, page all-visible'
SELECT tuple_count, dead_tuple_count, round(dead_tuple_percent::numeric, 1) AS dead_pct,
       round(free_percent::numeric, 1) AS free_pct
FROM pgstattuple('analytics.mvcc_lab');
SELECT lp, lp_state, t_xmin, t_xmax, t_ctid, flags FROM analytics.mvcc_page('analytics.mvcc_lab');
SELECT blkno, all_visible, all_frozen, pd_all_visible FROM pg_visibility('analytics.mvcc_lab');
-- all_visible = true is what lets index-only scans skip the heap.

-- =============================================================================
-- 8. BLOAT AT SCALE: VACUUM vs VACUUM FULL
-- =============================================================================
\echo '== 8. Bloat lab: 10k rows updated 3 times'

DROP TABLE IF EXISTS analytics.mvcc_bloat_lab;
CREATE TABLE analytics.mvcc_bloat_lab (
    id      integer PRIMARY KEY,
    payload text,
    filler  char(100) DEFAULT 'x'
) WITH (autovacuum_enabled = off);
INSERT INTO analytics.mvcc_bloat_lab (id, payload)
SELECT g, 'row ' || g FROM generate_series(1, 10000) AS g;
VACUUM (ANALYZE) analytics.mvcc_bloat_lab;

CREATE TEMP TABLE IF NOT EXISTS mvcc_bloat_log (step text, size_bytes bigint, live bigint, dead bigint, free_pct numeric);
TRUNCATE mvcc_bloat_log;
INSERT INTO mvcc_bloat_log
SELECT '1 fresh load', pg_relation_size('analytics.mvcc_bloat_lab'), tuple_count, dead_tuple_count, round(free_percent::numeric, 1)
FROM pgstattuple('analytics.mvcc_bloat_lab');

UPDATE analytics.mvcc_bloat_lab SET payload = payload || '.';   -- every UPDATE writes 10k new versions
UPDATE analytics.mvcc_bloat_lab SET payload = payload || '.';
UPDATE analytics.mvcc_bloat_lab SET payload = payload || '.';
INSERT INTO mvcc_bloat_log
SELECT '2 after 3 full-table updates', pg_relation_size('analytics.mvcc_bloat_lab'), tuple_count, dead_tuple_count, round(free_percent::numeric, 1)
FROM pgstattuple('analytics.mvcc_bloat_lab');

VACUUM analytics.mvcc_bloat_lab;      -- marks space reusable; file size normally stays
INSERT INTO mvcc_bloat_log
SELECT '3 after VACUUM', pg_relation_size('analytics.mvcc_bloat_lab'), tuple_count, dead_tuple_count, round(free_percent::numeric, 1)
FROM pgstattuple('analytics.mvcc_bloat_lab');

VACUUM FULL analytics.mvcc_bloat_lab; -- rewrites the table (ACCESS EXCLUSIVE lock!) and returns space to the OS
INSERT INTO mvcc_bloat_log
SELECT '4 after VACUUM FULL', pg_relation_size('analytics.mvcc_bloat_lab'), tuple_count, dead_tuple_count, round(free_percent::numeric, 1)
FROM pgstattuple('analytics.mvcc_bloat_lab');

SELECT step, pg_size_pretty(size_bytes) AS table_size, live, dead, free_pct
FROM mvcc_bloat_log ORDER BY step;
-- Lesson: plain VACUUM turns dead space into free space (free_pct up) without
-- shrinking the file; VACUUM FULL / pg_repack / CLUSTER shrink it but rewrite.

-- =============================================================================
-- 9. FREEZING AND XID WRAPAROUND
-- =============================================================================
\echo '== 9. Freezing: VACUUM (FREEZE) marks xmin as frozen (visible to everyone forever)'

SELECT relname, relfrozenxid, age(relfrozenxid) AS xid_age
FROM pg_class WHERE oid = 'analytics.mvcc_lab'::regclass;

VACUUM (FREEZE) analytics.mvcc_lab;

SELECT relname, relfrozenxid, age(relfrozenxid) AS xid_age
FROM pg_class WHERE oid = 'analytics.mvcc_lab'::regclass;
-- HEAP_XMIN_FROZEN = XMIN_COMMITTED + XMIN_INVALID bits together (since 9.4 the
-- original xmin is kept for forensics instead of being overwritten with 2).
SELECT lp, t_xmin, flags FROM analytics.mvcc_page('analytics.mvcc_lab') WHERE lp_state = 'normal';
SELECT * FROM pg_visibility_map_summary('analytics.mvcc_lab');   -- all_frozen pages are skipped by anti-wraparound vacuums

-- Wraparound watch-list: 32-bit xids wrap after ~2^31 transactions; autovacuum
-- forces an aggressive vacuum when age(relfrozenxid) > autovacuum_freeze_max_age.
SELECT datname,
       age(datfrozenxid)      AS xid_age,
       mxid_age(datminmxid)   AS multixact_age,
       round(100.0 * age(datfrozenxid) / current_setting('autovacuum_freeze_max_age')::bigint, 2)
                              AS pct_of_freeze_max_age
FROM pg_database WHERE datname = current_database();

SELECT c.oid::regclass AS table_name,
       age(c.relfrozenxid)    AS xid_age,
       mxid_age(c.relminmxid) AS multixact_age,
       pg_size_pretty(pg_table_size(c.oid)) AS size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
  AND n.nspname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics')
ORDER BY age(c.relfrozenxid) DESC, c.oid::regclass::text
LIMIT 5;

-- =============================================================================
-- 10. WHO IS HOLDING BACK VACUUM? (the xmin horizon)
-- =============================================================================
\echo '== 10. Backends whose snapshot pins old row versions (long transactions are the #1 bloat cause)'

-- A dead tuple can only be removed if it is older than every running snapshot.
-- backend_xmin of an idle-in-transaction session therefore blocks cleanup in
-- the whole database. Also check replication slots and prepared transactions.
SELECT pid, datname, state, backend_xid, backend_xmin,
       age(backend_xmin) AS xmin_age,
       now() - xact_start AS xact_duration,     -- wall-clock: genuinely now()
       left(query, 60) AS query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
  AND pid <> pg_backend_pid()
ORDER BY age(backend_xmin) DESC
LIMIT 5;

SELECT 'replication slot' AS holder, slot_name::text AS name, xmin, catalog_xmin
FROM pg_replication_slots WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL
UNION ALL
SELECT 'prepared xact', gid, transaction, NULL FROM pg_prepared_xacts;

-- =============================================================================
-- 11. DEAD-TUPLE OVERVIEW FOR THE CITY SCHEMAS (reusable view)
-- =============================================================================
\echo '== 11. Dead-tuple overview (analytics.v_dead_tuple_overview)'

CREATE OR REPLACE VIEW analytics.v_dead_tuple_overview AS
SELECT s.schemaname, s.relname,
       s.n_live_tup, s.n_dead_tup,
       round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 2) AS dead_pct,
       pg_size_pretty(pg_table_size(s.relid)) AS table_size,
       s.last_vacuum, s.last_autovacuum, s.vacuum_count, s.autovacuum_count
FROM pg_stat_user_tables s
WHERE s.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents', 'analytics');
COMMENT ON VIEW analytics.v_dead_tuple_overview IS
'Per-table live/dead tuple counts from the cumulative statistics system (estimates; use pgstattuple for exact numbers).';

SELECT * FROM analytics.v_dead_tuple_overview
ORDER BY n_dead_tup DESC, schemaname, relname
LIMIT 8;

-- Exercises
--  1. In two psql sessions: [Session A] BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT 1;
--     [Session B] UPDATE analytics.mvcc_lab SET note = 'x'; VACUUM analytics.mvcc_lab;
--     then rerun section 7: the dead versions stay until Session A ends.
--  2. Recreate mvcc_lab with fillfactor = 100 and rerun section 6 many times:
--     when the page fills up, updates stop being HOT.
