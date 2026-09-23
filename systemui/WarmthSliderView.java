package com.android.systemui.inkpalm;

import android.content.ContentResolver;
import android.content.Context;
import android.os.Handler;
import android.provider.Settings;
import android.util.AttributeSet;
import android.widget.SeekBar;

/**
 * The Screen Temperature row in the Quick Settings panel, directly under brightness
 * (res/layout/quick_settings_brightness_dialog.xml).
 *
 * Since 2026-09-24 Screen Temperature IS Android 11's Night Light: einktile's
 * ScreenTempService maps Night Light's state and colour temperature onto the front light's
 * warm LED bank, and overlays/screentemp-fw makes Night Light's pixel tint identity (on a
 * greyscale panel the tint only darkened). This row is therefore a front end to Night Light
 * rather than to the LED property, so it always agrees with the Screen Temperature tile, the
 * Settings page and the schedule:
 *
 *   position 0      Night Light off
 *   position 1..24  Night Light on, temperature from config Max (1, mildest) to Min (24, warmest)
 *
 * The view wires itself up in its constructor, so no QSPanel patch is needed and it carries no
 * resource id of its own -- nothing in the SystemUI resource table changes.
 */
public class WarmthSliderView extends SeekBar implements SeekBar.OnSeekBarChangeListener {

    private static final String ACTIVATED = "night_display_activated";
    private static final String TEMP = "night_display_color_temperature";
    private static final int MAX_LEVEL = 24;
    private static final long THROTTLE_MS = 300L;

    private final Handler mHandler = new Handler();
    private long mLastApply;
    private boolean mPendingApply;

    public WarmthSliderView(Context context) { this(context, null); }

    public WarmthSliderView(Context context, AttributeSet attrs) {
        super(context, attrs);
        setMax(MAX_LEVEL);
        setProgress(readLevel());
        setOnSeekBarChangeListener(this);
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        // The panel is re-shown rather than re-created, so re-read on every open.
        setProgress(readLevel());
    }

    private static int clamp(int v) { return v < 0 ? 0 : (v > MAX_LEVEL ? MAX_LEVEL : v); }

    private static int sysInt(String name, int dflt) {
        android.content.res.Resources r = android.content.res.Resources.getSystem();
        int id = r.getIdentifier(name, "integer", "android");
        try { return id != 0 ? r.getInteger(id) : dflt; } catch (Exception e) { return dflt; }
    }
    private static int tMin() { return sysInt("config_nightDisplayColorTemperatureMin", 2596); }
    private static int tMax() { return sysInt("config_nightDisplayColorTemperatureMax", 4082); }

    private int readLevel() {
        ContentResolver cr = getContext().getContentResolver();
        if (Settings.Secure.getInt(cr, ACTIVATED, 0) != 1) return 0;
        int min = tMin(), max = tMax();
        int t = Settings.Secure.getInt(cr, TEMP, sysInt("config_nightDisplayColorTemperatureDefault", 2850));
        if (max <= min) return MAX_LEVEL;
        float f = (float) (max - Math.max(min, Math.min(max, t))) / (max - min);
        return clamp(1 + Math.round(f * (MAX_LEVEL - 1)));
    }

    /** Level 0 turns Night Light off; 1..24 sets its temperature and turns it on. */
    private void apply(int level) {
        ContentResolver cr = getContext().getContentResolver();
        try {
            if (level <= 0) {
                Settings.Secure.putInt(cr, ACTIVATED, 0);
            } else {
                int min = tMin(), max = tMax();
                int t = max - Math.round((float) (level - 1) * (max - min) / (MAX_LEVEL - 1));
                Settings.Secure.putInt(cr, TEMP, t);
                if (Settings.Secure.getInt(cr, ACTIVATED, 0) != 1) Settings.Secure.putInt(cr, ACTIVATED, 1);
            }
        } catch (Exception e) { /* nothing else to do */ }
        mLastApply = System.currentTimeMillis();
        mPendingApply = false;
    }

    /** Live while dragging, but not on every pixel -- each apply costs a panel refresh. */
    private void applyThrottled(final int level) {
        long now = System.currentTimeMillis();
        if (now - mLastApply >= THROTTLE_MS) {
            apply(level);
        } else if (!mPendingApply) {
            mPendingApply = true;
            mHandler.postDelayed(new Runnable() {
                public void run() { if (mPendingApply) apply(getProgress()); }
            }, THROTTLE_MS - (now - mLastApply));
        }
    }

    public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
        if (fromUser) applyThrottled(clamp(progress));
    }

    public void onStartTrackingTouch(SeekBar bar) { }

    public void onStopTrackingTouch(SeekBar bar) { apply(clamp(bar.getProgress())); }
}
