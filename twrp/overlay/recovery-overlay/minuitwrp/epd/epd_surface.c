#include <string.h>
#include "epd.h"
#include "epd_surface.h"

size_t epd_pixel_bytes(epd_pixfmt f)
{
    switch (f) {
    case EPD_PIX_RGBA8888: case EPD_PIX_BGRA8888:
    case EPD_PIX_RGBX8888: case EPD_PIX_BGRX8888: return 4;
    case EPD_PIX_RGB888:                          return 3;
    case EPD_PIX_RGB565:                          return 2;
    case EPD_PIX_GRAY8:                           return 1;
    }
    return 0;
}

/* Fixed integer luminance. No alpha blending: minui composites its UI before
 * gr_flip(), so the surface handed to us is already flattened. If a future minui
 * build genuinely delivers unpremultiplied alpha, handle it in the integration
 * layer - NOT here, and NOT silently. */
static inline uint8_t luma(unsigned r, unsigned g, unsigned b)
{
    return (uint8_t)((77u * r + 150u * g + 29u * b) >> 8);
}

static inline uint8_t sample(const uint8_t *p, epd_pixfmt f)
{
    switch (f) {
    case EPD_PIX_RGBA8888: case EPD_PIX_RGBX8888: return luma(p[0], p[1], p[2]);
    case EPD_PIX_BGRA8888: case EPD_PIX_BGRX8888: return luma(p[2], p[1], p[0]);
    case EPD_PIX_RGB888:                          return luma(p[0], p[1], p[2]);
    case EPD_PIX_RGB565: {
        unsigned v = (unsigned)p[0] | ((unsigned)p[1] << 8);
        unsigned r = (v >> 11) & 0x1f, g = (v >> 5) & 0x3f, b = v & 0x1f;
        return luma((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
    }
    case EPD_PIX_GRAY8:                           return p[0];
    }
    return 0;
}

bool epd_surface_to_y8(const epd_surface *src, epd_rotation rot, uint8_t *dst)
{
    if (!src || !src->pixels || !dst) return false;
    const size_t pb = epd_pixel_bytes(src->format);
    if (!pb) return false;
    if (src->row_bytes < (size_t)src->width * pb) return false;

    const unsigned W = src->width, H = src->height;

    /* dimensions must land exactly on the panel after rotation */
    if (rot == EPD_ROT_NONE || rot == EPD_ROT_180) {
        if (W != EPD_WIDTH || H != EPD_HEIGHT) return false;
    } else {
        if (W != EPD_HEIGHT || H != EPD_WIDTH) return false;
    }

    for (unsigned sy = 0; sy < H; sy++) {
        const uint8_t *row = src->pixels + (size_t)sy * src->row_bytes;
        for (unsigned sx = 0; sx < W; sx++) {
            const uint8_t y = sample(row + (size_t)sx * pb, src->format);
            unsigned dx, dy;
            switch (rot) {
            case EPD_ROT_NONE:   dx = sx;              dy = sy;              break;
            case EPD_ROT_180:    dx = (W - 1) - sx;    dy = (H - 1) - sy;    break;
            /* src is WxH portrait; dst is EPD_WIDTH x EPD_HEIGHT landscape.
             * The destination bound for dy is W-1 (not H-1) and for dx is H-1. */
            case EPD_ROT_90_CCW: dx = sy;              dy = (W - 1) - sx;    break;
            case EPD_ROT_90_CW:  dx = (H - 1) - sy;    dy = sx;              break;
            case EPD_ROT_TRANSPOSE: dx = sy;           dy = sx;              break;
            default: return false;
            }
            dst[(size_t)dy * EPD_WIDTH + dx] = y;
        }
    }
    return true;
}

/* ---- content-change guard ---- */
static uint8_t  last_frame[EPD_SIZE];
static bool     have_last;

bool epd_frame_changed(const uint8_t *frame)
{
    if (!frame) return false;
    if (!have_last) return true;
    return memcmp(frame, last_frame, EPD_SIZE) != 0;
}

void epd_frame_commit(const uint8_t *frame)
{
    if (!frame) return;
    memcpy(last_frame, frame, EPD_SIZE);
    have_last = true;
}

void epd_frame_reset(void) { have_last = false; }
