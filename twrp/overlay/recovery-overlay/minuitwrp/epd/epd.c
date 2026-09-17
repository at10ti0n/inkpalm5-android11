/* libepd implementation - see epd.h for the contract and the safety rationale. */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stddef.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdint.h>
typedef uint32_t u32; typedef uint8_t u8; typedef uint64_t u64; typedef int32_t s32;
#include "sunxi_display2.h"
#include "epd.h"

#define CMD_SET_GC_CNT 0x407
#define CMD_UPDATE2    0x406
#define MODE_GC16      0x04u
#define HEAP_SYSTEM    1u
#define STOCK_ALIGN    0u
#define STOCK_FLAGS    3u      /* CACHED | CACHED_NEEDS_SYNC - Gate 1C-b/1D */
#define SLOT_CH        1u
#define SLOT_ID        0u
#define SLOT_Z         4u

/* Sanity bounds for the calibration blobs. The waveform on this unit is 6,900,384 B;
 * the /system fallback is 6,899,360 B. Anything wildly outside that is not a waveform. */
#define WF_MIN  (1u<<20)          /*  1 MiB */
#define WF_MAX  (32u<<20)         /* 32 MiB */
#define VCOM_MIN 2
#define VCOM_MAX 32

/* Compile-time proof of the layout this backend depends on (Gate 1E-e). */
_Static_assert(sizeof(struct disp_layer_config2) == 200, "user stride must be 0xc8");
_Static_assert(offsetof(struct disp_layer_config2, info.fb.y8_fd) == 36, "y8_fd @36");
_Static_assert(offsetof(struct disp_layer_config2, enable)        == 184, "enable @184");
_Static_assert(EPD_SIZE == 921600, "Y8 frame must be 921600 bytes");

