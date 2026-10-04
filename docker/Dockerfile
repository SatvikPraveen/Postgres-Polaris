# syntax=docker/dockerfile:1.7
# PostgreSQL Polaris image
#
# Built on the official multi-arch postgres image (linux/amd64 + linux/arm64)
# with PostGIS and the extension set used across the curriculum installed
# from the PGDG apt repository that the base image already configures.
#
#   docker build --build-arg PG_MAJOR=17 -t polaris-db .
#
# Supported PG_MAJOR values: 17, 18 (CI tests both). Modules use PG 17
# features (JSON_TABLE, MERGE ... RETURNING, COPY ON_ERROR, EXPLAIN SERIALIZE).

ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-bookworm

ARG PG_MAJOR
ARG POSTGIS_MAJOR=3

LABEL org.opencontainers.image.title="PostgreSQL Polaris" \
      org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} + PostGIS ${POSTGIS_MAJOR} with pg_cron, pg_partman, pgTAP, HypoPG, pgvector" \
      org.opencontainers.image.source="https://github.com/SatvikPraveen/Postgres-Polaris" \
      org.opencontainers.image.licenses="MIT"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR} \
        postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR}-scripts \
        postgresql-${PG_MAJOR}-cron \
        postgresql-${PG_MAJOR}-partman \
        postgresql-${PG_MAJOR}-pgtap \
        postgresql-${PG_MAJOR}-hypopg \
        postgresql-${PG_MAJOR}-pgvector \
        postgresql-${PG_MAJOR}-pg-stat-kcache \
        libtap-parser-sourcehandler-pgtap-perl \
        ca-certificates \
        curl \
        jq \
        ; \
    rm -rf /var/lib/apt/lists/*

# Server configuration lives outside PGDATA so it is versioned with the repo
# and identical across fresh volumes. docker-compose passes
# `-c config_file=/etc/postgresql/postgresql.conf`.
COPY conf/postgresql.conf /etc/postgresql/postgresql.conf

# First-boot initialisation (only runs when the data volume is empty).
COPY initdb/ /docker-entrypoint-initdb.d/

# Mount points for the curriculum (read-only bind mounts in compose).
RUN mkdir -p /sql /data /tests /examples /benchmarks \
    && chown postgres:postgres /sql /data /tests /examples /benchmarks

ENV PG_MAJOR=${PG_MAJOR}
EXPOSE 5432
