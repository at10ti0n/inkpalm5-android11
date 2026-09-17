#!/bin/bash
# Run from your COMPUTER once Android 11 has finished its first boot and `adb devices`
# shows "device".  Installs the key layouts, touch config and tiles, then applies the
# native configuration (portrait, AOD, timeouts, radios off).  Safe to re-run.
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
adb push "$R/configs/sunxi-keyboard.kl"            /sdcard/
adb push "$R/configs/pmu1736-powerkey.kl"          /sdcard/
adb push "$R/configs/Vendor_dead_Product_beef.kl"  /sdcard/
adb push "$R/configs/Vendor_dead_Product_beef.idc" /sdcard/
adb push "$R/configs/a11-boot-fixups.sh"           /sdcard/
adb push "$R/configs/configure-native.sh"          /sdcard/

adb shell "su -c '
set -e
mkdir -p /data/system/devices/keylayout /data/system/devices/idc
cp /sdcard/sunxi-keyboard.kl /sdcard/pmu1736-powerkey.kl /sdcard/Vendor_dead_Product_beef.kl /data/system/devices/keylayout/
cp /sdcard/Vendor_dead_Product_beef.idc /data/system/devices/idc/
chown -R system:system /data/system/devices
chmod 644 /data/system/devices/keylayout/*.kl /data/system/devices/idc/*.idc
cp /sdcard/a11-boot-fixups.sh /data/local/a11-boot-fixups.sh
chmod 755 /data/local/a11-boot-fixups.sh
rm -f /sdcard/sunxi-keyboard.kl /sdcard/pmu1736-powerkey.kl /sdcard/Vendor_dead_Product_beef.kl /sdcard/Vendor_dead_Product_beef.idc /sdcard/a11-boot-fixups.sh
echo \"  input configs installed\"
'" | tr -d '\r'

say "installing the E-Ink tiles app"
adb install -r "$A/einktile.apk"
adb shell "su -c '
T=\$(settings get secure sysui_qs_tiles)
for t in ModeTile RefreshTile WarmthTile; do
  case \"\$T\" in *\$t*) ;; *) T=\"\$T,custom(net.inkpalm.einktile/.\$t)\";; esac
done
settings put secure sysui_qs_tiles \"\$T\"
echo \"  tiles: \$(settings get secure sysui_qs_tiles | tr , \"\n\" | grep -c einktile) registered\"
'" | tr -d '\r'

say "applying the native configuration (portrait, AOD, timeouts, radios off)"
adb shell "su -c 'sh /sdcard/configure-native.sh && rm -f /sdcard/configure-native.sh && echo \"  configure-native done\"'" | tr -d '\r'
adb shell "su -c 'sh /data/local/a11-boot-fixups.sh; echo \"  startup settings applied\"'" | tr -d '\r'
adb shell "su -c 'setprop persist.sys.frontlight.warm 10'"

say "rebooting to apply rotation and input configuration"
adb shell "su -c 'sync; reboot'" 2>/dev/null || true
echo "When it comes back it should be PORTRAIT, touch aligned, with the brightness slider"
echo "and the Mode / Refresh / Warmth tiles working."
