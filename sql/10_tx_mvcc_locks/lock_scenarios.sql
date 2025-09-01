-- File: sql/10_tx_mvcc_locks/lock_scenarios.sql
-- Purpose: Deadlocks, NOWAIT, SKIP LOCKED patterns and lock conflict resolution

-- =============================================================================
-- LOCK CONFLICT SCENARIOS
-- =============================================================================

-- Function to demonstrate lock conflicts
CREATE OR REPLACE FUNCTION analytics.demo_lock_conflicts()
RETURNS TABLE(
    scenario TEXT,
    session_id INTEGER,
    lock_type TEXT,
    object_locked TEXT,
    wait_time_sec NUMERIC,
    outcome TEXT
) AS $$
BEGIN
    -- Create demo table for lock testing
    CREATE TEMP TABLE lock_test_accounts (
        account_id INTEGER PRIMARY KEY,
        balance NUMERIC(10,2),
        version INTEGER DEFAULT 1
    ) ON COMMIT DROP;

    INSERT INTO lock_test_accounts VALUES
        (1, 1000.00, 1),
        (2, 500.00, 1),
        (3, 750.00, 1);

    -- Scenario 1: Row-level locks with SELECT FOR UPDATE
    RETURN QUERY
    SELECT
        'Row Lock Conflict'::TEXT,
        1,
        'FOR UPDATE'::TEXT,
        'account_id = 1'::TEXT,
        0.0,
        'Lock acquired successfully'::TEXT;

    -- Demo the actual locking (would block in concurrent sessions)
    PERFORM * FROM lock_test_accounts WHERE account_id = 1 FOR UPDATE;

    -- Scenario 2: NOWAIT example
    RETURN QUERY
    SELECT
        'NOWAIT Example'::TEXT,
        2,
        'FOR UPDATE NOWAIT'::TEXT,
        'account_id = 1'::TEXT,
        0.0,
        'Would fail immediately if locked'::TEXT;

    -- Scenario 3: SKIP LOCKED example
    RETURN QUERY
    SELECT
        'SKIP LOCKED Example'::TEXT,
        3,
        'FOR UPDATE SKIP LOCKED'::TEXT,
        'all unlocked rows'::TEXT,
        0.0,
        'Processes available rows only'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- NOWAIT PATTERNS
-- =============================================================================

-- Bank transfer with NOWAIT to avoid blocking
CREATE OR REPLACE FUNCTION civics.safe_tax_payment_with_nowait(
    p_citizen_id BIGINT,
    p_payment_amount NUMERIC(12,2)
)
RETURNS TABLE(
    success BOOLEAN,
    message TEXT,
    new_balance NUMERIC,
    processing_time_ms NUMERIC
) AS $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    current_balance NUMERIC;
    tax_record RECORD;
BEGIN
    start_time := clock_timestamp();

    -- Try to lock tax record with NOWAIT
    BEGIN
        SELECT * INTO tax_record
        FROM civics.tax_payments
        WHERE citizen_id = p_citizen_id
            AND payment_status != 'paid'
        ORDER BY due_date
        LIMIT 1
        FOR UPDATE NOWAIT;

        -- If we get here, we have the lock
        IF NOT FOUND THEN
            end_time := clock_timestamp();
            RETURN QUERY SELECT
                false,
                'No outstanding tax payments found'::TEXT,
                0::NUMERIC,
                EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
            RETURN;
        END IF;

        current_balance := tax_record.amount_due - tax_record.amount_paid;

        -- Process payment
        UPDATE civics.tax_payments
        SET amount_paid = amount_paid + p_payment_amount,
            payment_status = CASE
                WHEN amount_paid + p_payment_amount >= amount_due THEN 'paid'::civics.payment_status
                ELSE payment_status
            END,
            payment_date = CASE
                WHEN payment_date IS NULL THEN NOW()
                ELSE payment_date
            END
        WHERE tax_id = tax_record.tax_id;

        end_time := clock_timestamp();

        RETURN QUERY SELECT
            true,
            'Payment processed successfully'::TEXT,
            (current_balance - p_payment_amount),
            EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;

    EXCEPTION
        WHEN lock_not_available THEN
            end_time := clock_timestamp();
            RETURN QUERY SELECT
                false,
                'Tax record is locked by another session - try again later'::TEXT,
                NULL::NUMERIC,
                EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
        WHEN OTHERS THEN
            end_time := clock_timestamp();
            RETURN QUERY SELECT
                false,
                'Error: ' || SQLERRM,
                NULL::NUMERIC,
                EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
    END;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SKIP LOCKED PATTERNS
-- =============================================================================

-- Queue processing with SKIP LOCKED
CREATE TABLE IF NOT EXISTS analytics.processing_queue (
    queue_id BIGSERIAL PRIMARY KEY,
    task_type TEXT NOT NULL,
    task_data JSONB,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    worker_id TEXT,
    error_message TEXT
);

