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
settings put secure doze_enabled 1
settings put secure doze_always_on 1
# Native timeout respects activity and apps holding keep-screen-on.
