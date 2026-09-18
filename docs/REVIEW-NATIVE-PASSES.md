# Review of the native first and second passes, and the remaining quirks -- 2026-09-17

Independent review of commits `7aa8311` (first pass) and `1b1dc13` (second pass).  Every
claim below was re-measured on the live device on the same day; where the documents and
the device disagree, the device wins and it is said so.

## 1. Verdict on the first pass (rotation, key layouts, AOD)

**Rotation -- correct, and better than the workaround it replaces.**  Live:
`mRotation=1 mUserRotationMode=USER_ROTATION_FREE mFixedToUserRotation=true`, input
viewport `orientation=1`, with the guard loop gone.  The root cause (SystemUI's
`NavigationBarFragment` copying `display.getRotation()` into `user_rotation` at startup
when the sensor policy is *locked*) is the right reading of the Android 11 source, and the
three-boot controlled test is the right kind of evidence.  Two things to keep visible:
the Settings UI now shows *auto-rotate on* while WindowManager ignores it -- a user who
"fixes" that toggle re-introduces the reset; and the landscape interval at startup and the
letterboxing of natural-orientation apps are untouched, because natural is still landscape
(see §3.2 for the native route).

**Key layouts -- correct.**  One file per device name; `Vendor_0001_Product_0001.kl`
removed from the lookup path; `sunxi-gpadc0` back on `Generic.kl`.  The note that ID-based
files take precedence over name-based ones is exactly the trap the earlier shared file fell
into.

**AOD -- correct, and it corrects the earlier record.**  The claim "DozeService never
starts" was wrong: the service ran in DOZE with the display OFF, and the missing piece was
`config_dozeAlwaysOnDisplayAvailable`.  Live: the overlay resolves `true`, `[x]
net.inkpalm.overlay.aod`, `DOZE_SUSPEND`.  The synthetic sleep page and its polling loop
were the wrong tool and are rightly retired (the SleepActivity was since removed from the
tile APK outright, in v2).

## 2. Verdict on the second pass (suspend, USB)

**Suspend -- correct diagnosis, correct fix, measurement honestly bounded.**  Live: the
suspend service (PID 2099) holds `/sys/power/state` and `/sys/power/wakeup_count`;
both `mDecoupleHal*Config` flags are `true` from the static overlay; `suspend_stats` shows
0 this boot, which the document predicts for a USB-connected device.  The class change
(`early_hal` -> `hal`) is a real ordering fix against this 8.1 ramdisk and is correctly
flagged as boot-image-specific.  On the numbers: 4 mAh over 8 min 58 s is ~27 mA average
-- a large improvement over ~157 mA, but still an order of magnitude above e-reader
standby.  The next measurement should be unplugged, longer, and paired with a wake-source
inventory (`/sys/kernel/debug/wakeup_sources`), since the document already notes a
telephony partial wakelock.

**USB -- the best single change in either pass.**  Live: one `adbd` with PPID 1 (init-
managed), `ffs.ready=1`, `state=adb`, `b.1/f1 -> ffs.adb`, `adbd_apex` absent, the
`/cache/phh-adb` sentinel gone.  `adb root` works.  Reading the failure as *competing
daemons* (stock service pointing at a missing path, PHH's `override` unsupported by the
old init, plus the sentinel) is the correct account.  Two cautions: the symlink and the
`apex-setup.rc` patch live on the GSI's `/system`, so any GSI update reverts them (the
hash-gated patch script is the right guard); and the 120-second boot-trial guard protects
against a bad USB config, not against a failure to boot -- the document says so.

**Process.**  Evidence kept out of the public tree, backups staged before every change,
rollback written before the trial: that is the standard the earlier gates set, and it was
kept.  One divergence to fix: the v1 release images predate both passes, so a reader who
flashes v1 and then follows the current docs is running a mix.  Either cut v2 or mark v1
clearly in the release notes as "pre-native-pass".

## 3. Remaining quirks: native Android 11 routes, ranked

