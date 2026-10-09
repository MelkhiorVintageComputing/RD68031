| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- the MC68030's two caches, UM section 6, for sim/tb/core_cache_tb.sv.
|
| A cache is architecturally invisible except through the bus and through
| memory that changes behind it, so every test here is a short run of accesses
| between two MARKs -- a write of the phase number to MARKA, which the
| testbench watches for -- and the testbench counts the bus cycles of each
| phase, changes memory or a pin at a MARK when the test needs it, and checks
| the values the program stored at RES.
|
| The memory map is the core harness's: a 32-bit asynchronous port at $0000_0000,
| a 16-bit one at $1000_0000, an 8-bit one at $2000_0000, and a 32-bit
| synchronous port that bursts at $3000_0000 (UM 7.3.7).
|
| Two rules keep the tests from disturbing each other:
|   - line index 15 (A7-A4 = $F) is never a test line: MARKA and the stack's
|     top long word are there, and with WA set an aligned long-word write
|     allocates its line (UM 6.1.2.1);
|   - nothing is stored at RES between preparing a line and probing it while WA
|     is set, for the same reason: values are kept in registers until the probe
|     is over.
|
| Not built with crt0.S: this program owns its vector table and its modes.

        .equ    STACK,   0xF000
        .equ    MARKA,   0x0EF0         | line 15
        .equ    EXC,     0x0E80         | exceptions taken, counted by `any`
        .equ    RES,     0xC000         | results, one long word each, in order
        .equ    SUBA,    0x30F0         | the subroutine the instruction cache runs
        .equ    SUBB,    0x300030F0     | ... and its copy on the bursting port
        .equ    CPUA,    0x00030000     | a CPU-space address the testbench answers

        | CACR -- UM figure 6-14
        .equ    EI,  0x0001
        .equ    FI,  0x0002
        .equ    CEI, 0x0004
        .equ    CI,  0x0008
        .equ    IBE, 0x0010
        .equ    ED,  0x0100
        .equ    FD,  0x0200
        .equ    CED, 0x0400
        .equ    CD,  0x0800
        .equ    DBE, 0x1000
        .equ    WA,  0x2000

        .macro  MARK n
        move.l  #\n, MARKA
        nop                             | PRM 4: waits for the bus -- the MARK is out
        nop
        nop
        .endm

        .macro  CACR v
        move.l  #(\v), %d0
        movec   %d0, %cacr
        .endm

        .macro  CAAR v
        move.l  #(\v), %d0
        movec   %d0, %caar
        .endm

        | Read a long word, a word or a byte into D1, and store it at RES.
        .macro  RDL a
        movea.l #(\a), %a0
        move.l  (%a0), %d1
        move.l  %d1, (%a2)+
        .endm
        .macro  RDW a
        movea.l #(\a), %a0
        moveq   #0, %d1
        move.w  (%a0), %d1
        move.l  %d1, (%a2)+
        .endm
        .macro  RDB a
        movea.l #(\a), %a0
        moveq   #0, %d1
        move.b  (%a0), %d1
        move.l  %d1, (%a2)+
        .endm
        | ... into a register, storing nothing.
        .macro  GETL a, r
        movea.l #(\a), %a0
        move.l  (%a0), \r
        .endm

        | One call of the subroutine at A5: nine passes of its loop, each adding
        | one to D3.
        .macro  CALL
        moveq   #9, %d1
        jsr     (%a5)
        .endm

        | The instruction cache is direct mapped, and this program is far bigger
        | than it: code run between two calls of the subroutine could take the
        | subroutine's line. So every group of instruction cache tests starts at
        | a 256-byte boundary and is shorter than 224 bytes -- it never touches
        | line 15, the subroutine's, nor prefetches into it.
        .macro  NEWBLOCK
        bra     9f
        .balign 256, 0
9:
        .endm

        .section .vectors, "a"
        .long   STACK
        .long   _start
        .rept   254
        .long   any
        .endr

        .text
        .globl  _start
_start:
        move.l  #STACK, %sp
        movea.l #RES, %a2
        clr.l   EXC
        moveq   #0, %d3
        movea.l #SUBA, %a5

