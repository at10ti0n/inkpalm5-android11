#!/system/bin/sh
# Capture everything needed to identify WHICH loop SurfaceFlinger is stuck in, at the moment it
# is stuck. Read-only except files in the chosen output directory. No reboot, no service restart,
# no power-configuration change.
#
#   sh /data/local/sf-capture.sh /data/local/sf-hang/<timestamp>
#
# Order is deliberate and is the whole point of the script:
#   1. per-thread stat/wchan  identifies the spinning thread and what the others wait on
#   2. memory/reclaim state   before profiling perturbs the workload
#   3. maps                   to turn sampled PCs into symbols offline
#   4. simpleperf, 5 s        a hot loop yields precise PCs; must run BEFORE debuggerd, which
#                             pauses threads
#   5. FULL TOMBSTONE         registers and stack. Immediately after the profile: the decisive
#                             evidence must not queue behind anything that can block.
#   6. dumpsys, each bounded  LAST, because these talk to system_server, which during this
#                             failure is itself wedged behind the same locks
#   7. logcat, dmesg
# Incident 1 failed on exactly this: its single sampled PC landed on a PLT stub
# (RefBase::decStrong, reachable from several call sites) and its app-thread unwind stopped
# there, so it could name neither the caller nor the mutex owner. Steps 1, 4 and 5 are the fix.
#
# Every command's exit status is recorded in exit-status.txt and the script exits non-zero if
# any of them failed -- a capture that silently lost the profile or the tombstone is worthless.
set -u
lock=/data/local/sf-hang-capture.lock
mkdir "$lock" 2>/dev/null || exit 3
trap 'rmdir "$lock"' EXIT
out=$1
mkdir -p "$out"
pid=$(pidof surfaceflinger)
[ -n "$pid" ] || exit 1
fails=0; miss=0
st() {  # st <name> <exit-status>
  echo "$1=$2" >> "$out/exit-status.txt"
  [ "$2" = 0 ] || fails=$((fails + 1))
}
# A brace group's exit status is only its LAST command's, so a failed read early in a block
# would otherwise be invisible. Every read inside the blocks goes through rd(), which marks
# the gap in the output itself and counts it. These are counted, not fatal: a thread exiting
# while we walk /proc is normal, and some /proc files do not exist on this 4.9 kernel.
rd() {
  if [ -r "$1" ] && cat "$1" 2>/dev/null; then
    return 0
  fi
  echo "<<UNREADABLE: $1>>"
  miss=$((miss + 1))
  return 1
}

{
 date; rd /proc/uptime; echo "surfaceflinger=$pid"
 rd /proc/$pid/status
 for t in /proc/$pid/task/*; do
  # one field per line: wchan has no trailing newline, so cat alone runs them together
  echo "THREAD $t"; rd "$t/comm"; rd "$t/stat"; printf 'wchan: '; rd "$t/wchan"; echo
 done
 rd /sys/kernel/debug/suspend_stats
 rd /sys/kernel/debug/wakeup_sources
} > "$out/state.txt" 2>&1
st state $?
echo "state-unreadable=$miss" >> "$out/exit-status.txt"

{
 date
 for f in /proc/meminfo /proc/vmstat /proc/buddyinfo /proc/pressure/memory /sys/block/zram0/mm_stat /proc/$pid/oom_score /proc/$pid/oom_score_adj; do
  echo "=== $f"
  rd "$f"
 done
} > "$out/memory.txt" 2>&1
st memory $?
echo "state+memory-unreadable=$miss" >> "$out/exit-status.txt"

cat /proc/$pid/maps > "$out/sf-maps.txt" 2>&1; st maps $?
# maps is required to symbolize the profile, so unlike the blocks above it must be non-empty.
[ -s "$out/sf-maps.txt" ] || st maps-empty 1

timeout 15 simpleperf record -p "$pid" -e cpu-clock:u -f 200 -g --duration 5 -o "$out/perf.data" > "$out/perf-record.txt" 2>&1
st perf-record $?
# Registers and stack, immediately after the profile and before anything that can block.
timeout 30 debuggerd "$pid" > "$out/sf-tombstone.txt" 2>&1; st tombstone $?
timeout 15 simpleperf report -i "$out/perf.data" --sort symbol > "$out/perf-report.txt" 2>&1
st perf-report $?

# system_server is wedged during this failure: these come last, each bounded, and a timeout
# here is expected rather than fatal.
timeout 15 dumpsys power > "$out/power.txt" 2>&1; st dumpsys-power $?
timeout 15 dumpsys SurfaceFlinger > "$out/surfaceflinger.txt" 2>&1; st dumpsys-sf $?
timeout 30 logcat -b all -d -t 2000 > "$out/logcat.txt" 2>&1; st logcat $?
timeout 15 dmesg > "$out/kernel.txt" 2>&1; st dmesg $?

# perf.data and the tombstone are the decisive artefacts: a zero-length one is a failure even
# if the command reported success.
[ -s "$out/perf.data" ] || st perf-data-empty 1
[ -s "$out/sf-tombstone.txt" ] || st tombstone-empty 1
echo "unreadable_reads=$miss" >> "$out/exit-status.txt"
echo "failed_commands=$fails" >> "$out/exit-status.txt"
[ "$fails" = 0 ] || exit 4
exit 0
