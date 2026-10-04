#!/usr/bin/env bash
# First-boot initialisation, step 4: build the curriculum schema and load
# the synthetic dataset so `make up` yields a ready-to-query database.
# Set POLARIS_SKIP_BOOTSTRAP=1 to start from an empty database instead.
set -euo pipefail

if [[ "${POLARIS_SKIP_BOOTSTRAP:-0}" == "1" ]]; then
    echo "polaris: POLARIS_SKIP_BOOTSTRAP=1, leaving database empty"
    exit 0
fi

if [[ ! -f /sql/build.sql ]]; then
    echo "polaris: /sql not mounted, skipping curriculum bootstrap"
    exit 0
fi

cd /sql
psql -v ON_ERROR_STOP=1 --no-psqlrc \
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     -v scale="${POLARIS_SCALE:-1}" -v seed="${POLARIS_SEED:-0.42}" \
     -f build.sql
