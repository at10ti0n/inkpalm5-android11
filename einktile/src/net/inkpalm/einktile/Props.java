package net.inkpalm.einktile;
import java.lang.reflect.Method;
/* Runs as the system UID (platform-signed, sharedUserId android.uid.system), so it writes the
 * vendor HWC's refresh properties directly through android.os.SystemProperties -- no root,
 * no shell.  Contract: hwcomposer.virgo.so::displayToScreen reads persist.sys.mRefreshMode per
 * frame; persist.sys.canRefresh=1 is a one-shot full refresh (docs/REFRESH-CONTROL.md). */
public final class Props {
    public static final String MODE = "persist.sys.mRefreshMode";
    public static final String ONESHOT = "persist.sys.canRefresh";
    public static final int TEXT = MODE_TEXT_PLACEHOLDER;        // 2   (DU)   stock "Text"
    public static final int GRAPHICS = MODE_GRAPHICS_PLACEHOLDER; // 132 (0x84) stock "Graphics"
    private static Method sGet, sSet;
    private static void init() throws Exception {
        if (sGet != null) return;
        Class<?> c = Class.forName("android.os.SystemProperties");
        sGet = c.getMethod("get", String.class, String.class);
        sSet = c.getMethod("set", String.class, String.class);
    }
    public static String get(String k){ try { init(); return (String) sGet.invoke(null, k, ""); } catch (Exception e) { return ""; } }
    public static boolean set(String k, String v){ try { init(); sSet.invoke(null, k, v); return true; } catch (Exception e) { return false; } }
}
