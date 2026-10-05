#!/usr/bin/env python3
"""All-in-one installer for Android 11 on the Moaan InkPalm 5 Pro Mini (EPD105).

Run it with the device connected over USB; it works out where the device is and does the
next step, so you can stop and run it again at any point:

    python3 install/inkpalm.py                 # macOS / Linux  (or double-click Install-InkPalm.command)
    py -3 install\\inkpalm.py                   # Windows        (or double-click install-windows.bat)

On rooted stock Android 8.1 it: checks the firmware, backs up the partitions to your
computer, flashes TWRP, reboots into it, backs up /data, wipes, writes Android 11, waits for
the first boot and configures it. On Android 11 it updates the configuration only, keeping
your settings (--first-time re-applies the one-time defaults).

It downloads what it needs into ./inkpalm-work: Google's platform-tools (adb) if adb is not
installed, the latest release of this project and phhusson's GSI v313, each hash-checked.

Options:
  --sf-patch        stage the SurfaceFlinger freeze workaround (patch-sf.py)
  --no-orient-patch skip the full-screen fix for KOReader / Launcher3 (patch-orientation.py;
                    on by default since 2026-10-05)
  --assets DIR      use release files already downloaded (must include SHA256SUMS)
  --gsi FILE        use a GSI .img or .img.xz you already have
  --first-time      on Android 11: also re-apply the one-time defaults
  --yes             do not ask before each phase
Single phases (normally chosen automatically): check, backup, flash-twrp, twrp-install, configure.

Nothing ever writes the `private` partition (your panel's calibration) and it is not read.
"""
import argparse, datetime, hashlib, json, lzma, os, platform, shutil, subprocess, sys, tempfile
import time, urllib.request, zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(REPO, "inkpalm-work")
GH_REPO = "at10ti0n/inkpalm5-android11"
GSI_URL = "https://github.com/phhusson/treble_experimentations/releases/download/v313/system-roar-arm-aonly-vanilla.img.xz"
GSI_XZ_SHA = "b2f1b320e8babd352808714616cfd7996428bd7130e4430b3df9aeefe372f797"
SYSTEM_SIZE = 1375731712                   # EPD105 system partition, bytes
FIRMWARE = "MAS_EPD105_L61B807_T09_V03"    # ro.project.sw.version of the tested build
VENDOR_FP = "Allwinner/virgo_perf1/virgo-perf1:8.1.0/OPM1.171019.026/20240320-173513"
STOCK_RECOVERY = "a13a37be5c0e381d0649aac6377967b87946f2cd4cb4c9743292ce1829842b6c"
STOCK_BOOT = "62ce2f881e331303027a1562ec93efebaa49a5700737f8df4e25c86ffcfba83d"
BACKUP_PARTS = ["boot", "recovery", "system", "vendor", "misc", "env", "bootloader", "dto",
                "metadata", "frp", "cache", "media_data", "empty"]   # never "private" or data
NEED = ["boot-android11-epd105.img", "twrp-epd105.img", "libhwcflip.so", "lights.virgo.so",
        "inkpalm-aod.apk", "einktile.apk"]
CONFIG_FILES = ["configs/sunxi-gpadc0.kl", "configs/sunxi-keyboard.kl", "configs/pmu1736-powerkey.kl",
                "configs/Vendor_dead_Product_beef.kl", "configs/Vendor_dead_Product_beef.idc",
                "configs/a11-boot-fixups.sh", "configs/configure-native.sh",
                "configs/android.system.suspend@1.0-service.rc", "configs/zz-inkpalm-profiles.rc",
                "tools/sf-watch.sh",
                "tools/sf-capture.sh", "docs/images/standby.png", "install/device/configure.sh"]
OPTIONAL_ASSETS = ["libwpaexit.so", "inkpalm-nomodem.apk", "inkpalm-screentemp-fw.apk",
                   "inkpalm-screentemp-settings.apk", "inkpalm-screentemp-systemui.apk",
                   "inkpalm-power.apk", "SystemUI-warmth.apk", "libsffencefinish.so", "libhwcflip.so"]
WIN = platform.system() == "Windows"
ADB = "adb"
ARGS = None

