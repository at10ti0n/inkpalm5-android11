#!/usr/bin/env python3
"""Model test for the delayed-sleep interlock in patch-powerpress.py.

SCOPE, stated plainly: this exercises the ALGORITHM -- generation tokens, the coalescing
policy, what is re-checked when the callback fires, and what happens when scheduling fails.
It is NOT a test of the smali and NOT a test of the device.

It cannot catch what a model cannot see. The previous revision of this patch assembled only
after a register-allocation failure was found by the assembler, not here: most Dalvik
instructions address v0-v15 only, and raising an existing method's .locals shifts its
parameter registers past that. It also cannot see lock ordering -- `lockNow()` is modelled as
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
        self.keyguard_queue = []    # tokens handed to the keyguard Runnable
        self.keyguard_shown = 0     # times it actually locked the device
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
        self.keyguard_queue.append(self.gen)     # the keyguard Runnable carries the token too
        if not self.post_ok:
            self.pending = False
            self.gen += 1
            return self._sleep_now()             # returns "changed" to the caller; no recursion
        self.posted.append(self.gen)
        return False

    def user_activity(self):        # reached only after the original method's validation
        self.gen += 1
        self.pending = False

    # Deliberately TWO steps, because the real code is two steps: the token is validated
    # under mLock, the lock is released, and only then does lockNow() go out over binder.
    # Modelling them as one operation would hide the window between them, which is exactly
    # what an earlier revision of this file did.
    def keyguard_validate(self, token):
        """Under mLock: decide whether this queued keyguard message is still live."""
        return self.pending and token == self.gen

    def keyguard_dispatch(self, validated):
        """After releasing mLock: the outbound call. Nothing can stop it at this point."""
        if validated:
            self.keyguard_shown += 1

    def run_keyguard(self, token):
        self.keyguard_dispatch(self.keyguard_validate(token))

    def fire(self, token):
        if token != self.gen:
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
            len(p.posted) == 1 and len(p.keyguard_queue) == 1)

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

# 10. the queued keyguard work must respect the same token
p = Pms(); p.request(BTN); tok = p.posted[0]
p.user_activity()                   # cancels the sleep
p.run_keyguard(p.keyguard_queue[0])
ok &= check("cancelled request: the queued keyguard does NOT lock the device",
            p.keyguard_shown == 0)
p.fire(tok)
ok &= check("...and nothing sleeps", p.slept == [])

p = Pms(); p.request(TMO); old_kg = p.keyguard_queue[0]
p.request(BTN)                      # supersedes
p.run_keyguard(old_kg)
ok &= check("superseded request: its keyguard work is dropped", p.keyguard_shown == 0)
p.run_keyguard(p.keyguard_queue[1])
ok &= check("...while the live request still shows the keyguard", p.keyguard_shown == 1)

# 11. scheduling failure returns "changed" to the caller instead of updating power state again
p = Pms(post_ok=False); p.staged = TMO
changed = p._arm_locked()
ok &= check("failed scheduling reports the change to its caller, does not recurse",
            changed is True and p.slept == [TMO[:4]])
p2 = Pms(); p2.staged = TMO
ok &= check("normal arming reports no change", p2._arm_locked() is False)

# 12. The accepted race, asserted rather than hidden. Activity landing AFTER validation but
#     BEFORE the outbound call does not stop the keyguard: dispatch is committed at
#     validation. The sleep is still cancelled, so the device stays awake and locked.
p = Pms(); p.request(TMO); tok = p.posted[0]
v = p.keyguard_validate(p.keyguard_queue[0])        # passes: still live
p.user_activity()                                   # lands in the window
p.keyguard_dispatch(v)
ok &= check("ACCEPTED: activity after validation does not stop the keyguard",
            p.keyguard_shown == 1)
p.fire(tok)
ok &= check("...but the sleep is still cancelled, so the device stays awake and locked",
            p.slept == [] and not p.pending)

print("\nall model checks passed" if ok else "\nMODEL CHECKS FAILED")
raise SystemExit(0 if ok else 1)
