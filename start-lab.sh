#!/usr/bin/env bash
# ============================================================
#  start-lab.sh — bring up the whole Purple Team Lab
#    - Elastic + Kibana + Windows target   (this repo's compose)
#    - Tuoni C2 community edition           (shell-dot/tuoni)
#
#  Run from the repo root, inside a WSL2 distro (or any Linux
#  shell) that has Docker available:
#      ./start-lab.sh
# ============================================================
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$LAB_DIR"
TUONI_DIR="${HOME}/tuoni"
# shellcheck source=banner.sh
. "$LAB_DIR/banner.sh"

# --- sanity checks ----------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found. Enable Docker Desktop > Settings > Resources > WSL integration for this distro."
docker version   >/dev/null 2>&1 || die "can't reach the Docker daemon. Is Docker Desktop running?"
command -v git   >/dev/null 2>&1 || die "git not found. Install it:  sudo apt-get update && sudo apt-get install -y git"

# --- env file ---------------------------------------------------------
if [ ! -f .env ]; then
  [ -f .env.example ] || die "No .env or .env.example in $LAB_DIR"
  cp .env.example .env
  for k in ENCRYPTION_KEY SO_ENCRYPTION_KEY REPORTING_KEY; do
    val=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
    sed -i "s|^$k=.*|$k=$val|" .env
  done
fi
set -a; . ./.env; set +a

# --- ingest mode: winlogbeat (default) or elastic-agent (Fleet) --------
INGEST="${INGEST:-winlogbeat}"
DC="docker compose -f docker-compose.yml"
if [ "$INGEST" = "elastic-agent" ]; then
  DC="$DC -f docker-compose.fleet.yml"
fi

# --- splash -----------------------------------------------------------
banner "${STACK_VERSION:-}"
[ "$INGEST" = "elastic-agent" ] && ok "ingest mode: elastic-agent (Fleet)" || ok "ingest mode: winlogbeat"
[ -e /dev/kvm ] || warn "/dev/kvm not found — the Windows target may fail to boot (needs WSL2 + nested virtualization)."

# --- 1. pull -----------------------------------------------------------
step "Pulling Elastic images (validates STACK_VERSION)"
$DC pull elasticsearch kibana || die "Image pull failed. Check STACK_VERSION=$STACK_VERSION is a real tag on docker.elastic.co."
[ "$INGEST" = "elastic-agent" ] && $DC pull fleet-server >/dev/null 2>&1
ok "images ready"

# --- 2. core stack -----------------------------------------------------
step "Starting core stack (Elasticsearch, Kibana, Windows target)"
$DC up -d
ok "containers created"

# --- 3. wait for services ---------------------------------------------
step "Waiting for the SIEM to come online"
wait_until "Elasticsearch" "curl -s -u elastic:$ELASTIC_PASSWORD http://localhost:${ES_PORT:-9200}/_cluster/health | grep -q '\"status\"'" 300
wait_until "Kibana"        "curl -s http://localhost:${KIBANA_PORT:-5601}/api/status | grep -q '\"level\":\"available\"'" 300
if [ "$INGEST" = "elastic-agent" ]; then
  wait_until "Fleet Server" "curl -s http://localhost:8220/api/status | grep -q HEALTHY" 300
fi

# --- 4. detection rules -----------------------------------------------
step "Installing + enabling prebuilt detection rules"
bash install-rules.sh || warn "rules step had issues — re-run ./install-rules.sh later."

# --- 5. Tuoni ----------------------------------------------------------
step "Starting Tuoni C2"
[ -d "$TUONI_DIR/.git" ] || git clone https://github.com/shell-dot/tuoni "$TUONI_DIR"

# Host that browsers use to reach the Tuoni server. Priority:
#   TUONI_FQDN from .env  ->  auto-detected primary IP  ->  localhost
# (Avoids the internal 'local-c2' alias, which browsers can't resolve.)
FQDN="${TUONI_FQDN:-}"
if [ -z "$FQDN" ]; then
  FQDN=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [ -z "$FQDN" ] && FQDN=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$FQDN" ] && FQDN=localhost
fi

# First start generates config/certs/creds if this is a fresh clone.
( cd "$TUONI_DIR" && ./tuoni start ) || warn "tuoni start had issues — cd ~/tuoni && ./tuoni logs"

# Point the browser client at $FQDN instead of 'local-c2', restart only if changed.
CFG="$TUONI_DIR/config/tuoni.env"
if [ -f "$CFG" ]; then
  if grep -q '^TUONI_HOST_FQDN=' "$CFG"; then
    cur=$(grep '^TUONI_HOST_FQDN=' "$CFG" | head -n1 | cut -d= -f2-)
    if [ "$cur" != "$FQDN" ]; then
      sed -i "s|^TUONI_HOST_FQDN=.*|TUONI_HOST_FQDN=$FQDN|" "$CFG"
      ( cd "$TUONI_DIR" && ./tuoni restart ) >/dev/null 2>&1 || true
    fi
  else
    printf 'TUONI_HOST_FQDN=%s\n' "$FQDN" >> "$CFG"
    ( cd "$TUONI_DIR" && ./tuoni restart ) >/dev/null 2>&1 || true
  fi
  ok "tuoni up — browser client points at $FQDN"
else
  warn "tuoni config not found ($CFG) — client still uses default 'local-c2' (see README)."
fi

# --- 6. Windows note (non-blocking) -----------------------------------
step "Windows target"
warn "Installs itself in the background on first run (~10-20 min)."
_c 246
printf '      watch install : http://localhost:8006\n'
printf '      check status  : ./status.sh\n'
[ "$INGEST" = "elastic-agent" ] && printf '      it enrols into Fleet on its own — see Kibana > Fleet > Agents\n'
_r

# --- 7. Auto baseline snapshot (background, one-time) ------------------
if [ "${AUTO_SNAPSHOT:-1}" = 1 ]; then
  if docker run --rm -v pl_snapshots:/snap alpine sh -c "[ -d /snap/clean ]" 2>/dev/null; then
    ok "clean snapshot already exists — revert with ./snapshot.sh restore clean"
  else
    nohup bash "$LAB_DIR/auto-snapshot.sh" >/dev/null 2>&1 &
    step "Baseline snapshot"
    _c 246; printf '      A "clean" snapshot will be saved automatically once\n'
    printf '      telemetry is flowing (background). Revert later with:\n'
    printf '      ./snapshot.sh restore clean\n'; _r
  fi
fi

# --- summary ----------------------------------------------------------
_c 141; printf '\n  ── Lab endpoints ─────────────────────────────────\n'; _r
_c 246
printf '   Kibana        http://localhost:%s   (elastic / see .env)\n' "${KIBANA_PORT:-5601}"
printf '   Elasticsearch http://localhost:%s\n' "${ES_PORT:-9200}"
printf '   Windows SSH   ssh %s@localhost -p %s\n' "${WIN_USERNAME:-labadmin}" "${WIN_SSH_PORT:-2222}"
printf '   Windows setup http://localhost:%s\n' "${WIN_VIEW_PORT:-8006}"
printf '   Tuoni C2      https://localhost:12702   (cd ~/tuoni && ./tuoni print-credentials)\n'
printf '   Tuoni server  https://%s:8443   (accept the self-signed cert once, per browser)\n' "$FQDN"
[ "$INGEST" = "elastic-agent" ] && printf '   Fleet Server  http://localhost:8220   (Kibana > Fleet > Agents)\n'
_r
printf '\n'
