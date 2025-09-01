-- File: sql/02_constraints_indexes/specialist_indexes.sql
-- Purpose: Partial, expression, INCLUDE/covering indexes, and advanced patterns

-- =============================================================================
-- PARTIAL INDEXES (Conditional indexes for subsets)
-- =============================================================================

-- Status-specific partial indexes
CREATE INDEX idx_citizens_active_zip ON civics.citizens(zip_code)
    WHERE status = 'active';

CREATE INDEX idx_permits_pending_by_type ON civics.permit_applications(permit_type, application_date)
    WHERE status = 'pending';

CREATE INDEX idx_tax_overdue ON civics.tax_payments(citizen_id, due_date)
    WHERE payment_status = 'overdue';

CREATE INDEX idx_licenses_expiring_soon ON commerce.business_licenses(merchant_id, expiration_date)
    WHERE status = 'active' AND expiration_date <= CURRENT_DATE + INTERVAL '90 days';

CREATE INDEX idx_orders_recent_incomplete ON commerce.orders(merchant_id, order_date DESC)
    WHERE status IN ('pending', 'processing', 'confirmed')
    AND order_date >= CURRENT_DATE - INTERVAL '30 days';

CREATE INDEX idx_stations_maintenance_due ON mobility.stations(station_type, next_maintenance_due)
    WHERE next_maintenance_due <= CURRENT_DATE + INTERVAL '7 days';

CREATE INDEX idx_complaints_high_priority_open ON documents.complaint_records(submitted_at DESC, category)
    WHERE priority_level IN ('high', 'urgent') AND status NOT IN ('resolved', 'archived');

-- Geography-specific partial indexes
CREATE INDEX idx_pois_restaurants_active ON geo.points_of_interest(neighborhood_id, name)
    WHERE category = 'restaurant' AND is_active = true;

CREATE INDEX idx_roads_construction ON geo.road_segments(road_name, maintenance_authority)
    WHERE construction_status = 'construction';

-- Time-based partial indexes
CREATE INDEX idx_trips_recent_by_mode ON mobility.trip_segments(trip_mode, start_time DESC)
    WHERE start_time >= CURRENT_DATE - INTERVAL '7 days';

CREATE INDEX idx_sensors_recent_readings ON mobility.sensor_readings(sensor_code, reading_time DESC)
    WHERE reading_time >= CURRENT_DATE - INTERVAL '24 hours';

-- =============================================================================
-- EXPRESSION/FUNCTIONAL INDEXES
-- =============================================================================

-- Case-insensitive text searches
CREATE INDEX idx_citizens_name_lower ON civics.citizens(lower(first_name || ' ' || last_name));
CREATE INDEX idx_merchants_business_name_lower ON commerce.merchants(lower(business_name));
CREATE INDEX idx_pois_name_lower ON geo.points_of_interest(lower(name));
CREATE INDEX idx_roads_name_lower ON geo.road_segments(lower(road_name));

-- Date/time extractions for temporal queries
CREATE INDEX idx_orders_year_month ON commerce.orders(EXTRACT(YEAR FROM order_date), EXTRACT(MONTH FROM order_date));
CREATE INDEX idx_complaints_day_of_week ON documents.complaint_records(EXTRACT(DOW FROM submitted_at))
    WHERE submitted_at >= CURRENT_DATE - INTERVAL '1 year';
CREATE INDEX idx_trips_hour_of_day ON mobility.trip_segments(EXTRACT(HOUR FROM start_time));

-- Calculated fields
CREATE INDEX idx_tax_balance_owed ON civics.tax_payments((amount_due - amount_paid))
    WHERE payment_status != 'paid';

CREATE INDEX idx_permits_processing_time ON civics.permit_applications(
    EXTRACT(EPOCH FROM (COALESCE(approval_date, CURRENT_TIMESTAMP) - application_date))/86400
) WHERE status IN ('pending', 'approved');

