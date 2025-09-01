# PostgreSQL Polaris

A comprehensive PostgreSQL learning environment featuring real-world urban data scenarios, advanced patterns, and hands-on exercises designed to take you from beginner to expert.

## Quick Start

```bash
# Clone and setup
git clone https://github.com/SatvikPraveen/postgres-polaris.git
cd postgres-polaris
make bootstrap

# Start the environment
make up

# Access database
make psql
# OR visit http://localhost:8080 (Adminer web interface)
```

## Learning Levels

### Beginner (4-6 hours)

Perfect for SQL newcomers and those refreshing fundamentals.

1. **[Schema Design](sql/01_schema_design/)** - Urban data modeling and relationships
2. **[Constraints & Indexes](sql/02_constraints_indexes/)** - Data integrity and performance fundamentals
3. **[DML Queries](sql/03_dml_queries/)** - SELECT, GROUP BY, JOINs, and advanced querying
4. **[Views & Materialized Views](sql/04_views_matviews/)** - Data abstraction and simplification

### Intermediate (8-12 hours)

For developers building database-backed applications.

1. Complete Beginner Path
2. **[Functions & Triggers](sql/05_functions_triggers/)** - Business logic automation with PL/pgSQL
3. **[JSONB & Full-Text](sql/06_jsonb_fulltext/)** - Modern data patterns and search
4. **[Geospatial](sql/07_geospatial/)** - PostGIS and location analytics
5. **[Partitioning & Timeseries](sql/08_partitioning_timeseries/)** - Scaling strategies
6. **[Data Movement](sql/09_data_movement/)** - COPY operations and foreign data wrappers

### Advanced (15+ hours)

For database administrators and system architects.

1. Complete Intermediate Path
2. **[Transactions & MVCC](sql/10_tx_mvcc_locks/)** - Concurrency control and isolation
3. **[Performance Tuning](sql/11_perf_tuning/)** - Query optimization and statistics
4. **[Security & RLS](sql/12_security_rls/)** - Multi-tenant security patterns
5. **[Backup & Replication](sql/13_backup_replication/)** - High availability and disaster recovery
6. **[Async Patterns](sql/14_async_patterns/)** - LISTEN/NOTIFY, advisory locks, and scheduling
7. **[Testing & Quality](sql/15_testing_quality/)** - Data validation and regression testing
8. **[Capstone Projects](sql/16_capstones/)** - Real-world analytical scenarios

## Project Architecture

```
postgres-polaris/
├── docker/                    # Complete containerized environment
│   ├── docker-compose.yml     # Multi-service orchestration
│   ├── Dockerfile             # Custom PostgreSQL with extensions
│   ├── initdb/               # Database initialization scripts
│   └── pgadmin_servers.json  # Pre-configured admin interface
├── sql/                      # Progressive learning modules (16 total)
│   ├── 00_init/             # Database initialization and setup
│   ├── 01_schema_design/    # Urban data modeling foundations
│   ├── 02_constraints_indexes/ # Data integrity and performance
│   ├── 03_dml_queries/      # Advanced querying techniques
│   ├── 04_views_matviews/   # Data abstraction layers
│   ├── 05_functions_triggers/ # Business logic automation
│   ├── 06_jsonb_fulltext/   # Document storage and search
│   ├── 07_geospatial/       # PostGIS spatial analysis
│   ├── 08_partitioning_timeseries/ # Scaling and time-based data
│   ├── 09_data_movement/    # ETL and data integration
│   ├── 10_tx_mvcc_locks/    # Concurrency and isolation
│   ├── 11_perf_tuning/      # Query optimization mastery
│   ├── 12_security_rls/     # Multi-tenant security
│   ├── 13_backup_replication/ # High availability patterns
│   ├── 14_async_patterns/   # Event-driven architectures
│   ├── 15_testing_quality/  # Data validation and testing
│   └── 16_capstones/        # Applied analytical projects
├── data/                    # Urban simulation datasets
│   ├── boundaries.geojson   # Geographic boundary data
│   ├── documents.jsonb      # Sample document collections
│   ├── seeds.csv           # Demographic and commercial data
│   └── timeseries.csv      # Mobility and sensor data
├── docs/                   # Comprehensive documentation
│   ├── HOWTO_SETUP.md      # Detailed installation guide
│   ├── LEARNING_PATHS.md   # Role-based learning recommendations
│   ├── MODULE_MAP_EXERCISES.md # Exercise solutions and explanations
│   ├── EXPLAIN_PLAN_LIBRARY.md # Query optimization reference
│   └── TROUBLESHOOTING.md  # Common issues and solutions
├── examples/               # Ready-to-run demonstrations
│   ├── quick_demo.sql      # 10-minute introduction
│   ├── analytics_showcase.sql # Business intelligence patterns
│   ├── geospatial_showcase.sql # Location analysis examples
│   ├── performance_tuning_showcase.sql # Optimization techniques
│   └── security_showcase.sql # Multi-tenant security demos
├── scripts/                # Automation and utilities
│   ├── load_sample_data.sh # Data loading automation
│   ├── backup_demo.sh      # Backup and restore examples
│   ├── reset_db.sh         # Environment reset utility
│   └── run_sql.sh          # Batch SQL execution
└── tests/                  # Validation and benchmarks
    ├── schema_validation.sql # Structure integrity tests
    ├── data_integrity_checks.sql # Data quality validation
    ├── performance_benchmarks.sql # Performance regression tests
    └── regression_tests.sql # Functional regression suite
```

