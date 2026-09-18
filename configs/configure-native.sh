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
