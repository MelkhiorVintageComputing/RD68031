| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- RTE's rerun of a faulted access that faults again.
|
| UM 8.2.3: "If a fault occurs when the RTE instruction attempts to rerun the
| bus cycle(s), the processor creates a new stack frame on the supervisor stack
| after deallocating the previous frame, and address error or bus error
| exception processing starts in the normal manner." UM 8.1.2 makes a double
| bus fault of a bus error during the exception processing for a bus error,
| address error or reset, or "while the processor is loading internal state
| information from the stack during the execution of an RTE instruction" --
| and the rerun is neither: the frame has been loaded.
|
| An operating system relies on it: SunOS 4.1.1 grows a user stack by letting
| the first fault on the page below it return with DF still set, and maps the
| page on the second (doc/bugs-found.md). Every test here is that: the hook
| returns from the first bus error without repairing anything, the rerun faults
| again, and the second bus error -- an ordinary one, vector 2 -- must carry
| the same fault, in a frame at the same place (the first one deallocated). The
| hook then repairs the tables, flushes the ATC and returns, and the access
| completes.
|
|   1   a supervisor data write to an invalid page
|   2   a supervisor data read from an invalid page: the data lands
|   3   an instruction in an invalid page: the prefetch's rerun (RB/RC)
|   4   user mode, as SunOS does it: LINK, then MOVEM.L D4-D7/A3-A5,(A7)
|       into the invalid page below the stack's
|   5   user mode: a data read from an invalid page
|   6   a data write that BERR refuses (a page mapped onto $4000_0000)
|   7   a data read that BERR refuses
|
| 6 and 7 come last because UAE030 cannot run them: it stacks the PHYSICAL
| address of a translated access that BERR ended as the fault address, reruns
| from it, and faults for ever (doc/m11-mismatches.md, b18). make cosim-mmu
| cuts its trace before them.
|
| A bus error during RTE's loading of the frame stays a double bus fault:
| core_fault_tb, "RTE load".
|
| PS 256, TIA 12, TIB 12, short descriptors: logical $0100_bb00 is A[16],
| B[bb]. The supervisor's code, stack and results are TT0's.

#include "mmu_common.inc"

        .equ    PATC,   0xAB000000
        .equ    TCF,    0x8080CC00      | E, PS 8, TIA 12, TIB 12
        .equ    FIXV,   0x8060          | the descriptor the second entry writes
        .equ    FIXA,   0x8064          | ... and where
        .equ    ENT,    0x8068          | hook entries, this test
        .equ    SP1,    0x806C          | the first entry: its frame's address
        .equ    SSW1,   0x8070          | ... SSW
        .equ    FA1,    0x8074          | ... fault address, +$10
        .equ    PC1,    0x8078          | ... stacked PC
        .equ    SB1,    0x807C          | ... stage B address, +$24
        .equ    SP2,    0x8080          | the second entry's
        .equ    SSW2,   0x8084
        .equ    FA2,    0x8088
        .equ    PC2,    0x808C
        .equ    SB2,    0x8090
        .equ    FV2,    0x8094          | ... and its format and vector

| A test begins: no entries yet, and what the second one repairs.
        .macro  ARM addr, val
        clr.l   ENT
        clr.l   SSW1
        clr.l   SSW2
        clr.l   FV2
        move.l  #\addr, FIXA
        move.l  #\val, FIXV
        .endm

| ... and ends: two entries, the same fault twice, the frames at one address.
        .macro  TWICE ssw, fa
        CHECK   ENT, 2
        CHECK   SSW1, \ssw
        CHECK   SSW2, \ssw
        CHECK   FA1, \fa
        CHECK   FA2, \fa
        CHECK   FV2, 0xB008
        move.l  SP2, %d3
        sub.l   SP1, %d3
        CHECK   %d3, 0                   | the first frame deallocated
        move.l  PC2, %d3
        sub.l   PC1, %d3
        CHECK   %d3, 0                   | the same instruction
        .endm

        .text
main:
        WRRP    %crp, 0x7FFF0002, tfa
        WRREG32 %tc, TCF
        pflusha
        lea     hook_twice, %a5
        move.l  %a5, BERRH

| ---------------------------------------------------------------------------
| 1 -- a write to an invalid page. SSW $0105: DF, a write, a long word,
| supervisor data.
| ---------------------------------------------------------------------------
        ARM     tfb + 3*4, 0x0000C300 + 1
        PHASE   1
        move.l  #0x13572468, 0x01000310
        PHASE   2
        TWICE   0x0105, 0x01000310
        CHECK   0x0000C310, 0x13572468
        CHECK   NBERR, 2
        move.l  SP1, %d3
        CHECK   %d3, STACK - 0x5C        | the long frame, on an empty stack