| ===========================================================================
| The data cache, UM 6.1.2
| ===========================================================================

        | 1, 2: a read misses and fills; the same read again hits. At MARK 2 the
        | testbench changes $8000 in memory, so a hit is the OLD value.
        CACR    EI+ED
        MARK    1
        RDL     0x8000
        MARK    2
        RDL     0x8000
        | 3: disabled, the cache is not looked up -- the new value, from the bus.
        CACR    EI
        MARK    3
        RDL     0x8000
        RDL     0x8000
        | 4: enabled again, "the previously valid entries remain valid and can be
        | used" (UM 6.3.1.6) -- the old value again, no bus.
        CACR    EI+ED
        MARK    4
        RDL     0x8000
        | 5: CD clears it (UM 6.3.1.3), and reads back as zero.
        CACR    EI+ED+CD
        MARK    5
        RDL     0x8000
        movec   %cacr, %d1
        move.l  %d1, (%a2)+

        | 6, 7: CED clears the one entry CAAR's index names (UM 6.3.1.4).
        MARK    6
        RDL     0x8010
        RDL     0x8014
        CAAR    0x8010
        CACR    EI+ED+CED
        MARK    7
        RDL     0x8010
        RDL     0x8014
        movec   %cacr, %d1
        move.l  %d1, (%a2)+
        | 8: ... by index alone: the tag is not compared.
        CAAR    0xFFFF8014
        CACR    EI+ED+CED
        MARK    8
        RDL     0x8014

        | 9: frozen from the start, nothing goes in (UM 6.3.1.5).
        CACR    EI+ED+FD+CD
        MARK    9
        RDL     0x8020
        RDL     0x8020
        | 10: frozen after a fill, what is in there hits; and a write that hits
        | updates it, "even if the cache is frozen" (UM 6.1.2). The testbench
        | changes $8030 in memory at MARK 11, so a read of the written value
        | comes from the cache.
        CACR    EI+ED
        RDL     0x8030
        CACR    EI+ED+FD
        MARK    10
        RDL     0x8030
        movea.l #0x8030, %a0
        move.l  #0x10A0A0A0, (%a0)
        MARK    11
        RDL     0x8030
        | 12: frozen, WA is ignored -- an aligned long-word write that misses
        | allocates nothing (UM 6.3.1.1).
        CACR    EI+ED+FD+WA
        movea.l #0x8040, %a0
        move.l  #0x12121212, (%a0)
        MARK    12
        RDL     0x8040

        | 13, 14: write-through. A write that hits goes to memory too, and the
        | cache has it: the testbench changes $8050 in memory at MARK 14.
        CACR    EI+ED+CD
        RDL     0x8050
        MARK    13
        movea.l #0x8050, %a0
        move.l  #0x13131313, (%a0)
        MARK    14
        RDL     0x8050

