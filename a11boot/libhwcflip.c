/* libhwcflip -- LD_PRELOAD for the vendor composer process (hwcomposer-2-1) on EPD105.
 * Intercepts ioctl(/dev/disp, DISP_EINK_UPDATE2=0x406, args[4]) and, for every layer
 * config args[3][i] (i < args[1], 200 B each, disp_layer_config2), mirrors the referenced
 * buffer along the panel's long (1280) axis in place, with DMA_BUF_IOCTL_SYNC around the
 * CPU access, and mirrors screen_win.x.  Reason (MEASURED 2026-09-17): the HWC framebuffer
 * path shows every SurfaceFlinger raster reflected along that axis; a rotation cannot
 * cancel a reflection.  Pure pass-through for every other ioctl. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/dma-buf.h>
#include <fcntl.h>
#include <stdio.h>
/* Allwinner 4.9 ION: cache maintenance is ION_IOC_SYNC on an ION client fd (what the HWC
 * itself does before UPDATE2); DMA_BUF_IOCTL_SYNC does no flush here. */
#define ION_IOC_SYNC 0xc0084907u
typedef int (*ioctl_fn)(int,int,...);
static ioctl_fn real_ioctl;
struct ion_fd_data { int fd; int handle; };
static int g_ion=-1; static unsigned g_calls, g_all, g_flipped, g_shadowfail;
/* Shadow ring: never modify the composer's buffer (the HWC may resubmit it unchanged, and
 * an in-place mirror is not idempotent -> intermittently un-mirrored frames). */