| ---------------------------------------------------------------------------
| 2 -- a read from an invalid page. SSW $0145. The data reaches D3.
| ---------------------------------------------------------------------------
        ARM     tfb + 4*4, 0x0000C400 + 1
        moveq   #0, %d3
        PHASE   3
        move.l  0x01000408, %d3
        PHASE   4
        move.l  %d3, %d7
        TWICE   0x0145, 0x01000408
        CHECK   %d7, PATC + 0xC408
        CHECK   NBERR, 4

| ---------------------------------------------------------------------------
| 3 -- an instruction in an invalid page. Two MOVEQs end page B[14]; the RTS
| after them is the first word of B[15], invalid until the second entry maps
| it. The fault is the prefetch's, DF clear and a stage fault bit set; RTE's
| rerun of the fetch (UM 8.2.1) faults again.
| ---------------------------------------------------------------------------
        ARM     tfb + 15*4, code3 + 1
        moveq   #0, %d4
        moveq   #0, %d6
        PHASE   5
        jsr     0x01000EFC
        nop
        PHASE   6
        CHECK   ENT, 2
        CHECK   %d6, 3
        CHECK   %d4, 4
        move.l  SSW1, %d3
        and.l   #0xC000, %d3
        sne     %d3
        and.l   #0xFF, %d3
        CHECK   %d3, 0xFF                | a stage fault bit
        move.l  SSW1, %d3
        and.l   #0x0100, %d3
        CHECK   %d3, 0
        move.l  SSW2, %d3
        sub.l   SSW1, %d3
        CHECK   %d3, 0
        move.l  SB2, %d3
        sub.l   SB1, %d3
        CHECK   %d3, 0
        CHECK   FV2, 0xB008
        move.l  SP2, %d3
        sub.l   SP1, %d3
        CHECK   %d3, 0
        move.l  PC2, %d3
        sub.l   PC1, %d3
        CHECK   %d3, 0
        CHECK   NBERR, 6

| ---------------------------------------------------------------------------
| 4 -- user mode, as SunOS grows its stack. The user's stack is page B[20],
| A7 near its bottom; LINK A6,#-$100 pushes A6 there and moves A7 into B[19],
| which is invalid, and MOVEM.L D4-D7/A3-A5,(A7) writes there. SSW $0101: DF,
| a write, a long word, user data. TRAP #0 comes back.
| ---------------------------------------------------------------------------
        ARM     tfb + 19*4, 0x0000C900 + 1
        lea     user_back6, %a5
        move.l  %a5, TRAPH
        move.l  #0x44444444, %d4
        move.l  #0x55555555, %d5
        move.l  #0x66666666, %d6
        move.l  #0x77777777, %d7
        move.l  #0xA3A3A3A3, %a3
        move.l  #0xA4A4A4A4, %a4
        move.l  #0xA5A5A5A5, %a5
        move.l  #0xA6A6A6A6, %a6
        lea     0x01001410, %a0
        move.l  %a0, %usp
        PHASE   7
        clr.w   -(%sp)                   | format 0
        move.l  #0x01001200, -(%sp)      | B[18]: the user's code, +$00
        clr.w   -(%sp)                   | user mode
        rte
user_back6:
        addq.l  #8, %sp                  | the TRAP's four-word frame
        PHASE   8
        TWICE   0x0101, 0x0100130C
        CHECK   0x0000CA0C, 0xA6A6A6A6   | LINK's push, in B[20]
        CHECK   0x0000C90C, 0x44444444
        CHECK   0x0000C910, 0x55555555
        CHECK   0x0000C914, 0x66666666
        CHECK   0x0000C918, 0x77777777
        CHECK   0x0000C91C, 0xA3A3A3A3
        CHECK   0x0000C920, 0xA4A4A4A4
        CHECK   0x0000C924, 0xA5A5A5A5
        CHECK   NTRAP, 1
        CHECK   NBERR, 8

| ---------------------------------------------------------------------------
| 5 -- user mode, a read from an invalid page, B[22]. SSW $0141. The user
| program puts what it read into D5 and returns by TRAP #0.
| ---------------------------------------------------------------------------
        ARM     tfb + 22*4, 0x0000CB00 + 1
        lea     user_back7, %a5
        move.l  %a5, TRAPH
        moveq   #0, %d5
        lea     0x01001410, %a0
        move.l  %a0, %usp
        PHASE   9
        clr.w   -(%sp)
        move.l  #0x01001240, -(%sp)      | B[18], +$40
        clr.w   -(%sp)
        rte
