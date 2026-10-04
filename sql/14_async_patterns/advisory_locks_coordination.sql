-- File: sql/14_async_patterns/advisory_locks_coordination.sql
-- Purpose: coordinating application work with advisory locks and SKIP LOCKED queues
--
-- What this module teaches
--   1. Advisory locks are application-defined mutexes identified by a bigint (or two int4s);
--      PostgreSQL never takes them on its own
--   2. Session-level locks (pg_advisory_lock) survive COMMIT/ROLLBACK and are re-entrant
--      (lock twice = unlock twice); transaction-level locks (pg_advisory_xact_lock) are
--      released automatically at transaction end and cannot be unlocked manually
--   3. Blocking vs try variants, shared vs exclusive, lock_timeout to bound waits
--   4. Turning names into keys: hashtextextended() -> bigint, or a (namespace, id) int4 pair
--   5. A job queue with FOR UPDATE SKIP LOCKED, the usual better tool for "claim one item"
--   6. Inspecting pg_locks, and ending with NO advisory locks held
--
-- Two-session demos use the dblink extension to open a second connection to this database
-- (local trust auth in this lab).  If dblink is unavailable they are skipped with a NOTICE
-- and the equivalent steps are listed as [Session B] comments.
-- Safety: all tables are module-owned (schema coordination).

\echo '== 14 / advisory locks & SKIP LOCKED =='

CREATE SCHEMA IF NOT EXISTS coordination;

-- Helper view: advisory locks held or awaited in this database, decoded.
-- bigint keys appear as classid = high 32 bits, objid = low 32 bits, objsubid = 1;
-- two-int4 keys appear as classid = key1, objid = key2, objsubid = 2.
CREATE OR REPLACE VIEW coordination.advisory_locks AS
SELECT l.pid,
       l.pid = pg_backend_pid() AS is_me,
       l.mode,
       l.granted,
       CASE l.objsubid WHEN 1 THEN 'bigint' ELSE 'int4,int4' END AS key_kind,
       CASE l.objsubid
            WHEN 1 THEN ((l.classid::BIGINT << 32) | l.objid::BIGINT)::TEXT
            ELSE l.classid || ',' || l.objid END                   AS lock_key,
       l.virtualtransaction
FROM pg_locks l
WHERE l.locktype = 'advisory'
  AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database());

-- =============================================================================
-- 1. SESSION VS TRANSACTION LEVEL
-- =============================================================================
\echo '-- (a) session lock survives ROLLBACK'
BEGIN;
SELECT pg_advisory_lock(424242);
ROLLBACK;
SELECT count(*) AS my_locks_after_rollback FROM coordination.advisory_locks WHERE is_me;
SELECT pg_advisory_unlock(424242) AS unlocked;

\echo '-- (b) transaction lock is released at COMMIT'
BEGIN;
SELECT pg_advisory_xact_lock(424242);
SELECT count(*) AS my_locks_inside_tx FROM coordination.advisory_locks WHERE is_me;
COMMIT;
SELECT count(*) AS my_locks_after_commit FROM coordination.advisory_locks WHERE is_me;

\echo '-- (c) session locks are re-entrant: two acquisitions need two releases'
SELECT pg_advisory_lock(7), pg_advisory_lock(7);
SELECT pg_advisory_unlock(7) AS first_unlock,
       (SELECT count(*) FROM coordination.advisory_locks WHERE is_me) AS still_held;
SELECT pg_advisory_unlock(7) AS second_unlock;
-- A third unlock returns false with a WARNING ("you don't own a lock of type ExclusiveLock")
SET client_min_messages = error;
SELECT pg_advisory_unlock(7) AS third_unlock;
RESET client_min_messages;

\echo '-- (d) shared locks: many readers, exclusive waits for all of them'
SELECT pg_advisory_lock_shared(99), pg_try_advisory_lock_shared(99) AS second_shared_ok;
SELECT mode, count(*) FROM coordination.advisory_locks WHERE is_me GROUP BY mode;
SELECT pg_advisory_unlock_shared(99), pg_advisory_unlock_shared(99);

