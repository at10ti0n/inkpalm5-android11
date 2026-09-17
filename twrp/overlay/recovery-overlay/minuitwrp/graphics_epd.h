/* graphics_epd - EPD-native minui backend for Moaan EPD105 (Gate 1F-3b) */
#ifndef GRAPHICS_EPD_H
#define GRAPHICS_EPD_H

/* At integration define EPD_USE_REAL_MINUI so this binds to the genuine upstream
 * headers. The shim exists only so the backend can be compiled and dry-tested with
 * no TWRP tree present; its ABI is asserted equivalent by twrp/minuitwrp/abicheck.cpp. */
#ifdef EPD_USE_REAL_MINUI
#  include <linux/types.h>
#  include "graphics.h"        /* real minuitwrp/graphics.h -> real minui.h */
#else
#  include "minui_shim.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* The only backend on EPD105. Never use open_fbdev() on this device: the panel does
 * not consume /dev/graphics/fb0 (Gate 1A), and the stock fbdev backend would blank
 * the framebuffer, derive pixel_bytes from a 24-bpp vinfo, and copy to fb0 on every
 * flip - all pointless here and all able to break EPD correctness for no benefit. */
struct minui_backend *open_epd(void);

/* PRESENTATION ARM. gr_init() in this TWRP base calls gr_flip() TWICE before it
 * returns. Until epd_backend_arm() is called, flip() returns the drawing surface and
 * performs NO conversion, NO ion_sync_fd and NO 0x406. This is an explicit state, NOT
 * a "skip the first two flips" counter - a counter would be brittle against any change
 * in TWRP's startup path.
 *
 * ARM POINT (resolved from the pinned gui/gui.cpp). gui_init() does:
 *     gr_init();                       <- the two unwanted flips, structurally inert
 *     PageManager::SelectPackage("splash");
 *     PageManager::Render();
 *     epd_backend_arm();               <- EPD105 only, HERE
 *     flip();                          <- first eligible hardware present
 *     PageManager::ReleasePackage("splash");
 * Arming after a complete GUI frame has been rendered, and not one instruction earlier. */
void epd_backend_arm(void);

/* ARM-ONCE - optional diagnostic mode, not selected by the continuous GUI build.
 * Presents the first CHANGED frame, and on success AUTOMATICALLY DISARMS. Every later
 * flip is software-only with zero 0x406.
 *
 * Rationale: past the splash, TWRP's runPages() is a render loop (PageManager::Update,
 * conditional Render, flip on state change, ~30Hz/2Hz timing). The content-change guard
 * suppresses identical frames, but startup legitimately produces several DIFFERENT ones.
 * The first panel-bearing recovery boot must not also be the first test of repeat
 * behaviour: we want exactly ONE physically observable submission, with no possibility
 * of a render loop emitting a series of GC16 updates.
 *
 * A FAILED present does NOT disarm - the retry remains eligible, matching the
 * commit-only-on-success rule in epd_glue. */
void epd_backend_arm_once(void);

/* true once arm-once has fired and auto-disarmed */
bool epd_backend_spent(void);

/* diagnostics (adb-visible; also asserted by the dry test) */
bool     epd_backend_armed(void);
bool     epd_backend_display_ok(void);   /* false => epd_init() failed; recovery still runs */
unsigned epd_backend_flips(void);        /* every flip() call */
unsigned epd_backend_preflips(void);     /* flips that returned early because unarmed */

#ifdef __cplusplus
}
#endif
#endif
