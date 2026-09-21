# Incidents 2026-09-17/18 and 2026-09-19: device hot, screen frozen, power button dead

Reported by the operator: "device seems hot to touch even after being unplugged", then
"it seems stuck, can't open it back with power button".  Captured live over ADB before any
reboot (`a11/gate17/build/hang/20260918-001051/`, project side).  Failure mode identified; the underlying code defect is not yet isolated, and there is
no verified fix.  This is the first hang in ~2 months of daily use of this port.

## What was actually wrong: a SurfaceFlinger livelock

The device was **not** off and **not** crashed.  ADB was alive, `sys.boot_completed=1`,
`mWakefulness=Awake`, uptime 2 h 51 m.  SurfaceFlinger had stopped compositing:

```
top:        surfaceflinger 96.8% CPU, 24:14 CPU time     (400%cpu ... 284%idle)
tid 2272 "app"  state R, wchan=0, 149672 ticks, +109 ticks/s  <- one core, continuously
dumpsys SurfaceFlinger  -> *** DUMP TIMEOUT (10000ms) EXPIRED ***
```

`debuggerd -b` shows every other SF thread blocked on the **same EventThread mutex**, held
by the spinning `app` thread:

```
"surfaceflinger" 2235  EventThread::getEventThreadConnectionCount() -> std::mutex::lock()
                        <- SurfaceFlinger::onMessageRefresh()   (main compose loop)
"Binder:2235_1"  2246  EventThread::registerDisplayEventConnection() -> mutex::lock()
"Binder:2235_2"  2247  EventThread::requestNextVsync() -> mutex::lock()
"app"            2272  pc 0x1505e8 libsurfaceflinger.so, unwind broken  <- holds the mutex
```
The app-facing `EventThread` (vsync dispatch to apps) entered a loop while holding its
mutex.  Everything downstream starves: no composition, so the panel keeps its last image
(E-Ink holds an image with no power, which is why it looked "off but stuck"), and key
events change nothing visible -- hence "the power button does nothing".

## Why it got hot, and why unplugging did not help
```
mHoldingDisplaySuspendBlocker=true      framework still thinks the display is ON
suspend_stats: success 149, fail 54     it HAD been suspending normally before this
cpu0..3  governor=performance @1.8 GHz  vendor power HAL scheme (see below)
thermal: cpu 55, gpu 50, battery 33 C   warm, not a thermal emergency
```
One core pegged at max clock, plus a held display suspend blocker, means the SoC can never
enter suspend.  That runs until the battery does, on or off the charger.  Battery stayed at
33 C, so this was a comfort/battery problem, not a safety one -- but a device that cannot
sleep will flatten itself overnight.

## Ruled out
* **Not the new front light.**  `/proc/lm3630a/*` all read 0 during the hang: the light was
  correctly off.  The lights HAL process was idle in `binder_thread_read`, 1 thread.
* **Not the composer shim directly.**  `android.hardware.graphics.composer@2.1-service`
  (with `libhwcflip.so` loaded) was idle in `binder_thread_read`.  It cannot be fully
  exonerated -- it changes per-frame timing on the path EventThread schedules against --
  but nothing in it was running or blocked.
* **Not a background CPU hog.**  Re-measured on a clean boot, screen off: **368% idle of
  400%**.  The load average of ~2.8 that this looked like at first is two permanently
  uninterruptible kernel threads, `[eink pixel proc]` and `[usb-hardware-sc]`, which Linux
  counts in loadavg without them using CPU.  A healthy boot is genuinely idle.
* **Not the CPU governor.**  `performance` on all four cores is the *vendor* design:
  `power.virgo.so` (running, `android.hardware.power@1.0-service`) writes
  `scaling_governor` and modulates `scaling_max_freq` (1200000 at idle, 1800000 under the
  hint) instead of using an on-demand governor.  Measured idle at both `performance` and
  `interactive`, screen off, 50 s each: identical, 1200000 throughout, temp 43-45.  No
  benefit, so the governor was left at the vendor default.

