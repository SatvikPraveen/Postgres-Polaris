-- Location: /tests/data_integrity_checks.sql
-- FK consistency, constraint validation, and data quality checks

\set ON_ERROR_STOP on
\timing on

-- Start data integrity testing
SELECT 'Starting data integrity checks...' as status;

-- Test 1: Check for NULL values in critical columns
DO $$
DECLARE
    null_citizens integer;
    null_merchants integer;
    null_orders integer;
BEGIN
    RAISE NOTICE 'Test 1: Checking for NULL values in critical columns...';

    -- Check citizens table
    SELECT COUNT(*) INTO null_citizens
    FROM citizens
    WHERE citizen_id IS NULL OR name IS NULL OR email IS NULL;

    IF null_citizens > 0 THEN
        RAISE WARNING 'Citizens table has % records with NULL critical values', null_citizens;
    ELSE
        RAISE NOTICE '✓ Citizens table: no NULL values in critical columns';
    END IF;

    -- Check merchants table
    SELECT COUNT(*) INTO null_merchants
    FROM merchants
    WHERE merchant_id IS NULL OR business_name IS NULL OR status IS NULL;

    IF null_merchants > 0 THEN
        RAISE WARNING 'Merchants table has % records with NULL critical values', null_merchants;
    ELSE
        RAISE NOTICE '✓ Merchants table: no NULL values in critical columns';
    END IF;

    -- Check orders table
    SELECT COUNT(*) INTO null_orders
    FROM orders
    WHERE order_id IS NULL OR customer_id IS NULL OR merchant_id IS NULL OR total_amount IS NULL;

    IF null_orders > 0 THEN
        RAISE WARNING 'Orders table has % records with NULL critical values', null_orders;
    ELSE
        RAISE NOTICE '✓ Orders table: no NULL values in critical columns';
    END IF;
END $;

-- Test 2: Foreign key consistency checks
DO $
DECLARE
    orphan_orders integer;
    orphan_customer_orders integer;
    orphan_merchant_orders integer;
BEGIN
    RAISE NOTICE 'Test 2: Checking foreign key consistency...';

    -- Check for orders with invalid customer_id
    SELECT COUNT(*) INTO orphan_customer_orders
    FROM orders o
    LEFT JOIN citizens c ON o.customer_id = c.citizen_id
    WHERE c.citizen_id IS NULL;

    IF orphan_customer_orders > 0 THEN
        RAISE WARNING 'Found % orders with invalid customer_id references', orphan_customer_orders;
    ELSE
        RAISE NOTICE '✓ All orders have valid customer references';
    END IF;

    -- Check for orders with invalid merchant_id
    SELECT COUNT(*) INTO orphan_merchant_orders
    FROM orders o
    LEFT JOIN merchants m ON o.merchant_id = m.merchant_id
    WHERE m.merchant_id IS NULL;

    IF orphan_merchant_orders > 0 THEN
        RAISE WARNING 'Found % orders with invalid merchant_id references', orphan_merchant_orders;
    ELSE
        RAISE NOTICE '✓ All orders have valid merchant references';
    END IF;
END $;

-- Test 3: Data format validation
DO $
DECLARE
    invalid_emails integer;
    invalid_amounts integer;
    invalid_dates integer;
BEGIN
    RAISE NOTICE 'Test 3: Validating data formats...';

    -- Check email format
    SELECT COUNT(*) INTO invalid_emails
    FROM citizens
    WHERE email IS NOT NULL
    AND email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
    ;

    IF invalid_emails > 0 THEN
        RAISE WARNING 'Found % citizens with invalid email formats', invalid_emails;
    ELSE
        RAISE NOTICE '✓ All citizen emails have valid formats';
    END IF;

    -- Check for negative order amounts
    SELECT COUNT(*) INTO invalid_amounts
    FROM orders
    WHERE total_amount <= 0;

    IF invalid_amounts > 0 THEN
        RAISE WARNING 'Found % orders with invalid amounts (<=0)', invalid_amounts;
    ELSE
        RAISE NOTICE '✓ All order amounts are positive';
    END IF;

    -- Check for future registration dates
    SELECT COUNT(*) INTO invalid_dates
    FROM citizens
    WHERE registration_date > CURRENT_DATE;

    IF invalid_dates > 0 THEN
        RAISE WARNING 'Found % citizens with future registration dates', invalid_dates;
    ELSE
        RAISE NOTICE '✓ All registration dates are valid';
    END IF;
END $;

-- Test 4: Business logic validation
DO $
DECLARE
    underage_citizens integer;
    inactive_merchant_orders integer;
    same_day_issues integer;
