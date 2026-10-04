-- File: sql/10_tx_mvcc_locks/transactions_isolation.sql
-- Purpose: Transaction isolation levels in PostgreSQL 17: what each level
--          guarantees, the anomalies they allow (non-repeatable read, lost update,
--          write skew) and how Serializable Snapshot Isolation (SSI) catches them.
--
-- Single-session safe: the script never blocks.
--   * Real concurrency comes from a loopback postgres_fdw connection to this same
--     database ("Session B"): a separate backend with its own transaction. Its
--     remote transaction commits when ours commits, so it can play the part of a
--     concurrent writer that holds locks or races us to a commit.
--     (dblink is not installed; postgres_fdw is.) If the loopback cannot connect
--     (e.g. pg_hba requires a password) those demos are skipped with a message.
--   * Interleavings that need two independent commits are written out as
--     `-- [Session A]` / `-- [Session B]` steps to paste into two psql windows.
-- Idempotent: all objects are module-owned (analytics.iso_*) and rebuilt each run.

-- =============================================================================
-- 0. THE FOUR LEVELS, AS POSTGRESQL ACTUALLY IMPLEMENTS THEM
-- =============================================================================
\echo '== 0. Isolation levels in PostgreSQL'

-- Facts that differ from the SQL standard's minimums:
--   * READ UNCOMMITTED is accepted but behaves exactly like READ COMMITTED:
--     PostgreSQL never shows uncommitted data (no dirty reads at any level).
--   * REPEATABLE READ is snapshot isolation: it also prevents phantom reads,
--     but still allows write skew (a serialization anomaly).
--   * SERIALIZABLE = snapshot isolation + SSI conflict tracking: any anomaly
--     makes one transaction fail with SQLSTATE 40001, which the client retries.
DROP FUNCTION IF EXISTS analytics.compare_isolation_levels();   -- older revisions returned other columns
CREATE OR REPLACE FUNCTION analytics.compare_isolation_levels()
RETURNS TABLE (isolation_level text, dirty_read text, nonrepeatable_read text,
               phantom_read text, lost_update text, write_skew text, notes text)
LANGUAGE sql IMMUTABLE AS $$
    VALUES
    ('READ UNCOMMITTED', 'no', 'possible', 'possible', 'possible', 'possible',
     'Mapped to READ COMMITTED in PostgreSQL'),
    ('READ COMMITTED',   'no', 'possible', 'possible', 'possible', 'possible',
     'Default. New snapshot per statement; blocked UPDATEs re-check the latest row version'),
    ('REPEATABLE READ',  'no', 'no',       'no',       'no (40001 error)', 'possible',
     'One snapshot per transaction; concurrent update of the same row -> 40001'),
    ('SERIALIZABLE',     'no', 'no',       'no',       'no (40001 error)', 'no (40001 error)',
     'SSI: predicate (SIRead) locks detect dangerous rw-dependency cycles')
$$;

SELECT * FROM analytics.compare_isolation_levels();

-- =============================================================================
-- 1. LAB TABLES
-- =============================================================================
\echo '== 1. Lab setup: analytics.iso_accounts and analytics.iso_oncall'

DROP TABLE IF EXISTS analytics.iso_accounts CASCADE;
CREATE TABLE analytics.iso_accounts (
    account_id integer PRIMARY KEY,
    owner      text          NOT NULL,
    balance    numeric(12,2) NOT NULL CHECK (balance >= 0),
    version    integer       NOT NULL DEFAULT 1,     -- for optimistic locking
    updated_at timestamptz   NOT NULL DEFAULT now()  -- wall-clock audit stamp
);
-- Three real citizens become account owners (deterministic: lowest ids).
INSERT INTO analytics.iso_accounts (account_id, owner, balance)
SELECT rn, owner, (ARRAY[1000, 500, 750])[rn]
FROM (SELECT row_number() OVER (ORDER BY citizen_id)::int AS rn,
             first_name || ' ' || last_name AS owner
      FROM civics.citizens
      ORDER BY citizen_id
      LIMIT 3) c;

