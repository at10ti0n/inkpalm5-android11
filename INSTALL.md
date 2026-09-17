# Install guide — Android 11 on the Moaan InkPalm 5 Pro Mini (EPD105)

Start to finish, about 45 minutes. Two scripts do the fiddly parts; you run six commands.

> **This can brick your device.** You are overwriting `boot`, `recovery` and `system`.
> Step 1 is a backup, and it is not optional — there is no fastboot on this device, so a
> bad write leaves you with buttons and TWRP as your only way back. Read the whole page
> first. No warranty.
>
> **Never write the `private` partition.** It holds your panel's waveform and VCOM
> calibration, it is unique to your unit, and nobody can regenerate it.

## What you need

* A **Moaan InkPalm 5 Pro Mini (EPD105)** on **rooted stock Android 8.1**.
  Not rooted yet? Do that first: https://github.com/qwerty12/inkPalm-5-EPD105-root
* A computer with `adb`, `python3` and `bash`. USB cable.
* This repo: `git clone https://github.com/at10ti0n/inkpalm5-android11`
* The prebuilt images: **[latest release](https://github.com/at10ti0n/inkpalm5-android11/releases/latest)** →
  download and unzip into a folder, e.g. `~/inkpalm-assets/`. Verify them:
  ```
  cd ~/inkpalm-assets && shasum -a256 -c SHA256SUMS
  ```
  (Prefer to build from your own stock images instead of trusting mine? See
  [BUILDING.md](BUILDING.md) — the images are byte-for-byte reproducible.)
* phhusson's GSI: **`system-roar-arm-aonly-vanilla.img`** (tested: v313) from
  https://github.com/phhusson/treble_experimentations/releases — **arm**, **a-only**,
  **vanilla**. Not arm64, not a/b, not gapps. Unpack the `.xz` to get the `.img`.

---

## 1. Back up your device

```
adb shell su -c "dd if=/dev/block/by-name/boot     bs=4096"    > stock-boot.img
adb shell su -c "dd if=/dev/block/by-name/recovery bs=4096"    > stock-recovery.img
adb shell su -c "dd if=/dev/block/by-name/system   bs=1048576" > stock-system.img
```
Three files, ~1.5 GB total. **Put them somewhere you will still have them in a year.**
They are your only way back to stock.

## 2. Flash TWRP

```
adb push ~/inkpalm-assets/twrp-epd105.img /data/local/tmp/
adb shell su -c "dd if=/data/local/tmp/twrp-epd105.img of=/dev/block/by-name/recovery bs=4096 && sync"
adb shell su -c "dd if=/dev/block/by-name/recovery bs=4096 | sha256sum"
```
That last hash **must** match `twrp-epd105.img` in `SHA256SUMS`. If it does not, write it
again — do not reboot with a bad recovery.

> Flash **by name**. `boot` and `recovery` are both 32 MiB and adjacent; a typo here is
> the one mistake that is genuinely fatal.

## 3. Boot into TWRP, using the buttons

Do **not** use `adb reboot recovery` from stock Android — it can write a boot-control
message that sends you somewhere else.

1. Unplug USB.
2. Hold **Power** until the Moaan logo comes back.
3. Hold **Volume Up**, and plug USB in while still holding it.
4. Keep holding until TWRP draws (~20 s).

`adb devices` now shows `recovery`, and you have a root shell. If the screen stays on the
logo, unplug and repeat — the timing is finicky, not deterministic.

## 4. Back up /data, then wipe

```
adb shell "twrp backup D stock-data"
adb shell "twrp wipe data"
adb shell "twrp wipe cache"
```

## 5. Install (one command)

```
bash install/from-twrp.sh ~/Downloads/system-roar-arm-aonly-vanilla.img ~/inkpalm-assets
```

This pads and writes the GSI, writes the boot image and **verifies the read-back**,
installs the three vendor files (display fix, front light, AOD overlay) and enables ADB for
the first boot. It stops with an error rather than continuing if anything does not match.
Writing `system` takes several minutes — leave it alone.

Then:
```
adb shell reboot
```

## 6. First boot

**The first boot takes several minutes and comes up in landscape, mirrored-looking and with
touch in the wrong place. That is expected** — step 7 fixes it. Wait for
`adb devices` to show `device`.

## 7. Configure (one command)

```
bash install/from-android.sh ~/inkpalm-assets
```

Installs the key layouts and touch config, adds the three Quick Settings tiles, applies the
native configuration (locked portrait, AOD sleep screen, 2-minute timeout, Bluetooth and
scanning off), and reboots.

**When it comes back you are done.** Portrait, touch aligned, brightness slider working.

## 8. Apps (optional)

Nothing here is required, it is just what makes it a good reader:

* **[Aurora Store](https://auroraoss.com/)** — Play Store apps without Google. Install its
  APK with `adb install`, then get everything else through it.
* **[Unlauncher](https://github.com/jkuester/unlauncher)** — a text-list launcher. Set it as
  default in Settings → Apps → Default apps → Home app.
* **[EinkBro](https://github.com/plateaukao/einkbro)** — a browser built for E Ink.
* **Kindle** — works; volume keys turn pages.

---

## Using it

| | |
|---|---|
| **Brightness** | the normal Android slider. All the way down = light off. |
| **Warmth** | the **Warmth** tile in Quick Settings (0–24). |
| **Text / Graphics** | the **Mode** tile — Text is faster and greyer, Graphics is slower and cleaner. Same two modes stock had. |
| **Clear ghosting** | the **Refresh** tile does one full flash. |
| **Page turns** | volume keys (Vol Down = Space, Vol Up = D-pad left) — works in Kindle and browsers. |
| **The Moaan logo** | Home, and wakes the device. |

## If something goes wrong

**Stuck on the Moaan logo / bootloop.** Get into TWRP with the button sequence in step 3,
then restore:
```
adb push stock-boot.img /sdcard/ && adb shell "dd if=/sdcard/stock-boot.img of=/dev/block/by-name/boot bs=4096 && sync"
adb push stock-system.img /sdcard/ && adb shell "dd if=/sdcard/stock-system.img of=/dev/block/by-name/system bs=1048576 && sync"
adb shell "twrp restore stock-data"
```
Then `stock-recovery.img` to `recovery` last, if you want stock recovery back too.

**No ADB in Android 11.** From TWRP: `adb shell "twrp mount /cache; touch /cache/phh-adb"`,
then reboot. Never run `adb root` — it kills the ADB daemon this build starts, and you lose
the connection until you reboot.

**Screen mirrored or sideways after step 7.** `/vendor/lib/libhwcflip.so` is missing or
unreadable — re-run step 5's vendor-file section from TWRP.

**Front light does nothing.** Check `adb shell su -c 'getprop persist.sys.frontlight.warm'`
returns a number, and that `/vendor/lib/hw/lights.virgo.so` matches the release hash. See
[docs/FRONTLIGHT.md](docs/FRONTLIGHT.md).

## Known issues

* **One unexplained freeze.** On 2026-09-17, after ~2.5 h uptime, SurfaceFlinger livelocked:
  the screen froze on its last image, the power button appeared dead, and the device got
  warm and stopped sleeping. ADB still worked; a reboot fixed it. It has happened once in
  two months. Diagnosed but **not fixed** — full evidence and next steps in
  [docs/INCIDENT-SF-LIVELOCK.md](docs/INCIDENT-SF-LIVELOCK.md). If it happens to you,
  please run `a11/gate17/build/hang/capture.sh` **before** rebooting and open an issue.
* **Landscape for a moment at every boot**, before the rotation lock applies.
* **Battery life is not characterised yet.** Suspend works; long-term numbers are pending.
* **Untested:** audio (no speaker on this device), Bluetooth (declared, kept off).
* No NFC and no GPS hardware. Telephony is declared by the vendor but absent.

## Where things are

    install/     the two scripts above
    twrp/        TWRP builder + the recovery display/touch fix
    a11boot/     boot image builder + the composer mirror fix
    frontlight/  the replacement lights HAL (brightness + warmth)
    einktile/    the Quick Settings tiles app
    configs/     key layouts, touch config, native configuration
    docs/        how each piece works, and why

Questions: the [r/InkPalm5 thread](https://www.reddit.com/r/InkPalm5/comments/1wirslw/android_11_running_on_the_moaan_inkpalm_5_pro/)
or an issue here. Results from other units are especially welcome — this has been tested on
exactly one device.
