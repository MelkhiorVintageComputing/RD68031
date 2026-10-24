| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- two user tasks sharing the FPU under a scheduler, their stacks
| faulting: what NetBSD does to libm, in miniature.
|
| Run by core_fpu_mmu_tb +timer, with RD68884 as the MC68881. Each task calls
| exp(), log() and fmod() the way NetBSD's libm does -- the arguments on the
| user stack, `fetoxd sp@(4),fp0`, the result through `fmoved fp0,sp@-` into
| D0/D1 -- and compares every result, bit for bit, with the reference the
| supervisor computed before starting them. The testbench's timer interrupts
| at level 5 at random intervals, so in the middle of FPU instructions as well
| as between them (format $9 frames as well as $0). Each tick write-protects
| or invalidates one of the two pages of the running task's stack, as a fork's
| copy-on-write would, and switches to the other task; each page fault that
| follows repairs the page, and every other one switches too, as a fault that
| sleeps would.
| The switch is NetBSD's cpu_switchto: FSAVE, FMOVEM out if the frame is not
| null; FMOVEM in if not null, FRESTORE -- so one task's busy frame is saved
| while the other's is restored, and each task's own exception frame ($0, $9
| or $B) is resumed by RTE on its own kernel stack.
|
| Task 0's stack makes its operand reads straddle the two pages, task 1's its
| result stores. After NTICKS ticks the supervisor checks that neither task
| found a wrong result and that both made progress.
|
| PS 256, TIA 12, TIB 12, short descriptors: logical $0100_bb00 is B[bb].
|   B[1]  the tasks' code           B[2]  operands and references (read)
|   B[3]  the tasks' counters       B[4], B[5]  task 0's stack
|   B[6], B[7]  task 1's stack

#include "mmu_common.inc"

        .equ    TCF,    0x8080CC00
        .equ    NTICKS, 400
        .equ    CURT,   0x8060          | the running task's control block
        .equ    TICKS,  0x8064
        .equ    NFLT,   0x8068          | page faults taken
        .equ    NBUSY,  0x8070          | busy frames saved
        .equ    NFS,    0x8074          | FSAVEs
        .equ    NIDLE,  0x8084          | idle frames
        .equ    CACRV,  0x808C          | the CACR to run with: the testbench's
        .equ    NNULL,  0x8088          | null frames
        .equ    NF9,    0x8090          | ticks that interrupted an instruction ($9)
        .equ    TCB0,   0x8A00          | +0 SSP, +4 the other's TCB,
        .equ    TCB1,   0x8C00          | +$10 FSAVE frame, +$D0 FP0-FP7, +$130 FPCR/FPSR/FPIAR
        .equ    KS0,    0xEC00          | the kernel stacks' tops
        .equ    KS1,    0xE800
        .equ    UCODE,  0x01000100
        .equ    UDATA,  0x01000200      | +0 x for exp, +8 x for log, +16 y and
        .equ    PDATA,  0xC200          | +24 x for fmod; +32, +40, +48 the results
        .equ    UCNT,   0x01000300      | task t at +$40*t: iterations, errors,
        .equ    PCNT,   0xC300          | the first wrong result (2 longs), FBccs wrong
        .equ    DESC4,  tfb + 4*4       | the stacks' descriptors, B[4]-B[7]

        .text
main:
        move.l  CACRV, %d0
        movec   %d0, %cacr
        clr.l   TICKS
        clr.l   NFLT
        clr.l   NBUSY
        clr.l   NFS
        clr.l   NIDLE
        clr.l   NNULL
        clr.l   NF9
        lea     PCNT, %a0
        moveq   #31, %d0
1:      clr.l   (%a0)+
        dbra    %d0, 1b

| The operands and the references, where the tasks read them.
        lea     PDATA, %a0
        move.l  XE, (%a0)
        move.l  XE+4, 4(%a0)
        move.l  XL, 8(%a0)
        move.l  XL+4, 12(%a0)
        move.l  XM, 16(%a0)
        move.l  XM+4, 20(%a0)
        move.l  DM, 24(%a0)
        move.l  DM+4, 28(%a0)
        fetox.d XE, %fp0
        fmove.d %fp0, 32(%a0)
        flogn.d XL, %fp0
        fmove.d %fp0, 40(%a0)
        fmove.d DM, %fp0
        fmod.d  XM, %fp0
        fmove.d %fp0, 48(%a0)
        frestore NULLW                  | the tasks start with a reset FPU

