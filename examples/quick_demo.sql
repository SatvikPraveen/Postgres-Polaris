-- Location: /examples/quick_demo.sql
-- 5-minute tour of key PostgreSQL Polaris features

-- Welcome message
SELECT '🌟 Welcome to PostgreSQL Polaris - Quick Demo!' as message;

-- Demo 1: Basic querying and joins
SELECT 'Demo 1: Customer Order Analysis' as demo;

SELECT
    c.name as customer,
    COUNT(o.order_id) as total_orders,
    COALESCE(SUM(o.total_amount), 0) as total_spent,
    COALESCE(AVG(o.total_amount), 0)::decimal(10,2) as avg_order_value
FROM citizens c
LEFT JOIN orders o ON c.citizen_id = o.customer_id
GROUP BY c.citizen_id, c.name
ORDER BY total_spent DESC, customer
LIMIT 10;

-- Demo 2: Window functions for analytics
SELECT 'Demo 2: Sales Trends with Window Functions' as demo;

SELECT
    order_date,
    total_amount,
    SUM(total_amount) OVER (
        ORDER BY order_date
        ROWS UNBOUNDED PRECEDING
    ) as running_total,
    AVG(total_amount) OVER (
        ORDER BY order_date
        ROWS 2 PRECEDING
    )::decimal(10,2) as moving_avg_3day
FROM orders
WHERE order_date IS NOT NULL
ORDER BY order_date;

-- Demo 3: Advanced aggregations
SELECT 'Demo 3: Merchant Performance by Category' as demo;

SELECT
    COALESCE(m.category, 'ALL CATEGORIES') as category,
    COUNT(o.order_id) as total_orders,
    SUM(o.total_amount)::decimal(12,2) as revenue,
    AVG(o.total_amount)::decimal(10,2) as avg_order_size,
    COUNT(DISTINCT o.customer_id) as unique_customers
FROM merchants m
LEFT JOIN orders o ON m.merchant_id = o.merchant_id AND o.status = 'completed'
GROUP BY ROLLUP(m.category)
ORDER BY revenue DESC NULLS LAST;

-- Demo 4: Text search and pattern matching
SELECT 'Demo 4: Customer Search Examples' as demo;

-- Email domain analysis
SELECT
    split_part(email, '@', 2) as email_domain,
    COUNT(*) as customer_count,
    STRING_AGG(name, ', ' ORDER BY name) as sample_customers
FROM citizens
WHERE email IS NOT NULL
GROUP BY split_part(email, '@', 2)
ORDER BY customer_count DESC;

-- Demo 5: Date/time analysis
SELECT 'Demo 5: Registration Timeline Analysis' as demo;

SELECT
    DATE_TRUNC('month', registration_date) as month,
    COUNT(*) as new_registrations,
    COUNT(*) OVER (
        ORDER BY DATE_TRUNC('month', registration_date)
        ROWS UNBOUNDED PRECEDING
    ) as cumulative_total
FROM citizens
WHERE registration_date IS NOT NULL
GROUP BY DATE_TRUNC('month', registration_date)
ORDER BY month;

-- Demo 6: Complex business logic
SELECT 'Demo 6: Customer Lifetime Value Analysis' as demo;

WITH customer_metrics AS (
    SELECT
        c.citizen_id,
        c.name,
        c.registration_date,
        COUNT(o.order_id) as order_count,
        COALESCE(SUM(o.total_amount), 0) as total_spent,
        COALESCE(MAX(o.order_date), c.registration_date) as last_order_date,
        CURRENT_DATE - COALESCE(MAX(o.order_date), c.registration_date) as days_since_last_order
    FROM citizens c
    LEFT JOIN orders o ON c.citizen_id = o.customer_id
    GROUP BY c.citizen_id, c.name, c.registration_date
),
customer_segments AS (
    SELECT *,
        CASE
            WHEN total_spent > 200 AND days_since_last_order <= 30 THEN 'VIP Active'
            WHEN total_spent > 100 AND days_since_last_order <= 60 THEN 'High Value'
            WHEN order_count > 0 AND days_since_last_order <= 90 THEN 'Regular'
            WHEN order_count > 0 THEN 'At Risk'
            ELSE 'New/Inactive'
        END as customer_segment
    FROM customer_metrics
)
SELECT
    customer_segment,
    COUNT(*) as customer_count,
    AVG(total_spent)::decimal(10,2) as avg_spent,
    AVG(order_count)::decimal(10,1) as avg_orders,
    AVG(days_since_last_order)::decimal(10,0) as avg_days_since_last_order
