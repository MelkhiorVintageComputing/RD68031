#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

"""Instruction clock counts against UM section 11.

    python3 tools/cycles.py gen   > build/cycles.vec
    python3 tools/cycles.py check build/cycles.out build/cycles_sync.out \
                                  [--doc doc/timing-divergences.md]

`gen` writes one row per instruction for sim/tb/core_cycles_tb.sv. The testbench
runs each row's program -- a fixed prologue, the row's setup, the instruction,
a landing pad of NOPs -- twice round a loop with the instruction cache on, and
reports the clocks from the instruction boundary before the instruction to the
one after it, on both passes. The first pass is COLD (the cache is empty, so
it is near the manual's no-cache case); the second is WARM (every word is in
the cache, which is the manual's instruction-cache case: in the cache, no
overlap). The data cache is off unless a row's setup turns it on (UM 11.6:
"the data cache is not enabled").

`make cycles` runs the bench twice: once with the 32-bit port ending its
cycles with DSACK, three clocks, and once with STERM, two -- the bus every
figure of UM section 11 assumes ("all memory accesses occur with two-clock bus
cycles and no wait states"). The SYNC column is the one to hold against the
manual; the ASYNC one is the regression record carried from RD68021.

`check` compares both warm counts with OURS and OURS_SYNC below and fails if
any row moved. Every row is a regression check, not a report: the number this
design takes is written down, and a change to it -- faster or slower -- is a
change someone has to look at and then write down. It also regenerates the
table in doc/timing-divergences.md between its markers when --doc is given.

UM is the arbiter for the manual's numbers. Each row's CC is the
instruction-cache-case total of UM 11.6: the instruction's own entry plus,
where its table's footnote says so, the fetch-effective-address (11.6.1),
fetch-immediate (11.6.2), calculate (11.6.3), calculate-immediate (11.6.4) or
jump (11.6.5) entry for its mode; NCC is the average no-cache case, summed the
same way. The sum is written out in the row so it can be checked against the
manual by eye. A row with no figure in the manual has None for both.

The prologue, every pass:

    D0=$11 D1=2 D2=$1F D3=5 D4=0 D5=0  A0=$2000 A1=$2100 A2=$2200 A3=$3000
    A5=X+2 (the word after a one-word instruction)  SP=$1000  D6=1 (so Z is clear)

$3000 holds an RTS. Vector 32 (TRAP #0) points at an RTE; vectors 4 and 10
(illegal, line A) at a handler that steps the stacked PC past the instruction
and returns.
"""

import re
import sys

