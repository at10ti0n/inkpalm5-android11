.class Lcom/android/server/power/InkpalmDelayedSleep;
.super Ljava/lang/Object;
.source "InkpalmDelayedSleep.java"

# The delayed half of "show the lock screen, then sleep": posted by
# PowerManagerService.inkpalmArm, it calls back into inkpalmFire ~800 ms later.
#
# It carries a GENERATION token and decides nothing itself. inkpalmFire takes the service's
# own lock, compares the token against the current generation, and only then sleeps -- so a
# request that was superseded by a newer arm, or invalidated by user activity, is dropped,
# and the check cannot race against activity arriving after it.
#
# This class deliberately lives in com.android.server.power, the same package as
# PowerManagerService: it uses that class's package-private members, and package-private
# access does NOT cross packages just because two classes ship in the same jar.

.implements Ljava/lang/Runnable;

.field private final mPms:Lcom/android/server/power/PowerManagerService;
.field private final mGen:I
.field private final mReason:I
.field private final mUid:I

.method constructor <init>(Lcom/android/server/power/PowerManagerService;III)V
    .registers 5
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mPms:Lcom/android/server/power/PowerManagerService;
    iput p2, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mGen:I
    iput p3, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mReason:I
    iput p4, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mUid:I
    return-void
.end method

.method public run()V
    .registers 5
    iget-object v0, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mPms:Lcom/android/server/power/PowerManagerService;
    iget v1, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mGen:I
    iget v2, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mReason:I
    iget v3, p0, Lcom/android/server/power/InkpalmDelayedSleep;->mUid:I
    invoke-virtual {v0, v1, v2, v3}, Lcom/android/server/power/PowerManagerService;->inkpalmFire(III)V
    return-void
.end method