CREATE INDEX idx_trips_speed_kmh ON mobility.trip_segments(
    CASE WHEN duration_minutes > 0 THEN (distance_km * 60.0 / duration_minutes) ELSE NULL END
) WHERE duration_minutes IS NOT NULL AND distance_km IS NOT NULL;

-- JSON/JSONB expressions
CREATE INDEX idx_complaints_metadata_severity ON documents.complaint_records((metadata->>'severity'))
    WHERE metadata ? 'severity';

CREATE INDEX idx_pois_hours_weekend ON geo.points_of_interest(
    (business_hours->'saturday'->>'open')
) WHERE business_hours ? 'saturday';

-- Geographic calculations
CREATE INDEX idx_pois_distance_from_city_center ON geo.points_of_interest(
    ST_Distance(location_geom, ST_SetSRID(ST_Point(-96.7970, 32.9870), 4326))
);

-- Text processing for search
CREATE INDEX idx_complaints_subject_trgm ON documents.complaint_records
    USING gin(subject gin_trgm_ops);

CREATE INDEX idx_policies_title_trgm ON documents.policy_documents
    USING gin(title gin_trgm_ops);

-- =============================================================================
-- COVERING INDEXES (INCLUDE clause - PostgreSQL 11+)
-- =============================================================================

-- Citizens covering frequently accessed columns
CREATE INDEX idx_citizens_email_include ON civics.citizens(email)
    INCLUDE (first_name, last_name, phone, street_address, status);

CREATE INDEX idx_citizens_zip_include ON civics.citizens(zip_code, status)
    INCLUDE (citizen_id, first_name, last_name, email);

-- Orders with customer details
CREATE INDEX idx_orders_merchant_date_include ON commerce.orders(merchant_id, order_date DESC)
    INCLUDE (order_number, status, total_amount, customer_citizen_id);

CREATE INDEX idx_orders_customer_include ON commerce.orders(customer_citizen_id)
    INCLUDE (order_id, order_date, merchant_id, total_amount, status);

-- Permits with location data
CREATE INDEX idx_permits_citizen_include ON civics.permit_applications(citizen_id, status)
    INCLUDE (permit_number, permit_type, property_address, fee_amount, application_date);

-- Stations with inventory summary
CREATE INDEX idx_stations_type_include ON mobility.stations(station_type, status)
    INCLUDE (station_code, station_name, total_capacity, latitude, longitude);

-- POIs with essential details
CREATE INDEX idx_pois_category_include ON geo.points_of_interest(category, neighborhood_id)
    INCLUDE (name, street_address, phone, is_active, average_rating)
    WHERE is_active = true;

-- Complaints with reporter info
CREATE INDEX idx_complaints_status_include ON documents.complaint_records(status, priority_level)
    INCLUDE (complaint_number, subject, reporter_name, reporter_email, submitted_at);

-- =============================================================================
-- MULTI-COLUMN SPECIALIZED INDEXES
-- =============================================================================

-- Hash indexes for multi-column exact matches
CREATE INDEX idx_tax_citizen_year_type_hash ON civics.tax_payments
    USING hash(citizen_id, tax_year, tax_type);

CREATE INDEX idx_trip_segments_trip_order_hash ON mobility.trip_segments
    USING hash(trip_id, segment_order);

-- GIN indexes for multiple JSONB columns
CREATE INDEX idx_complaints_all_json_gin ON documents.complaint_records
    USING gin((metadata || COALESCE(attachments, '{}'::jsonb)));

-- Multiple partial conditions
CREATE INDEX idx_orders_active_recent ON commerce.orders(merchant_id, order_date DESC, total_amount)
    WHERE status NOT IN ('cancelled', 'refunded')
    AND order_date >= CURRENT_DATE - INTERVAL '6 months'
    AND total_amount > 0;

-- Complex geographic queries
CREATE INDEX idx_pois_category_rating_geo ON geo.points_of_interest
    USING gist(location_geom, category)
    WHERE is_active = true AND average_rating >= 4.0;