#define NSHADOW 3
typedef int (*ion_open_t)(void); typedef int (*ion_alloc_t)(int,size_t,size_t,unsigned,unsigned,int*); typedef int (*ion_share_t)(int,int,int*);
static struct { int fd; void *map; size_t len; } g_sh[NSHADOW]; static unsigned g_shi; static int g_shinit;
static int shadow_init(size_t len){
    if(g_shinit) return g_shinit>0;
    void *h=dlopen("libion.so",RTLD_NOW); ion_open_t o=h?(ion_open_t)dlsym(h,"ion_open"):0; ion_alloc_t a=h?(ion_alloc_t)dlsym(h,"ion_alloc"):0; ion_share_t sh=h?(ion_share_t)dlsym(h,"ion_share"):0;
    if(!o||!a||!sh){ g_shinit=-1; return 0; }
    int ionfd=o(); if(ionfd<0){ g_shinit=-1; return 0; }
    for(int i=0;i<NSHADOW;i++){ int handle=-1,dfd=-1; if(a(ionfd,len,0,1,3,&handle)||sh(ionfd,handle,&dfd)||dfd<0){ g_shinit=-1; return 0; }
        void *m=mmap(0,len,PROT_READ|PROT_WRITE,MAP_SHARED,dfd,0); if(m==MAP_FAILED){ g_shinit=-1; return 0; } g_sh[i].fd=dfd; g_sh[i].map=m; g_sh[i].len=len; }
    g_shinit=1; return 1;
}
static void flip_rows_copy(const uint8_t *src, uint8_t *dst, unsigned w, unsigned h, unsigned bpp, size_t stride){
    for(unsigned y=0;y<h;y++){ const uint8_t *r=src+y*stride; uint8_t *d=dst+y*stride; for(unsigned x=0;x<w;x++) memcpy(d+(size_t)x*bpp, r+(size_t)(w-1-x)*bpp, bpp); }
}
extern int __system_property_set(const char*, const char*);
static void probe(const char*k,unsigned v){ char b[16]; snprintf(b,sizeof b,"%u",v); __system_property_set(k,b); }
typedef int (*logfn)(int,const char*,const char*,...); static logfn g_log;
static void lg(const char*fmt,unsigned a,unsigned b,unsigned c,unsigned d){ if(!g_log){ void*h=dlopen("liblog.so",RTLD_NOW); if(h) g_log=(logfn)dlsym(h,"__android_log_print"); } if(g_log) g_log(4,"hwcflip",fmt,a,b,c,d); }
static void ion_sync(int fd){ if(g_ion<0) g_ion=open("/dev/ion",O_RDONLY|O_CLOEXEC); if(g_ion>=0){ struct ion_fd_data d={fd,0}; real_ioctl(g_ion,ION_IOC_SYNC,&d);} }
#define CMD_UPDATE2 0x406
#define CFG_LEN 200
static unsigned bpp_of(uint32_t f){ if(f<=0x07) return 4; if(f<=0x09) return 3; if(f<=0x0d) return 2; if(f==0x50) return 1; return 0; }
static void flip_rows(uint8_t *p, unsigned w, unsigned h, unsigned bpp, size_t stride){
    uint8_t tmp[4];
    for(unsigned y=0;y<h;y++){ uint8_t *r=p+y*stride;
        for(unsigned a=0,b=w-1;a<b;a++,b--){ uint8_t *pa=r+(size_t)a*bpp,*pb=r+(size_t)b*bpp; memcpy(tmp,pa,bpp); memcpy(pa,pb,bpp); memcpy(pb,tmp,bpp); } }
}
static void fix_layer(uint8_t *cfg){
    int fd; uint32_t fmt,w,h,sx,sw; memcpy(&fd,cfg+32,4); memcpy(&w,cfg+40,4); memcpy(&h,cfg+44,4); memcpy(&fmt,cfg+76,4);
    memcpy(&sx,cfg+8,4); memcpy(&sw,cfg+16,4);
    unsigned bpp=bpp_of(fmt); g_calls++; probe("vendor.hwcflip.update2",g_calls); probe("vendor.hwcflip.fd",(unsigned)fd); probe("vendor.hwcflip.fmt",fmt); probe("vendor.hwcflip.w",w); probe("vendor.hwcflip.h",h); { uint32_t sx,sy,sw,sh; memcpy(&sx,cfg+8,4); memcpy(&sy,cfg+12,4); memcpy(&sw,cfg+16,4); memcpy(&sh,cfg+20,4); char v[48]; snprintf(v,sizeof v,"%u,%u,%u,%u",sx,sy,sw,sh); __system_property_set("vendor.hwcflip.win",v); } if(g_calls<=3||g_calls%100==0) lg("update2 #%u fd=%u fmt=0x%x w=%u",g_calls,(unsigned)fd,fmt,w);
    if(fd<=0||!bpp||w==0||h==0||w>4096||h>4096){ if(g_calls<=3) lg("skip: fd=%u fmt=0x%x w=%u h=%u",(unsigned)fd,fmt,w,h); return; }
    size_t stride=(size_t)w*bpp, len=stride*h;
    if(!shadow_init(len)){ g_shadowfail++; probe("vendor.hwcflip.shadowfail",g_shadowfail); return; }
    ion_sync(fd);
    void *m=mmap(0,len,PROT_READ,MAP_SHARED,fd,0);
    if(m!=MAP_FAILED){ unsigned i=g_shi; g_shi=(g_shi+1)%NSHADOW; flip_rows_copy(m,g_sh[i].map,w,h,bpp,stride); munmap(m,len); ion_sync(g_sh[i].fd); int nfd=g_sh[i].fd; memcpy(cfg+32,&nfd,4); g_flipped++; probe("vendor.hwcflip.flipped",g_flipped); } else probe("vendor.hwcflip.mmapfail",g_calls);
    if(sw && sx+sw<=1280){ uint32_t nx=1280-sx-sw; memcpy(cfg+8,&nx,4); }   /* mirror screen_win.x */
}
int ioctl(int fd,int req,...){
    va_list ap; va_start(ap,req); void *arg=va_arg(ap,void*); va_end(ap);
    if(!real_ioctl) real_ioctl=(ioctl_fn)dlsym(RTLD_NEXT,"ioctl");
    ++g_all; probe("vendor.hwcflip.all",g_all);
    if(g_all<=8){ char k[40]; snprintf(k,sizeof k,"vendor.hwcflip.c%u",g_all); char v[40]; snprintf(v,sizeof v,"fd%d_cmd%x",fd,(unsigned)req); __system_property_set(k,v); }
    if(req==CMD_UPDATE2){ probe("vendor.hwcflip.u2seen",g_all); static int once; if(!once){ once=1; unsigned long *a=arg; char v[64];
        snprintf(v,sizeof v,"%lx,%lx,%lx,%lx",a[0],a[1],a[2],a[3]); __system_property_set("vendor.hwcflip.args",v);
        uint8_t *c=(uint8_t*)a[3]; if(c){ snprintf(v,sizeof v,"%02x%02x%02x%02x-%02x%02x%02x%02x-fd%02x%02x%02x%02x-en%02x",c[0],c[1],c[2],c[3],c[8],c[9],c[10],c[11],c[32],c[33],c[34],c[35],c[184]); __system_property_set("vendor.hwcflip.cfg",v);} 
        uint32_t *ar=(uint32_t*)a[0]; if(ar){ snprintf(v,sizeof v,"%u,%u,%u,%u",ar[0],ar[1],ar[2],ar[3]); __system_property_set("vendor.hwcflip.area",v);} } }
    if(req==CMD_UPDATE2 && arg){ unsigned long *a=arg; unsigned n=(unsigned)a[1]; uint8_t *cfg=(uint8_t*)a[3];
        if(cfg && n>=1 && n<=32){ static int dumped; if(!dumped){ dumped=1; char v[90]; int o=0; for(unsigned i=0;i<n&&i<16;i++){ uint8_t *L=cfg+(size_t)i*CFG_LEN; o+=snprintf(v+o,sizeof v-o,"%x/%x ",L[184],L[32]); if(o>80)break; } __system_property_set("vendor.hwcflip.slots",v); }
            for(unsigned i=0;i<n;i++){ uint8_t *L=cfg+(size_t)i*CFG_LEN; int lfd; memcpy(&lfd,L+32,4); if(L[184]==1 && lfd>0) fix_layer(L); } } }
    return real_ioctl(fd,req,arg);
}
