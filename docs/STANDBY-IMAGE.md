# Standby image before sleep — stock trace and Android 11 implementation

Status: **installed; physical image, automated sleep/cancellation checks and the
unplugged suspend/wake check passed** (user-confirmed 2026-09-22: image clear, wake normal).
Do not treat this as a released fix.

## What stock Android 8.1 actually did

Recovered from this device's original `partitions/system.img`, rather than inferred
from the appearance of the sleep screen:

1. `PowerManagerService.goToSleepNoUpdateLocked` takes the vendor "super standby"
   path for a power press and the relevant timeout transition.
2. It sets `mCanUdatePowerState=false` (the spelling is in the binary) and posts
   `mShowLogo`, which calls `showSuspendLogo()`.
3. `showSuspendLogo()` creates a dedicated full-screen **SuspendLogo** window:
   type 2006, flags 66816, `setRefreshMode(4)`, custom wallpaper or the vendor's
   fallback image. It does not depend on the keyguard having drawn.
4. `mAfterShowLogoTimer` is **2200 ms**. The delayed `mAfterShowLogo` restores
   `mCanUdatePowerState=true` and calls `updatePowerStateLocked()` under `mLock`.
   One vendor power-mode timeout branch adds another 300 ms.
5. Wake posts `mHideLogo`, which removes that window.

Thus stock explicitly **staged an image before permitting display shutdown**, using
a fixed delay. It did not have a demonstrated frame-completion handshake here.
The earlier suggestion that ordinary keyguard behaviour was sufficient was wrong.

Local evidence is in `a11/stock-sleep-review/` in the parent workspace. Original
vendor binaries and decompiled source are not redistributed with this repository.

| Input | SHA-256 |
|---|---|
| Stock services.vdex | `5f9534b5c637a390f186dbc997995cfc471fa388124f753edb569e35913320bd` |
| Stock SystemUI.vdex | `670d2d1bc402b6a0d9dfe3bacbf2f4e0687cc700bf089bc48a39119d9f477e4e` |
| Android 11 services.jar being patched | `ac34b0f57e09fc32ff1e024736f7114e30464c973406e0a3204cd1d5848518d4` |

Extraction used debugfs, vdexExtractor and jadx. The stock services VDEX required
vdexExtractor's checksum override after unquickening; its reconstructed DEX is not
claimed to be byte-identical to the pre-optimization original. The resulting services
DEX decompiled without errors; the control flow above is from that recovered code.
SystemUI unquickened without a checksum override.

## Android 11 approach

`framework/StandbyScreen.java` draws the current user's lock wallpaper in a dedicated
type-2006 window, with no animation, input focus, keep-screen-on flag, or permanent
polling. It uses an independent handler thread; bitmap decoding, file reads and window
manager calls never happen under the power-service lock or on its handler.

The existing request interlock is adapted from the earlier uninstalled keyguard patch:

- Short power press and ordinary idle timeout stage the original event time, reason,
  flags and UID under `PowerManagerService.mLock`.
- A generation token prevents stale show/completion/deadline work from reviving a
  cancelled request. Interactive user activity, successful wake and an unrelated accepted
  sleep invalidate it. Software OTHER + NO_CHANGE_LIGHTS activity still updates native
  clocks and cancels timeout requests, but cannot cancel an explicit power-button request. The renderer checks the token too and removes stale overlays.
- A power request supersedes a pending timeout; repeated timeout checks coalesce.
- Completion and the independent **8-second deadline** both call the same one-shot
  decision. It rechecks timeout eligibility under `mLock` and replays the original
  request through the normal sleep method. An expired request does not sleep again.
- The image remains over the keyguard through sleep and is removed on wake. No
  `lockNow()` call, SystemUI modification, AOD enablement, or SurfaceFlinger change
  is involved in this patch.

The deadline is an exceptional fallback, **not successful image verification**. Missing
wallpaper, unavailable frame stats, a failed render, or a stalled display can take it.
Its purpose is to avoid leaving the device awake indefinitely. Logs distinguish
`completion=true` from `completion=false` at the sleep decision.

