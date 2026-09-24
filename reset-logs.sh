#!/usr/bin/env bash
# ============================================================
#  reset-logs.sh — clear ingested Windows telemetry for a
#  clean slate between attack runs.
#
#  Deletes the winlogbeat data only. Does NOT touch detection
#  rules, Kibana config, or the Windows VM. Winlogbeat recreates
#  its index automatically on the next event.
#
#    ./reset-logs.sh            # asks for confirmation
#    ./reset-logs.sh -y         # no prompt
#    ./reset-logs.sh -y --alerts# also clear fired detection alerts
# ============================================================
set -uo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$LAB_DIR"
. "$LAB_DIR/banner.sh" 2>/dev/null || true
set -a; [ -f .env ] && . ./.env; set +a
EP="${ELASTIC_PASSWORD:?ELASTIC_PASSWORD not set (check .env)}"
ESP="${ES_PORT:-9200}"
ES="http://localhost:$ESP"

YES=0; ALERTS=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    --alerts) ALERTS=1 ;;
  esac
done

if [ "$YES" != 1 ]; then
  printf 'This deletes all winlogbeat telemetry from Elasticsearch'
  [ "$ALERTS" = 1 ] && printf ' AND clears fired detection alerts'
  printf '.\nContinue? [y/N] '
  read -r ans; case "$ans" in y|Y) ;; *) echo "Aborted."; exit 0 ;; esac
fi

echo "[reset] Deleting winlogbeat data streams (if any)..."
curl -s -u "elastic:$EP" -X DELETE "$ES/_data_stream/winlogbeat-*" >/dev/null 2>&1 || true
echo "[reset] Deleting winlogbeat indices..."
curl -s -u "elastic:$EP" -X DELETE "$ES/winlogbeat-*" >/dev/null 2>&1 || true

if [ "$ALERTS" = 1 ]; then
  echo "[reset] Clearing fired detection alerts..."
  curl -s -u "elastic:$EP" -X POST \
    "$ES/.alerts-security.alerts-default/_delete_by_query?conflicts=proceed" \
    -H 'Content-Type: application/json' -d '{"query":{"match_all":{}}}' >/dev/null 2>&1 || true
fi

echo "[reset] Done. Winlogbeat will recreate its index on the next event."
echo "[reset] Current winlogbeat indices:"
curl -s -u "elastic:$EP" "$ES/_cat/indices/winlogbeat-*?v" || true
