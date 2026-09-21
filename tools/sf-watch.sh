#!/system/bin/sh
# Detect the SurfaceFlinger livelock (docs/INCIDENT-SF-LIVELOCK.md) WHILE IT IS HAPPENING and
# capture it. Both incidents so far were found hours later with the evidence already gone: the
# watchdog report names the callers blocked on SurfaceFlinger, but nothing says what SF itself
# was doing. Only a live CPU profile and a register-bearing tombstone can answer that.
#
#   run now:  adb shell su -c 'setsid sh /data/local/sf-watch.sh >/dev/null 2>&1 &'
#   status:   adb shell su -c 'cat /data/local/sf-hang/status; ls /data/local/sf-hang'
#
# RECOVERY. After the capture completes -- never before, the evidence comes first -- this
# kills SurfaceFlinger, which init restarts and which takes system_server with it. MEASURED
# 2026-09-21 on a live three-hour hang: the compositor came back, dumpsys answered again, the
# keyguard rendered, and the watcher picked up the new pid by itself. No reboot was needed.
# That is a soft framework restart, so foreground app state is lost; the alternative observed
# twice is a device that never draws again, cannot be woken by the power button, and needs a
# 20-second power hold. Set RECOVER=0 to keep the hung process for live debugging instead.
#
# Trigger: ANY SurfaceFlinger thread above 80% of one core for three consecutive intervals
# (~45 s). Idle is a few ticks per minute, and no ordinary use holds one core that long.
# Percentages come from CLK_TCK and the MEASURED elapsed uptime, never an assumed interval.
#
# No wakelock and no wake alarm, so it cannot keep the device awake; while the device is
# suspended it simply does not tick. It keeps watching after a capture instead of exiting.
set -u
OUT=/data/local/sf-hang
CAP=/data/local/sf-capture.sh
BUSY_PCT=80          # of one core
BUSY_N=3             # consecutive intervals over BUSY_PCT before capturing
INTERVAL=15          # seconds between samples
COOLDOWN=1800        # seconds AFTER A CAPTURE before another may start
KEEP=6               # most recent capture directories to keep
RECOVER=1            # after capturing, restart SurfaceFlinger to break the livelock (0 = off)
MAX_RECOVER=3        # per boot, so a systematically broken state cannot restart-loop
mkdir -p "$OUT"
HZ=$(getconf CLK_TCK); case "$HZ" in ''|*[!0-9]*) HZ=100;; esac
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$OUT/sf-watch.log"; }
now_s() { read -r up rest < /proc/uptime; now=${up%%.*}; }