## Core Features

**Realistic Urban Simulation**

- Complete city ecosystem with interconnected data domains
- 10,000+ citizens with demographic diversity and lifecycle events
- Commerce network including merchants, orders, and supply chains
- Transit system with real-time operations and capacity management
- Geographic data with neighborhood boundaries and spatial relationships

**Progressive Learning Architecture**

- 16 comprehensive modules building from basics to expert-level patterns
- Each module includes theory, practical exercises, and real-world applications
- Detailed solutions with performance analysis and optimization techniques
- Capstone projects integrating multiple advanced concepts

**Production-Ready Patterns**

- Enterprise security models including row-level security and audit trails
- High-availability configurations with replication and backup strategies
- Performance optimization techniques used in large-scale deployments
- Data quality frameworks with automated monitoring and validation

**Modern PostgreSQL Stack**

- Latest PostgreSQL features including advanced indexing and parallel processing
- PostGIS for comprehensive geospatial analysis and routing
- Full-text search with custom configurations and ranking
- JSONB document storage with validation and advanced querying

## Urban Dataset Details

**Civics Schema (Government Operations)**

- **Citizens**: 10,000+ individuals with demographics, addresses, and registration history
- **Permit Applications**: Construction, business, and event permits with approval workflows
- **Tax Records**: Property assessments, payment history, and compliance tracking
- **Voting Records**: Election participation and ballot preferences (anonymized)
- **Property Ownership**: Real estate transactions and zoning classifications

**Commerce Schema (Economic Activity)**

- **Merchants**: Business directories with licenses, categories, and operational status
- **Orders**: Transaction processing with payment methods and fulfillment tracking
- **Inventory**: Product catalogs with pricing, availability, and supplier relationships
- **Customer Analytics**: Purchase patterns, loyalty metrics, and segmentation data
- **Supply Chain**: Vendor relationships and logistics tracking

**Mobility Schema (Transportation Network)**

- **Transit Routes**: Bus and rail lines with schedules and capacity specifications
- **Trip Records**: Real-time operational data with delays and passenger counts
- **Station Management**: Facility maintenance, accessibility, and usage statistics
- **Sensor Data**: Traffic monitoring, environmental conditions, and infrastructure health
- **Routing Analysis**: Optimal path calculation and network optimization

**Geographic Schema (Spatial Infrastructure)**

- **Neighborhood Boundaries**: Political districts and community areas with PostGIS polygons
- **Road Networks**: Street layouts with intersection data and traffic classifications
- **Points of Interest**: Schools, hospitals, parks, and commercial centers
- **Zoning Data**: Land use classifications and development restrictions
- **Environmental Layers**: Flood zones, green spaces, and conservation areas

**Document Schema (Information Management)**

- **Citizen Complaints**: Service requests with categorization and resolution tracking
- **Policy Documents**: Regulations and procedures with full-text search capabilities
- **Meeting Minutes**: Government proceedings with agenda tracking and decision logs
- **Audit Trails**: System changes and user activities with temporal tracking
- **Metadata Systems**: Document classification and relationship management

