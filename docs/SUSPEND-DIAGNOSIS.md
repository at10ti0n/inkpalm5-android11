# Why suspend fails on the EPD105 — diagnosis from capture 4

Status: **resolved** — run 2 confirms display-side coupling. Verdict and numbers at the end.

## The numbers that started this

Capture 4 (unplugged, real suspend, physical power-button wake) ended with
`suspend_stats: success 19, fail 12 (failed_freeze 9, failed_suspend 3)`,
`last_failed_errno -16` (EBUSY), `last_failed_step freeze`, `last_failed_dev` empty.

## What the 12 failures actually are

Every suspend attempt reconstructed from `power:suspend_resume` events (the parser's
19/12 split matches `suspend_stats` exactly, which validates it):

* **31 attempts in ~108 trace-seconds.** Every one — success or failure — lasts under 0.8 s
  of trace time, with the next attempt 0.3–1.3 s later. The ftrace `local` clock stops
  during real suspend, so sleeps are invisible; what is visible is that the device **woke
  roughly 30 times in five minutes**. The failures are collateral from that thrash.
* **No failure is a freezer timeout.** The longest failed attempt is 0.77 s; the freezer
  timeout is 20 s. So the -EBUSY is not a task refusing to freeze. It is the *other* -EBUSY:
  `pm_wakeup_pending()` becoming true while freezing.
