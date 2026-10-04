-- First-boot initialisation, step 1: databases.
-- The entrypoint runs this file connected to $POSTGRES_DB as $POSTGRES_USER.
\set ON_ERROR_STOP on

-- Scratch database used by tests that must not touch the main dataset.
SELECT format('CREATE DATABASE polaris_test TEMPLATE template0 ENCODING %L', 'UTF8')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'polaris_test')
\gexec

-- Every curriculum object lives in a domain schema; make them resolvable
-- without qualification in interactive sessions.
SELECT format(
    'ALTER DATABASE %I SET search_path = public, civics, commerce, mobility, geo, documents, analytics, audit',
    current_database())
\gexec
