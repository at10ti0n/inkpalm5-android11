/* threadregs <tid>: attach with ptrace, print the general registers, the VFP/NEON d0-d15 and
 * 256 bytes of stack above sp, then detach.  ARM32 only.  The thread is stopped for a few ms. */
#define _FILE_OFFSET_BITS 64
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/user.h>
#include <unistd.h>
#include <fcntl.h>
#ifndef PTRACE_GETVFPREGS
#define PTRACE_GETVFPREGS 27
#endif
struct vfp { uint64_t d[32]; uint32_t fpscr; };
int main(int argc,char**argv){
    if(argc<2){ fprintf(stderr,"usage: threadregs <tid>\n"); return 2; }
    pid_t tid=atoi(argv[1]);
    if(ptrace(PTRACE_ATTACH,tid,0,0)<0){ perror("attach"); return 1; }
    int st; if(waitpid(tid,&st,__WALL)<0){ perror("waitpid"); }
    struct user_regs r; struct vfp v; memset(&v,0,sizeof v);
    if(ptrace(PTRACE_GETREGS,tid,0,&r)<0) perror("getregs");
    if(ptrace(PTRACE_GETVFPREGS,tid,0,&v)<0) perror("getvfpregs");
    printf("tid=%d pc=%08lx lr=%08lx sp=%08lx r8=%08lx r9=%08lx\n",tid,r.uregs[15],r.uregs[14],r.uregs[13],r.uregs[8],r.uregs[9]);
    for(int i=0;i<16;i++) printf("d%-2d=%016llx%s",i,(unsigned long long)v.d[i],(i%4==3)?"\n":"  ");
    char path[64]; snprintf(path,sizeof path,"/proc/%d/mem",tid); int fd=open(path,O_RDONLY);
    if(fd>=0){
        uint32_t w[128];
        if(pread(fd,w,sizeof w,(off_t)(uint32_t)r.uregs[13])==(ssize_t)sizeof w){ printf("stack from sp (event optional lives at sp+0x60..0x8f in threadMain, flag byte at +0x88):\n"); for(int i=0;i<128;i++) printf("%s+%03x: %08x%s", i%4?"":"  ", i*4, w[i], i%4==3?"\n":"  "); } else perror("read stack");
        if(pread(fd,w,sizeof w,(off_t)(uint32_t)r.uregs[9])==(ssize_t)sizeof w){ printf("object at r9 (EventThread: +0x30 mutex +0x38/3c connections begin/end +0x54 deque start +0x58 deque size +0x68 vsync count +0x6c synthetic +0x70 engaged +0x78 state):\n"); for(int i=0;i<64;i++) printf("%s+%03x: %08x%s", i%4?"":"  ", i*4, w[i], i%4==3?"\n":"  "); } else perror("read object");
        close(fd); }
    ptrace(PTRACE_DETACH,tid,0,0);
    return 0;
}
