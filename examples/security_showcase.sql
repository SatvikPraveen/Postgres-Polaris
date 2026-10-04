-- Location: /examples/security_showcase.sql
-- =============================================================================
-- Security showcase - RBAC, row-level security, masking, audit, encryption
-- =============================================================================
-- Demos (each section says what it teaches):
--   1. RBAC                 - NOLOGIN group roles, least-privilege GRANTs,
--                             column-level privileges
--   2. Row-level security   - per-neighbourhood case workers via a session
--                             setting; USING vs WITH CHECK; default deny;
--                             why superusers (and table owners) bypass RLS
--   3. Masking view         - security_barrier view that hides PII unless the
--                             caller holds an "unmask" role
--   4. Audit trail          - SECURITY DEFINER trigger (with a pinned
--                             search_path) writing who/what/when as JSONB diffs
--   5. Encryption           - pgcrypto: symmetric PGP for reversible secrets,
--                             bcrypt (crypt + gen_salt) for one-way secrets
--   6. Privacy compliance   - retention windows relative to meta.as_of(),
--                             "right to be forgotten" anonymisation
--   7. Security assessment  - catalog queries an auditor would run
--   8. Cleanup              - drop everything this script created
--
-- Safety: every table lives in the module-owned schema showcase_security
-- (copies of base rows), so RLS/triggers never touch the shared base tables.
-- Roles are cluster-wide: they are created idempotently and dropped at the end
-- (if another database still uses them, the drop is skipped with a NOTICE).
-- Data reads follow the real schema; recency uses meta.as_of().
-- Run: psql -X -v ON_ERROR_STOP=1 -d <db> -f /examples/security_showcase.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset null '-'
SET client_min_messages = notice;

-- Start from a clean slate (also makes the script safe to re-run after an interruption).
DROP SCHEMA IF EXISTS showcase_security CASCADE;
CREATE SCHEMA showcase_security;

-- =============================================================================
\echo ''
\echo '=== 1. RBAC: three NOLOGIN roles with least privilege ==='
-- NOLOGIN "group" roles carry privileges; real users would be granted
-- membership. We impersonate them with SET ROLE (allowed for a superuser).
DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['showcase_clerk', 'showcase_analyst', 'showcase_auditor'] LOOP
        BEGIN
            EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOBYPASSRLS', r);
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL;   -- already there (or created concurrently by another session)
        END;
    END LOOP;
END $$;

-- A module-owned copy of the complaint queue (base table stays untouched).
CREATE TABLE showcase_security.complaints AS
SELECT complaint_id, complaint_number, neighborhood_id, category, priority_level, status,
       reporter_name, reporter_email, subject, submitted_at, resolved_at
FROM documents.complaint_records;
ALTER TABLE showcase_security.complaints ADD PRIMARY KEY (complaint_id);

GRANT USAGE ON SCHEMA showcase_security TO showcase_clerk, showcase_analyst, showcase_auditor;
-- meta.as_of() is a plain (SECURITY INVOKER) SQL function, inlined into the
-- caller's query, so callers need read access to what it reads. These grants
-- are revoked again by DROP OWNED BY in section 8.
GRANT USAGE ON SCHEMA meta TO showcase_clerk, showcase_analyst, showcase_auditor;
GRANT SELECT ON meta.dataset TO showcase_clerk, showcase_analyst, showcase_auditor;
-- Clerks work the queue: read + update status, nothing else.
GRANT SELECT ON showcase_security.complaints TO showcase_clerk;
GRANT UPDATE (status, resolved_at, neighborhood_id) ON showcase_security.complaints TO showcase_clerk;
-- Analysts get statistics columns only - no reporter PII (column-level GRANT).
GRANT SELECT (complaint_id, neighborhood_id, category, priority_level, status, submitted_at, resolved_at)
    ON showcase_security.complaints TO showcase_analyst;
-- Auditors read everything (but see section 2: RLS still applies to them).
GRANT SELECT ON showcase_security.complaints TO showcase_auditor;

SELECT grantee, privilege_type, count(*) AS columns
FROM information_schema.column_privileges
WHERE table_schema = 'showcase_security' AND table_name = 'complaints'
  AND grantee LIKE 'showcase_%'
GROUP BY grantee, privilege_type
ORDER BY grantee, privilege_type;

-- =============================================================================
\echo ''
\echo '=== 2. Row-level security: each clerk sees only their neighbourhood ==='
ALTER TABLE showcase_security.complaints ENABLE ROW LEVEL SECURITY;

-- The neighbourhood comes from a session setting the application sets per
-- request; nullif(..., '') makes an unset value deny instead of erroring.
CREATE POLICY clerk_own_hood ON showcase_security.complaints
    FOR ALL TO showcase_clerk
    USING      (neighborhood_id = nullif(current_setting('showcase.neighborhood_id', true), '')::bigint)
    WITH CHECK (neighborhood_id = nullif(current_setting('showcase.neighborhood_id', true), '')::bigint);
