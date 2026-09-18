# Native third pass (EPD105, 2026-09-17): system-UID tiles, telephony, and what actually holds wake

## 3.1 Tiles as a platform-signed system app -- DONE, measured
The GSI's platform certificate is the public AOSP test key (SHA1 27:19:6E:38...3D:FA; `keys/`).
`einktile` v2 is signed with it and declares `sharedUserId="android.uid.system"`, so it
runs as uid 1000 and writes `persist.sys.mRefreshMode` / `persist.sys.canRefresh` through
`android.os.SystemProperties` -- no `su`, no PHH Superuser grant.  It also receives the stock
intent `android.eink.force.refresh` and performs a full refresh, restoring the hook Moaan's
own apps and stock SystemUI used.  MEASURED: receiver sets canRefresh=1 as uid 1000 (read
back within 100 ms, before the HWC consumed it); tile click toggles 132 -> 2 -> 132; zero
Superuser prompts.  Two install notes: a signature change needs `adb uninstall` first, and
SystemUI only rebinds custom tiles after the `sysui_qs_tiles` value actually changes (write a
different list, then the intended one).  A freshly installed app is in the stopped state
until one component is started explicitly.  One cosmetic AVC: a system-UID app cannot write
its own app-data directory under the app-data label -- the app must stay file-free.

## 3.5 Telephony -- feature files removed (GSI /system), phone process left alone
The feature declarations live in the GSI, not the vendor: `/system/etc/permissions/
android.hardware.telephony.gsm.xml` and `...telephony.ims.xml`.  Both backed up to
`/data/local/native-telephony-backup/` (sha256 1e936273..., 6f0d8f1e...) and removed via a
`/system` rw remount; after reboot `pm list features | grep -c telephony` = 0, Settings and
SystemUI healthy, no fatal exception.  `rild` (vendor init) and `com.android.phone` still
run; disabling them is deferred because the wake-source table shows they cost nothing:

    chgusb_det / usb_connecting   ~1.6e6 ms   (USB plugged -- the measurement condition)
    sy7673a_wakelock              85 activations, 27,531 ms   <-- E-Ink power IC
    [timerfd], mmc1, battery, NETLINK  ~1-2 s each
    radio-interface               1 activation, 200 ms        <-- telephony: negligible

So the next battery lever is the `sy7673a` (panel power) wake source -- how often the HWC
wakes it and whether the E-Ink power rail is left up between updates -- not telephony.
Rollback: copy the two XMLs back from the backup with a rw remount and reboot.

## 3.2 Natural portrait experiment -- MEASURED NEGATIVE, rolled back
`a11boot/mkboot.py` accepts `A11_SF_ORIENTATION=90` to add
`setprop ro.surface_flinger.primary_display_orientation ORIENTATION_90` to the prepended rc.
Built `boot-sf90-experiment.img` (sha256 796e8061...), flashed to boot (read-back verified),
with `user_rotation=0`, `wm set-fix-to-user-rotation disabled` and the orientation-aware
`Vendor_dead_Product_beef.idc` in place.  Readings on the running device (2026-09-17):

```
ro.surface_flinger.primary_display_orientation=ORIENTATION_90
wm size: Physical size: 720x1280
mRotation=0 mFixedToUserRotation=false
Viewport INTERNAL ... orientation=0, logicalFrame=[0, 0, 720, 1280], deviceSize=[720, 1280]
Touch Input Mapper: OrientationAware: true
  RawSurfaceWidth: 720px  RawSurfaceHeight: 1280px  SurfaceOrientation: 0
  XScale: 0.562  YScale: 1.775
```

Reading: SF's own orientation makes the display *look* portrait, but InputReader sees a
viewport with `orientation=0` and a 720x1280 surface, so it stretches the digitizer's raw
1280x720 axes straight onto it (0.562 = 720/1280, 1.775 = 1280/720) -- touch is transposed
again.  The `.idc` cannot help: `orientationAware` only rotates by the viewport orientation,
which is 0 here because the rotation happened below the framework.  This is the same
failure as Gate 14, now with the `.idc` ruled out as the missing piece.

Conclusion: natural-portrait via `primary_display_orientation` is not achievable on this
panel/touch pair without a touch driver that reports rotated axes.  Fixed-to-user rotation
(`accelerometer_rotation=1`, `user_rotation=1`, `wm set-fix-to-user-rotation enabled`) on a
natural 1280x720 display remains the route; it is the framework-native one anyway.
The `A11_SF_ORIENTATION` option stays in `mkboot.py` (off by default) for anyone who wants
to repeat the measurement.

