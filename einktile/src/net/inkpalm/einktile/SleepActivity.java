package net.inkpalm.einktile;
import android.app.Activity;
import android.content.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
import java.text.SimpleDateFormat;
import java.util.Date;
/* E-Ink sleep page: shown by the boot fixups loop just before the device sleeps, so the
 * panel holds a clear "asleep" image instead of the last app.  Finishes itself on wake. */
public class SleepActivity extends Activity {
    private final BroadcastReceiver wake = new BroadcastReceiver(){ @Override public void onReceive(Context c, Intent i){ finish(); } };
    @Override protected void onCreate(Bundle b){
        super.onCreate(b);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN, WindowManager.LayoutParams.FLAG_FULLSCREEN);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_HIDE_NAVIGATION|View.SYSTEM_UI_FLAG_FULLSCREEN|View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        LinearLayout l=new LinearLayout(this); l.setOrientation(LinearLayout.VERTICAL); l.setGravity(Gravity.CENTER); l.setBackgroundColor(Color.WHITE);
        TextView t=new TextView(this); t.setText(new SimpleDateFormat("HH:mm").format(new Date())); t.setTextSize(96); t.setTextColor(Color.BLACK); t.setTypeface(Typeface.DEFAULT_BOLD); t.setGravity(Gravity.CENTER);
        TextView d=new TextView(this); d.setText(new SimpleDateFormat("EEEE, d MMMM").format(new Date())); d.setTextSize(24); d.setTextColor(Color.BLACK); d.setGravity(Gravity.CENTER);
        TextView h=new TextView(this); h.setText("\n\n\nsleeping  —  press the power button to wake"); h.setTextSize(16); h.setTextColor(Color.DKGRAY); h.setGravity(Gravity.CENTER);
        l.addView(t); l.addView(d); l.addView(h); setContentView(l);
        registerReceiver(wake, new IntentFilter(Intent.ACTION_SCREEN_ON));
    }
    @Override protected void onDestroy(){ try{ unregisterReceiver(wake);}catch(Exception e){} super.onDestroy(); }
}
