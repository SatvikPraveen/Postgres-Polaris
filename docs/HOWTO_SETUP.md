# Setup Guide - PostgreSQL Polaris

**Location**: `/docs/HOWTO_SETUP.md`

Complete setup instructions for getting PostgreSQL Polaris running locally.

## 🚀 Quick Setup (5 minutes)

### Prerequisites

- Docker & Docker Compose
- Git
- Make (optional but recommended)

### One-Command Setup

```bash
git clone <your-repo> && cd postgres-polaris
make bootstrap && make up
```

That's it! Your environment is ready:

- **Database**: `localhost:5432`
- **Adminer UI**: http://localhost:8080
- **Connect**: `make psql`

## 📋 Detailed Setup Instructions

### Step 1: Clone Repository

```bash
git clone <your-repository-url>
cd postgres-polaris
```

### Step 2: Environment Configuration

```bash
# Copy environment templates
cp .env.example .env
cp docker/.env.example docker/.env

# Optional: Customize settings
nano .env  # or your preferred editor
```

### Step 3: Docker Setup

```bash
# Pull required images
docker-compose -f docker/docker-compose.yml pull

# Start services
docker-compose -f docker/docker-compose.yml up -d

# Wait for initialization (first startup takes ~30 seconds)
docker logs polaris-db -f  # Watch startup logs
```

### Step 4: Verify Installation

```bash
# Check container status
docker ps

# Test database connection
docker exec -it polaris-db psql -U polaris -d polaris -c "SELECT version();"

# Access web interface
open http://localhost:8080  # macOS
xdg-open http://localhost:8080  # Linux
```

## 🔧 Connection Details

### Database Connection

```
Host: localhost
Port: 5432
Database: polaris
Username: polaris
Password: polar_star_2024
```

### Adminer Web Interface

- **URL**: http://localhost:8080
- **System**: PostgreSQL
- **Server**: polaris-db
- **Username**: polaris
- **Password**: polar_star_2024
- **Database**: polaris

### Direct psql Connection

```bash
# Via Docker
docker exec -it polaris-db psql -U polaris -d polaris

# Via local psql (if installed)
psql -h localhost -p 5432 -U polaris -d polaris
```

## 📊 Loading Sample Data

### Automatic Data Loading

```bash
# Load all sample datasets
make load-data

# Or manually
./scripts/load_sample_data.sh
```

### Manual Data Loading

```bash
# Connect to database
make psql

# Load specific datasets
\i sql/03_dml_queries/seed_data.sql

# Verify data loaded
SELECT COUNT(*) FROM citizens;
SELECT COUNT(*) FROM merchants;
SELECT COUNT(*) FROM orders;
```

## 🏃 First Steps

### 1. Run Quick Demo

```bash
make run-examples
# Or via Adminer: Copy/paste from examples/quick_demo.sql
```

### 2. Explore Schema

```sql
-- List all tables
\dt

-- Describe table structure
\d citizens
\d orders
\d spatial_features
```

### 3. Try Sample Queries

```sql
-- Simple query
SELECT name, city FROM citizens LIMIT 5;

-- Join query
SELECT c.name, COUNT(o.*) as order_count
FROM citizens c
LEFT JOIN orders o ON c.citizen_id = o.customer_id
GROUP BY c.citizen_id, c.name
ORDER BY order_count DESC;
```

## 🗂️ Project Structure Tour

### Key Directories

```
postgres-polaris/
├── sql/              # 15 learning modules (start here)
├── data/             # Sample urban dataset
├── docs/             # Guides and documentation
├── docker/           # Container configuration
├── scripts/          # Helper tools
├── tests/            # Validation tests
└── examples/         # Ready-to-run demos
```

### Learning Path

1. **Start**: `sql/01_schema_design/` - Data modeling basics
2. **Practice**: `sql/03_dml_queries/` - Query fundamentals
3. **Optimize**: `sql/02_constraints_indexes/` - Performance basics
4. **Advanced**: `sql/06_jsonb_fulltext/` - Modern PostgreSQL

## 🛠️ Available Commands

### Core Operations

```bash
make up              # Start environment
make down            # Stop environment
make restart         # Restart all services
make psql            # Connect to database
make logs            # View container logs
make status          # Check container status
```

### Data Management

```bash
make reset           # Reset database (destroys data!)
make load-data       # Load sample data
make backup          # Create backup
```

### Module Execution

```bash
make run-module MODULE=01_schema_design/civics.sql
make run-init        # Run initialization scripts
make run-examples    # Run demo examples
```

### Testing

```bash
make test            # Run all validation tests
make test-schema     # Validate table structure
make test-data       # Check data integrity
make bench           # Performance benchmarks
```

## 🐛 Troubleshooting

### Common Issues

#### Port Already in Use

```bash
# Check what's using port 5432
lsof -i :5432
netstat -tulpn | grep 5432

# Solution: Change port in docker/.env
POSTGRES_PORT=5433
ADMINER_PORT=8081
```

#### Container Won't Start

```bash
# Check Docker daemon
docker info

# Clean up old containers/volumes
docker system prune -a
docker volume prune

# Rebuild from scratch
make clean && make bootstrap && make up
```

#### Database Connection Failed

```bash
# Check container logs
docker logs polaris-db

# Verify container is running
docker ps | grep polaris

# Test network connectivity
docker exec -it polaris-db ping polaris-adminer
```

#### Permission Errors

```bash
# Fix file permissions
sudo chown -R $USER:$USER .
chmod +x scripts/*.sh

# Docker socket permissions (Linux)
sudo usermod -a -G docker $USER
# Log out and back in
```

### Getting Help

#### Check Logs

```bash
# Database logs
docker logs polaris-db -f

# All services
docker-compose -f docker/docker-compose.yml logs -f

# Specific timeframe
docker logs polaris-db --since=10m
```

#### Database Diagnostics

```sql
-- Check database status
SELECT version();
SELECT current_database();
SELECT current_user;

-- Check loaded extensions
SELECT * FROM pg_extension;

-- Monitor connections
SELECT * FROM pg_stat_activity;
```

## 🔄 Updating and Maintenance

### Update Project

```bash
git pull origin main
make down
docker-compose -f docker/docker-compose.yml pull
make up
```

### Regular Maintenance

```bash
# Weekly cleanup
make clean

# Monthly full reset (lose all data)
make reset

# Backup before major changes
make backup
```

### Performance Tuning

```bash
# Monitor resource usage
docker stats polaris-db

# Check database performance
make psql
\x
SELECT * FROM pg_stat_database WHERE datname='polaris';
```

## 🎯 Next Steps

1. **Start Learning**: Visit [Learning Paths](LEARNING_PATHS.md)
2. **Explore Modules**: Check [Module Exercises](MODULE_MAP_EXERCISES.md)
3. **Run Examples**: Try the showcase demos in `examples/`
4. **Build Projects**: Work on capstone projects in `sql/99_capstones/`

## 💡 Pro Tips

- **Use Adminer** for visual query building and data exploration
- **Bookmark queries** in Adminer for repeated use
- **Enable query logging** to see all executed SQL
- **Use transactions** when experimenting with data changes
- **Save interesting queries** in personal files for reference

---

**Need Help?** Check [Troubleshooting Guide](TROUBLESHOOTING.md) or open an issue on GitHub.