# (name, setup words, instruction words, UM 11 cache case, how it adds up,
#  UM 11 average no-cache case, ours (asynchronous bus), ours (synchronous bus))
#
# `ours` is None for a row whose count has not been frozen yet; `check` prints
# it and fails, so a new row cannot slip in unexamined.
ROWS = [
    # --- 11.6.8 / 11.6.9: arithmetic, with the fetch-EA time for the source mode
    ('NOP', [], [0x4E71],
     2, '2', 2, 1, 1),
    ('MOVEQ #1,D4', [], [0x7801],
     2, '2', 2, 1, 1),
    ('ADD.L D0,D4', [], [0xD880],
     2, '2', 2, 2, 2),
    ('ADD.L (A0),D4', [], [0xD890],
     5, '2 + fea (An) 3', 5, 6, 5),
    ('ADD.L (A0)+,D4', [], [0xD898],
     5, '2 + fea (An)+ 3', 5, 6, 5),
    ('ADD.L -(A1),D4', [], [0xD8A1],
     6, '2 + fea -(An) 4', 6, 6, 5),
    ('ADD.L (8,A0),D4', [], [0xD8A8, 0x0008],
     6, '2 + fea (d16,An) 4', 6, 7, 6),
    ('ADD.L ($2000).W,D4', [], [0xD8B8, 0x2000],
     6, '2 + fea (xxx).W 4', 6, 8, 7),
    ('ADD.L ($2000).L,D4', [], [0xD8B9, 0x0000, 0x2000],
     6, '2 + fea (xxx).L 4', 7, 9, 8),
    ('ADD.L #imm,D4', [], [0xD8BC, 0x1234, 0x5678],
     6, '2 + fea #.L 4', 6, 4, 4),
    # A0 + D3 + 4 is $2009: this operand is MISALIGNED, three bytes and one,
    # two cycles where UM 11.6 assumes one ("all operands in memory ... are
    # long-word aligned"). Kept, as it was frozen; the row after it is the
    # same mode on an aligned operand, the one to hold against the manual.
    ('ADD.L (4,A0,D3.L),D4', [], [0xD8B0, 0x3804],
     8, '2 + fea (d8,An,Xn) 6, misaligned', 8, 13, 11),
    ('ADD.L (3,A0,D3.L),D4', [], [0xD8B0, 0x3803],
     8, '2 + fea (d8,An,Xn) 6', 8, 10, 9),
    ('ADD.L ([A0]),D4', [], [0xD8B0, 0x0151],
     12, '2 + fea ([B]) 10', 12, 20, 18),
    ('ADD.L D4,(A0)', [], [0xD990],
     6, '3 + fea (An) 3', 7, 9, 8),
    ('CMP.L D0,D4', [], [0xB880],
     2, '2', 2, 2, 2),
    ('CMPA.L A0,A2', [], [0xB5C8],
     4, '4', 4, 3, 3),
    ('MULU.W D1,D4', [], [0xC8C1],
     28, '28 + fea Dn 0', 28, 4, 4),
    ('MULU.L D1,D4', [], [0x4C01, 0x4004],
     46, '44 + fiea #.W,Dn 2', 46, 6, 6),
    ('DIVU.W D1,D4', [], [0x88C1],
     44, '44', 44, 44, 44),
    ('DIVS.W D1,D4', [], [0x89C1],
     56, '56', 56, 44, 44),
    ('DIVU.L D1,D4', [], [0x4C41, 0x4004],
     80, '78 + fiea #.W,Dn 2', 80, 44, 44),
    ('DIVS.L D1,D4', [], [0x4C41, 0x4804],
     92, '90 + fiea #.W,Dn 2', 92, 44, 44),
    ('ADDQ.L #1,D4', [], [0x5284],
     2, '2', 2, 1, 1),
    ('ADDQ.L #1,(A0)', [], [0x5290],
     6, '3 + fea (An) 3', 7, 7, 6),
    ('ADDI.L #imm,D4', [], [0x0684, 0x1234, 0x5678],
     6, '2 + fiea #.L,Dn 4', 6, 4, 4),
    ('ADDI.W #1,(A0)', [], [0x0650, 0x0001],
     6, '3 + fiea #.W,(An) 3', 8, 10, 9),
    # --- 11.6.10
    ('ABCD D0,D4', [], [0xC900],
     4, '4', 4, 1, 1),
    ('ABCD -(A1),-(A2)', [], [0xC509],
     13, '13', 14, 16, 14),
    ('ADDX.L D0,D4', [], [0xD980],
     2, '2', 2, 1, 1),
    ('CMPM.L (A0)+,(A1)+', [], [0xB388],
     8, '8', 8, 15, 13),
    ('PACK D0,D4,#0', [], [0x8940, 0x0000],
     6, '6', 6, 3, 3),
    ('UNPK D0,D4,#0', [], [0x8980, 0x0000],
     8, '8', 8, 3, 3),
    # --- 11.6.11
    ('CLR.L D4', [], [0x4284],
     2, '2', 2, 2, 2),
    ('CLR.L (A0)', [], [0x4290],
     5, '3 + cea (An) 2', 6, 2, 2),
    ('NEG.L D4', [], [0x4484],
     2, '2', 2, 2, 2),
    ('EXT.L D4', [], [0x48C4],
     4, '4', 4, 1, 1),
    ('NBCD D4', [], [0x4804],
     6, '6', 6, 2, 2),
    ('ST D4', [], [0x50C4],
     4, '4', 4, 2, 2),
    ('TAS D4', [], [0x4AC4],
     4, '4', 4, 2, 2),
    ('TAS (A0)', [], [0x4AD0],
     14, '12 + cea (An) 2', 14, 13, 11),
    ('TST.L D4', [], [0x4A84],
     2, '2', 2, 2, 2),
    ('TST.L (A0)', [], [0x4A90],
     5, '2 + fea (An) 3', 5, 6, 5),
    # --- 11.6.12
    ('LSL.L #1,D4', [], [0xE38C],
     4, '4', 4, 1, 1),
    ('LSL.L D1,D4', [], [0xE3AC],
     6, '6 (count <= size)', 6, 1, 1),
    ('ASL.L #1,D4', [], [0xE384],
     6, '6', 6, 1, 1),
    ('ASR.L #1,D4', [], [0xE284],
     4, '4', 4, 1, 1),
    ('ROL.L #1,D4', [], [0xE39C],
     6, '6', 6, 1, 1),
    ('ROXL.L #1,D4', [], [0xE394],
     12, '12', 12, 1, 1),
    ('LSL.W (A0)', [], [0xE3D0],
     7, '4 + fea (An) 3', 7, 9, 8),
    # --- 11.6.13
    ('BTST #3,D4', [], [0x0804, 0x0003],
     4, '4', 4, 3, 3),
    ('BTST D1,D4', [], [0x0304],
     4, '4', 4, 2, 2),
    ('BSET D1,D4', [], [0x03C4],
     6, '6', 6, 2, 2),
    ('BTST D1,(A0)', [], [0x0310],
     7, '4 + fea (An) 3', 7, 9, 8),
    ('BSET D1,(A0)', [], [0x03D0],
     9, '6 + fea (An) 3', 9, 11, 10),
    # 13, was 12: the bit number is kept in T0 across the effective address
    # and put back, since an indexed address decodes its own extension word in
    # XW where the number was -- doc/bugs-found.md, M12.
    ('BTST #3,(A0)', [], [0x0810, 0x0003],
     7, '4 + fiea #.W,(An) 3', 8, 11, 10),
    # --- 11.6.14, with the calculate-immediate time for the mode
    ('BFTST D4{0:8}', [], [0xE8C4, 0x0008],
     8, '8', 8, 2, 2),
    ('BFEXTU D4{0:8},D5', [], [0xE9C4, 0x5008],
     10, '10', 10, 3, 3),
    ('BFINS D5,D4{0:8}', [], [0xEFC4, 0x5008],
     12, '12', 12, 4, 4),
    ('BFFFO D4{0:8},D5', [], [0xEDC4, 0x5008],
     20, '20', 20, 3, 3),
    ('BFCHG D4{0:8}', [], [0xEAC4, 0x0008],
     14, '14', 14, 4, 4),
    ('BFEXTU (A0){0:8},D5', [], [0xE9D0, 0x5008],
     14, '12 + ciea #.W,(An) 2', 14, 12, 11),
    ('BFINS D5,(A0){0:8}', [], [0xEFD0, 0x5008],
     14, '12 + ciea #.W,(An) 2', 14, 14, 13),
    ('BFTST (A0){4:32}', [], [0xE8D0, 0x0100],
     16, '14 (5 bytes) + ciea #.W,(An) 2', 16, 14, 12),
    # --- 11.6.15
    ('BRA.S (taken)', [], [0x6002],
     6, 'Bcc taken 6', 8, 6, 6),
    ('BRA.W (taken)', [], [0x6000, 0x0004],
     6, 'Bcc taken 6', 8, 6, 6),
    ('BRA.L (taken)', [], [0x60FF, 0x0000, 0x0006],
     6, 'Bcc taken 6', 8, 8, 8),
    ('BEQ.S (not taken)', [], [0x6702],
     4, '4', 4, 2, 2),
    ('BEQ.W (not taken)', [], [0x6700, 0x0004],
     6, '6', 6, 3, 3),
    ('BEQ.L (not taken)', [], [0x67FF, 0x0000, 0x0006],
     6, '6', 8, 5, 5),
    ('DBF (count not expired)', [], [0x51CE, 0x0002],
     6, '6', 8, 6, 6),
    ('DBF (count expired)', [0x7C00], [0x51CE, 0x0002],
     10, '10', 13, 4, 4),
    ('DBT (cc true)', [], [0x50CE, 0x0002],
     6, '6', 8, 3, 3),
    # --- 11.6.7
    ('EXG D0,D4', [], [0xC144],
     4, '4', 4, 3, 3),
    ('SWAP D4', [], [0x4844],
     4, '4', 4, 1, 1),
    ('MOVE SR,D4', [], [0x40C4],
     4, '4', 4, 2, 2),
    ('MOVE D0,CCR', [], [0x44C0],
     4, '4', 4, 2, 2),
    ('MOVE #$2700,SR', [], [0x46FC, 0x2700],
     10, '8 + fea #.W 2', 12, 3, 3),
    ('MOVE A0,USP', [], [0x4E60],
     4, '4', 4, 2, 2),
    ('MOVEC CACR,D4', [], [0x4E7A, 0x4002],
     6, '6', 6, 3, 3),
    ('MOVEC D4,SFC', [], [0x4E7B, 0x4000],
     12, '12 (SFC, DFC, CACR)', 12, 3, 3),
    ('MOVEM.L D0-D3,(A2)', [], [0x48D2, 0x000F],
     14, '4 + 2x4 + ciea #.W,(An) 2', 14, 17, 17),
    ('MOVEM.L (A0),D4-D5', [], [0x4CD0, 0x0030],
     18, '8 + 4x2 + ciea #.W,(An) 2', 18, 17, 15),
    ('MOVEP.L D4,(0,A2)', [], [0x09CA, 0x0000],
     14, '14', 14, 18, 18),
    ('MOVEP.L (0,A0),D4', [], [0x0948, 0x0000],
     14, '14', 14, 26, 22),
    ('MOVES.L (A0),D4', [], [0x0E90, 0x4000],
     9, '7 + ciea #.W,(An) 2', 9, 12, 11),
    # --- 11.6.6
    ('MOVE.L D0,D4', [], [0x2800],
     2, 'Rn,Dn 2', 2, 2, 2),
    ('MOVEA.L A0,A4', [], [0x2848],
     2, 'Rn,An 2', 2, 3, 3),
    ('MOVE.W #1,D4', [], [0x383C, 0x0001],
     4, 'EA,Dn 2 + fea #.W 2', 4, 2, 2),
    ('MOVE.L #imm,D4', [], [0x283C, 0x1234, 0x5678],
     6, 'EA,Dn 2 + fea #.L 4', 6, 4, 4),
    ('MOVE.L D0,(A2)', [], [0x2480],
     3, 'Rn,(An) 3', 4, 3, 3),
    ('MOVE.L D0,-(A2)', [], [0x2500],
     4, 'Rn,-(An) 4', 4, 4, 4),
    ('MOVE.L (A0),D4', [], [0x2810],
     5, 'EA,Dn 2 + fea (An) 3', 5, 6, 5),
    ('MOVE.L (8,A0),D4', [], [0x2828, 0x0008],
     6, 'EA,Dn 2 + fea (d16,An) 4', 6, 7, 6),
    ('MOVE.L (4,A0,D3.L),D4', [], [0x2830, 0x3804],
     8, 'EA,Dn 2 + fea (d8,An,Xn) 6, misaligned', 8, 13, 11),
    ('MOVE.L (3,A0,D3.L),D4', [], [0x2830, 0x3803],
     8, 'EA,Dn 2 + fea (d8,An,Xn) 6', 8, 10, 9),
    ('MOVE.L (A0),(A2)', [], [0x2490],
     7, 'Source,(An) 4 + fea (An) 3', 8, 7, 6),
    ('MOVE.L (A0)+,(A2)+', [], [0x24D8],
     7, 'Source,(An)+ 4 + fea (An)+ 3', 8, 8, 7),
    # --- 11.6.16, with the jump or calculate time for the mode
    ('ORI #0,CCR', [], [0x003C, 0x0000],
     12, '12', 14, 2, 2),
    ('ANDI #$FFFF,SR', [], [0x027C, 0xFFFF],
     12, '12', 14, 3, 3),
    ('LEA (A0),A4', [], [0x49D0],
     4, '2 + cea (An) 2', 4, 3, 3),
    ('LEA (8,A0),A4', [], [0x49E8, 0x0008],
     4, '2 + cea (d16,An) 2', 4, 3, 3),
    ('PEA (A0)', [], [0x4850],
     6, '4 + cea (An) 2', 6, 6, 6),
    ('LINK.W A4,#-8', [], [0x4E54, 0xFFF8],
     4, '4', 5, 6, 6),
    ('LINK.L A4,#-8', [], [0x480C, 0xFFFF, 0xFFF8],
     6, '6', 7, 8, 8),
    # 8, not the 7 frozen here before M10: the design at the start of M10
    # already took 8, and nothing had run this since. doc/timing-divergences.md.
    ('UNLK A4', [0x4E54, 0x0000], [0x4E5C],
     5, '5', 5, 8, 7),
    ('JMP (A5)', [], [0x4ED5],
     6, '4 + jea (An) 2', 8, 6, 6),
    # M10: the instruction cache's tag is per LINE (UM 6.1.1). This JSR is at
    # $040C, in line 0 with its target $3000: the call and the return take the
    # line from each other on every pass. doc/timing-divergences.md.
    ('JSR (A3)', [], [0x4E93],
     6, '4 + jea (An) 2', 9, 14, 13),
    # M15: the same call to an RTS the setup writes at $30A0, line 10. The
    # loop itself, $0400 to about $045F, fills lines 0 to 5, so $3000 (line 0)
    # takes a line the loop needs and the loop takes it back, every pass; line
    # 10 is clear of it. MOVE.W #$4E75,($30A0).W; LEA ($30A0).W,A4.
    ('JSR (A4) [own line]', [0x31FC, 0x4E75, 0x30A0, 0x49F8, 0x30A0], [0x4E94],
     6, '4 + jea (An) 2', 9, 9, 9),
    ('BSR.S', [], [0x6102, 0x6002, 0x4E75],
     6, '6', 9, 9, 9),
    ('RTS', [0x487A, 0x0004], [0x4E75],
     9, '9', 11, 9, 7),
    ('RTR', [0x487A, 0x0008, 0x3F3C, 0x0000], [0x4E77],
     12, '12', 14, 17, 15),
    ('RTD #4', [0x2F00, 0x487A, 0x0006], [0x4E74, 0x0004],
     10, '10', 12, 12, 11),
    ('RTE (format 0)', [0x3F3C, 0x0000, 0x487A, 0x0008, 0x3F3C, 0x2700], [0x4E73],
     18, '18 (four word)', 20, 31, 27),
    # A coprocessor midinstruction frame -- UM figure 7-43, built from the top:
    # the effective address, the internal word and operation word ($F200, cpGEN
    # to CpID 1), the program counter, format $9, the scanPC -- the landing pad
    # -- and the status register. RTE ends by reading the response CIR, and
    # sim/models/rd68031_cpmodel.sv answers "processing finished".
    ('RTE (coprocessor)', [0x4878, 0x0000, 0x2F3C, 0x0000, 0xF200, 0x4855, 0x3F3C, 0x9000, 0x4855, 0x3F3C, 0x2700], [0x4E73],
     26, '26', 26, 63, 55),
    ('CHK.L D1,D4 (in range)', [], [0x4901],
     8, '8', 8, 5, 5),
    ('CHK2.L (A0),D4', [], [0x04D0, 0x4800],
     21, '18 + fiea #.W,(An) 3', 22, 22, 20),
    ('CMP2.L (A0),D4', [], [0x04D0, 0x4000],
     23, '20 + fiea #.W,(An) 3', 24, 21, 19),
    ('CAS.L (unsuccessful)', [], [0x0ED0, 0x0040],
     13, '11 + ciea #.W,(An) 2', 13, 13, 12),
    ('CAS.L (successful)', [0x4290], [0x0ED0, 0x0044],
     15, '13 + ciea #.W,(An) 2', 15, 17, 15),
    ('CAS2.L (successful)', [0x4290, 0x4291], [0x0EFC, 0x8044, 0x9085],
     24, '24', 26, 38, 34),
    # --- 11.6.17
    ('TRAPV (no trap)', [], [0x4E76],
     4, '4', 4, 2, 2),
    ('TRAPF', [], [0x51FC],
     4, '4', 4, 2, 2),
    ('TRAPF.W', [], [0x51FA, 0x0000],
     6, '6', 6, 3, 3),
    ('TRAPF.L', [], [0x51FB, 0x0000, 0x0000],
     8, '8', 8, 4, 4),
    # ... and so does this TRAP and its handler.
    ('TRAP #0', [], [0x4E40],
     18, '18', 20, 32, 28),
    # M15: the same with its handler, an RTE the setup writes at $30A0 (line
    # 10, clear of the loop's lines 0 to 5), and vector 32 pointed at it:
    # MOVE.W #$4E73,($30A0).W; MOVE.L #$30A0,($80).W.
    ('TRAP #0 [own line]', [0x31FC, 0x4E73, 0x30A0, 0x21FC, 0x0000, 0x30A0, 0x0080],
     [0x4E40], 18, '18', 20, 27, 24),
    ('ILLEGAL', [], [0x4AFC],
     18, '18', 20, 32, 28),
    ('line A', [], [0xA000],
     18, '18', 20, 32, 28),
    ('RESET', [], [0x4E70],
     518, '518', 518, 515, 515),
    # --- The coprocessor interface, against the scripted coprocessor of
    # sim/models/rd68031_cpmodel.sv answering as an MC68881 does (CP_SCRIPTS
    # below), at no wait states and with no time of its own. So these rows
    # are the PROCESSOR's clocks; the manual's figures are MC68881UM tables
    # 8-6, 8-7 and 8-8 in the cache case, plus table 8-1's effective address,
    # and include the MC68881's own time -- a ceiling, not a target.
    ('FNOP', [], [0xF280, 0x0000],
     18, 'MC68881 8-7 18', None, 18, 18),
    ('FBEQ.W (taken)', [], [0xF281, 0x0002],
     20, 'MC68881 8-7 20', None, 21, 21),
    ('FBEQ.W (not taken)', [], [0xF281, 0x0002],
     18, 'MC68881 8-7 18', None, 18, 18),
    ('FSEQ D0', [], [0xF240, 0x0001],
     18, 'MC68881 8-7 18', None, 22, 22),
    ('FMOVE.L D0,FPCR', [], [0xF200, 0x9000],
     28, 'MC68881 8-6 28', None, 25, 25),
    ('FMOVE.L FPCR,D0', [], [0xF200, 0xB000],
     31, 'MC68881 8-6 31', None, 27, 27),
    ('FMOVE.L (A0),FPCR', [], [0xF210, 0x9000],
     35, 'MC68881 8-6 33 + (An) 2', None, 29, 28),
    ('FMOVEM.L FPcr*3,(A0)', [], [0xF210, 0xBC00],
     47, 'MC68881 8-6 27+6n + (An) 2', None, 45, 43),
    ('FMOVEM.X (A0),FP0-FP2', [], [0xF210, 0xD0E0],
     130, 'MC68881 8-6 35+31n + (An) 2', None, 96, 87),
    ('FMOVEM.X FP0-FP2,-(A7)', [], [0xF227, 0xE007],
     118, 'MC68881 8-6 37+25n + -(An) 6', None, 97, 91),
    ('FSAVE -(A7) (idle)', [], [0xF327],
     58, 'MC68881 8-8 52 + -(An) 6', None, 63, 63),
    ('FRESTORE (A7)+ (idle)', [0x9EFC, 0x0018, 0x2F3C, 0x1F18, 0x0000], [0xF35F],
     63, 'MC68881 8-8 57 + (An)+ 6', None, 72, 65),
    # --- UM 11.4, the data cache: the setup enables it (MOVE.W #$0101,D0;
    # MOVEC D0,CACR, EI and ED) so the warm pass's operand read hits. A hit
    # takes the operand fetch's tail off the CC, down to one clock (rules 1a-1c);
    # a memory-indirect mode counts as one read; RMC reads always miss; an
    # operand fetch inside CCop (CMPM) is not corrected. No NCC: both miss there.
    ('ADD.L (A0),D4 [D hit]', [0x303C, 0x0101, 0x4E7B, 0x0002], [0xD890],
     4, '2 + fea (An) 3, tail 1 -> 2', None, 3, 3),
    ('ADD.L -(A1),D4 [D hit]', [0x303C, 0x0101, 0x4E7B, 0x0002], [0xD8A1],
     5, '2 + fea -(An) 4, tail 2 -> 3', None, 4, 4),
    ('ADD.L (8,A0),D4 [D hit]', [0x303C, 0x0101, 0x4E7B, 0x0002], [0xD8A8, 0x0008],
     5, '2 + fea (d16,An) 4, tail 2 -> 3', None, 4, 4),
    # The pointer at $2000 is set to $2010 (MOVE.L #$2010,(A0)): left at zero
    # it points at $0000, in the same data cache line as $2000, and the two
    # reads take the line from each other.
    ('ADD.L ([A0]),D4 [D hit]', [0x303C, 0x0101, 0x4E7B, 0x0002, 0x20BC, 0x0000, 0x2010],
     [0xD8B0, 0x0151], 12, '2 + fea ([B]) 10, tail 0', None, 14, 14),
    ('MOVE.L (A0),(A2) [D hit]', [0x303C, 0x0101, 0x4E7B, 0x0002], [0x2490],
     6, 'Source,(An) 4 + fea (An) 3, tail 1 -> 2', None, 4, 4),
    # A1 is moved to $2010 (LEA (16,A0),A1): at $2100 it is in the same
    # data cache line as $2000.
    ('CMPM.L (A0)+,(A1)+ [D hit]', [0x303C, 0x0101, 0x4E7B, 0x0002, 0x43E8, 0x0010],
     [0xB388], 8, '8, not corrected (11.4 note)', None, 9, 9),
    ('TAS (A0) [D hit]', [0x303C, 0x0101, 0x4E7B, 0x0002], [0x4AD0],
     14, '12 + cea (An) 2, RMC misses', None, 13, 11),
    # --- The MMU instructions. UM section 11 has no table for them (its
    # 11.7 is the table search alone), so these rows are measurements with no
    # manual figure, frozen like the rest. The MMU is disabled (TC.E = 0).
    ('PMOVE TC,(A0)', [], [0xF010, 0x4200], None, '--', None, 13, 13),
    ('PMOVE (A0),TC', [], [0xF010, 0x4000], None, '--', None, 19, 18),
    ('PMOVE (A0),TT0', [], [0xF010, 0x0800], None, '--', None, 19, 18),
    ('PMOVE.Q CRP,(A0)', [], [0xF010, 0x4E00], None, '--', None, 15, 15),
    ('PMOVE MMUSR,(A0)', [], [0xF010, 0x6200], None, '--', None, 13, 13),
    ('PFLUSHA', [], [0xF000, 0x2400], None, '--', None, 7, 7),
    ('PFLUSH #0,#0', [], [0xF000, 0x3010], None, '--', None, 7, 7),
    ('PTESTR #1,(A0),#0', [], [0xF010, 0x8211], None, '--', None, 13, 13),
]

