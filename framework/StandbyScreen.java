package com.android.server.power;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.os.Binder;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Log;
import android.view.Display;
import android.view.View;
import android.view.WindowContentFrameStats;
import android.view.WindowManager;
import android.widget.ImageView;
import java.io.BufferedReader;
import java.io.FileReader;
import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicInteger;

/** EPD105 standby overlay. PMS owns eligibility and the independent timeout.
 * All window/Binder/file work is on our own thread, never under the PMS lock.
 * FrameStats is only the compositor fence: require a later, completed panel cycle too.
 * No permanent polling, wake alarm, or change to the compositor/refresh properties.
 */
public final class StandbyScreen {
    private static final String TAG = "InkpalmStandby";
    private static final AtomicInteger desired = new AtomicInteger();
    private static final AtomicInteger ready = new AtomicInteger(-1);
    private static final AtomicInteger closed = new AtomicInteger(-1);
    private static Handler worker;
    private static Session shown; // worker-thread confined

    private static synchronized Handler worker() {
        if (worker == null) {
            HandlerThread t = new HandlerThread("InkpalmStandby");
            t.start();
            worker = new Handler(t.getLooper());
        }
        return worker;
    }

    /** Called under mLock. No window operations or Binder calls. */
    public static void generation(final int token) {
        desired.set(token);
        // Avoid creating a thread on every user activity before the first sleep.
        Handler h;
        synchronized (StandbyScreen.class) { h = worker; }
        if (h != null) h.post(new Runnable() { public void run() {
            if (shown != null && shown.token != desired.get()) hide();
        }});
    }

    /** Called on the PMS handler, outside mLock. */
    public static void show(final Context context, final int token,
                            final Handler callbackHandler, final Runnable completed) {
        if (desired.get() != token || closed.get() == token) return;
        if (!worker().post(new Runnable() { public void run() {
            if (desired.get() != token || closed.get() == token) return;
            hide();
            try {
                Session s = new Session(context, token, callbackHandler, completed);
                shown = s;
                s.start();
            } catch (Exception | OutOfMemoryError e) {
                Log.e(TAG, "show failed token=" + token + "; PMS timeout remains armed", e);
                hide();
            }
        }})) Log.e(TAG, "render thread refused token=" + token);
    }

    /** Stop observation at the independent deadline; leave the image through sleep. */
    public static void stop(final int token) {
        closed.set(token);
        Log.i(TAG, "sleep decision token=" + token + " completion=" + (ready.get()==token));
        Handler h;
        synchronized (StandbyScreen.class) { h = worker; }
        if (h != null) h.post(new Runnable() { public void run() {
            if (shown != null && shown.token == token) {
                shown.stopped = true;
                worker.removeCallbacks(shown);
            }
        }});
    }

    private static void hide() {
        Session s = shown;
        shown = null;
        if (s == null) return;
        s.stopped = true;
        worker.removeCallbacks(s);
        if (s.view != null && s.view.isAttachedToWindow()) {
            try { s.windows.removeViewImmediate(s.view); }
            catch (RuntimeException e) { Log.e(TAG, "remove failed", e); }
        }
        // Let RenderThread release the bitmap normally; never recycle an in-flight buffer.
        Log.i(TAG, "removed token=" + s.token);
    }

    static final class Panel {
        final long count, activeSince, lastChange;
        Panel(long count, long activeSince, long lastChange) {
            this.count=count; this.activeSince=activeSince; this.lastChange=lastChange;
        }
        static Panel read() throws Exception {
            try (BufferedReader r = new BufferedReader(new FileReader("/sys/kernel/debug/wakeup_sources"))) {
                for (String l; (l=r.readLine()) != null;) {
                    String[] p=l.trim().split("\\s+");
                    if (p.length >= 9 && p[0].equals("sy7673a_wakelock"))
                        return new Panel(Long.parseLong(p[1]), Long.parseLong(p[5]), Long.parseLong(p[8]));
                }
            }
            throw new IllegalStateException("panel wake source missing");
        }
    }

    // Kept independent of Android APIs so the actual gate can be tested on the host.
    static final class CompletionGate {
        long stableSince, previousCount=-1, previousChange=-1, previousPresent=-1;
        boolean observe(long presented, long monoNowNs, long baseline, long count,
                        long activeSince, long lastChangeMs, long uptimeMs) {
            boolean ready=presented>0 && presented<=monoNowNs && count>baseline
                    && activeSince==0 && lastChangeMs>=0
                    && lastChangeMs<=monoNowNs/1000000L
                    && lastChangeMs*1000000L>=presented;
            if (!ready || count!=previousCount || lastChangeMs!=previousChange
                    || presented!=previousPresent) stableSince=uptimeMs;
            previousCount=count; previousChange=lastChangeMs; previousPresent=presented;
            return ready && uptimeMs-stableSince>=150;
        }
    }

