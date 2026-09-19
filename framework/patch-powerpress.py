#!/usr/bin/env python3
"""Patch services.jar so a short power press -- and the idle timeout -- show the lock screen
BEFORE the display goes off. On E Ink the panel keeps the last composited frame, and stock
Android draws the keyguard and switches the display off concurrently, so the app frame wins
that race and becomes the sleep screen.

usage: patch-powerpress.py <PhoneWindowManager.smali> <PowerManagerService.smali>
       (edits in place, idempotent)

DESIGN NOTES, after review of an earlier attempt that was built but never installed:

* All state and every decision live in PowerManagerService. The earlier version kept shared
  statics on a class in com.android.server.policy and read them from com.android.server.power:
  package-private access does not cross packages just because the classes ship in one jar, so
  it would have thrown IllegalAccessError at runtime. Assembling cleanly proved nothing.
* PhoneWindowManager reaches the new path WITHOUT any new cross-package member: it sets a
  private bit in the flags it already passes to goToSleepFromPowerButton, which forwards them
  to PowerManager.goToSleep and so to goToSleepInternal, where the bit is recognised and
  stripped. No new API, no framework.jar change.
* Each request carries a GENERATION token. A new arm bumps the generation, so an older pending
  callback can no longer act; user activity bumps it too. The earlier version compared against
  a single shared timestamp, so a second arm could revive a first callback.
* The timeout path arms at the moment it decides to sleep, not when a queued stage runs, so
  activity between scheduling and execution is seen.
* The token check and the sleep happen in ONE acquisition of the service lock, closing the gap
  between deciding and sleeping. Volatile fields cannot close it.
* Invalidation is placed where the original method RECORDS accepted activity, after its own
  validation, so it can neither run for a rejected event nor regress a timestamp.

Behaviour is untested on a device. The patch is not installed.
"""
import re, sys

FLAG = "0x80000000"   # private bit in the goToSleep flags; stripped before anything else sees it

PMS = "Lcom/android/server/power/PowerManagerService;"
SLEEPER = "Lcom/android/server/power/InkpalmDelayedSleep;"

PMS_METHODS = f'''
# inkpalm: arm a delayed sleep instead of sleeping now. Called with the flags bit set (power
# button, via goToSleepInternal) or directly from updateWakefulnessLocked (idle timeout).
# Shows the keyguard immediately, while the screen is still on, so the panel refreshes to it.
.method private inkpalmArm(JIII)V
    .registers 12

    iget-object v0, p0, {PMS}->mLock:Ljava/lang/Object;

    monitor-enter v0

    :try_start_0
    iget-boolean v1, p0, {PMS}->mInkpalmPending:Z

    if-nez v1, :cond_done

    iget-object v1, p0, {PMS}->mPolicy:Lcom/android/server/policy/WindowManagerPolicy;

    if-eqz v1, :cond_nopolicy

    const/4 v2, 0x0

    invoke-interface {{v1, v2}}, Lcom/android/server/policy/WindowManagerPolicy;->lockNow(Landroid/os/Bundle;)V

    :cond_nopolicy
    iget v1, p0, {PMS}->mInkpalmGen:I

    add-int/lit8 v1, v1, 0x1

    iput v1, p0, {PMS}->mInkpalmGen:I

    const/4 v2, 0x1

    iput-boolean v2, p0, {PMS}->mInkpalmPending:Z

    new-instance v2, {SLEEPER}

    invoke-direct {{v2, p0, v1, p3, p5}}, {SLEEPER}-><init>({PMS}III)V

    iget-object v3, p0, {PMS}->mHandler:Landroid/os/Handler;

    const-wide/16 v4, 0x320

    invoke-virtual {{v3, v2, v4, v5}}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    :cond_done
    monitor-exit v0
    :try_end_0
    .catchall {{:try_start_0 .. :try_end_0}} :catchall_0

    return-void

    :catchall_0
    move-exception v1

    monitor-exit v0

    throw v1
.end method

# inkpalm: the delayed callback. Token check and sleep under ONE lock acquisition, so activity
# cannot slip in between them. A stale token means a newer arm or user activity superseded us.
.method inkpalmFire(III)V
    .registers 14

    iget-object v0, p0, {PMS}->mLock:Ljava/lang/Object;

    monitor-enter v0

    :try_start_0
    iget v1, p0, {PMS}->mInkpalmGen:I

    if-ne v1, p1, :cond_done

    const/4 v1, 0x0

    iput-boolean v1, p0, {PMS}->mInkpalmPending:Z

    invoke-static {{}}, Landroid/os/SystemClock;->uptimeMillis()J

    move-result-wide v5

    move-object v4, p0

    move v7, p2

    const/4 v8, 0x0

    move v9, p3

    invoke-direct/range {{v4 .. v9}}, {PMS}->goToSleepNoUpdateLocked(JIII)Z

    move-result v1

    if-eqz v1, :cond_done

    invoke-direct {{p0}}, {PMS}->updatePowerStateLocked()V

    :cond_done
    monitor-exit v0
    :try_end_0
    .catchall {{:try_start_0 .. :try_end_0}} :catchall_0

    return-void

    :catchall_0
    move-exception v1

    monitor-exit v0

    throw v1
.end method

# inkpalm: accepted user activity invalidates any pending delayed sleep. Called from
# userActivityNoUpdateLocked, which already holds the lock, at the points where it records
# the activity -- i.e. after its own validation.
.method private inkpalmInvalidate()V
    .registers 2

    iget v0, p0, {PMS}->mInkpalmGen:I

    add-int/lit8 v0, v0, 0x1

    iput v0, p0, {PMS}->mInkpalmGen:I

    const/4 v0, 0x0

    iput-boolean v0, p0, {PMS}->mInkpalmPending:Z

    return-void
.end method
'''