| ---------------------------------------------------------------------------
| Write allocation, UM 6.1.2.1 and figure 6-4. Line 5 of the cache: entries
| $A050 (V0), $A054 (V1), $A058 (V2), $A05C (V3), with V1 left invalid by the
| preparation; $B05x has the same index and another tag.
| ---------------------------------------------------------------------------
        .macro  WAPREP mode
        MARK    18                      | the preparation is a phase of its own
        CACR    EI+ED+CD+\mode
        GETL    0xA050, %d4
        GETL    0xA058, %d4
        GETL    0xA05C, %d4
        .endm

        .macro  WATEST mode, base
        | Example 1: a word write that hits -- "always update cache and memory".
        WAPREP  \mode
        MARK    \base+0
        movea.l #0xA052, %a0
        move.w  #0xE101, (%a0)
        MARK    \base+1
        GETL    0xA050, %d4
        move.l  %d4, (%a2)+
        | Example 2: a misaligned long word, half missing (V1) and half hitting
        | (V2): the hit is updated.
        WAPREP  \mode
        MARK    \base+2
        movea.l #0xA056, %a0
        move.l  #0xE2E2E2E2, (%a0)
        MARK    \base+3
        GETL    0xA058, %d4
        GETL    0xA054, %d5
        move.l  %d4, (%a2)+
        move.l  %d5, (%a2)+
        | Example 3: an aligned long word, tag matching, entry invalid.
        WAPREP  \mode
        MARK    \base+4
        movea.l #0xA054, %a0
        move.l  #0xE3E3E3E3, (%a0)
        MARK    \base+5
        GETL    0xA054, %d4
        GETL    0xA050, %d5
        move.l  %d4, (%a2)+
        move.l  %d5, (%a2)+
        | Example 4: an aligned long word with no tag match. Probed twice, from
        | two preparations, because each probe changes the line.
        WAPREP  \mode
        MARK    \base+6
        movea.l #0xB054, %a0
        move.l  #0xE4E4E4E4, (%a0)
        MARK    \base+7
        GETL    0xB054, %d4
        move.l  %d4, (%a2)+
        WAPREP  \mode
        MARK    \base+8
        movea.l #0xB054, %a0
        move.l  #0xE5E5E5E5, (%a0)
        MARK    \base+9
        GETL    0xA050, %d4
        move.l  %d4, (%a2)+
        | Example 5: a misaligned long word with no tag match.
        WAPREP  \mode
        MARK    \base+10
        movea.l #0xB056, %a0
        move.l  #0xE6E6E6E6, (%a0)
        MARK    \base+11
        GETL    0xA050, %d4
        GETL    0xA058, %d5
        move.l  %d4, (%a2)+
        move.l  %d5, (%a2)+
        | A byte write, tag matching, entry invalid: allocates nothing.
        WAPREP  \mode
        MARK    \base+12
        movea.l #0xA055, %a0
        move.b  #0xE7, (%a0)
        MARK    \base+13
        GETL    0xA054, %d4
        move.l  %d4, (%a2)+
        | A byte write with no tag match: with WA, the entry's valid bit cleared.
        WAPREP  \mode
        MARK    \base+14
        movea.l #0xB051, %a0
        move.b  #0xE8, (%a0)
        MARK    \base+15
        GETL    0xA050, %d4
        move.l  %d4, (%a2)+
        .endm

        WATEST  0, 20
        WATEST  WA, 40

| ---------------------------------------------------------------------------
| Read-modify-write and CPU space -- UM 6.1.2, 6.1.2.2
| ---------------------------------------------------------------------------
        | 60, 61: TAS on a cached byte: its read is forced to miss; its write
        | updates the entry.
        CACR    EI+ED+CD
        RDL     0x8060
        MARK    60
        movea.l #0x8060, %a0
        tas     (%a0)
        MARK    61
        RDB     0x8060
        | 62, 63: TAS on a byte not cached: its read creates the entry, and the
        | testbench changes $8070 in memory at MARK 63 to prove it.
        MARK    62
        movea.l #0x8070, %a0
        tas     (%a0)
        MARK    63
        RDL     0x8070
        | 64: CPU space is never cached (UM 6.1.2): two reads, two cycles.
        moveq   #7, %d0
        movec   %d0, %sfc
        MARK    64
        movea.l #CPUA, %a0
        moves.l (%a0), %d1
        moves.l (%a0), %d1
        move.l  %d1, (%a2)+
        | 65, 66: the tag carries FC2-FC0 (UM 6.1.2): the same address in user
        | data space, through MOVES, is another entry.
        RDL     0x8100
        moveq   #1, %d0
        movec   %d0, %sfc
        MARK    65
        movea.l #0x8100, %a0
        moves.l (%a0), %d1
        MARK    66
        moves.l (%a0), %d1
        move.l  %d1, (%a2)+
        | 67: and supervisor program space is a third.
        moveq   #6, %d0
        movec   %d0, %sfc
        MARK    67
        moves.l (%a0), %d1
        | 68, 69: TAS on a cached byte of the 8-bit port: no cycles complete the
        | entry inside the locked sequence, and the entry it could not refresh is
        | left invalid rather than stale.
        movea.l #0x20000031, %a0
        move.b  (%a0), %d1
        MARK    68
        tas     (%a0)
        MARK    69
        move.b  (%a0), %d1

| ---------------------------------------------------------------------------
| Narrow ports -- UM 6.1.3.1, figures 6-5 to 6-10: the cycles that complete
| each cache entry.
| ---------------------------------------------------------------------------
        CACR    EI+ED+CD
        MARK    70
        RDB     0x20000003              | figure 6-5
        MARK    71
        RDB     0x20000001
        MARK    72
        RDB     0x10000003              | figure 6-6
        MARK    73
        RDW     0x10000000
        MARK    74
        RDL     0x20000006              | figure 6-8
        MARK    75
        RDL     0x20000008
        MARK    76
        RDL     0x10000026              | figure 6-9
        MARK    77
        RDL     0x80A6                  | figure 6-10
        MARK    78
        RDL     0x80A4
        | 79: disabled, only the operand's own cycle.
        CACR    EI
        MARK    79
        RDB     0x20000013

