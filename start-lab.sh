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
# Put our docker-compose shim on PATH so Tuoni's dependency check passes and it
# never offers to reinstall Docker (which breaks Docker Desktop + WSL setups).
chmod +x "$LAB_DIR/bin/docker-compose" 2>/dev/null || true
export PATH="$LAB_DIR/bin:$PATH"
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
step "Checking Elastic images"
imgs="docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION} docker.elastic.co/kibana/kibana:${STACK_VERSION}"
[ "$INGEST" = "elastic-agent" ] && imgs="$imgs docker.elastic.co/elastic-agent/elastic-agent:${STACK_VERSION}"
need_pull=0
for img in $imgs; do docker image inspect "$img" >/dev/null 2>&1 || need_pull=1; done
if [ "$need_pull" = 1 ]; then
  spin_run "pulling images (first run / after a cache clear)" \
    $DC --progress quiet pull elasticsearch kibana || die "Image pull failed — check STACK_VERSION=$STACK_VERSION is a real tag on docker.elastic.co."
  [ "$INGEST" = "elastic-agent" ] && $DC --progress quiet pull fleet-server >/dev/null 2>&1
  ok "images pulled"
else
  ok "images already present (skipping pull)"
fi

# --- 2. core stack -----------------------------------------------------
step "Starting core stack (Elasticsearch, Kibana, Windows target)"
# Verbose on purpose: shows each container's Waiting/Started status. On a first
# Fleet run this can sit a few minutes while Kibana pulls integration packages.
if ! $DC up -d; then
  warn "compose up failed — clearing unused Docker networks and retrying (usually a stale network / 172.30.0.0/24 overlap)"
  docker network prune -f >/dev/null 2>&1 || true
  $DC up -d || die "compose up failed again — check: $DC logs"
fi
ok "containers up"

# --- 3. wait for services ---------------------------------------------
step "Waiting for the SIEM to come online"
wait_until "Elasticsearch" "curl -s -u elastic:$ELASTIC_PASSWORD http://localhost:${ES_PORT:-9200}/_cluster/health | grep -q '\"status\"'" 300
wait_until "Kibana"        "curl -s http://localhost:${KIBANA_PORT:-5601}/api/status | grep -q '\"level\":\"available\"'" 300
if [ "$INGEST" = "elastic-agent" ]; then
  wait_until "Fleet Server" "curl -s http://localhost:8220/api/status | grep -q HEALTHY" 300
fi

# --- 4. detection rules -----------------------------------------------
step "Detection rules"
rule_total=$(curl -s -u "elastic:$ELASTIC_PASSWORD" -H 'elastic-api-version: 2023-10-31' \
  "http://localhost:${KIBANA_PORT:-5601}/api/detection_engine/rules/_find?per_page=0" \
  | grep -o '"total":[0-9]*' | head -n1 | cut -d: -f2)
if [ "${rule_total:-0}" -gt 0 ] 2>/dev/null; then
  ok "rules already installed ($rule_total) — skipping (run 'purple rules' to refresh)"
else
  bash install-rules.sh || warn "rules step had issues — re-run ./install-rules.sh later."
fi

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
# If it fails (e.g. stale network refs after a network prune), recreate the
# containers and retry once so it self-heals.
if ! ( cd "$TUONI_DIR" && ./tuoni start ); then
  warn "tuoni start failed — recreating its containers (clears stale network refs)"
  docker rm -f tuoni-server tuoni-client tuoni-client-nginx tuoni-docs tuoni-utility >/dev/null 2>&1 || true
  ( cd "$TUONI_DIR" && ./tuoni stop ) >/dev/null 2>&1 || true
  ( cd "$TUONI_DIR" && ./tuoni start ) || warn "tuoni still failing — cd ~/tuoni && ./tuoni logs"
fi

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

# Force the Tuoni login to tuoni/tuoni for the lab. change-credentials is
# interactive (username, then password), so we feed both on stdin. Only attempt
# it when sudo won't prompt (it's cached from './tuoni start' above), and cap it
# with a timeout so it can never hang the script.
if sudo -n true 2>/dev/null; then
  if printf 'tuoni\ntuoni\n' | ( cd "$TUONI_DIR" && timeout 40 ./tuoni change-credentials ) >/dev/null 2>&1; then
    ok "tuoni login set to tuoni / tuoni"
  else
    warn "couldn't set tuoni creds automatically — run: cd ~/tuoni && ./tuoni change-credentials"
  fi
else
  warn "skipped setting tuoni creds (sudo needs a password) — run: cd ~/tuoni && ./tuoni change-credentials"
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
printf '   Kibana        http://localhost:%s   (elastic / %s)\n' "${KIBANA_PORT:-5601}" "$ELASTIC_PASSWORD"
printf '   Elasticsearch http://localhost:%s   (elastic / %s)\n' "${ES_PORT:-9200}" "$ELASTIC_PASSWORD"
printf '   Windows SSH   ssh %s@localhost -p %s   (password: %s)\n' "${WIN_USERNAME:-jsmith}" "${WIN_SSH_PORT:-2222}" "$WIN_PASSWORD"
printf '   Windows setup http://localhost:%s\n' "${WIN_VIEW_PORT:-8006}"
printf '   Tuoni C2      https://localhost:12702\n'
printf '   Tuoni server  https://%s:8443   (accept the self-signed cert once, per browser)\n' "$FQDN"
[ "$INGEST" = "elastic-agent" ] && printf '   Fleet Server  http://localhost:8220   (Kibana > Fleet > Agents)\n'
# Tuoni login — printed straight from Tuoni (its password is auto-generated)
tcreds=$( cd "$TUONI_DIR" 2>/dev/null && ./tuoni print-credentials 2>/dev/null | grep -iE 'user|pass' | tr -d '\r' )
if [ -n "$tcreds" ]; then
  printf '   Tuoni login:\n'; printf '%s\n' "$tcreds" | sed 's/^/       /'
else
  printf '   Tuoni login   run: cd ~/tuoni && ./tuoni print-credentials\n'
fi
_r
printf '\n'
