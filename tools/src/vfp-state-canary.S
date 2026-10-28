.syntax unified
.thumb
.fpu neon
.text
.align 2
.global vfp_raw_sleep
.type vfp_raw_sleep,%function
.thumb_func
// expected, before, after, timespec. No userspace calls while canary is loaded.
vfp_raw_sleep:
    push {r4,r5,r6,r7,r8,lr}
    vpush {d8-d15}
    mov r4,r1
    mov r5,r2
    mov r6,r3
    vmrs r8,fpscr
    vldmia r0!,{d0-d15}
    vldmia r0!,{d16-d31}
    mov.w r3,#0x03000000
    vmsr fpscr,r3
    vstmia r4!,{d0-d15}
    vstmia r4!,{d16-d31}
    vmrs r2,fpscr
    str r2,[r4]
    mov r0,r6
    movs r1,#0
    movs r7,#162
    svc #0
    vstmia r5!,{d0-d15}
    vstmia r5!,{d16-d31}
    vmrs r2,fpscr
    str r2,[r5]
    vmsr fpscr,r8
    vpop {d8-d15}
    pop {r4,r5,r6,r7,r8,pc}
.size vfp_raw_sleep,.-vfp_raw_sleep
.section .note.GNU-stack,"",%progbits
