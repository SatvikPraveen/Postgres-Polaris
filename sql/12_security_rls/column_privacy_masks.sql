-- File: sql/12_security_rls/column_privacy_masks.sql
-- Purpose: pgcrypto, masking views, and column-level privacy protection

-- =============================================================================
-- PGCRYPTO SETUP
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- ENCRYPTION FUNCTIONS
-- =============================================================================

-- Function to encrypt sensitive data
CREATE OR REPLACE FUNCTION auth.encrypt_sensitive_data(
    plain_text TEXT,
    key_name TEXT DEFAULT 'default'
)
RETURNS TEXT AS $$
DECLARE
    encryption_key TEXT;
BEGIN
    -- In production, retrieve from secure key management
    encryption_key := COALESCE(
        current_setting('app.encryption_key_' || key_name, true),
        'default_key_change_in_production'
    );

    RETURN encode(
        pgp_sym_encrypt(plain_text, encryption_key),
        'base64'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to decrypt sensitive data
CREATE OR REPLACE FUNCTION auth.decrypt_sensitive_data(
    encrypted_text TEXT,
    key_name TEXT DEFAULT 'default'
)
RETURNS TEXT AS $$
DECLARE
    encryption_key TEXT;
BEGIN
    -- In production, retrieve from secure key management
    encryption_key := COALESCE(
        current_setting('app.encryption_key_' || key_name, true),
        'default_key_change_in_production'
    );

    RETURN pgp_sym_decrypt(
        decode(encrypted_text, 'base64'),
        encryption_key
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[DECRYPTION_ERROR]';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- ADD ENCRYPTED COLUMNS
-- =============================================================================

-- Add encrypted SSN storage to citizens
ALTER TABLE civics.citizens
ADD COLUMN IF NOT EXISTS ssn_encrypted TEXT,
ADD COLUMN IF NOT EXISTS phone_encrypted TEXT;

-- Function to encrypt existing SSN data
CREATE OR REPLACE FUNCTION civics.encrypt_existing_ssn_data()
RETURNS TEXT AS $$
DECLARE
    citizen_rec RECORD;
    updated_count INTEGER := 0;
BEGIN
    FOR citizen_rec IN
        SELECT citizen_id, ssn_hash
        FROM civics.citizens
        WHERE ssn_hash IS NOT NULL
        AND ssn_encrypted IS NULL
    LOOP
        -- Simulate SSN from hash (in reality, you'd have original data)
        UPDATE civics.citizens
        SET ssn_encrypted = auth.encrypt_sensitive_data(
            'XXX-XX-' || RIGHT(citizen_rec.ssn_hash, 4)
        )
        WHERE citizen_id = citizen_rec.citizen_id;

        updated_count := updated_count + 1;
    END LOOP;

    RETURN format('Encrypted SSN data for %s citizens', updated_count);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DATA MASKING VIEWS
-- =============================================================================

-- Masked view for citizen data (for general staff)
CREATE OR REPLACE VIEW civics.v_citizens_masked AS
SELECT
    citizen_id,
    first_name,
    last_name,
    -- Masked email: show first letter + domain
    CASE
        WHEN current_setting('app.user_role', true) IN ('admin', 'supervisor')
        THEN email
        ELSE LEFT(email, 1) || '***@' || SPLIT_PART(email, '@', 2)
    END as email,
    -- Masked phone: show area code only
    CASE
        WHEN current_setting('app.user_role', true) IN ('admin', 'supervisor')
        THEN phone
        ELSE REGEXP_REPLACE(phone, '(\d{3})[^0-9]*(\d{3})[^0-9]*(\d{4})', '\1-XXX-XXXX')
    END as phone,
    -- Masked address: show city and zip only
    CASE
        WHEN current_setting('app.user_role', true) IN ('admin', 'supervisor')
        THEN street_address
        ELSE '[REDACTED]'
    END as street_address,
    city,
    state,
    zip_code,
    -- Masked birth date: show year only
    CASE
        WHEN current_setting('app.user_role', true) IN ('admin', 'supervisor')
        THEN date_of_birth
        ELSE make_date(EXTRACT(YEAR FROM date_of_birth)::INTEGER, 1, 1)
    END as birth_date,
    status,
    registered_date,
    created_at,
    updated_at
FROM civics.citizens
WHERE current_setting('app.user_role', true) != ''  -- Require authentication context
ORDER BY citizen_id;

COMMENT ON VIEW civics.v_citizens_masked IS
'Masked citizen view that shows different levels of detail based on user role';

-- Masked view for tax information (financial data protection)
CREATE OR REPLACE VIEW civics.v_tax_payments_masked AS
SELECT
    tax_id,
    citizen_id,
    tax_type,
    tax_year,
    -- Mask actual amounts for non-financial staff
    CASE
        WHEN current_setting('app.user_role', true) IN ('admin', 'finance_staff', 'supervisor')
        THEN assessment_amount
        ELSE ROUND(assessment_amount, -2) -- Round to nearest $100
    END as assessment_amount,
    CASE
        WHEN current_setting('app.user_role', true) IN ('admin', 'finance_staff', 'supervisor')
        THEN amount_due
        ELSE ROUND(amount_due, -2)
    END as amount_due,
    -- Show payment status but mask amounts
    CASE
        WHEN current_setting('app.user_role', true) IN ('admin', 'finance_staff', 'supervisor')
        THEN amount_paid
        ELSE CASE WHEN payment_status = 'paid' THEN amount_due ELSE 0 END
    END as amount_paid,
    payment_status,
    due_date,
    payment_date,
    property_address,
    created_at,
    updated_at
FROM civics.tax_payments
WHERE current_setting('app.user_role', true) != ''
ORDER BY tax_id;

-- =============================================================================
-- DYNAMIC DATA MASKING FUNCTIONS
-- =============================================================================

-- Function to mask email addresses
CREATE OR REPLACE FUNCTION auth.mask_email(
    email_address TEXT,
    mask_level TEXT DEFAULT 'partial'
)
RETURNS TEXT AS $$
BEGIN
    IF email_address IS NULL THEN
        RETURN NULL;
    END IF;

    CASE mask_level
        WHEN 'full' THEN
            RETURN '[REDACTED]';
        WHEN 'domain' THEN
            RETURN SPLIT_PART(email_address, '@', 1) || '@[REDACTED]';
        WHEN 'partial' THEN
            RETURN LEFT(email_address, 2) || '***@' || SPLIT_PART(email_address, '@', 2);
        WHEN 'first_last' THEN
            RETURN LEFT(email_address, 1) ||
                   REPEAT('*', LENGTH(SPLIT_PART(email_address, '@', 1)) - 2) ||
                   RIGHT(SPLIT_PART(email_address, '@', 1), 1) ||
                   '@' || SPLIT_PART(email_address, '@', 2);
        ELSE
            RETURN email_address;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to mask phone numbers
CREATE OR REPLACE FUNCTION auth.mask_phone(
    phone_number TEXT,
    mask_level TEXT DEFAULT 'partial'
)
RETURNS TEXT AS $$
DECLARE
    clean_phone TEXT;
BEGIN
    IF phone_number IS NULL THEN
        RETURN NULL;
    END IF;

    -- Remove non-numeric characters
    clean_phone := REGEXP_REPLACE(phone_number, '[^0-9]', '', 'g');

    CASE mask_level
        WHEN 'full' THEN
            RETURN '[REDACTED]';
        WHEN 'area_code' THEN
            RETURN '(' || LEFT(clean_phone, 3) || ') XXX-XXXX';
        WHEN 'partial' THEN
            RETURN '(' || LEFT(clean_phone, 3) || ') ' ||
                   SUBSTR(clean_phone, 4, 3) || '-XXXX';
        WHEN 'last_four' THEN
            RETURN 'XXX-XXX-' || RIGHT(clean_phone, 4);
        ELSE
            RETURN phone_number;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to mask currency amounts
CREATE OR REPLACE FUNCTION auth.mask_currency(
    amount NUMERIC,
    mask_level TEXT DEFAULT 'rounded'
)
RETURNS NUMERIC AS $$
BEGIN
    IF amount IS NULL THEN
        RETURN NULL;
    END IF;

    CASE mask_level
        WHEN 'full' THEN
            RETURN 0;
        WHEN 'rounded' THEN
            RETURN ROUND(amount, -2); -- Round to nearest $100
        WHEN 'range' THEN
            -- Return range midpoint
            RETURN CASE
                WHEN amount < 1000 THEN 500
                WHEN amount < 5000 THEN 2500
                WHEN amount < 10000 THEN 7500
                WHEN amount < 50000 THEN 25000
                ELSE 75000
            END;
        ELSE
            RETURN amount;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- ROLE-BASED MASKING VIEWS
-- =============================================================================

-- Public-facing citizen directory (heavily masked)
CREATE OR REPLACE VIEW civics.v_citizen_directory_public AS
SELECT
    citizen_id,
    first_name,
    LEFT(last_name, 1) || '.' as last_initial,
    city,
    zip_code,
    EXTRACT(YEAR FROM registered_date) as registration_year
FROM civics.citizens
WHERE status = 'active'
    AND current_setting('app.allow_public_directory', true) = 'true'
ORDER BY last_name, first_name;

-- Staff view with moderate masking
CREATE OR REPLACE VIEW civics.v_citizens_staff AS
SELECT
    citizen_id,
    first_name,
    last_name,
    auth.mask_email(email, 'partial') as email,
    auth.mask_phone(phone, 'area_code') as phone,
    city,
    state,
    zip_code,
    status,
    registered_date
FROM civics.citizens
WHERE current_setting('app.user_role', true) IN ('staff', 'admin', 'supervisor')
ORDER BY citizen_id;

-- Financial staff view with currency masking
CREATE OR REPLACE VIEW civics.v_tax_summary_financial AS
SELECT
    tp.citizen_id,
    c.first_name || ' ' || c.last_name as citizen_name,
    tp.tax_year,
    tp.tax_type,
    CASE
        WHEN current_setting('app.user_role', true) = 'finance_staff'
        THEN tp.amount_due
        ELSE auth.mask_currency(tp.amount_due, 'rounded')
    END as amount_due,
    CASE
        WHEN current_setting('app.user_role', true) = 'finance_staff'
        THEN tp.amount_paid
        ELSE auth.mask_currency(tp.amount_paid, 'rounded')
    END as amount_paid,
    tp.payment_status,
    tp.due_date
FROM civics.tax_payments tp
JOIN civics.citizens c ON tp.citizen_id = c.citizen_id
WHERE current_setting('app.user_role', true) IN ('finance_staff', 'admin')
ORDER BY tp.citizen_id, tp.tax_year DESC;

-- =============================================================================
-- AUDIT TRAIL FOR DATA ACCESS
-- =============================================================================

-- Table to log sensitive data access
CREATE TABLE IF NOT EXISTS audit.sensitive_data_access (
    access_id BIGSERIAL PRIMARY KEY,
    user_id TEXT NOT NULL,
    user_role TEXT,
    table_accessed TEXT NOT NULL,
    row_id TEXT,
    columns_accessed TEXT[],
    access_type TEXT, -- SELECT, UPDATE, etc.
    masking_applied BOOLEAN DEFAULT false,
    access_timestamp TIMESTAMPTZ DEFAULT NOW(),
    client_ip INET DEFAULT INET_CLIENT_ADDR(),
    session_id TEXT,
    justification TEXT
);

-- Function to log sensitive data access
CREATE OR REPLACE FUNCTION audit.log_sensitive_access(
    table_name TEXT,
    row_identifier TEXT,
    columns_list TEXT[],
    operation_type TEXT DEFAULT 'SELECT'
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO audit.sensitive_data_access (
        user_id, user_role, table_accessed, row_id,
        columns_accessed, access_type, session_id
    ) VALUES (
        current_setting('app.current_user_id', true),
        current_setting('app.user_role', true),
        table_name,
        row_identifier,
        columns_list,
        operation_type,
        TO_HEX(EXTRACT(EPOCH FROM NOW())::BIGINT) || '-' || TO_HEX(PG_BACKEND_PID())
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- DATA ANONYMIZATION FUNCTIONS
-- =============================================================================

-- Function to anonymize data for testing/development
CREATE OR REPLACE FUNCTION auth.anonymize_citizen_data()
RETURNS TEXT AS $$
DECLARE
    citizen_rec RECORD;
    updated_count INTEGER := 0;
BEGIN
    -- Only allow in non-production environments
    IF current_setting('app.environment', true) = 'production' THEN
        RAISE EXCEPTION 'Anonymization not allowed in production environment';
    END IF;

    FOR citizen_rec IN
        SELECT citizen_id FROM civics.citizens
    LOOP
        UPDATE civics.citizens
        SET
            first_name = 'TestUser' || citizen_rec.citizen_id,
            last_name = 'Citizen' || citizen_rec.citizen_id,
            email = 'test' || citizen_rec.citizen_id || '@example.com',
            phone = '214-555-' || LPAD(citizen_rec.citizen_id::TEXT, 4, '0'),
            street_address = citizen_rec.citizen_id || ' Test Street'
        WHERE citizen_id = citizen_rec.citizen_id;

        updated_count := updated_count + 1;
    END LOOP;

    RETURN format('Anonymized %s citizen records', updated_count);
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PRIVACY COMPLIANCE FUNCTIONS
-- =============================================================================

-- Function to handle "right to be forgotten" requests
CREATE OR REPLACE FUNCTION auth.handle_data_deletion_request(
    target_citizen_id BIGINT,
    deletion_reason TEXT,
    authorized_by TEXT
)
RETURNS TEXT AS $$
DECLARE
    deletion_summary TEXT := 'Data deletion summary:' || E'\n';
    record_count INTEGER;
BEGIN
    -- Log the deletion request
    INSERT INTO audit.data_deletion_requests (
        citizen_id, reason, authorized_by, request_timestamp
    ) VALUES (
        target_citizen_id, deletion_reason, authorized_by, NOW()
    );

    -- Anonymize rather than delete to maintain referential integrity
    UPDATE civics.citizens
    SET
        first_name = '[DELETED]',
        last_name = '[DELETED]',
        email = 'deleted@deleted.com',
        phone = '000-000-0000',
        street_address = '[REDACTED]',
        status = 'deceased'
    WHERE citizen_id = target_citizen_id;

    GET DIAGNOSTICS record_count = ROW_COUNT;
    deletion_summary := deletion_summary || format('- Anonymized %s citizen record', record_count) || E'\n';

    -- Handle related records
    UPDATE documents.complaint_records
    SET
        reporter_name = '[DELETED]',
        reporter_email = 'deleted@deleted.com',
        reporter_phone = '000-000-0000'
    WHERE reporter_citizen_id = target_citizen_id;

    GET DIAGNOSTICS record_count = ROW_COUNT;
    deletion_summary := deletion_summary || format('- Anonymized %s complaint records', record_count) || E'\n';

    RETURN deletion_summary;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create deletion requests tracking table
CREATE TABLE IF NOT EXISTS audit.data_deletion_requests (
    request_id BIGSERIAL PRIMARY KEY,
    citizen_id BIGINT,
    reason TEXT,
    authorized_by TEXT,
    request_timestamp TIMESTAMPTZ,
    completed_timestamp TIMESTAMPTZ,
    status TEXT DEFAULT 'pending'
);
