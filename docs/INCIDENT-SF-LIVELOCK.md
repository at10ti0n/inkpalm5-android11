# Incident 2026-09-17/18: device hot, screen frozen, power button dead

Reported by the operator: "device seems hot to touch even after being unplugged", then
"it seems stuck, can't open it back with power button".  Captured live over ADB before any
reboot (`a11/gate17/build/hang/20260918-001051/`, project side).  Root cause identified;
no fix yet.  This is the first hang in ~2 months of daily use of this port.

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
   `settings put secure doze_always_on 0` for a few days.  If the hang does not recur,
   AOD/doze is implicated and the overlay work needs revisiting.
3. Only if it recurs and 2 does not implicate AOD: A/B the composer shim.
4. Unrelated but found in the same logs: the RIL retries forever,
   `RIL: fd = -1, sleep 2s wait device, total wait time: 3050s` -- a 0.5 Hz wakeup for a
   radio this device does not have.  Disabling it belongs with the §3.5 telephony work.
