#!/system/bin/sh
# Existing boot-completed service executes this once. ADB must be acknowledged by host.
B=/data/local/stock-second-pass/usb-backup
sh "$B/a11-boot-fixups.sh"
echo awaiting-host > /data/local/stock-second-pass/usb-status
n=0
while [ "$n" -lt 120 ]; do
    if [ -f /data/local/stock-second-pass/usb-accepted ]; then
        cp -p "$B/a11-boot-fixups.sh" /data/local/a11-boot-fixups.sh || exit 1
        cmp "$B/a11-boot-fixups.sh" /data/local/a11-boot-fixups.sh || exit 1
        sync
        echo accepted > /data/local/stock-second-pass/usb-status
        exit 0
    fi
    sleep 1
    n=$((n+1))
done
sh /data/local/stock-second-pass/usb-rollback.sh > /data/local/stock-second-pass/usb-rollback.log 2>&1
