| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- the MMU cases the oracle comparison needs and the three
| self-checking MMU programs leave out (make cosim-mmu, make ap030).
|
| This program is compared, not self-checking: UAE030 and the core run it and
| tools/bus_diff.py holds them to the same registers at every instruction and
| the same physical data-access stream, table searches and U/M write-backs
| included. Its few CHECKs are things UM section 9 states outright. Each phase
| opens with a write of its number to MARK, which is also where make ap030
| cuts its pin streams.
|
|   1   operands across a page boundary with neither page in the ATC: which
|       page is searched first, and when (UM 9.2.1, 7.2.3)
|   2   TAS, CAS, CAS2 on pages not yet in the ATC, and on pages whose entry
|       has M clear: a read-modify-write and an ATC miss (UM 9.10.3 against
|       9.2.1 -- doc/mmu.md's first open question), a CAS across two pages
|   3   a user access through a long descriptor with S set: is U written at
|       the descriptor that makes the violation (UM 9.5.1.1 against 9-29)
|   4   PTEST across a bus error during the search: MMUSR B and N; PLOAD of
|       the same address, then PTEST level 0
|   5   PLOAD while TT1 matches the address: is the table searched
|   6   PFLUSH by function code and mask, with an address, through SFC, DFC
|       and Dn; PMOVE with and without FD: which entries survive
|   7   30 pages through the 22-entry ATC: replacement (UM 9.4)
|   8   a user program: its code, data and stack translated, a misaligned
|       long word written across into an invalid page and repaired, then
|       TRAP back to the supervisor
|   9   a write-protected page: the fault, the handler clearing WP and
|       flushing the entry, RTE's rerun with M set
|   10  TT1 with CI over the synchronous port, the caches on
|
| PS 256, TIA 12, TIB 12, short descriptors (TCF): logical $0100_bb00 is A[16]
| and B[bb]. The supervisor's code, stack and results are TT0's.

#include "mmu_common.inc"

        .equ    PATC,   0xAB000000
        .equ    TCF,    0x8080CC00      | E, PS 8, TIA 12, TIB 12
        .equ    LA,     0x01000000      | A[16]: tb1
        .equ    LU,     0x02000000      | A[32]: tbu, the user's
        .equ    LE,     0x03000000      | A[48]: a table at $4000_0000
        .equ    LT,     0x05000000      | A[80]: tb5, under TT1 in phase 5

| A bus error hook that abandons the access: DF cleared (UM 8.2.2).
        .text
main:
        WRRP    %crp, 0x7FFF0002, ta
        WRREG32 %tc, TCF
        pflusha

| ---------------------------------------------------------------------------
| 1 -- across a page boundary, both pages missing.
| ---------------------------------------------------------------------------
        PHASE   1
        move.l  LA+0x02FE, %d1           | B[2] and B[3]: 2 + 2 bytes
        move.l  LA+0x04FF, %d2           | B[4] and B[5]: 1 + 3
        move.w  LA+0x06FF, %d3           | B[6] and B[7]
        move.l  #0x11223344, LA+0x08FD  | B[8] and B[9]: 3 + 1, a write
        movem.l %d1-%d3, LA+0x0AF8       | B[10] and B[11]
        movem.l LA+0x0CF8, %d4-%d6       | B[12] and B[13], read back
        PHASE   2

| ---------------------------------------------------------------------------
| 2 -- read-modify-write cycles that miss in the ATC, or hit an entry with M
| clear. UM 8.2.3 and doc/mmu.md: an RMW cycle is a write for the MMU.
| ---------------------------------------------------------------------------
        pflusha
        PHASE   3
        tas     LA+0x1000                | B[16], nothing in the ATC
        tas     LA+0x1000                | the entry now has M
        move.l  LA+0x1100, %d0           | B[17] by a read: M clear
        tas     LA+0x1101                | ... then an RMW to it
        move.l  #0x00000000, %d0
        move.l  #0x55AA55AA, %d1
        lea     LA+0x1200, %a0           | B[18], missing
        move.l  (%a0), %d0               | ... after a read, M clear
        cas.l   %d0, %d1, (%a0)          | equal: written
        lea     LA+0x1300, %a1           | B[19], missing
        cas.l   %d0, %d1, (%a1)          | not equal (PATC...): no write
        lea     LA+0x1400, %a2           | B[20] and B[21], both missing
        lea     LA+0x1500, %a3
        move.l  (%a2), %d2
        move.l  (%a3), %d3
        cas2.l  %d2:%d3, %d4:%d5, (%a2):(%a3)
        lea     LA+0x16FF, %a4           | B[22] and B[23]: a word across
        move.w  (%a4), %d0
        move.w  #0x7777, %d1
        cas.w   %d0, %d1, (%a4)
        PHASE   4
        CHECK   LA+0x1200, 0x55AA55AA

| ---------------------------------------------------------------------------
| 3 -- a user data access through a long table descriptor with S set (UM
| 9.5.1.1, 9.5.5.3). The hook records the descriptors as the failed search
| left them (U at the S descriptor? at the page descriptor below it?), clears
| S, flushes and returns; RTE reruns the access. (The hook does not abandon
| the access by clearing DF: UAE030 restarts the instruction where the part
| continues it -- doc/oracles.md -- and would loop.)
| ---------------------------------------------------------------------------
        WRRP    %crp, 0x7FFF0003, tal
        pflusha
        lea     hook_s, %a5
        move.l  %a5, BERRH
        moveq   #FC_UD, %d0
        movec   %d0, %dfc
        movec   %d0, %sfc
        lea     LA+0x0100, %a0
        PHASE   5
        moves.l (%a0), %d6               | refused once: S, a user access
        PHASE   6
        move.l  SDESC, %d7               | U at the S descriptor, in the hook
        move.l  SDESC+4, %d5             | U at the page descriptor, in the hook
        move.l  SDESC+8, %d4             | PTEST for user data, in the hook
        ptestr  #FC_SD, (%a0), #7, %a1   | supervisor: fine
        bsr     mmusr
        move.l  LA+0x0100, %d2           | supervisor data: allowed
        WRRP    %crp, 0x7FFF0002, ta
        pflusha
        PHASE   7

| ---------------------------------------------------------------------------
| 4 -- a bus error during the search ($4000_0000 answers BERR): PTEST level 7
| says B, and N counts what? PLOAD loads a B entry; PTEST level 0 sees it.
| ---------------------------------------------------------------------------
        lea     LE+0x0100, %a0
        PHASE   8
        ptestr  #FC_SD, (%a0), #7, %a1
        bsr     mmusr
        move.l  %d3, %d4
        move.l  %a1, %d5
        ptestr  #FC_SD, (%a0), #0        | PTEST loaded nothing
        bsr     mmusr
        move.l  %d3, %d6
        ploadr  #FC_SD, (%a0)
        ptestr  #FC_SD, (%a0), #0        | B
        bsr     mmusr
        move.l  %d3, %d7
        PHASE   9
        CHECK   %d6, 0x0400

| ---------------------------------------------------------------------------
| 5 -- PLOAD while TT1 matches: UM 9.8 does not say TTx stop it.
| ---------------------------------------------------------------------------
        pflusha
        WRREG32 %tt1, 0x05008150         | $05xxxxxx, FC 5 only, R and W (RWM)
        lea     LT+0x0100, %a0
        PHASE   10
        ploadr  #FC_SD, (%a0)            | searched?
        ptestr  #FC_SD, (%a0), #0        | level 0: T
        bsr     mmusr
        move.l  %d3, %d4
        move.l  (%a0), %d5               | through TT1: logical = physical
        WRREG32 %tt1, 0
        move.l  (%a0), %d6               | through the ATC, if PLOAD loaded it
        PHASE   11

| ---------------------------------------------------------------------------
| 6 -- PFLUSH. Entries for user data and supervisor data at the same pages,
| loaded with PLOAD; each flush, then a read of each through MOVES (FC 1) or
| an ordinary read (FC 5): a table search means the entry was flushed.
| ---------------------------------------------------------------------------
        pflusha
        moveq   #FC_UD, %d0
        movec   %d0, %sfc
        lea     LA+0x3000, %a0           | B[$30]
        lea     LA+0x3100, %a1           | B[$31]
        ploadr  #FC_UD, (%a0)
        ploadr  #FC_UD, (%a1)
        ploadr  #FC_SD, (%a0)
        ploadr  #FC_SD, (%a1)
        PHASE   12
        pflush  #FC_UD, #7               | FC 1 only
        moves.l (%a0), %d0               | searched
        move.l  (%a0), %d0               | not
        PHASE   13
        pflush  #FC_SD, #7, (%a1)        | FC 5, B[$31] only
        move.l  (%a1), %d0               | searched
        moves.l (%a1), %d0               | not
        move.l  (%a0), %d0               | not
        PHASE   14
        pflush  #0, #0                   | mask 0: every function code
        moves.l (%a1), %d0               | searched
        move.l  (%a0), %d0               | searched
        PHASE   15
        moveq   #FC_SD, %d1
        pflush  %d1, #7                  | FC from D1
        move.l  (%a0), %d0               | searched
        moves.l (%a1), %d0               | not
        PHASE   16
        pflush  %sfc, #7, (%a1)          | FC from SFC (1)
        moves.l (%a1), %d0               | searched
        movec   %d1, %dfc
        pflush  %dfc, #7, (%a0)          | FC from DFC (5)
        move.l  (%a0), %d0               | searched
        PHASE   17
        lea     SCR, %a5
        move.l  #TCF, (%a5)
        pmovefd (%a5), %tc               | FD: the ATC is kept
        move.l  (%a0), %d0               | not
        pmove   (%a5), %tc               | flushed
        move.l  (%a0), %d0               | searched
        WRREG32 %tt1, 0                  | PMOVE TT1 flushes too
        move.l  (%a0), %d0               | searched
        lea     SCR, %a5
        move.l  #0, (%a5)
        pmovefd (%a5), %tt1              | ... not with FD
        move.l  (%a0), %d0               | not
        PHASE   18

| ---------------------------------------------------------------------------
| 7 -- 30 pages through 22 entries: B[$40]-B[$5D], then the last 8 again
| (most recently used), then the first 8 again.
| ---------------------------------------------------------------------------
        pflusha
        PHASE   19
        move.l  #LA+0x4000, %a0
        moveq   #29, %d1
1:      move.l  (%a0), %d0
        lea     0x100(%a0), %a0
        dbf     %d1, 1b
        PHASE   20
        move.l  #LA+0x5600, %a0
        moveq   #7, %d1
1:      move.l  (%a0), %d0
        lea     0x100(%a0), %a0
        dbf     %d1, 1b
        PHASE   21
        move.l  #LA+0x4000, %a0
        moveq   #7, %d1
1:      move.l  (%a0), %d0
        lea     0x100(%a0), %a0
        dbf     %d1, 1b
        PHASE   22

| ---------------------------------------------------------------------------
| 8 -- a user program at logical $0200_0000, its stack below $0200_0FF0, its data
| at $0200_0400; B[5] of its table is invalid until the hook maps it.
| ---------------------------------------------------------------------------
        pflusha
        lea     hook_map, %a5
        move.l  %a5, BERRH
        lea     trap_back, %a5
        move.l  %a5, TRAPH
        move.l  #LU+0x0FF0, %a0
        move.l  %a0, %usp
        move.l  %sp, SSAVE
        PHASE   23
        move.w  #0, -(%sp)               | format 0
        move.l  #LU, -(%sp)              | PC
        move.w  #0x0000, -(%sp)          | SR: user, no trace
        rte
user_back:
        move.l  SSAVE, %sp
        PHASE   24

| ---------------------------------------------------------------------------
| 9 -- a write to a write-protected page: the fault, WP cleared, PFLUSH with
| the address, RTE's rerun searches again and sets M.
| ---------------------------------------------------------------------------
        pflusha
        lea     hook_wp, %a5
        move.l  %a5, BERRH
        PHASE   25
        move.l  #0x0BADF00D, LA+0x6010   | B[$60]: WP
        move.b  #0x5A, LA+0x6020
        PHASE   26
        CHECK   tb1+0x60*4, 0x0000D019   | U, M; WP cleared by the hook

| ---------------------------------------------------------------------------
| 10 -- TT1 over the synchronous port with CI: CIOUT on its cycles, the data
| cache not filled from them; then without CI, with the caches on.
| ---------------------------------------------------------------------------
        WRREG32 %tt1, 0x30008543         | $30xxxxxx, CI, RWM, FC 4-7
        move.l  #0x30000100, %a0
        move.l  #0x31313131, (%a0)
        move.l  #0x1919, %d0             | clear both; EI, IBE, ED, DBE
        movec   %d0, %cacr
        PHASE   27
        move.l  (%a0), %d1
        move.l  (%a0), %d2
        move.l  #0x32323232, 4(%a0)
        WRREG32 %tt1, 0x30008143         | no CI
        move.l  0x10(%a0), %d3           | a burst, perhaps
        move.l  0x14(%a0), %d4
        PHASE   28
        moveq   #0, %d0
        movec   %d0, %cacr
        WRREG32 %tt1, 0
        WRREG32 %tc, 0
        FINISH

| ---------------------------------------------------------------------------
mmusr:  lea     SCR, %a5
        pmove   %psr, (%a5)
        moveq   #0, %d3
        move.w  (%a5), %d3
        rts

| Phase 3: record the two descriptors and PTEST's answer, clear S, flush.
hook_s:
        movem.l %d3/%a1/%a5, -(%sp)
        move.l  tal+16*8, SDESC
        move.l  tals+4, SDESC+4
        lea     LA+0x0100, %a1
        ptestr  #FC_UD, (%a1), #7, %a1
        bsr     mmusr
        move.l  %d3, SDESC+8
        bclr    #0, tal+16*8+2           | S is bit 8
        pflusha
        movem.l (%sp)+, %d3/%a1/%a5
        rte

| Map B[5] of the user's table and rerun.
hook_map:
        move.l  #0x0000D200 + 1, tbu+5*4
        pflusha
        rte

| Clear WP in B[$60] and flush that page.
hook_wp:
        move.l  %a0, -(%sp)
        bclr    #2, tb1+0x60*4+3
        move.l  4+16(%sp), %a0
        pflush  #FC_SD, #7, (%a0)
        move.l  (%sp)+, %a0
        rte

| TRAP #0 from the user program: back to the supervisor's main line.
trap_back:
        jmp     user_back

        .data
        .equ    SSAVE, 0x8090
        .equ    SDESC, 0x80A0

| ---------------------------------------------------------------------------
| The tables, from $9000. B[i] of tb1 maps to page $C000 + (i mod 24) * $100;
| B[$60] to $D000 with WP.
| ---------------------------------------------------------------------------
        .section .tables, "aw"
ta:     .fill   16, 4, 0
        .long   tb1 + 2                  | A[16]
        .fill   15, 4, 0
        .long   tbu + 2                  | A[32]: the user's
        .fill   15, 4, 0
        .long   0x40000002               | A[48]: a table in the bus-error window
        .fill   31, 4, 0
        .long   tb5 + 2                  | A[80]
        .org    0x200
tb1:    .set    i, 0
        .rept   0x60
        .long   0xC000 + (i % 24) * 0x100 + 1
        .set    i, i + 1
        .endr
        .long   0x0000D005               | B[$60]: WP
        .org    0x400
tbu:    .long   0x0000D801               | B[0]: the user's code
        .long   0, 0, 0
        .long   0x0000D901               | B[4]: data
        .long   0                        | B[5]: invalid until mapped
        .fill   9, 4, 0
        .long   0x0000DF01               | B[15]: the stack
        .org    0x480
tb5:    .long   0, 0x0000C501, 0, 0      | B[1]
        .org    0x500
tal:    .fill   32, 4, 0                 | long: A[16] at +$80
        .long   0x7FFF0102, tals         | S, U clear, to a short table
        .org    0x600
tals:   .long   0, 0x0000C601, 0, 0      | B[1], short, U clear

        .section .pages, "awx"
        .set    pa, 0xC000
        .rept   0x600
        .long   PATC + pa
        .set    pa, pa + 4
        .endr

| The user program, at physical $D800 and logical $0200_0000.
        .org    0x1800
user:   move.l  #0x2468ACE0, %d0
        move.l  %d0, -(%sp)                  | the stack, B[15]
        move.l  LU+0x0400, %d1               | data, B[4]
        move.l  %d0, LU+0x0404
        move.l  #0x10203040, LU+0x04FE       | across into B[5]: invalid
        move.l  LU+0x04FE, %d2
        move.l  (%sp)+, %d3
        trap    #0
        .org    0x1900
        .rept   64
        .long   0x55550000 + pa
        .set    pa, pa + 4
        .endr
