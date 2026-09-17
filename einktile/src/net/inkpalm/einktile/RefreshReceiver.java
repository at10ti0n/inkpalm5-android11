package net.inkpalm.einktile;
import android.content.*;
/* Native hook for reading apps: the stock intent android.eink.force.refresh triggers one
 * full-quality refresh, exactly as stock's SystemUI RefreshTile intended. */
public class RefreshReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i){ Props.set(Props.ONESHOT, "1"); }
}
