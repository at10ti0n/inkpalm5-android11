# Performance and battery pass (2026-09-24)

Measured on the device first; each change is reversible.

| # | Change | Evidence | Where |
|---|---|---|---|
| 1 | CPU governor `performance` -> `interactive` | Kernel boots with `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE`; all four cores held at the top clock whenever awake (frequency history: nothing below 1.2 GHz). The vendor power HAL (`power.virgo.so`, tag `AW_PowerHAL`) has a boot-complete mode that would switch it, driven by an Allwinner framework hint Android 11 never sends. With `interactive` the CPU sat at 480 MHz within seconds, and the HAL's launch hints did not switch it back. | `configs/a11-boot-fixups.sh` |
| 2a | SystemUI compiled (`speed`) | Replacing SystemUI left it at `extract` (no native code) until background dexopt, which needs idle **and** charging. After `cmd package compile`: status `speed`, executable mapping in the SystemUI process. | `configs/configure-native.sh` |
| 2b | Framework (services.jar) compiled and placed next to the jar | After the standby trial replaced services.jar, the system server ran with a verify-only compile. A `speed` compile in /data/dalvik-cache (25.7 MB, dex2oat 46 s) is mapped **non-executable** by system_server; only /system and boot oat files are r-xp. | `tools/install-services-odex.sh` (needs the /system write; run by the user) |
| 3 | 15 phone-only / unused apps disabled for the user | Messaging, Dialer, Contacts, Calendar + its provider (wake-up alarms), Gallery, Search, WebView tester, Cell Broadcast, SIM Toolkit, Traceur, Print spooler + service, Easter egg, basic dreams. MemAvailable after boot 444 MB, was 350-395 MB. | `configs/configure-native.sh` |
| 6 | Wi-Fi daemon exits cleanly at shutdown | Tombstone at every reboot: double free in the 8.1 daemon's SIGTERM cleanup, fatal under Android 11's Scudo. Fixed by a preload; a reboot then wrote none. | `wifi/`, `install/from-android.sh` |

Not done here: an unplugged drain measurement before/after item 1 (needs the device off the
cable for 30-60 min; on USB it never suspends), and removing the extra compositor restart per
boot (needs a boot image built from the current `a11boot/a11-prepend.rc`).
