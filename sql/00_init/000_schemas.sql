-- File: sql/00_init/000_schemas.sql
-- Purpose: Create schema shells for organizing city data

-- Clean slate
DROP SCHEMA IF EXISTS civics CASCADE;
DROP SCHEMA IF EXISTS commerce CASCADE;
DROP SCHEMA IF EXISTS mobility CASCADE;
DROP SCHEMA IF EXISTS geo CASCADE;
DROP SCHEMA IF EXISTS documents CASCADE;
DROP SCHEMA IF EXISTS analytics CASCADE;
DROP SCHEMA IF EXISTS audit CASCADE;

-- Core domain schemas
CREATE SCHEMA civics AUTHORIZATION postgres;
COMMENT ON SCHEMA civics IS 'Citizen management, permits, taxes, voting records';

CREATE SCHEMA commerce AUTHORIZATION postgres;
COMMENT ON SCHEMA commerce IS 'Merchants, orders, payments, business licenses';

CREATE SCHEMA mobility AUTHORIZATION postgres;
COMMENT ON SCHEMA mobility IS 'Transportation, trips, sensors, station inventory';

CREATE SCHEMA geo AUTHORIZATION postgres;
COMMENT ON SCHEMA geo IS 'Geospatial data, neighborhoods, roads, points of interest';

CREATE SCHEMA documents AUTHORIZATION postgres;
COMMENT ON SCHEMA documents IS 'JSONB document storage for complaints, policies, notes';

-- Support schemas
CREATE SCHEMA analytics AUTHORIZATION postgres;
COMMENT ON SCHEMA analytics IS 'Views, materialized views, and analytical functions';

CREATE SCHEMA audit AUTHORIZATION postgres;
COMMENT ON SCHEMA audit IS 'Audit trails and security logging';

-- Grant basic usage
GRANT USAGE ON SCHEMA civics TO PUBLIC;
GRANT USAGE ON SCHEMA commerce TO PUBLIC;
GRANT USAGE ON SCHEMA mobility TO PUBLIC;
GRANT USAGE ON SCHEMA geo TO PUBLIC;
GRANT USAGE ON SCHEMA documents TO PUBLIC;
GRANT USAGE ON SCHEMA analytics TO PUBLIC;

-- Set search path to include all schemas
ALTER DATABASE postgres SET search_path = public, civics, commerce, mobility, geo, documents, analytics, audit;
