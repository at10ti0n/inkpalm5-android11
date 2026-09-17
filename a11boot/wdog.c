/* g11wdog -- init-independent boot watchdog for the Gate 11 FULL-BOOT GSI trial.
 * Static ARM binary started by init at `on fs`.  Every 5 s it reads the first 512 B of
 * p13 (offset 0, where init's `write` builtin puts markers) looking for the string the
 * rc writes on `sys.boot_completed=1`.  No property API, no libc-vs-init layout risk.
 *   found            -> log to /dev/kmsg, snapshot T911K, exit 0 (device stays up)
 *   t == T/2         -> interim snapshot T911H
 *   t >= T (no find) -> snapshot T911W, sync, reboot(RESTART2, "recovery")  -> TWRP+ADB
 * Nothing here writes a partition; the collector owns its own slots.            */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <linux/reboot.h>
#define P13 "/dev/block/mmcblk0p13"
#define DONE "-BOOTCOMPLETE-"
static int kfd=-1;
static void klog(const char*s){ if(kfd<0) kfd=open("/dev/kmsg",O_WRONLY|O_CLOEXEC); if(kfd>=0) write(kfd,s,strlen(s)); }
static void snap(const char*tag){ pid_t p=fork(); if(p==0){ char*av[]={"/collector",(char*)tag,0}; char*ev[]={0}; execve("/collector",av,ev); _exit(127);} if(p>0){int st; waitpid(p,&st,0);} }
static int done_marker(void){ char b[512]; int fd=open(P13,O_RDONLY|O_CLOEXEC); if(fd<0) return 0; ssize_t n=pread(fd,b,sizeof b,0); close(fd); if(n<=0) return 0; for(ssize_t i=0;i+14<=n;i++) if(memcmp(b+i,DONE,14)==0) return 1; return 0; }
int main(int argc,char**argv){
    int T=(argc>1)?atoi(argv[1]):1200; if(T<60) T=60; int half=T/2, t=0, halfdone=0; char m[96];
    snprintf(m,sizeof m,"g11wdog: armed, T=%d s, polling %s for %s\n",T,P13,DONE); klog(m);
    for(;;){ struct timespec ts={5,0}; nanosleep(&ts,0); t+=5;
        if(done_marker()){ snprintf(m,sizeof m,"g11wdog: BOOT COMPLETED marker seen at t=%d s -- standing down\n",t); klog(m); snap("T911K"); return 0; }
        if(!halfdone && t>=half){ halfdone=1; snprintf(m,sizeof m,"g11wdog: t=%d s, no completion yet -- interim snapshot\n",t); klog(m); snap("T911H"); }
        if(t>=T){ snprintf(m,sizeof m,"g11wdog: TIMEOUT at t=%d s -- final snapshot then reboot to recovery\n",t); klog(m); snap("T911W"); sync();
            syscall(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART2, "recovery"); return 1; }
    }
}
