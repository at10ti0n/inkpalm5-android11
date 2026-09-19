#!/usr/bin/env python3
"""Patch services.jar so a short power press -- and the idle timeout -- show the lock screen
BEFORE the display goes off. On E Ink the panel keeps the last composited frame, and stock
Android draws the keyguard and switches the display off concurrently, so the app frame wins
that race and becomes the sleep screen.

usage: patch-powerpress.py <PhoneWindowManager.smali> <PowerManagerService.smali>
       (edits in place, idempotent)

Design, after two rounds of review of earlier attempts (neither installed):

* All state and every decision live in PowerManagerService. An earlier version kept shared
  statics on a class in com.android.server.policy and read them from com.android.server.power;
  package-private access does not cross packages just because the classes ship in one jar, so
  that would have thrown IllegalAccessError. Assembling cleanly proves nothing.
* PhoneWindowManager gains no new member: it sets a private bit in the flags it already passes
  to goToSleepFromPowerButton, which forwards them to PowerManager.goToSleep and so to
  goToSleepInternal, where the bit is recognised and stripped.
* Each request carries a generation token; a new arm or accepted user activity bumps it, so a
  superseded callback cannot act.
* The token check, the eligibility re-check and the sleep happen in ONE acquisition of mLock.
* The request's ORIGINAL event time, reason, flags and uid are stored and replayed, so
  goToSleepNoUpdateLocked's own staleness checks still apply. Substituting "now" and zero
  flags would silently change which requests get rejected.
* A timeout request is re-checked against isItBedTimeYetLocked() when it fires: a wake lock
  taken during the delay, or a changed timeout, generates no user activity.
* lockNow() is NOT called under mLock. Stock PowerManagerService never invokes
  WindowManagerPolicy itself -- it hands the policy to Notifier, which calls from its own
  handler thread -- and lockNow reaches the keyguard over binder. It is posted instead.
* postDelayed's result is checked. If the looper refuses the message, the pending flag is
  cleared (otherwise it would suppress every later sleep) and the stock sleep happens inline.

Behaviour is untested on a device; the patch is not installed.
"""
import re, sys, os

FLAG = "0x80000000"   # private bit in the goToSleep flags; stripped before anything else sees it
PMS = "Lcom/android/server/power/PowerManagerService;"
SLEEPER = "Lcom/android/server/power/InkpalmDelayedSleep;"
KEYGUARD = "Lcom/android/server/power/InkpalmShowKeyguard;"

# active request (the one that is pending) + staged request (the one being proposed).
# Two sets, because the coalescing decision has to happen BEFORE the new values overwrite
# the pending ones, and passing them as arguments would need registers above v15.
FIELDS = ('.field private mInkpalmGen:I\n\n'
          '.field private mInkpalmPending:Z\n\n'
          '.field private mInkpalmIsTimeout:Z\n\n'
          '.field private mInkpalmEventTime:J\n\n'
          '.field private mInkpalmReason:I\n\n'
          '.field private mInkpalmFlags:I\n\n'
          '.field private mInkpalmUid:I\n\n'
          '.field private mInkpalmReqTimeout:Z\n\n'
          '.field private mInkpalmReqTime:J\n\n'
          '.field private mInkpalmReqReason:I\n\n'
          '.field private mInkpalmReqFlags:I\n\n'
          '.field private mInkpalmReqUid:I\n\n')


def methods():
    tmpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             '_pms_methods.tmpl')).read()
    return tmpl.replace('{PMS}', PMS).replace('{SLEEPER}', SLEEPER).replace('{KEYGUARD}', KEYGUARD) \
               .replace('{{', '{').replace('}}', '}')


def bump_locals(s, sig, extra):
    """Raise a method's .locals so a block of consecutive scratch registers becomes available.
    Safe in smali: pN names are remapped automatically, existing vN references stay valid."""
    m = re.search(r'(\.method [^\n]*%s\n    \.locals )(\d+)\n' % re.escape(sig), s)
    if not m:
        sys.exit('%s not found -- different framework build?' % sig)
    old = int(m.group(2))
    s = s[:m.start()] + m.group(1) + str(old + extra) + '\n' + s[m.end():]
    return s, old


