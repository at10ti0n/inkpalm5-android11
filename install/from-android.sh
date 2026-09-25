#!/bin/bash
# Run from your COMPUTER once Android 11 has finished its first boot and `adb devices`
# shows "device".  Installs the key layouts, touch config and tiles, then applies the
# native configuration (portrait, standby image, timeouts, radios off).  Safe to re-run.
# Usage:   bash install/from-android.sh <assets-dir>
set -euo pipefail
A=${1:?usage: from-android.sh <assets-dir>}
R=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$A/einktile.apk" ] || { echo "missing: $A/einktile.apk" >&2; exit 1; }
[ "$(adb get-state 2>/dev/null)" = device ] || { echo "device not in Android (adb devices should show 'device')" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }

say "waiting for boot to complete"
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 5; done

say "pushing input configs and the startup script"
adb push "$R/configs/sunxi-gpadc0.kl" /sdcard/
adb push "$R/configs/sunxi-keyboard.kl"            /sdcard/
adb push "$R/configs/pmu1736-powerkey.kl"          /sdcard/
adb push "$R/configs/Vendor_dead_Product_beef.kl"  /sdcard/
adb push "$R/configs/Vendor_dead_Product_beef.idc" /sdcard/
adb push "$R/configs/a11-boot-fixups.sh"           /sdcard/
adb push "$R/tools/sf-watch.sh"                    /sdcard/
adb push "$R/tools/sf-capture.sh"                  /sdcard/
[ -f "$R/tools/threadregs.bin" ] && adb push "$R/tools/threadregs.bin" /sdcard/
adb push "$R/configs/configure-native.sh"          /sdcard/
# Optional: the SurfaceFlinger livelock patch (docs/INCIDENT-SF-LIVELOCK.md). Pulls the GSI's own
# library, patches one instruction on this machine (hash-checked both ways), stages it where the
# boot rc bind-mounts it before SurfaceFlinger starts. Takes effect at the next boot of a boot.img
# built from a11boot/a11-prepend.rc that carries the bind line.
if [ "${SF_PATCH:-0}" = 1 ]; then
  t=$(mktemp -d); adb pull /system/lib/libsurfaceflinger.so "$t/stock.so" >/dev/null
  python3 "$R/a11boot/patch-sf.py" "$t/stock.so" "$t/patched.so"
  adb push "$t/patched.so" /data/local/tmp/libsurfaceflinger-patched.so >/dev/null
  adb shell "su -c 'mv /data/local/tmp/libsurfaceflinger-patched.so /data/local/libsurfaceflinger-patched.so; chown root:root /data/local/libsurfaceflinger-patched.so; chmod 644 /data/local/libsurfaceflinger-patched.so; sha256sum /data/local/libsurfaceflinger-patched.so | cut -c1-16'" | tr -d '\r'
  rm -rf "$t"; echo "  SurfaceFlinger patch staged (active after a reboot on a boot.img with the bind line)"
fi

