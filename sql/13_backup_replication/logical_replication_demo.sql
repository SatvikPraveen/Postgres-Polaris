-- File: sql/13_backup_replication/logical_replication_demo.sql
-- Purpose: logical replication - publications, replication slots, logical decoding
--
-- What this module teaches
--   1. Publications: FOR TABLE, FOR TABLES IN SCHEMA (PG15+), row filters and column lists (PG15+)
--   2. The replica-identity rule: UPDATE/DELETE need a replica identity, and row filters /
--      column lists of a publication that publishes UPDATE/DELETE may only rely on it
--   3. Logical replication slots and logical decoding with test_decoding
--      (pg_logical_slot_peek_changes vs pg_logical_slot_get_changes)
--   4. Why abandoned slots are dangerous: they pin WAL forever (max_slot_wal_keep_size)
--   5. Subscriptions (documented only: a subscription to a DB in the same cluster needs
--      create_slot = false, see section 8)
--
-- Prerequisite: wal_level = logical (set in this lab's server config).
-- Safety: publications cover only the module-owned schema repl_demo.  The replication slots
-- are TEMPORARY and are dropped explicitly at the end of the file as well.

\echo '== 13 / logical replication =='

SELECT name, setting FROM pg_settings
WHERE name IN ('wal_level', 'max_replication_slots', 'max_wal_senders', 'max_slot_wal_keep_size')
ORDER BY name;

-- =============================================================================
-- 1. MODULE-OWNED SOURCE TABLES
-- =============================================================================
DROP PUBLICATION IF EXISTS repl_demo_schema_pub, repl_demo_directory_pub,
                           repl_demo_big_orders_pub, repl_demo_bad_filter_pub;
DROP SCHEMA IF EXISTS repl_demo CASCADE;
CREATE SCHEMA repl_demo;

CREATE TABLE repl_demo.citizens_pub (
    citizen_id  BIGINT PRIMARY KEY,
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    email       TEXT NOT NULL,        -- PII: excluded from the directory publication
    phone       TEXT,                 -- PII
    zip_code    TEXT NOT NULL,
    status      TEXT NOT NULL
);
INSERT INTO repl_demo.citizens_pub
SELECT citizen_id, first_name, last_name, email, phone, zip_code, status::TEXT
FROM civics.citizens WHERE citizen_id <= 1000 ORDER BY citizen_id;

CREATE TABLE repl_demo.orders_pub (
    order_id     BIGINT PRIMARY KEY,
    merchant_id  BIGINT NOT NULL,
    status       TEXT NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL,
    order_date   TIMESTAMPTZ NOT NULL
);
-- last 30 days of the dataset, relative to the dataset clock (not now())
INSERT INTO repl_demo.orders_pub
SELECT order_id, merchant_id, status::TEXT, total_amount, order_date
FROM commerce.orders
WHERE order_date >= meta.as_of() - interval '30 days'
ORDER BY order_id;

-- A table WITHOUT a primary key: fine for INSERT-only replication, but UPDATE/DELETE
-- fail once it is published, until it gets a replica identity.
CREATE TABLE repl_demo.event_log (
    event_time TIMESTAMPTZ NOT NULL DEFAULT now(),
    message    TEXT NOT NULL
);

SELECT 'citizens_pub' AS table_name, count(*) FROM repl_demo.citizens_pub
UNION ALL SELECT 'orders_pub', count(*) FROM repl_demo.orders_pub;

-- =============================================================================
-- 2. PUBLICATIONS
-- =============================================================================
-- Whole schema (PG15+): tables created in repl_demo later are included automatically.
CREATE PUBLICATION repl_demo_schema_pub FOR TABLES IN SCHEMA repl_demo;

-- Column list (PG15+): replicate a directory without email/phone.  For UPDATE/DELETE the
-- list must contain the replica identity (here the primary key citizen_id).
CREATE PUBLICATION repl_demo_directory_pub
    FOR TABLE repl_demo.citizens_pub (citizen_id, first_name, last_name, zip_code, status);

-- Row filter (PG15+): only big orders.  The filter uses a non-key column, so the publication
-- may only publish INSERTs (an append-only feed).  Filter expressions must be immutable:
-- no now(), CURRENT_DATE or user-defined functions.
CREATE PUBLICATION repl_demo_big_orders_pub
    FOR TABLE repl_demo.orders_pub WHERE (total_amount >= 100)
    WITH (publish = 'insert');

-- Other forms, for reference (not created here because they would cover shared tables):
--   CREATE PUBLICATION all_pub FOR ALL TABLES;                 -- superuser only
--   CREATE PUBLICATION civics_pub FOR TABLES IN SCHEMA civics, commerce;
--   ... WITH (publish_via_partition_root = true)                -- publish partitions as their root

\echo '-- pg_publication / pg_publication_tables'
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate, pubviaroot
FROM pg_publication WHERE pubname LIKE 'repl_demo%' ORDER BY pubname;

SELECT pubname, schemaname, tablename, attnames, rowfilter
FROM pg_publication_tables
WHERE pubname LIKE 'repl_demo%'
ORDER BY pubname, tablename;

-- =============================================================================
-- 3. THE REPLICA IDENTITY RULE
-- =============================================================================
-- (a) A published table with no replica identity rejects UPDATE/DELETE.
INSERT INTO repl_demo.event_log (message) VALUES ('first event');
DO $$
BEGIN
    UPDATE repl_demo.event_log SET message = 'edited';
    RAISE NOTICE 'unexpected: update succeeded';
EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RAISE NOTICE 'no replica identity: %', SQLERRM;
END $$;

-- Fix: give it a key, or REPLICA IDENTITY FULL (whole old row is logged: more WAL,
-- and the subscriber has to find rows by comparing every column).
ALTER TABLE repl_demo.event_log REPLICA IDENTITY FULL;
UPDATE repl_demo.event_log SET message = 'edited';

-- (b) A row filter on a non-identity column in a publication that publishes UPDATEs:
--     the publication is created, but UPDATEs on the table then fail.
CREATE PUBLICATION repl_demo_bad_filter_pub
    FOR TABLE repl_demo.citizens_pub WHERE (status = 'active');
DO $$
DECLARE v_detail TEXT;
BEGIN
    UPDATE repl_demo.citizens_pub SET phone = phone WHERE citizen_id = 1;
    RAISE NOTICE 'unexpected: update succeeded';
EXCEPTION WHEN invalid_column_reference THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RAISE NOTICE 'row filter vs replica identity: % (%)', SQLERRM, v_detail;
END $$;
DROP PUBLICATION repl_demo_bad_filter_pub;

SELECT c.relname,
       CASE c.relreplident WHEN 'd' THEN 'default (primary key)' WHEN 'f' THEN 'full'
                           WHEN 'i' THEN 'index' WHEN 'n' THEN 'nothing' END AS replica_identity
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'repl_demo' AND c.relkind = 'r'
ORDER BY c.relname;

-- =============================================================================
-- 4. LOGICAL DECODING WITH A REPLICATION SLOT
-- =============================================================================
-- A logical slot remembers how far a consumer has read and keeps the WAL (and catalog rows)
-- it still needs.  Slot names are cluster-wide, so include the database name.
-- TEMPORARY slots disappear when the session ends, a good default for experiments.
SELECT 'repl_demo_' || current_database()        AS slot_name,
       'repl_demo_pgout_' || current_database()  AS pgout_slot \gset

SELECT pg_drop_replication_slot(slot_name)
FROM pg_replication_slots
WHERE slot_name IN (:'slot_name', :'pgout_slot') AND NOT active;   -- leftovers from a crashed run

SELECT slot_name, lsn AS consistent_point
FROM pg_create_logical_replication_slot(:'slot_name', 'test_decoding', temporary => true);
SELECT slot_name, lsn AS consistent_point
FROM pg_create_logical_replication_slot(:'pgout_slot', 'pgoutput', temporary => true);

-- Make some changes after the slot's consistent point
BEGIN;
INSERT INTO repl_demo.orders_pub (order_id, merchant_id, status, total_amount, order_date)
VALUES (900000001, 1, 'pending', 250.00, meta.as_of()),
       (900000002, 1, 'pending',  12.50, meta.as_of());
UPDATE repl_demo.citizens_pub SET zip_code = '75199' WHERE citizen_id = 1;
DELETE FROM repl_demo.citizens_pub WHERE citizen_id = 2;
COMMIT;

\echo '-- peek: read the decoded changes WITHOUT consuming them'
SELECT lsn, xid IS NOT NULL AS has_xid, data
FROM pg_logical_slot_peek_changes(:'slot_name', NULL, NULL,
                                  'include-xids', '0', 'skip-empty-xacts', '1')
ORDER BY lsn
LIMIT 10;

-- test_decoding shows every table in the database; publications only matter to pgoutput,
-- the plugin used by real subscriptions.  Peek through the big-orders publication:
-- 1 BEGIN + 1 RELATION + 1 INSERT (the 12.50 order is filtered out) + 1 COMMIT.
SELECT count(*) AS pgoutput_messages,
       count(*) FILTER (WHERE get_byte(data, 0) = ascii('I')) AS insert_messages
FROM pg_logical_slot_peek_binary_changes(:'pgout_slot', NULL, NULL,
        'proto_version', '4', 'publication_names', 'repl_demo_big_orders_pub');

\echo '-- slot status: retained WAL grows until changes are consumed'
SELECT slot_name, plugin, slot_type, temporary, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
       confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name IN (:'slot_name', :'pgout_slot')
ORDER BY slot_name;

-- get_changes CONSUMES: afterwards a peek returns nothing new
SELECT count(*) AS changes_consumed
FROM pg_logical_slot_get_changes(:'slot_name', NULL, NULL, 'skip-empty-xacts', '1');
SELECT count(*) AS changes_left
FROM pg_logical_slot_peek_changes(:'slot_name', NULL, NULL, 'skip-empty-xacts', '1');

-- Per-slot decoding statistics (PG14+)
SELECT slot_name, total_txns, total_bytes, spill_txns, stream_txns
FROM pg_stat_replication_slots
WHERE slot_name IN (:'slot_name', :'pgout_slot')
ORDER BY slot_name;

-- =============================================================================
-- 5. MONITORING HELPERS
-- =============================================================================
CREATE OR REPLACE FUNCTION repl_demo.check_replication_status()
RETURNS TABLE(object_type TEXT, object_name TEXT, state TEXT, lag_or_retained TEXT, note TEXT)
LANGUAGE sql STABLE AS $$
    -- publications in this database
    SELECT 'publication', p.pubname::TEXT,
           CASE WHEN p.puballtables THEN 'all tables' ELSE count(pt.tablename) || ' table(s)' END,
           NULL::TEXT,
           concat_ws(',', CASE WHEN p.pubinsert THEN 'insert' END, CASE WHEN p.pubupdate THEN 'update' END,
                          CASE WHEN p.pubdelete THEN 'delete' END, CASE WHEN p.pubtruncate THEN 'truncate' END)
    FROM pg_publication p LEFT JOIN pg_publication_tables pt ON pt.pubname = p.pubname
    GROUP BY p.pubname, p.puballtables, p.pubinsert, p.pubupdate, p.pubdelete, p.pubtruncate
    UNION ALL
    -- slots of this database: the #1 cause of disks filling up with WAL
    SELECT 'slot', s.slot_name::TEXT,
           CASE WHEN s.active THEN 'active' ELSE 'INACTIVE' END,
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn)),
           'wal_status=' || COALESCE(s.wal_status, '?')
    FROM pg_replication_slots s
    WHERE s.database = current_database()
    UNION ALL
    -- walsenders (one per connected subscriber / standby)
    SELECT 'walsender', r.application_name::TEXT, r.state,
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn)),
           'replay_lag=' || COALESCE(r.replay_lag::TEXT, 'n/a')
    FROM pg_stat_replication r