Cancellation racing an in-progress window-manager call may briefly show the overlay
before the queued removal runs. It cannot revive the cancelled sleep. A permanently
blocked window-manager call can delay overlay removal; this patch does not repair
an independently hung compositor/window manager.

## Completion evidence and its limits

The renderer queries `getWindowContentFrameStats()` for **its own window token**.
It requires the newest frame to have been posted after the request and have a real
presentation timestamp (not an unsignalled/future timestamp). A previous frame cannot
stand in for a newer pending frame.

The compositor's fence is not the E Ink waveform finishing. After that timestamp,
the gate also requires a new `sy7673a_wakelock` cycle, an inactive source, a last-change
timestamp at/after presentation, and 150 ms of unchanged observations. Both clocks
were compared in the preliminary device capture. The exact stock kernel's
`sy7673a_power_down` releases this wake source after its power-down sequence.

This combines a frame-specific compositor observation with a **global** panel-idle
observation. The panel signal is not a per-frame completion fence, and a failed PMIC
operation could still release it; physical tests and kernel-error checks are required.
Do not represent the gate as hardware proof from these counters alone.

The reference PocketBook kernel has `DISP_EINK_SYNC/STATE/GET_ACTIVE_UPDATES`, but the
matching Moaan kernel's examined ioctl switch does not implement those cases directly.
No speculative ioctl was issued and no kernel/PMIC register was changed.

The preliminary platform-signed activity probe returned real presentation timestamps
and panel cycle changes. Its initial frame took roughly 2.5 seconds to present in one
run: that is evidence against assuming the earlier 800 ms delay always suffices, not a
performance claim about the new overlay or a completed standby test.

## Build and checks

```sh
bash framework/test-completion.sh
python3 framework/interlock-model-test.py
bash framework/patch-services.sh services.jar services-standby.jar
```

The builder refuses any input except the original Android 11 hash above. It does not
stack patches on an already modified framework. Assembling/Dex parsing catches some
structural defects, but cannot establish ART verification, lock ordering or device
behaviour. The Python model tests request ordering; the Java checks exercise the
actual completion gate. Neither replaces the tests below.

For the controlled device trial, `framework/trial-standby.sh install services-standby.jar`
requires the builder's adjacent `.standby-sha256` receipt and either the exact original
framework or a recorded prior trial on the device. It saves and verifies a dedicated `/data/local/inkpalm-standby-backup`,
including original precompiled artifacts, before replacing anything. It then reboots.
`framework/trial-standby.sh rollback` verifies that backup and refuses to overwrite an
unrelated framework modification. The deployment path has run on the device with verified framework/oat backups;
it is separate from the release installer. The device shell aliases `hash`, so
the script deliberately uses `file_sha256` for its checksum helper.

## Initial installed trial (2026-09-22)

The first trial jar hash was
`4077368bc5b133f557cf3d4606efd52823f90d30f9d7f73efa7f2ab62ec64026`.
The corrected trial is
`a198a9b9d9b5ad1bea8800bc3428d00b48f1f0667e10954ce8ce749437af7eca`.
The original framework and all three precompiled artifacts were backed up and
checksum-verified. Initial boot and execution of the new code produced no observed
ART verifier error or Android crash. The existing boot-fixup script independently
rebound the SF workaround and restarted the framework once; its final library hash
remains `d8a7132d244ff4b7425d4cc9b320732002187002d9804b792f9f03d5701f5a07`.

Initial runtime observations:

- Timeout token 5: completion after 1082 ms, followed by normal timeout sleep.
- Launcher power-button token 8: completion after 3232 ms, followed by normal
  power-button sleep. `dumpsys power` reports Asleep / display OFF.
- Both decisions reported `completion=true`; neither used the 8-second fallback.
- WindowManager reports the standby window drawn at 720×1280, above the keyguard.
- No matching panel power-down failure was found in the captured kernel log.

The user confirmed the chosen image was clear on the physical panel while asleep.
Wake removed the overlay and restored display ON. Further live checks passed:

- Power-button sleep over keyguard completed in 3722 ms.
- Power-button sleep from an open Kindle book (StandAloneBookReaderActivity)
  completed in 1459 ms, followed by display OFF.
- Touch during preparation removed token 21; the device remained awake beyond
  the original 8-second deadline with no stale sleep decision.
- After sleep, the standby worker was parked in `SyS_epoll_wait`, not polling.
- Landscape rendered at 1280×720 and completed in 1939 ms before sleep; portrait
  was then restored. Physical landscape cropping has not been separately reviewed.
- Extending the timeout from 15 seconds to the original 120 seconds during token 34
  preparation rejected sleep at the eligibility recheck and removed the overlay.
- Missing/unreadable-image trials exposed a cancellation bug: software
  NO_CHANGE_LIGHTS activity could cancel an explicit power-button request before the
  fallback. The user confirmed no interaction, and the hardware input recorder had
  no events. The corrected trial preserves button requests across OTHER activity with
  that flag while still cancelling on actual touch/button events, normal activity,
  and timeout activity. Its verification results are recorded below.
- Wallpaper bytes and original mode 0600 were restored after fault injection;
  SHA-256 `d15c8c38a48608a5a0d78b70bf8b01aa8937173b7732dd36dd9e4d1c3c36bc3a`.

The corrected trial booted without observed verifier errors and passed the
unreadable-image fallback: token 8 slept at the independent 8-second deadline with
`completion=false`. A deterministic Binder `userActivity(OTHER, NO_CHANGE_LIGHTS)`
injection during token 11 verified the new branch actually ran and preserved the
power-button request; it also slept once at the deadline. This confirms the fix's
behaviour, but does not identify the original software caller that generated those
updates in the first trial. No hardware input was recorded during that earlier period.
A real touch during corrected token 14 cancelled the pending fallback; after its
original deadline the device remained Awake / display ON. A subsequent normal idle
request (token 18) completed image/panel observation in 4071 ms and then slept.
The original 120-second timeout and portrait rotation 1 were restored. The timing
probe APK and activity-injection DEX were removed from the device. Private raw captures remain
under `a11/stock-sleep-review/` outside the export repository.

## Remaining validation and release scope

- Unplugged suspend and normal physical wake: passed (user-confirmed, 60 s unplugged).
- Physical landscape cropping/readability was not separately reviewed, although the
  landscape window and completion path were measured.
- Repeated-request coalescing and stale callbacks are covered by the 32-check model;
  no exhaustive physical button-stress run has been performed.
- The rollback script verifies original backups and installed-trial hashes, but an
  actual rollback boot has not been performed for this trial.
- Longer battery/stability observation is still needed. This work does not establish
  the cause or repair of the separate SurfaceFlinger livelock.

The controlled trial is separate from the standard installer and published release.
No release assets should advertise this behaviour until their integration is reviewed.

## "The standby image looks zoomed": measured, and left alone

Reported after the trial: the standby image looks zoomed or cropped, reproducible by a
power-press sleep followed by a power-press wake. Measured 2026-09-22:

- The overlay's composed frame (screenshot taken while the overlay was up) is pixel-identical
  to the 720x1280 lock wallpaper file, and the panel holds that frame while asleep (user
  confirmed "full image, small letters").
- The keyguard draws the same file at **exactly 1.10x, centered** (offset 36, 64; correlation
  0.998 against the scaled file). That is Android 11's platform wallpaper zoom,
  `config_wallpaperMaxScale = 1.10`, which the window manager applies to every wallpaper on
  the home and lock screens. So a wake shows a 10% zoom-in relative to the standby image.
- It is not the launcher's 1440x1280 "desired size" (the first reading, wrong). einktile v5
  still pins the desired size to the portrait screen when it sets the lock wallpaper, because
  parallax is meaningless on E Ink and a screen-sized wallpaper otherwise gets scaled to it;
  that change persists but does not alter the keyguard framing.

Decision: leave it. Options considered: draw the overlay at the same 1.10x (consistent, loses
5% per edge), or a platform-signed resource overlay setting the scale to 1.0 (needs a reboot,
framework-target overlays may be refused).
