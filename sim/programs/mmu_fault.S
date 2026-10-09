| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- the bus errors the MMU raises, and RTE's rerun of them.
|
| UM 8.1.2: "a bus error exception also occurs when the MMU detects that a
| successful address translation is not possible", and UM 9.5.2: the search
| that fails loads an ATC entry with B set, "and the MC68030 takes an exception
| on the retry of the cycle". The frame is the ordinary format $B one of
| doc/checkpoint.md's FAULTS table, the handler asks with PTEST (UM 9.10.3),
| repairs the tables, flushes the entry and returns; RTE reruns the access.
|
|   1    an invalid page descriptor
|   2    a write to a write-protected page, rerun with M set
|   3    a user write (MOVES) through a supervisor-only table descriptor
|   4    a limit violation at the root pointer, the limit raised by PMOVE
|   5    a bus error on a table search cycle
|   6    CAS on a write-protected page: its READ faults (UM 8.2.3)
|   7    a long word read across into an invalid page: the residual faults
|   8    a long word written across into a write-protected page
|   9    a prefetch into an invalid page that the program never uses: no fault
|   10   an instruction in an invalid page: the fault on its use
|   11   a write refused in its second page, with the data cache on: the
|        entry for the refused bytes is invalidated (UM 6.1.2)
|
| PS 256, TIA 12, TIB 12, short descriptors: logical $0100_bb00 is A[16],
| B[bb]. The supervisor's code, stack and results are TT0's.

#include "mmu_common.inc"

        .equ    PATC,   0xAB000000
        .equ    FIXV,   0x8060          | the descriptor a hook writes
        .equ    TCF,    0x8080CC00      | E, PS 8, TIA 12, TIB 12

| A hook: the registers it uses saved, A1 the fault address, D1 its function
| code, and the tables searched for it -- PTEST at level 7 with A2, MMUSR and
| A2 kept for the program to check (FMMUSR, FDA).
        .macro  HOOKIN
        movem.l %d0-%d1/%a1-%a2/%a5, -(%sp)
        move.l  20+16(%sp), %a1
        move.w  20+10(%sp), %d1
        and.w   #7, %d1
        ptestr  %d1, (%a1), #7, %a2
        bsr     keepmmu
        .endm

        .macro  HOOKOUT
        pflusha
        movem.l (%sp)+, %d0-%d1/%a1-%a2/%a5
        rte
        .endm

        .macro  SETHOOK h
        lea     \h, %a5
        move.l  %a5, BERRH
        .endm

        .macro  SSWLO               | FSSW's data half and DF, into D3
        move.l  FSSW, %d3
        and.l   #0x01FF, %d3
        .endm

        .text
main:
        WRRP    %crp, 0x7FFF0002, tfa
        WRREG32 %tc, TCF
        pflusha

| ---------------------------------------------------------------------------
| 1 -- an invalid page descriptor. SSW: DF, a read, a long word, supervisor
| data -- $0145 (doc/ssw.md). PTEST: I, two levels; A2 the descriptor.
| ---------------------------------------------------------------------------
        SETHOOK hook_fix
        move.l  #0x0000C300 + 1, FIXV
        PHASE   1
        move.l  0x01000308, %d3
        PHASE   2
        CHECK   %d3, PATC + 0xC308
        CHECK   NBERR, 1
        SSWLO
        CHECK   %d3, 0x0145
        CHECK   FADDR, 0x01000308
        CHECK   FFV, 0xB008
        CHECK   FMMUSR, 0x0402
        CHECK   FDA, tfb + 3*4

| ---------------------------------------------------------------------------
| 2 -- a write to a write-protected page: the search loads WP and no M, the
| retry faults (SSW $0105); the hook clears WP, and the rerun searches again
| and sets M.
| ---------------------------------------------------------------------------
        SETHOOK hook_wp
        PHASE   3
        move.l  #0x5A5A5A5A, 0x01000420
        PHASE   4
        CHECK   NBERR, 2
        SSWLO
        CHECK   %d3, 0x0105
        CHECK   FADDR, 0x01000420
        CHECK   FMMUSR, 0x0802
        CHECK   0x0000C420, 0x5A5A5A5A
        CHECK   tfb + 4*4, 0x0000C419    | U and M; WP cleared by the hook

