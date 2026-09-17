#!/bin/bash
# Run from your COMPUTER while the device is in TWRP (`adb devices` shows "recovery").
# Writes the GSI and boot image, installs the vendor files, enables ADB for the first boot.
# Everything is verified by read-back before it moves on.  Usage:
#     bash install/from-twrp.sh <gsi.img> <assets-dir>
set -euo pipefail
GSI=${1:?usage: from-twrp.sh <gsi.img> <assets-dir>}
A=${2:?usage: from-twrp.sh <gsi.img> <assets-dir>}
SYSSIZE=1375731712      # EPD105 system partition, bytes

say() { printf '\n== %s\n' "$*"; }
need() { [ -f "$1" ] || { echo "missing: $1" >&2; exit 1; }; }
need "$GSI"; for f in boot-android11-epd105.img libhwcflip.so lights.virgo.so inkpalm-aod.apk; do need "$A/$f"; done

[ "$(adb get-state 2>/dev/null)" = recovery ] || { echo "device is not in TWRP (adb devices should show 'recovery')" >&2; exit 1; }

say "padding the GSI to the system partition size"
cp "$GSI" /tmp/gsi-padded.img
python3 - "$SYSSIZE" <<'EOF'
import sys,os
p='/tmp/gsi-padded.img'; n=int(sys.argv[1]); s=os.path.getsize(p)
assert s<=n, f'GSI is {s} bytes, larger than the {n}-byte system partition'
with open(p,'ab') as f: f.write(b'\0'*(n-s))
print(f'  padded {s} -> {n}')
EOF

say "writing system (this takes several minutes)"
adb push /tmp/gsi-padded.img /sdcard/gsi.img
adb shell "dd if=/sdcard/gsi.img of=/dev/block/by-name/system bs=1048576 && sync"
adb shell "rm /sdcard/gsi.img"

say "writing boot"
adb push "$A/boot-android11-epd105.img" /sdcard/boot.img
adb shell "dd if=/sdcard/boot.img of=/dev/block/by-name/boot bs=4096 && sync"
WANT=$(shasum -a256 "$A/boot-android11-epd105.img" | cut -d' ' -f1)
GOT=$(adb shell "blockdev --flushbufs /dev/block/mmcblk0p4; dd if=/dev/block/by-name/boot bs=4096 2>/dev/null | sha256sum" | tr -d '\r' | cut -d' ' -f1)
[ "$WANT" = "$GOT" ] || { echo "BOOT READ-BACK MISMATCH -- do not reboot, reflash" >&2; exit 1; }
echo "  boot read-back VERIFIED"
adb shell "rm /sdcard/boot.img"

say "installing the vendor files (display fix, front light, AOD overlay)"
adb shell "mkdir -p /vendor_mnt 2>/dev/null; mount /dev/block/by-name/vendor /vendor 2>/dev/null; mount -o rw,remount /vendor" || true
adb push "$A/libhwcflip.so" /vendor/lib/libhwcflip.so
adb push "$A/lights.virgo.so" /vendor/lib/hw/lights.virgo.so.new
adb push "$A/inkpalm-aod.apk" /vendor/overlay/inkpalm-aod.apk
adb shell "
  [ -f /vendor/lib/hw/lights.virgo.so.stock ] || cp -p /vendor/lib/hw/lights.virgo.so /vendor/lib/hw/lights.virgo.so.stock
  mv /vendor/lib/hw/lights.virgo.so.new /vendor/lib/hw/lights.virgo.so
  chmod 644 /vendor/lib/libhwcflip.so /vendor/lib/hw/lights.virgo.so /vendor/overlay/inkpalm-aod.apk
  chown 0:0 /vendor/lib/libhwcflip.so /vendor/lib/hw/lights.virgo.so /vendor/overlay/inkpalm-aod.apk
  chcon u:object_r:vendor_file:s0 /vendor/lib/libhwcflip.so /vendor/lib/hw/lights.virgo.so /vendor/overlay/inkpalm-aod.apk
  sync"
adb shell "ls -lZ /vendor/lib/libhwcflip.so /vendor/lib/hw/lights.virgo.so /vendor/overlay/inkpalm-aod.apk" | tr -d '\r'

say "enabling ADB for the first Android 11 boot"
adb shell "twrp mount /cache 2>/dev/null || mount /dev/block/by-name/cache /cache; touch /cache/phh-adb; sync"

say "done -- now run:  adb shell reboot"
echo "The first boot is SLOW (several minutes) and comes up in LANDSCAPE. That is expected."
echo "When it finishes, run: bash install/from-android.sh <assets-dir>"
