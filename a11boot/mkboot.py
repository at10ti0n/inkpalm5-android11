#!/usr/bin/env python3
"""mkboot.py -- build the Android 11 boot image for the Moaan EPD105 from YOUR stock boot.img.
   python3 mkboot.py <stock-boot.img> <out-boot.img>
Applies: (1) permissive-init byte patch (init: 01 20 -> 00 20 before security_setenforce),
(2) prepends a11-prepend.rc to /init.rc, (3) adds /wdog (optional watchdog, see wdog.c).
Refuses any input that is not the known stock image (sha256 checked)."""
import gzip, hashlib, struct, sys
from pathlib import Path
STOCK_SHA='62ce2f881e331303027a1562ec93efebaa49a5700737f8df4e25c86ffcfba83d'   # EPD105 stock boot (B300-o-mr1-v1.0rc2)
INIT_SHA='b45a8bceb3b69700ec1c87d392ef94b1f485625e99616fd27ac75fec5bd91a73'
INIT_PATCHED_SHA='8192d81a6388686fdc7fc9e7c6360027c7360824e76b53db3258f756d403f4e9'
PATCH_OFF=41146
src,dst=Path(sys.argv[1]),Path(sys.argv[2]); here=Path(__file__).resolve().parent
d=src.read_bytes(); assert hashlib.sha256(d).hexdigest()==STOCK_SHA, 'not the known EPD105 stock boot.img'
k,ka,r,ra,s,sa,t,pg,hv,ov=struct.unpack_from('<10I',d,8); ro=pg+((k+pg-1)//pg)*pg; kernel=d[pg:pg+k]; cpio=gzip.decompress(d[ro:ro+r])
def parse(buf):
    out=[]; i=0
    while True:
        f=[int(buf[i+6+8*j:i+14+8*j],16) for j in range(13)]; ns=i+110; name=buf[ns:ns+f[11]-1].decode(); ds=(ns+f[11]+3)&~3
        out.append(dict(ino=f[0],mode=f[1],uid=f[2],gid=f[3],nlink=f[4],mtime=f[5],dmaj=f[7],dmin=f[8],rmaj=f[9],rmin=f[10],name=name,data=buf[ds:ds+f[6]])); i=(ds+f[6]+3)&~3
        if name=='TRAILER!!!': return out,i
ents,end=parse(cpio); tail=cpio[end:]; hexcase='%08x' if cpio[6:14]==cpio[6:14].lower() else '%08X'
def emit(ents):
    b=bytearray()
    for e in ents:
        nm=e['name'].encode()+b'\0'
        b+=b'070701'+''.join(hexcase%v for v in (e['ino'],e['mode'],e['uid'],e['gid'],e['nlink'],e['mtime'],len(e['data']),e['dmaj'],e['dmin'],e['rmaj'],e['rmin'],len(nm),0)).encode()+nm
        b+=bytes((-len(b))%4); b+=e['data']; b+=bytes((-len(b))%4)
    b+=bytes(len(tail)) if len(tail)<512 else bytes((-len(b))%512); return bytes(b)
assert emit(ents)==cpio
init=next(e for e in ents if e['name']=='init'); assert hashlib.sha256(init['data']).hexdigest()==INIT_SHA
ib=bytearray(init['data']); assert ib[PATCH_OFF:PATCH_OFF+2]==b'\x01\x20'; ib[PATCH_OFF:PATCH_OFF+2]=b'\x00\x20'; assert hashlib.sha256(bytes(ib)).hexdigest()==INIT_PATCHED_SHA; init['data']=bytes(ib)
import os
prep=(here/'a11-prepend.rc').read_bytes()
if os.environ.get('A11_SF_ORIENTATION'):   # 3.2 natural-portrait experiment
    prep=b'on init\n    setprop ro.surface_flinger.primary_display_orientation ORIENTATION_'+os.environ['A11_SF_ORIENTATION'].encode()+b'\n\n'+prep
rc=next(e for e in ents if e['name']=='init.rc'); rc['data']=prep+rc['data']
wd=here/'wdog'
if wd.exists(): ents.insert(len(ents)-1,dict(ino=max(e['ino'] for e in ents)+1,mode=0o100755,uid=0,gid=0,nlink=1,mtime=0,dmaj=init['dmaj'],dmin=init['dmin'],rmaj=0,rmin=0,name='wdog',data=wd.read_bytes()))
gz=gzip.compress(emit(ents),9,mtime=0); hdr=bytearray(d[:2048]); struct.pack_into('<I',hdr,16,len(gz))
h=hashlib.sha1(); [ (h.update(x), h.update(struct.pack('<I',len(x)))) for x in (kernel,gz,b'') ]; hdr[576:608]=h.digest()+bytes(12)
pad=lambda x:x+bytes((-len(x))%2048); img=bytes(hdr)+pad(kernel)+pad(gz); assert len(img)<=33554432; img+=bytes(33554432-len(img))
dst.write_bytes(img); print('wrote',dst,'sha256',hashlib.sha256(img).hexdigest())
