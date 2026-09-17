/* lights.virgo.so replacement for the Moaan InkPalm 5 Pro Mini (EPD105) on Android 11.
 *
 * The vendor module drives the LCD backlight through /dev/disp, which on this E-Ink board
 * goes nowhere.  The real front light is a TI LM3630A (two banks: cold + warm) whose
 * kernel driver exposes /proc/lm3630a/{pwm_level,leda_max_cur,leda_brightness,
 * ledb_max_cur,ledb_brightness}.  Stock 8.1 SystemUI wrote those five nodes from
 * per-level lookup tables (led107.LedParamControl); the tables are reproduced verbatim in
 * frontlight_tables.h.
 *
 * Framework contract (android.hardware.light@2.0 default impl -> legacy lights HAL):
 *   set_light(BACKLIGHT, color)   color 0xAARRGGBB -> brightness 0..255
 * We map brightness 0..255 -> cold level 0..24, take the warm level from the property
 * persist.sys.frontlight.warm (0..24), and write the nodes exactly like stock
 * setLedValue().  Brightness 0 (screen off / doze) turns both banks off, so the native
 * screen timeout and AOD also switch the light off, and the slider restores it.
 *
 * Only the backlight light is offered; every other light type reports "unavailable".
 * Build (NDK r2x):
 *   armv7a-linux-androideabi28-clang -shared -fPIC -O2 -Wl,-z,now \
 *       -o lights.virgo.so lights_epd105.c -llog
 * Install: /vendor/lib/hw/lights.virgo.so (keep the stock one as lights.virgo.so.stock).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/system_properties.h>
#include <android/log.h>
#include "frontlight_tables.h"

#define TAG "lights.epd105"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* ---- hardware/hardware.h + hardware/lights.h, 32-bit ABI, no AOSP tree needed ---- */
#define HARDWARE_MODULE_TAG 0x48574D54u   /* 'HWMT' */
#define HARDWARE_DEVICE_TAG 0x48574454u   /* 'HWDT' */
struct hw_module_t;
struct hw_device_t;
struct hw_module_methods_t { int (*open)(const struct hw_module_t*, const char*, struct hw_device_t**); };
struct hw_module_t {
    uint32_t tag; uint16_t module_api_version; uint16_t hal_api_version;
    const char *id, *name, *author; struct hw_module_methods_t *methods; void *dso;
    uint32_t reserved[32 - 7];
};
struct hw_device_t {
    uint32_t tag; uint32_t version; struct hw_module_t *module;
    uint32_t reserved[12]; int (*close)(struct hw_device_t*);
};
struct light_state_t { unsigned color; int flashMode, flashOnMS, flashOffMS, brightnessMode; };
struct light_device_t {
    struct hw_device_t common;
    int (*set_light)(struct light_device_t*, const struct light_state_t*);
};

#define PROC "/proc/lm3630a/"
#define WARM_PROP "persist.sys.frontlight.warm"
#define MAX_LEVEL (FL_LEVELS - 1)
/* The framework never sends 0 while the display is in DOZE (AOD sleep screen): it clamps
 * the doze brightness to config_screenBrightnessSettingMinimum, which is also the lowest
 * value the user slider can produce (10 on the GSI, MEASURED: doze -> backlight 10).  On
 * an E-Ink reader "as dim as the slider goes" means off, so <= OFF_AT is off; the slider
 * then spans 11..255 -> cold 1..24.  Set persist.sys.frontlight.off_at to override. */
#define OFF_AT_DEFAULT 10

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_last_cold = -1, g_last_warm = -1;

static int write_node(const char *name, int v)
{
    char path[64], buf[16]; int fd, n, len;
    snprintf(path, sizeof path, PROC "%s", name);
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) { LOGE("open %s: %s", path, strerror(errno)); return -errno; }
    len = snprintf(buf, sizeof buf, "%d", v);
    n = write(fd, buf, len);
    close(fd);
    if (n != len) { LOGE("write %s=%d: %s", path, v, strerror(errno)); return -1; }
    return 0;
}

static int off_at(void)
{
    char v[PROP_VALUE_MAX] = "";
    if (__system_property_get("persist.sys.frontlight.off_at", v) > 0) return atoi(v);
    return OFF_AT_DEFAULT;
}

static int warm_level(void)
{
    char v[PROP_VALUE_MAX] = "0"; int w;
    __system_property_get(WARM_PROP, v);
    w = atoi(v);
    return w < 0 ? 0 : w > MAX_LEVEL ? MAX_LEVEL : w;
}

/* Same five writes, same order, same tables as stock FunctionSettingsControl.setLedValue. */
static int apply(int cold, int warm)
{
    int rc = 0;
    rc |= write_node("pwm_level",       PWM_VALUE[warm][cold]);
    rc |= write_node("leda_max_cur",    COLD_CURRENT[warm][cold]);
    rc |= write_node("leda_brightness", COLD_BRIGHTNESS[warm][cold]);
    rc |= write_node("ledb_max_cur",    WARM_CURRENT[warm][cold]);
    rc |= write_node("ledb_brightness", WARM_BRIGHTNESS[warm][cold]);
    return rc;
}

static int set_backlight(struct light_device_t *dev, const struct light_state_t *st)
{
    (void)dev;
    unsigned c = st->color;
    int b = ((77 * ((c >> 16) & 0xff)) + (150 * ((c >> 8) & 0xff)) + (29 * (c & 0xff))) >> 8;
    int lo = off_at();
    int cold = b <= lo ? 0 : 1 + (b - lo - 1) * MAX_LEVEL / (255 - lo);   /* lo+1..255 -> 1..24 */
    int warm = b <= lo ? 0 : warm_level();                              /* off/doze: both banks off */
    int rc;
    pthread_mutex_lock(&g_lock);
    if (cold != g_last_cold || warm != g_last_warm) {
        rc = apply(cold, warm);
        LOGI("backlight %d -> cold %d warm %d%s", b, cold, warm, rc ? " (write error)" : "");
        g_last_cold = cold; g_last_warm = warm;
    } else rc = 0;
    pthread_mutex_unlock(&g_lock);
    return rc;
}

static int dev_close(struct hw_device_t *d) { free(d); return 0; }

static int module_open(const struct hw_module_t *m, const char *name, struct hw_device_t **out)
{
    if (strcmp(name, "backlight") != 0) return -EINVAL;   /* LIGHT_ID_BACKLIGHT only */
    struct light_device_t *dev = calloc(1, sizeof *dev);
    if (!dev) return -ENOMEM;
    dev->common.tag = HARDWARE_DEVICE_TAG;
    dev->common.version = 0;
    dev->common.module = (struct hw_module_t*)m;
    dev->common.close = dev_close;
    dev->set_light = set_backlight;
    *out = &dev->common;
    LOGI("opened backlight -> " PROC " (warm level from " WARM_PROP ")");
    return 0;
}

static struct hw_module_methods_t g_methods = { .open = module_open };

__attribute__((visibility("default")))
struct hw_module_t HMI = {
    .tag = HARDWARE_MODULE_TAG,
    .module_api_version = 0x0100,   /* HARDWARE_MODULE_API_VERSION(1,0) */
    .hal_api_version = 0,
    .id = "lights",
    .name = "EPD105 LM3630A front light",
    .author = "inkpalm5-android11",
    .methods = &g_methods,
};