## Leading hypothesis for the trigger (UNVERIFIED)
The spin started roughly 2.5 h into a boot, and the device had just been unplugged for the
§3.8 battery measurement.  Unplugging drives a display-policy change and, with
`doze_always_on=1`, a doze/AOD transition -- and AOD on this port is our own RRO overlay
work (`overlays/aod`, `config_dozeAlwaysOnDisplayAvailable`, the power-decouple configs).
EventThread is directly involved in those vsync transitions, and this panel has no real
hardware vsync.  That makes an AOD/doze transition on battery the first thing to suspect.
It is a hypothesis, not a finding: one occurrence, no reproduction.

## State now
Rebooted; healthy (SF 2 s CPU in 62 s uptime, `dumpsys SurfaceFlinger` answers, screen and
touch normal).  Nothing was changed to "fix" this, because nothing is diagnosed well enough
to fix.  Governor restored to `performance`; sampler scratch files removed from `/data/local`.

## Next steps, in order
1. **Watch for recurrence.**  If it happens again, capture first with
   `a11/gate17/build/hang/capture.sh` (waits for the device, dumps thermal/suspend/wakeup/
   top/thread-states/backtrace, reboots nothing), then reboot.
2. **Cheap discriminator for the AOD hypothesis:** run unplugged with
   `settings put secure doze_always_on 0` for a few days.  A difference in repeatable failure rates could implicate AOD/doze; absence of
   another rare hang by itself would not establish causation.
3. Only if it recurs and 2 does not implicate AOD: A/B the composer shim.
4. Unrelated but found in the same logs: the RIL retries forever,
   `RIL: fd = -1, sleep 2s wait device, total wait time: 3050s` -- a 0.5 Hz wakeup for a
   radio this device does not have.  Disabling it belongs with the §3.5 telephony work.


## Follow-up investigation, 2026-09-18

The installed SurfaceFlinger library matches the incident copy (SHA-256
`4bf68ec57473f69f22f6a307566efa354edccff12a57940474381996c874bf71`).
ELF relocation analysis maps the sampled PC `0x1505e8` to the PLT call stub for
`android::RefBase::decStrong`, at GOT slot `0x163930`. Multiple places in the app
EventThread call that stub. The single broken backtrace does not identify the
failing loop or justify patching a particular instruction. Ghidra and Thumb
instruction review have not yet isolated a code defect.

A connected stress run passed 23 wake/sleep cycles, then another LLM's installer
work rebooted the device. The operator confirmed that concurrent work; this was
an interrupted test, not a reproduced hang. The subsequent connected observation
lasted roughly eight hours without a recurrence, but had zero kernel suspends.

An unplugged test then completed **12 sleep/wake cycles and 23 successful kernel
suspends** in 17 min 34 sec. SurfaceFlinger retained its PID and responded after
every cycle. There were seven additional freeze-stage EBUSY aborts, no failed
resumes, and battery temperature remained 29 C. This does not prove a fix: the
original livelock did not recur, and no compositor patch has been applied.

### Capture on recurrence

`diagnostics/sf-hang/capture-device.sh OUTPUT_DIRECTORY` collects real mappings,
thread state, five seconds of CPU sampling, and a full debuggerd tombstone with
registers and stack data. The old backtrace-only sample lacked these details.
The capture was validated on a healthy device. It does not reboot or restart
services and avoids the old capture script's forced I2C reads.

`diagnostics/sf-hang/watch-device.sh` is temporary diagnostic instrumentation.
Stage the capture as `/data/local/tmp/sf-capture-device.sh` and run the watcher as
root, detached with nohup if monitoring while unplugged. It samples the app
EventThread every 15 seconds and captures after three consecutive intervals at
80% or more of one core. It uses no wake alarm or Android wakelock, expires after
72 hours, and ends at reboot. It is not installed as a boot service. Two collectors
are serialized with a directory lock; a killed collector can leave that lock and
must be inspected before removing it. A capture exit status other than zero means
collection did not finish successfully.

Raw output stays on the device under `/data/local/tmp/sf-hang-watch-v2` and should
be kept private: logs and tombstones can contain application data. If the screen
freezes again, connect USB and collect the output before rebooting. This watcher
preserves evidence; it does not repair or recover from the hang. No battery-life
claim is made for the instrumentation overhead.


---

# Second occurrence, 2026-09-19 (overnight, same signature)

Reported as "the device is stuck, it was left off the cable overnight". USB enumerated
nothing at all for 3+ minutes -- no ADB, not even a charging device -- so the SoC was not
running; a 20 s power hold brought back the Moaan logo and a normal boot. The panel had been
showing the standby letterpress image the whole time, which is E Ink holding its last frame,
not a sign of life.

