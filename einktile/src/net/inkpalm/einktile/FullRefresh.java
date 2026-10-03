package net.inkpalm.einktile;
import android.os.IBinder;
import android.os.Parcel;
import android.util.Log;
/* One full E Ink refresh (the black/white clearing flash), for the Refresh tile, the long-press
 * logo and the stock android.eink.force.refresh broadcast.
 * The composer applies persist.sys.canRefresh by drawing the next frame in the CURRENT
 * persist.sys.mRefreshMode (docs/REFRESH-CONTROL.md) -- DU in Text, GU16 in Graphics, neither of
 * which flashes -- and only when a frame comes (MEASURED 2026-10-04: v7's refresh did nothing
 * visible). So: switch to GC16 (4), set the one-shot, ask SurfaceFlinger to repaint
 * (transaction 1004, as `service call SurfaceFlinger 1004`), wait until the composer has consumed
 * the one-shot, restore the user's mode. MEASURED: composer drew mode=4, user saw the flash. */
public final class FullRefresh {
    private static final int GC16 = 4;
    private static volatile boolean busy;
    public static void run() {
        if (busy) return;
        busy = true;
        new Thread(new Runnable() { @Override public void run() {
            String prev = Props.get(Props.MODE);
            try {
                Props.set(Props.MODE, Integer.toString(GC16));
                Props.set(Props.ONESHOT, "1");
                repaint();
                for (int i = 0; i < 50 && "1".equals(Props.get(Props.ONESHOT)); i++) Thread.sleep(30);
                Thread.sleep(100);
            } catch (InterruptedException ignored) {
            } finally {
                Props.set(Props.MODE, prev.isEmpty() || prev.equals(Integer.toString(GC16)) ? Integer.toString(Props.TEXT) : prev);
                busy = false;
            }
        }}, "einktile-refresh").start();
    }
    static void repaint() {
        Parcel data = Parcel.obtain();
        try {
            IBinder sf = (IBinder) Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String.class).invoke(null, "SurfaceFlinger");
            data.writeInterfaceToken("android.ui.ISurfaceComposer");
            sf.transact(1004, data, null, 0);
        } catch (Exception e) {
            Log.w("einktile", "repaint request failed: " + e);
        } finally {
            data.recycle();
        }
    }
}