# What the scripted coprocessor answers, per pass, for the coprocessor rows:
# R a response, O an operand it hands over, S a register select, V a save
# format word. Once the script runs out it answers "processing finished"
# ($0802) to the response CIR, and a restore CIR reads back what was written --
# a valid format. The primitives are an MC68881's (MC68881UM section 7):
# $9504 evaluate <ea> and transfer four bytes in, $B104 out, $B20C three
# control registers out, $810C / $A10C transfer multiple registers in / out,
# twelve bytes each, and $0801 a null whose condition is true. A dialogue that
# comes again ends on an explicit $0802, so that each pass takes its own.
CP_SCRIPTS = {
    'FBEQ.W (taken)':         ['R0801'],
    'FSEQ D0':                ['R0801'],
    'FMOVE.L D0,FPCR':        ['R9504', 'R0802'],
    'FMOVE.L FPCR,D0':        ['RB104', 'O00000000', 'R0802'],
    'FMOVE.L (A0),FPCR':      ['R9504', 'R0802'],
    'FMOVEM.L FPcr*3,(A0)':   ['RB20C', 'O00000000', 'O00000000', 'O00000000',
                               'R0802'],
    'FMOVEM.X (A0),FP0-FP2':  ['R810C', 'S00E0', 'R0802'],
    'FMOVEM.X FP0-FP2,-(A7)': ['RA10C', 'S0007'] + ['O00000000'] * 9 + ['R0802'],
    'FSAVE -(A7) (idle)':     ['V1F18'] + ['O00000000'] * 6,
}


