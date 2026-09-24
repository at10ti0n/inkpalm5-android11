#!/system/bin/sh
# Give the patched framework (services.jar) ahead-of-time compiled code again.  Run as root on
# the device:  su -c 'sh /data/local/tmp/install-services-odex.sh'
#
# MEASURED 2026-09-24: once services.jar is replaced (the standby trial, framework/), its
# prebuilt odex in /system/framework/oat/arm no longer matches and was moved aside. Android 11
# then compiles the system server's jars into /data/dalvik-cache with the "verify" filter
# (dalvik.vm.systemservercompilerfilter default), i.e. no native code -- and even a "speed"
# compile there is mapped NON-executable by system_server (only boot and /system odex files got
# r-xp mappings). So: let installd compile it properly, then place the result next to the jar.
#
# Verified 2026-09-24: afterwards system_server maps /system/framework/oat/arm/services.odex r-xp.
# Idempotent. Undo: rm /system/framework/oat/arm/services.{odex,vdex} (remount rw) and reboot;
# framework/trial-standby.sh rollback also moves these aside before restoring the originals.
D=/data/dalvik-cache/arm; O=/system/framework/oat/arm; L=/data/local/tmp/services-odex.log
OAT=$D/system@framework@services.jar@classes.dex
echo "$(date) start" > $L; echo services-odex > /sys/power/wake_lock
# Always release the wake lock (an earlier version aborted under `set -e` and kept it held).
trap 'echo services-odex > /sys/power/wake_unlock' EXIT
restart_framework() {   # waits for a NEW system_server that answers
  old=$(pidof system_server); setprop ctl.restart zygote; n=0
  while [ $n -lt 600 ]; do sleep 5; n=$((n+5)); p=$(pidof system_server)
    [ -n "$p" ] && [ "$p" != "$old" ] && ! pgrep dex2oat >/dev/null && dumpsys activity -h >/dev/null 2>&1 && return 0; done
  return 1
}
# 1. a real compile, done by installd itself (correct class-loader context, boot image checksums)
if [ "$(stat -c %s $OAT 2>/dev/null || echo 0)" -lt 10000000 ]; then
  setprop dalvik.vm.systemservercompilerfilter speed
  rm -f $D/system@framework@services.jar@classes.*
  restart_framework || { echo "framework did not come back" >> $L; exit 1; }
  setprop dalvik.vm.systemservercompilerfilter ""
fi
ls -la $D/ | grep services.jar >> $L
[ "$(stat -c %s $OAT)" -ge 10000000 ] || { echo "compile did not produce native code" >> $L; exit 1; }
# 2. next to the jar, where system_server maps it executable
mount -o rw,remount /system
cp $OAT $O/services.odex; cp $D/system@framework@services.jar@classes.vdex $O/services.vdex
for f in $O/services.odex $O/services.vdex; do chmod 644 $f; chown 0:0 $f; chcon u:object_r:system_file:s0 $f; done
sync; mount -o ro,remount /system
# MEASURED 2026-09-24: while the /data copy exists, system_server keeps loading IT (non-executable)
# and ignores the /system odex. Remove it; if the /system odex were unusable, the zygote would
# just regenerate a verify-only /data copy at the next start.
rm -f $D/system@framework@services.jar@classes.*
restart_framework || { echo "framework did not come back after install" >> $L; exit 1; }
sleep 15; p=$(pidof system_server)
x=$(grep -c "r-xp.*framework/oat/arm/services.odex" /proc/$p/maps || true)
echo "$(date) system_server=$p executable services.odex mappings=$x" >> $L
[ "$x" -ge 1 ] && echo OK >> $L || echo "NOT EXECUTABLE -- remove $O/services.* and reboot" >> $L
cat $L
