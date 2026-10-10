| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- a bus probe, for make ap030: the same transfers on two processors
| with the same slave models, compared pin by pin (tools/bus_diff.py pins).
|
| The map is the core harness's (sim/tb/rd68031_core_harness.svh): 32-bit
| asynchronous at $0xxx_xxxx, 16-bit at $1xxx_xxxx, 8-bit at $2xxx_xxxx,
| 32-bit synchronous with burst at $3xxx_xxxx, BERR at $4xxx_xxxx. Each phase
| opens with a write of its number to MARK; the two benches change the slave
| models' knobs at some of them, identically (sim/tb/core_pins_tb.sv,
| sim/ap030/ap030_tb.sv):
|
|   1-4   every size at every alignment, read and write, on each port
|         (UM 7.2, tables 7-4 and 7-5)
|   5     MOVEM, MOVEP, and a long word across a port boundary
|   6     TAS, CAS, CAS2 on each port: RMC (UM 7.6)
|   7     the data cache and burst fills from the synchronous port: CBREQ,
|         CBACK (UM 7.3.7); a write-through write; a read that hits
|   8     ... with CIIN on every read of the synchronous port (knob)
|   9     ... with CIIN on the third beat of a burst only (knob)
|   10    wait states: 2 on the 32-bit port, 1 on the 16-bit port, 1 and 1 on
|         the synchronous port (knobs)
|   11    a bus error on an operand read and on a write, the access abandoned
|   12    TT1 with CI over the synchronous port: CIOUT, no CBREQ
|   13    the instruction cache filled by bursts from the synchronous port: code
|         copied there and run

#include "mmu_common.inc"

        .equ    P32,    0x0000E000
        .equ    P16,    0x1000E000
        .equ    P8,     0x2000E000
        .equ    PS,     0x3000E000

| One size at offsets 0-3 of a base: write a pattern, read it back.
        .macro  ALIGNS base
        move.l  #\base, %a0
        move.l  #0x11223344, %d0
        move.b  %d0, 0(%a0)
        move.b  %d0, 1(%a0)
        move.b  %d0, 2(%a0)
        move.b  %d0, 3(%a0)
        move.w  %d0, 4(%a0)
        move.w  %d0, 7(%a0)
        move.w  %d0, 10(%a0)
        move.w  %d0, 13(%a0)
        move.l  %d0, 16(%a0)
        move.l  %d0, 21(%a0)
        move.l  %d0, 26(%a0)
        move.l  %d0, 31(%a0)
        move.b  1(%a0), %d1
        move.b  3(%a0), %d1
        move.w  4(%a0), %d1
        move.w  7(%a0), %d1
        move.w  10(%a0), %d1
        move.w  13(%a0), %d1
        move.l  16(%a0), %d1
        move.l  21(%a0), %d1
        move.l  26(%a0), %d1
        move.l  31(%a0), %d1
        .endm

| The read-modify-write instructions on one base.
        .macro  RMWS base
        move.l  #\base, %a0
        move.l  #0x00000080, 0x40(%a0)
        tas     0x40(%a0)
        tas     0x43(%a0)
        move.l  0x40(%a0), %d0
        move.l  #0x12345678, %d1
        cas.l   %d0, %d1, 0x40(%a0)
        cas.l   %d0, %d1, 0x40(%a0)
        move.w  0x45(%a0), %d0
        cas.w   %d0, %d1, 0x45(%a0)
        lea     0x40(%a0), %a1
        lea     0x48(%a0), %a2
        move.l  (%a1), %d2
        move.l  (%a2), %d3
        cas2.l  %d2:%d3, %d0:%d1, (%a1):(%a2)
        .endm

        .text
main:
        PHASE   1
        ALIGNS  P32
        PHASE   2
        ALIGNS  P16
        PHASE   3
        ALIGNS  P8
        PHASE   4
        ALIGNS  PS

        PHASE   5
        move.l  #P32+0x100, %a0
        movem.l %d0-%d3, (%a0)
        movem.l (%a0), %d4-%d7
        move.l  #P16+0x101, %a0
        movem.w %d0-%d3, (%a0)
        movem.w (%a0), %d4-%d7
        move.l  #P8+0x100, %a0
        movep.l %d0, 0(%a0)
        movep.l 0(%a0), %d1
        move.l  #P16+0x100, %a0
        movep.w %d0, 1(%a0)
        movep.w 1(%a0), %d2
        move.l  #0x10203040, 0x0FFFFFFE  | across from the 32-bit port into the 16-bit
        move.l  0x0FFFFFFE, %d3

        PHASE   6
        RMWS    P32
        RMWS    P16
        RMWS    P8
        RMWS    PS

| The data cache, write allocate off, burst on.
        move.l  #PS+0x200, %a0
        moveq   #15, %d1
1:      move.l  %d1, (%a0)+
        dbf     %d1, 1b
        move.l  #0x00001900, %d0         | CD, DBE, ED
        movec   %d0, %cacr
        move.l  #PS+0x200, %a0
        PHASE   7
        move.l  (%a0), %d1               | a miss: a burst
        move.l  4(%a0), %d2              | hits
        move.l  12(%a0), %d3
        move.l  #0xAAAA5555, 8(%a0)      | written through
        move.l  8(%a0), %d4              | hit
        move.l  0x14(%a0), %d5           | another line
        move.b  0x23(%a0), %d6           | a byte miss
        movec   %d0, %cacr               | CD again: empty
        PHASE   8
        move.l  (%a0), %d1               | CIIN on every read: no fill
        move.l  4(%a0), %d2
        movec   %d0, %cacr
        PHASE   9
        move.l  (%a0), %d1               | CIIN on the third beat
        move.l  8(%a0), %d2
        move.l  12(%a0), %d3
        moveq   #0, %d0
        movec   %d0, %cacr

        PHASE   10
        ALIGNS  P32
        ALIGNS  P16
        move.l  #0x00001900, %d0
        movec   %d0, %cacr
        move.l  0x30(%a0), %d1           | a burst with waits
        moveq   #0, %d0
        movec   %d0, %cacr

        PHASE   11
        lea     hook_skip, %a5
        move.l  %a5, BERRH
        move.l  0x40000010, %d1
        move.l  #0x13579BDF, 0x40000020
        move.w  0x40000031, %d2
        PHASE   12
        WRREG32 %tt1, 0x30008543         | $30xxxxxx, CI, RWM, FC 4-7
        move.l  #0x00001900, %d0
        movec   %d0, %cacr
        move.l  #PS+0x300, %a0
        move.l  (%a0), %d1               | CIOUT: no burst, no fill
        move.l  (%a0), %d2
        move.l  #0x0F0F0F0F, 4(%a0)
        moveq   #0, %d0
        movec   %d0, %cacr
        WRREG32 %tt1, 0

| The instruction cache from the synchronous port: a short routine copied
| there and called with the instruction cache and its bursts on.
        PHASE   13
        lea     routine, %a0
        move.l  #PS+0x400, %a1
        moveq   #(routine_end - routine) / 2 - 1, %d1
1:      move.w  (%a0)+, (%a1)+
        dbf     %d1, 1b
        move.l  #0x00000019, %d0         | CI, IBE, EI
        movec   %d0, %cacr
        jsr     PS+0x400
        jsr     PS+0x400                 | hits
        moveq   #0, %d0
        movec   %d0, %cacr
        PHASE   14
        FINISH

hook_skip:
        bsr     clear_df
        rte

routine:
        moveq   #7, %d1
1:      add.l   %d1, %d2
        dbf     %d1, 1b
        nop
        nop
        nop
        nop
        rts
routine_end:
