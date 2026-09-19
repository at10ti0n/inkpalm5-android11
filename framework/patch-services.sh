#!/bin/bash
# Make a short power press -- and the idle timeout -- show the lock screen BEFORE the
# display goes off, so the E Ink panel holds the standby image through sleep instead of the
# app that was open.
#
# Unpatched Android shows the keyguard and switches the display off at the same time; on
# E Ink the last composited frame is what stays, and the keyguard loses that race every
# time. The patch (framework/patch-powerpress.py + InkpalmSleep.smali) makes powerPress
# call lockNow() and sleep 800 ms later; on the lock screen already, it sleeps at once.
#
# Works on YOUR OWN services.jar, like systemui/patch-systemui.sh -- a patched jar only
# matches the GSI build it came from.
#
#   bash framework/patch-services.sh <services.jar> <out.jar>
#   adb pull /system/framework/services.jar        # after the GSI is installed
#
# Needs apktool 3.x and Android build-tools (dexdump, for the self-check).
set -euo pipefail
JAR=${1:?usage: patch-services.sh <services.jar> <out.jar>}
OUT=${2:?usage: patch-services.sh <services.jar> <out.jar>}
HERE=$(cd "$(dirname "$0")" && pwd)
BT=${BT:-/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
say() { printf '\n== %s\n' "$*"; }

say "decompiling services.jar (a minute or two)"
apktool d -f -o "$W/src" "$JAR" >/dev/null
PWM=$(find "$W/src" -name PhoneWindowManager.smali | head -1)
PMS=$(find "$W/src" -name PowerManagerService.smali | head -1)
[ -n "$PWM" ] && [ -n "$PMS" ] || { echo "PhoneWindowManager/PowerManagerService smali not found" >&2; exit 1; }

say "applying the patch (power press + idle timeout)"
cp "$HERE/InkpalmDelayedSleep.smali" "$(dirname "$PMS")/InkpalmDelayedSleep.smali"
python3 "$HERE/patch-powerpress.py" "$PWM" "$PMS"

say "rebuilding"
apktool b -f "$W/src" -o "$OUT" >/dev/null
# (dexdump's output goes to a file: grep -q closing the pipe early would trip pipefail)
( cd "$W" && unzip -q -o "$OUT" classes.dex && "$BT/dexdump" -d classes.dex > dump.txt 2>/dev/null && grep -q "PowerManagerService;.inkpalmFire" dump.txt && grep -q "PowerManagerService;.inkpalmArm" dump.txt ) \
  || { echo "self-check failed: patched method not in classes.dex" >&2; exit 1; }
echo
echo "wrote $OUT  (sha256 $(shasum -a256 "$OUT" | cut -c1-16))"
cat <<'EOS'

Install (keeps backups; a broken services.jar means no Android UI, but ADB survives):
  adb push <out.jar> /data/local/tmp/services-patched.jar
  adb shell su -c '
    F=/system/framework
    mount -o rw,remount /system
    [ -f /data/local/services.jar.stock ] || cp -p $F/services.jar /data/local/services.jar.stock
    [ -d /data/local/services-oat.stock ] || { mkdir -p /data/local/services-oat.stock; cp -p $F/oat/arm/services.* /data/local/services-oat.stock/; }
    rm -f $F/oat/arm/services.odex $F/oat/arm/services.vdex $F/oat/arm/services.art   # stale odex would win
    cp /data/local/tmp/services-patched.jar $F/services.jar
    chmod 644 $F/services.jar; chown 0:0 $F/services.jar; chcon u:object_r:system_file:s0 $F/services.jar
    sync; reboot'

Rollback:
  adb shell su -c '
    F=/system/framework
    mount -o rw,remount /system
    cp /data/local/services.jar.stock $F/services.jar
    cp -p /data/local/services-oat.stock/services.* $F/oat/arm/
    chmod 644 $F/services.jar; chcon u:object_r:system_file:s0 $F/services.jar
    sync; reboot'
EOS
