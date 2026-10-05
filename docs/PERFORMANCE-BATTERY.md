# Performance and battery pass (2026-09-24)

Measured on the device first; each change is reversible.

| # | Change | Evidence | Where |
|---|---|---|---|
| 1 | CPU governor `performance` -> `interactive` | Kernel boots with `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE`; all four cores held at the top clock whenever awake (frequency history: nothing below 1.2 GHz). The vendor power HAL (`power.virgo.so`, tag `AW_PowerHAL`) has a boot-complete mode that would switch it, driven by an Allwinner framework hint Android 11 never sends. With `interactive` the CPU sat at 480 MHz within seconds, and the HAL's launch hints did not switch it back. | `configs/a11-boot-fixups.sh` |
| 2a | SystemUI compiled (`speed`) | Replacing SystemUI left it at `extract` (no native code) until background dexopt, which needs idle **and** charging. After `cmd package compile`: status `speed`, executable mapping in the SystemUI process. | `configs/configure-native.sh` |
| 2b | Framework (services.jar) compiled and placed next to the jar | After the standby trial replaced services.jar, the system server ran with a verify-only compile. A `speed` compile in /data/dalvik-cache (25.7 MB, dex2oat 46 s) is mapped **non-executable** by system_server; only /system and boot oat files are r-xp. | **Reverted 2026-09-24.** Running the full `speed` odex made the device much slower (memory thrash, Kindle ANRs) -- see [INCIDENT-SERVICES-ODEX.md](INCIDENT-SERVICES-ODEX.md). Do not re-run `tools/install-services-odex.sh`. |
| 3 | 15 phone-only / unused apps disabled for the user | Messaging, Dialer, Contacts, Calendar + its provider (wake-up alarms), Gallery, Search, WebView tester, Cell Broadcast, SIM Toolkit, Traceur, Print spooler + service, Easter egg, basic dreams. MemAvailable after boot 444 MB, was 350-395 MB. | `configs/configure-native.sh` |
| 7 | `vm.swappiness` 60 -> 100 | Recommended by the read-only diagnosis (DIAGNOSIS-FRAMEWORK-COMPILE.md): reclaim idle anonymous memory into zram (688 MB lz4, ~3.4:1) rather than evicting code pages that must be re-read from eMMC. Long-term effect not yet measured. | `configs/a11-boot-fixups.sh` |
| 8 | Phone process: no more radio wait | Since rild was stopped (2026-09-17, it retried a missing modem node every 2 s) the vendor-declared IRadio/slot1 never appears; with mobile data still marked capable, Android built one phone and `RIL.getRadioProxy` waited forever: two phone ANRs at every boot and a 1 Hz retry log. `overlays/nomodem` sets `config_mobile_data_capable=false`; with voice and SMS already off, the modem count is 0 (the Wi-Fi-only tablet setup). After reboot: 0 ANRs, 0 retry lines, Wi-Fi fine. | `overlays/nomodem`, `install/from-android.sh` |
| 6 | Wi-Fi daemon exits cleanly at shutdown | Tombstone at every reboot: double free in the 8.1 daemon's SIGTERM cleanup, fatal under Android 11's Scudo. Fixed by a preload; a reboot then wrote none. | `wifi/`, `install/from-android.sh` |

Not done here: an unplugged drain measurement before/after item 1 (needs the device off the
cable for 30-60 min; on USB it never suspends), The extra compositor restart per boot is gone since
2026-09-25: a boot image built from the current `a11boot/a11-prepend.rc` (sha256 `8b3be428...`,
from pristine stock) bind-mounts the SurfaceFlinger patch at `post-fs-data`. Verified: SurfaceFlinger
started once with the patched library, the boot script reported "already in service", no ANRs.

## 2026-10-05: measured follow-ups (device on v2.6.1)

