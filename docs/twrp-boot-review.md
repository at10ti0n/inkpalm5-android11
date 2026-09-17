# Will it boot? -- second review of recovery-EPD105-twrp-boot-test.img

Desk-only, 2026-09-17.  Companion to CANDIDATE-AUDIT-2026-09-17.md (which answered
"is it safe"; this answers "will it work").  No device action.

VERDICT.  As shipped it will most likely reach a running, HEADLESS TWRP: init runs, the
GUI starts, the panel stays on the Moaan logo, and -- for the first time in this
project -- ADB may enumerate.  It will NOT show a picture, because every partition
mount in the image, including the /private mount the panel path fails-closed on, uses a
device path this ramdisk's ueventd does not create on this device.  That one defect is
MEASURED at the desk, was the unexcluded branch in the project's own Gate 1F record,
and is fixable with a few rc lines.  A second, separate defect (init's temporary `exec`
path) is real but does not touch the declared services.

---

## 1. History that the previous audit did not know

Six TWRP-family images were flashed in Gate 1F (2026-08-26).  None produced ADB or a
panel image.  MEASURED there:
  * 1F-4a  stock ramdisk + 3 rc directives -> stock UI appeared, /cache markers written.
  * 1F-4b  v4 (TWRP) ramdisk -> Moaan logo only, NO /cache markers.
  * a3r1..a6  instrumented v4 -> first-stage init re-exec'd; second-stage init parsed
    and executed `on early-init` completely and reached `on init`; rootfs writes by init
    succeeded on both sides of a temporary `exec`; the exec'd static helper left NO
    sentinel and NO raw-partition record.
The investigation was closed administratively with suspects (1) `setcon`, (2) the
Android-9 init binary, (3) missing ueventd.sun8iw15p1.rc, (4) missing sunxi-keyboard.ko.
The September build fixed (3) and (4) and swapped the USB design.  Its session logs
contain no root-cause claim for the earlier failures.

## 2. The defect -- /dev/block/by-name/* does not exist under this ramdisk

MEASURED, this image:
  * every fstab line and the `/private` mount use `/dev/block/by-name/<name>`
    (`etc/twrp.fstab`, `init.recovery.sun8iw15p1.rc:12`); `validate_candidate.py:32`
    asserts that exact string.
  * `/init` is TWRP's Android-9-era binary (1,608,840 B).  Its strings include
    `/boot_devices`, `/proc/device-tree/firmware/android/`, `/dev/block/by-name/`,
    `/dev/block/bootdevice/by-name` -- the P mechanism.
  * the stock 8.1-era init has NO `/dev/block/by-name` literal and NO `boot_devices`; it
    carries `/dev/block/%s` + `by-name` as separate strings (a vendor path builder).
  * the device tree (`twrp/dto-unpack/uboot-dtb.dtb`) has no `firmware/android`, no
    `fstab`, no `boot_devices` node.
  * the captured kernel cmdline has no `androidboot.boot_devices`.
  * stock Android's vendor fstab and stock recovery both use `/dev/block/by-name/*`
    and work -> on this device those links come from the vendor's 8.1 init.

ASSERTED (AOSP P init/devices.cpp, corroborated by the strings above): Android 9
ueventd always creates `/dev/block/platform/<dev>/by-name/<name>`, but creates the
top-level `/dev/block/by-name/<name>` ONLY for devices listed in `boot_devices`, taken
from `androidboot.boot_devices` or the DT `firmware/android` node.  Both are absent
here, so under TWRP's ueventd `/dev/block/by-name/` is never populated.

CONSEQUENCE, and it matches every prior observation:
  * 1F-4b: `mount ext4 /dev/block/by-name/cache /cache` fails -> no markers, while init
    is in fact running (a4r1/a6 later proved it).
  * `/private` mount fails -> `check_calibration()` fails-closed -> "PANEL DISABLED,
    recovery continues" -> logo only.
  * TWRP cannot mount /cache, /data, /system -> headless but alive.
The 4EA record listed "this ueventd never creates by-name symlinks at all" as the
unexcluded global failure mode and then assumed the links exist because coldboot
completes; that assumption came from 8.1 behaviour and was never checked against P.

## 3. A second defect, separate: init's temporary `exec` path