-- Function to process queue items with SKIP LOCKED
CREATE OR REPLACE FUNCTION analytics.process_queue_items(
    worker_id_param TEXT,
    batch_size INTEGER DEFAULT 10
)
RETURNS TABLE(
    tasks_processed INTEGER,
    tasks_skipped INTEGER,
    processing_time_sec NUMERIC,
    worker_id TEXT
) AS $$
DECLARE
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    task_record RECORD;
    processed_count INTEGER := 0;
    available_count INTEGER;
    total_pending INTEGER;
BEGIN
    start_time := clock_timestamp();

    -- Count total pending tasks
    SELECT COUNT(*) INTO total_pending
    FROM analytics.processing_queue
    WHERE status = 'pending';

    -- Process available tasks using SKIP LOCKED
    FOR task_record IN
        SELECT queue_id, task_type, task_data
        FROM analytics.processing_queue
        WHERE status = 'pending'
        ORDER BY created_at
        LIMIT batch_size
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Mark as started
        UPDATE analytics.processing_queue
        SET status = 'processing',
            started_at = NOW(),
            worker_id = worker_id_param
        WHERE queue_id = task_record.queue_id;

        -- Simulate task processing
        PERFORM pg_sleep(0.01); -- 10ms processing time

        -- Mark as completed
        UPDATE analytics.processing_queue
        SET status = 'completed',
            completed_at = NOW()
        WHERE queue_id = task_record.queue_id;

        processed_count := processed_count + 1;
    END LOOP;

    -- Count how many are still available
    SELECT COUNT(*) INTO available_count
    FROM analytics.processing_queue
    WHERE status = 'pending';

    end_time := clock_timestamp();

    RETURN QUERY SELECT
        processed_count,
        (total_pending - processed_count - available_count),
        EXTRACT(EPOCH FROM (end_time - start_time)),
        worker_id_param;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DEADLOCK DETECTION AND RESOLUTION
-- =============================================================================

-- Function to simulate and handle potential deadlocks
CREATE OR REPLACE FUNCTION analytics.simulate_deadlock_scenario(
    session_identifier TEXT,
    target_account_1 INTEGER DEFAULT 1,
    target_account_2 INTEGER DEFAULT 2
)
RETURNS TEXT AS $$
DECLARE
    result TEXT;
BEGIN
    -- Create temp accounts for deadlock demo
    CREATE TEMP TABLE deadlock_accounts (
        account_id INTEGER PRIMARY KEY,
        balance NUMERIC(10,2)
    );

    INSERT INTO deadlock_accounts VALUES (1, 1000), (2, 500);

    result := 'Session ' || session_identifier || ': ';

    BEGIN
        -- Session order determines deadlock potential
        IF session_identifier = 'A' THEN
            -- Session A: Lock account 1 first, then account 2
            PERFORM pg_sleep(0.1);
            UPDATE deadlock_accounts SET balance = balance - 100 WHERE account_id = target_account_1;
            result := result || 'Locked account ' || target_account_1 || '; ';

            PERFORM pg_sleep(0.2); -- Increase deadlock window
            UPDATE deadlock_accounts SET balance = balance + 100 WHERE account_id = target_account_2;
            result := result || 'Locked account ' || target_account_2 || '; ';

        ELSE
            -- Session B: Lock account 2 first, then account 1 (potential deadlock)
            PERFORM pg_sleep(0.1);
            UPDATE deadlock_accounts SET balance = balance - 50 WHERE account_id = target_account_2;
            result := result || 'Locked account ' || target_account_2 || '; ';

            PERFORM pg_sleep(0.2);
            UPDATE deadlock_accounts SET balance = balance + 50 WHERE account_id = target_account_1;
            result := result || 'Locked account ' || target_account_1 || '; ';
        END IF;

        result := result || 'Transaction completed successfully';

    EXCEPTION
        WHEN deadlock_detected THEN
            result := result || 'DEADLOCK DETECTED - Transaction aborted and will retry';
            ROLLBACK;
        WHEN OTHERS THEN
            result := result || 'ERROR: ' || SQLERRM;
            ROLLBACK;
    END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Deadlock-resistant money transfer function
CREATE OR REPLACE FUNCTION analytics.deadlock_resistant_transfer(
    from_account INTEGER,
    to_account INTEGER,
    transfer_amount NUMERIC(10,2),
    max_retries INTEGER DEFAULT 3
)
RETURNS TABLE(
    success BOOLEAN,
    attempt_number INTEGER,
    final_message TEXT,
    total_time_ms NUMERIC
) AS $
DECLARE
    retry_count INTEGER := 0;
    start_time TIMESTAMPTZ;
    account1 INTEGER;
    account2 INTEGER;
    result_msg TEXT;
