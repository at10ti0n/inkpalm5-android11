#!/usr/bin/env python3
"""Model test for the standby-sleep interlock in patch-powerpress.py.

SCOPE, stated plainly: this exercises the ALGORITHM -- generation tokens, the coalescing
policy, what is re-checked when the callback fires, and what happens when scheduling fails.
It is NOT a test of the smali and NOT a test of the device.

It cannot catch what a model cannot see. The previous revision of this patch assembled only
after a register-allocation failure was found by the assembler, not here: most Dalvik
instructions address v0-v15 only, and raising an existing method's .locals shifts its
parameter registers past that. It also cannot see lock ordering -- window creation is modelled as
a plain call, whereas in the real code it reaches window manager over binder, which is why it
must not run under the power lock.

What it is good for: orderings, which are cheap to get wrong and expensive to find on a device
that has to be power-cycled by hand.
"""

BUTTON, TIMEOUT = False, True


class Pms:
    """One method per patched method. Each body is what the smali does while holding mLock,
    so calling them one at a time models the lock."""

    def __init__(self, bedtime=True, post_ok=True):
        self.gen = 0
        self.pending = False
        self.active = None          # (event_time, reason, flags, uid, is_timeout)
        self.staged = None
        self.posted = []            # tokens handed to postDelayed
        self.overlay_queue = []    # tokens handed to the overlay Runnable
        self.overlay_shown = 0     # times an overlay was added
        self.slept = []             # (event_time, reason, flags, uid) actually slept with
        self.bedtime = bedtime      # what isItBedTimeYetLocked() will say when the callback runs
        self.post_ok = post_ok      # whether the looper accepts messages

    # Staging and promotion are ONE operation because they happen in one acquisition of
    # mLock. Modelling them as two callable steps would model the bug, not the code: an
    # earlier revision staged the request BEFORE taking the lock, so a second request could
    # overwrite the fields, or interleave with them field by field, between staging and
    # promotion. test_staging_is_atomic below pins that down.
    def request(self, req):
        self.staged = req
        self._arm_locked()

    def _arm_locked(self):
        if self.pending:
            if self.staged[4] is TIMEOUT:      # new is a timeout -> coalesce
                return
            if self.active[4] is BUTTON:       # pending is already a button request -> coalesce
                return
            # pending timeout + new button -> supersede
        self.active = self.staged
        self.gen += 1
        self.pending = True
        self.overlay_queue.append(self.gen)     # the overlay Runnable carries the token too
        if not self.post_ok:
            self.pending = False
            self.gen += 1
            return self._sleep_now()             # returns "changed" to the caller; no recursion
        self.posted.append(self.gen)
        return False

    def user_activity(self, no_change_lights=False, event=0):
        if no_change_lights and event == 0 and self.pending and self.active[4] is BUTTON:
            return
        self.gen += 1
        self.pending = False

    # PMS and render worker each validate the token; the real worker owns cleanup too.
    def overlay_validate(self, token):
        """Under mLock: decide whether this queued overlay message is still live."""
        return self.pending and token == self.gen

    def overlay_dispatch(self, token):
        """The render worker checks the generation again before adding a window.
        Cancellation racing the add can still flash an overlay; queued removal cleans it up.
        """
        if self.overlay_validate(token):
            self.overlay_shown += 1

    def run_overlay(self, token):
        self.overlay_dispatch(token)

    def fire(self, token):
        if token != self.gen or not self.pending:
            return
        self.pending = False
        if self.active[4] is TIMEOUT and not self.bedtime:
            return                  # no longer warranted: wake lock taken, or timeout changed
        self._sleep_now()

    def _sleep_now(self):
        self.slept.append(self.active[:4])
        return True


def check(name, cond):
    print(("PASS  " if cond else "FAIL  ") + name)
    return cond


ok = True
BTN = (1000, "button", 0, 1000, BUTTON)
TMO = (2000, "timeout", 0, 1000, TIMEOUT)

# 1. ordinary cases
p = Pms(); p.request(BTN); p.fire(p.posted[0])
ok &= check("arm then fire sleeps once, with the ORIGINAL event time and flags",
            p.slept == [BTN[:4]] and not p.pending)

# 2. activity inside the window cancels
p = Pms(); p.request(BTN); p.user_activity(); p.fire(p.posted[0])
ok &= check("activity before fire cancels the sleep", p.slept == [] and not p.pending)

# Software wake-lock-release activity cannot undo an explicit button request.
p = Pms(); p.request(BTN); p.user_activity(no_change_lights=True); p.fire(p.posted[0])
ok &= check("software NO_CHANGE_LIGHTS preserves button fallback", p.slept == [BTN[:4]])
p = Pms(); p.request(TMO); p.user_activity(no_change_lights=True); p.fire(p.posted[0])
ok &= check("software activity still cancels idle timeout", p.slept == [])
p = Pms(); p.request(BTN); p.user_activity(no_change_lights=True, event=2); p.fire(p.posted[0])
ok &= check("touch with NO_CHANGE_LIGHTS still cancels button sleep", p.slept == [])

# 3. the revival case: arm A, activity, arm B, then A's callback runs
p = Pms(); p.request(BTN); a = p.posted[0]
p.user_activity(); p.request(TMO); b = p.posted[1]
p.fire(a)
ok &= check("stale callback A does not sleep after re-arm", p.slept == [])
ok &= check("...and does not clear B's pending flag", p.pending)
p.fire(b)
ok &= check("...and B still sleeps", p.slept == [TMO[:4]])

