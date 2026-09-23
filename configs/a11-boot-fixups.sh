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
# Animations, Bluetooth, location, scanning and battery-saver defaults are set ONCE by
# configs/configure-native.sh. Android 11 persists them, and re-asserting them here at every
# boot silently overrode the user's own choices (a Bluetooth page turner switched on was off
# again after each reboot). docs/A11-NATIVE-FEATURES-PROPOSAL.md, item 4.
[ -z "$(getprop persist.sys.mRefreshMode)" ] && setprop persist.sys.mRefreshMode 132
# auto full refresh after N partial updates (HWC updateGu16Refreshlimit); 0 = never (stock)
[ -z "$(getprop persist.display.gu16_max_limit)" ] && setprop persist.display.gu16_max_limit 10
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
# SurfaceFlinger livelock detector (docs/INCIDENT-SF-LIVELOCK.md). Both hangs so far were
# found hours later with the logs gone; this records the start time and grabs the stacks.
# It holds no wakelock and writes a line only when SF is actually burning CPU.
[ -x /data/local/sf-watch.sh ] && ! pgrep -f "[s]f-watch.sh" >/dev/null 2>&1 && \
  setsid sh /data/local/sf-watch.sh >/dev/null 2>&1 &

# SurfaceFlinger livelock patch (docs/INCIDENT-SF-LIVELOCK.md). The boot rc bind-mounts the
# patched library before SurfaceFlinger starts; on a boot.img that predates that rc line this
# fallback does it here and restarts the compositor ONCE (a framework restart, ~45 s, only when
# the running SurfaceFlinger maps a different file than the patched copy).
P=/data/local/libsurfaceflinger-patched.so
if [ -f "$P" ] && [ ! -e /dev/.sf-patch-tried ]; then
  touch /dev/.sf-patch-tried
  want=$(stat -c %i "$P"); have=$(grep libsurfaceflinger.so /proc/$(pidof surfaceflinger)/maps 2>/dev/null | head -1 | awk '{print $5}')
  if [ -n "$have" ] && [ "$have" != "$want" ]; then
    mount -o bind "$P" /system/lib/libsurfaceflinger.so && {
      echo "$(date) sf-patch: bind mounted, restarting surfaceflinger (mapped inode $have, want $want)" >> $L
      echo sf-patch > /sys/power/wake_lock; ( sleep 180; echo sf-patch > /sys/power/wake_unlock ) >/dev/null 2>&1 </dev/null &
      kill -9 $(pidof surfaceflinger)
    }
  else echo "$(date) sf-patch: already in service (inode $have)" >> $L; fi
fi

echo "$(date) done user_rotation=$(settings get system user_rotation)" >> $L
