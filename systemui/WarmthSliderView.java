package com.android.systemui.inkpalm;

import android.content.ContentResolver;
import android.content.Context;
import android.os.Handler;
import android.provider.Settings;
import android.util.AttributeSet;
import android.widget.SeekBar;

import java.lang.reflect.Method;

/**
 * Front-light warmth as a slider row in the Quick Settings panel, sitting directly under the
 * brightness row (see res/layout/quick_settings_brightness_dialog.xml).
 *
 * Brightness already drives the cold LED bank through the replacement lights HAL
 * (frontlight/lights_epd105.c). That HAL reads the warm bank level from
 * persist.sys.frontlight.warm on every backlight call, so this slider writes the property and
 * then nudges the brightness setting by one step and back, which makes the framework re-issue
 * the backlight call and the HAL re-apply with the new warmth.
 *
 * The view wires itself up in its constructor, so no QSPanel patch is needed and it carries no
 * resource id of its own -- nothing in the SystemUI resource table changes.
 */
public class WarmthSliderView extends SeekBar implements SeekBar.OnSeekBarChangeListener {

    private static final String PROP = "persist.sys.frontlight.warm";
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

    private static int readLevel() {
        try { return clamp(Integer.parseInt(getProp(PROP))); } catch (Exception e) { return 0; }
    }

    private static String getProp(String key) {
        try {
            Class<?> c = Class.forName("android.os.SystemProperties");
            Method m = c.getMethod("get", String.class, String.class);
            return (String) m.invoke(null, key, "0");
        } catch (Exception e) { return "0"; }
    }

    private static void setProp(String key, String value) {
        try {
            Class<?> c = Class.forName("android.os.SystemProperties");
            Method m = c.getMethod("set", String.class, String.class);
            m.invoke(null, key, value);
        } catch (Exception e) { /* permissive init allows this; ignore if it ever does not */ }
    }

    /** Write the level, then make the framework re-issue the backlight call. */
    private void apply(int level) {
        setProp(PROP, String.valueOf(level));
        try {
            final ContentResolver cr = getContext().getContentResolver();
            final int cur = Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS, 100);
            final int bump = cur >= 255 ? cur - 1 : cur + 1;
            Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS, bump);
            mHandler.postDelayed(new Runnable() {
                public void run() {
                    Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS, cur);
                }
            }, 200L);
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
