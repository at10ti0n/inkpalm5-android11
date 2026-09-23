package net.inkpalm.einktile;

import android.database.ContentObserver;
import android.graphics.drawable.Icon;
import android.os.Handler;
import android.provider.Settings;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.widget.Toast;

/** EPD105 natural orientation is landscape (0), portrait is rotation 1.
 * configure-native.sh enables fixed-to-user rotation. Keep sensor policy enabled:
 * locking it lets SystemUI overwrite user_rotation during startup on this port. */
public class RotationTile extends TileService {
    private boolean observing;
    private final ContentObserver observer = new ContentObserver(new Handler()) {
        @Override public void onChange(boolean selfChange) { refresh(); }
    };

    private boolean isPortrait() {
        int rotation = Settings.System.getInt(getContentResolver(), Settings.System.USER_ROTATION, 1);
        return rotation == 1 || rotation == 3;
    }

    private void refresh() {
        Tile tile = getQsTile();
        if (tile == null) return;
        boolean portrait = isPortrait();
        tile.setLabel(portrait ? "Portrait" : "Landscape");
        tile.setIcon(Icon.createWithResource(this,
                portrait ? R.drawable.ic_portrait : R.drawable.ic_landscape));
        tile.setState(portrait ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.updateTile();
    }

    @Override public void onStartListening() { ScreenTempService.start(this);
        if (!observing) {
            getContentResolver().registerContentObserver(
                    Settings.System.getUriFor(Settings.System.USER_ROTATION), false, observer);
            observing = true;
        }
        refresh();
    }

    @Override public void onStopListening() {
        if (observing) {
            getContentResolver().unregisterContentObserver(observer);
            observing = false;
        }
    }

    @Override public void onDestroy() {
        onStopListening();
        super.onDestroy();
    }

    @Override public void onClick() {
        int target = isPortrait() ? 0 : 1;
        try {
            boolean sensor = Settings.System.putInt(getContentResolver(),
                    Settings.System.ACCELEROMETER_ROTATION, 1);
            boolean changed = sensor && Settings.System.putInt(getContentResolver(),
                    Settings.System.USER_ROTATION, target);
            if (!changed) throw new IllegalStateException("Setting write rejected");
        } catch (RuntimeException e) {
            Toast.makeText(this, "Could not change orientation", Toast.LENGTH_SHORT).show();
        }
        refresh();
    }
}
