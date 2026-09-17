/* libepd - recovery-native E-Ink display backend for Moaan InkPalm 5 Pro (EPD105)
 *
 * Derived from the physically validated Gate 1E-f submission primitive.
 * Contract proven end to end on hardware 2026-08-25; see
 * twrp/analysis/GATE1E-F-RESULT.md and GATE1E-D-STATIC-ROOTCAUSE.md.
 *
 *   panel   1280x720 landscape, Y8, 1 byte/pixel, 0x00 = black, 0xff = white
 *   source  disp_layer_config2.info.fb.y8_fd  (user offset 36)
 *   mode    EINK_GC16_MODE (0x04), full screen
 *
 * DELIBERATE DEPARTURE FROM THE ONE-SHOT SAFETY PROPERTY
 * -----------------------------------------------------
 * Every panel-facing binary before this one was structurally incapable of more than
 * one DISP_EINK_UPDATE2. A display backend is repeat-capable BY DEFINITION - that is
 * what a display backend is. The one-shot property is therefore replaced, not dropped:
 *
 *   - the ioctl still appears at EXACTLY ONE callsite in the whole library
 *   - epd_present_y8() is the ONLY way to reach it, and refuses unless initialised
 *   - the layer config is built ONCE in epd_init() and validated against the golden
 *     fixture there; epd_present_y8() never rebuilds or mutates it
 *   - no timer, no thread, no internal repaint. The caller decides when to present.
 *
 * FAIL-CLOSED CALIBRATION POLICY (Gate 1F step 1, frozen)
 * ------------------------------------------------------
 * /private holds this panel's waveform AND its VCOM. epd_init() verifies both are
 * readable and sane BEFORE any ION allocation or ioctl. If they are not, epd_init()
 * FAILS and no refresh is ever attempted. We do NOT fall through to the kernel's
 * /system/default.bin fallback: that is a different waveform revision (R182 vs R260
 * on this unit) and driving the panel with it is not acceptable.
 */
#ifndef EPD_H
#define EPD_H

#include <stdint.h>
#include <stddef.h>

#define EPD_WIDTH   1280
#define EPD_HEIGHT   720
#define EPD_BPP        1                        /* Y8 */
#define EPD_SIZE   ((size_t)EPD_WIDTH * EPD_HEIGHT * EPD_BPP)   /* 921600 */

#define EPD_WHITE  0xff
#define EPD_BLACK  0x00

/* calibration, per the frozen Gate 1F policy - these are DT-configured paths */
#define EPD_WAVEFORM_PATH "/private/default.bin"
#define EPD_VCOM_PATH     "/private/vcom.bin"

enum {
    EPD_OK               =  0,
    EPD_ERR_ALREADY      = -1,
    EPD_ERR_NOT_INIT     = -2,
    EPD_ERR_CALIBRATION  = -3,   /* /private waveform or vcom missing/unreadable/insane */
    EPD_ERR_ION          = -4,
    EPD_ERR_DISP         = -5,
    EPD_ERR_FIXTURE      = -6,   /* layer config failed the golden-fixture guard */
    EPD_ERR_IOCTL        = -7,
    EPD_ERR_ARG          = -8,
};

/* Verify calibration, allocate ONE long-lived cached ION buffer, open /dev/disp,
 * build and validate the layer config. Returns EPD_OK or a negative EPD_ERR_*.
 * Safe to call once; returns EPD_ERR_ALREADY if already initialised. */
int  epd_init(void);

/* Copy a full-screen Y8 frame and present it with a single GC16 full-screen update.
 * `pixels` must point to EPD_SIZE bytes, panel-native orientation (1280x720 landscape).
 * Rotation from the caller's surface is the CALLER's responsibility.
 * Blocks only for the copy + ioctl; does not wait for the panel to settle. */
int  epd_present_y8(const uint8_t *pixels);

/* Release the ION buffer and /dev/disp. Idempotent. */
void epd_shutdown(void);

/* Diagnostics: last errno seen, and a human-readable name for an EPD_ERR_* code. */
int         epd_last_errno(void);
const char *epd_strerror(int code);

#endif /* EPD_H */
