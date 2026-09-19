.class Lcom/android/server/power/InkpalmShowKeyguard;
.super Ljava/lang/Object;
.source "InkpalmShowKeyguard.java"

# Shows the keyguard on the handler thread, so the E Ink panel has drawn it before the
# delayed sleep switches the display off.
#
# Why a posted Runnable and not a direct call: PowerManagerService never invokes
# WindowManagerPolicy itself in stock code -- it hands the policy to Notifier, which calls it
# from its own handler thread. lockNow() reaches the keyguard service over binder, so calling
# it while holding mLock would hold the power lock across an outbound call into window
# manager: a lock-ordering hazard stock deliberately avoids. inkpalmShowKeyguard() reads the
# policy reference under the lock and makes the call after releasing it.

.implements Ljava/lang/Runnable;

.field private final mPms:Lcom/android/server/power/PowerManagerService;

.method constructor <init>(Lcom/android/server/power/PowerManagerService;)V
    .registers 2
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/power/InkpalmShowKeyguard;->mPms:Lcom/android/server/power/PowerManagerService;
    return-void
.end method

.method public run()V
    .registers 2
    iget-object v0, p0, Lcom/android/server/power/InkpalmShowKeyguard;->mPms:Lcom/android/server/power/PowerManagerService;
    invoke-virtual {v0}, Lcom/android/server/power/PowerManagerService;->inkpalmShowKeyguard()V
    return-void
.end method
