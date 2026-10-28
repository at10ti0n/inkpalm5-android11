# Bounded framework restart wake lock (EPD105)

The 2026-10-28 incident was a framework crash, not a kernel reboot. Device uptime
continued across a `system_server` SIGBUS in
`AssetManager2::RebuildFilterList` at 07:28:51.009. A root `stat` process aborted
in BoringSSL's power-on self-test at 07:28:51.020. The new zygote logged 592,738 ms
for PostZygoteInitGC; `wm_boot_animation_done` was not logged until 11:54:20.709.
The installed zygote RC only wrote `/sys/power/state on` on restart. It had no
recovery wake lock. Older kernel records from the start of the incident had
already rotated out when this trial was prepared.

The guard addresses recovery being stretched by autosuspend. It does not repair
the original crash. CPU/VFP state corruption is a hypothesis, not established by
these reports; the September report also lacks the failing thread's VFP capture.
There is no measured promise of one-minute recovery or zero battery cost.

AOSP later implemented the same recovery principle in a pair of changes:
[take a lock on zygote restart](https://android.googlesource.com/platform/system/core/+/3182e9c2a%5E!/)
and [release it when autosuspend is enabled again](https://android.googlesource.com/platform/system/hardware/interfaces/+/6e976b2).
Copying only their acquisition would omit essential release behavior on Android 11.

## Implementation

`configs/framework-recovery.rc` installs as
`/vendor/etc/init/inkpalm-framework-recovery.rc`. Stock Android 8.1 init supports
the property conjunctions and `write` commands used here. No binary, daemon,
framework patch, boot image, or calibration change is required.

- `post-fs-data` initializes a nonpersistent recovery-episode property to `idle`.
- Either boot animation starting or `init.svc.zygote=restarting` acquires a named
  kernel wake lock with a **900,000,000,000 ns (15 minute)** kernel timeout, once
  per episode. The animation trigger covers the measured interval before init
  reports zygote restarting. The second trigger cannot renew the first lock.
- The guard must observe the boot animation running before its stopped state
  can release the lock. Zygote must also be running. A stale boot-completed
  property or a stopped animation left from the preceding session is insufficient.
- Repeated crashes during the episode do not write the wake lock again. Its
  original expiry remains in force even if recovery never finishes.
- Successful recovery resets the episode. A later independent crash can receive
  its own bounded recovery interval; this is not a lifetime battery-use limit.

`sys.inkpalm.fwguard` is `idle`, `waiting-animation`, or `animating`. It tracks the
episode, **not the kernel lock's current activity**. After timeout it remains
armed until the readiness sequence completes, preventing renewal in a crash loop.
If a recovery never starts/finishes an animation, expiry still releases the lock;
early release and rearming require the observed animation sequence.

The animation trigger also protects initial boot while its animation is running.
It is a vendor property-action approximation of the newer native
zygote/SystemSuspend pairing.
It must be tested on the installed init and on battery before being called proven.

## Trial and rollback

The normal `configure` phase installs the guard by default and activates it with
its usual reboot. To add only this fix to an existing Android 11 installation:

```sh
python3 install/inkpalm.py framework-recovery
adb reboot
```

This phase stages the repo's RC and the shared device installer directly, without
downloading release assets or updating apps. It refuses an unreviewed zygote RC or
an unknown existing guard. Both the full installer and the shell wrapper use
`install/device/framework-recovery.sh`; the reviewed RC's hash is pinned there.

Run `python3 tools/test-framework-recovery.py` for the event-model checks.
`bash tools/install-framework-recovery.sh install` verifies the reviewed zygote
definition and transferred RC, refuses unknown existing files, records the
original absence in `/data/local/inkpalm-framework-recovery`, and atomically
installs the RC with vendor-config ownership/mode/context. Vendor is remounted
read-only before returning. Reboot separately to load it.

Rollback: `bash tools/install-framework-recovery.sh rollback`, then reboot.
It removes only the exact recorded RC; it does not modify other vendor rules.
For recovery without Android ADB, remove that same single RC from mounted vendor
in TWRP, then reboot. Removing a file cannot unload already parsed init actions.

Observe `getprop sys.inkpalm.fwguard`, `/sys/power/wake_lock`, the kernel messages
prefixed `inkpalm-fwguard`, new zygote/system_server PIDs and boot-animation events.
Do not use `sys.boot_completed=1` alone as a successful warm-restart check.

## Validation

Preparation: the device accepted a separate 2-second timed wake lock and removed
it automatically after 3 seconds. The revised event model passes 23 checks including stale
readiness, repeated crashes before/after expiry, delayed zygote restart and a new
episode after recovery. These are not a live init parser or suspend test.

Installed 2026-10-28. RC SHA-256:
`0215e926bf20a414c325450696ce2f833a5ea272ba67cb898949787a9b3b4bcc`.
The existing services.jar, libsurfaceflinger.so and zygote RC hashes were unchanged.

The first version (zygote trigger only, SHA-256
`1baca31f712471d26798ed92f24094575e28bbfd1e96b8ed310818251e605c36`)
produced these results:

- Reboot loaded the RC and initialized its episode property. An early startup
  zygote restart acquired the lock. The property advanced through `animating` to
  `idle`, and the lock was absent after boot animation completion.
- Deliberately killing system_server over USB produced a new system_server PID
  (2340 -> 4522). The recorder observed the named recovery lock while the animation
  ran, then `idle`, animation stopped, and no held kernel wake lock. Recovery took
  **39 seconds**. USB already blocks suspend; this verifies acquisition/release,
  not suspend protection on battery.
- Unplugged recovery completed in **34 seconds**, new system_server 4522 -> 6820.
  The operator confirmed automatic sleep afterward, without pressing power. Two
  successful kernel suspends followed recovery. One short successful suspend
  occurred at the start, before the zygote-triggered guard acquired its lock.
  Kernel timestamps placed boot animation start at 356.949469, the successful
  suspend interval at 357.277036 -> 357.839622, and the guard start at 357.990705.
  This exposed a race worth reducing: the revision also acquires at animation
  start, which is earlier on this port. It remains a userspace init action, not
  an atomic lock acquisition at the instant a process crashes.
- File-level rollback removed the exact RC and remounted vendor read-only.
  Reinstallation restored its verified hash. This did not reboot with the guard
  absent, so it is not a live test of unloading the rules.

For a controlled test, `tools/trial-framework-recovery-device.sh` must run as root
on the device with arguments `usb|unplug UNIQUE-RUN-NAME`. It **deliberately kills
system_server**, records the episode phases, held lock and suspend counters, then
exits when a new system_server has completed the animation. It checks readiness
before starting and refuses to overwrite a run. Results stay under
`/data/local/inkpalm-framework-recovery/UNIQUE-RUN-NAME/`.

The `unplug` mode waits at most five minutes for USB power to disappear, then
waits three seconds and starts. A separate, kernel-timed preparation lock is
released **before** the kill; it cannot account for protection during recovery.
After recovery, let the device sleep and reconnect to compare the suspend counters.
Use nohup and redirect stdin/stdout/stderr so the recorder survives ADB disconnect.

The revised animation/zygote guard passed a repeat unplugged trial on 2026-10-28:

- USB power was confirmed disconnected before the deliberate system_server exit.
  The preparation lock was released before the exit.
- New system_server PID 2349 -> 4254, same kernel boot ID across the trial.
  The recorder reported **34 seconds** from exit to recovery.
- During the animation, only the named recovery lock appeared in the kernel
  user-wake-lock list. It was absent after completion; episode property `idle`.
- Kernel suspend counters were **success 0 / fail 0** before, during, and just
  after recovery. Thus the transition suspend seen in the first version did not
  recur, and there were no suspend attempts during this revised trial.
- After recovery the device slept automatically, without a power-button press.
  On reconnect, the success counter was **1**, with all failure counters still
  zero. The operator independently confirmed recovery and automatic sleep.
- The final RC hash matched the installed receipt, vendor was read-only, and the
  temporary on-device trial script was removed. Trial records remain available.

The guard-only Python phase and shell wrapper were run on the device after
integration; both recognized the already installed RC and changed no files.
Four CLI integration checks cover staging, success/refusal reporting and avoiding
asset downloads; two shell checks cover the default and explicit device serial.

The guard is installed and tested on this device, and is included in the current
repo's installer (older downloaded repo/release copies do not gain it automatically).
These were deliberate process exits, not reproduction of the
original SIGBUS or a long-term stability test. The 15-minute value and nonrenewal
logic were checked in the RC/event model; actual kernel expiry was tested with
the separate short probe, not a full 15-minute failed-recovery run.

Private raw captures are local under
`measurements/framework-recovery-2026-10-28/` (outside this export repo), with
on-device trial records under `/data/local/inkpalm-framework-recovery/`.
