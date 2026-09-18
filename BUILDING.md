# Building from your own stock images

[INSTALL.md](INSTALL.md) uses the prebuilt release images. This page is the other route:
build everything yourself from **your own** device's partitions, so nothing here has to be
trusted. The builders refuse any input whose SHA-256 is not the known stock image, so a
successful build is itself a check that your dumps are intact.

Nothing proprietary is redistributed by this repo — not Moaan's partitions, not E Ink's
waveform/VCOM calibration, not the GSI.

## Inputs

```
adb shell su -c "dd if=/dev/block/by-name/boot     bs=4096"    > boot.img       # 62ce2f88...
adb shell su -c "dd if=/dev/block/by-name/recovery bs=4096"    > recovery.img   # a13a37be...
adb shell su -c "dd if=/dev/block/by-name/system   bs=1048576" > system.img     # rollback
```

## Build

```
python3 twrp/mktwrp.py    recovery.img  twrp-epd105.img
python3 a11boot/mkboot.py boot.img      boot-android11-epd105.img
```

`mktwrp.py` re-adds the E Ink waveform (`/system/default.bin`) from *your* stock ramdisk —
which is why the shipped TWRP ramdisk in this repo has it stripped.

The native pieces need the Android NDK (r2x) and, for the APKs, build-tools 34 + JDK 11:

```
NDK=.../toolchains/llvm/prebuilt/<host>/bin
$NDK/armv7a-linux-androideabi28-clang -shared -fPIC -O2 -Wl,-z,now -o libhwcflip.so   a11boot/libhwcflip.c -ldl
$NDK/armv7a-linux-androideabi28-clang -shared -fPIC -O2 -Wl,-z,now -o lights.virgo.so frontlight/lights_epd105.c -llog
MODE_TEXT=2 MODE_GRAPHICS=132 bash einktile/build.sh     # -> einktile/build/einktile.apk
bash overlays/aod/build.sh                               # -> overlays/aod/build/inkpalm-aod.apk
```

The Quick Settings warmth slider is built separately, because it patches SystemUI and a
patched SystemUI only matches the GSI build it came from:

```
adb pull /system/system_ext/priv-app/SystemUI/SystemUI.apk      # after the GSI is installed
adb pull /system/framework/framework-res.apk
bash systemui/patch-systemui.sh SystemUI.apk framework-res.apk SystemUI-warmth.apk
```
The same patch also hides the lock-screen clock and date, so the sleep screen is only the
standby image; `KEEP_CLOCK=1 bash systemui/patch-systemui.sh ...` leaves the clock in.
It needs `apktool` 3.x on top of the tools above, and prints the install and rollback
commands when it finishes.

The framework patch that makes a power press show the lock screen before the display goes
off is built the same way, from your own `services.jar`:

```
adb pull /system/framework/services.jar
bash framework/patch-services.sh services.jar services-powerpress.jar
```
It adds one tiny smali class and edits one case in `PhoneWindowManager.powerPress`
(`framework/patch-powerpress.py` shows exactly what). The installer removes the
precompiled `services.odex` so the patched dex is the one that runs. Re-run it after any GSI update — a GSI flash puts the stock
SystemUI back.

Collect the outputs into one folder and it is a drop-in replacement for the release
assets — hand that folder to `install/from-twrp.sh` and `install/from-android.sh` and
follow [INSTALL.md](INSTALL.md) from step 1.

## Doing it by hand

If you would rather not run the install scripts, they are short and readable; each step is
a plain `adb`/`dd` line with a read-back check. Read `install/from-twrp.sh` and
`install/from-android.sh` — between them they are the whole procedure, and the comments say
why each piece is needed.

## What each piece is for

| File | Why it exists |
|---|---|
| `twrp-epd105.img` | TWRP with the by-name symlinks, EPD display and swapped touch axes |
| `boot-android11-epd105.img` | stock 8.1 ramdisk + permissive-init patch + prepended rc |
| `libhwcflip.so` | `/vendor/lib/` — cancels the vendor composer's frame mirroring |
| `lights.virgo.so` | `/vendor/lib/hw/` — drives the real LM3630A front light |
| `inkpalm-aod.apk` | `/vendor/overlay/` — enables the native always-on display |
| `einktile.apk` | Quick Settings tiles: Text/Graphics, full refresh, warmth, portrait/landscape (v4) |
| `SystemUI-warmth.apk` | patched SystemUI: Screen Temperature slider, lock-screen clock hidden (GSI-specific) |
| `services-powerpress.jar` | patched framework: power press shows the lock screen, then sleeps 800 ms later (GSI-specific) |

Design notes for all of these are in `docs/`; start with
[REFRESH-CONTROL.md](docs/REFRESH-CONTROL.md) and [FRONTLIGHT.md](docs/FRONTLIGHT.md).
