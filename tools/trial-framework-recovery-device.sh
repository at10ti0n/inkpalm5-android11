#!/system/bin/sh
# Explicit destructive test of a *process*, not a kernel reboot: kills system_server.
# Run as root after installing the RC and rebooting. No persistent service is installed.
# Usage: sh trial-framework-recovery-device.sh usb|unplug UNIQUE-RUN-NAME
set -eu
mode=${1:?usb or unplug}; run=${2:?unique run name}
case "$mode" in usb|unplug) ;; *) exit 2 ;; esac
case "$run" in ''|*[!a-zA-Z0-9-]*) exit 2 ;; esac
b=/data/local/inkpalm-framework-recovery
d=$b/$run
[ "$(getprop sys.inkpalm.fwguard)" = idle ]
[ "$(getprop init.svc.bootanim)" = stopped ]
[ ! -e "$d" ] || { echo 'Run already exists' >&2; exit 1; }
mkdir -m 0700 "$d"
exec > "$d/events.txt" 2>&1
trap 'echo inkpalm_fwguard_trial_prep > /sys/power/wake_unlock 2>/dev/null || true' EXIT
up() { read -r now _ < /proc/uptime; echo "${now%.*}"; }
snapshot() {
  echo "$1 boottime=$(up)"
  getprop sys.inkpalm.fwguard
  getprop init.svc.zygote
  getprop init.svc.bootanim
  cat /sys/power/wake_lock
  cat /sys/kernel/debug/suspend_stats
}
cat /proc/sys/kernel/random/boot_id > "$d/boot-id.txt"
if [ "$mode" = unplug ]; then
  # Bound the arming period too. This preparation lock ends BEFORE the crash.
  echo 'inkpalm_fwguard_trial_prep 360000000000' > /sys/power/wake_lock
  echo armed > "$d/status"
  start=$(up)
  while :; do
    read -r usb < /sys/class/power_supply/usb/online
    [ "$usb" = 0 ] && break
    [ $(($(up) - start)) -lt 300 ] || { echo cancelled-no-unplug > "$d/status"; exit 1; }
    sleep 1
  done
  echo "USB disconnected boottime=$(up)"
  sleep 3
fi
old=$(pidof system_server)
case "$old" in ''|*[!0-9]*) echo 'Expected one system_server PID' >&2; exit 1 ;; esac
[ "$(getprop sys.inkpalm.fwguard)" = idle ]
snapshot before-crash
echo inkpalm_fwguard_trial_prep > /sys/power/wake_unlock 2>/dev/null || true
start=$(up)
echo restarting > "$d/status"
echo "Killing system_server pid=$old boottime=$start"
kill -9 "$old"
seen=0; previous=idle
while [ $(($(up) - start)) -lt 950 ]; do
  phase=$(getprop sys.inkpalm.fwguard)
  if [ "$phase" != "$previous" ]; then
    snapshot "phase=$phase"
    previous=$phase
  fi
  [ "$phase" != idle ] && seen=1
  current=$(pidof system_server || true)
  if [ "$seen" = 1 ] && [ "$phase" = idle ] && [ -n "$current" ] &&
     [ "$current" != "$old" ] && [ "$(getprop init.svc.bootanim)" = stopped ]; then
    snapshot recovered
    echo "new_system_server=$current elapsed_s=$(($(up) - start))"
    echo recovered > "$d/status"
    sync
    exit 0
  fi
  sleep 1
done
snapshot deadline
echo timeout > "$d/status"
sync
exit 1
