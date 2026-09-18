#!/system/bin/sh
# EPD105 Android 11 boot fixups (started by init at sys.boot_completed=1; see gate17 rc).
# Bounded startup configuration; no rotation or sleep polling.
# See docs/NATIVE-A11-FIRST-PASS.md for the tested rotation/AOD configuration.
L=/data/local/a11-fixups.log; echo "$(date) start" >> $L
n=0; while [ "$(getprop init.svc.surfaceflinger)" != running ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done
# Rotation and native sleep are persistent settings configured once (configure-native.sh),
# but re-assert the rotation here: an app that asks for the display's NATURAL orientation
# (android:screenOrientation="nosensor" with resizeableActivity=false -- KOReader does this)
# gets landscape on this panel, and SystemUI writes that back into user_rotation, where it
# persists across reboots. MEASURED 2026-09-18: running KOReader left user_rotation=0.
# One bounded write, no polling; fixed-to-user-rotation still does the real work.
settings put system user_rotation 1
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
# FUSE storage: vold creates /mnt/user/0/primary itself on the sdcardfs path but not on the
# FUSE one here, and /sdcard -> /storage/self/primary -> /mnt/user/0/primary, so without it
# /sdcard does not resolve at all. See a11boot/a11-prepend.rc for the mount points.
if [ "$(getprop persist.sys.fuse)" = true ] && [ ! -e /mnt/user/0/primary ]; then
  ln -s /mnt/user/0/emulated/0 /mnt/user/0/primary
fi
# No modem on this device and the framework already knows (ro.radio.noril=true), but the
# vendor still starts rild and radio_monitor, both declared with `capabilities BLOCK_SUSPEND`
# (rild is in the wakelock group too). rild then retries a device node that does not exist
# every 2 s for the life of the boot -- MEASURED "fd = -1, sleep 2s wait device, total wait
# time: 3050s". Costs no measurable CPU, but it is a 0.5 Hz wakeup that never ends.
# Stopping them leaves Settings, SystemUI and the phone process healthy (verified).
stop ril-daemon 2>/dev/null
stop radio_monitor-daemon 2>/dev/null
echo "$(date) done user_rotation=$(settings get system user_rotation)" >> $L