-- Write-skew lab: a rule spanning several rows ("at least one inspector on call")
-- that no single-row constraint can enforce.
DROP TABLE IF EXISTS analytics.iso_oncall CASCADE;
CREATE TABLE analytics.iso_oncall (
    inspector text    PRIMARY KEY,
    on_call   boolean NOT NULL
);
INSERT INTO analytics.iso_oncall VALUES ('alice', true), ('bob', true);

SELECT account_id, owner, balance FROM analytics.iso_accounts ORDER BY account_id;

-- =============================================================================
-- 2. CHOOSING A LEVEL (and the classic mistakes)
-- =============================================================================
\echo '== 2. Setting the isolation level'

SHOW default_transaction_isolation;

BEGIN ISOLATION LEVEL REPEATABLE READ;            -- preferred: state it at BEGIN
SELECT current_setting('transaction_isolation') AS level_inside_tx;
COMMIT;

-- SET TRANSACTION must come before the first query of the transaction. Once a
-- snapshot exists the level can no longer change. (For the same reason, a function
-- cannot change the level of the transaction that calls it.)
BEGIN;
SELECT 1 AS first_query_takes_the_snapshot;
DO $$
BEGIN
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
EXCEPTION WHEN active_sql_transaction THEN
    RAISE NOTICE 'Expected: % (SQLSTATE %)', SQLERRM, SQLSTATE;
END $$;
COMMIT;

-- Read-only reports: SERIALIZABLE READ ONLY DEFERRABLE waits for a "safe"
-- snapshot and then runs without any SSI overhead or risk of 40001.
BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;
SELECT count(*) AS accounts, sum(balance) AS total_balance FROM analytics.iso_accounts;
COMMIT;

-- =============================================================================
-- 3. SNAPSHOTS: per statement (READ COMMITTED) vs per transaction (REPEATABLE READ)
-- =============================================================================
\echo '== 3. Snapshots and snapshot export'

-- A snapshot is xmin:xmax:list-of-in-progress-xids. Rows written by xids that are
-- >= xmax or in the list are invisible to it.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT pg_current_snapshot() AS tx_snapshot;
-- Export the snapshot so another session can see exactly the same data
-- (this is how pg_dump --jobs gives every worker a consistent view).
SELECT pg_export_snapshot() AS exported_snapshot_id;
-- [Session B] BEGIN ISOLATION LEVEL REPEATABLE READ;
-- [Session B] SET TRANSACTION SNAPSHOT '<exported_snapshot_id>';   -- must be first
-- [Session B] SELECT sum(balance) FROM analytics.iso_accounts;   -- identical to A's view
COMMIT;   -- the exported snapshot is only importable while this transaction is open

-- Non-repeatable read, run this in two psql windows to see it:
--   [Session A] BEGIN;                                 -- READ COMMITTED
--   [Session A] SELECT balance FROM analytics.iso_accounts WHERE account_id = 1;  -- 1000
--   [Session B] UPDATE analytics.iso_accounts SET balance = balance + 10 WHERE account_id = 1;
--   [Session A] SELECT balance FROM analytics.iso_accounts WHERE account_id = 1;  -- 1010 (changed!)
--   [Session A] COMMIT;
-- Repeat with [Session A] BEGIN ISOLATION LEVEL REPEATABLE READ; -> the second
-- SELECT still shows the first value, because the snapshot was taken by the
-- first statement (not by BEGIN) and is reused for the whole transaction.
-- Phantoms behave the same way: in REPEATABLE READ, rows inserted and committed
-- by B after A's first query never appear in A's later range queries.

