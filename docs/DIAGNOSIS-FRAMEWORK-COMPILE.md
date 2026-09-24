# services.jar compile state on the InkPalm 5 Pro Mini: diagnosis (2026-09-24/25)

Read-only diagnosis, device unchanged. All device work was `adb shell "su -c ..."`; nothing was
written to /system, /vendor or /data (not even /data/local/tmp). Raw material (ANR and
low-memory reports, redacted logs, meminfo dumps) stays local to the author's machine because it
contains device and application details; the commands that produce it are in the appendix.

Legend: **[M]** measured on the device tonight (command given); **[D]** from a device report
(ANR/dropbox) written at the time; **[S]** read from AOSP android11-release source; **[I]** inference.

## 0. Recommendation

Leave services.jar at `verify` + JIT. Do not re-install the 25 MB `speed` odex as it was done
tonight (no app image, timed against a cold restart with Kindle + WebView resident). The
incident's causal story ("file-backed AOT code thrashes on this device") is **not established**:
the phh GSI shipped exactly such a file (25.7 MB, `compiler-filter = speed`, plus a 2.1 MB
`.art`) and the device ran it from 09-17 to 09-22; the post-revert restart showed the same thrash
signature; and that signature decays to zero within ~15 minutes at rest. Measured at rest, the
verify+JIT state is not slow at anything I could measure read-only: system_server uses ~3% of one
core with the screen on, its JIT code is 1.2 MB, and the whole system takes under one major fault
per second. If framework AOT is ever re-attempted, do it the stock way (speed-profile or speed
**with** the app image, on /system, /data copy removed) under a matched-time A/B protocol
(section 6). Better levers exist first: swappiness for the zram setup, and the phone-process
IRadio loop (section 7).

## 1. Device state as found (23:41-00:05 device time)

[M] `getprop`: `dalvik.vm.usejit=true`, `dalvik.vm.usejitprofiles=true`,
`dalvik.vm.jit.codecachesize=0` (obsolete vendor property; Android 11's AndroidRuntime.cpp reads
`dalvik.vm.jitmaxsize/jitinitialsize/jitthreshold`, none set [S] aosp/AndroidRuntime.cpp
814-832), `ro.config.low_ram=true`, `pm.dexopt.bg-dexopt=speed-profile`. No
`dalvik.vm.systemservercompilerfilter`, no `dalvik.vm.profilesystemserver`. Build is
`phh:userdebug/test-keys` [D] (lowmem report header).

[M] Files:

