#!/system/bin/sh
# Device side of the Android 11 configuration step. Runs as root ON THE DEVICE, from the
# staging directory the host installer (install/inkpalm.py) pushed. Every host OS uses this
# same script, so no shell quoting passes through adb.
#
#   sh configure.sh <staging-dir>        environment: FIRST_TIME=1 applies the one-time defaults
#
# The staging dir holds the repo's configs and the release assets, plus optional
# libsurfaceflinger-patched.so and services-orient.jar (+ .sha256) that the host patched.
# Safe to re-run: each step checks before it writes and keeps the originals in /data/local.
D=${1:?usage: configure.sh <staging-dir>}
cd "$D" || exit 1
say() { echo; echo "== $*"; }
put() {  # put <src> <dst> <selinux type>: install as root:root 0644 with the given label
  # Never rewrite a file in place: a running process (wpa_supplicant with libwpaexit.so,
  # system_server with an overlay) has it mapped, and truncating it corrupts that process
  # (MEASURED 2026-10-03: wpa_supplicant SIGSEGV in libwpaexit after an in-place copy).
  # Identical files are left alone; changed ones get a new file renamed over the old name.
  [ -f "$2" ] && [ "$(sha "$1")" = "$(sha "$2")" ] && return 0
  cp "$1" "$2.new" && chmod 644 "$2.new" && chown 0:0 "$2.new" && chcon "u:object_r:$3:s0" "$2.new" && mv "$2.new" "$2"
}
rw() { mount -o rw,remount "$1"; }
ro() { sync; mount -o ro,remount "$1" 2>/dev/null; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

say "input configs and startup scripts"
mkdir -p /data/system/devices/keylayout /data/system/devices/idc
cp sunxi-gpadc0.kl sunxi-keyboard.kl pmu1736-powerkey.kl Vendor_dead_Product_beef.kl /data/system/devices/keylayout/
cp Vendor_dead_Product_beef.idc /data/system/devices/idc/
chown -R system:system /data/system/devices
chmod 644 /data/system/devices/keylayout/*.kl /data/system/devices/idc/*.idc
# sf-watch.sh runs permanently: replace by rename, never rewrite it under the running shell.
for f in a11-boot-fixups.sh sf-watch.sh sf-capture.sh; do cp $f /data/local/$f.new && chmod 755 /data/local/$f.new && mv /data/local/$f.new /data/local/$f; done
[ -f threadregs.bin ] && cp threadregs.bin /data/local/threadregs.new && chmod 755 /data/local/threadregs.new && mv /data/local/threadregs.new /data/local/threadregs
echo "  installed"

if [ -f libsurfaceflinger-patched.so ]; then
  say "SurfaceFlinger freeze workaround (staged; the boot image mounts it at the next boot)"
  # /data/local/libsurfaceflinger-patched.so is bind-mounted over the running SurfaceFlinger's
  # library: never write it in place (truncating a mapped library crashes the process).
  T=/data/local/libsurfaceflinger-patched.so
  if [ -f $T ] && [ "$(sha libsurfaceflinger-patched.so)" = "$(sha $T)" ]; then echo "  already staged"
  elif cp libsurfaceflinger-patched.so $T.new && chown root:root $T.new && chmod 644 $T.new && mv $T.new $T; then
    echo "  staged ($(sha $T | cut -c1-16))"
  else rm -f $T.new; echo "  FAILED to stage (previous copy, if any, unchanged)"; fi
fi

say "E-Ink tiles app"
pm install -r einktile.apk | tail -1
E=net.inkpalm.einktile
# The Quick Settings panel for an E Ink reader (docs/A11-NATIVE-FEATURES-PROPOSAL.md).
settings put secure sysui_qs_tiles "custom($E/.RotationTile),custom($E/.ModeTile),custom($E/.RefreshTile),wifi,bt,dnd,battery,airplane,night"
# Hold the Moaan logo (Home) = full refresh: einktile v7's key-only accessibility service.
S=$E/$E.HomeKeyService
C=$(settings get secure enabled_accessibility_services)
case "$C" in *"$S"*) ;; null|"") settings put secure enabled_accessibility_services "$S" ;; *) settings put secure enabled_accessibility_services "$C:$S" ;; esac
settings put secure accessibility_enabled 1
echo "  tiles set; hold-the-logo refresh on"

if [ -f libwpaexit.so ]; then
  # 8.1's wpa_supplicant double-frees on SIGTERM; Android 11's allocator turns that into a
  # crash at every shutdown. The preload exits immediately instead (wifi/README.md).
  say "Wi-Fi daemon: clean exit at shutdown"
  R=/vendor/etc/init/hw/init.common.rc
  [ -f /data/local/init.common.rc.stock ] || cp -p $R /data/local/init.common.rc.stock
  rw /vendor
  put libwpaexit.so /vendor/lib/libwpaexit.so vendor_file
  grep -q libwpaexit $R || sed -i '/^service wpa_supplicant /,/^ *oneshot/ s|^\( *\)oneshot|\1oneshot\n\1setenv LD_PRELOAD /vendor/lib/libwpaexit.so|' $R
  ro /vendor
  grep -q libwpaexit $R && echo "  installed" || echo "  NOT installed (rc layout differs)"
fi

if [ -f libhwcflip.so ]; then
  # The display shim (frame mirror + software vsync) is loaded by the running composer: put()
  # installs a changed copy by rename, active after the reboot. Identical copies are skipped.
  say "display shim (/vendor/lib/libhwcflip.so)"
  rw /vendor
  if [ "$(sha libhwcflip.so)" = "$(sha /vendor/lib/libhwcflip.so)" ]; then echo "  already installed"
  else put libhwcflip.so /vendor/lib/libhwcflip.so vendor_file && echo "  updated (active after the reboot)"; fi
  ro /vendor
fi

say "framework overlays in /vendor/overlay (no modem, Screen Temperature tint, suspend policy)"
# Static overlays: system_server only reads its own resources from preinstalled overlays.
rw /vendor
for o in nomodem:inkpalm-nomodem.apk screentemp-fw:inkpalm-screentemp.apk power:inkpalm-power.apk; do
  src=inkpalm-${o%%:*}.apk; dst=/vendor/overlay/${o#*:}
  if [ -f "$src" ]; then put "$src" "$dst" vendor_overlay_file && echo "  ${o#*:}"; fi
done
ro /vendor

say "Screen Temperature names and tile list (ordinary overlay packages)"
for o in screentemp-settings screentemp-systemui; do
  [ -f inkpalm-$o.apk ] && pm install -r inkpalm-$o.apk | tail -1
done
# A freshly installed overlay is not always registered yet; wait for each and check.
for o in net.inkpalm.overlay.screentemp.settings net.inkpalm.overlay.screentemp.systemui; do
  pm path $o >/dev/null 2>&1 || continue
  i=0
  until cmd overlay list | grep -q "\[x\] $o"; do
    [ $i -ge 15 ] && break
    cmd overlay enable --user 0 $o >/dev/null 2>&1; sleep 2; i=$((i+1))
  done
  cmd overlay list | grep -q "\[x\] $o" && echo "  $o: enabled" || echo "  $o: NOT ENABLED -- re-run, or: cmd overlay enable $o"
done

if [ -f zz-inkpalm-profiles.rc ]; then
  # Apps could not record JIT profiles: phh's apex-setup.rc loses the /data_mirror/cur_profiles
  # mount (configs/zz-inkpalm-profiles.rc). Takes effect at the next boot.
  say "app usage profiles (JIT profile mirror)"
  rw /system
  put zz-inkpalm-profiles.rc /system/etc/init/zz-inkpalm-profiles.rc system_file && echo "  installed"
fi

say "kernel suspend: SystemSuspend start order (docs/NATIVE-A11-SECOND-PASS.md)"
RC=/system/etc/init/android.system.suspend@1.0-service.rc
STOCK_RC=c7164caf27ccdc9df71555d54006d087be131ef0afa5bd380b42bb9c5726eb67
CUR=$(sha $RC); OURS=$(sha android.system.suspend@1.0-service.rc)
if [ "$CUR" = "$OURS" ]; then echo "  already installed"
elif [ "$CUR" != "$STOCK_RC" ]; then echo "  SKIPPED -- $RC is not the GSI's own (${CUR:-unreadable}); change class early_hal to class hal by hand"
else
  rw /system
  [ -f /data/local/system-suspend.rc.stock ] || cp -p $RC /data/local/system-suspend.rc.stock
  put android.system.suspend@1.0-service.rc $RC system_file && echo "  installed (original in /data/local/system-suspend.rc.stock)"
fi

if [ -f libsffencefinish.so ]; then
  # Input lag: the vendor composer waited up to 3 s for SurfaceFlinger's GPU composition fence
  # (docs/INPUT-LATENCY.md). The preload calls glFinish() before that fence is handed over
  # (a11boot/libsffencefinish.c); why the fence was late is not established. One setenv line in the GSI's
  # own surfaceflinger.rc; any other rc is left alone. Takes effect after the reboot.
  say "display latency fix (SurfaceFlinger preload)"
  SRC=/system/etc/init/surfaceflinger.rc
  STOCK_SF_RC=f654d2f950e74e27f5f9a6124a7193769b8cd29b2558d3758580fdf526448cf7
  rw /system
  put libsffencefinish.so /system/lib/libsffencefinish.so system_lib_file
  # Only point SurfaceFlinger at the library once it is verifiably in place.
  if [ "$(sha /system/lib/libsffencefinish.so)" != "$(sha libsffencefinish.so)" ]; then echo "  FAILED to install /system/lib/libsffencefinish.so -- surfaceflinger.rc left unchanged"
  elif grep -q libsffencefinish $SRC; then echo "  already installed"
  elif [ "$(sha $SRC)" != "$STOCK_SF_RC" ]; then echo "  SKIPPED -- $SRC is not the GSI v313 file; add 'setenv LD_PRELOAD /system/lib/libsffencefinish.so' to the surfaceflinger service by hand"
  else
    [ -f /data/local/surfaceflinger.rc.stock ] || cp -p $SRC /data/local/surfaceflinger.rc.stock
    sed 's|^    task_profiles HighPerformance|    task_profiles HighPerformance\n    setenv LD_PRELOAD /system/lib/libsffencefinish.so|' $SRC > $SRC.new
    if grep -q libsffencefinish $SRC.new; then
      chmod 644 $SRC.new; chown 0:0 $SRC.new; chcon u:object_r:system_file:s0 $SRC.new; mv $SRC.new $SRC
      echo "  installed (original in /data/local/surfaceflinger.rc.stock)"
    else rm -f $SRC.new; echo "  SKIPPED -- unexpected rc layout"; fi
  fi
fi

if [ "${FIRST_TIME:-0}" = 1 ]; then
  say "one-time defaults (portrait, AOD off, timeouts, radios off)"
  sh configure-native.sh && echo "  done"
else
  say "one-time defaults: skipped (an update keeps your settings)"
fi
sh /data/local/a11-boot-fixups.sh; echo "  startup settings applied"
# The vendor composer logs ~10 verbose lines per frame; logd spent ~19 ms CPU per panel update on
# them (MEASURED 2026-10-05: 4.4 ms with this tag at Info). Debugging the display path:
#   setprop persist.log.tag.sunxihwc_eink ""   (verbose again; it is what showed the 3 s wait)
setprop persist.log.tag.sunxihwc_eink I

say "standby image (lock-screen wallpaper)"
if [ "${FIRST_TIME:-0}" != 1 ] && grep -q "<kwp" /data/system/users/0/wallpaper_info.xml 2>/dev/null; then
  echo "  kept your current lock-screen image"
else
cp standby.png /data/local/tmp/standby.png; chmod 0644 /data/local/tmp/standby.png
am broadcast -n $E/.LockWallpaperReceiver -a $E.SET_LOCK_WALLPAPER --include-stopped-packages --es path /data/local/tmp/standby.png >/dev/null 2>&1
sleep 3
grep -q "<kwp" /data/system/users/0/wallpaper_info.xml && echo "  lock wallpaper set" || echo "  lock wallpaper NOT set"
fi
# Unlauncher repaints both wallpapers white on resume unless KEEP_DEVICE_WALLPAPER (proto
# field 2) is on.
P=/data/data/com.jkuester.unlauncher/files/datastore/core_preferences.proto
if [ -d "$(dirname $P)" ]; then
  am force-stop com.jkuester.unlauncher
  if [ ! -f $P ] || ! od -An -tx1 $P | tr -d " \n" | grep -q 1001; then
    printf "\020\001" >> $P
    chown "$(stat -c %U:%G /data/data/com.jkuester.unlauncher)" $P; chmod 600 $P
    echo "  Unlauncher: keep-device-wallpaper enabled"
  fi
fi

if [ -f SystemUI-warmth.apk ]; then
  # A patched SystemUI only matches the GSI build it was made from: stock v313, or v2.3's.
  say "Screen Temperature slider (patched SystemUI)"
  SUI=/system/system_ext/priv-app/SystemUI
  CUR=$(sha $SUI/SystemUI.apk); OURS=$(sha SystemUI-warmth.apk)
  case "$CUR" in
    "$OURS") echo "  already installed" ;;
    6fb1830ec147e77699393d95de92d04ef99deac02e32e19576f19e93a1389d16|ff609d49f517f2a546990e0f29da71c1fb3088b729eabf86489103bf6056d587)
      rw /system
      [ -f /data/local/SystemUI.apk.stock ] || cp -p $SUI/SystemUI.apk /data/local/SystemUI.apk.stock
      [ -d /data/local/SystemUI-oat.stock ] || cp -a $SUI/oat /data/local/SystemUI-oat.stock
      rm -rf $SUI/oat
      put SystemUI-warmth.apk $SUI/SystemUI.apk system_file && echo "  installed (original in /data/local/SystemUI.apk.stock)" ;;
    *) echo "  SKIPPED -- this SystemUI.apk is not the GSI v313 build (${CUR:-unreadable}); the tile and Settings still work" ;;
  esac
fi

if [ -f services-orient.jar ]; then
  say "full-screen apps that ask for the natural orientation (framework patch)"
  F=/system/framework
  if [ "$(sha services-orient.jar)" != "$(cat services-orient.jar.sha256)" ]; then echo "  transfer hash mismatch, SKIPPED"
  else
    rw /system
    cp -p $F/services.jar /data/local/services.jar.pre-orient
    mkdir -p /data/local/services-oat.pre-orient
    for x in odex vdex art; do [ -f $F/oat/arm/services.$x ] && mv $F/oat/arm/services.$x /data/local/services-oat.pre-orient/; done
    put services-orient.jar $F/services.jar system_file && echo "  installed (original kept as /data/local/services.jar.pre-orient)"
  fi
fi
sync
echo; echo "== configuration finished"