Rollback: the device was reflashed with a boot built from THIS repo as published
(`python3 a11boot/mkboot.py <stock boot.img> boot.img`, no options) -- sha256 c6f97ad6...
It boots, `a11fixups` ran (log `done`), and after re-applying the three rotation settings:
`mRotation=1 mFixedToUserRotation=true`, viewport `orientation=1`, `XScale: 0.999
YScale: 0.999`.  Note: this is the first boot of the *clean* repo build; the v1 release
image (60bf6233...) still carries the gate17 trial instrumentation (`/collector`, `g17wdog`,
p13 markers) in its prepended rc.  Functionally equivalent; the clean build is what a fresh
clone produces and it is now verified on hardware.

## 3.8 Unplugged suspend / battery measurement -- baseline taken, waiting on the interval
Plugged in, the device never suspends (`/sys/kernel/debug/suspend_stats` success=0, fail=0
since boot; the `chgusb`/`usb_connecting` wake sources hold it), so every number worth
having needs the cable out and ADB gone.  Baseline 2026-09-17 18:37 EEST, clean repo boot
(c6f97ad6...), AOD on, screen timeout 120 s, radios off, deviceidle enabled:

```
level 100, USB powered, status 5 (full)
wakeup_sources (total_time ms since boot): mmc1:0001:2 (Wi-Fi SDIO) 2392,
  sy7673a_wakelock (EPD power IC) 18021 over 36 activations (max 601 ms), event0 53
dumpsys batterystats --reset   (so the next dump is the unplugged interval only)
```
Full table: `a11/gate17/build/battery/wakeup_sources-baseline.txt` (project side).

Protocol: unplug, press power once so the screen goes to AOD, leave it for >= 4 h
(overnight is better), plug back in, then read `dumpsys batterystats | grep -A3 Discharge`,
`suspend_stats`, and the `wakeup_sources` delta against the baseline.  Targets: percent
per hour with the screen off, suspend success count > 0, and which wake source dominates
`prevent_suspend_time` -- `sy7673a_wakelock` is the one to watch, it is the only
non-USB source that grows while idle.

## 3.9 Front light -- vendor lights module replaced, native slider + Warmth tile (DONE)
First real regression report from daily use: no brightness, no warmth.  Root cause and fix
in `docs/FRONTLIGHT.md`: the stock LM3630A is driven through `/proc/lm3630a/` by stock
SystemUI, never by the vendor lights HAL module (which writes to `/dev/disp`).  A
replacement `lights.virgo.so` keeps the whole framework/HIDL chain native and maps the
backlight call onto the stock tables; warmth is a persisted property with a QS tile
(einktile v3).  Doze/slider-minimum = off.  Measured end-to-end, committed with sources.

## 3.10 Incident: SurfaceFlinger livelock (hot + frozen screen) -- diagnosed, not fixed
2026-09-17/18, first hang of this port.  SF's app-facing EventThread spun holding the
EventThread mutex; main + binder threads blocked on it, `dumpsys SurfaceFlinger` timed out,
the display stopped updating (so the panel held its last image and the power button looked
dead), and the framework kept the display suspend blocker, so the SoC never suspended --
one core at max clock until the battery gives out, on or off the charger.  Front light,
composer shim, background load and CPU governor all measured and ruled out as the cause;
the clean-boot idle is 368%/400%.  Full evidence and the ranked next steps are in
`docs/INCIDENT-SF-LIVELOCK.md`.  Leading untested hypothesis: the doze/AOD transition on
unplug, which is our own overlay work.


## 3.11 Vendor RIL daemons stopped -- the 2-second retry loop is gone
Found while diagnosing the SF livelock (§3.10): `rild` logs
`fd = -1, sleep 2s wait device, total wait time: 3050s` -- it retries a modem device node
that does not exist, every 2 seconds, for the entire boot. This device has no modem and the
framework already knows (`ro.radio.noril=true`, `ril.sw.modem.status=off`), but the vendor
still starts two daemons for it:

```
/vendor/etc/init/rild.rc           service ril-daemon        class main
                                   group ... wakelock   capabilities BLOCK_SUSPEND
/vendor/etc/init/radio_monitor.rc  service radio_monitor-daemon  class main
                                   capabilities BLOCK_SUSPEND
```
Neither uses measurable CPU (`rild` never appears in `top` -- it sleeps between retries), so
this is not a CPU drain. What it is: a 0.5 Hz wakeup that never stops, from two daemons both
declared able to block suspend, on a device whose battery story is entirely about staying
suspended.

