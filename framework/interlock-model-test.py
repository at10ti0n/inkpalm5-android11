#!/usr/bin/env python3
"""Model test for the delayed-sleep interlock in patch-powerpress.py.

SCOPE, stated plainly: this exercises the ALGORITHM (generation tokens, the pending flag, and
what happens under the lock), not the smali and not the device. It cannot catch a register
mistake, a verifier rejection or a wrong insertion point. Behaviour on a device is untested.

It exists because the interesting failures are orderings, and an ordering bug is cheap to
find here and expensive to find on a device that has to be power-cycled by hand.
"""


class Pms:
    """Mirrors inkpalmArm / inkpalmFire / inkpalmInvalidate. Every method body here is what
    the smali does while holding mLock, so running them one at a time models the lock."""

    def __init__(self):
        self.gen = 0
        self.pending = False
        self.posted = []          # (token, reason, uid), in post order
        self.slept = []           # reasons actually slept with
        self.locked_now = 0       # times the keyguard was shown

    def arm(self, reason, uid):
        if self.pending:          # already armed: do not post a second callback
            return
        self.locked_now += 1
        self.gen += 1
        self.pending = True
        self.posted.append((self.gen, reason, uid))

    def user_activity(self):      # only reached after the original method's validation
        self.gen += 1
        self.pending = False

    def fire(self, token, reason, uid):
        if token != self.gen:     # superseded by a newer arm, or invalidated by activity
            return
        self.pending = False
        self.slept.append(reason)


def check(name, cond):
    print(("PASS  " if cond else "FAIL  ") + name)
    return cond


ok = True

# 1. the ordinary case
p = Pms(); p.arm("button", 1000); tok = p.posted[0]; p.fire(*tok)
ok &= check("arm then fire sleeps once", p.slept == ["button"] and not p.pending)

# 2. activity inside the delay window cancels
p = Pms(); p.arm("button", 1000); tok = p.posted[0]; p.user_activity(); p.fire(*tok)
ok &= check("activity before fire cancels the sleep", p.slept == [] and not p.pending)

# 3. THE REVIVAL BUG the review found: arm A, activity, arm B, then A's callback runs.
#    With a single shared timestamp, A compared against B's stamp and slept. With tokens it
#    must not, and B must still work.
p = Pms(); p.arm("button", 1000); a = p.posted[0]
p.user_activity(); p.arm("timeout", 1000); b = p.posted[1]
p.fire(*a)
ok &= check("stale callback A does not sleep after re-arm", p.slept == [])
ok &= check("...and does not clear B's pending flag", p.pending)
p.fire(*b)
ok &= check("...and B still sleeps", p.slept == ["timeout"])

# 4. re-arming while a request is pending must not post a second callback (the timeout path
#    runs updateWakefulnessLocked repeatedly; without this it could re-arm forever)
p = Pms(); p.arm("timeout", 1000); p.arm("timeout", 1000); p.arm("timeout", 1000)
ok &= check("re-arm while pending posts once", len(p.posted) == 1 and p.locked_now == 1)

# 5. activity arriving AFTER the token check would have to interleave inside fire(); the real
#    code does the check and the sleep in one lock acquisition, so the only two orderings are
#    activity-then-fire (cancelled, case 2) and fire-then-activity (slept, then activity acts
#    on an already-asleep device). Model both to record the intent.
p = Pms(); p.arm("button", 1000); tok = p.posted[0]; p.fire(*tok); p.user_activity()
ok &= check("activity after fire does not un-sleep, and leaves nothing pending",
            p.slept == ["button"] and not p.pending)

# 6. a token from a previous generation can never match after any number of arms
p = Pms(); p.arm("button", 1000); old = p.posted[0]
for _ in range(5):
    p.user_activity(); p.arm("timeout", 1000)
p.fire(*old)
ok &= check("very stale token never fires", p.slept == [])

print("\nall model checks passed" if ok else "\nMODEL CHECKS FAILED")
raise SystemExit(0 if ok else 1)
