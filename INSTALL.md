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
* phhusson's GSI: **`system-roar-arm-aonly-vanilla.img`** (**use v313** — see the note on
  the Screen Temperature slider under *Known issues*) from
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

Installs the key layouts and touch config, adds the four Quick Settings tiles, applies the
native configuration (locked portrait, lock-screen image, 2-minute timeout, Bluetooth and
scanning off), and reboots.

**When it comes back you are done.** Portrait, touch aligned, brightness slider working.

## 8. Apps (optional)

Nothing here is required, it is just what makes it a good reader:

* **[Aurora Store](https://auroraoss.com/)** — Play Store apps without Google. Install its
  APK with `adb install`, then get everything else through it.
* **[Unlauncher](https://github.com/jkuester/unlauncher)** — a text-list launcher. Set it as
  default in Settings → Apps → Default apps → Home app.
* **[EinkBro](https://github.com/plateaukao/einkbro)** — a browser built for E Ink.
* **Kindle** — physical side buttons turn pages through the sunxi-gpadc0 layout.
* **Orientation** — the Portrait/Landscape Quick Settings tile switches fixed orientation directly. Use einktile v4 or newer; the standard auto-rotate tile is not equivalent on this port.

---

## Using it

| | |
|---|---|
| **Brightness** | the **Brightness** slider in Quick Settings. All the way down = light off. |
| **Warmth** | **Screen Temperature** (Android's Night Light, driving the warm LEDs): the tile, the slider under Brightness (all the way to Cool = off), or Settings > Display > Screen Temperature for intensity and a schedule (custom times). |
| **Text / Graphics** | the **Mode** tile — Text is faster and greyer, Graphics is slower and cleaner. Same two modes stock had. |
| **Clear ghosting** | the **Refresh** tile does one full flash. |
| **Page turns** | the side buttons are normal volume keys; turn on the reading app's own option: Kindle, *Aa* menu > More > "Turn pages with volume controls"; KOReader, its volume-key page-turning setting. |
| **The Moaan logo** | Home, and wakes the device. |
| **Dark theme** | Android 11's own, works OS-wide: the **Dark theme** tile, or Settings → Display. Off by default — on a reflective E Ink panel, dark-on-light is usually the more readable way round. |

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

## Is my firmware version supported?

This has been built and tested against exactly one firmware build:
**`MAS_EPD105_L61B807_T07_V03`** (vendor fingerprint
`Allwinner/virgo_perf1/virgo-perf1:8.1.0/OPM1.171019.026/20240320-173513`, vendor build date
2024-03-20). The version string lives in `vendor.img`, not in boot or recovery.

A different version string does **not** automatically mean it won't work — what matters is
whether your `boot` and `recovery` partitions match. The builders check this for you and
refuse anything they don't recognise, so you can find out **without flashing anything**:

```
adb shell su -c "dd if=/dev/block/by-name/boot     bs=4096" > boot.img
adb shell su -c "dd if=/dev/block/by-name/recovery bs=4096" > recovery.img
sha256sum boot.img recovery.img
```
```
known-good boot.img      62ce2f881e331303027a1562ec93efebaa49a5700737f8df4e25c86ffcfba83d
known-good recovery.img  a13a37be5c0e381d0649aac6377967b87946f2cd4cb4c9743292ce1829842b6c
```

* **Both match** → your partitions are byte-identical to the tested ones. Proceed normally.
* **They differ** → **stop.** The prebuilt images are the *tested* stock ramdisk plus
  patches; on a different ramdisk they are untested and can bootloop, and your recovery path
  (TWRP) is built from that same untested stock. Please open an issue with your two hashes
  and your version string instead — that is genuinely useful, and adding support is mostly a
  matter of verifying the ramdisk structure and the init-patch offset against real data.

`a11boot/mkboot.py` also verifies the ramdisk's `init` hash and that the two bytes at the
patch offset are what it expects, so a coincidentally-matching image with a different init
is still caught.

## Known issues

* **Always-on display is off by default, on purpose.** With the AOD clock on, every redraw
  induces spurious touch events from the Goodix controller (the panel's ±15 V refresh rails
  couple into the capacitive sensor), and each one wakes the device: measured **34 touch
  wakes and 12 failed suspends in five minutes** against **zero of either with AOD off**.
  The proper fix is kernel-side (mask the touch IRQ during panel refresh) and is not
  available on the stock binary kernel. `settings put secure doze_always_on 1` turns the
  clock back on if you want it; see [docs/SUSPEND-DIAGNOSIS.md](docs/SUSPEND-DIAGNOSIS.md).
  With the clock off, the display simply goes off, and **the E Ink panel keeps whatever was
  on screen** -- usually the app you were reading. That is not a panel fault: Android draws
  the lock screen and switches the display off at the same moment, and screen-off does not
  wait for windows to be drawn, so on E Ink the app frame wins the race.

  The installer does set a lock-screen image (`docs/images/standby.png`; replace it with any
  720x1280 image and re-run), and the patched SystemUI hides the lock-screen clock, so that
  is what you see **when you wake the device**. Making it the *sleep* screen as well needs a
  framework patch (`framework/patch-services.sh`) that is **deliberately not shipped**: it
  adds surface creation to every display transition while a SurfaceFlinger hang is under
  investigation, and it has a known defect of its own. See
  [docs/INCIDENT-SF-LIVELOCK.md](docs/INCIDENT-SF-LIVELOCK.md).

* **The Screen Temperature slider and the clock-free lock screen are tied to GSI v313.** They live inside SystemUI, and a
  patched SystemUI only matches the exact GSI build it was built from, so step 7 installs it
  **only** if the SystemUI on your device is byte-for-byte that build — any other GSI is left
  untouched and the step says so. Everything else, brightness included, works on any GSI;
  Screen Temperature still works from its tile and from Settings > Display. To get the slider on a different GSI, build one
  against your own SystemUI with `systemui/patch-systemui.sh` ([BUILDING.md](BUILDING.md)).
  Reflashing or updating the GSI later reverts it — re-run the patch.

* **Two unexplained freezes so far** (2026-09-17 and 2026-09-19, in about two months of
  daily use). SurfaceFlinger starts spinning on one core, nothing composites, the panel keeps
  its last image and the device looks switched off; because it cannot suspend, it flattens the
  battery. Recovery is a 20-second power-button hold. Diagnosed but not fixed, see
  [docs/INCIDENT-SF-LIVELOCK.md](docs/INCIDENT-SF-LIVELOCK.md). A detector
  (`tools/sf-watch.sh`) is installed and runs at every boot. The condition the freeze lived in --
  SurfaceFlinger never receiving a vsync, because the E Ink kernel path emits none -- is fixed as of
  2026-09-21 by the new `libhwcflip.so`, which generates the vsync callback itself (see
  [docs/INCIDENT-SF-LIVELOCK.md](docs/INCIDENT-SF-LIVELOCK.md)). Whether the freeze can still occur
  under the corrected scheduler is not yet known, so the watcher stays, and since 2026-09-21 it also
  **recovers automatically**: after saving the evidence it restarts SurfaceFlinger, which clears
  the hang without a reboot (measured on a live three-hour hang). You lose whatever app was in
  the foreground, which beats a device that will not draw again. If it happens to you, send the
  contents of `/data/local/sf-hang/`.
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
