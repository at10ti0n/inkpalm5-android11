#!/usr/bin/env python3
"""patch-sf.py -- one-instruction fix for the SurfaceFlinger EventThread livelock (docs/INCIDENT-SF-LIVELOCK.md).
   python3 patch-sf.py <libsurfaceflinger.so from the phh v313 arm GSI> <out.so>

EventThread::threadMain zero-initialises its per-iteration std::optional<Event> by storing the
NEON pair d8/d9, which the compiler zeroed ONCE before the thread's endless loop and trusts as
callee-saved forever. Whenever the kernel loses that thread's VFP state, the optional's has_value
byte reads garbage on every pass: the event "exists", matches no type, the thread never reaches
its wait, and the EventThread mutex is never released -- the livelock. The store that covers the
has_value byte (0xa0044: vst1.64 {d8,d9},[r0]) becomes `strb.w r1,[sp,#0x88]`, where r1 is the
pending-queue size just loaded at 0xa0040: 0 when empty (the only case where the zero matters),
and overwritten by the pop path's own `has_value = 1` otherwise. Nothing else in the function
reads d8/d9. Refuses any input that is not the known library (sha256 checked)."""
import hashlib, sys
from pathlib import Path
SRC_SHA='4bf68ec57473f69f'; DST_SHA='d8a7132d244ff4b7'   # first 16 hex of sha256
VADDR=0xa0044; FILE_OFF=VADDR-0x1000                       # second LOAD: vaddr 0x606b0 <- offset 0x5f6b0
OLD=bytes.fromhex('00f9cf8a'); NEW=bytes.fromhex('8df88810')
src,dst=Path(sys.argv[1]),Path(sys.argv[2]); b=bytearray(src.read_bytes())
assert hashlib.sha256(b).hexdigest().startswith(SRC_SHA), 'not the known libsurfaceflinger.so (phh v313 arm)'
assert b[FILE_OFF:FILE_OFF+4]==OLD; b[FILE_OFF:FILE_OFF+4]=NEW
assert hashlib.sha256(b).hexdigest().startswith(DST_SHA); dst.write_bytes(b); print('wrote',dst,'sha256',hashlib.sha256(b).hexdigest())
