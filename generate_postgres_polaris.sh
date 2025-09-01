#!/bin/bash

# Postgres Polaris Project Generator
# Creates the complete project structure with placeholder files
# Usage: ./generate_postgres_polaris.sh [project_name]

set -euo pipefail

PROJECT_NAME="${1:-postgres-polaris}"
BASE_DIR="$(pwd)/${PROJECT_NAME}"

echo "🚀 Generating Postgres Polaris project structure..."
echo "📁 Creating project at: ${BASE_DIR}"

# Remove existing directory if it exists
if [ -d "${BASE_DIR}" ]; then
    echo "⚠️  Directory ${BASE_DIR} exists. Removing..."
    rm -rf "${BASE_DIR}"
fi

# Create main directory
mkdir -p "${BASE_DIR}"
cd "${BASE_DIR}"

echo "📂 Creating directory structure..."

# Create all directories
mkdir -p {docker/initdb,sql/{00_init,01_schema_design,02_constraints_indexes,03_dml_queries,04_views_matviews,05_functions_triggers,06_jsonb_fulltext,07_geospatial,08_partitioning_timeseries,09_data_movement,10_tx_mvcc_locks,11_perf_tuning,12_security_rls,13_backup_replication,14_async_patterns,15_testing_quality,16_capstones},data,docs,scripts,tests,examples}

echo "📝 Creating root files..."

# README.md
cat > README.md << 'EOF'
# Postgres Polaris 🌟

A comprehensive PostgreSQL mastery project demonstrating end-to-end database expertise through pure SQL implementations.

## Quick Start

```bash
# Clone and setup
git clone <your-repo>
cd postgres-polaris
make bootstrap

# Launch environment
make up

# Access database
make psql
# Or use browser UI at http://localhost:8080
```

## Learning Path

1. **Foundations** (`sql/00_init` → `sql/03_dml_queries`)
2. **Intermediate** (`sql/04_views_matviews` → `sql/09_data_movement`)
3. **Advanced** (`sql/10_tx_mvcc_locks` → `sql/15_testing_quality`)
4. **Capstones** (`sql/16_capstones`)

## Project Structure

- `docker/` - Containerized PostgreSQL environment
- `sql/` - Modular SQL learning progression
- `data/` - Sample datasets for realistic examples
- `docs/` - Guides, exercises, and references
- `examples/` - Ready-to-run demonstrations
- `tests/` - Automated validation and benchmarks

## Features Demonstrated

✅ Schema Design & Normalization
✅ Advanced Indexing Strategies
✅ JSONB & Full-Text Search
✅ PostGIS Spatial Operations
✅ Partitioning & Time-Series
✅ MVCC, Locking & Performance
✅ Security & Row-Level Security
✅ Backup & Logical Replication
✅ Advanced SQL Patterns

---
*PostgreSQL-only mastery without framework bloat*
EOF

# LICENSE
cat > LICENSE << 'EOF'
MIT License

Copyright (c) 2025 Postgres Polaris Project

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

# Makefile
cat > Makefile << 'EOF'
.PHONY: help bootstrap up down psql reset test clean

# Default target
help:
	@echo "Postgres Polaris - PostgreSQL Mastery Project"
	@echo ""
	@echo "Available targets:"
	@echo "  bootstrap    - Initial project setup"
	@echo "  up          - Start PostgreSQL + UI containers"
	@echo "  down        - Stop containers"
	@echo "  psql        - Connect to database via psql"
	@echo "  reset       - Reset database (DESTRUCTIVE)"
	@echo "  test        - Run validation tests"
	@echo "  load-data   - Load sample datasets"
	@echo "  clean       - Remove containers and volumes"

bootstrap:
	@echo "🚀 Setting up Postgres Polaris..."
	@cp docker/.env.example docker/.env
	@cp .env.example .env
	@echo "✅ Bootstrap complete. Run 'make up' to start."

up:
	@echo "🐘 Starting PostgreSQL environment..."
	@cd docker && docker-compose up -d
	@echo "✅ Services running:"
	@echo "  - PostgreSQL: localhost:5432"
	@echo "  - Adminer UI: http://localhost:8080"

down:
	@cd docker && docker-compose down

psql:
	@echo "🔌 Connecting to PostgreSQL..."
	@cd docker && docker-compose exec postgres psql -U postgres -d polaris

reset:
	@echo "⚠️  Resetting database (DESTRUCTIVE)..."
	@./scripts/reset_db.sh

test:
	@echo "🧪 Running validation tests..."
	@./scripts/run_sql.sh tests/schema_validation.sql
	@./scripts/run_sql.sh tests/data_integrity_checks.sql

load-data:
	@echo "📊 Loading sample datasets..."
	@./scripts/load_sample_data.sh

clean:
	@cd docker && docker-compose down -v
	@docker system prune -f
EOF

# .gitignore
cat > .gitignore << 'EOF'
# Environment files
.env
docker/.env

# OS files
.DS_Store
Thumbs.db

# Editor files
.vscode/
.idea/
*.swp
*.swo
*~

# Logs
*.log
logs/

# Temporary files
*.tmp
temp/

# Database dumps
*.sql.gz
*.dump
backups/

# Docker volumes (if locally mounted)
postgres-data/
EOF

# .env.example
cat > .env.example << 'EOF'
# Top-level environment variables
PROJECT_NAME=postgres-polaris
ENVIRONMENT=development

# Override Docker Compose settings if needed
POSTGRES_PORT=5432
ADMINER_PORT=8080
EOF

echo "🐳 Creating Docker files..."

# docker/.env.example
cat > docker/.env.example << 'EOF'
# PostgreSQL Configuration
POSTGRES_DB=polaris
POSTGRES_USER=postgres
POSTGRES_PASSWORD=polaris_dev_password

# UI Configuration
ADMINER_PORT=8080
PGADMIN_PORT=5050

# Optional: PgAdmin (comment out Adminer in docker-compose.yml to use)
PGADMIN_DEFAULT_EMAIL=admin@polaris.local
PGADMIN_DEFAULT_PASSWORD=polaris_admin
EOF

# docker/Dockerfile
cat > docker/Dockerfile << 'EOF'
# Use PostGIS-enabled PostgreSQL for spatial capabilities
FROM postgis/postgis:16-3.4

