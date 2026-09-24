#!/usr/bin/env bash
# ============================================================
#  install-rules.sh — install + enable Elastic prebuilt
#  detection rules. Safe to re-run. Run from the repo root
#  against a live stack:   ./install-rules.sh
#  Needs internet from Kibana (to fetch the rules package).
# ============================================================
set -uo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$LAB_DIR/.env" ] && . "$LAB_DIR/.env"

KB="http://localhost:${KIBANA_PORT:-5601}"
AUTH="elastic:${ELASTIC_PASSWORD:?ELASTIC_PASSWORD not set (check .env)}"
INT=(-H 'kbn-xsrf: true' -H 'elastic-api-version: 1'          -H 'Content-Type: application/json')
PUB=(-H 'kbn-xsrf: true' -H 'elastic-api-version: 2023-10-31' -H 'Content-Type: application/json')

say(){ printf '\n\033[1;36m[rules]\033[0m %s\n' "$*"; }

say "Waiting for Kibana to be available at $KB ..."
until curl -s "$KB/api/status" | grep -q '"level":"available"'; do sleep 5; done

say "Installing prebuilt rules package + all rules (internal _perform)..."
resp=$(curl -s -w '\n%{http_code}' -u "$AUTH" "${INT[@]}" \
  -X POST "$KB/internal/detection_engine/prebuilt_rules/installation/_perform" \
  -d '{"mode":"ALL_RULES"}')
code=$(printf '%s' "$resp" | tail -n1)
printf '%s\n' "$resp" | sed '$d' | head -c 500; echo
say "_perform returned HTTP $code"

if [ "$code" != "200" ]; then
  say "Internal endpoint didn't return 200 — trying legacy PUT prepackaged as fallback..."
  curl -s -u "$AUTH" "${PUB[@]}" -X PUT "$KB/api/detection_engine/rules/prepackaged"; echo
fi

say "Enabling all installed rules..."
en=$(curl -s -w '\n%{http_code}' -u "$AUTH" "${PUB[@]}" \
  -X POST "$KB/api/detection_engine/rules/_bulk_action" \
  -d '{"action":"enable","query":""}')
say "_bulk_action enable returned HTTP $(printf '%s' "$en" | tail -n1)"

total=$(curl -s -u "$AUTH" -H 'elastic-api-version: 2023-10-31' \
  "$KB/api/detection_engine/rules/_find?per_page=0" | grep -o '"total":[0-9]*' | head -n1 | cut -d: -f2)
say "Done. Rules now present in Kibana: ${total:-unknown}"
say "Check them in Kibana → Security → Rules."