adb shell "su -c '
set -e
mkdir -p /data/system/devices/keylayout /data/system/devices/idc
cp /sdcard/sunxi-gpadc0.kl /sdcard/sunxi-keyboard.kl /sdcard/pmu1736-powerkey.kl /sdcard/Vendor_dead_Product_beef.kl /data/system/devices/keylayout/
cp /sdcard/Vendor_dead_Product_beef.idc /data/system/devices/idc/
chown -R system:system /data/system/devices
chmod 644 /data/system/devices/keylayout/*.kl /data/system/devices/idc/*.idc
cp /sdcard/a11-boot-fixups.sh /data/local/a11-boot-fixups.sh
cp /sdcard/sf-watch.sh /data/local/sf-watch.sh
cp /sdcard/sf-capture.sh /data/local/sf-capture.sh
[ -f /sdcard/threadregs.bin ] && cp /sdcard/threadregs.bin /data/local/threadregs && chmod 755 /data/local/threadregs
chmod 755 /data/local/a11-boot-fixups.sh /data/local/sf-watch.sh /data/local/sf-capture.sh
rm -f /sdcard/sf-watch.sh /sdcard/sf-capture.sh /sdcard/threadregs.bin /sdcard/sunxi-gpadc0.kl /sdcard/sunxi-keyboard.kl /sdcard/pmu1736-powerkey.kl /sdcard/Vendor_dead_Product_beef.kl /sdcard/Vendor_dead_Product_beef.idc /sdcard/a11-boot-fixups.sh
echo \"  input configs installed\"
'" | tr -d '\r'

say "installing the E-Ink tiles app"
adb install -r "$A/einktile.apk"
# The full Quick Settings panel for an E Ink reader (docs/A11-NATIVE-FEATURES-PROPOSAL.md):
# Orientation, Mode, Refresh, Wi-Fi, Bluetooth, DND, Battery Saver, Airplane, Screen Temperature
# (the stock Night Light tile, renamed). Cast, Screen Record, Dark theme and phh's debug tile
# are not on it; overlays/screentemp-systemui also trims the Edit list to this hardware.
adb shell "su -c '
E=net.inkpalm.einktile
settings put secure sysui_qs_tiles \"custom(\$E/.RotationTile),custom(\$E/.ModeTile),custom(\$E/.RefreshTile),wifi,bt,dnd,battery,airplane,night\"
echo \"  tiles: \$(settings get secure sysui_qs_tiles)\"
'" | tr -d '\r'

# Wi-Fi: the 8.1 vendor wpa_supplicant double-frees in its SIGTERM cleanup, which Android 11's
# allocator turns into a crash and a tombstone at every reboot. wifi/libwpaexit.c makes SIGTERM
# exit immediately (wifi/README.md). Vendor partition; the original rc is kept in /data/local.
if [ -f "$A/libwpaexit.so" ]; then
  say "Wi-Fi daemon: clean exit at shutdown"
  adb push "$A/libwpaexit.so" /data/local/tmp/libwpaexit.so >/dev/null
  adb shell "su -c '
  R=/vendor/etc/init/hw/init.common.rc
  [ -f /data/local/init.common.rc.stock ] || cp -p \$R /data/local/init.common.rc.stock
  mount -o rw,remount /vendor
  cp /data/local/tmp/libwpaexit.so /vendor/lib/libwpaexit.so
  chmod 644 /vendor/lib/libwpaexit.so; chown 0:0 /vendor/lib/libwpaexit.so; chcon u:object_r:vendor_file:s0 /vendor/lib/libwpaexit.so
  grep -q libwpaexit \$R || sed -i \"/^service wpa_supplicant /,/^ *oneshot/ s|^\\( *\\)oneshot|\\1oneshot\\n\\1setenv LD_PRELOAD /vendor/lib/libwpaexit.so|\" \$R
  sync; mount -o ro,remount /vendor; rm -f /data/local/tmp/libwpaexit.so
  grep -q libwpaexit \$R && echo \"  installed (active after the next reboot)\"
  '" | tr -d '\r'
fi

# No modem: config_mobile_data_capable=false (overlays/nomodem), so Android creates no phone/RIL
# and the phone process stops waiting on the IRadio HAL that rild (stopped by the boot fixups)
# would provide. Static framework overlay: must be preinstalled in /vendor/overlay.
if [ -f "$A/inkpalm-nomodem.apk" ]; then
  say "no-modem overlay"
  adb push "$A/inkpalm-nomodem.apk" /data/local/tmp/inkpalm-nomodem.apk >/dev/null
  adb shell "su -c '
  mount -o rw,remount /vendor
  cp /data/local/tmp/inkpalm-nomodem.apk /vendor/overlay/inkpalm-nomodem.apk
  chmod 644 /vendor/overlay/inkpalm-nomodem.apk; chown 0:0 /vendor/overlay/inkpalm-nomodem.apk
  chcon u:object_r:vendor_overlay_file:s0 /vendor/overlay/inkpalm-nomodem.apk
  sync; mount -o ro,remount /vendor; rm -f /data/local/tmp/inkpalm-nomodem.apk
  echo \"  installed (active after the next reboot)\"
  '" | tr -d '\r'
fi

# Screen Temperature = Night Light driving the front light's warm LEDs. Three overlays, all
# signed with the GSI platform key: the framework one (identity tint, so Night Light no longer
# darkens the greyscale panel) must be PREINSTALLED in /vendor/overlay -- MEASURED: system_server
# ignores /data overlays for its own resources on Android 11; the Settings and SystemUI ones
# (the "Screen Temperature" name, the trimmed tile list) work as ordinary packages.
say "Screen Temperature (Night Light -> warm LEDs)"
for o in screentemp-settings screentemp-systemui; do
  [ -f "$A/inkpalm-$o.apk" ] && adb install -r "$A/inkpalm-$o.apk" | tail -1
done
if [ -f "$A/inkpalm-screentemp-fw.apk" ]; then
  adb push "$A/inkpalm-screentemp-fw.apk" /data/local/tmp/inkpalm-screentemp.apk >/dev/null
  adb shell "su -c '
  mount -o rw,remount /vendor
  cp /data/local/tmp/inkpalm-screentemp.apk /vendor/overlay/inkpalm-screentemp.apk
  chmod 644 /vendor/overlay/inkpalm-screentemp.apk; chown 0:0 /vendor/overlay/inkpalm-screentemp.apk
  chcon u:object_r:vendor_overlay_file:s0 /vendor/overlay/inkpalm-screentemp.apk
  sync; mount -o ro,remount /vendor; rm -f /data/local/tmp/inkpalm-screentemp.apk
  cmd overlay enable --user 0 net.inkpalm.overlay.screentemp.settings
  cmd overlay enable --user 0 net.inkpalm.overlay.screentemp.systemui
  echo \"  overlays installed (the framework one takes effect after the next reboot)\"
  '" | tr -d '\r'
fi

say "applying the native configuration (portrait, AOD, timeouts, radios off)"
adb shell "su -c 'sh /sdcard/configure-native.sh && rm -f /sdcard/configure-native.sh && echo \"  configure-native done\"'" | tr -d '\r'
adb shell "su -c 'sh /data/local/a11-boot-fixups.sh; echo \"  startup settings applied\"'" | tr -d '\r'

# Standby image: with doze off the device sleeps on the keyguard and the E Ink panel keeps
# that frame, so the lock-screen wallpaper IS the standby screen. Android 11 has no shell
# command for lock wallpapers; einktile (system UID) sets it from a file on broadcast.
# Replace docs/images/standby.png with any 720x1280 image to change it.
say "standby image (lock-screen wallpaper)"
adb push "$R/docs/images/standby.png" /data/local/tmp/standby.png >/dev/null
adb shell "su -c '
chmod 0644 /data/local/tmp/standby.png
am broadcast -n net.inkpalm.einktile/.LockWallpaperReceiver -a net.inkpalm.einktile.SET_LOCK_WALLPAPER --include-stopped-packages --es path /data/local/tmp/standby.png >/dev/null 2>&1
sleep 3
grep -q \"<kwp\" /data/system/users/0/wallpaper_info.xml && echo \"  lock wallpaper set\" || echo \"  lock wallpaper NOT set (is einktile v4+ installed?)\"
# Unlauncher repaints BOTH wallpapers plain white every time it resumes unless its
# KEEP_DEVICE_WALLPAPER preference (proto field 2) is on. Set it if the launcher is present.
P=/data/data/com.jkuester.unlauncher/files/datastore/core_preferences.proto
if [ -d \$(dirname \$P) ]; then
  am force-stop com.jkuester.unlauncher
  if [ ! -f \$P ] || ! od -An -tx1 \$P | tr -d \" \\n\" | grep -q 1001; then
    printf \"\\020\\001\" >> \$P
    chown \$(stat -c %U:%G /data/data/com.jkuester.unlauncher) \$P; chmod 600 \$P
    echo \"  Unlauncher: keep-device-wallpaper enabled\"
  fi
fi
'" | tr -d '\r'

# The warmth slider lives inside SystemUI, and a patched SystemUI only matches the exact
# GSI build it was decompiled from -- so this replaces SystemUI ONLY when the one on the
# device is byte-for-byte the build this APK was made from. Any other GSI is left alone.
STOCK_SYSUI_SHA=6fb1830ec147e77699393d95de92d04ef99deac02e32e19576f19e93a1389d16
# v2.3 shipped a patched SystemUI (warmth slider + hidden clock); upgrading from it is allowed.
V23_SYSUI_SHA=ff609d49f517f2a546990e0f29da71c1fb3088b729eabf86489103bf6056d587
if [ -f "$A/SystemUI-warmth.apk" ]; then
  say "front-light warmth slider in Quick Settings"
  CUR=$(adb shell "su -c 'sha256sum /system/system_ext/priv-app/SystemUI/SystemUI.apk'" 2>/dev/null | tr -d '\r' | grep -oE '^[0-9a-f]{64}' | head -1)
  OURS=$(shasum -a256 "$A/SystemUI-warmth.apk" | cut -d' ' -f1)
  if [ "$CUR" = "$OURS" ]; then
    echo "  already installed"
  elif [ "$CUR" != "$STOCK_SYSUI_SHA" ] && [ "$CUR" != "$V23_SYSUI_SHA" ]; then
    echo "  SKIPPED -- your SystemUI.apk is not the GSI build this was built against."
    echo "    on device: ${CUR:-<unreadable>}"
    echo "    expected:  $STOCK_SYSUI_SHA (stock) or $V23_SYSUI_SHA (v2.3)"
    echo "    Brightness and Screen Temperature (tile, Settings > Display) still work; for the"
    echo "    slider row, build one against your own SystemUI with systemui/patch-systemui.sh."
  else
    adb push "$A/SystemUI-warmth.apk" /sdcard/SystemUI-warmth.apk
    adb shell "su -c '
      set -e
      D=/system/system_ext/priv-app/SystemUI
      mount -o rw,remount /system
      [ -f /data/local/SystemUI.apk.stock ] || cp -p \$D/SystemUI.apk /data/local/SystemUI.apk.stock
      [ -d /data/local/SystemUI-oat.stock ] || cp -a \$D/oat /data/local/SystemUI-oat.stock
      rm -rf \$D/oat
      cp /sdcard/SystemUI-warmth.apk \$D/SystemUI.apk
      chmod 644 \$D/SystemUI.apk; chown 0:0 \$D/SystemUI.apk
      chcon u:object_r:system_file:s0 \$D/SystemUI.apk
      rm -f /sdcard/SystemUI-warmth.apk; sync
      echo \"  installed (original saved to /data/local/SystemUI.apk.stock)\"
    '" | tr -d '\r'
  fi
fi

# Power press -> lock screen first, then sleep (E Ink keeps the last frame through sleep).
# Same rule as SystemUI: only onto the exact GSI build it was patched from.
STOCK_SERVICES_SHA=ac34b0f57e09fc32ff1e024736f7114e30464c973406e0a3204cd1d5848518d4
if [ -f "$A/services-powerpress.jar" ]; then
  say "standby image on power press (framework patch)"
  CUR=$(adb shell "su -c 'sha256sum /system/framework/services.jar'" 2>/dev/null | tr -d '\r' | grep -oE '^[0-9a-f]{64}' | head -1)
  OURS=$(shasum -a256 "$A/services-powerpress.jar" | cut -d' ' -f1)
  if [ "$CUR" = "$OURS" ]; then
    echo "  already installed"
  elif [ "$CUR" != "$STOCK_SERVICES_SHA" ]; then
    echo "  SKIPPED -- your services.jar is not the GSI build this was built against."
    echo "    on device: ${CUR:-<unreadable>}"
    echo "    expected:  $STOCK_SERVICES_SHA"
    echo "    The device will sleep showing the last app instead of the standby image; build"
    echo "    one against your own services.jar with framework/patch-services.sh (BUILDING.md)."
  else
    adb push "$A/services-powerpress.jar" /data/local/tmp/services-patched.jar >/dev/null
    adb shell "su -c '
      set -e
      F=/system/framework
      mount -o rw,remount /system
      [ -f /data/local/services.jar.stock ] || cp -p \$F/services.jar /data/local/services.jar.stock
      [ -d /data/local/services-oat.stock ] || { mkdir -p /data/local/services-oat.stock; cp -p \$F/oat/arm/services.* /data/local/services-oat.stock/; }
      rm -f \$F/oat/arm/services.odex \$F/oat/arm/services.vdex \$F/oat/arm/services.art
      cp /data/local/tmp/services-patched.jar \$F/services.jar
      chmod 644 \$F/services.jar; chown 0:0 \$F/services.jar; chcon u:object_r:system_file:s0 \$F/services.jar
      sync
      echo \"  installed (stock jar + odex backed up under /data/local)\"
    '" | tr -d '\r'
  fi
fi

say "rebooting"
adb shell "su -c 'sync; reboot'" 2>/dev/null || true
echo "When it comes back it should be PORTRAIT, touch aligned, with Brightness and Screen"
echo "Temperature sliders in Quick Settings and the Mode / Refresh tiles working."