-- =============================================================================
-- UNIQUE PARTIAL INDEXES (Conditional uniqueness)
-- =============================================================================

-- Only one active permit per property per type
CREATE UNIQUE INDEX idx_permits_active_property_type ON civics.permit_applications(parcel_id, permit_type)
    WHERE status = 'approved' AND parcel_id IS NOT NULL;

-- Only one primary business license per merchant
CREATE UNIQUE INDEX idx_licenses_primary_merchant ON commerce.business_licenses(merchant_id)
    WHERE license_type = 'General Business' AND status = 'active';

-- Unique station codes within type
CREATE UNIQUE INDEX idx_stations_code_type ON mobility.stations(station_code, station_type);

-- =============================================================================
-- BLOOM INDEXES (for multiple equality conditions - requires extension)
-- =============================================================================

-- Note: Bloom indexes require the bloom extension
-- CREATE EXTENSION IF NOT EXISTS bloom;

/*
-- Multi-column equality searches (when bloom extension is available)
CREATE INDEX idx_citizens_bloom ON civics.citizens
    USING bloom(zip_code, status, date_of_birth)
    WITH (length=80, col1=2, col2=2, col3=4);

CREATE INDEX idx_orders_bloom ON commerce.orders
    USING bloom(merchant_id, status, customer_citizen_id)
    WITH (length=80, col1=4, col2=2, col3=4);
*/

-- =============================================================================
-- INDEX OPTIMIZATION FUNCTIONS
-- =============================================================================

-- Function to suggest missing indexes based on query patterns
CREATE OR REPLACE FUNCTION analytics.suggest_missing_indexes()
RETURNS TABLE(
    suggested_index TEXT,
    estimated_benefit TEXT,
    table_name TEXT,
    columns_suggested TEXT
) AS $$
BEGIN
    -- This is a simplified version - real implementation would analyze pg_stat_statements
    RETURN QUERY
    SELECT
        ('CREATE INDEX idx_' || t.table_name || '_suggested_' ||
         REPLACE(REPLACE(c.column_name, ' ', '_'), ',', '_'))::TEXT as suggested_index,
        'Medium'::TEXT as estimated_benefit,
        t.table_name::TEXT,
        c.column_name::TEXT as columns_suggested
    FROM information_schema.tables t
    JOIN information_schema.columns c ON t.table_name = c.table_name
    WHERE t.table_schema IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND c.column_name IN ('created_at', 'updated_at', 'status')
        AND NOT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE tablename = t.table_name
            AND indexdef LIKE '%' || c.column_name || '%'
        )
    ORDER BY t.table_name;
END;
$$ LANGUAGE plpgsql;

-- Function to identify redundant indexes
CREATE OR REPLACE FUNCTION analytics.find_redundant_indexes()
RETURNS TABLE(
    potentially_redundant TEXT,
    overlaps_with TEXT,
    schema_table TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        i1.indexname::TEXT as potentially_redundant,
        i2.indexname::TEXT as overlaps_with,
        (i1.schemaname || '.' || i1.tablename)::TEXT as schema_table
    FROM pg_indexes i1
    JOIN pg_indexes i2 ON i1.tablename = i2.tablename
        AND i1.schemaname = i2.schemaname
        AND i1.indexname < i2.indexname
    WHERE i1.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
        AND i1.indexname NOT LIKE '%_pkey'
        AND i2.indexname NOT LIKE '%_pkey'
        -- Simplified overlap detection
        AND (
            position(substring(i1.indexdef FROM '\(([^)]+)\)') IN i2.indexdef) > 0 OR
            position(substring(i2.indexdef FROM '\(([^)]+)\)') IN i1.indexdef) > 0
        )
    ORDER BY schema_table, potentially_redundant;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.find_redundant_indexes() IS
'Identify potentially redundant indexes that may overlap in functionality';
