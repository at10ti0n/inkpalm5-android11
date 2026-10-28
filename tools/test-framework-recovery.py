#!/usr/bin/env python3
"""Exercise the shipped RC's property actions, including stale readiness/crash loops.

This is a small event model, not an Android init parser or an on-device suspend test.
The only accepted commands are the ones used by this RC.
"""
import shlex
from collections import deque
from pathlib import Path

RC = Path(__file__).resolve().parents[1] / "configs/framework-recovery.rc"
rules = []
for raw in RC.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("on "):
        rules.append((line[3:].split(" && "), []))
    else:
        command = shlex.split(line)
        assert command[0] in ("setprop", "write") and len(command) == 3, line
        rules[-1][1].append(command)


class InitModel:
    def __init__(self):
        self.props = {"init.svc.zygote": "running", "init.svc.bootanim": "stopped",
                      "sys.boot_completed": "1"}
        self.time = 0
        self.deadline = 0
        self.acquisitions = 0
        self.releases = 0
        self.event("post-fs-data")

    def event(self, name, value=None):
        queue = deque([(name, value)])
        while queue:
            name, value = queue.popleft()
            if value is not None:
                self.props[name] = value
            for conditions, commands in rules:
                property_conditions = [c[9:].split("=", 1) for c in conditions
                                       if c.startswith("property:")]
                events = [c for c in conditions if not c.startswith("property:")]
                if events:
                    match = events == [name] and value is None
                else:
                    match = any(k == name and v == value for k, v in property_conditions)
                if not match or not all(self.props.get(k) == v for k, v in property_conditions):
                    continue
                for op, target, argument in commands:
                    if op == "setprop":
                        queue.append((target, argument))
                    elif target == "/sys/power/wake_lock":
                        lock, timeout = argument.split()
                        assert lock == "inkpalm_framework_recovery"
                        assert int(timeout) == 900_000_000_000
                        self.deadline = self.time + int(timeout) / 1e9
                        self.acquisitions += 1
                    elif target == "/sys/power/wake_unlock":
                        assert argument == "inkpalm_framework_recovery"
                        self.deadline = 0
                        self.releases += 1
                    else:
                        assert target == "/dev/kmsg"

    def crash(self):
        self.event("init.svc.zygote", "restarting")

    def ready(self):
        self.event("init.svc.zygote", "running")
        self.event("init.svc.bootanim", "running")
        self.event("init.svc.bootanim", "stopped")


checks = 0
def check(condition):
    global checks
    assert condition
    checks += 1


m = InitModel()
check(m.acquisitions == 0)  # Normal cold boot does not take this recovery lock.
m.crash()
check(m.acquisitions == 1 and m.deadline == 900)
check(m.props["sys.inkpalm.fwguard"] == "waiting-animation")
m.event("sys.boot_completed", "1")
m.event("init.svc.bootanim", "stopped")
m.event("init.svc.zygote", "running")
check(m.releases == 0)  # Stale completion cannot release the new episode.
for second in (10, 400, 899, 901, 1800):
    m.time = second
    m.crash()
    m.event("init.svc.zygote", "running")
    check(m.acquisitions == 1 and m.deadline == 900)
check(m.time > m.deadline)  # Kernel expiry is independent of helper/readiness.
m.ready()
check(m.releases == 1 and m.props["sys.inkpalm.fwguard"] == "idle")
m.crash()
check(m.acquisitions == 2 and m.deadline == 2700)  # A new recovered episode.

m = InitModel()
m.crash()
m.event("init.svc.bootanim", "running")
m.event("init.svc.bootanim", "stopped")
check(m.releases == 0)  # Zygote has not restarted yet.
m.event("init.svc.zygote", "running")
check(m.releases == 1)

m = InitModel()
m.event("init.svc.bootanim", "running")
check(m.acquisitions == 1 and m.props["sys.inkpalm.fwguard"] == "animating")
deadline = m.deadline
m.time = 2
m.crash()  # A crash while an animation is already running.
check(m.props["sys.inkpalm.fwguard"] == "animating")
check(m.acquisitions == 1 and m.deadline == deadline)  # The second trigger cannot renew.
m.event("init.svc.zygote", "running")
m.event("init.svc.bootanim", "stopped")
check(m.releases == 1)

m = InitModel()
m.crash()
deadline = m.deadline
for second in (1, 100, 899, 901, 1800):
    m.time = second
    m.event("init.svc.bootanim", "running")
    m.crash()
    m.event("init.svc.bootanim", "stopped")
    check(m.acquisitions == 1 and m.deadline == deadline and m.releases == 0)
print(f"PASS: {checks} recovery guard event checks")

# Exercise the real CLI dispatch with I/O mocked: guard-only installation must
# stage both files, report refusal as failure, and never download release assets.
import contextlib
import importlib.util
import io
import sys
from unittest.mock import patch

root = RC.parents[1]
spec = importlib.util.spec_from_file_location("inkpalm_installer_test", root / "install/inkpalm.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
check({"configs/framework-recovery.rc", "install/device/framework-recovery.sh"}
      <= set(installer.CONFIG_FILES))
with patch.object(sys, "argv", ["inkpalm.py", "framework-recovery", "--yes"]), \
     patch.object(installer, "ensure_adb"), \
     patch.object(installer, "ensure_assets", side_effect=AssertionError("unexpected asset download")), \
     patch.object(installer, "adb", return_value="") as adb_mock, \
     patch.object(installer, "run_device", return_value=True) as run_mock, \
     contextlib.redirect_stdout(io.StringIO()):
    installer.main()
    pushed = {Path(c.args[1]).name for c in adb_mock.call_args_list if c.args[0] == "push"}
    check(pushed == {"framework-recovery.rc", "framework-recovery.sh"})
    check(run_mock.call_args.args[1] == "== framework recovery installed")
    run_mock.return_value = False
    try:
        installer.main()
    except SystemExit as e:
        check(e.code == 1)
    else:
        raise AssertionError("refused installation reported success")
print("PASS: 4 installer integration checks")

# macOS /bin/bash 3.2 treats empty arrays as unset under set -u. Exercise the
# wrapper with and without a serial, using a fake adb so no device is touched.
import os
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as td:
    fake = Path(td) / "adb"
    log = Path(td) / "calls.txt"
    fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FWGUARD_ADB_LOG"\n')
    fake.chmod(0o755)
    env = dict(os.environ, ADB=str(fake), FWGUARD_ADB_LOG=str(log))
    env.pop("INKPALM_SERIAL", None)
    for serial in (None, "TEST-SERIAL"):
        if serial:
            env["INKPALM_SERIAL"] = serial
        log.write_text("")
        subprocess.run(["/bin/bash", str(root / "tools/install-framework-recovery.sh"), "install"],
                       env=env, check=True, capture_output=True)
        calls = log.read_text().splitlines()
        check(calls[0] == ("-s TEST-SERIAL get-state" if serial else "get-state"))
print("PASS: 2 shell wrapper checks")
