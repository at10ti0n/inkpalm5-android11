.class Lcom/android/server/policy/InkpalmSleep;
.super Ljava/lang/Object;
.source "InkpalmSleep.java"

# Runs ~800 ms after a short power press: by then the keyguard (the standby image) has been
# composited and the E Ink panel has refreshed, so the frame it holds through sleep is the
# lock screen, not the app that was open. See PhoneWindowManager.powerPress (patched).
#
# The two static fields are the user-activity interlock, shared with the idle-timeout path in
# com.android.server.power (same jar, same classloader, so a static is the cheapest channel
# between the two services):
#
#   sArmTime      set when either path arms a delayed sleep
#   sLastActivity written by PowerManagerService.userActivityNoUpdateLocked on EVERY user
#                 activity event, which is the one place that sees all of them
#
# At fire time, sLastActivity > sArmTime means the user touched the screen inside the delay
# window, and the sleep is abandoned. Without this the device sleeps ~800 ms after the press
# no matter what the user does in between -- the defect that keeps this patch unshipped.

.implements Ljava/lang/Runnable;

.field static volatile sArmTime:J
.field static volatile sLastActivity:J

.field private final mPwm:Lcom/android/server/policy/PhoneWindowManager;

.method static constructor <clinit>()V
    .registers 2
    const-wide/16 v0, 0x0
    sput-wide v0, Lcom/android/server/policy/InkpalmSleep;->sArmTime:J
    sput-wide v0, Lcom/android/server/policy/InkpalmSleep;->sLastActivity:J
    return-void
.end method

.method constructor <init>(Lcom/android/server/policy/PhoneWindowManager;)V
    .registers 2
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/policy/InkpalmSleep;->mPwm:Lcom/android/server/policy/PhoneWindowManager;
    return-void
.end method

# true when the user did something after the delayed sleep was armed.
.method static cancelled()Z
    .registers 5
    sget-wide v0, Lcom/android/server/policy/InkpalmSleep;->sLastActivity:J
    sget-wide v2, Lcom/android/server/policy/InkpalmSleep;->sArmTime:J
    cmp-long v4, v0, v2
    if-lez v4, :cond_not_cancelled
    const/4 v0, 0x1
    return v0
    :cond_not_cancelled
    const/4 v0, 0x0
    return v0
.end method

.method static arm()V
    .registers 2
    invoke-static {}, Landroid/os/SystemClock;->uptimeMillis()J
    move-result-wide v0
    sput-wide v0, Lcom/android/server/policy/InkpalmSleep;->sArmTime:J
    return-void
.end method

.method public run()V
    .registers 4
    invoke-static {}, Lcom/android/server/policy/InkpalmSleep;->cancelled()Z
    move-result v0
    if-eqz v0, :cond_sleep
    return-void
    :cond_sleep
    iget-object v0, p0, Lcom/android/server/policy/InkpalmSleep;->mPwm:Lcom/android/server/policy/PhoneWindowManager;
    invoke-static {}, Landroid/os/SystemClock;->uptimeMillis()J
    move-result-wide v1
    invoke-virtual {v0, v1, v2}, Lcom/android/server/policy/PhoneWindowManager;->inkpalmSleepNow(J)V
    return-void
.end method