-- =============================================================================
-- 4. LOOPBACK "SESSION B" (postgres_fdw to this same database)
-- =============================================================================
\echo '== 4. Creating the loopback Session B connection'

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Rebuilt every run (also fixes dbname when this database was cloned from a template).
DROP SERVER IF EXISTS m10_iso_session_b CASCADE;
DO $$
BEGIN
    EXECUTE format(
        'CREATE SERVER m10_iso_session_b FOREIGN DATA WRAPPER postgres_fdw
             OPTIONS (dbname %L, application_name %L, options %L)',
        current_database(), 'm10_iso_session_b',
        -- Session B gives up on any lock wait after 250 ms. That matters because
        -- a wait between us and our own loopback is a deadlock PostgreSQL cannot
        -- see (the dependency runs through the network connection).
        '-c lock_timeout=250 -c statement_timeout=10000');
    -- Superusers may connect without a password; other roles need one here.
    EXECUTE format('CREATE USER MAPPING FOR CURRENT_USER SERVER m10_iso_session_b OPTIONS (user %L)',
                   current_user);
END $$;

-- Session B's window onto the lab tables.
CREATE FOREIGN TABLE analytics.iso_accounts_b (
    account_id integer, owner text, balance numeric(12,2), version integer, updated_at timestamptz
) SERVER m10_iso_session_b OPTIONS (schema_name 'analytics', table_name 'iso_accounts');
CREATE FOREIGN TABLE analytics.iso_oncall_b (inspector text, on_call boolean)
    SERVER m10_iso_session_b OPTIONS (schema_name 'analytics', table_name 'iso_oncall');

CREATE OR REPLACE FUNCTION analytics.iso_session_b_available()
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM analytics.iso_oncall_b LIMIT 1;
    RETURN true;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Loopback Session B unavailable (%); live concurrency demos will be skipped', SQLERRM;
    RETURN false;
END $$;

SELECT CASE WHEN analytics.iso_session_b_available() THEN 'true' ELSE 'false' END AS session_b_ok \gset

-- =============================================================================
-- 5. LOST UPDATES: read-modify-write races and three safe patterns
-- =============================================================================
\echo '== 5. Lost update: Session B holds the row we want to change'

\if :session_b_ok
BEGIN;  -- READ COMMITTED
SELECT balance AS a_read_balance FROM analytics.iso_accounts WHERE account_id = 1;   -- A reads 1000
UPDATE analytics.iso_accounts_b SET balance = balance - 100 WHERE account_id = 1;    -- B withdraws 100 (uncommitted, row locked)
-- Who holds what? B's backend shows up in pg_locks under its own pid. (The row
-- lock itself lives in the tuple's xmax, not in pg_locks; waiters queue on B's
-- transactionid lock instead.)
SELECT a.application_name, l.locktype, l.relation::regclass AS relation, l.mode, l.granted
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE a.application_name = 'm10_iso_session_b' AND l.locktype IN ('relation', 'transactionid')
  AND (l.relation IS NULL OR l.relation = 'analytics.iso_accounts'::regclass)
ORDER BY l.locktype, l.mode;
-- A now writes a value it computed from its stale read (1000 - 50). The UPDATE must
-- wait for B's row lock; we cap the wait so the script cannot hang.
SET LOCAL lock_timeout = '200ms';
DO $$
BEGIN
    UPDATE analytics.iso_accounts SET balance = 1000 - 50 WHERE account_id = 1;
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'A blocked behind B''s row lock: %', SQLERRM;
END $$;
ROLLBACK;
\else
\echo 'skipped (no loopback session)'
\endif
-- What happens once B commits instead of being timed out:
--   READ COMMITTED : A's UPDATE proceeds on B's new row version. With the stale
--                    literal (1000 - 50) B's withdrawal is silently lost.
--   REPEATABLE READ: A gets "could not serialize access due to concurrent update"
--                    (40001) and must retry with a fresh snapshot.

\echo '== 5b. Safe patterns (single session)'
-- (1) Let the database do the arithmetic atomically, with the guard in WHERE.
UPDATE analytics.iso_accounts
SET balance = balance - 50, version = version + 1, updated_at = now()
WHERE account_id = 1 AND balance >= 50
RETURNING account_id, balance, version;

