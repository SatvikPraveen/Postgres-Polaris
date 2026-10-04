-- File: sql/05_functions_triggers/plpgsql_basics.sql
-- Purpose: PL/pgSQL and SQL functions: volatility, SQL-standard bodies, error
--          handling, business logic, and utility helpers.
--
-- Standalone: depends only on the base dataset. Idempotent (CREATE OR REPLACE,
-- IF NOT EXISTS). Every data-changing demo runs inside a transaction that is
-- rolled back, so base tables are left untouched.
--
-- Reproducibility: the synthetic data lies before meta.as_of()
-- (2025-12-31 23:59:59 UTC). Date logic that asks "how old / how soon / is it
-- expired" takes an explicit as-of date that defaults to meta.as_of(), so the
-- results do not drift with the wall clock.

\echo '== 05 plpgsql_basics: volatility categories =='

-- =============================================================================
-- 1. VOLATILITY: IMMUTABLE vs STABLE vs VOLATILE
-- =============================================================================
-- The volatility label is a promise to the planner:
--   IMMUTABLE - result depends ONLY on the arguments, forever. May be
--               constant-folded at plan time and used in index expressions.
--   STABLE    - result is fixed within one statement (may read tables, now(),
--               the TimeZone setting, ...). Can be used for index scans
--               (WHERE col = f()) but NOT in index expressions.
--   VOLATILE  - may change on every call or have side effects (nextval,
--               random(), clock_timestamp(), INSERT ...). Re-evaluated per row.
-- Lying (marking a STABLE function IMMUTABLE) gives wrong answers from
-- expression indexes and cached plans, so pick the weakest true label.

-- IMMUTABLE: age at an explicit reference date. Everything it needs is in the
-- arguments, so it is genuinely immutable. Written with a SQL-standard body
-- (BEGIN ATOMIC, PostgreSQL 14+): the body is parsed and dependency-tracked at
-- CREATE time, instead of being an opaque string like $$...$$.
CREATE OR REPLACE FUNCTION civics.age_on(birth_date DATE, as_of DATE)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURNS NULL ON NULL INPUT
BEGIN ATOMIC
    SELECT EXTRACT(YEAR FROM age(as_of::timestamp, birth_date::timestamp))::INTEGER;
END;

COMMENT ON FUNCTION civics.age_on(DATE, DATE) IS
'Age in whole years on a given date. IMMUTABLE: depends only on its arguments.';

