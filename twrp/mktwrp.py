#!/usr/bin/env python3
"""mktwrp.py -- build the EPD105 TWRP image from YOUR stock recovery.img.
   python3 mktwrp.py <stock-recovery.img> <out-recovery.img>
Uses your stock recovery's kernel and header (byte-for-byte), our TWRP ramdisk
(twrp-epd105-ramdisk.cpio.gz: TWRP 3.7 + by-name links + libepdfix display/touch preload),
and re-adds the panel waveform fallback (/system/default.bin) FROM YOUR OWN stock ramdisk --
that file is E Ink's calibration data and is deliberately not shipped here."""
import gzip, hashlib, struct, sys
from pathlib import Path
STOCK_SHA='a13a37be5c0e381d0649aac6377967b87946f2cd4cb4c9743292ce1829842b6c'   # EPD105 stock recovery
src,dst=Path(sys.argv[1]),Path(sys.argv[2]); here=Path(__file__).resolve().parent
d=src.read_bytes(); assert hashlib.sha256(d).hexdigest()==STOCK_SHA, 'not the known EPD105 stock recovery.img'
k,ka,r,ra,s,sa,t,pg,hv,ov=struct.unpack_from('<10I',d,8); ro=pg+((k+pg-1)//pg)*pg; kernel=d[pg:pg+k]; scpio=gzip.decompress(d[ro:ro+r])
def parse(buf):
    out=[]; i=0
    while True:
        f=[int(buf[i+6+8*j:i+14+8*j],16) for j in range(13)]; ns=i+110; name=buf[ns:ns+f[11]-1].decode(); ds=(ns+f[11]+3)&~3
        out.append((name,buf[i:ds+f[6]],buf[ds:ds+f[6]])); i=(ds+f[6]+3)&~3
        if name=='TRAILER!!!': return out
wf=next(data for n,raw,data in parse(scpio) if n=='system/default.bin'); assert len(wf)>1_000_000
ours=parse(gzip.decompress((here/'twrp-epd105-ramdisk.cpio.gz').read_bytes()))
body=b''.join(raw for n,raw,_ in ours[:-1]); trailer=ours[-1][1]
nm=b'system/default.bin\0'; hdr=b'070701'+''.join('%08x'%v for v in (0x7fff0,0o100644,0,0,1,0,len(wf),0,0,0,0,len(nm),0)).encode()+nm
ent=hdr+bytes((-len(hdr))%4)+wf+bytes((-(len(hdr)+((-len(hdr))%4)+len(wf)))%4)
cpio=body+ent+trailer; cpio+=bytes((-len(cpio))%512); gz=gzip.compress(cpio,9,mtime=0)
h2=bytearray(d[:2048]); struct.pack_into('<I',h2,16,len(gz)); h=hashlib.sha1(); [ (h.update(x),h.update(struct.pack('<I',len(x)))) for x in (kernel,gz,b'') ]; h2[576:608]=h.digest()+bytes(12)
pad=lambda x:x+bytes((-len(x))%2048); img=bytes(h2)+pad(kernel)+pad(gz); assert len(img)<=33554432; img+=bytes(33554432-len(img))
dst.write_bytes(img); print('wrote',dst,'sha256',hashlib.sha256(img).hexdigest())
