-- File: sql/14_async_patterns/advisory_locks_coordination.sql
-- Purpose: coordination patterns using PostgreSQL advisory locks

-- =============================================================================
-- ADVISORY LOCK COORDINATION INFRASTRUCTURE
-- =============================================================================

-- Create schema for lock coordination
CREATE SCHEMA IF NOT EXISTS coordination;

-- Lock registry table
CREATE TABLE coordination.lock_registry (
    lock_id BIGINT PRIMARY KEY,
    lock_name TEXT NOT NULL UNIQUE,
    lock_description TEXT,
    lock_scope TEXT CHECK (lock_scope IN ('session', 'transaction', 'global')) DEFAULT 'session',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by TEXT DEFAULT current_user
);

-- Lock acquisition log
CREATE TABLE coordination.lock_acquisition_log (
    log_id BIGSERIAL PRIMARY KEY,
    lock_id BIGINT NOT NULL,
    lock_name TEXT NOT NULL,
    session_id TEXT,
    backend_pid INTEGER,
    acquired_at TIMESTAMPTZ DEFAULT NOW(),
    released_at TIMESTAMPTZ,
    duration_seconds INTEGER GENERATED ALWAYS AS (EXTRACT(epoch FROM (released_at - acquired_at))) STORED,
    acquisition_type TEXT CHECK (acquisition_type IN ('exclusive', 'shared', 'try_exclusive', 'try_shared')),
    acquired_successfully BOOLEAN DEFAULT TRUE,
    operation_context TEXT,
    notes TEXT
);

-- Current lock holders view
CREATE OR REPLACE VIEW coordination.active_locks AS
SELECT
    lr.lock_id,
    lr.lock_name,
    lr.lock_description,
    lal.session_id,
    lal.backend_pid,
    lal.acquired_at,
    NOW() - lal.acquired_at as held_duration,
    lal.operation_context
FROM coordination.lock_registry lr
JOIN coordination.lock_acquisition_log lal ON lr.lock_id = lal.lock_id
WHERE lal.released_at IS NULL
ORDER BY lal.acquired_at;

-- =============================================================================
-- ADVISORY LOCK WRAPPER FUNCTIONS
-- =============================================================================

-- Register a new advisory lock
CREATE OR REPLACE FUNCTION coordination.register_lock(
    lock_name TEXT,
    lock_description TEXT DEFAULT NULL,
    lock_scope TEXT DEFAULT 'session'
)
RETURNS BIGINT AS $$
DECLARE
    lock_id BIGINT;
BEGIN
    -- Generate lock ID from hash of name for consistency
    lock_id := abs(hashtext(lock_name))::BIGINT;

    INSERT INTO coordination.lock_registry (
        lock_id, lock_name, lock_description, lock_scope
    ) VALUES (
        lock_id, lock_name, lock_description, lock_scope
    ) ON CONFLICT (lock_name) DO UPDATE SET
        lock_description = EXCLUDED.lock_description,
        lock_scope = EXCLUDED.lock_scope;

    RETURN lock_id;
END;
$$ LANGUAGE plpgsql;

