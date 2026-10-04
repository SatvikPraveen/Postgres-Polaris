#!/usr/bin/env bash
# Run one SQL file from the repo inside the database container.
#
#   scripts/run_sql.sh sql/07_geospatial/routing_nearest.sql
#   scripts/run_sql.sh -d polaris_test -t examples/quick_demo.sql
#
#   -d DB     target database (default: $POSTGRES_DB or polaris)
#   -t        print per-statement timing
#   -e        echo each statement before running it
#   -1        wrap the file in a single transaction
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

db="$POLARIS_DB"; extra=()
while getopts ":d:te1h" opt; do
    case "$opt" in
        d) db="$OPTARG" ;;
        t) extra+=(-c '\timing on') ;;
        e) extra+=(--echo-queries) ;;
        1) extra+=(--single-transaction) ;;
        h) sed -n '2,11p' "$0"; exit 0 ;;
        *) die "unknown option -$OPTARG" ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || die "usage: $0 [-d db] [-t] [-e] [-1] <file.sql>"
[[ -f "$1" ]] || die "no such file: $1"

require_container
target="$(container_path "$1")"
log "running $1 on database '$db'"
start=$(date +%s)
docker exec -i "$POLARIS_CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$POLARIS_USER" -d "$db" ${extra[@]+"${extra[@]}"} -f "$target"
ok "$1 finished in $(( $(date +%s) - start ))s"
