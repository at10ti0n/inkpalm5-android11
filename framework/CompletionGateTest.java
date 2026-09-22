package com.android.server.power;

/** Tests the production gate, not a parallel reimplementation. No Android runtime needed. */
public final class CompletionGateTest {
    static void check(boolean condition, String text) {
        if (!condition) throw new AssertionError(text);
        System.out.println("PASS " + text);
    }
    static boolean observe(StandbyScreen.CompletionGate g, long present, long count,
                           long active, long change, long t) {
        return g.observe(present,10000000000L,9,count,active,change,t);
    }
    public static void main(String[] args) {
        StandbyScreen.CompletionGate g=new StandbyScreen.CompletionGate();
        check(!observe(g,-1,10,0,2000,0),"no frame does not complete");
        check(!observe(g,Long.MAX_VALUE,10,0,2000,1000),"unsignalled fence does not complete");
        check(!observe(g,1000000000L,9,0,2000,2000),"old panel cycle does not complete");
        check(!observe(g,1000000000L,10,1,2000,3000),"active panel does not complete");
        check(!observe(g,3000000000L,10,0,2000,4000),"power-down before presentation does not complete");
        check(!observe(g,1000000000L,10,0,2000,5000),"first matching observation starts quiet interval");
        check(!observe(g,1000000000L,10,0,2000,5149),"quiet interval must elapse");
        check(observe(g,1000000000L,10,0,2000,5150),"presented frame and completed quiet panel cycle accepted");
        check(!observe(g,1000000000L,11,0,2100,5200),"new panel cycle resets quiet interval");
        check(!observe(g,1500000000L,11,0,2100,5300),"new presentation resets quiet interval");
        check(!observe(g,-1,11,0,2100,5500),"new pending frame revokes readiness");
        check(!observe(g,1500000000L,11,0,2100,5700),"must observe quiet again after pending frame");
        check(!observe(g,11000000000L,11,0,12000,6000),"future timestamps rejected");
    }
}