CREATE POLICY analyst_all_rows ON showcase_security.complaints
    FOR SELECT TO showcase_analyst
    USING (true);
-- No policy for showcase_auditor: with RLS enabled, no policy = no rows.

SELECT set_config('showcase.neighborhood_id', '3', false);

SET ROLE showcase_clerk;
SELECT current_user AS acting_as, count(*) AS visible_complaints,
       count(DISTINCT neighborhood_id) AS neighbourhoods_visible
FROM showcase_security.complaints;
-- USING silently filters writes too: updating another hood touches 0 rows.
UPDATE showcase_security.complaints SET status = 'under_review'
WHERE neighborhood_id = 4;
-- WITH CHECK rejects moving a row out of your own neighbourhood.
DO $$
BEGIN
    UPDATE showcase_security.complaints SET neighborhood_id = 4
    WHERE complaint_id = (SELECT min(complaint_id) FROM showcase_security.complaints);
    RAISE NOTICE 'unexpected: the row moved';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'WITH CHECK blocked the move: % (SQLSTATE %)', SQLERRM, SQLSTATE;
END $$;
RESET ROLE;

SET ROLE showcase_analyst;
SELECT current_user AS acting_as, count(*) AS visible_complaints FROM showcase_security.complaints;
DO $$
BEGIN
    PERFORM reporter_email FROM showcase_security.complaints LIMIT 1;
    RAISE NOTICE 'unexpected: analyst read reporter_email';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'column privilege blocked PII: %', SQLERRM;
END $$;
RESET ROLE;

SET ROLE showcase_auditor;
SELECT current_user AS acting_as, count(*) AS visible_complaints_default_deny FROM showcase_security.complaints;
RESET ROLE;

-- Superusers and roles with BYPASSRLS ignore policies; so does the table
-- owner unless ALTER TABLE ... FORCE ROW LEVEL SECURITY is set.
SELECT current_user AS acting_as,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS is_superuser,
       count(*) AS visible_complaints_bypass
FROM showcase_security.complaints;

-- =============================================================================
\echo ''
\echo '=== 3. Masking view: PII hidden unless the caller is an auditor ==='
-- security_barrier stops user-supplied functions in WHERE from being pushed
-- below the masking and leaking raw values. The view runs with its owner's
-- rights (default security_invoker = false), so analysts need no access to
-- civics.citizens itself.
CREATE VIEW showcase_security.citizens_masked WITH (security_barrier = true) AS
SELECT c.citizen_id,
       CASE WHEN pg_has_role(current_user, 'showcase_auditor', 'MEMBER')
            THEN c.first_name || ' ' || c.last_name
            ELSE left(c.first_name, 1) || '. ' || left(c.last_name, 1) || '.' END        AS full_name,
       CASE WHEN pg_has_role(current_user, 'showcase_auditor', 'MEMBER')
            THEN c.email::text
            ELSE regexp_replace(c.email, '^(.).*(@.*)$', '\1***\2') END                 AS email,
       CASE WHEN pg_has_role(current_user, 'showcase_auditor', 'MEMBER')
            THEN c.phone::text
            ELSE regexp_replace(c.phone, '\d{4}$', 'XXXX') END                          AS phone,
       c.zip_code,
       date_part('year', age(meta.as_of(), c.date_of_birth::timestamptz))::int / 10 * 10 AS age_decade
FROM civics.citizens c;
GRANT SELECT ON showcase_security.citizens_masked TO showcase_analyst, showcase_auditor;

SET ROLE showcase_analyst;
SELECT * FROM showcase_security.citizens_masked ORDER BY citizen_id LIMIT 3;
DO $$
BEGIN
    PERFORM 1 FROM civics.citizens LIMIT 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'analyst cannot read the base table directly: %', SQLERRM;
END $$;
RESET ROLE;

SET ROLE showcase_auditor;
SELECT * FROM showcase_security.citizens_masked ORDER BY citizen_id LIMIT 3;
RESET ROLE;

-- =============================================================================
\echo ''
\echo '=== 4. Audit trail: who changed what, when (JSONB diff) ==='
CREATE TABLE showcase_security.audit_log (
    audit_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    logged_at    timestamptz NOT NULL DEFAULT clock_timestamp(),   -- wall clock: when it really happened
    acting_role  text        NOT NULL,                             -- the role that ran the statement
    session_user_name text   NOT NULL DEFAULT session_user,
    operation    text        NOT NULL,
    table_name   text        NOT NULL,
    row_pk       bigint,
    changed      jsonb
);

