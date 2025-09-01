# Troubleshooting Guide - PostgreSQL Polaris

**Location**: `/docs/TROUBLESHOOTING.md`

Common issues and solutions for PostgreSQL Polaris learning environment.

## 🆘 Quick Problem Resolution

### Emergency Commands

```bash
# Complete reset (nuclear option)
make clean && make bootstrap && make up

# Check status
make status && docker logs polaris-db --tail=50

# Force restart
make down && sleep 5 && make up
```

## 🐳 Docker & Container Issues

### Container Won't Start

**Symptoms**: `docker-compose up` fails or containers exit immediately

**Diagnosis**:

```bash
# Check container status
docker ps -a | grep polaris

# Check logs for errors
docker logs polaris-db
docker logs polaris-adminer

# Verify Docker daemon
docker info
```

**Common Solutions**:

1. **Port Conflicts**:

```bash
# Check what's using PostgreSQL port
lsof -i :5432
netstat -tulpn | grep 5432

# Solution: Change port in docker/.env
POSTGRES_PORT=5433
ADMINER_PORT=8081
```

2. **Permission Issues**:

```bash
# Fix file permissions
sudo chown -R $USER:$USER .
chmod +x scripts/*.sh

# Docker socket permissions (Linux)
sudo usermod -a -G docker $USER
# Log out and back in
```

3. **Insufficient Resources**:

```bash
# Check Docker resources
docker system df
docker system prune -f

# Increase Docker memory (Docker Desktop)
# Settings > Resources > Memory: 4GB+
```

4. **Volume Mount Issues**:

```bash
# Clean volumes
docker volume prune
docker-compose -f docker/docker-compose.yml down -v

# Rebuild completely
make clean && make bootstrap && make up
```

### Database Initialization Fails

**Symptoms**: Container starts but database unreachable

**Diagnosis**:

```bash
# Check initialization progress
docker logs polaris-db -f

# Test connection
docker exec -it polaris-db pg_isready -U polaris

# Check processes in container
docker exec -it polaris-db ps aux
```

**Solutions**:

1. **Slow Initialization**:

```bash
# Wait longer (first startup can take 60+ seconds)
sleep 60 && make psql

# Check if extensions are loading
docker logs polaris-db | grep -i "extension\|error"
```

2. **Extension Loading Fails**:

```bash
# Check PostGIS availability
docker exec -it polaris-db psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS postgis;"

# Manual extension installation
docker exec -it polaris-db apt-get update && apt-get install -y postgresql-14-postgis-3
```

3. **Init Script Errors**:

```bash
# Check initdb logs
docker exec -it polaris-db ls -la /docker-entrypoint-initdb.d/
docker logs polaris-db | grep -i "initdb\|error"

# Manual script execution
docker exec -it polaris-db psql -U postgres -d polaris -f /docker-entrypoint-initdb.d/000_create_database.sql
```

## 🔌 Connection Problems

### Cannot Connect to Database

**Symptoms**: Connection refused, timeout, or authentication errors

**Diagnosis**:

```bash
# Test network connectivity
docker network ls
docker exec -it polaris-adminer ping polaris-db

# Check PostgreSQL status
docker exec -it polaris-db pg_ctl status -D /var/lib/postgresql/data
```

**Solutions**:

1. **Database Not Ready**:

```bash
# Wait for full startup
docker logs polaris-db | grep "database system is ready"

# Use helper command
make psql  # Handles connection details automatically
```

2. **Authentication Issues**:

```bash
# Verify credentials in docker/.env
cat docker/.env | grep POSTGRES

# Test with psql directly
docker exec -it polaris-db psql -U polaris -d polaris -c "SELECT current_user;"
```

3. **Network Issues**:

```bash
# Recreate network
docker network rm postgres-polaris_default
docker-compose -f docker/docker-compose.yml up -d
```

### Adminer Won't Load

**Symptoms**: http://localhost:8080 unreachable or shows error

