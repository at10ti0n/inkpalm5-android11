/* graphics_epd.cpp - EPD-native minui backend for Moaan InkPalm 5 Pro (EPD105).
 *
 * Base: TeamWin/Team-Win-Recovery-Project android-9.0 @ 58f2132bc3954fc704787d477500a209eedb8e29
 *       minuitwrp drawing stack. See PROVENANCE.md.
 *
 * WE OWN THE SURFACE. It is not discovered from a framebuffer: it is defined here as
 * 720x1280 RGBA8888, row_bytes 2880, plain memory. Pixelflinger/TWRP draws into it
 * normally. That removes the fb0 24-bpp / GGL-format mismatch from the correctness
 * path entirely, and makes the descriptor handed to epd_surface exact by construction.
 *
 * Pipeline:
 *   TWRP GUI -> GRSurface 720x1280 RGBA8888 -> epd_surface (Y8 + rotate)
 *            -> epd_glue (validate, suppress unchanged, commit on success)
 *            -> epd_present_y8 -> ION + ion_sync_fd + 0x406
 */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef EPD_USE_REAL_MINUI
#  include <pixelflinger/pixelflinger.h>   /* GGL_PIXEL_FORMAT_*, as upstream does */
#endif
#include "graphics_epd.h"
extern "C" {
#include "epd.h"
#include "epd_surface.h"
#include "epd_glue.h"
}

/* Logical UI surface - pinned, not probed. */
#define UI_W          720
#define UI_H         1280
#define UI_PIXBYTES     4
#define UI_ROWBYTES  (UI_W * UI_PIXBYTES)     /* 2880 */

/* Orientation stays a single named constant until the first Gate 1F-4 image settles
 * it. Do not silently flip this - see twrp/libepd/ROTATION.md. */
static const epd_rotation EPD105_ROTATION = EPD_ROT_TRANSPOSE;   /* fix2: observed 2026-09-17 */

static GRSurface  gr_surf;
static bool       g_armed;
static bool       g_arm_once;      /* auto-disarm after the first successful present */
static bool       g_spent;         /* arm-once has fired */
static bool       g_display_ok;
static unsigned   g_flips, g_preflips;

/* Production presenter. The glue holds this as a function pointer so the dry test can
 * substitute a fake and never reach the panel. */
static int present_real(const uint8_t *y8)
{
    return epd_present_y8(y8) == EPD_OK ? 0 : -1;
}

static GRSurface *epd_be_init(minui_backend *)
{
    memset(&gr_surf, 0, sizeof gr_surf);
    g_armed = false; g_arm_once = false; g_spent = false;
    g_display_ok = false; g_flips = g_preflips = 0;

    gr_surf.width       = UI_W;
    gr_surf.height      = UI_H;
    gr_surf.row_bytes   = UI_ROWBYTES;
    gr_surf.pixel_bytes = UI_PIXBYTES;
    gr_surf.format      = GGL_PIXEL_FORMAT_RGBA_8888;
    gr_surf.data        = (unsigned char *)calloc((size_t)UI_H, UI_ROWBYTES);
    if (!gr_surf.data) return NULL;          /* nothing can draw; caller handles */

    /* Display init may fail (e.g. /private not mounted => calibration unavailable).
     * FAIL CLOSED for the panel, but DO NOT take recovery down with it: TWRP must
     * still start so the device stays reachable and diagnosable over adb. */
    int rc = epd_init();
    if (rc != EPD_OK) {
        fprintf(stderr, "graphics_epd: epd_init failed: %d (%s) errno=%d - "
                        "PANEL DISABLED, recovery continues\n",
                rc, epd_strerror(rc), epd_last_errno());
        return &gr_surf;
    }
    if (epd_glue_init(present_real, EPD105_ROTATION) != 0) {
        fprintf(stderr, "graphics_epd: epd_glue_init failed - PANEL DISABLED\n");
        epd_shutdown();
        return &gr_surf;
    }
    g_display_ok = true;
    return &gr_surf;
}

static GRSurface *epd_be_flip(minui_backend *)
{
    g_flips++;

    /* gr_init() flips twice before returning. Until armed, present NOTHING. */
    if (!g_armed || !g_display_ok) { g_preflips++; return &gr_surf; }

    epd_surface src;
    src.pixels    = gr_surf.data;
    src.width     = (unsigned)gr_surf.width;
    src.height    = (unsigned)gr_surf.height;
    src.row_bytes = (size_t)gr_surf.row_bytes;
    src.format    = EPD_PIX_RGBA8888;

    int rc = epd_glue_flip(&src);
    if (rc < 0) {
        fprintf(stderr, "graphics_epd: flip rc=%d\n", rc);
        /* A FAILED present must NOT consume the one-shot: the retry stays eligible,
         * mirroring epd_glue's commit-only-on-success rule. */
        return &gr_surf;
    }
    if (rc == EPD_FLIP_PRESENTED && g_arm_once) {
        g_armed = false; g_spent = true;
        fprintf(stderr, "graphics_epd: arm-once SPENT after 1 present; "
                        "all further flips are software-only\n");
    }
    return &gr_surf;
}

/* No-op for the first port. gr_fb_blank() delegates here, but we have no reason yet to
 * translate framebuffer-blank semantics into an EPD power or waveform operation. */
static void epd_be_blank(minui_backend *, bool) { }

static void epd_be_exit(minui_backend *)
{
    epd_glue_shutdown();
    if (g_display_ok) epd_shutdown();
    free(gr_surf.data);
    gr_surf.data = NULL;
    g_armed = false; g_display_ok = false;
}

static minui_backend epd_backend = {
    .init  = epd_be_init,
    .flip  = epd_be_flip,
    .blank = epd_be_blank,
    .exit  = epd_be_exit,
};

extern "C" {

minui_backend *open_epd(void) { return &epd_backend; }

void epd_backend_arm(void)
{
    g_armed = true; g_arm_once = false;
    fprintf(stderr, "graphics_epd: ARMED (continuous) after %u pre-arm flip(s)\n", g_preflips);
}

void epd_backend_arm_once(void)
{
    g_armed = true; g_arm_once = true; g_spent = false;
    fprintf(stderr, "graphics_epd: ARMED ONCE after %u pre-arm flip(s) - "
                    "exactly one present will occur\n", g_preflips);
}

bool epd_backend_spent(void) { return g_spent; }

bool     epd_backend_armed(void)      { return g_armed; }
bool     epd_backend_display_ok(void) { return g_display_ok; }
unsigned epd_backend_flips(void)      { return g_flips; }
unsigned epd_backend_preflips(void)   { return g_preflips; }

}
