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
NDK=$NDK bash a11boot/build-hwcflip.sh build/libhwcflip.so   # HWC2 headers are vendored in a11boot/include/
$NDK/armv7a-linux-androideabi28-clang -shared -fPIC -O2 -Wl,-z,now -o lights.virgo.so frontlight/lights_epd105.c -llog
MODE_TEXT=2 MODE_GRAPHICS=132 bash einktile/build.sh     # -> einktile/build/einktile.apk
bash overlays/aod/build.sh                               # -> overlays/aod/build/inkpalm-aod.apk
for o in screentemp-fw screentemp-settings screentemp-systemui; do    # Screen Temperature
  bash overlays/build-platform-overlay.sh overlays/$o    # -> overlays/$o/build/inkpalm-$o.apk
done
```
Use JDK 17 for the APK builds on current macOS: JDK 21's class files break build-tools 34's d8,
and an x86-only JDK no longer starts on Apple silicon without Rosetta.

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

The experimental standby framework patch is built from the exact original PHH v313
`services.jar`. It draws a dedicated image window and waits for presentation/panel-idle
observations, with an independent timeout. **Installed for testing; not released**;
see [the stock trace, design and acceptance tests](docs/STANDBY-IMAGE.md).

```
adb pull /system/framework/services.jar
bash framework/patch-services.sh services.jar services-standby.jar
```
The builder checks the original input hash, compiles the render worker, and patches the
power-button/timeout request interlock and cancellation paths. Stale precompiled services
artifacts must be backed up and removed for a controlled device trial. A different GSI
requires a new review; the builder intentionally refuses it.

Collect the release outputs (excluding the experimental standby framework) into
one folder and it is a drop-in replacement for the release assets — hand that folder to `install/from-twrp.sh` and `install/from-android.sh` and
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
| `einktile.apk` | Quick Settings tiles: Text/Graphics, full refresh, portrait/landscape; lock-wallpaper receiver; ScreenTempService, which maps Night Light onto the warm LEDs (v6) |
| `inkpalm-screentemp-fw.apk` | `/vendor/overlay/` (must be preinstalled) — Night Light tint set to identity, so it no longer greys the panel |
| `inkpalm-screentemp-settings.apk`, `inkpalm-screentemp-systemui.apk` | ordinary packages — rename Night Light to Screen Temperature; trim the Quick Settings Edit list to this hardware |
| `SystemUI-warmth.apk` | patched SystemUI: Screen Temperature slider (a front end to Night Light since 2026-09-24), lock-screen clock hidden (GSI-specific) |
| `services-powerpress.jar` | patched framework: power press and idle timeout show the lock screen, then sleep 800 ms later (GSI-specific). **Not shipped and rolled back on the author's device** pending the SurfaceFlinger investigation -- it adds surface creation to the path implicated in [docs/INCIDENT-SF-LIVELOCK.md](docs/INCIDENT-SF-LIVELOCK.md). Without it the panel keeps the last app frame through sleep. |

Design notes for all of these are in `docs/`; start with
[REFRESH-CONTROL.md](docs/REFRESH-CONTROL.md) and [FRONTLIGHT.md](docs/FRONTLIGHT.md).

## Releasing

The release is published from a staging directory, so **every file in it ships** and
`SHA256SUMS` is generated from exactly what is present. Before publishing, list the directory
and confirm each file is intended; afterwards, download the published `SHA256SUMS` and diff it
against the local one.

`services-powerpress.jar` must never be staged there. It is rolled back and deliberately
unshipped (see [docs/INCIDENT-SF-LIVELOCK.md](docs/INCIDENT-SF-LIVELOCK.md) and §3.18 of the
third-pass notes). The current builder now produces the replacement standby experiment,
which also must stay out of release assets until device verification. The old delay patch was
staged by mistake on 2026-09-19 and listed in a local `SHA256SUMS` that no longer matched the
published one; the release itself never contained it.
