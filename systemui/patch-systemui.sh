#!/bin/bash
# Add the front-light warmth slider to the Quick Settings panel, as a second line directly
# under the brightness slider.
#
# Works on YOUR OWN SystemUI.apk, the same way the TWRP and boot builders work on your own
# stock images -- because a patched SystemUI only matches the exact GSI build it came from,
# a prebuilt one cannot be shipped safely.
#
#   bash systemui/patch-systemui.sh <SystemUI.apk> <framework-res.apk> <out.apk>
#
# Pull both from the device after the GSI is installed:
#   adb pull /system/system_ext/priv-app/SystemUI/SystemUI.apk
#   adb pull /system/framework/framework-res.apk
#
# Needs: apktool 3.x, Android build-tools (zipalign, apksigner, d8), a JDK, and
# platforms/android-27/android.jar (any API >= 24 works; the class uses nothing newer).
set -euo pipefail
APK=${1:?usage: patch-systemui.sh <SystemUI.apk> <framework-res.apk> <out.apk>}
FW=${2:?usage: patch-systemui.sh <SystemUI.apk> <framework-res.apk> <out.apk>}
OUT=${3:?usage: patch-systemui.sh <SystemUI.apk> <framework-res.apk> <out.apk>}
HERE=$(cd "$(dirname "$0")" && pwd)
KEYS=$HERE/../keys
BT=${BT:-/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0}
AJ=${AJ:-/opt/homebrew/share/android-commandlinetools/platforms/android-27/android.jar}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

say() { printf '\n== %s\n' "$*"; }

say "compiling WarmthSliderView"
mkdir -p "$W/cls" "$W/dex"
javac -source 8 -target 8 -bootclasspath "$AJ" -classpath "$AJ" -d "$W/cls" \
      "$HERE/WarmthSliderView.java" 2>&1 | grep -v 'bootstrap class path' || true
"$BT/d8" --release --min-api 30 --output "$W/dex" $(find "$W/cls" -name '*.class')

say "converting it to smali"
( cd "$W/dex" && printf 'PK\5\6%.18s' '' > empty.zip && cp empty.zip carrier.apk \
  && zip -q carrier.apk classes.dex && apktool d -f -o smali-out carrier.apk >/dev/null )

say "decompiling SystemUI"
apktool if "$FW" >/dev/null
apktool d -f -o "$W/src" "$APK" >/dev/null

say "applying the patch"
mkdir -p "$W/src/smali/com/android/systemui/inkpalm"
cp "$W"/dex/smali-out/smali/com/android/systemui/inkpalm/*.smali \
   "$W/src/smali/com/android/systemui/inkpalm/"
# The layout gains one sibling view and no new resource id, so the resource table is untouched.
cp "$HERE/quick_settings_brightness_dialog.xml" \
   "$W/src/res/layout/quick_settings_brightness_dialog.xml"

say "rebuilding and signing with the platform key"
apktool b -f "$W/src" -o "$W/unsigned.apk" >/dev/null
"$BT/zipalign" -f -p 4 "$W/unsigned.apk" "$W/aligned.apk"
"$BT/apksigner" sign --key "$KEYS/platform.pk8" --cert "$KEYS/platform.x509.pem" \
                     --out "$OUT" "$W/aligned.apk"

WANT=$("$BT/apksigner" verify --print-certs "$APK" 2>/dev/null | grep -i 'SHA-1 digest' | head -1 | awk '{print $NF}')
GOT=$("$BT/apksigner" verify --print-certs "$OUT" 2>/dev/null | grep -i 'SHA-1 digest' | head -1 | awk '{print $NF}')
[ "$WANT" = "$GOT" ] || { echo "CERT MISMATCH: original $WANT, patched $GOT -- do not install" >&2; exit 1; }
echo
echo "wrote $OUT"
echo "  signing cert matches the original ($GOT), so android.uid.systemui still applies"
echo
echo "Install (keep the backups -- a bad SystemUI means no UI, though ADB survives):"
cat <<'EOS'
  adb push <out.apk> /sdcard/SystemUI-warm.apk
  adb shell su -c '
    D=/system/system_ext/priv-app/SystemUI
    mount -o rw,remount /system
    [ -f /data/local/SystemUI.apk.stock ] || cp -p $D/SystemUI.apk /data/local/SystemUI.apk.stock
    [ -d /data/local/SystemUI-oat.stock ] || cp -a $D/oat /data/local/SystemUI-oat.stock
    rm -rf $D/oat                      # stale odex would win over the new dex
    cp /sdcard/SystemUI-warm.apk $D/SystemUI.apk
    chmod 644 $D/SystemUI.apk; chown 0:0 $D/SystemUI.apk
    chcon u:object_r:system_file:s0 $D/SystemUI.apk
    sync; reboot'

Rollback:
  adb shell su -c '
    D=/system/system_ext/priv-app/SystemUI
    mount -o rw,remount /system
    cp /data/local/SystemUI.apk.stock $D/SystemUI.apk
    cp -a /data/local/SystemUI-oat.stock $D/oat
    chmod 644 $D/SystemUI.apk; chcon u:object_r:system_file:s0 $D/SystemUI.apk
    sync; reboot'
EOS