## Same failure, now with a timeline

The boot before the hang started at 01:47; the next entry in the boot log is 11:21, the
owner's 20-second power hold. Nothing rebooted in between, so every report below belongs to
one continuous boot. Each dropbox report carries a CPU-usage window with an awake fraction in
its header.

```
02:40-02:51   1% awake    SF  1% of awake time     inconclusive
08:44-08:48   1% awake    SF 73% of awake time     inconclusive
10:01-10:02   (awake)     SF 99%                   spinning -- established
10:03                                              system_server watchdog
```

**Three corrections, in successive rounds of review. The onset is not dated at all.**

1. The first revision read the 08:48 sample as "already spinning": wrong. That window is
   4 min 44 s long and 1% awake, i.e. roughly 5.5 s of running time, so 73% of it is about 4 s
   of CPU, not five minutes of a pegged core.
2. The second over-tightened the other way, claiming the device was "still suspending at
   08:48:39" and had "slept normally all night". The awake fraction describes the **whole**
   window, so a spin beginning in its final seconds fits it -- and there is **no sample at all
   between 03:06 and 08:44**, nearly six unobserved hours.
3. The third still rested on "a held core prevents suspend". That premise is **false**: the
   suspend freezer can freeze a busy userspace thread, so high CPU on its own does not make
   suspend impossible. Showing that a machine could not suspend needs suspend events, wake
   sources and their timing -- which incident 1 has (the held display suspend blocker quoted
   above) and incident 2 does not.

So the awake percentages date nothing. What survives: **near-full-core usage is established for
10:01:53-10:02:04**, and the watchdog fired at 10:03:38. Everything earlier is unobserved or
inconclusive, including whether the night was healthy. The battery -- the device was off the
charger -- ran down some time after the last report at 10:03.

The watchdog report gives the blocking chain the first incident could only infer:

```
main            Notifier -> AMS.onWakefulnessChanged   waiting on AMS lock  (thread 11)
android.fg      Watchdog HandlerChecker                waiting on AMS lock  (thread 11)
Binder:2298_2   AMS.appDiedLocked -> ProcessRecord.makeInactive
                holds AMS lock, waiting on WindowManagerGlobalLock          (thread 114)
Binder:2298_D   WindowState.removeIfPossible -> ... -> SurfaceAnimator.createAnimationLeash
                holds WindowManagerGlobalLock, blocked in binder ioctl into
                SurfaceComposerClient::createSurface                        <- never returns
```

Read the chain from the bottom: an application process died, and the cleanup of its windows
transferred the input-method control target, which starts an animation, which builds a leash,
which asks SurfaceFlinger for a surface. **This is window teardown involving IME controls, not
keyguard creation** -- worth stating plainly, because it is not evidence for or against the
framework patch below. It is simply the caller that happened to be holding both locks when SF
stopped answering.

So: SF spins on one core, a `createSurface` binder call into it never returns, the caller
holds the window-manager lock, its caller holds the AMS lock, and the whole system wedges
behind those two locks. One core pegged means no suspend, which is what flattens the battery
overnight.

**What this does NOT establish (correction after review).** All of the above is about the
*callers*. There is no stack for SurfaceFlinger's own spinning thread and no CPU sample from
inside SF for this incident, because nothing was capturing at the time. Whether it is the same
internal failure as incident 1 -- the app `EventThread` -- is an **inference from the external
symptoms, not a finding**. An earlier revision of this document called it "consistent with
incident 1 in every respect"; that was an overstatement and is withdrawn.

Incident 1's own evidence is thinner than it first appeared, too. Its sampled PC `0x1505e8`
lands in the ARM PLT, not in a loop body: the slot resolves to `android::RefBase::decStrong`,
which the EventThread lambda calls from several places (promotion cleanup, consumer-vector
cleanup, destruction). A single sampled PC there cannot distinguish which caller is looping,
and the old capture has no usable caller stack for the hot thread, so it does not directly
prove mutex ownership either. See `a11/sf-hang-fix/INVESTIGATION.md` on the project side.

## What is different, and what that does and does not tell us

Incident 1 ran with AOD on and was blamed on doze/AOD transitions. AOD has been off since
2026-09-19, so that trigger is ruled out for this one. What both share is a **display-state
transition driving EventThread/surface work on a panel with no hardware vsync**.