$$;

SELECT * FROM repl_demo.check_replication_status() ORDER BY object_type, object_name;

-- On a SUBSCRIBER you would monitor:
--   SELECT subname, received_lsn, latest_end_lsn, last_msg_receipt_time FROM pg_stat_subscription;
--   SELECT subname, apply_error_count, sync_error_count FROM pg_stat_subscription_stats;  -- PG15+

-- Conflict handling reference.  Logical replication applies changes as-is; an apply error
-- (e.g. duplicate key) stops the subscription worker and it retries forever.
CREATE OR REPLACE FUNCTION repl_demo.replication_conflict_playbook()
RETURNS TABLE(conflict_type TEXT, symptom TEXT, resolution TEXT)
LANGUAGE sql IMMUTABLE AS $$
    VALUES
    ('unique violation on INSERT', 'worker log: duplicate key value violates unique constraint',
     'delete/fix the row on the subscriber, or ALTER SUBSCRIPTION s SKIP (lsn = ''<finish LSN from log>'') (PG15+)'),
    ('row missing on UPDATE/DELETE', 'change silently skipped (logged at DEBUG); data drifts',
     'make the subscriber read-only for replicated tables; resync with ALTER SUBSCRIPTION s REFRESH PUBLICATION WITH (copy_data = true) on a truncated table'),
    ('FK / check violation', 'apply error; subscription stops',
     'replicate parent tables in the same publication; triggers & FKs run on the subscriber only for session_replication_role = replica rules'),
    ('schema drift', 'apply error: column missing',
     'DDL is NOT replicated: apply DDL on the subscriber first, then on the publisher'),
    ('stuck after error', 'worker keeps restarting',
     'ALTER SUBSCRIPTION s DISABLE; fix; ENABLE.  Or WITH (disable_on_error = true) (PG15+)')