# 4. coalescing policy, each case stated
p = Pms(); p.request(TMO); p.request(TMO); p.request(TMO)
ok &= check("timeout while a timeout is pending: coalesced, posted once",
            len(p.posted) == 1 and len(p.overlay_queue) == 1)

p = Pms(); p.request(TMO); first = p.posted[0]
p.request(BTN)
ok &= check("button while a timeout is pending: supersedes", len(p.posted) == 2)
p.fire(first)
ok &= check("...the superseded timeout callback does nothing", p.slept == [])
p.fire(p.posted[1])
ok &= check("...and the button request sleeps with ITS event time", p.slept == [BTN[:4]])

p = Pms(); p.request(BTN); p.request(TMO); p.request(BTN)
ok &= check("anything while a button request is pending: coalesced", len(p.posted) == 1)

# 5. eligibility is re-checked for a timeout, not for a button
p = Pms(bedtime=False); p.request(TMO); p.fire(p.posted[0])
ok &= check("timeout no longer warranted at fire time: does not sleep",
            p.slept == [] and not p.pending)
p = Pms(bedtime=False); p.request(BTN); p.fire(p.posted[0])
ok &= check("button request is unconditional, as in stock", p.slept == [BTN[:4]])

# 6. scheduling failure must not wedge the device awake forever
p = Pms(post_ok=False); p.request(TMO)
ok &= check("postDelayed refused: pending cleared and the stock sleep happens inline",
            p.slept == [TMO[:4]] and not p.pending and p.posted == [])
p.request(TMO)
ok &= check("...and a later request is not suppressed", len(p.slept) == 2)

# 7. activity after the callback has slept
p = Pms(); p.request(BTN); p.fire(p.posted[0]); p.user_activity()
ok &= check("activity after fire leaves nothing pending", p.slept == [BTN[:4]] and not p.pending)

# 8. a very stale token never fires
p = Pms(); p.request(BTN); old = p.posted[0]
for _ in range(5):
    p.user_activity(); p.request(TMO)
p.fire(old)
ok &= check("very stale token never fires", p.slept == [])

# 9. staging must not be separable from promotion. The earlier revision wrote the request
#    fields before taking the lock; a second request could then land in between. The model
#    exposes only request(), so the interleaving cannot be expressed -- and this check pins
#    the consequence it used to have.
p = Pms()
p.request(BTN)
p.request(TMO)                      # button pending -> coalesced, must NOT become the active one
ok &= check("a later request cannot overwrite the active one (the staging race)",
            p.active == BTN and len(p.posted) == 1)
p.fire(p.posted[0])
ok &= check("...and the button request sleeps with its own values", p.slept == [BTN[:4]])

# 10. the queued overlay work must respect the same token
p = Pms(); p.request(BTN); tok = p.posted[0]
p.user_activity()                   # cancels the sleep
p.run_overlay(p.overlay_queue[0])
ok &= check("cancelled request: the queued overlay does not appear",
            p.overlay_shown == 0)
p.fire(tok)
ok &= check("...and nothing sleeps", p.slept == [])

p = Pms(); p.request(TMO); old_kg = p.overlay_queue[0]
p.request(BTN)                      # supersedes
p.run_overlay(old_kg)
ok &= check("superseded request: its overlay work is dropped", p.overlay_shown == 0)
p.run_overlay(p.overlay_queue[1])
ok &= check("...while the live request still shows the overlay", p.overlay_shown == 1)

# 11. scheduling failure returns "changed" to the caller instead of updating power state again
p = Pms(post_ok=False); p.staged = TMO
changed = p._arm_locked()
ok &= check("failed scheduling reports the change to its caller, does not recurse",
            changed is True and p.slept == [TMO[:4]])
p2 = Pms(); p2.staged = TMO
ok &= check("normal arming reports no change", p2._arm_locked() is False)

# 12. Cancellation before the render worker runs prevents an old overlay from showing.
p = Pms(); p.request(TMO); tok = p.posted[0]
assert p.overlay_validate(tok)
p.user_activity()
p.overlay_dispatch(tok)
ok &= check("cancelled before render-worker dispatch: stale overlay is dropped",
            p.overlay_shown == 0)
p.fire(tok)
ok &= check("...and its sleep is cancelled", p.slept == [] and not p.pending)

# 13. The real implementation has TWO callbacks: completion and timeout. Only one may sleep.
p = Pms(); p.request(BTN); tok = p.posted[0]
p.fire(tok); p.fire(tok)
ok &= check("completion followed by fallback sleeps exactly once", p.slept == [BTN[:4]])
p = Pms(); p.request(BTN); tok = p.posted[0]
p.fire(tok); p.user_activity(); p.fire(tok)
ok &= check("late completion after fallback and wake cannot re-sleep", p.slept == [BTN[:4]])

# 14. A wake or an unrelated accepted sleep uses the same invalidation operation.
p = Pms(); p.request(TMO); tok = p.posted[0]
p.user_activity(); p.fire(tok)
ok &= check("superseding transition invalidates queued sleep", p.slept == [])

print("\nall model checks passed" if ok else "\nMODEL CHECKS FAILED")
raise SystemExit(0 if ok else 1)
