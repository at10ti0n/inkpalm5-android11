/* epd_surface - minui surface -> panel-native Y8 conversion for libepd (Gate 1F step 3)
 *
 * Separated from epd.c deliberately: epd.c owns the ION buffer and the single 0x406
 * callsite and must stay small and auditable. All pixel-format and orientation
 * knowledge lives here, where it can be tested offline with zero panel access.
 *
 * NOTHING in this file touches /dev/disp, ION, or the panel. It is pure computation.
 */
#ifndef EPD_SURFACE_H
#define EPD_SURFACE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* Describe the caller's (minui) surface EXPLICITLY. Do not assume RGBA8888:
 * TWRP/minui varies by build (RGBA/BGRA/RGBX/RGB565/8bpp). The integration must
 * fill this in from minui's actual gr_framebuffer/gr_surface at build or runtime. */
typedef enum {
    EPD_PIX_RGBA8888 = 0,   /* byte order R,G,B,A in memory */
    EPD_PIX_BGRA8888,       /* byte order B,G,R,A in memory */
    EPD_PIX_RGBX8888,
    EPD_PIX_BGRX8888,
    EPD_PIX_RGB888,         /* 3 bytes/px */
    EPD_PIX_RGB565,         /* 2 bytes/px, little-endian u16 */
    EPD_PIX_GRAY8,          /* already Y8 */
} epd_pixfmt;

typedef struct {
    const uint8_t *pixels;
    unsigned       width;      /* e.g. 720  (portrait) */
    unsigned       height;     /* e.g. 1280 (portrait) */
    size_t         row_bytes;  /* stride; NOT necessarily width*pixel_bytes */
    epd_pixfmt     format;
} epd_surface;

/* Orientation. UNRESOLVED as of Gate 1F step 3 - both are implemented and must be
 * disambiguated by observation, not by geometry. See twrp/libepd/ROTATION.md. */
typedef enum {
    EPD_ROT_NONE = 0,   /* source is already 1280x720 landscape */
    EPD_ROT_90_CCW,     /* dx = sy;          dy = (W-1) - sx  ; W = src width  */
    EPD_ROT_90_CW,      /* dx = (H-1) - sy;  dy = sx           ; H = src height */
    EPD_ROT_180,
    EPD_ROT_TRANSPOSE,  /* dx = sy;  dy = sx.  OBSERVED CORRECT on EPD105, 2026-09-17:
                         * CCW showed the right way up but MIRRORED left-right, i.e. the
                         * (W-1)-sx term was wrong and the panel wants a plain transpose. */
} epd_rotation;

size_t epd_pixel_bytes(epd_pixfmt f);

/* Convert + rotate into `dst`, which MUST be EPD_SIZE (921600) bytes.
 * Returns true on success. Fails (without writing) on dimension mismatch. */
bool epd_surface_to_y8(const epd_surface *src, epd_rotation rot, uint8_t *dst);

/* ---- content-change guard -------------------------------------------------
 * A recovery UI may call gr_flip() far more often than the content changes, and
 * every present costs a full-screen GC16 (~hundreds of ms of panel time). The
 * integration MUST suppress unchanged frames.
 *
 * epd_frame_changed() returns true only if `frame` differs from the last frame
 * passed to epd_frame_commit(). Call commit() ONLY after a present succeeded, so
 * a failed present does not poison the cache into skipping the retry. */
bool epd_frame_changed(const uint8_t *frame);
void epd_frame_commit(const uint8_t *frame);
void epd_frame_reset(void);     /* forget the last frame; next frame always "changed" */

#endif /* EPD_SURFACE_H */