static const unsigned char EPD_GOLDEN_CFG[200] = {
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0xd0, 0x02, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0xd0, 0x02, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

struct area_info { unsigned int x_top, y_top, x_bottom, y_bottom; };

typedef int (*fn_open)(void);  typedef int (*fn_close)(int);
typedef int (*fn_alloc)(int,size_t,unsigned,unsigned,unsigned,int*);
typedef int (*fn_share)(int,int,int*); typedef int (*fn_free)(int,int);
typedef int (*fn_sync)(int,int);

static struct {
    bool  ready;
    void *lib;
    fn_open  o; fn_close c; fn_alloc a; fn_share s; fn_free f; fn_sync y;
    int   ion, handle, dma_fd, disp;
    void *map;
    struct disp_layer_config2 cfg;
    struct area_info          area;
    int   last_errno;
} E;

int epd_last_errno(void) { return E.last_errno; }

const char *epd_strerror(int code)
{
    switch (code) {
    case EPD_OK:              return "ok";
    case EPD_ERR_ALREADY:     return "already initialised";
    case EPD_ERR_NOT_INIT:    return "not initialised";
    case EPD_ERR_CALIBRATION: return "/private calibration missing or insane";
    case EPD_ERR_ION:         return "ION allocation failed";
    case EPD_ERR_DISP:        return "cannot open /dev/disp";
    case EPD_ERR_FIXTURE:     return "layer config failed the golden-fixture guard";
    case EPD_ERR_IOCTL:       return "UPDATE2 ioctl failed";
    case EPD_ERR_ARG:         return "bad argument";
    default:                  return "unknown";
    }
}

/* FAIL CLOSED. Never falls back to /system/default.bin - see epd.h. */
static int check_calibration(void)
{
    struct stat st;
    if (access(EPD_WAVEFORM_PATH, R_OK) != 0) { E.last_errno = errno; return -1; }
    if (stat(EPD_WAVEFORM_PATH, &st) != 0)    { E.last_errno = errno; return -1; }
    if (st.st_size < (off_t)WF_MIN || st.st_size > (off_t)WF_MAX) return -1;
    if (access(EPD_VCOM_PATH, R_OK) != 0)     { E.last_errno = errno; return -1; }
    if (stat(EPD_VCOM_PATH, &st) != 0)        { E.last_errno = errno; return -1; }
    if (st.st_size < VCOM_MIN || st.st_size > VCOM_MAX) return -1;
    return 0;
}

/* Golden-fixture guard, carried over from Gate 1E-f where it proved its worth.
 * INVARIANT (not "exactly one byte"): every difference must lie within 36..39,
 * y8_fd must be >= 0, and the field must actually differ from the placeholder. */
static int fixture_guard(void)
{
    const unsigned char *p = (const unsigned char *)&E.cfg;
    int ndiff = 0;
    for (int i = 0; i < 200; i++) {
        if (p[i] == EPD_GOLDEN_CFG[i]) continue;
        ndiff++;
        if (i < 36 || i > 39) return -1;
    }
    if (ndiff == 0) return -1;
    if (E.cfg.info.fb.y8_fd < 0) return -1;
    return 0;
}

int epd_init(void)
{
    if (E.ready) return EPD_ERR_ALREADY;
    memset(&E, 0, sizeof E);
    E.ion = E.handle = E.dma_fd = E.disp = -1;
    E.map = MAP_FAILED;

    if (check_calibration() != 0) return EPD_ERR_CALIBRATION;

    E.lib = dlopen("libion.so", RTLD_NOW);
    if (!E.lib) {
        fprintf(stderr, "epd: libion load failed: %s\n", dlerror());
        return EPD_ERR_ION;
    }
    E.o=(fn_open)dlsym(E.lib,"ion_open");   E.c=(fn_close)dlsym(E.lib,"ion_close");
    E.a=(fn_alloc)dlsym(E.lib,"ion_alloc"); E.s=(fn_share)dlsym(E.lib,"ion_share");
    E.f=(fn_free)dlsym(E.lib,"ion_free");   E.y=(fn_sync)dlsym(E.lib,"ion_sync_fd");
    if(!E.o||!E.c||!E.a||!E.s||!E.f||!E.y) { epd_shutdown(); return EPD_ERR_ION; }

    E.ion = E.o();
    if (E.ion < 0) { E.last_errno=errno; epd_shutdown(); return EPD_ERR_ION; }
    /* ONE long-lived allocation for the life of the backend - never per frame. */
    if (E.a(E.ion, EPD_SIZE, STOCK_ALIGN, HEAP_SYSTEM, STOCK_FLAGS, &E.handle)) {
        E.last_errno=errno; epd_shutdown(); return EPD_ERR_ION; }
    if (E.s(E.ion, E.handle, &E.dma_fd) || E.dma_fd < 0) {
        E.last_errno=errno; epd_shutdown(); return EPD_ERR_ION; }
    E.map = mmap(NULL, EPD_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, E.dma_fd, 0);
    if (E.map == MAP_FAILED) { E.last_errno=errno; epd_shutdown(); return EPD_ERR_ION; }

    /* Build the layer config ONCE. epd_present_y8() never touches it again. */
    memset(&E.cfg, 0, sizeof E.cfg);
    E.cfg.info.mode              = LAYER_MODE_BUFFER;
    E.cfg.info.zorder            = SLOT_Z;
    E.cfg.info.alpha_value       = 0xff;
    E.cfg.info.screen_win.width  = EPD_WIDTH;
    E.cfg.info.screen_win.height = EPD_HEIGHT;
    E.cfg.info.fb.y8_fd          = E.dma_fd;      /* @36 - THE PIXEL SOURCE */
    E.cfg.info.fb.size[0].width  = EPD_WIDTH;
    E.cfg.info.fb.size[0].height = EPD_HEIGHT;
    /* fb.fd, fb.format, fb.crop stay ZERO: proven never read on this path. */
    E.cfg.enable                 = 1;             /* @184 */
    E.cfg.channel                = SLOT_CH;
    E.cfg.layer_id               = SLOT_ID;

    memset(&E.area, 0, sizeof E.area);
    E.area.x_bottom = (EPD_WIDTH > EPD_HEIGHT ? EPD_WIDTH : EPD_HEIGHT) - 1;
    E.area.y_bottom = (EPD_WIDTH < EPD_HEIGHT ? EPD_WIDTH : EPD_HEIGHT) - 1;

    if (fixture_guard() != 0) { epd_shutdown(); return EPD_ERR_FIXTURE; }

    E.disp = open("/dev/disp", O_RDWR);
    if (E.disp < 0) { E.last_errno=errno; epd_shutdown(); return EPD_ERR_DISP; }

    E.ready = true;
    return EPD_OK;
}

int epd_present_y8(const uint8_t *pixels)
{
    if (!E.ready)  return EPD_ERR_NOT_INIT;
    if (!pixels)   return EPD_ERR_ARG;

    memcpy(E.map, pixels, EPD_SIZE);

    /* Ownership handoff (Gate 1D). No CPU access to E.map after this until the
     * next epd_present_y8() call re-enters at the memcpy above. */
    if (E.y(E.ion, E.dma_fd)) { E.last_errno = errno; return EPD_ERR_IOCTL; }

    { unsigned long a[4] = { 0, 0, 0, 0 };
      (void)ioctl(E.disp, CMD_SET_GC_CNT, a); }   /* stock gc_cnt = 0, non-fatal */

    { unsigned long args[4];
      args[0] = (unsigned long)&E.area;
      args[1] = 1;
      args[2] = MODE_GC16;
      args[3] = (unsigned long)&E.cfg;
      errno = 0;
      if (ioctl(E.disp, CMD_UPDATE2, args)) {     /* THE ONE AND ONLY 0x406 CALLSITE */
          E.last_errno = errno; return EPD_ERR_IOCTL; } }

    return EPD_OK;
}

void epd_shutdown(void)
{
    if (E.disp >= 0)               { close(E.disp); E.disp = -1; }
    if (E.map != MAP_FAILED && E.map) { munmap(E.map, EPD_SIZE); E.map = MAP_FAILED; }
    if (E.dma_fd >= 0)             { close(E.dma_fd); E.dma_fd = -1; }
    if (E.handle >= 0 && E.ion >= 0 && E.f) { E.f(E.ion, E.handle); E.handle = -1; }
    if (E.ion >= 0 && E.c)         { E.c(E.ion); E.ion = -1; }
    if (E.lib)                     { dlclose(E.lib); E.lib = NULL; }
    E.ready = false;
}
