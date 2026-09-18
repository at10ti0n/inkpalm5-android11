# Native Android 11 first pass (EPD105, 2026-09-17)

This is a source-tree update after v1; the published v1 images are unchanged.
It keeps PHH v313, the existing boot/kernel, and the working composer mirror shim.

## Rotation: persistent fixed portrait without a guard

Use these three settings together (as root):

```sh
wm set-fix-to-user-rotation enabled
settings put system accelerometer_rotation 1
settings put system user_rotation 1
```

The `accelerometer_rotation=1` value is intentional. WindowManager's fixed-to-user
rotation takes precedence over sensor and app orientation requests. Setting the
sensor policy to locked (`0`) makes Android 11 SystemUI's navigation startup copy
the current display angle into the saved rotation. The initial angle here is
landscape (`0`), so it overwrites portrait (`1`). The previous boot script hid this.

Evidence: with the boot script replaced by a read-only observer, the locked-policy
boot changed user_rotation from 1 to 0. With sensor policy enabled and fixed rotation
retained, the following boot preserved 1 and reached portrait with no rotation writes.
The source and installed SystemUI both contain NavigationBarFragment's
`setRotationLockedAtAngle(display.getRotation())` call gated on `isRotationLocked()`.
This is a matching code path and a controlled behavioural test, not a captured Java
call stack. Source:
https://android.googlesource.com/platform/frameworks/base/+/android-11.0.0_r1/packages/SystemUI/src/com/android/systemui/statusbar/phone/NavigationBarFragment.java

A brief landscape startup remains before WindowManager applies portrait; the operator
confirmed this. Natural geometry is still landscape, so app letterboxing is not fixed.
The auto-rotate UI describes the sensor policy, not the fixed WindowManager policy;
turning it off can reintroduce the startup reset. Do not run `wm set-user-rotation lock`.
The shipped startup script no longer writes either rotation setting or polls them.

## Independent key layouts

`sunxi-keyboard.kl` keeps Vol Down = SPACE and Vol Up = DPAD_LEFT, plus ENTER/HOME/MENU.
`pmu1736-powerkey.kl` contains POWER WAKE. The logo layout is unchanged.

Remove the old `Vendor_0001_Product_0001.kl` from the active lookup paths after backing
it up: ID-based files take precedence over device-name files. On this device that
shared file also matched `sunxi-gpadc0`; it now falls back to Generic.kl.
Reboot and verify each device's `KeyLayoutFile` in `dumpsys input`.
No kernel ID changes are necessary.

## Native AOD

The original statement that DozeService never starts was incorrect for the current
runtime. It ran in DOZE with an OFF display. The missing framework capability was
`android:bool/config_dozeAlwaysOnDisplayAvailable=false`.

The resource-only `overlays/aod` package changes that boolean to true. The existing
SystemUI DozeService then reaches DOZE_AOD / DOZE_SUSPEND. The operator confirmed a
readable clock on the physical panel. `debug.doze.aod=true` was used only for the
initial experiment; the persistent overlay works with that property unset.

The original PHH SystemUI AOD overlay was already enabled and is left unchanged.
The capability overlay does not alter refresh waveforms, brightness, display power
implementation, or the per-panel calibration. It must be preinstalled (tested in
/vendor/overlay), because framework-res does not expose these resources to ordinary
third-party overlays. A normal APK sideload is not the installation method.

Native `screen_off_timeout=120000` replaces the polling SleepActivity launcher and
synthetic Sleep key. It respects Android user activity and keep-screen-on requests.
The sleep screen is now the native AOD one (the SystemUI clock); the old SleepActivity
was removed from the tile APK in v2 and no longer exists anywhere in this repo.

This verifies display behaviour, not battery life. USB-connected suspend statistics
showed no completed kernel suspend in the test, and telephony sometimes held a partial
wakelock. DOZE_SUSPEND is an Android display state, not proof of CPU suspend or low drain.
An unplugged battery/suspend measurement remains separate work.

## Install on an existing v1 setup

Keep a copy of the old startup script and shared key layout outside their active paths.
The commands below assume an ADB shell with root (`su 0 sh` on the tested boot).
Host build:

```sh
bash overlays/aod/build.sh
adb push overlays/aod/build/inkpalm-aod.apk /data/local/tmp/
adb push configs/sunxi-keyboard.kl configs/pmu1736-powerkey.kl /data/local/tmp/
adb push configs/a11-boot-fixups.sh configs/configure-native.sh /data/local/tmp/
```

In the rooted device shell, install the overlay on /vendor, set owner root:root,
mode 0644 and context u:object_r:vendor_file:s0, then remount /vendor read-only.
Copy the two named layouts into /data/system/devices/keylayout with owner
system:system and mode 0644, and move the old shared ID layout into the backup folder.
Copy the new startup script to /data/local/a11-boot-fixups.sh, mode 0755.
Stop any existing manually launched old polling script as well as the init service;
reboot to clear all old processes and load the overlay and key layouts.

After boot, run the staged `configure-native.sh` once as root. Reboot again to verify
persistence. Future boots do not need this script; the settings and overlay are saved.
The exported init service is now explicitly `oneshot` so the bounded startup script
will not restart in a loop. The existing Gate 17 boot already had `oneshot`.

Verification:

```sh
settings get system user_rotation                 # 1
settings get system accelerometer_rotation        # 1 (intentional)
settings get system screen_off_timeout            # 120000
cmd overlay lookup android android:bool/config_dozeAlwaysOnDisplayAvailable  # true
cmd overlay list                                 # [x] net.inkpalm.overlay.aod
dumpsys window displays                          # mRotation=1, mFixedToUserRotation=true
dumpsys input                                    # separate KeyLayoutFile paths
getprop init.svc.a11fixups                         # stopped after bounded startup
```

After an ordinary sleep, `dumpsys dreams` should report DOZE_SUSPEND and
`dumpsys activity service com.android.systemui/.doze.DozeService` should report
DOZE_AOD. Verify a visible clock, physical power/wake and page keys on the panel too.

## Rollback

Disable `net.inkpalm.overlay.aod` using `cmd overlay disable --user 0`, restore the
backed-up startup script and shared ID layout, and reboot. The shared layout takes
precedence over the named files. The original script restores its own locked rotation
and timeout. (It cannot resume the old custom sleep page: that activity was removed
from the tile APK in v2.) To remove the overlay file entirely,
delete only /vendor/overlay/inkpalm-aod.apk with /vendor temporarily writable, then
remount read-only and reboot. No boot or recovery image needs to be flashed.

## Follow-up

The [second pass](NATIVE-A11-SECOND-PASS.md) adds the required suspend-service
startup and static power-overlay fixes. The capability overlay alone does not
provide working kernel suspend on this boot/GSI combination.
