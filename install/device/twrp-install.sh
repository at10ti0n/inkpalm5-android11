#!/sbin/sh
# Device side of the install step. Runs in TWRP (root shell), from the staging directory the
# host installer pushed: system.img (the GSI, already padded to the partition size), boot.img,
# libhwcflip.so, lights.virgo.so, inkpalm-aod.apk and SHA256SUMS for exactly those files.
# Writes system and boot, reads both back, installs the vendor files, enables first-boot ADB.
# Stops at the first failure.
#   sh twrp-install.sh <staging-dir>
D=${1:?usage: twrp-install.sh <staging-dir>}
cd "$D" || exit 1
fail() { echo "FAILED: $*"; exit 1; }
want() { grep " $1\$" SHA256SUMS | cut -d' ' -f1; }
readback() {  # readback <partition> <bytes> -> sha256 of the first <bytes> (a multiple of 4096)
  blockdev --flushbufs /dev/block/by-name/$1 2>/dev/null
  dd if=/dev/block/by-name/$1 bs=4096 count=$(($2 / 4096)) 2>/dev/null | sha256sum | cut -d' ' -f1
}

echo "== checking the staged files"
sha256sum -c SHA256SUMS || fail "staged files do not match what the computer sent"

echo "== writing system (several minutes)"
dd if=system.img of=/dev/block/by-name/system bs=1048576 || fail "system write"
sync
[ "$(readback system $(stat -c %s system.img))" = "$(want system.img)" ] || fail "system read-back mismatch -- do not reboot, run the installer again"
echo "  system written and verified"

echo "== writing boot"
dd if=boot.img of=/dev/block/by-name/boot bs=4096 || fail "boot write"
sync
[ "$(readback boot $(stat -c %s boot.img))" = "$(want boot.img)" ] || fail "boot read-back mismatch -- do not reboot, run the installer again"
echo "  boot written and verified"

echo "== vendor files (display fix, front light, AOD overlay)"
mount /dev/block/by-name/vendor /vendor 2>/dev/null; mount -o rw,remount /vendor || fail "cannot mount vendor"
[ -f /vendor/lib/hw/lights.virgo.so.stock ] || cp -p /vendor/lib/hw/lights.virgo.so /vendor/lib/hw/lights.virgo.so.stock
cp libhwcflip.so /vendor/lib/libhwcflip.so
cp lights.virgo.so /vendor/lib/hw/lights.virgo.so
cp inkpalm-aod.apk /vendor/overlay/inkpalm-aod.apk
for f in /vendor/lib/libhwcflip.so /vendor/lib/hw/lights.virgo.so /vendor/overlay/inkpalm-aod.apk; do
  chmod 644 $f; chown 0:0 $f; chcon u:object_r:vendor_file:s0 $f
done
sync
for f in libhwcflip.so:/vendor/lib/libhwcflip.so lights.virgo.so:/vendor/lib/hw/lights.virgo.so inkpalm-aod.apk:/vendor/overlay/inkpalm-aod.apk; do
  [ "$(sha256sum ${f#*:} | cut -d' ' -f1)" = "$(want ${f%%:*})" ] || fail "${f#*:} did not verify"
done
echo "  installed and verified"

echo "== enabling ADB for the first Android 11 boot"
twrp mount /cache >/dev/null 2>&1 || mount /dev/block/by-name/cache /cache
touch /cache/phh-adb; sync
echo "== install finished"