Honest caveat: this hang followed, by ~7 hours, the framework patch that makes every
screen-off show the keyguard first (§3.17). That patch adds keyguard window and surface
creation to a transition that previously created nothing, so it plausibly changes timing and
exposure around display transitions. It is **not** implicated by the stack above, which is
window-death/IME cleanup and would have run with or without it. It cannot be blamed on the
evidence available -- the identical hang predates it by two days -- but it cannot be cleared either,
and it plausibly increases exposure. Two data points in two months is not a rate that
distinguishes the two hypotheses.

Note the asymmetry in what each observation buys: the patch being absent during incident 1
shows it is **not necessary** for the failure, not that it is harmless. AOD being off during
incident 2 likewise only removes AOD as a *necessary* condition; it does not clear
display-transition bugs generally. **Decision: the patch is rolled back for everyday use**
(stock `services.jar` and its odex restored, verified 2026-09-19), while the corrected
instrumentation stays.

It stays rolled back for a second, independent reason found in review: the 800 ms callback it
posts goes to sleep unconditionally and never rechecks whether the user touched the screen in
the meantime, so a touch landing inside that window is ignored and the device sleeps anyway.
That is a defect in the patch on its own terms, regardless of the SurfaceFlinger question, and
must be fixed (recheck `mLastUserActivityTime`, or cancel the callback on user activity) before
it is reinstated.

## The instrumentation (`tools/sf-watch.sh` + `tools/sf-capture.sh`)

