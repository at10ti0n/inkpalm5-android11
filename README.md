# Android 11 on the Moaan InkPalm 5 Pro Mini (EPD105)

A working Android 11 (phhusson's Treble GSI) on the Moaan InkPalm 5 Pro Mini — Allwinner
B300 (sun8iw15p1), ARMv7, kernel 4.9, 5.2" 1280×720 E Ink — plus a working TWRP with ADB,
display and touch.  Stock firmware is Android 8.1.

**What works:** boots, E Ink panel (correct orientation, no mirroring), touch, Wi-Fi, ADB from
boot, Quick Settings tiles for the panel's Text/Graphics waveform and a manual full refresh,
volume buttons as page-turn keys, the capacitive logo as Home/wake, Unlauncher, Kindle,
EinkBro, Aurora Store.  **Untested:** audio (declared, no speaker, nothing played yet), Bluetooth (declared, kept
off), battery life (no measured figures).  No NFC/GPS hardware; telephony is declared but
absent (PHH no-RIL).

**Prebuilt images:** https://github.com/at10ti0n/inkpalm5-android11/releases/tag/v1 (verify SHA256SUMS).
The repository itself is *builders and sources*: each script takes **your
own** stock `boot.img` / `recovery.img` (hash-checked) and produces the modified image.
Nothing proprietary is redistributed — not Moaan's partitions, not E Ink's waveform/VCOM
calibration (`/private`, never touch it), not the GSI (download it from phhusson).

## Screenshots (Android 11 on the device, captured via `screencap` -- the composed frame the panel shows)
| Home (Unlauncher) | Quick Settings: E-Ink tiles | About: Android 11 |
|---|---|---|
| ![home](docs/images/home.png) | ![qs](docs/images/quicksettings.png) | ![about](docs/images/about-android11.png) |

| EinkBro | Kindle about (8.156 on API 30) | Kindle reader (title blurred; page content is DRM-protected) |
|---|---|---|
| ![einkbro](docs/images/einkbro.png) | ![kindle-about](docs/images/kindle-about.png) | ![kindle](docs/images/kindle-reader.png) |

Panel photos: `docs/images/android11-portrait.jpg` (working) and `docs/images/first-boot-mirrored.jpg` (first boot, before the composer fix).

## How it works (the parts that took weeks to find)
* **TWRP was blank on this device** because TWRP's Android-9 `init` only creates
  `/dev/block/by-name/*` when the bootloader passes `androidboot.boot_devices` — Moaan's
  8.1 vendor init makes those links itself.  Fifteen `symlink` lines in the recovery rc fix
  every mount (`twrp/`).  The panel wants a *transpose* of TWRP's portrait surface and the
  Goodix touch axes are swapped: `twrp/preload/libepdfix.c` interposes both inside the
  recovery binary via `LD_PRELOAD` (source patch for a real rebuild in `twrp/overlay/`).
* **Android 11 boots on the stock 8.1 boot ramdisk** with a two-byte permissive-init patch;
  the GSI's own init is never used (`a11boot/mkboot.py`).
* **The vendor composer reflects every frame** along the panel's long axis and no rotation
  can cancel a reflection.  `a11boot/libhwcflip.c`, preloaded into the composer service,
  mirrors each `DISP_EINK_UPDATE2` layer into a private ION buffer ring before the ioctl.
* **Rotation and touch**: do *not* use `ro.surface_flinger.primary_display_orientation`
  (InputReader then transposes touch).  Keep the display natural and lock Android's user
  rotation (`configs/a11-boot-fixups.sh`) with an input config marking the Goodix panel as
  an orientation-aware touchscreen (`configs/Vendor_dead_Product_beef.idc`).
* **E Ink refresh control**: the vendor HWC reads `persist.sys.mRefreshMode` per frame and
  `persist.sys.canRefresh=1` as a one-shot full refresh (Ghidra decompile, see
  `docs/REFRESH-CONTROL.md`).  Stock's two modes are Text = 2 (DU) and Graphics = 132.
  `einktile/` is a tiny Quick Settings app that flips them.
* **ADB in Android 11**: PHH's `/cache/phh-adb` switch (adbd is script-launched; never
  `adb root`, it kills it until reboot).

## Layout
    twrp/       mktwrp.py + twrp-epd105-ramdisk.cpio.gz + libepdfix.c + overlay patch
    a11boot/    mkboot.py + a11-prepend.rc + libhwcflip.c + wdog.c
    configs/    a11-boot-fixups.sh, key layouts (volume = page turn), touch idc
    einktile/   Quick Settings tiles (build.sh: Android build-tools + JDK 11)
    docs/       FLASHING.md (read first), REFRESH-CONTROL.md, twrp-boot-review.md, images/

## Credits
phhusson (Treble GSI, superuser), TeamWin (TWRP), jkuester (Unlauncher), plateaukao
(EinkBro), Aurora OSS, philips/inkpalm-5-adb-english (the ADB starting points), the
linux-sunxi wiki.  Built with Claude Code doing the reverse engineering alongside a human
holding the buttons.

## License
GPL-2.0 for everything in this repository (the TWRP overlay must be; the rest follows).
No warranty.  This can brick a device: read `docs/FLASHING.md` and keep your stock images.

## Discussion
r/InkPalm5 thread: https://www.reddit.com/r/InkPalm5/comments/1wirslw/android_11_running_on_the_moaan_inkpalm_5_pro/
Issues and pull requests welcome here; results from other units especially.
