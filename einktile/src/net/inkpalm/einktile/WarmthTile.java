package net.inkpalm.einktile;
import android.app.AlertDialog;
import android.content.Context;
import android.os.Handler;
import android.provider.Settings;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
/* Front-light warmth (warm LED bank level 0..24, stock's WarmLedSeekBar range).  Brightness
 * itself is the native Android slider: the replacement lights HAL (frontlight/lights_epd105.c)
 * maps the framework backlight value to the cold bank and reads the warm level from
 * persist.sys.frontlight.warm on every call.  After changing the level we nudge the
 * brightness setting so the framework re-issues the backlight call and the HAL re-applies. */
public class WarmthTile extends TileService {
    static final String PROP = "persist.sys.frontlight.warm";
    static final int MAX = 24;
    private final Handler mH = new Handler();
    private int level() { try { return Math.max(0, Math.min(MAX, Integer.parseInt(Props.get(PROP)))); } catch (Exception e) { return 0; } }
    private void refresh() {
        Tile t = getQsTile(); if (t == null) return;
        int l = level();
        t.setLabel("Warmth: " + l);
        t.setState(l > 0 ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        t.updateTile();
    }
    @Override public void onStartListening() { refresh(); }
    @Override public void onClick() {
        final Context c = this;
        LinearLayout box = new LinearLayout(c); box.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (16 * getResources().getDisplayMetrics().density); box.setPadding(pad, pad, pad, 0);
        final TextView label = new TextView(c); label.setGravity(Gravity.CENTER); label.setTextSize(18);
        final SeekBar bar = new SeekBar(c); bar.setMax(MAX); bar.setProgress(level());
        label.setText("Warm light: " + bar.getProgress() + " / " + MAX);
        bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onProgressChanged(SeekBar s, int p, boolean u) { label.setText("Warm light: " + p + " / " + MAX); if (u) apply(p); }
            public void onStartTrackingTouch(SeekBar s) {}
            public void onStopTrackingTouch(SeekBar s) { apply(s.getProgress()); }
        });
        box.addView(label); box.addView(bar);
        AlertDialog d = new AlertDialog.Builder(c).setTitle("Front light warmth").setView(box)
            .setPositiveButton("Done", null).create();
        showDialog(d);
    }
    private void apply(int p) {
        Props.set(PROP, String.valueOf(p));
        // Re-issue the framework backlight call: the HAL only runs when brightness changes.
        try {
            final int cur = Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 100);
            final int bump = cur >= 255 ? cur - 1 : cur + 1;
            Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, bump);
            mH.postDelayed(new Runnable() { public void run() {
                Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, cur); } }, 250);
        } catch (Exception e) {}
        refresh();
    }
}
