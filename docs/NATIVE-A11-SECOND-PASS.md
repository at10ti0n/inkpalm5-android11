# Native Android 11 suspend and USB (EPD105, 2026-09-17)

Tested on the existing PHH v313 installation and stock 8.1 boot/vendor. These are
post-v1 changes; published v1 images are unchanged. Apply the first-pass native AOD
configuration too. No boot image, vendor binary, display ioctl, or calibration
change is involved.

## Suspend: two independent fixes

The stock ramdisk starts `early_hal` in `late-fs`, but grants system ownership of
`/sys/power/state` and `/sys/power/wakeup_count` only during `on boot`.
Android 11 SystemSuspend originally started too early. Its live FDs were sockets:
AOSP deliberately substitutes a blocking socketpair if it cannot open either power
file. It then handles wakelocks but never suspends. See
[AOSP SystemSuspend startup](https://android.googlesource.com/platform/system/hardware/interfaces/+/refs/heads/android11-release/suspend/1.0/default/main.cpp).

`configs/android.system.suspend@1.0-service.rc` changes only `class early_hal` to
`class hal`. On this ramdisk, `class_start hal` follows the power-file ownership
commands. After reboot the service holds both actual kernel power files open.
Do not assume this ordering on another boot image.

AOD separately needs both framework booleans below set to true:

- `config_powerDecoupleAutoSuspendModeFromDisplay`
- `config_powerDecoupleInteractiveModeFromDisplay`

With the defaults false, Android 11's legacy display callback enables autosuspend
only for OFF, not DOZE_SUSPEND. `overlays/power` lets the framework suspend-blocker
policy control this normally. It must be **static**: the mutable trial resolved
true via `cmd overlay lookup` but PowerManagerService still read false after reboot.
[Android's overlay documentation](https://source.android.google.cn/docs/core/runtime/rros?hl=en)
explains immutable overlays and system resources.

Back up `/system/etc/init/android.system.suspend@1.0-service.rc`, replace it with the
supplied file preserving ownership/mode/context, and install the built power APK at
`/vendor/overlay/inkpalm-power.apk` (root:root, 0644, vendor_file context). Remount
partitions read-only afterward and reboot. Static overlays activate at boot;
`cmd overlay enable` is not the deployment mechanism for this package.

Verify `dumpsys power`: both `mDecoupleHal...Config` fields true; when settled in
AOD, `DOZE_SUSPEND`, autosuspend true and interactive false. Inspect SystemSuspend's
`/proc/PID/fd` for both power files. Ordinary wakelocks and plugged USB can still
prevent kernel suspend. Do not force sleep with sysfs writes or read wakeup_count
as a diagnostic: that read can block while a wake source is held.

Rollback: restore the original service RC and move the power overlay out of the
active overlay directory, remount read-only and reboot. AOD remains available but
loses the tested suspend behavior.

## Measurements

| Configuration | Interval | Charge-counter decrease | Successful kernel suspends |
|---|---:|---:|---:|
| Original native AOD | 21 min 5 sec | 55 mAh | 0 |
| Original, AOD disabled | 16 min 16 sec | 38 mAh | 0 |
| Both fixes, native AOD | 8 min 58 sec | 4 mAh | 15 |

The fixed trial also had two additional aborted attempts (one freeze, one suspend,
errno EBUSY), with no failed resume. Physical clock readability and normal wake
were confirmed by the operator. These short, unequal intervals demonstrate working
suspend and substantially lower observed drain, not a battery-life estimate.
Raw captures remain local because they contain device/application details.

Ghidra analysis of the live-matching vendor power.virgo.so confirmed its interactive
callback changes CPU cooling-budget values; it does not itself implement suspend
or manipulate display/calibration data. No binary patch was needed.

## Native USB/ADB

The stock init registers `adbd /system/bin/adbd`, but that executable path was absent.
PHH later declares a duplicate APEX-based adbd service using `override`, unsupported
by this old init, and separately starts `adbd_apex`. The `/cache/phh-adb` fallback
also launches a daemon and builds its own gadget. This produced competing daemons
and broke `adb root` restarts.

The tested repair:

1. Add `/system/bin/adbd` as a symlink to `/apex/com.android.adbd/bin/adbd`.
2. Patch `/system/etc/init/apex-setup.rc` to remove only the competing `adbd_apex`
   service/start/restart actions, retaining APEX mounts and unrelated settings.
3. Move `/cache/phh-adb` out of the active path, with a backup.
4. Reboot into the stock `b.1` gadget and its ffs.ready/UDC chain.

`configs/native-usb/patch-apex.py ORIGINAL OUTPUT` performs the scoped patch and
refuses an original whose SHA-256 differs from `apex-input.sha256`. Pull and hash
**your installed file** first. Do not copy an arbitrary full RC over another GSI.
The stock init does support seqpacket sockets; that was not the incompatibility.

The included `boot-trial.sh` and `rollback.sh` preserve the tested recovery procedure.
They are trial helpers, not a standalone installer. Before using them, stage exact
originals at `/data/local/stock-second-pass/usb-backup/` as `apex-setup.rc`,
`a11-boot-fixups.sh`, and `phh-adb`; stage rollback as
`/data/local/stock-second-pass/usb-rollback.sh`; ensure `usb-accepted` is absent.
The existing boot-completed `a11fixups` service runs the trial script from
`/data/local/a11-boot-fixups.sh`. It restores the old files and reboots unless the
host creates `/data/local/stock-second-pass/usb-accepted` within 120 seconds after
normal boot fixups finish. Confirm this service exists before relying on the guard.
On acceptance it restores the ordinary bounded startup script. Its recovery window
begins after boot completion, so it is not protection against a failure to boot.

Verify one `adbd` with PPID 1, `init.svc.adbd=running`, `sys.usb.ffs.ready=1`,
`sys.usb.config=sys.usb.state=adb`, and `b.1/f1` pointing to `ffs.adb`. The competing
`adbd_apex` service and `/cache/phh-adb` sentinel should be absent.
`adb root` and `adb unroot` both reconnected with UID 0 and UID 2000 respectively
on the tested device. A subsequent normal reboot and physical USB unplug/replug
also passed. Replug retained the same single daemon PID, readiness 1 and bound UDC.
The ordinary boot fixups were restored and their oneshot service stopped normally.

Rollback restores the original apex RC and sentinel, removes only the exact trial
symlink, restores the original startup script and reboots. Keep a working recovery
route and the original backups until verification is complete.
