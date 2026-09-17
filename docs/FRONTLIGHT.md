# Front light (brightness + warmth) on Android 11 -- EPD105

Stock 8.1 had two sliders (cold light, warm light).  On the GSI neither the brightness
slider nor anything else lit the panel.  Fixed 2026-09-17; this is what was found and built.

## Hardware and what the vendor stack does with it
* TI **LM3630A** two-bank LED driver on i2c-2 @ 0x36 (`/sys/bus/i2c/devices/2-0036`,
  kernel driver `lm3630a_bl`, chip-enable GPIO 360 high).  Bank A/B = cold/warm.
  Both banks run in PWM mode (CONFIG 0x01 = 0x1b); one SoC PWM (`s_pwm` pwm-0, 32 kHz)
  is the shared dimmer, the per-bank brightness registers set the mix.
* `/sys/class/backlight/lm3630a_led{a,b}` exist but are inert here (writes set the PWM
  duty only; `actual_brightness` stays 0).
* The vendor **lights HAL module** `/vendor/lib/hw/lights.virgo.so` ("SoftWinner lights
  Module") never touches the LM3630A: it sends the backlight value to `/dev/disp`
  (`disp` sysfs shows `backlight( n)` following the slider) -- the LCD backlight path of
  the reference design, which goes nowhere on this board.  So on Android 11 the native
  slider -> `LightsService` -> `android.hardware.light@2.0-service` -> `lights.virgo.so`
  chain was complete and functional; it just ended in the wrong place.
* Stock SystemUI bypassed the HAL.  `com.android.systemui.moan.FunctionSettingsControl.
  setLedValue(cold, warm)` (decompiled from the stock odex; stock `/system/priv-app/
  SystemUI`) writes five world-writable procfs nodes the Moaan kernel adds:
  ```
  /proc/lm3630a/pwm_level        0..255 shared PWM duty (0 = PWM off)
  /proc/lm3630a/leda_max_cur     0..7   cold bank full-scale current
  /proc/lm3630a/leda_brightness  0..255 cold bank brightness register (+ bank enable)
  /proc/lm3630a/ledb_max_cur     0..7   warm bank full-scale current
  /proc/lm3630a/ledb_brightness  0..255 warm bank brightness register (+ bank enable)
  ```
  from five 25x25 lookup tables (`led107.LedParamControl`: `PWM_VALUE`, `COLD_CURRENT`,
  `COLD_BRIGHTNESS`, `WARM_CURRENT`, `WARM_BRIGHTNESS`, indexed `[warm][cold]`, levels
  0..24).  The tables are what make a "cold 12, warm 0" and a "cold 12, warm 20" look the
  same brightness on the cold side despite the shared PWM.  They are reproduced verbatim in
  `frontlight/frontlight_tables.h` (extracted programmatically from the class initializer).
  Stock also persisted `mogu_cold_led_value` / `mogu_warm_led_value` in Settings.Global
  and turned both banks off on sleep.

## The fix: a lights HAL module that drives the real hardware
`frontlight/lights_epd105.c` -> `lights.virgo.so` replaces the vendor module (same legacy
`hw_module_t`/`light_device_t` contract, so the untouched `light@2.0-service` and framework
keep working; only `backlight` is offered, other light types report unavailable exactly as
before).  Per call:

* framework backlight value b (0..255) -> **cold level** `1 + (b-11)*24/245` for b > 10,
  i.e. the native brightness slider is the cold light;
* **warm level** = `persist.sys.frontlight.warm` (0..24), re-read on every call;
* the five proc nodes are written in stock order from the stock tables.

**Off rule.** The framework never sends 0 while the display dozes (AOD sleep screen): it
clamps the doze brightness to `config_screenBrightnessSettingMinimum`, which on the GSI is
10 -- and 10 is also the lowest value the slider can produce (MEASURED: doze -> backlight
10; slider fully left -> 10).  On an E-Ink reader "as dim as it goes" is off, so the HAL
treats b <= 10 as both banks off.  Result: slider fully left = light off, sleep = light
off, wake = restored, no polling, no framework change.  Override with
`persist.sys.frontlight.off_at` if a different build has a different minimum.

**Warmth UI.** einktile v3 adds a **Warmth** Quick Settings tile (0..24 slider dialog).
It writes the property and then nudges `screen_brightness` by one step and back so the
framework re-issues the backlight call and the HAL re-applies with the new warm level.
Verified end-to-end (`logcat -s lights.epd105`):
```
backlight 128 -> cold 12 warm 10      slider 0.5
backlight 129 -> cold 12 warm 20      Warmth tile 20:  leda_brightness 110, ledb 147
backlight 129 -> cold 12 warm 0       Warmth tile 0:   leda_brightness 158, ledb 0
backlight 10  -> cold 0  warm 0       doze / slider minimum: all nodes 0
backlight 255 -> cold 24 warm 10      slider max: pwm 255, leda 222, ledb 209
```

## Install
```
armv7a-linux-androideabi28-clang -shared -fPIC -O2 -Wl,-z,now -o lights.virgo.so \
    frontlight/lights_epd105.c -llog                       # or use the release binary
adb push lights.virgo.so /sdcard/
adb shell su -c 'mount -o remount,rw /vendor;
  cp -p /vendor/lib/hw/lights.virgo.so /vendor/lib/hw/lights.virgo.so.stock;   # once
  cp /sdcard/lights.virgo.so /vendor/lib/hw/lights.virgo.so;
  chmod 644 /vendor/lib/hw/lights.virgo.so; chcon u:object_r:vendor_file:s0 /vendor/lib/hw/lights.virgo.so;
  setprop persist.sys.frontlight.warm 10; sync; reboot'
adb install -r einktile/build/einktile.apk      # v3, adds the Warmth tile (add it in QS edit)
```
Reboot rather than restarting `light-hal-2-0`: `system_server` keeps the dead HIDL proxy
and silently drops backlight calls until it is restarted (MEASURED).
Rollback: copy `lights.virgo.so.stock` back.  The stock module is vendor-proprietary and
is not in this repo.

## Not done / notes
* Which physical bank is cold vs warm follows the stock table names (`leda` = cold).
  If a unit shows the opposite, swap the two `_brightness`/`_max_cur` pairs in `apply()`.
* The stock `ContrastControl` writes `/sys/kernel/debug/dispdbg/gamma_lvl` -- the 8.1
  "contrast" setting.  Not wired up yet; same shape of fix if wanted.
* Cold levels 1..24 are a linear map of the slider; the stock UI had 24 discrete steps,
  so nothing is lost, but the slider's lowest visible step is level 1 at value 11.