-- =============================================================================
-- 2. KEYS: FROM NAMES TO NUMBERS
-- =============================================================================
-- hashtext() is int4 (and abs() of it halves the space and still collides);
-- hashtextextended(text, seed) gives a 64-bit hash: collisions become negligible.
-- Alternative: a (namespace int4, id int4) pair, e.g. (table oid, row id), so different
-- subsystems can never collide.  bigint keys and int4-pair keys never conflict with each other.
SELECT name,
       hashtext(name)               AS int4_hash,
       hashtextextended(name, 0)    AS bigint_hash
FROM unnest(ARRAY['nightly_refresh', 'permit_processing_42', 'inventory_7_widget']) AS name;

SELECT pg_advisory_lock('civics.permit_applications'::regclass::oid::INT, 42) AS locked_pair;
SELECT key_kind, lock_key FROM coordination.advisory_locks WHERE is_me;
SELECT pg_advisory_unlock('civics.permit_applications'::regclass::oid::INT, 42);

-- =============================================================================
-- 3. CONFLICTS BETWEEN TWO SESSIONS (dblink as Session B)
-- =============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'dblink') THEN
        CREATE EXTENSION IF NOT EXISTS dblink;
    ELSE
        RAISE NOTICE 'dblink not available: two-session demos will be skipped';
    END IF;
END $$;

-- [Session B]  SELECT pg_advisory_lock(hashtextextended('nightly_refresh', 0));
-- [Session A]  SELECT pg_try_advisory_lock(...);            -> false, immediately
-- [Session A]  SET lock_timeout = '200ms'; SELECT pg_advisory_lock(...);   -> ERROR 55P03
-- [Session B]  SELECT pg_advisory_unlock(...);
DO $$
DECLARE
    k        BIGINT := hashtextextended('nightly_refresh', 0);
    got_it   BOOLEAN;
    b_pid    INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') THEN
        RAISE NOTICE 'skipping two-session advisory lock demo (no dblink)';
        RETURN;
    END IF;

    PERFORM dblink_connect('session_b', 'dbname=' || current_database() || ' user=' || current_user);
    BEGIN
        SELECT pid INTO b_pid FROM dblink('session_b', 'SELECT pg_backend_pid()') AS t(pid INT);
        PERFORM * FROM dblink('session_b', format('SELECT pg_advisory_lock(%s)', k)) AS t(x TEXT);
        RAISE NOTICE 'Session B (pid %) holds the nightly_refresh lock', b_pid;

        got_it := pg_try_advisory_lock(k);
        RAISE NOTICE 'Session A pg_try_advisory_lock -> % (no waiting)', got_it;

        BEGIN
            SET LOCAL lock_timeout = '200ms';
            PERFORM pg_advisory_lock(k);
            RAISE NOTICE 'unexpected: blocking lock acquired';
        EXCEPTION WHEN lock_not_available THEN
            RAISE NOTICE 'Session A pg_advisory_lock with lock_timeout=200ms -> %', SQLERRM;
        END;

        PERFORM * FROM dblink('session_b', format('SELECT pg_advisory_unlock(%s)', k)) AS t(x TEXT);
        got_it := pg_try_advisory_lock(k);
        RAISE NOTICE 'after Session B unlocked, Session A try -> %', got_it;
        IF got_it THEN PERFORM pg_advisory_unlock(k); END IF;

        PERFORM dblink_disconnect('session_b');
    EXCEPTION WHEN OTHERS THEN
        PERFORM dblink_disconnect('session_b');   -- the connection's locks die with it
        RAISE;
    END;
END $$;

-- =============================================================================
-- 4. A LOCK REGISTRY WITH LOGGING
-- =============================================================================
CREATE TABLE IF NOT EXISTS coordination.lock_registry (
    lock_id          BIGINT PRIMARY KEY,
    lock_name        TEXT NOT NULL UNIQUE,
    lock_description TEXT,
    lock_scope       TEXT CHECK (lock_scope IN ('session', 'transaction')) DEFAULT 'session',
    created_at       TIMESTAMPTZ DEFAULT now(),
    created_by       TEXT DEFAULT current_user
);

