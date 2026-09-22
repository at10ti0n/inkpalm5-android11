#!/bin/bash
# Show a dedicated standby overlay before power-button / idle-timeout sleep.
# StandbyScreen observes the window presentation and subsequent panel power-down.
# The PMS handler has an independent bounded fallback; see docs/STANDBY-IMAGE.md.
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
JAR=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$JAR")
OUT=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT")
[ "$JAR" != "$OUT" ] || { echo "Use a separate output file" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
BT=${BT:-/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0}
AJ=${AJ:-/opt/homebrew/share/android-commandlinetools/platforms/android-27/android.jar}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
say() { printf '\n== %s\n' "$*"; }

# Exact input reviewed on this PHH v313 build. Never stack this on an old delay patch.
WANT=ac34b0f57e09fc32ff1e024736f7114e30464c973406e0a3204cd1d5848518d4
GOT=$(shasum -a256 "$JAR" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || { echo "Unreviewed services.jar: $GOT" >&2; exit 1; }

say "compiling the standalone render / completion worker"
mkdir -p "$W/cls" "$W/dex"
javac -source 8 -target 8 -bootclasspath "$AJ" -d "$W/cls" "$HERE/StandbyScreen.java"
"$BT/d8" --release --min-api 30 --output "$W/dex" "$W"/cls/com/android/server/power/*.class
(cd "$W/dex" && zip -q carrier.apk classes.dex && apktool d -f -o smali-out carrier.apk >/dev/null)

say "decompiling services.jar (a minute or two)"
apktool d -f -o "$W/src" "$JAR" >/dev/null
PWM=$(find "$W/src" -name PhoneWindowManager.smali | head -1)
PMS=$(find "$W/src" -name PowerManagerService.smali | head -1)
[ -n "$PWM" ] && [ -n "$PMS" ] || { echo "PhoneWindowManager/PowerManagerService smali not found" >&2; exit 1; }

say "applying the patch (power press + idle timeout)"
cp "$HERE/InkpalmDelayedSleep.smali" "$HERE/InkpalmShowStandby.smali" "$(dirname "$PMS")/"
cp "$W"/dex/smali-out/smali/com/android/server/power/*.smali "$(dirname "$PMS")/"
python3 "$HERE/patch-powerpress.py" "$PWM" "$PMS"

say "rebuilding"
apktool b -f "$W/src" -o "$OUT" >/dev/null
# (dexdump's output goes to a file: grep -q closing the pipe early would trip pipefail)
( cd "$W" && unzip -q -o "$OUT" classes.dex && "$BT/dexdump" -d classes.dex > dump.txt 2>/dev/null && grep -q "PowerManagerService;.inkpalmFire" dump.txt && grep -q "PowerManagerService;.inkpalmArm" dump.txt ) \
  || { echo "self-check failed: patched method not in classes.dex" >&2; exit 1; }
echo
echo "wrote $OUT  (sha256 $(shasum -a256 "$OUT" | cut -c1-16))"
shasum -a256 "$OUT" | awk '{print $1}' > "$OUT.standby-sha256"
cat <<'EOS'

Controlled trial only; not a released asset. See docs/STANDBY-IMAGE.md for results.
The following script verifies the framework and keeps a dedicated backup.
It reboots the device; ADB recovery requires Android to boot far enough.

Install:
  bash framework/trial-standby.sh install <services-standby.jar>

Rollback:
  bash framework/trial-standby.sh rollback
EOS