    private static final class Session implements Runnable {
        final int token;
        final Context context;
        final Handler callbackHandler;
        final Runnable completed;
        final long startNs = System.nanoTime();
        final long deadline = SystemClock.uptimeMillis() + 7500;
        WindowManager windows;
        ImageView view;
        Object wm;
        Method stats;
        long baseline;
        final CompletionGate gate=new CompletionGate();
        boolean stopped;

        Session(Context c, int t, Handler h, Runnable callback) {
            context=c; token=t; callbackHandler=h; completed=callback;
        }

        void start() throws Exception {
            baseline=Panel.read().count;
            Display display=((DisplayManager)context.getSystemService(Context.DISPLAY_SERVICE))
                    .getDisplay(Display.DEFAULT_DISPLAY);
            Context visual=context.createDisplayContext(display);
            windows=(WindowManager)visual.getSystemService(Context.WINDOW_SERVICE);
            int user=(Integer)Class.forName("android.app.ActivityManager")
                    .getMethod("getCurrentUser").invoke(null);
            String path="/data/system/users/"+user+"/wallpaper_lock";
            BitmapFactory.Options options=new BitmapFactory.Options();
            options.inJustDecodeBounds=true;
            BitmapFactory.decodeFile(path,options);
            if (options.outWidth <= 0 || options.outHeight <= 0)
                throw new IllegalStateException("No readable lock wallpaper for user " + user);
            options.inSampleSize=1;
            while ((long)(options.outWidth/options.inSampleSize)*(options.outHeight/options.inSampleSize)>2000000)
                options.inSampleSize*=2;
            options.inJustDecodeBounds=false;
            Bitmap bitmap=BitmapFactory.decodeFile(path,options);
            if (bitmap==null) throw new IllegalStateException("Cannot decode lock wallpaper");
            view=new ImageView(visual);
            view.setBackgroundColor(Color.WHITE);
            view.setScaleType(ImageView.ScaleType.CENTER_CROP);
            view.setImageBitmap(bitmap);
            view.setSystemUiVisibility(5894); // immersive, hide bars, stable fullscreen layout
            WindowManager.LayoutParams lp=new WindowManager.LayoutParams(-1,-1,2006,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE |
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE |
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN |
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS |
                    WindowManager.LayoutParams.FLAG_FULLSCREEN |
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED, PixelFormat.OPAQUE);
            lp.setTitle("InkpalmStandby:"+token);
            lp.token=new Binder();
            lp.windowAnimations=0;
            IBinder binder=(IBinder)Class.forName("android.os.ServiceManager")
                    .getMethod("getService",String.class).invoke(null,"window");
            wm=Class.forName("android.view.IWindowManager$Stub")
                    .getMethod("asInterface",IBinder.class).invoke(null,binder);
            stats=Class.forName("android.view.IWindowManager")
                    .getMethod("getWindowContentFrameStats",IBinder.class);
            if (desired.get()!=token || closed.get()==token) { hide(); return; }
            windows.addView(view,lp);
            Log.i(TAG,"shown token="+token+" startNs="+startNs+" panelBaseline="+baseline);
            worker.postDelayed(this,50);
        }

        @Override public void run() {
            if (stopped || shown!=this) return;
            if (desired.get()!=token) { hide(); return; }
            if (SystemClock.uptimeMillis() >= deadline) {
                stopped=true;
                Log.w(TAG,"completion unavailable token="+token+"; bounded PMS fallback");
                return;
            }
            try {
                WindowContentFrameStats s=(WindowContentFrameStats)stats.invoke(wm,view.getWindowToken());
                long presented=-1;
                // Only the newest frame counts. An older presented frame must not hide a
                // newer pending frame (for example after a layout/orientation change).
                if (s!=null && s.getFrameCount()>0) {
                    int i=s.getFrameCount()-1;
                    long p=s.getFramePresentedTimeNano(i);
                    if (s.getFramePostedTimeNano(i)>=startNs && p>=startNs && p!=Long.MAX_VALUE)
                        presented=p;
                }
                Panel panel=Panel.read();
                long now=SystemClock.uptimeMillis();
                // Observe a quiet interval after the completed panel cycle, not after show().
                if (gate.observe(presented,System.nanoTime(),baseline,panel.count,
                                 panel.activeSince,panel.lastChange,now)) {
                    stopped=true;
                    ready.set(token);
                    Log.i(TAG,"complete token="+token+" presentNs="+presented+" panelCount="+
                            panel.count+" panelOffMs="+panel.lastChange+" elapsedMs="+(System.nanoTime()-startNs)/1000000);
                    callbackHandler.post(completed);
                    return;
                }
            } catch (Exception e) {
                stopped=true;
                Log.e(TAG,"completion check failed token="+token+"; bounded PMS fallback",e);
                return;
            }
            worker.postDelayed(this,50);
        }
    }
}