CREATE TABLE IF NOT EXISTS coordination.lock_acquisition_log (
    log_id                BIGSERIAL PRIMARY KEY,
    lock_id               BIGINT NOT NULL,
    lock_name             TEXT NOT NULL,
    application_name      TEXT,
    backend_pid           INTEGER,
    acquired_at           TIMESTAMPTZ DEFAULT clock_timestamp(),
    released_at           TIMESTAMPTZ,
    duration_seconds      NUMERIC GENERATED ALWAYS AS (EXTRACT(epoch FROM (released_at - acquired_at))) STORED,
    acquisition_type      TEXT CHECK (acquisition_type IN ('exclusive', 'shared', 'try_exclusive', 'try_shared')),
    acquired_successfully BOOLEAN DEFAULT TRUE,
    operation_context     TEXT,
    notes                 TEXT
);

-- Log rows of locks that are still held (by any backend that is still alive)
CREATE OR REPLACE VIEW coordination.active_locks AS
SELECT lr.lock_id, lr.lock_name, lr.lock_description, lal.application_name, lal.backend_pid,
       lal.acquired_at, now() - lal.acquired_at AS held_duration, lal.operation_context
FROM coordination.lock_registry lr
JOIN coordination.lock_acquisition_log lal ON lal.lock_id = lr.lock_id
WHERE lal.released_at IS NULL AND lal.acquired_successfully
ORDER BY lal.acquired_at;