-- (2) Pessimistic: lock first, then read-compute-write in the same transaction.
BEGIN;
SELECT balance FROM analytics.iso_accounts WHERE account_id = 2 FOR UPDATE;
UPDATE analytics.iso_accounts SET balance = balance + 25, version = version + 1 WHERE account_id = 2
RETURNING account_id, balance, version;
COMMIT;

-- (3) Optimistic: carry the version you read; 0 rows updated means someone else won.
SELECT version AS seen_version FROM analytics.iso_accounts WHERE account_id = 3 \gset
UPDATE analytics.iso_accounts SET balance = balance + 5, version = version + 1
WHERE account_id = 3 AND version = :seen_version
RETURNING account_id, balance, version;                   -- 1 row: we won
UPDATE analytics.iso_accounts SET balance = balance + 5, version = version + 1
WHERE account_id = 3 AND version = :seen_version
RETURNING account_id, balance, version;                   -- 0 rows: stale version, re-read and retry

-- Transfer helper using pattern (2) with a fixed lock order (lowest id first)
-- so two opposite transfers can never deadlock.
CREATE OR REPLACE FUNCTION analytics.iso_transfer(p_from integer, p_to integer, p_amount numeric)
RETURNS TABLE (account_id integer, balance numeric)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_amount <= 0 OR p_from = p_to THEN
        RAISE EXCEPTION 'invalid transfer % -> % (%)', p_from, p_to, p_amount;
    END IF;
    PERFORM 1 FROM analytics.iso_accounts a
    WHERE a.account_id IN (p_from, p_to)
    ORDER BY a.account_id
    FOR UPDATE;
    UPDATE analytics.iso_accounts a SET balance = a.balance - p_amount, version = a.version + 1
    WHERE a.account_id = p_from AND a.balance >= p_amount;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'insufficient funds in account %', p_from USING ERRCODE = 'check_violation';
    END IF;
    UPDATE analytics.iso_accounts a SET balance = a.balance + p_amount, version = a.version + 1
    WHERE a.account_id = p_to;
    RETURN QUERY SELECT a.account_id, a.balance::numeric FROM analytics.iso_accounts a
                 WHERE a.account_id IN (p_from, p_to) ORDER BY a.account_id;
END $$;

SELECT * FROM analytics.iso_transfer(1, 2, 100);

-- =============================================================================
-- 6. WRITE SKEW: REPEATABLE READ allows it, SERIALIZABLE (SSI) prevents it
-- =============================================================================
\echo '== 6. Write skew under REPEATABLE READ (live, with Session B)'

-- Rule: at least one inspector must stay on call. Alice (us) and Bob (Session B)
-- each check the rule, see two on call, and take themselves off. Each transaction
-- is fine on its own; together they break the rule. They update DIFFERENT rows,
-- so there is no row-lock conflict and snapshot isolation does not notice.
\if :session_b_ok
UPDATE analytics.iso_oncall SET on_call = true;
BEGIN ISOLATION LEVEL REPEATABLE READ;              -- Session B's remote xact is also REPEATABLE READ
SELECT count(*) AS a_sees_on_call FROM analytics.iso_oncall   WHERE on_call;   -- 2
SELECT count(*) AS b_sees_on_call FROM analytics.iso_oncall_b WHERE on_call;   -- 2
UPDATE analytics.iso_oncall   SET on_call = false WHERE inspector = 'alice';
UPDATE analytics.iso_oncall_b SET on_call = false WHERE inspector = 'bob';
COMMIT;                                               -- both commit
SELECT inspector, on_call FROM analytics.iso_oncall ORDER BY inspector;  -- nobody on call: anomaly
SELECT count(*) FILTER (WHERE on_call) = 0 AS rule_violated FROM analytics.iso_oncall;
\else
\echo 'skipped (no loopback session)'
\endif

