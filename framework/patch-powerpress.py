#!/usr/bin/env python3
"""Patch PhoneWindowManager.smali so a short power press shows the lock screen first and
sleeps 800 ms later (E Ink keeps the last composited frame through sleep; unpatched, the
display is switched off before the keyguard reaches the panel, so the sleeping device shows
whatever app was open). Already on the keyguard -> sleeps immediately, as before.

usage: patch-powerpress.py <PhoneWindowManager.smali> [<PowerManagerService.smali>]
       (edits in place, idempotent)

With the second file, the idle-timeout path gets the same treatment: PowerManagerService
normally calls goToSleepNoUpdateLocked() straight from updateWakefulnessLocked(); patched, it
posts InkpalmTimeoutSleep instead (lock now, sleep 800 ms later) and arms a flag so the
repeated bedtime checks in the meantime do nothing.
"""
import re, sys

def patch_pms(p):
    s = open(p).read()
    if 'inkpalmSleepNow' in s:
        print('already patched', p); return
    old = """    :cond_1
    const/4 v5, 0x2

    const/4 v6, 0x0

    const/16 v7, 0x3e8

    move-object v2, p0

    move-wide v3, v8

    invoke-direct/range {v2 .. v7}, Lcom/android/server/power/PowerManagerService;->goToSleepNoUpdateLocked(JIII)Z

    move-result v0
"""
    m = re.search(r'\.method private updateWakefulnessLocked\(I\)Z.*?\.end method', s, re.S)
    if not m or old not in m.group(0):
        sys.exit('updateWakefulnessLocked timeout call not found -- different framework build?')
    new = """    :cond_1
    # inkpalm: do not sleep from here -- lock first, sleep 800 ms later (InkpalmTimeoutSleep).
    iget-boolean v1, p0, Lcom/android/server/power/PowerManagerService;->mInkpalmArmed:Z

    if-nez v1, :goto_0

    const/4 v1, 0x1

    iput-boolean v1, p0, Lcom/android/server/power/PowerManagerService;->mInkpalmArmed:Z

    new-instance v1, Lcom/android/server/power/InkpalmTimeoutSleep;

    const/4 v2, 0x0

    invoke-direct {v1, p0, v2}, Lcom/android/server/power/InkpalmTimeoutSleep;-><init>(Lcom/android/server/power/PowerManagerService;I)V

    iget-object v2, p0, Lcom/android/server/power/PowerManagerService;->mHandler:Landroid/os/Handler;

    invoke-virtual {v2, v1}, Landroid/os/Handler;->post(Ljava/lang/Runnable;)Z
"""
    body = m.group(0).replace(old, new, 1)
    s = s[:m.start()] + body + s[m.end():]
    s = s.replace('# instance fields\n', '# instance fields\n.field private mInkpalmArmed:Z\n\n', 1)
    # Every user-activity event passes through userActivityNoUpdateLocked, which makes it
    # the one place that can tell a delayed sleep the user is still using the device. p1 is
    # eventTime (J) in the same uptimeMillis base InkpalmSleep.arm() uses, and writing a
    # static from a param register needs no free register, so .locals is untouched.
    m2 = re.search(r'\.method private userActivityNoUpdateLocked\(JIII\)Z\n(?:[^\n]*\n)*?\n', s)
    if not m2:
        sys.exit('userActivityNoUpdateLocked prologue not found -- different framework build?')
    ins = '    sput-wide p1, Lcom/android/server/policy/InkpalmSleep;->sLastActivity:J\n\n'
    s = s[:m2.end()] + ins + s[m2.end():]
    s += """
# inkpalm: stage 0 of the idle-timeout sleep -- show the keyguard with the screen on, then
# schedule the real sleep 800 ms later.
.method inkpalmLockNow()V
    .registers 5

    invoke-static {}, Lcom/android/server/policy/InkpalmSleep;->arm()V

    iget-object v0, p0, Lcom/android/server/power/PowerManagerService;->mPolicy:Lcom/android/server/policy/WindowManagerPolicy;

    if-eqz v0, :cond_0

    const/4 v1, 0x0

    invoke-interface {v0, v1}, Lcom/android/server/policy/WindowManagerPolicy;->lockNow(Landroid/os/Bundle;)V

    :cond_0
    new-instance v0, Lcom/android/server/power/InkpalmTimeoutSleep;

    const/4 v1, 0x1

    invoke-direct {v0, p0, v1}, Lcom/android/server/power/InkpalmTimeoutSleep;-><init>(Lcom/android/server/power/PowerManagerService;I)V

    iget-object v1, p0, Lcom/android/server/power/PowerManagerService;->mHandler:Landroid/os/Handler;

    const-wide/16 v2, 0x320

    invoke-virtual {v1, v0, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    return-void
.end method

# inkpalm: the user touched the screen inside the delay window -- drop the arm so the ordinary
# timeout machinery starts again from scratch.
.method inkpalmDisarm()V
    .registers 2

    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/android/server/power/PowerManagerService;->mInkpalmArmed:Z

    return-void
.end method

# inkpalm: stage 1 -- the sleep updateWakefulnessLocked would have done (reason TIMEOUT, uid system).
.method inkpalmSleepNow()V
    .registers 7

    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/android/server/power/PowerManagerService;->mInkpalmArmed:Z

    iget-object v0, p0, Lcom/android/server/power/PowerManagerService;->mClock:Lcom/android/server/power/PowerManagerService$Clock;

    invoke-interface {v0}, Lcom/android/server/power/PowerManagerService$Clock;->uptimeMillis()J

    move-result-wide v1

    move-object v0, p0

    const/4 v3, 0x2

    const/4 v4, 0x0

    const/16 v5, 0x3e8

    invoke-direct/range {v0 .. v5}, Lcom/android/server/power/PowerManagerService;->goToSleepInternal(JIII)V

    return-void
.end method
"""
    open(p, 'w').write(s); print('patched', p)

