#!/bin/bash
# Build einktile.apk with the installed SDK (build-tools 34.0.0, platform 27) and JDK 11.
set -euo pipefail
cd "$(dirname "$0")"; BT=/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0; AJ=/opt/homebrew/share/android-commandlinetools/platforms/android-27/android.jar
TEXT=${MODE_TEXT:?set MODE_TEXT}; GFX=${MODE_GRAPHICS:?set MODE_GRAPHICS}
rm -rf build; mkdir -p build/gen build/cls build/res
sed "s/MODE_TEXT_PLACEHOLDER/$TEXT/; s/MODE_GRAPHICS_PLACEHOLDER/$GFX/" src/net/inkpalm/einktile/Props.java > build/gen/Props.java
$BT/aapt2 compile --dir res -o build/res.zip
$BT/aapt2 link -o build/base.apk -I "$AJ" --manifest AndroidManifest.xml --java build/gen build/res.zip
javac -source 8 -target 8 -bootclasspath "$AJ" -classpath "$AJ" -d build/cls build/gen/net/inkpalm/einktile/R.java build/gen/Props.java src/net/inkpalm/einktile/ModeTile.java src/net/inkpalm/einktile/RefreshTile.java src/net/inkpalm/einktile/RefreshReceiver.java 2>&1 | grep -v 'bootstrap class path' || true
$BT/d8 --release --min-api 24 --output build/ $(find build/cls -name '*.class')
cp build/base.apk build/unsigned.apk; (cd build && zip -q unsigned.apk classes.dex)
$BT/zipalign -f 4 build/unsigned.apk build/aligned.apk
# Platform-signed: the GSI's platform certificate is the public AOSP test key (keys/), which
# lets sharedUserId=android.uid.system take effect.  Never use these keys for anything else.
$BT/apksigner sign --key ../keys/platform.pk8 --cert ../keys/platform.x509.pem --out build/einktile.apk build/aligned.apk
echo "built build/einktile.apk sha256 $(shasum -a256 build/einktile.apk | cut -c1-16)"
