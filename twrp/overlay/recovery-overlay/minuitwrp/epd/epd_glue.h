/* epd_glue - the ONLY layer that knows both sides. Gate 1F-3b.
 *
 * LAYERING RULE, enforced by review and by the dry test:
 *     epd.c          owns ION + /dev/disp + the single 0x406 callsite.
 *                    Knows NOTHING about minui, surfaces, rotation or caching.
 *     epd_surface.c  owns pixel format, luma, rotation, change detection.
 *                    Knows NOTHING about /dev/disp, ION or ioctls.
 *     epd_glue.c     owns the policy that joins them. Tiny on purpose, so the
 *                    single 0x406 owner stays auditable after TWRP becomes large.
 *
 * The presenter is a function pointer so the dry integration test can inject a
 * fake and exercise the failure/retry path WITHOUT a device or a panel.
 */
#ifndef EPD_GLUE_H
#define EPD_GLUE_H

#include <stdint.h>
#include "epd_surface.h"

/* Returns 0 on success, non-zero on failure. In production this is a thin wrapper
 * around epd_present_y8(). */
typedef int (*epd_presenter_fn)(const uint8_t *y8);

enum {
    EPD_FLIP_PRESENTED = 0,   /* content changed; presenter called exactly once, succeeded */
    EPD_FLIP_SUPPRESSED = 1,  /* content identical to last presented frame; presenter NOT called */
    EPD_GLUE_ERR_NOT_INIT   = -1,
    EPD_GLUE_ERR_ARG        = -2,
    EPD_GLUE_ERR_SURFACE    = -3,  /* format/stride/dimension mismatch - HARD ERROR */
    EPD_GLUE_ERR_PRESENT    = -4,  /* presenter failed; cache deliberately NOT committed */
};

/* `rot` stays a caller-supplied named constant until orientation is settled off the
 * first recovery frame - see twrp/libepd/ROTATION.md. Never hardcode it silently. */
int  epd_glue_init(epd_presenter_fn present, epd_rotation rot);

/* Call from gr_flip(). Converts, suppresses unchanged content, presents at most once.
 * NEVER retries internally, spawns nothing, and starts no timer. */
int  epd_glue_flip(const epd_surface *src);

void epd_glue_shutdown(void);

/* diagnostics for the dry test / adb logging */
unsigned epd_glue_presents(void);      /* successful presents */
unsigned epd_glue_suppressed(void);    /* flips skipped as unchanged */
unsigned epd_glue_present_calls(void); /* presenter invocations, incl. failures */

#endif /* EPD_GLUE_H */