-- STABLE: "age today". The one-argument form of age() uses current_date
-- internally, so this can NOT be IMMUTABLE (the original lesson marked it
-- IMMUTABLE, which is a classic bug: an expression index on it would freeze
-- every citizen's age at index-build time). We anchor "today" to the dataset
-- reference date so results are reproducible.
CREATE OR REPLACE FUNCTION civics.calculate_age(birth_date DATE)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
BEGIN
    IF birth_date IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN civics.age_on(birth_date, meta.as_of()::date);
END;
$$;

COMMENT ON FUNCTION civics.calculate_age(DATE) IS
'Age as of the dataset reference date (meta.as_of()). STABLE, not IMMUTABLE: "today" moves.';

-- STABLE: business quarter of a timestamp (default: dataset "now").
-- to_char(timestamptz) depends on the TimeZone setting -> STABLE at best.
CREATE OR REPLACE FUNCTION analytics.current_business_quarter(
    p_at TIMESTAMPTZ DEFAULT meta.as_of()
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    v_month INTEGER := EXTRACT(MONTH FROM p_at);
BEGIN
    RETURN CASE
               WHEN v_month BETWEEN 1 AND 3 THEN 'Q1 '
               WHEN v_month BETWEEN 4 AND 6 THEN 'Q2 '
               WHEN v_month BETWEEN 7 AND 9 THEN 'Q3 '
               ELSE 'Q4 '
           END || EXTRACT(YEAR FROM p_at);
END;
$$;

-- Older versions of this file created a zero-argument overload; remove it so
-- calls without arguments are not ambiguous.
DROP FUNCTION IF EXISTS analytics.current_business_quarter();

COMMENT ON FUNCTION analytics.current_business_quarter(TIMESTAMPTZ) IS
'Business quarter label (e.g. "Q4 2025") for a timestamp; defaults to meta.as_of(). STABLE.';

-- VOLATILE: consumes a sequence value, so each call returns something new.
-- Uses a module-owned sequence so the demo does not burn ids from the base
-- commerce.orders_order_id_seq.
CREATE SEQUENCE IF NOT EXISTS commerce.order_number_demo_seq;

CREATE OR REPLACE FUNCTION commerce.generate_order_number()
RETURNS VARCHAR(50)
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    -- Format: ORD-YYYY-NNNNNN (wall-clock year: this is a genuinely "new" order)
    RETURN 'ORD-' || to_char(now(), 'YYYY') || '-' ||
           lpad(nextval('commerce.order_number_demo_seq')::text, 6, '0');
END;
$$;

COMMENT ON FUNCTION commerce.generate_order_number() IS
'Generate a unique order number from commerce.order_number_demo_seq. VOLATILE (sequence side effect).';

-- Inspect what we declared: provolatile i/s/v, proparallel s/r/u.
SELECT p.oid::regprocedure AS function,
       CASE p.provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END AS volatility,
       CASE p.proparallel WHEN 's' THEN 'SAFE' WHEN 'r' THEN 'RESTRICTED' ELSE 'UNSAFE' END AS parallel
FROM pg_proc p
WHERE p.oid IN ('civics.age_on(date,date)'::regprocedure,
                'civics.calculate_age(date)'::regprocedure,
                'analytics.current_business_quarter(timestamptz)'::regprocedure,
                'commerce.generate_order_number()'::regprocedure)
ORDER BY 1::text;

-- VOLATILE functions are evaluated once per row; STABLE ones may be evaluated
-- once per statement. Three rows -> three distinct order numbers, one quarter.
SELECT g AS row_no,
       commerce.generate_order_number()      AS volatile_value,
       analytics.current_business_quarter()  AS stable_value
FROM generate_series(1, 3) AS g
ORDER BY g;

-- Why the label matters: only IMMUTABLE functions are allowed in index
-- expressions. Try both inside a DO block so the expected error is caught.
DO $$
BEGIN
    BEGIN
        EXECUTE 'CREATE INDEX plpgsql_demo_bad_idx ON civics.citizens (civics.calculate_age(date_of_birth))';
        RAISE NOTICE 'unexpected: STABLE function accepted in an index expression';
    EXCEPTION WHEN invalid_object_definition OR feature_not_supported THEN
        RAISE NOTICE 'STABLE function rejected in index expression, as expected: % (SQLSTATE %)', SQLERRM, SQLSTATE;
    END;
    -- The rejected CREATE INDEX was rolled back with its sub-transaction.
END;
$$;

-- The IMMUTABLE two-argument version is fine in an expression (and the planner
-- can inline a simple SQL function into the calling query).
SELECT civics.age_on(DATE '1990-06-15', DATE '2025-12-31') AS age_on_ref_date,
       civics.calculate_age(DATE '1990-06-15')             AS age_as_of_dataset;

-- Age distribution of active citizens on the dataset reference date.
SELECT (civics.calculate_age(date_of_birth) / 10) * 10 AS age_band,
       count(*)                                         AS citizens
FROM civics.citizens
WHERE status = 'active'
GROUP BY 1
ORDER BY 1;

\echo '== 05 plpgsql_basics: error handling =='

-- =============================================================================
-- 2. ERROR HANDLING PATTERNS
-- =============================================================================
-- Teaching points:
--  * Validate early and RAISE with a specific SQLSTATE, MESSAGE, DETAIL, HINT.
--  * An EXCEPTION clause opens a sub-transaction (savepoint): everything done
--    in that block is rolled back when it catches. It costs an XID, so do not
--    wrap every statement in one inside hot loops.
--  * Catch the SPECIFIC conditions you can handle (unique_violation,
--    check_violation, foreign_key_violation...). A blanket WHEN OTHERS that
--    swallows errors hides bugs; if you must use it, capture the details with
--    GET STACKED DIAGNOSTICS and surface them.

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
    v_status civics.civic_status;
    v_outstanding NUMERIC;
    v_state TEXT;
    v_msg TEXT;
    v_detail TEXT;
    v_constraint TEXT;
BEGIN
    -- Input validation: cheap checks first, no sub-transaction needed.
    IF p_citizen_id IS NULL OR p_permit_type IS NULL OR p_description IS NULL THEN
        RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50), 'Missing required parameters';
        RETURN;
    END IF;

    IF length(trim(p_description)) < 10 THEN
        RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50), 'Description must be at least 10 characters';
        RETURN;
    END IF;

    -- Business rules: plain queries; NOT FOUND tells us the citizen is missing.
    SELECT c.status INTO v_status
    FROM civics.citizens c
    WHERE c.citizen_id = p_citizen_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
            format('Citizen %s not found', p_citizen_id);
        RETURN;
    ELSIF v_status <> 'active' THEN
        RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
            format('Citizen %s is %s, not active', p_citizen_id, v_status);
        RETURN;
    END IF;

    SELECT COALESCE(SUM(t.amount_due - t.amount_paid), 0)
    INTO v_outstanding
    FROM civics.tax_payments t
    WHERE t.citizen_id = p_citizen_id
      AND t.payment_status = 'overdue';

    IF v_outstanding > 100.00 THEN
        RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
            format('Outstanding tax balance of $%s must be resolved first', v_outstanding);
        RETURN;
    END IF;

    -- The write: this is where constraint violations can happen, so this is
    -- the block that gets an EXCEPTION clause.
    BEGIN
        -- Take the id first so permit_id and permit_number agree.
        -- Same number format as the base data: PRM-YYYY-NNNNNN.
        -- (nextval is NOT rolled back with the transaction: gaps are normal.)
        v_permit_id := nextval('civics.permit_applications_permit_id_seq');
        v_permit_number := 'PRM-' || to_char(now(), 'YYYY') || '-' || lpad(v_permit_id::text, 6, '0');

        INSERT INTO civics.permit_applications (
            permit_id, citizen_id, permit_type, permit_number, description,
            property_address, fee_amount, status
        ) VALUES (
            v_permit_id, p_citizen_id, p_permit_type, v_permit_number, p_description,
            p_property_address, p_fee_amount, 'pending'
        );

        RETURN QUERY SELECT true, v_permit_id, v_permit_number, 'Permit application submitted successfully';
    EXCEPTION
        WHEN unique_violation THEN
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                'Permit number already exists - please try again';
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME, v_msg = MESSAGE_TEXT;
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                format('Data validation failed (%s): %s', v_constraint, v_msg);
        WHEN OTHERS THEN
            -- Last resort: report everything we know rather than hiding it.
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE,
                                    v_msg = MESSAGE_TEXT,
                                    v_detail = PG_EXCEPTION_DETAIL;
            RETURN QUERY SELECT false, NULL::BIGINT, NULL::VARCHAR(50),
                format('Unexpected error %s: %s %s', v_state, v_msg, COALESCE(v_detail, ''));
    END;