\echo '== 6b. The same race under SERIALIZABLE: SSI sees the rw-dependency cycle'
\if :session_b_ok
UPDATE analytics.iso_oncall SET on_call = true;
BEGIN ISOLATION LEVEL SERIALIZABLE;                  -- postgres_fdw makes Session B SERIALIZABLE too
SELECT count(*) AS a_sees_on_call FROM analytics.iso_oncall   WHERE on_call;
SELECT count(*) AS b_sees_on_call FROM analytics.iso_oncall_b WHERE on_call;
UPDATE analytics.iso_oncall   SET on_call = false WHERE inspector = 'alice';
UPDATE analytics.iso_oncall_b SET on_call = false WHERE inspector = 'bob';
-- Both backends hold SIRead predicate locks on what they read: that is the
-- information SSI uses to find "A read what B wrote AND B read what A wrote".
SELECT CASE WHEN l.pid = pg_backend_pid() THEN 'A (this session)' ELSE 'B (loopback)' END AS session,
       l.locktype, l.mode, count(*) AS locks
FROM pg_locks l
WHERE l.mode = 'SIReadLock' AND l.relation = 'analytics.iso_oncall'::regclass
GROUP BY 1, 2, 3 ORDER BY 1, 2;
-- COMMIT here would fail for one of the two with
--   ERROR: could not serialize access due to read/write dependencies among transactions
--   DETAIL: Reason code: Canceled on identification as a pivot, during commit attempt.
-- (Session B commits first inside our COMMIT, so the error would surface on our
-- COMMIT and stop this script; we roll back instead.)
ROLLBACK;
SELECT inspector, on_call FROM analytics.iso_oncall ORDER BY inspector;
\else
\echo 'skipped (no loopback session)'
\endif
-- Two-window version:
--   [Session A] BEGIN ISOLATION LEVEL SERIALIZABLE;
--   [Session A] SELECT count(*) FROM analytics.iso_oncall WHERE on_call;               -- 2
--   [Session B] BEGIN ISOLATION LEVEL SERIALIZABLE;
--   [Session B] SELECT count(*) FROM analytics.iso_oncall WHERE on_call;               -- 2
--   [Session A] UPDATE analytics.iso_oncall SET on_call = false WHERE inspector = 'alice';
--   [Session B] UPDATE analytics.iso_oncall SET on_call = false WHERE inspector = 'bob';
--   [Session A] COMMIT;   -- succeeds
--   [Session B] COMMIT;   -- ERROR 40001: could not serialize access ... retry
-- On retry B re-reads, sees only Bob on call, and stays on call.