**Solutions**:

```bash
# Check Adminer container
docker logs polaris-adminer

# Verify port mapping
docker port polaris-adminer

# Alternative: Use different port
# Edit docker/.env: ADMINER_PORT=8081
make restart
```

## 📊 Data Loading Issues

### Sample Data Won't Load

**Symptoms**: Empty tables or COPY command failures

**Diagnosis**:

```bash
# Check if files exist and have correct permissions
ls -la data/
docker exec -it polaris-db ls -la /data/

# Test manual data loading
make psql
\i sql/03_dml_queries/seed_data.sql
```

**Solutions**:

1. **File Permission Problems**:

```bash
# Fix permissions
chmod 644 data/*.csv data/*.json data/*.geojson

# Verify Docker can read files
docker exec -it polaris-db cat /data/seeds.csv | head -5
```

2. **CSV Format Issues**:

```bash
# Check CSV structure
head -5 data/seeds.csv
file data/seeds.csv  # Check encoding

# Manual load with error reporting
docker exec -it polaris-db psql -U polaris -d polaris -c "\COPY table FROM '/data/file.csv' WITH CSV HEADER;"
```

3. **Schema Not Ready**:

```bash
# Run initialization first
make run-init

# Then load data
make load-data
```

### JSONB/GeoJSON Import Fails

**Symptoms**: JSON parsing errors or invalid geometry

**Solutions**:

```bash
# Validate JSON format
python3 -m json.tool data/documents.jsonb
jq '.' data/boundaries.geojson  # If jq installed

# Check PostGIS extension
make psql
SELECT postgis_version();
```

## 🐌 Performance Issues

### Queries Running Slowly

**Symptoms**: Simple queries taking > 1 second

**Diagnosis**:

```sql
-- Enable timing in psql
\timing on

-- Check for sequential scans
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM citizens WHERE email = 'test@example.com';

-- Look for missing indexes
SELECT schemaname, tablename, indexname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0;
```

**Solutions**:

1. **Missing Indexes**:

```sql
-- Run constraint/index module
\i sql/02_constraints_indexes/indexing_basics.sql

-- Check index usage
\d+ table_name
```

2. **Statistics Out of Date**:

```sql
-- Update statistics
ANALYZE;

-- Check last analyze time
SELECT schemaname, tablename, last_analyze
FROM pg_stat_user_tables;
```

3. **Configuration Issues**:

```sql
-- Check memory settings
SHOW work_mem;
SHOW shared_buffers;

-- Adjust for session
SET work_mem = '256MB';
```

### High Memory Usage

**Symptoms**: Container using excessive RAM or getting OOM killed

**Solutions**:

```bash
# Monitor memory usage
docker stats polaris-db

# Reduce PostgreSQL memory settings
# Edit docker/.env:
POSTGRES_SHARED_BUFFERS=256MB
POSTGRES_EFFECTIVE_CACHE_SIZE=1GB
```

## 🔒 Permission & Security Issues

### Permission Denied Errors

**Symptoms**: Cannot create tables, access files, or run functions

**Solutions**:

```sql
-- Check current user and permissions
SELECT current_user, current_database();
\du  -- List users and roles

-- Grant necessary permissions
GRANT ALL PRIVILEGES ON DATABASE polaris TO polaris;
GRANT ALL ON ALL TABLES IN SCHEMA public TO polaris;
```

### Schema or Extension Missing

**Symptoms**: "relation does not exist" or "extension not available"

**Solutions**:

```sql
-- List available extensions
SELECT * FROM pg_available_extensions WHERE name LIKE '%postgis%';

-- Install missing extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS btree_gin;

-- Check schemas
SELECT schema_name FROM information_schema.schemata;
```

## 🔧 SQL Module Issues

### Module Scripts Failing

**Symptoms**: Syntax errors or "file not found" when running modules

**Diagnosis**:

