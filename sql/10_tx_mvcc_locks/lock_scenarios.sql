-- File: sql/10_tx_mvcc_locks/lock_scenarios.sql
-- Purpose: Heavyweight locks in practice: the table lock-mode conflict matrix
--          (documented and measured), row locks, NOWAIT / lock_timeout,
--          a SKIP LOCKED job queue, deadlocks, advisory locks and lock monitoring.
--
-- Single-session safe: the script never blocks.
--   * A session never conflicts with its own locks, so the competing session
--     ("Session B") is a loopback postgres_fdw connection to this same database.
--     It runs with lock_timeout = 200ms, so whenever it would wait on us it gives
--     up quickly with SQLSTATE 55P03 (lock_not_available), which we catch.
--     Its remote transaction ends when ours ends.
--   * Our own waits are bounded with NOWAIT or SET LOCAL lock_timeout.
--   * A real (detected) deadlock needs two independently waiting sessions; it is
--     given as `-- [Session A]` / `-- [Session B]` steps.
-- Idempotent: all objects are module-owned (analytics.lock_*); base data is never changed.

-- Older revisions of this file created these functions with other result shapes.
DROP FUNCTION IF EXISTS analytics.monitor_locks();
DROP FUNCTION IF EXISTS analytics.detect_lock_issues();

-- =============================================================================
-- 0. LAB SETUP
-- =============================================================================
\echo '== 0. Lab setup'

DROP TABLE IF EXISTS analytics.lock_matrix_target CASCADE;
CREATE TABLE analytics.lock_matrix_target (id integer PRIMARY KEY, v integer NOT NULL);
INSERT INTO analytics.lock_matrix_target VALUES (1, 0);

DROP TABLE IF EXISTS analytics.lock_accounts CASCADE;
CREATE TABLE analytics.lock_accounts (
    account_id integer PRIMARY KEY,
    balance    numeric(12,2) NOT NULL CHECK (balance >= 0)
);
INSERT INTO analytics.lock_accounts VALUES (1, 1000), (2, 500), (3, 750);

-- Job queue: one triage job per still-open complaint (status submitted/under_review).
DROP TABLE IF EXISTS analytics.lock_jobs CASCADE;
CREATE TABLE analytics.lock_jobs (
    job_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    complaint_id bigint      NOT NULL,
    priority     smallint    NOT NULL,          -- 1 = urgent ... 4 = low
    status       text        NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'running', 'done', 'failed')),
    worker       text,
    attempts     integer     NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL,
    started_at   timestamptz,
    finished_at  timestamptz
);
-- Workers only ever look for pending jobs in priority order: a partial index keeps
-- that lookup tiny no matter how many finished jobs accumulate.
CREATE INDEX lock_jobs_pending_idx ON analytics.lock_jobs (priority, job_id) WHERE status = 'pending';

INSERT INTO analytics.lock_jobs (complaint_id, priority, created_at)
SELECT complaint_id,
       CASE priority_level WHEN 'urgent' THEN 1 WHEN 'high' THEN 2 WHEN 'normal' THEN 3 ELSE 4 END,
       submitted_at
FROM documents.complaint_records
WHERE status IN ('submitted', 'under_review')
ORDER BY submitted_at DESC, complaint_id
LIMIT 12;

-- Session B: loopback connection (rebuilt every run; dbname follows clones).
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SERVER IF EXISTS m10_lock_session_b CASCADE;
DO $$
BEGIN
    EXECUTE format(
        'CREATE SERVER m10_lock_session_b FOREIGN DATA WRAPPER postgres_fdw
             OPTIONS (dbname %L, application_name %L, options %L)',
        current_database(), 'm10_lock_session_b',
        '-c lock_timeout=200 -c statement_timeout=10000');
    -- Superusers may connect without a password; other roles need one here.
    EXECUTE format('CREATE USER MAPPING FOR CURRENT_USER SERVER m10_lock_session_b OPTIONS (user %L)',
                   current_user);
END $$;

-- Remote-side views give Session B statements that postgres_fdw cannot push down
-- by itself (SKIP LOCKED, advisory-lock calls).
CREATE OR REPLACE VIEW analytics.lock_jobs_claimable AS
SELECT job_id, complaint_id, priority
FROM analytics.lock_jobs
WHERE status = 'pending'
ORDER BY priority, job_id
LIMIT 3
FOR UPDATE SKIP LOCKED;

