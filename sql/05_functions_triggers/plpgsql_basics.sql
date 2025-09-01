-- File: sql/05_functions_triggers/plpgsql_basics.sql
-- Purpose: PL/pgSQL functions with volatility, error handling, and business logic

-- =============================================================================
-- VOLATILITY AND FUNCTION CLASSIFICATIONS
-- =============================================================================

-- IMMUTABLE function - same input always returns same output
CREATE OR REPLACE FUNCTION civics.calculate_age(birth_date DATE)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF birth_date IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN EXTRACT(YEAR FROM AGE(birth_date));
END;
$$;

COMMENT ON FUNCTION civics.calculate_age(DATE) IS
'Calculate age from birth date. IMMUTABLE - safe for indexes and optimization.';

-- STABLE function - same output within single statement/transaction
CREATE OR REPLACE FUNCTION analytics.current_business_quarter()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    current_month INTEGER;
BEGIN
    current_month := EXTRACT(MONTH FROM CURRENT_DATE);

    CASE
        WHEN current_month BETWEEN 1 AND 3 THEN
            RETURN 'Q1 ' || EXTRACT(YEAR FROM CURRENT_DATE);
        WHEN current_month BETWEEN 4 AND 6 THEN
            RETURN 'Q2 ' || EXTRACT(YEAR FROM CURRENT_DATE);
        WHEN current_month BETWEEN 7 AND 9 THEN
            RETURN 'Q3 ' || EXTRACT(YEAR FROM CURRENT_DATE);
        ELSE
            RETURN 'Q4 ' || EXTRACT(YEAR FROM CURRENT_DATE);
    END CASE;
END;
$$;

COMMENT ON FUNCTION analytics.current_business_quarter() IS
'Get current business quarter. STABLE - depends on CURRENT_DATE.';

-- VOLATILE function - may return different results on each call
CREATE OR REPLACE FUNCTION commerce.generate_order_number()
RETURNS VARCHAR(50)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    order_num VARCHAR(50);
    sequence_val BIGINT;
BEGIN
    -- Get next value from sequence
    SELECT nextval('commerce.orders_order_id_seq') INTO sequence_val;

    -- Format: ORD-YYYY-NNNNNN
    order_num := 'ORD-' ||
                 EXTRACT(YEAR FROM NOW()) || '-' ||
                 LPAD(sequence_val::TEXT, 6, '0');

    RETURN order_num;
END;
$$;

COMMENT ON FUNCTION commerce.generate_order_number() IS
'Generate unique order number. VOLATILE - uses sequences and NOW().';

-- =============================================================================
-- ERROR HANDLING PATTERNS
-- =============================================================================

-- Function with comprehensive error handling
CREATE OR REPLACE FUNCTION civics.apply_for_permit(
    p_citizen_id BIGINT,
    p_permit_type civics.permit_type,
    p_description TEXT,
    p_property_address TEXT DEFAULT NULL,
    p_fee_amount NUMERIC(10,2) DEFAULT 0.00
)
RETURNS TABLE(
    success BOOLEAN,
    permit_id BIGINT,
    permit_number VARCHAR(50),
    message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_permit_id BIGINT;
    v_permit_number VARCHAR(50);
    v_citizen_exists BOOLEAN;
    v_outstanding_balance NUMERIC;
BEGIN
    -- Input validation
    IF p_citizen_id IS NULL OR p_permit_type IS NULL OR p_description IS NULL THEN
        RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50), 'Missing required parameters';
        RETURN;
    END IF;

    IF length(trim(p_description)) < 10 THEN
        RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50), 'Description must be at least 10 characters';
        RETURN;
    END IF;

    -- Business rule validation
    BEGIN
        SELECT EXISTS(SELECT 1 FROM civics.citizens WHERE citizen_id = p_citizen_id AND status = 'active')
        INTO v_citizen_exists;

        IF NOT v_citizen_exists THEN
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50), 'Citizen not found or inactive';
            RETURN;
        END IF;

        -- Check for outstanding tax balance
        SELECT COALESCE(SUM(amount_due - amount_paid), 0)
        INTO v_outstanding_balance
        FROM civics.tax_payments
        WHERE citizen_id = p_citizen_id AND payment_status = 'overdue';

        IF v_outstanding_balance > 100.00 THEN
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                format('Outstanding tax balance of $%s must be resolved first', v_outstanding_balance);
            RETURN;
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                format('Validation error: %s', SQLERRM);
            RETURN;
    END;

    -- Create permit application
    BEGIN
        -- Generate permit number
        v_permit_number := p_permit_type::TEXT || '-' ||
                          EXTRACT(YEAR FROM NOW()) || '-' ||
                          LPAD(nextval('civics.permit_applications_permit_id_seq')::TEXT, 3, '0');

        INSERT INTO civics.permit_applications (
            citizen_id, permit_type, permit_number, description,
            property_address, fee_amount, status
        ) VALUES (
            p_citizen_id, p_permit_type, v_permit_number, p_description,
            p_property_address, p_fee_amount, 'pending'
        ) RETURNING permit_id INTO v_permit_id;

        RETURN QUERY SELECT true, v_permit_id, v_permit_number, 'Permit application submitted successfully';

    EXCEPTION
        WHEN unique_violation THEN
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                'Permit number already exists - please try again';
        WHEN check_violation THEN
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                format('Data validation failed: %s', SQLERRM);
        WHEN OTHERS THEN
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                format('Unexpected error: %s', SQLERRM);
    END;
