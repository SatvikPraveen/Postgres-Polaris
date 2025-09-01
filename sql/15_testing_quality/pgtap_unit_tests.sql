-- File: sql/15_testing_quality/pgtap_unit_tests.sql
-- Purpose: optional pgTAP unit tests for database functions and procedures

-- =============================================================================
-- PGTAP EXTENSION SETUP
-- =============================================================================

-- Install pgTAP extension (requires superuser privileges)
-- CREATE EXTENSION IF NOT EXISTS pgtap;

-- Create schema for test utilities
CREATE SCHEMA IF NOT EXISTS testing;

-- Test execution log
CREATE TABLE testing.test_execution_log (
    execution_id BIGSERIAL PRIMARY KEY,
    test_suite TEXT NOT NULL,
    test_name TEXT NOT NULL,
    test_status TEXT CHECK (test_status IN ('pass', 'fail', 'skip', 'error')) NOT NULL,
    test_description TEXT,
    error_message TEXT,
    execution_time_ms INTEGER,
    executed_at TIMESTAMPTZ DEFAULT NOW(),
    executed_by TEXT DEFAULT current_user
);

-- =============================================================================
-- TEST UTILITY FUNCTIONS
-- =============================================================================

-- Simple test assertion without pgTAP
CREATE OR REPLACE FUNCTION testing.assert_equals(
    expected ANYELEMENT,
    actual ANYELEMENT,
    test_name TEXT DEFAULT 'equality_test'
)
RETURNS BOOLEAN AS $$
BEGIN
    IF expected = actual OR (expected IS NULL AND actual IS NULL) THEN
        INSERT INTO testing.test_execution_log (test_suite, test_name, test_status, test_description)
        VALUES ('manual_tests', test_name, 'pass', 'Expected: ' || COALESCE(expected::TEXT, 'NULL') || ', Got: ' || COALESCE(actual::TEXT, 'NULL'));
        RETURN TRUE;
    ELSE
        INSERT INTO testing.test_execution_log (test_suite, test_name, test_status, test_description, error_message)
        VALUES ('manual_tests', test_name, 'fail', 'Assertion failed', 'Expected: ' || COALESCE(expected::TEXT, 'NULL') || ', Got: ' || COALESCE(actual::TEXT, 'NULL'));
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Test that value is not null
CREATE OR REPLACE FUNCTION testing.assert_not_null(
    value ANYELEMENT,
    test_name TEXT DEFAULT 'not_null_test'
)
RETURNS BOOLEAN AS $$
BEGIN
    IF value IS NOT NULL THEN
        INSERT INTO testing.test_execution_log (test_suite, test_name, test_status, test_description)
        VALUES ('manual_tests', test_name, 'pass', 'Value is not null');
        RETURN TRUE;
    ELSE
        INSERT INTO testing.test_execution_log (test_suite, test_name, test_status, test_description, error_message)
        VALUES ('manual_tests', test_name, 'fail', 'Expected non-null value', 'Got NULL');
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Test that condition is true
CREATE OR REPLACE FUNCTION testing.assert_true(
    condition BOOLEAN,
    test_name TEXT DEFAULT 'boolean_test'
)
RETURNS BOOLEAN AS $$
BEGIN
    IF condition THEN
        INSERT INTO testing.test_execution_log (test_suite, test_name, test_status, test_description)
        VALUES ('manual_tests', test_name, 'pass', 'Condition evaluated to true');
        RETURN TRUE;
    ELSE
        INSERT INTO testing.test_execution_log (test_suite, test_name, test_status, test_description, error_message)
        VALUES ('manual_tests', test_name, 'fail', 'Expected true condition', 'Condition was false or null');
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- CITIZEN MANAGEMENT TESTS
-- =============================================================================

-- Test citizen registration function
CREATE OR REPLACE FUNCTION testing.test_citizen_registration()
RETURNS VOID AS $$
DECLARE
    test_citizen_id BIGINT;
    citizen_count_before INTEGER;
    citizen_count_after INTEGER;
