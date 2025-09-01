# Module Map & Exercises - PostgreSQL Polaris

**Location**: `/docs/MODULE_MAP_EXERCISES.md`

Comprehensive guide to all 15 learning modules with exercises, solutions, and quick reference cheatsheets.

## 📖 Module Overview

### Foundation Modules (Hours 1-4)

- **00_init**: Environment setup and conventions
- **01_schema_design**: Data modeling and relationships
- **02_constraints_indexes**: Performance fundamentals
- **03_dml_queries**: Query mastery

### Intermediate Modules (Hours 5-8)

- **04_views_matviews**: Data abstraction layers
- **05_functions_triggers**: Business logic automation
- **06_jsonb_fulltext**: Modern data patterns
- **07_geospatial**: PostGIS spatial analysis

### Advanced Modules (Hours 9-15)

- **08_partitioning_timeseries**: Scale strategies
- **09_data_movement**: Import/export/federation
- **10_tx_mvcc_locks**: Concurrency control
- **11_perf_tuning**: Query optimization
- **12_security_rls**: Multi-tenant security
- **13_backup_replication**: Data protection
- **14_async_patterns**: Event-driven architecture

### Capstone Projects (Hours 16+)

- **99_capstones**: Real-world scenarios

## 🎯 Module Details & Exercises

### Module 00: Init - Environment Setup

**Files**: `sql/00_init/*.sql`
**Time**: 30 minutes
**Prerequisites**: None

**Learning Objectives**:

- Database initialization
- Naming conventions
- Development workflow

**Key Exercises**:

1. **Schema Creation**: Create development schemas
2. **Convention Setup**: Implement naming standards
3. **Reset Procedures**: Master cleanup workflows

**Quick Commands**:

```bash
make run-init
make run-module MODULE=00_init/000_schemas.sql
```

**Cheatsheet**:

```sql
-- Create schema
CREATE SCHEMA IF NOT EXISTS app_data;

-- Set search path
SET search_path = app_data, public;

-- Add comments
COMMENT ON SCHEMA app_data IS 'Application data tables';
```

---

### Module 01: Schema Design - Data Modeling

**Files**: `sql/01_schema_design/*.sql`
**Time**: 2 hours
**Prerequisites**: Module 00

**Learning Objectives**:

- Normalization principles
- Relationship modeling
- Urban data patterns

**Key Exercises**:

1. **Citizens Table**: Design person entities with addresses
2. **Commerce Schema**: Model merchants, products, orders
3. **Mobility Data**: Transit routes, trips, stations
4. **Geospatial Schema**: Neighborhoods, POIs, boundaries

**Practice Problems**:

```sql
-- Exercise 1: Design a citizen registration system
-- Requirements: track name, contact, address, registration date
-- Bonus: support multiple addresses per citizen

-- Exercise 2: Model a merchant marketplace
-- Requirements: businesses, categories, products, inventory
-- Bonus: support business hours and seasonal availability

-- Exercise 3: Design transit system
-- Requirements: routes, stops, schedules, vehicle tracking
-- Bonus: real-time arrival predictions
```

**Solutions Available**: Yes, in same directory with `_solution.sql` suffix

**Cheatsheet**:

```sql
-- Primary key patterns
id SERIAL PRIMARY KEY
uuid UUID DEFAULT gen_random_uuid() PRIMARY KEY

-- Foreign keys
REFERENCES table_name(id) ON DELETE CASCADE

-- Common constraints
NOT NULL, UNIQUE, CHECK (value > 0)

-- Indexes for FK performance
CREATE INDEX idx_table_fk_column ON table(foreign_key_column);
```

---

### Module 02: Constraints & Indexes - Performance Foundations

**Files**: `sql/02_constraints_indexes/*.sql`
**Time**: 1.5 hours
**Prerequisites**: Module 01

**Learning Objectives**:

- Constraint types and usage
- Index strategies
- Query performance basics

**Key Exercises**:

1. **Primary/Foreign Keys**: Implement referential integrity
2. **Check Constraints**: Business rule enforcement
3. **Unique Constraints**: Prevent duplicates
4. **Index Types**: B-tree, Hash, GIN, GiST, BRIN
5. **Partial Indexes**: Conditional indexing

**Practice Problems**:

```sql
-- Exercise 1: Add constraints to prevent invalid data
-- Citizens: age 18+, valid email format, unique SSN
-- Orders: positive amounts, valid status enum

-- Exercise 2: Design indexes for common queries
-- Find citizens by city
-- Search orders by date range and status
-- Lookup merchants by category

-- Exercise 3: Create partial indexes
-- Index only active merchants
-- Index only recent orders (last 6 months)
```

**Performance Targets**:

- Simple lookups: <1ms
- Range queries: <10ms
- Complex joins: <50ms

**Cheatsheet**:

```sql
-- Constraint types
PRIMARY KEY, FOREIGN KEY, UNIQUE, NOT NULL, CHECK

-- Index types and usage
CREATE INDEX ON table(column);                    -- B-tree (default)
CREATE INDEX ON table USING HASH(column);         -- Hash (equality only)
CREATE INDEX ON table USING GIN(column);          -- GIN (arrays, JSONB)
CREATE INDEX ON table USING GIST(column);         -- GiST (geometry, ranges)

-- Partial indexes
CREATE INDEX ON orders(created_at) WHERE status = 'pending';

-- Multi-column indexes
CREATE INDEX ON table(col1, col2, col3);  -- Order matters!
```

---

### Module 03: DML & Queries - SQL Mastery

**Files**: `sql/03_dml_queries/*.sql`
**Time**: 2 hours
**Prerequisites**: Modules 01-02

**Learning Objectives**:

- Advanced SELECT patterns
- Aggregation and grouping
- Window functions
- CTEs and recursive queries

**Key Exercises**:

1. **Data Seeding**: Load sample urban data
2. **Basic Queries**: Filtering, sorting, joining
3. **Aggregations**: GROUP BY, HAVING, ROLLUP, CUBE
4. **Window Functions**: Ranking, running totals, lag/lead
5. **CTEs**: Hierarchical data, recursive patterns

**Practice Problems**:

```sql
-- Exercise 1: Customer analysis
-- Find top 10 customers by spending
-- Show monthly spending trends
-- Identify customers with no orders in 90 days

-- Exercise 2: Transit analysis
-- Peak ridership hours by route
-- Average trip duration by day of week
-- Routes with capacity issues

-- Exercise 3: Merchant performance
-- Revenue ranking within category
-- Month-over-month growth rates
-- Seasonal trend analysis
```

**Advanced Challenges**:

```sql
-- Recursive CTE: Organization hierarchy
-- Window function: Running averages with custom frames
-- Complex aggregation: Multi-dimensional CUBE analysis
```

**Cheatsheet**:

```sql
-- Window functions
ROW_NUMBER() OVER (PARTITION BY col ORDER BY col2)
RANK() OVER (ORDER BY col DESC)
LAG(col, 1) OVER (ORDER BY date)
SUM(col) OVER (ORDER BY date ROWS 7 PRECEDING)

-- CTEs
WITH recursive_cte AS (
  SELECT ... -- Base case
  UNION ALL
  SELECT ... -- Recursive case
)

-- Aggregation
GROUP BY ROLLUP(col1, col2)  -- Subtotals
GROUP BY CUBE(col1, col2)    -- All combinations
```

---

### Module 04: Views & Materialized Views - Data Abstraction

**Files**: `sql/04_views_matviews/*.sql`
**Time**: 1 hour
**Prerequisites**: Module 03

**Learning Objectives**:

- View design patterns
- Materialized view strategies
- Refresh mechanisms
- Performance considerations

**Key Exercises**:

1. **Reporting Views**: Customer summaries, merchant dashboards
2. **Security Views**: Row-level filtering, column masking
3. **Materialized Views**: Heavy aggregations, dashboard data
4. **Refresh Strategies**: Manual, scheduled, triggered

**Practice Problems**:

```sql
-- Exercise 1: Create customer dashboard view
-- Show customer info + order summary + recent activity

-- Exercise 2: Merchant analytics matview
-- Daily/weekly/monthly revenue by category
-- Refresh nightly for dashboard

-- Exercise 3: Real-time vs batch views
-- Design views for both real-time queries and batch reports
```

**Cheatsheet**:

```sql
-- Views
CREATE VIEW view_name AS SELECT ...;
CREATE OR REPLACE VIEW view_name AS SELECT ...;

-- Materialized views
CREATE MATERIALIZED VIEW mv_name AS SELECT ...;
REFRESH MATERIALIZED VIEW mv_name;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_name; -- Requires unique index

-- View dependencies
SELECT * FROM information_schema.view_table_usage;
```

