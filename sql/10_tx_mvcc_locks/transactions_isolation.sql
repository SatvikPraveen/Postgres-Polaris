-- File: sql/10_tx_mvcc_locks/transactions_isolation.sql
-- Purpose: Transaction isolation levels and anomaly demonstrations

-- =============================================================================
-- ISOLATION LEVELS OVERVIEW
-- =============================================================================

-- PostgreSQL supports 4 isolation levels:
-- READ UNCOMMITTED (rarely used)
-- READ COMMITTED (default)
-- REPEATABLE READ
-- SERIALIZABLE (strictest)

-- =============================================================================
-- READ COMMITTED DEMONSTRATIONS
-- =============================================================================

-- Demo 1: Non-repeatable reads with READ COMMITTED
/*
-- Session 1:
BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT total_amount FROM commerce.orders WHERE order_id = 1;
-- Wait for Session 2 to update
SELECT total_amount FROM commerce.orders WHERE order_id = 1;  -- May see different value
COMMIT;

-- Session 2 (run during Session 1's wait):
BEGIN;
UPDATE commerce.orders SET total_amount = total_amount + 10 WHERE order_id = 1;
COMMIT;
*/

-- Demo setup function for isolation testing
CREATE OR REPLACE FUNCTION analytics.demo_isolation_setup()
RETURNS TEXT AS $$
BEGIN
    -- Create demo table for isolation testing
    CREATE TEMP TABLE isolation_test (
        id INTEGER PRIMARY KEY,
        balance NUMERIC(10,2),
        version INTEGER DEFAULT 1,
        updated_at TIMESTAMPTZ DEFAULT NOW()
    );

    INSERT INTO isolation_test VALUES
        (1, 1000.00, 1, NOW()),
        (2, 500.00, 1, NOW()),
        (3, 750.00, 1, NOW());

    RETURN 'Isolation test table created with sample data';
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- REPEATABLE READ DEMONSTRATIONS
-- =============================================================================

-- Demo 2: Repeatable Read prevents non-repeatable reads
CREATE OR REPLACE FUNCTION analytics.demo_repeatable_read()
RETURNS TABLE(
    step TEXT,
    balance NUMERIC,
    isolation_level TEXT
) AS $$
DECLARE
    step_counter INTEGER := 1;
BEGIN
    -- Ensure test data exists
    PERFORM analytics.demo_isolation_setup();

    -- Start REPEATABLE READ transaction
    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

    -- First read
    RETURN QUERY
    SELECT
        ('Step ' || step_counter || ': Initial read')::TEXT as step,
        it.balance,
        current_setting('transaction_isolation')::TEXT as isolation_level
    FROM isolation_test it WHERE id = 1;

    step_counter := step_counter + 1;

    -- Simulate concurrent update (would be done in another session)
    -- UPDATE isolation_test SET balance = 1500.00 WHERE id = 1;

    -- Second read - should be same as first in REPEATABLE READ
    RETURN QUERY
    SELECT
        ('Step ' || step_counter || ': Second read (same transaction)')::TEXT as step,
        it.balance,
        current_setting('transaction_isolation')::TEXT as isolation_level
    FROM isolation_test it WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PHANTOM READ DEMONSTRATIONS
-- =============================================================================

-- Demo 3: Phantom reads in REPEATABLE READ
CREATE OR REPLACE FUNCTION analytics.demo_phantom_reads()
RETURNS TABLE(
    step TEXT,
    record_count BIGINT,
    total_balance NUMERIC
) AS $$
BEGIN
    PERFORM analytics.demo_isolation_setup();

    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

    -- First aggregation
    RETURN QUERY
    SELECT
        'Step 1: Initial aggregation'::TEXT as step,
        COUNT(*) as record_count,
        SUM(balance) as total_balance
    FROM isolation_test
    WHERE balance > 600.00;

    -- Simulate concurrent insert (would be done in another session)
    -- This would cause phantom read in some databases, but PostgreSQL REPEATABLE READ prevents this

    -- Second aggregation
    RETURN QUERY
    SELECT
        'Step 2: Second aggregation (same transaction)'::TEXT as step,
        COUNT(*) as record_count,
        SUM(balance) as total_balance
    FROM isolation_test
    WHERE balance > 600.00;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SERIALIZABLE ISOLATION DEMONSTRATIONS