def patch_pms(p):
    s = open(p).read()
    if 'inkpalmFire' in s:
        print('already patched', p); return

    # 1. state
    s = s.replace('# instance fields\n',
                  '# instance fields\n.field private mInkpalmGen:I\n\n.field private mInkpalmPending:Z\n\n', 1)

    # 2. goToSleepInternal: recognise and strip the private flag bit, and arm instead of sleeping.
    m = re.search(r'\.method private goToSleepInternal\(JIII\)V\n    \.locals (\d+)\n', s)
    if not m:
        sys.exit('goToSleepInternal not found -- different framework build?')
    locals_n = int(m.group(1))
    tmp = 'v%d' % locals_n                      # one fresh register, declared by bumping .locals
    head = (f'.method private goToSleepInternal(JIII)V\n    .locals {locals_n + 1}\n')
    inject = (f'\n    const/high16 {tmp}, -{FLAG}\n\n'
              f'    and-int/2addr {tmp}, p4\n\n'
              f'    if-eqz {tmp}, :cond_inkpalm_normal\n\n'
              f'    const {tmp}, 0x7fffffff\n\n'
              f'    and-int/2addr p4, {tmp}\n\n'
              f'    invoke-direct/range {{p0 .. p5}}, {PMS}->inkpalmArm(JIII)V\n\n'
              f'    return-void\n\n'
              f'    :cond_inkpalm_normal\n')
    # keep the .param lines between the header and the body
    rest = s[m.end():]
    params = ''
    while rest.lstrip().startswith('.param'):
        line_end = rest.index('\n', rest.index('.param')) + 1
        params += rest[:line_end]; rest = rest[line_end:]
    s = s[:m.start()] + head + params + inject + rest

    # 3. idle timeout: arm instead of sleeping. 'changed' stays false -- wakefulness is unaltered.
    m = re.search(r'\.method private updateWakefulnessLocked\(I\)Z.*?\.end method', s, re.S)
    if not m:
        sys.exit('updateWakefulnessLocked not found -- different framework build?')
    old = ('    invoke-direct/range {v2 .. v7}, '
           'Lcom/android/server/power/PowerManagerService;->goToSleepNoUpdateLocked(JIII)Z\n\n'
           '    move-result v0\n')
    body = m.group(0)
    if body.count(old) != 2:
        sys.exit('updateWakefulnessLocked: expected 2 goToSleepNoUpdateLocked calls, got %d'
                 % body.count(old))
    # the SECOND one is the ordinary bedtime path (the first is the attentive-timeout case)
    idx = body.rindex(old)
    new = (f'    invoke-direct/range {{v2 .. v7}}, {PMS}->inkpalmArm(JIII)V\n\n'
           '    const/4 v0, 0x0\n')
    body = body[:idx] + new + body[idx + len(old):]
    s = s[:m.start()] + body + s[m.end():]

    # 4. invalidate where accepted activity is recorded (after the method's own validation)
    n = 0
    for field in ('mLastUserActivityTimeNoChangeLights', 'mLastUserActivityTime'):
        needle = f'    iput-wide p1, p0, {PMS}->{field}:J\n'
        if needle not in s:
            sys.exit(f'{field} write not found -- different framework build?')
        s = s.replace(needle, needle + f'\n    invoke-direct {{p0}}, {PMS}->inkpalmInvalidate()V\n', 1)
        n += 1

    s += PMS_METHODS
    open(p, 'w').write(s)
    print(f'patched {p} (invalidation points: {n})')


def patch_pwm(p):
    s = open(p).read()
    if 'inkpalm' in s:
        print('already patched', p); return
    m = re.search(r'(\.method private powerPress\(JZI\)V.*?)'
                  r'(    :cond_(\w+)\n    invoke-direct \{p0, p1, p2, (v\d)\}, '
                  r'Lcom/android/server/policy/PhoneWindowManager;->goToSleepFromPowerButton\(JI\)Z\n\n'
                  r'(    \.line \d+\n)?    :cond_\w+\n    :goto_0\n    return-void\n\.end method\n)',
                  s, re.S)
    if not m:
        sys.exit('powerPress GO_TO_SLEEP case not found -- different framework build?')
    label, reg = m.group(3), m.group(4)
    block = m.group(2)
    # Only the flags argument changes: the private bit asks PowerManagerService to show the
    # keyguard and sleep shortly after, instead of sleeping immediately.
    new_block = block.replace(
        f'    :cond_{label}\n    invoke-direct {{p0, p1, p2, {reg}}}',
        f'    :cond_{label}\n'
        f'    # inkpalm: ask for a delayed sleep so the keyguard reaches the panel first\n'
        f'    const/high16 {reg}, -{FLAG}\n\n'
        f'    invoke-direct {{p0, p1, p2, {reg}}}', 1)
    s = s[:m.start(2)] + new_block + s[m.end(2):]
    open(p, 'w').write(s)
    print('patched', p)


if len(sys.argv) < 3:
    sys.exit(__doc__)
patch_pwm(sys.argv[1])
patch_pms(sys.argv[2])
