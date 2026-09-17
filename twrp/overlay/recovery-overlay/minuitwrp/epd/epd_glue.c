#include <string.h>
#include <stdlib.h>
#include "epd.h"
#include "epd_surface.h"
#include "epd_glue.h"

static epd_presenter_fn g_present;
static epd_rotation     g_rot;
static uint8_t         *g_frame;       /* one long-lived conversion target */
static int              g_ready;
static unsigned         n_present, n_suppress, n_calls;

int epd_glue_init(epd_presenter_fn present, epd_rotation rot)
{
    if (!present) return EPD_GLUE_ERR_ARG;
    if (g_ready)  return 0;
    g_frame = malloc(EPD_SIZE);
    if (!g_frame) return EPD_GLUE_ERR_ARG;
    g_present = present;
    g_rot     = rot;
    /* The cache begins INVALID, so the first legitimate flip presents exactly once. */
    epd_frame_reset();
    n_present = n_suppress = n_calls = 0;
    g_ready = 1;
    return 0;
}

int epd_glue_flip(const epd_surface *src)
{
    if (!g_ready)        return EPD_GLUE_ERR_NOT_INIT;
    if (!src)            return EPD_GLUE_ERR_ARG;

    /* Hard error on any surface mismatch. The converter refuses rather than
     * adapting itself to an unexpected framebuffer layout - a silent adaptation
     * here would produce a plausible but wrong image on a device we cannot see. */
    if (!epd_surface_to_y8(src, g_rot, g_frame)) return EPD_GLUE_ERR_SURFACE;

    if (!epd_frame_changed(g_frame)) { n_suppress++; return EPD_FLIP_SUPPRESSED; }

    n_calls++;
    if (g_present(g_frame) != 0) return EPD_GLUE_ERR_PRESENT;  /* NO commit, NO retry */

    /* Commit only after a successful present, so a failure leaves the next
     * identical flip free to try again instead of being suppressed. */
    epd_frame_commit(g_frame);
    n_present++;
    return EPD_FLIP_PRESENTED;
}

void epd_glue_shutdown(void)
{
    free(g_frame); g_frame = NULL;
    g_present = NULL; g_ready = 0;
    epd_frame_reset();
}

unsigned epd_glue_presents(void)      { return n_present; }
unsigned epd_glue_suppressed(void)    { return n_suppress; }
unsigned epd_glue_present_calls(void) { return n_calls; }
