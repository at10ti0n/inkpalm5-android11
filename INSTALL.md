# Install guide — Android 11 on the Moaan InkPalm 5 Pro Mini (EPD105)

Start to finish, about 45 minutes. **One installer does all of it** (below); the manual route
further down shows each step it takes.

> **This can brick your device.** You are overwriting `boot`, `recovery` and `system`.
> Step 1 is a backup, and it is not optional — there is no fastboot on this device, so a
> bad write leaves you with buttons and TWRP as your only way back. Read the whole page
> first. No warranty.
>
> **Never write the `private` partition.** It holds your panel's waveform and VCOM
> calibration, it is unique to your unit, and nobody can regenerate it.

## What you need

* A **Moaan InkPalm 5 Pro Mini (EPD105)** on **rooted stock Android 8.1**.
  Not rooted yet? Use qwerty12's method: https://github.com/qwerty12/inkPalm-5-EPD105-root,
  **but read this first.** That guide targets the `MAS_EPD105_L8AM105_*` firmware line (its
  check wants `ro.fota.version` = `MAS_EPD105_L8AM105_V05_210518`). This port was built on the
  `MAS_EPD105_L61B807_*` line (check with `adb shell getprop ro.project.sw.version`): same SoC,
  board and partition layout, different firmware branch. On L61B807:
  * the signed **dump ZIP works and only reads** your boot partition (its update script has no
    version check, and stock recovery trusts the same AOSP test key it is signed with);
  * **don't use qwerty12's pre-patched V05/V11 boot images**; they are untested on L61B807.
    Compared with this device's stock boot (2026-09-28), V05's has the same kernel version
    (4.9.56), header, drivers and ramdisk (one SELinux file differs), but it is a different
    kernel build from 2021 under a 2024 system, and the vendor's kernel modules (e.g. the Mali
    GPU driver, built with `modversions`) are only known to load on L61B807's own kernel. It is
    not a brick risk (only the boot partition is written, and stock recovery can put your own
    dumped image back), just an unnecessary unknown;
  * patch **your own** dumped `bimg.img` with Magisk and flash that with the template ZIP.
    Keep the unpatched `bimg.img`: it is the stock boot image this guide checks and builds from.
* A computer with **Python 3** and a USB cable (plug in directly, not through a hub).
  macOS and Linux are tested; Windows is experimental (see below). On macOS without Python,
  `xcode-select --install` provides it.
* This repo: **Code → Download ZIP** on GitHub and unzip it, or
  `git clone https://github.com/at10ti0n/inkpalm5-android11`.
* USB debugging on: Settings → About → tap *Build number* seven times, then Settings → System →
  Developer options → *USB debugging*.

## Quick install (one command)

Connect the device (rooted stock Android 8.1, unlocked) and run:

| | |
|---|---|
| **macOS** | double-click **`Install-InkPalm.command`** in the repo folder (or `python3 install/inkpalm.py` in Terminal) |
| **Linux** | `python3 install/inkpalm.py` |
| **Windows** (experimental) | double-click **`install-windows.bat`** |

It asks before each phase and does, in order:

1. **Downloads** what it needs into `inkpalm-work/` in the repo folder: Google's adb if you have
   none, this project's latest release and phhusson's GSI v313, each checked against a hash.
2. **Checks the device**: root, the firmware build, and that the recovery partition is the one
   this was tested on. If the device is not the tested build it stops before writing anything.
3. **Backs up** every partition to your computer except `private` (the panel calibration, never
   read or written) and data, each copy verified against the device.
4. **Flashes TWRP**, verifies it, reboots into it (allow a few minutes).
5. **Backs up /data** from TWRP to your computer, then wipes data and cache. Your internal
   storage (books, downloads) stays on the device.
6. **Writes Android 11** (system, boot, the vendor files), reading every write back.
7. **Waits for the first boot** (slow, starts in landscape), **configures it**, and reboots.

If anything is interrupted -- a cable, a crash, Ctrl-C -- run it again: it works out where the
device is and continues. Your backup is in `inkpalm-work/backup-<serial>-<date>/`, with a
README on how to restore it.

Options (add after `inkpalm.py`, or after the launcher in a terminal):
`--sf-patch` (SurfaceFlinger freeze workaround) and `--orient-patch` (full-screen KOReader),
see *Known issues*.

**Updating later:** run it again on Android 11. It installs the new release's files and keeps
your settings and lock-screen image (`--first-time` re-applies the defaults).

