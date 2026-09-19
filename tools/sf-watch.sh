#!/system/bin/sh
# Catch the SurfaceFlinger livelock (docs/INCIDENT-SF-LIVELOCK.md) at its START.
#
# Both hangs so far were found hours after the fact, with the logs already gone: SF spins on
# one core holding the EventThread mutex, nothing composites, the panel keeps its last image
# and the device looks switched off. This samples SF's own CPU counters once a minute and
# writes a line only when it is actually burning CPU, plus a heartbeat, so the log stays tiny
# and the START TIME is recorded. It holds no wakelock, so it cannot keep the device awake --
# while suspended it simply does not tick.
#
#   run now:    adb shell su -c 'setsid sh /data/local/sf-watch.sh >/dev/null 2>&1 &'
#   read it:    adb shell su -c 'cat /data/local/sf-watch.log'
#   at boot:    add that first line to /data/local/a11-boot-fixups.sh
L=/data/local/sf-watch.log
TICKS_PER_S=100          # HZ=100 on this kernel (confirmed in the watchdog dumps)
BUSY=20                  # ticks of CPU per 60 s sample = 20% of one core -> report
HEARTBEAT=30             # minutes between "still fine" lines
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $L; }
[ -f $L ] && [ "$(stat -c %s $L)" -gt 1000000 ] && mv $L $L.1
log "sf-watch started (uptime $(cut -d. -f1 /proc/uptime)s)"
prev=; n=0
while true; do
  pid=$(pidof surfaceflinger)
  if [ -z "$pid" ]; then log "SurfaceFlinger NOT RUNNING"; sleep 60; continue; fi
  set -- $(cat /proc/$pid/stat 2>/dev/null)
  [ $# -lt 15 ] && { sleep 60; continue; }
  # NOTE the braces: in this shell $14 expands as $1 followed by "4", which silently
  # yields the pid and a delta of zero forever -- the detector would never fire.
  cur=$(( ${14} + ${15} ))                   # utime + stime, in ticks
  if [ -n "$prev" ]; then
    d=$((cur - prev))
    if [ $d -ge $BUSY ]; then
      log "SF BUSY ${d} ticks/60s ($((d * 100 / TICKS_PER_S / 60))% of a core) wakefulness=$(dumpsys power | grep -o 'mWakefulness=[A-Za-z]*' | head -1) display=$(dumpsys power | grep -o 'Display Power: state=[A-Z]*' | head -1)"
      # First detection also grabs the stacks, which is what was missing both times.
      if [ ! -f /data/local/sf-hang-stacks.txt ]; then
        log "capturing stacks -> /data/local/sf-hang-stacks.txt"
        { echo "=== $(date) SF busy ${d} ticks/60s"; debuggerd -b $pid; echo; echo "=== top"; top -b -n 1 | head -15; } \
          > /data/local/sf-hang-stacks.txt 2>&1
      fi
    elif [ $((n % HEARTBEAT)) -eq 0 ]; then
      log "ok (${d} ticks/60s)"
    fi
  fi
  prev=$cur; n=$((n + 1)); sleep 60
done