| The control blocks, and each task's kernel stack as if it had called swtch
| from a handler: the return to kexit, USP, D0-D7/A0-A6, a format $0 frame
| into its code in user mode.
        lea     TCB0, %a0
        lea     TCB1, %a1
        move.l  %a1, 4(%a0)
        move.l  %a0, 4(%a1)
        clr.l   0x10(%a0)               | null FPU frames
        clr.l   0x10(%a1)
        lea     KS0, %a2
        move.l  #UCNT, %d1
        move.l  #0x01000504, %d2        | task 0: its argument across B[4]/B[5]
        bsr     mkstack
        move.l  %a2, (%a0)
        lea     KS1, %a2
        move.l  #UCNT + 0x40, %d1
        move.l  #0x01000710, %d2        | task 1: its result's store across B[6]/B[7]
        bsr     mkstack
        move.l  %a2, (%a1)

        move.l  #timer, 0x74            | vector 29: the level 5 autovector
        WRRP    %crp, 0x7FFF0002, tfa
        WRREG32 %tc, TCF
        pflusha
        lea     hook_flt, %a0
        move.l  %a0, BERRH
        PHASE   1
        move.l  #TCB0, CURT
        move.l  TCB0, %sp
        rts                             | into task 0, through kexit

| A2 the stack's top, D1 the task's counters, D2 its USP; A2 the new SP.
mkstack:
        clr.w   -(%a2)                  | format $0, vector 0
        move.l  #UCODE, -(%a2)
        clr.w   -(%a2)                  | SR: user, IPL 0
        moveq   #14, %d0
1:      clr.l   -(%a2)                  | A6 ... D0
        dbra    %d0, 1b
        move.l  %d1, 13*4(%a2)          | A5: the counters
        move.l  #UDATA, 12*4(%a2)       | A4: the operands
        move.l  %d2, -(%a2)             | USP
        move.l  #kexit, -(%a2)
        rts

| ---------------------------------------------------------------------------
| The kernel. Both handlers save the task's registers on its kernel stack, and
| leave through kexit; swtch changes kernel stacks and FPU contexts.
| ---------------------------------------------------------------------------
timer:
        movem.l %d0-%d7/%a0-%a6, -(%sp)
        move.l  %usp, %a0
        move.l  %a0, -(%sp)
        cmp.b   #0x90, 64+6(%sp)        | the frame's format: $9, mid-instruction
        bne.s   1f
        addq.l  #1, NF9
1:      addq.l  #1, TICKS
        cmp.l   #NTICKS, TICKS
        bge     report
| Arm a fault on the running task's stack: tick mod 4 picks the lower or the
| upper page, write-protected or invalid.
        move.l  CURT, %a0
        lea     DESC4, %a1
        cmp.l   #TCB0, %a0
        beq.s   2f
        addq.l  #8, %a1                 | task 1: B[6], B[7]
2:      move.l  TICKS, %d0
        btst    #0, %d0
        beq.s   3f
        addq.l  #4, %a1                 | the upper page
3:      btst    #1, %d0
        bne.s   4f
        bset    #2, 3(%a1)              | WP
        bra.s   5f
4:      bclr    #0, 3(%a1)              | DT 1 -> 0: invalid
5:      pflusha
        jsr     swtch
        bra.s   kexit

hook_flt:
        ori.w   #0x0700, %sr
        movem.l %d0-%d7/%a0-%a6, -(%sp)
        move.l  %usp, %a0
        move.l  %a0, -(%sp)
        addq.l  #1, NFLT
        lea     DESC4, %a1              | every stack page valid and writable
        move.l  #0xC401, (%a1)+
        move.l  #0xC501, (%a1)+
        move.l  #0xC601, (%a1)+
        move.l  #0xC701, (%a1)+
        pflusha
        btst    #0, NFLT+3              | every other fault sleeps: a task
        bne.s   kexit                   | resuming onto an armed fault runs on
        jsr     swtch
kexit:
        move.l  (%sp)+, %a0
        move.l  %a0, %usp
        movem.l (%sp)+, %d0-%d7/%a0-%a6
        rte

swtch:
        move.l  CURT, %a0
        fsave   0x10(%a0)
        addq.l  #1, NFS
        move.l  0x10(%a0), %d0
        bne.s   1f
        addq.l  #1, NNULL
        bra.s   3f
1:      swap    %d0
        cmp.b   #0x18, %d0
        bne.s   2f
        addq.l  #1, NIDLE
        bra.s   4f
2:      addq.l  #1, NBUSY
4:      fmovem.x %fp0-%fp7, 0xD0(%a0)
        fmovem.l %fpcr/%fpsr/%fpiar, 0x130(%a0)
3:      move.l  %sp, (%a0)
        move.l  4(%a0), %a0
        move.l  %a0, CURT
        move.l  (%a0), %sp
        tst.l   0x10(%a0)
        beq.s   5f
        fmovem.l 0x130(%a0), %fpcr/%fpsr/%fpiar
        fmovem.x 0xD0(%a0), %fp0-%fp7
5:      frestore 0x10(%a0)
        rts