Both hangs were found hours late with the evidence already gone, which is why neither has a
stack for the spinning thread. `tools/sf-watch.sh` samples **every** SF thread every 15 s and
triggers when one exceeds **80% of a core for three consecutive intervals**; `sf-capture.sh`
(the project's existing capture script) then collects, in this order: per-thread `stat`/`wchan`,
memory and reclaim state, `/proc/<pid>/maps`, **5 s of `simpleperf cpu-clock:u` before**
`debuggerd` pauses anything, then the bounded `dumpsys` calls, then a full tombstone with
registers. The ordering matters: a hot loop yields precise PCs to the sampler, whereas a single
backtrace sample is what left incident 1 unresolved; and `dumpsys` talks to system_server, which
during this failure is itself blocked, so it comes last and every call has a timeout.

Each incident gets its own directory under `/data/local/sf-hang/`, with a 30-minute cooldown
and the six most recent kept. No wakelock and no wake alarm, so it cannot keep the device
awake; while suspended it simply does not tick. Started from `configs/a11-boot-fixups.sh`.

Two rounds of review found nine defects between them. They are listed because most are easy
to repeat, and because every one would have cost the next occurrence.

First round, on the original detector:

* **The threshold was nonsense.** 20 ticks per 60 s at `HZ=100` is 0.33% of a core, not 20%.
  Ordinary activity would have tripped it. (Its own log line printed "0% of a core" and that
  went unnoticed.)
* **It called `dumpsys power` twice, unbounded, before capturing** -- on the one service that
  is wedged during this failure, which would have stalled the capture indefinitely.
* **It captured at most once, ever**, gated on a file that a healthy sample or an earlier boot
  could have created.
* **It assumed every interval was exactly 60 s and never reset on a pid change.**

And one that made it useless outright: in this shell `$14` expands as `$1` followed by `4`, so
the sampler read the pid, the delta was always zero, and it could never have fired. Use `${14}`.

Second round, on the replacement:

* **A 30-minute blind spot at every boot.** The cooldown was compared against a `last_cap` of
  zero, so no capture was possible until uptime passed 1800 s. The cooldown now applies only
  after a capture has actually happened.
* **Per-thread counters were not actually dropped on a pid change**, despite the comment saying
  so, leaving `T_<tid>` entries that a reused thread id in the new process could be diffed
  against. They are now unset explicitly, exited threads are forgotten each pass, and each
  cached counter carries the thread's `starttime`, so a reused id cannot match a stale entry.
* **The tombstone was queued behind two `dumpsys` calls**, up to 30 s of delay on the one
  artefact that carries registers, during a failure in which `dumpsys` is exactly what hangs.
  `debuggerd` now runs immediately after the profile; every `dumpsys` runs after it.
* **Command failures could look like success.** The script's exit status was whichever command
  ran last, so a lost profile or a failed tombstone would have been invisible. Each command's
  status is now recorded in `exit-status.txt`, and the script exits non-zero if any failed.

Verified on the device 2026-09-19: simpleperf on a deliberately spinning process gave 603
samples, 0 lost, symbolized; the watcher measured 94-103% of a core for that thread, triggered
after the configured intervals, ran the capture and kept watching; a capture fired at 603 s
uptime, which the blind spot would have blocked; a simulated pid change logged "counters
dropped", produced no bogus trigger from stale state and read the new process correctly; and a
healthy baseline capture wrote `state -> memory -> maps -> perf -> tombstone -> dumpsys ->
logcat -> dmesg` in that order, with registers for all 19 SF threads and `failed_commands=0`.
That baseline proves the output format and nothing else: with SF idle simpleperf records zero
samples, so what spins during the failure remains unanswered until a live capture exists.


---

# If it happens again: what to collect, before rebooting

The capture runs by itself. The one thing that needs a human is **getting it off the device
before the reboot**, and not rebooting first. If the screen is frozen and the power button
appears dead, **try ADB before the 20-second power hold**. In incident 1 ADB was alive long
after the UI was gone, which is how that evidence exists at all. For incident 2 nothing
establishes whether ADB ever responded: by the time the device was looked at, USB enumerated
nothing, and no one tried earlier. So this is worth attempting, not something to count on.

```sh
adb shell su -c 'ls -t /data/local/sf-hang'            # newest capture-<timestamp> first
adb shell su -c 'tar czf /data/local/tmp/sf-hang.tgz -C /data/local sf-hang'
adb shell su -c 'base64 /data/local/tmp/sf-hang.tgz' | tr -d '\r' | base64 -d > sf-hang.tgz
```

The base64 hop is not decoration: piping binary through `adb shell` corrupts it (a `live.dtb`
earlier in this project came back with 75 stray CR bytes). Take the **whole** directory,
`sf-watch.log` included -- it names the thread that tripped the threshold and when the
**threshold** was met, which the capture itself does not record.

Be precise about what that timestamp is: it is the **detection time**, not the onset. The
watcher fires only after one thread has held 80% of a core across three consecutive samples,
so it is necessarily later than the spin began, and only exists for a spin that is sustained --
a burst that clears before the third sample is never logged at all.

The lag is **not bounded by 3 x 15 s**. Sampling is not aligned to the onset, each pass takes
time on top of the sleep, the scheduler can delay a low-priority shell loop on a busy machine,
and suspend stops the loop entirely, so a spin beginning just before a suspend is not seen
until the device resumes. Treat the logged time as "no later than this", with no useful lower
bound.

### Decoding a hit on the same instruction

Offline analysis of incident 1's binary (`docs/sf-eventthread/`, reproducible against SHA-256
`4bf68ec5...`, build ID `5ffeeeeef796a40caaf474d3b30af5f2`) turns the previously useless
sampled PC into a discriminator. `0x1505e8` is the last instruction of a PLT entry whose GOT
slot resolves to `android::RefBase::decStrong`; the stub itself contains no loop. Four direct
calls in the EventThread thread-proxy reach it, and because an intact direct call leaves LR
untouched at the stub, a register capture at that PC distinguishes them:

| call | LR at the stub | interpreted path |
| --- | --- | --- |
| `0xa04e0` | `0xa04e5` | old consumer-vector storage cleanup during reallocation |
| `0xa050c` | `0xa0511` | temporary strong-reference release while scanning connections |
| `0xa0674` | `0xa0679` | consumer-vector clear after dispatch |
| `0xa07be` | `0xa07c3` | consumer-vector destruction on thread exit |

Addresses and LR values are direct observations of the binary; the path names are
interpretations of the surrounding control flow, cross-checked against a comparable Android 11
EventThread source. These are the four calls **in that function**, not every caller in
SurfaceFlinger.

To use it: compute the load bias from the **same incident's** mappings -- never from an
arbitrary mapping start, and never from the healthy baseline -- normalise the runtime LR by
that bias, and account for the Thumb bit. Incident 1's own backtrace cannot be decoded this
way; it has neither registers nor mappings. If the hot thread is caught somewhere else
entirely, analyse that instruction and its loop instead of forcing this explanation onto it.
A tombstone is a later snapshot than the profile, so the two disagreeing can mean the state
moved, not that the data is bad.