## Available Commands

```bash
# Environment Management
make bootstrap     # Complete initial setup with dependency checks
make up           # Start all Docker services (PostgreSQL, Adminer, monitoring)
make down         # Graceful shutdown of all containers
make restart      # Full restart cycle for configuration changes
make status       # Display service health and connection information

# Database Operations
make psql         # Interactive PostgreSQL client connection
make reset        # Reset database to clean initial state with sample data
make backup       # Create timestamped database backup
make restore      # Restore from most recent backup file

# Development Workflow
make test         # Run comprehensive validation suite (schema, data, performance)
make bench        # Execute performance benchmarks with timing analysis
make lint         # Validate SQL code style and best practices
make docs         # Generate documentation from code comments

# Data Management
make sample-data  # Regenerate realistic sample dataset
make load-data    # Load additional datasets from data/ directory
make export-data  # Export current data for external analysis
make import-csv   # Bulk import CSV files with automatic schema detection

# Monitoring and Analysis
make logs         # Display aggregated service logs
make stats        # Database statistics and performance metrics
make explain      # Run EXPLAIN ANALYZE on sample queries
make monitor      # Start real-time performance monitoring dashboard
```

## Quick Start Examples

**Urban Analytics Query**

```sql
-- Neighborhood economic analysis with spatial joins
WITH neighborhood_commerce AS (
    SELECT
        n.name as neighborhood,
        COUNT(DISTINCT m.merchant_id) as total_merchants,
        COUNT(DISTINCT o.order_id) as total_orders,
        SUM(o.total_amount) as total_revenue,
        AVG(o.total_amount) as avg_order_value,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY o.total_amount) as median_order_value
    FROM geography.neighborhoods n
    LEFT JOIN commerce.merchants m ON ST_Contains(n.boundary, m.location)
    LEFT JOIN commerce.orders o ON m.merchant_id = o.merchant_id
    WHERE o.order_date >= CURRENT_DATE - INTERVAL '1 year'
    GROUP BY n.neighborhood_id, n.name
),
demographic_context AS (
    SELECT
        n.name as neighborhood,
        COUNT(c.citizen_id) as population,
        AVG(EXTRACT(YEAR FROM age(c.date_of_birth))) as avg_age,
        AVG(c.annual_income) as avg_income,
        COUNT(*) FILTER (WHERE c.employment_status = 'employed') * 100.0 / COUNT(*) as employment_rate
    FROM geography.neighborhoods n
    LEFT JOIN civics.citizens c ON ST_Contains(n.boundary, ST_Point(c.longitude, c.latitude))
    GROUP BY n.neighborhood_id, n.name
)
SELECT
    nc.neighborhood,
    nc.total_merchants,
    nc.total_orders,
    ROUND(nc.total_revenue::NUMERIC, 2) as total_revenue,
    ROUND(nc.avg_order_value::NUMERIC, 2) as avg_order_value,
    dc.population,
    ROUND(dc.avg_income::NUMERIC, 2) as avg_income,
    ROUND(dc.employment_rate::NUMERIC, 1) as employment_rate_pct,
    ROUND((nc.total_revenue / NULLIF(dc.population, 0))::NUMERIC, 2) as revenue_per_capita
FROM neighborhood_commerce nc
JOIN demographic_context dc ON nc.neighborhood = dc.neighborhood
WHERE nc.total_orders > 0
ORDER BY revenue_per_capita DESC;
```

**Real-Time Transit Performance Monitoring**

