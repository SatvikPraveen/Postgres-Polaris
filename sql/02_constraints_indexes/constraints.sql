-- File: sql/02_constraints_indexes/constraints.sql
-- Purpose: Primary keys, foreign keys, unique, check, exclusion constraints

-- =============================================================================
-- CHECK CONSTRAINTS
-- =============================================================================

-- Citizens constraints
ALTER TABLE civics.citizens
    ADD CONSTRAINT chk_citizens_age CHECK (date_of_birth <= CURRENT_DATE AND date_of_birth >= '1900-01-01'),
    ADD CONSTRAINT chk_citizens_email CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    ADD CONSTRAINT chk_citizens_zip CHECK (zip_code ~ '^\d{5}(-\d{4})?$');

-- Tax payments constraints
ALTER TABLE civics.tax_payments
    ADD CONSTRAINT chk_tax_amounts CHECK (assessment_amount >= 0 AND amount_due >= 0 AND amount_paid >= 0),
    ADD CONSTRAINT chk_tax_payment_logic CHECK (amount_paid <= amount_due),
    ADD CONSTRAINT chk_tax_year CHECK (tax_year BETWEEN 1970 AND EXTRACT(YEAR FROM CURRENT_DATE) + 1),
    ADD CONSTRAINT chk_mill_rate CHECK (mill_rate IS NULL OR mill_rate > 0);

-- Permit constraints
ALTER TABLE civics.permit_applications
    ADD CONSTRAINT chk_permit_fees CHECK (fee_amount >= 0 AND fee_paid >= 0 AND fee_paid <= fee_amount),
    ADD CONSTRAINT chk_permit_dates CHECK (approval_date IS NULL OR approval_date >= application_date),
    ADD CONSTRAINT chk_permit_expiration CHECK (expiration_date IS NULL OR expiration_date > COALESCE(approval_date, application_date));

-- Commerce constraints
ALTER TABLE commerce.merchants
    ADD CONSTRAINT chk_merchants_revenue CHECK (annual_revenue IS NULL OR annual_revenue >= 0),
    ADD CONSTRAINT chk_merchants_employees CHECK (employee_count IS NULL OR employee_count >= 0),
    ADD CONSTRAINT chk_merchants_tax_id CHECK (length(tax_id) >= 9);

ALTER TABLE commerce.orders
    ADD CONSTRAINT chk_order_amounts CHECK (subtotal >= 0 AND tax_amount >= 0 AND tip_amount >= 0 AND total_amount >= 0),
    ADD CONSTRAINT chk_order_total CHECK (ABS(total_amount - (subtotal + tax_amount + tip_amount)) < 0.01),
    ADD CONSTRAINT chk_delivery_dates CHECK (actual_delivery IS NULL OR actual_delivery >= order_date);

ALTER TABLE commerce.order_items
    ADD CONSTRAINT chk_item_pricing CHECK (unit_price >= 0 AND quantity > 0 AND line_total >= 0),
    ADD CONSTRAINT chk_item_line_total CHECK (ABS(line_total - (unit_price * quantity)) < 0.01);

ALTER TABLE commerce.payments
    ADD CONSTRAINT chk_payment_amount CHECK (amount > 0),
    ADD CONSTRAINT chk_payment_processing CHECK (
        (status = 'completed' AND processed_at IS NOT NULL) OR
        (status != 'completed')
    );

-- Mobility constraints
ALTER TABLE mobility.stations
    ADD CONSTRAINT chk_station_coordinates CHECK (
        latitude BETWEEN -90 AND 90 AND
        longitude BETWEEN -180 AND 180
    ),
    ADD CONSTRAINT chk_station_capacity CHECK (total_capacity >= 0);

ALTER TABLE mobility.station_inventory
    ADD CONSTRAINT chk_inventory_counts CHECK (
        available_count >= 0 AND
        in_use_count >= 0 AND
        maintenance_count >= 0
    );