END;
$$;

COMMENT ON FUNCTION civics.apply_for_permit(BIGINT, civics.permit_type, TEXT, TEXT, NUMERIC) IS
'Submit permit application with full validation and error handling';

-- =============================================================================
-- BUSINESS LOGIC FUNCTIONS
-- =============================================================================

-- Tax calculation function with progressive rates
CREATE OR REPLACE FUNCTION civics.calculate_property_tax(
    assessed_value NUMERIC,
    property_type TEXT DEFAULT 'residential'
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    base_rate NUMERIC := 0.010;  -- 1% base rate
    exemption_amount NUMERIC := 0;
    effective_value NUMERIC;
    calculated_tax NUMERIC;
BEGIN
    -- Input validation
    IF assessed_value IS NULL OR assessed_value <= 0 THEN
        RAISE EXCEPTION 'Assessed value must be positive';
    END IF;

    -- Apply exemptions based on property type
    CASE property_type
        WHEN 'residential' THEN
            exemption_amount := 25000; -- Homestead exemption
        WHEN 'senior_residential' THEN
            exemption_amount := 50000; -- Senior citizen exemption
        WHEN 'commercial' THEN
            exemption_amount := 10000; -- Small business exemption
        WHEN 'industrial' THEN
            base_rate := 0.012; -- Higher rate for industrial
            exemption_amount := 0;
        ELSE
            exemption_amount := 0;
    END CASE;

    -- Calculate effective taxable value
    effective_value := GREATEST(assessed_value - exemption_amount, 0);

    -- Progressive tax calculation
    IF effective_value <= 100000 THEN
        calculated_tax := effective_value * base_rate;
    ELSIF effective_value <= 500000 THEN
        calculated_tax := 100000 * base_rate + (effective_value - 100000) * (base_rate * 1.1);
    ELSE
        calculated_tax := 100000 * base_rate +
                         400000 * (base_rate * 1.1) +
                         (effective_value - 500000) * (base_rate * 1.2);
    END IF;

    RETURN ROUND(calculated_tax, 2);
END;
$$;

COMMENT ON FUNCTION civics.calculate_property_tax(NUMERIC, TEXT) IS
'Calculate property tax with exemptions and progressive rates by property type';

-- Business license validation function
CREATE OR REPLACE FUNCTION commerce.validate_business_license(
    p_merchant_id BIGINT,
    p_license_type TEXT
)
RETURNS TABLE(
    is_valid BOOLEAN,
    status TEXT,
    expiration_date DATE,
    days_until_expiration INTEGER,
    message TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    license_rec RECORD;
BEGIN
    -- Get latest license of specified type
    SELECT bl.*, CURRENT_DATE - bl.expiration_date as days_expired
    INTO license_rec
    FROM commerce.business_licenses bl
    WHERE bl.merchant_id = p_merchant_id
        AND bl.license_type = p_license_type
        AND bl.status IN ('active', 'expired')
    ORDER BY bl.issue_date DESC
    LIMIT 1;

    -- No license found
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'not_found'::TEXT, NULL::DATE, NULL::INTEGER, 'No license found for this type';
        RETURN;
    END IF;

    -- Check license status
    IF license_rec.status = 'active' AND license_rec.expiration_date >= CURRENT_DATE THEN
        RETURN QUERY SELECT
            true,
            'valid'::TEXT,
            license_rec.expiration_date,
            (license_rec.expiration_date - CURRENT_DATE)::INTEGER,
            'License is valid';
    ELSIF license_rec.expiration_date < CURRENT_DATE THEN
        RETURN QUERY SELECT
            false,
            'expired'::TEXT,
            license_rec.expiration_date,
            (license_rec.expiration_date - CURRENT_DATE)::INTEGER,
            format('License expired %s days ago', ABS(license_rec.expiration_date - CURRENT_DATE));
    ELSIF license_rec.expiration_date <= CURRENT_DATE + INTERVAL '30 days' THEN
        RETURN QUERY SELECT
            true,
            'expiring_soon'::TEXT,
            license_rec.expiration_date,
            (license_rec.expiration_date - CURRENT_DATE)::INTEGER,
            format('License expires in %s days - renewal recommended', license_rec.expiration_date - CURRENT_DATE);
    ELSE
        RETURN QUERY SELECT
            true,
            'valid'::TEXT,
            license_rec.expiration_date,
            (license_rec.expiration_date - CURRENT_DATE)::INTEGER,
            'License is valid';
    END IF;
END;
$$;

COMMENT ON FUNCTION commerce.validate_business_license(BIGINT, TEXT) IS
'Validate business license status with expiration warnings';

-- =============================================================================
-- UTILITY AND HELPER FUNCTIONS
-- =============================================================================

-- Format phone number function
CREATE OR REPLACE FUNCTION analytics.format_phone_number(phone_raw TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
STRICT  -- Returns NULL if any parameter is NULL
AS $$
DECLARE
    clean_phone TEXT;
    formatted_phone TEXT;
BEGIN
    -- Remove all non-numeric characters
    clean_phone := regexp_replace(phone_raw, '[^0-9]', '', 'g');

    -- Handle different length phone numbers
    CASE length(clean_phone)
        WHEN 10 THEN
            formatted_phone := '(' || substr(clean_phone, 1, 3) || ') ' ||
                              substr(clean_phone, 4, 3) || '-' ||
                              substr(clean_phone, 7, 4);
        WHEN 11 THEN
            IF substr(clean_phone, 1, 1) = '1' THEN
                formatted_phone := '+1 (' || substr(clean_phone, 2, 3) || ') ' ||
                                  substr(clean_phone, 5, 3) || '-' ||
                                  substr(clean_phone, 8, 4);
            ELSE
                formatted_phone := phone_raw; -- Return original if not US format
            END IF;
        ELSE
            formatted_phone := phone_raw; -- Return original for other formats
    END CASE;

    RETURN formatted_phone;
END;
$$;

COMMENT ON FUNCTION analytics.format_phone_number(TEXT) IS
'Format phone numbers into consistent (XXX) XXX-XXXX format. STRICT function.';

-- Distance calculation function using Haversine formula
CREATE OR REPLACE FUNCTION geo.calculate_distance_km(
    lat1 DECIMAL(10,8),
    lon1 DECIMAL(11,8),
    lat2 DECIMAL(10,8),
    lon2 DECIMAL(11,8)
)
RETURNS NUMERIC(8,3)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    earth_radius CONSTANT NUMERIC := 6371; -- Earth radius in kilometers
    lat1_rad NUMERIC;
    lon1_rad NUMERIC;
    lat2_rad NUMERIC;
    lon2_rad NUMERIC;
    dlat NUMERIC;
    dlon NUMERIC;
    a NUMERIC;
    c NUMERIC;
    distance NUMERIC;
BEGIN
    -- Input validation
    IF lat1 IS NULL OR lon1 IS NULL OR lat2 IS NULL OR lon2 IS NULL THEN
        RETURN NULL;
    END IF;

    IF ABS(lat1) > 90 OR ABS(lat2) > 90 OR ABS(lon1) > 180 OR ABS(lon2) > 180 THEN
        RAISE EXCEPTION 'Invalid coordinates: latitude must be -90 to 90, longitude must be -180 to 180';
    END IF;

    -- Convert to radians
    lat1_rad := radians(lat1);
    lon1_rad := radians(lon1);
    lat2_rad := radians(lat2);
    lon2_rad := radians(lon2);

    -- Calculate differences
    dlat := lat2_rad - lat1_rad;
    dlon := lon2_rad - lon1_rad;

    -- Haversine formula
    a := sin(dlat/2) * sin(dlat/2) +
         cos(lat1_rad) * cos(lat2_rad) *
         sin(dlon/2) * sin(dlon/2);
    c := 2 * atan2(sqrt(a), sqrt(1-a));
    distance := earth_radius * c;

    RETURN ROUND(distance, 3);
END;
$$;

COMMENT ON FUNCTION geo.calculate_distance_km(DECIMAL, DECIMAL, DECIMAL, DECIMAL) IS
'Calculate great-circle distance between two points using Haversine formula';
