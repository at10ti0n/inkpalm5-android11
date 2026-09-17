Title: Android 11 running on the Moaan InkPalm 5 Pro Mini (E Ink, Allwinner B300) — working TWRP, correct display and touch, sources + builders

Body:

After a month of reverse engineering, the InkPalm 5 Pro Mini boots and runs Android 11
(phhusson's Treble GSI) on its stock 4.9 kernel — portrait, no mirroring, touch aligned,
Wi-Fi, ADB from boot, volume buttons turning pages, Kindle/EinkBro/Unlauncher, and Quick
Settings tiles for the panel's Text/Graphics waveform and a manual full refresh.  There is
also a working TWRP with ADB at the menu, which stock recovery never offered.

Repo: https://github.com/at10ti0n/inkpalm5-android11  — sources + builders, and prebuilt
images under Releases (v1) for those who just want to flash.  Every script takes your OWN stock boot/recovery
image (hash-checked) and produces the modified one; nothing proprietary is redistributed
(no Moaan partitions, no E Ink waveform, no GSI — grab that from phh).  GPL-2.0.

Things that were genuinely non-obvious, in case they help other Allwinner E Ink devices:

* TWRP showed only the boot logo for a month: TWRP's Android 9 init creates
  /dev/block/by-name/* only if the bootloader passes androidboot.boot_devices, and this
  vendor's 8.1 init creates the links itself.  Fifteen symlink lines fixed every mount.
* The panel wants a transpose of TWRP's surface and the Goodix touch axes are swapped —
  fixed with a small LD_PRELOAD inside recovery (source patch for a rebuild included).
* The vendor HWC reflects every frame along the panel's long axis, and no rotation cancels a
  reflection.  A preload into the composer service mirrors each UPDATE2 layer into a private
  ION buffer before the ioctl.
* Do NOT use ro.surface_flinger.primary_display_orientation on this class of device: the
  input system then transposes touch.  Lock Android's own user rotation instead and give the
  touch panel an .idc marking it orientation-aware.
* The vendor HWC reads persist.sys.mRefreshMode per frame and persist.sys.canRefresh=1 as a
  one-shot full refresh (found by decompiling the HWC); stock's modes are 2 (DU) and 132.

Untested rather than broken: audio (output + mic are declared and AudioFlinger runs, but no
speaker on this device and nothing played yet), Bluetooth (declared, switched off for battery,
never paired), battery life (obvious drains removed, no measured figures).  No NFC and no GPS
hardware (network location only).  The vendor declares telephony it doesn't have; PHH runs it
in no-RIL mode, harmless.  Standard warning:
this can brick a device, keep your stock images, never write the /private partition (panel
calibration).

Credits: phhusson, TeamWin, jkuester (Unlauncher), plateaukao (EinkBro), Aurora OSS,
philips/inkpalm-5-adb-english, linux-sunxi.  Reverse engineering was done with Claude Code;
the buttons were pressed by a human.