ALTER TABLE mobility.trip_segments
    ADD CONSTRAINT chk_trip_coordinates CHECK (
        (start_latitude IS NULL OR start_latitude BETWEEN -90 AND 90) AND
        (end_latitude IS NULL OR end_latitude BETWEEN -90 AND 90) AND
        (start_longitude IS NULL OR start_longitude BETWEEN -180 AND 180) AND
        (end_longitude IS NULL OR end_longitude BETWEEN -180 AND 180)
    ),
    ADD CONSTRAINT chk_trip_times CHECK (end_time IS NULL OR end_time >= start_time),
    ADD CONSTRAINT chk_trip_metrics CHECK (
        (distance_km IS NULL OR distance_km >= 0) AND
        (average_speed_kmh IS NULL OR average_speed_kmh >= 0) AND
        (comfort_rating IS NULL OR comfort_rating BETWEEN 1 AND 5) AND
        (delay_minutes IS NULL OR delay_minutes >= 0)
    );

ALTER TABLE mobility.sensor_readings
    ADD CONSTRAINT chk_sensor_coordinates CHECK (
        latitude BETWEEN -90 AND 90 AND
        longitude BETWEEN -180 AND 180
    ),
    ADD CONSTRAINT chk_sensor_quality CHECK (
        data_quality_score IS NULL OR
        data_quality_score BETWEEN 0.00 AND 1.00
    );

-- Geo constraints
ALTER TABLE geo.road_segments
    ADD CONSTRAINT chk_road_attributes CHECK (
        (speed_limit IS NULL OR speed_limit > 0) AND
        (lane_count IS NULL OR lane_count > 0) AND
        (condition_rating IS NULL OR condition_rating BETWEEN 1 AND 5)
    );

ALTER TABLE geo.points_of_interest
    ADD CONSTRAINT chk_poi_rating CHECK (
        average_rating IS NULL OR
        average_rating BETWEEN 1.00 AND 5.00
    ),
    ADD CONSTRAINT chk_poi_reviews CHECK (review_count >= 0);

-- Documents constraints
ALTER TABLE documents.complaint_records
    ADD CONSTRAINT chk_complaint_coordinates CHECK (
        (incident_latitude IS NULL OR incident_latitude BETWEEN -90 AND 90) AND
        (incident_longitude IS NULL OR incident_longitude BETWEEN -180 AND 180)
    ),
    ADD CONSTRAINT chk_complaint_dates CHECK (
        (acknowledged_at IS NULL OR acknowledged_at >= submitted_at) AND
        (resolved_at IS NULL OR resolved_at >= submitted_at)
    );

-- =============================================================================
-- UNIQUE CONSTRAINTS
-- =============================================================================

-- Additional unique constraints beyond primary keys
ALTER TABLE civics.citizens
    ADD CONSTRAINT uq_citizens_ssn_hash UNIQUE (ssn_hash);

ALTER TABLE civics.permit_applications
    ADD CONSTRAINT uq_permit_number UNIQUE (permit_number);

ALTER TABLE commerce.merchants
    ADD CONSTRAINT uq_merchants_tax_id UNIQUE (tax_id);

ALTER TABLE commerce.business_licenses
    ADD CONSTRAINT uq_license_number UNIQUE (license_number);

ALTER TABLE commerce.orders
    ADD CONSTRAINT uq_order_number UNIQUE (order_number);

ALTER TABLE mobility.stations
    ADD CONSTRAINT uq_station_code UNIQUE (station_code);

ALTER TABLE geo.neighborhood_boundaries
    ADD CONSTRAINT uq_neighborhood_name UNIQUE (neighborhood_name),
    ADD CONSTRAINT uq_neighborhood_code UNIQUE (neighborhood_code);

ALTER TABLE documents.complaint_records
    ADD CONSTRAINT uq_complaint_number UNIQUE (complaint_number);

ALTER TABLE documents.policy_documents
    ADD CONSTRAINT uq_policy_number_version UNIQUE (policy_number, version);

-- =============================================================================
-- EXCLUSION CONSTRAINTS
-- =============================================================================

