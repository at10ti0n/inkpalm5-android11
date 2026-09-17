# einktile -- Quick Settings tiles for the InkPalm's E-Ink modes (Android 11), 2026-09-17

Two tiles, placed first in Quick Settings (settings secure sysui_qs_tiles):
  Mode: Text / Graphics   toggles persist.sys.mRefreshMode between 2 (DU, fast, 1-bit)
                          and 132 (0x84, 16-grey quality) and sets persist.sys.canRefresh=1
                          -- the same two values and the same one-shot refresh stock Android
                          8.1's SystemUI RefreshModeSelectDialog used (Ghidra decompile of the
                          stock SystemUI vdex: a11/gate15/ghidra/eink-SystemUI-0.log).
  Refresh Screen          persist.sys.canRefresh=1 (stock's tile broadcast
                          android.eink.force.refresh has no receiver under AOSP).
Property writes go through PHH su (root shell); reads via getprop.  The vendor HWC reads
both properties per frame (a11/gate15/REFRESH-CONTROL.md), effect is immediate.

Build: MODE_TEXT=2 MODE_GRAPHICS=132 bash build.sh  (build-tools 34.0.0, platform 27,
JDK 11; keystore.jks generated on first build, pass einktile).  Output build/einktile.apk.
Installed 13:41; both services bound (dumpsys activity services).