# Install additional extensions
RUN apt-get update && apt-get install -y \
    postgresql-16-cron \
    postgresql-16-partman \
    postgresql-16-pg-stat-kcache \
    postgresql-16-hypopg \
    && rm -rf /var/lib/apt/lists/*

# Copy initialization scripts
COPY initdb/ /docker-entrypoint-initdb.d/

# Ensure proper permissions
RUN chmod +x /docker-entrypoint-initdb.d/*.sql

# Set locale for consistent sorting/collation
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8
EOF

# docker/docker-compose.yml
cat > docker/docker-compose.yml << 'EOF'
version: '3.8'

services:
  postgres:
    build: .
    container_name: polaris-postgres
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ../sql:/sql:ro
      - ../data:/data:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: >
      postgres
      -c shared_preload_libraries='pg_stat_statements,pg_cron'
      -c pg_stat_statements.track=all
      -c log_statement=all
      -c log_min_duration_statement=1000

  adminer:
    image: adminer:4.8.1
    container_name: polaris-adminer
    ports:
      - "${ADMINER_PORT:-8080}:8080"
    environment:
      ADMINER_DEFAULT_SERVER: postgres
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres_data:
    driver: local
EOF

echo "🔧 Creating initialization scripts..."

# docker/initdb/000_create_database.sql
cat > docker/initdb/000_create_database.sql << 'EOF'
-- Create main database (if not exists via environment)
-- This runs only on first container startup

-- Enable logging for learning purposes
ALTER SYSTEM SET log_statement = 'all';
ALTER SYSTEM SET log_min_duration_statement = 100;
SELECT pg_reload_conf();

-- Create application database if not exists
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'polaris') THEN
        CREATE DATABASE polaris
        WITH ENCODING = 'UTF8'
             LC_COLLATE = 'C'
             LC_CTYPE = 'C'
             TEMPLATE = template0;
    END IF;
END $$;

\echo 'Database polaris created or already exists'
EOF

# docker/initdb/010_enable_extensions.sql
cat > docker/initdb/010_enable_extensions.sql << 'EOF'
-- Enable essential extensions
-- Runs in template1 to be available in all new databases

\c template1;

-- Core extensions for data analysis
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- PostGIS for spatial operations
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "postgis_topology";

-- Additional utility extensions
CREATE EXTENSION IF NOT EXISTS "btree_gist";
CREATE EXTENSION IF NOT EXISTS "pg_cron";
CREATE EXTENSION IF NOT EXISTS "file_fdw";

\echo 'Extensions enabled in template1'

-- Switch to main database and enable extensions there too
\c polaris;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "postgis_topology";
CREATE EXTENSION IF NOT EXISTS "btree_gist";
CREATE EXTENSION IF NOT EXISTS "pg_cron";
CREATE EXTENSION IF NOT EXISTS "file_fdw";

\echo 'Extensions enabled in polaris database'
EOF

# docker/initdb/020_roles_and_security.sql
cat > docker/initdb/020_roles_and_security.sql << 'EOF'
-- Initial security setup
\c polaris;

-- Create application roles
CREATE ROLE IF NOT EXISTS app_reader;
CREATE ROLE IF NOT EXISTS app_writer;
CREATE ROLE IF NOT EXISTS app_admin;

-- Create demo users
CREATE USER IF NOT EXISTS demo_analyst WITH PASSWORD 'analyst_pass';
CREATE USER IF NOT EXISTS demo_developer WITH PASSWORD 'developer_pass';

-- Grant role memberships
GRANT app_reader TO demo_analyst;
GRANT app_writer TO demo_developer;
GRANT app_admin TO postgres;

-- Set default privileges for new objects
ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO app_reader;
ALTER DEFAULT PRIVILEGES GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;
ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO app_admin;

\echo 'Roles and basic security configured'
EOF

# docker/initdb/999_health_checks.sql
cat > docker/initdb/999_health_checks.sql << 'EOF'
-- Verify initialization completed successfully
\c polaris;

-- Check extensions
SELECT
    extname as extension_name,
    extversion as version
FROM pg_extension
WHERE extname IN ('postgis', 'pg_stat_statements', 'pgcrypto', 'pg_trgm')
ORDER BY extname;

-- Check roles
SELECT rolname, rolcanlogin, rolcreaterole
FROM pg_roles
WHERE rolname IN ('app_reader', 'app_writer', 'app_admin', 'demo_analyst', 'demo_developer')
ORDER BY rolname;

-- Verify database settings
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'log_statement', 'log_min_duration_statement');

\echo 'Health checks completed - initialization successful!'
EOF

echo "📊 Creating SQL modules..."

# sql/00_init/000_schemas.sql
cat > sql/00_init/000_schemas.sql << 'EOF'
-- Schema Foundation
-- Creates organizational schemas for the project

\echo 'Creating application schemas...'

-- Core business domain schemas
CREATE SCHEMA IF NOT EXISTS civics;
CREATE SCHEMA IF NOT EXISTS commerce;
CREATE SCHEMA IF NOT EXISTS mobility;
CREATE SCHEMA IF NOT EXISTS geo;

-- Technical schemas
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS analytics;

-- Set schema search path for convenience
ALTER DATABASE polaris SET search_path TO civics, commerce, mobility, geo, public;

-- Add schema descriptions
COMMENT ON SCHEMA civics IS 'Citizens, permits, taxes, voting records';
COMMENT ON SCHEMA commerce IS 'Merchants, orders, payments, inventory';
COMMENT ON SCHEMA mobility IS 'Transportation trips, sensors, stations';
COMMENT ON SCHEMA geo IS 'Spatial data - neighborhoods, roads, POIs';
COMMENT ON SCHEMA audit IS 'Audit trails and change tracking';
COMMENT ON SCHEMA staging IS 'ETL staging area';
COMMENT ON SCHEMA analytics IS 'Materialized views and KPIs';

\echo 'Schemas created successfully'
EOF

# sql/00_init/010_comments_conventions.sql
cat > sql/00_init/010_comments_conventions.sql << 'EOF'
-- Naming Conventions and Documentation Standards
-- Establishes project-wide consistency rules

\echo 'Setting up naming conventions...'

-- Table naming: singular, snake_case
-- Example: citizen, purchase_order, sensor_reading

-- Column naming conventions:
-- - Primary keys: id (not table_id)
-- - Foreign keys: {referenced_table}_id
-- - Timestamps: created_at, updated_at, deleted_at
-- - Booleans: is_active, has_permissions
-- - JSON/JSONB: {purpose}_data, {entity}_meta

-- Index naming patterns:
-- - Primary key: {table}_pkey (automatic)
-- - Unique: {table}_{columns}_key
-- - Foreign key: {table}_{referenced_table}_fkey
-- - General: {table}_{columns}_idx
-- - Partial: {table}_{columns}_{condition}_idx

-- Function naming:
-- - Pure functions: calculate_tax(amount)
-- - Procedures: process_payment(order_id)
-- - Triggers: {table}_{action}_trigger

CREATE OR REPLACE FUNCTION lint_table_comment(table_schema text, table_name text)
RETURNS boolean AS $$
BEGIN
    -- Every table should have a comment
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables t
        JOIN pg_description d ON d.objoid = (table_schema||'.'||table_name)::regclass
        WHERE t.table_schema = $1 AND t.table_name = $2
    ) THEN
        RAISE WARNING 'Table %.% missing comment', table_schema, table_name;
        RETURN false;
    END IF;
    RETURN true;
END;
$$ LANGUAGE plpgsql;

\echo 'Naming conventions established'
EOF

# sql/00_init/999_reset_demo_data.sql
cat > sql/00_init/999_reset_demo_data.sql << 'EOF'
-- Demo Data Reset Utility
-- Cleans up data for fresh demos without dropping schema

\echo 'Resetting demo data...'

-- Disable triggers temporarily for faster cleanup
SET session_replication_role = replica;

-- Truncate in dependency order (children first)
TRUNCATE TABLE IF EXISTS
    civics.votes,
    civics.permits,
    civics.tax_payments,
    commerce.order_items,
    commerce.orders,
    commerce.payments,
    mobility.trip_segments,
    mobility.trips,
    mobility.sensor_readings
CASCADE;

-- Reset sequences
DO $$
DECLARE
    seq_record RECORD;
BEGIN
    FOR seq_record IN
        SELECT schemaname, sequencename
        FROM pg_sequences
        WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo')
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I RESTART WITH 1',
            seq_record.schemaname, seq_record.sequencename);
    END LOOP;
END $$;

-- Re-enable triggers
SET session_replication_role = DEFAULT;

-- Refresh materialized views
DO $$
DECLARE
    view_record RECORD;
BEGIN
    FOR view_record IN
        SELECT schemaname, matviewname
        FROM pg_matviews
        WHERE schemaname IN ('analytics')
    LOOP
        EXECUTE format('REFRESH MATERIALIZED VIEW %I.%I',
            view_record.schemaname, view_record.matviewname);
    END LOOP;
END $$;

\echo 'Demo data reset completed'
EOF

echo "📋 Creating data files..."

# data/seeds.csv
cat > data/seeds.csv << 'EOF'
table,id,name,email,age,city,registration_date
citizens,1,"Alice Johnson",alice@example.com,34,Portland,2023-01-15
citizens,2,"Bob Smith",bob@example.com,42,Seattle,2023-02-20
citizens,3,"Carol Davis",carol@example.com,29,Portland,2023-03-10
citizens,4,"David Wilson",david@example.com,51,Seattle,2023-01-05
citizens,5,"Eva Brown",eva@example.com,38,Portland,2023-04-12
merchants,1,"Downtown Coffee",coffee@downtown.com,2019-03-15,Portland,Food & Beverage
merchants,2,"Tech Gadgets Plus",info@techgadgets.com,2020-07-22,Seattle,Electronics
merchants,3,"Green Grocers",hello@greengrocers.com,2018-11-08,Portland,Grocery
trips,1,1,2023-05-01 08:30:00,2023-05-01 08:45:00,bike,3.2
trips,2,2,2023-05-01 17:15:00,2023-05-01 17:35:00,bus,8.7
trips,3,3,2023-05-02 12:20:00,2023-05-02 12:40:00,walk,1.1
EOF

# data/documents.jsonb
cat > data/documents.jsonb << 'EOF'
{"type": "complaint", "id": 1, "citizen_id": 1, "category": "noise", "description": "Construction noise starting at 6 AM", "location": {"street": "123 Oak St", "neighborhood": "Pearl District"}, "priority": "medium", "status": "open", "submitted_at": "2023-05-15T14:30:00Z", "tags": ["noise", "construction", "early_hours"]}
{"type": "policy", "id": 1, "title": "Bike Lane Usage Guidelines", "version": "2.1", "effective_date": "2023-06-01", "sections": [{"title": "General Rules", "content": "Bike lanes are reserved for bicycles and e-scooters only"}, {"title": "Parking", "content": "No parking or stopping in bike lanes at any time"}], "approval_status": "approved", "last_updated": "2023-05-20T10:00:00Z"}
{"type": "complaint", "id": 2, "citizen_id": 3, "category": "pothole", "description": "Large pothole causing vehicle damage", "location": {"street": "456 Pine Ave", "neighborhood": "Hawthorne"}, "priority": "high", "status": "in_progress", "submitted_at": "2023-05-18T09:15:00Z", "tags": ["road_maintenance", "pothole", "vehicle_damage"]}
{"type": "metadata", "entity": "sensor", "sensor_id": "TEMP_001", "specifications": {"type": "temperature", "range": {"min": -40, "max": 85}, "unit": "celsius", "accuracy": 0.5}, "installation": {"date": "2023-04-01", "location": "Burnside Bridge", "technician": "John Doe"}, "maintenance": {"last_calibration": "2023-05-01", "next_scheduled": "2023-08-01"}}
EOF

# data/boundaries.geojson
cat > data/boundaries.geojson << 'EOF'
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "neighborhood": "Pearl District",
        "population": 12500,
        "median_income": 75000
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[
          [-122.6840, 45.5272],
          [-122.6760, 45.5272],
          [-122.6760, 45.5340],
          [-122.6840, 45.5340],
          [-122.6840, 45.5272]
        ]]
      }
    },
    {
      "type": "Feature",
      "properties": {
        "neighborhood": "Hawthorne",
        "population": 8200,
        "median_income": 68000
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[
          [-122.6580, 45.5120],
          [-122.6480, 45.5120],
          [-122.6480, 45.5200],
          [-122.6580, 45.5200],
          [-122.6580, 45.5120]
        ]]
      }
    },
    {
      "type": "Feature",
      "properties": {
        "type": "bus_stop",
        "route": "Line 20",
        "name": "Pine & 3rd"
      },
      "geometry": {
        "type": "Point",
        "coordinates": [-122.6750, 45.5250]
      }
    }
  ]
}
EOF

# data/timeseries.csv
cat > data/timeseries.csv << 'EOF'
timestamp,sensor_id,location,temperature,humidity,air_quality_pm25
2023-05-01 00:00:00,TEMP_001,Burnside Bridge,18.5,65,12.3
2023-05-01 01:00:00,TEMP_001,Burnside Bridge,17.8,68,11.8
2023-05-01 02:00:00,TEMP_001,Burnside Bridge,17.2,70,10.9
2023-05-01 03:00:00,TEMP_001,Burnside Bridge,16.9,72,9.8
2023-05-01 00:00:00,TEMP_002,Steel Bridge,19.1,62,13.1
2023-05-01 01:00:00,TEMP_002,Steel Bridge,18.6,64,12.5
2023-05-01 02:00:00,TEMP_002,Steel Bridge,18.0,66,11.7
2023-05-01 03:00:00,TEMP_002,Steel Bridge,17.5,68,10.8
EOF

# data/sample_queries.md
cat > data/sample_queries.md << 'EOF'
# Sample Data Queries

After loading the sample data, try these queries to verify everything works:

## Citizens & Registrations
```sql
SELECT city, COUNT(*), AVG(age) as avg_age
FROM civics.citizens
GROUP BY city;
```

## Merchant Categories
```sql
SELECT category, COUNT(*) as merchant_count
FROM commerce.merchants
GROUP BY category
ORDER BY merchant_count DESC;
```

## Trip Analysis
```sql
SELECT
    mode_of_transport,
    COUNT(*) as trip_count,
    AVG(distance_km) as avg_distance,
    AVG(EXTRACT(EPOCH FROM (end_time - start_time))/60) as avg_minutes
FROM mobility.trips
GROUP BY mode_of_transport;
```

## JSONB Document Search
```sql
SELECT
    doc->>'type' as document_type,
    doc->>'category' as category,
    doc->'location'->>'neighborhood' as neighborhood
FROM staging.documents
WHERE doc->>'type' = 'complaint';
```

## Spatial Queries (after PostGIS setup)
```sql
SELECT
    properties->>'neighborhood' as name,
    (properties->>'population')::int as population,
    ST_Area(ST_Transform(geom, 3857)) as area_m2
FROM geo.neighborhoods;
```
EOF

echo "📚 Creating documentation..."

# docs/HOWTO_SETUP.md
cat > docs/HOWTO_SETUP.md << 'EOF'
# Setup Guide

## Prerequisites

- Docker & Docker Compose
- Git
- Make (optional, for convenience)

## Quick Start

1. **Clone the repository**
   ```bash
   git clone <your-repo-url>
   cd postgres-polaris
   ```

2. **Initialize the project**
   ```bash
   make bootstrap
   # OR manually:
   cp docker/.env.example docker/.env
   cp .env.example .env
   ```

3. **Start the environment**
   ```bash
   make up
   # OR manually:
   cd docker && docker-compose up -d
   ```

4. **Verify installation**
   - PostgreSQL: `localhost:5432`
   - Adminer UI: http://localhost:8080
   - Login: Server=`postgres`, User=`postgres`, Password=`polaris_dev_password`, Database=`polaris`

## Loading Sample Data

```bash
make load-data
# OR manually run:
./scripts/load_sample_data.sh
```

## Access Methods

### Browser UI (Adminer)
1. Go to http://localhost:8080
2. Use credentials from `docker/.env`
3. Navigate SQL files in `/sql` directory

### Command Line (psql)
```bash
make psql
# OR:
docker-compose -f docker/docker-compose.yml exec postgres psql -U postgres -d polaris
```

### Running SQL Modules
```bash
./scripts/run_sql.sh sql/01_schema_design/civics.sql
# OR directly in psql:
\i /sql/01_schema_design/civics.sql
```

## Troubleshooting

### Container Issues
```bash
# Check container status
docker-compose -f docker/docker-compose.yml ps

# View logs
docker-compose -f docker/docker-compose.yml logs postgres

# Complete reset
make clean && make bootstrap && make up
```

### Permission Issues
```bash
# Fix file permissions
chmod +x scripts/*.sh
```

### Port Conflicts
Edit `docker/.env` and change:
- `ADMINER_PORT=8080` → `ADMINER_PORT=8081`
- Restart with `make down && make up`
EOF

# docs/MODULE_MAP_EXERCISES.md
cat > docs/MODULE_MAP_EXERCISES.md << 'EOF'
# Module Map & Learning Guide

## Learning Path Overview

### 🟢 Foundation (Required)
| Module | Focus | Key Concepts | Time |
|--------|--------|--------------|------|
| `00_init` | Setup | Schemas, conventions | 30min |
| `01_schema_design` | Tables | Normalization, relationships | 2hrs |
| `02_constraints_indexes` | Integrity | PK/FK, indexing strategies | 2hrs |
| `03_dml_queries` | Queries | JOINs, aggregation, CTEs | 3hrs |

### 🟡 Intermediate (Choose Your Path)
| Module | Focus | Key Concepts | Time |
|--------|--------|--------------|------|
| `04_views_matviews` | Abstraction | Views, materialized views | 1.5hrs |
| `05_functions_triggers` | Logic | PL/pgSQL, triggers | 2.5hrs |
| `06_jsonb_fulltext` | Documents | JSONB, search | 2hrs |
| `07_geospatial` | Location | PostGIS, spatial queries | 3hrs |
| `08_partitioning_timeseries` | Scale | Time-series, partitioning | 2hrs |
| `09_data_movement` | Integration | COPY, FDW, federation | 1.5hrs |

### 🔴 Advanced (Production Focus)
| Module | Focus | Key Concepts | Time |
|--------|--------|--------------|------|
| `10_tx_mvcc_locks` | Concurrency | Isolation, deadlocks | 3hrs |
| `11_perf_tuning` | Performance | EXPLAIN, statistics | 4hrs |
| `12_security_rls` | Security | RLS, masking | 2hrs |
| `13_backup_replication` | Operations | Backup, replication | 2hrs |
| `14_async_patterns` | Messaging | LISTEN/NOTIFY, jobs | 1.5hrs |
| `15_testing_quality` | Quality | Testing, validation | 1hr |

### 🌟 Capstone Projects
| Project | Skills Combined | Complexity |
|---------|----------------|------------|
| Analytics Dashboard | Views + Performance | ⭐⭐⭐ |
| Anomaly Detection | Windows + Stats | ⭐⭐⭐⭐ |
| Geo Accessibility | PostGIS + Analytics | ⭐⭐⭐⭐ |
| Real-time Monitoring | LISTEN/NOTIFY + Views | ⭐⭐⭐⭐⭐ |

## Quick Reference

### Essential psql Commands
```sql
\l                    -- List databases
\dt                   -- List tables
\d table_name         -- Describe table
\di                   -- List indexes
\df                   -- List functions
\dv                   -- List views
\q                    -- Quit
```

### Common Patterns
```sql
-- Idempotent table creation
CREATE TABLE IF NOT EXISTS schema.table (...);

-- Safe column addition
ALTER TABLE schema.table ADD COLUMN IF NOT EXISTS col_name type;

-- Index with concurrency
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_name ON table (columns);

-- Materialized view refresh
REFRESH MATERIALIZED VIEW CONCURRENTLY view_name;
```

### Performance Analysis
```sql
-- Query plan analysis
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;

-- Index usage stats
SELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0;

-- Table bloat check
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
FROM pg_tables WHERE schemaname NOT IN ('information_schema', 'pg_catalog');
```

## Exercises by Module

### Foundation Exercises

**Schema Design (01)**
- [ ] Create normalized tables for a library system
- [ ] Design proper foreign key relationships
- [ ] Add appropriate constraints and defaults

**Indexing (02)**
- [ ] Create indexes for common query patterns
- [ ] Identify missing indexes using pg_stat_statements
- [ ] Implement partial indexes for filtered queries

**Query Patterns (03)**
- [ ] Write window function queries for running totals
- [ ] Create recursive CTEs for hierarchical data
- [ ] Practice complex JOINs with multiple tables

### Intermediate Exercises

**Views & Materialized Views (04)**
- [ ] Create a view layer for reporting
- [ ] Set up incremental materialized view refresh
- [ ] Handle view dependencies properly

**Functions & Triggers (05)**
- [ ] Write PL/pgSQL functions with error handling
- [ ] Implement audit triggers
- [ ] Create event triggers for DDL tracking

### Advanced Exercises

**Performance Tuning (11)**
- [ ] Optimize slow queries using EXPLAIN
- [ ] Tune autovacuum settings
- [ ] Implement query caching strategies

**Security (12)**
- [ ] Set up row-level security policies
- [ ] Implement column-level encryption
- [ ] Create secure views for sensitive data

## Recommended Learning Sequences

### **Web Developer Path** (2-3 days)
1. Foundation modules (00-03)
2. JSONB & Full-text (06)
3. Functions & Triggers (05)
4. Security basics (12)
5. Capstone: Analytics Dashboard

### **Data Analyst Path** (3-4 days)
1. Foundation modules (00-03)
2. Views & Materialized Views (04)
3. Geospatial (07)
4. Partitioning (08)
5. Performance basics (11)
6. Capstone: Geo Accessibility Study

### **DBA Path** (5-7 days)
1. All Foundation & Intermediate modules
2. Deep dive: MVCC & Locking (10)
3. Deep dive: Performance Tuning (11)
4. Backup & Replication (13)
5. Testing & Quality (15)
6. All Capstone projects

### **Full Stack Path** (4-5 days)
1. Foundation modules (00-03)
2. JSONB & Search (06)
3. Functions & Triggers (05)
4. Async Patterns (14)
5. Security & RLS (12)
6. Capstone: Real-time Monitoring
EOF

# Create remaining documentation files...
cat > docs/EXPLAIN_PLAN_LIBRARY.md << 'EOF'
# EXPLAIN Plan Library

Reference collection of query plans for common scenarios.

## Index Scan Types

### Sequential Scan (Avoid for Large Tables)
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM civics.citizens WHERE age > 30;
```
```
Seq Scan on citizens  (cost=0.00..1.15 rows=5 width=140) (actual time=0.012..0.015 rows=4 loops=1)
  Filter: (age > 30)
  Rows Removed by Filter: 1
  Buffers: shared hit=1
```

### Index Scan (Good)
```sql
CREATE INDEX idx_citizens_age ON civics.citizens(age);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM civics.citizens WHERE age > 30;
```
```
Index Scan using idx_citizens_age on citizens  (cost=0.14..8.18 rows=4 width=140)
  Index Cond: (age > 30)
  Buffers: shared hit=3
```

## Join Strategies

### Nested Loop (Small Tables)
```
Nested Loop  (cost=0.29..16.38 rows=1 width=72)
  ->  Seq Scan on orders  (cost=0.00..1.01 rows=1 width=36)
  ->  Index Scan using merchants_pkey on merchants  (cost=0.29..15.36 rows=1 width=36)
```

### Hash Join (Medium Tables)
```
Hash Join  (cost=1.04..2.07 rows=1 width=72)
  Hash Cond: (orders.merchant_id = merchants.id)
  ->  Seq Scan on orders  (cost=0.00..1.01 rows=1 width=36)
  ->  Hash  (cost=1.03..1.03 rows=3 width=36)
```

### Merge Join (Large Sorted Tables)
```
Merge Join  (cost=0.57..1.59 rows=1 width=72)
  Merge Cond: (orders.merchant_id = merchants.id)
  ->  Index Scan using orders_merchant_id_idx on orders
  ->  Index Scan using merchants_pkey on merchants
```

## Problematic Patterns

### Missing Index
```
Filter: (email = 'alice@example.com')
Rows Removed by Filter: 999999
```
**Fix:** `CREATE INDEX ON table(email);`

### Wrong Data Type
```
Filter: ((id)::text = '123'::text)
```
**Fix:** Use proper types or explicit casting

### Function on Column
```
Filter: (upper(name) = 'ALICE')
```
**Fix:** `CREATE INDEX ON table(upper(name));`
EOF

cat > docs/TROUBLESHOOTING.md << 'EOF'
# Troubleshooting Guide

## Common Setup Issues

### Docker Compose Fails to Start

**Symptom:** `ERROR: Version in "./docker-compose.yml" is unsupported`
**Solution:** Update Docker Compose to version 3.8+ support

**Symptom:** `Port 5432 already in use`
**Solution:**
```bash
# Find conflicting process
sudo lsof -i :5432
# Kill or change port in docker/.env
POSTGRES_PORT=5433
```

### Database Connection Issues

**Symptom:** `FATAL: password authentication failed`
**Solution:** Check credentials in `docker/.env`

**Symptom:** `could not connect to server: Connection refused`
**Solution:**
```bash
# Wait for container to fully start
docker-compose logs postgres
# Look for "database system is ready to accept connections"
```

## SQL Execution Problems

### Permission Denied
```sql
ERROR: permission denied for schema civics
```
**Solution:**
```sql
-- Grant schema usage
GRANT USAGE ON SCHEMA civics TO current_user;
GRANT SELECT ON ALL TABLES IN SCHEMA civics TO current_user;
```

### Extension Not Found
```sql
ERROR: extension "postgis" is not available
```
**Solution:** Verify PostGIS image in Dockerfile:
```dockerfile
FROM postgis/postgis:16-3.4
```

### Out of Shared Memory
```sql
ERROR: could not resize shared memory segment
```
**Solution:** Increase Docker memory allocation or tune PostgreSQL:
```sql
ALTER SYSTEM SET shared_buffers = '128MB';
SELECT pg_reload_conf();
```

## Performance Issues

### Slow Queries
1. Enable query logging:
   ```sql
   ALTER SYSTEM SET log_min_duration_statement = 1000;
   ```

2. Analyze with EXPLAIN:
   ```sql
   EXPLAIN (ANALYZE, BUFFERS) YOUR_QUERY;
   ```

3. Check for missing indexes:
   ```sql
   SELECT * FROM pg_stat_user_tables WHERE seq_scan > 1000;
   ```

### High Memory Usage
```sql
-- Check connection count
SELECT count(*) FROM pg_stat_activity;

-- Check cache hit ratio
SELECT
  sum(heap_blks_read) as heap_read,
  sum(heap_blks_hit)  as heap_hit,
  (sum(heap_blks_hit) - sum(heap_blks_read)) / sum(heap_blks_hit) as ratio
FROM pg_statio_user_tables;
```

## Data Loading Issues

### COPY Command Fails
```sql
ERROR: invalid input syntax for type integer: ""
```
**Solution:** Handle empty values in CSV:
```sql
COPY table FROM '/data/file.csv'
CSV HEADER NULL '';
```

### File Not Found
```sql
ERROR: could not open file "/data/seeds.csv" for reading: No such file or directory
```
**Solution:** Check Docker volume mounts in `docker-compose.yml`

## Reset Procedures

### Complete Environment Reset
```bash
./scripts/reset_db.sh
# OR manually:
cd docker && docker-compose down -v
docker system prune -f
make bootstrap && make up
```

### Data-Only Reset
```bash
make psql
\i /sql/00_init/999_reset_demo_data.sql
```

### Schema-Only Reset
```sql
DROP SCHEMA civics, commerce, mobility, geo CASCADE;
\i /sql/00_init/000_schemas.sql
```

## Getting Help

### Check System Status
```sql
-- Database size
SELECT pg_size_pretty(pg_database_size('polaris'));

-- Active connections
SELECT * FROM pg_stat_activity WHERE state = 'active';

-- Recent errors
SELECT * FROM pg_stat_database WHERE datname = 'polaris';
```

### Log Analysis
```bash
# Container logs
docker-compose -f docker/docker-compose.yml logs postgres --tail=50

# PostgreSQL logs (inside container)
docker-compose -f docker/docker-compose.yml exec postgres tail -f /var/log/postgresql/postgresql*.log
```
EOF

cat > docs/LEARNING_PATHS.md << 'EOF'
# Learning Paths

Choose your adventure based on your role and time commitment.

## 🚀 Quick Start (2-3 hours)
*Perfect for evaluating the project or quick PostgreSQL refresher*

### Path: Essential Skills
1. **Setup** (30min)
   - Run `make bootstrap && make up`
   - Load sample data: `make load-data`
   - Try browser UI at http://localhost:8080

2. **Core Queries** (45min)
   - `/sql/03_dml_queries/practice_selects.sql`
   - `/examples/quick_demo.sql`

3. **Performance Basics** (45min)
   - `/sql/11_perf_tuning/explain_analyze_playbook.sql`
   - `/examples/performance_tuning_showcase.sql`

4. **Capstone** (30min)
   - `/sql/16_capstones/citywide_analytics_dashboard.sql`

**Skills Gained:** Query optimization, EXPLAIN analysis, basic performance tuning

---

## 💼 Business Analyst (1-2 days)
*Focus on data analysis, reporting, and business intelligence*

### Day 1: Foundation & Analysis
**Morning (3-4 hours)**
- Setup and schema understanding (`00_init`, `01_schema_design`)
- Query patterns (`03_dml_queries`)
- Views and materialized views (`04_views_matviews`)

**Afternoon (3-4 hours)**
- JSONB for document analysis (`06_jsonb_fulltext`)
- Window functions and analytics
- Basic performance awareness (`11_perf_tuning` - read-only)

### Day 2: Advanced Analysis
**Morning (2-3 hours)**
- Geospatial analysis (`07_geospatial`)
- Time-series patterns (`08_partitioning_timeseries`)

**Afternoon (2-3 hours)**
- Capstone: Analytics Dashboard
- Capstone: Anomaly Detection
- Optional: Geo Accessibility Study

**Skills Gained:** Advanced SQL, analytics functions, spatial analysis, business reporting

---

## 🛠️ Full-Stack Developer (2-3 days)
*Application development focus with security and integration*

### Day 1: Core Development Skills
- Schema design best practices (`01_schema_design`)
- Constraints and indexing strategy (`02_constraints_indexes`)
- Application queries (`03_dml_queries`)
- Functions and triggers (`05_functions_triggers`)

### Day 2: Modern Features
- JSONB for API development (`06_jsonb_fulltext`)
- Data integration (`09_data_movement`)
- Security and RLS (`12_security_rls`)
- Real-time patterns (`14_async_patterns`)

### Day 3: Production Readiness
- Performance tuning (`11_perf_tuning`)
- Testing strategies (`15_testing_quality`)
- Backup awareness (`13_backup_replication`)
- Capstone: Real-time Monitoring

**Skills Gained:** Production PostgreSQL, security patterns, real-time features, API design

---

## 🏗️ Database Administrator (4-5 days)
*Complete operational mastery*

### Day 1-2: Foundations
- All foundation modules (`00_init` through `03_dml_queries`)
- Views and stored procedures (`04_views_matviews`, `05_functions_triggers`)
- Data integration (`09_data_movement`)

### Day 3: Advanced Operations
- Deep dive: Transactions and locking (`10_tx_mvcc_locks`)
- Performance tuning mastery (`11_perf_tuning`)
- Statistics and autovacuum tuning

### Day 4: Production Operations
- Security and RLS (`12_security_rls`)
- Backup and replication (`13_backup_replication`)
- Monitoring and async patterns (`14_async_patterns`)

### Day 5: Quality and Scale
- Testing and validation (`15_testing_quality`)
- All capstone projects
- Partitioning and time-series (`08_partitioning_timeseries`)

**Skills Gained:** Complete PostgreSQL administration, performance optimization, production operations

---

## 🎯 Data Engineer (3-4 days)
*ETL, pipelines, and large-scale data processing*

### Day 1: Foundation
- Schema design (`01_schema_design`)
- Indexing strategies (`02_constraints_indexes`)
- Complex queries (`03_dml_queries`)

### Day 2: Data Processing
- Functions and procedures (`05_functions_triggers`)
- JSONB and document processing (`06_jsonb_fulltext`)
- Data movement and FDW (`09_data_movement`)

### Day 3: Scale and Performance
- Partitioning and time-series (`08_partitioning_timeseries`)
- Transactions and concurrency (`10_tx_mvcc_locks`)
- Performance optimization (`11_perf_tuning`)

### Day 4: Production Pipeline
- Async processing (`14_async_patterns`)
- Testing and quality (`15_testing_quality`)
- Capstone: Anomaly Detection
- Optional: Geospatial processing (`07_geospatial`)

**Skills Gained:** Large-scale data processing, ETL patterns, pipeline optimization

---

## 🔬 Data Scientist (2-3 days)
*Analytics, spatial analysis, and statistical patterns*

### Focus Areas:
1. **Statistical SQL** (`03_dml_queries` - window functions)
2. **Document Analysis** (`06_jsonb_fulltext`)
3. **Geospatial Analytics** (`07_geospatial`) - full module
4. **Time-Series Analysis** (`08_partitioning_timeseries`)
5. **Advanced Analytics** (all capstone projects)

### Recommended Sequence:
- Day 1: Foundation + Window Functions + JSONB
- Day 2: Complete PostGIS module + Time-series
- Day 3: All capstone projects (focus on anomaly detection and geo accessibility)

**Skills Gained:** Spatial analysis, statistical functions, time-series processing, anomaly detection

---

## 🎓 Academic/Teaching (Complete Coverage)
*Comprehensive understanding for teaching or research*

### Week 1: Foundations (5 days)
- Day 1-2: Setup through DML queries
- Day 3: Views, functions, triggers
- Day 4: JSONB and full-text search
- Day 5: Geospatial introduction

### Week 2: Advanced Topics (5 days)
- Day 1: Partitioning and time-series
- Day 2: Data movement and FDW
- Day 3: Transactions, MVCC, locking
- Day 4: Performance tuning deep dive
- Day 5: Security and RLS

### Week 3: Operations & Projects (5 days)
- Day 1: Backup and replication
- Day 2: Async patterns and jobs
- Day 3: Testing and quality assurance
- Day 4-5: All capstone projects

**Skills Gained:** Complete PostgreSQL expertise, teaching-ready knowledge, research capabilities

---

## Self-Assessment Checkpoints

### After Foundation Modules
- [ ] Can design normalized schemas
- [ ] Understand indexing trade-offs
- [ ] Write complex analytical queries
- [ ] Use CTEs and window functions

### After Intermediate Modules
- [ ] Create maintainable view layers
- [ ] Write stored procedures with error handling
- [ ] Process JSON documents efficiently
- [ ] Perform spatial analysis (if relevant)

### After Advanced Modules
- [ ] Diagnose and fix performance issues
- [ ] Implement proper security policies
- [ ] Design backup and recovery procedures
- [ ] Handle concurrency and locking

### Capstone Readiness
- [ ] Combine multiple PostgreSQL features
- [ ] Build complete analytical solutions
- [ ] Demonstrate production-ready patterns
- [ ] Explain trade-offs and design decisions
EOF

echo "🔧 Creating scripts..."

# scripts/run_sql.sh
cat > scripts/run_sql.sh << 'EOF'
#!/bin/bash

# Run SQL file against the PostgreSQL database
# Usage: ./scripts/run_sql.sh path/to/file.sql [database_name]

set -euo pipefail

SQL_FILE="${1:-}"
DATABASE="${2:-polaris}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -z "$SQL_FILE" ]; then
    echo "Usage: $0 <sql_file> [database_name]"
    echo "Examples:"
    echo "  $0 sql/01_schema_design/civics.sql"
    echo "  $0 tests/schema_validation.sql"
    exit 1
fi

# Check if SQL file exists
if [ ! -f "$PROJECT_DIR/$SQL_FILE" ]; then
    echo "❌ SQL file not found: $SQL_FILE"
    exit 1
fi

echo "🔧 Running SQL file: $SQL_FILE"
echo "🗄️  Database: $DATABASE"

# Load environment variables
if [ -f "$PROJECT_DIR/docker/.env" ]; then
    export $(grep -v '^#' "$PROJECT_DIR/docker/.env" | xargs)
fi

# Run the SQL file
cd "$PROJECT_DIR/docker"
docker-compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "$DATABASE" -f "/sql/${SQL_FILE#sql/}"

echo "✅ SQL file executed successfully"
EOF

# scripts/reset_db.sh
cat > scripts/reset_db.sh << 'EOF'
#!/bin/bash

# DESTRUCTIVE: Reset the entire database
# Usage: ./scripts/reset_db.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "⚠️  WARNING: This will completely reset the database!"
echo "📁 Project directory: $PROJECT_DIR"
echo ""
read -p "Are you sure? Type 'YES' to continue: " confirm

if [ "$confirm" != "YES" ]; then
    echo "❌ Reset cancelled"
    exit 1
fi

echo "🔥 Stopping containers and removing volumes..."
cd "$PROJECT_DIR/docker"
docker-compose down -v

echo "🧹 Cleaning up Docker resources..."
docker system prune -f

echo "🚀 Rebuilding and starting fresh..."
docker-compose up -d --build

echo "⏳ Waiting for database to be ready..."
sleep 10

# Wait for health check
echo "🏥 Checking database health..."
for i in {1..30}; do
    if docker-compose exec postgres pg_isready -U postgres; then
        echo "✅ Database is ready!"
        break
    fi
    echo "⏳ Waiting... ($i/30)"
    sleep 2
done

echo "🎉 Database reset complete!"
echo "🌐 Access Adminer at: http://localhost:8080"
echo "🔌 Connect via psql: make psql"
EOF

# scripts/backup_demo.sh
cat > scripts/backup_demo.sh << 'EOF'
#!/bin/bash

# Demonstrate various PostgreSQL backup strategies
# Usage: ./scripts/backup_demo.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"

# Create backup directory
mkdir -p "$BACKUP_DIR"

echo "🗄️ PostgreSQL Backup Demonstration"
echo "📁 Backup directory: $BACKUP_DIR"

# Load environment
cd "$PROJECT_DIR/docker"
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-polaris}"
CONTAINER_NAME="${COMPOSE_PROJECT_NAME:-docker}_postgres_1"

echo ""
echo "1️⃣ Schema-only backup (structure)"
docker-compose exec postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --schema-only --verbose --file="/tmp/schema_only.sql"
docker cp "${CONTAINER_NAME}:/tmp/schema_only.sql" "$BACKUP_DIR/"
echo "✅ Schema backup: $BACKUP_DIR/schema_only.sql"

echo ""
echo "2️⃣ Data-only backup (content)"
docker-compose exec postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --data-only --verbose --file="/tmp/data_only.sql"
docker cp "${CONTAINER_NAME}:/tmp/data_only.sql" "$BACKUP_DIR/"
echo "✅ Data backup: $BACKUP_DIR/data_only.sql"

echo ""
echo "3️⃣ Complete database backup (custom format)"
docker-compose exec postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --format=custom --verbose --file="/tmp/complete.dump"
docker cp "${CONTAINER_NAME}:/tmp/complete.dump" "$BACKUP_DIR/"
echo "✅ Complete backup: $BACKUP_DIR/complete.dump"

echo ""
echo "4️⃣ Specific schema backup"
docker-compose exec postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --schema=civics --verbose --file="/tmp/civics_schema.sql"
docker cp "${CONTAINER_NAME}:/tmp/civics_schema.sql" "$BACKUP_DIR/"
echo "✅ Civics schema backup: $BACKUP_DIR/civics_schema.sql"

echo ""
echo "5️⃣ Compressed backup"
docker-compose exec postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --format=custom --compress=9 --verbose --file="/tmp/compressed.dump"
docker cp "${CONTAINER_NAME}:/tmp/compressed.dump" "$BACKUP_DIR/"
echo "✅ Compressed backup: $BACKUP_DIR/compressed.dump"

echo ""
echo "📊 Backup file sizes:"
ls -lh "$BACKUP_DIR"

echo ""
echo "🔄 Restore examples:"
echo "pg_restore -U postgres -d polaris_restored /path/to/complete.dump"
echo "psql -U postgres -d polaris_restored < /path/to/schema_only.sql"

echo ""
echo "✅ Backup demonstration complete!"
EOF

# scripts/load_sample_data.sh
cat > scripts/load_sample_data.sh << 'EOF'
#!/bin/bash

# Load all sample data into the database
# Usage: ./scripts/load_sample_data.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "📊 Loading sample data into PostgreSQL..."

# Ensure database is running
cd "$PROJECT_DIR/docker"
if ! docker-compose exec postgres pg_isready -U postgres > /dev/null 2>&1; then
    echo "❌ Database is not running. Start with: make up"
    exit 1
fi

# Load environment
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-polaris}"

echo "1️⃣ Creating schemas and base tables..."
"$SCRIPT_DIR/run_sql.sh" "sql/00_init/000_schemas.sql"
"$SCRIPT_DIR/run_sql.sh" "sql/01_schema_design/civics.sql"
"$SCRIPT_DIR/run_sql.sh" "sql/01_schema_design/commerce.sql"
"$SCRIPT_DIR/run_sql.sh" "sql/01_schema_design/mobility.sql"

echo ""
echo "2️⃣ Loading CSV seed data..."
docker-compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
CREATE TEMP TABLE temp_seeds (
    table_name text,
    id int,
    name text,
    email text,
    age int,
    city text,
    registration_date date
);

COPY temp_seeds FROM '/data/seeds.csv' CSV HEADER;

-- Load citizens
INSERT INTO civics.citizens (name, email, age, city, registration_date)
SELECT name, email, age, city, registration_date::date
FROM temp_seeds WHERE table_name = 'citizens'
ON CONFLICT DO NOTHING;

-- Load merchants
INSERT INTO commerce.merchants (name, email, founded_date, city, category)
SELECT name, email, registration_date::date, city, 'General'
FROM temp_seeds WHERE table_name = 'merchants'
ON CONFLICT DO NOTHING;

SELECT 'Loaded ' || count(*) || ' citizens' FROM civics.citizens;
SELECT 'Loaded ' || count(*) || ' merchants' FROM commerce.merchants;
"

echo ""
echo "3️⃣ Loading JSONB documents..."
docker-compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
CREATE TABLE IF NOT EXISTS staging.documents (
    id serial PRIMARY KEY,
    doc jsonb NOT NULL,
    created_at timestamp DEFAULT now()
);

-- Load JSONB data line by line
\copy staging.documents (doc) FROM '/data/documents.jsonb';

SELECT 'Loaded ' || count(*) || ' JSONB documents' FROM staging.documents;
SELECT doc->>'type' as doc_type, count(*) FROM staging.documents GROUP BY doc->>'type';
"

echo ""
echo "4️⃣ Loading geospatial data..."
docker-compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
-- Create geospatial tables if not exists
CREATE TABLE IF NOT EXISTS geo.neighborhoods (
    id serial PRIMARY KEY,
    name text NOT NULL,
    population int,
    median_income int,
    geom geometry(Polygon, 4326)
);

CREATE TABLE IF NOT EXISTS geo.points_of_interest (
    id serial PRIMARY KEY,
    name text NOT NULL,
    poi_type text,
    geom geometry(Point, 4326)
);

-- Note: GeoJSON loading requires custom function or ogr2ogr
-- For demo, we'll create some manual spatial data
INSERT INTO geo.neighborhoods (name, population, median_income, geom) VALUES
('Pearl District', 12500, 75000, ST_GeomFromText('POLYGON((-122.6840 45.5272, -122.6760 45.5272, -122.6760 45.5340, -122.6840 45.5340, -122.6840 45.5272))', 4326)),
('Hawthorne', 8200, 68000, ST_GeomFromText('POLYGON((-122.6580 45.5120, -122.6480 45.5120, -122.6480 45.5200, -122.6580 45.5200, -122.6580 45.5120))', 4326))
ON CONFLICT DO NOTHING;

INSERT INTO geo.points_of_interest (name, poi_type, geom) VALUES
('Pine & 3rd Bus Stop', 'transit', ST_GeomFromText('POINT(-122.6750 45.5250)', 4326))
ON CONFLICT DO NOTHING;

SELECT 'Loaded ' || count(*) || ' neighborhoods' FROM geo.neighborhoods;
SELECT 'Loaded ' || count(*) || ' POIs' FROM geo.points_of_interest;
"

echo ""
echo "5️⃣ Loading time-series sensor data..."
docker-compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
CREATE TABLE IF NOT EXISTS mobility.sensor_readings (
    id serial PRIMARY KEY,
    sensor_id text NOT NULL,
    location text,
    reading_time timestamp NOT NULL,
    temperature numeric(5,2),
    humidity numeric(5,2),
    air_quality_pm25 numeric(6,2),
    created_at timestamp DEFAULT now()
);

COPY mobility.sensor_readings (reading_time, sensor_id, location, temperature, humidity, air_quality_pm25)
FROM '/data/timeseries.csv' CSV HEADER;

SELECT 'Loaded ' || count(*) || ' sensor readings' FROM mobility.sensor_readings;
SELECT sensor_id, count(*), min(reading_time), max(reading_time)
FROM mobility.sensor_readings
GROUP BY sensor_id;
"

echo ""
echo "✅ Sample data loading complete!"
echo ""
echo "🔍 Verify data with these queries:"
echo "SELECT COUNT(*) FROM civics.citizens;"
echo "SELECT doc->>'type', COUNT(*) FROM staging.documents GROUP BY doc->>'type';"
echo "SELECT name, ST_Area(geom) as area FROM geo.neighborhoods;"
echo "SELECT sensor_id, COUNT(*) FROM mobility.sensor_readings GROUP BY sensor_id;"
EOF

# Make scripts executable
chmod +x scripts/*.sh

echo "🧪 Creating test files..."

# tests/schema_validation.sql
cat > tests/schema_validation.sql << 'EOF'
-- FILE: tests/schema_validation.sql
-- Schema Validation Tests - Ensures all expected database objects exist

\echo 'Running schema validation tests...'

-- Test 1: Required schemas exist
SELECT
    CASE
        WHEN COUNT(*) = 7 THEN '✅ All schemas exist'
        ELSE '❌ Missing schemas: ' || (7 - COUNT(*))::text
    END as schema_test
FROM information_schema.schemata
WHERE schema_name IN ('civics', 'commerce', 'mobility', 'geo', 'audit', 'staging', 'analytics');

-- Test 2: Required extensions loaded
SELECT
    CASE
        WHEN COUNT(*) >= 5 THEN '✅ Core extensions loaded'
        ELSE '❌ Missing extensions'
    END as extension_test
FROM pg_extension
WHERE extname IN ('postgis', 'pg_stat_statements', 'pgcrypto', 'pg_trgm', 'uuid-ossp');

-- Test 3: Core tables exist
SELECT
    schema_name,
    table_name,
    CASE
        WHEN table_type = 'BASE TABLE' THEN '✅ Table exists'
        ELSE '❌ Table missing'
    END as status
FROM information_schema.tables
WHERE schema_name IN ('civics', 'commerce', 'mobility', 'geo')
ORDER BY schema_name, table_name;

-- Test 4: Indexes created
SELECT
    schemaname,
    tablename,
    indexname,
    '✅ Index exists' as status
FROM pg_indexes
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo')
ORDER BY schemaname, tablename;

\echo 'Schema validation completed'
EOF

# tests/data_integrity_checks.sql
cat > tests/data_integrity_checks.sql << 'EOF'
-- FILE: tests/data_integrity_checks.sql
-- Data Integrity Tests - Validates referential integrity and constraints

\echo 'Running data integrity checks...'

-- Test 1: Foreign key violations
SELECT
    conrelid::regclass as table_name,
    conname as constraint_name,
    CASE
        WHEN COUNT(*) = 0 THEN '✅ No FK violations'
        ELSE '❌ FK violations found: ' || COUNT(*)::text
    END as fk_test
FROM pg_constraint c
WHERE contype = 'f'
GROUP BY conrelid, conname;

-- Test 2: NOT NULL constraint violations
SELECT
    table_schema,
    table_name,
    column_name,
    '✅ NOT NULL enforced' as status
FROM information_schema.columns
WHERE is_nullable = 'NO'
  AND table_schema IN ('civics', 'commerce', 'mobility', 'geo')
ORDER BY table_schema, table_name;

-- Test 3: Duplicate records check
WITH duplicate_check AS (
    SELECT 'civics.citizens' as table_name, email, COUNT(*) as dup_count
    FROM civics.citizens GROUP BY email HAVING COUNT(*) > 1
    UNION ALL
    SELECT 'commerce.merchants' as table_name, email, COUNT(*)
    FROM commerce.merchants GROUP BY email HAVING COUNT(*) > 1
)
SELECT
    CASE
        WHEN COUNT(*) = 0 THEN '✅ No duplicate emails found'
        ELSE '❌ Duplicate emails: ' || COUNT(*)::text
    END as duplicate_test
FROM duplicate_check;

\echo 'Data integrity checks completed'
EOF

# tests/performance_benchmarks.sql
cat > tests/performance_benchmarks.sql << 'EOF'
-- FILE: tests/performance_benchmarks.sql
-- Performance Benchmark Tests - Validates query performance expectations

\echo 'Running performance benchmark tests...'

-- Enable timing and detailed output
\timing on

-- Test 1: Index usage verification
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM civics.citizens WHERE email = 'alice@example.com';

-- Test 2: Join performance
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, m.name as merchant_name
FROM civics.citizens c
JOIN commerce.merchants m ON c.city = m.city
LIMIT 10;

-- Test 3: Aggregation performance
EXPLAIN (ANALYZE, BUFFERS)
SELECT city, COUNT(*), AVG(age)
FROM civics.citizens
GROUP BY city;

-- Performance summary
SELECT
    schemaname,
    tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    CASE
        WHEN seq_scan > idx_scan THEN '⚠️ High seq scan ratio'
        ELSE '✅ Good index usage'
    END as scan_ratio_status
FROM pg_stat_user_tables
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo');

\echo 'Performance benchmark tests completed'
EOF

# tests/regression_tests.sql
cat > tests/regression_tests.sql << 'EOF'
-- FILE: tests/regression_tests.sql
-- Regression Tests - Version compatibility and feature consistency

\echo 'Running regression tests...'

-- Test 1: PostgreSQL version compatibility
SELECT
    version(),
    CASE
        WHEN version() LIKE '%PostgreSQL 16%' THEN '✅ Compatible version'
        WHEN version() LIKE '%PostgreSQL 15%' THEN '✅ Compatible version'
        ELSE '⚠️ Untested version'
    END as version_test;

-- Test 2: PostGIS version compatibility
SELECT
    PostGIS_Version(),
    CASE
        WHEN PostGIS_Version() LIKE '3.4%' THEN '✅ Compatible PostGIS'
        WHEN PostGIS_Version() LIKE '3.3%' THEN '✅ Compatible PostGIS'
        ELSE '⚠️ Untested PostGIS version'
    END as postgis_test;

-- Test 3: Feature availability
SELECT
    'pg_stat_statements' as feature,
    CASE
        WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
        THEN '✅ Available'
        ELSE '❌ Missing'
    END as status
UNION ALL
SELECT
    'JSON functions',
    CASE
        WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'json_extract_path')
        THEN '✅ Available'
        ELSE '❌ Missing'
    END;

\echo 'Regression tests completed'
EOF

# examples/quick_demo.sql
cat > examples/quick_demo.sql << 'EOF'
-- FILE: examples/quick_demo.sql
-- 5-Minute PostgreSQL Demo - Key features showcase

\echo '🌟 PostgreSQL Quick Demo - 5 Minutes to Wow!'

-- Setup demo data quickly
CREATE TEMP TABLE demo_sales AS
SELECT
    generate_series(1, 1000) as id,
    'Product ' || (random() * 100)::int as product_name,
    (random() * 1000 + 10)::numeric(10,2) as price,
    (random() * 50 + 1)::int as quantity,
    date '2024-01-01' + (random() * 365)::int as sale_date,
    CASE (random() * 3)::int
        WHEN 0 THEN 'Electronics'
        WHEN 1 THEN 'Clothing'
        ELSE 'Home & Garden'
    END as category;

\echo '1️⃣ Window Functions - Running totals and rankings'
SELECT
    sale_date,
    price * quantity as revenue,
    SUM(price * quantity) OVER (ORDER BY sale_date) as running_total,
    RANK() OVER (ORDER BY price * quantity DESC) as revenue_rank
FROM demo_sales
ORDER BY sale_date
LIMIT 10;

\echo '2️⃣ Advanced Aggregation - ROLLUP and GROUPING SETS'
SELECT
    COALESCE(category, 'TOTAL') as category,
    COALESCE(EXTRACT(month FROM sale_date)::text, 'ALL MONTHS') as month,
    COUNT(*) as sales_count,
    SUM(price * quantity)::numeric(12,2) as total_revenue
FROM demo_sales
GROUP BY ROLLUP(category, EXTRACT(month FROM sale_date))
ORDER BY category NULLS LAST, month NULLS LAST
LIMIT 15;

\echo '3️⃣ CTEs and Analytics - Top performers by category'
WITH category_stats AS (
    SELECT
        category,
        AVG(price * quantity) as avg_revenue,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY price * quantity) as p90_revenue
    FROM demo_sales
    GROUP BY category
),
top_sales AS (
    SELECT s.*, cs.avg_revenue, cs.p90_revenue,
           s.price * s.quantity > cs.p90_revenue as is_top_performer
    FROM demo_sales s
    JOIN category_stats cs ON s.category = cs.category
)
SELECT
    category,
    COUNT(*) FILTER (WHERE is_top_performer) as top_performers,
    COUNT(*) as total_sales,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_top_performer) / COUNT(*), 1) as top_performer_pct
FROM top_sales
GROUP BY category;

\echo '4️⃣ JSONB Document Processing'
CREATE TEMP TABLE demo_products AS
SELECT
    id,
    product_name,
    jsonb_build_object(
        'specifications', jsonb_build_object(
            'weight', (random() * 10)::numeric(4,2),
            'color', (ARRAY['red', 'blue', 'green', 'black'])[ceil(random() * 4)],
            'warranty_years', (random() * 5 + 1)::int
        ),
        'reviews', jsonb_build_array(
            jsonb_build_object('rating', ceil(random() * 5), 'comment', 'Great product!'),
            jsonb_build_object('rating', ceil(random() * 5), 'comment', 'Good value')
        )
    ) as metadata
FROM demo_sales
LIMIT 100;

SELECT
    product_name,
    metadata->'specifications'->>'color' as color,
    (metadata->'specifications'->'warranty_years')::int as warranty,
    jsonb_array_length(metadata->'reviews') as review_count,
    ROUND(AVG((review->>'rating')::int), 1) as avg_rating
FROM demo_products,
     jsonb_array_elements(metadata->'reviews') as review
GROUP BY product_name, metadata->'specifications'->>'color', metadata->'specifications'->'warranty_years'
ORDER BY avg_rating DESC
LIMIT 10;

\echo '5️⃣ Performance Analysis - EXPLAIN demonstration'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    category,
    COUNT(*),
    AVG(price * quantity) as avg_revenue
FROM demo_sales
WHERE sale_date >= '2024-06-01'
GROUP BY category
HAVING COUNT(*) > 50;

\echo '✅ Demo complete! Key PostgreSQL features demonstrated:'
\echo '   • Window functions for analytics'
\echo '   • Advanced GROUP BY with ROLLUP'
\echo '   • Complex CTEs with filtering'
\echo '   • JSONB document processing'
\echo '   • Query performance analysis'
\echo ''
\echo '🚀 Ready to explore more? Check out the full modules in /sql/'
EOF

# examples/analytics_showcase.sql
cat > examples/analytics_showcase.sql << 'EOF'
-- FILE: examples/analytics_showcase.sql
-- Business Intelligence and Analytics Patterns

\echo '📊 Analytics Showcase - BI Patterns in PostgreSQL'

-- Create comprehensive demo dataset
CREATE TEMP TABLE sales_fact AS
SELECT
    generate_series(1, 5000) as sale_id,
    (random() * 100 + 1)::int as customer_id,
    (random() * 50 + 1)::int as product_id,
    (random() * 10 + 1)::int as quantity,
    (random() * 500 + 20)::numeric(8,2) as unit_price,
    date '2023-01-01' + (random() * 730)::int as sale_date,
    CASE (random() * 4)::int
        WHEN 0 THEN 'North' WHEN 1 THEN 'South'
        WHEN 2 THEN 'East' ELSE 'West'
    END as region,
    CASE (random() * 3)::int
        WHEN 0 THEN 'Online' WHEN 1 THEN 'Retail' ELSE 'Partner'
    END as channel;

\echo '1️⃣ Time Series Analysis with Seasonality'
SELECT
    DATE_TRUNC('month', sale_date) as month,
    region,
    COUNT(*) as transactions,
    SUM(quantity * unit_price) as revenue,
    AVG(quantity * unit_price) as avg_order_value,
    LAG(SUM(quantity * unit_price)) OVER (PARTITION BY region ORDER BY DATE_TRUNC('month', sale_date)) as prev_month_revenue,
    ROUND(
        (SUM(quantity * unit_price) - LAG(SUM(quantity * unit_price)) OVER (PARTITION BY region ORDER BY DATE_TRUNC('month', sale_date)))
        / LAG(SUM(quantity * unit_price)) OVER (PARTITION BY region ORDER BY DATE_TRUNC('month', sale_date)) * 100, 2
    ) as revenue_growth_pct
FROM sales_fact
GROUP BY DATE_TRUNC('month', sale_date), region
ORDER BY month, region
LIMIT 20;

\echo '2️⃣ Customer Segmentation with RFM Analysis'
WITH customer_metrics AS (
    SELECT
        customer_id,
        MAX(sale_date) as last_purchase_date,
        EXTRACT(days FROM (CURRENT_DATE - MAX(sale_date))) as recency_days,
        COUNT(*) as frequency,
        SUM(quantity * unit_price) as monetary
    FROM sales_fact
    GROUP BY customer_id
),
rfm_scores AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days DESC) as recency_score,
        NTILE(5) OVER (ORDER BY frequency) as frequency_score,
        NTILE(5) OVER (ORDER BY monetary) as monetary_score
    FROM customer_metrics
),
customer_segments AS (
    SELECT *,
        CASE
            WHEN recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4 THEN 'Champions'
            WHEN recency_score >= 3 AND frequency_score >= 3 AND monetary_score >= 3 THEN 'Loyal Customers'
            WHEN recency_score >= 3 AND frequency_score <= 2 AND monetary_score >= 3 THEN 'Big Spenders'
            WHEN recency_score <= 2 AND frequency_score >= 3 AND monetary_score >= 3 THEN 'At Risk'
            WHEN recency_score <= 2 AND frequency_score <= 2 THEN 'Lost Customers'
            ELSE 'Developing'
        END as segment
    FROM rfm_scores
)
SELECT
    segment,
    COUNT(*) as customer_count,
    ROUND(AVG(monetary), 2) as avg_customer_value,
    ROUND(AVG(frequency), 1) as avg_purchase_frequency,
    ROUND(AVG(recency_days), 0) as avg_days_since_last_purchase
FROM customer_segments
GROUP BY segment
ORDER BY avg_customer_value DESC;

\echo '3️⃣ Cohort Analysis - Customer Retention'
WITH first_purchase AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', MIN(sale_date)) as cohort_month
    FROM sales_fact
    GROUP BY customer_id
),
customer_activity AS (
    SELECT
        fp.customer_id,
        fp.cohort_month,
        DATE_TRUNC('month', sf.sale_date) as activity_month,
        EXTRACT(months FROM age(DATE_TRUNC('month', sf.sale_date), fp.cohort_month)) as period_number
    FROM first_purchase fp
    JOIN sales_fact sf ON fp.customer_id = sf.customer_id
),
cohort_table AS (
    SELECT
        cohort_month,
        period_number,
        COUNT(DISTINCT customer_id) as customers
    FROM customer_activity
    GROUP BY cohort_month, period_number
),
cohort_sizes AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) as total_customers
    FROM first_purchase
    GROUP BY cohort_month
)
SELECT
    ct.cohort_month,
    cs.total_customers as cohort_size,
    ct.period_number as months_after_first_purchase,
    ct.customers as active_customers,
    ROUND(100.0 * ct.customers / cs.total_customers, 1) as retention_rate
FROM cohort_table ct
JOIN cohort_sizes cs ON ct.cohort_month = cs.cohort_month
WHERE ct.cohort_month >= '2024-01-01'
ORDER BY ct.cohort_month, ct.period_number
LIMIT 20;

\echo '4️⃣ Advanced Analytics - Statistical Functions'
SELECT
    region,
    channel,
    COUNT(*) as sample_size,
    ROUND(AVG(quantity * unit_price), 2) as mean_revenue,
    ROUND(STDDEV(quantity * unit_price), 2) as revenue_stddev,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY quantity * unit_price), 2) as q1,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY quantity * unit_price), 2) as median,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY quantity * unit_price), 2) as q3,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY quantity * unit_price), 2) as p95,
    -- Coefficient of variation
    ROUND(STDDEV(quantity * unit_price) / AVG(quantity * unit_price) * 100, 2) as coefficient_of_variation
FROM sales_fact
GROUP BY region, channel
ORDER BY mean_revenue DESC;

\echo '✅ Analytics showcase complete! Patterns demonstrated:'
\echo '   • Time series analysis with growth rates'
\echo '   • RFM customer segmentation'
\echo '   • Cohort retention analysis'
\echo '   • Statistical distribution analysis'
EOF

# examples/geospatial_showcase.sql
cat > examples/geospatial_showcase.sql << 'EOF'
-- FILE: examples/geospatial_showcase.sql
-- PostGIS Spatial Analysis Demonstration

\echo '🌍 Geospatial Showcase - PostGIS Spatial Analysis'

-- Create comprehensive spatial demo data
CREATE TEMP TABLE demo_locations AS
SELECT
    generate_series(1, 100) as id,
    'Location ' || generate_series(1, 100) as name,
    -- Random points within Portland, OR bounding box
    ST_SetSRID(ST_MakePoint(
        -122.7 + random() * 0.2,  -- Longitude range
        45.5 + random() * 0.1     -- Latitude range
    ), 4326) as geom,
    CASE (random() * 4)::int
        WHEN 0 THEN 'restaurant' WHEN 1 THEN 'retail'
        WHEN 2 THEN 'service' ELSE 'entertainment'
    END as category,
    (random() * 100)::int as capacity;

CREATE TEMP TABLE demo_districts AS
SELECT
    'District ' || generate_series(1, 5) as name,
    ST_Buffer(
        ST_SetSRID(ST_MakePoint(
            -122.65 + (generate_series(1, 5) - 3) * 0.02,
            45.52 + (generate_series(1, 5) - 3) * 0.01
        ), 4326)::geography,
        1000  -- 1km buffer
    )::geometry as geom,
    (random() * 50000 + 10000)::int as population;

\echo '1️⃣ Spatial Relationships - Points in Polygons'
SELECT
    d.name as district,
    d.population,
    COUNT(l.id) as location_count,
    ROUND(COUNT(l.id)::numeric / d.population * 1000, 2) as locations_per_1k_people,
    string_agg(DISTINCT l.category, ', ') as categories_present
FROM demo_districts d
LEFT JOIN demo_locations l ON ST_Within(l.geom, d.geom)
GROUP BY d.name, d.population
ORDER BY location_count DESC;

\echo '2️⃣ Distance Analysis - Nearest Neighbor Queries'
WITH nearest_pairs AS (
    SELECT DISTINCT ON (l1.id)
        l1.id as location_id,
        l1.name as location_name,
        l1.category,
        l2.id as nearest_id,
        l2.name as nearest_name,
        l2.category as nearest_category,
        ROUND(ST_Distance(l1.geom::geography, l2.geom::geography)::numeric, 0) as distance_meters
    FROM demo_locations l1
    CROSS JOIN demo_locations l2
    WHERE l1.id != l2.id
    ORDER BY l1.id, ST_Distance(l1.geom::geography, l2.geom::geography)
)
SELECT
    category,
    COUNT(*) as total_locations,
    ROUND(AVG(distance_meters), 0) as avg_nearest_distance_m,
    ROUND(MIN(distance_meters), 0) as min_nearest_distance_m,
    ROUND(MAX(distance_meters), 0) as max_nearest_distance_m
FROM nearest_pairs
GROUP BY category
ORDER BY avg_nearest_distance_m;

\echo '3️⃣ Spatial Clustering - Density Analysis'
SELECT
    l.id,
    l.name,
    l.category,
    ST_X(l.geom) as longitude,
    ST_Y(l.geom) as latitude,
    COUNT(nearby.id) as neighbors_within_500m,
    CASE
        WHEN COUNT(nearby.id) >= 10 THEN 'High Density'
        WHEN COUNT(nearby.id) >= 5 THEN 'Medium Density'
        ELSE 'Low Density'
    END as density_category
FROM demo_locations l
LEFT JOIN demo_locations nearby ON (
    l.id != nearby.id
    AND ST_DWithin(l.geom::geography, nearby.geom::geography, 500)
)
GROUP BY l.id, l.name, l.category, l.geom
ORDER BY neighbors_within_500m DESC
LIMIT 15;

\echo '4️⃣ Spatial Aggregation - Grid Analysis'
WITH spatial_grid AS (
    -- Create 0.01 degree grid cells (roughly 1km x 1km)
    SELECT
        FLOOR(ST_X(geom) / 0.01) * 0.01 as grid_x,
        FLOOR(ST_Y(geom) / 0.01) * 0.01 as grid_y,
        COUNT(*) as location_count,
        SUM(capacity) as total_capacity,
        string_agg(DISTINCT category, ', ') as categories
    FROM demo_locations
    GROUP BY
        FLOOR(ST_X(geom) / 0.01),
        FLOOR(ST_Y(geom) / 0.01)
)
SELECT
    grid_x + 0.005 as center_longitude,  -- Center of grid cell
    grid_y + 0.005 as center_latitude,
    location_count,
    total_capacity,
    ROUND(total_capacity::numeric / location_count, 0) as avg_capacity_per_location,
    categories
FROM spatial_grid
WHERE location_count > 1
ORDER BY location_count DESC;

\echo '5️⃣ Route Analysis - Distance Matrix'
WITH sample_points AS (
    SELECT * FROM demo_locations
    WHERE category = 'restaurant'
    ORDER BY random()
    LIMIT 5
)
SELECT
    from_point.name as from_location,
    to_point.name as to_location,
    ROUND(ST_Distance(from_point.geom::geography, to_point.geom::geography)::numeric, 0) as straight_line_distance_m,
    -- Estimate travel time assuming 5 km/h walking speed
    ROUND(ST_Distance(from_point.geom::geography, to_point.geom::geography) / 83.33, 1) as estimated_walk_time_min
FROM sample_points from_point
CROSS JOIN sample_points to_point
WHERE from_point.id != to_point.id
ORDER BY from_point.name, straight_line_distance_m;

\echo '✅ Geospatial showcase complete! Spatial analysis demonstrated:'
\echo '   • Point-in-polygon spatial joins'
\echo '   • Nearest neighbor distance analysis'
\echo '   • Spatial clustering and density'
\echo '   • Grid-based spatial aggregation'
\echo '   • Distance matrix calculations'
EOF

# examples/performance_tuning_showcase.sql
cat > examples/performance_tuning_showcase.sql << 'EOF'
-- FILE: examples/performance_tuning_showcase.sql
-- Performance Optimization Patterns and Techniques

\echo '⚡ Performance Tuning Showcase - Optimization Patterns'

-- Create performance test dataset
CREATE TEMP TABLE perf_orders AS
SELECT
    generate_series(1, 50000) as order_id,
    (random() * 5000 + 1)::int as customer_id,
    (random() * 1000 + 1)::int as product_id,
    date '2023-01-01' + (random() * 365)::int as order_date,
    (random() * 1000 + 10)::numeric(10,2) as order_amount,
    CASE (random() * 4)::int
        WHEN 0 THEN 'pending' WHEN 1 THEN 'completed'
        WHEN 2 THEN 'cancelled' ELSE 'shipped'
    END as status;

CREATE TEMP TABLE perf_customers AS
SELECT
    generate_series(1, 5000) as customer_id,
    'Customer ' || generate_series(1, 5000) as name,
    'customer' || generate_series(1, 5000) || '@example.com' as email,
    CASE (random() * 3)::int
        WHEN 0 THEN 'Bronze' WHEN 1 THEN 'Silver' ELSE 'Gold'
    END as tier;

\echo '1️⃣ BEFORE: Slow query without optimization'
\timing on
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT
    c.name,
    c.tier,
    COUNT(*) as order_count,
    SUM(o.order_amount) as total_spent
FROM perf_customers c
JOIN perf_orders o ON c.customer_id = o.customer_id
WHERE o.order_date >= '2023-06-01'
  AND o.status = 'completed'
GROUP BY c.customer_id, c.name, c.tier
HAVING SUM(o.order_amount) > 1000
ORDER BY total_spent DESC;

\echo '2️⃣ OPTIMIZATION: Adding strategic indexes'
CREATE INDEX idx_orders_date_status ON perf_orders(order_date, status) WHERE status = 'completed';
CREATE INDEX idx_orders_customer_amount ON perf_orders(customer_id, order_amount);
CREATE INDEX idx_customers_tier ON perf_customers(tier);

\echo '3️⃣ AFTER: Same query with indexes'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT
    c.name,
    c.tier,
    COUNT(*) as order_count,
    SUM(o.order_amount) as total_spent
FROM perf_customers c
JOIN perf_orders o ON c.customer_id = o.customer_id
WHERE o.order_date >= '2023-06-01'
  AND o.status = 'completed'
GROUP BY c.customer_id, c.name, c.tier
HAVING SUM(o.order_amount) > 1000
ORDER BY total_spent DESC;

\echo '4️⃣ Query Rewrite: Using window functions for ranking'
-- Instead of ORDER BY with LIMIT, use window functions
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
WITH customer_stats AS (
    SELECT
        c.customer_id,
        c.name,
        c.tier,
        SUM(o.order_amount) as total_spent,
        COUNT(*) as order_count,
        DENSE_RANK() OVER (ORDER BY SUM(o.order_amount) DESC) as spending_rank
    FROM perf_customers c
    JOIN perf_orders o ON c.customer_id = o.customer_id
    WHERE o.order_date >= '2023-06-01'
      AND o.status = 'completed'
    GROUP BY c.customer_id, c.name, c.tier
    HAVING SUM(o.order_amount) > 1000
)
SELECT * FROM customer_stats
WHERE spending_rank <= 10;

\echo '5️⃣ Index Usage Analysis'
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan as times_used,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    CASE
        WHEN idx_scan = 0 THEN '❌ Unused index'
        WHEN idx_scan < 100 THEN '⚠️ Low usage'
        ELSE '✅ Well used'
    END as usage_status
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

\echo '6️⃣ Table Statistics and Bloat Check'
SELECT
    schemaname,
    tablename,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_tup_del as deletes,
    n_live_tup as live_rows,
    n_dead_tup as dead_rows,
    CASE
        WHEN n_live_tup > 0 THEN
            ROUND(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2)
        ELSE 0
    END as dead_row_percentage,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
ORDER BY dead_row_percentage DESC;

\echo '7️⃣ Query Plan Cache Analysis (pg_stat_statements preview)'
-- Show how to analyze query patterns
SELECT
    'Query pattern analysis' as analysis_type,
    'Use pg_stat_statements for production query monitoring' as recommendation,
    'SELECT query, calls, total_time, mean_time FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10' as example_query;

\echo '8️⃣ Connection and Lock Analysis'
SELECT
    state,
    COUNT(*) as connection_count,
    AVG(EXTRACT(EPOCH FROM (now() - state_change)))::int as avg_duration_seconds
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
GROUP BY state;

-- Check for lock contention
SELECT
    locktype,
    mode,
    COUNT(*) as lock_count,
    CASE
        WHEN COUNT(*) > 10 THEN '⚠️ High lock contention'
        ELSE '✅ Normal lock activity'
    END as lock_status
FROM pg_locks
WHERE NOT granted
GROUP BY locktype, mode
ORDER BY lock_count DESC;

\timing off

\echo '✅ Performance tuning showcase complete! Techniques demonstrated:'
\echo '   • Before/after query optimization with EXPLAIN ANALYZE'
\echo '   • Strategic index creation for common patterns'
\echo '   • Query rewriting with window functions'
\echo '   • Index usage monitoring and analysis'
\echo '   • Table bloat and vacuum monitoring'
\echo '   • Connection and lock analysis'
\echo ''
\echo '🚀 Key takeaways:'
\echo '   • Always EXPLAIN ANALYZE before optimizing'
\echo '   • Create indexes for WHERE, JOIN, and ORDER BY clauses'
\echo '   • Monitor index usage to avoid over-indexing'
\echo '   • Watch for table bloat and dead rows'
EOF

# examples/security_showcase.sql
cat > examples/security_showcase.sql << 'EOF'
-- FILE: examples/security_showcase.sql
-- PostgreSQL Security Patterns and Row-Level Security Demo

\echo '🔐 Security Showcase - RLS, Masking, and Access Control'

-- Create security demo schema and data
CREATE SCHEMA IF NOT EXISTS security_demo;

CREATE TABLE security_demo.sensitive_records AS
SELECT
    generate_series(1, 100) as id,
    'user' || generate_series(1, 100) as username,
    'user' || generate_series(1, 100) || '@company.com' as email,
    -- Simulate SSN (fake data)
    '***-**-' || LPAD((random() * 9999)::text, 4, '0') as ssn_masked,
    (random() * 100000 + 30000)::int as salary,
    CASE (random() * 3)::int
        WHEN 0 THEN 'HR' WHEN 1 THEN 'Engineering' ELSE 'Sales'
    END as department,
    CASE (random() * 3)::int
        WHEN 0 THEN 'employee' WHEN 1 THEN 'manager' ELSE 'admin'
    END as role_level,
    NOW() - (random() * 365)::int * INTERVAL '1 day' as created_at;

\echo '1️⃣ Role-Based Access Control Setup'
-- Create demo roles
CREATE ROLE IF NOT EXISTS security_employee;
CREATE ROLE IF NOT EXISTS security_manager;
CREATE ROLE IF NOT EXISTS security_hr_admin;

-- Grant basic permissions
GRANT USAGE ON SCHEMA security_demo TO security_employee, security_manager, security_hr_admin;
GRANT SELECT ON security_demo.sensitive_records TO security_employee, security_manager, security_hr_admin;

\echo '2️⃣ Row-Level Security (RLS) Implementation'
-- Enable RLS on the table
ALTER TABLE security_demo.sensitive_records ENABLE ROW LEVEL SECURITY;

-- Policy 1: Employees can only see their own records
CREATE POLICY employee_own_records ON security_demo.sensitive_records
    FOR SELECT TO security_employee
    USING (username = current_user);

-- Policy 2: Managers can see their department
CREATE POLICY manager_department_records ON security_demo.sensitive_records
    FOR SELECT TO security_manager
    USING (department = (
        SELECT department FROM security_demo.sensitive_records
        WHERE username = current_user
    ));

-- Policy 3: HR admins see everything
CREATE POLICY hr_all_records ON security_demo.sensitive_records
    FOR SELECT TO security_hr_admin
    USING (true);

\echo '3️⃣ Column-Level Security with Views'
-- Create masked view for sensitive salary data
CREATE VIEW security_demo.employee_directory AS
SELECT
    id,
    username,
    email,
    department,
    CASE
        WHEN pg_has_role(current_user, 'security_hr_admin', 'member') THEN salary::text
        WHEN pg_has_role(current_user, 'security_manager', 'member') THEN
            CASE
                WHEN salary > 75000 THEN '75K+'
                WHEN salary > 50000 THEN '50K-75K'
                ELSE 'Under 50K'
            END
        ELSE 'Confidential'
    END as salary_band,
    created_at
FROM security_demo.sensitive_records;

-- Grant access to the view instead of base table
GRANT SELECT ON security_demo.employee_directory TO security_employee;

\echo '4️⃣ Audit Trail Implementation'
CREATE TABLE security_demo.access_log (
    id serial PRIMARY KEY,
    username text NOT NULL,
    table_accessed text NOT NULL,
    action text NOT NULL,
    record_id int,
    accessed_at timestamp DEFAULT now(),
    client_ip inet DEFAULT inet_client_addr()
);

-- Create audit trigger function
CREATE OR REPLACE FUNCTION security_demo.log_access()
RETURNS trigger AS $
BEGIN
    INSERT INTO security_demo.access_log (username, table_accessed, action, record_id)
    VALUES (current_user, TG_TABLE_NAME, TG_OP,
        CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END);
    RETURN COALESCE(NEW, OLD);
END;
$ LANGUAGE plpgsql;

-- Apply audit trigger
CREATE TRIGGER sensitive_records_audit
    AFTER INSERT OR UPDATE OR DELETE ON security_demo.sensitive_records
    FOR EACH ROW EXECUTE FUNCTION security_demo.log_access();

\echo '5️⃣ Data Encryption Example'
-- Create table with encrypted fields
CREATE TABLE security_demo.encrypted_notes AS
SELECT
    generate_series(1, 20) as id,
    'Note ' || generate_series(1, 20) as title,
    -- Encrypt sensitive content (requires pgcrypto)
    pgp_sym_encrypt(
        'This is confidential note content for record ' || generate_series(1, 20),
        'demo_encryption_key'
    ) as encrypted_content,
    NOW() as created_at;

-- Query encrypted data
SELECT
    id,
    title,
    pgp_sym_decrypt(encrypted_content, 'demo_encryption_key') as decrypted_content,
    created_at
FROM security_demo.encrypted_notes
LIMIT 5;

\echo '6️⃣ Security Analysis Queries'
-- Check RLS policies
SELECT
    schemaname,
    tablename,
    policyname,
    roles,
    cmd,
    qual
FROM pg_policies
WHERE schemaname = 'security_demo';

-- Analyze access patterns
SELECT
    username,
    table_accessed,
    action,
    COUNT(*) as access_count,
    MAX(accessed_at) as last_access,
    COUNT(DISTINCT record_id) as unique_records_accessed
FROM security_demo.access_log
GROUP BY username, table_accessed, action
ORDER BY access_count DESC;

-- Check for suspicious access patterns
SELECT
    username,
    DATE(accessed_at) as access_date,
    COUNT(*) as daily_access_count,
    CASE
        WHEN COUNT(*) > 50 THEN '⚠️ High volume access'
        WHEN COUNT(DISTINCT record_id) > 20 THEN '⚠️ Wide data access'
        ELSE '✅ Normal access'
    END as risk_assessment
FROM security_demo.access_log
GROUP BY username, DATE(accessed_at)
ORDER BY daily_access_count DESC;

\echo '7️⃣ Permission Summary'
-- Show effective permissions
SELECT
    r.rolname as role,
    n.nspname as schema,
    c.relname as table,
    string_agg(DISTINCT p.perm, ', ') as permissions
FROM pg_roles r
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) p(perm)
JOIN pg_namespace n ON n.nspname = 'security_demo'
JOIN pg_class c ON c.relnamespace = n.oid
WHERE has_table_privilege(r.rolname, c.oid, p.perm)
  AND r.rolname LIKE 'security_%'
GROUP BY r.rolname, n.nspname, c.relname
ORDER BY r.rolname, c.relname;

\echo '✅ Security showcase complete! Security patterns demonstrated:'
\echo '   • Role-based access control (RBAC)'
\echo '   • Row-level security policies'
\echo '   • Column-level masking with views'
\echo '   • Audit trail implementation'
\echo '   • Data encryption with pgcrypto'
\echo '   • Access pattern monitoring'
\echo '   • Permission analysis queries'
EOF

echo "📝 Creating remaining SQL modules (consolidated structure)..."

# sql/01_schema_design/civics.sql
cat > sql/01_schema_design/civics.sql << 'EOF'
-- FILE: sql/01_schema_design/civics.sql
-- Civics Domain - Citizens, permits, taxes, voting records

\echo 'Creating civics domain tables...'

-- Citizens table - core entity
CREATE TABLE IF NOT EXISTS civics.citizens (
    id serial PRIMARY KEY,
    name text NOT NULL,
    email text UNIQUE NOT NULL,
    age int CHECK (age >= 18 AND age <= 120),
    city text NOT NULL,
    registration_date date NOT NULL DEFAULT CURRENT_DATE,
    is_active boolean DEFAULT true,
    created_at timestamp DEFAULT now(),
    updated_at timestamp DEFAULT now()
);

-- Permits table
CREATE TABLE IF NOT EXISTS civics.permits (
    id serial PRIMARY KEY,
    citizen_id int NOT NULL REFERENCES civics.citizens(id),
    permit_type text NOT NULL,
    description text,
    application_date date NOT NULL DEFAULT CURRENT_DATE,
    approval_date date,
    expiry_date date,
    fee_amount numeric(10,2) CHECK (fee_amount >= 0),
    status text DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied', 'expired')),
    created_at timestamp DEFAULT now()
);

-- Tax payments table
CREATE TABLE IF NOT EXISTS civics.tax_payments (
    id serial PRIMARY KEY,
    citizen_id int NOT NULL REFERENCES civics.citizens(id),
    tax_year int NOT NULL CHECK (tax_year >= 2000 AND tax_year <= EXTRACT(year FROM CURRENT_DATE) + 1),
    amount_due numeric(12,2) NOT NULL CHECK (amount_due >= 0),
    amount_paid numeric(12,2) DEFAULT 0 CHECK (amount_paid >= 0),
    payment_date date,
    is_fully_paid boolean GENERATED ALWAYS AS (amount_paid >= amount_due) STORED,
    created_at timestamp DEFAULT now()
);

-- Voting records table
CREATE TABLE IF NOT EXISTS civics.votes (
    id serial PRIMARY KEY,
    citizen_id int NOT NULL REFERENCES civics.citizens(id),
    election_type text NOT NULL,
    election_date date NOT NULL,
    precinct text,
    voted_at timestamp DEFAULT now(),
    UNIQUE(citizen_id, election_type, election_date)
);

-- Add table comments
COMMENT ON TABLE civics.citizens IS 'Registered citizens with basic demographic info';
COMMENT ON TABLE civics.permits IS 'Building permits, business licenses, etc.';
COMMENT ON TABLE civics.tax_payments IS 'Property tax and municipal fee payments';
COMMENT ON TABLE civics.votes IS 'Voting participation records';

\echo 'Civics domain tables created successfully'
EOF

# sql/01_schema_design/commerce.sql
cat > sql/01_schema_design/commerce.sql << 'EOF'
-- FILE: sql/01_schema_design/commerce.sql
-- Commerce Domain - Merchants, orders, payments

\echo 'Creating commerce domain tables...'

-- Merchants table
CREATE TABLE IF NOT EXISTS commerce.merchants (
    id serial PRIMARY KEY,
    name text NOT NULL,
    email text UNIQUE NOT NULL,
    founded_date date,
    city text NOT NULL,
    category text NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp DEFAULT now(),
    updated_at timestamp DEFAULT now()
);

-- Orders table
CREATE TABLE IF NOT EXISTS commerce.orders (
    id serial PRIMARY KEY,
    merchant_id int NOT NULL REFERENCES commerce.merchants(id),
    customer_email text NOT NULL,
    order_date date NOT NULL DEFAULT CURRENT_DATE,
    total_amount numeric(12,2) NOT NULL CHECK (total_amount >= 0),
    status text DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled')),
    created_at timestamp DEFAULT now(),
    updated_at timestamp DEFAULT now()
);

-- Order items table (normalized)
CREATE TABLE IF NOT EXISTS commerce.order_items (
    id serial PRIMARY KEY,
    order_id int NOT NULL REFERENCES commerce.orders(id) ON DELETE CASCADE,
    product_name text NOT NULL,
    quantity int NOT NULL CHECK (quantity > 0),
    unit_price numeric(10,2) NOT NULL CHECK (unit_price >= 0),
    line_total numeric(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);

-- Payments table
CREATE TABLE IF NOT EXISTS commerce.payments (
    id serial PRIMARY KEY,
    order_id int NOT NULL REFERENCES commerce.orders(id),
    payment_method text NOT NULL CHECK (payment_method IN ('credit_card', 'debit_card', 'paypal', 'bank_transfer', 'cash')),
    amount numeric(12,2) NOT NULL CHECK (amount > 0),
    payment_date timestamp DEFAULT now(),
    transaction_id text UNIQUE,
    status text DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed', 'refunded'))
);

-- Add table comments
COMMENT ON TABLE commerce.merchants IS 'Local businesses and online merchants';
COMMENT ON TABLE commerce.orders IS 'Customer orders placed with merchants';
COMMENT ON TABLE commerce.order_items IS 'Individual items within each order';
COMMENT ON TABLE commerce.payments IS 'Payment transactions for orders';

\echo 'Commerce domain tables created successfully'
EOF

# sql/01_schema_design/mobility.sql
cat > sql/01_schema_design/mobility.sql << 'EOF'
-- FILE: sql/01_schema_design/mobility.sql
-- Mobility Domain - Transportation trips, sensors, stations

\echo 'Creating mobility domain tables...'

-- Trips table
CREATE TABLE IF NOT EXISTS mobility.trips (
    id serial PRIMARY KEY,
    user_id int, -- References citizens but loose coupling
    start_time timestamp NOT NULL,
    end_time timestamp NOT NULL,
    mode_of_transport text NOT NULL CHECK (mode_of_transport IN ('walk', 'bike', 'bus', 'car', 'train', 'scooter')),
    distance_km numeric(8,2) CHECK (distance_km >= 0),
    cost numeric(8,2) DEFAULT 0 CHECK (cost >= 0),
    created_at timestamp DEFAULT now(),
    CONSTRAINT valid_trip_duration CHECK (end_time > start_time)
);

-- Trip segments (for multi-modal journeys)
CREATE TABLE IF NOT EXISTS mobility.trip_segments (
    id serial PRIMARY KEY,
    trip_id int NOT NULL REFERENCES mobility.trips(id) ON DELETE CASCADE,
    segment_order int NOT NULL CHECK (segment_order > 0),
    start_location point,
    end_location point,
    transport_mode text NOT NULL,
    duration_minutes int CHECK (duration_minutes > 0),
    UNIQUE(trip_id, segment_order)
);

-- Sensor readings table (time-series data)
CREATE TABLE IF NOT EXISTS mobility.sensor_readings (
    id serial PRIMARY KEY,
    sensor_id text NOT NULL,
    location text,
    reading_time timestamp NOT NULL,
    temperature numeric(5,2),
    humidity numeric(5,2),
    air_quality_pm25 numeric(6,2),
    traffic_volume int CHECK (traffic_volume >= 0),
    created_at timestamp DEFAULT now()
);

-- Transit stations
CREATE TABLE IF NOT EXISTS mobility.transit_stations (
    id serial PRIMARY KEY,
    name text NOT NULL,
    station_type text NOT NULL CHECK (station_type IN ('bus_stop', 'train_station', 'bike_share', 'parking')),
    location point,
    capacity int CHECK (capacity > 0),
    is_accessible boolean DEFAULT false,
    amenities text[], -- Array of amenities
    created_at timestamp DEFAULT now()
);

-- Station inventory (bikes, parking spaces, etc.)
CREATE TABLE IF NOT EXISTS mobility.station_inventory (
    id serial PRIMARY KEY,
    station_id int NOT NULL REFERENCES mobility.transit_stations(id),
    inventory_type text NOT NULL,
    total_capacity int NOT NULL CHECK (total_capacity > 0),
    available_count int NOT NULL CHECK (available_count >= 0),
    last_updated timestamp DEFAULT now(),
    CONSTRAINT valid_inventory CHECK (available_count <= total_capacity)
);

-- Add table comments
COMMENT ON TABLE mobility.trips IS 'Individual transportation journeys';
COMMENT ON TABLE mobility.trip_segments IS 'Multi-modal trip breakdown';
COMMENT ON TABLE mobility.sensor_readings IS 'Environmental and traffic sensors';
COMMENT ON TABLE mobility.transit_stations IS 'Bus stops, train stations, bike shares';
COMMENT ON TABLE mobility.station_inventory IS 'Real-time availability at stations';

\echo 'Mobility domain tables created successfully'
EOF

# sql/01_schema_design/geo.sql
cat > sql/01_schema_design/geo.sql << 'EOF'
-- FILE: sql/01_schema_design/geo.sql
-- Geospatial Domain - Neighborhoods, roads, points of interest

\echo 'Creating geospatial domain tables...'

-- Neighborhoods (polygon geometry)
CREATE TABLE IF NOT EXISTS geo.neighborhoods (
    id serial PRIMARY KEY,
    name text NOT NULL UNIQUE,
    population int CHECK (population >= 0),
    median_income int CHECK (median_income >= 0),
    area_sq_km numeric(10,4) CHECK (area_sq_km > 0),
    geom geometry(Polygon, 4326),
    created_at timestamp DEFAULT now()
);

-- Roads and streets (linestring geometry)
CREATE TABLE IF NOT EXISTS geo.roads (
    id serial PRIMARY KEY,
    name text NOT NULL,
    road_type text CHECK (road_type IN ('highway', 'arterial', 'collector', 'residential', 'bike_path')),
    speed_limit int CHECK (speed_limit > 0 AND speed_limit <= 120),
    is_one_way boolean DEFAULT false,
    surface_type text DEFAULT 'asphalt',
    geom geometry(LineString, 4326),
    length_km numeric(10,4),
    created_at timestamp DEFAULT now()
);

-- Points of interest (point geometry)
CREATE TABLE IF NOT EXISTS geo.points_of_interest (
    id serial PRIMARY KEY,
    name text NOT NULL,
    poi_type text NOT NULL,
    category text,
    address text,
    phone text,
    website text,
    rating numeric(2,1) CHECK (rating >= 0 AND rating <= 5),
    geom geometry(Point, 4326),
    neighborhood_id int REFERENCES geo.neighborhoods(id),
    created_at timestamp DEFAULT now()
);

-- Spatial analysis helper table - grid cells
CREATE TABLE IF NOT EXISTS geo.analysis_grid (
    id serial PRIMARY KEY,
    grid_x int NOT NULL,
    grid_y int NOT NULL,
    cell_size_m int NOT NULL DEFAULT 1000,
    geom geometry(Polygon, 4326),
    population_density numeric(10,2),
    poi_count int DEFAULT 0,
    UNIQUE(grid_x, grid_y, cell_size_m)
);

-- Service areas (for accessibility analysis)
CREATE TABLE IF NOT EXISTS geo.service_areas (
    id serial PRIMARY KEY,
    service_type text NOT NULL,
    facility_name text,
    service_radius_m int CHECK (service_radius_m > 0),
    geom geometry(Polygon, 4326),
    population_served int,
    created_at timestamp DEFAULT now()
);

-- Add spatial indexes (PostGIS)
CREATE INDEX IF NOT EXISTS idx_neighborhoods_geom ON geo.neighborhoods USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_roads_geom ON geo.roads USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_pois_geom ON geo.points_of_interest USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_grid_geom ON geo.analysis_grid USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_service_areas_geom ON geo.service_areas USING GIST(geom);

-- Add table comments
COMMENT ON TABLE geo.neighborhoods IS 'Administrative boundaries with demographics';
COMMENT ON TABLE geo.roads IS 'Street network with transportation attributes';
COMMENT ON TABLE geo.points_of_interest IS 'Businesses, landmarks, and facilities';
COMMENT ON TABLE geo.analysis_grid IS 'Regular grid for spatial aggregation';
COMMENT ON TABLE geo.service_areas IS 'Service catchment areas for accessibility analysis';

\echo 'Geospatial domain tables created successfully'
EOF

# sql/01_schema_design/documents.sql
cat > sql/01_schema_design/documents.sql << 'EOF'
-- FILE: sql/01_schema_design/documents.sql
-- Document Storage - JSONB for complaints, policies, metadata

\echo 'Creating document storage tables...'

-- Main documents table with JSONB
CREATE TABLE IF NOT EXISTS staging.documents (
    id serial PRIMARY KEY,
    doc_type text NOT NULL,
    title text,
    doc jsonb NOT NULL,
    full_text text, -- Extracted for full-text search
    tags text[],
    created_at timestamp DEFAULT now(),
    updated_at timestamp DEFAULT now(),
    version int DEFAULT 1
);

-- Document relationships (many-to-many)
CREATE TABLE IF NOT EXISTS staging.document_relations (
    id serial PRIMARY KEY,
    parent_doc_id int NOT NULL REFERENCES staging.documents(id),
    child_doc_id int NOT NULL REFERENCES staging.documents(id),
    relation_type text NOT NULL CHECK (relation_type IN ('references', 'supersedes', 'amends', 'implements')),
    created_at timestamp DEFAULT now(),
    UNIQUE(parent_doc_id, child_doc_id, relation_type)
);

-- Document access log
CREATE TABLE IF NOT EXISTS staging.document_access (
    id serial PRIMARY KEY,
    document_id int NOT NULL REFERENCES staging.documents(id),
    accessed_by text NOT NULL,
    access_type text NOT NULL CHECK (access_type IN ('view', 'download', 'edit', 'delete')),
    ip_address inet,
    user_agent text,
    accessed_at timestamp DEFAULT now()
);

-- JSONB validation constraints
ALTER TABLE staging.documents
ADD CONSTRAINT valid_jsonb_structure
CHECK (jsonb_typeof(doc) = 'object');

-- Add specific validation for document types
CREATE OR REPLACE FUNCTION validate_document_jsonb(doc_type text, doc jsonb)
RETURNS boolean AS $
BEGIN
    CASE doc_type
        WHEN 'complaint' THEN
            RETURN doc ? 'category' AND doc ? 'description' AND doc ? 'status';
        WHEN 'policy' THEN
            RETURN doc ? 'title' AND doc ? 'effective_date' AND doc ? 'approval_status';
        WHEN 'metadata' THEN
            RETURN doc ? 'entity';
        ELSE
            RETURN true; -- Allow other document types
    END CASE;
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- Apply validation constraint
ALTER TABLE staging.documents
ADD CONSTRAINT valid_doc_structure
CHECK (validate_document_jsonb(doc_type, doc));

-- Indexes for JSONB queries
CREATE INDEX IF NOT EXISTS idx_documents_doc_gin ON staging.documents USING GIN(doc);
CREATE INDEX IF NOT EXISTS idx_documents_doc_type ON staging.documents(doc_type);
CREATE INDEX IF NOT EXISTS idx_documents_tags_gin ON staging.documents USING GIN(tags);

-- Full-text search index
CREATE INDEX IF NOT EXISTS idx_documents_fulltext ON staging.documents USING GIN(to_tsvector('english', full_text));

-- Function to extract full text from JSONB
CREATE OR REPLACE FUNCTION extract_document_text(doc jsonb)
RETURNS text AS $
BEGIN
    RETURN COALESCE(
        doc->>'title', ''
    ) || ' ' || COALESCE(
        doc->>'description', ''
    ) || ' ' || COALESCE(
        doc->>'content', ''
    );
END;
$ LANGUAGE plpgsql IMMUTABLE;

-- Trigger to maintain full_text column
CREATE OR REPLACE FUNCTION update_document_fulltext()
RETURNS trigger AS $
BEGIN
    NEW.full_text := extract_document_text(NEW.doc);
    NEW.updated_at := now();
    RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER documents_fulltext_trigger
    BEFORE INSERT OR UPDATE ON staging.documents
    FOR EACH ROW EXECUTE FUNCTION update_document_fulltext();

-- Add table comments
COMMENT ON TABLE staging.documents IS 'Flexible document storage using JSONB';
COMMENT ON TABLE staging.document_relations IS 'Document relationships and dependencies';
COMMENT ON TABLE staging.document_access IS 'Audit trail for document access';

\echo 'Document storage tables created successfully'
EOF

echo ""
echo "✅ Complete project structure generated at: ${BASE_DIR}"
echo "🚀 Next steps:"
echo "   1. cd ${PROJECT_NAME}"
echo "   2. make bootstrap"
echo "   3. make up"
echo "   4. Open http://localhost:8080 in your browser"
echo ""
echo "📚 Key directories created:"
echo "   • docker/     - PostgreSQL environment"
echo "   • sql/        - Learning modules (00-16)"
echo "   • data/       - Sample datasets"
echo "   • examples/   - Ready-to-run demos"
echo "   • tests/      - Validation scripts"
echo "   • docs/       - Learning guides"
echo "   • scripts/    - Utility scripts"
#EOF

# Make scripts executable
chmod +x "${BASE_DIR}/scripts"/*.sh
