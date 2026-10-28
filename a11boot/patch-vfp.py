#!/usr/bin/env python3
"""Upstream-equivalent VFP hotplug fix for the exact EPD105 flat kernel.

Preserve the supplied boot image's ramdisk and all layout/partition padding.
Backports Linux commit 1328f02005bbbaed15b9d5b7f3ab5ec9d4d5268a.
No device I/O. See docs/INCIDENT-VFP-HOTPLUG.md before installing an output image.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys

KERNEL_ORIGINAL = "c6627f3c80acdfc15c3cad218f9446f2eef409900640309d4e29b650a35c81ea"
KERNEL_PATCHED = "2e3012f238a559016d4e2f2c5ebde1afaea0f4812fcb50da07e1d2169ca87b0a"
OFFSET = 0xFACE8
OLD = bytes.fromhex("0d30a0e17f1dc3e33f10c1e3dfffffeb")
NEW = bytes.fromhex("64300ce315314ce30020a0e3002183e7")

def digest(data):
    return hashlib.sha256(data).hexdigest()

def patch_boot(data):
    if len(data) != 33554432 or data[:8] != b"ANDROID!":
        raise ValueError("Expected a full 32 MiB EPD105 boot partition backup")
    k, ka, r, ra, s, sa, tags, pg, dt, osv = struct.unpack_from("<10I", data, 8)
    if (k, ka, pg, dt, s) != (18169856, 0x40008000, 2048, 0, 0):
        raise ValueError("Different boot/kernel layout; review before adapting")
    if data[-64:-60] == b"AVBf":
        raise ValueError("Unexpected AVB footer")
    align = lambda n: (n + pg - 1) // pg * pg
    ro = pg + align(k)
    if not (0 < r < 8 * 1024 * 1024 and ro + r <= len(data)):
        raise ValueError("Invalid ramdisk size")
    kernel, ramdisk = data[pg:pg+k], data[ro:ro+r]
    kh = digest(kernel)
    if kh == KERNEL_PATCHED:
        raise ValueError("Already patched")
    if kh != KERNEL_ORIGINAL or kernel[OFFSET:OFFSET+16] != OLD:
        raise ValueError("Kernel does not match the reviewed, vulnerable EPD105 build")
    def boot_id(kbytes):
        h = hashlib.sha1()
        for blob in (kbytes, ramdisk, b""):
            h.update(blob); h.update(struct.pack("<I", len(blob)))
        return h.digest()
    if data[576:596] != boot_id(kernel):
        raise ValueError("Existing legacy boot ID does not match its payloads")
    patched_kernel = kernel[:OFFSET] + NEW + kernel[OFFSET+16:]
    if digest(patched_kernel) != KERNEL_PATCHED:
        raise ValueError("Unexpected patched kernel hash")
    result = bytearray(data)
    result[pg+OFFSET:pg+OFFSET+16] = NEW
    result[576:596] = boot_id(patched_kernel)
    allowed = set(range(576,596)) | set(range(pg+OFFSET,pg+OFFSET+16))
    if any(i not in allowed for i,(a,b) in enumerate(zip(data,result)) if a != b):
        raise AssertionError("Unexpected change outside the kernel fix and legacy ID")
    return bytes(result), {"original_boot_sha256":digest(data),
                           "patched_boot_sha256":digest(result),
                           "original_kernel_sha256":kh,
                           "patched_kernel_sha256":KERNEL_PATCHED,
                           "ramdisk_sha256":digest(ramdisk),
                           "kernel_file_offset":pg+OFFSET,
                           "upstream_commit":"1328f02005bbbaed15b9d5b7f3ab5ec9d4d5268a"}

if __name__ == "__main__":
    source, output = map(Path, sys.argv[1:])
    if source.resolve() == output.resolve():
        raise SystemExit("Use a different output path; preserve your original backup")
    try:
        result, receipt = patch_boot(source.read_bytes())
    except ValueError as e:
        raise SystemExit(str(e))
    output.write_bytes(result)
    output.with_suffix(output.suffix+".json").write_text(json.dumps(receipt, indent=2)+"\n")
    print(json.dumps(receipt, indent=2))