BEGIN
    -- Setup
    SELECT COUNT(*) INTO citizen_count_before FROM civics.citizens;

    -- Test citizen insertion
    INSERT INTO civics.citizens (
        first_name, last_name, email, phone,
        street_address, city, state_province, postal_code,
        date_of_birth, status
    ) VALUES (
        'Test', 'Citizen', 'test.citizen@test.com', '555-TEST-001',
        '123 Test St', 'Test City', 'TS', '12345',
        '1990-01-01', 'active'
    ) RETURNING citizen_id INTO test_citizen_id;

    -- Verify citizen was created
    PERFORM testing.assert_not_null(test_citizen_id, 'citizen_registration_returns_id');

    -- Verify count increased
    SELECT COUNT(*) INTO citizen_count_after FROM civics.citizens;
    PERFORM testing.assert_equals(citizen_count_before + 1, citizen_count_after, 'citizen_count_increased');

    -- Verify citizen data
    PERFORM testing.assert_equals('Test', first_name, 'citizen_first_name_correct')
    FROM civics.citizens WHERE citizen_id = test_citizen_id;

    PERFORM testing.assert_equals('active', status, 'citizen_default_status')
    FROM civics.citizens WHERE citizen_id = test_citizen_id;

    -- Cleanup
    DELETE FROM civics.citizens WHERE citizen_id = test_citizen_id;
END;
$$ LANGUAGE plpgsql;

-- Test citizen status updates
CREATE OR REPLACE FUNCTION testing.test_citizen_status_updates()
RETURNS VOID AS $$
DECLARE
    test_citizen_id BIGINT;
    old_status TEXT;
    new_status TEXT;
BEGIN
    -- Create test citizen
    INSERT INTO civics.citizens (
        first_name, last_name, email, phone,
        street_address, city, state_province, postal_code,
        date_of_birth, status
    ) VALUES (
        'Status', 'Test', 'status.test@test.com', '555-TEST-002',
        '456 Status St', 'Status City', 'ST', '67890',
        '1985-05-15', 'pending'
    ) RETURNING citizen_id INTO test_citizen_id;

    -- Test status update
    UPDATE civics.citizens
    SET status = 'active'
    WHERE citizen_id = test_citizen_id;

    -- Verify status changed
    SELECT status INTO new_status
    FROM civics.citizens
    WHERE citizen_id = test_citizen_id;

    PERFORM testing.assert_equals('active', new_status, 'citizen_status_update_works');

    -- Test invalid status (should fail)
    BEGIN
        UPDATE civics.citizens
        SET status = 'invalid_status'
        WHERE citizen_id = test_citizen_id;

        -- If we get here, test should fail
        PERFORM testing.assert_true(FALSE, 'invalid_status_should_be_rejected');
    EXCEPTION WHEN check_violation THEN
        -- This is expected
        PERFORM testing.assert_true(TRUE, 'invalid_status_properly_rejected');
    END;

    -- Cleanup
    DELETE FROM civics.citizens WHERE citizen_id = test_citizen_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PERMIT APPLICATION TESTS
-- =============================================================================

-- Test permit application workflow
CREATE OR REPLACE FUNCTION testing.test_permit_application_workflow()
RETURNS VOID AS $$
DECLARE
    test_citizen_id BIGINT;
    test_permit_id BIGINT;
    permit_status TEXT;