def patch_pms(p):
    s = open(p).read()
    if 'inkpalmFire' in s:
        print('already patched', p); return

    s = s.replace('# instance fields\n', '# instance fields\n' + FIELDS, 1)

    # --- goToSleepInternal: recognise the private bit, strip it, stage the request, arm.
    # Only ONE extra local is needed (the bit test); staging uses the parameter registers
    # directly, so nothing is pushed past v15.
    s, _ = bump_locals(s, 'goToSleepInternal(JIII)V', 1)
    m = re.search(r'\.method private goToSleepInternal\(JIII\)V\n    \.locals (\d+)\n'
                  r'((?:    \.param[^\n]*\n)*)', s)
    t = 'v%d' % (int(m.group(1)) - 1)
    inject = (f'\n    const/high16 {t}, -{FLAG}\n\n'
              f'    and-int/2addr {t}, p4\n\n'
              f'    if-eqz {t}, :cond_inkpalm_normal\n\n'
              f'    const {t}, 0x7fffffff\n\n'
              f'    and-int/2addr p4, {t}\n\n'
              f'    const/4 {t}, 0x0\n\n'
              f'    iput-boolean {t}, p0, {PMS}->mInkpalmReqTimeout:Z\n\n'
              f'    iput-wide p1, p0, {PMS}->mInkpalmReqTime:J\n\n'
              f'    iput p3, p0, {PMS}->mInkpalmReqReason:I\n\n'
              f'    iput p4, p0, {PMS}->mInkpalmReqFlags:I\n\n'
              f'    iput p5, p0, {PMS}->mInkpalmReqUid:I\n\n'
              f'    invoke-direct {{p0}}, {PMS}->inkpalmArm()V\n\n'
              f'    return-void\n\n'
              f'    :cond_inkpalm_normal\n')
    s = s[:m.end()] + inject + s[m.end():]

    # --- idle timeout: stage the request and arm instead of sleeping. No .locals change:
    # v5/v6/v7 already hold reason/flags/uid and v8 the time; v0 is the 'changed' result,
    # free to borrow before it is assigned.
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
    idx = body.rindex(old)          # the second is the ordinary bedtime path
    new = (f'    const/4 v0, 0x1\n\n'
           f'    iput-boolean v0, p0, {PMS}->mInkpalmReqTimeout:Z\n\n'
           f'    iput-wide v8, p0, {PMS}->mInkpalmReqTime:J\n\n'
           f'    iput v5, p0, {PMS}->mInkpalmReqReason:I\n\n'
           f'    iput v6, p0, {PMS}->mInkpalmReqFlags:I\n\n'
           f'    iput v7, p0, {PMS}->mInkpalmReqUid:I\n\n'
           f'    invoke-direct {{p0}}, {PMS}->inkpalmArm()V\n\n'
           '    const/4 v0, 0x0\n')
    body = body[:idx] + new + body[idx + len(old):]
    s = s[:m.start()] + body + s[m.end():]

    # --- invalidate where accepted activity is recorded (after the method's own validation)
    n = 0
    for field in ('mLastUserActivityTimeNoChangeLights', 'mLastUserActivityTime'):
        needle = f'    iput-wide p1, p0, {PMS}->{field}:J\n'
        if needle not in s:
            sys.exit(f'{field} write not found -- different framework build?')
        s = s.replace(needle, needle + f'\n    invoke-direct {{p0}}, {PMS}->inkpalmInvalidate()V\n', 1)
        n += 1

    s += methods()
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
    new_block = block.replace(
        f'    :cond_{label}\n    invoke-direct {{p0, p1, p2, {reg}}}',
        f'    :cond_{label}\n'
        f'    # inkpalm: private flag bit -- ask PowerManagerService for a delayed sleep so the\n'
        f'    # keyguard reaches the panel first. Nothing else about this call changes.\n'
        f'    const/high16 {reg}, -{FLAG}\n\n'
        f'    invoke-direct {{p0, p1, p2, {reg}}}', 1)
    s = s[:m.start(2)] + new_block + s[m.end(2):]
    open(p, 'w').write(s)
    print('patched', p)


if len(sys.argv) < 3:
    sys.exit(__doc__)
patch_pwm(sys.argv[1])
patch_pms(sys.argv[2])
