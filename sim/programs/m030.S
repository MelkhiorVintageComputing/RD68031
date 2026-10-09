| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- the MC68030's instruction set where it is not the MC68020's.
|
| Assembled with -mcpu=68030, so the MMU instructions are the assembler's own
| encodings and not ones typed in here; CALLM and RTM, which the assembler
| refuses for this processor, are written as words.
|
|   CALLM, RTM          the MC68020's module calls. Not on the MC68030: an
|                       illegal instruction, vector 4 (UM 8.1.5), in either mode.
|   PMOVE, PFLUSH(A),   the MMU instructions, F-line with CpID 0. Privileged
|   PTEST, PLOAD        (UM 8.1.6): in user mode a privilege violation, vector
|                       8. In supervisor mode they run -- with translation
|                       disabled here, so they change nothing that matters; a
|                       command word the part does not define (a Dn operand,
|                       an MC68851 register, PTEST level 0 with an address
|                       register, PFLUSHA with an <ea>) is an F-line exception,
|                       vector 11 (UM 8.1.5). core_mmu_tb tests what they do.
|   CpID 0, not MMU     "unimplemented F-line" -- F-line in supervisor mode,
|                       privilege violation in user mode (UM 9.8, 8.1.5).
|   CpID 1              a coprocessor instruction, and never the MMU's: with
|                       nothing answering, an F-line exception in either mode
|                       (UM 10.5.2.8) -- not a privilege violation in user mode.
|   MOVEC CACR, CAAR    the MC68030's CACR layout, UM figure 6-14: only WA, DBE,
|                       FD, ED, IBE, FI and EI are kept, and CAAR keeps all 32
|                       bits (UM 6.3.2). A control register the MC68030 does
|                       not have is an illegal instruction (UM 8.1.5).
|
| One handler takes every exception. It logs the format and vector word, the
| status register and the program counter the frame holds, then steps the
| stacked program counter past the instruction by the length the program put in
| D7 and returns. The table at `expect` is what UM section 8 says each entry
| should be; sim/tb/core_m030_tb.sv compares the two, and the MOVEC results at
| RES, and runs the whole program over two different buses to the same end.
|
| Not built with crt0.S: this program owns its vector table and its modes.

        .equ    STACK,   0xF000         | the interrupt stack, growing down
        .equ    USTACK,  0xE000         | the user stack
        .equ    LOGP,    0x8000         | the log pointer
        .equ    LOG,     0x8010         | per exception: fmt/vector, SR, PC
        .equ    RES,     0x8800         | the MOVEC round trips
        .equ    SCRATCH, 0x9000         | an operand nothing should touch

        .section .vectors, "a"
        .long   STACK                   | 0: the initial interrupt stack pointer
        .long   _start                  | 1: the initial program counter
        .rept   254
        .long   any                     | 2-255: all logged the same way
        .endr
        | $400: where the testbench finds the expectations.
        .long   expect
        .long   (expect_end - expect) / 8
        .long   LOG
        .long   RES

        .text
        .globl  _start
_start:
        move.l  #STACK, %sp
        move.l  #LOG, LOGP
        move.l  #0x3111, %d0            | WA DBE ED IBE EI: run cached, like a real system
        movec   %d0, %cacr
        lea     SCRATCH, %a0
        lea     SCRATCH + 0x10, %a1

| ---------------------------------------------------------------------------
| Supervisor mode
| ---------------------------------------------------------------------------
        moveq   #8, %d7
s_callm:
        .short  0x06F9, 0x0004          | CALLM #4,($3000).L
        .long   0x00003000
        moveq   #2, %d7
s_rtm_a:
        .short  0x06CD                  | RTM A5
s_rtm_d:
        .short  0x06C0                  | RTM D0

        | Each runs: TC is zero after reset, so writing it back changes nothing,
        | and the searches find CRP's descriptor type zero -- invalid.
        moveq   #4, %d7
s_pmove_rd:
        pmove   %tc, (%a0)
s_pmove_wr:
        pmove   (%a0), %tc
s_pmove_crp:
        pmove   %crp, (%a0)
s_pmove_sr:
        pmove   %psr, (%a0)
s_pmove_tt:
        pmove   %tt0, (%a0)
s_pflusha:
        pflusha
s_pflush_fc:
        pflush  #1, #7
s_pflush_ea:
        pflush  #1, #7, (%a0)
s_ptest:
        ptestr  #1, (%a0), #7
s_ptestw:
        ptestw  #5, (%a0), #7, %a1
s_pload:
        ploadr  #1, (%a0)
        moveq   #6, %d7
s_pload_abs:
        ploadw  %sfc, (0x1234).w
        | ... and what the MC68030 does not define, F-line -- UM 8.1.5.
        moveq   #4, %d7
s_mmu_dn:
        .short  0xF000, 0x4200          | PMOVE TC,D0: no Dn operand (PRM 6)
s_mmu_drp:
        .short  0xF010, 0x4600          | PMOVE DRP,(A0): an MC68851 register
s_mmu_pt0a:
        .short  0xF010, 0x8110          | PTEST #0 with an address register
s_mmu_flea:
        .short  0xF010, 0x2400          | PFLUSHA (A0): no <ea> for PFLUSHA
s_mmu_srfd:
        .short  0xF010, 0x6100          | PMOVE (A0),MMUSR with FD set
        moveq   #2, %d7
s_cp0_t1:
        .short  0xF040                  | CpID 0, type 001: the MC68851's PScc
s_cp0_t7:
        .short  0xF1C0                  | CpID 0, type 111
