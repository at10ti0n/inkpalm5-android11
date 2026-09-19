.class Lcom/android/server/power/InkpalmShowKeyguard;
.super Ljava/lang/Object;
.source "InkpalmShowKeyguard.java"

# Shows the keyguard on the handler thread, so the E Ink panel has drawn it before the
# delayed sleep switches the display off.
#
# It carries the same GENERATION token as the sleep callback, and inkpalmShowKeyguard checks
# it: without that, user activity could cancel the sleep while this queued message still ran
# and locked the device anyway -- and a superseded request would keep the same side effect.
#
# Why a posted Runnable rather than a direct call: stock PowerManagerService never invokes
# WindowManagerPolicy at all -- it hands the policy to Notifier, which calls it from its own
# handler thread -- and lockNow() reaches the keyguard over binder. Holding mLock across that
# is a lock-ordering hazard, so the policy reference is read under the lock and the call is
# made after releasing it.

.implements Ljava/lang/Runnable;

.field private final mPms:Lcom/android/server/power/PowerManagerService;
.field private final mGen:I

.method constructor <init>(Lcom/android/server/power/PowerManagerService;I)V
    .registers 3
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/power/InkpalmShowKeyguard;->mPms:Lcom/android/server/power/PowerManagerService;
    iput p2, p0, Lcom/android/server/power/InkpalmShowKeyguard;->mGen:I
    return-void
.end method

.method public run()V
    .registers 3
    iget-object v0, p0, Lcom/android/server/power/InkpalmShowKeyguard;->mPms:Lcom/android/server/power/PowerManagerService;
    iget v1, p0, Lcom/android/server/power/InkpalmShowKeyguard;->mGen:I
    invoke-virtual {v0, v1}, Lcom/android/server/power/PowerManagerService;->inkpalmShowKeyguard(I)V
    return-void
.end method
