#!/usr/bin/env python3
"""Patch PhoneWindowManager.smali so a short power press shows the lock screen first and
sleeps 800 ms later (E Ink keeps the last composited frame through sleep; unpatched, the
display is switched off before the keyguard reaches the panel, so the sleeping device shows
whatever app was open). Already on the keyguard -> sleeps immediately, as before.

usage: patch-powerpress.py <PhoneWindowManager.smali>     (edits in place, idempotent)
"""
import re, sys
p = sys.argv[1]; s = open(p).read()
if 'inkpalmSleepNow' in s:
    print('already patched'); sys.exit(0)
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
