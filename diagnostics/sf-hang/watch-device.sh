#!/system/bin/sh
# Temporary passive watcher, 72 h max. No wakelock, wake alarm or recovery action.
# A reboot ends it. Normal sleeps do not wake a suspended device.
set -u
out=/data/local/tmp/sf-hang-watch-v2
mkdir -p "$out"
hz=$(getconf CLK_TCK)
case "$hz" in ''|*[!0-9]*) exit 2;; esac
now_seconds() {
 read -r uptime rest < /proc/uptime
 now=${uptime%%.*}
}
thread_ticks() {
 read -r statline < "$1" || return 1
 fields=${statline##*) }
 set -- $fields
 [ "$#" -ge 13 ] || return 1
 shift 11
 ticks=$(($1+$2))
}
now_seconds; start=$now
pid=0; tid=0; previous=0; previous_time=$now; hot=0
while :; do
 now_seconds
 [ $((now-start)) -lt 259200 ] || break
 # Cache the thread; scan only on startup or disappearance, avoiding per-thread forks.
 name=
 [ -r /proc/$pid/task/$tid/comm ] && read -r name < /proc/$pid/task/$tid/comm
 if [ "$name" != app ]; then
  pid=$(pidof surfaceflinger)
  tid=0; hot=0
  for t in /proc/$pid/task/*; do
   name=
   [ -r "$t/comm" ] && read -r name < "$t/comm"
   [ "$name" = app ] && tid=${t##*/}
  done
  if [ "$tid" != 0 ] && thread_ticks /proc/$pid/task/$tid/stat; then
   previous=$ticks; previous_time=$now
  fi
 fi
 if [ "$tid" != 0 ] && thread_ticks /proc/$pid/task/$tid/stat && [ "$now" -gt "$previous_time" ]; then
  percent=$(((ticks-previous)*100/(hz*(now-previous_time))))
  if [ "$percent" -ge 80 ]; then hot=$((hot+1)); else hot=0; fi
  echo "$now pid=$pid tid=$tid cpu=$percent hot=$hot" > "$out/status"
  if [ "$hot" -ge 3 ]; then
   echo "capturing pid=$pid tid=$tid" > "$out/status"
   sh /data/local/tmp/sf-capture-device.sh "$out/capture-$now"
   result=$?
   echo "capture-finished status=$result path=$out/capture-$now" > "$out/status"
   exit "$result"
  fi
  previous=$ticks; previous_time=$now
 fi
 sleep 15
done
echo expired > "$out/status"
