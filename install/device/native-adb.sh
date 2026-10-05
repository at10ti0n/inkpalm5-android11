#!/system/bin/sh
# Switch ADB from PHH's script-launched fallback to the init-managed adbd (docs/NATIVE-A11-
# SECOND-PASS.md, "Native USB/ADB"), with the tested automatic rollback armed. Runs as root on the
# device from the staging dir; the host has already verified and patched apex-setup.rc.
#   sh native-adb.sh <staging-dir>     staging: apex-setup.rc.patched + .sha256, boot-trial.sh, rollback.sh
# After this script the device reboots. On the next boot the a11fixups service runs boot-trial.sh:
# unless the host creates /data/local/stock-second-pass/usb-accepted within 120 s, rollback.sh
# restores the original rc, removes the symlink, puts /cache/phh-adb back and reboots.
D=${1:?usage: native-adb.sh <staging-dir>}
cd "$D" || exit 1
fail() { echo "FAILED: $*"; exit 1; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
RC=/system/etc/init/apex-setup.rc
S=/data/local/stock-second-pass; B=$S/usb-backup
ORIG=edb1f2cfb75da475f0018201fed77b87cbf1020d7d525aa69a36eceb6dd95af6

[ "$(sha "$RC")" = "$ORIG" ] || fail "apex-setup.rc is not the PHH v313 original"
[ "$(sha apex-setup.rc.patched)" = "$(cat apex-setup.rc.patched.sha256)" ] || fail "patched rc transfer mismatch"
[ -e /system/bin/adbd ] && [ ! -L /system/bin/adbd ] && fail "/system/bin/adbd exists and is not a symlink"
# The guard only works if the boot image's a11fixups service runs /data/local/a11-boot-fixups.sh.
[ -n "$(getprop init.svc.a11fixups)" ] || fail "boot service a11fixups not found; the rollback guard would not run"

echo "== backing up the originals ($B)"
mkdir -p $B
cp -p "$RC" $B/apex-setup.rc
cp -p /data/local/a11-boot-fixups.sh $B/a11-boot-fixups.sh
if [ -f /cache/phh-adb ]; then cp -p /cache/phh-adb $B/phh-adb; else : > $B/phh-adb; fi
[ "$(sha $B/apex-setup.rc)" = "$ORIG" ] || fail "backup did not verify"
cp rollback.sh $S/usb-rollback.sh; chmod 755 $S/usb-rollback.sh
rm -f $S/usb-accepted; echo armed > $S/usb-status
sync

echo "== installing native ADB"
mount -o rw,remount /system || fail "cannot remount /system"
cp apex-setup.rc.patched "$RC.new" && chmod 644 "$RC.new" && chown 0:0 "$RC.new" && \
  chcon u:object_r:system_file:s0 "$RC.new" && mv "$RC.new" "$RC" || fail "rc install"
[ -L /system/bin/adbd ] || ln -s /apex/com.android.adbd/bin/adbd /system/bin/adbd || fail "symlink"
sync; mount -o ro,remount /system 2>/dev/null
[ -f /cache/phh-adb ] && mv /cache/phh-adb $B/phh-adb.disabled

echo "== arming the rollback guard (next boot runs boot-trial.sh)"
cp boot-trial.sh /data/local/a11-boot-fixups.sh.new && chmod 755 /data/local/a11-boot-fixups.sh.new && \
  mv /data/local/a11-boot-fixups.sh.new /data/local/a11-boot-fixups.sh || fail "guard install"
sync
echo "== native ADB staged"
