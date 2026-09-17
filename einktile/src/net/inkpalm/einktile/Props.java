package net.inkpalm.einktile;
import java.io.*;
/* Writes the vendor HWC's refresh properties via PHH's su (root shell). MEASURED contract:
 * hwcomposer.virgo.so::displayToScreen reads persist.sys.mRefreshMode per frame and
 * persist.sys.canRefresh=1 as a one-shot full refresh that self-clears (a11/gate15/REFRESH-CONTROL.md). */
public final class Props {
    public static final String MODE = "persist.sys.mRefreshMode";
    public static final String ONESHOT = "persist.sys.canRefresh";
    // Stock Android 8.1 SystemUI RefreshTile values -- filled from the Ghidra decompile.
    public static final int TEXT = MODE_TEXT_PLACEHOLDER;
    public static final int GRAPHICS = MODE_GRAPHICS_PLACEHOLDER;
    public static String get(String k){ try{ Process p=Runtime.getRuntime().exec(new String[]{"getprop",k}); BufferedReader r=new BufferedReader(new InputStreamReader(p.getInputStream())); String s=r.readLine(); p.waitFor(); return s==null?"":s.trim(); }catch(Exception e){ return ""; } }
    public static boolean set(String k,String v){ try{ Process p=Runtime.getRuntime().exec(new String[]{"su","-c","setprop "+k+" "+v}); return p.waitFor()==0; }catch(Exception e){ return false; } }
}