| The end, from the last tick: neither task found a wrong result, both went
| round their loop, the faults and the busy frames happened.
report:
        move.w  #0x2700, %sr
        move.l  #STACK, %sp
        PHASE   2
        WRREG32 %tc, 0
        pflusha
        lea     PCNT, %a0
        CHECK   4(%a0), 0               | task 0's wrong results
        CHECK   8(%a0), 0               | ... the first one
        CHECK   12(%a0), 0
        CHECK   0x44(%a0), 0            | task 1's
        CHECK   0x48(%a0), 0
        CHECK   0x4C(%a0), 0
        CHECK   0x10(%a0), 0            | task 0's FBccs answered wrongly
        CHECK   0x50(%a0), 0            | task 1's
        tst.l   (%a0)
        sne     %d3
        CHECK   %d3, 0xFF               | task 0 went round
        tst.l   0x40(%a0)
        sne     %d3
        CHECK   %d3, 0xFF               | task 1 went round
        tst.l   NFLT
        sne     %d3
        CHECK   %d3, 0xFF               | page faults happened
        FINISH

NULLW:  .long   0

        .balign 4
XE:     .long   0x40160A62, 0x23E18698
XL:     .long   0x400AA973, 0x96D0917D
XM:     .long   0x400D9999, 0x9999999A
DM:     .long   0x40C81CD6, 0xC8B43958

| ---------------------------------------------------------------------------
| The tasks' code, in user mode: A4 the operands, A5 the counters.
| ---------------------------------------------------------------------------
        .balign 256
ucode:
loop:   move.l  4(%a4), -(%sp)          | exp(x)
        move.l  (%a4), -(%sp)
        bsr.s   uexp
        addq.l  #8, %sp
        cmp.l   32(%a4), %d0
        bne.s   bad1
        cmp.l   36(%a4), %d1
        beq.s   1f
bad1:   bsr.s   bad
1:      move.l  12(%a4), -(%sp)         | log(x)
        move.l  8(%a4), -(%sp)
        bsr.s   ulog
        addq.l  #8, %sp
        cmp.l   40(%a4), %d0
        bne.s   bad2
        cmp.l   44(%a4), %d1
        beq.s   2f
bad2:   bsr.s   bad
2:      move.l  20(%a4), -(%sp)         | fmod(x, y): y, then x
        move.l  16(%a4), -(%sp)
        move.l  28(%a4), -(%sp)
        move.l  24(%a4), -(%sp)
        bsr.s   umod
        lea     16(%sp), %sp
        cmp.l   48(%a4), %d0
        bne.s   bad3
        cmp.l   52(%a4), %d1
        beq.s   3f
bad3:   bsr.s   bad
3:      addq.l  #1, (%a5)
        bra.s   loop

bad:    addq.l  #1, 4(%a5)
        tst.l   8(%a5)
        bne.s   1f
        tst.l   12(%a5)
        bne.s   1f
        move.l  %d0, 8(%a5)
        move.l  %d1, 12(%a5)
1:      rts

| libm's, as NetBSD/m68k builds them: the result in D0/D1 through the stack,
| and an FBcc on it, as libm's range checks have: issued while the FPU still
| computes, its answer must survive an FSAVE/FRESTORE taken in the meantime
| (RD68884 7ec30da: an FSAVE dropped it, and NetBSD's libm branched the wrong
| way). A branch not taken is counted at +16 of the task's counters.
uexp:   fetox.d 4(%sp), %fp0
        fbogt   1f                      | libm's range check: exp > 0, taken
        addq.l  #1, 16(%a5)
1:      fmove.d %fp0, -(%sp)
        move.l  (%sp)+, %d0
        move.l  (%sp)+, %d1
        rts
ulog:   flogn.d 4(%sp), %fp0
        fbogt   1f                      | log(3.33) > 0, taken
        addq.l  #1, 16(%a5)
1:      fmove.d %fp0, -(%sp)
        move.l  (%sp)+, %d0
        move.l  (%sp)+, %d1
        rts
umod:   fmove.d 4(%sp), %fp0
        fmod.d  12(%sp), %fp0
        fbogt   1f                      | the remainder > 0, taken
        addq.l  #1, 16(%a5)
1:      fmove.d %fp0, -(%sp)
        move.l  (%sp)+, %d0
        move.l  (%sp)+, %d1
        rts

| ---------------------------------------------------------------------------
| The tables.
| ---------------------------------------------------------------------------
        .section .tables, "aw"
tfa:    .fill   16, 4, 0
        .long   tfb + 2                 | A[16]
        .fill   15, 4, 0
        .org    0x100
tfb:    .long   0
        .long   ucode + 1               | B[1]: the tasks' code
        .long   0xC201                  | B[2]: operands, references
        .long   0xC301                  | B[3]: counters
        .long   0xC401, 0xC501          | B[4], B[5]: task 0's stack
        .long   0xC601, 0xC701          | B[6], B[7]: task 1's stack
        .fill   56, 4, 0
