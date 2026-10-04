-- File: sql/00_init/000_schemas.sql
-- Purpose: Create the domain and support schemas every module builds on.
--
-- Idempotent and destructive: drops and recreates all curriculum schemas.
-- Objects are owned by the connecting role (POSTGRES_USER in Docker), so the
-- script works under any superuser name.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP SCHEMA IF EXISTS civics, commerce, mobility, geo, documents,
                      analytics, audit, auth CASCADE;

-- Core domain schemas
CREATE SCHEMA civics;
COMMENT ON SCHEMA civics IS 'Citizen management, permits, taxes, voting records';

CREATE SCHEMA commerce;
COMMENT ON SCHEMA commerce IS 'Merchants, orders, payments, business licenses';

CREATE SCHEMA mobility;
COMMENT ON SCHEMA mobility IS 'Transportation, trips, sensors, station inventory';

CREATE SCHEMA geo;
COMMENT ON SCHEMA geo IS 'Geospatial data, neighborhoods, roads, points of interest';

CREATE SCHEMA documents;
COMMENT ON SCHEMA documents IS 'JSONB document storage for complaints, policies, notes';

-- Support schemas
CREATE SCHEMA analytics;
COMMENT ON SCHEMA analytics IS 'Views, materialized views, and analytical functions';

CREATE SCHEMA audit;
COMMENT ON SCHEMA audit IS 'Audit trails and security logging';

CREATE SCHEMA auth;
COMMENT ON SCHEMA auth IS 'Session context helpers used by row-level security policies';

-- Privileges for the application roles created at first boot
-- (docker/initdb/020_roles.sql). Guarded so the file also runs on a bare
-- PostgreSQL where those roles do not exist.
DO $$
DECLARE
    s text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'polaris_app_readonly') THEN
        RAISE NOTICE 'application roles not found; skipping grants';
        RETURN;
    END IF;

    FOREACH s IN ARRAY ARRAY['civics','commerce','mobility','geo','documents','analytics','auth'] LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO polaris_app_readonly, polaris_app_readwrite', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO polaris_app_readonly', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO polaris_app_readwrite', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO polaris_app_readwrite', s);
    END LOOP;

    GRANT CREATE ON SCHEMA analytics TO polaris_analyst;
    GRANT USAGE ON SCHEMA audit TO polaris_auditor;
    ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT ON TABLES TO polaris_auditor;
END
$$;

-- Resolve unqualified names across domains in interactive sessions.
SELECT format(
    'ALTER DATABASE %I SET search_path = public, civics, commerce, mobility, geo, documents, analytics, audit',
    current_database())
\gexec
