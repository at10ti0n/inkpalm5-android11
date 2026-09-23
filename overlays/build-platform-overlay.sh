#!/bin/bash
# Build a resource overlay signed with the GSI's platform key (the public AOSP test key in
# keys/), so it can be installed as an ordinary package and enabled with `cmd overlay` --
# no /vendor or /system write. Usage: bash overlays/build-platform-overlay.sh <overlay-dir>
set -euo pipefail
D=$(cd "${1:?overlay dir}" && pwd); K=$(cd "$(dirname "$0")/../keys" && pwd)
BT=${ANDROID_BUILD_TOOLS:-/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0}
AJ=${ANDROID_JAR:-/opt/homebrew/share/android-commandlinetools/platforms/android-27/android.jar}
N=$(basename "$D"); B="$D/build"; rm -rf "$B"; mkdir -p "$B"
"$BT/aapt2" compile --dir "$D/res" -o "$B/res.zip"
"$BT/aapt2" link -o "$B/unsigned.apk" -I "$AJ" --manifest "$D/AndroidManifest.xml" "$B/res.zip"
"$BT/zipalign" -f 4 "$B/unsigned.apk" "$B/aligned.apk"
"$BT/apksigner" sign --key "$K/platform.pk8" --cert "$K/platform.x509.pem" --out "$B/inkpalm-$N.apk" "$B/aligned.apk"
echo "built $B/inkpalm-$N.apk sha256 $(shasum -a256 "$B/inkpalm-$N.apk" | cut -c1-16)"
