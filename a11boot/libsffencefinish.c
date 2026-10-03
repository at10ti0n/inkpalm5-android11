/* libsffencefinish -- EXPERIMENT (2026-10-04), LD_PRELOAD for surfaceflinger only.
 *
 * MEASURED: the vendor composer's commit thread logs "normal commit start" and then waits ~3.0 s
 * before committing the frame whenever the screen had been idle (101.603 -> 104.607,
 * 106.135 -> 109.138); in a burst the same step takes ~7 ms. That is a timed-out wait on the
 * layer's acquire fence: the native fence of SurfaceFlinger's GPU composition.
 * Hypothesis: this Mali Utgard (r8p1) driver does not start the GPU job when RenderEngine calls
 * glFlush() on its offscreen composition, only with later GL work, so the last frame of a burst
 * (the keystroke you are waiting to see) does not signal until the composer gives up.
 *
 * GLESRenderEngine::flush() creates an EGL_SYNC_NATIVE_FENCE_ANDROID, glFlush()es and then
 * calls eglDupNativeFenceFDANDROID(). This shim runs glFinish() at that moment, so the GPU work
 * is complete and the fence it hands out is already signalled. Nothing else changes.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

typedef EGLint (*dup_fn)(EGLDisplay, EGLSyncKHR);
EGLint eglDupNativeFenceFDANDROID(EGLDisplay dpy, EGLSyncKHR sync) {
    static dup_fn real; static void (*fin)(void);
    if (!real) real = (dup_fn)dlsym(RTLD_NEXT, "eglDupNativeFenceFDANDROID");
    if (!fin) { void *h = dlopen("libGLESv2.so", RTLD_NOW); if (h) fin = (void (*)(void))dlsym(h, "glFinish"); }
    if (fin) fin();
    return real ? real(dpy, sync) : EGL_NO_NATIVE_FENCE_FD_ANDROID;
}
