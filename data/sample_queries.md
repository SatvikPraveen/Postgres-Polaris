# Sample Queries for Data Loading

**Location**: `/data/sample_queries.md`

Test queries to verify successful data loading and explore the dataset structure.

## Quick Data Verification

### Check Row Counts

```sql
-- Verify data loaded correctly
SELECT 'citizens' as table_name, COUNT(*) as row_count FROM citizens
UNION ALL
SELECT 'merchants', COUNT(*) FROM merchants
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'trips', COUNT(*) FROM trips
UNION ALL
SELECT 'sensor_readings', COUNT(*) FROM sensor_readings;
```

### Sample Data Preview

```sql
-- Preview citizens data
SELECT citizen_id, name, city, registration_date
FROM citizens
LIMIT 5;

-- Preview merchant data
SELECT merchant_id, business_name, category, status
FROM merchants
WHERE status = 'active'
LIMIT 5;

-- Preview recent orders
SELECT order_id, total_amount, status, order_date
FROM orders
ORDER BY order_date DESC
LIMIT 5;
```

## JSONB Document Queries

### Complaint Analysis

```sql
-- Find high-priority complaints
SELECT
    data->>'category' as complaint_type,
    data->>'priority' as priority,
    data->'details'->>'description' as description
FROM documents
WHERE data->>'type' = 'complaint'
  AND data->>'priority' = 'high';

-- Complaints by neighborhood (using location data)
SELECT
    data->'details'->'location'->>'address' as location,
    data->>'category' as type,
    data->>'status' as status
FROM documents
WHERE data->>'type' = 'complaint'
ORDER BY data->'details'->'date_submitted';
```

### Policy Document Search

```sql
-- Search policy documents
SELECT
    data->>'title' as policy_title,
    data->>'category' as category,
    data->>'version' as version,
    data->>'effective_date' as effective_date
FROM documents
WHERE data->>'type' = 'policy';

-- Find policies with specific keywords
SELECT
    data->>'title' as title,
    data->'content'->>'summary' as summary
FROM documents
WHERE data->>'type' = 'policy'
  AND data->'content'->>'summary' ILIKE '%noise%';
```

### Business Metadata Queries

```sql
-- Business profile analysis
SELECT
    data->>'name' as business_name,
    data->'metadata'->'customer_demographics'->>'peak_hours' as peak_hours,
    data->'reviews'->>'average_rating' as avg_rating
FROM documents
WHERE data->>'type' = 'business_profile';

-- Find businesses with certifications
SELECT
    data->>'name' as business_name,
    data->'metadata'->>'certifications' as certifications
FROM documents
WHERE data->>'type' = 'business_profile'
  AND data->'metadata' ? 'certifications';
```

## Geospatial Data Queries

### Neighborhood Information

```sql
-- Basic spatial feature info
SELECT
    properties->>'name' as name,
    properties->>'type' as feature_type,
    properties->>'population' as population
FROM spatial_features
WHERE properties->>'type' = 'neighborhood'
ORDER BY (properties->>'population')::integer DESC;
```

### Transit Routes

```sql
-- Transit route details
SELECT
    properties->>'name' as route_name,
    properties->>'route_id' as route_id,
    properties->>'length_km' as length_km,
    properties->>'daily_ridership' as ridership
FROM spatial_features
WHERE properties->>'type' = 'transit_route'
ORDER BY (properties->>'daily_ridership')::integer DESC;
```

### Points of Interest

```sql
-- Find all POIs with their types
SELECT
    properties->>'name' as poi_name,
    properties->>'type' as poi_type,
    ST_X(geometry::geometry) as longitude,
    ST_Y(geometry::geometry) as latitude
FROM spatial_features
WHERE geometry::text LIKE 'POINT%'
ORDER BY properties->>'type', properties->>'name';
```

## Time Series Analysis

### Traffic Pattern Analysis

```sql
-- Peak traffic hours
SELECT
    EXTRACT(hour FROM timestamp) as hour_of_day,
    AVG(value) as avg_vehicle_count,
    MAX(value) as peak_count
FROM sensor_readings
WHERE measurement_type = 'vehicle_count'
  AND timestamp >= '2024-01-15'
  AND timestamp < '2024-01-16'
GROUP BY EXTRACT(hour FROM timestamp)
ORDER BY hour_of_day;
```

### Environmental Monitoring

```sql
-- Air quality trends
SELECT
    DATE(timestamp) as date,
    sensor_id,
    AVG(value) as avg_pm25,
    MAX(value) as peak_pm25
FROM sensor_readings
WHERE measurement_type = 'pm25'
GROUP BY DATE(timestamp), sensor_id
ORDER BY date, sensor_id;
```

