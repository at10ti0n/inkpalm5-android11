#!/usr/bin/env python3
"""Stop Android 11 letterboxing apps that ask for the display's natural orientation.

WindowContainer.getRequestedConfigurationOrientation() maps screenOrientation="nosensor"
(5) to DisplayContent.getNaturalOrientation(). This panel is natively 1280x720 and runs
rotated to portrait, so natural = landscape, and apps such as KOReader and Launcher3 are
letterboxed into a 720x405 box. On a device with no sensors, "nosensor" asks for nothing
that differs from "unspecified", so the branch now returns ORIENTATION_UNDEFINED (0): the
app takes whatever orientation the user chose. getNaturalOrientation() has no other caller.

Bytecode, in place (same length; the dex is STORED in the jar, so only the dex header
checksums and the zip CRCs change -- byte-identical output on any machine):
    iget-object v0, p0, mDisplayContent   54 20 ....
    if-eqz v0, :cond_3                    38 00 ....
    invoke-virtual {v0}, getNatural...    6e 10 .... 00 00
    move-result v0                        0a 00
    return v0                             0f 00
becomes  const/4 v0, 0 ; return v0 ; 7 x nop.

Usage: patch-orientation.py <services.jar> <out.jar>
Accepts only the reviewed inputs below and checks the output hash. Exit 2: already patched."""
import hashlib, re, struct, sys, zlib

INPUTS = {  # input sha256 -> expected output sha256
    "ac34b0f57e09fc32ff1e024736f7114e30464c973406e0a3204cd1d5848518d4":
        "a3908eb6be1edd7fe0995e839722873312a58e9f8206d7fe7f51607d7af58a5a",  # PHH v313 stock
    "a198a9b9d9b5ad1bea8800bc3428d00b48f1f0667e10954ce8ce749437af7eca":
        "6ea3d702326677839c10f4ee1ed8e49456f29cd87139f2433b5758ec5be83133",  # + standby trial
}
# Preceded by: iget v0,p0,mOrientation / const/4 v1,5 / if-ne v0,v1; followed by const/16 v1,0xe
PAT = re.compile(rb"\x52\x20..\x12\x51\x33\x10..(\x54\x20..\x38\x00..\x6e\x10..\x00\x00\x0a\x00\x0f\x00)\x13\x01\x0e\x00", re.S)
NEW = b"\x12\x00\x0f\x00" + b"\x00\x00" * 7

def die(m): sys.exit("patch-orientation: " + m)

src, dst = sys.argv[1], sys.argv[2]
jar = bytearray(open(src, "rb").read())
h = hashlib.sha256(jar).hexdigest()
if h in INPUTS.values(): print("already patched"); sys.exit(2)
if h not in INPUTS: die(f"unreviewed services.jar {h}")

# Walk the central directory to find the STORED dex entries.
eocd = jar.rfind(b"PK\x05\x06")
n, cd_size, cd_off = struct.unpack_from("<HII", jar, eocd + 10)
hits, p = [], cd_off
for _ in range(n):
    (sig, _, _, _, method, _, _, crc, csz, usz, nl, el, cl, _, _, _, lho) = struct.unpack_from("<IHHHHHHIIIHHHHHII", jar, p)
    name = bytes(jar[p + 46:p + 46 + nl]).decode()
    if name.endswith(".dex"):
        if method != 0: die(f"{name} is compressed")
        lnl, lel = struct.unpack_from("<HH", jar, lho + 26)
        data = lho + 30 + lnl + lel
        for m in PAT.finditer(bytes(jar[data:data + usz])):
            hits.append((name, p, lho, data, usz, m.start(1)))
    p += 46 + nl + el + cl
if len(hits) != 1: die(f"expected the pattern once, found {len(hits)}")
name, cdp, lho, data, usz, off = hits[0]
jar[data + off:data + off + len(NEW)] = NEW
dex = memoryview(jar)[data:data + usz]
dex[12:32] = hashlib.sha1(dex[32:]).digest()                       # dex signature
struct.pack_into("<I", dex, 8, zlib.adler32(dex[12:]) & 0xffffffff)  # dex checksum
crc = zlib.crc32(dex) & 0xffffffff
struct.pack_into("<I", jar, lho + 14, crc)                          # local header CRC
struct.pack_into("<I", jar, cdp + 16, crc)                          # central directory CRC
out = hashlib.sha256(jar).hexdigest()
if INPUTS[h] and out != INPUTS[h]: die(f"output {out} is not the reviewed {INPUTS[h]}")
open(dst, "wb").write(jar)
print(f"patched {name} at 0x{off:x}; wrote {dst} sha256 {out}")