$$;
SELECT * FROM repl_demo.replication_conflict_playbook();

-- =============================================================================
-- 6. PUBLICATION ADMINISTRATION
-- =============================================================================
CREATE OR REPLACE FUNCTION repl_demo.add_table_to_publication(pub_name TEXT, schema_name TEXT, table_name TEXT)
RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('ALTER PUBLICATION %I ADD TABLE %I.%I', pub_name, schema_name, table_name);
    RETURN format('Added %I.%I to publication %I (subscribers must run ALTER SUBSCRIPTION ... REFRESH PUBLICATION)',
                  schema_name, table_name, pub_name);
END $$;

CREATE OR REPLACE FUNCTION repl_demo.remove_table_from_publication(pub_name TEXT, schema_name TEXT, table_name TEXT)
RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('ALTER PUBLICATION %I DROP TABLE %I.%I', pub_name, schema_name, table_name);
    RETURN format('Removed %I.%I from publication %I', schema_name, table_name, pub_name);
END $$;

SELECT repl_demo.add_table_to_publication('repl_demo_big_orders_pub', 'repl_demo', 'event_log');
SELECT pubname, tablename FROM pg_publication_tables WHERE pubname = 'repl_demo_big_orders_pub' ORDER BY tablename;
SELECT repl_demo.remove_table_from_publication('repl_demo_big_orders_pub', 'repl_demo', 'event_log');