| ---------------------------------------------------------------------------
| Half hits -- UM 6.1.2, "the hit and miss are treated independently", and
| UM 7.2.7, OCS on the second portion
| ---------------------------------------------------------------------------
        CACR    EI+ED+CD
        MARK    84
        GETL    0x80B4, %d4
        GETL    0x80C8, %d4
        MARK    80
        RDL     0x80B6                  | $80B4 hits, $80B8 does not
        MARK    81
        RDL     0x80C6                  | $80C4 does not, $80C8 hits

| ---------------------------------------------------------------------------
| Bursts -- UM 6.1.3.2 and 7.3.7, on the synchronous port
| ---------------------------------------------------------------------------
        CACR    EI+ED+DBE+CD
        MARK    90
        RDL     0x30000104              | a cold line: one burst, four long words
        MARK    91
        RDL     0x30000100
        RDL     0x30000108
        RDL     0x3000010C
        | 92: DBE clear: single entries, no CBREQ.
        CACR    EI+ED
        MARK    92
        RDL     0x30000114
        RDL     0x30000118
        | 93, 94: the device gives two long words and negates CBACK (the
        | testbench limits it at MARK 93); the rest of the line is single
        | entries -- "the corresponding long word is not valid (but one or more
        | of the other three valid bits for that line are set)" (UM 6.1.1).
        CACR    EI+ED+DBE
        MARK    93
        RDL     0x30000124
        MARK    94
        RDL     0x30000128
        RDL     0x3000012C
        RDL     0x30000120
        | 95, 96: CIIN on the third long word of a burst: it is not cached and
        | the burst ends (UM 6.1.3.2).
        MARK    95
        RDL     0x30000134
        MARK    96
        RDL     0x30000138
        RDL     0x3000013C
        RDL     0x30000130
        | 97, 98: CIIN throughout: nothing is cached, and the first cycle's CIIN
        | aborts the burst. A write ignores CIIN (UM 6.1.2.1): with WA, an
        | aligned long word allocates all the same.
        CACR    EI+ED+DBE+WA
        MARK    97
        GETL    0x30000144, %d4
        GETL    0x30000144, %d5
        movea.l #0x30000154, %a0
        move.l  #0x98989898, (%a0)
        MARK    98
        GETL    0x30000154, %d6
        move.l  %d4, (%a2)+
        move.l  %d5, (%a2)+
        move.l  %d6, (%a2)+
        | 99, 100: BERR on the third long word of a burst: no exception, that
        | entry invalid (UM 6.1.3.2).
        CACR    EI+ED+DBE
        MARK    99
        RDL     0x30000164
        MARK    100
        RDL     0x30000168
        RDL     0x3000016C
        | 101, 102: BERR on a cycle that only completes an entry, from the 8-bit
        | port: no exception, the entry invalid (UM 6.1.3.1).
        MARK    101
        RDB     0x20000023
        MARK    102
        RDB     0x20000023
        move.l  EXC, %d1
        move.l  %d1, (%a2)+

