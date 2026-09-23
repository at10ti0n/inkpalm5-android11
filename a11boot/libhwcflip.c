/* libhwcflip -- LD_PRELOAD for the vendor composer process (hwcomposer-2-1) on EPD105.
 *
 * Two jobs, both compensating for an Android 8.1 vendor HWC driven by an Android 11 SurfaceFlinger.
 *
 * 1. FRAME MIRROR (original job). Intercepts ioctl(/dev/disp, DISP_EINK_UPDATE2=0x406, args[4])
 *    and, for every layer config args[3][i] (i < args[1], 200 B each, disp_layer_config2), mirrors
 *    the referenced buffer along the panel's long (1280) axis into a shadow buffer, and mirrors
 *    screen_win.x.  Reason (MEASURED 2026-09-17): the HWC framebuffer path shows every
 *    SurfaceFlinger raster reflected along that axis; a rotation cannot cancel a reflection.
 *
 * 2. SOFTWARE VSYNC (added 2026-09-21).  MEASURED on this device: the vendor HWC enables kernel
 *    vsync (DISP_VSYNC_EVENT_EN on /dev/disp, returns 0) and has a uevent thread waiting for it,
 *    but the kernel never emits VSYNC events on the E Ink path -- ueventd, which sees every kernel
 *    event, saw none in 24 s while four frames went to the panel.  So SurfaceFlinger reports
 *    "No Last HW vsync" forever.  Android 11's VSyncReactor needs hardware vsync samples to
 *    confirm a period change; without them it is stuck "transitioning" to the panel's 62.5 ms
 *    period with its predictor on a 16.67 ms placeholder, present fences ignored, and the app
 *    EventThread permanently in synthetic mode -- the regime in which the SurfaceFlinger livelock
 *    (docs/INCIDENT-SF-LIVELOCK.md) lives.  This shim hooks hw_get_module() so it can wrap the
 *    HWC2 device's getFunction(), captures the vsync callback the composer HAL registers, and
 *    drives it from a timer thread at the panel period while vsync is enabled.  The HWC's own
 *    setVsyncEnabled is still forwarded, so its kernel-side behaviour is unchanged.
 *
 *    Period: persist.display.default_vsync_freq (Hz, vendor property, 16 on this device), override
 *    with vendor.hwcflip.vsync_hz.  Kill switch: vendor.hwcflip.vsync=0 (read at each enable).
 *    Timestamps are the planned CLOCK_MONOTONIC deadlines, so spacing is exact; the reactor's
 *    confirmation allowance is 10% of the period.
 *
 * Pure pass-through for every other ioctl and every other HWC2 function.
 *
 * Build:  armv7a-linux-androideabi28-clang -shared -fPIC -O2 -Wl,-z,now -I<aosp headers> \
 *           -o libhwcflip.so libhwcflip.c -ldl      (see BUILDING.md)
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <hardware/hardware.h>
#include <hardware/hwcomposer2.h>

typedef int (*ioctl_fn)(int,int,...);
static ioctl_fn real_ioctl;
static unsigned g_calls, g_all, g_flipped, g_shadowfail;

extern int __system_property_set(const char*, const char*);
extern int __system_property_get(const char*, char*);
static void probe(const char*k,unsigned v){ char b[16]; snprintf(b,sizeof b,"%u",v); __system_property_set(k,b); }
typedef int (*logfn)(int,const char*,const char*,...); static logfn g_log;
static void lg(const char*fmt,unsigned a,unsigned b,unsigned c,unsigned d){ if(!g_log){ void*h=dlopen("liblog.so",RTLD_NOW); if(h) g_log=(logfn)dlsym(h,"__android_log_print"); } if(g_log) g_log(4,"hwcflip",fmt,a,b,c,d); }

/* ------------------------------------------------------------------------------------------ */
/* 1. frame mirror                                                                            */
/* ------------------------------------------------------------------------------------------ */

/* Shadow ring: never modify the composer's buffer (the HWC may resubmit it unchanged, and an
 * in-place mirror is not idempotent -> intermittently un-mirrored frames).
 * Allocated UNCACHED (ion flags 0).  The previous build allocated cached and then tried
 * ION_IOC_SYNC on its own ion client, which MEASURED (strace 2026-09-21) fails with EINVAL on
 * every frame; uncached needs no maintenance for the display engine to read what the CPU wrote.
 * The source buffer is not synced here either: the HWC syncs it itself before this ioctl. */
