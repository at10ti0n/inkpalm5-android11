# E-Ink refresh control on Android 11 (EPD105) -- MEASURED 2026-09-17

Source: Ghidra decompile of hwcomposer.virgo.so::displayToScreen (a11/gate15/ghidra/
hwc-refreshmode-java.log) + live test via the HWC's own log line
`area_info:(x,y,w,h) mode=%x` (logcat, tag from the vendor HWC).

Per frame, unless persist.sys.isTestMode=1:
  if persist.sys.canRefresh == 1:  mode = persist.sys.mRefreshMode (default 0x84);
                                    persist.sys.canRefresh := 0        (ONE-SHOT refresh)
  if not (mode & 0xf00 == 0x400 (rect) or (mode & 0xff) in {4,5} or (mode & 0xff) == 0x88):
       mode = persist.sys.mRefreshMode                                  (GLOBAL override)
The value is passed straight to DISP_EINK_UPDATE2 as the waveform mode.
persist.display.gu16_max_limit -> updateGu16Refreshlimit(): partial (GU16) updates before
an automatic full refresh; stock 0.

Live-verified (13:28): setprop persist.sys.mRefreshMode 2  -> log mode=2   (DU, fastest)
                       setprop persist.sys.mRefreshMode 16 -> log mode=10  (A2, fast)
                       setprop persist.sys.mRefreshMode 132 (0x84, stock quality default)
                       setprop persist.sys.canRefresh 1     -> one full refresh, self-clears
Effect is immediate; no restart.  Waveform bit names (Allwinner eink): 0x02 DU, 0x04 GC16,
0x08 GC4, 0x10 A2, 0x20 GL16/GU16, 0x40 GLR16, 0x80 GLD16 -- INFERRED from the vendor
enum convention; DU/A2/0x84 behaviour confirmed by the log, panel look not yet compared.

ADB one-liners (need su):
  fast reading/scrolling : adb shell su -c 'setprop persist.sys.mRefreshMode 2'
  quality                : adb shell su -c 'setprop persist.sys.mRefreshMode 132'
  clear ghosting now     : adb shell su -c 'setprop persist.sys.canRefresh 1'
Planned: Quick Settings tile app issuing the same writes (needs SDK build-tools).