`configs/a11-boot-fixups.sh` now stops both at `sys.boot_completed`. Measured after a
reboot: `init.svc.ril-daemon=stopped`, `init.svc.radio_monitor-daemon=stopped`, **0** retry
lines in 20 s (was one every 2 s), no FATAL entries, SystemUI and Settings healthy, portrait
rotation intact. **Wi-Fi is unaffected** -- verified by re-associating afterwards: supplicant
`COMPLETED`, DHCP address, 15 ms ping, `WIFI[] state: CONNECTED`. RIL is the cellular stack;
Wi-Fi runs on `android.hardware.wifi@1.0-service` + `wificond` + `wpa_supplicant`, untouched.

Stopping at boot-completed rather than never starting them leaves them running for the first
~60 s of each boot. Preventing that entirely would mean declaring both service names in
`a11boot/a11-prepend.rc` as `disabled` (the same first-definition-wins trick used for
`hwcomposer-2-1`), which costs a new boot image; not worth it for 60 seconds.

The actual mAh saved is still **unmeasured** -- like everything else in §3.8, it needs the
unplugged interval.

## 3.12 KOReader: works only on v2021.05, and it rewrites the rotation setting
Two device-specific findings from installing KOReader (2026-09-18).

**Only releases up to v2021.05 work.** From v2021.06 KOReader targets SDK 30 and caps its
legacy storage permissions at `maxSdkVersion='29'`, relying solely on
`MANAGE_EXTERNAL_STORAGE`. That permission is only honoured by Android 11's **FUSE** storage
stack; this device's 8.1 vendor kernel provides **sdcardfs** instead, so granting it changes
nothing and KOReader exits:
```
datastorage.lua:46: Permission denied /storage/emulated/0/koreader
Zygote: Process exited cleanly (1)      <- deliberate exit, so no tombstone, empty crash.log
```
v2021.05 (targetSdk 28, uncapped `WRITE_EXTERNAL_STORAGE`) gets the writable sdcardfs view
and works. The grant must precede the process fork -- the storage mount view is chosen at
fork time, so `pm grant` then **force-stop** then launch:
```
/proc/<pid>/mounts before:  /storage/emulated ... gid=1015 mask=6   (default view, traverse only)
/proc/<pid>/mounts after:   /storage/emulated ... gid=9997 mask=7   (write view)
```

**It rewrites `user_rotation`.** KOReader declares `screenOrientation="nosensor"` with
`resizeableActivity=false`, i.e. the display's *natural* orientation -- landscape here.
SystemUI writes that back into `user_rotation`, and it survives reboots (MEASURED: after
running KOReader, `user_rotation=0` on the next boot). `a11-boot-fixups.sh` now re-asserts
`user_rotation 1` at boot: one bounded write, no polling. Same root cause as quirks 5-7.
KOReader also stays letterboxed (it renders a landscape-shaped surface);
`force_resizable_activities=1` widens it to full width but does not fix the height.

**Page keys.** Measured across all three readers, no single forward key works everywhere --
see quirk 11. `.kl` now sends `DPAD_RIGHT` on Vol Down so Kindle and KOReader both page.

## 3.13 The kernel already has FUSE -- no kernel work is needed (CORRECTION)
Investigating whether an updated kernel was needed for Android 11 storage, `/proc/config.gz`
on the running device settles it:
```
CONFIG_FUSE_FS=y          /dev/fuse present; fuse, fuseblk, fusectl in /proc/filesystems
CONFIG_CGROUP_CPUACCT=y
CONFIG_SDCARD_FS=y
persist.sys.fuse          <unset>   <- why userspace runs sdcardfs
```
**This corrects two earlier claims in this project.** The stock 4.9.56 kernel is *not*
missing FUSE -- it has both FUSE and sdcardfs compiled in, and the device runs sdcardfs
purely because `persist.sys.fuse` is unset. And Zygote's boot message
`createProcessGroup failed, kernel missing CONFIG_CGROUP_CPUACCT?` is a wrong guess by
Zygote: that option is `=y`. The real cause there is the read-only cgroup mount
(`Failed to make and chown /uid_<n>: Read-only file system`).

