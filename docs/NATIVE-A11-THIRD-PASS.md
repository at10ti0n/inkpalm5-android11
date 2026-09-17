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

## 3.2 Natural portrait experiment -- boot image built, NOT flashed
`a11boot/mkboot.py` accepts `A11_SF_ORIENTATION=90` to add
`setprop ro.surface_flinger.primary_display_orientation ORIENTATION_90` to the prepended rc.
Test plan: flash, keep `user_rotation=0`, keep the orientation-aware `.idc`, then read the
input viewport and one corner tap.  If touch follows the rotated viewport, natural becomes
portrait (no letterboxing, no landscape startup, no fixed-to-user-rotation dependency).
The earlier transposed-touch result predates the `.idc`, so it is not evidence either way.
