#!/usr/bin/env bash
# Shared helpers for Polaris scripts. Source, do not execute.
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts
# Every script talks to the database through `docker exec` so the host only
# needs Docker; psql, pg_dump and pg_prove run inside the container.

set -euo pipefail

POLARIS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load docker/.env then .env (later wins) without overriding the caller's env.
for f in "$POLARIS_ROOT/docker/.env" "$POLARIS_ROOT/.env"; do
    if [[ -f "$f" ]]; then
        while IFS='=' read -r k v; do
            [[ -z "$k" || "$k" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${!k:-}" ]] && export "$k=$v"
        done < "$f"
    fi
done

POLARIS_CONTAINER="${POLARIS_CONTAINER:-polaris-db}"
POLARIS_USER="${POSTGRES_USER:-polaris}"
POLARIS_DB="${POSTGRES_DB:-polaris}"

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RST=''
fi

log()  { printf '%s[polaris]%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s[  ok  ]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[ warn ]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[ fail ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

require_container() {
    docker inspect -f '{{.State.Running}}' "$POLARIS_CONTAINER" 2>/dev/null | grep -q true \
        || die "container '$POLARIS_CONTAINER' is not running (start it with: make up)"
}

# psql_in <db> [psql args...]  -- non-interactive psql inside the container
psql_in() {
    local db="$1"; shift
    docker exec -i "$POLARIS_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$POLARIS_USER" -d "$db" "$@"
}

# Convert a repo path (sql/.., tests/.., examples/.., benchmarks/..) into the
# container's bind-mount path.
container_path() {
    local p="$1"
    p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
    p="${p#"$POLARIS_ROOT"/}"
    case "$p" in
        sql/*|tests/*|examples/*|data/*|benchmarks/*) printf '/%s' "$p" ;;
        *) die "path must live under sql/, tests/, examples/, data/ or benchmarks/: $1" ;;
    esac
}

recreate_db() {
    local db="$1" template="${2:-template0}"
    psql_in postgres -c "SET client_min_messages = warning" -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" \
                     -c "CREATE DATABASE \"$db\" TEMPLATE \"$template\"" >/dev/null
}

drop_db() {
    psql_in postgres -c "SET client_min_messages = warning" -c "DROP DATABASE IF EXISTS \"$1\" WITH (FORCE)" >/dev/null
}