### 3.1  Refresh tiles without `su`  (high value, low risk, desk-buildable)
MEASURED: the GSI's platform certificate is the public AOSP test key (SHA1
`27:19:6E:38:...:3D:FA`).  An APK signed with AOSP's `platform.pk8` and declaring
`android:sharedUserId="android.uid.system"` runs as the system UID and may write
`persist.sys.*` directly through `SystemProperties.set` -- no root, no PHH Superuser
grant, no shell exec.  The same app can host a `BroadcastReceiver` for the stock intent
`android.eink.force.refresh` (what stock apps and the stock SystemUI tile already send),
which restores a per-app refresh hook for any reading app that knew the Moaan API.
Steps: fetch `platform.pk8/x509.pem` from AOSP `build/make/target/product/security`, sign
with the repo's `signapk`, add the sharedUserId, replace `Runtime.exec("su")` with
`SystemProperties` reflection.  Risk: a platform-signed app is fully trusted -- keep it
tiny.

### 3.2  Natural portrait  (fixes letterboxing and the landscape startup)  -- one experiment
The earlier `ro.surface_flinger.primary_display_orientation=90` trial transposed touch, but
it was run BEFORE the orientation-aware `.idc` existed.  AOSP's InputReader rotates touch
by the display viewport, and with a correct `.idc` the hwrotation case is supported on
other devices.  The experiment: rebuild the boot image with that property, keep
`user_rotation=0`, keep the idc, and measure the viewport and one corner tap.  If touch
follows, natural becomes portrait: no letterboxing, no startup rotation, no
fixed-to-user-rotation dependency.  If it transposes again, the result is at least a
measured "no" instead of an inherited one.  Cost: one boot image, one reboot, rollback by
flashing the current boot.

### 3.3  Composer mirror  -- stays a shim (verified)
The kernel display ABI (`sunxi_display2.h`) carries only stereo and scan flags in
`disp_buffer_flags`/`disp_scan_flags`; there is no flip or mirror bit, so no ioctl-level
native fix exists.  The vendor HWC does have a G2D transform path (`submitTransformLayer`,
`hwc_set_layer_transform`) that could apply `FLIP_H` natively, but SurfaceFlinger never
sends a flip transform and cannot be configured to.  Options are a SurfaceFlinger patch
(a GSI rebuild) or the present preload.  Recommendation: keep `libhwcflip.so`, document it
as permanent, and drop the "proper fix" wording.

### 3.4  TWRP by-name links  -- native via the device tree
Android 9+ `init` reads `/proc/device-tree/firmware/android/boot_devices`; with it,
ueventd creates `/dev/block/by-name/*` itself and the fifteen `symlink` lines go away.
The node can be added to the DTB in the `dto` partition (`dtc` decompile, add
`firmware { android { compatible = "android,firmware"; boot_devices = "soc/sdc2..."; }; }`,
recompile, flash `dto`).  Benefit is small (the symlinks work); risk is a partition the
project has never written.  Proposed only if `dto` is ever modified for another reason
(e.g. §3.2's alternative of a portrait panel node).

### 3.5  Telephony  -- native via feature files
The vendor declares `android.hardware.telephony*` in `/vendor/etc/permissions/*.xml`.
Removing those files (vendor partition, already writable in this project) makes the
framework stop advertising telephony; then `com.android.phone` can be disabled without
the crashes that disabling it on a telephony device causes.  Ties directly to the
telephony partial wakelock seen during the suspend measurement.

### 3.6  Permissive-init patch  -- native means the Android 11 init
The two-byte patch exists because the 8.1 `user` init ignores `androidboot.selinux=
permissive`.  The native alternative is booting the GSI's own `init` (first-stage mount,
apexd, linkerconfig) -- the standard PHH path on other devices, and the largest remaining
item; everything above (USB, suspend ordering) would change with it.  Long-term only.

### 3.7  Leave as is
Volume keys (no per-app mapping in Android; Key Mapper is the only per-app route), the
logo as a single key (controller firmware), Kindle's secure surface.

## 4. Suggested order
3.1 (tile as system app) -> 3.2 (one-boot portrait experiment) -> 3.5 (telephony) ->
unplugged suspend measurement with wake-source inventory -> v2 release capturing both
passes as an installer script rather than images (the passes edit /system and /vendor,
which images cannot carry).
