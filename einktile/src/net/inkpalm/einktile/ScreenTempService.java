package net.inkpalm.einktile;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.res.Resources;
import android.database.ContentObserver;
import android.net.Uri;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;

/* Screen Temperature: Android 11's Night Light drives the front light's WARM LED bank.
 *
 * On this greyscale E Ink panel the stock Night Light pixel tint only darkens (white to ~81%
 * grey at 3030 K, MEASURED 2026-09-24); the only warmth the device can show is the LM3630A warm
 * bank. overlays/screentemp-fw makes Night Light's colour matrix identity, and this service
 * follows its two settings:
 *
 *   night_display_activated          on  -> warm level from the temperature (intensity)
 *                                    off -> persist.sys.frontlight.warm_day (default 0)
 *   night_display_color_temperature  config_nightDisplayColorTemperatureMax (least warm) ..Min
 *                                    (warmest) -> warm level 1..24
 *
 * Night Light's own tile, Settings page and schedule (custom times; sunset-to-sunrise needs
 * location, which the port keeps off) therefore control the light. The level goes to
 * persist.sys.frontlight.warm, which the lights HAL (frontlight/lights_epd105.c) reads on every
 * backlight call; nudging brightness makes the framework issue that call now.
 *
 * Runs as the system UID (sharedUserId), started at boot, sticky; no polling, no wake locks. */
public class ScreenTempService extends Service {
    static final String TAG = "einktile.screentemp";
    static final String WARM = "persist.sys.frontlight.warm";
    static final String WARM_DAY = "persist.sys.frontlight.warm_day";
    static final String ACTIVATED = "night_display_activated";
    static final String TEMP = "night_display_color_temperature";
    static final int MAX_LEVEL = 24;

    private final Handler mH = new Handler(Looper.getMainLooper());
    private ContentObserver mObs;

    public static void start(Context c) {
        try { c.startService(new Intent(c, ScreenTempService.class)); }
        catch (Exception e) { Log.e(TAG, "start failed: " + e); }
    }

    @Override public void onCreate() {
        mObs = new ContentObserver(mH) {
            @Override public void onChange(boolean self, Uri uri) { apply("change"); }
        };
        getContentResolver().registerContentObserver(Settings.Secure.getUriFor(ACTIVATED), false, mObs);
        getContentResolver().registerContentObserver(Settings.Secure.getUriFor(TEMP), false, mObs);
    }

    @Override public int onStartCommand(Intent i, int flags, int id) {
        Log.i(TAG, "running");
        apply("start"); return START_STICKY;
    }
    @Override public void onDestroy() { getContentResolver().unregisterContentObserver(mObs); }
    @Override public IBinder onBind(Intent i) { return null; }

    private static int sysInt(String name, int dflt) {
        Resources r = Resources.getSystem();
        int id = r.getIdentifier(name, "integer", "android");
        try { return id != 0 ? r.getInteger(id) : dflt; } catch (Exception e) { return dflt; }
    }

    static int levelFor(int temp, int min, int max) {
        if (max <= min) return MAX_LEVEL;
        float f = (float) (max - Math.max(min, Math.min(max, temp))) / (max - min); // 0 = mild, 1 = warmest
        return Math.max(1, Math.min(MAX_LEVEL, 1 + Math.round(f * (MAX_LEVEL - 1))));
    }

    void apply(String why) {
        boolean on = Settings.Secure.getInt(getContentResolver(), ACTIVATED, 0) == 1;
        int min = sysInt("config_nightDisplayColorTemperatureMin", 2596);
        int max = sysInt("config_nightDisplayColorTemperatureMax", 4082);
        int temp = Settings.Secure.getInt(getContentResolver(), TEMP,
                sysInt("config_nightDisplayColorTemperatureDefault", 2850));
        int level;
        if (on) level = levelFor(temp, min, max);
        else { try { level = Integer.parseInt(Props.get(WARM_DAY)); } catch (Exception e) { level = 0; } }
        level = Math.max(0, Math.min(MAX_LEVEL, level));
        String cur = Props.get(WARM);
        if (String.valueOf(level).equals(cur)) return;
        Props.set(WARM, String.valueOf(level));
        Log.i(TAG, why + ": night light " + (on ? "on" : "off") + " temp=" + temp + "K -> warm " + level);
        nudge();
    }

    /* The HAL only runs when the framework issues a backlight call, i.e. on a brightness change.
     * One pending restore at a time: a second change inside the window reuses the ORIGINAL
     * brightness, so rapid changes cannot ratchet it up (the old Warmth tile could). */
    private int mOrig = -1;
    private final Runnable mRestore = new Runnable() { public void run() {
        if (mOrig >= 0) Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, mOrig);
        mOrig = -1;
    } };
    void nudge() {
        try {
            if (mOrig < 0) mOrig = Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 100);
            int bump = mOrig >= 255 ? mOrig - 1 : mOrig + 1;
            int now = Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, mOrig);
            // alternate so every change is a real change even while a restore is pending
            Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, now == bump ? mOrig : bump);
            mH.removeCallbacks(mRestore);
            mH.postDelayed(mRestore, 250);
        } catch (Exception e) { Log.e(TAG, "nudge failed: " + e); }
    }
}
