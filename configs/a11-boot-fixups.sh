#!/system/bin/sh
# EPD105 Android 11 boot fixups (started by init at sys.boot_completed=1; see gate17 rc).
# Bounded startup configuration; no rotation or sleep polling.
# See docs/NATIVE-A11-FIRST-PASS.md for the tested rotation/AOD configuration.
L=/data/local/a11-fixups.log; echo "$(date) start" >> $L
n=0; while [ "$(getprop init.svc.surfaceflinger)" != running ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done
# Rotation and native sleep are persistent settings configured once; see configure-native.sh.
settings put global window_animation_scale 0
settings put global transition_animation_scale 0
settings put global animator_duration_scale 0
settings put global stay_on_while_plugged_in 0
[ -z "$(getprop persist.sys.mRefreshMode)" ] && setprop persist.sys.mRefreshMode 132
# auto full refresh after N partial updates (HWC updateGu16Refreshlimit); 0 = never (stock)
[ -z "$(getprop persist.display.gu16_max_limit)" ] && setprop persist.display.gu16_max_limit 10
# battery (2026-09-17): no BT peripherals, no GPS on this device, keep radios/scanning off
svc bluetooth disable; settings put global bluetooth_on 0
settings put secure location_mode 0
settings put global wifi_scan_always_enabled 0; settings put global ble_scan_always_enabled 0
dumpsys deviceidle enable >/dev/null 2>&1
echo "$(date) done user_rotation=$(settings get system user_rotation)" >> $L
