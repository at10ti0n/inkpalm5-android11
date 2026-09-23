# Leaning on stock Android 11 features: review and proposal

2026-09-24. A review of what the port adds on top of Android 11, measured against what
Android 11 already provides, with a proposal for where the port should hand work back to the
platform. **Implemented the same day**; see "Status" at the end for what shipped, what changed
from the proposal, and one proposal that was withdrawn after it crashed the composer.

## What the port does today

| Area | Our piece | Android 11 equivalent used? |
|---|---|---|
| Boot, display mirror, vsync | `a11boot/` rc + `libhwcflip` preload (mirror, software vsync) | n/a: hardware adaptation |
| SurfaceFlinger livelock | `patch-sf.py` (in service), `sf-watch.sh` detect + recover | n/a: workaround for a platform/kernel interaction |
| Front light brightness | replacement lights HAL | **yes**: the stock brightness slider drives it |
| Front light warmth | Warmth tile (einktile) + warmth slider line (SystemUI patch) + `persist.sys.frontlight.warm` | **no**: Night Light works but only darkens pixels |
| Refresh mode, full refresh | Mode and Refresh tiles (einktile) | none exists; keep |
| Rotation | Rotation tile + fixed-to-user rotation | stock tile needs an accelerometer; this device has no sensors |
| Standby image | lock wallpaper (einktile receiver) + standby overlay trial (services.jar) | **yes**: stock lock wallpaper |
| Lock-screen clock hidden | SystemUI patch | no stock setting in 11 |
| Sleep screen / AOD | stock doze settings, AOD off | **yes** |
| Page keys | `.kl` key layouts | **yes**: stock key layout mechanism |
| Storage | FUSE via rc mount points | **yes**: stock FUSE stack |
| Startup settings | `a11-boot-fixups.sh` re-asserts settings at every boot | partly; see below |

## Measured on the device today

- **Night Light works, and on E Ink it only darkens.** It is available, and when on, SurfaceFlinger
  applies a display colour matrix. At the current 3030 K the matrix rows sum to red 1.00,
  green 0.77, blue 0.54, so paper white drops to about 81% grey by luma weighting. No warmth,
  less contrast. The warmth this device can show comes from the warm LED bank, not from pixels.
  (An earlier draft of this document said Night Light was unavailable; that misread the
  "Display white balance: Not available" line of `dumpsys color_display`, and checked per-layer
  transforms instead of the display matrix.)
- **"Colors" is set to Boosted** (colour mode 1), so a saturation matrix is applied to every frame
  even with Night Light off. Its rows sum to 1, so greys are unchanged; it only costs work.
- **No sensors.** `dumpsys sensorservice` lists none: no accelerometer, no light sensor. Stock
  auto-rotate and adaptive brightness can never work; the stock rotation tile is already absent.
- **No camera, telephony, NFC or GPS** hardware features; Bluetooth is present.
- **Battery saver forces dark theme** (`enable_night_mode=true` in the full saver policy). On E Ink
  that is a full-screen inversion with ghosting at the moment the battery is low.
- **Quick Settings panel now:** Rotation, Mode, Refresh, Wi-Fi, Bluetooth, Do Not Disturb, Battery
  Saver, Airplane, Cast, Screen Record, `dbg:mem` (a phh debug tile), Warmth, Dark theme,
  Night Light.
- Screen saver (daydream) is already off; the suspend-policy overlay is installed and active.

## Proposal

### 1. Make Night Light the warmth control (recommended, medium effort)

Turn Night Light into what it means on a reading device: warm front light, with its schedule.

1. **Framework overlay** (extend the existing `overlays/` pattern):
   both `config_nightDisplayColorTemperatureCoefficients` arrays set to identity
   (`0, 0, 1` per channel). Night Light keeps its tile, Settings page and schedule, but the
   matrix it applies becomes identity, so pixels are no longer darkened.
2. **A small observer** watching `night_display_activated` and
   `night_display_color_temperature`: activated maps the temperature onto the warm bank
   (4082 K to a low warm level, 2596 K to level 24), deactivated returns to a day level
   (0, or a `persist.sys.frontlight.warm_day` preference). It writes the existing property and
   nudges brightness, exactly what the Warmth tile does now. The lights HAL is unchanged.
   Host: SystemUI, which is persistent and already patched; the warmth slider code there is
   replaced by the observer, so the patch gets smaller.
3. **Remove** the Warmth tile, and either remove the warmth slider line or rebind it to the
   Night Light temperature so both controls always agree.

