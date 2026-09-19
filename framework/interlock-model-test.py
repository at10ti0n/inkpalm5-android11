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
        self.keyguard_posts = 0
        self.slept = []             # (event_time, reason, flags, uid) actually slept with
        self.bedtime = bedtime      # what isItBedTimeYetLocked() will say when the callback runs
        self.post_ok = post_ok      # whether the looper accepts messages

    def stage(self, event_time, reason, flags, uid, is_timeout):
        self.staged = (event_time, reason, flags, uid, is_timeout)

    def arm(self):
        if self.pending:
            if self.staged[4] is TIMEOUT:      # new is a timeout -> coalesce
                return
            if self.active[4] is BUTTON:       # pending is already a button request -> coalesce
                return
            # pending timeout + new button -> supersede
        self.active = self.staged
        self.gen += 1
        self.pending = True
        self.keyguard_posts += 1
        if not self.post_ok:
            self.pending = False
            self.gen += 1
            self._sleep_now()
            return
        self.posted.append(self.gen)

    def user_activity(self):        # reached only after the original method's validation
        self.gen += 1
        self.pending = False

    def fire(self, token):
        if token != self.gen:
            return
        self.pending = False
        if self.active[4] is TIMEOUT and not self.bedtime:
            return                  # no longer warranted: wake lock taken, or timeout changed
        self._sleep_now()

    def _sleep_now(self):
        self.slept.append(self.active[:4])


def check(name, cond):
    print(("PASS  " if cond else "FAIL  ") + name)
    return cond


ok = True
BTN = (1000, "button", 0, 1000, BUTTON)
TMO = (2000, "timeout", 0, 1000, TIMEOUT)

# 1. ordinary cases
p = Pms(); p.stage(*BTN); p.arm(); p.fire(p.posted[0])
ok &= check("arm then fire sleeps once, with the ORIGINAL event time and flags",
            p.slept == [BTN[:4]] and not p.pending)

# 2. activity inside the window cancels
p = Pms(); p.stage(*BTN); p.arm(); p.user_activity(); p.fire(p.posted[0])
ok &= check("activity before fire cancels the sleep", p.slept == [] and not p.pending)

# 3. the revival case: arm A, activity, arm B, then A's callback runs
p = Pms(); p.stage(*BTN); p.arm(); a = p.posted[0]
p.user_activity(); p.stage(*TMO); p.arm(); b = p.posted[1]
p.fire(a)
ok &= check("stale callback A does not sleep after re-arm", p.slept == [])
ok &= check("...and does not clear B's pending flag", p.pending)
p.fire(b)
ok &= check("...and B still sleeps", p.slept == [TMO[:4]])

# 4. coalescing policy, each case stated
p = Pms(); p.stage(*TMO); p.arm(); p.stage(*TMO); p.arm(); p.stage(*TMO); p.arm()
ok &= check("timeout while a timeout is pending: coalesced, posted once",
            len(p.posted) == 1 and p.keyguard_posts == 1)

p = Pms(); p.stage(*TMO); p.arm(); first = p.posted[0]
p.stage(*BTN); p.arm()
ok &= check("button while a timeout is pending: supersedes", len(p.posted) == 2)
p.fire(first)
ok &= check("...the superseded timeout callback does nothing", p.slept == [])
p.fire(p.posted[1])
ok &= check("...and the button request sleeps with ITS event time", p.slept == [BTN[:4]])

p = Pms(); p.stage(*BTN); p.arm(); p.stage(*TMO); p.arm(); p.stage(*BTN); p.arm()
ok &= check("anything while a button request is pending: coalesced", len(p.posted) == 1)

# 5. eligibility is re-checked for a timeout, not for a button
p = Pms(bedtime=False); p.stage(*TMO); p.arm(); p.fire(p.posted[0])
ok &= check("timeout no longer warranted at fire time: does not sleep",
            p.slept == [] and not p.pending)
p = Pms(bedtime=False); p.stage(*BTN); p.arm(); p.fire(p.posted[0])
ok &= check("button request is unconditional, as in stock", p.slept == [BTN[:4]])

# 6. scheduling failure must not wedge the device awake forever
p = Pms(post_ok=False); p.stage(*TMO); p.arm()
ok &= check("postDelayed refused: pending cleared and the stock sleep happens inline",
            p.slept == [TMO[:4]] and not p.pending and p.posted == [])
p.stage(*TMO); p.arm()
ok &= check("...and a later request is not suppressed", len(p.slept) == 2)

# 7. activity after the callback has slept
p = Pms(); p.stage(*BTN); p.arm(); p.fire(p.posted[0]); p.user_activity()
ok &= check("activity after fire leaves nothing pending", p.slept == [BTN[:4]] and not p.pending)

# 8. a very stale token never fires
p = Pms(); p.stage(*BTN); p.arm(); old = p.posted[0]
for _ in range(5):
    p.user_activity(); p.stage(*TMO); p.arm()
p.fire(old)
ok &= check("very stale token never fires", p.slept == [])

print("\nall model checks passed" if ok else "\nMODEL CHECKS FAILED")
raise SystemExit(0 if ok else 1)