BEGIN
    RAISE NOTICE 'Test 4: Checking business logic constraints...';

    -- Check for underage citizens (assuming 18+ requirement)
    SELECT COUNT(*) INTO underage_citizens
    FROM citizens
    WHERE birth_date IS NOT NULL
    AND birth_date > CURRENT_DATE - INTERVAL '18 years';

    IF underage_citizens > 0 THEN
        RAISE WARNING 'Found % citizens under 18 years old', underage_citizens;
    ELSE
        RAISE NOTICE '✓ All citizens meet age requirements';
    END IF;

    -- Check for orders from inactive merchants
    SELECT COUNT(*) INTO inactive_merchant_orders
    FROM orders o
    JOIN merchants m ON o.merchant_id = m.merchant_id
    WHERE m.status != 'active';

    IF inactive_merchant_orders > 0 THEN
        RAISE WARNING 'Found % orders from inactive merchants', inactive_merchant_orders;
    ELSE
        RAISE NOTICE '✓ All orders are from active merchants';
    END IF;

    -- Check registration date vs birth date logic
    SELECT COUNT(*) INTO same_day_issues
    FROM citizens
    WHERE birth_date IS NOT NULL
    AND registration_date IS NOT NULL
    AND registration_date < birth_date;

    IF same_day_issues > 0 THEN
        RAISE WARNING 'Found % citizens with registration before birth date', same_day_issues;
    ELSE
        RAISE NOTICE '✓ All registration dates are after birth dates';
    END IF;
END $;

-- Test 5: Duplicate detection
DO $
DECLARE
    duplicate_emails integer;
    duplicate_merchants integer;
    duplicate_orders integer;
BEGIN
    RAISE NOTICE 'Test 5: Checking for duplicates...';

    -- Check for duplicate emails
    SELECT COUNT(*) INTO duplicate_emails
    FROM (
        SELECT email, COUNT(*)
        FROM citizens
        WHERE email IS NOT NULL
        GROUP BY email
        HAVING COUNT(*) > 1
    ) dupe_emails;

    IF duplicate_emails > 0 THEN
        RAISE WARNING 'Found % duplicate email addresses', duplicate_emails;
    ELSE
        RAISE NOTICE '✓ No duplicate email addresses found';
    END IF;

    -- Check for duplicate business names at same address
    SELECT COUNT(*) INTO duplicate_merchants
    FROM (
        SELECT business_name, address, COUNT(*)
        FROM merchants
        GROUP BY business_name, address
        HAVING COUNT(*) > 1
    ) dupe_merchants;

    IF duplicate_merchants > 0 THEN
        RAISE WARNING 'Found % duplicate merchant names at same address', duplicate_merchants;
    ELSE
        RAISE NOTICE '✓ No duplicate merchants at same address';
    END IF;
END $;

-- Test 6: Data completeness check
DO $
DECLARE
    citizens_with_orders integer;
    merchants_with_orders integer;
    total_citizens integer;
    total_merchants integer;
BEGIN
    RAISE NOTICE 'Test 6: Checking data completeness...';

    SELECT COUNT(*) INTO total_citizens FROM citizens;
    SELECT COUNT(*) INTO total_merchants FROM merchants;

    -- Check how many citizens have orders
    SELECT COUNT(DISTINCT customer_id) INTO citizens_with_orders FROM orders;

    -- Check how many merchants have orders
    SELECT COUNT(DISTINCT merchant_id) INTO merchants_with_orders FROM orders;

    RAISE NOTICE 'Data completeness stats:';
    RAISE NOTICE '  Citizens: % total, % with orders (%.1f%%)',
        total_citizens,
        citizens_with_orders,
        CASE WHEN total_citizens > 0 THEN (citizens_with_orders::float / total_citizens * 100) ELSE 0 END;

    RAISE NOTICE '  Merchants: % total, % with orders (%.1f%%)',
        total_merchants,
        merchants_with_orders,
        CASE WHEN total_merchants > 0 THEN (merchants_with_orders::float / total_merchants * 100) ELSE 0 END;
END $;

-- Test 7: Statistical outlier detection
DO $
DECLARE
    high_value_orders integer;
    high_trip_counts integer;
    avg_order_amount numeric;
    max_order_amount numeric;
BEGIN
    RAISE NOTICE 'Test 7: Checking for statistical outliers...';

    -- Check for unusually high order amounts
    SELECT AVG(total_amount), MAX(total_amount)
    INTO avg_order_amount, max_order_amount
    FROM orders;

    SELECT COUNT(*) INTO high_value_orders
    FROM orders
    WHERE total_amount > avg_order_amount * 5; -- 5x average as outlier threshold

    IF high_value_orders > 0 THEN
        RAISE NOTICE 'Found % high-value orders (>5x average of $%.2f)', high_value_orders, avg_order_amount;
    ELSE
        RAISE NOTICE '✓ No extreme outliers in order amounts';
    END IF;

    RAISE NOTICE 'Order amount stats: avg=$%.2f, max=$%.2f', avg_order_amount, max_order_amount;
