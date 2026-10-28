#!/usr/bin/env python3
"""Test the exact-kernel builder against a supplied current boot backup; no writes."""
import importlib.util
from pathlib import Path
import sys

path=Path(__file__).resolve().with_name('patch-vfp.py')
spec=importlib.util.spec_from_file_location('patch_vfp',path)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
a=Path(sys.argv[1]).read_bytes()
b,receipt=m.patch_boot(a)
assert len(a)==len(b)
assert a[:576]==b[:576] and a[596:2048]==b[596:2048]
ro=2048+18169856
assert a[ro:]==b[ro:]
assert m.digest(b[2048:ro])==m.KERNEL_PATCHED
checks=4
for broken in [b,a[:-1],b'BADMAGIC'+a[8:],a[:2048]+bytes([a[2048]^1])+a[2049:],
               a[:576]+bytes([a[576]^1])+a[577:]]:
    try:m.patch_boot(broken)
    except ValueError:checks+=1
    else:raise AssertionError('bad or duplicate patch accepted')
print(f'PASS: {checks} boot packaging/preservation/refusal checks')