**Windows:** adb needs a USB driver for each mode of the device (Android, and TWRP which shows up
as USB ID `1f3a:1001`). If the installer waits for the device forever, install the *WinUSB*
driver for it with [Zadig](https://zadig.akeo.ie) (Options → List All Devices). Reports from
Windows users are very welcome.

---

# Manual install (what the installer does, step by step)

You need `adb`, `python3` and `bash` for this route, plus:

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
for p in boot recovery system; do
  adb shell su -c "'dd if=/dev/block/by-name/$p of=/data/local/tmp/$p.img bs=1048576; chmod 644 /data/local/tmp/$p.img; sha256sum /data/local/tmp/$p.img'"
  adb pull /data/local/tmp/$p.img stock-$p.img && adb shell su -c "'rm /data/local/tmp/$p.img'"
done
shasum -a256 stock-*.img       # each must equal the hash the device printed
```
Copy to the device first, then pull: piping `dd` straight out through `adb shell` can alter
binary data on its way to the file. Three files, ~1.5 GB total. **Put them somewhere you will still have them in a year.**
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

## 3. Boot into TWRP

**Easiest, from stock Android with USB connected:**
```
adb reboot recovery
```
This was the working route into recovery throughout development. It asks the bootloader
for recovery (it may also leave a boot request in the `misc` partition, which recovery
clears); it does not touch anything else.

**Or with the buttons** (the timing is finicky, not deterministic):

1. Unplug USB.
2. Hold **Power** alone until the Moaan logo appears, then let go.
3. Press and hold **Volume Up** only, and plug USB in while still holding it.
4. Keep holding until TWRP draws (~20 s). If it stays on the logo, unplug and repeat.

Stuck on the logo either way? Hold **Power + Volume Down** for 15-20 s to force a restart.

Give TWRP 10-20 s after its screen appears, then `adb devices` shows `recovery` and you have a
root shell. If it does not, run `adb kill-server && adb devices` and try another cable/port.

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
installs the three vendor files (display fix, front light, AOD overlay), enables ADB for
the first boot, reboots and waits for Android. It stops with an error rather than continuing
if anything does not match. Writing `system` takes several minutes — leave it alone. (It
also wipes data and cache first if the installer has not recorded a wipe.)

## 6. First boot

**The first boot takes several minutes and comes up in landscape, mirrored-looking and with
touch in the wrong place. That is expected** — step 7 fixes it. Wait for
`adb devices` to show `device`.

## 7. Configure (one command)

```
bash install/from-android.sh ~/inkpalm-assets
```

Installs the key layouts and touch config, the E-Ink tiles app, the Screen Temperature
overlays and SystemUI slider, sets the Quick Settings panel, applies the native configuration
(locked portrait, lock-screen image, 2-minute timeout, Bluetooth and scanning off), sets up
kernel suspend, and reboots. Optional extras are switched on by
prefixing the command: `SF_PATCH=1` and `ORIENT_PATCH=1` (see Known issues). `UPDATE=1`
keeps your settings when re-running it later.

**When it comes back you are done.** Portrait, touch aligned, brightness slider working.

## 8. Apps (optional)

Nothing here is required, it is just what makes it a good reader:

* **[Aurora Store](https://auroraoss.com/)** — Play Store apps without Google. Install its
  APK with `adb install`, then get everything else through it.
* **[Unlauncher](https://github.com/jkuester/unlauncher)** — a text-list launcher. Set it as
  default in Settings → Apps → Default apps → Home app.
* **[EinkBro](https://github.com/plateaukao/einkbro)** — a browser built for E Ink.
* **Kindle** — turn on "Turn pages with volume controls" in its settings to page with the side buttons.
* **[KOReader](https://github.com/koreader/koreader/releases)** — the `arm` APK. It opens in a
  small box unless you use `ORIENT_PATCH=1` (Known issues).

---

## Using it

| | |
|---|---|
| **Brightness** | the **Brightness** slider in Quick Settings. All the way down = light off. |
| **Warmth** | **Screen Temperature** (Android's Night Light, driving the warm LEDs): the tile, the slider under Brightness (all the way to Cool = off), or Settings > Display > Screen Temperature for intensity and a schedule (custom times). |
| **Orientation** | the **Orientation** tile switches portrait/landscape. There is no accelerometer, so Android's auto-rotate does nothing here. |
| **Text / Graphics** | the **Mode** tile — Text is faster and greyer, Graphics is slower and cleaner. Same two modes stock had. |
| **Clear ghosting** | the **Refresh** tile does one full flash. |
| **Page turns** | the side buttons are normal volume keys; turn on the reading app's own option: Kindle's "Turn pages with volume controls" setting, and KOReader's volume-key page-turning setting. |
| **The Moaan logo** | Home, and wakes the device. **Hold it** (about half a second) for one full refresh, like the Refresh tile; turn that off in Settings → Accessibility → "Long-press Home to refresh". |
| **Dark theme** | Android 11's own, works OS-wide: Settings → Display → Dark theme (its tile is left off the panel, and it ghosts heavily). Off by default, and battery saver no longer switches it on. |

## If something goes wrong

**Stuck on the Moaan logo / bootloop.** Force a restart (Power + Volume Down, 15-20 s), get
into TWRP with the button sequence in step 3, then restore:
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
**`MAS_EPD105_L61B807_T09_V03`** (`ro.project.sw.version`; system build `20240320-173513`,
vendor fingerprint `Allwinner/virgo_perf1/virgo-perf1:8.1.0/OPM1.171019.026/20240320-173513`).
Check yours on stock 8.1 with:

```
adb shell getprop ro.project.sw.version
adb shell getprop ro.vendor.build.fingerprint
```

*(Corrected 2026-09-28: earlier versions of this guide said T07 and that the version lives in
vendor.img. `T07_V03` is only the source tag compiled into the vendor's Mali GPU driver, which
T09 did not rebuild; the firmware version is the `ro.project.*` properties in the system
partition. The author's device was updated over the air from T06_V02 to T09_V03.)*

A different version string does **not** automatically mean it won't work — what matters is
whether your stock `boot` and `recovery` partitions match. Rooting changes `boot` (Magisk
patches it), so compare the **unrooted** boot dump (`bimg.img` from the root step) and the
live recovery partition. You can find out **without flashing anything**:

```
shasum -a256 bimg.img
adb shell su -c "'dd if=/dev/block/by-name/recovery bs=4096 | sha256sum'"
```
(The installer checks the recovery partition and the firmware properties for you.)
```
known-good boot (unrooted) 62ce2f881e331303027a1562ec93efebaa49a5700737f8df4e25c86ffcfba83d
known-good recovery        a13a37be5c0e381d0649aac6377967b87946f2cd4cb4c9743292ce1829842b6c
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

* **Occasional SurfaceFlinger freezes** (four on the author's device, 2026-09-17 to 09-21).
  SurfaceFlinger spins on one core, nothing composites, the panel keeps its last image and the
  power button seems dead. The watcher (`tools/sf-watch.sh`, installed and started at every boot)
  saves the evidence and **recovers automatically** by restarting SurfaceFlinger, in about a
  minute, without a reboot; you lose the foreground app's state. The spinning loop was traced to
  a value the thread keeps in a NEON register and trusts forever; a one-instruction workaround for
  it exists. **Opt in with `SF_PATCH=1 bash install/from-android.sh ...`**: it patches your own
  `libsurfaceflinger.so` on your computer (hash-checked) and stages it, and the v2.4 boot image
  mounts it before SurfaceFlinger starts. In service on the author's device since 2026-09-22
  with no freeze since (including one unbroken run of almost 8 days to 2026-10-02), which is still not
  proof; the root cause is not confirmed.
  See [docs/INCIDENT-SF-LIVELOCK.md](docs/INCIDENT-SF-LIVELOCK.md). If a freeze happens to you,
  send the contents of `/data/local/sf-hang/`.
* **KOReader and the stock launcher (Launcher3) open letterboxed** in a small landscape box in
  the middle of the screen. They ask Android for the display's *natural* orientation, and this
  panel is natively landscape (Android rotates it to portrait). **Opt in to the fix with
  `ORIENT_PATCH=1 bash install/from-android.sh ...`**: it patches one method of your own
  `services.jar` on your computer (hash-checked both ways, byte-identical on every machine) so
  that request means "no preference", and the app fills the screen in whatever orientation the
  Orientation tile is set to. Tested on the author's device 2026-10-02, on the stock and the
  standby-trial `services.jar`. If you rotate while KOReader is open it is boxed again until you
  restart it (it declares itself non-resizable). Undo: copy
  `/data/local/services.jar.pre-orient` back over `/system/framework/services.jar`, reboot.
  Without the patch, a list launcher such as Unlauncher avoids it on the home screen.
* **Landscape for a moment at every boot**, before the rotation lock applies.
* **Battery life is not characterised yet.** Kernel suspend works (the installer sets it up
  since v2.5; before that it had to be done by hand). One tester reports about 1% in 12 hours
  asleep; the author's own long-term measurement is pending.
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
