-- File: docker/initdb/020_roles_and_security.sql
-- Create roles and security setup for postgres-polaris
-- Executed only on first container startup

\echo 'Setting up roles and security...'

-- Connect to main database
\c polaris;

-- Create application roles
CREATE ROLE polaris_app_readonly;
CREATE ROLE polaris_app_readwrite;
CREATE ROLE polaris_analyst;
CREATE ROLE polaris_developer;

-- Create users for different access levels
CREATE USER polaris_app_user WITH
    PASSWORD 'app_user_secure_2024'
    IN ROLE polaris_app_readwrite;

CREATE USER polaris_readonly_user WITH
    PASSWORD 'readonly_secure_2024'
    IN ROLE polaris_app_readonly;

CREATE USER polaris_analyst_user WITH
    PASSWORD 'analyst_secure_2024'
    IN ROLE polaris_analyst;

CREATE USER polaris_dev_user WITH
    PASSWORD 'dev_secure_2024'
    IN ROLE polaris_developer;

-- Grant schema usage to roles
GRANT USAGE ON SCHEMA civics TO polaris_app_readonly, polaris_app_readwrite, polaris_analyst, polaris_developer;
GRANT USAGE ON SCHEMA commerce TO polaris_app_readonly, polaris_app_readwrite, polaris_analyst, polaris_developer;
GRANT USAGE ON SCHEMA mobility TO polaris_app_readonly, polaris_app_readwrite, polaris_analyst, polaris_developer;
GRANT USAGE ON SCHEMA geo TO polaris_app_readonly, polaris_app_readwrite, polaris_analyst, polaris_developer;
GRANT USAGE ON SCHEMA documents TO polaris_app_readonly, polaris_app_readwrite, polaris_analyst, polaris_developer;
GRANT USAGE ON SCHEMA analytics TO polaris_app_readonly, polaris_app_readwrite, polaris_analyst, polaris_developer;

-- Read-only permissions
GRANT SELECT ON ALL TABLES IN SCHEMA civics TO polaris_app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA commerce TO polaris_app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA mobility TO polaris_app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA geo TO polaris_app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA documents TO polaris_app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO polaris_app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO polaris_app_readonly;

-- Read-write permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA civics TO polaris_app_readwrite;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA commerce TO polaris_app_readwrite;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA mobility TO polaris_app_readwrite;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA geo TO polaris_app_readwrite;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA documents TO polaris_app_readwrite;

-- Analyst permissions (includes analytics schema)
GRANT polaris_app_readonly TO polaris_analyst;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA analytics TO polaris_analyst;
GRANT CREATE ON SCHEMA analytics TO polaris_analyst;

-- Developer permissions (broader access for development)
GRANT polaris_app_readwrite TO polaris_developer;
GRANT polaris_analyst TO polaris_developer;
GRANT CREATE ON SCHEMA civics TO polaris_developer;
GRANT CREATE ON SCHEMA commerce TO polaris_developer;
GRANT CREATE ON SCHEMA mobility TO polaris_developer;
GRANT CREATE ON SCHEMA geo TO polaris_developer;
GRANT CREATE ON SCHEMA documents TO polaris_developer;

-- Grant sequence usage
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA civics TO polaris_app_readwrite, polaris_developer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA commerce TO polaris_app_readwrite, polaris_developer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA mobility TO polaris_app_readwrite, polaris_developer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA geo TO polaris_app_readwrite, polaris_developer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA documents TO polaris_app_readwrite, polaris_developer;

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA civics GRANT SELECT ON TABLES TO polaris_app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA commerce GRANT SELECT ON TABLES TO polaris_app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA mobility GRANT SELECT ON TABLES TO polaris_app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA geo GRANT SELECT ON TABLES TO polaris_app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA documents GRANT SELECT ON TABLES TO polaris_app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO polaris_app_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA civics GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA commerce GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA mobility GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA geo GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA documents GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO polaris_app_readwrite;

ALTER DEFAULT PRIVILEGES IN SCHEMA civics GRANT USAGE, SELECT ON SEQUENCES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA commerce GRANT USAGE, SELECT ON SEQUENCES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA mobility GRANT USAGE, SELECT ON SEQUENCES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA geo GRANT USAGE, SELECT ON SEQUENCES TO polaris_app_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA documents GRANT USAGE, SELECT ON SEQUENCES TO polaris_app_readwrite;

-- Row Level Security setup (will be configured in specific modules)
-- Enable RLS by default on sensitive schemas
-- ALTER TABLE civics.citizens ENABLE ROW LEVEL SECURITY;
-- This will be done in the specific schema modules

-- Create audit role for security monitoring
CREATE ROLE polaris_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO polaris_auditor;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT ON TABLES TO polaris_auditor;

-- Security settings
SET log_statement = 'ddl';
SET log_connections = on;
SET log_disconnections = on;

\echo 'Roles and security setup completed successfully.';

-- Display created roles
\echo 'Created roles:'
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin
FROM pg_roles
WHERE rolname LIKE 'polaris_%'
ORDER BY rolname;
