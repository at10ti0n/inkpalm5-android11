# einktile -- Quick Settings tiles for the InkPalm's E-Ink modes (Android 11), 2026-09-17

CURRENT (v7): three tiles -- Mode, Refresh Screen, Portrait/Landscape (labelled Orientation);
warmth is Screen Temperature (v6, below); long-press Home refresh (v7, below). The text up to
"v6" is the history of earlier versions.

Four tiles available in Quick Settings until v6 (settings secure sysui_qs_tiles):
  Mode: Text / Graphics   toggles persist.sys.mRefreshMode between 2 (DU, fast, 1-bit)
                          and 132 (0x84, 16-grey quality) and sets persist.sys.canRefresh=1
                          -- the same two values and the same one-shot refresh stock Android
                          8.1's SystemUI RefreshModeSelectDialog used (Ghidra decompile of the
                          stock SystemUI vdex: a11/gate15/ghidra/eink-SystemUI-0.log).
  Refresh Screen          persist.sys.canRefresh=1 (stock's tile broadcast
                          android.eink.force.refresh has no receiver under AOSP).
  Warmth                  (removed in v6) adjusted the warm LED bank.
  Portrait / Landscape    switches user_rotation between 1 and 0, with separate orientation
                          icons. Requires the fixed-to-user configuration from
                          configs/configure-native.sh; keeps accelerometer_rotation=1
                          to avoid the SystemUI startup-reset issue. No root command,
                          service polling, or sensor auto-rotation is used by the tile.

v4 adds RotationTile. Updating from v2/v3 uses adb install -r; retain the public AOSP
platform signing key. Add the tile through Quick Settings Edit or the install script.
Use the current einktile.apk (v7) when preparing the installer assets directory.

v2: the app is PLATFORM-SIGNED with the public AOSP test key (keys/, which is the GSI's own
platform certificate) and declares sharedUserId=android.uid.system, so it writes the properties
directly via android.os.SystemProperties as the system UID -- no root, no PHH Superuser grant.
It also receives the stock intent `android.eink.force.refresh` (what Moaan's apps and stock
SystemUI send) and performs a full refresh, restoring that hook for any reading app.
Installing over the v1 (su-based) build requires `adb uninstall` first (signature change) and
re-adding the tiles to Quick Settings.  MEASURED 2026-09-17: receiver sets canRefresh=1 as
uid 1000; tile click toggles 132->2->132; zero su prompts.
Old v1 text: property writes went through PHH su (root shell); reads via getprop.  The vendor HWC reads
both properties per frame (a11/gate15/REFRESH-CONTROL.md), effect is immediate.

Build: MODE_TEXT=2 MODE_GRAPHICS=132 bash build.sh  (build-tools 34.0.0, platform 27,
JDK 17 -- JDK 21 breaks d8; signs using the public AOSP platform key in ../keys).  Output build/einktile.apk.
Installed 13:41; both services bound (dumpsys activity services).

v6 (2026-09-24): the Warmth tile is gone. ScreenTempService (started at boot, sticky, and by the
tiles as a backstop) follows Android's Night Light -- night_display_activated and
night_display_color_temperature -- and sets the warm LED level: on = 1..24 from mildest to
warmest temperature, off = persist.sys.frontlight.warm_day (default 0). Night Light's own tile,
Settings page and schedule are the UI (renamed Screen Temperature by overlays/screentemp-*).
Fixed on the way: rapid changes could ratchet brightness up one step (one pending restore now).

v5 (2026-09-22): SET_LOCK_WALLPAPER also pins the wallpaper service's desired size to the portrait
screen (SET_WALLPAPER_HINTS), so a screen-sized wallpaper is never scaled to a launcher's 2x-width
parallax request. Does not change the keyguard's 10% platform zoom (docs/STANDBY-IMAGE.md).

v7 (2026-10-02): long-press Home (the capacitive Moaan logo) = one full refresh, as requested
by a tester. HomeKeyService is an accessibility service that filters key events and sees
nothing else (no window content, no events). It holds Home back while it is down: released
within the long-press timeout it performs the Home action, held past it it sets
persist.sys.canRefresh=1. With the screen off it does not intercept, so the logo still wakes
the device. MEASURED on the device with the real key path (sendevent on goodix-ts, KEY_HOMEPAGE):
short press went home, a 1.2 s press refreshed and stayed in Settings, logo wake unchanged.
Note `input keyevent` does not reach accessibility key filters, so test with sendevent.
The installer enables it; Settings > Accessibility turns it off.

v8 (2026-10-04): the long-press refresh now actually flashes. The composer applies
persist.sys.canRefresh only to the next frame it draws, and holding the logo changes nothing on
screen, so v7 set the flag and nothing happened (MEASURED: flag still pending, no panel update;
the user saw no flash). HomeKeyService now adds and removes a 1x1 transparent accessibility overlay
for 300 ms to produce that frame. MEASURED with the real key path: panel update 91 ms after the
hold, flag consumed. (No vibration motor on this device: vibrator.default.so has no kernel driver.)

v9 (2026-10-04): a real full refresh. Setting persist.sys.canRefresh only redraws the next frame in
the current mode (DU/GU16: no flash), so neither the Refresh tile nor the long-press logo ever
flashed (user report). FullRefresh switches to GC16 (4), sets the one-shot, asks SurfaceFlinger to
repaint (binder transaction 1004 -- accepted from the system UID), waits until the composer has
consumed the one-shot, and restores the user's mode. Used by the tile, the logo hold and the
android.eink.force.refresh broadcast. MEASURED: composer drew mode=4 52 ms after a logo hold; mode
restored; the user saw the flash (manual GC16 test). v8's overlay kick is replaced by the repaint.
