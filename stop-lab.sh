#!/usr/bin/env bash
# stop-lab.sh — tear the lab down.  Add  --wipe  to also delete volumes
# (Windows disk + Elasticsearch data) for a clean slate.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOWN_ARGS=""
[ "${1:-}" = "--wipe" ] && DOWN_ARGS="-v"

cd "$LAB_DIR"
set -a; [ -f .env ] && . ./.env; set +a
DC="docker compose -f docker-compose.yml"
[ "${INGEST:-winlogbeat}" = "elastic-agent" ] && DC="$DC -f docker-compose.fleet.yml"

echo "[lab] Stopping Elastic + Kibana + Windows${INGEST:+ + Fleet}..."
$DC down $DOWN_ARGS

if [ -d "$HOME/tuoni" ]; then
  echo "[lab] Stopping Tuoni..."
  ( cd "$HOME/tuoni" && ./tuoni stop ) || echo "[lab] (couldn't run ./tuoni stop — stop it manually if needed)"
fi
echo "[lab] Done."