#define NSHADOW 3
typedef int (*ion_open_t)(void); typedef int (*ion_alloc_t)(int,size_t,size_t,unsigned,unsigned,int*); typedef int (*ion_share_t)(int,int,int*);
static struct { int fd; void *map; size_t len; } g_sh[NSHADOW]; static unsigned g_shi; static int g_shinit;
static int shadow_init(size_t len){
    if(g_shinit) return g_shinit>0;
    void *h=dlopen("libion.so",RTLD_NOW); ion_open_t o=h?(ion_open_t)dlsym(h,"ion_open"):0; ion_alloc_t a=h?(ion_alloc_t)dlsym(h,"ion_alloc"):0; ion_share_t sh=h?(ion_share_t)dlsym(h,"ion_share"):0;
    if(!o||!a||!sh){ g_shinit=-1; return 0; }
    int ionfd=o(); if(ionfd<0){ g_shinit=-1; return 0; }
    for(int i=0;i<NSHADOW;i++){ int handle=-1,dfd=-1; if(a(ionfd,len,0,1,0,&handle)||sh(ionfd,handle,&dfd)||dfd<0){ g_shinit=-1; return 0; }
        void *m=mmap(0,len,PROT_READ|PROT_WRITE,MAP_SHARED,dfd,0); if(m==MAP_FAILED){ g_shinit=-1; return 0; } g_sh[i].fd=dfd; g_sh[i].map=m; g_sh[i].len=len; }
    g_shinit=1; return 1;
}
static void flip_rows_copy(const uint8_t *src, uint8_t *dst, unsigned w, unsigned h, unsigned bpp, size_t stride){
    for(unsigned y=0;y<h;y++){ const uint8_t *r=src+y*stride; uint8_t *d=dst+y*stride; for(unsigned x=0;x<w;x++) memcpy(d+(size_t)x*bpp, r+(size_t)(w-1-x)*bpp, bpp); }
}
#define CMD_UPDATE2 0x406
#define CFG_LEN 200
static unsigned bpp_of(uint32_t f){ if(f<=0x07) return 4; if(f<=0x09) return 3; if(f<=0x0d) return 2; if(f==0x50) return 1; return 0; }
static void fix_layer(uint8_t *cfg){
    int fd; uint32_t fmt,w,h,sx,sw; memcpy(&fd,cfg+32,4); memcpy(&w,cfg+40,4); memcpy(&h,cfg+44,4); memcpy(&fmt,cfg+76,4);
    memcpy(&sx,cfg+8,4); memcpy(&sw,cfg+16,4);
    unsigned bpp=bpp_of(fmt); g_calls++;
    if(g_calls<=3||g_calls%100==0){ probe("vendor.hwcflip.update2",g_calls); probe("vendor.hwcflip.fd",(unsigned)fd); probe("vendor.hwcflip.fmt",fmt); probe("vendor.hwcflip.w",w); probe("vendor.hwcflip.h",h); lg("update2 #%u fd=%u fmt=0x%x w=%u",g_calls,(unsigned)fd,fmt,w); }
    if(fd<=0||!bpp||w==0||h==0||w>4096||h>4096){ if(g_calls<=3) lg("skip: fd=%u fmt=0x%x w=%u h=%u",(unsigned)fd,fmt,w,h); return; }
    size_t stride=(size_t)w*bpp, len=stride*h;
    if(!shadow_init(len)){ g_shadowfail++; probe("vendor.hwcflip.shadowfail",g_shadowfail); return; }
    /* The shadows are sized once, from the first frame (1280x720x4 in practice). A LARGER buffer
     * must never be copied into them: MEASURED 2026-09-24, with Settings > Colors = Natural the
     * saturation matrix disappears, SurfaceFlinger hands the vendor HWC individual DEVICE layers,
     * and the 1280x1440 wallpaper overran a shadow -> SIGSEGV in memcpy, composer restart loop,
     * framework restarts. Leave such a layer unmirrored (counted, logged) instead of crashing. */
    if(len>g_sh[0].len){ static unsigned big; big++; probe("vendor.hwcflip.toobig",big);
        if(big<=3) lg("skip oversize layer #%u: %ux%u needs %u bytes",big,w,h,(unsigned)len); return; }
    void *m=mmap(0,len,PROT_READ,MAP_SHARED,fd,0);
    if(m!=MAP_FAILED){ unsigned i=g_shi; g_shi=(g_shi+1)%NSHADOW; flip_rows_copy(m,g_sh[i].map,w,h,bpp,stride); munmap(m,len); int nfd=g_sh[i].fd; memcpy(cfg+32,&nfd,4); g_flipped++; if(g_flipped%50==1) probe("vendor.hwcflip.flipped",g_flipped); } else probe("vendor.hwcflip.mmapfail",g_calls);
    if(sw && sx+sw<=1280){ uint32_t nx=1280-sx-sw; memcpy(cfg+8,&nx,4); }   /* mirror screen_win.x */
}
int ioctl(int fd,int req,...){
    va_list ap; va_start(ap,req); void *arg=va_arg(ap,void*); va_end(ap);
    if(!real_ioctl) real_ioctl=(ioctl_fn)dlsym(RTLD_NEXT,"ioctl");
    ++g_all; if(g_all%64==1) probe("vendor.hwcflip.all",g_all);   /* a property write per syscall was too much */
    if(req==CMD_UPDATE2 && arg){ unsigned long *a=arg; unsigned n=(unsigned)a[1]; uint8_t *cfg=(uint8_t*)a[3];
        if(cfg && n>=1 && n<=32){ for(unsigned i=0;i<n;i++){ uint8_t *L=cfg+(size_t)i*CFG_LEN; int lfd; memcpy(&lfd,L+32,4); if(L[184]==1 && lfd>0) fix_layer(L); } } }
    return real_ioctl(fd,req,arg);
}

