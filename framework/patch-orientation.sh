#!/bin/bash
# Full-screen apps that ask for the "natural" orientation (KOReader, Launcher3) -- see
# patch-orientation.py. Stacks on the stock PHH v313 services.jar or on the standby-image
# trial jar (patch-services.sh), and refuses anything else.
#   bash framework/patch-orientation.sh <services.jar> <out.jar>
# Needs apktool 3.x and build-tools (dexdump, for the self-check).
set -euo pipefail
JAR=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${1:?usage: patch-orientation.sh <services.jar> <out.jar>}")
OUT=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${2:?usage: patch-orientation.sh <services.jar> <out.jar>}")
[ "$JAR" != "$OUT" ] || { echo "Use a separate output file" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
BT=${BT:-/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
STOCK=ac34b0f57e09fc32ff1e024736f7114e30464c973406e0a3204cd1d5848518d4    # PHH v313
STANDBY=a198a9b9d9b5ad1bea8800bc3428d00b48f1f0667e10954ce8ce749437af7eca  # + standby trial
GOT=$(shasum -a256 "$JAR" | awk '{print $1}')
[ "$GOT" = "$STOCK" ] || [ "$GOT" = "$STANDBY" ] || { echo "Unreviewed services.jar: $GOT" >&2; exit 1; }
echo "== decompiling"
apktool d -f -o "$W/src" "$JAR" >/dev/null
WC=$(find "$W/src" -path '*/com/android/server/wm/WindowContainer.smali' | head -1)
[ -n "$WC" ] || { echo "WindowContainer.smali not found" >&2; exit 1; }
python3 "$HERE/patch-orientation.py" "$WC"
echo "== rebuilding"
apktool b -f "$W/src" -o "$OUT" >/dev/null
# Self-check: nothing may call getNaturalOrientation any more (the stock jar has one call).
N=0; mkdir "$W/dex"; unzip -q -o "$OUT" 'classes*.dex' -d "$W/dex"
for d in "$W"/dex/classes*.dex; do
  "$BT/dexdump" -d "$d" > "$W/dump.txt" 2>/dev/null
  N=$((N + $(grep -c 'invoke-virtual.*getNaturalOrientation' "$W/dump.txt" || true)))
done
[ "$N" = 0 ] || { echo "self-check failed: getNaturalOrientation still called ($N)" >&2; exit 1; }
shasum -a256 "$OUT" | awk '{print $1}' > "$OUT.standby-sha256"
echo "wrote $OUT (sha256 $(cut -c1-16 "$OUT.standby-sha256"))"