BEGIN
    -- Create test citizen
    INSERT INTO civics.citizens (
        first_name, last_name, email, phone,
        street_address, city, state_province, postal_code,
        date_of_birth, status
    ) VALUES (
        'Permit', 'Applicant', 'permit.applicant@test.com', '555-TEST-003',
        '789 Permit Ave', 'Permit City', 'PC', '11111',
        '1980-12-25', 'active'
    ) RETURNING citizen_id INTO test_citizen_id;

    -- Test permit application creation
    INSERT INTO civics.permit_applications (
        citizen_id, permit_type, description,
        estimated_cost, requested_start_date, status
    ) VALUES (
        test_citizen_id, 'building', 'Test building permit',
        5000.00, CURRENT_DATE + INTERVAL '30 days', 'pending'
    ) RETURNING application_id INTO test_permit_id;

    -- Verify permit was created
    PERFORM testing.assert_not_null(test_permit_id, 'permit_application_created');

    -- Test permit status progression
    UPDATE civics.permit_applications
    SET status = 'under_review'
    WHERE application_id = test_permit_id;

    SELECT status INTO permit_status
    FROM civics.permit_applications
    WHERE application_id = test_permit_id;

    PERFORM testing.assert_equals('under_review', permit_status, 'permit_status_updated_to_under_review');

    -- Test permit approval
    UPDATE civics.permit_applications
    SET status = 'approved',
        approved_date = CURRENT_DATE,
        final_cost = 4800.00
    WHERE application_id = test_permit_id;

    -- Verify approval fields
    SELECT status INTO permit_status
    FROM civics.permit_applications
    WHERE application_id = test_permit_id;

    PERFORM testing.assert_equals('approved', permit_status, 'permit_approved');

    PERFORM testing.assert_not_null(approved_date, 'permit_approval_date_set')
    FROM civics.permit_applications WHERE application_id = test_permit_id;

    -- Cleanup
    DELETE FROM civics.permit_applications WHERE application_id = test_permit_id;
    DELETE FROM civics.citizens WHERE citizen_id = test_citizen_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COMMERCE SYSTEM TESTS
-- =============================================================================

-- Test merchant and order creation
CREATE OR REPLACE FUNCTION testing.test_commerce_workflow()
RETURNS VOID AS $$
DECLARE
    test_citizen_id BIGINT;
    test_merchant_id BIGINT;
    test_order_id BIGINT;
    order_total DECIMAL(10,2);
BEGIN
    -- Create test citizen (merchant owner)
    INSERT INTO civics.citizens (
        first_name, last_name, email, phone,
        street_address, city, state_province, postal_code,
        date_of_birth, status
    ) VALUES (
        'Merchant', 'Owner', 'merchant.owner@test.com', '555-TEST-004',
        '321 Business St', 'Commerce City', 'CC', '22222',
        '1975-06-10', 'active'
    ) RETURNING citizen_id INTO test_citizen_id;

    -- Create test merchant
    INSERT INTO commerce.merchants (
        owner_citizen_id, business_name, business_type,
        street_address, city, state_province, postal_code,
        business_phone, business_email, status
    ) VALUES (
        test_citizen_id, 'Test Merchant LLC', 'retail',
        '321 Business St', 'Commerce City', 'CC', '22222',
        '555-BIZ-TEST', 'business@testmerchant.com', 'active'
    ) RETURNING merchant_id INTO test_merchant_id;

    -- Verify merchant creation
    PERFORM testing.assert_not_null(test_merchant_id, 'merchant_created');

    -- Create test order
    INSERT INTO commerce.orders (
        merchant_id, customer_citizen_id,
        total_amount, tax_amount, payment_method,
        delivery_address, order_status
    ) VALUES (
        test_merchant_id, test_citizen_id,
        99.99, 8.25, '4***-****-****-1234',
        '321 Business St, Commerce City, CC 22222', 'pending'
    ) RETURNING order_id INTO test_order_id;

    -- Verify order creation
    PERFORM testing.assert_not_null(test_order_id, 'order_created');

    -- Test order total calculation
    SELECT total_amount INTO order_total
    FROM commerce.orders WHERE order_id = test_order_id;

    PERFORM testing.assert_equals(99.99::DECIMAL(10,2), order_total, 'order_total_correct');

    -- Test order status updates
    UPDATE commerce.orders
    SET order_status = 'processing'
    WHERE order_id = test_order_id;

    PERFORM testing.assert_equals('processing', order_status, 'order_status_updated')
    FROM commerce.orders WHERE order_id = test_order_id;

    -- Cleanup
    DELETE FROM commerce.orders WHERE order_id = test_order_id;
    DELETE FROM commerce.merchants WHERE merchant_id = test_merchant_id;
    DELETE FROM civics.citizens WHERE citizen_id = test_citizen_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- MESSAGING SYSTEM TESTS
