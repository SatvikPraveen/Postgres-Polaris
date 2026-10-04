#!/usr/bin/env bash
# Verified logical backup: pg_dump (custom format, compressed), restore into
# a scratch database with parallel jobs, then prove the restore is complete by
# comparing meta.fingerprint() of source and restored copy.
#
#   scripts/backup_demo.sh              # back up $POSTGRES_DB
#   scripts/backup_demo.sh -k           # keep the restored database
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_container

keep=false
[[ "${1:-}" == "-k" ]] && keep=true
src="$POLARIS_DB"; dst="${src}_restore_check"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
outdir="$POLARIS_ROOT/backups"; mkdir -p "$outdir"
dump="$outdir/${src}_${stamp}.dump"

log "dumping '$src'"
docker exec "$POLARIS_CONTAINER" pg_dump -U "$POLARIS_USER" -d "$src" -Fc -Z zstd:3 \
    --exclude-extension=pg_cron -f "/tmp/backup.dump"   # pg_cron may only exist in its home database
docker cp "$POLARIS_CONTAINER:/tmp/backup.dump" "$dump" >/dev/null
entries="$(docker exec "$POLARIS_CONTAINER" sh -c 'pg_restore -l /tmp/backup.dump | grep -c "TABLE DATA"')"
log "archive contains $entries table-data entries ($(du -h "$dump" | cut -f1))"

log "restoring into '$dst' with 4 parallel jobs"
recreate_db "$dst"
docker exec "$POLARIS_CONTAINER" pg_restore -U "$POLARIS_USER" -d "$dst" -j 4 --no-owner /tmp/backup.dump
docker exec "$POLARIS_CONTAINER" rm -f /tmp/backup.dump

log "verifying content fingerprints"
q="SELECT table_name, row_count, content_md5 FROM meta.fingerprint() ORDER BY 1"
if diff <(psql_in "$src" -tA -c "$q") <(psql_in "$dst" -tA -c "$q") >/dev/null; then
    ok "restore verified: every table matches ($dump)"
else
    die "restored database differs from source"
fi
$keep || drop_db "$dst"