# ---------------------------------------------------------------- output and prompts
def say(msg): print(f"\n== {msg}", flush=True)
def info(msg): print(f"   {msg}", flush=True)
def die(msg):
    print(f"\nSTOPPED: {msg}", flush=True)
    print("Nothing after this point was done. Fix the cause and run the installer again.")
    sys.exit(1)
def confirm(q):
    if ARGS.yes: return
    try: a = input(f"\n{q} [y/N] ").strip().lower()
    except EOFError: a = ""
    if a not in ("y", "yes"): die("cancelled")
def pause(msg):
    if ARGS.yes: return
    try: input(f"\n{msg}\nPress Enter when done... ")
    except EOFError: pass

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()

# ---------------------------------------------------------------- state (resume)
def state_path(): return os.path.join(WORK, "state.json")
def load_state():
    try: return json.load(open(state_path()))
    except Exception: return {}
def save_state(**kv):
    s = load_state(); s.update(kv)
    os.makedirs(WORK, exist_ok=True)
    json.dump(s, open(state_path(), "w"), indent=1)

# ---------------------------------------------------------------- downloads
def download(url, dest):
    tmp = dest + ".part"
    info(f"downloading {os.path.basename(dest)}")
    # curl ships with macOS, Linux and Windows 10+, and uses the system's certificates (a
    # python.org install on macOS often has none until "Install Certificates" is run).
    if shutil.which("curl"):
        r = subprocess.run(["curl", "-fL", "--progress-bar", "--retry", "3", "-o", tmp, url])
        if r.returncode != 0: die(f"download failed: {url}")
    else:
        try: urllib.request.urlretrieve(url, tmp)
        except Exception as e: die(f"download failed: {url} ({e})")
    os.replace(tmp, dest)

def ensure_adb():
    global ADB
    if os.environ.get("ADB"): ADB = os.environ["ADB"]; return
    if shutil.which("adb"): ADB = shutil.which("adb"); return
    pt = os.path.join(WORK, "platform-tools", "adb.exe" if WIN else "adb")
    if not os.path.exists(pt):
        say("getting adb (Google's platform-tools)")
        osname = {"Darwin": "darwin", "Windows": "windows"}.get(platform.system(), "linux")
        z = os.path.join(WORK, "platform-tools.zip")
        os.makedirs(WORK, exist_ok=True)
        download(f"https://dl.google.com/android/repository/platform-tools-latest-{osname}.zip", z)
        with zipfile.ZipFile(z) as zf: zf.extractall(WORK)
        os.remove(z)
        if not WIN:
            for f in ("adb", "fastboot"):
                p = os.path.join(WORK, "platform-tools", f)
                if os.path.exists(p): os.chmod(p, 0o755)
    ADB = pt

def ensure_assets():
    if ARGS.assets: d = os.path.abspath(ARGS.assets)
    else:
        say("getting the latest release of this project")
        api = f"https://api.github.com/repos/{GH_REPO}/releases/latest"
        meta = os.path.join(WORK, "release.json")
        os.makedirs(WORK, exist_ok=True)
        download(api, meta)
        rel = json.load(open(meta))
        d = os.path.join(WORK, "release-" + rel["tag_name"])
        os.makedirs(d, exist_ok=True)
        for a in rel["assets"]:
            p = os.path.join(d, a["name"])
            if not (os.path.exists(p) and os.path.getsize(p) == a["size"]):
                download(a["browser_download_url"], p)
    sums = os.path.join(d, "SHA256SUMS")
    if not os.path.exists(sums): die(f"no SHA256SUMS in {d}")
    for line in open(sums):
        want, name = line.split()
        p = os.path.join(d, name)
        if not os.path.exists(p): die(f"release file missing: {name}")
        if sha256(p) != want: die(f"{name} does not match SHA256SUMS (delete it and run again)")
    for n in NEED:
        if not os.path.exists(os.path.join(d, n)): die(f"release folder lacks {n}")
    info(f"release files verified ({d})")
    return d