-- =============================================================================

-- Test messaging pub/sub functionality
CREATE OR REPLACE FUNCTION testing.test_messaging_system()
RETURNS VOID AS $$
DECLARE
    subscription_result BOOLEAN;
    message_id BIGINT;
    subscriber_count INTEGER;
BEGIN
    -- Test subscription
    subscription_result := messaging.subscribe_to_channel(
        'test_channel',
        'test_subscriber',
        'live'
    );

    PERFORM testing.assert_true(subscription_result, 'channel_subscription_successful');

    -- Test message sending
    message_id := messaging.notify_channel(
        'test_channel',
        'test_event',
        json_build_object('test_data', 'test_value'),
        'test_sender',
        TRUE  -- persist message
    );

    PERFORM testing.assert_not_null(message_id, 'message_sent_with_persistence');

    -- Verify message was logged
    SELECT subscriber_count INTO subscriber_count
    FROM messaging.notification_log
    WHERE channel_name = 'test_channel'
    AND event_type = 'test_event'
    ORDER BY notification_sent_at DESC
    LIMIT 1;

    PERFORM testing.assert_equals(1, subscriber_count, 'subscriber_count_logged_correctly');

    -- Test message queue processing
    PERFORM messaging.process_queue_messages('test_channel', 10);

    -- Verify message was processed
    PERFORM testing.assert_equals('completed', status, 'queued_message_processed')
    FROM messaging.message_queue
    WHERE message_id = message_id;

    -- Cleanup
    DELETE FROM messaging.message_queue WHERE message_id = message_id;
    DELETE FROM messaging.channel_subscribers WHERE channel_name = 'test_channel' AND subscriber_id = 'test_subscriber';
    DELETE FROM messaging.notification_log WHERE channel_name = 'test_channel' AND event_type = 'test_event';
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COORDINATION SYSTEM TESTS
-- =============================================================================

-- Test advisory lock coordination
CREATE OR REPLACE FUNCTION testing.test_coordination_locks()
RETURNS VOID AS $$
DECLARE
    lock_acquired BOOLEAN;
    lock_released BOOLEAN;
    lock_id BIGINT;
BEGIN
    -- Test lock registration
    lock_id := coordination.register_lock('test_coordination_lock', 'Test lock for unit testing');
    PERFORM testing.assert_not_null(lock_id, 'lock_registration_returns_id');

    -- Test lock acquisition
    lock_acquired := coordination.try_acquire_lock('test_coordination_lock', 'Unit test operation');
    PERFORM testing.assert_true(lock_acquired, 'lock_acquisition_successful');

    -- Test double acquisition (should fail)
    lock_acquired := coordination.try_acquire_lock('test_coordination_lock', 'Second acquisition attempt');
    PERFORM testing.assert_true(NOT lock_acquired, 'double_lock_acquisition_prevented');

    -- Test lock release
    lock_released := coordination.release_lock('test_coordination_lock');
    PERFORM testing.assert_true(lock_released, 'lock_release_successful');

    -- Test lock acquisition after release (should work)
    lock_acquired := coordination.try_acquire_lock('test_coordination_lock', 'Post-release acquisition');
    PERFORM testing.assert_true(lock_acquired, 'lock_reacquisition_after_release');

    -- Final cleanup
    PERFORM coordination.release_lock('test_coordination_lock');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PRIVACY AND SECURITY TESTS
