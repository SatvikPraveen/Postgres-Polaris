# File: docker/Dockerfile
# PostgreSQL with PostGIS for postgres-polaris project

FROM postgis/postgis:16-3.4

# Install additional extensions and tools
RUN apt-get update && apt-get install -y \
    postgresql-16-cron \
    postgresql-16-partman \
    postgresql-contrib-16 \
    postgresql-16-pgtap \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Copy initialization scripts
COPY initdb/ /docker-entrypoint-initdb.d/

# Create directories for SQL modules and data (read-only mounts)
RUN mkdir -p /sql /data

# Set permissions
RUN chown postgres:postgres /sql /data

# Set default database configuration
ENV POSTGRES_DB=polaris
ENV POSTGRES_USER=polaris_admin
ENV POSTGRES_PASSWORD=polaris_secure_2024
ENV POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=en_US.UTF-8"

# Configure PostgreSQL
ENV POSTGRES_HOST_AUTH_METHOD=md5
ENV POSTGRES_MULTIPLE_DATABASES=polaris,polaris_test

# Expose PostgreSQL port
EXPOSE 5432

# Health check with proper escaping
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1

# Set proper user
USER postgres
