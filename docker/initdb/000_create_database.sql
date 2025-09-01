-- File: docker/initdb/000_create_database.sql
-- Create database and initial setup for postgres-polaris
-- Executed only on first container startup

\echo 'Creating polaris database and initial setup...'

-- Create additional databases if needed
CREATE DATABASE polaris_test WITH
    OWNER = polaris_admin
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.UTF-8'
    LC_CTYPE = 'en_US.UTF-8'
    TEMPLATE = template0;

-- Connect to main database
\c polaris;

-- Create main schemas
CREATE SCHEMA IF NOT EXISTS civics AUTHORIZATION polaris_admin;
CREATE SCHEMA IF NOT EXISTS commerce AUTHORIZATION polaris_admin;
CREATE SCHEMA IF NOT EXISTS mobility AUTHORIZATION polaris_admin;
CREATE SCHEMA IF NOT EXISTS geo AUTHORIZATION polaris_admin;
CREATE SCHEMA IF NOT EXISTS documents AUTHORIZATION polaris_admin;
CREATE SCHEMA IF NOT EXISTS audit AUTHORIZATION polaris_admin;
CREATE SCHEMA IF NOT EXISTS analytics AUTHORIZATION polaris_admin;
CREATE SCHEMA IF NOT EXISTS monitoring AUTHORIZATION polaris_admin;

-- Set schema permissions
GRANT USAGE ON SCHEMA civics TO PUBLIC;
GRANT USAGE ON SCHEMA commerce TO PUBLIC;
GRANT USAGE ON SCHEMA mobility TO PUBLIC;
GRANT USAGE ON SCHEMA geo TO PUBLIC;
GRANT USAGE ON SCHEMA documents TO PUBLIC;
GRANT USAGE ON SCHEMA audit TO PUBLIC;
GRANT USAGE ON SCHEMA analytics TO PUBLIC;
GRANT USAGE ON SCHEMA monitoring TO PUBLIC;

-- Create application-specific tablespaces (optional)
-- CREATE TABLESPACE polaris_data LOCATION '/var/lib/postgresql/tablespaces/data';
-- CREATE TABLESPACE polaris_indexes LOCATION '/var/lib/postgresql/tablespaces/indexes';

\echo 'Database polaris created successfully with initial schemas.';