/* ------------------------------------------------------------------------------------------ */
/* 2. software vsync                                                                          */
/* ------------------------------------------------------------------------------------------ */

typedef int (*hgm_fn)(const char*, const struct hw_module_t**);
typedef int (*open_fn)(const struct hw_module_t*, const char*, struct hw_device_t**);

static const struct hw_module_t *g_real_module;    /* what the vendor HWC handed out */
static struct hw_module_t g_module_copy;            /* what the loader sees: same, but open() is ours */
static struct hw_module_methods_t g_methods;
static open_fn real_open;
typedef hwc2_function_pointer_t (*getfn_t)(struct hwc2_device*, int32_t);   /* declared inline in hwcomposer2.h, no typedef there */
static getfn_t real_getFunction;
static HWC2_PFN_REGISTER_CALLBACK real_registerCallback;
static HWC2_PFN_SET_VSYNC_ENABLED real_setVsyncEnabled;

static pthread_mutex_t g_vm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_vc = PTHREAD_COND_INITIALIZER;
static HWC2_PFN_VSYNC g_vsync_cb; static hwc2_callback_data_t g_vsync_data;
static hwc2_display_t g_vsync_display; static int g_vsync_on; static int g_thread_started;
static uint64_t g_vsync_count; static int64_t g_period_ns;

static int64_t period_from_props(void){
    char v[92]; long hz=0;
    if(__system_property_get("vendor.hwcflip.vsync_hz",v)>0) hz=atol(v);
    if(hz<=0 && __system_property_get("persist.display.default_vsync_freq",v)>0) hz=atol(v);
    if(hz<=0||hz>240) hz=16;
    return 1000000000LL/hz;
}
static int vsync_allowed(void){ char v[92]; if(__system_property_get("vendor.hwcflip.vsync",v)>0 && v[0]=='0') return 0; return 1; }
static int64_t now_ns(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (int64_t)t.tv_sec*1000000000LL+t.tv_nsec; }

static void *vsync_thread(void *arg){
    (void)arg;
    int64_t next=0;
    for(;;){
        pthread_mutex_lock(&g_vm);
        while(!g_vsync_on || !g_vsync_cb){ next=0; pthread_cond_wait(&g_vc,&g_vm); }
        int64_t period=g_period_ns;
        if(next==0){ next=now_ns()+period; }
        pthread_mutex_unlock(&g_vm);
        struct timespec ts={ (time_t)(next/1000000000LL), (long)(next%1000000000LL) };
        while(clock_nanosleep(CLOCK_MONOTONIC,TIMER_ABSTIME,&ts,NULL)==EINTR){}
        HWC2_PFN_VSYNC cb; hwc2_callback_data_t data; hwc2_display_t disp; int on;
        pthread_mutex_lock(&g_vm); cb=g_vsync_cb; data=g_vsync_data; disp=g_vsync_display; on=g_vsync_on; pthread_mutex_unlock(&g_vm);
        if(on && cb){ cb(data,disp,next); g_vsync_count++; if(g_vsync_count<=3||g_vsync_count%256==0) probe("vendor.hwcflip.vsync_count",(unsigned)g_vsync_count); }
        next+=period;
        /* if we fell far behind (suspend/resume), re-anchor instead of bursting */
        if(now_ns()-next > 4*period) next=0;
    }
    return NULL;
}