| ===========================================================================
| The instruction cache, UM 6.1.1
| ===========================================================================
        NEWBLOCK
        CACR    EI+CI
        MARK    110
        CALL                            | fills
        MARK    111
        CALL                            | hits
        | 112: disabled: every pass is a bus cycle.
        CACR    0
        MARK    112
        CALL
        | 113: re-enabled: the old entries hit (UM 6.3.1.11).
        CACR    EI
        MARK    113
        CALL
        | 114: frozen from empty (UM 6.3.1.10).
        NEWBLOCK
        CACR    EI+FI+CI
        MARK    114
        CALL
        | 115: frozen full: still hits.
        CACR    EI
        CALL
        CACR    EI+FI
        MARK    115
        CALL
        | 116: CI clears it all, and reads back as zero.
        CACR    EI+CI
        MARK    116
        CALL
        movec   %cacr, %d1
        move.l  %d1, (%a2)+
        | 117: CEI clears the entry CAAR names, and only it.
        NEWBLOCK
        CAAR    SUBA
        CACR    EI+CEI
        MARK    117
        CALL
        | 118: ... by index: the tag is not compared.
        CAAR    SUBA+0x10000
        CACR    EI+CEI
        MARK    118
        CALL

        | 120, 121: on the bursting port with IBE: one burst fills the line.
        NEWBLOCK
        movea.l #SUBB, %a5
        CACR    EI+IBE+CI
        MARK    120
        CALL
        MARK    121
        CALL
        | 122: IBE clear: single entries.
        CACR    EI+CI
        MARK    122
        CALL
        | 123: two long words per burst (the testbench limits the device).
        CACR    EI+IBE+CI
        MARK    123
        CALL
        | 124: CIIN throughout (the testbench sets it): nothing is cached.
        CACR    EI+IBE+CI
        MARK    124
        CALL
        movea.l #SUBA, %a5

        NEWBLOCK
        | 125, 126: CDIS disables both caches whatever CACR says, and flushes
        | neither (UM 6.1, 6.3.1). The testbench asserts it at MARK 125 and
        | negates it at MARK 126.
        CACR    EI+ED+CI+CD
        CALL
        GETL    0x8200, %d4
        MARK    125
        CALL
        GETL    0x8200, %d4
        MARK    126
        CALL
        GETL    0x8200, %d4

        NEWBLOCK
        | 127, 128: a prefetch that ends in a bus error is not cached (the
        | testbench makes the long word past the RTS answer with BERR).
        CACR    EI+CI
        MARK    127
        CALL
        MARK    128
        CALL

        NEWBLOCK
        | 130-133: code that modifies itself. The instruction cache is not told
        | of a write -- "the instruction cache is not snooped" is the software's
        | problem, which is why CACR has CI and CEI. After the first call the
        | subroutine's ADDQ.L #1,D3 becomes ADDQ.L #2,D3 by an ordinary write.
        CACR    EI+ED+WA+CI+CD
        moveq   #0, %d3
        MARK    130
        CALL
        movea.l #SUBA, %a0
        move.w  #0x5483, (%a0)          | ADDQ.L #2,D3
        MARK    131
        CALL                            | the cache still has ADDQ.L #1
        move.l  %d3, (%a2)+             | 18
        CACR    EI+ED+WA+CI
        MARK    132
        CALL                            | cleared: the new one runs
        move.l  %d3, (%a2)+             | 36
        CAAR    SUBA
        move.w  #0x5283, (%a0)          | back to ADDQ.L #1
        CACR    EI+ED+WA+CEI
        MARK    133
        CALL                            | CEI on the entry is enough
        move.l  %d3, (%a2)+             | 45

        NEWBLOCK
        | 134, 135: the tag carries FC2 (UM 6.1.1): in user mode, the
        | supervisor's entries do not hit. TRAP #1 comes back.
        CACR    EI+CI
        CALL
        MARK    134
        CALL                            | supervisor: hits
        movea.l #0xE000, %a0
        move    %a0, %usp
        move.w  #0x0000, %sr
        MARK    135
        CALL                            | user: misses
        trap    #1

        MARK    199
done:   bra     done

| ---------------------------------------------------------------------------
| Exceptions. TRAP #1 returns to the supervisor state; anything else is
| counted at EXC and returned from, which the tests above expect never to
| happen.
| ---------------------------------------------------------------------------
any:
        move.l  %d0, -(%sp)
        move.w  10(%sp), %d0            | the format/vector word
        andi.w  #0x0FFF, %d0
        cmpi.w  #0x0084, %d0            | vector 33, TRAP #1
        bne.s   1f
        move.l  (%sp)+, %d0
        ori.w   #0x2000, (%sp)
        rte
1:      addq.l  #1, EXC
        move.l  (%sp)+, %d0
        rte

| ---------------------------------------------------------------------------
| The subroutine. It is line 15 of the instruction cache, all of it: its four
| instructions are the line's first two long words. Position independent, so the
| testbench can copy it to the bursting port.
| ---------------------------------------------------------------------------
        .org    0x20F0                  | SUBA, from .text at $1000
sub:    addq.l  #1, %d3
        subq.l  #1, %d1
        bne.s   sub
        rts
        nop
        nop
        nop
        nop
