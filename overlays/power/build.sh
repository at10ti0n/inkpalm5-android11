#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BT=${ANDROID_BUILD_TOOLS:-/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0}
AJ=${ANDROID_JAR:-/opt/homebrew/share/android-commandlinetools/platforms/android-27/android.jar}
mkdir -p build
"$BT/aapt2" compile --dir res -o build/resources.zip
"$BT/aapt2" link -o build/unsigned.apk -I "$AJ" --manifest AndroidManifest.xml build/resources.zip
"$BT/zipalign" -f 4 build/unsigned.apk build/aligned.apk
if [ ! -f build/signing.jks ]; then
    keytool -genkeypair -keystore build/signing.jks -storepass inkpalm -keypass inkpalm -alias overlay -dname 'CN=InkPalm local overlay' -keyalg RSA -keysize 2048 -validity 10000
fi
"$BT/apksigner" sign --ks build/signing.jks --ks-pass pass:inkpalm --key-pass pass:inkpalm --out build/inkpalm-power.apk build/aligned.apk
"$BT/apksigner" verify build/inkpalm-power.apk
shasum -a 256 build/inkpalm-power.apk