END;
$$;

COMMENT ON FUNCTION civics.apply_for_permit(BIGINT, civics.permit_type, TEXT, TEXT, NUMERIC) IS
'Submit a permit application with validation; returns (success, permit_id, permit_number, message).';

-- Demo: exercise every branch, then ROLLBACK so the base table is unchanged.
BEGIN;
-- a) success: first active citizen with no overdue taxes
SELECT 'success' AS scenario, r.*
FROM civics.apply_for_permit(
        (SELECT min(c.citizen_id) FROM civics.citizens c
          WHERE c.status = 'active'
            AND NOT EXISTS (SELECT 1 FROM civics.tax_payments t
                            WHERE t.citizen_id = c.citizen_id AND t.payment_status = 'overdue')),
        'building', 'Rear deck extension with new stairs', '100 Demo St', 150.00) AS r;
-- b) business rule: citizen with the largest overdue balance
SELECT 'overdue taxes' AS scenario, r.success, r.message
FROM civics.apply_for_permit(
        (SELECT t.citizen_id FROM civics.tax_payments t WHERE t.payment_status = 'overdue'
          GROUP BY t.citizen_id ORDER BY sum(t.amount_due - t.amount_paid) DESC, t.citizen_id LIMIT 1),
        'event', 'Block party for the neighbourhood') AS r;
