# Flashing guide -- read all of it first

Requirements: rooted stock Android 8.1 (Magisk works), `adb`, Python 3, this repo, and the
two stock images pulled FROM YOUR OWN DEVICE (they are hash-checked by the builders):
    adb shell su -c "dd if=/dev/block/by-name/boot bs=4096" > boot.img
    adb shell su -c "dd if=/dev/block/by-name/recovery bs=4096" > recovery.img
    adb shell su -c "dd if=/dev/block/by-name/system bs=1048576" > system.img   # for rollback
Keep them somewhere safe.  Also keep a TWRP backup of /data later.  NEVER write /private.

1. Build TWRP:            python3 twrp/mktwrp.py recovery.img twrp.img
2. Flash it FROM ANDROID (by name -- boot and recovery are both 32 MiB, a slip is fatal):
    adb push twrp.img /data/local/tmp/ && adb shell su -c "dd if=/data/local/tmp/twrp.img of=/dev/block/by-name/recovery bs=4096 && sync"
    adb shell su -c "dd if=/dev/block/by-name/recovery bs=4096 | sha256sum"   # must match twrp.img
3. Enter TWRP by BUTTONS (never `adb reboot recovery` from stock Android, it may write a
   BCB): unplug USB, hold POWER until the Moaan logo returns, then hold Volume-Up (plug USB
   in while holding) until TWRP draws.  `adb devices` shows `recovery`; you have a root shell.
4. In TWRP: back up /data (`twrp backup D name`), then `twrp wipe data; twrp wipe cache`.
5. Get phhusson's GSI: system-roar-arm-aonly-vanilla.img (v313), pad it to your system
   partition size (1,375,731,712 B on this device) and write it:
    adb push gsi.img /sdcard/ ; adb shell "dd if=/sdcard/gsi.img of=/dev/block/by-name/system bs=1048576 && sync"
6. Build and flash the boot image:  python3 a11boot/mkboot.py boot.img a11boot.img
    adb push a11boot.img /sdcard/ ; adb shell "dd if=/sdcard/a11boot.img of=/dev/block/by-name/boot bs=4096 && sync"
7. Enable ADB in Android 11 and install the composer fix (from TWRP):
    adb shell "twrp mount /cache; touch /cache/phh-adb"
    adb shell "mount -o rw,remount /vendor" ; adb push libhwcflip.so /vendor/lib/ ; adb shell "chmod 644 /vendor/lib/libhwcflip.so; chcon u:object_r:vendor_file:s0 /vendor/lib/libhwcflip.so; mount -o ro,remount /vendor"
   (build libhwcflip.so with the NDK: armv7a-linux-androideabi28-clang -shared -fPIC -O2 -Wl,-z,now -o libhwcflip.so libhwcflip.c -ldl)
8. `adb shell reboot`.  Android 11 comes up (first boot is slow).  It will be LANDSCAPE.
9. From Android 11 (adb shell su):  copy configs/a11-boot-fixups.sh to /data/local/, the
   .kl files to /data/system/devices/keylayout/, the .idc to /data/system/devices/idc/
   (owner system:system), then run the script once:  sh /data/local/a11-boot-fixups.sh
   Portrait, touch, animations-off, radios-off are now set and re-applied every boot.
10. Optional: einktile (build.sh, then `adb install`; grant it root in PHH Superuser),
    Unlauncher, EinkBro, Aurora Store.

Rollback: from TWRP, dd your saved boot.img and system.img back by name, restore the
/data backup, reboot.  Remove /vendor/lib/libhwcflip.so if you want /vendor byte-exact.
