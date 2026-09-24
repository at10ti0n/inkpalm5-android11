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
cable for 30-60 min; on USB it never suspends), and removing the extra compositor restart per
boot (needs a boot image built from the current `a11boot/a11-prepend.rc`).