-- =============================================================================

-- Demo 4: Serialization failure with SERIALIZABLE
CREATE OR REPLACE FUNCTION analytics.demo_serializable_conflict()
RETURNS TEXT AS $$
DECLARE
    result TEXT := 'Serializable isolation demo:' || E'\n';
BEGIN
    PERFORM analytics.demo_isolation_setup();

    BEGIN
        SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

        -- Read data
        SELECT balance INTO STRICT result FROM isolation_test WHERE id = 1;
        result := result || 'Read balance: ' || result || E'\n';

        -- Simulate some business logic delay
        PERFORM pg_sleep(0.1);

        -- Update based on read data
        UPDATE isolation_test
        SET balance = balance * 1.1,
            version = version + 1,
            updated_at = NOW()
        WHERE id = 1;

        result := result || 'Updated balance successfully' || E'\n';

        COMMIT;

    EXCEPTION
        WHEN serialization_failure THEN
            result := result || 'Serialization failure detected - transaction rolled back' || E'\n';
            ROLLBACK;
        WHEN OTHERS THEN
            result := result || 'Other error: ' || SQLERRM || E'\n';
            ROLLBACK;
    END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PRACTICAL BUSINESS SCENARIO DEMOS
-- =============================================================================

-- Bank transfer with different isolation levels
CREATE OR REPLACE FUNCTION analytics.demo_bank_transfer(
    from_account INTEGER,
    to_account INTEGER,
    transfer_amount NUMERIC,
    isolation_level TEXT DEFAULT 'READ committed'
)
RETURNS TABLE(
    step TEXT,
    account_id INTEGER,
    balance NUMERIC,
    status TEXT
) AS $$
DECLARE
    from_balance NUMERIC;
    to_balance NUMERIC;
    isolation_command TEXT;
BEGIN
    -- Set isolation level
    isolation_command := 'SET TRANSACTION ISOLATION LEVEL ' || isolation_level;
    EXECUTE isolation_command;

    -- Check from account balance
    SELECT balance INTO from_balance
    FROM isolation_test
    WHERE id = from_account;

    RETURN QUERY SELECT 'Initial from account'::TEXT, from_account, from_balance, 'OK'::TEXT;

    -- Check to account balance
    SELECT balance INTO to_balance
    FROM isolation_test
    WHERE id = to_account;

    RETURN QUERY SELECT 'Initial to account'::TEXT, to_account, to_balance, 'OK'::TEXT;

    -- Validate sufficient funds
    IF from_balance < transfer_amount THEN
        RETURN QUERY SELECT 'Insufficient funds'::TEXT, from_account, from_balance, 'ERROR'::TEXT;
        RETURN;
    END IF;

    -- Perform transfer
    UPDATE isolation_test
    SET balance = balance - transfer_amount,
        version = version + 1,
        updated_at = NOW()
    WHERE id = from_account;

    UPDATE isolation_test
    SET balance = balance + transfer_amount,
        version = version + 1,
        updated_at = NOW()
    WHERE id = to_account;

    -- Return final balances
    RETURN QUERY
    SELECT
        'Final from account'::TEXT,
        id,
        balance,
        'TRANSFERRED'::TEXT
    FROM isolation_test
    WHERE id = from_account;

    RETURN QUERY
    SELECT
        'Final to account'::TEXT,
        id,
        balance,
        'RECEIVED'::TEXT
    FROM isolation_test
    WHERE id = to_account;

EXCEPTION
    WHEN serialization_failure THEN
        RETURN QUERY SELECT 'Transaction failed'::TEXT, -1, 0::NUMERIC, 'SERIALIZATION_FAILURE'::TEXT;
    WHEN OTHERS THEN
        RETURN QUERY SELECT 'Transaction failed'::TEXT, -1, 0::NUMERIC, SQLERRM::TEXT;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DEADLOCK SIMULATION
