package net.inkpalm.einktile;
import android.accessibilityservice.AccessibilityService;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import android.view.ViewConfiguration;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;
/* Long-press Home (the capacitive Moaan logo) = one full E Ink refresh; a short press is
 * still Home. An accessibility service is the only unprivileged place that sees Home before
 * the window manager acts on it. While Home is down it is held back; released before
 * the long-press timeout it is replayed as the Home global action; held past it, it refreshes
 * instead.
 * Screen off: not touched, so the logo still wakes the device as before. Enabled by the
 * installer (enabled_accessibility_services); turn off in Settings > Accessibility. */
public class HomeKeyService extends AccessibilityService {
    private final Handler h = new Handler(Looper.getMainLooper());
    private boolean down, fired;
    private final Runnable longPress = new Runnable() {
        @Override public void run(){ refresh(); }
    };
    @Override protected boolean onKeyEvent(KeyEvent e){
        if (e.getKeyCode() != KeyEvent.KEYCODE_HOME) return false;
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        if (!down && (pm == null || !pm.isInteractive())) return false;
        if (e.getAction() == KeyEvent.ACTION_DOWN) {
            if (e.getRepeatCount() == 0 && !down) {
                down = true; fired = false;
                h.postDelayed(longPress, ViewConfiguration.getLongPressTimeout());
            } else if (down && (e.getFlags() & KeyEvent.FLAG_LONG_PRESS) != 0) {
                h.removeCallbacks(longPress); refresh();
            }
            return true;
        }
        if (e.getAction() == KeyEvent.ACTION_UP && down) {
            down = false; h.removeCallbacks(longPress);
            if (!fired && !e.isCanceled()) performGlobalAction(GLOBAL_ACTION_HOME);
            return true;
        }
        return false;
    }
    private void refresh(){
        if (fired) return;
        fired = true; Props.set(Props.ONESHOT, "1"); Log.i("einktile", "long-press Home: full refresh");
    }
    @Override public void onAccessibilityEvent(AccessibilityEvent e){}
    @Override public void onInterrupt(){ h.removeCallbacks(longPress); down = false; }
}