-- The same query without SKIP LOCKED, to show what B would otherwise do.
CREATE OR REPLACE VIEW analytics.lock_jobs_next_waiting AS
SELECT job_id, complaint_id, priority
FROM analytics.lock_jobs
WHERE status = 'pending'
ORDER BY priority, job_id
LIMIT 3
FOR UPDATE;

CREATE OR REPLACE VIEW analytics.lock_try_report_lock AS
SELECT pg_try_advisory_xact_lock(hashtext('m10:nightly-report')) AS got_lock;

CREATE FOREIGN TABLE analytics.lock_matrix_target_b (id integer, v integer)
    SERVER m10_lock_session_b OPTIONS (schema_name 'analytics', table_name 'lock_matrix_target');
CREATE FOREIGN TABLE analytics.lock_accounts_b (account_id integer, balance numeric(12,2))
    SERVER m10_lock_session_b OPTIONS (schema_name 'analytics', table_name 'lock_accounts');
CREATE FOREIGN TABLE analytics.lock_jobs_claimable_b (job_id bigint, complaint_id bigint, priority smallint)
    SERVER m10_lock_session_b OPTIONS (schema_name 'analytics', table_name 'lock_jobs_claimable');
CREATE FOREIGN TABLE analytics.lock_jobs_next_waiting_b (job_id bigint, complaint_id bigint, priority smallint)
    SERVER m10_lock_session_b OPTIONS (schema_name 'analytics', table_name 'lock_jobs_next_waiting');
CREATE FOREIGN TABLE analytics.lock_try_report_lock_b (got_lock boolean)
    SERVER m10_lock_session_b OPTIONS (schema_name 'analytics', table_name 'lock_try_report_lock');
-- Read-only window on a base table (B only ever locks rows here; changes are rolled back).
CREATE FOREIGN TABLE analytics.lock_tax_payments_b (tax_id bigint, citizen_id bigint, payment_status text)
    SERVER m10_lock_session_b OPTIONS (schema_name 'civics', table_name 'tax_payments');

CREATE OR REPLACE FUNCTION analytics.lock_session_b_available()
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM analytics.lock_matrix_target_b LIMIT 1;
    RETURN true;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Loopback Session B unavailable (%); live contention demos will be skipped', SQLERRM;
    RETURN false;
END $$;

SELECT CASE WHEN analytics.lock_session_b_available() THEN 'true' ELSE 'false' END AS session_b_ok \gset

-- =============================================================================
-- 1. TABLE-LEVEL LOCK MODES: who takes what, and the documented conflict matrix
-- =============================================================================
\echo '== 1. Lock modes and the documented conflict matrix'

CREATE OR REPLACE VIEW analytics.lock_mode_reference AS
SELECT * FROM (VALUES
    (1, 'AccessShareLock',          'ACCESS SHARE',           'SELECT',
        ARRAY['AccessExclusiveLock']),
    (2, 'RowShareLock',             'ROW SHARE',              'SELECT ... FOR UPDATE/SHARE',
        ARRAY['ExclusiveLock','AccessExclusiveLock']),
    (3, 'RowExclusiveLock',         'ROW EXCLUSIVE',          'INSERT, UPDATE, DELETE, MERGE',
        ARRAY['ShareLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock']),
    (4, 'ShareUpdateExclusiveLock', 'SHARE UPDATE EXCLUSIVE', 'VACUUM, ANALYZE, CREATE INDEX CONCURRENTLY, most ALTER TABLE ... SET',
        ARRAY['ShareUpdateExclusiveLock','ShareLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock']),
    (5, 'ShareLock',                'SHARE',                  'CREATE INDEX (non-concurrent)',
        ARRAY['RowExclusiveLock','ShareUpdateExclusiveLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock']),
    (6, 'ShareRowExclusiveLock',    'SHARE ROW EXCLUSIVE',    'CREATE TRIGGER, some ALTER TABLE (e.g. ADD FOREIGN KEY)',
        ARRAY['RowExclusiveLock','ShareUpdateExclusiveLock','ShareLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock']),
    (7, 'ExclusiveLock',            'EXCLUSIVE',              'REFRESH MATERIALIZED VIEW CONCURRENTLY',
        ARRAY['RowShareLock','RowExclusiveLock','ShareUpdateExclusiveLock','ShareLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock']),
    (8, 'AccessExclusiveLock',      'ACCESS EXCLUSIVE',       'DROP/TRUNCATE, VACUUM FULL, most ALTER TABLE, LOCK TABLE (default)',
        ARRAY['AccessShareLock','RowShareLock','RowExclusiveLock','ShareUpdateExclusiveLock','ShareLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock'])
) AS t(strength, pg_locks_mode, sql_mode, typical_statements, conflicts_with);
COMMENT ON VIEW analytics.lock_mode_reference IS
'The eight table-level lock modes (as named in pg_locks), typical statements and documented conflicts.';