FROM customer_segments
GROUP BY customer_segment
ORDER BY
    CASE customer_segment
        WHEN 'VIP Active' THEN 1
        WHEN 'High Value' THEN 2
        WHEN 'Regular' THEN 3
        WHEN 'At Risk' THEN 4
        ELSE 5
    END;

-- Demo 7: JSONB functionality (if available)
DO $$
DECLARE
    documents_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'documents'
    ) INTO documents_exists;

    IF documents_exists THEN
        RAISE NOTICE 'Demo 7: JSONB Document Analysis';

        -- Show document types and their properties
        FOR rec IN
            SELECT
                data->>'type' as document_type,
                COUNT(*) as count,
                jsonb_object_keys(
                    jsonb_agg(data) -> 0 -- Get keys from first document of each type
                ) as sample_properties
            FROM documents
            WHERE data ? 'type'
            GROUP BY data->>'type'
        LOOP
            RAISE NOTICE '  Document type: % (% records)', rec.document_type, rec.count;
        END LOOP;

        -- Example JSONB query
        PERFORM 1 FROM (
            SELECT
                data->>'type' as doc_type,
                data->'details'->>'description' as description,
                data->>'status' as status
            FROM documents
            WHERE data @> '{"type": "complaint"}'::jsonb
            LIMIT 3
        ) AS demo_query;

        RAISE NOTICE '✓ JSONB queries executed successfully';
    ELSE
        RAISE NOTICE 'Demo 7: JSONB functionality not available (documents table not found)';
    END IF;
END $$;

-- Demo 8: Geospatial features (if PostGIS available)
DO $$
DECLARE
    postgis_available boolean;
    spatial_table_exists boolean;
BEGIN
    SELECT EXISTS (SELECT FROM pg_extension WHERE extname = 'postgis') INTO postgis_available;

    IF postgis_available THEN
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_schema = 'public'
            AND table_name = 'spatial_features'
        ) INTO spatial_table_exists;

        RAISE NOTICE 'Demo 8: Geospatial Analysis with PostGIS';

        IF spatial_table_exists THEN
            -- Show spatial features summary
            FOR rec IN
                SELECT
                    properties->>'type' as feature_type,
                    COUNT(*) as feature_count,
                    AVG(ST_Area(geometry)) as avg_area
                FROM spatial_features
                WHERE geometry IS NOT NULL
                GROUP BY properties->>'type'
            LOOP
                RAISE NOTICE '  Feature type: % (% features, avg area: %)',
                    rec.feature_type, rec.feature_count, rec.avg_area;
            END LOOP;

            -- Example spatial query
            PERFORM 1 FROM (
                SELECT
                    properties->>'name' as feature_name,
                    ST_AsText(ST_Centroid(geometry)) as center_point
                FROM spatial_features
                WHERE properties->>'type' = 'neighborhood'
                LIMIT 3
            ) AS demo_spatial;

            RAISE NOTICE '✓ Spatial queries executed successfully';
        ELSE
            RAISE NOTICE '  PostGIS available but no spatial data loaded yet';
        END IF;
    ELSE
        RAISE NOTICE 'Demo 8: PostGIS not available - install for spatial features';
    END IF;
END $$;