What you gain: the stock Night Light tile, its Settings page with an intensity slider, and its
**schedule** (custom on and off times). *Sunset to sunrise* needs location, which the port keeps
off, so only custom times would work. What you lose: warmth outside Night Light hours, unless
the day level is kept; and quick in-panel adjustment, unless the slider line is kept and rebound.

To verify when built: the tile toggles the LED bank; SurfaceFlinger's color transform stays
identity; no GPU composition appears while active; schedule transitions fire while asleep.

### 2. Trim Quick Settings to what an E Ink reader uses (small effort)

- **Keep:** Rotation, Mode, Refresh, Wi-Fi, Airplane, Do Not Disturb, Battery Saver,
  Night Light (after item 1).
- **Remove from the panel:** Cast, Screen Record, `dbg:mem`, Warmth (after item 1).
  Dark theme: remove unless you want it; it works but ghosts heavily.
  Bluetooth: keep only if you use a Bluetooth page turner (see item 4).
- **Optionally tidy the Edit list** with a SystemUI overlay on `quick_settings_tiles_stock`,
  dropping cellular, flashlight, location, hotspot, invert colours, work profile, reverse
  charging, cast and screen record, so they cannot be added back by accident.

Mechanism: the installer already rewrites `sysui_qs_tiles`; it would write the full intended
list instead of appending.

### 3. Stop battery saver from forcing dark theme, and set Colors to Natural (trivial)

`settings put global battery_saver_constants enable_night_mode=false`, once, in
`configure-native.sh`. Battery saver keeps all its power measures, minus the inversion.
Also select Settings, Display, Colors, Natural, which drops the always-on saturation matrix.

### 4. Let Android remember user choices instead of re-asserting them at boot (small)

`a11-boot-fixups.sh` turns Bluetooth off, sets location off, turns off Wi-Fi and BLE
scanning and zeroes the three animation scales at every boot. Android 11 persists all of these,
so doing it each boot silently overrides your own choices (switch Bluetooth on for a page
turner, and it is off again after a reboot). Move them to the one-time `configure-native.sh`.
Keep the per-boot user-rotation re-assertion, which fixes a real app behaviour.

### 5. Leave as they are

- **Mode and Refresh tiles:** Android has no refresh-mode concept.
- **Rotation tile and fixed-to-user rotation:** the stock route needs an accelerometer.
- **Lock-screen clock hiding and the standby overlay:** no stock equivalent in Android 11.
- **Brightness:** already the stock slider.
- **Grey-scale or colour-correction accessibility modes:** pointless on a greyscale panel.

## Suggested order

Items 3 and 4 first (settings only, reversible, no rebuild). Then item 2 together with item 1,
since removing the Warmth tile only makes sense once Night Light drives the LED.

## Status (2026-09-24, implemented and verified on the device)

| Item | Result |
|---|---|
| 1. Night Light as the warmth control | **Done, as "Screen Temperature".** Night Light's tile, Settings > Display page and schedule drive the warm LEDs; the pixel tint is identity; the QS slider row is a front end to Night Light; the Warmth tile is gone. Details: [FRONTLIGHT.md](FRONTLIGHT.md). |
| 2. Quick Settings trimmed | **Done.** Orientation, Mode, Refresh, Wi-Fi, Bluetooth, DND, Battery Saver, Airplane, Screen Temperature. The Edit list offers only tiles this hardware can use. |
| 3. Battery saver without dark theme | **Done.** Also dark theme set to stay off: the GSI default "auto" would have inverted the UI at sunset. |
| 3b. Colors: Natural | **Withdrawn.** It crashed the composer; see below. Colors stays Boosted. |
| 4. Settings persisted, not re-asserted at boot | **Done.** Bluetooth, location, scanning and animation defaults are set once by `configure-native.sh`; the boot script keeps only the rotation fix and the refresh-mode defaults. |
| 5. Leave as is | Unchanged: Mode, Refresh, Orientation tiles, hidden lock-screen clock, standby overlay. |

**Why Colors must stay Boosted.** "Boosted" applies a saturation matrix, which the vendor
composer cannot do in hardware, so SurfaceFlinger composites everything on the GPU into one
1280x720 image. That is the only input the frame mirror (`a11boot/libhwcflip.c`) was built and
validated for. With Natural the matrix disappears, individual layers reach the old vendor
composer directly (verified: the lock screen's layers switch from CLIENT to DEVICE), and at
boot the 1280x1440 wallpaper buffer overran the mirror's 1280x720 buffers: three composer
crashes in memcpy and repeated framework restarts. The mirror now refuses any buffer larger than
its own (logged as `vendor.hwcflip.toobig`) instead of overrunning, so choosing Natural in
Settings can no longer crash it, but layers composed that way are not mirrored and would show
wrongly. Leave Colors on Boosted.