SELECT strength, sql_mode, typical_statements FROM analytics.lock_mode_reference ORDER BY strength;

-- Matrix: X = the two modes conflict (symmetric). Rows/columns in strength order.
SELECT r.sql_mode AS held_vs_requested,
       max(CASE WHEN c.strength = 1 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "AccSh",
       max(CASE WHEN c.strength = 2 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "RowSh",
       max(CASE WHEN c.strength = 3 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "RowEx",
       max(CASE WHEN c.strength = 4 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "ShUpdEx",
       max(CASE WHEN c.strength = 5 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "Share",
       max(CASE WHEN c.strength = 6 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "ShRowEx",
       max(CASE WHEN c.strength = 7 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "Excl",
       max(CASE WHEN c.strength = 8 THEN CASE WHEN c.pg_locks_mode = ANY (r.conflicts_with) THEN 'X' ELSE '.' END END) AS "AccEx"
FROM analytics.lock_mode_reference r CROSS JOIN analytics.lock_mode_reference c
GROUP BY r.strength, r.sql_mode
ORDER BY r.strength;

-- =============================================================================
-- 2. SEEING YOUR OWN LOCKS IN pg_locks
-- =============================================================================
\echo '== 2. Locks held by one transaction'

BEGIN;
SELECT * FROM analytics.lock_accounts WHERE account_id = 1 FOR UPDATE;   -- RowShareLock + tuple lock in xmax
UPDATE analytics.lock_accounts SET balance = balance + 1 WHERE account_id = 2;  -- RowExclusiveLock, assigns an xid
LOCK TABLE analytics.lock_matrix_target IN SHARE MODE;
SELECT l.locktype,
       COALESCE(l.relation::regclass::text, l.transactionid::text, l.virtualxid) AS object,
       l.mode, l.granted, l.fastpath
FROM pg_locks l
WHERE l.pid = pg_backend_pid()
  AND (l.relation IS NULL OR l.relation::regclass::text LIKE 'analytics.lock_%')
ORDER BY l.locktype, object, l.mode;
ROLLBACK;
-- Notes: every transaction holds an ExclusiveLock on its own virtualxid (and on
-- its transactionid once it writes); others wait on those to wait for "the
-- transaction", e.g. for a row lock. Weak locks (< ShareUpdateExclusive) on
-- relations are taken via the per-backend fast path (fastpath = t).

-- =============================================================================
-- 3. THE MATRIX, MEASURED: Session B probes while we hold each mode
-- =============================================================================
\echo '== 3. Empirical conflict check (we hold mode X; Session B runs SELECT / SELECT FOR UPDATE / UPDATE)'

\if :session_b_ok
CREATE TEMP TABLE IF NOT EXISTS lock_probe_results (
    held_mode text, held_strength int, probe text, probe_mode text, observed text);
TRUNCATE lock_probe_results;

DO $$
DECLARE
    m      record;
    p      record;
    result text;
BEGIN
    FOR m IN SELECT strength, sql_mode FROM analytics.lock_mode_reference ORDER BY strength LOOP
        FOR p IN SELECT * FROM (VALUES
                    (1, 'SELECT',            'AccessShareLock',  'SELECT count(*) FROM analytics.lock_matrix_target_b'),
                    (2, 'SELECT FOR UPDATE', 'RowShareLock',     'SELECT id FROM analytics.lock_matrix_target_b WHERE id = -1 FOR UPDATE'),
                    (3, 'UPDATE',            'RowExclusiveLock', 'UPDATE analytics.lock_matrix_target_b SET v = v WHERE id = -1')
                 ) AS v(ord, probe, probe_mode, sql) ORDER BY ord LOOP
            BEGIN
                -- subtransaction: our LOCK and B's remote work are both undone below
                EXECUTE format('LOCK TABLE analytics.lock_matrix_target IN %s MODE', m.sql_mode);
                EXECUTE p.sql;
                result := 'granted';
                RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'undo probe';
            EXCEPTION
                WHEN lock_not_available THEN result := 'BLOCKED';
                WHEN raise_exception    THEN NULL;  -- our own undo signal
            END;
            INSERT INTO lock_probe_results VALUES (m.sql_mode, m.strength, p.probe, p.probe_mode, result);
        END LOOP;
    END LOOP;
END $$;

SELECT r.held_mode,
       max(r.observed) FILTER (WHERE r.probe = 'SELECT')            AS "B: SELECT",
       max(r.observed) FILTER (WHERE r.probe = 'SELECT FOR UPDATE') AS "B: SELECT FOR UPDATE",
       max(r.observed) FILTER (WHERE r.probe = 'UPDATE')            AS "B: UPDATE",
       bool_and((r.observed = 'BLOCKED') = (r.probe_mode = ANY (ref.conflicts_with))) AS matches_docs
FROM lock_probe_results r
JOIN analytics.lock_mode_reference ref ON ref.sql_mode = r.held_mode
GROUP BY r.held_strength, r.held_mode
ORDER BY r.held_strength;
\else
\echo 'skipped (no loopback session)'
\endif
-- Takeaway: plain reads are blocked only by ACCESS EXCLUSIVE, but an ALTER TABLE
-- that queues for ACCESS EXCLUSIVE also blocks every read queued behind it.
-- Always run DDL with a short lock_timeout and retry.

-- =============================================================================
-- 4. ROW LOCKS: NOWAIT and lock_timeout
-- =============================================================================
\echo '== 4. Row lock held by Session B; we refuse to wait (NOWAIT) or wait briefly (lock_timeout)'

\if :session_b_ok
BEGIN;
UPDATE analytics.lock_accounts_b SET balance = balance - 100 WHERE account_id = 1;  -- B now holds the row

DO $$
BEGIN
    PERFORM 1 FROM analytics.lock_accounts WHERE account_id = 1 FOR UPDATE NOWAIT;
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'NOWAIT: % (SQLSTATE %)', SQLERRM, SQLSTATE;
END $$;

SET LOCAL lock_timeout = '150ms';
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    UPDATE analytics.lock_accounts SET balance = balance + 1 WHERE account_id = 1;
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'lock_timeout: gave up after ~% ms: %',
        round(extract(epoch FROM clock_timestamp() - t0) * 1000), SQLERRM;
END $$;

-- Other rows are unaffected: row locks are per row.
UPDATE analytics.lock_accounts SET balance = balance + 1 WHERE account_id = 2 RETURNING account_id, balance;
ROLLBACK;
\else
\echo 'skipped (no loopback session)'
\endif

-- Row-lock strengths (weakest to strongest): FOR KEY SHARE, FOR SHARE,
-- FOR NO KEY UPDATE (taken by ordinary UPDATEs that do not change a key),
-- FOR UPDATE (DELETE, key-changing UPDATE). FK checks take FOR KEY SHARE on the
-- parent row, which does not conflict with FOR NO KEY UPDATE, so updating a
-- citizen's email does not block inserting their orders.

-- A NOWAIT business function on real data: pay the oldest open tax bill of a
-- citizen, or report immediately that another session is working on it.
CREATE OR REPLACE FUNCTION analytics.pay_tax_nowait(p_citizen_id bigint, p_amount numeric)
RETURNS TABLE (success boolean, message text, tax_id bigint, remaining numeric)
LANGUAGE plpgsql AS $$
DECLARE
    t civics.tax_payments%ROWTYPE;
    pay numeric;
BEGIN
    IF p_amount <= 0 THEN
        RETURN QUERY SELECT false, 'amount must be positive', NULL::bigint, NULL::numeric;
        RETURN;
    END IF;
    BEGIN
        SELECT * INTO t
        FROM civics.tax_payments tp
        WHERE tp.citizen_id = p_citizen_id AND tp.payment_status <> 'paid'
        ORDER BY tp.due_date, tp.tax_id
        LIMIT 1
        FOR UPDATE NOWAIT;
    EXCEPTION WHEN lock_not_available THEN
        RETURN QUERY SELECT false, 'bill is locked by another session - try again later', NULL::bigint, NULL::numeric;
        RETURN;
    END;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'no outstanding tax bills', NULL::bigint, NULL::numeric;
        RETURN;
    END IF;
    pay := least(p_amount, t.amount_due - t.amount_paid);       -- respects chk_tax_payment_logic
    UPDATE civics.tax_payments tp
    SET amount_paid    = tp.amount_paid + pay,
        payment_status = CASE WHEN tp.amount_paid + pay >= tp.amount_due THEN 'paid'::civics.payment_status
                              ELSE tp.payment_status END,
        payment_date   = COALESCE(tp.payment_date, now()),
        updated_at     = now()
    WHERE tp.tax_id = t.tax_id;
    RETURN QUERY SELECT true, format('paid %s', pay), t.tax_id, t.amount_due - t.amount_paid - pay;
END $$;

-- Demo on base data, always rolled back.
\if :session_b_ok
BEGIN;
SELECT tax_id FROM analytics.lock_tax_payments_b
WHERE tax_id = (SELECT tax_id FROM civics.tax_payments
                WHERE citizen_id = 14 AND payment_status <> 'paid'
                ORDER BY due_date, tax_id LIMIT 1)
FOR UPDATE;                                                   -- Session B grabs citizen 14's oldest bill
SELECT * FROM analytics.pay_tax_nowait(14, 100);              -- we get an immediate, friendly refusal
SELECT * FROM analytics.pay_tax_nowait(20, 100);              -- a different citizen is not affected
ROLLBACK;
\else
BEGIN;
SELECT * FROM analytics.pay_tax_nowait(20, 100);
ROLLBACK;
\endif

-- =============================================================================
-- 5. SKIP LOCKED: a concurrent job queue without contention
-- =============================================================================
\echo '== 5. Job queue with FOR UPDATE SKIP LOCKED'

-- Claim up to n jobs in one statement. Locked rows (claimed by other workers)
-- are skipped instead of waited for, so workers never block each other.
CREATE OR REPLACE FUNCTION analytics.claim_jobs(p_worker text, p_n integer DEFAULT 3)
RETURNS SETOF analytics.lock_jobs
LANGUAGE sql AS $$
    UPDATE analytics.lock_jobs j
    SET status = 'running', worker = p_worker, attempts = j.attempts + 1, started_at = now()
    WHERE j.job_id IN (SELECT job_id
                       FROM analytics.lock_jobs
                       WHERE status = 'pending'
                       ORDER BY priority, job_id
                       LIMIT p_n
                       FOR UPDATE SKIP LOCKED)
    RETURNING j.*;
$$;

\if :session_b_ok
BEGIN;
-- Worker A claims 3 jobs; its transaction (and row locks) stay open while it works.
SELECT job_id, complaint_id, priority, worker FROM analytics.claim_jobs('worker-A', 3) ORDER BY priority, job_id;
-- Worker B (separate backend) asks for the next 3 claimable jobs at the same time:
-- it silently skips A's locked rows and gets different ones, without waiting.
SELECT job_id, complaint_id, priority, 'worker-B' AS worker FROM analytics.lock_jobs_claimable_b ORDER BY priority, job_id;
-- Without SKIP LOCKED, B queues behind A's locked rows (here its lock_timeout fires).
DO $$
BEGIN
    PERFORM 1 FROM analytics.lock_jobs_next_waiting_b;
    RAISE NOTICE 'B got rows without waiting (unexpected)';
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'Plain FOR UPDATE: worker B would wait for worker A: %', split_part(SQLERRM, E'\n', 1);
END $$;
-- A finishes its work and commits; its row locks vanish with the transaction.
UPDATE analytics.lock_jobs SET status = 'done', finished_at = now()
WHERE worker = 'worker-A' AND status = 'running';
COMMIT;
\else
SELECT job_id, complaint_id, priority, worker FROM analytics.claim_jobs('worker-A', 3) ORDER BY priority, job_id;
UPDATE analytics.lock_jobs SET status = 'done', finished_at = now() WHERE worker = 'worker-A' AND status = 'running';
\endif

SELECT status, count(*) AS jobs, min(priority) AS best_priority
FROM analytics.lock_jobs GROUP BY status ORDER BY status;
-- Production notes: a crashed worker's lock disappears with its session, so
-- claim-and-hold-in-one-transaction needs no "stuck job" sweeper; if you instead
-- commit the 'running' state, add a heartbeat/timeout sweep. Keep job
-- transactions short, and VACUUM the queue table aggressively (see module 11).

-- =============================================================================
-- 6. DEADLOCKS
-- =============================================================================
\echo '== 6. Deadlocks'

-- Classic deadlock (two windows):
--   [Session A] BEGIN; UPDATE analytics.lock_accounts SET balance = balance - 10 WHERE account_id = 1;
--   [Session B] BEGIN; UPDATE analytics.lock_accounts SET balance = balance - 10 WHERE account_id = 2;
--   [Session A] UPDATE analytics.lock_accounts SET balance = balance + 10 WHERE account_id = 2;  -- waits for B
--   [Session B] UPDATE analytics.lock_accounts SET balance = balance + 10 WHERE account_id = 1;  -- waits for A: cycle
-- After deadlock_timeout (default 1s) the waiting backend runs the deadlock
-- detector, finds the cycle and aborts one transaction:
--   ERROR: deadlock detected (SQLSTATE 40P01)
--   DETAIL: Process 123 waits for ShareLock on transaction 456; blocked by process 789. ...
-- The survivor proceeds. The victim must retry the whole transaction.
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('deadlock_timeout', 'log_lock_waits', 'lock_timeout', 'max_locks_per_transaction')
ORDER BY name;

-- Prevention: acquire locks in one global order (here: ascending account_id),
-- so two transfers in opposite directions queue instead of crossing.
CREATE OR REPLACE FUNCTION analytics.lock_transfer(p_from integer, p_to integer, p_amount numeric)
RETURNS TABLE (account_id integer, balance numeric)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM analytics.lock_accounts a
    WHERE a.account_id IN (p_from, p_to)
    ORDER BY a.account_id
    FOR NO KEY UPDATE;                    -- the same strength an UPDATE would take
    UPDATE analytics.lock_accounts a SET balance = a.balance - p_amount WHERE a.account_id = p_from;
    UPDATE analytics.lock_accounts a SET balance = a.balance + p_amount WHERE a.account_id = p_to;
    RETURN QUERY SELECT a.account_id, a.balance::numeric FROM analytics.lock_accounts a
                 WHERE a.account_id IN (p_from, p_to) ORDER BY a.account_id;
END $$;

SELECT * FROM analytics.lock_transfer(2, 1, 50);

-- A deadlock the detector cannot see: the cycle runs through a network
-- connection. We hold account 1, Session B holds account 2, then we ask B
-- (synchronously) to take account 1. We wait on the socket, B waits on our lock;
-- no backend sees a lock-wait cycle. Only B's lock_timeout breaks it. The same
-- trap exists with dblink/postgres_fdw and with application code that holds a
-- transaction open while waiting for another connection.
\if :session_b_ok
BEGIN;
UPDATE analytics.lock_accounts   SET balance = balance - 10 WHERE account_id = 1;   -- A holds 1
UPDATE analytics.lock_accounts_b SET balance = balance - 10 WHERE account_id = 2;   -- B holds 2
DO $$
BEGIN
    UPDATE analytics.lock_accounts_b SET balance = balance + 10 WHERE account_id = 1;  -- B wants 1
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'Distributed deadlock broken only by Session B''s lock_timeout: %', split_part(SQLERRM, E'\n', 1);
END $$;
ROLLBACK;
\else
\echo 'skipped (no loopback session)'
\endif

-- =============================================================================
-- 7. ADVISORY LOCKS: application-defined mutexes
-- =============================================================================
\echo '== 7. Advisory locks'

-- Transaction-scoped (released at COMMIT/ROLLBACK) vs session-scoped (held until
-- unlocked or disconnect, even across ROLLBACK). Keys are bigint or (int, int);
-- hashtext() maps a name to a key (collisions are possible but rare).
\if :session_b_ok
BEGIN;
SELECT pg_try_advisory_xact_lock(hashtext('m10:nightly-report')) AS a_got_lock;
SELECT got_lock AS b_got_lock FROM analytics.lock_try_report_lock_b;     -- false: A holds it
SELECT l.locktype, l.classid, l.objid, l.mode, l.granted,
       CASE WHEN l.pid = pg_backend_pid() THEN 'A' ELSE 'B' END AS holder
FROM pg_locks l WHERE l.locktype = 'advisory' AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY holder;
COMMIT;
\else
SELECT pg_try_advisory_xact_lock(hashtext('m10:nightly-report')) AS a_got_lock;
\endif

-- Run-once guard for a batch job. Session-level lock, released on every path.
CREATE OR REPLACE FUNCTION analytics.process_with_advisory_lock(p_process text, p_payload text)
RETURNS TABLE (acquired_lock boolean, process_result text, lock_duration_ms numeric)
LANGUAGE plpgsql AS $$
DECLARE
    k  bigint := hashtext(p_process);
    t0 timestamptz := clock_timestamp();
BEGIN
    IF NOT pg_try_advisory_lock(k) THEN
        RETURN QUERY SELECT false, format('%s is already running in another session', p_process),
                            round(extract(epoch FROM clock_timestamp() - t0) * 1000, 2);
        RETURN;
    END IF;
    BEGIN
        PERFORM pg_sleep(0.05);              -- the exclusive work would go here
        PERFORM pg_advisory_unlock(k);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_advisory_unlock(k);       -- session locks survive errors: always unlock
        RAISE;
    END;
    RETURN QUERY SELECT true, format('%s completed: %s', p_process, p_payload),
                        round(extract(epoch FROM clock_timestamp() - t0) * 1000, 2);
END $$;

SELECT acquired_lock, process_result FROM analytics.process_with_advisory_lock('m10:recalc-balances', 'ok');
-- (Module 14 covers advisory-lock coordination patterns in depth.)

-- =============================================================================
-- 8. LOCK MONITORING
-- =============================================================================
\echo '== 8. Lock monitoring'

-- All heavyweight locks in this database, waiting ones first.
CREATE OR REPLACE FUNCTION analytics.monitor_locks()
RETURNS TABLE (pid integer, application_name text, locktype text, object text, mode text,
               granted boolean, waiting_for interval, state text, query text)
LANGUAGE sql STABLE AS $$
    SELECT l.pid, a.application_name, l.locktype,
           COALESCE(l.relation::regclass::text, l.transactionid::text, l.virtualxid,
                    l.locktype || ':' || l.objid),
           l.mode, l.granted,
           now() - l.waitstart,                          -- waitstart: PostgreSQL 14+
           a.state, left(a.query, 60)
    FROM pg_locks l
    LEFT JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
       OR l.locktype IN ('transactionid', 'virtualxid')
    ORDER BY l.granted, l.waitstart NULLS LAST, l.pid;
$$;

-- Who blocks whom: pg_blocking_pids() understands the conflict matrix, lock
-- queues and parallel-query groups (joining pg_locks on relation and mode does not).
CREATE OR REPLACE FUNCTION analytics.detect_lock_issues()
RETURNS TABLE (blocked_pid integer, blocking_pid integer, blocked_wait interval,
               blocked_query text, blocking_state text, blocking_query text, recommendation text)
LANGUAGE sql STABLE AS $$
    SELECT w.pid, b.pid,
           now() - w.query_start,
           left(w.query, 60), b.state, left(b.query, 60),
           CASE
               WHEN b.state = 'idle in transaction'
                    THEN 'Blocker is idle in transaction: fix the app or set idle_in_transaction_session_timeout'
               WHEN now() - w.query_start > interval '30 seconds'
                    THEN 'Long wait: consider pg_cancel_backend(blocking_pid)'
               ELSE 'Monitor'
           END
    FROM pg_stat_activity w
    CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid)
    JOIN pg_stat_activity b ON b.pid = bp.pid
    WHERE w.wait_event_type = 'Lock'
    ORDER BY now() - w.query_start DESC;
$$;

SELECT * FROM analytics.detect_lock_issues();       -- empty unless someone is waiting right now
SELECT pid, locktype, object, mode, granted FROM analytics.monitor_locks()
WHERE pid = pg_backend_pid() AND locktype = 'relation'
ORDER BY object LIMIT 5;

-- Close the loopback connection.
SELECT count(*) FILTER (WHERE d) AS loopback_connections_closed
FROM (SELECT postgres_fdw_disconnect('m10_lock_session_b') AS d
      WHERE EXISTS (SELECT 1 FROM postgres_fdw_get_connections() c
                    WHERE c.server_name = 'm10_lock_session_b')) s;