-- Which publications would carry the most change volume?  (n_tup_* are cumulative counters)
CREATE OR REPLACE FUNCTION repl_demo.analyze_publication_volume()
RETURNS TABLE(publication_name TEXT, table_count INTEGER, cumulative_changes BIGINT, assessment TEXT)
LANGUAGE sql STABLE AS $$
    WITH pub_tables AS (
        SELECT pt.pubname,
               count(*)::INTEGER AS table_count,
               COALESCE(sum(s.n_tup_ins + s.n_tup_upd + s.n_tup_del), 0)::BIGINT AS changes
        FROM pg_publication_tables pt
        LEFT JOIN pg_stat_user_tables s ON s.schemaname = pt.schemaname AND s.relname = pt.tablename
        GROUP BY pt.pubname
    )
    SELECT pubname::TEXT, table_count, changes,
           CASE WHEN changes > 100000 THEN 'HIGH - consider row filters or splitting'
                WHEN changes > 10000  THEN 'MEDIUM - monitor bandwidth'
                ELSE 'LOW' END
    FROM pub_tables
    ORDER BY changes DESC, pubname
$$;
SELECT * FROM repl_demo.analyze_publication_volume() WHERE publication_name LIKE 'repl_demo%';

-- =============================================================================
-- 7. CLEAN UP THE SLOTS (never leave an unused slot behind)
-- =============================================================================
-- An inactive slot holds back WAL removal and VACUUM's catalog xmin indefinitely until the
-- disk fills.  Set max_slot_wal_keep_size as a safety net in production.
SELECT pg_drop_replication_slot(slot_name)
FROM pg_replication_slots
WHERE slot_name IN (:'slot_name', :'pgout_slot');

