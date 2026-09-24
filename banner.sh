#!/usr/bin/env bash
# ============================================================
#  banner.sh — shared UI helpers (logo, progress, spinners).
#  Sourced by start-lab.sh / status.sh. Animation auto-disables
#  when output isn't a terminal or NO_COLOR is set.
# ============================================================
ESC=$'\033'
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then UI=1; else UI=0; fi
_c(){ [ "$UI" = 1 ] && printf '%s[38;5;%sm' "$ESC" "$1"; return 0; }
_r(){ [ "$UI" = 1 ] && printf '%s[0m' "$ESC"; return 0; }
_hide(){ [ "$UI" = 1 ] && printf '%s[?25l' "$ESC"; return 0; }
_show(){ [ "$UI" = 1 ] && printf '%s[?25h' "$ESC"; return 0; }
_home(){ [ "$UI" = 1 ] && printf '%s[H' "$ESC"; return 0; }

# "PURPLE" — ANSI Shadow
FIG=(
'██████╗ ██╗   ██╗██████╗ ██████╗ ██╗     ███████╗'
'██╔══██╗██║   ██║██╔══██╗██╔══██╗██║     ██╔════╝'
'██████╔╝██║   ██║██████╔╝██████╔╝██║     █████╗  '
'██╔═══╝ ██║   ██║██╔══██╗██╔═══╝ ██║     ██╔══╝  '
'██║     ╚██████╔╝██║  ██║██║     ███████╗███████╗'
'╚═╝      ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝'
)

# banner [version]
banner(){
  local ver="${1:-}"
  clear 2>/dev/null || true
  if [ "$UI" = 1 ]; then
    _hide; printf '\n'
    local c; for ln in "${FIG[@]}"; do _c 141; printf '  %s\n' "$ln"; sleep 0.07; done
    _r
  else
    printf '\n  === PURPLE TEAM LAB ===\n'
  fi
  _c 246
  printf '\n  Home Purple Team Lab · built on Docker\n\n'
  _r
  _show
}

# --- progress helpers ---
STEP=0
step(){ STEP=$((STEP+1)); _c 141; printf '\n  [%d] ' "$STEP"; _r; printf '%s\n' "$1"; }
ok(){   _c 83;  printf '      %s %s\n' "$([ "$UI" = 1 ] && printf '✔' || printf 'OK')" "${1:-done}"; _r; }
warn(){ _c 214; printf '      ! %s\n' "${1:-}"; _r; }
die(){  _c 196; printf '\n  [error] %s\n' "${1:-}" >&2; _r; exit 1; }

# wait_until "desc" "shell test" [timeout_s]
wait_until(){
  local desc="$1" test_cmd="$2" timeout="${3:-300}"
  local spin='|/-\' i=0 start=$SECONDS el
  _hide
  while ! eval "$test_cmd" >/dev/null 2>&1; do
    el=$((SECONDS-start))
    if [ "$el" -ge "$timeout" ]; then _show; warn "$desc — timed out after ${timeout}s"; return 1; fi
    [ "$UI" = 1 ] && printf '\r      %s waiting for %s (%ds)   ' "${spin:i++%4:1}" "$desc" "$el"
    sleep 0.5
  done
  _show
  [ "$UI" = 1 ] && printf '\r%s[K' "$ESC"
  ok "$desc (${el:-0}s)"
}