```sql
-- Advanced transit delay analysis with predictive indicators
WITH route_performance AS (
    SELECT
        t.route_id,
        t.trip_date::DATE as service_date,
        COUNT(*) as total_trips,
        AVG(t.delay_minutes) as avg_delay,
        STDDEV(t.delay_minutes) as delay_variance,
        COUNT(*) FILTER (WHERE t.delay_minutes > 5) as delayed_trips,
        COUNT(*) FILTER (WHERE t.delay_minutes > 15) as severely_delayed_trips,
        MAX(t.delay_minutes) as max_delay
    FROM mobility.trips t
    WHERE t.trip_date >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY t.route_id, t.trip_date::DATE
),
service_reliability AS (
    SELECT
        route_id,
        AVG(avg_delay) as monthly_avg_delay,
        AVG(delayed_trips::NUMERIC / total_trips) * 100 as on_time_performance,
        CORR(extract(dow from service_date), avg_delay) as weekday_delay_correlation,
        COUNT(*) FILTER (WHERE avg_delay > 10) as problem_days
    FROM route_performance
    GROUP BY route_id
),
current_status AS (
    SELECT
        t.route_id,
        COUNT(*) as current_active_trips,
        AVG(t.delay_minutes) as current_avg_delay,
        COUNT(*) FILTER (WHERE t.delay_minutes > 10) as current_delayed_trips
    FROM mobility.trips t
    WHERE t.scheduled_arrival >= NOW() - INTERVAL '2 hours'
    AND t.scheduled_arrival <= NOW() + INTERVAL '2 hours'
    GROUP BY t.route_id
)
SELECT
    sr.route_id,
    ROUND(sr.monthly_avg_delay::NUMERIC, 2) as monthly_avg_delay_min,
    ROUND(sr.on_time_performance::NUMERIC, 1) as on_time_performance_pct,
    sr.problem_days as poor_performance_days,
    cs.current_active_trips,
    ROUND(cs.current_avg_delay::NUMERIC, 2) as current_avg_delay_min,
    cs.current_delayed_trips,
    CASE
        WHEN sr.on_time_performance < 70 THEN 'CRITICAL'
        WHEN sr.on_time_performance < 85 THEN 'NEEDS_ATTENTION'
        WHEN sr.on_time_performance < 95 THEN 'GOOD'
        ELSE 'EXCELLENT'
    END as service_grade,
    CASE
        WHEN cs.current_avg_delay > sr.monthly_avg_delay * 1.5 THEN 'DEGRADED'
        WHEN cs.current_avg_delay > sr.monthly_avg_delay * 1.2 THEN 'WATCH'
        ELSE 'NORMAL'
    END as current_status
FROM service_reliability sr
LEFT JOIN current_status cs ON sr.route_id = cs.route_id
ORDER BY sr.on_time_performance ASC, sr.monthly_avg_delay DESC;
```

## Comprehensive Learning Objectives

**Database Architecture Mastery**

- Relational schema design with proper normalization and denormalization strategies
- Constraint implementation for data integrity and business rule enforcement
- Index design for optimal query performance across diverse workloads
- Partitioning strategies for horizontal scaling and maintenance efficiency

**Advanced SQL Proficiency**

- Complex analytical queries using window functions and common table expressions
- Recursive queries for hierarchical data and graph traversal problems
- Advanced aggregation techniques including ROLLUP, CUBE, and custom aggregates
- Query optimization techniques with EXPLAIN plan analysis and statistics management

**Modern PostgreSQL Features**

- JSONB document modeling with validation schemas and advanced indexing
- Full-text search implementation with custom configurations and ranking algorithms
- Array and range data types with specialized operators and indexing strategies
- Advanced data types including network addresses, geometric shapes, and custom types

**Geospatial Analysis Expertise**

- PostGIS installation, configuration, and spatial data type management
- Spatial indexing strategies (GiST, SP-GiST) for optimal geographic query performance
- Complex spatial analysis including buffer operations, intersection analysis, and routing
- Integration of geographic data with business intelligence and analytical workflows

**Enterprise Performance Optimization**

- Query performance analysis using EXPLAIN, EXPLAIN ANALYZE, and pg_stat_statements
- Index optimization including partial indexes, expression indexes, and covering indexes
- Database statistics management and automatic vacuum configuration
- Connection pooling and resource management for high-concurrency applications

**Production Security Implementation**

- Row-level security policies for multi-tenant applications and data isolation
- Authentication and authorization patterns including role-based access control
- Data encryption at rest and in transit with proper key management
- Audit logging and compliance frameworks for regulatory requirements

**High Availability and Disaster Recovery**

- Streaming replication configuration for read replicas and failover scenarios
- Point-in-time recovery implementation with WAL archiving and restoration
- Logical replication for selective data synchronization and migration strategies
- Backup strategies including pg_dump, pg_basebackup, and continuous archiving

