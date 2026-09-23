/* libwpaexit.so -- LD_PRELOAD for the vendor wpa_supplicant (Android 8.1 blob) on Android 11.
 *
 * MEASURED 2026-09-24: on SIGTERM (init's stop at every reboot/shutdown) the daemon's own
 * cleanup, wpa_supplicant_deinit -> wpa_supplicant_deinit_iface -> wpa_config_free, frees one
 * entry of its network list twice. Android 8.1's allocator tolerated that; Android 11's Scudo
 * aborts ("invalid chunk state when deallocating") -> a tombstone at every reboot (29 of them).
 * Reproduced on demand with `kill -TERM $(pidof wpa_supplicant)`; turning Wi-Fi off from the UI
 * uses the HIDL terminate() path and exits cleanly, so it is not affected.
 *
 * Fix: when the daemon installs its SIGTERM handler (eloop uses plain signal()), install one
 * that _exit()s instead. Skipped on SIGTERM: disconnect/deauth and interface teardown -- the
 * process is being stopped by init, the system is going down, and the kernel closes every fd.
 * Nothing else is touched.
 *
 * Build: $NDK/armv7a-linux-androideabi27-clang -shared -fPIC -O2 -o libwpaexit.so libwpaexit.c -ldl
 * Install: /vendor/lib/libwpaexit.so + `setenv LD_PRELOAD /vendor/lib/libwpaexit.so` in the
 * wpa_supplicant service (vendor init.common.rc); see wifi/README.md. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

typedef void (*handler_t)(int);

static void fast_exit(int sig) { (void)sig; _exit(0); }

handler_t signal(int sig, handler_t h)
{
    static handler_t (*real)(int, handler_t);
    if (!real) real = (handler_t (*)(int, handler_t))dlsym(RTLD_NEXT, "signal");
    if (!real) return SIG_ERR;
    if (sig == SIGTERM && h != SIG_IGN && h != SIG_DFL) h = fast_exit;
    return real(sig, h);
}
