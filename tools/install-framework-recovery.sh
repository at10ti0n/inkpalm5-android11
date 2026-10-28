#!/bin/bash
# Install one vendor RC or remove its recorded copy. Reboot separately to activate.
set -euo pipefail
MODE=${1:?usage: install-framework-recovery.sh install | rollback}
case "$MODE" in install|rollback) ;; *) exit 2 ;; esac
ADB=${ADB:-adb}
adb_run() {
  if [ -n "${INKPALM_SERIAL:-}" ]; then "$ADB" -s "$INKPALM_SERIAL" "$@"
  else "$ADB" "$@"; fi
}
R=$(cd "$(dirname "$0")/.." && pwd)
st=/data/local/tmp/inkpalm-fwguard-install
adb_run get-state
adb_run shell mkdir -p "$st"
adb_run push "$R/install/device/framework-recovery.sh" "$st/framework-recovery.sh" >/dev/null
if [ "$MODE" = install ]; then
  adb_run push "$R/configs/framework-recovery.rc" "$st/framework-recovery.rc" >/dev/null
fi
adb_run shell su 0 sh "$st/framework-recovery.sh" "$MODE" "$st/framework-recovery.rc"
