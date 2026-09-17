package net.inkpalm.einktile;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
public class ModeTile extends TileService {
    private boolean isText(){ String v=Props.get(Props.MODE); try{ return Integer.parseInt(v)==Props.TEXT; }catch(Exception e){ return false; } }
    private void refresh(){ Tile t=getQsTile(); if(t==null) return; boolean text=isText(); t.setLabel(text?"Mode: Text":"Mode: Graphics"); t.setState(text?Tile.STATE_ACTIVE:Tile.STATE_INACTIVE); t.updateTile(); }
    @Override public void onStartListening(){ refresh(); }
    @Override public void onClick(){ Props.set(Props.MODE, String.valueOf(isText()?Props.GRAPHICS:Props.TEXT)); Props.set(Props.ONESHOT,"1"); refresh(); }
}
