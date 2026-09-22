.class Lcom/android/server/power/InkpalmShowStandby;
.super Ljava/lang/Object;
.source "InkpalmShowStandby.java"

.implements Ljava/lang/Runnable;

.field private final mPms:Lcom/android/server/power/PowerManagerService;
.field private final mGen:I

.method constructor <init>(Lcom/android/server/power/PowerManagerService;I)V
    .registers 3
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/android/server/power/InkpalmShowStandby;->mPms:Lcom/android/server/power/PowerManagerService;
    iput p2, p0, Lcom/android/server/power/InkpalmShowStandby;->mGen:I
    return-void
.end method

.method public run()V
    .registers 3
    iget-object v0, p0, Lcom/android/server/power/InkpalmShowStandby;->mPms:Lcom/android/server/power/PowerManagerService;
    iget v1, p0, Lcom/android/server/power/InkpalmShowStandby;->mGen:I
    invoke-virtual {v0, v1}, Lcom/android/server/power/PowerManagerService;->inkpalmShowStandby(I)V
    return-void
.end method
