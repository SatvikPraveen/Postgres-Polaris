#!/usr/bin/env bash
# Verify that every curriculum module is standalone and idempotent:
# each file runs twice, with ON_ERROR_STOP, on its own fresh copy of the
# base dataset. Prints a summary table; exits non-zero if any module fails.
#
#   scripts/check_modules.sh                    # all modules
#   scripts/check_modules.sh sql/07_geospatial  # one directory or file
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_container

template=polaris_ci_template
logdir="$POLARIS_ROOT/.check_logs"; mkdir -p "$logdir"

targets=("${@:-sql}")
files=()
for t in "${targets[@]}"; do
    if [[ -d "$t" ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(
            find "$t" -name '*.sql' -path '*/[01][0-9]_*/*' \
                 ! -path '*/00_init/*' ! -path '*/01_schema_design/*' \
                 ! -name constraints.sql ! -name seed_data.sql | sort)
    else
        files+=("$t")
    fi
done
[[ ${#files[@]} -gt 0 ]] || die "no module files found"

log "building template database '$template'"
psql_in postgres -c "ALTER DATABASE \"$template\" WITH IS_TEMPLATE false" >/dev/null 2>&1 || true
recreate_db "$template"
docker exec -i -w /sql "$POLARIS_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$POLARIS_USER" -d "$template" \
    -v scale=1 -v seed=42 -f /sql/build.sql >"$logdir/_template.log" 2>&1 || die "template build failed (see $logdir/_template.log)"
psql_in postgres -c "ALTER DATABASE \"$template\" WITH IS_TEMPLATE true ALLOW_CONNECTIONS false" >/dev/null

pass=0; fail=0; results=()
for f in "${files[@]}"; do
    name="$(echo "${f#sql/}" | tr '/.' '__')"
    db="chk_${name:0:50}"
    recreate_db "$db" "$template"
    status=PASS; t0=$(date +%s)
    for run in 1 2; do
        if ! psql_in "$db" -f "$(container_path "$f")" >"$logdir/$name.run$run.log" 2>&1; then
            status="FAIL(run $run)"; break
        fi
    done
    secs=$(( $(date +%s) - t0 ))
    drop_db "$db"
    if [[ $status == PASS ]]; then pass=$((pass + 1)); ok "$f (${secs}s)"
    else fail=$((fail + 1)); warn "$f $status -> $(grep -m1 ERROR "$logdir/$name".run*.log | cut -c1-160)"; fi
    results+=("$(printf '%-62s %-12s %4ss' "$f" "$status" "$secs")")
done

psql_in postgres -c "ALTER DATABASE \"$template\" WITH IS_TEMPLATE false" >/dev/null
drop_db "$template"

printf '\n%-62s %-12s %5s\n' MODULE STATUS TIME
printf '%s\n' "${results[@]}"
printf '\n%d passed, %d failed (logs in %s)\n' "$pass" "$fail" "${logdir#"$POLARIS_ROOT"/}"
[[ $fail -eq 0 ]]