BEGIN
    start_time := clock_timestamp();

    -- Always lock accounts in consistent order to prevent deadlocks
    account1 := LEAST(from_account, to_account);
    account2 := GREATEST(from_account, to_account);

    WHILE retry_count <= max_retries LOOP
        retry_count := retry_count + 1;

        BEGIN
            -- Lock accounts in consistent order
            PERFORM balance FROM deadlock_accounts WHERE account_id = account1 FOR UPDATE;
            PERFORM balance FROM deadlock_accounts WHERE account_id = account2 FOR UPDATE;

            -- Perform transfer
            UPDATE deadlock_accounts
            SET balance = balance - transfer_amount
            WHERE account_id = from_account;

            UPDATE deadlock_accounts
            SET balance = balance + transfer_amount
            WHERE account_id = to_account;

            result_msg := 'Transfer completed successfully on attempt ' || retry_count;

            RETURN QUERY SELECT
                true,
                retry_count,
                result_msg,
                EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;
            RETURN;

        EXCEPTION
            WHEN deadlock_detected THEN
                IF retry_count >= max_retries THEN
                    RETURN QUERY SELECT
                        false,
                        retry_count,
                        'Transfer failed after ' || max_retries || ' attempts due to deadlocks'::TEXT,
                        EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;
                    RETURN;
                END IF;

                -- Wait before retry with exponential backoff
                PERFORM pg_sleep(0.1 * retry_count);
                CONTINUE;
        END;
    END LOOP;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- ADVISORY LOCKS FOR COORDINATION
-- =============================================================================

-- Use advisory locks for application-level coordination
CREATE OR REPLACE FUNCTION analytics.process_with_advisory_lock(
    process_name TEXT,
    process_data TEXT
)
RETURNS TABLE(
    acquired_lock BOOLEAN,
    process_result TEXT,
    lock_duration_ms NUMERIC
) AS $
DECLARE
    lock_id BIGINT;
    start_time TIMESTAMPTZ;
    got_lock BOOLEAN;
BEGIN
    -- Convert process name to numeric ID for advisory lock
    lock_id := abs(hashtext(process_name));
    start_time := clock_timestamp();

    -- Try to acquire advisory lock (non-blocking)
    got_lock := pg_try_advisory_lock(lock_id);

    IF NOT got_lock THEN
        RETURN QUERY SELECT
            false,
            'Process ' || process_name || ' is already running in another session'::TEXT,
            EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;
        RETURN;
    END IF;

    BEGIN
        -- Simulate exclusive process
        PERFORM pg_sleep(0.5);

        RETURN QUERY SELECT
            true,
            'Process ' || process_name || ' completed: ' || process_data,
            EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            true,
            'Process failed: ' || SQLERRM,
            EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;
    END;

    -- Release advisory lock
    PERFORM pg_advisory_unlock(lock_id);
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- LOCK MONITORING AND ANALYSIS
-- =============================================================================

-- Function to monitor current locks
CREATE OR REPLACE FUNCTION analytics.monitor_locks()
RETURNS TABLE(
    lock_type TEXT,
    database_name TEXT,
    relation_name TEXT,
    mode_name TEXT,
    granted BOOLEAN,
    pid INTEGER,
    query_start TIMESTAMPTZ,
    state TEXT,
    wait_event TEXT
) AS $
BEGIN
    RETURN QUERY
    SELECT
        l.locktype::TEXT,
        d.datname::TEXT,
        COALESCE(c.relname, 'N/A')::TEXT,
        l.mode::TEXT,
        l.granted,
        l.pid,
        a.query_start,
        a.state::TEXT,
        a.wait_event::TEXT
    FROM pg_locks l
    LEFT JOIN pg_database d ON l.database = d.oid
    LEFT JOIN pg_class c ON l.relation = c.oid
    LEFT JOIN pg_stat_activity a ON l.pid = a.pid
    WHERE l.locktype IN ('relation', 'tuple', 'transactionid', 'virtualxid')
        AND a.datname = current_database()
    ORDER BY l.granted, a.query_start;
END;
$ LANGUAGE plpgsql;

-- Function to detect lock waits and potential deadlocks
CREATE OR REPLACE FUNCTION analytics.detect_lock_issues()
RETURNS TABLE(
    issue_type TEXT,
    blocking_pid INTEGER,
    blocked_pid INTEGER,
    blocking_query TEXT,
    blocked_query TEXT,
    wait_duration INTERVAL,
    recommendation TEXT
) AS $
BEGIN
    RETURN QUERY
    SELECT
        'Lock Wait'::TEXT,
        bl.pid as blocking_pid,
        wa.pid as blocked_pid,
        bl.query as blocking_query,
        wa.query as blocked_query,
        clock_timestamp() - wa.query_start as wait_duration,
        CASE
            WHEN clock_timestamp() - wa.query_start > INTERVAL '30 seconds'
            THEN 'Consider terminating long-running blocking query'
            ELSE 'Monitor wait time'
        END::TEXT
    FROM pg_stat_activity wa
    JOIN pg_locks wl ON wa.pid = wl.pid AND NOT wl.granted
    JOIN pg_locks bl ON wl.relation = bl.relation AND wl.mode = bl.mode AND bl.granted
    JOIN pg_stat_activity bl_act ON bl.pid = bl_act.pid
    WHERE wa.state = 'active'
        AND bl_act.state = 'active'
        AND wa.pid != bl_act.pid;
END;
$ LANGUAGE plpgsql;