-- c) input validation and d) unknown citizen
SELECT 'short description' AS scenario, r.success, r.message
FROM civics.apply_for_permit(1, 'parking', 'too short') AS r;
SELECT 'unknown citizen' AS scenario, r.success, r.message
FROM civics.apply_for_permit(-1, 'parking', 'Residential parking permit request') AS r;
-- e) constraint violation caught by the EXCEPTION block (negative fee -> chk_permit_fees)
SELECT 'check violation' AS scenario, r.success, r.message
FROM civics.apply_for_permit(1, 'street', 'Temporary street closure for repairs', NULL, -5) AS r;
ROLLBACK;

-- RAISE with a custom SQLSTATE, DETAIL and HINT, caught by condition name.
DO $$
DECLARE
    v_state TEXT; v_msg TEXT; v_detail TEXT; v_hint TEXT;
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = 'P0001',              -- raise_exception
        MESSAGE = 'Permit fee cannot be waived',
        DETAIL  = 'permit_type=building requires a fee',
        HINT    = 'Use the hardship-waiver workflow instead';
EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT,
                            v_detail = PG_EXCEPTION_DETAIL, v_hint = PG_EXCEPTION_HINT;
    RAISE NOTICE 'caught % | % | % | %', v_state, v_msg, v_detail, v_hint;
END;
$$;

\echo '== 05 plpgsql_basics: business logic =='

-- =============================================================================
-- 3. BUSINESS LOGIC FUNCTIONS
-- =============================================================================