def ensure_gsi():
    """Return the path of the GSI padded to the system partition size."""
    padded = os.path.join(WORK, "system-gsi-padded.img")
    if os.path.exists(padded) and os.path.getsize(padded) == SYSTEM_SIZE and load_state().get("gsi_padded_sha") == sha256(padded):
        return padded
    src = ARGS.gsi
    if not src:
        src = os.path.join(WORK, "system-roar-arm-aonly-vanilla.img.xz")
        if not os.path.exists(src) or sha256(src) != GSI_XZ_SHA:
            say("getting phhusson's GSI v313 (arm, a-only, vanilla), about 400 MB")
            download(GSI_URL, src)
        if sha256(src) != GSI_XZ_SHA: die("the GSI download does not match the expected hash")
    say("preparing the GSI (unpack and pad to the system partition size)")
    opener = lzma.open if src.endswith(".xz") else open
    n = 0
    with opener(src, "rb") as f, open(padded + ".part", "wb") as o:
        for b in iter(lambda: f.read(1 << 20), b""): o.write(b); n += len(b)
        if n > SYSTEM_SIZE: die(f"GSI is {n} bytes, larger than the system partition")
        o.write(b"\0" * (SYSTEM_SIZE - n))
    os.replace(padded + ".part", padded)
    save_state(gsi_padded_sha=sha256(padded))
    info(f"GSI ready ({n} bytes, padded to {SYSTEM_SIZE})")
    return padded

# ---------------------------------------------------------------- adb
def adb(*a, check=True, timeout=None, quiet=False):
    r = subprocess.run([ADB, *a], capture_output=True, text=True, timeout=timeout)
    out = (r.stdout or "").replace("\r", "")
    if check and r.returncode != 0:
        die(f"adb {' '.join(a[:2])} failed: {(r.stderr or out).strip()[:300]}")
    return out.strip()