\echo '== 6c. Fixing write skew without SERIALIZABLE: materialize the conflict with FOR UPDATE'
\if :session_b_ok
UPDATE analytics.iso_oncall SET on_call = true;
BEGIN ISOLATION LEVEL REPEATABLE READ;
-- Lock every row the rule depends on, then check and write.
SELECT count(*) AS a_sees_on_call
FROM (SELECT 1 FROM analytics.iso_oncall WHERE on_call FOR UPDATE) locked;
UPDATE analytics.iso_oncall SET on_call = false WHERE inspector = 'alice';
-- Session B runs the same protocol and has to wait for our locks (it gives up
-- after its 250 ms lock_timeout instead of waiting for our COMMIT).
DO $$
BEGIN
    PERFORM 1 FROM analytics.iso_oncall_b WHERE on_call FOR UPDATE;
    RAISE NOTICE 'Session B got the locks (unexpected)';
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'Session B must wait for A: %', split_part(SQLERRM, E'\n', 1);
END $$;
COMMIT;
SELECT inspector, on_call FROM analytics.iso_oncall ORDER BY inspector;  -- bob still on call
\else
\echo 'skipped (no loopback session)'
\endif
-- When the rule is about rows that might not exist yet (e.g. "no overlapping
-- bookings"), FOR UPDATE cannot lock the absent rows: use SERIALIZABLE, an
-- exclusion constraint, or an advisory lock on the rule's key instead.

-- =============================================================================
-- 7. SAVEPOINTS: partial rollback inside one transaction
-- =============================================================================
\echo '== 7. Savepoints'

BEGIN;
UPDATE analytics.iso_accounts SET balance = balance + 1 WHERE account_id = 1;
SAVEPOINT before_risky_step;
DO $$
BEGIN
    -- violates CHECK (balance >= 0); a PL/pgSQL EXCEPTION block is an implicit savepoint
    UPDATE analytics.iso_accounts SET balance = balance - 1000000 WHERE account_id = 2;
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'risky step failed and was rolled back on its own: %', SQLERRM;
END $$;
UPDATE analytics.iso_accounts SET balance = balance + 2 WHERE account_id = 3;
ROLLBACK TO SAVEPOINT before_risky_step;   -- undoes account 3's change, keeps account 1's
RELEASE SAVEPOINT before_risky_step;
COMMIT;
SELECT account_id, balance FROM analytics.iso_accounts ORDER BY account_id;
-- Cost note: each savepoint that writes gets a subtransaction xid. More than 64
-- open subtransactions per backend overflow the shared cache and slow every
-- snapshot in the cluster (PG17 adds subtransaction_buffers to size the SLRU).
-- Avoid EXCEPTION blocks inside tight loops.

-- =============================================================================
-- 8. RETRYING 40001 / 40P01 (client side)
-- =============================================================================
-- Serialization failures (40001) and deadlocks (40P01) abort the whole
-- transaction; the only correct reaction is to re-run it from BEGIN:
--   for attempt in 1..5:
--       try:   BEGIN ISOLATION LEVEL SERIALIZABLE; <work>; COMMIT; break
--       except SQLSTATE in ('40001', '40P01'):  ROLLBACK; sleep(jitter * 2^attempt)
-- A function cannot do this for its caller: it runs inside the caller's transaction.

-- =============================================================================
-- 9. MONITORING OPEN TRANSACTIONS
-- =============================================================================
\echo '== 9. Monitoring transactions'

-- Note: pg_stat_activity does not expose another session's isolation level; only
-- current_setting('transaction_isolation') in that session can.
CREATE OR REPLACE VIEW analytics.v_open_transactions AS
SELECT pid, usename, datname, application_name, state,
       backend_xid,                        -- set once the transaction has written
       backend_xmin,                       -- oldest snapshot it holds (pins VACUUM)
       now() - xact_start  AS xact_age,    -- wall-clock: genuinely now()
       now() - state_change AS in_state_for,
       wait_event_type, wait_event,
       left(query, 80) AS last_query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND backend_type = 'client backend';
COMMENT ON VIEW analytics.v_open_transactions IS
'Open client transactions with age, snapshot xmin and wait state; look for long idle-in-transaction sessions.';

SELECT pid, state, backend_xid, backend_xmin, last_query
FROM analytics.v_open_transactions
WHERE datname = current_database()
ORDER BY xact_age DESC
LIMIT 5;

-- Guard rails (seconds shown are examples; set per role or database):
--   ALTER ROLE app SET idle_in_transaction_session_timeout = '60s';
--   ALTER ROLE app SET transaction_timeout = '5min';        -- new in PostgreSQL 17
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('idle_in_transaction_session_timeout', 'transaction_timeout',
               'default_transaction_isolation', 'max_pred_locks_per_transaction')
ORDER BY name;

-- Commit/rollback, deadlock and serialization-conflict counters for this database.
SELECT datname, xact_commit, xact_rollback, deadlocks, conflicts
FROM pg_stat_database WHERE datname = current_database();

-- Close the loopback connection so it does not linger in pg_stat_activity.
SELECT count(*) FILTER (WHERE d) AS loopback_connections_closed
FROM (SELECT postgres_fdw_disconnect('m10_iso_session_b') AS d
      WHERE EXISTS (SELECT 1 FROM postgres_fdw_get_connections() c
                    WHERE c.server_name = 'm10_iso_session_b')) s;