user_back7:
        addq.l  #8, %sp
        PHASE   10
        lea     trap_rte, %a5
        move.l  %a5, TRAPH
        TWICE   0x0141, 0x01001604
        CHECK   %d5, PATC + 0xCB04
        CHECK   NTRAP, 2
        CHECK   NBERR, 10

| ---------------------------------------------------------------------------
| 6 -- a write that the bus refuses: B[5] maps onto $4000_0500, where every
| cycle ends in BERR. The second entry maps it onto $C500.
| ---------------------------------------------------------------------------
        ARM     tfb + 5*4, 0x0000C500 + 1
        PHASE   11
        move.l  #0x2468ACE0, 0x01000520
        PHASE   12
        TWICE   0x0105, 0x01000520
        CHECK   0x0000C520, 0x2468ACE0
        CHECK   NBERR, 12

| ---------------------------------------------------------------------------
| 7 -- a read that the bus refuses: B[6] onto $4000_0600, then $C600.
| ---------------------------------------------------------------------------
        ARM     tfb + 6*4, 0x0000C600 + 1
        moveq   #0, %d3
        PHASE   13
        move.l  0x01000630, %d3
        PHASE   14
        move.l  %d3, %d7
        TWICE   0x0145, 0x01000630
        CHECK   %d7, PATC + 0xC630
        CHECK   NBERR, 14


        WRREG32 %tc, 0
        FINISH

| ---------------------------------------------------------------------------
| The hook. The first entry records its frame and returns with DF and the
| rerun bits as they are, nothing repaired, so RTE reruns the access and it
| faults again; the second records that frame, writes FIXV at FIXA, flushes
| the ATC and returns.
| ---------------------------------------------------------------------------
hook_twice:
        move.l  %a0, -(%sp)
        lea     4(%sp), %a0              | the frame
        addq.l  #1, ENT
        cmp.l   #1, ENT
        bne.s   2f
        move.l  %a0, SP1
        move.w  10(%a0), SSW1+2
        move.l  16(%a0), FA1
        move.l  2(%a0), PC1
        move.l  36(%a0), SB1
        move.l  (%sp)+, %a0
        rte
2:      move.l  %a0, SP2
        move.w  10(%a0), SSW2+2
        move.l  16(%a0), FA2
        move.l  2(%a0), PC2
        move.l  36(%a0), SB2
        move.w  6(%a0), FV2+2
        move.l  FIXA, %a0
        move.l  FIXV, (%a0)
        pflusha
        move.l  (%sp)+, %a0
        rte

| ---------------------------------------------------------------------------
| Code that runs translated, each on a 256-byte page of its own.
| ---------------------------------------------------------------------------
        .balign 256
code2:  .fill   126, 2, 0x4E71
        moveq   #3, %d6                  | +$FC
        moveq   #4, %d4                  | +$FE
        .balign 256
code3:  rts                              | +$00 of the page the hook maps
        .balign 256
code4:  link    %a6, #-0x100             | the user program: +$00
        movem.l %d4-%d7/%a3-%a5, (%sp)   | +$04: into the invalid page
        trap    #0                       | +$08
        .fill   27, 2, 0x4E71            | to +$40
        move.l  0x01001604, %d5          | +$40
        trap    #0                       | +$46

| ---------------------------------------------------------------------------
| The tables.
| ---------------------------------------------------------------------------
        .section .tables, "aw"
tfa:    .fill   16, 4, 0
        .long   tfb + 2                  | A[16]
        .fill   15, 4, 0
        .org    0x100
tfb:    .long   0, 0, 0
        .long   0                        | B[3]: invalid
        .long   0                        | B[4]: invalid
        .long   0x40000500 + 1           | B[5]: where BERR answers
        .long   0x40000600 + 1           | B[6]: likewise
        .fill   7, 4, 0                  | B[7]-B[13]
        .long   code2 + 1                | B[14]: code
        .long   0                        | B[15]: invalid, until mapped
        .long   0, 0                     | B[16], B[17]
        .long   code4 + 1                | B[18]: the user's code
        .long   0                        | B[19]: invalid, below the stack
        .long   0x0000CA00 + 1           | B[20]: the user's stack
        .long   0                        | B[21]
        .long   0                        | B[22]: invalid
        .fill   41, 4, 0

        .section .pages, "aw"
        .set    pa, 0xC000
        .rept   1024
        .long   PATC + pa
        .set    pa, pa + 4
        .endr