| ---------------------------------------------------------------------------
| 3 -- a user data write (MOVES) through a long table descriptor with S set:
| UM 9.5.5.3, the search ends with B in the entry, and the retry faults. SSW
| $0101; PTEST for FC 1: S, two levels, no I.
| ---------------------------------------------------------------------------
        WRRP    %crp, 0x7FFF0003, tfl
        SETHOOK hook_s
        moveq   #FC_UD, %d0
        movec   %d0, %dfc
        move.l  #0x13572468, %d4
        lea     0x01000110, %a0
        PHASE   5
        moves.l %d4, (%a0)
        PHASE   6
        CHECK   NBERR, 3
        SSWLO
        CHECK   %d3, 0x0101
        CHECK   FMMUSR, 0x2002
        CHECK   0x0000C510, 0x13572468
        CHECK   tfl + 16*8, 0x7FFF000A   | S cleared, U set by the rerun
        WRRP    %crp, 0x7FFF0002, tfa

| ---------------------------------------------------------------------------
| 4 -- a limit violation at the root: A must be at most 15, and it is 16.
| PTEST: L, I, no table. The hook raises the limit (PMOVE CRP, which flushes).
| ---------------------------------------------------------------------------
        WRRP    %crp, 0x000F0002, tfa
        SETHOOK hook_lim
        PHASE   7
        move.l  0x01000610, %d3
        PHASE   8
        CHECK   NBERR, 4
        CHECK   %d3, PATC + 0xC610
        CHECK   FMMUSR, 0x4400

| ---------------------------------------------------------------------------
| 5 -- a bus error on a search cycle: A[17] points at a table in the region
| that answers BERR. UM 9.4: B is "set for an entry if a bus error ... is
| encountered during the table search"; PTEST: B, I, two tables, and A2 the
| last descriptor fetched whole -- A[17].
| ---------------------------------------------------------------------------
        SETHOOK hook_berr
        PHASE   9
        move.l  0x01100020, %d3
        PHASE   10
        CHECK   NBERR, 5
        CHECK   %d3, PATC + 0xC720
        CHECK   FMMUSR, 0x8402
        CHECK   FDA, tfa + 17*4

| ---------------------------------------------------------------------------
| 6 -- CAS on a write-protected page. UM 8.2.3: "the MMU of the MC68030 treats
| any bus cycle with RMC asserted as a write operation for protection
| checking", so the READ faults: SSW DF, RM, a read -- $01C5. RTE with DF set
| reruns the whole instruction, and the search it makes then sets M.
| ---------------------------------------------------------------------------
        SETHOOK hook_wp
        lea     0x01000700, %a0
        move.l  #PATC + 0xC700 + 0x100, %d1   | what is there
        move.l  #0x11223344, %d2
        PHASE   11
        cas.l   %d1, %d2, (%a0)
        seq     %d5
        PHASE   12
        CHECK   NBERR, 6
        SSWLO
        CHECK   %d3, 0x01C5
        CHECK   0x0000C800, 0x11223344
        and.l   #0xFF, %d5
        CHECK   %d5, 0xFF                | Z: it swapped
        CHECK   tfb + 7*4, 0x0000C819

| ---------------------------------------------------------------------------
| 7 -- a long word read across a page boundary into an invalid page. Its first
| word comes from B[8]'s page; the cycle into B[9] is the refused one, and the
| frame says so: +$10 the residual's address, SIZE a word, DF -- $0165. RTE
| reads the residual.
| ---------------------------------------------------------------------------
        SETHOOK hook_fix
        move.l  #0x0000CA00 + 1, FIXV
        PHASE   13
        move.l  0x010008FE, %d3
        PHASE   14
        CHECK   NBERR, 7
        CHECK   %d3, 0xC9FCAB00
        SSWLO
        CHECK   %d3, 0x0165
        CHECK   FADDR, 0x01000900

| ---------------------------------------------------------------------------
| 8 -- a long word written across into a write-protected page: one byte goes,
| the residual three are refused -- SIZE three bytes, a write: $0135 -- and
| RTE writes them once the hook has cleared WP.
| ---------------------------------------------------------------------------
        SETHOOK hook_wp
        PHASE   15
        move.l  #0xDEADBEEF, 0x01000AFF
        PHASE   16
        CHECK   NBERR, 8
        SSWLO
        CHECK   %d3, 0x0135
        CHECK   FADDR, 0x01000B00
        CHECK   0x0000CBFC, 0xAB00CBDE
        CHECK   0x0000CC00, 0xADBEEF00

