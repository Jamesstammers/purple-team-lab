#!/usr/bin/env bash
# ============================================================
#  status.sh — quick health snapshot of the whole lab.
#  Run:  ./status.sh
# ============================================================
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$LAB_DIR"
. "$LAB_DIR/banner.sh" 2>/dev/null || true
set -a; [ -f .env ] && . ./.env; set +a
EP="${ELASTIC_PASSWORD:-}"
ESP="${ES_PORT:-9200}"

_c 141; printf '\n== Containers ==\n'; _r
docker compose ps 2>/dev/null
[ -d "$HOME/tuoni" ] && docker ps --filter name=tuoni --format '  {{.Names}}\t{{.Status}}' 2>/dev/null

_c 141; printf '\n== Elasticsearch ==\n'; _r
curl -s -u "elastic:$EP" "http://localhost:$ESP/_cluster/health?pretty" 2>/dev/null \
  | grep -E '"status"|"number_of_nodes"' || echo '  not reachable yet'

_c 141; printf '\n== Windows telemetry (winlogbeat indices) ==\n'; _r
out=$(curl -s -u "elastic:$EP" "http://localhost:$ESP/_cat/indices/winlogbeat-*?v" 2>/dev/null)
[ -n "$out" ] && echo "$out" || echo '  none yet — Windows still provisioning, or Winlogbeat not started'

_c 141; printf '\n== Detection rules (enabled/total) ==\n'; _r
curl -s -u "elastic:$EP" -H 'elastic-api-version: 2023-10-31' \
  "http://localhost:${KIBANA_PORT:-5601}/api/detection_engine/rules/_find?per_page=0" 2>/dev/null \
  | grep -o '"total":[0-9]*' | head -n1 || echo '  Kibana not ready'

_c 141; printf '\n== Tuoni C2 ==\n'; _r
curl -sk -o /dev/null -w '  UI https://localhost:12702 -> HTTP %{http_code}\n' https://localhost:12702 2>/dev/null \
  || echo '  not reachable'
printf '\n'
