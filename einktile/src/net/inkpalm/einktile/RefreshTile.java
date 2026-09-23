package net.inkpalm.einktile;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
public class RefreshTile extends TileService {
    @Override public void onStartListening(){ ScreenTempService.start(this); Tile t=getQsTile(); if(t!=null){ t.setLabel("Refresh Screen"); t.setState(Tile.STATE_INACTIVE); t.updateTile(); } }
    @Override public void onClick(){ Props.set(Props.ONESHOT,"1"); }
}
