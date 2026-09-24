#!/usr/bin/env bash
# ============================================================
#  auto-snapshot.sh — wait until the Windows target is fully
#  provisioned (telemetry flowing), then save the 'clean'
#  baseline snapshot. Runs in the background from start-lab.sh;
#  no-op if a 'clean' snapshot already exists.
#
#  Manual use:  ./auto-snapshot.sh [timeout_seconds]
# ============================================================
set -uo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$LAB_DIR"
set -a; [ -f .env ] && . ./.env; set +a
EP="${ELASTIC_PASSWORD:-}"; ESP="${ES_PORT:-9200}"
ES="http://localhost:$ESP"
NAME=clean
TIMEOUT="${1:-2700}"          # give the first install up to 45 min

# Already have a baseline? Nothing to do.
if docker run --rm -v pl_snapshots:/snap alpine sh -c "[ -d /snap/$NAME ]" 2>/dev/null; then
  exit 0
fi

# Wait for Windows telemetry to appear (install + Sysmon/Winlogbeat done).
start=$SECONDS
while :; do
  cnt=$(curl -s -u "elastic:$EP" "$ES/winlogbeat-*/_count" 2>/dev/null | grep -o '"count":[0-9]*' | head -n1 | cut -d: -f2)
  if [ -n "${cnt:-}" ] && [ "$cnt" -gt 0 ] 2>/dev/null; then break; fi
  [ $((SECONDS - start)) -ge "$TIMEOUT" ] && exit 0
  sleep 30
done

sleep 30                       # let provisioning settle
# Re-check the guard in case another run beat us to it.
docker run --rm -v pl_snapshots:/snap alpine sh -c "[ -d /snap/$NAME ]" 2>/dev/null && exit 0
bash "$LAB_DIR/snapshot.sh" save "$NAME"