| ---------------------------------------------------------------------------
| 9 -- a prefetch into an invalid page, never used. The routine's last word is
| an RTS at the end of its page; the pipe may well fetch on into the next,
| invalid, page, and that fault is the pipe's to take only "when it attempts
| to use the prefetched information" (UM 8.1.2) -- here, never.
| ---------------------------------------------------------------------------
        SETHOOK berr_none
        moveq   #0, %d6
        PHASE   17
        jsr     0x01000CFC
        nop
        PHASE   18
        CHECK   NBERR, 8
        CHECK   %d6, 7

| ---------------------------------------------------------------------------
| 10 -- an instruction in an invalid page. Two MOVEQs end page B[14]; the RTS
| that follows them is at the start of B[15], which is invalid until the hook
| maps it. The fault is the prefetch's, taken when the word is wanted: DF
| clear, a stage fault bit set (UM 8.2.1).
| ---------------------------------------------------------------------------
        SETHOOK hook_fetch
        move.l  #code3 + 1, FIXV
        moveq   #0, %d4
        moveq   #0, %d6
        PHASE   19
        jsr     0x01000EFC
        nop
        PHASE   20
        CHECK   NBERR, 9
        CHECK   %d6, 3
        CHECK   %d4, 4
        move.l  FSSW, %d3
        and.l   #0x0100, %d3
        CHECK   %d3, 0                   | no data fault
        move.l  FSSW, %d3
        and.l   #0xC000, %d3
        sne     %d3
        and.l   #0xFF, %d3
        CHECK   %d3, 0xFF                | a stage fault bit

| ---------------------------------------------------------------------------
| 11 -- the data cache and a refused write. UM 6.1.2: "if the MMU determines
| that the access is invalid, the write is aborted, the corresponding entry is
| invalidated, and a bus error exception is taken". Both long words the write
| touches are in the cache; it takes all four bytes as the write is taken, the
| first two reach memory, and the cycle into the write-protected page is
| refused. The hook abandons the rest (DF cleared, UM 8.2.2). Reading the long
| word back must give the new first half, from the cache, and memory's old
| second half: the second entry was invalidated, not left holding bytes that
| were never written.
| ---------------------------------------------------------------------------
        move.l  #0x2100, %d0             | WA, ED
        movec   %d0, %cacr
        move.l  0x010010FC, %d3          | both long words into the cache
        move.l  0x01001100, %d3
        SETHOOK hook_abandon
        PHASE   21
        move.l  #0xCAFEF00D, 0x010010FE
        PHASE   22
        move.l  0x010010FE, %d7
        moveq   #0, %d0
        movec   %d0, %cacr
        CHECK   %d7, 0xCAFEAB00          | not $CAFEF00D
        CHECK   NBERR, 10
        SSWLO
        CHECK   %d3, 0x0125
        CHECK   0x0000CDFC, 0xAB00CAFE   | the first half reached memory
        CHECK   0x0000CE00, PATC + 0xCE00   | the second did not
        move.l  #0x0100, %d0
        movec   %d0, %cacr

| ---------------------------------------------------------------------------
| 12 -- user mode, translated: the program fetched from a page through the
| tables in user program space (FC 2, which TT0 does not cover), and its data
| write through them in user data space, its stack there too. It returns by
| TRAP #0, whose hook comes back here.
| ---------------------------------------------------------------------------
        SETHOOK berr_none
        lea     user_back, %a5
        move.l  %a5, TRAPH
        lea     0x01001300, %a0          | B[19]: the user's data page
        lea     0x010013F0, %a5
        move.l  %a5, %usp
        PHASE   23
        clr.w   -(%sp)                   | format 0
        move.l  #0x01001200, -(%sp)      | B[18]: the user's code
        clr.w   -(%sp)                   | user mode
        rte
user_back:
        addq.l  #8, %sp                  | the TRAP's four-word frame
        PHASE   24
        lea     trap_rte, %a5
        move.l  %a5, TRAPH
        CHECK   NTRAP, 1
        CHECK   NBERR, 10
        CHECK   0x0000CF00, 0x55AA55AA
        CHECK   0x0000CFEC, 0x0100120C   | the user's JSR pushed its return
        CHECK   tfb + 18*4, code4 + 1 + 8   | U in the code page's descriptor
        CHECK   tfb + 19*4, 0x0000CF19   | U and M in the data page's

        WRREG32 %tc, 0
        FINISH

