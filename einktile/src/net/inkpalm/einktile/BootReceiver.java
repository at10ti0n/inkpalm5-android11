package net.inkpalm.einktile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
/* Starts ScreenTempService at boot and after an app update. */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) { ScreenTempService.start(c); }
}
