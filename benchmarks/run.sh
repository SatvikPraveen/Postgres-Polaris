#!/usr/bin/env bash
# Benchmark harness: runs every workload in benchmarks/workloads with
# pgbench across a client-count sweep, with repetitions, against a freshly
# built benchmark database, and records everything needed to reproduce or
# audit the numbers.
#
#   benchmarks/run.sh                                   # defaults below
#   CLIENTS="1 8" DURATION=20 REPS=5 benchmarks/run.sh
#   WORKLOADS="point_lookup spatial_knn" benchmarks/run.sh
#
# Output: benchmarks/results/<UTC timestamp>/
#   environment.json   server version, non-default settings, image, host, git sha
#   runs.csv           one row per (workload, clients, repetition)
#   latency/*.log.gz   sampled per-transaction latencies (pgbench -l)
#   benchmarks/results/latest -> that directory
#
# Method: the database is rebuilt from (scale, seed) before the suite; each
# measurement is preceded by a warm-up run that is discarded; repetitions are
# interleaved across workloads to spread slow drift; pgbench uses a fixed
# --random-seed per repetition so the request stream is reproducible.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"
require_container

CLIENTS="${CLIENTS:-1 2 4 8 16}"
DURATION="${DURATION:-30}"
WARMUP="${WARMUP:-5}"
REPS="${REPS:-3}"
SCALE="${SCALE:-1}"
SEED="${SEED:-42}"
SAMPLING="${SAMPLING:-0.05}"
BENCH_DB="${BENCH_DB:-polaris_bench}"
WORKLOADS="${WORKLOADS:-$(find "$POLARIS_ROOT/benchmarks/workloads" -name '*.sql' -exec basename {} .sql \; | sort | tr '\n' ' ')}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$POLARIS_ROOT/benchmarks/results/$stamp"
mkdir -p "$out/latency"
ln -sfn "$stamp" "$POLARIS_ROOT/benchmarks/results/latest"

log "building benchmark database '$BENCH_DB' (scale=$SCALE seed=$SEED)"
"$POLARIS_ROOT/scripts/build_db.sh" -d "$BENCH_DB" -s "$SCALE" -r "$SEED" >/dev/null
psql_in "$BENCH_DB" -c "VACUUM (ANALYZE)" >/dev/null

log "recording environment"
git_sha="$(git -C "$POLARIS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git_dirty="$(git -C "$POLARIS_ROOT" status --porcelain 2>/dev/null | grep -q . && echo true || echo false)"
psql_in "$BENCH_DB" -tA <<SQL >"$out/environment.json"
SELECT jsonb_pretty(jsonb_build_object(
  'timestamp_utc',  '$stamp',
  'git_commit',     '$git_sha',
  'git_dirty',      $git_dirty,
  'server_version', current_setting('server_version'),
  'dataset',        (SELECT to_jsonb(d) - 'row_counts' FROM meta.dataset d),
  'host', jsonb_build_object(
      'os',     '$(uname -sr)',
      'arch',   '$(uname -m)',
      'cpus',   $(docker info --format '{{.NCPU}}'),
      'memory_bytes', $(docker info --format '{{.MemTotal}}')),
  'container_image', '$(docker inspect -f '{{.Config.Image}}' "$POLARIS_CONTAINER")',
  'protocol', jsonb_build_object('clients', '$CLIENTS', 'duration_s', $DURATION, 'warmup_s', $WARMUP,
                                 'repetitions', $REPS, 'latency_sampling_rate', $SAMPLING,
                                 'workloads', '$WORKLOADS'),
  'settings', (SELECT jsonb_object_agg(name, setting || coalesce(unit, ''))
               FROM pg_settings WHERE source NOT IN ('default', 'override')
                 AND name NOT LIKE 'lc_%' AND name NOT IN ('application_name', 'client_encoding', 'DateStyle', 'TimeZone'))))
SQL

echo "workload,clients,rep,tps,latency_avg_ms,transactions,failed" >"$out/runs.csv"

# Ship the workload files into the container so the harness does not depend
# on the bind mount (works against any container running this image).
docker exec "$POLARIS_CONTAINER" rm -rf /tmp/bench /tmp/bench_workloads
docker exec "$POLARIS_CONTAINER" mkdir -p /tmp/bench /tmp/bench_workloads
docker cp -q "$POLARIS_ROOT/benchmarks/workloads/." "$POLARIS_CONTAINER:/tmp/bench_workloads/"

pgbench_run() { # workload clients seconds random_seed [log_prefix]
    local w="$1" c="$2" t="$3" rs="$4" prefix="${5:-}" threads
    threads=$(( c < 4 ? c : 4 ))
    local logargs=()
    [[ -n "$prefix" ]] && logargs=(-l --sampling-rate="$SAMPLING" --log-prefix="/tmp/bench/$prefix")
    docker exec "$POLARIS_CONTAINER" bash -c "mkdir -p /tmp/bench && cd /tmp/bench && \
        pgbench -n -U '$POLARIS_USER' -d '$BENCH_DB' -c $c -j $threads -T $t --random-seed=$rs \
                ${logargs[*]+${logargs[*]}} -f /tmp/bench_workloads/$w.sql" 2>&1 || true
}

total=$(( $(wc -w <<<"$WORKLOADS") * $(wc -w <<<"$CLIENTS") * REPS ))
n=0
for rep in $(seq 1 "$REPS"); do
    for c in $CLIENTS; do
        for w in $WORKLOADS; do
            n=$((n + 1))
            pgbench_run "$w" "$c" "$WARMUP" "$((1000 + rep))" >/dev/null
            res="$(pgbench_run "$w" "$c" "$DURATION" "$((1000 + rep))" "${w}_c${c}_r${rep}")"
            tps="$(sed -nE 's/^tps = ([0-9.]+) \(without initial connection time\)/\1/p' <<<"$res")"
            lat="$(sed -nE 's/^latency average = ([0-9.]+) ms/\1/p' <<<"$res")"
            txn="$(sed -nE 's/^number of transactions actually processed: ([0-9]+).*/\1/p' <<<"$res")"
            failed="$(sed -nE 's/^number of failed transactions: ([0-9]+).*/\1/p' <<<"$res")"
            [[ -n "$tps" ]] || { echo "$res" >&2; die "pgbench failed for $w c=$c rep=$rep"; }
            echo "$w,$c,$rep,$tps,$lat,$txn,${failed:-0}" >>"$out/runs.csv"
            log "[$n/$total] $w clients=$c rep=$rep tps=$tps lat=${lat}ms"
        done
    done
done

docker exec "$POLARIS_CONTAINER" tar -C /tmp/bench -cf - . \
    | tar -C "$out/latency" -xf -
docker exec "$POLARIS_CONTAINER" rm -rf /tmp/bench /tmp/bench_workloads
gzip -q "$out"/latency/* 2>/dev/null || true
drop_db "$BENCH_DB"

ok "results in ${out#"$POLARIS_ROOT"/}"
python3 "$POLARIS_ROOT/benchmarks/analyze.py" "$out"