static int32_t my_registerCallback(hwc2_device_t *dev, int32_t desc, hwc2_callback_data_t data, hwc2_function_pointer_t ptr){
    if(desc==HWC2_CALLBACK_VSYNC){
        pthread_mutex_lock(&g_vm); g_vsync_cb=(HWC2_PFN_VSYNC)ptr; g_vsync_data=data; pthread_cond_broadcast(&g_vc); pthread_mutex_unlock(&g_vm);
        lg("vsync callback registered=%u",(unsigned)(ptr!=NULL),0,0,0);
    }
    return real_registerCallback ? real_registerCallback(dev,desc,data,ptr) : HWC2_ERROR_NONE;
}
static int32_t my_setVsyncEnabled(hwc2_device_t *dev, hwc2_display_t display, int32_t enabled){
    /* MEASURED 2026-09-21, three independent ways, on this vendor composer pair (8.1-era impl +
     * hwcomposer.virgo.so): the value that reaches this function is NOT the HWC2 enum.  Aligned on
     * one clock, SurfaceFlinger's "Setting power mode 2" (ON) is followed 4 ms later by a call with
     * enabled=2, and "Setting power mode 0" (OFF) by enabled=0; SurfaceFlinger's own state-change
     * trace markers coincide with exactly those two calls; and the vendor HWC logs its standard
     * enable code when forwarded 2 and its standard disable code when forwarded 0.  So here
     * 2 = enable, 0 = disable, and HWC2_VSYNC_ENABLE (1) never appears.  A first version of this
     * shim assumed the header encoding and so generated vsync only while the screen was off, when
     * SurfaceFlinger drops every sample -- which is why nothing ever reached the reactor.
     * vendor.hwcflip.vsync_encoding=hwc2 selects the standard encoding for a HAL that uses it.
     * The raw value is forwarded unchanged either way. */
    int on;
    { char v[92]; int std_enc = (__system_property_get("vendor.hwcflip.vsync_encoding",v)>0 && v[0]=='h');
      on = std_enc ? (enabled==HWC2_VSYNC_ENABLE) : (enabled==2); }
    on = on && vsync_allowed();
    pthread_mutex_lock(&g_vm);
    g_vsync_display=display; g_vsync_on=on; g_period_ns=period_from_props();
    if(on && !g_thread_started){ pthread_t t; if(pthread_create(&t,NULL,vsync_thread,NULL)==0){ g_thread_started=1; pthread_detach(t);} }
    pthread_cond_broadcast(&g_vc);
    pthread_mutex_unlock(&g_vm);
    probe("vendor.hwcflip.vsync_on",(unsigned)on);
    lg("setVsyncEnabled display=%u enabled=%u -> sw vsync %u, period %u us",(unsigned)display,(unsigned)enabled,(unsigned)on,(unsigned)(g_period_ns/1000));
    return real_setVsyncEnabled ? real_setVsyncEnabled(dev,display,enabled) : HWC2_ERROR_NONE;
}
static hwc2_function_pointer_t my_getFunction(hwc2_device_t *dev, int32_t desc){
    hwc2_function_pointer_t real = real_getFunction(dev,desc);
    if(desc==HWC2_FUNCTION_REGISTER_CALLBACK){ real_registerCallback=(HWC2_PFN_REGISTER_CALLBACK)real; return (hwc2_function_pointer_t)my_registerCallback; }
    if(desc==HWC2_FUNCTION_SET_VSYNC_ENABLED){ real_setVsyncEnabled=(HWC2_PFN_SET_VSYNC_ENABLED)real; return (hwc2_function_pointer_t)my_setVsyncEnabled; }
    return real;
}
static int my_open(const struct hw_module_t *m, const char *name, struct hw_device_t **dev){
    (void)m;
    int r = real_open(g_real_module,name,dev);        /* the vendor gets ITS module, never our copy */
    if(r || !dev || !*dev) return r;
    hwc2_device_t *d=(hwc2_device_t*)*dev;
    if(((d->common.version>>24)&0xf)!=2 || !d->getFunction){ lg("hwc device version 0x%x: not HWC2, no sw vsync",(unsigned)d->common.version,0,0,0); return r; }
    real_getFunction=d->getFunction; d->getFunction=my_getFunction;
    lg("HWC2 device hooked (version 0x%x); sw vsync armed",(unsigned)d->common.version,0,0,0);
    return r;
}
int hw_get_module(const char *id, const struct hw_module_t **module){
    hgm_fn real=(hgm_fn)dlsym(RTLD_NEXT,"hw_get_module");
    if(!real) return -1;
    int r=real(id,module);
    if(r || !module || !*module || !id || strcmp(id,HWC_HARDWARE_MODULE_ID)!=0) return r;
    if(!(*module)->methods || !(*module)->methods->open) return r;
    g_real_module=*module;
    memcpy(&g_module_copy,*module,sizeof g_module_copy);
    real_open=(*module)->methods->open; g_methods.open=my_open; g_module_copy.methods=&g_methods;
    *module=&g_module_copy;
    lg("hw_get_module(hwcomposer) hooked",0,0,0,0);
    return r;
}
