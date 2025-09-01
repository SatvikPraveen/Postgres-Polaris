-- File: docker/initdb/010_enable_extensions.sql
-- Enable PostgreSQL extensions for postgres-polaris
-- Executed only on first container startup

\echo 'Enabling PostgreSQL extensions...'

-- Connect to main database
\c polaris;

-- Core extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "hstore";
CREATE EXTENSION IF NOT EXISTS "ltree";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
CREATE EXTENSION IF NOT EXISTS "btree_gist";
CREATE EXTENSION IF NOT EXISTS "intarray";
CREATE EXTENSION IF NOT EXISTS "unaccent";

-- PostGIS extensions (spatial data)
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "postgis_topology";
CREATE EXTENSION IF NOT EXISTS "postgis_raster";
CREATE EXTENSION IF NOT EXISTS "address_standardizer";
CREATE EXTENSION IF NOT EXISTS "address_standardizer_data_us";
CREATE EXTENSION IF NOT EXISTS "postgis_tiger_geocoder";

-- Full-text search
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "fuzzystrmatch";

-- Statistics and monitoring
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "pg_buffercache";

-- Partitioning and maintenance
CREATE EXTENSION IF NOT EXISTS "pg_partman";

-- Scheduling (pg_cron)
CREATE EXTENSION IF NOT EXISTS "pg_cron";

-- Testing (if available)
CREATE EXTENSION IF NOT EXISTS "pgtap";

-- JSON/JSONB enhancements
CREATE EXTENSION IF NOT EXISTS "tablefunc";

-- Data validation
CREATE EXTENSION IF NOT EXISTS "isn";
CREATE EXTENSION IF NOT EXISTS "citext";

-- Foreign data wrappers
CREATE EXTENSION IF NOT EXISTS "file_fdw";
CREATE EXTENSION IF NOT EXISTS "postgres_fdw";

-- Enable pg_cron database
UPDATE pg_database SET datallowconn = 'true' WHERE datname = 'postgres';
GRANT USAGE ON SCHEMA cron TO polaris_admin;

\echo 'Extensions enabled successfully.';

-- Verify critical extensions
\echo 'Verifying extensions...'
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('postgis', 'uuid-ossp', 'pgcrypto', 'pg_trgm', 'pg_cron', 'pg_partman')
ORDER BY extname;