# utime+stime and starttime for one task. Strips through ") " first: comm can contain spaces
# and brackets. starttime is carried so a REUSED thread id cannot be diffed against the
# counters of the thread that previously held it.
ticks_of() {
  read -r line < "$1" || return 1
  set -- ${line##*') '}
  [ $# -ge 20 ] || return 1
  shift 11
  ticks=$(( $1 + $2 )); startt=$9
}
# Drop every cached per-thread counter (pid changed: they all belong to a dead process).
forget_all() {
  for _t in ${SEEN:-}; do unset "T_$_t"; done
  SEEN=
}

log "sf-watch started (interval ${INTERVAL}s, trigger ${BUSY_PCT}% x ${BUSY_N}, HZ=$HZ, recover=$RECOVER)"
pid=0; SEEN=; last_cap=; recoveries=0       # empty = no capture yet, so the cooldown cannot gate the first one
while :; do
  now_s
  cur=$(pidof surfaceflinger)
  if [ -z "$cur" ]; then
    [ "$pid" != 0 ] && { log "SurfaceFlinger NOT RUNNING"; pid=0; forget_all; }
    sleep "$INTERVAL"; continue
  fi
  if [ "$cur" != "$pid" ]; then
    [ "$pid" != 0 ] && log "SurfaceFlinger pid changed $pid -> $cur (counters dropped)"
    forget_all
    pid=$cur; prev_time=$now; hot=0; hot_tid=
    for t in /proc/$pid/task/*; do
      ticks_of "$t/stat" || continue
      tid=${t##*/}; eval "T_$tid=\"\$ticks:\$startt\""; SEEN="$SEEN $tid"
    done
    sleep "$INTERVAL"; continue
  fi

  elapsed=$((now - prev_time))
  [ "$elapsed" -le 0 ] && { sleep "$INTERVAL"; continue; }
  top_pct=0; top_tid=; new_seen=
  for t in /proc/$pid/task/*; do
    ticks_of "$t/stat" || continue
    tid=${t##*/}; new_seen="$new_seen $tid"
    eval "p=\${T_$tid:-}"
    # Same thread id AND same start time, or the previous counter is not comparable.
    if [ -n "$p" ] && [ "${p#*:}" = "$startt" ]; then
      pct=$(( (ticks - ${p%%:*}) * 100 / (HZ * elapsed) ))
      if [ "$pct" -gt "$top_pct" ]; then top_pct=$pct; top_tid=$tid; fi
    fi
    eval "T_$tid=\"\$ticks:\$startt\""
  done
  # Forget threads that have exited, so a later reuse of the id starts clean.
  for t in $SEEN; do
    case " $new_seen " in *" $t "*) ;; *) unset "T_$t";; esac
  done
  SEEN=$new_seen
  prev_time=$now

  if [ "$top_pct" -ge "$BUSY_PCT" ] && [ "$top_tid" = "${hot_tid:-}" ]; then
    hot=$((hot + 1))
  elif [ "$top_pct" -ge "$BUSY_PCT" ]; then
    hot=1; hot_tid=$top_tid
  else
    hot=0; hot_tid=
  fi
  comm=; [ -n "$top_tid" ] && [ -r /proc/$pid/task/$top_tid/comm ] && read -r comm < /proc/$pid/task/$top_tid/comm
  echo "$(date '+%m-%d %H:%M:%S') pid=$pid top=${top_pct}% tid=${top_tid:-none} comm=${comm:-?} hot=$hot" > "$OUT/status"

  if [ "$hot" -ge "$BUSY_N" ] && { [ -z "$last_cap" ] || [ $((now - last_cap)) -ge "$COOLDOWN" ]; }; then
    d="$OUT/capture-$(date '+%Y%m%d-%H%M%S')"
    log "LIVELOCK SUSPECTED pid=$pid tid=$top_tid comm=${comm:-?} ${top_pct}% of a core for $((BUSY_N * INTERVAL))s -> $d"
    mkdir -p "$d"; echo "spinning thread: tid=$top_tid comm=${comm:-?} ${top_pct}% of a core" > "$d/trigger.txt"
    HOT_TID=$top_tid sh "$CAP" "$d" >> "$OUT/sf-watch.log" 2>&1
    log "capture exit=$? -> $d ($(cat "$d/exit-status.txt" 2>/dev/null | tr '\n' ' '))"
    last_cap=$now; hot=0; hot_tid=
    if [ "$RECOVER" = 1 ] && [ "${recoveries:-0}" -lt "$MAX_RECOVER" ]; then
      recoveries=$((${recoveries:-0} + 1))
      log "recovering: killing SurfaceFlinger pid=$pid (restart $recoveries of $MAX_RECOVER this boot)"
      # MEASURED 2026-09-21: off the cable, the framework restart after the kill stalled for 13
      # minutes because nothing held the device awake and it kept suspending mid-restart. Hold a
      # wake lock for the restart window; a detached sleeper releases it.
      echo sf-recover > /sys/power/wake_lock 2>/dev/null
      ( sleep 240; echo sf-recover > /sys/power/wake_unlock 2>/dev/null ) >/dev/null 2>&1 &
      kill -9 "$pid" 2>/dev/null
      # The pid-change branch on the next pass drops every cached counter.
    elif [ "$RECOVER" = 1 ]; then
      log "NOT recovering: already restarted $MAX_RECOVER times this boot, leaving it alone"
    fi
    n=0
    for c in $(ls -1dt "$OUT"/capture-* 2>/dev/null); do
      n=$((n + 1)); [ "$n" -gt "$KEEP" ] && rm -rf "$c"
    done
  fi
  sleep "$INTERVAL"
done
