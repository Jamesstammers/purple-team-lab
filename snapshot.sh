#!/usr/bin/env bash
# ============================================================
#  snapshot.sh — save / restore the Windows target's disk.
#  Use it to snapshot a clean, provisioned box and revert
#  after running beacons/malware on it.
#
#    ./snapshot.sh save [name]      # default name: clean
#    ./snapshot.sh restore [name]   # revert to a snapshot
#    ./snapshot.sh list             # list snapshots
#
#  The VM is stopped during save/restore for a consistent copy,
#  then started again. Snapshots live in the 'pl_snapshots'
#  Docker volume. Take your baseline AFTER Windows has installed
#  and Sysmon/Winlogbeat are running.
# ============================================================
set -uo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$LAB_DIR"

CMD="${1:-}"; NAME="${2:-clean}"
SNAPVOL="pl_snapshots"

VOL=$(docker volume ls --format '{{.Name}}' | grep '_win_storage$' | head -n1)
[ -n "$VOL" ] || { echo "[snap] Couldn't find the win_storage volume — has the lab ever started?"; exit 1; }

stop_win()  { echo "[snap] Stopping Windows target..."; docker compose stop windows >/dev/null; }
start_win() { echo "[snap] Starting Windows target..."; docker compose start windows >/dev/null; }

case "$CMD" in
  save)
    stop_win
    echo "[snap] Saving disk to snapshot '$NAME' (this can take a few minutes)..."
    docker run --rm -v "$VOL":/storage -v "$SNAPVOL":/snap alpine sh -c \
      "rm -rf /snap/$NAME && mkdir -p /snap/$NAME && cp -a /storage/*.img /snap/$NAME/ && echo saved" \
      || { echo '[snap] Save failed (no .img yet? Windows may still be installing)'; start_win; exit 1; }
    start_win
    echo "[snap] Snapshot '$NAME' created."
    ;;
  restore)
    docker run --rm -v "$SNAPVOL":/snap alpine sh -c "[ -d /snap/$NAME ]" \
      || { echo "[snap] No snapshot named '$NAME'. Run: ./snapshot.sh list"; exit 1; }
    stop_win
    echo "[snap] Restoring snapshot '$NAME' onto the Windows disk..."
    docker run --rm -v "$VOL":/storage -v "$SNAPVOL":/snap alpine sh -c \
      "cp -a /snap/$NAME/*.img /storage/ && echo restored"
    start_win
    echo "[snap] Reverted to '$NAME'. (Tip: run ./reset-logs.sh to clear telemetry too.)"
    ;;
  list)
    echo "[snap] Snapshots:"
    docker run --rm -v "$SNAPVOL":/snap alpine sh -c \
      "cd /snap 2>/dev/null && du -sh */ 2>/dev/null || echo '  (none yet)'"
    ;;
  *)
    echo "Usage: ./snapshot.sh {save|restore|list} [name]"
    exit 1
    ;;
esac
