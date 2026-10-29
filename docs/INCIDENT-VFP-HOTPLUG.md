# Missing ARM VFP hotplug fix in the EPD105 kernel

Status 2026-10-29: the defect is confirmed in the vendor kernel and an exact
backport is installed on the author's device. The first unplugged night and its
automatic morning theme transition passed, following 23 controlled real suspend
cycles. This is separate from the bounded framework
[recovery guard](FRAMEWORK-RECOVERY.md), which shortens recovery after a crash.

## What is established

Linux fixed this CPU-offline callback in 2018:
[ARM: 8746/1: vfp: Go back to clearing vfp_current_hw_state[]](https://github.com/torvalds/linux/commit/1328f02005bbbaed15b9d5b7f3ab5ec9d4d5268a).
The required code is:

```c
static int vfp_dying_cpu(unsigned int cpu)
{
    vfp_current_hw_state[cpu] = NULL;
    return 0;
}
```

The EPD105's March 2024 vendor build is still Linux 4.9.56 and instead calls
`vfp_force_reload(cpu, current_thread_info())`. That helper can leave the CPU's
cached VFP owner intact when the current kernel thread does not own those
registers. After the hardware loses its contents, stale ownership can cause a
thread to reuse invalid registers instead of loading its saved state.

The exact vulnerable kernel SHA-256 is
`c6627f3c80acdfc15c3cad218f9446f2eef409900640309d4e29b650a35c81ea`.
Its recovered symbol table and disassembly locate the callback at `0xc0102cd4`
and the owner array at `0xc115c064`. A live function trace confirmed calls from
`vfp_dying_cpu` into `vfp_force_reload` during CPU3 offlining.

## Connection to the crashes

On October 28, system_server crashed in `AssetManager2::RebuildFilterList` with an
unaligned bucket-derived pointer. A separate `stat` process aborted in BoringSSL's
power-on self-test 11 ms later. Four such crypto aborts exist across October
19/25/27/28. The common abort PC does not identify whether the integrity digest or
another self-test failed; stderr was discarded by the old logger.

The asset function, like the previously investigated SurfaceFlinger loop, keeps
zeros in callee-saved NEON registers across calls. Register loss could turn its
array initialization into invalid bucket pointers. A stack value derived from
the bad pointer shows that the pointer was already bad before the faulting load.

The old eight-hour September canary log also contains a previously overlooked
positive: its CPU3-labelled worker reported all d8-d15 changed after a 403-second
gap. This is stronger evidence than the clean short USB tests, but that canary
called libc between loading and checking its registers. The new raw-syscall probe
removes that ambiguity by capturing all d0-d31 and FPSCR immediately around a raw
kernel sleep call.

Together these findings make the kernel defect a strong candidate for the original
crashes. They do not retroactively prove the contents of the missing VFP registers
in the system_server tombstone, or exclude every other corruption source.

## Exact backport

`a11boot/patch-vfp.py` operates on a **current full boot-partition backup**. It
requires the exact reviewed kernel, layout and valid legacy boot ID. It changes
four ARM instructions in place at kernel file offset `0xface8`:

```asm
movw r3, #0xc064
movt r3, #0xc115
mov  r2, #0
str  r2, [r3, r0, lsl #2]
```

This implements the upstream store. The original frame, mcount hook and return
remain intact. No trampoline, new symbol or kernel module is needed. The patched
kernel SHA-256 is
`2e3012f238a559016d4e2f2c5ebde1afaea0f4812fcb50da07e1d2169ca87b0a`.

The supplied boot image's ramdisk, other payloads, layout and padding are preserved.
Only that instruction region and the legacy SHA-1 boot ID change. An image with a
different kernel, malformed layout or inconsistent existing boot ID is refused.
Never replace a customized boot image with someone else's whole image to get this fix.

Offline build (no device I/O):

```sh
python3 a11boot/patch-vfp.py boot-before-vfp.img boot-vfp-fixed.img
python3 a11boot/test-vfp.py boot-before-vfp.img
# Optional, requires the Unicorn Python package on the computer:
python3 a11boot/test-vfp-emulation.py boot-before-vfp.img
```

The builder prints both whole-image hashes and a JSON receipt. Flashing remains a
manual kernel trial; it is **not enabled automatically by the release installer**.
Keep a verified copy of the original boot on the computer and device, plus a
working independent TWRP recovery route, before installing a candidate. Verify
the transferred candidate, check that the boot partition still matches the input
backup, and verify the whole partition after writing. Reboot to activate it.
Rollback restores that exact input boot image and reboots; removing the vendor
recovery guard does not undo this kernel change.

## Validation so far

- Exact live kernel extent matched the reviewed input. Original boot was backed
  up on device and host with matching SHA-256. The existing working TWRP recovery
  partition was independently identified and left untouched.
- ARM emulation ran the actual old/new callbacks, including their original stack
  frames and mcount code, for all four CPUs. The old callback retained stale owner
  pointers in the idle-thread case; the new callback cleared only the selected
  CPU's slot. Return value, stack and callee-saved registers were preserved.
- Nine packaging/preservation/refusal checks passed. Flash read-back matched the
  generated image, and Android booted normally.
- The postpatch live trace recorded 11 CPU-offline callbacks and **zero** calls
  from that callback to the defective helper. Ten controlled CPU3 cycles passed
  the raw-register test. Ten prepatch cycles were also clean, so this short test
  did not reproduce the rare hardware corruption.
- 300 fresh toybox/libcrypto startups passed with empty stderr, alongside 20
  dark/light theme changes. system_server kept the same PID; automatic night mode
  was restored and no new tombstones appeared.
- The ten-minute unplugged alarm trial completed **23 successful kernel suspends**,
  with one aborted attempt (`EBUSY`) and no resume failures. All four raw-syscall
  workers reported zero register mismatches. Nineteen fresh crypto startups after
  observed resumes passed; the final totals were zero register, crypto and alarm
  errors. system_server retained its PID and no new tombstones appeared. Physical
  sleep and wake were independently confirmed by the operator.
- The alarm FD was closed after that trial. A separate passive monitor ran
  unplugged overnight with no alarm FD or held kernel wake lock. At the first
  reconnect, the kernel had completed **138 additional successful suspends**
  (23 to 161 cumulative). All four raw-register workers remained clean and all
  **127 fresh crypto startups** after observed resumes passed. There were also
  32 aborted suspend attempts, with no kernel resume failures; these are not
  successful suspends and are not counted as such.
- The natural morning trigger was actually exercised: `TwilightService.onAlarm`
  ran at 07:10:36 local time on October 29, followed by the day-theme
  configuration at 07:15:44 and the display override at 07:15:45. Automatic night
  mode remained enabled. The boot ID, system_server PID **and process start time**
  all matched the saved baseline, proving the same Android core survived the
  night. No new tombstones or DropBox crash/restart records appeared. The operator
  independently confirmed normal waking the next morning; they were not asked
  to watch the display overnight.
- The passive monitor completed its full **12-hour** interval at about 11:34
  local time. All four workers reached `DONE` with zero mismatches; the final
  result was `TOTAL corruptions=0 crypto_failures=0 alarm_failures=0`. Its launcher
  recorded `complete`, both processes exited, and no test wake lock remained.
  The morning reconnect preceded the deadline by about 12 minutes; suspend
  counters stayed at 161 during that final USB-connected interval. USB prevents
  suspend on this device, so the meaningful overnight suspend evidence was
  gathered while unplugged.

The overnight result validates the repaired kernel through one natural occurrence
of the previous trigger. It does not turn the historical attribution into direct
register evidence, or establish that every rare freeze on this build is solved.
The backport remains an opt-in trial for the exact reviewed kernel.

The native diagnostic source is in `tools/src/vfp-state-canary.c` and `.S`. The C
must be compiled without VFP/vector instructions; compile the explicit assembly
separately. It offers a passive mode and optional bounded one-shot alarm mode.
Alarm mode intentionally schedules CPU wakeups during its stated duration; passive
mode does not hold a wake lock or schedule wakeups. FIPS child failures, register
mismatches and alarm errors are reported separately.

Build and invocation (ARMv7 Cortex-A7 device, root required for wake alarms):

```sh
bash tools/build-vfp-canary.sh "$ANDROID_NDK_HOME" vfp-state-canary
# On the device, after transferring the binary and making it executable:
# vfp-state-canary 43200       # 12h passive monitoring; no scheduled wakes
# vfp-state-canary 600 30      # 10min, one-shot CPU wake every 30s
```

Use a detached recorder to retain stdout/stderr through USB disconnection, and
inspect kernel suspend counters to prove the device actually suspended. The
program reports successful comparison of register snapshots separately from
inferred suspend intervals: preemption between clock reads can also inflate the
clock delta, so kernel counters are the corroborating source. Optional alarm wakes
stop at the absolute test deadline;
they are one-shot and rearmed in userspace, so a stopped program cannot leave an
ongoing periodic wakeup behind.

Raw tombstones, boot images and logs remain private outside the export repository.