| Item | Result | Kept? |
|---|---|---|
| Standby, Wi-Fi off (3 h 51 min, untouched) | ~1.6 mAh/h (~3 %/day); CPU awake 0.6 % | -- |
| Standby, Wi-Fi on (9 h 57 min, untouched) | ~2.1 mAh/h (~4 %/day); CPU awake 0.7 %; ~9 Wi-Fi wakeups/h | Wi-Fi costs ~1 %/day: not worth changing defaults |
| Volume-key ADC 1000 -> 400 Hz (`/sys/class/gpadc/sr`; driver accepts 400..100000) | interrupts 911 -> 306/s, keys fine; screen-on current 148 mA median at **both** rates (440 samples, alternating) | **No**: no measurable saving; stock 1000 Hz kept |
| NEON frame-mirror copy (libhwcflip) | copy 29 -> 6 ms/update, ready->shown median 71 -> 17 ms | **Yes** (byte-identical; panel checked) |
| Vendor HWC verbose log tag -> Info | logd ~19 -> ~4.4 ms CPU per panel update | **Yes** (configure.sh; re-enable for debugging) |
| JIT profile mirror (zz-inkpalm-profiles.rc) | app profiles were 0 bytes; now recorded | **Yes** |
| "GPU missed frames" | 0 over 60 s idle and over 12 keystrokes | closed |
| Deep doze | never entered naturally even in 10 h untouched (light idle 99 %); manual stepping reaches IDLE | open, low value (CPU already asleep >99 %) |

| App profiles -> Kindle cold start (caches dropped, 3 runs each) | `verify` (no profile, as before the fix): 16.4 / 14.5 / 14.7 s; `speed-profile` from its recorded profile: 11.9 / 9.5 / 5.0 s | **Yes** (the profile fix; bg-dexopt compiles while charging) |
| Kindle ANR 2026-10-04 01:25 (book open) | Kindle 243 % CPU in its own Compose layout, kswapd 29 %, SurfaceFlinger 2.7 %: app work under memory pressure, not the display path | mitigated by the compiled Kindle |
| Memory with Kindle open | MemAvailable 272 MB, swap 162 MB used; zram already lz4 at 3.3:1 | -- |
| Unused-hardware services | `com.android.smspush` disabled (4 MB, no SMS). RCS (`com.android.service.ims`) and Secure Element (`com.android.se`) are persistent and restart at once -- left alone | smspush **yes** |

Screen on, idle, front light on: ~150 mA -- the front light and panel dominate; nothing in software
moved it measurably.

## 2026-10-05: responsiveness candidates (after an external review)

| Candidate | Measured | Decision |
|---|---|---|
| **Interaction CPU boost** (Power HAL ignores hint 2) | Trace (ftrace cpu_frequency, real key via goodix-ts): after idle the governor's first step comes 24-42 ms after the key and goes straight to 1.4-1.8 GHz (touch load trips go_hispeed); the HAL already pins 1.8 GHz for ~3 s on wake. A/B, 12 idle trials each: first panel update 394 ms median (key) vs 375 ms (key + boostpulse); ranges overlap | **No**: ~19 ms of ~390 ms; the rest is app/system work |
| **Slow-frame tail** (p95 ~73 ms) | Ready->shown is bimodal: 10-19 ms (63 frames) or 60-79 ms (36): a frame ready just after SurfaceFlinger's wake waits one 62.5 ms vsync period; one 131 ms frame = two periods | **No change**: it is 16 Hz vsync quantization, not stalls; the 16 Hz period stays (livelock fix, panel rate) |
| **App switching** | 24 Kindle<->KOReader switches, normal caches: 0 LMK kills, same PIDs; KOReader HOT 204-339 ms; Kindle first panel update a median 95 ms after the request (it then redraws for seconds itself) | **No change**: no reloads; remaining time is the apps' own work |
| **adbd crash** (tombstone 2026-10-04 01:05) | Happened during a reboot the host had just triggered (shutdown teardown). Not reproduced: ~8 later reboots, 600 rapid/parallel adb calls, 50 transfers killed mid-stream -- same adbd PID, no tombstone | **No change**: benign shutdown-time crash |
| **Warmth slider throttle 300 -> 120 ms** (+ monotonic clock, one reusable callback, no duplicate writes, release always applied) | A Night Light change costs 0 panel updates (identity transform). 2 s drag: 7-8 warm-level changes (300 ms) vs 15-16 (120 ms), 6 drags each; brightness unchanged after ~90 changes at 255 and at 100; Night Light restored; no SystemUI crash | **Yes** (systemui/WarmthSliderView.java; needs the SystemUI-warmth.apk release asset) |