-- =============================================================================

-- Function to simulate potential deadlock scenario
CREATE OR REPLACE FUNCTION analytics.simulate_deadlock_scenario(
    session_id INTEGER
)
RETURNS TEXT AS $$
DECLARE
    result TEXT;
BEGIN
    PERFORM analytics.demo_isolation_setup();

    result := 'Session ' || session_id || ' starting deadlock simulation' || E'\n';

    -- Session 1 locks account 1 first, then account 2
    -- Session 2 locks account 2 first, then account 1
    -- This creates potential for deadlock

    IF session_id = 1 THEN
        -- Lock account 1
        UPDATE isolation_test SET balance = balance + 0.01 WHERE id = 1;
        result := result || 'Session 1: Locked account 1' || E'\n';

        -- Wait a bit to increase deadlock chance
        PERFORM pg_sleep(0.5);

        -- Try to lock account 2
        UPDATE isolation_test SET balance = balance + 0.01 WHERE id = 2;
        result := result || 'Session 1: Locked account 2' || E'\n';
    ELSE
        -- Lock account 2
        UPDATE isolation_test SET balance = balance + 0.01 WHERE id = 2;
        result := result || 'Session 2: Locked account 2' || E'\n';

        -- Wait a bit to increase deadlock chance
        PERFORM pg_sleep(0.5);

        -- Try to lock account 1
        UPDATE isolation_test SET balance = balance + 0.01 WHERE id = 1;
        result := result || 'Session 2: Locked account 1' || E'\n';
    END IF;

    RETURN result || 'Session ' || session_id || ' completed successfully';

EXCEPTION
    WHEN deadlock_detected THEN
        RETURN result || 'DEADLOCK DETECTED in session ' || session_id;
    WHEN OTHERS THEN
        RETURN result || 'ERROR in session ' || session_id || ': ' || SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ISOLATION LEVEL COMPARISON FUNCTIONS
-- =============================================================================

-- Compare behavior across isolation levels
CREATE OR REPLACE FUNCTION analytics.compare_isolation_levels()
RETURNS TABLE(
    isolation_level TEXT,
    dirty_reads_possible BOOLEAN,
    nonrepeatable_reads_possible BOOLEAN,
    phantom_reads_possible BOOLEAN,
    serialization_anomalies_possible BOOLEAN,
    performance_impact TEXT
) AS $$
BEGIN
    RETURN QUERY VALUES
        ('READ UNCOMMITTED', true, true, true, true, 'Highest performance, lowest consistency'),
        ('READ COMMITTED', false, true, true, true, 'Good performance, some consistency'),
        ('REPEATABLE READ', false, false, false, true, 'Lower performance, high consistency'),
        ('SERIALIZABLE', false, false, false, false, 'Lowest performance, highest consistency');
END;
$$ LANGUAGE plpgsql;

-- Monitor transaction isolation in active sessions
CREATE OR REPLACE FUNCTION analytics.monitor_transaction_isolation()
RETURNS TABLE(
    pid INTEGER,
    state TEXT,
    transaction_start TIMESTAMPTZ,
    isolation_level TEXT,
    waiting BOOLEAN,
    wait_event TEXT,
    query TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        pg_stat_activity.pid,
        pg_stat_activity.state,
        pg_stat_activity.xact_start as transaction_start,
        COALESCE(
            current_setting('transaction_isolation', true),
            'default (read committed)'
        ) as isolation_level,
        pg_stat_activity.wait_event IS NOT NULL as waiting,
        pg_stat_activity.wait_event,
        pg_stat_activity.query
    FROM pg_stat_activity
    WHERE pg_stat_activity.state IN ('active', 'idle in transaction')
        AND pg_stat_activity.pid != pg_backend_pid()
    ORDER BY pg_stat_activity.xact_start NULLS LAST;
END;
$$ LANGUAGE plpgsql;
