-- File: sql/12_security_rls/column_privacy_masks.sql
-- Purpose: column-level privileges, masking views, and pgcrypto encryption for PII
--
-- What this module teaches
--   1. Column-level GRANTs: a role can be allowed to read only some columns of a table
--   2. Masking views: expose PII in reduced form; security_barrier stops "leaky" functions
--      from seeing rows the view filters out
--   3. security_invoker views (PG15+): the view checks the CALLER's privileges, not the owner's
--   4. pgcrypto: pgp_sym_encrypt/decrypt for reversible encryption, hmac() for a searchable
--      "blind index", crypt()/gen_salt() for passwords
--   5. Masking decisions should use real role membership (pg_has_role), not a GUC that any
--      session can set
--
-- Safety: PII copies live in the module-owned schema privacy (rebuilt every run).  Views over
-- base tables are read-only.  Anonymisation / "right to be forgotten" demos run on the module copy.

\echo '== 12 / column privacy: setup =='

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- 0. DEMO ROLES (cluster-global, idempotent, never dropped)
-- =============================================================================
DO $$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['privacy_clerk', 'privacy_supervisor'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            BEGIN
                EXECUTE format('CREATE ROLE %I NOLOGIN', r);
            EXCEPTION WHEN duplicate_object THEN NULL;
            END;
        END IF;
    END LOOP;
END $$;

-- =============================================================================
-- 1. MODULE-OWNED PII TABLE
-- =============================================================================
DROP SCHEMA IF EXISTS privacy CASCADE;
CREATE SCHEMA privacy;

-- A copy of 500 citizens plus a synthetic SSN.  Area numbers 900-999 are never issued
-- by the SSA, so these can never be real SSNs.
CREATE TABLE privacy.citizen_profiles (
    citizen_id      BIGINT PRIMARY KEY,
    first_name      TEXT NOT NULL,
    last_name       TEXT NOT NULL,
    email           TEXT NOT NULL,
    phone           TEXT,
    street_address  TEXT NOT NULL,
    city            TEXT NOT NULL,
    zip_code        TEXT NOT NULL,
    date_of_birth   DATE NOT NULL,
    status          TEXT NOT NULL,
    ssn_plain       TEXT,          -- only here to seed the demo; dropped below
    ssn_encrypted   BYTEA,         -- pgp_sym_encrypt output
    ssn_blind_index TEXT,          -- hmac(ssn, key) -> equality search without decrypting
    ssn_last4       TEXT           -- what most screens actually need
);

INSERT INTO privacy.citizen_profiles
    (citizen_id, first_name, last_name, email, phone, street_address, city, zip_code,
     date_of_birth, status, ssn_plain)
SELECT citizen_id, first_name, last_name, email, phone, street_address, city, zip_code,
       date_of_birth, status::TEXT,
       format('9%s-%s-%s',
              lpad((citizen_id % 100)::TEXT, 2, '0'),
              lpad(((citizen_id * 7) % 100)::TEXT, 2, '0'),
              lpad(((citizen_id * 7919) % 10000)::TEXT, 4, '0'))
FROM civics.citizens
WHERE citizen_id <= 500
ORDER BY citizen_id;

-- =============================================================================
-- 2. PGCRYPTO: SYMMETRIC ENCRYPTION, BLIND INDEX, PASSWORD HASHING
-- =============================================================================
-- Key handling: in production the key comes from a KMS / secret store and is passed per
-- session or per call.  Never hard-code it in SQL: literals end up in server logs
-- (log_statement), pg_stat_statements and backups.  Here we put a demo key in a GUC.
SELECT set_config('app.encryption_key', 'demo-only-key-rotate-me', false);

-- Encrypt helper.  SECURITY DEFINER functions must pin search_path, or a caller could
-- shadow pgp_sym_encrypt with their own function.  No silent default key: fail loudly.
CREATE OR REPLACE FUNCTION auth.encrypt_sensitive_data(plain_text TEXT, key_name TEXT DEFAULT 'encryption_key')
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    k TEXT := NULLIF(current_setting('app.' || key_name, true), '');
BEGIN
    IF k IS NULL THEN
        RAISE EXCEPTION 'encryption key app.% is not set', key_name;
    END IF;
    RETURN encode(pgp_sym_encrypt(plain_text, k, 'cipher-algo=aes256'), 'base64');
END $$;

CREATE OR REPLACE FUNCTION auth.decrypt_sensitive_data(encrypted_text TEXT, key_name TEXT DEFAULT 'encryption_key')
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    k TEXT := NULLIF(current_setting('app.' || key_name, true), '');
BEGIN
    IF k IS NULL THEN
        RAISE EXCEPTION 'encryption key app.% is not set', key_name;
    END IF;
    RETURN pgp_sym_decrypt(decode(encrypted_text, 'base64'), k);
EXCEPTION
    WHEN external_routine_invocation_exception THEN   -- "Wrong key or corrupt data"
        RETURN '[DECRYPTION FAILED]';
END $$;

REVOKE ALL ON FUNCTION auth.encrypt_sensitive_data(TEXT, TEXT), auth.decrypt_sensitive_data(TEXT, TEXT) FROM PUBLIC;

-- Encrypt the SSNs, build the blind index, keep last 4, then drop the plaintext column.
UPDATE privacy.citizen_profiles
SET ssn_encrypted   = pgp_sym_encrypt(ssn_plain, current_setting('app.encryption_key'), 'cipher-algo=aes256'),
    ssn_blind_index = encode(hmac(ssn_plain, current_setting('app.encryption_key'), 'sha256'), 'hex'),
    ssn_last4       = right(ssn_plain, 4);

ALTER TABLE privacy.citizen_profiles DROP COLUMN ssn_plain;
CREATE INDEX ON privacy.citizen_profiles (ssn_blind_index);

\echo '-- encrypted at rest: ciphertext is random (two encryptions of the same value differ)'
SELECT citizen_id,
       left(encode(ssn_encrypted, 'hex'), 24) || '...'                     AS ciphertext_prefix,
       pgp_sym_decrypt(ssn_encrypted, current_setting('app.encryption_key')) AS decrypted,
       ssn_last4
FROM privacy.citizen_profiles
ORDER BY citizen_id
LIMIT 3;

SELECT pgp_sym_encrypt('900-00-0000', 'k') = pgp_sym_encrypt('900-00-0000', 'k') AS ciphertexts_equal;

-- Because ciphertext is randomised you cannot WHERE ssn_encrypted = ...; use the HMAC.
\echo '-- blind-index lookup (no decryption of other rows needed)'
SELECT citizen_id, first_name, last_name, ssn_last4
FROM privacy.citizen_profiles
WHERE ssn_blind_index = encode(hmac('942-94-2598', current_setting('app.encryption_key'), 'sha256'), 'hex');

-- Wrong key -> helper returns a marker instead of aborting the query
SELECT auth.decrypt_sensitive_data(auth.encrypt_sensitive_data('secret value'))          AS right_key,
       (SELECT set_config('app.wrong_key', 'nope', false)) IS NOT NULL                     AS wrong_key_set,
       auth.decrypt_sensitive_data(auth.encrypt_sensitive_data('secret value'), 'wrong_key') AS wrong_key;

-- Passwords: never encrypt, hash with a slow salted algorithm (bcrypt via crypt/gen_salt).
WITH pw AS (SELECT crypt('correct horse battery staple', gen_salt('bf', 8)) AS hash)
SELECT left(hash, 7) AS bcrypt_prefix,
       crypt('correct horse battery staple', hash) = hash AS right_password_ok,
       crypt('Tr0ub4dor&3', hash) = hash                  AS wrong_password_ok
FROM pw;

-- =============================================================================
-- 3. COLUMN-LEVEL PRIVILEGES
-- =============================================================================
-- The clerk may read directory columns but not email / phone / DOB / SSN.
GRANT USAGE ON SCHEMA privacy TO privacy_clerk, privacy_supervisor;
GRANT SELECT (citizen_id, first_name, last_name, city, zip_code, status)
    ON privacy.citizen_profiles TO privacy_clerk;
GRANT SELECT ON privacy.citizen_profiles TO privacy_supervisor;
-- Column-level UPDATE: the clerk may correct addresses, nothing else.
GRANT UPDATE (street_address, city, zip_code) ON privacy.citizen_profiles TO privacy_clerk;

SELECT grantee, column_name, privilege_type
FROM information_schema.column_privileges
WHERE table_schema = 'privacy' AND table_name = 'citizen_profiles' AND grantee = 'privacy_clerk'
ORDER BY privilege_type, column_name;

\echo '-- clerk: granted columns work, SELECT * and PII columns are refused'
SET ROLE privacy_clerk;
SELECT citizen_id, first_name, last_name, zip_code
FROM privacy.citizen_profiles ORDER BY citizen_id LIMIT 3;

DO $$
BEGIN
    PERFORM * FROM privacy.citizen_profiles LIMIT 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'SELECT * as clerk: %', SQLERRM;
END $$;

DO $$
BEGIN
    PERFORM email FROM privacy.citizen_profiles LIMIT 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'SELECT email as clerk: %', SQLERRM;
END $$;

DO $$
BEGIN
    UPDATE privacy.citizen_profiles SET email = 'x@example.com' WHERE citizen_id = 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'UPDATE email as clerk: %', SQLERRM;
END $$;
RESET ROLE;

-- =============================================================================
-- 4. MASKING FUNCTIONS
-- =============================================================================
-- Level-based masks (pure functions: IMMUTABLE, PARALLEL SAFE)
CREATE OR REPLACE FUNCTION auth.mask_email(email_address TEXT, mask_level TEXT DEFAULT 'partial')
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    local_part TEXT := split_part(email_address, '@', 1);
    domain     TEXT := split_part(email_address, '@', 2);
BEGIN
    IF email_address IS NULL THEN RETURN NULL; END IF;
    RETURN CASE mask_level
        WHEN 'full'       THEN '[REDACTED]'
        WHEN 'domain'     THEN local_part || '@[REDACTED]'
        WHEN 'partial'    THEN left(local_part, 1) || '***@' || domain
        WHEN 'first_last' THEN left(local_part, 1)
                               || repeat('*', greatest(length(local_part) - 2, 1))
                               || right(local_part, 1) || '@' || domain
        ELSE email_address
    END;
END $$;

CREATE OR REPLACE FUNCTION auth.mask_phone(phone_number TEXT, mask_level TEXT DEFAULT 'partial')
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    d TEXT := regexp_replace(phone_number, '[^0-9]', '', 'g');
BEGIN
    IF phone_number IS NULL THEN RETURN NULL; END IF;
    RETURN CASE mask_level
        WHEN 'full'      THEN '[REDACTED]'
        WHEN 'area_code' THEN '(' || left(d, 3) || ') XXX-XXXX'
        WHEN 'partial'   THEN '(' || left(d, 3) || ') ' || substr(d, 4, 3) || '-XXXX'
        WHEN 'last_four' THEN '(***) ***-' || right(d, 4)
        ELSE phone_number
    END;
END $$;

CREATE OR REPLACE FUNCTION auth.mask_currency(amount NUMERIC, mask_level TEXT DEFAULT 'rounded')
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
BEGIN
    IF amount IS NULL THEN RETURN NULL; END IF;
    RETURN CASE mask_level
        WHEN 'full'    THEN 0
        WHEN 'rounded' THEN round(amount, -2)           -- nearest $100
        WHEN 'range'   THEN CASE                         -- bucket midpoint
                                WHEN amount < 1000  THEN 500
                                WHEN amount < 5000  THEN 2500
                                WHEN amount < 10000 THEN 7500
                                WHEN amount < 50000 THEN 25000
                                ELSE 75000
                            END
        ELSE amount
    END;
END $$;

-- Who may see raw PII?  Decide from role membership, which the session cannot forge.
-- (A check on current_setting('app.user_role') can be bypassed by any user who runs
--  SET app.user_role = 'admin'.)  Superusers are members of every role.
CREATE OR REPLACE FUNCTION privacy.can_see_pii()
RETURNS BOOLEAN LANGUAGE sql STABLE AS
$$ SELECT pg_has_role(current_user, 'privacy_supervisor', 'MEMBER') $$;

-- Role-aware masks: callers pass the viewing role, admins/supervisors see raw values.
CREATE OR REPLACE FUNCTION privacy.mask_ssn(ssn TEXT, viewer_role TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN viewer_role IN ('admin', 'supervisor') THEN ssn
                ELSE '***-**-' || right(ssn, 4) END
$$;

CREATE OR REPLACE FUNCTION privacy.mask_email(email TEXT, viewer_role TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN viewer_role IN ('admin', 'supervisor') THEN email
                ELSE auth.mask_email(email, 'partial') END
$$;

CREATE OR REPLACE FUNCTION privacy.mask_phone(phone TEXT, viewer_role TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN viewer_role IN ('admin', 'supervisor') THEN phone
                ELSE auth.mask_phone(phone, 'last_four') END
$$;

SELECT privacy.mask_ssn('123-45-6789', 'citizen')          AS ssn_citizen,
       privacy.mask_ssn('123-45-6789', 'admin')            AS ssn_admin,
       privacy.mask_email('john.doe@email.com', 'citizen') AS email_citizen,
       privacy.mask_phone('555-123-4567', 'citizen')       AS phone_citizen,
       auth.mask_email('john.doe@email.com', 'first_last') AS email_first_last,
       auth.mask_currency(12345.67, 'range')               AS currency_range;

-- =============================================================================
-- 5. MASKING VIEWS WITH security_barrier
-- =============================================================================
-- The view owner (polaris) reads the base table; callers only need SELECT on the view.
-- security_barrier = true forces the view's own WHERE clause to run BEFORE any
-- user-supplied predicate, so a leaky function cannot observe hidden rows.
-- Decryption for the view. The key stays out of the database (see section 2):
-- an authorised caller supplies it per session in app.encryption_key. Without
-- this wrapper, pgp_sym_decrypt(ct, NULL) quietly returns NULL, which looks
-- exactly like "no SSN on file". The wrapper makes both failure modes
-- explicit: a missing key and a wrong key each return a clear marker. It runs
-- as the caller (not SECURITY DEFINER), so it can only use the caller's key.
CREATE OR REPLACE FUNCTION privacy.reveal(ciphertext BYTEA)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    k TEXT := nullif(current_setting('app.encryption_key', true), '');
BEGIN
    IF ciphertext IS NULL THEN
        RETURN NULL;                                   -- genuinely nothing on file
    ELSIF k IS NULL THEN
        RETURN '[ENCRYPTED: set app.encryption_key]';
    END IF;
    RETURN pgp_sym_decrypt(ciphertext, k);
EXCEPTION
    WHEN external_routine_invocation_exception THEN    -- "Wrong key or corrupt data"
        RETURN '[DECRYPTION FAILED: wrong key]';
END $$;

CREATE OR REPLACE VIEW privacy.v_citizens_masked
WITH (security_barrier = true) AS
SELECT
    citizen_id,
    first_name,
    last_name,
    CASE WHEN privacy.can_see_pii() THEN email ELSE auth.mask_email(email, 'partial') END AS email,
    CASE WHEN privacy.can_see_pii() THEN phone ELSE auth.mask_phone(phone, 'area_code') END AS phone,
    CASE WHEN privacy.can_see_pii() THEN street_address ELSE '[REDACTED]' END AS street_address,
    city,
    zip_code,
    CASE WHEN privacy.can_see_pii() THEN date_of_birth
         ELSE make_date(extract(year FROM date_of_birth)::INT, 1, 1) END AS birth_date,  -- year only
    CASE WHEN privacy.can_see_pii() THEN privacy.reveal(ssn_encrypted)
         ELSE '***-**-' || ssn_last4 END AS ssn,
    status
FROM privacy.citizen_profiles
WHERE status = 'active';                 -- inactive / deceased records are hidden entirely

COMMENT ON VIEW privacy.v_citizens_masked IS
    'Masked citizen view: raw PII only for members of privacy_supervisor; security_barrier prevents leaks of hidden rows';

GRANT SELECT ON privacy.v_citizens_masked TO privacy_clerk, privacy_supervisor;
GRANT EXECUTE ON FUNCTION privacy.can_see_pii(), privacy.reveal(BYTEA) TO privacy_clerk, privacy_supervisor;
GRANT privacy_clerk TO privacy_supervisor;

\echo '-- same view, different viewers'
SET ROLE privacy_clerk;
SELECT 'clerk' AS viewer, citizen_id, email, phone, street_address, birth_date, ssn
FROM privacy.v_citizens_masked ORDER BY citizen_id LIMIT 2;
RESET ROLE;

SET ROLE privacy_supervisor;
SELECT 'supervisor + key' AS viewer, citizen_id, email, phone, street_address, birth_date, ssn
FROM privacy.v_citizens_masked ORDER BY citizen_id LIMIT 2;

\echo '-- supervisor without the key, then with a wrong key: explicit markers, never a silent NULL'
SELECT set_config('app.encryption_key', '', false) AS key_cleared \gset
SELECT 'supervisor, no key' AS viewer, citizen_id, ssn
FROM privacy.v_citizens_masked ORDER BY citizen_id LIMIT 1;
SELECT set_config('app.encryption_key', 'not-the-key', false) AS key_wrong \gset
SELECT 'supervisor, wrong key' AS viewer, citizen_id, ssn
FROM privacy.v_citizens_masked ORDER BY citizen_id LIMIT 1;
SELECT set_config('app.encryption_key', 'demo-only-key-rotate-me', false) AS key_restored \gset
RESET ROLE;

-- ----------------------------------------------------------------------------
-- Leaky-function attack: why security_barrier matters
-- ----------------------------------------------------------------------------
-- A cheap user function in the WHERE clause can be evaluated before the view's own
-- filter.  This "leaky" function records every non-active row it gets to see.
CREATE OR REPLACE FUNCTION privacy.leaky_peek(p_status TEXT, p_email TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql COST 0.0000001 AS $$
BEGIN
    IF p_status <> 'active' THEN
        PERFORM set_config('privacy.leaked',
            (COALESCE(NULLIF(current_setting('privacy.leaked', true), ''), '0')::INT + 1)::TEXT, false);
    END IF;
    RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION privacy.leaky_peek(TEXT, TEXT) TO privacy_clerk;

-- A plain (non-barrier) view that also hides non-active citizens
CREATE OR REPLACE VIEW privacy.v_active_no_barrier AS
SELECT citizen_id, status, email FROM privacy.citizen_profiles WHERE status = 'active';
CREATE OR REPLACE VIEW privacy.v_active_barrier WITH (security_barrier = true) AS
SELECT citizen_id, status, email FROM privacy.citizen_profiles WHERE status = 'active';
GRANT SELECT ON privacy.v_active_no_barrier, privacy.v_active_barrier TO privacy_clerk;

SET ROLE privacy_clerk;
SELECT set_config('privacy.leaked', '0', false);
SELECT count(*) AS rows_returned FROM privacy.v_active_no_barrier WHERE privacy.leaky_peek(status, email);
SELECT current_setting('privacy.leaked') AS hidden_rows_seen_without_barrier;

SELECT set_config('privacy.leaked', '0', false);
SELECT count(*) AS rows_returned FROM privacy.v_active_barrier WHERE privacy.leaky_peek(status, email);
SELECT current_setting('privacy.leaked') AS hidden_rows_seen_with_barrier;
RESET ROLE;
-- Built-in operators and functions marked LEAKPROOF may still be pushed into a barrier view,
-- so index use on simple predicates is preserved.

-- =============================================================================
-- 6. security_invoker VIEWS (PG15+)
-- =============================================================================
-- Default views are "definer" views: base-table privileges are checked as the VIEW OWNER.
-- With security_invoker = true they are checked as the CALLER (and RLS applies to the caller).
CREATE OR REPLACE VIEW privacy.v_directory_invoker
WITH (security_invoker = true) AS
SELECT citizen_id, first_name, last_name, city, zip_code FROM privacy.citizen_profiles;

CREATE OR REPLACE VIEW privacy.v_contact_invoker
WITH (security_invoker = true) AS
SELECT citizen_id, first_name, email FROM privacy.citizen_profiles;

GRANT SELECT ON privacy.v_directory_invoker, privacy.v_contact_invoker TO privacy_clerk;

SET ROLE privacy_clerk;
-- Works: every column is covered by the clerk's column grants
SELECT count(*) AS directory_rows_visible FROM privacy.v_directory_invoker;
-- Fails: the clerk lacks SELECT(email) on the base table, view grant is not enough
DO $$
BEGIN
    PERFORM count(*) FROM privacy.v_contact_invoker;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'security_invoker view as clerk: %', SQLERRM;
END $$;
RESET ROLE;

SELECT c.relname AS view_name, c.reloptions
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'privacy' AND c.relkind = 'v'
ORDER BY c.relname;

-- =============================================================================
-- 7. MASKED VIEWS OVER BASE TABLES (read-only)
-- =============================================================================
-- Financial data: exact amounts only for privacy_supervisor members.
CREATE OR REPLACE VIEW privacy.v_tax_payments_masked
WITH (security_barrier = true) AS
SELECT
    tax_id,
    citizen_id,
    tax_type,
    tax_year,
    CASE WHEN privacy.can_see_pii() THEN assessment_amount
         ELSE auth.mask_currency(assessment_amount, 'rounded') END AS assessment_amount,
    CASE WHEN privacy.can_see_pii() THEN amount_due
         ELSE auth.mask_currency(amount_due, 'rounded') END AS amount_due,
    CASE WHEN privacy.can_see_pii() THEN amount_paid
         ELSE auth.mask_currency(amount_paid, 'rounded') END AS amount_paid,
    payment_status,
    due_date,
    payment_date,
    CASE WHEN privacy.can_see_pii() THEN property_address ELSE '[REDACTED]' END AS property_address
FROM civics.tax_payments;

-- Public directory: heavily reduced, no contact data at all
CREATE OR REPLACE VIEW privacy.v_citizen_directory_public
WITH (security_barrier = true) AS
SELECT citizen_id,
       first_name,
       left(last_name, 1) || '.' AS last_initial,
       city,
       zip_code,
       extract(year FROM registered_date)::INT AS registration_year
FROM civics.citizens
WHERE status = 'active';

GRANT SELECT ON privacy.v_tax_payments_masked, privacy.v_citizen_directory_public TO privacy_clerk;

SET ROLE privacy_clerk;
SELECT tax_id, tax_type, tax_year, assessment_amount, amount_due, property_address
FROM privacy.v_tax_payments_masked ORDER BY tax_id LIMIT 3;
SELECT * FROM privacy.v_citizen_directory_public ORDER BY citizen_id LIMIT 3;
RESET ROLE;

SELECT tax_id, tax_type, tax_year, assessment_amount, amount_due
FROM privacy.v_tax_payments_masked ORDER BY tax_id LIMIT 3;   -- superuser: unmasked

-- =============================================================================
-- 8. AUDIT TRAIL FOR SENSITIVE ACCESS
-- =============================================================================
CREATE TABLE IF NOT EXISTS audit.sensitive_data_access (
    access_id          BIGSERIAL PRIMARY KEY,
    user_id            TEXT NOT NULL,
    user_role          TEXT,
    table_accessed     TEXT NOT NULL,
    row_id             TEXT,
    columns_accessed   TEXT[],
    access_type        TEXT,             -- SELECT, UPDATE, ...
    masking_applied    BOOLEAN DEFAULT false,
    access_timestamp   TIMESTAMPTZ DEFAULT now(),
    client_ip          INET DEFAULT inet_client_addr(),
    session_id         TEXT,
    justification      TEXT
);

-- SECURITY DEFINER so callers can append to the log without INSERT rights on it.
-- Inside a SECURITY DEFINER function current_user is the function OWNER, so the caller's
-- role is captured through a parameter default (defaults are expanded at the call site).
-- Drop older signatures so the call below is never ambiguous
DROP FUNCTION IF EXISTS audit.log_sensitive_access(TEXT, TEXT, TEXT[], TEXT);
DROP FUNCTION IF EXISTS audit.log_sensitive_access(TEXT, TEXT, TEXT[], TEXT, TEXT);
CREATE OR REPLACE FUNCTION audit.log_sensitive_access(
    table_name     TEXT,
    row_identifier TEXT,
    columns_list   TEXT[],
    operation_type TEXT DEFAULT 'SELECT',
    justification  TEXT DEFAULT NULL,
    caller_role    NAME DEFAULT current_user   -- default is evaluated in the CALLER's context
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, audit
AS $$
BEGIN
    INSERT INTO audit.sensitive_data_access
        (user_id, user_role, table_accessed, row_id, columns_accessed, access_type,
         masking_applied, session_id, justification)
    VALUES
        (session_user, caller_role, table_name, row_identifier, columns_list, operation_type,
         NOT pg_has_role(caller_role, 'privacy_supervisor', 'MEMBER'),
         to_hex(extract(epoch FROM pg_postmaster_start_time())::BIGINT) || '.' || to_hex(pg_backend_pid()),
         justification);
END $$;
-- Callers need USAGE on the schema to reach the function, but NO privilege on the table.
GRANT USAGE ON SCHEMA audit TO privacy_clerk;
REVOKE ALL ON FUNCTION audit.log_sensitive_access(TEXT, TEXT, TEXT[], TEXT, TEXT, NAME) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.log_sensitive_access(TEXT, TEXT, TEXT[], TEXT, TEXT, NAME) TO privacy_clerk;

BEGIN;
SET LOCAL ROLE privacy_clerk;
SELECT audit.log_sensitive_access('privacy.citizen_profiles', '42', ARRAY['email','phone'], 'SELECT', 'case #1234');
RESET ROLE;
SELECT user_id, user_role, table_accessed, row_id, columns_accessed, masking_applied, justification
FROM audit.sensitive_data_access ORDER BY access_id DESC LIMIT 1;
ROLLBACK;   -- keep the shared audit table clean across reruns

-- =============================================================================
-- 9. ANONYMISATION AND "RIGHT TO BE FORGOTTEN" (on the module copy)
-- =============================================================================
-- Set-based anonymisation for building dev/test copies.  Deterministic so joins still work.
CREATE OR REPLACE FUNCTION privacy.anonymize_profiles()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE n INTEGER;
BEGIN
    IF current_setting('app.environment', true) = 'production' THEN
        RAISE EXCEPTION 'Anonymization not allowed in production environment';
    END IF;

    UPDATE privacy.citizen_profiles
    SET first_name     = 'Test' || citizen_id,
        last_name      = 'Citizen' || citizen_id,
        email          = 'test' || citizen_id || '@example.com',
        phone          = '(000) 555-' || lpad((citizen_id % 10000)::TEXT, 4, '0'),
        street_address = citizen_id || ' Test Street',
        ssn_encrypted  = NULL,
        ssn_blind_index = NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN format('Anonymized %s citizen profiles', n);
END $$;

CREATE TABLE IF NOT EXISTS audit.data_deletion_requests (
    request_id          BIGSERIAL PRIMARY KEY,
    citizen_id          BIGINT,
    reason              TEXT,
    authorized_by       TEXT,
    request_timestamp   TIMESTAMPTZ,
    completed_timestamp TIMESTAMPTZ,
    status              TEXT DEFAULT 'pending'
);

-- Erasure = pseudonymise in place (keeps referential integrity and aggregates) + log it.
CREATE OR REPLACE FUNCTION privacy.handle_data_deletion_request(
    target_citizen_id BIGINT,
    deletion_reason   TEXT,
    authorized_by     TEXT
)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE n INTEGER;
BEGIN
    UPDATE privacy.citizen_profiles
    SET first_name = '[DELETED]', last_name = '[DELETED]',
        email = 'deleted+' || citizen_id || '@example.invalid',
        phone = NULL, street_address = '[REDACTED]',
        ssn_encrypted = NULL, ssn_blind_index = NULL, ssn_last4 = NULL,
        status = 'inactive'
    WHERE citizen_id = target_citizen_id;
    GET DIAGNOSTICS n = ROW_COUNT;

    INSERT INTO audit.data_deletion_requests
        (citizen_id, reason, authorized_by, request_timestamp, completed_timestamp, status)
    VALUES (target_citizen_id, deletion_reason, authorized_by, now(), now(),
            CASE WHEN n = 1 THEN 'completed' ELSE 'not_found' END);

    RETURN format('Pseudonymised %s profile(s) for citizen %s', n, target_citizen_id);
END $$;

\echo '-- erasure + anonymisation demos (rolled back)'
BEGIN;
SELECT privacy.handle_data_deletion_request(42, 'GDPR art. 17 request', 'dpo@polaris.example');
SELECT citizen_id, first_name, email, phone, ssn_last4, status
FROM privacy.citizen_profiles WHERE citizen_id = 42;
SELECT privacy.anonymize_profiles();
SELECT citizen_id, first_name, last_name, email, phone
FROM privacy.citizen_profiles ORDER BY citizen_id LIMIT 3;
ROLLBACK;

-- Leave the session clean
SELECT set_config('app.encryption_key', '', false), set_config('app.wrong_key', '', false);
\echo '== column privacy module complete =='