| ---------------------------------------------------------------------------
| The hooks.
| ---------------------------------------------------------------------------
keepmmu:
        lea     SCR, %a5
        pmove   %psr, (%a5)
        moveq   #0, %d0
        move.w  (%a5), %d0
        move.l  %d0, FMMUSR
        move.l  %a2, FDA
        rts

| The descriptor PTEST found, made what FIXV says.
hook_fix:
        HOOKIN
        move.l  FIXV, (%a2)
        HOOKOUT

| ... its WP bit cleared.
hook_wp:
        HOOKIN
        bclr    #2, 3(%a2)
        HOOKOUT

| ... the S bit cleared in the long table descriptor above it.
hook_s:
        HOOKIN
        bclr    #0, tfl + 16*8 + 2
        HOOKOUT

| ... the root pointer's limit raised.
hook_lim:
        HOOKIN
        WRRP    %crp, 0x7FFF0002, tfa
        HOOKOUT

| ... A[17] pointed at a table that is there.
hook_berr:
        HOOKIN
        move.l  #tfb2 + 2, tfa + 17*4
        HOOKOUT

| An instruction fault: the word that was wanted is stage C's, at the stage B
| address less two (UM 8.2) -- in program space.
hook_fetch:
        movem.l %d0-%d1/%a1-%a2/%a5, -(%sp)
        move.l  20+36(%sp), %a1
        subq.l  #2, %a1
        ptestr  #FC_SP, (%a1), #7, %a2
        bsr     keepmmu
        move.l  FIXV, (%a2)
        HOOKOUT

| The access abandoned: DF cleared, nothing repaired.
hook_abandon:
        bclr    #0, 10(%sp)
        rte

| ---------------------------------------------------------------------------
| Code that runs translated, each on a 256-byte page of its own.
| ---------------------------------------------------------------------------
        .balign 256
code1:  .fill   126, 2, 0x4E71           | NOPs up to offset 252
        moveq   #7, %d6                  | +$FC
        rts                              | +$FE: the last word of the page
        .balign 256
code2:  .fill   126, 2, 0x4E71
        moveq   #3, %d6                  | +$FC
        moveq   #4, %d4                  | +$FE
        .balign 256
code3:  rts                              | +$00 of the page the hook maps
        .balign 256
code4:  move.l  #0x55AA55AA, (%a0)       | the user program: +$00
        jsr     0x0100120E               | +$06: a call, so the stack is used
        trap    #0                       | +$0C
        rts                              | +$0E

| ---------------------------------------------------------------------------
| The tables.
| ---------------------------------------------------------------------------
        .section .tables, "aw"
tfa:    .fill   16, 4, 0
        .long   tfb + 2                  | A[16]
        .long   0x40000002               | A[17]: a table where BERR answers
        .fill   14, 4, 0
        .org    0x100
tfb:    .long   0, 0, 0
        .long   0                        | B[3]: invalid
        .long   0x0000C400 + 4 + 1       | B[4]: WP
        .long   0
        .long   0x0000C600 + 1           | B[6]
        .long   0x0000C800 + 4 + 1       | B[7]: WP
        .long   0x0000C900 + 1           | B[8]
        .long   0                        | B[9]: invalid
        .long   0x0000CB00 + 1           | B[10]
        .long   0x0000CC00 + 4 + 1       | B[11]: WP
        .long   code1 + 1                | B[12]: code
        .long   0                        | B[13]: invalid
        .long   code2 + 1                | B[14]: code
        .long   0                        | B[15]: invalid, until mapped
        .long   0x0000CD00 + 1           | B[16]
        .long   0x0000CE00 + 4 + 1       | B[17]: WP
        .long   code4 + 1                | B[18]: the user's code
        .long   0x0000CF00 + 1           | B[19]: the user's data and stack
        .fill   44, 4, 0
        .org    0x200
tfb2:   .long   0x0000C700 + 1           | B[0] of A[17], once repaired
        .fill   3, 4, 0
        .org    0x300
tfl:    .fill   32, 4, 0
        .long   0x7FFF0102, tflb         | A[16]: long, S, short below
        .org    0x400
tflb:   .long   0, 0x0000C500 + 1, 0, 0

        .section .pages, "aw"
        .set    pa, 0xC000
        .rept   1024
        .long   PATC + pa
        .set    pa, pa + 4
        .endr
