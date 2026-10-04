#!/usr/bin/env bash
# (Re)build a database from scratch: extensions, schemas, constraints and the
# synthetic dataset for a given scale and seed.
#
#   scripts/build_db.sh                       # polaris, scale 1, seed 42
#   scripts/build_db.sh -s 5 -r 7 -d city5    # scale 5, seed 7, into db city5
#   scripts/build_db.sh -m                    # also run every module 02-16
#
# Rebuilding the main 'polaris' database regenerates data in place (pg_cron's
# background worker keeps it connected, so it cannot be dropped).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

db="$POLARIS_DB"; scale="${POLARIS_SCALE:-1}"; seed="${POLARIS_SEED:-42}"; modules=()
while getopts ":d:s:r:mh" opt; do
    case "$opt" in
        d) db="$OPTARG" ;;
        s) scale="$OPTARG" ;;
        r) seed="$OPTARG" ;;
        m) modules=(-v modules=1) ;;
        h) sed -n '2,11p' "$0"; exit 0 ;;
        *) die "unknown option -$OPTARG" ;;
    esac
done
[[ "$scale" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "scale must be a positive number"
[[ "$seed"  =~ ^[0-9]+$ ]]            || die "seed must be a non-negative integer"

require_container
if [[ "$db" != "$POLARIS_DB" ]]; then
    log "creating database '$db'"
    recreate_db "$db"
fi
log "building '$db' (scale=$scale seed=$seed)"
start=$(date +%s)
docker exec -i -w /sql "$POLARIS_CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$POLARIS_USER" -d "$db" \
    -v scale="$scale" -v seed="$seed" "${modules[@]}" -f /sql/build.sql
ok "built '$db' in $(( $(date +%s) - start ))s"
