#!/usr/bin/env python3
"""Patch the matching PHH Android 11 services.jar for a dedicated standby overlay.
PMS holds an eligible button/timeout request while StandbyScreen observes its frame and
panel completion. An independent 8-second fallback remains on the PMS handler. Every
sleep decision and cancellation is serialized by mLock; window work never runs there.
Usage: patch-powerpress.py <PhoneWindowManager.smali> <PowerManagerService.smali>
"""
import re, sys, os

FLAG = "0x80000000"   # private bit in the goToSleep flags; stripped before anything else sees it
PMS = "Lcom/android/server/power/PowerManagerService;"
SLEEPER = "Lcom/android/server/power/InkpalmDelayedSleep;"
SHOW = "Lcom/android/server/power/InkpalmShowStandby;"

# active request (the one that is pending) + staged request (the one being proposed).
# Two sets, because the coalescing decision has to happen BEFORE the new values overwrite
# the pending ones, and passing them as arguments would need registers above v15.
FIELDS = ('.field private mInkpalmFiring:Z\n\n'
          '.field private mInkpalmGen:I\n\n'
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
    return tmpl.replace('{PMS}', PMS).replace('{SLEEPER}', SLEEPER).replace('{KEYGUARD}', SHOW) \
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
    s, _ = bump_locals(s, 'goToSleepInternal(JIII)V', 2)
    m = re.search(r'\.method private goToSleepInternal\(JIII\)V\n    \.locals (\d+)\n'
                  r'((?:    \.param[^\n]*\n)*)', s)
    n = int(m.group(1))
    t, lk = 'v%d' % (n - 2), 'v%d' % (n - 1)
    # Staging and promotion must happen in ONE acquisition of mLock. Writing the request
    # fields before taking the lock lets a concurrent request overwrite them -- or interleave
    # with them field by field, mixing one request's event time with another's flags.
    inject = (f'\n    const/high16 {t}, -{FLAG}\n\n'
              f'    and-int/2addr {t}, p4\n\n'
              f'    if-eqz {t}, :cond_inkpalm_normal\n\n'
              f'    const {t}, 0x7fffffff\n\n'
              f'    and-int/2addr p4, {t}\n\n'
              f'    iget-object {lk}, p0, {PMS}->mLock:Ljava/lang/Object;\n\n'
              f'    monitor-enter {lk}\n\n'
              f'    :try_start_inkpalm\n'
              f'    const/4 {t}, 0x0\n\n'
              f'    iput-boolean {t}, p0, {PMS}->mInkpalmReqTimeout:Z\n\n'
              f'    iput-wide p1, p0, {PMS}->mInkpalmReqTime:J\n\n'
              f'    iput p3, p0, {PMS}->mInkpalmReqReason:I\n\n'
              f'    iput p4, p0, {PMS}->mInkpalmReqFlags:I\n\n'
              f'    iput p5, p0, {PMS}->mInkpalmReqUid:I\n\n'
              f'    invoke-direct {{p0}}, {PMS}->inkpalmArmLocked()Z\n\n'
              f'    move-result {t}\n\n'
              f'    if-eqz {t}, :cond_inkpalm_nochange\n\n'
              f'    invoke-direct {{p0}}, {PMS}->updatePowerStateLocked()V\n\n'
              f'    :cond_inkpalm_nochange\n'
              f'    monitor-exit {lk}\n'
              f'    :try_end_inkpalm\n'
              f'    .catchall {{:try_start_inkpalm .. :try_end_inkpalm}} :catchall_inkpalm\n\n'
              f'    return-void\n\n'
              f'    :catchall_inkpalm\n'
              f'    move-exception {t}\n\n'
              f'    monitor-exit {lk}\n\n'
              f'    throw {t}\n\n'
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
    # This caller already holds mLock (the method is *Locked), so staging and promotion are
    # in one acquisition here too. inkpalmArmLocked returns the same "changed" boolean the
    # original call produced, so the enclosing updatePowerStateLocked loop behaves as in
    # stock -- no recursive update, and a fallback sleep is not reported as "no change".
    new = (f'    const/4 v0, 0x1\n\n'
           f'    iput-boolean v0, p0, {PMS}->mInkpalmReqTimeout:Z\n\n'
           f'    iput-wide v8, p0, {PMS}->mInkpalmReqTime:J\n\n'
           f'    iput v5, p0, {PMS}->mInkpalmReqReason:I\n\n'
           f'    iput v6, p0, {PMS}->mInkpalmReqFlags:I\n\n'
           f'    iput v7, p0, {PMS}->mInkpalmReqUid:I\n\n'
           f'    invoke-direct {{p0}}, {PMS}->inkpalmArmLocked()Z\n\n'
           '    move-result v0\n')
    body = body[:idx] + new + body[idx + len(old):]
    s = s[:m.start()] + body + s[m.end():]

    # --- invalidate where accepted activity is recorded (after the method's own validation)
    n = 0
    for field in ('mLastUserActivityTimeNoChangeLights', 'mLastUserActivityTime'):
        needle = f'    iput-wide p1, p0, {PMS}->{field}:J\n'
        if needle not in s:
            sys.exit(f'{field} write not found -- different framework build?')
        callback = (f'    invoke-direct {{p0, p3}}, {PMS}->inkpalmNoChangeLightsActivity(I)V'
                    if field == 'mLastUserActivityTimeNoChangeLights'
                    else f'    invoke-direct {{p0}}, {PMS}->inkpalmInvalidate()V')
        s = s.replace(needle, needle + '\n' + callback + '\n', 1)
        n += 1

    # Wake removes the overlay; an unrelated accepted sleep supersedes pending work.
    for field, callback in [('mLastWakeTime', 'inkpalmInvalidate'),
                            ('mLastSleepTime', 'inkpalmOtherSleep')]:
        matches = list(re.finditer(r'    iput-wide ([pv]\d+), ([pv]\d+), '
                                  + re.escape(PMS) + f'->{field}:J\n', s))
        if len(matches) != 1:
            sys.exit(f'{field}: expected one accepted-transition write')
        match = matches[0]
        s = s[:match.end()] + f'\n    invoke-direct {{{match.group(2)}}}, {PMS}->{callback}()V\n' + s[match.end():]

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
        f'    # standby overlay reaches the panel first. Nothing else about this call changes.\n'
        f'    const/high16 {reg}, -{FLAG}\n\n'
        f'    invoke-direct {{p0, p1, p2, {reg}}}', 1)
    s = s[:m.start(2)] + new_block + s[m.end(2):]
    open(p, 'w').write(s)
    print('patched', p)


if len(sys.argv) < 3:
    sys.exit(__doc__)
patch_pwm(sys.argv[1])
patch_pms(sys.argv[2])