-- SECURITY DEFINER lets the trigger insert into audit_log although clerks have
-- no privilege on it. Pin search_path so a caller cannot hijack names.
CREATE FUNCTION showcase_security.audit_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, showcase_security AS $$
DECLARE diff jsonb;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(n.key, jsonb_build_object('old', o.value, 'new', n.value))
          INTO diff
        FROM jsonb_each(to_jsonb(NEW)) n
        JOIN jsonb_each(to_jsonb(OLD)) o USING (key)
        WHERE n.value IS DISTINCT FROM o.value;
    ELSE
        diff := to_jsonb(coalesce(NEW, OLD));
    END IF;
    -- Inside SECURITY DEFINER, current_user is the function OWNER, not the
    -- caller. The caller's SET ROLE is still visible in the "role" setting;
    -- session_user is the login role.
    INSERT INTO showcase_security.audit_log (acting_role, operation, table_name, row_pk, changed)
    VALUES (coalesce(nullif(current_setting('role'), 'none'), session_user), TG_OP, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
            (to_jsonb(coalesce(NEW, OLD)) ->> 'complaint_id')::bigint, diff);
    RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION showcase_security.audit_row() FROM PUBLIC;

CREATE TRIGGER trg_audit_complaints
AFTER INSERT OR UPDATE OR DELETE ON showcase_security.complaints
FOR EACH ROW EXECUTE FUNCTION showcase_security.audit_row();

SET ROLE showcase_clerk;     -- still scoped to neighbourhood 3 by RLS
-- Reopen the two oldest archived complaints for review.
UPDATE showcase_security.complaints
SET status = 'under_review', resolved_at = NULL
WHERE complaint_id IN (SELECT complaint_id FROM showcase_security.complaints
                       WHERE status = 'archived' ORDER BY complaint_id LIMIT 2);
DO $$
BEGIN
    PERFORM 1 FROM showcase_security.audit_log;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'clerks write the audit log only through the trigger; they cannot read it';
END $$;
RESET ROLE;

SELECT audit_id, acting_role, session_user_name, operation, row_pk,
       changed::text AS changed
FROM showcase_security.audit_log
ORDER BY audit_id;

-- =============================================================================
\echo ''
\echo '=== 5. Encryption with pgcrypto ==='
-- Reversible secret (e.g. a tax id): pgp_sym_encrypt with a key the database
-- never stores - here a session variable stands in for a KMS-provided key.
-- One-way secret (e.g. a PIN): bcrypt via crypt(pin, gen_salt('bf')).
SELECT set_config('showcase.key', 'demo-key-from-a-kms-not-from-source-code', false) IS NOT NULL AS key_loaded;

CREATE TABLE showcase_security.citizen_secrets (
    citizen_id  bigint PRIMARY KEY,
    tax_id_enc  bytea NOT NULL,
    pin_hash    text  NOT NULL
);
INSERT INTO showcase_security.citizen_secrets
SELECT citizen_id,
       pgp_sym_encrypt(format('900-%s-%s', lpad((citizen_id % 100)::text, 2, '0'), lpad(citizen_id::text, 4, '0')),
                       current_setting('showcase.key')),
       crypt(lpad((citizen_id * 7919 % 10000)::text, 4, '0'), gen_salt('bf', 8))
FROM civics.citizens
WHERE citizen_id <= 5;

SELECT citizen_id,
       octet_length(tax_id_enc)                                         AS ciphertext_bytes,
       pgp_sym_decrypt(tax_id_enc, current_setting('showcase.key'))     AS tax_id_decrypted,
       left(pin_hash, 7) || '...'                                       AS bcrypt_prefix,
       pin_hash = crypt(lpad((citizen_id * 7919 % 10000)::text, 4, '0'), pin_hash) AS right_pin_accepted,
       pin_hash = crypt('0000', pin_hash)                               AS wrong_pin_accepted
FROM showcase_security.citizen_secrets
ORDER BY citizen_id;

DO $$
BEGIN
    PERFORM pgp_sym_decrypt(tax_id_enc, 'wrong key') FROM showcase_security.citizen_secrets LIMIT 1;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'decrypting with the wrong key fails: %', SQLERRM;
END $$;
SELECT set_config('showcase.key', '', false) = '' AS key_cleared_from_session;

-- =============================================================================
\echo ''
\echo '=== 6. Privacy compliance: retention windows and the right to be forgotten ==='
CREATE TABLE showcase_security.retention_policies (
    data_category  text PRIMARY KEY,
    source_table   text NOT NULL,
    keep_for       interval NOT NULL,
    legal_basis    text NOT NULL
);
INSERT INTO showcase_security.retention_policies VALUES
    ('resolved complaints', 'documents.complaint_records', interval '6 months', 'municipal records schedule'),
    ('delivered orders',    'commerce.orders',             interval '1 year',   'tax law'),
    ('sensor telemetry',    'mobility.sensor_readings',    interval '90 days',  'operational need only');