END $;

-- Test 8: Time series data validation (if exists)
DO $
DECLARE
    sensor_table_exists boolean;
    future_readings integer;
    old_readings integer;
    battery_issues integer;
BEGIN
    RAISE NOTICE 'Test 8: Checking time series data quality...';

    SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'sensor_readings'
    ) INTO sensor_table_exists;

    IF sensor_table_exists THEN
        -- Check for future timestamps
        SELECT COUNT(*) INTO future_readings
        FROM sensor_readings
        WHERE timestamp > CURRENT_TIMESTAMP;

        -- Check for very old readings (>1 year)
        SELECT COUNT(*) INTO old_readings
        FROM sensor_readings
        WHERE timestamp < CURRENT_TIMESTAMP - INTERVAL '1 year';

        -- Check for low battery sensors
        SELECT COUNT(*) INTO battery_issues
        FROM sensor_readings
        WHERE battery_level < 20;

        RAISE NOTICE 'Sensor data quality:';
        RAISE NOTICE '  Future timestamps: %', future_readings;
        RAISE NOTICE '  Old readings (>1yr): %', old_readings;
        RAISE NOTICE '  Low battery readings: %', battery_issues;

        IF future_readings > 0 THEN
            RAISE WARNING 'Found sensor readings with future timestamps';
        END IF;
    ELSE
        RAISE NOTICE 'No sensor_readings table found (expected for early modules)';
    END IF;
END $;

-- Test 9: JSONB data validation (if exists)
DO $
DECLARE
    documents_table_exists boolean;
    malformed_json integer;
    missing_required_fields integer;
BEGIN
    RAISE NOTICE 'Test 9: Validating JSONB data quality...';

    SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'documents'
    ) INTO documents_table_exists;

    IF documents_table_exists THEN
        -- Check for documents missing required fields
        SELECT COUNT(*) INTO missing_required_fields
        FROM documents
        WHERE NOT (data ? 'type') OR NOT (data ? 'id');

        IF missing_required_fields > 0 THEN
            RAISE WARNING 'Found % documents missing required fields (type, id)', missing_required_fields;
        ELSE
            RAISE NOTICE '✓ All documents have required fields';
        END IF;

        -- Show document type distribution
        RAISE NOTICE 'Document types:';
        FOR rec IN
            SELECT data->>'type' as doc_type, COUNT(*) as count
            FROM documents
            WHERE data ? 'type'
            GROUP BY data->>'type'
            ORDER BY COUNT(*) DESC
        LOOP
            RAISE NOTICE '  %: %', rec.doc_type, rec.count;
        END LOOP;
    ELSE
        RAISE NOTICE 'No documents table found (expected for early modules)';
    END IF;
END $;

-- Test 10: Constraint validation summary
SELECT
    'Test 10: Constraint validation summary' as test,
    tc.table_name,
    tc.constraint_type,
    COUNT(*) as constraint_count
FROM information_schema.table_constraints tc
WHERE tc.table_schema = 'public'
AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE', 'CHECK')
GROUP BY tc.table_name, tc.constraint_type
ORDER BY tc.table_name, tc.constraint_type;

-- Final integrity summary
DO $
DECLARE
    total_records integer := 0;
    citizens_count integer := 0;
    merchants_count integer := 0;
    orders_count integer := 0;
    trips_count integer := 0;
BEGIN
    -- Get record counts
    SELECT COUNT(*) INTO citizens_count FROM citizens;
    SELECT COUNT(*) INTO merchants_count FROM merchants;
    SELECT COUNT(*) INTO orders_count FROM orders;
    SELECT COUNT(*) INTO trips_count FROM trips;

    total_records := citizens_count + merchants_count + orders_count + trips_count;

    RAISE NOTICE '========================================';
    RAISE NOTICE 'DATA INTEGRITY CHECK SUMMARY';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Record counts:';
    RAISE NOTICE '  Citizens: %', citizens_count;
    RAISE NOTICE '  Merchants: %', merchants_count;
    RAISE NOTICE '  Orders: %', orders_count;
    RAISE NOTICE '  Trips: %', trips_count;
    RAISE NOTICE '  Total: %', total_records;
    RAISE NOTICE '========================================';

    IF total_records > 0 THEN
        RAISE NOTICE '✅ Data integrity checks COMPLETED';
        RAISE NOTICE 'Review any warnings above for data quality issues';
    ELSE
        RAISE NOTICE '⚠️  No data found - consider running: make load-data';
    END IF;
END $;

SELECT 'Data integrity checks completed' as status;