-- =============================================================================

-- Test data masking functions
CREATE OR REPLACE FUNCTION testing.test_privacy_masking()
RETURNS VOID AS $$
DECLARE
    masked_ssn TEXT;
    masked_email TEXT;
    masked_phone TEXT;
BEGIN
    -- Test SSN masking for regular user
    masked_ssn := privacy.mask_ssn('123-45-6789', 'citizen');
    PERFORM testing.assert_equals('***-**-6789', masked_ssn, 'ssn_masking_for_citizen');

    -- Test SSN visibility for admin
    masked_ssn := privacy.mask_ssn('123-45-6789', 'admin');
    PERFORM testing.assert_equals('123-45-6789', masked_ssn, 'ssn_visible_for_admin');

    -- Test email masking
    masked_email := privacy.mask_email('john.doe@email.com', 'citizen');
    PERFORM testing.assert_equals('j***@email.com', masked_email, 'email_masking_works');

    -- Test phone masking
    masked_phone := privacy.mask_phone('555-123-4567', 'citizen');
    PERFORM testing.assert_equals('(***) ***-4567', masked_phone, 'phone_masking_works');

    -- Test admin phone visibility
    masked_phone := privacy.mask_phone('555-123-4567', 'admin');
    PERFORM testing.assert_equals('555-123-4567', masked_phone, 'phone_visible_for_admin');
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ANALYTICS TESTS
-- =============================================================================

-- Test analytics functions
CREATE OR REPLACE FUNCTION testing.test_analytics_functions()
RETURNS VOID AS $$
DECLARE
    stats_result JSONB;
    citizen_count INTEGER;
