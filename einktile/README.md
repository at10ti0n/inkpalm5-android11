# einktile -- Quick Settings tiles for the InkPalm's E-Ink modes (Android 11), 2026-09-17

Two tiles, placed first in Quick Settings (settings secure sysui_qs_tiles):
  Mode: Text / Graphics   toggles persist.sys.mRefreshMode between 2 (DU, fast, 1-bit)
                          and 132 (0x84, 16-grey quality) and sets persist.sys.canRefresh=1
                          -- the same two values and the same one-shot refresh stock Android
                          8.1's SystemUI RefreshModeSelectDialog used (Ghidra decompile of the
                          stock SystemUI vdex: a11/gate15/ghidra/eink-SystemUI-0.log).
  Refresh Screen          persist.sys.canRefresh=1 (stock's tile broadcast
                          android.eink.force.refresh has no receiver under AOSP).
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
JDK 11; keystore.jks generated on first build, pass einktile).  Output build/einktile.apk.
Installed 13:41; both services bound (dumpsys activity services).