| File | Size | Filter | Mapped by system_server |
|---|---|---|---|
| `/data/dalvik-cache/arm/system@framework@services.jar@classes.dex` (odex) | 164,520 B | `verify` (oatdump) | `r--p` + `rw-p` |
| `/data/dalvik-cache/arm/system@framework@services.jar@classes.vdex` | 15,036,581 B | (contains the dex) | `r--p`, **Rss 12,220 kB of 14,688 kB** |
| `/system/framework/oat/arm/services.odex` (tonight's, unused) | 25,767,288 B | `speed` (oatdump) | not mapped |
| `/system/framework/oat/arm/services.vdex` (tonight's, unused) | 15,071,840 B | | not mapped |
| `/data/local/inkpalm-standby-backup/oat/services.odex` (**original GSI prebuilt**) | 25,741,348 B | **`speed`**, `compilation-reason = prebuilt` (key-value store parsed from the file header) | n/a |
| `/data/local/inkpalm-standby-backup/oat/services.art` (original app image) | 2,138,112 B | | n/a |
| `/data/local/inkpalm-standby-backup/oat/services.vdex` (original) | 135,718 B | | n/a |

The original prebuilt is the same size and filter as tonight's compile. What tonight's install
lacked was the 2.1 MB `.art` app image (installd only writes one when a reference profile is
present [S] aosp/installd-dexopt.cpp 2202-2213), and its vdex carried a full copy of the dex
(15 MB) where the prebuilt's did not.

[M] JIT in system_server (`/proc/<pid>/smaps`, `/memfd:jit-cache`): code region Rss 1,188 kB,
data region Rss 840 kB (32 MB reserved each). SystemUI similar. JIT memory is ~2 MB of shmem
(swappable to zram), not a RAM problem.

[M] SystemUI (`cmd package compile -m speed` at 02:11, status `speed`, 14.97 MB odex in
/data/dalvik-cache, mapped **`r-xp`**): code segment Size 11,532 kB, **Rss 5,152 kB** (45%
resident at rest); 941 major faults in its lifetime (started 23:38), **+23 in a quiet 120 s**. An
app-process odex in /data/dalvik-cache executes fine; the non-executable rule is specific to
system_server (section 3).

[M] Memory (`dumpsys meminfo`, 23:45, Kindle in background): Total 939,832 kB; Free RAM 268 MB
(64 MB cached PSS + 135 MB cached kernel + 70 MB free); ZRAM 22.6 MB physical for 76 MB swapped
(3.4:1); Kindle 190.8 MB PSS + WebView sandbox 27.8 MB; system_server 69 MB; SystemUI 38.9 MB;
launcher 40.7 MB; zygote 60 MB native [D]. Kindle's PSS is 54 MB `.apk mmap` + 23 MB `.so mmap`
+ 68.5 MB native heap (`dumpsys meminfo 27126`): its file-backed code alone (77 MB) is three
times the framework's.

[M] lmkd uses the in-kernel driver: `sys.lmk.minfree_levels =
18432:0,23040:100,27648:200,32256:250,36864:900,46080:950` (pages): cached apps are killed
below 180 MB free+file, foreground below 72 MB. `vm.swappiness=60`, `vfs_cache_pressure=100`,
`page-cluster=0`, `extra_free_kbytes=10800`. zram 688 MB, lz4, 4 streams. eMMC:
`read_ahead_kb=128`, scheduler `cfq`; /system ext4, /data f2fs. Kernel 4.9.56.

## 2. Is verify+JIT measurably slow at anything that matters? (Q1)

### 2a. Steady state, screen on, launcher focused, Kindle resident in background

Two 120 s samples (`/proc/vmstat`, `/proc/<pid>/stat` fields 10/12/14/15, `/proc/meminfo`):

| Window (uptime s) | pgmajfault | pswpout | system_server majflt / utime / stime (ticks) | SystemUI majflt | Kindle majflt / utime+stime | kswapd0 ticks | MemAvailable |
|---|---|---|---|---|---|---|---|
| 4499-4620 | +39 | +30 | +1 / +291 / +122 | +23 | +6 / +260 | n/a | 352-370 MB |
| 4990-5111 | +8 | +2 | +2 / +231 / +110 | +0 | +0 / +249 | **+23** (0.19% of a core) | 346-370 MB |

[M] At rest: under 0.4 major faults per second system-wide, no swap-out, kswapd idle.
system_server burns 3.4-4.1 s CPU per 120 s (2.8-3.4% of one core, on a governor sitting at
480 MHz 64% of the time [M] `time_in_state`); Kindle in the background burns about as much. That
is what verify+JIT costs at idle: not nothing, but not starving anything. Whether AOT would cut it
is untested; the original speed-odex era has no comparable idle sample.

### 2b. system_server main-thread responsiveness from the log (system buffer only)

| State | Window | Slow dispatch / min | median ms | p90 ms | max ms |
|---|---|---|---|---|---|
| A: verify odex on /data (+ a non-executable speed copy) | 23:06-23:15 (539 s) | 1.67 | 306 | 848 | 1,719 |
| B: **speed odex on /system, executable** | 23:15-23:37 (1,278 s) | **0.70** | 248 | 943 | 1,358 |
| C: verify (post-revert), first 4 min | 23:37-23:41 (234 s) | 3.85 | 152 | 530 | 20,117 (android.bg, the phone ANR dump) |

[M] from `Looper: Slow dispatch took` lines in `logcat-main-system.txt`. State B has the *lowest*
rate of slow system_server handler dispatches; A and C are post-restart windows inflated by
startup. Weak evidence (different workloads, no control), but it points away from "the speed odex
made the framework's own handlers slower". The recurring 100-185 ms
`NotificationManagerService$WorkerHandler m=2` dispatch appears in every state.

### 2c. App launch, boot, framework restart

[M] Kindle cold start 23:40:23 -> BookOpenActivity windows drawn 4,680 ms (`sysui_multi_action`
field 319 in `logcat-events.txt`); its own 190 MB process, WebView sandbox spawn and
`attachApplicationLocked` slow-operation lines (58-440 ms in system_server) are the visible
costs. Framework restart 23:37: system_server up by 23:37:54 (am_low_memory event), `Posting
BOOT_COMPLETED` 23:38:06.455, launcher shown 23:38:07.452: ~13 s from system_server start to
home. The 22:36 cold boot is in no surviving buffer (`/data/misc/bootstat` empty, events buffer
starts 23:37), so boot-to-home could not be measured tonight (experiment E1).

### 2d. What every framework start costs regardless of odex

[D] `com.android.phone` ANRs twice at every framework start since at least 09-22 00:11 (all 30
`system_app_anr` reports), main thread in `RIL.getRadioProxy -> IRadio.getService` (HwBinder
wait) from `PhoneGlobals.onCreate`, although `ro.radio.noril=true` and `pm list features` lists
no telephony feature [M]. After the two "bg anr" kills the third instance sits in a 1 s
`HidlServiceManagement: Trying again for android.hardware.radio@1.0::IRadio/slot1` loop forever:
1,651 log lines in 20 minutes [M]; 7.8 MB PSS; 3.2 s CPU in 1,246 s (0.26% of a core) [M]
`/proc/26783/stat`. Each ANR also triggers a full ANR trace collection (SIGQUIT to many processes
+ 20 s CPU sampling) inside the first two minutes of every boot.

## 3. How Android 11 picks and executes the framework odex (from source)

[S] `ZygoteInit.java` 623-680: `performSystemServerDexOpt` compiles each SYSTEMSERVERCLASSPATH
jar with `dalvik.vm.systemservercompilerfilter` (default `"verify"`; comment: *"the compilation
will happen on /data and system server cannot load executable code outside /system"*), calling
`installd.dexopt(..., packageName "*", dexFlags 0, ..., profileName null, ..., "server-dexopt")`.

[S] `art/runtime/oat_file_assistant.cc` 836-841 (`OatFileInfo::GetFile`): `executable =
load_executable_; if (executable && only_load_system_executable_) executable =
LocationIsOnSystem(filename_)`. `only_load_system_executable` comes from
`OatFileManager::only_use_system_oat_files_`, set for system_server via
`Runtime::SetOnlyUseSystemOatFiles` (runtime.cc 1803). **This is why the 02:12 speed compile in
/data/dalvik-cache was mapped `r--p`**, and why the same thing in SystemUI's process is `r-xp`.

[S] `oat_file_assistant.cc` `GetBestInfo()`: when the dex's parent directory is not writable
(everything on /system), *"If the oat location is usable take it"* (the /data/dalvik-cache copy)
before considering the odex next to the jar. **This is why system_server kept loading the
verify-only /data copy while a valid /system odex existed.**

[S] `build/soong/dexpreopt/dexpreopt.go` 406-427: system server jars are pre-opted with
**`speed`** unless `PRODUCT_SYSTEM_SERVER_COMPILER_FILTER` is set; `frameworks/base/services/
Android.bp` 52-55: `dex_preopt { app_image: true, profile: "art-profile" }`. That is the prebuilt
the GSI shipped and the device ran until 09-22: full speed + app image.

[S] `installd-dexopt.cpp` 1392-1432 `maybe_open_reference_profile`: *"If we are not profile
guided compilation, or we are compiling system server do not bother to open the profiles"*
(`pkgname[0] == '*'`); `profile_name == nullptr` -> *"This path is taken for system server
re-compilation launched from ZygoteInit"* -> no profile. 2205-2209: without a reference profile,
`generate_app_image = false`. **The zygote route can never produce a profile-guided odex or an
app image for services.jar in Android 11**: `speed-profile` via the property degenerates to
almost nothing, `speed` gives the full 25 MB with no `.art`.

## 4. Profile-guided compile of services.jar: how, and is it a net win? (Q2)

### 4a. Collecting a system-server profile on Android 11

[S] ZygoteInit 483-518: `shouldProfileSystemServer()` = `dalvik.vm.profilesystemserver`
(overridable by `persist.device_config.runtime_native_boot.profilesystemserver`), honoured only on
userdebug/eng (this build is `phh:userdebug`). `prepareSystemServerProfile` calls
`installd.prepareAppProfile("android", user 0, appId(SYSTEM_UID), "primary.prof", codePaths[0])`
and `VMRuntime.registerAppInfo(profilePath, codePaths)` with
`profilePath = /data/misc/profiles/cur/0/android/primary.prof` [M] (directory exists, empty).
ART then runs `ProfileSaver` for system_server (jit.cc 390-391).

[S] `runtime.cc` 3039-3041 `Runtime::GetOatFilesExecutable()`: false when `IsSystemServer() &&
SaveProfilingInfo` -> **while profiling, system_server executes no AOT code at all**, i.e.
collection happens in exactly today's verify+JIT regime.

[S] Nothing in the Android 11 framework consumes that profile automatically
(BackgroundDexOptService/PackageManagerService have no system-server path; the zygote route drops
profiles). It exists so engineers can `profman --dump-classes-and-methods` it into the build's
`services/art-profile`. A device-side profile-guided odex is therefore manual:

1. `setprop dalvik.vm.profilesystemserver true` + framework restart; use the device for a few
   hours; confirm `/data/misc/profiles/cur/0/android/primary.prof` is non-empty.
2. Optionally use/merge AOSP's own `services/art-profile` (android11-release: 46,238 lines;
   5,925 classes, 40,313 methods: 14,323 `HSP`, 10,239 `HP`, 15,751 `P`-only). Only `H` (hot)
   methods are compiled by `speed-profile`; `S`/`P` steer the app image and layout. Pixel-derived,
   but the framework code is the same build. Convert: `profman --create-profile-from=...
   --apk=services.jar --dex-location=/system/framework/services.jar --reference-profile-file=out.prof`.
3. Run `dex2oat32` by hand as root with installd's recorded arguments (the full command line is
   in the current odex's key-value store, `oatdump --header-only`: boot classpath,
   `--instruction-set=arm`, class loader context `PCL[com.android.location.provider.jar*...]`)
   plus `--compiler-filter=speed-profile --profile-file=<prof> --app-image-file=services.art
   --image-format=lz4`, output to a temp dir.
4. Install `services.odex/.vdex/.art` into `/system/framework/oat/arm/`, delete
   `/data/dalvik-cache/arm/system@framework@services.jar@classes.*`, restart the framework;
   verify the `r-xp` mapping of the /system odex and that the `.art` is mapped.

Every step is a write or a restart; none was performed.

### 4b. Expected size and fault behaviour

[I] The 25.7 MB speed odex compiles every method. A speed-profile odex compiles only the hot set
and lays hot methods out contiguously (dexlayout), so the resident set for the same work is
smaller than the 45% measured for SystemUI's speed odex. Reasonable expectation: an 8-12 MB odex
of which 3-5 MB stays resident, in exchange for the ~1.2 MB JIT cache and part of the JIT's CPU.
The dex itself (12.2 MB resident of the vdex today) stays resident either way.

[I] Net memory effect: file-backed working set grows by roughly 3-10 MB (speed-profile) or
10-15 MB (speed), out of a page cache holding 350 MB at rest and ~190 MB right after a framework
restart with Kindle + WebView resident. A few percent of the reclaimable budget: enough to matter
only at the edge, which is exactly where both incident windows sat (section 5). The gain side was
never measured on this device and the log proxy in 2b did not show the speed odex hurting.

### 4c. Worth doing?

Not on the current evidence. Verify+JIT is not measurably slow at rest (2a), the JIT footprint is
2 MB, and the only responsiveness complaint on record (Kindle ANRs) was a memory-pressure event
whose attribution to the odex is unproven (section 5). A profile-guided compile is a legitimate,
stock-shaped configuration (closer to what the GSI shipped than verify is), but it needs the A/B
protocol in section 6 to show a benefit, and its ceiling is modest. Rank below section 7's levers.

## 5. The incident's explanation: confirmed, refuted, or open? (Q3)

Claim: the 25 MB file-backed odex was evicted and re-faulted under memory pressure (eMMC), while
JIT code would have lived in anonymous memory and swapped to zram.

What holds up:

- [D] 23:29 ANR window (20.7 s): system_server **1,323 major faults** (64/s), kswapd0 10%, total
  CPU 7.6% with iowait 2.9%. ~2.4 core-seconds of iowait / 1,323 faults ~ 1.8 ms per major fault
  [I]: eMMC-speed re-reads, as claimed.
- [S] The JIT cache is `memfd` (shmem): swappable to zram, not re-read from eMMC.

What does not hold up:

- [M] **The device ran a 25.7 MB `speed` services.odex (plus `.art`) from 09-17 to 09-22** (the
  GSI's prebuilt). The 09-22 00:11-01:15 boot-time ANR reports [D] in that era show system_server
  major faults of 388/239/13/128/158/241/1/2/179/1/23 per 60 s window and kswapd 0-5.3%: no worse
  than the verify era (09-24 01:26-02:29: 223/173/7/11/211/13/0/200/0/221/4/216/4). "25 MB of
  file-backed code" alone did not thrash this device for five days.
- [D] In the 23:29 window **every** process was faulting: SystemUI 793 major, Kindle 409 major (at
  0.3% CPU), system_server 1,323. That is global page-cache reclaim, not one file. Kindle's own
  file-backed code (77 MB) is three times services.odex.
- Coordinator's post-revert measurement (23:38-23:40, verify state): system_server 901 major
  faults in 120 s (7.5/s), kswapd0 ~14% of a core, 56k pages swapped out. Same signature as the
  incident (kswapd 9-11%), with the odex gone. My samples 15 and 25 minutes later: kswapd 0.19%,
  ~0 faults. The incident windows were 7 and 14 minutes after the 23:15 restart, during active
  Kindle use with a fresh WebView sandbox. **The revert is not a clean test**: what changed at
  23:37 was also "everything restarted cold again".
- [M] The verify state is not "code in anonymous memory": the interpreter reads bytecode from the
  15 MB vdex, file-backed, 12.2 MB resident, evicted and re-faulted from eMMC exactly like an odex
  (system_server `.dex mmap` 13.1 MB PSS, all private clean). The difference between the two
  states is the size of the file-backed working set, not its kind.
- [D] Kindle's 23:29 main thread was inside `fork()` from `libwebviewchromium.so`, blocked on the
  scudo allocator lock in `__bionic_atfork_run_prepare`, with the Signal Catcher blocked on the
  same lock (why the first trace attempt at 23:29:05 produced no Java stacks). A process forking
  while another thread is mid-allocation and page-faulting is a plausible ANR under any thrash;
  nothing ties it to services.odex.

Verdict: **open, leaning "coincidence with a post-restart pressure transient"**. The odex
plausibly added ~10-15 MB to the file-backed working set at the worst moment, but the observed
thrash is reproduced by a framework restart alone, and the same odex size ran for days without
incident. The missing piece is the app image (`.art`), which the prebuilt had and tonight's
compile could not have (inference from installd's comment *"there is no speedup from loading it
in that case"*, not a measurement).

Cheaper confirmation than repeating the slowdown blind (both need the odex loaded, so both are a
20-minute reversible experiment, not read-only):

- **E2a: attribute the faults.** `simpleperf` is present (`/system/bin/simpleperf`; `simpleperf
  list` shows `major-faults`; `perf_event_paranoid=3` but root is fine). `simpleperf record -e
  major-faults -p <system_server> --duration 60 -o /data/local/tmp/mf.data`, then `simpleperf
  report --sort dso` gives major faults per mapped file. If services.odex is <20% of
  system_server's faults in the incident state, the claim is refuted outright.
- **E2b: watch residency.** Sample `Rss` of the `r-xp services.odex` mapping in
  `/proc/<pid>/smaps` every 5 s alongside `majflt`: eviction-and-refault shows as an Rss sawtooth
  synchronous with majflt increments. No tools needed.
- Both must run at matched times after a restart (e.g. minutes 7-14) with the same app set, in
  both states, or they prove nothing.

## 6. Proposed experiments (none run; all need writes or restarts; all reversible)

| # | Experiment | What it answers | Risk |
|---|---|---|---|
| E1 | Reboot twice, capture `logcat -b events` `boot_progress_*` and `Displayed` for the launcher; repeat after any change | boot-to-home baseline (unmeasured today) | low; two reboots |
| E2 | Re-install tonight's speed odex (script step 2 only, no compile) for 20 min with E2a+E2b instrumentation, Kindle open on a book; same 20 min protocol after reverting. Compare system_server majflt/s, kswapd ticks, MemAvailable, odex Rss, ANRs | confirms or refutes section 5 | medium: reproduces the bad state deliberately for 20 min; two framework restarts; phone ANRs at each |
| E3 | Build speed-profile + app image per 4a (AOSP profile first; own profile later), install on /system, remove /data copy; run the E2 protocol plus 2a's idle sample and 2b's slow-dispatch rate over 24 h | is profile-guided AOT a net win | medium: /system write, framework restart; rollback = delete three files + restart |
| E4 | `echo 100 > /proc/sys/vm/swappiness` (kernel 4.9 max 100) for a day; compare pgmajfault/s vs pswpout/s in post-restart windows and the 2a idle sample | whether reclaim can be pushed toward zram (RAM-speed, 3.4:1) instead of evicting file pages (eMMC) | low; single sysctl, revert instantly |
| E5 | Stop the phone process's RIL creation (find why `PhoneGlobals` builds a RIL with `ro.radio.noril=true` and no telephony feature; phh's Treble app has telephony toggles; `pm disable-user` is not enough for a persistent app) | removes two ANR dumps per boot and a 1 Hz log loop | medium: telephony code path in a GSI; check ims.rcsservice/ons afterwards |
| E6 | Interactive governor: `above_hispeed_delay`/`target_loads`/`boostpulse` on touch (the vendor power HAL's hints do not reach A11); measure touch-to-frame with `dumpsys gfxinfo` and E1 | input latency at 480 MHz | low-medium; sysfs only, revert instantly |

## 7. Levers ranked (benefit vs risk)

1. **Swappiness 60 -> 100 (E4).** 688 MB of lz4 zram at 3.4:1 [M]; pressure events show
   file-page eviction with eMMC re-reads (~1.8 ms each [I]) while anonymous memory sits at 500 MB
   [M] `AnonPages`. Making reclaim prefer anon-to-zram is the standard tuning for this
   configuration and targets the observed failure mode (all processes faulting on file pages).
   Risk: low, one sysctl, reversible; `page-cluster=0` already set. Measure with vmstat deltas.
2. **Phone-process IRadio loop (E5).** Present at every boot since 09-22 at least; two ANR dumps
   in the first two minutes of every boot (each dumps stacks of all processes and samples CPU for
   20 s), then a persistent 1 Hz getService retry with 1.4 log lines/s. Steady-state cost is
   small (0.26% of a core, 7.8 MB), but the boot-time cost lands exactly in the window where the
   device thrashes. Risk: medium.
3. **Framework AOT with app image, speed-profile (E3), only after E2.** Stock-shaped, modest
   ceiling, real cost in file-backed working set. Never again as `speed` without `.art`.
4. **Leave SystemUI at `speed`.** [M] 5.1 MB resident of 11.5 MB code, 23 major faults per 120 s
   at rest, executable. It faulted in the 23:29 window like everyone else (793). If E2a shows its
   odex dominating its faults, `speed-profile` via bg-dexopt is the fallback; otherwise no action.
5. **Governor tunables (E6).** `hispeed_freq=1.8 GHz`, `go_hispeed_load=99`, `target_loads=90`:
   conservative; 64% of time at 480 MHz. Latency lever, not a memory one.
6. **Not recommended:** `dalvik.vm.jitthreshold` changes (moves JIT CPU earlier in boot, the
   worst moment); readahead changes (128 kB is right for 4 kB-fault-driven code paging); lmkd
   minfree changes (the 180 MB cached-app kill level is what keeps Kindle+WebView from pushing
   deeper); removing `/system/framework/oat/arm/services.{odex,vdex}` for performance reasons
   (unused files cost nothing; remove for hygiene at the next /system remount).

## 8. "Why wouldn't a compile help? Would it fill the RAM and starve it?"

AOT code does not consume anonymous RAM: an odex is mapped read-only from the file, its pages are
clean and the kernel drops them at will. What it does is enlarge the *file-backed working set*:
SystemUI's speed odex keeps 5.1 MB of its 11.5 MB code resident [M]; a services odex would keep
roughly 10 MB (speed) or 3-5 MB (speed-profile) resident on top of the 12 MB of dex that stays
resident in either state [M]. With 350 MB reclaimable at rest [M] that is invisible; after a
framework restart with Kindle + WebView resident there is ~190 MB [M], and every extra clean page
is one more eMMC re-read when the kernel needs room. The JIT side costs ~2 MB of swappable memory
plus ~3% of one core in system_server at idle [M]. So a compile is unlikely to make the device
much faster *or* much slower at steady state; it shifts a few MB from "recomputed" to "re-read".
Tonight's slowdown came with a cold restart plus Kindle plus a fresh WebView, and the same thrash
signature appeared after the revert too, so "the compile starved it" is plausible but not shown;
five days on the GSI's own 25 MB speed odex say it is at least not sufficient on its own.

## 9. Corrections to the incident write-up

- "system_server prefers the /data copy" is `OatFileAssistant::GetBestInfo` (a usable
  dalvik-cache oat wins for unwritable /system dex parents); "maps a /data copy non-executable"
  is `only_load_system_executable_` + `LocationIsOnSystem` (section 3). Both by design.
- "AOSP's own choice for low-RAM devices" is not right: the build compiles system server jars with
  `speed` regardless of RAM (`dexpreopt.go` 406-413); `verify` in the zygote route is because
  /data code cannot be executed by system_server, not a memory decision.
- "speed-profile without a profile compiles nothing extra" is right and stronger: the zygote route
  *cannot* pass a profile, and installd suppresses the app image without one.
- The prebuilt the standby trial displaced was already a full `speed` compile with an app image;
  the trial moved the device from speed+.art to verify, and tonight's install to speed without .art.

## Appendix: commands behind the numbers

- Props: `adb shell "getprop | grep -E 'dalvik\.vm|ro\.config\.low_ram|pm\.dexopt|ro\.lmk'"`
- Filters: `su -c '/apex/com.android.art/bin/oatdump --oat-file=<f> --header-only'` (the original
  prebuilt segfaults oatdump; its header was read with `dd bs=4096 count=8 | base64` and the
  key-value store parsed on the host, `orig-odex-head.bin`).
- Mappings/residency: `grep services /proc/$(pidof system_server)/maps`; awk over
  `/proc/<pid>/smaps` for `SystemUI.apk@classes.dex`, `services.jar@classes`, `jit-cache`.
- Quiet samples: `/proc/vmstat` (`pgmajfault pswpin pswpout pgsteal_kswapd pgscan_direct`),
  `/proc/<pid>/stat` fields 10 12 14 15 for system_server, SystemUI, Kindle, kswapd0 (pid 585),
  `/proc/meminfo`, `/sys/block/zram0/mm_stat`, 120 s apart, nothing else running.
- Memory: `dumpsys meminfo`, `dumpsys meminfo <pid>` (files `meminfo-*.txt`).
- Reports: `/data/system/dropbox/*anr*`, `*lowmem*` pulled via `tar | base64`; table from the
  `CPU usage`, `kswapd0`, `system_server`, `com.android.systemui`, `TOTAL` lines.
- Logs: `logcat -b main,system,crash -d -v threadtime` and `-b events`, redacted for MAC/IP; era
  statistics from the system buffer only (the main buffer begins 23:41).
- Governor: `/sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state`,
  `/sys/devices/system/cpu/cpufreq/interactive/*`.
- Phone loop: `/proc/26783/stat`, `grep -c IRadio logcat-main-system.txt`, `pm list features`.
