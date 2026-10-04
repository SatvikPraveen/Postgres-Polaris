#!/usr/bin/env bash
# Reproducibility check: generate the dataset twice from the same (scale,
# seed) into two scratch databases, the second under deliberately different
# planner settings, and compare meta.fingerprint() table by table.
#
#   scripts/reproduce.sh            # scale 1, seed 42
#   scripts/reproduce.sh 2 7        # scale 2, seed 7
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_container

scale="${1:-1}"; seed="${2:-42}"
a=polaris_repro_a; b=polaris_repro_b
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; drop_db $a; drop_db $b' EXIT

build() {
    local db="$1" opts="$2"
    recreate_db "$db"
    docker exec -i -w /sql -e PGOPTIONS="$opts" "$POLARIS_CONTAINER" \
        psql -X -q -v ON_ERROR_STOP=1 -U "$POLARIS_USER" -d "$db" -v scale="$scale" -v seed="$seed" \
        -f /sql/build.sql >/dev/null
    psql_in "$db" -tA -F ' ' -c "SELECT table_name, row_count, content_md5 FROM meta.fingerprint() ORDER BY 1" >"$tmp/$db"
}

log "build A: default planner settings"
build $a ""
log "build B: nested loops only, work_mem=64kB, parallel workers forced"
build $b "-c enable_hashjoin=off -c enable_mergejoin=off -c work_mem=64kB -c debug_parallel_query=on"

printf '\n%-36s %10s  %s\n' TABLE ROWS MD5
awk '{printf "%-36s %10s  %s\n", $1, $2, $3}' "$tmp/$a"
echo
if diff -u "$tmp/$a" "$tmp/$b"; then
    ok "identical datasets: $(wc -l <"$tmp/$a" | tr -d ' ') tables, scale=$scale seed=$seed"
else
    die "datasets differ (see diff above)"
fi