SELECT count(*) AS demo_slots_remaining
FROM pg_replication_slots WHERE slot_name IN (:'slot_name', :'pgout_slot');

-- The publications are kept (they cost nothing without a slot) so they can be inspected.

-- =============================================================================
-- 8. SUBSCRIPTIONS (documented; run on the subscriber)
-- =============================================================================
/*
-- Different cluster: the subscription creates its slot on the publisher automatically.
CREATE SUBSCRIPTION directory_sub
    CONNECTION 'host=publisher.example.com port=5432 dbname=polaris user=repl_user password=...'
    PUBLICATION repl_demo_directory_pub
    WITH (copy_data = true,             -- initial table sync
          streaming = parallel,         -- PG16+: apply large in-progress txns in parallel
          disable_on_error = true,      -- PG15+
          failover = true);             -- PG17+: slot is synced to physical standbys

-- SAME cluster (e.g. from database polaris to ag_copy): CREATE SUBSCRIPTION would deadlock
-- waiting for its own slot creation, so create the slot separately:
--   [publisher db]  SELECT pg_create_logical_replication_slot('directory_sub', 'pgoutput');
--   [subscriber db] CREATE TABLE repl_demo.citizens_pub (... same columns ...);
--   [subscriber db] CREATE SUBSCRIPTION directory_sub
--                     CONNECTION 'dbname=<publisher db> user=polaris'
--                     PUBLICATION repl_demo_directory_pub
--                     WITH (create_slot = false, slot_name = 'directory_sub');
-- Drop order matters: DROP SUBSCRIPTION also drops the remote slot.  If the publisher is gone:
--   ALTER SUBSCRIPTION directory_sub DISABLE;
--   ALTER SUBSCRIPTION directory_sub SET (slot_name = NONE);
--   DROP SUBSCRIPTION directory_sub;

-- Bidirectional / multi-origin without loops (PG16+):  WITH (origin = none)
-- Turn a physical standby into a logical subscriber (PG17+):  pg_createsubscriber
*/

-- =============================================================================
-- 9. FAILOVER READINESS (read-only checklist)
-- =============================================================================
CREATE OR REPLACE FUNCTION repl_demo.failover_checklist()
RETURNS TABLE(item TEXT, value TEXT)
LANGUAGE sql STABLE AS $$
    SELECT 'current WAL position', pg_current_wal_lsn()::TEXT
    UNION ALL SELECT 'publications in this DB', count(*)::TEXT FROM pg_publication
    UNION ALL SELECT 'logical slots (cluster)', count(*)::TEXT FROM pg_replication_slots WHERE slot_type = 'logical'
    UNION ALL SELECT 'inactive slots (cluster)', count(*)::TEXT FROM pg_replication_slots WHERE NOT active
    UNION ALL SELECT 'failover-enabled slots (PG17)', count(*)::TEXT FROM pg_replication_slots WHERE failover
    UNION ALL SELECT 'last checkpoint', checkpoint_time::TEXT FROM pg_control_checkpoint()
$$;
SELECT * FROM repl_demo.failover_checklist();

\echo '== logical replication module complete =='