* Three signatures:
  - **5–15 ms** (#7, #8, #20): instant abort — a wakeup was already pending at freeze entry.
  - **~100 ms with an E Ink refresh in-window** (#13, #15, #23, #25, #27): a refresh fired
    mid-freeze. 9 of the 12 failures had a `sy7673a_power_on` inside the attempt.
  - **3 died in `dpm_suspend`** (#2, #7, #20): a device's suspend callback returned an
    error. Two had a refresh in flight. `eink_suspend` exists in the stock kernel
    (kallsyms) and is the obvious candidate; `last_failed_dev` cannot confirm it because
    later freeze failures overwrote the field.

## What is waking it

Wake-source delta across the unplugged window (`wakeup_count` = times a source actually
woke the system from suspend):

```
event0             34     <- the Goodix touchscreen (goodix-ts, /dev/input/event0)
sy7673a_wakelock    9     <- the panel power IC, i.e. E Ink redraws
everything else     0
```

**The touchscreen woke the device 34 times while it sat untouched.** The 9 `sy7673a` wakes
are the redraws that follow. Chain: touch wake → framework redraws the AOD → E Ink refresh →
immediate re-suspend attempt collides with the refresh → freeze aborts / `eink_suspend`
refuses → retry → sleep → next touch wake. Each iteration costs a full resume plus a panel
power cycle.

Facts about the touch path: IRQ 33, `sunxi_pio_edge` pin 9, edge-triggered (matches the DT:
r_pio bank 11 pin 9). No `power/wakeup` sysfs attribute exists on the i2c client (`0-0014`)
or the input device — the driver arms the wake IRQ directly, so there is no runtime toggle.
Only `/proc/gt1x_debug` is exposed; no gesture/wake-mode knob.

## It is not steady-state chatter

One idle minute, device dozing on USB, untouched, `getevent` recording:

```
t=0    irq33=229   event0 ev/wake=304/34   sy7673a ev/wake=473/9
t=60   irq33=229   event0 ev/wake=304/34   sy7673a ev/wake=474/9
raw events from event0: 0
```

Touch completely silent. The only activity was one E Ink cycle — the AOD clock redrawing at
the minute boundary (1 cycle/min, ~277 ms; cheap). The 34 wakes happen **only across real
suspend/resume transitions**, which the USB-dozing idle never exercises.

Two explanations survive, with fixes on opposite sides of the system:

1. **Display-side coupling.** On each resume the AOD redraw drives the panel's ±15 V rails
   via the SY7673A; the capacitive controller, in its low-power resume state, registers the
   noise as a touch. Self-sustaining. Consistent with `event0` and `sy7673a` being locked
   together in the trace.
2. **Touch-driver suspend/resume handling.** GT1X's reset/IRQ line state across the
   transition fires a spurious interrupt on each resume, independent of the panel.

## The discriminator: run 2 with AOD off

Identical unplugged run with `doze_always_on=0` (screen state OFF, nothing rendered).
Baselines saved: suspend `19/12/9`, irq33 229, `event0` wakes 34, `sy7673a` wakes 9.

* `event0` wakes stay ~34 → touch was quiet with nothing drawn → **display-side (1)**.
* `event0` wakes climb by ~30 again → touch wakes on its own → **touch-driver (2)**.

Eventual fix if (2): stop the touch IRQ from waking the system — which also means the
**Moaan logo would no longer wake the device**, only the power button. That is a usability
trade the owner should make, not the tooling.

## On the black AOD

Asked whether the black AOD background is costly. Not for this problem: E Ink is bistable
(holding black is free) and the SY7673A cycles once per *update*, not per pixel — measured at
one cycle per minute while dozing. The one real effect: `gu16_max_limit=10` forces a full
refresh every 10th update, and in that full-waveform mode every pixel is driven whether it
changes or not, so a black screen costs somewhat more than white *for that one update every
~10 minutes*. Second-order. The touch-wake loop at ~7/min is the drain.

---

## Run 2 result — AOD off

Same unplugged routine, same tracing, one variable changed (`doze_always_on=0`, screen
state OFF, nothing rendered). `pm_freeze_timeout` confirmed at 20000 ms; trace clock `local`.
Buffer: 611 entries, `overrun 0`, `dropped 0` on every CPU.

```
                        RUN 1 (AOD on)     RUN 2 (AOD off)
suspend attempts             31                  4
reached machine_suspend      19                  4
failures                     12                  0
event0 (touch) wakes         34                  0
sy7673a wakes                 9                  0
```

**With nothing being drawn, the touch controller did not wake the device once in five
minutes.** Four clean suspends. The only wake activity was `rtc` (+3) and `event2`, the
power key — legitimate alarms and the operator's button press.

### Verdict: (1), display-side coupling

The touch driver does **not** wake the device on its own; if it did, a five-minute window
would have shown at least some `event0` wakes independent of AOD. It showed zero. The
spurious touches are induced by the E Ink refresh — the AOD redraw on every resume drives
the panel rails through the SY7673A, and the capacitive controller registers the noise. That
touch wakes the system, which redraws, which refreshes, which fires the touch again. Remove
the redraw and the loop cannot sustain itself.

The timing detail that makes it a *suspend* problem: the panel power cycle is ~277 ms and
the `sy7673a_wakelock` covers it, but the system begins its next suspend attempt almost
immediately after the redraw is submitted. A touch event arriving while freezing is
`pm_wakeup_pending()` → -EBUSY, which is exactly `last_failed_errno -16, step freeze`.

### What this means for a fix

* **Immediate, zero-risk: leave AOD off.** Sleep shows a black screen instead of the clock.
  Suspend then holds cleanly (this run). Trade: no sleep-screen clock. This is the device's
  state as of the end of this investigation; restoring `doze_always_on=1` restores the drain.
* **Keeping AOD requires breaking one link in the loop, and both are kernel-side:** either
  mask the touch IRQ while the panel is powered (a GT1X ↔ E Ink driver interaction), or hold
  the `sy7673a_wakelock` for some margin past `power_down` so the trailing noise cannot land
  mid-freeze. Neither can be done on the stock binary kernel.

That last point is worth stating plainly: after two days of concluding the kernel *upgrade*
had no payoff, this is the **first concrete, well-scoped piece of kernel driver work with a
measured benefit** — not a version bump, but a targeted change to touch/panel interaction on
a rebuilt 4.9 tree with the ported GT1X source.

A framework-side workaround (a short wakelock or a delay before allowing suspend after a
doze redraw) is conceivable and untested; it treats the symptom and costs battery on every
redraw, so it is a fallback, not the fix.

Files: `capture4b-aod-off/` (trace, per-CPU stats, wakeup_sources before/after,
suspend_stats before/after), `analyze-suspend-run.py` (reproduces both tables from the raw
files).
