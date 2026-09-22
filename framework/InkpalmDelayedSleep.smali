.class Lcom/android/server/power/InkpalmDelayedSleep;
.super Ljava/lang/Object;
.source "InkpalmDelayedSleep.java"

# The completion / fallback half of "show the standby image, then sleep". It carries ONLY a generation token
# and decides nothing: the request itself (event time, reason, flags, uid, origin) lives in
# PowerManagerService, because at most one request is pending at a time, and reading it there
# under the lock is what keeps the decision atomic.
#
# inkpalmFire takes the service lock, checks the token, re-checks that a timeout request is
# still warranted, and only then sleeps -- with the ORIGINAL event time and flags, so the
# service's own staleness checks still apply.
#
# In com.android.server.power on purpose: it calls a package-private method on
# PowerManagerService, and package-private access does not cross packages just because two
# classes ship in the same jar.

.implements Ljava/lang/Runnable;

.field private final mPms:Lcom/android/server/power/PowerManagerService;
.field private final mGen:I

.method constructor <init>(Lcom/android/server/power/PowerManagerService;I)V
    .registers 3
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mPms:Lcom/android/server/power/PowerManagerService;
    iput p2, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mGen:I
    return-void
.end method

.method public run()V
    .registers 3
    iget-object v0, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mPms:Lcom/android/server/power/PowerManagerService;
    iget v1, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mGen:I
    invoke-virtual {v0, v1}, Lcom/android/server/power/PowerManagerService;->inkpalmFire(I)V
    return-void
.end method
