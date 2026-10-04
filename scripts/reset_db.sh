#!/usr/bin/env bash
# Regenerate the base dataset in place (all base tables truncated and
# rebuilt from scale and seed). Module-created objects are kept.
#
#   scripts/reset_db.sh            # scale/seed from .env, default 1/42
#   scripts/reset_db.sh -y         # skip confirmation
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require_container

if [[ "${1:-}" != "-y" ]]; then
    read -r -p "Regenerate all base data in '$POLARIS_DB'? [y/N] " ans
    [[ "$ans" == [yY] ]] || { log "aborted"; exit 0; }
fi
docker exec -i -w /sql "$POLARIS_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$POLARIS_USER" -d "$POLARIS_DB" \
    -v scale="${POLARIS_SCALE:-1}" -v seed="${POLARIS_SEED:-42}" -f /sql/00_init/999_reset_demo_data.sql
ok "dataset regenerated"