def run_device(cmd, marker):
    """Run a device-side script, echo its output, and require its final marker line (adb's exit
    status is not reliable across adbd versions)."""
    p = subprocess.Popen([ADB, "shell", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    ok = False
    for line in p.stdout:
        line = line.replace("\r", "").rstrip("\n"); print(line, flush=True)
        if line.strip() == marker: ok = True
    p.wait()
    return ok
def adb_stream(*a):  # long transfers: show adb's own progress
    if subprocess.run([ADB, *a]).returncode != 0: die(f"adb {' '.join(a[:2])} failed")
def state():
    r = subprocess.run([ADB, "get-state"], capture_output=True, text=True)
    s = (r.stdout or "").strip()
    if not s and "unauthorized" in (r.stderr or ""): return "unauthorized"
    return s or "none"
def shell(cmd, **k): return adb("shell", cmd, **k)
def root(cmd, **k):
    assert "'" not in cmd, cmd
    return adb("shell", f"su -c '{cmd}'", **k)
def prop(p): return shell(f"getprop {p}", check=False)

def wait_for(target, minutes, hint):
    """Wait until adb reports `target` (device / recovery); explain if it is slow."""
    t0, told = time.time(), False
    while time.time() - t0 < minutes * 60:
        s = state()
        if s == target: return
        if s == "unauthorized" and not told:
            info("the device asks to allow USB debugging: tick 'always allow' and tap Allow"); told = True
        if time.time() - t0 > 90 and not told:
            info(hint); told = True
        time.sleep(3)
    die(f"the device did not appear as '{target}' within {minutes} minutes. " + usb_help())

def usb_help():
    if WIN:
        return ("On Windows, adb needs a USB driver for each mode of this device. Install the "
                "WinUSB driver for it with Zadig (https://zadig.akeo.ie, Options > List All "
                "Devices), then run again.")
    return "Try another cable or USB port, plug in directly (no hub), then run again."

def wait_booted(minutes):
    wait_for("device", minutes, "Android is still starting; the first boot can take 10 minutes.")
    t0 = time.time()
    while time.time() - t0 < minutes * 60:
        if shell("getprop sys.boot_completed", check=False) == "1": return
        time.sleep(5)
    die("Android did not finish booting in time")

def where():
    s = state()
    if s == "recovery":
        return "twrp" if shell("which twrp", check=False) else "recovery-other"
    if s == "device":
        rel = prop("ro.build.version.release")
        return {"8.1.0": "stock", "11": "a11"}.get(rel, "android-" + rel)
    return s

# ---------------------------------------------------------------- phases
def check_stock():
    say("checking the device")
    sw, fp = prop("ro.project.sw.version"), prop("ro.vendor.build.fingerprint")
    info(f"firmware {sw or '?'}; vendor {fp or '?'}")
    if "uid=0" not in root("id", check=False):
        die("no root. This needs rooted stock Android 8.1 (INSTALL.md, 'What you need'). If a "
            "Magisk prompt appeared on the device, tap Grant and run again.")
    rec = root("dd if=/dev/block/by-name/recovery bs=1048576 2>/dev/null | sha256sum").split()[0]
    twrp = sha256(os.path.join(ARGS.assets_dir, "twrp-epd105.img"))
    if sw != FIRMWARE or fp != VENDOR_FP:
        info(f"this is not the tested firmware ({FIRMWARE}).")
        if rec != STOCK_RECOVERY and rec != twrp:
            die("both the firmware and the recovery partition differ from the tested device. "
                "Please open an issue with these two values instead of installing: "
                f"{sw} / recovery {rec}")
        confirm("The recovery partition matches the tested one. Continue anyway?")
    info("recovery: " + ("stock (tested)" if rec == STOCK_RECOVERY else "TWRP already" if rec == twrp else f"unknown {rec[:16]}"))
    save_state(serial=adb("get-serialno"), firmware=sw, recovery=rec)

def pull_partition(p, dest_dir, twrp=False):
    tmp = f"/data/local/tmp/inkpalm-bk-{p}.img" if not twrp else f"/tmp/inkpalm-bk-{p}.img"
    run = shell if twrp else root
    dev = run(f"dd if=/dev/block/by-name/{p} of={tmp} bs=1048576 2>/dev/null; chmod 644 {tmp}; sha256sum {tmp}").split()[0]
    out = os.path.join(dest_dir, p + ".img")
    adb("pull", tmp, out)
    run(f"rm -f {tmp}")
    if sha256(out) != dev: die(f"backup of {p} did not verify (copy differs from the device)")
    return dev

def backup():
    serial = adb("get-serialno")
    d = os.path.join(WORK, f"backup-{serial[-6:]}-{datetime.date.today().isoformat()}")
    os.makedirs(d, exist_ok=True)
    say(f"backing up the partitions to {d}")
    info("not read or written: 'private' (the panel calibration) and 'UDISK' (data, backed up from TWRP later)")
    free = root("df /data | tail -1").split()
    if len(free) > 3 and free[3].isdigit() and int(free[3]) < 1500000:
        die("the device needs 1.5 GB free on internal storage for the backup (one partition at a time)")
    sums = []
    for p in BACKUP_PARTS:
        h = pull_partition(p, d)
        sums.append(f"{h}  {p}.img")
        info(f"{p}: verified")
    open(os.path.join(d, "SHA256SUMS"), "w").write("\n".join(sums) + "\n")
    open(os.path.join(d, "README.txt"), "w").write(
        "Backup made by install/inkpalm.py before installing Android 11.\n"
        "Restore from TWRP: adb push <p>.img /sdcard/ then\n"
        "adb shell \"dd if=/sdcard/<p>.img of=/dev/block/by-name/<p> bs=1048576 && sync\"\n"
        "for boot, system and vendor (and recovery last, if you want stock recovery back).\n"
        "/data is in twrp-data/; restore with: adb push twrp-data /sdcard/TWRP/BACKUPS/<serial>/stock-data\n"
        "then adb shell \"twrp restore stock-data\".\n")
    save_state(backup_dir=d, backup_done=True)

def flash_twrp():
    say("flashing TWRP into the recovery partition")
    img = os.path.join(ARGS.assets_dir, "twrp-epd105.img")
    want = sha256(img)
    adb("push", img, "/data/local/tmp/twrp-epd105.img")
    root("dd if=/data/local/tmp/twrp-epd105.img of=/dev/block/by-name/recovery bs=4096 && sync; rm -f /data/local/tmp/twrp-epd105.img")
    got = root(f"dd if=/dev/block/by-name/recovery bs=4096 count={os.path.getsize(img) // 4096} 2>/dev/null | sha256sum").split()[0]
    if got != want: die("TWRP read-back does not match. Do NOT reboot; run the installer again to rewrite it.")
    info("TWRP written and verified")
    save_state(twrp_flashed=True)

def to_twrp():
    say("rebooting into TWRP")
    adb("reboot", "recovery", check=False)
    info("this can take a few minutes before TWRP shows up on USB")
    wait_for("recovery", 10, "still waiting for TWRP (it can take several minutes)...")
    time.sleep(5)
    if where() != "twrp": die("the device is in a recovery that is not TWRP")

def twrp_data_backup():
    s = load_state(); d = s.get("backup_dir")
    if not d: die("no backup folder recorded; run the backup phase first")
    name = "stock-data"
    say("backing up /data from TWRP (your apps and settings; internal storage is kept on the device)")
    shell(f"twrp backup D {name}", timeout=3600)
    folder = shell(f"ls -d /sdcard/TWRP/BACKUPS/*/{name}", check=False).splitlines()
    if not folder: die("TWRP did not create the /data backup")
    out = os.path.join(d, "twrp-data")
    adb("pull", folder[0], out)
    for f in os.listdir(out):
        if f.endswith(".md5"):
            want = open(os.path.join(out, f)).read().split()[0]
            h = hashlib.md5()
            with open(os.path.join(out, f[:-4]), "rb") as g:
                for b in iter(lambda: g.read(1 << 20), b""): h.update(b)
            if h.hexdigest() != want: die(f"/data backup file {f[:-4]} did not verify")
    info("/data backup copied and verified")
    save_state(data_backup_done=True)

def twrp_install():
    gsi = ensure_gsi()
    if not load_state().get("wiped"):
        confirm("Wipe /data and /cache now? (Your internal storage -- books, downloads -- stays.)")
        say("wiping data and cache")
        shell("twrp wipe data"); shell("twrp wipe cache")
        save_state(wiped=True)
    say("copying Android 11 to the device")
    st = "/sdcard/inkpalm"
    shell(f"rm -rf {st}; mkdir -p {st}")
    files = {"system.img": gsi, "boot.img": os.path.join(ARGS.assets_dir, "boot-android11-epd105.img")}
    for n in ("libhwcflip.so", "lights.virgo.so", "inkpalm-aod.apk"): files[n] = os.path.join(ARGS.assets_dir, n)
    sums = tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt")
    for n, p in files.items(): sums.write(f"{sha256(p)}  {n}\n")
    sums.close()
    for n, p in files.items(): adb_stream("push", p, f"{st}/{n}")
    adb("push", sums.name, f"{st}/SHA256SUMS"); os.unlink(sums.name)
    adb("push", os.path.join(REPO, "install", "device", "twrp-install.sh"), f"{st}/twrp-install.sh")
    say("writing Android 11 (several minutes; leave the device alone)")
    ok = run_device(f"sh {st}/twrp-install.sh {st}", "== install finished")
    shell(f"rm -rf {st}", check=False)
    if not ok: die("the install step failed on the device (see above). Do not reboot; run again.")
    save_state(installed=True)
    say("first boot of Android 11 (slow, and it starts in landscape; that is expected)")
    adb("reboot", check=False)
    wait_booted(20)

def configure(first_time):
    say("configuring Android 11" + (" (first time)" if first_time else " (update: your settings are kept)"))
    if "uid=0" not in root("id", check=False): die("root (su) is not available on Android 11")
    st = "/data/local/tmp/inkpalm"
    root(f"rm -rf {st}; mkdir -p {st}; chmod 777 {st}")
    for f in CONFIG_FILES: adb("push", os.path.join(REPO, f), f"{st}/")
    for f in ["einktile.apk", *OPTIONAL_ASSETS]:
        p = os.path.join(ARGS.assets_dir, f)
        if os.path.exists(p): adb("push", p, f"{st}/")
    regs = os.path.join(REPO, "tools", "threadregs.bin")
    if os.path.exists(regs): adb("push", regs, f"{st}/")
    t = tempfile.mkdtemp()
    try:
        if ARGS.sf_patch:
            say("SurfaceFlinger freeze workaround: patching your libsurfaceflinger.so")
            adb("pull", "/system/lib/libsurfaceflinger.so", os.path.join(t, "sf.so"))
            r = subprocess.run([sys.executable, os.path.join(REPO, "a11boot", "patch-sf.py"),
                                os.path.join(t, "sf.so"), os.path.join(t, "libsurfaceflinger-patched.so")])
            if r.returncode == 0: adb("push", os.path.join(t, "libsurfaceflinger-patched.so"), f"{st}/")
            elif r.returncode == 2: info("already in service")
            else: info("SKIPPED (this library is not the reviewed build)")
        if ARGS.orient_patch:
            say("full-screen apps: patching your services.jar")
            root(f"cp /system/framework/services.jar {st}/cur.jar; chmod 644 {st}/cur.jar")
            adb("pull", f"{st}/cur.jar", os.path.join(t, "cur.jar"))
            out = os.path.join(t, "services-orient.jar")
            r = subprocess.run([sys.executable, os.path.join(REPO, "framework", "patch-orientation.py"),
                                os.path.join(t, "cur.jar"), out])
            if r.returncode == 0:
                open(out + ".sha256", "w").write(sha256(out))
                adb("push", out, f"{st}/"); adb("push", out + ".sha256", f"{st}/")
            elif r.returncode == 2: info("already installed")
            else: info("SKIPPED (this services.jar is not a reviewed build)")
    finally:
        shutil.rmtree(t, ignore_errors=True)
    env = "FIRST_TIME=1 " if first_time else ""
    ok = run_device(f"su -c '{env}sh {st}/configure.sh {st}'", "== configuration finished")
    root(f"rm -rf {st}", check=False)
    if not ok: die("configuration failed on the device (see above)")
    save_state(configured=True)
    say("rebooting to apply everything")
    root("sync; reboot", check=False)
    time.sleep(10)
    wait_booted(10)
    rot = shell("settings get system user_rotation", check=False)
    info("portrait: " + ("yes" if rot == "1" else f"user_rotation={rot}"))

APEX_RC = "/system/etc/init/apex-setup.rc"
APEX_ORIG = "edb1f2cfb75da475f0018201fed77b87cbf1020d7d525aa69a36eceb6dd95af6"   # phh v313
APEX_PATCHED = "bb4e0ac6bc2e8c0ec9b18e7faa885bef025f8d49b4bd6ce9c60cdb25ffa5808f"  # tested result

def native_adb():
    """Switch ADB from phh's fallback daemon to the init-managed adbd, so `adb root` and
    reconnects work (docs/NATIVE-A11-SECOND-PASS.md). Armed with the tested rollback: unless
    this computer confirms ADB within 120 s of the next boot, the device restores the old
    setup and reboots by itself."""
    say("native ADB (init-managed adbd)")
    cur = root(f"sha256sum {APEX_RC}").split()[0]
    link = root("readlink /system/bin/adbd", check=False)
    if cur == APEX_PATCHED and link == "/apex/com.android.adbd/bin/adbd":
        info("already installed"); return
    if cur != APEX_ORIG:
        info(f"SKIPPED -- {APEX_RC} is not the PHH v313 original ({cur[:16]}); ADB stays as it is"); return
    t = tempfile.mkdtemp(); st = "/data/local/tmp/inkpalm-usb"
    try:
        root(f"rm -rf {st}; mkdir -p {st}; cp {APEX_RC} {st}/orig.rc; chmod 644 {st}/orig.rc")
        adb("pull", f"{st}/orig.rc", os.path.join(t, "orig.rc"))
        out = os.path.join(t, "apex-setup.rc.patched")
        r = subprocess.run([sys.executable, os.path.join(REPO, "configs", "native-usb", "patch-apex.py"),
                            os.path.join(t, "orig.rc"), out], capture_output=True, text=True)
        if r.returncode != 0 or sha256(out) != APEX_PATCHED:
            info("SKIPPED -- the patch did not produce the tested file; ADB stays as it is"); return
        open(out + ".sha256", "w").write(APEX_PATCHED)
        for f in (out, out + ".sha256", os.path.join(REPO, "configs", "native-usb", "boot-trial.sh"),
                  os.path.join(REPO, "configs", "native-usb", "rollback.sh"),
                  os.path.join(REPO, "install", "device", "native-adb.sh")):
            adb("push", f, f"{st}/")
    finally:
        shutil.rmtree(t, ignore_errors=True)
    if not run_device(f"su -c 'sh {st}/native-adb.sh {st}'", "== native ADB staged"):
        root(f"rm -rf {st}", check=False)
        die("native ADB staging failed on the device (see above); nothing was switched")
    root(f"rm -rf {st}", check=False)
    info("rebooting; the device restores the old ADB by itself if the new one does not come up")
    root("sync; reboot", check=False)
    time.sleep(15)
    t0 = time.time(); ok = False
    while time.time() - t0 < 300:
        if state() == "device" and "uid=0" in root("id", check=False):
            ok = True; break
        time.sleep(3)
    if ok:
        root("touch /data/local/stock-second-pass/usb-accepted")
        for _ in range(30):
            if root("cat /data/local/stock-second-pass/usb-status", check=False) == "accepted": break
            time.sleep(2)
        n = root("ps -A -o ppid,comm | grep -c \"^ *1 adbd\"", check=False)
        info(f"native ADB accepted (init-managed adbd: {n}); `adb root` now restarts it cleanly")
    else:
        info("native ADB did not come up; the device rolls back by itself and reboots. Waiting...")
        wait_booted(15)
        die("native ADB was rolled back automatically; your old ADB is back. Please report this.")

# ---------------------------------------------------------------- main
def main():
    global ARGS
    ap = argparse.ArgumentParser(description="InkPalm 5 Pro Mini: Android 11 installer")
    ap.add_argument("phase", nargs="?", default="auto",
                    choices=["auto", "check", "backup", "flash-twrp", "twrp-install", "configure", "native-adb"])
    ap.add_argument("--assets"); ap.add_argument("--gsi")
    ap.add_argument("--sf-patch", action="store_true")
    ap.add_argument("--orient-patch", dest="orient_patch", action="store_true", default=True, help=argparse.SUPPRESS)
    ap.add_argument("--no-orient-patch", dest="orient_patch", action="store_false")
    ap.add_argument("--first-time", action="store_true"); ap.add_argument("--yes", action="store_true")
    ARGS = ap.parse_args()
    print("InkPalm 5 Pro Mini -- Android 11 installer. Read INSTALL.md first; this rewrites your device.")
    ensure_adb()
    adb("start-server", check=False)
    ARGS.assets_dir = ensure_assets()
    s = load_state()

    if ARGS.phase != "auto":
        {"check": check_stock, "backup": backup, "flash-twrp": flash_twrp,
         "twrp-install": twrp_install, "native-adb": native_adb,
         "configure": lambda: configure(ARGS.first_time)}[ARGS.phase]()
        return

    say("looking for the device")
    wait_for_any()
    w = where()
    info({"stock": "rooted? stock Android 8.1", "a11": "Android 11", "twrp": "TWRP"}.get(w, w))
    if w == "stock":
        check_stock()
        confirm("Back up this device, flash TWRP and install Android 11?")
        if not s.get("backup_done"): backup()
        flash_twrp()
        to_twrp(); w = "twrp"
    if w == "twrp":
        s = load_state()
        if not s.get("backup_dir"): die("no partition backup on record. Boot back to stock Android and run again.")
        if not s.get("data_backup_done"): twrp_data_backup()
        twrp_install()
        configure(first_time=True)
        native_adb()
    elif w == "a11":
        configure(first_time=ARGS.first_time or not s.get("configured") and s.get("installed", False))
        native_adb()
    else:
        die(f"don't know what to do with the device in state '{w}'. " + usb_help())
    say("done")
    print("Portrait, touch aligned, Brightness and Screen Temperature in Quick Settings.")
    print("Hold the Moaan logo for a full refresh. Your backup is in", load_state().get("backup_dir", "(none)"))

def wait_for_any():
    t0, told = time.time(), False
    while state() not in ("device", "recovery"):
        if state() == "unauthorized" and not told:
            info("allow USB debugging on the device (tick 'always allow')"); told = True
        if time.time() - t0 > 30 and not told:
            info("no device yet: connect it with USB debugging on. " + usb_help()); told = True
        if time.time() - t0 > 600: die("no device found")
        time.sleep(2)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: die("interrupted -- run again to continue where it stopped")
