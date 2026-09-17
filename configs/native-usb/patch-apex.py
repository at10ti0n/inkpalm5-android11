#!/usr/bin/env python3
"""Remove PHH's competing ADB service, retaining all APEX and unrelated actions."""
import hashlib
import re
import sys
from pathlib import Path
source, output = map(Path, sys.argv[1:])
data = source.read_text()
# This builder is deliberately scoped to the captured PHH v313 legacy-init RC.
expected = Path(__file__).with_name('apex-input.sha256').read_text().strip()
if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
    raise SystemExit('unexpected apex-setup.rc; re-audit before adapting')
blocks = [
    r'^service adbd_apex /apex/com\.android\.adbd/bin/adbd --root_seclabel=u:r:su:s0\n(?:[ \t]+[^\n]*\n)+',
    r'^on property:sys\.usb\.state=adb\n    restart adbd_apex\n',
    r'^on property:sys\.usb\.state=mtp,adb\n    restart adbd_apex\n',
    r'^    start adbd_apex\n',
]
for pattern in blocks:
    data, n = re.subn(pattern, '', data, flags=re.MULTILINE)
    if n != 1:
        raise SystemExit(f'expected exactly one match, got {n}: {pattern}')
if 'adbd_apex' in data:
    raise SystemExit('unhandled adbd_apex reference')
output.write_text('# EPD105: ADB is owned by boot init service adbd; see native USB notes.\n' + data)
print(hashlib.sha256(output.read_bytes()).hexdigest(), output)