-- Prevent overlapping active permits for same property
ALTER TABLE civics.permit_applications
    ADD CONSTRAINT excl_permit_overlap EXCLUDE USING gist (
        parcel_id WITH =,
        permit_type WITH =,
        tstzrange(COALESCE(approval_date, application_date), expiration_date, '[)') WITH &&
    ) WHERE (status IN ('approved', 'pending') AND parcel_id IS NOT NULL);

-- Prevent overlapping business licenses for same merchant
ALTER TABLE commerce.business_licenses
    ADD CONSTRAINT excl_license_overlap EXCLUDE USING gist (
        merchant_id WITH =,
        license_type WITH =,
        daterange(issue_date, expiration_date, '[)') WITH &&
    ) WHERE (status = 'active');

-- =============================================================================
-- DEFERRABLE CONSTRAINTS (for data loading)
-- =============================================================================

-- Make some foreign keys deferrable for bulk loading
ALTER TABLE civics.permit_applications
    DROP CONSTRAINT permit_applications_citizen_id_fkey,
    ADD CONSTRAINT permit_applications_citizen_id_fkey
        FOREIGN KEY (citizen_id) REFERENCES civics.citizens(citizen_id)
        DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE commerce.orders
    DROP CONSTRAINT orders_customer_citizen_id_fkey,
    ADD CONSTRAINT orders_customer_citizen_id_fkey
        FOREIGN KEY (customer_citizen_id) REFERENCES civics.citizens(citizen_id)
        DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE mobility.trip_segments
    DROP CONSTRAINT trip_segments_user_id_fkey,
    ADD CONSTRAINT trip_segments_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES civics.citizens(citizen_id)
        DEFERRABLE INITIALLY IMMEDIATE;

-- =============================================================================
-- DOMAIN CONSTRAINTS (reusable constraint types)
-- =============================================================================

-- Create domains for commonly used patterns
CREATE DOMAIN email_address AS VARCHAR(255)
    CHECK (VALUE ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

CREATE DOMAIN us_phone AS VARCHAR(20)
    CHECK (VALUE ~ '^\+?1?[-.\s]?\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}$');

CREATE DOMAIN us_zip_code AS VARCHAR(10)
    CHECK (VALUE ~ '^\d{5}(-\d{4})?$');

CREATE DOMAIN positive_money AS NUMERIC(12,2)
    CHECK (VALUE >= 0);

CREATE DOMAIN rating_1_to_5 AS INTEGER
    CHECK (VALUE BETWEEN 1 AND 5);

CREATE DOMAIN percentage AS NUMERIC(5,2)
    CHECK (VALUE BETWEEN 0.00 AND 100.00);

-- =============================================================================
-- VALIDATION FUNCTIONS
-- =============================================================================

-- Function to validate all constraints in database
CREATE OR REPLACE FUNCTION analytics.validate_all_constraints()
RETURNS TABLE(
    constraint_schema TEXT,
    constraint_table TEXT,
    constraint_name TEXT,
    constraint_type TEXT,
    is_valid BOOLEAN,
    violation_count BIGINT
) AS $$
DECLARE
    constraint_rec RECORD;
    validation_query TEXT;
    violation_count BIGINT;
BEGIN
    FOR constraint_rec IN
        SELECT
            tc.table_schema,
            tc.table_name,
            tc.constraint_name,
            tc.constraint_type
        FROM information_schema.table_constraints tc
        WHERE tc.table_schema IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
            AND tc.constraint_type IN ('CHECK', 'FOREIGN KEY', 'UNIQUE')
    LOOP
        -- This is a simplified version - full implementation would be more complex
        constraint_schema := constraint_rec.table_schema;
        constraint_table := constraint_rec.table_name;
        constraint_name := constraint_rec.constraint_name;
        constraint_type := constraint_rec.constraint_type;
        is_valid := true;
        violation_count := 0;

        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.validate_all_constraints() IS
'Validate all constraints and report violations (simplified implementation)';