### Sensor Health Check

```sql
-- Monitor sensor battery levels
SELECT
    sensor_id,
    sensor_type,
    MIN(battery_level) as min_battery,
    AVG(battery_level) as avg_battery,
    COUNT(CASE WHEN battery_level < 80 THEN 1 END) as low_battery_readings
FROM sensor_readings
WHERE timestamp >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY sensor_id, sensor_type
ORDER BY min_battery;
```

## Cross-Dataset Joins

### Customer Order Analysis

```sql
-- Customer spending by location
SELECT
    c.name as customer_name,
    c.city,
    COUNT(o.order_id) as order_count,
    SUM(o.total_amount) as total_spent,
    AVG(o.total_amount) as avg_order_value
FROM citizens c
JOIN orders o ON c.citizen_id = o.customer_id
GROUP BY c.citizen_id, c.name, c.city
ORDER BY total_spent DESC
LIMIT 10;
```

### Merchant Performance

```sql
-- Top performing merchants by category
SELECT
    m.category,
    m.business_name,
    COUNT(o.order_id) as order_count,
    SUM(o.total_amount) as revenue,
    AVG(o.total_amount) as avg_order_size
FROM merchants m
JOIN orders o ON m.merchant_id = o.merchant_id
WHERE o.status = 'completed'
GROUP BY m.category, m.business_name, m.merchant_id
ORDER BY revenue DESC;
```

### Transit Usage Patterns

```sql
-- Daily ridership summary
SELECT
    trip_date,
    COUNT(*) as total_trips,
    SUM(passenger_count) as total_passengers,
    AVG(passenger_count) as avg_passengers_per_trip,
    SUM(fare_amount) as total_revenue
FROM trips
GROUP BY trip_date
ORDER BY trip_date DESC;
```

## Data Quality Checks

### Missing Data Detection

```sql
-- Check for NULL values across key tables
SELECT
    'citizens' as table_name,
    COUNT(*) as total_rows,
    COUNT(CASE WHEN email IS NULL THEN 1 END) as missing_emails,
    COUNT(CASE WHEN phone IS NULL THEN 1 END) as missing_phones
FROM citizens

UNION ALL

SELECT
    'orders',
    COUNT(*),
    COUNT(CASE WHEN customer_id IS NULL THEN 1 END),
    COUNT(CASE WHEN total_amount IS NULL THEN 1 END)
FROM orders;
```

### Data Consistency Validation

```sql
-- Verify referential integrity
SELECT
    'Orders with invalid customer_id' as check_type,
    COUNT(*) as violation_count
FROM orders o
LEFT JOIN citizens c ON o.customer_id = c.citizen_id
WHERE c.citizen_id IS NULL

UNION ALL

SELECT
    'Orders with invalid merchant_id',
    COUNT(*)
FROM orders o
LEFT JOIN merchants m ON o.merchant_id = m.merchant_id
WHERE m.merchant_id IS NULL;
```

### Statistical Summary

```sql
-- Dataset summary statistics
SELECT
    'Order Amounts' as metric,
    MIN(total_amount) as minimum,
    MAX(total_amount) as maximum,
    AVG(total_amount) as average,
    STDDEV(total_amount) as std_dev
FROM orders
WHERE status = 'completed'

UNION ALL

SELECT
    'Trip Passenger Count',
    MIN(passenger_count),
    MAX(passenger_count),
    AVG(passenger_count),
    STDDEV(passenger_count)
FROM trips;
```

## Advanced Analysis Examples

### Window Functions Demo

```sql
-- Running totals and rankings
SELECT
    customer_id,
    order_date,
    total_amount,
    SUM(total_amount) OVER (
        PARTITION BY customer_id
        ORDER BY order_date
        ROWS UNBOUNDED PRECEDING
    ) as running_total,
    RANK() OVER (
        PARTITION BY DATE(order_date)
        ORDER BY total_amount DESC
    ) as daily_rank
FROM orders
WHERE status = 'completed'
ORDER BY customer_id, order_date;
```

### Complex Aggregations

```sql
-- Multi-level grouping with rollup
SELECT
    COALESCE(m.category, 'ALL CATEGORIES') as category,
    COALESCE(DATE(o.order_date), DATE('1900-01-01')) as order_date,
    COUNT(*) as order_count,
    SUM(o.total_amount) as revenue
FROM orders o
JOIN merchants m ON o.merchant_id = m.merchant_id
WHERE o.status = 'completed'
GROUP BY ROLLUP(m.category, DATE(o.order_date))
ORDER BY category, order_date;
```

---

**Usage**: Copy and paste these queries into Adminer (http://localhost:8080) or run via `psql` to explore the loaded datasets and verify everything is working correctly.
