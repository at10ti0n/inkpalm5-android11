#!/system/bin/sh
# Restore only the files changed by this trial; never touch calibration or partitions.
set -eu
B=/data/local/stock-second-pass/usb-backup
[ -f "$B/apex-setup.rc" ]
[ -f "$B/a11-boot-fixups.sh" ]
[ -f "$B/phh-adb" ]
# Refuse to remove an executable that is not this trial's exact symlink.
if [ -e /system/bin/adbd ] || [ -L /system/bin/adbd ]; then
    [ -L /system/bin/adbd ]
    [ "$(readlink /system/bin/adbd)" = /apex/com.android.adbd/bin/adbd ]
fi
mount -o rw,remount /system
cp -p "$B/apex-setup.rc" /system/etc/init/apex-setup.rc
if [ -L /system/bin/adbd ]; then rm /system/bin/adbd; fi
cmp "$B/apex-setup.rc" /system/etc/init/apex-setup.rc
sync
mount -o ro,remount /system
cp -p "$B/a11-boot-fixups.sh" /data/local/a11-boot-fixups.sh
cp -p "$B/phh-adb" /cache/phh-adb
sync
echo rollback-restored > /data/local/stock-second-pass/usb-status
reboot