-- Progressive property tax with exemptions. Pure arithmetic on the arguments,
-- so IMMUTABLE is correct (and it is safe to use in generated columns/indexes).
CREATE OR REPLACE FUNCTION civics.calculate_property_tax(
    assessed_value NUMERIC,
    property_type TEXT DEFAULT 'residential'
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    base_rate NUMERIC := 0.010;  -- 1% base rate
    exemption_amount NUMERIC := 0;
    effective_value NUMERIC;
    calculated_tax NUMERIC;
BEGIN
    IF assessed_value IS NULL OR assessed_value <= 0 THEN
        RAISE EXCEPTION 'Assessed value must be positive, got %', assessed_value
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    CASE property_type
        WHEN 'residential'        THEN exemption_amount := 25000;  -- homestead
        WHEN 'senior_residential' THEN exemption_amount := 50000;  -- senior
        WHEN 'commercial'         THEN exemption_amount := 10000;  -- small business
        WHEN 'industrial'         THEN base_rate := 0.012;         -- higher rate, no exemption
        ELSE exemption_amount := 0;
    END CASE;

    effective_value := GREATEST(assessed_value - exemption_amount, 0);

    -- Marginal brackets: 1.0x up to 100k, 1.1x 100k-500k, 1.2x above 500k
    IF effective_value <= 100000 THEN
        calculated_tax := effective_value * base_rate;
    ELSIF effective_value <= 500000 THEN
        calculated_tax := 100000 * base_rate + (effective_value - 100000) * (base_rate * 1.1);
    ELSE
        calculated_tax := 100000 * base_rate
                        + 400000 * (base_rate * 1.1)
                        + (effective_value - 500000) * (base_rate * 1.2);
    END IF;

    RETURN ROUND(calculated_tax, 2);
END;
$$;

COMMENT ON FUNCTION civics.calculate_property_tax(NUMERIC, TEXT) IS
'Property tax with exemptions and marginal brackets by property type. IMMUTABLE.';

-- Compare property types on the same assessed values.
SELECT v AS assessed_value,
       civics.calculate_property_tax(v, 'residential')        AS residential,
       civics.calculate_property_tax(v, 'senior_residential') AS senior,
       civics.calculate_property_tax(v, 'commercial')         AS commercial,
       civics.calculate_property_tax(v, 'industrial')         AS industrial
FROM unnest(ARRAY[80000, 250000, 900000]::numeric[]) AS v
ORDER BY v;

-- Apply it to real assessments (property rows carry assessed_value).
SELECT tax_year,
       count(*)                                                        AS bills,
       round(avg(assessed_value))                                      AS avg_assessed,
       round(avg(civics.calculate_property_tax(assessed_value)), 2)    AS avg_model_tax
FROM civics.tax_payments
WHERE tax_type = 'property' AND assessed_value > 0
GROUP BY tax_year
ORDER BY tax_year;

-- Business licence validation relative to an as-of date (default: dataset now).
-- Fixed ordering bug: the old version tested "active and not expired" before
-- "expiring within 30 days", so 'expiring_soon' could never be returned.
DROP FUNCTION IF EXISTS commerce.validate_business_license(BIGINT, TEXT);

CREATE OR REPLACE FUNCTION commerce.validate_business_license(
    p_merchant_id BIGINT,
    p_license_type TEXT,
    p_as_of DATE DEFAULT meta.as_of()::date
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
    lic RECORD;
    v_days INTEGER;
BEGIN
    SELECT bl.status, bl.expiration_date
    INTO lic
    FROM commerce.business_licenses bl
    WHERE bl.merchant_id = p_merchant_id
      AND bl.license_type = p_license_type
      AND bl.status IN ('active', 'expired')
    ORDER BY bl.issue_date DESC NULLS LAST, bl.license_id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'not_found'::TEXT, NULL::DATE, NULL::INTEGER,
                            'No license found for this type'::TEXT;
        RETURN;
    END IF;

    v_days := lic.expiration_date - p_as_of;   -- date - date = integer days

    IF lic.status <> 'active' OR v_days < 0 THEN
        RETURN QUERY SELECT false, 'expired'::TEXT, lic.expiration_date, v_days,
            format('License expired %s days ago', abs(v_days));
    ELSIF v_days <= 30 THEN
        RETURN QUERY SELECT true, 'expiring_soon'::TEXT, lic.expiration_date, v_days,
            format('License expires in %s days - renewal recommended', v_days);
    ELSE
        RETURN QUERY SELECT true, 'valid'::TEXT, lic.expiration_date, v_days,
            'License is valid'::TEXT;
    END IF;
END;
$$;

COMMENT ON FUNCTION commerce.validate_business_license(BIGINT, TEXT, DATE) IS
'Validate the latest active/expired licence of a type as of a date (default meta.as_of()).';

-- One merchant per outcome (LATERAL calls the set-returning function per row).
WITH latest AS (
    SELECT DISTINCT ON (merchant_id, license_type) merchant_id, license_type
    FROM commerce.business_licenses
    WHERE status IN ('active', 'expired')
    ORDER BY merchant_id, license_type, issue_date DESC NULLS LAST, license_id DESC
), checked AS (
    SELECT l.merchant_id, l.license_type, v.*
    FROM latest l
    CROSS JOIN LATERAL commerce.validate_business_license(l.merchant_id, l.license_type) v
)
SELECT DISTINCT ON (status) status, merchant_id, license_type, expiration_date, days_until_expiration, message
FROM checked
ORDER BY status, merchant_id, license_type;

-- The same licence seen from different as-of dates: valid -> expiring_soon -> expired.
SELECT d AS as_of, v.status, v.days_until_expiration, v.message
FROM unnest(ARRAY[DATE '2025-12-31', DATE '2026-03-20', DATE '2026-05-01']) AS d
CROSS JOIN LATERAL commerce.validate_business_license(1, 'general_business', d) v
ORDER BY d;

-- Status counts as of the dataset reference date.
SELECT v.status, count(*) AS licences
FROM (SELECT DISTINCT merchant_id, license_type FROM commerce.business_licenses) l
CROSS JOIN LATERAL commerce.validate_business_license(l.merchant_id, l.license_type) v
GROUP BY v.status
ORDER BY v.status;

\echo '== 05 plpgsql_basics: utility functions =='

-- =============================================================================
-- 4. UTILITY AND HELPER FUNCTIONS
-- =============================================================================

-- STRICT (= RETURNS NULL ON NULL INPUT): the function body is skipped and NULL
-- returned whenever any argument is NULL.
CREATE OR REPLACE FUNCTION analytics.format_phone_number(phone_raw TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
    digits TEXT := regexp_replace(phone_raw, '[^0-9]', '', 'g');
BEGIN
    CASE length(digits)
        WHEN 10 THEN
            RETURN format('(%s) %s-%s', substr(digits, 1, 3), substr(digits, 4, 3), substr(digits, 7, 4));
        WHEN 11 THEN
            IF left(digits, 1) = '1' THEN
                RETURN format('+1 (%s) %s-%s', substr(digits, 2, 3), substr(digits, 5, 3), substr(digits, 8, 4));
            END IF;
            RETURN phone_raw;  -- not a US number
        ELSE
            RETURN phone_raw;  -- unknown format: return unchanged
    END CASE;
END;
$$;

COMMENT ON FUNCTION analytics.format_phone_number(TEXT) IS
'Normalise US phone numbers to (XXX) XXX-XXXX. IMMUTABLE STRICT.';

SELECT raw, analytics.format_phone_number(raw) AS formatted
FROM (VALUES ('972.555.0101'), ('1-972-555-0101'), ('+44 20 7946 0958'), (NULL)) AS t(raw);

-- Great-circle distance with the Haversine formula, as a teaching exercise in
-- PL/pgSQL arithmetic. In production prefer PostGIS:
--   ST_Distance(a::geography, b::geography)   -- metres, on the WGS84 spheroid
-- which is more accurate (ellipsoidal, not spherical) and index-assisted via
-- ST_DWithin. Signature kept because other modules call it.
CREATE OR REPLACE FUNCTION geo.calculate_distance_km(
    lat1 DECIMAL(10,8),
    lon1 DECIMAL(11,8),
    lat2 DECIMAL(10,8),
    lon2 DECIMAL(11,8)
)
RETURNS NUMERIC(8,3)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    earth_radius CONSTANT DOUBLE PRECISION := 6371.0088;  -- mean Earth radius, km
    dlat DOUBLE PRECISION;
    dlon DOUBLE PRECISION;
    a DOUBLE PRECISION;
BEGIN
    IF lat1 IS NULL OR lon1 IS NULL OR lat2 IS NULL OR lon2 IS NULL THEN
        RETURN NULL;
    END IF;

    IF abs(lat1) > 90 OR abs(lat2) > 90 OR abs(lon1) > 180 OR abs(lon2) > 180 THEN
        RAISE EXCEPTION 'Invalid coordinates: latitude must be -90..90, longitude -180..180'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    dlat := radians(lat2 - lat1);
    dlon := radians(lon2 - lon1);
    a := sin(dlat / 2) ^ 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ^ 2;

    RETURN round((earth_radius * 2 * asin(sqrt(a)))::numeric, 3);
END;
$$;

COMMENT ON FUNCTION geo.calculate_distance_km(DECIMAL, DECIMAL, DECIMAL, DECIMAL) IS
'Haversine great-circle distance in km (spherical). Prefer PostGIS ST_Distance(geography) in production.';

-- Haversine vs PostGIS geodesic distance between a few station pairs:
-- they agree to within ~0.5% (sphere vs ellipsoid).
SELECT a.station_id AS from_station, b.station_id AS to_station,
       geo.calculate_distance_km(a.latitude, a.longitude, b.latitude, b.longitude) AS haversine_km,
       round((ST_Distance(ST_SetSRID(ST_MakePoint(a.longitude, a.latitude), 4326)::geography,
                          ST_SetSRID(ST_MakePoint(b.longitude, b.latitude), 4326)::geography) / 1000)::numeric, 3)
                                                                                      AS postgis_km
FROM mobility.stations a
JOIN mobility.stations b ON b.station_id = a.station_id + 50
WHERE a.station_id IN (1, 2, 3)
ORDER BY a.station_id;
