#!/system/bin/sh
# Run ONCE as root after installing /vendor/overlay/inkpalm-aod.apk and rebooting.
# Native configuration persists; a11-boot-fixups.sh does not reapply it.
set -e
cmd overlay enable --user 0 net.inkpalm.overlay.aod
# Fixed-to-user rotation wins over sensor policy. A locked sensor policy instead
# makes SystemUI copy startup ROTATION_0 into user_rotation on this landscape panel.
wm set-fix-to-user-rotation enabled
settings put system accelerometer_rotation 1
settings put system user_rotation 1
settings put system screen_off_timeout 120000
# One-time defaults that Android 11 then remembers (these used to be re-asserted at every boot
# by a11-boot-fixups.sh, which overrode the user's own later choices).
settings put global window_animation_scale 0
settings put global transition_animation_scale 0
settings put global animator_duration_scale 0
settings put global stay_on_while_plugged_in 0
# No GPS on this device; Bluetooth starts off (switch it on for a page turner, it stays on).
svc bluetooth disable; settings put global bluetooth_on 0
settings put secure location_mode 0
settings put global wifi_scan_always_enabled 0; settings put global ble_scan_always_enabled 0
dumpsys deviceidle enable >/dev/null 2>&1
# Battery saver keeps its power measures but no longer forces dark theme: on E Ink that is a
# full-screen inversion with ghosting, exactly when the battery is low.
settings put global battery_saver_constants enable_night_mode=false
# Dark theme stays OFF (the GSI default is "auto", which would invert the whole UI at sunset).
cmd uimode night no
# Colors stays BOOSTED (1), deliberately. Its saturation matrix leaves greys unchanged, but it
# makes SurfaceFlinger composite on the GPU into ONE 1280x720 image, which is what the vendor
# composer + frame mirror (a11boot/libhwcflip.c) were built and validated for. MEASURED
# 2026-09-24: Natural (0) lets individual layers reach the old vendor HWC as DEVICE layers, the
# 1280x1440 wallpaper overran the mirror's buffers, and the composer crashed in a loop.
settings put system display_color_mode 1
# Phone-only and unused apps: disabled for the user (reversible: pm enable <pkg>). Frees memory
# on this 900 MB low-RAM device, so reading apps are killed and reloaded less often, and removes
# their alarms (the calendar provider scheduled wake-ups). Clock is kept for alarms; the contacts
# storage provider is kept because apps may query it. MEASURED 2026-09-24: MemAvailable after
# boot 444 MB, was 350-395 MB.
for p in com.android.messaging com.android.dialer com.android.contacts com.android.calendar \
         com.android.providers.calendar com.android.gallery3d com.android.quicksearchbox \
         org.chromium.webview_shell com.android.cellbroadcastreceiver com.android.stk \
         com.android.traceur com.android.printspooler com.android.bips com.android.egg \
         com.android.dreams.basic; do
  pm disable-user --user 0 $p >/dev/null 2>&1 || true
done
# SystemUI runs from /system but is compiled into /data; after it is replaced (systemui/) it
# only has "extract"/verify code until background dexopt runs (idle AND charging). Compile it.
cmd package compile -m speed -f com.android.systemui >/dev/null 2>&1 || true
# Screen Temperature (Night Light driving the warm LEDs, einktile ScreenTempService): warm level
# while Night Light is off. 0 = cold light only during the day.
setprop persist.sys.frontlight.warm_day 0
# Doze is OFF: the sleep transition then ends on the keyguard (clock + lock wallpaper),
# the display goes OFF, and the E Ink panel holds that frame for free -- a stock-style
# static standby screen. MEASURED 2026-09-19: ~5 panel cycles at sleep entry, 0 while
# asleep. install/from-android.sh sets the standby image (docs/images/standby.png).
settings put secure doze_enabled 0
# AOD is OFF by default as of 2026-09-19. MEASURED (docs/SUSPEND-DIAGNOSIS.md): with AOD on,
# every E Ink redraw on resume induces spurious touch events (34 touch-wakes in 5 min,
# 12 failed suspends, suspend never holds); with AOD off the same run gave 4 clean suspends
# and zero touch wakes. Set to 1 if you want the sleep-screen clock and accept the drain.
settings put secure doze_always_on 0
# Native timeout respects activity and apps holding keep-screen-on.

# Android 11 FUSE storage. The mount points Android 11's init.rc creates are added by the
# boot image's prepended rc (a11boot/a11-prepend.rc); this switches the stack on. Without
# FUSE the device runs sdcardfs and any app relying on MANAGE_EXTERNAL_STORAGE is broken
# (e.g. KOReader from v2021.06 on). To go back: set both to false and reboot -- BOTH, the
# fflag override forces persist.sys.fuse back to true on its own.
setprop persist.sys.fflag.override.settings_fuse true
setprop persist.sys.fuse true