---

### Module 05: Functions & Triggers - Business Logic

**Files**: `sql/05_functions_triggers/*.sql`
**Time**: 1.5 hours
**Prerequisites**: Module 04

**Learning Objectives**:

- PL/pgSQL programming
- Function design patterns
- Trigger mechanisms
- Error handling

**Key Exercises**:

1. **Utility Functions**: Data validation, formatting
2. **Business Logic**: Discount calculations, tax computation
3. **Audit Triggers**: Change tracking, logging
4. **Data Validation**: Constraint enforcement
5. **Event Triggers**: Schema change monitoring

**Practice Problems**:

```sql
-- Exercise 1: Order processing function
-- Calculate taxes, discounts, shipping
-- Handle inventory updates
-- Return order summary

-- Exercise 2: Audit system
-- Track all changes to critical tables
-- Store before/after values
-- Include user and timestamp info

-- Exercise 3: Data quality triggers
-- Validate email formats on insert
-- Auto-update modified timestamps
-- Normalize phone number formats
```

**Cheatsheet**:

```sql
-- Function basics
CREATE OR REPLACE FUNCTION func_name(param_type)
RETURNS return_type AS $
BEGIN
  -- Logic here
  RETURN value;
END;
$ LANGUAGE plpgsql;

-- Trigger function
CREATE TRIGGER trigger_name
  BEFORE/AFTER INSERT/UPDATE/DELETE
  ON table_name
  FOR EACH ROW
  EXECUTE FUNCTION trigger_function();
```

---

### Module 06: JSONB & Full-Text Search - Modern Patterns

**Files**: `sql/06_jsonb_fulltext/*.sql`
**Time**: 2 hours
**Prerequisites**: Module 05

**Learning Objectives**:

- JSONB data modeling
- JSON validation patterns
- GIN indexing strategies
- Full-text search implementation
- Search ranking and highlighting

**Key Exercises**:

1. **Document Modeling**: Complaints, policies, business profiles
2. **JSON Validation**: Schema constraints, business rules
3. **Search Implementation**: Text search across JSONB
4. **Performance**: GIN indexes, query optimization

**Practice Problems**:

```sql
-- Exercise 1: Complaint system
-- Model citizen complaints with flexible metadata
-- Support attachments, status tracking, geo-location

-- Exercise 2: Business directory
-- Store business profiles with variable attributes
-- Support full-text search across all fields

-- Exercise 3: Policy document system
-- Version control for policy documents
-- Full-text search with ranking and highlighting
```

**Cheatsheet**:

```sql
-- JSONB operators
column->>'key'           -- Text value
column->'key'            -- JSON value
column @> '{"key":"val"}'  -- Contains
column ? 'key'           -- Key exists

-- GIN indexes
CREATE INDEX ON table USING GIN(jsonb_column);

-- Full-text search
to_tsvector('english', text_column)
to_tsquery('english', 'search & terms')
ts_rank(tsvector, tsquery)
```

---

### Module 07: Geospatial - PostGIS Analysis

**Files**: `sql/07_geospatial/*.sql`
**Time**: 2 hours
**Prerequisites**: Module 06

**Learning Objectives**:

- Coordinate systems and projections
- Spatial data types
- Geometric operations
- Spatial indexing
- Location-based queries

**Key Exercises**:

1. **Spatial Setup**: Enable PostGIS, understand SRID
2. **Geometric Operations**: Distance, intersection, buffering
3. **Spatial Indexes**: GiST performance optimization
4. **Location Queries**: Nearest neighbor, within radius
5. **Routing**: Basic pathfinding examples

**Practice Problems**:

```sql
-- Exercise 1: Neighborhood analysis
-- Find which neighborhood each citizen lives in
-- Calculate average income by neighborhood

-- Exercise 2: Transit accessibility
-- Find all POIs within walking distance of transit stops
-- Calculate service coverage areas

-- Exercise 3: Emergency services
-- Optimal placement of fire stations
-- Response time analysis by area
```

**Cheatsheet**:

```sql
-- Spatial data types
GEOMETRY(POINT, 4326)
GEOGRAPHY(POLYGON, 4326)

-- Common functions
ST_Distance(geom1, geom2)
ST_Contains(polygon, point)
ST_Intersects(geom1, geom2)
ST_Buffer(geom, radius)
ST_Area(polygon)

-- Spatial index
CREATE INDEX ON table USING GIST(geometry_column);
```

