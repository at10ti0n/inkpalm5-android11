#!/system/bin/sh
# EPD105 Android 11 boot fixups (started by init at sys.boot_completed=1; see gate17 rc).
# Re-asserts what the framework loses across reboots. Idempotent; logs to /data/local/a11-fixups.log.
L=/data/local/a11-fixups.log; echo "$(date) start" >> $L
n=0; while [ "$(getprop init.svc.surfaceflinger)" != running ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done
settings put system accelerometer_rotation 0
settings put system user_rotation 1
wm set-user-rotation lock 1
wm set-fix-to-user-rotation enabled
settings put global window_animation_scale 0
settings put global transition_animation_scale 0
settings put global animator_duration_scale 0
settings put global stay_on_while_plugged_in 0
[ -z "$(getprop persist.sys.mRefreshMode)" ] && setprop persist.sys.mRefreshMode 132
# battery (2026-09-17): no BT peripherals, no GPS on this device, keep radios/scanning off
svc bluetooth disable; settings put global bluetooth_on 0
settings put secure location_mode 0
settings put global wifi_scan_always_enabled 0; settings put global ble_scan_always_enabled 0
dumpsys deviceidle enable >/dev/null 2>&1
echo "$(date) done user_rotation=$(settings get system user_rotation)" >> $L
# --- guard: if anything turns auto-rotate back on (a stray tile tap, an app), re-lock. ---
while true; do
  if [ "$(settings get system accelerometer_rotation)" = 1 ] || [ "$(settings get system user_rotation)" != 1 ]; then
    settings put system accelerometer_rotation 0; settings put system user_rotation 1
    wm set-user-rotation lock 1; echo "$(date) re-locked rotation" >> $L
  fi
  sleep 15
done
