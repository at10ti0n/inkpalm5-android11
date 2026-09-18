#!/system/bin/sh
# Read-only diagnostics except files in the chosen output directory. No reboot.
set -u
lock=/data/local/tmp/sf-hang-capture.lock
mkdir "$lock" 2>/dev/null || exit 3
trap 'rmdir "$lock"' EXIT
out=$1
mkdir -p "$out"
pid=$(pidof surfaceflinger)
[ -n "$pid" ] || exit 1
{
 date; cat /proc/uptime; echo "surfaceflinger=$pid"
 cat /proc/$pid/status
 for t in /proc/$pid/task/*; do
  echo "THREAD $t"; cat "$t/comm" "$t/stat" "$t/wchan"
 done
 cat /sys/kernel/debug/suspend_stats
 cat /sys/kernel/debug/wakeup_sources
} > "$out/state.txt" 2>&1
# Memory pressure, reclaim and allocation context before profiling alters the workload.
{
 date
 for f in /proc/meminfo /proc/vmstat /proc/buddyinfo /proc/pressure/memory /sys/block/zram0/mm_stat /proc/$pid/oom_score /proc/$pid/oom_score_adj; do
  echo "=== $f"
  [ ! -r "$f" ] || cat "$f"
 done
} > "$out/memory.txt" 2>&1
cat /proc/$pid/maps > "$out/sf-maps.txt"
# Sample first, before debuggerd pauses threads. A hot loop yields precise PCs.
timeout 15 simpleperf record -p "$pid" -e cpu-clock:u -f 200 -g --duration 5 -o "$out/perf.data" > "$out/perf-record.txt" 2>&1
timeout 15 simpleperf report -i "$out/perf.data" --sort symbol > "$out/perf-report.txt" 2>&1
timeout 15 dumpsys power > "$out/power.txt" 2>&1
timeout 15 dumpsys SurfaceFlinger > "$out/surfaceflinger.txt" 2>&1
# Full tombstone includes registers/stack and maps missing from backtrace-only capture.
timeout 30 debuggerd "$pid" > "$out/sf-tombstone.txt" 2>&1
logcat -b all -d -t 2000 > "$out/logcat.txt" 2>&1
dmesg > "$out/kernel.txt" 2>&1
