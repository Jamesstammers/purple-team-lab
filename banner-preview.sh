#!/usr/bin/env bash
# ============================================================
#  banner-preview.sh — preview animated banner options.
#  Run:  bash banner-preview.sh
#  Watch each, then tell Claude which number you want (1/2/3).
# ============================================================
ESC=$'\033'
col()   { printf '%s[38;5;%sm' "$ESC" "$1"; }
reset() { printf '%s[0m' "$ESC"; }
hide()  { printf '%s[?25l' "$ESC"; }
show()  { printf '%s[?25h' "$ESC"; }
home()  { printf '%s[H' "$ESC"; }

# "PURPLE" in ANSI Shadow
FIG=(
'██████╗ ██╗   ██╗██████╗ ██████╗ ██╗     ███████╗'
'██╔══██╗██║   ██║██╔══██╗██╔══██╗██║     ██╔════╝'
'██████╔╝██║   ██║██████╔╝██████╔╝██║     █████╗  '
'██╔═══╝ ██║   ██║██╔══██╗██╔═══╝ ██║     ██╔══╝  '
'██║     ╚██████╔╝██║  ██║██║     ███████╗███████╗'
'╚═╝      ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝'
)
RULE='──────────────────────────────────────────────────'
TAG='PURPLE TEAM LAB  ·  detection engineering sandbox'

# ---- Option 1: boot sequence ----
option1() {
  clear; hide
  col 141; printf '\n  %s\n' "$RULE"
  printf   '   %s\n' "$TAG"
  printf   '  %s\n\n' "$RULE"; reset
  steps=("elasticsearch" "kibana" "detection rules" "windows target" "sysmon + winlogbeat" "tuoni C2")
  for s in "${steps[@]}"; do
    printf '   [ .... ] bringing up %s' "$s"; sleep 0.35
    printf '\r   [ '; col 83; printf 'OK'; reset; printf ' ] %s\033[K\n' "$s"; sleep 0.08
  done
  col 141; printf '\n   lab online.\n'; reset; show
}

# ---- Option 2: neon pulse ----
option2() {
  clear; hide
  shades=(54 55 56 57 93 99 135 141 135 99 57 56)
  for c in "${shades[@]}"; do
    home; printf '\n'
    for ln in "${FIG[@]}"; do col "$c"; printf '  %s\n' "$ln"; done
    col 246; printf '\n  %s\n' "$TAG"; reset
    sleep 0.11
  done
  show
}

# ---- Option 3: typewriter reveal ----
option3() {
  clear; hide; printf '\n'
  for ln in "${FIG[@]}"; do col 141; printf '  %s\n' "$ln"; sleep 0.12; done
  reset; sleep 0.15; col 246; printf '  '
  for ((i=0; i<${#TAG}; i++)); do printf '%s' "${TAG:$i:1}"; sleep 0.02; done
  printf '\n'; reset; show
}

trap show EXIT
for n in 1 2 3; do
  "option$n"
  col 246; printf '\n\n   >>> Option %s — press Enter for the next\n' "$n"; reset
  read -r
done
clear
printf 'Pick your favourite and tell Claude: 1, 2, or 3.\n'
