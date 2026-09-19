#!/system/bin/sh
# Detect the SurfaceFlinger livelock (docs/INCIDENT-SF-LIVELOCK.md) WHILE IT IS HAPPENING and
# capture it. Both incidents so far were found hours later with the evidence already gone: the
# watchdog report names the callers blocked on SurfaceFlinger, but not what SF itself is doing.
#
#   run now:  adb shell su -c 'setsid sh /data/local/sf-watch.sh >/dev/null 2>&1 &'
#   status:   adb shell su -c 'cat /data/local/sf-hang/status; ls /data/local/sf-hang'
#
# Trigger: ANY SurfaceFlinger thread above 80% of one core for three consecutive intervals
# (~45 s). Idle is 3-4 ticks/minute, and even heavy page-turning never holds one core for 45 s,
# so this does not fire on ordinary use. Percentages are computed from CLK_TCK and the MEASURED
# elapsed time, not an assumed interval, and all counters reset when the SF pid changes.
#
# It holds no wakelock and sets no wake alarm, so it cannot keep the device awake; while the
# device is suspended it simply does not tick. It keeps watching after a capture (cooldown
# below) instead of exiting, and each incident goes in its own directory.
set -u
OUT=/data/local/sf-hang
CAP=/data/local/sf-capture.sh
BUSY_PCT=80          # of one core
BUSY_N=3             # consecutive intervals over BUSY_PCT before capturing
INTERVAL=15          # seconds between samples
COOLDOWN=1800        # seconds after a capture before another may start
KEEP=6               # most recent capture directories to keep
mkdir -p "$OUT"
HZ=$(getconf CLK_TCK); case "$HZ" in ''|*[!0-9]*) HZ=100;; esac
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$OUT/sf-watch.log"; }

now_s() { read -r up rest < /proc/uptime; now=${up%%.*}; }
# utime+stime of one task, in ticks. Strips through ") " first: the comm field can contain
# anything, including spaces and brackets.
ticks_of() {
  read -r line < "$1" || return 1
  set -- ${line##*') '}
  [ $# -ge 13 ] || return 1
  shift 11
  ticks=$(( $1 + $2 ))
}

log "sf-watch started (interval ${INTERVAL}s, trigger ${BUSY_PCT}% x ${BUSY_N}, HZ=$HZ)"
pid=0; last_cap=0
while :; do
  now_s
  cur=$(pidof surfaceflinger)
  if [ -z "$cur" ]; then
    [ "$pid" != 0 ] && { log "SurfaceFlinger NOT RUNNING"; pid=0; }
    sleep "$INTERVAL"; continue
  fi
  if [ "$cur" != "$pid" ]; then
    # New process: every cached counter belongs to the dead one.
    [ "$pid" != 0 ] && log "SurfaceFlinger pid changed $pid -> $cur (counters reset)"
    pid=$cur; prev_t=0; prev_time=$now; hot=0; hot_tid=
    for t in /proc/$pid/task/*; do
      ticks_of "$t/stat" && prev_t=$((prev_t + ticks))
    done
    sleep "$INTERVAL"; continue
  fi

  # Busiest single thread over the measured elapsed time.
  elapsed=$((now - prev_time))
  [ "$elapsed" -le 0 ] && { sleep "$INTERVAL"; continue; }
  top_pct=0; top_tid=; tot=0
  for t in /proc/$pid/task/*; do
    ticks_of "$t/stat" || continue
    tid=${t##*/}; tot=$((tot + ticks))
    eval "p=\${T_$tid:-}"
    if [ -n "$p" ]; then
      pct=$(( (ticks - p) * 100 / (HZ * elapsed) ))
      if [ "$pct" -gt "$top_pct" ]; then top_pct=$pct; top_tid=$tid; fi
    fi
    eval "T_$tid=\$ticks"
  done
  proc_pct=$(( (tot - prev_t) * 100 / (HZ * elapsed) ))
  prev_t=$tot; prev_time=$now

  if [ "$top_pct" -ge "$BUSY_PCT" ]; then
    [ "$top_tid" = "${hot_tid:-}" ] && hot=$((hot + 1)) || hot=1
    hot_tid=$top_tid
  else
    hot=0; hot_tid=
  fi
  comm=; [ -n "$top_tid" ] && [ -r /proc/$pid/task/$top_tid/comm ] && read -r comm < /proc/$pid/task/$top_tid/comm
  echo "$(date '+%m-%d %H:%M:%S') pid=$pid proc=${proc_pct}% top=${top_pct}% tid=${top_tid:-none} comm=${comm:-?} hot=$hot" > "$OUT/status"

  if [ "$hot" -ge "$BUSY_N" ] && [ $((now - last_cap)) -ge "$COOLDOWN" ]; then
    d="$OUT/capture-$(date '+%Y%m%d-%H%M%S')"
    log "LIVELOCK SUSPECTED pid=$pid tid=$top_tid comm=${comm:-?} ${top_pct}% of a core for $((BUSY_N * INTERVAL))s -> $d"
    echo "spinning thread: tid=$top_tid comm=${comm:-?} ${top_pct}%" > "$OUT/trigger.txt"
    sh "$CAP" "$d" >> "$OUT/sf-watch.log" 2>&1
    log "capture finished status=$? -> $d"
    cp "$OUT/trigger.txt" "$d/trigger.txt" 2>/dev/null
    last_cap=$now; hot=0; hot_tid=
    # Keep only the most recent KEEP captures.
    n=0
    for c in $(ls -1dt "$OUT"/capture-* 2>/dev/null); do
      n=$((n + 1)); [ "$n" -gt "$KEEP" ] && rm -rf "$c"
    done
  fi
  sleep "$INTERVAL"
done