BEGIN
    -- Test real-time stats function
    stats_result := messaging.get_realtime_stats();
    PERFORM testing.assert_not_null(stats_result, 'realtime_stats_returns_data');

    -- Verify stats structure
    PERFORM testing.assert_true(stats_result ? 'active_citizens', 'stats_contains_active_citizens');
    PERFORM testing.assert_true(stats_result ? 'last_updated', 'stats_contains_timestamp');

    -- Test citizen demographics (if we have test data)
    SELECT COUNT(*) INTO citizen_count FROM civics.citizens WHERE status = 'active';

    IF citizen_count > 0 THEN
        PERFORM testing.assert_true(
            (stats_result->>'active_citizens')::INTEGER >= 0,
            'active_citizen_count_non_negative'
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TEST SUITE RUNNERS
-- =============================================================================

-- Run all citizen-related tests
CREATE OR REPLACE FUNCTION testing.run_citizen_tests()
RETURNS TABLE(
    test_suite TEXT,
    tests_run INTEGER,
    tests_passed INTEGER,
    tests_failed INTEGER,
    success_rate NUMERIC
) AS $$
DECLARE
    initial_count INTEGER;
    final_count INTEGER;
BEGIN
    -- Clear previous test results for this suite
    DELETE FROM testing.test_execution_log WHERE test_suite = 'citizen_tests';

    -- Get initial count
    SELECT COUNT(*) INTO initial_count FROM testing.test_execution_log;

    -- Run tests
    PERFORM testing.test_citizen_registration();
    PERFORM testing.test_citizen_status_updates();

    -- Get final count and calculate results
    SELECT COUNT(*) INTO final_count FROM testing.test_execution_log WHERE test_suite = 'manual_tests';

    RETURN QUERY
    SELECT
        'citizen_tests'::TEXT as test_suite,
        COUNT(*)::INTEGER as tests_run,
        COUNT(*) FILTER (WHERE test_status = 'pass')::INTEGER as tests_passed,
        COUNT(*) FILTER (WHERE test_status = 'fail')::INTEGER as tests_failed,
        ROUND((COUNT(*) FILTER (WHERE test_status = 'pass')::NUMERIC / NULLIF(COUNT(*), 0)) * 100, 2) as success_rate
    FROM testing.test_execution_log
    WHERE test_suite = 'manual_tests'
    AND executed_at >= NOW() - INTERVAL '1 minute';
END;
$$ LANGUAGE plpgsql;

-- Run all tests
CREATE OR REPLACE FUNCTION testing.run_all_tests()
RETURNS TABLE(
    test_category TEXT,
    test_function TEXT,
    execution_status TEXT,
    execution_time_ms INTEGER,
    error_message TEXT
) AS $$
DECLARE
    test_functions TEXT[] := ARRAY[
        'testing.test_citizen_registration',
        'testing.test_citizen_status_updates',
        'testing.test_permit_application_workflow',
        'testing.test_commerce_workflow',
        'testing.test_messaging_system',
        'testing.test_coordination_locks',
        'testing.test_privacy_masking',
        'testing.test_analytics_functions'
    ];
    func_name TEXT;
    start_time TIMESTAMPTZ;
    execution_time INTEGER;
BEGIN
    -- Clear previous test results
    DELETE FROM testing.test_execution_log WHERE executed_at >= NOW() - INTERVAL '1 hour';

    FOREACH func_name IN ARRAY test_functions LOOP
        start_time := clock_timestamp();

        BEGIN
            EXECUTE 'SELECT ' || func_name || '()';
            execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

            RETURN QUERY SELECT
                split_part(func_name, '.', 1) as test_category,
                func_name as test_function,
                'SUCCESS'::TEXT as execution_status,
                execution_time as execution_time_ms,
                NULL::TEXT as error_message;

        EXCEPTION WHEN OTHERS THEN
            execution_time := EXTRACT(milliseconds FROM clock_timestamp() - start_time)::INTEGER;

            RETURN QUERY SELECT
                split_part(func_name, '.', 1) as test_category,
                func_name as test_function,
                'ERROR'::TEXT as execution_status,
                execution_time as execution_time_ms,
                SQLERRM as error_message;
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Generate test report
CREATE OR REPLACE FUNCTION testing.generate_test_report()
RETURNS TABLE(
    report_section TEXT,
    metric_name TEXT,
    metric_value TEXT,
    status TEXT
) AS $$
BEGIN
    -- Overall test statistics
    RETURN QUERY
    SELECT
        'Test Summary'::TEXT as report_section,
        'Total Tests Run'::TEXT as metric_name,
        COUNT(*)::TEXT as metric_value,
        'INFO'::TEXT as status
    FROM testing.test_execution_log
    WHERE executed_at >= NOW() - INTERVAL '1 hour';

    RETURN QUERY
    SELECT
        'Test Summary'::TEXT,
        'Success Rate'::TEXT,
        COALESCE(
            ROUND((COUNT(*) FILTER (WHERE test_status = 'pass')::NUMERIC /
                   NULLIF(COUNT(*), 0)) * 100, 1)::TEXT || '%',
            'No tests'
        ) as metric_value,
        CASE
            WHEN COUNT(*) = 0 THEN 'NO DATA'
            WHEN (COUNT(*) FILTER (WHERE test_status = 'pass')::NUMERIC / COUNT(*)) >= 0.95 THEN 'PASS'
            WHEN (COUNT(*) FILTER (WHERE test_status = 'pass')::NUMERIC / COUNT(*)) >= 0.80 THEN 'WARNING'
            ELSE 'FAIL'
        END as status
    FROM testing.test_execution_log
    WHERE executed_at >= NOW() - INTERVAL '1 hour';

    -- Failed tests
    RETURN QUERY
    SELECT
        'Failed Tests'::TEXT,
        test_name,
        COALESCE(error_message, 'Test assertion failed'),
        'FAIL'::TEXT
    FROM testing.test_execution_log
    WHERE test_status = 'fail'
    AND executed_at >= NOW() - INTERVAL '1 hour'
    ORDER BY executed_at DESC;
END;
$$ LANGUAGE plpgsql;