if len(sys.argv) > 2:
    patch_pms(sys.argv[2])
p = sys.argv[1]; s = open(p).read()
if 'inkpalmSleepNow' in s:
    print('already patched', p); sys.exit(0)
# The GO_TO_SLEEP case of powerPress(JZI): the last label before the method's return.
m = re.search(r'(\.method private powerPress\(JZI\)V.*?)'
              r'(    :cond_(\w+)\n    invoke-direct \{p0, p1, p2, (v\d)\}, Lcom/android/server/policy/PhoneWindowManager;->goToSleepFromPowerButton\(JI\)Z\n\n(    \.line \d+\n)?    :cond_\w+\n    :goto_0\n    return-void\n\.end method\n)',
              s, re.S)
if not m:
    sys.exit('powerPress GO_TO_SLEEP case not found -- different framework build?')
label, flags, line = m.group(3), m.group(4), m.group(5) or ''
new = f'''    :cond_{label}
    # inkpalm: show the keyguard now (screen stays on), sleep 800 ms later via InkpalmSleep.
    invoke-virtual {{p0}}, Lcom/android/server/policy/PhoneWindowManager;->isKeyguardShowingAndNotOccluded()Z

    move-result v0

    if-nez v0, :cond_inkpalm

    const/4 v0, 0x0

    invoke-virtual {{p0, v0}}, Lcom/android/server/policy/PhoneWindowManager;->lockNow(Landroid/os/Bundle;)V

    invoke-static {{}}, Lcom/android/server/policy/InkpalmSleep;->arm()V

    new-instance v0, Lcom/android/server/policy/InkpalmSleep;

    invoke-direct {{v0, p0}}, Lcom/android/server/policy/InkpalmSleep;-><init>(Lcom/android/server/policy/PhoneWindowManager;)V

    iget-object v1, p0, Lcom/android/server/policy/PhoneWindowManager;->mHandler:Landroid/os/Handler;

    const-wide/16 v2, 0x320

    invoke-virtual {{v1, v0, v2, v3}}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    goto :goto_0

    :cond_inkpalm
    invoke-direct {{p0, p1, p2, {flags}}}, Lcom/android/server/policy/PhoneWindowManager;->goToSleepFromPowerButton(JI)Z

{line}    :cond_end_inkpalm
    :goto_0
    return-void
.end method

# inkpalm: called by InkpalmSleep; package-visible so the Runnable reaches the private sleep path.
.method inkpalmSleepNow(J)V
    .registers 4

    const/4 v0, 0x0

    invoke-direct {{p0, p1, p2, v0}}, Lcom/android/server/policy/PhoneWindowManager;->goToSleepFromPowerButton(JI)Z

    return-void
.end method
'''
# keep the original trailing label name so other jumps into it still resolve
tail_label = re.search(r'    :cond_(\w+)\n    :goto_0\n    return-void', m.group(2)).group(1)
new = new.replace(':cond_end_inkpalm', f':cond_{tail_label}')
s = s[:m.start(2)] + new + s[m.end(2):]
open(p, 'w').write(s); print('patched', p)