Two boundaries from the same analysis: the compiled dispatch path advances past the `-EAGAIN`
branch rather than retrying the same send in a tight loop, and the function contains
condition-variable waits. Both weaken simple explanations without proving any path is reached.

The four files that decide the case:

| file | why |
|---|---|
| `perf.data` | 5 s of PCs from inside the spinning thread. This is the artefact both incidents lacked. |
| `sf-tombstone.txt` | registers and stack for every thread, so the loop has a caller, not just a PLT stub |
| `sf-maps.txt` | turns those PCs into symbols offline |
| `exit-status.txt` | says which of the above actually succeeded |

**Keep the directory even when the script exits 4.** Exit 4 means something decisive is
missing; it does not mean the rest is worthless. Timeouts on `dumpsys` are recorded as soft
failures and deliberately do not fail the capture -- during this failure `dumpsys` hangs
*because* system_server is wedged, so a capture full of dumpsys timeouts that still holds a
profile and a tombstone is exactly the capture worth having.

A non-empty `perf.data` is not proof of usable samples, and a non-empty tombstone is not proof
of a resolved stack. Those are judged on the contents, once there are contents to judge.


---

# Third occurrence, 2026-09-20 — caught live, diagnosed, and recovered without a reboot

The instrumentation worked. The watcher tripped at 20:59:01, captured with every collector
succeeding, and the device was still hung three hours later with ADB alive, so the failure was
examined **while it was happening** rather than reconstructed afterwards.

## What is established

* **The spinning thread is the app `EventThread`** (`tid 2275`, `comm=app`). The `sf` EventThread
  is parked correctly in its untimed wait. One loop, not general compositor failure.
* **The trigger is a screen power-mode change.** `Setting power mode 2 on display 0` is logged at
  20:58:09, and the watcher needs 45 s of sustained spin to fire at 20:59:01.
* **Mutex ownership is proven, not inferred** -- the thing neither earlier incident could show.
  The main SurfaceFlinger thread sits in `std::mutex::lock()` at the first instruction of
  `EventThread::onScreenAcquired()`, reached from `Scheduler::onScreenAcquired` and
  `SurfaceFlinger::setPowerModeInternal`. The EventThread's mutex word reads locked-with-waiters.
  The compositor's main loop is therefore stopped: nothing composites, the panel holds its last
  frame, and the power button appears dead because nothing can draw the result.
* **The loop is the connection scan.** The link register is identical in two captures three hours
  apart and normalises (load base `0xb3817000`) to `0xa0511`, the return address for the call at
  `0xa050c` -- the temporary strong-reference release while scanning connections, the second row
  of the call-site table above. Instruction-level profiling puts every hot address inside
  `0xa031c..0xa0510`, with the scan's own back-edge the single hottest instruction.
* **It is not a reference-counting defect and not a connection leak.** The profile is
  `attemptIncStrong` 27%, `decStrong` 21%, `decWeak` 17% with the loop body at 30%: those are
  callees of the scan, which is why incident 1's single sampled PC landed on the `decStrong` PLT
  stub and looked like the culprit. The connection vector holds 16 entries and is unchanged over
  three hours.
* **It does not prevent suspend.** 822 s of CPU across 3.2 h of wall clock, about 7% duty: the
  freezer stops the spinner on every suspend. 314 successful suspends. Unlike incident 2 this
  does not flatten the battery; it simply never draws again.
* **Zero kernel time.** 3.05 s of user time in 3 s with `stime` frozen, so the thread makes no
  syscalls at all.

Ghidra 12.1.3 headless (JDK 21) decompiled the function cleanly, giving the field offsets used
above and the exact predicate: the wait is skipped by one condition, an event being pending.
There are three exits -- untimed when idle, 16 ms in synthetic-vsync mode, 1 s with hardware vsync.

## What is NOT established, stated plainly

The live object reads `mState = Idle` and `mPendingEvents.size() = 0`, sampled 60 times. With
those values the decompiled code must call the untimed wait, which is a syscall, and no syscalls
occur. Meanwhile samples land on the event-type comparisons at `0xa036a` and `0xa0376`, which are
only reachable when an event **is** present, at a rate comparable to the no-event path. Both
readings cannot be right. The most likely explanation is that the queue fills and drains inside a
single pass, faster than memory sampling can see, but that is a hypothesis and the pushing path
is not identified. Settling it needs a watchpoint or single-stepping, not sampling.

