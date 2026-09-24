# Incident: a fully compiled framework made the device much slower (2026-09-24, reverted)

## Summary

To speed up the system server, services.jar was compiled with the `speed` filter (all 25 MB of
native code) and installed as `/system/framework/oat/arm/services.odex`. Within minutes the user
reported the device was "much slower". Kindle stopped responding twice, the kernel's memory
reclaim ran continuously, and the system server re-read evicted code from storage. It was
reverted about 30 minutes later, with a /data-only change.

**Status:** reverted, but **the revert has not been shown to fix the slowdown** (see "After the
revert"); the cause is not established. `system_server` loads the verify-only /data copy again. The
`/system/framework/oat/arm/services.{odex,vdex}` files are still present but unused, because
system_server prefers the /data copy (see below). Remove them to finish the cleanup (needs a
/system write).

## Background

- Device: 939 MB RAM, `ro.config.low_ram=true`, 690 MB zram swap, eMMC storage, 4x Cortex-A7.
- Since the standby-image trial replaced services.jar (2026-09-22), its prebuilt odex no longer
  matched and was moved aside. Android 11 then compiles system-server jars into
  /data/dalvik-cache with `dalvik.vm.systemservercompilerfilter`, default **`verify`** (no native
  code; the JIT compiles hot methods at runtime into anonymous memory).
- The performance pass (docs/PERFORMANCE-BATTERY.md, item 2b) treated "no AOT code" as a defect
  to fix. On this device that premise was wrong.

## Timeline (all 2026-09-24, device local time)

| Time | Event |
|---|---|
| 02:12 | `speed` compile of services.jar via the zygote property route; dex2oat ran 46 s and produced a 25.7 MB odex in /data/dalvik-cache. |
| 02:13 | Measured: system_server maps it **non-executable** (`r--p`). Only boot oats and /system odex files were `r-xp`. |
| 23:05 | The user ran `tools/install-services-odex.sh`: the odex/vdex were copied next to the jar, and the framework restarted. The script died silently: `grep -c` exits 1 on a zero count under `set -e`, which left its wake lock held. |
| 23:15 | Second framework restart after removing the /data copy. system_server now maps `/system/framework/oat/arm/services.odex` `r-xp`, i.e. executes it. |
| 23:17-23:18 | Phone-process ANRs on BOOT_COMPLETED. These happen at every framework start, and predate this change. |
| 23:22 | **Kindle ANR** (input dispatching timed out). |
| 23:2x | The user reports "the device is actually much slower now". |
| 23:29 | **Kindle ANR** (a Google datatransport JobService took too long). |
| 23:37 | Reverted: the verify-only /data copy was restored (a 09-22 backup of the same jar), and the framework restarted. system_server maps only the /data copy. |

Kindle had no ANRs in the device's dropbox history before 23:22. Phone ANRs occur at every boot.

## Evidence

From the two Kindle ANR reports:

- `kswapd0` at 10-11% CPU in both 20-23 s windows: continuous memory reclaim.
- system_server: **1,323 major faults in 20.7 s** (23:29), and 208 in 23 s (23:22). Major
  faults are page reads from storage: code and data pages that were evicted and needed again.

Snapshot at 23:23: MemAvailable 245 MB (444 MB after the previous boot); zram about 88 MB of swap
in use. Kindle 194 MB PSS plus a 43 MB WebView process. system_server PSS **dropped** to 80 MB
(from 108 MB), because compiled code is file-backed, clean, and not counted as dirty memory.

Ruled out on the way:
- **CPU governor** (`interactive`, changed earlier the same day). Cold launch of Settings/EinkBro was
  as fast or faster than under `performance` (the order of runs biased the comparison).
- **Display pipeline.** vsync 62.5 ms, not synthetic; SF patch in service; no SurfaceFlinger spin.
- **iowait / load average.** Two kernel threads (`eink pixel proc`, `usb-hardware-sc`) sleep in
  uninterruptible `msleep` permanently, and inflate load and iowait on every boot. It is not real I/O.

## After the revert (measured 23:38-23:40)

120 s starting ~20 s after the framework restart that applied the revert:

| | During the 23:29 ANR | After the revert |
|---|---|---|
| system_server major faults | 1,323 in 20.7 s (~64/s) | 901 in 120 s (~7.5/s) |
| kswapd0 CPU | 10-11% | ~14% |
| swap-outs | -- | 56,084 pages in 120 s |
| MemAvailable | 245 MB (23:23) | 193 MB |

Lower fault rate, but memory reclaim just as busy. Confounded: every app restarts cold after a
framework restart, and a read-only diagnosis (heavy `dumpsys meminfo`) ran in the same window.
So the explanation below is a **hypothesis**, not a finding.

A second suspect, omitted from the first version of this document: earlier the same day
**SystemUI**, a persistent process, was compiled with the same full `speed` filter
(`cmd package compile -m speed -f com.android.systemui`, about a 15 MB oat, previously
"extract"). Same pattern, applied to an always-resident process. Other changes that day: CPU
governor `interactive`, 15 apps disabled, front-light HAL. A follow-up diagnosis was started to
separate these.

## Why it happened (hypothesis; see above)

`speed` compiles every method of services.jar: 25 MB of native code that has to be paged in from
eMMC as it executes. Under the JIT, only hot methods get compiled, into a small anonymous code
cache that swaps to zram (RAM-speed), not eMMC. With Kindle holding about 200 MB, the kernel keeps
evicting the clean, file-backed odex pages (cheapest to drop), and system_server immediately
faults them back in from storage: thrash. AOSP's own choice for low-RAM devices is consistent
with this. System-server jars compiled on /data default to `verify`, and low-RAM builds
generally prefer `speed-profile` (hot methods only) or less over full `speed`.

Two mechanisms found along the way, useful for any future attempt:

1. **system_server prefers a /data/dalvik-cache copy over the /system odex** whenever both exist
   and are valid, and maps a /data copy **non-executable**. So a /data compile never helps
   system_server, and the /system odex only takes effect once the /data copy is removed.
2. **`speed-profile` needs a profile.** System-server profiling is off by default
   (`dalvik.vm.profilesystemserver`), so `speed-profile` without one compiles nothing extra.

## Process mistakes

- A "biggest speed-up" was predicted from a mechanism ("AOT beats JIT") without checking the
  device's constraint (low RAM, slow eMMC), and without a before/after measurement plan.
- The install script was not dry-run on its failure path (the `grep -c` / `set -e` abort), and
  held a wake lock without a trap.
- The success check proved the code was *executable*, not that the device was *faster*.

## Open questions (for the follow-up diagnosis)

- Is a profile-guided compile (`speed-profile` with a real system-server profile) a net win here?
  How would one collect the profile, and what size and fault behaviour result?
- Do major faults and kswapd return to baseline after the revert, with the same Kindle workload?
- Is the verify+JIT state actually slow at anything measurable (boot time, input latency), or was
  "no AOT code" never a problem worth fixing on this device?
