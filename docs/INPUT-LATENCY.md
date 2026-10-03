# Input latency: the 3-second composer wait (fixed 2026-10-04)

**Symptom.** Typing (and any interaction) reached the E Ink panel 1.5-3 s after the tap, in
bursts. The waveform made no difference (Text/DU and A2 measured the same).

**Measured.** Same capture each time (Settings search box, six taps, `dumpsys SurfaceFlinger
--latency` plus the frame-mirror's per-update trace, `vendor.hwcflip.trace=1`):

| | Stock | wait_sync hidden | **Fix** | Stock again (control) |
|---|---|---|---|---|
| App frame ready -> shown, max | 3447 ms | 3105 ms | **185 ms** | 3204 ms |
| Frames over 1 s | 27/64 | 31/92 | **0/127** | 23/80 |
| Panel gaps over 2 s | 8 | 8 | **0** | 7 |
| Tap -> first panel update | 1.5-3.0 s | 0.03-2.7 s | **62-170 ms** | 0.14-2.7 s |

**Cause.** The app's frames were ready on time; SurfaceFlinger showed them late. The vendor
composer's commit thread logged `normal commit start`, then waited **exactly 3.0 s** before
committing whenever the screen had been idle (~7 ms inside a burst): a timed-out wait on the
layer's acquire fence, i.e. the native fence of SurfaceFlinger's GPU composition (Colors =
Boosted makes every frame GPU-composed). This Mali-400 MP (Utgard, driver r8p1) does not run the
job when RenderEngine `glFlush()`es its offscreen composition, only with later GL work, so the
last frame of every burst -- the keystroke you are waiting to see -- waited for the timeout.
Earlier, SurfaceFlinger itself also blocked on that fence ("Throttling EGL Production").

**Fix.** `a11boot/libsffencefinish.c`, LD_PRELOADed into surfaceflinger only (one `setenv` line in
`/system/etc/init/surfaceflinger.rc`, added by the installer to the GSI's own file, original kept in
`/data/local/surfaceflinger.rc.stock`). It interposes `eglDupNativeFenceFDANDROID`, which
GLESRenderEngine::flush() calls right after `glFlush()`, and runs `glFinish()` first, so the fence
the composer receives is already signalled. SurfaceFlinger now waits for the GPU on every frame;
in the measurements frames stay well inside the 62.5 ms period.

**Side effects.** With frames this fast, SurfaceFlinger shows only the newest frame per refresh:
a keyboard key popup that lasts less than one refresh may not be shown at all when typing fast
(raise *Key popup dismiss delay* in the keyboard's settings if you want to see every one).

**Things that were not the cause:** the keyboard app, CPU speed, the waveform, the panel driver
(its UPDATE2 call takes ~20 ms), GPU-side waiting on imported fences (hiding `EGL_KHR_wait_sync`
changed nothing). An earlier attempt that hid `EGL_ANDROID_native_fence_sync` while
`EGL_KHR_wait_sync` stayed advertised blanked the screen: Android 11's
`bindExternalTextureBuffer` then fails every layer bind.

Full investigation, raw traces and scripts: the handoff package
`handoff-display-latency-2026-10-04` in the project workspace (not in this repository).

**Still open, separate:** the frame mirror copies pixel by pixel, 27-60 ms per update
(`a11boot/libhwcflip.c`, `flip_rows_copy`); a row-wise copy would cut that to a few ms.
