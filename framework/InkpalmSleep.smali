.class Lcom/android/server/policy/InkpalmSleep;
.super Ljava/lang/Object;
.source "InkpalmSleep.java"

# Runs ~800 ms after a short power press: by then the keyguard (the standby image) has been
# composited and the E Ink panel has refreshed, so the frame it holds through sleep is the
# lock screen, not the app that was open. See PhoneWindowManager.powerPress (patched).

.implements Ljava/lang/Runnable;

.field private final mPwm:Lcom/android/server/policy/PhoneWindowManager;

.method constructor <init>(Lcom/android/server/policy/PhoneWindowManager;)V
    .registers 2
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/policy/InkpalmSleep;->mPwm:Lcom/android/server/policy/PhoneWindowManager;
    return-void
.end method

.method public run()V
    .registers 4
    iget-object v0, p0, Lcom/android/server/policy/InkpalmSleep;->mPwm:Lcom/android/server/policy/PhoneWindowManager;
    invoke-static {}, Landroid/os/SystemClock;->uptimeMillis()J
    move-result-wide v1
    invoke-virtual {v0, v1, v2}, Lcom/android/server/policy/PhoneWindowManager;->inkpalmSleepNow(J)V
    return-void
.end method