**Operational Excellence**

- Database monitoring with built-in statistics views and external tools integration
- Automated maintenance tasks using pg_cron and custom scheduling frameworks
- Performance regression testing and benchmark development
- Capacity planning and resource allocation for growth scenarios

## System Requirements and Setup

**Minimum System Requirements**

- **Operating System**: Docker-compatible platform (Linux, macOS, Windows with WSL2)
- **Docker**: Version 20.10.0 or higher with Docker Compose 2.0+
- **Memory**: 4GB RAM available for container allocation
- **Storage**: 10GB free disk space for data, logs, and temporary files
- **Network**: Internet connectivity for initial setup and extension downloads

**Recommended Development Environment**

- **Memory**: 8GB+ RAM for optimal performance during complex analytical queries
- **Storage**: SSD storage for improved I/O performance during data loading operations
- **CPU**: Multi-core processor for parallel query execution and concurrent user scenarios
- **Network**: Stable broadband connection for documentation and community resource access

**Production Deployment Considerations**

- **Scaling**: Container orchestration support (Kubernetes, Docker Swarm) for production deployment
- **Monitoring**: Integration points for Prometheus, Grafana, and other monitoring solutions
- **Security**: Network isolation and firewall configuration for production security
- **Backup**: External storage integration for automated backup and archival processes

## Contributing and Community

**Contribution Workflow**
We welcome contributions that enhance the learning experience and expand the curriculum:

1. **Fork and Branch**: Create your own fork and feature branch for development
2. **Quality Standards**: Ensure all new content includes comprehensive documentation and testing
3. **Code Review**: Submit detailed pull requests with clear descriptions of changes and improvements
4. **Testing**: Add validation tests for new exercises and verify existing functionality remains intact

**Content Guidelines**

- **Exercise Design**: All new exercises must include problem statements, solution explanations, and performance analysis
- **SQL Style**: Follow established coding conventions for readability and maintainability
- **Documentation**: Update relevant documentation files when adding new modules or changing existing functionality
- **Performance**: Include EXPLAIN output and optimization discussion for complex queries

**Community Resources and Support**

- **GitHub Issues**: Report bugs, request features, and discuss enhancements with the development community
- **Documentation**: Comprehensive guides for setup, troubleshooting, and advanced configuration scenarios
- **Examples Gallery**: Showcase of student projects and real-world implementations using PostgreSQL Polaris
- **Discussion Forum**: Community-driven support for learning questions and technical discussions

## License and Acknowledgments

**Open Source License**
This project is released under the MIT License, allowing for both educational and commercial use with proper attribution. See the [LICENSE](LICENSE) file for complete terms and conditions.

**Community Acknowledgments**
PostgreSQL Polaris builds upon the outstanding work of the global PostgreSQL community. Special recognition goes to:

- **PostgreSQL Global Development Group** for creating and maintaining the world's most advanced open source database
- **PostGIS Development Team** for enabling sophisticated geospatial analysis capabilities
- **PostgreSQL Community** for extensive documentation, tutorials, and best practice sharing
- **Contributors and Educators** who have shared knowledge and improved database education worldwide

---

## Ready to Begin Your PostgreSQL Journey?

**Quick Setup Commands**

```bash
git clone https://github.com/SatvikPraveen/postgres-polaris.git
cd postgres-polaris
make bootstrap && make up
```

**Access Points**

- **Database Console**: `make psql` for direct PostgreSQL command line access
- **Web Interface**: Visit http://localhost:8080 for Adminer database administration
- **Documentation**: Browse the `docs/` directory for comprehensive learning guides
- **Quick Demo**: Run `examples/quick_demo.sql` for a 10-minute introduction to key concepts

**Next Steps**

1. Review the [Setup Guide](docs/HOWTO_SETUP.md) for detailed installation instructions
2. Choose your [Learning Path](docs/LEARNING_PATHS.md) based on your current experience level
3. Start with [Module 01: Schema Design](sql/01_schema_design/) to understand the urban data model
4. Join our community discussions and share your learning progress

Transform your PostgreSQL expertise from beginner to advanced practitioner with hands-on experience using realistic, complex datasets that mirror real-world analytical challenges.