def gen():
    print(len(ROWS))
    for k, row in enumerate(ROWS):
        name, pre, ins = row[:3]
        script = CP_SCRIPTS.get(name, [])
        tag = 'r%d' % k
        words = [len(pre)] + pre + [len(ins)] + ins
        print(tag, ' '.join('%x' % w for w in words), len(script), ' '.join(script))


def load(path):
    got = {}
    with open(path) as fh:
        for line in fh:
            m = re.match(r'^CYCLES (\S+) (\d+) (\d+)', line)
            if m:
                got[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return got


def check(path, path_sync, doc=None):
    got = load(path)
    got_s = load(path_sync)
    bad = 0
    rows = []
    for k, (name, pre, ins, cc, how, ncc, ours, ours_s) in enumerate(ROWS):
        # By position and not by name: names differ in punctuation, and a tag
        # made from one collapsed (A0), (A0)+ and ([A0]) into the same row.
        tag = 'r%d' % k
        if tag not in got or tag not in got_s:
            print(f'  FAIL: {name}: no measurement')
            bad += 1
            continue
        warm, cold = got[tag]
        warm_s, cold_s = got_s[tag]
        for what, have, want in (('asynchronous', warm, ours),
                                 ('synchronous', warm_s, ours_s)):
            if want is None:
                print(f'  NEW:  {name}: {have} warm on the {what} bus '
                      f'(manual {cc}) -- freeze it in tools/cycles.py')
                bad += 1
            elif have != want:
                print(f'  FAIL: {name}: {have} clocks on the {what} bus, '
                      f'was {want} (manual {cc})')
                bad += 1
        rows.append((name, how, cc, ncc, warm, warm_s, cold, cold_s))
    if doc:
        splice(doc, rows)
    # The coprocessor rows are against MC68881UM section 8, whose totals
    # include the FPU's own time; they are reported apart from UM 11's mix.
    cp = [r for r in rows if r[0] in CP_SCRIPTS or r[1].startswith('MC68881')]
    um = [r for r in rows if r not in cp and r[2] is not None and r[2] < 500]
    for col, what in ((4, 'asynchronous'), (5, 'synchronous')):
        n = len(um)
        same = sum(1 for r in um if r[col] == r[2])
        faster = sum(1 for r in um if r[col] < r[2])
        slower = n - same - faster
        tot_m = sum(r[2] for r in um)
        tot_o = sum(r[col] for r in um)
        print(f'  cycles, {what} bus: {n} instructions -- {same} exact, '
              f'{faster} faster, {slower} slower; {tot_o} clocks against '
              f'the manual\'s {tot_m} (RESET aside)')
    nc = [r for r in um if r[3] is not None]
    print(f'  no-cache case: {len(nc)} instructions, cold on the synchronous '
          f'bus {sum(r[7] for r in nc)} clocks against the manual\'s average '
          f'{sum(r[3] for r in nc)}')
    if cp:
        print(f'  coprocessor: {len(cp)} instructions, {sum(r[4] for r in cp)} '
              f'clocks with the scripted coprocessor; MC68881UM section 8, '
              f'whose totals include the FPU\'s own time, adds up to '
              f'{sum(r[2] for r in cp)}')
    if bad:
        print('FAIL: cycles')
        return 1
    print('PASS: cycles')
    return 0


BEGIN = '<!-- cycles:begin -- generated by tools/cycles.py; do not edit -->'
END = '<!-- cycles:end -->'


def splice(doc, rows):
    def delta(have, want):
        if want is None:
            return ''
        d = have - want
        return '' if d == 0 else ('**%+d**' % d if d > 0 else '%+d' % d)

    def num(v):
        return '--' if v is None else str(v)

    lines = ['| Instruction | UM 11 CC | | sync, warm | Δ | async, warm | Δ '
             '| UM 11 NCC | sync, cold | Δ | async, cold |',
             '|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|']
    for name, how, cc, ncc, warm, warm_s, cold, cold_s in rows:
        lines.append(f'| `{name}` | {num(cc)} | {how} | {warm_s} | '
                     f'{delta(warm_s, cc)} | {warm} | {delta(warm, cc)} | '
                     f'{num(ncc)} | {cold_s} | {delta(cold_s, ncc)} | {cold} |')
    table = '\n'.join(lines)
    text = open(doc).read()
    if BEGIN not in text:
        raise SystemExit(f'{doc} has no {BEGIN!r} marker')
    a = text.index(BEGIN) + len(BEGIN)
    b = text.index(END)
    text = text[:a] + '\n' + table + '\n' + text[b:]
    open(doc, 'w').write(text)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == 'gen':
        gen()
        return 0
    if len(sys.argv) >= 4 and sys.argv[1] == 'check':
        doc = sys.argv[5] if len(sys.argv) >= 6 and sys.argv[4] == '--doc' else None
        return check(sys.argv[2], sys.argv[3], doc)
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main())