## The fix that is actually available: recover instead of reboot

Killing SurfaceFlinger cleared it. MEASURED 2026-09-21 on the live three-hour hang: the
compositor restarted, `dumpsys` answered again, the keyguard rendered with its wallpaper, the
device was usable, and the watcher picked up the new pid by itself. **No reboot, no power hold.**

`tools/sf-watch.sh` now does this automatically: `RECOVER=1` restarts SurfaceFlinger **after** the
capture completes, capped at `MAX_RECOVER=3` per boot so a systematically broken state cannot
restart-loop. Verified against a dummy spinning process -- detect, capture, then kill, in that
order. Set `RECOVER=0` to keep a hung process for live debugging.

The trade is honest: this is a soft framework restart, so foreground app state is lost. The
alternative, observed twice, is a device that never draws again and needs a 20-second power hold.
It is a mitigation, not a cure -- the compositor bug is untouched.


---

# Why the livelock's regime existed at all, and the fix that removes it (2026-09-21)

Everything above happened inside one condition: the app `EventThread` running permanently in
**synthetic-vsync mode**, ticking on its own hardcoded 16 ms timer, with SurfaceFlinger's vsync
reactor stuck "transitioning" to the panel's period and never getting there. That condition was
not a bug in the compositor; it was the seam of this port.

## Measured chain

1. **The kernel never emits vsync on the E Ink path.** The vendor composer does everything right on
   its side: it issues `DISP_VSYNC_EVENT_EN` on `/dev/disp` (request `0xb`, returns 0) and has a
   uevent thread parked in `epoll_wait` for `VSYNC` events. But `ueventd`, which receives every
   kernel event, saw one unrelated event in 24 s while four frames went to the panel with vsync
   enabled. Electronic paper has no periodic refresh to report.
2. **So SurfaceFlinger reports `No Last HW vsync`, forever.** Android 11's `VSyncReactor` confirms a
   period change only from hardware samples (`periodConfirmed`, 10% allowance), ignoring present
   fences while a transition is pending. With no samples it sat at `mPeriodConfirmationInProgress=1`,
   `mPeriodTransitioningTo=62500000`, predictor on its 16.67 ms placeholder, fences ignored, and the
   app EventThread `synthetic` even with the screen on.
3. **The legacy model is no escape.** `debug.sf.vsync_reactor=false` was tried: the legacy
   `DispSync` also gates period adoption on a resync sample, so its period stayed **0** across a
   screen transition. Reverted.
4. **Our shim was not the cause.** It intercepts only the panel update ioctl. It did, however, carry
   a defect found in the same traces: its cache-sync call on the shadow buffers failed with `EINVAL`
   on every frame. Fixed in the same revision by allocating the shadows uncached.

## The fix: generate the vsync the panel cannot

`a11boot/libhwcflip.c` now also hooks `hw_get_module()` in the composer process, wraps the HWC2
device's `getFunction()`, captures the vsync callback the composer HAL registers, and drives it from
a timer thread at the panel period (`persist.display.default_vsync_freq`, 16 Hz here) whenever
vsync is enabled. The vendor's own `setVsyncEnabled` is still forwarded, so its kernel-side
behaviour is unchanged. Kill switch `vendor.hwcflip.vsync=0`; period override
`vendor.hwcflip.vsync_hz`.

**Verified on the device, then again from a cold boot:**

```
before                                     after
mPeriodConfirmationInProgress=1            mPeriodConfirmationInProgress=0
mPeriodTransitioningTo=62500000            mPeriodTransitioningTo=nullptr
mIdealPeriod=16.67                         mIdealPeriod=62.50
app: mPeriod=16.67  sf: mPeriod=16.67      app: mPeriod=62.50  sf: mPeriod=62.50
app: state=Idle ... synthetic              app: state=Idle ...            (screen on)
```

SurfaceFlinger behaves exactly as designed once samples arrive: it confirms the period within two
callbacks, takes the samples its predictor wants, then switches hardware vsync **off** (the
generator stops); on every screen-on it re-enables, re-confirms, and switches off again.
SurfaceFlinger idles at 0 CPU ticks; rendering, touch and the frame mirror are unaffected; the
livelock watcher stays quiet.

