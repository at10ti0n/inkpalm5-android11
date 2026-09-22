package net.inkpalm.einktile;

import android.app.WallpaperManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.WindowManager;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;

/* Sets (or clears) the LOCK-SCREEN wallpaper from a file, so a static standby image can be
 * configured from a script. Android 11 has no shell command for this ("cmd wallpaper" has no
 * implementation), and this app already runs as the system UID with the platform signature.
 *
 * Why a lock wallpaper: with doze disabled the sleep transition ends on the keyguard, the
 * display then goes OFF, and the E Ink panel holds that last frame for free -- a stock-style
 * standby screen with zero redraws while asleep (docs/SUSPEND-DIAGNOSIS.md explains why
 * redraws matter on this hardware).
 *
 *   am broadcast -a net.inkpalm.einktile.SET_LOCK_WALLPAPER --es path /sdcard/standby.png
 *   am broadcast -a net.inkpalm.einktile.CLEAR_LOCK_WALLPAPER
 */
public class LockWallpaperReceiver extends BroadcastReceiver {
    static final String TAG = "einktile.wallpaper";
    static final String ACTION_SET = "net.inkpalm.einktile.SET_LOCK_WALLPAPER";
    static final String ACTION_CLEAR = "net.inkpalm.einktile.CLEAR_LOCK_WALLPAPER";

    @Override
    public void onReceive(Context ctx, Intent intent) {
        WallpaperManager wm = WallpaperManager.getInstance(ctx);
        try {
            if (ACTION_CLEAR.equals(intent.getAction())) {
                wm.clear(WallpaperManager.FLAG_LOCK);
                Log.i(TAG, "lock wallpaper cleared");
                return;
            }
            String path = intent.getStringExtra("path");
            if (path == null || !new File(path).canRead()) {
                Log.e(TAG, "unreadable path: " + path);
                return;
            }
            // The launcher asks the wallpaper service for a "desired size" twice the screen
            // width (1440x1280 here) for home-screen parallax, and SystemUI then scales a
            // screen-sized lock wallpaper up to fill it: the keyguard showed one half of the
            // 720x1280 image at 2x while the standby overlay shows it 1:1 (MEASURED 2026-09-22).
            // Parallax means nothing on E Ink, so pin the desired size to the portrait screen.
            // Persisted by the wallpaper service; needs SET_WALLPAPER_HINTS (system UID).
            DisplayMetrics dm = new DisplayMetrics();
            ((WindowManager) ctx.getSystemService(Context.WINDOW_SERVICE)).getDefaultDisplay().getRealMetrics(dm);
            int w = Math.min(dm.widthPixels, dm.heightPixels), h = Math.max(dm.widthPixels, dm.heightPixels);
            wm.suggestDesiredDimensions(w, h);
            Log.i(TAG, "desired wallpaper size " + w + "x" + h);
            try (InputStream in = new FileInputStream(path)) {
                // allowBackup=true, visibleCropHint=null (no crop; the image is already 720x1280)
                int id = wm.setStream(in, null, true, WallpaperManager.FLAG_LOCK);
                Log.i(TAG, "lock wallpaper set from " + path + " id=" + id);
            }
        } catch (Exception e) {
            Log.e(TAG, "failed: " + e);
        }
    }
}
