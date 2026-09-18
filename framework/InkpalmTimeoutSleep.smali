.class Lcom/android/server/power/InkpalmTimeoutSleep;
.super Ljava/lang/Object;
.source "InkpalmTimeoutSleep.java"

# Idle-timeout counterpart of policy/InkpalmSleep. PowerManagerService posts stage 0 from
# updateWakefulnessLocked instead of sleeping: stage 0 shows the keyguard (screen still on)
# and schedules stage 1, which goes to sleep 800 ms later, once the E Ink panel holds the
# lock screen. See PowerManagerService.inkpalmLockNow / inkpalmSleepNow (patched).

.implements Ljava/lang/Runnable;

.field private final mPms:Lcom/android/server/power/PowerManagerService;
.field private final mStage:I

.method constructor <init>(Lcom/android/server/power/PowerManagerService;I)V
    .registers 3
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/power/InkpalmTimeoutSleep;->mPms:Lcom/android/server/power/PowerManagerService;
    iput p2, p0, Lcom/android/server/power/InkpalmTimeoutSleep;->mStage:I
    return-void
.end method

.method public run()V
    .registers 3
    iget-object v0, p0, Lcom/android/server/power/InkpalmTimeoutSleep;->mPms:Lcom/android/server/power/PowerManagerService;
    iget v1, p0, Lcom/android/server/power/InkpalmTimeoutSleep;->mStage:I
    if-nez v1, :sleep
    invoke-virtual {v0}, Lcom/android/server/power/PowerManagerService;->inkpalmLockNow()V
    return-void
    :sleep
    invoke-virtual {v0}, Lcom/android/server/power/PowerManagerService;->inkpalmSleepNow()V
    return-void
.end method