MEASURED: `twrp/tools/epdmark-a6` is STATIC (API21 clang -static, no interpreter) and
writes its rootfs ENTER sentinel (line 101) BEFORE opening the by-name path (line 122).
a6 saw no sentinel -> the helper never ran -> §2 does not explain a6.  What a6 exercised
is the anonymous one-shot service that `exec --` builds; `recovery` and `adbd` are
declared with explicit `seclabel` and start via `class_start default`, a different path
(the operator's a6 correction #3 already made this point).  UNRESOLVED, but not a
predictor of the declared services.  It does mean: do not rely on `exec` in rc for
diagnostics in this image.

## 4. What is sound (MEASURED)

  * Header identical to stock recovery except the ramdisk; kernel byte-identical.
  * Ramdisk structure: `sbin/ueventd -> ../init` present; `ueventd.sun8iw15p1.rc`
    IDENTICAL to stock; `sunxi-keyboard.ko` present; `/sbin/ld.config.txt` present with
    `/sbin` first; `LD_LIBRARY_PATH=/sbin` exported; `recovery` dynamic via
    `/sbin/linker`, 23 NEEDED all present; `adbd` and the USB controller STATIC.
  * sepolicy: valid binary, policyvers 30 (== stock); file_contexts.bin same magic.
  * Kernel (kallsyms of the running stock kernel): configfs gadget (35 syms), FunctionFS
    (82), sunxi UDC -- the configfs ADB design is kernel-compatible.  Stock's own rc uses
    configfs too but leaves `sys.usb.controller` EMPTY, which is why stock never
    enumerates at the menu; the controller binary fixes exactly that.  This ADB chain
    (`on boot` -> controller -> `sys.usb.config=adb` -> adbd -> ffs.ready -> UDC bind)
    does NOT depend on by-name links.
  * Panel path: `epd.c` is compiled into `libminuitwrp.so` (golden-cfg signature at
    0x37794; `#0x406` immediate present; `/dev/disp`, `/private/default.bin`,
    `/private/vcom.bin`, `libion.so` strings present); `libion.so` exports all six
    functions incl. `ion_sync_fd`; the 0x406/Y8/ION contract was HARDWARE-VALIDATED in
    Gate 1E-f (from Android userspace, SurfaceFlinger isolated) -- not yet from recovery.
  * `/private` (FAT16) really holds DEFAULT.BIN 6,900,384 B and VCOM.BIN 5 B, matching
    `check_calibration()`'s bounds.  The kernel reads the waveform by the DT path
    `/private/default.bin`; stock recovery never mounts /private and instead ships
    `/system/default.bin` (R182 fallback) inside its ramdisk -- that is how stock draws.
    This image ships no fallback, so its panel depends entirely on the /private mount.
  * Theme portrait_hdpi 1080x1920 on a 720x1280 surface: TWRP scales; not a blocker.
  * Touch: the kernel has a built-in Goodix GT1x driver; DT lists gt9xx/ft5x16/gslX680
    candidates.  BoardConfig sets no SWAP_XY/FLIP flags while the backend rotates the
    image 90 deg CCW (itself an unresolved guess, twrp/libepd/ROTATION.md).  Expect
    touch to be misaligned or rotated on first boot; not a boot blocker, ADB is.
  * misc all zero; nothing writes a partition at boot; rollback as in the safety audit.

## 5. What it is missing -- in order

  1. BLOCK-DEVICE LINKS.  Any one of:
     (a) in `init.recovery.sun8iw15p1.rc`, at `on early-fs` before the /private mount:
         `mkdir /dev/block/by-name 0755 root root` then one `symlink
         /dev/block/mmcblk0pN /dev/block/by-name/<name>` per partition from the fixed
         cmdline map (UDISK p1, bootloader p2, env p3, boot p4, system p5, vendor p6,
         misc p7, recovery p8, cache p9, metadata p10, private p11, frp p12, empty p13,
         dto p14, media_data p15).  Deterministic, no ueventd dependency, fstab
         unchanged.  RECOMMENDED.
     (b) rewrite twrp.fstab + the mount to raw `/dev/block/mmcblk0pN`.
     (c) append `androidboot.boot_devices=soc/sdcX` to the image cmdline -- X is NOT
         ESTABLISHED (klog shows mmcblk0 on host mmc0; the sysfs platform name is not
         in any capture), so (c) is not ready.
  2. Optionally ship stock's `/system/default.bin` (6,899,360 B; ~+3-4 MB compressed,
     check the 32 MiB fit) so the kernel has a fallback if the /private mount ever
     fails.  Stock recovery relies on exactly this.
  3. Do not use `exec` in rc for markers; use declared oneshot services (§3).
  4. After first boot with (1): settle rotation (ROTATION.md) and touch axes from
     observation, then set BoardConfig touch flags.

## 6. Prediction for a first boot of the image AS SHIPPED

Moaan logo, no UI.  Likely `adb devices` shows the device within ~10-20 s of the menu
being reached, root shell, `getprop init.svc.recovery` = running, `dmesg`/stderr with
"graphics_epd: epd_init failed: 3 (/private calibration missing or insane)".  If ADB
appears, (1a) can be tested live before rebuilding: create the symlinks by hand, mount
/private, and `setprop`/restart recovery.  If ADB does not appear, the safety audit's
rollback applies unchanged.

Nothing here authorizes a flash.  Gate 9 closed; Gate 10 runtime NOT TESTED.

> UPDATE 2026-09-17: fix for §2 built and desk-validated -- see `twrp/fix1/README.md`,
> image sha256 d6997127a6a3... ; flash/observe steps in `twrp/fix1/RUNBOOK.md`. Not flashed.