So the KOReader storage problem (3.12) is a *userspace configuration* question, not a
kernel capability one, and building a new kernel -- with all the risk to the vendor HWC's
`/dev/disp` ioctl ABI, the LM3630A and GT1158 drivers -- buys nothing for it.

**Switching to FUSE was then tested properly: it DOES NOT WORK.** (The first attempt was
misjudged -- see the paragraph after this one.) With `persist.sys.fuse=true`, waiting a full
**5 minutes past `sys.boot_completed`** (uptime 358 s, long after vold settles on a normal
boot), the device had **zero sdcardfs mounts and zero fuse mounts**, and `/sdcard` did not
exist. SystemUI and rotation were fine; only storage was gone. vold cannot bring up the
Android 11 FUSE stack here, so the sdcardfs limitation in 3.12 stands and KOReader stays
pinned to v2021.05.

Two practical notes for anyone retrying. `persist.sys.fflag.override.settings_fuse=true`
**forces `persist.sys.fuse` back to `true` on every boot**, so reverting needs BOTH set to
`false`; setting only `persist.sys.fuse=false` silently comes back up in the broken state.
And no data is at risk either way -- `/data/media/0` is untouched throughout; only the
emulated view disappears.

**The earlier inconclusive reading, for the record.** With
`persist.sys.fuse=true` the device booted, SystemUI and rotation were fine, but at 48 s
uptime there were no `emulated` mounts at all. That reading is not trustworthy: the same
check at the same uptime on the *reverted* boot also showed nothing, and storage was in
fact fine once vold finished creating the
`/sdcard -> /storage/self/primary -> /mnt/user/0/primary` chain later in boot. Both
properties are now `false` and sdcardfs is confirmed healthy. Anyone retrying this must
wait for a fully settled boot before judging, and should expect vold to need the matching
Android 11 userspace (MediaProvider's FUSE daemon) for the switch to mean anything.

## 3.14 FUSE storage WORKS -- the blocker was three missing mount points, not the kernel
Resolved 2026-09-18, and it supersedes the negative result in 3.13.

The kernel was never the problem (3.13: `CONFIG_FUSE_FS=y`). Neither was the daemon --
`MediaProvider.apk` ships `lib/armeabi-v7a/libfuse_jni.so` and `libfuse.so`, and vold has
full FUSE support. FUSE failed because **this port boots the stock Android 8.1 init, which
does not create the mount points Android 11's own `init.rc` creates.** vold said so exactly:

```
E vold: Failed to prepare directory /mnt/pass_through/0: No such file or directory
E vold: Failed to bind mount /mnt/runtime/write/emulated/0/Android/obb
        to /mnt/installer/0/emulated/0/Android/obb: No such file or directory
```

### The fix
`a11boot/a11-prepend.rc`, in **`on post-fs-data`** (NOT `on init`: `/mnt` is a tmpfs the
stock init mounts during its own `on init`, and because our actions are prepended they run
first and get wiped):
```
mkdir /mnt/user 0755 root root
mkdir /mnt/pass_through 0700 root root
mkdir /mnt/installer 0711 root root
mkdir /mnt/androidwritable 0711 root root
mount none /mnt/user /mnt/installer bind rec
mount none /mnt/user /mnt/androidwritable bind rec
```
plus `persist.sys.fuse=true` (configure-native.sh) and one symlink in
`a11-boot-fixups.sh`, because vold creates `/mnt/user/0/primary` on the sdcardfs path but
not on the FUSE one, and `/sdcard -> /storage/self/primary -> /mnt/user/0/primary`:
```
ln -s /mnt/user/0/emulated/0 /mnt/user/0/primary
```

### Verified on a clean boot, nothing manual
```
fuse mounts: 3     /dev/fuse on /mnt/user/0/emulated, /mnt/installer/0/emulated,
                   /mnt/androidwritable/0/emulated  (rw, allow_other)
/sdcard: 38 entries, writable
KOReader v2026.07.1 -- the CURRENT release -- runs, creates /sdcard/koreader, no crash log.
```
That is the app 3.12 had to pin to v2021.05. **The pin is lifted**; any app relying on
`MANAGE_EXTERNAL_STORAGE` should now work.

### Turning it off
Set BOTH `persist.sys.fuse` and `persist.sys.fflag.override.settings_fuse` to `false` and
reboot -- the fflag override forces `persist.sys.fuse` back to `true` on its own, so setting
only the one silently comes back up on FUSE. The boot image's mount points are harmless
when unused, so no reflash is needed to go back to sdcardfs.