```bash
# Check file exists
ls -la sql/01_schema_design/civics.sql

# Test file syntax
docker exec -it polaris-db psql -U polaris -d polaris --echo-all --single-transaction -f /sql/01_schema_design/civics.sql
```

**Solutions**:

1. **File Path Issues**:

```bash
# Use make command (handles paths automatically)
make run-module MODULE=01_schema_design/civics.sql

# Or full path
docker exec -it polaris-db psql -U polaris -d polaris -f /sql/01_schema_design/civics.sql
```

2. **Dependency Missing**:

```bash
# Run modules in order
make run-init  # Always run first
make run-module MODULE=01_schema_design/civics.sql
```

3. **Transaction Errors**:

```sql
-- Check for uncommitted transactions
SELECT * FROM pg_stat_activity WHERE state = 'idle in transaction';

-- Reset connections
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'polaris' AND pid != pg_backend_pid();
```

### Geospatial Queries Failing

**Symptoms**: "function st_contains does not exist"

**Solutions**:

```sql
-- Install PostGIS
CREATE EXTENSION IF NOT EXISTS postgis;

-- Check PostGIS installation
SELECT postgis_version();

-- Load spatial data
\i sql/01_schema_design/geo.sql
```

## 🧪 Testing & Validation Issues

### Tests Failing

**Symptoms**: `make test` reports failures

**Diagnosis**:

```bash
# Run individual test modules
make test-schema
make test-data

# Check specific test output
./scripts/run_sql.sh tests/schema_validation.sql
```

**Solutions**:

1. **Schema Not Ready**:

```bash
# Initialize properly
make run-init
make schema  # Run schema modules

# Then test
make test-schema
```

2. **Data Missing**:

```bash
# Load sample data first
make load-data

# Then run data tests
make test-data
```

## 🚨 Emergency Recovery

### Database Corrupted

**Symptoms**: Consistent crashes, data inconsistency

**Nuclear Option**:

```bash
# Complete clean slate
make down
docker volume rm $(docker volume ls -q | grep polaris)
docker system prune -a
make bootstrap && make up
```

### System Completely Broken

**Last Resort**:

```bash
# Uninstall everything
docker-compose -f docker/docker-compose.yml down -v --remove-orphans --rmi all
docker system prune -a -f
docker volume prune -f

# Start over
git clean -fdx  # WARNING: Removes all untracked files
git reset --hard HEAD
make bootstrap && make up
```

## 📞 Getting Help

### Collect Debug Information

```bash
# System information
uname -a
docker --version
docker-compose --version

# Container status
make status
docker ps -a

# Recent logs
docker logs polaris-db --since=10m > debug_logs.txt
docker logs polaris-adminer --since=10m >> debug_logs.txt

# Database status
make psql -c "
SELECT version();
SELECT name, setting FROM pg_settings WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem');
SELECT count(*) as active_connections FROM pg_stat_activity;
"
```

### Common Log Messages

**Normal Startup Messages** (ignore these):

```
PostgreSQL init process complete; ready for start up.
database system is ready to accept connections
```

**Warning Messages** (usually safe to ignore):

```
NOTICE: extension "postgis" already exists, skipping
WARNING: could not flush dirty data: Function not implemented
```

**Error Messages** (need attention):

```
FATAL: password authentication failed
ERROR: column "xyz" does not exist
PANIC: could not write to file
```

## 🎯 Prevention Tips

### Best Practices

1. **Always run `make run-init` first** when setting up
2. **Use `make` commands** instead of direct docker commands
3. **Check logs** before reporting issues
4. **Test with small datasets** before scaling up
5. **Keep backups** of any custom modifications

### Regular Maintenance

```bash
# Weekly
make test  # Validate system health
make bench  # Check performance baselines

# After major changes
make backup  # Save current state

# If experimenting
# Work in transactions with BEGIN/ROLLBACK
```

---

**Still Having Issues?**

1. Check the logs with specific error messages
2. Search existing GitHub issues
3. Open a new issue with debug information
4. Join the community forum for help