-- Acquire exclusive advisory lock with logging
CREATE OR REPLACE FUNCTION coordination.acquire_lock(
    lock_name TEXT,
    operation_context TEXT DEFAULT NULL,
    timeout_seconds INTEGER DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    lock_id BIGINT;
    acquired BOOLEAN := FALSE;
    start_time TIMESTAMPTZ := NOW();
BEGIN
    -- Get lock ID
    SELECT lr.lock_id INTO lock_id
    FROM coordination.lock_registry lr
    WHERE lr.lock_name = acquire_lock.lock_name;

    IF lock_id IS NULL THEN
        lock_id := coordination.register_lock(lock_name, 'Auto-registered lock');
    END IF;

    -- Try to acquire lock with timeout if specified
    IF timeout_seconds IS NOT NULL THEN
        -- Use a loop for timeout simulation (pg_advisory_lock doesn't have timeout)
        WHILE NOT acquired AND (EXTRACT(epoch FROM (NOW() - start_time)) < timeout_seconds) LOOP
            acquired := pg_try_advisory_lock(lock_id);
            IF NOT acquired THEN
                PERFORM pg_sleep(0.1); -- Wait 100ms before retry
            END IF;
        END LOOP;
    ELSE
        -- Blocking acquisition
        PERFORM pg_advisory_lock(lock_id);
        acquired := TRUE;
    END IF;

    -- Log acquisition attempt
    INSERT INTO coordination.lock_acquisition_log (
        lock_id, lock_name, session_id, backend_pid,
        acquisition_type, acquired_successfully, operation_context
    ) VALUES (
        lock_id, lock_name, current_setting('application_name', true),
        pg_backend_pid(), 'exclusive', acquired, operation_context
    );

    RETURN acquired;
END;
$$ LANGUAGE plpgsql;

-- Try to acquire lock (non-blocking)
CREATE OR REPLACE FUNCTION coordination.try_acquire_lock(
    lock_name TEXT,
    operation_context TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    lock_id BIGINT;
    acquired BOOLEAN;
BEGIN
    -- Get or register lock
    SELECT lr.lock_id INTO lock_id
    FROM coordination.lock_registry lr
    WHERE lr.lock_name = try_acquire_lock.lock_name;

    IF lock_id IS NULL THEN
        lock_id := coordination.register_lock(lock_name, 'Auto-registered lock');
    END IF;

    -- Try to acquire
    acquired := pg_try_advisory_lock(lock_id);

    -- Log attempt
    INSERT INTO coordination.lock_acquisition_log (
        lock_id, lock_name, session_id, backend_pid,
        acquisition_type, acquired_successfully, operation_context
    ) VALUES (
        lock_id, lock_name, current_setting('application_name', true),
        pg_backend_pid(), 'try_exclusive', acquired, operation_context
    );

    RETURN acquired;
END;
$$ LANGUAGE plpgsql;

-- Release advisory lock
CREATE OR REPLACE FUNCTION coordination.release_lock(
    lock_name TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    lock_id BIGINT;
    released BOOLEAN;
BEGIN
    -- Get lock ID
    SELECT lr.lock_id INTO lock_id
    FROM coordination.lock_registry lr
    WHERE lr.lock_name = release_lock.lock_name;

    IF lock_id IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Release lock
    released := pg_advisory_unlock(lock_id);

    -- Update log
    UPDATE coordination.lock_acquisition_log
    SET released_at = NOW()
    WHERE lock_acquisition_log.lock_id = release_lock.lock_id
    AND backend_pid = pg_backend_pid()
    AND released_at IS NULL;

    RETURN released;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COORDINATION PATTERNS
-- =============================================================================

-- Singleton job execution pattern
CREATE OR REPLACE FUNCTION coordination.execute_singleton_job(
    job_name TEXT,
    job_function TEXT, -- Function to execute
    max_execution_time INTERVAL DEFAULT '1 hour'
)
RETURNS TABLE(
    execution_status TEXT,
    message TEXT,
    execution_time INTERVAL
) AS $$
DECLARE
    lock_acquired BOOLEAN;
    start_time TIMESTAMPTZ;
    execution_result TEXT;
BEGIN
    start_time := NOW();

    -- Try to acquire lock for this job
    lock_acquired := coordination.try_acquire_lock(
        'singleton_job_' || job_name,
        'Singleton execution of ' || job_name
    );

    IF NOT lock_acquired THEN
        RETURN QUERY SELECT
            'SKIPPED'::TEXT,
            'Another instance of job "' || job_name || '" is already running',
            NOW() - start_time;
        RETURN;
    END IF;

    -- Execute the job
    BEGIN
        EXECUTE 'SELECT ' || job_function || '()';
        execution_result := 'SUCCESS';

        RETURN QUERY SELECT
            'COMPLETED'::TEXT,
            'Job "' || job_name || '" completed successfully',
            NOW() - start_time;

    EXCEPTION WHEN OTHERS THEN
        execution_result := 'FAILED: ' || SQLERRM;

        RETURN QUERY SELECT
            'FAILED'::TEXT,
            'Job "' || job_name || '" failed: ' || SQLERRM,
            NOW() - start_time;
    END;

    -- Always release the lock
    PERFORM coordination.release_lock('singleton_job_' || job_name);
END;
$$ LANGUAGE plpgsql;

-- Resource pool coordination
CREATE OR REPLACE FUNCTION coordination.allocate_from_pool(
    pool_name TEXT,
    pool_size INTEGER,
    requester_id TEXT,
    allocation_timeout INTEGER DEFAULT 30
)
RETURNS INTEGER AS $$
DECLARE
    allocated_slot INTEGER;
    slot_number INTEGER;
    lock_acquired BOOLEAN;
BEGIN
    -- Try to allocate a slot from the pool
    FOR slot_number IN 1..pool_size LOOP
        lock_acquired := coordination.try_acquire_lock(
            pool_name || '_slot_' || slot_number,
            'Pool allocation for ' || requester_id
        );

        IF lock_acquired THEN
            RETURN slot_number;
        END IF;
    END LOOP;

    -- No slots available
    RETURN -1;
END;
$$ LANGUAGE plpgsql;

-- Release pool resource
CREATE OR REPLACE FUNCTION coordination.release_from_pool(
    pool_name TEXT,
    slot_number INTEGER,
    requester_id TEXT
)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN coordination.release_lock(pool_name || '_slot_' || slot_number);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- BUSINESS LOGIC COORDINATION EXAMPLES
-- =============================================================================

-- Coordinate permit processing to prevent duplicates
CREATE OR REPLACE FUNCTION coordination.process_permit_application(
    application_id BIGINT,
    processor_id TEXT DEFAULT current_user
)
RETURNS TABLE(
    result_status TEXT,
    message TEXT,
    processing_time INTERVAL
) AS $$
DECLARE
    lock_acquired BOOLEAN;
    start_time TIMESTAMPTZ := NOW();
    current_status TEXT;
    permit_type TEXT;
BEGIN
    -- Get permit details
    SELECT status, civics.permit_applications.permit_type
    INTO current_status, permit_type
    FROM civics.permit_applications
    WHERE civics.permit_applications.application_id = process_permit_application.application_id;

    IF current_status IS NULL THEN
        RETURN QUERY SELECT
            'ERROR'::TEXT,
            'Permit application not found',
            NOW() - start_time;
        RETURN;
    END IF;

    -- Acquire lock for this specific permit
    lock_acquired := coordination.acquire_lock(
        'permit_processing_' || application_id,
        'Processing permit ' || application_id || ' by ' || processor_id,
        30 -- 30 second timeout
    );

    IF NOT lock_acquired THEN
        RETURN QUERY SELECT
            'CONFLICT'::TEXT,
            'Another processor is already working on this permit',
            NOW() - start_time;
        RETURN;
    END IF;

    -- Check status again (double-check pattern)
    SELECT status INTO current_status
    FROM civics.permit_applications
    WHERE civics.permit_applications.application_id = process_permit_application.application_id;

    IF current_status != 'pending' THEN
        PERFORM coordination.release_lock('permit_processing_' || application_id);
        RETURN QUERY SELECT
            'ALREADY_PROCESSED'::TEXT,
            'Permit status is ' || current_status || ', no action needed',
            NOW() - start_time;
        RETURN;
    END IF;

    -- Simulate processing work
    UPDATE civics.permit_applications
    SET
        status = 'under_review',
        last_updated = NOW(),
        reviewed_by = processor_id
    WHERE civics.permit_applications.application_id = process_permit_application.application_id;

    -- Release lock
    PERFORM coordination.release_lock('permit_processing_' || application_id);

    -- Notify about status change
    PERFORM messaging.notify_channel(
        'permit_status_updates',
        'status_updated',
        json_build_object(
            'application_id', application_id,
            'new_status', 'under_review',
            'processor_id', processor_id
        ),
        processor_id
    );

    RETURN QUERY SELECT
        'SUCCESS'::TEXT,
        'Permit moved to under_review status',
        NOW() - start_time;
END;
$$ LANGUAGE plpgsql;

-- Coordinate inventory updates to prevent overselling
CREATE OR REPLACE FUNCTION coordination.reserve_inventory(
    merchant_id BIGINT,
    product_name TEXT,
    quantity_requested INTEGER,
    reservation_id TEXT DEFAULT gen_random_uuid()::TEXT
)
RETURNS TABLE(
    reservation_status TEXT,
    reserved_quantity INTEGER,
    reservation_ref TEXT,
    message TEXT
) AS $$
DECLARE
    lock_acquired BOOLEAN;
    current_stock INTEGER;
    can_reserve INTEGER;
BEGIN
    -- Acquire inventory lock for this merchant/product
    lock_acquired := coordination.acquire_lock(
        'inventory_' || merchant_id || '_' || replace(product_name, ' ', '_'),
        'Inventory reservation for ' || quantity_requested || ' units',
        10 -- 10 second timeout
    );

    IF NOT lock_acquired THEN
        RETURN QUERY SELECT
            'TIMEOUT'::TEXT,
            0,
            NULL::TEXT,
            'Could not acquire inventory lock within timeout';
        RETURN;
    END IF;

    -- Check current stock
    SELECT quantity_available INTO current_stock
    FROM commerce.inventory
    WHERE commerce.inventory.merchant_id = reserve_inventory.merchant_id
    AND product_name = reserve_inventory.product_name;

    IF current_stock IS NULL THEN
        PERFORM coordination.release_lock('inventory_' || merchant_id || '_' || replace(product_name, ' ', '_'));
        RETURN QUERY SELECT
            'NOT_FOUND'::TEXT,
            0,
            NULL::TEXT,
            'Product not found in inventory';
        RETURN;
    END IF;

    -- Calculate how much we can actually reserve
    can_reserve := LEAST(current_stock, quantity_requested);

    IF can_reserve > 0 THEN
        -- Update inventory
        UPDATE commerce.inventory
        SET
            quantity_available = quantity_available - can_reserve,
            quantity_reserved = quantity_reserved + can_reserve,
            last_updated = NOW()
        WHERE commerce.inventory.merchant_id = reserve_inventory.merchant_id
        AND product_name = reserve_inventory.product_name;

        -- Log reservation (would need a reservations table in real implementation)

        PERFORM coordination.release_lock('inventory_' || merchant_id || '_' || replace(product_name, ' ', '_'));

        RETURN QUERY SELECT
            'SUCCESS'::TEXT,
            can_reserve,
            reservation_id,
            'Reserved ' || can_reserve || ' units';
    ELSE
        PERFORM coordination.release_lock('inventory_' || merchant_id || '_' || replace(product_name, ' ', '_'));

        RETURN QUERY SELECT
            'OUT_OF_STOCK'::TEXT,
            0,
            NULL::TEXT,
            'Insufficient stock (available: ' || current_stock || ')';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DISTRIBUTED TASK COORDINATION
-- =============================================================================

-- Claim next available task from queue
CREATE OR REPLACE FUNCTION coordination.claim_next_task(
    task_queue TEXT DEFAULT 'default',
    worker_id TEXT DEFAULT current_user,
    task_types TEXT[] DEFAULT NULL
)
RETURNS TABLE(
    task_id BIGINT,
    task_type TEXT,
    task_data JSONB,
    claimed_at TIMESTAMPTZ
) AS $$
DECLARE
    available_task RECORD;
    lock_acquired BOOLEAN;
BEGIN
    -- Find next available task
    FOR available_task IN
        SELECT mq.message_id, mq.event_type, mq.payload
        FROM messaging.message_queue mq
        WHERE mq.channel_name = task_queue
        AND mq.status = 'pending'
        AND (task_types IS NULL OR mq.event_type = ANY(task_types))
        ORDER BY mq.created_at
        FOR UPDATE SKIP LOCKED
        LIMIT 1
    LOOP
        -- Try to claim this specific task
        lock_acquired := coordination.try_acquire_lock(
            'task_' || available_task.message_id,
            'Task claimed by worker ' || worker_id
        );

        IF lock_acquired THEN
            -- Mark task as processing
            UPDATE messaging.message_queue
            SET status = 'processing', processed_at = NOW()
            WHERE message_id = available_task.message_id;

            RETURN QUERY SELECT
                available_task.message_id,
                available_task.event_type,
                available_task.payload,
                NOW();
            RETURN;
        END IF;
    END LOOP;

    -- No tasks available
    RETURN;
END;
$ LANGUAGE plpgsql;

-- Complete a claimed task
CREATE OR REPLACE FUNCTION coordination.complete_task(
    task_id BIGINT,
    worker_id TEXT DEFAULT current_user,
    result_status TEXT DEFAULT 'completed',
    result_data JSONB DEFAULT NULL
)
RETURNS BOOLEAN AS $
DECLARE
    task_released BOOLEAN;
BEGIN
    -- Update task status
    UPDATE messaging.message_queue
    SET
        status = result_status,
        processed_at = CASE WHEN processed_at IS NULL THEN NOW() ELSE processed_at END,
        error_message = CASE WHEN result_status = 'failed' THEN result_data->>'error' ELSE NULL END
    WHERE message_id = task_id;

    -- Release task lock
    task_released := coordination.release_lock('task_' || task_id);

    RETURN task_released AND FOUND;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- LOCK MONITORING AND MAINTENANCE
-- =============================================================================

-- Monitor lock usage and detect deadlocks
CREATE OR REPLACE FUNCTION coordination.monitor_locks()
RETURNS TABLE(
    metric_name TEXT,
    metric_value TEXT,
    status TEXT,
    details TEXT
) AS $
BEGIN
    -- Active locks count
    RETURN QUERY
    SELECT
        'Active Locks'::TEXT as metric_name,
        COUNT(*)::TEXT as metric_value,
        CASE WHEN COUNT(*) > 100 THEN 'WARNING' ELSE 'OK' END as status,
        'Currently held advisory locks' as details
    FROM coordination.active_locks;

    -- Long-held locks (> 1 hour)
    RETURN QUERY
    SELECT
        'Long-held Locks'::TEXT,
        COUNT(*)::TEXT,
        CASE WHEN COUNT(*) > 0 THEN 'WARNING' ELSE 'OK' END,
        'Locks held for more than 1 hour'
    FROM coordination.active_locks
    WHERE held_duration > INTERVAL '1 hour';

    -- Lock acquisition rate (last hour)
    RETURN QUERY
    SELECT
        'Acquisitions/Hour'::TEXT,
        COUNT(*)::TEXT,
        'INFO'::TEXT,
        'Lock acquisitions in the last hour'
    FROM coordination.lock_acquisition_log
    WHERE acquired_at >= NOW() - INTERVAL '1 hour';

    -- Failed acquisitions (last hour)
    RETURN QUERY
    SELECT
        'Failed Acquisitions'::TEXT,
        COUNT(*)::TEXT,
        CASE WHEN COUNT(*) > 10 THEN 'WARNING' ELSE 'OK' END,
        'Failed lock acquisitions in the last hour'
    FROM coordination.lock_acquisition_log
    WHERE acquired_at >= NOW() - INTERVAL '1 hour'
    AND acquired_successfully = FALSE;
END;
$ LANGUAGE plpgsql;

-- Clean up stale lock logs
CREATE OR REPLACE FUNCTION coordination.cleanup_lock_logs(
    retention_days INTEGER DEFAULT 30
)
RETURNS INTEGER AS $
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM coordination.lock_acquisition_log
    WHERE acquired_at < (NOW() - (retention_days || ' days')::INTERVAL);

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$ LANGUAGE plpgsql;

-- Force release abandoned locks
CREATE OR REPLACE FUNCTION coordination.release_abandoned_locks(
    max_hold_time INTERVAL DEFAULT '4 hours'
)
RETURNS TABLE(
    lock_name TEXT,
    backend_pid INTEGER,
    held_duration INTERVAL,
    force_released BOOLEAN
) AS $
DECLARE
    abandoned_lock RECORD;
    release_result BOOLEAN;
BEGIN
    FOR abandoned_lock IN
        SELECT al.lock_id, al.lock_name, al.backend_pid, al.held_duration
        FROM coordination.active_locks al
        WHERE al.held_duration > max_hold_time
    LOOP
        -- Try to release the lock (this will only work if the session still exists)
        BEGIN
            SELECT pg_advisory_unlock(abandoned_lock.lock_id) INTO release_result;

            -- Update the log
            UPDATE coordination.lock_acquisition_log
            SET released_at = NOW(), notes = 'Force released due to timeout'
            WHERE lock_id = abandoned_lock.lock_id
            AND backend_pid = abandoned_lock.backend_pid
            AND released_at IS NULL;

        EXCEPTION WHEN OTHERS THEN
            release_result := FALSE;
        END;

        RETURN QUERY SELECT
            abandoned_lock.lock_name,
            abandoned_lock.backend_pid,
            abandoned_lock.held_duration,
            release_result;
    END LOOP;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- DEMO AND TESTING FUNCTIONS
-- =============================================================================

-- Demo coordination patterns
CREATE OR REPLACE FUNCTION coordination.demo_coordination_patterns()
RETURNS TABLE(
    demo_step TEXT,
    result_status TEXT,
    description TEXT,
    example_usage TEXT
) AS $
DECLARE
    lock_acquired BOOLEAN;
    pool_slot INTEGER;
    task_claimed RECORD;
BEGIN
    -- Demo 1: Basic lock acquisition
    lock_acquired := coordination.try_acquire_lock('demo_lock', 'Demo test');

    RETURN QUERY SELECT
        'Basic Lock Test'::TEXT as demo_step,
        CASE WHEN lock_acquired THEN 'SUCCESS' ELSE 'FAILED' END as result_status,
        'Attempted to acquire demo_lock' as description,
        'SELECT coordination.try_acquire_lock(''my_lock'', ''my_operation'');' as example_usage;

    IF lock_acquired THEN
        PERFORM coordination.release_lock('demo_lock');
    END IF;

    -- Demo 2: Resource pool allocation
    pool_slot := coordination.allocate_from_pool('demo_pool', 3, 'demo_user');

    RETURN QUERY SELECT
        'Resource Pool Test'::TEXT,
        CASE WHEN pool_slot > 0 THEN 'SUCCESS' ELSE 'FAILED' END,
        'Allocated slot ' || pool_slot::TEXT || ' from pool of 3',
        'SELECT coordination.allocate_from_pool(''worker_pool'', 5, ''worker_1'');';

    IF pool_slot > 0 THEN
        PERFORM coordination.release_from_pool('demo_pool', pool_slot, 'demo_user');
    END IF;

    -- Demo 3: Singleton job pattern
    RETURN QUERY
    SELECT
        demo_step,
        result_status,
        description,
        example_usage
    FROM coordination.execute_singleton_job(
        'demo_job',
        'messaging.get_realtime_stats'
    );

    -- Demo 4: Show monitoring
    RETURN QUERY SELECT
        'Lock Monitoring'::TEXT,
        'INFO'::TEXT,
        'Current system status available',
        'SELECT * FROM coordination.monitor_locks();';
END;
$ LANGUAGE plpgsql;

-- Setup common coordination locks
CREATE OR REPLACE FUNCTION coordination.setup_common_locks()
RETURNS TEXT AS $
DECLARE
    result_msg TEXT := '';
BEGIN
    -- Register common application locks
    PERFORM coordination.register_lock('backup_process', 'Database backup coordination');
    PERFORM coordination.register_lock('analytics_refresh', 'Analytics materialized view refresh');
    PERFORM coordination.register_lock('data_migration', 'Data migration operations');
    PERFORM coordination.register_lock('system_maintenance', 'System maintenance tasks');
    PERFORM coordination.register_lock('report_generation', 'Long-running report generation');

    result_msg := 'Registered common coordination locks:' || E'\n';
    result_msg := result_msg || '- backup_process' || E'\n';
    result_msg := result_msg || '- analytics_refresh' || E'\n';
    result_msg := result_msg || '- data_migration' || E'\n';
    result_msg := result_msg || '- system_maintenance' || E'\n';
    result_msg := result_msg || '- report_generation' || E'\n';

    RETURN result_msg;
END;
$ LANGUAGE plpgsql;