-- How many rows are already past their retention window? (relative to the
-- dataset's "now"; a scheduled job would archive or delete them)
SELECT p.data_category, p.keep_for,
       CASE p.data_category
           WHEN 'resolved complaints' THEN (SELECT count(*) FROM documents.complaint_records
                                            WHERE status = 'resolved' AND resolved_at < meta.as_of() - p.keep_for)
           WHEN 'delivered orders'    THEN (SELECT count(*) FROM commerce.orders
                                            WHERE status = 'delivered' AND order_date < meta.as_of() - p.keep_for)
           WHEN 'sensor telemetry'    THEN (SELECT count(*) FROM mobility.sensor_readings
                                            WHERE reading_time < meta.as_of() - p.keep_for)
       END AS rows_past_retention
FROM showcase_security.retention_policies p
ORDER BY p.data_category;

-- Right to be forgotten on a module-owned copy of citizen profiles.
CREATE TABLE showcase_security.citizen_profiles AS
SELECT citizen_id, first_name, last_name, email::text AS email, phone, street_address, zip_code, home_geom
FROM civics.citizens WHERE citizen_id <= 10;
ALTER TABLE showcase_security.citizen_profiles ADD PRIMARY KEY (citizen_id);

CREATE FUNCTION showcase_security.forget_citizen(p_citizen_id bigint) RETURNS void
LANGUAGE sql AS $$
    UPDATE showcase_security.citizen_profiles
    SET first_name     = 'Anonymised',
        last_name      = left(md5(citizen_id::text), 8),           -- stable pseudonym for joins
        email          = 'erased-' || citizen_id || '@invalid.example',
        phone          = NULL,
        street_address = 'erased',
        home_geom      = ST_SnapToGrid(home_geom, 0.01)            -- keep ~1 km precision for statistics
    WHERE citizen_id = p_citizen_id;
$$;

SELECT 'before' AS state, citizen_id, first_name, last_name, email, phone, ST_AsText(home_geom) AS home
FROM showcase_security.citizen_profiles WHERE citizen_id = 7;
SELECT showcase_security.forget_citizen(7);
SELECT 'after' AS state, citizen_id, first_name, last_name, email, phone, ST_AsText(home_geom) AS home
FROM showcase_security.citizen_profiles WHERE citizen_id = 7;

-- =============================================================================
\echo ''
\echo '=== 7. Security assessment: what an auditor checks in the catalog ==='
-- 7a. Roles that bypass every policy
SELECT rolname, rolsuper, rolbypassrls, rolcanlogin
FROM pg_roles
WHERE (rolsuper OR rolbypassrls) AND rolname !~ '^pg_'
ORDER BY rolname;

-- 7b. Tables with RLS, and whether it is forced for the owner
SELECT n.nspname || '.' || c.relname AS table_name, c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS rls_forced,
       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relrowsecurity
ORDER BY 1
LIMIT 10;

-- 7c. SECURITY DEFINER functions without a pinned search_path (a classic hole)
SELECT p.oid::regprocedure AS function_name,
       coalesce(array_to_string(p.proconfig, ', '), '<none>') AS settings,
       CASE WHEN p.proconfig::text LIKE '%search_path%' THEN 'ok' ELSE 'FIX: SET search_path' END AS verdict
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prosecdef
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY verdict DESC, 1
LIMIT 10;

-- 7d. Schemas where PUBLIC may create objects (PG15+ revokes this on "public" by default)
SELECT n.nspname AS schema_name, a.privilege_type
FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
WHERE a.grantee = 0 AND a.privilege_type = 'CREATE'
ORDER BY 1;

-- 7e. Who is connected right now (wall clock: now() is correct here)
SELECT usename, application_name, state, count(*) AS sessions,
       max(now() - backend_start) AS oldest_session_age
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, application_name, state
ORDER BY sessions DESC, usename
LIMIT 5;

-- =============================================================================
\echo ''
\echo '=== 8. Cleanup: remove every object and role this showcase created ==='
SELECT set_config('showcase.neighborhood_id', '', false) = '' AS context_cleared;
DROP SCHEMA showcase_security CASCADE;
DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['showcase_clerk', 'showcase_analyst', 'showcase_auditor'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('DROP OWNED BY %I', r);          -- privileges in this database
            BEGIN
                EXECUTE format('DROP ROLE %I', r);
            EXCEPTION WHEN dependent_objects_still_exist OR undefined_object THEN
                RAISE NOTICE 'role % still used in another database (or already dropped) - kept', r;
            END;
        END IF;
    END LOOP;
END $$;

SELECT (SELECT count(*) FROM pg_namespace WHERE nspname = 'showcase_security') AS leftover_schemas,
       (SELECT count(*) FROM pg_class WHERE relrowsecurity
          AND relnamespace::regnamespace::text IN ('civics','commerce','mobility','geo','documents')) AS base_tables_with_rls;