## Two mistakes on the way, recorded because both were invisible until measured

* The first build crashed the composer in a restart loop: a `%s` format given an integer in one
  log line. Structure fine, one character wrong. A deploy script with automatic rollback exists now.
* This vendor pair does **not** use the HWC2 enum for `setVsyncEnabled`. Aligned on one clock,
  SurfaceFlinger's "Setting power mode 2" (ON) is followed 4 ms later by the value **2**, and
  "power mode 0" (OFF) by **0**; SurfaceFlinger's own state-change trace markers coincide with
  exactly those calls; and the vendor HWC logs its standard enable code when forwarded 2. So here
  2 = enable, 0 = disable, and 1 never appears. My first reading was inverted, so the generator ran
  only while the screen was off, when SurfaceFlinger drops every sample. `vendor.hwcflip.vsync_encoding=hwc2`
  selects the standard encoding for a HAL that uses it.

## What this does and does not claim

It removes the regime the livelock lived in and makes the scheduler coherent with the panel.
It does **not** prove the livelock cannot recur: the exact predicate that kept the scan loop out
of its wait was never resolved (see above), and only time under the new regime will tell. The
watcher and its automatic recovery therefore stay in place.

## Fourth occurrence, 2026-09-21 23:10: the vsync fix did not remove it

The first recurrence *under* the software-vsync regime, and the answer to the open question above
is no: coherent vsync does not prevent the livelock.

| | |
|---|---|
| 23:09:43.048 | SurfaceFlinger: `Setting power mode 2 on display 0` (screen-on) |
| 23:09:43.053 | shim: `setVsyncEnabled enabled=2 -> sw vsync 1` (the generator **was** running) |
| 23:10:36 | watcher: app EventThread (tid 2265) at 95% of a core for 45 s, capture taken |
| 23:11:00 | watcher: SurfaceFlinger killed (recovery 1 of 3 this boot) |
| 23:24:28 | watcher: new SurfaceFlinger pid seen, framework back |

Same signature as the third occurrence, to the percentage point: the connection-scan callees
(`attemptIncStrong` 26%, thread proxy 24%, `decStrong` 22%, `decWeak` 20%), the main thread
blocked in `std::mutex::lock` at the top of `EventThread::onScreenAcquired`, the same trigger 53 s
before detection. The capture's `dumpsys SurfaceFlinger` timed out as expected, so whether the app
thread was still `synthetic` at that instant is not recorded; the enable line above is the only
in-window evidence about vsync, and it says the generator had been asked for and was delivering.

**The recovery worked, the restart did not.** The kill cleared the livelock in seconds, but with
the cable out nothing held the device awake and it kept suspending in the middle of the framework
restart: 13 minutes from kill to a new SurfaceFlinger, during which the power button appeared dead
and the panel then showed the boot animation (phh's GSI draws Donald Duck and nephews as its logo
mask, `assets/images/android-logo-mask.png` in `framework-res.apk`; there is no bootanimation.zip
on this build). `tools/sf-watch.sh` now takes a kernel wake lock (`/sys/power/wake_lock`) for four
minutes around the kill.

**What the next capture will add.** The unresolved contradiction (state Idle, empty queue, yet no
syscalls and event-type compares in the profile) needs the spinning thread's own state, not the
process's. `tools/sf-capture.sh` now runs `tools/src/threadregs.c` on the hot thread twice, one
second apart (registers, NEON d0-d15, 512 B of stack, 256 B of the object in r9 with the
EventThread field offsets), and then three seconds of `strace` on it. An empty strace file is the
first direct proof of "no syscalls"; a non-empty one ends that line of reasoning.

**Ruled out on the way:** a kernel failing to preserve the callee-saved NEON registers d8-d15
across context switches (which would let a loop counter held in NEON never reach its bound). A
canary that loads patterns into d8-d15 and checks them in a tight loop ran 150 s on all four cores
through eight screen-off/on cycles and refreshes: zero corruptions.

**Status.** Four occurrences, always seconds after a screen-on, always the app EventThread's
connection scan holding the EventThread mutex. Software vsync makes the scheduler coherent and is
worth keeping on its own merits, but it is not the cure. The cure is not known. The watcher's
detect-and-kill is the fix in service: about a minute of frozen panel, foreground app state lost,
no reboot.