s_cp0_ea:
        .short  0xF018                  | CpID 0, type 000, (A0)+: not an MMU mode
        moveq   #4, %d7
s_cp1:
        .short  0xF200, 0x6000          | CpID 1: FMOVE.L FP0,D0

        | CACR: everything set, then a mixture, then nothing.
        lea     RES, %a2
        moveq   #-1, %d0
        movec   %d0, %cacr
        movec   %cacr, %d1
        move.l  %d1, (%a2)+             | RES+$00: $00003313
        move.l  #0x00002A15, %d0        | WA CD FD IBE CEI EI
        movec   %d0, %cacr
        movec   %cacr, %d1
        move.l  %d1, (%a2)+             | RES+$04: $00002211
        moveq   #0, %d0
        movec   %d0, %cacr
        movec   %cacr, %d1
        move.l  %d1, (%a2)+             | RES+$08: 0
        | CAAR: every bit is implemented.
        moveq   #-1, %d0
        movec   %d0, %caar
        movec   %caar, %d1
        move.l  %d1, (%a2)+             | RES+$0C: $FFFFFFFF
        move.l  #0x12345678, %d0
        movec   %d0, %caar
        movec   %caar, %d1
        move.l  %d1, (%a2)+             | RES+$10: $12345678
        | The other six control registers read without an exception.
        movec   %sfc, %d1
        movec   %dfc, %d1
        movec   %usp, %d1
        movec   %vbr, %d1
        movec   %msp, %d1
        movec   %isp, %d1
        move.l  %d1, (%a2)+             | RES+$14: the ISP, which is A7 here
        move.l  #0x3111, %d0            | both caches on again
        movec   %d0, %cacr

        | Control registers the MC68030 does not have: illegal, UM 8.1.5.
        moveq   #4, %d7
s_movec_003:
        .short  0x4E7A, 0x1003          | MOVEC $003,D1 (the MC68040's TC)
s_movec_805:
        .short  0x4E7B, 0x1805          | MOVEC D1,$805 (the MC68040's MMUSR)
s_movec_004:
        .short  0x4E7A, 0x1004          | MOVEC $004,D1

| ---------------------------------------------------------------------------
| User mode
| ---------------------------------------------------------------------------
        lea     USTACK, %a3
        move.l  %a3, %usp
        move.w  #0x0000, %sr
        moveq   #4, %d7
u_pmove:
        pmove   %tc, (%a0)
u_pflusha:
        pflusha
u_ptest:
        ptestr  #1, (%a0), #7
        moveq   #2, %d7
u_cp0_t1:
        .short  0xF040
u_cp0_t7:
        .short  0xF1C0
        moveq   #4, %d7
u_movec:
        movec   %cacr, %d1
        moveq   #8, %d7
u_callm:
        .short  0x06F9, 0x0004
        .long   0x00003000
        moveq   #4, %d7
u_cp1:
        .short  0xF200, 0x6000
        moveq   #0x5A, %d6              | the program got to the end in user mode

        .globl  _done
_done:
        bra     _done

| ---------------------------------------------------------------------------
| The handler
| ---------------------------------------------------------------------------
any:
        move.l  %a0, -(%sp)
        move.l  LOGP, %a0
        move.w  4+6(%sp), (%a0)+        | the format and vector word
        move.w  4+0(%sp), (%a0)+        | the status register
        move.l  4+2(%sp), (%a0)+        | the program counter
        move.l  %a0, LOGP
        add.l   %d7, 4+2(%sp)           | past the instruction
        move.l  (%sp)+, %a0
        rte

| ---------------------------------------------------------------------------
| What UM section 8 says each exception is: the format and vector word, the S
| bit of the status register stacked (where the exception came from), and the
| instruction's own address, which is what a four-word frame carries for an
| illegal, an F-line and a privilege violation (UM table 8-6).
| ---------------------------------------------------------------------------
        .section .rodata
        .equ    ILLEGAL, 0x0010
        .equ    PRIV,    0x0020
        .equ    LINEF,   0x002C
        .equ    SUP,     0x2000
        .equ    USR,     0x0000
        .macro  exp vec, s, at
        .short  \vec, \s
        .long   \at
        .endm
        .balign 4
expect:
        exp     ILLEGAL, SUP, s_callm
        exp     ILLEGAL, SUP, s_rtm_a
        exp     ILLEGAL, SUP, s_rtm_d
        exp     LINEF,   SUP, s_mmu_dn
        exp     LINEF,   SUP, s_mmu_drp
        exp     LINEF,   SUP, s_mmu_pt0a
        exp     LINEF,   SUP, s_mmu_flea
        exp     LINEF,   SUP, s_mmu_srfd
        exp     LINEF,   SUP, s_cp0_t1
        exp     LINEF,   SUP, s_cp0_t7
        exp     LINEF,   SUP, s_cp0_ea
        exp     LINEF,   SUP, s_cp1
        exp     ILLEGAL, SUP, s_movec_003
        exp     ILLEGAL, SUP, s_movec_805
        exp     ILLEGAL, SUP, s_movec_004
        exp     PRIV,    USR, u_pmove
        exp     PRIV,    USR, u_pflusha
        exp     PRIV,    USR, u_ptest
        exp     PRIV,    USR, u_cp0_t1
        exp     PRIV,    USR, u_cp0_t7
        exp     PRIV,    USR, u_movec
        exp     ILLEGAL, USR, u_callm
        exp     LINEF,   USR, u_cp1
expect_end:
