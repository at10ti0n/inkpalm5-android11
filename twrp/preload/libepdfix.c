/* libepdfix -- LD_PRELOAD for TWRP's recovery on EPD105 (fix2, 2026-09-17).
 * 1. DISPLAY: interposes epd_surface_to_y8 (+ the frame cache it pairs with) so every
 *    frame is converted with EPD_ROT_TRANSPOSE (dx=sy, dy=sx), which the panel wants.
 *    The real converter is compiled in from fix2's epd_surface.c under another name.
 * 2. TOUCH: on fds that are /dev/input/event*, swaps ABS_MT_POSITION_X<->Y (and ABS_X<->Y)
 *    in every input_event read, and swaps the EVIOCGABS range queries to match.
 * Pure pass-through for every other fd.  Nothing here touches the panel or storage. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include "epd_surface.h"

bool epd_surface_to_y8_impl(const epd_surface *src, epd_rotation rot, uint8_t *dst);
static int g_said;
static void say(const char *m){ if(!g_said){ g_said=1; write(2,m,strlen(m)); } }

bool epd_surface_to_y8(const epd_surface *src, epd_rotation rot, uint8_t *dst)
{
    (void)rot;
    say("epdfix: ACTIVE -- transpose display, swapped touch axes (fix2)\n");
    return epd_surface_to_y8_impl(src, EPD_ROT_TRANSPOSE, dst);
}

/* ---------------- touch ---------------- */
typedef ssize_t (*read_fn)(int, void *, size_t);
typedef ssize_t (*readchk_fn)(int, void *, size_t, size_t);
typedef int (*ioctl_fn)(int, int, ...);
typedef int (*close_fn)(int);
static read_fn r_read; static readchk_fn r_readchk; static ioctl_fn r_ioctl; static close_fn r_close;
static signed char cls[4096];           /* 0 unknown, 1 input device, -1 other */

static void resolve(void){
    if(!r_read)    r_read    = (read_fn)   dlsym(RTLD_NEXT, "read");
    if(!r_readchk) r_readchk = (readchk_fn)dlsym(RTLD_NEXT, "__read_chk");
    if(!r_ioctl)   r_ioctl   = (ioctl_fn)  dlsym(RTLD_NEXT, "ioctl");
    if(!r_close)   r_close   = (close_fn)  dlsym(RTLD_NEXT, "close");
}
static int is_input(int fd){
    if(fd<0||fd>=(int)sizeof cls) return 0;
    if(cls[fd]==0){
        char p[48], t[64]; int n;
        n = snprintf(p, sizeof p, "/proc/self/fd/%d", fd);
        (void)n;
        ssize_t l = readlink(p, t, sizeof t - 1);
        if(l>0){ t[l]=0; cls[fd] = (strncmp(t,"/dev/input/event",16)==0) ? 1 : -1; }
        else cls[fd] = -1;
    }
    return cls[fd]==1;
}
static void swap_events(void *buf, ssize_t n){
    struct input_event *ev = buf;
    for(ssize_t i=0; i+ (ssize_t)sizeof *ev <= n; i+=sizeof *ev, ev++){
        if(ev->type!=EV_ABS) continue;
        switch(ev->code){
        case ABS_MT_POSITION_X: ev->code=ABS_MT_POSITION_Y; break;
        case ABS_MT_POSITION_Y: ev->code=ABS_MT_POSITION_X; break;
        case ABS_X: ev->code=ABS_Y; break;
        case ABS_Y: ev->code=ABS_X; break;
        default: break;
        }
    }
}
ssize_t read(int fd, void *buf, size_t n){
    resolve(); ssize_t r = r_read(fd,buf,n);
    if(r>0 && is_input(fd)) swap_events(buf,r);
    return r;
}
ssize_t __read_chk(int fd, void *buf, size_t n, size_t bs){
    resolve(); ssize_t r = r_readchk(fd,buf,n,bs);
    if(r>0 && is_input(fd)) swap_events(buf,r);
    return r;
}
int close(int fd){ resolve(); if(fd>=0&&fd<(int)sizeof cls) cls[fd]=0; return r_close(fd); }
int ioctl(int fd, int req, ...){
    resolve(); va_list ap; va_start(ap,req); void *arg = va_arg(ap, void*); va_end(ap);
    if(is_input(fd)){
        if(req==(int)EVIOCGABS(ABS_MT_POSITION_X)) req = EVIOCGABS(ABS_MT_POSITION_Y);
        else if(req==(int)EVIOCGABS(ABS_MT_POSITION_Y)) req = EVIOCGABS(ABS_MT_POSITION_X);
        else if(req==(int)EVIOCGABS(ABS_X)) req = EVIOCGABS(ABS_Y);
        else if(req==(int)EVIOCGABS(ABS_Y)) req = EVIOCGABS(ABS_X);
    }
    return r_ioctl(fd,req,arg);
}