CREATE OR REPLACE FUNCTION coordination.register_lock(
    lock_name        TEXT,
    lock_description TEXT DEFAULT NULL,
    lock_scope       TEXT DEFAULT 'session'
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT := hashtextextended(lock_name, 0);
BEGIN
    INSERT INTO coordination.lock_registry AS r (lock_id, lock_name, lock_description, lock_scope)
    VALUES (v_id, lock_name, lock_description, lock_scope)
    ON CONFLICT ON CONSTRAINT lock_registry_lock_name_key DO UPDATE
    SET lock_description = COALESCE(EXCLUDED.lock_description, r.lock_description),
        lock_scope       = EXCLUDED.lock_scope;
    RETURN v_id;
END $$;

-- Does THIS backend already hold the advisory lock?
CREATE OR REPLACE FUNCTION coordination.holds_lock(p_lock_id BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM coordination.advisory_locks
                   WHERE is_me AND granted AND key_kind = 'bigint' AND lock_key = p_lock_id::TEXT)
$$;

-- Non-blocking, NOT re-entrant: a second try from the same session returns false, which is
-- what callers of a "mutex" usually expect (raw session locks would silently stack).
CREATE OR REPLACE FUNCTION coordination.try_acquire_lock(lock_name TEXT, operation_context TEXT DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_id  BIGINT := coordination.register_lock(lock_name);
    v_got BOOLEAN;
BEGIN
    v_got := NOT coordination.holds_lock(v_id) AND pg_try_advisory_lock(v_id);
    INSERT INTO coordination.lock_acquisition_log
        (lock_id, lock_name, application_name, backend_pid, acquisition_type, acquired_successfully, operation_context)
    VALUES (v_id, lock_name, current_setting('application_name'), pg_backend_pid(), 'try_exclusive', v_got, operation_context);
    RETURN v_got;
END $$;

-- Blocking acquire with an optional timeout (uses lock_timeout, no busy-wait loop)
CREATE OR REPLACE FUNCTION coordination.acquire_lock(
    lock_name         TEXT,
    operation_context TEXT DEFAULT NULL,
    timeout_ms        INTEGER DEFAULT NULL
)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_id  BIGINT := coordination.register_lock(lock_name);
    v_got BOOLEAN := TRUE;
BEGIN
    IF coordination.holds_lock(v_id) THEN
        v_got := FALSE;
    ELSE
        BEGIN
            IF timeout_ms IS NOT NULL THEN
                PERFORM set_config('lock_timeout', timeout_ms || 'ms', true);
            END IF;
            PERFORM pg_advisory_lock(v_id);
        EXCEPTION WHEN lock_not_available THEN
            v_got := FALSE;
        END;
    END IF;
    INSERT INTO coordination.lock_acquisition_log
        (lock_id, lock_name, application_name, backend_pid, acquisition_type, acquired_successfully, operation_context)
    VALUES (v_id, lock_name, current_setting('application_name'), pg_backend_pid(), 'exclusive', v_got, operation_context);
    RETURN v_got;
END $$;

CREATE OR REPLACE FUNCTION coordination.release_lock(lock_name TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    v_id       BIGINT := hashtextextended(lock_name, 0);
    v_released BOOLEAN := FALSE;
BEGIN
    IF coordination.holds_lock(v_id) THEN
        v_released := pg_advisory_unlock(v_id);
    END IF;
    UPDATE coordination.lock_acquisition_log l
    SET released_at = clock_timestamp()
    WHERE l.lock_id = v_id AND l.backend_pid = pg_backend_pid()
      AND l.released_at IS NULL AND l.acquired_successfully;
    RETURN v_released;
END $$;

\echo '-- registry API: try / second try (refused) / release / try again'
SELECT coordination.try_acquire_lock('report_generation', 'first')   AS first_try,
       coordination.try_acquire_lock('report_generation', 'second')  AS second_try_same_session;
SELECT lock_name, operation_context FROM coordination.active_locks WHERE backend_pid = pg_backend_pid();
SELECT coordination.release_lock('report_generation') AS released,
       coordination.try_acquire_lock('report_generation', 'third') AS third_try;
SELECT coordination.release_lock('report_generation') AS released_again;

-- =============================================================================
-- 5. COORDINATION PATTERNS
-- =============================================================================
-- (a) Singleton job: only one instance cluster-wide; others skip instead of queueing.
--     The job is passed as a regprocedure, which validates it and prevents SQL injection.
CREATE OR REPLACE FUNCTION coordination.sample_job()
RETURNS VOID LANGUAGE sql AS $$ SELECT pg_sleep(0.05) $$;

CREATE OR REPLACE FUNCTION coordination.execute_singleton_job(job_name TEXT, job_function REGPROCEDURE)
RETURNS TABLE(execution_status TEXT, message TEXT, execution_time INTERVAL)
LANGUAGE plpgsql AS $$
DECLARE
    t0 TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF NOT coordination.try_acquire_lock('singleton_job_' || job_name, 'singleton ' || job_name) THEN
        RETURN QUERY SELECT 'SKIPPED'::TEXT, format('job %s is already running', job_name), clock_timestamp() - t0;
        RETURN;
    END IF;

    BEGIN
        EXECUTE format('SELECT %s()', job_function::regproc);
        RETURN QUERY SELECT 'COMPLETED'::TEXT, format('job %s completed', job_name), clock_timestamp() - t0;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 'FAILED'::TEXT, format('job %s failed: %s', job_name, SQLERRM), clock_timestamp() - t0;
    END;

    PERFORM coordination.release_lock('singleton_job_' || job_name);   -- always release
END $$;

SELECT execution_status, message
FROM coordination.execute_singleton_job('nightly_refresh', 'coordination.sample_job()');

-- While someone else holds it, a second runner skips (simulated by holding it ourselves)
SELECT coordination.try_acquire_lock('singleton_job_nightly_refresh', 'simulated other runner') AS held;
SELECT execution_status, message
FROM coordination.execute_singleton_job('nightly_refresh', 'coordination.sample_job()');
SELECT coordination.release_lock('singleton_job_nightly_refresh') AS released;

-- (b) Resource pool: N slots, each slot is one advisory lock.
CREATE OR REPLACE FUNCTION coordination.allocate_from_pool(pool_name TEXT, pool_size INTEGER, requester_id TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    FOR slot IN 1..pool_size LOOP
        IF coordination.try_acquire_lock(pool_name || '_slot_' || slot, 'pool allocation for ' || requester_id) THEN
            RETURN slot;
        END IF;
    END LOOP;
    RETURN -1;   -- pool exhausted
END $$;

CREATE OR REPLACE FUNCTION coordination.release_from_pool(pool_name TEXT, slot_number INTEGER, requester_id TEXT)
RETURNS BOOLEAN LANGUAGE sql AS $$
    SELECT coordination.release_lock(pool_name || '_slot_' || slot_number)
$$;

SELECT coordination.allocate_from_pool('export_workers', 2, 'w1') AS w1_slot,
       coordination.allocate_from_pool('export_workers', 2, 'w2') AS w2_slot,
       coordination.allocate_from_pool('export_workers', 2, 'w3') AS w3_slot;   -- -1: full
SELECT coordination.release_from_pool('export_workers', 1, 'w1'),
       coordination.release_from_pool('export_workers', 2, 'w2');

-- (c) Per-entity critical section with a TRANSACTION lock + double-check.
--     xact locks suit connection poolers (released at commit even if the client forgets).
DROP TABLE IF EXISTS coordination.permit_work;
CREATE TABLE coordination.permit_work AS
SELECT permit_id, permit_type::TEXT AS permit_type, status::TEXT AS status,
       NULL::TEXT AS reviewed_by, NULL::TIMESTAMPTZ AS reviewed_at
FROM civics.permit_applications
WHERE status = 'pending'
ORDER BY permit_id
LIMIT 50;
ALTER TABLE coordination.permit_work ADD PRIMARY KEY (permit_id);

CREATE OR REPLACE FUNCTION coordination.process_permit_application(p_permit_id BIGINT, processor_id TEXT DEFAULT current_user)
RETURNS TABLE(result_status TEXT, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    -- (namespace, id) key: table oid + row id, released automatically at transaction end
    IF NOT pg_try_advisory_xact_lock('coordination.permit_work'::regclass::oid::INT, p_permit_id::INT) THEN
        RETURN QUERY SELECT 'CONFLICT'::TEXT, 'another processor is working on this permit'::TEXT;
        RETURN;
    END IF;

    SELECT status INTO v_status FROM coordination.permit_work WHERE permit_id = p_permit_id;
    IF v_status IS NULL THEN
        RETURN QUERY SELECT 'NOT_FOUND'::TEXT, format('permit %s not found', p_permit_id);
    ELSIF v_status <> 'pending' THEN                      -- double-check after locking
        RETURN QUERY SELECT 'ALREADY_PROCESSED'::TEXT, format('permit is %s', v_status);
    ELSE
        UPDATE coordination.permit_work
        SET status = 'under_review', reviewed_by = processor_id, reviewed_at = now()
        WHERE permit_id = p_permit_id;
        PERFORM pg_notify('permit_events',
                          json_build_object('permit_id', p_permit_id, 'new_status', 'under_review')::TEXT);
        RETURN QUERY SELECT 'SUCCESS'::TEXT, 'moved to under_review'::TEXT;
    END IF;
END $$;

SELECT (SELECT min(permit_id) FROM coordination.permit_work) AS first_permit \gset
SELECT * FROM coordination.process_permit_application(:first_permit, 'clerk_a');
SELECT * FROM coordination.process_permit_application(:first_permit, 'clerk_b');   -- double-check catches it

-- (d) Inventory reservation: serialize per (merchant, product) to prevent overselling.
DROP TABLE IF EXISTS coordination.inventory;
CREATE TABLE coordination.inventory (
    merchant_id        BIGINT,
    product_name       TEXT,
    quantity_available INTEGER NOT NULL CHECK (quantity_available >= 0),
    quantity_reserved  INTEGER NOT NULL DEFAULT 0,
    last_updated       TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (merchant_id, product_name)
);
INSERT INTO coordination.inventory (merchant_id, product_name, quantity_available)
SELECT merchant_id, 'gift card', 10 FROM commerce.merchants WHERE merchant_id <= 5;

CREATE OR REPLACE FUNCTION coordination.reserve_inventory(
    p_merchant_id BIGINT, p_product TEXT, p_quantity INTEGER,
    p_reservation_id TEXT DEFAULT gen_random_uuid()::TEXT
)
RETURNS TABLE(reservation_status TEXT, reserved_quantity INTEGER, reservation_ref TEXT, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_stock   INTEGER;
    v_reserve INTEGER;
BEGIN
    -- xact lock: no unlock bookkeeping on any exit path
    PERFORM pg_advisory_xact_lock(hashtextextended(format('inventory:%s:%s', p_merchant_id, p_product), 0));

    SELECT quantity_available INTO v_stock
    FROM coordination.inventory WHERE merchant_id = p_merchant_id AND product_name = p_product;
    IF v_stock IS NULL THEN
        RETURN QUERY SELECT 'NOT_FOUND'::TEXT, 0, NULL::TEXT, 'product not found'::TEXT;
        RETURN;
    END IF;

    v_reserve := LEAST(v_stock, p_quantity);
    IF v_reserve = 0 THEN
        RETURN QUERY SELECT 'OUT_OF_STOCK'::TEXT, 0, NULL::TEXT, format('available: %s', v_stock);
        RETURN;
    END IF;

    UPDATE coordination.inventory
    SET quantity_available = quantity_available - v_reserve,
        quantity_reserved  = quantity_reserved + v_reserve,
        last_updated = now()
    WHERE merchant_id = p_merchant_id AND product_name = p_product;

    RETURN QUERY SELECT CASE WHEN v_reserve < p_quantity THEN 'PARTIAL' ELSE 'SUCCESS' END,
                        v_reserve, p_reservation_id, format('reserved %s unit(s)', v_reserve);
END $$;
-- (A row lock via SELECT ... FOR UPDATE would do the same job here; advisory locks shine when
--  the thing being protected is not a single row, e.g. "an external API call for merchant 3".)

SELECT reservation_status, reserved_quantity, message FROM coordination.reserve_inventory(1, 'gift card', 7);
SELECT reservation_status, reserved_quantity, message FROM coordination.reserve_inventory(1, 'gift card', 7);
SELECT reservation_status, reserved_quantity, message FROM coordination.reserve_inventory(1, 'gift card', 7);

-- =============================================================================
-- 6. JOB QUEUE WITH FOR UPDATE SKIP LOCKED
-- =============================================================================
-- For "give me the next unclaimed item", row locks + SKIP LOCKED beat advisory locks: the
-- claim is part of the same transaction as the work, and concurrent workers skip rows that
-- are locked instead of waiting on them.
DROP TABLE IF EXISTS coordination.job_queue;
CREATE TABLE coordination.job_queue (
    job_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    queue_name   TEXT NOT NULL DEFAULT 'default',
    job_type     TEXT NOT NULL,
    payload      JSONB,
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    priority     INTEGER NOT NULL DEFAULT 100,
    run_after    TIMESTAMPTZ NOT NULL DEFAULT now(),
    claimed_by   TEXT,
    claimed_at   TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT
);
CREATE INDEX ON coordination.job_queue (queue_name, priority, job_id) WHERE status = 'pending';

-- Enqueue: one geocoding job per new complaint in the last week of the dataset
INSERT INTO coordination.job_queue (job_type, payload, priority)
SELECT 'geocode_complaint', jsonb_build_object('complaint_id', complaint_id),
       CASE priority_level WHEN 'urgent' THEN 10 WHEN 'high' THEN 50 ELSE 100 END
FROM documents.complaint_records
WHERE submitted_at >= meta.as_of() - interval '7 days'
ORDER BY complaint_id;

CREATE OR REPLACE FUNCTION coordination.claim_next_task(
    task_queue TEXT DEFAULT 'default',
    worker_id  TEXT DEFAULT current_user,
    task_types TEXT[] DEFAULT NULL
)
RETURNS TABLE(task_id BIGINT, task_type TEXT, task_data JSONB, claimed_at TIMESTAMPTZ)
LANGUAGE sql AS $$
    UPDATE coordination.job_queue q
    SET status = 'processing', claimed_by = worker_id, claimed_at = now(), attempts = q.attempts + 1
    WHERE q.job_id = (
        SELECT j.job_id FROM coordination.job_queue j
        WHERE j.queue_name = task_queue
          AND j.status = 'pending'
          AND j.run_after <= now()
          AND (task_types IS NULL OR j.job_type = ANY (task_types))
        ORDER BY j.priority, j.job_id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    RETURNING q.job_id, q.job_type, q.payload, q.claimed_at
$$;

CREATE OR REPLACE FUNCTION coordination.complete_task(
    task_id       BIGINT,
    worker_id     TEXT DEFAULT current_user,
    result_status TEXT DEFAULT 'completed',
    result_data   JSONB DEFAULT NULL
)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    UPDATE coordination.job_queue q
    SET status       = CASE WHEN result_status = 'failed' AND q.attempts < 3 THEN 'pending' ELSE result_status END,
        completed_at = CASE WHEN result_status = 'completed' THEN now() END,
        run_after    = CASE WHEN result_status = 'failed' THEN now() + make_interval(secs => 30 * q.attempts) ELSE q.run_after END,
        last_error   = result_data->>'error'
    WHERE q.job_id = task_id AND q.claimed_by = worker_id AND q.status = 'processing';
    RETURN FOUND;
END $$;

SELECT count(*) AS jobs_enqueued, count(*) FILTER (WHERE priority = 10) AS urgent FROM coordination.job_queue;

\echo '-- Session B claims a job inside an open transaction; Session A skips it instead of waiting'
DO $$
DECLARE
    b_job BIGINT;
    a_job BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') THEN
        RAISE NOTICE 'skipping two-worker SKIP LOCKED demo (no dblink)';
        RETURN;
    END IF;
    PERFORM dblink_connect('worker_b', 'dbname=' || current_database() || ' user=' || current_user);
    BEGIN
        PERFORM dblink_exec('worker_b', 'BEGIN');
        SELECT id INTO b_job
        FROM dblink('worker_b', 'SELECT task_id FROM coordination.claim_next_task(''default'', ''worker_b'')') AS t(id BIGINT);

        SET LOCAL lock_timeout = '1s';   -- would only matter without SKIP LOCKED
        SELECT task_id INTO a_job FROM coordination.claim_next_task('default', 'worker_a');
        RAISE NOTICE 'worker_b (uncommitted) claimed job %, worker_a got job % without blocking', b_job, a_job;

        PERFORM dblink_exec('worker_b', 'ROLLBACK');   -- B crashes: its claim vanishes, job is pending again
        PERFORM dblink_disconnect('worker_b');
    EXCEPTION WHEN OTHERS THEN
        PERFORM dblink_disconnect('worker_b');
        RAISE;
    END;
END $$;
-- [Session B]  BEGIN; SELECT * FROM coordination.claim_next_task('default','worker_b');  -- keep open
-- [Session A]  SELECT * FROM coordination.claim_next_task('default','worker_a');         -- next job, no wait

-- A worker loop: claim, do the work, complete.  (Each claim must be its own statement:
-- calling claim_next_task() three times inside ONE query would see one snapshot.)
CREATE OR REPLACE FUNCTION coordination.run_worker(worker_id TEXT, max_jobs INTEGER DEFAULT 10)
RETURNS TABLE(task_id BIGINT, task_type TEXT, task_data JSONB, completed BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR i IN 1..max_jobs LOOP
        SELECT * INTO r FROM coordination.claim_next_task('default', worker_id);
        EXIT WHEN r.task_id IS NULL;
        -- ... real work would happen here ...
        task_id := r.task_id; task_type := r.task_type; task_data := r.task_data;
        completed := coordination.complete_task(r.task_id, worker_id);
        RETURN NEXT;
    END LOOP;
END $$;

\echo '-- a single worker draining three jobs (highest priority first)'
SELECT * FROM coordination.run_worker('worker_c', 3);

SELECT status, claimed_by, count(*) FROM coordination.job_queue
GROUP BY status, claimed_by ORDER BY status, claimed_by NULLS FIRST;

-- PITFALL: advisory locks in WHERE with LIMIT/ORDER BY can lock more rows than returned,
-- because the filter runs before the sort/limit.  These locks are never released by LIMIT.
SELECT job_id FROM coordination.job_queue
WHERE status = 'pending' AND pg_try_advisory_lock(job_id)
ORDER BY priority, job_id LIMIT 2;
SELECT count(*) AS advisory_locks_actually_taken FROM coordination.advisory_locks WHERE is_me;
SELECT pg_advisory_unlock_all();     -- releases every SESSION advisory lock of this backend

-- =============================================================================
-- 7. MONITORING
-- =============================================================================
CREATE OR REPLACE FUNCTION coordination.monitor_locks()
RETURNS TABLE(metric_name TEXT, metric_value TEXT, status TEXT, details TEXT)
LANGUAGE sql STABLE AS $$
    SELECT 'Advisory locks held (this DB)', count(*) FILTER (WHERE granted)::TEXT,
           CASE WHEN count(*) FILTER (WHERE granted) > 100 THEN 'WARNING' ELSE 'OK' END,
           'pg_locks locktype = advisory'
    FROM coordination.advisory_locks
    UNION ALL
    SELECT 'Advisory lock waiters', count(*) FILTER (WHERE NOT granted)::TEXT,
           CASE WHEN count(*) FILTER (WHERE NOT granted) > 0 THEN 'WARNING' ELSE 'OK' END,
           'sessions blocked in pg_advisory_lock()'
    FROM coordination.advisory_locks
    UNION ALL
    SELECT 'Acquisitions in the last hour', count(*)::TEXT, 'INFO', 'from lock_acquisition_log'
    FROM coordination.lock_acquisition_log WHERE acquired_at >= now() - interval '1 hour'
    UNION ALL
    SELECT 'Failed tries in the last hour', count(*)::TEXT,
           CASE WHEN count(*) > 10 THEN 'WARNING' ELSE 'OK' END, 'contention indicator'
    FROM coordination.lock_acquisition_log
    WHERE acquired_at >= now() - interval '1 hour' AND NOT acquired_successfully
$$;

-- Who holds which advisory lock, and for how long has that session been in its state?
-- A session lock can only be released by its owner: to free a stuck one you must end the
-- owning session (SELECT pg_terminate_backend(pid)), which this function only suggests.
CREATE OR REPLACE FUNCTION coordination.find_lock_holders()
RETURNS TABLE(pid INTEGER, lock_key TEXT, mode TEXT, application_name TEXT, state TEXT,
              state_age INTERVAL, suggested_action TEXT)
LANGUAGE sql STABLE AS $$
    SELECT l.pid, l.lock_key, l.mode, a.application_name, a.state,
           now() - a.state_change,
           CASE WHEN a.state = 'idle' AND now() - a.state_change > interval '1 hour'
                THEN format('SELECT pg_terminate_backend(%s);', l.pid)
                ELSE 'none' END
    FROM coordination.advisory_locks l
    JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.granted
    ORDER BY a.state_change
$$;

CREATE OR REPLACE FUNCTION coordination.cleanup_lock_logs(retention_days INTEGER DEFAULT 30)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE n INTEGER;
BEGIN
    DELETE FROM coordination.lock_acquisition_log WHERE acquired_at < now() - make_interval(days => retention_days);
    GET DIAGNOSTICS n = ROW_COUNT;
    -- close log rows whose backend no longer exists (its session locks died with it)
    UPDATE coordination.lock_acquisition_log l
    SET released_at = clock_timestamp(), notes = 'owner backend gone'
    WHERE l.released_at IS NULL AND l.acquired_successfully
      AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.pid = l.backend_pid);
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION coordination.setup_common_locks()
RETURNS TABLE(lock_name TEXT, lock_id BIGINT) LANGUAGE sql AS $$
    SELECT n, coordination.register_lock(n, d)
    FROM (VALUES ('backup_process', 'Database backup coordination'),
                 ('analytics_refresh', 'Materialized view refresh'),
                 ('data_migration', 'Data migration operations'),
                 ('system_maintenance', 'Maintenance tasks'),
                 ('report_generation', 'Long-running report generation')) v(n, d)
$$;

SELECT * FROM coordination.setup_common_locks() ORDER BY lock_name;
SELECT coordination.cleanup_lock_logs(30) AS old_log_rows_deleted;
SELECT * FROM coordination.monitor_locks();

-- =============================================================================
-- 8. END STATE: no advisory locks held by this session
-- =============================================================================
SELECT pg_advisory_unlock_all();
SELECT count(*) AS my_advisory_locks_remaining FROM coordination.advisory_locks WHERE is_me;
\echo '== advisory locks module complete =='