-- Demo 9: Time series analysis (if sensor data available)
DO $$
DECLARE
    sensor_table_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'sensor_readings'
    ) INTO sensor_table_exists;

    IF sensor_table_exists THEN
        RAISE NOTICE 'Demo 9: Time Series Sensor Data Analysis';

        -- Show sensor data summary
        FOR rec IN
            SELECT
                sensor_type,
                measurement_type,
                COUNT(*) as reading_count,
                AVG(value)::decimal(10,2) as avg_value,
                MIN(timestamp) as first_reading,
                MAX(timestamp) as latest_reading
            FROM sensor_readings
            GROUP BY sensor_type, measurement_type
            ORDER BY sensor_type, measurement_type
        LOOP
            RAISE NOTICE '  %/% : % readings, avg=%, range=% to %',
                rec.sensor_type, rec.measurement_type, rec.reading_count,
                rec.avg_value, rec.first_reading, rec.latest_reading;
        END LOOP;

        -- Example time series query with window functions
        PERFORM 1 FROM (
            SELECT
                timestamp,
                sensor_id,
                value,
                LAG(value, 1) OVER (PARTITION BY sensor_id ORDER BY timestamp) as prev_value,
                value - LAG(value, 1) OVER (PARTITION BY sensor_id ORDER BY timestamp) as change
            FROM sensor_readings
            WHERE measurement_type = 'vehicle_count'
            ORDER BY sensor_id, timestamp
            LIMIT 10
        ) AS time_series_demo;

        RAISE NOTICE '✓ Time series analysis completed';
    ELSE
        RAISE NOTICE 'Demo 9: No sensor data available - load with make load-data';
    END IF;
END $$;

-- Demo 10: Advanced SQL patterns
SELECT 'Demo 10: Advanced SQL Patterns - Recursive Query' as demo;

-- Example: Generate a simple number series using recursive CTE
WITH RECURSIVE number_series AS (
    SELECT 1 as n, 1 as factorial
    UNION ALL
    SELECT n + 1, factorial * (n + 1)
    FROM number_series
    WHERE n < 10
)
SELECT
    n as number,
    factorial,
    factorial::text as factorial_text
FROM number_series;

-- Demo conclusion and next steps
SELECT 'Demo Complete! 🎉' as message;

-- Show what's available for deeper exploration
DO $$
DECLARE
    table_count integer;
    total_records integer;
    available_extensions text[];
BEGIN
    -- Count tables and records
    SELECT COUNT(*) INTO table_count
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

    SELECT
        COALESCE(
            (SELECT COUNT(*) FROM citizens) +
            (SELECT COUNT(*) FROM merchants) +
            (SELECT COUNT(*) FROM orders) +
            (SELECT COUNT(*) FROM trips),
        0) INTO total_records;

    -- Get available extensions
    SELECT ARRAY_AGG(extname ORDER BY extname) INTO available_extensions
    FROM pg_extension;

    RAISE NOTICE '===========================================';
    RAISE NOTICE 'POSTGRESQL POLARIS ENVIRONMENT SUMMARY';
    RAISE NOTICE '===========================================';
    RAISE NOTICE 'Database: %', current_database();
    RAISE NOTICE 'Tables available: %', table_count;
    RAISE NOTICE 'Sample records: %', total_records;
    RAISE NOTICE 'Extensions loaded: %', array_to_string(available_extensions, ', ');
    RAISE NOTICE '';
    RAISE NOTICE 'Ready for learning! Next steps:';
    RAISE NOTICE '• Start with Module 01: make run-module MODULE=01_schema_design/civics.sql';
    RAISE NOTICE '• Explore data: check data/sample_queries.md';
    RAISE NOTICE '• Run tests: make test';
    RAISE NOTICE '• Try other examples in the examples/ directory';
    RAISE NOTICE '';
    RAISE NOTICE 'Web interface: http://localhost:8080';
    RAISE NOTICE 'Command line: make psql';
    RAISE NOTICE '===========================================';
    RAISE NOTICE '🚀 Happy learning with PostgreSQL Polaris!';
END $$;

-- Final summary query
SELECT
    'Quick Demo Summary' as summary,
    '10 demonstrations completed' as demos_run,
    'Ready for modules 01-15' as next_steps,
    'Check docs/LEARNING_PATHS.md' as guidance;