---

### Module 08: Partitioning & Time Series - Scale Strategies

**Files**: `sql/08_partitioning_timeseries/*.sql`
**Time**: 1.5 hours
**Prerequisites**: Module 07

**Learning Objectives**:

- Declarative partitioning
- Time-based partitioning
- Retention policies
- Query routing
- Maintenance automation

**Key Exercises**:

1. **Sensor Data Partitioning**: By date ranges
2. **Multi-tenant Partitioning**: By organization
3. **Retention Management**: Automatic old data removal
4. **Query Performance**: Partition pruning optimization

**Cheatsheet**:

```sql
-- Create partitioned table
CREATE TABLE sensor_data (timestamp TIMESTAMPTZ, value NUMERIC)
PARTITION BY RANGE (timestamp);

-- Create partitions
CREATE TABLE sensor_data_2024_01
PARTITION OF sensor_data
FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- Automatic partition creation
SELECT partman.create_parent('public.sensor_data', 'timestamp', 'monthly');
```

---

### Module 09: Data Movement - Import/Export/Federation

**Files**: `sql/09_data_movement/*.sql`
**Time**: 1.5 hours
**Prerequisites**: Module 08

**Learning Objectives**:

- COPY command mastery
- Foreign data wrappers
- Bulk operations
- Data pipeline patterns

**Key Exercises**:

1. **CSV Import/Export**: Efficient bulk operations
2. **Foreign Tables**: Connect external data sources
3. **Cross-Database Queries**: Federation examples
4. **ETL Patterns**: Transform and load workflows

**Cheatsheet**:

```sql
-- COPY operations
COPY table FROM '/path/to/file.csv' WITH (FORMAT csv, HEADER);
COPY (SELECT ...) TO STDOUT WITH (FORMAT csv, HEADER);

-- Foreign data wrapper
CREATE EXTENSION postgres_fdw;
CREATE SERVER foreign_server FOREIGN DATA WRAPPER postgres_fdw;
CREATE FOREIGN TABLE foreign_table (...) SERVER foreign_server;
```

---

### Module 10-14: Advanced Topics Summary

**Modules**: TX/MVCC, Performance Tuning, Security, Backup/Replication, Async Patterns
**Time**: 6 hours total
**Prerequisites**: Modules 01-09

**Combined Learning Objectives**:

- Transaction isolation and concurrency
- Query optimization and performance monitoring
- Row-level security and data protection
- Backup strategies and high availability
- Event-driven patterns and coordination

**Key Focus Areas**:

- **Concurrency**: Deadlock prevention, lock monitoring
- **Performance**: EXPLAIN analysis, index tuning
- **Security**: RLS policies, audit trails
- **Reliability**: Backup automation, replication setup
- **Events**: LISTEN/NOTIFY, job scheduling

---

### Module 99: Capstone Projects - Real-World Integration

**Files**: `sql/99_capstones/*.sql`
**Time**: 4+ hours
**Prerequisites**: All previous modules

**Project Options**:

1. **City Analytics Dashboard**: KPI views with real-time updates
2. **Anomaly Detection System**: Statistical analysis and alerting
3. **Accessibility Study**: Geospatial analysis with demographics
4. **Real-time Monitoring**: Event-driven data processing

**Deliverables**:

- Complete working system
- Performance benchmarks
- Documentation and deployment guide
- Presentation of findings

## 🎯 Quick Reference Cards

### Essential Commands

```bash
# Module execution
make run-module MODULE=path/to/file.sql

# Testing and validation
make test-schema
make bench

# Data management
make load-data
make reset
```

### Common Patterns

```sql
-- Performance analysis
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;

-- Index usage check
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0;

-- Lock monitoring
SELECT * FROM pg_locks WHERE NOT granted;
```

### Troubleshooting Quick Fixes

- **Slow queries**: Check EXPLAIN plan, add indexes
- **Blocking locks**: Identify and terminate long transactions
- **High memory usage**: Tune work_mem and maintenance_work_mem
- **Connection issues**: Check pg_hba.conf and connection limits

---

**Next Steps**: Choose your learning path in [LEARNING_PATHS.md](LEARNING_PATHS.md) and start with Module 00!
