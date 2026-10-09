| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- the MMU's registers and instructions, UM 9.3, 9.4, 9.7 and 9.8.
|
|   phase  1      PMOVE to and from every register: what each keeps
|   phase  2      the MMU configuration exception, UM 8.1.10 and 9.7.5.3
|   phases 3-15   PLOAD, PTEST level 0, PFLUSH in every form, PMOVEFD
|   phases 20-35  TT0 and TT1: matching, CIOUT, both caches inhibited
|   phases 40-44  MMUDIS, UM 9.2.3
|
| Assembled with -mcpu=68030; every PMOVE operand is addressed through an
| address register -- (d16,PC) is not a control alterable mode (PRM 6).

#include "mmu_common.inc"

        .equ    PATC,   0xAB000000      | the long word at $C0xx is PATC + $C0xx
        .equ    PATD,   0xCD000000      | ... at $D0xx, PATD + $D0xx
        .equ    PAT3,   0x3C000000      | ... at $3000_C0xx, PAT3 + $C0xx

        .text
main:
        | The synchronous port's long words, for the TT tests.
        lea     0x3000C000, %a0
        move.l  #PAT3 + 0xC000, %d0
        moveq   #31, %d1
1:      move.l  %d0, (%a0)+
        addq.l  #4, %d0
        dbf     %d1, 1b

| ===========================================================================
| Phase 1 -- PMOVE round trips. UM 9.7.2: TC's unimplemented fields "are read
| as zeros and must always be written as zeros"; UM 9.5.1.1 and 9.7.1: a root
| pointer's reserved bits are not alterable and bits 3-0 "are ignored when
| written"; figures 9-37 and 9-38 for TTx and MMUSR.
| ===========================================================================
        PHASE   1
        WRREG32 %tt1, 0x12345678
        RDREG   %tt1
        CHECK   SCR, 0x12340670
        WRREG32 %tt1, 0
        WRREG32 %tc, 0x7CFFFFFF          | E clear: no consistency check
        RDREG   %tc
        CHECK   SCR, 0x00FFFFFF
        WRREG32 %tc, 0
        WRRP    %crp, 0xFFFFFFFF, 0xFFFFFFFF
        RDREG   %crp
        CHECK   SCR, 0xFFFF0003
        CHECK   SCR+4, 0xFFFFFFF0
        WRRP    %srp, 0x80000002, 0x00012345
        RDREG   %srp
        CHECK   SCR, 0x80000002
        CHECK   SCR+4, 0x00012340
        lea     SCR, %a5
        move.w  #0xFFFF, (%a5)
        pmove   (%a5), %psr
        clr.l   (%a5)
        pmove   %psr, (%a5)
        moveq   #0, %d3
        move.w  SCR, %d3
        CHECK   %d3, 0xEE47
        RDREG   %tt0
        CHECK   SCR, TT0_SUP

| ===========================================================================
| Phase 2 -- the MMU configuration exception: vector 56, a format $2 frame,
| the next instruction stacked and the PMOVE at +$08 (UM 8.1.10), and the
| register written all the same (UM 9.7.2, 9.7.5.3, PRM 6).
| ===========================================================================
        PHASE   2
        | TC with E set and the fields summing to 28: PS 12 + TIA 8 + TIB 8.
        lea     SCR, %a5
        move.l  #0x80C08800, (%a5)
c_tc1:  pmove   (%a5), %tc
c_tc1n: CHECK   NCFG, 1
        CHECK   CFGFV, 0x20E0
        CHECK   CFGPC, c_tc1n
        CHECK   CFGIA, c_tc1
        RDREG   %tc
        CHECK   SCR, 0x00C08800          | "updated with the data, and the E bit is cleared"
        | A reserved page size, $7.
        lea     SCR, %a5
        move.l  #0x8070F000, (%a5)
        pmove   (%a5), %tc
        CHECK   NCFG, 2
        RDREG   %tc
        CHECK   SCR, 0x0070F000
        | "The TIx fields are added together until a zero field is reached":
        | PS 12 + TIA 10 = 22, and TIC's 10 after TIB's zero does not count.
        lea     SCR, %a5
        move.l  #0x80C0A0A0, (%a5)
        pmove   (%a5), %tc
        CHECK   NCFG, 3
        RDREG   %tc
        CHECK   SCR, 0x00C0A0A0
        | A valid one: PS 12 + TIA 10 + TIB 10. No exception, and translation
        | is on until the next PMOVE -- everything here is TT0's.
        WRREG32 %tc, 0x80C0AA00
        CHECK   NCFG, 3
        RDREG   %tc
        CHECK   SCR, 0x80C0AA00
        WRREG32 %tc, 0
        | Root pointers with a descriptor type of zero.
        lea     SCR, %a5
        move.l  #0x00000000, (%a5)
        move.l  #0x00001000, 4(%a5)
c_crp:  pmove   (%a5), %crp
c_crpn: CHECK   NCFG, 4
        CHECK   CFGPC, c_crpn
        CHECK   CFGIA, c_crp
        RDREG   %crp
        CHECK   SCR, 0x00000000          | "loaded with the new value before the exception"
        CHECK   SCR+4, 0x00001000
        WRRP    %srp, 0x7FFF0000, 0x00002000
        CHECK   NCFG, 5
        RDREG   %srp
        CHECK   SCR, 0x7FFF0000
        CHECK   SCR+4, 0x00002000
        | PMOVEFD is checked the same way.
        lea     SCR, %a5
        move.l  #0x80C08800, (%a5)
        pmovefd (%a5), %tc
        CHECK   NCFG, 6
        WRREG32 %tc, 0

| ===========================================================================
| Phases 3-15 -- PLOAD, PTEST level 0, PFLUSH, PMOVEFD. TC is loaded with E
| clear: "the MMU instructions (PTEST, PLOAD, PMOVE, PFLUSH) can be executed
| successfully, regardless of the state of the E bit" (UM 9.7.2). PS 4K, TIA
| 10, TIB 10, short descriptors; A[5] -> B, logical $014xxxxx.
| ===========================================================================
        PHASE   3
        WRREG32 %tc, 0x00C0AA00
        WRRP    %crp, 0x7FFF0002, tA
        WRRP    %srp, 0x7FFF0002, tA
        pflusha
        lea     0x01400000, %a0          | B[0]: $C000
        lea     0x01401000, %a1          | B[1]: $D000, write protected
        lea     0x01402000, %a2          | B[2]: invalid
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400              | I: not in the ATC

        PHASE   4
        ploadr  #5, (%a0)                | A[5] and B[0], each U written: 2 + 2
        PHASE   5
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0000              | resident, M clear
        CHECK   tA+20, tB + 2 + 8        | U set in A[5] ...
        CHECK   tB, 0x0000C009           | ... and in B[0]; PLOADR sets no M

        PHASE   6
        ploadw  #5, (%a1)                | A[5] (U set), B[1]: U and no M (WP)
        PHASE   7
        ptestr  #5, (%a1), #0
        bsr     mmusr
        CHECK   %d3, 0x0800              | W
        CHECK   tB+4, 0x0000D00D         | U, WP, no M: "except after a descriptor
                                         | with the WP bit set is encountered"
        PHASE   8
        ploadw  #1, (%a0)                | user data, B[0]: M written
        PHASE   9
        ptestr  #1, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200              | M
        CHECK   tB, 0x0000C019

        | PFLUSH by function code and mask -- PRM 6.
        pflush  #1, #7
        ptestr  #1, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0000
        pflush  #0, #4                   | FC2 = 0: function codes 0-3
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0000
        pflush  #4, #4                   | FC2 = 1: 4-7
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400

        | From here B[0]'s M bit is set in memory, and an entry loaded from it
        | has M set too: "M -- this bit is set if the ATC entry corresponding
        | to the specified address has the modified bit set" (Table 9-3).
        PHASE   10
        ploadr  #5, (%a0)
        ploadr  #5, (%a1)
        PHASE   11
        pflush  #5, #7, (%a1)            | that page only
        ptestr  #5, (%a1), #0
        bsr     mmusr
        CHECK   %d3, 0x0400
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        | The function code from a data register, SFC and DFC -- PRM 6.
        moveq   #5, %d4
        ptestr  %d4, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        movec   %d4, %sfc
        ptestr  %sfc, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        moveq   #1, %d4
        movec   %d4, %dfc
        ptestr  %dfc, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400
        pflusha
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400

        | PMOVEFD keeps the ATC; PMOVE flushes it, except into MMUSR -- UM
        | 9.7.5.1, 9.4.
        PHASE   12
        ploadr  #5, (%a0)
        PHASE   13
        lea     SCR, %a5
        clr.l   (%a5)
        pmovefd (%a5), %tt1
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        pmove   (%a5), %tt1
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400
        ploadr  #5, (%a0)
        RDREG   %crp
        pmovefd (%a5), %crp
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        pmove   (%a5), %crp
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400
        ploadr  #5, (%a0)
        RDREG   %srp
        pmovefd (%a5), %srp
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        RDREG   %tc
        pmovefd (%a5), %tc
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        pmove   (%a5), %tc
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400
        ploadr  #5, (%a0)
        clr.w   (%a5)
        pmove   (%a5), %psr
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0200
        | PTEST level 0 against TT1, reads only: PTESTR and PTESTW differ
        | there and nowhere else (UM 9.8). Logical $01xxxxxx, FC 5.
        WRREG32 %tt1, 0x01008250
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0040              | T
        ptestw  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400              | the PMOVE flushed it
        WRREG32 %tt1, 0

        | A search that ends at an invalid descriptor loads an entry with B.
        PHASE   14
        ploadr  #5, (%a2)                | A[5], B[2]: two reads, no write
        PHASE   15
        ptestr  #5, (%a2), #0
        bsr     mmusr
        CHECK   %d3, 0x8400              | B and I
        ptestr  #5, (%a2), #7, %a3       | the tables: I, two levels
        bsr     mmusr
        CHECK   %d3, 0x0402
        CHECK   %a3, tB + 8              | the invalid descriptor itself

| ===========================================================================
| Phases 20-35 -- transparent translation, UM 9.3 and 9.7.3. TC stays with E
| clear: TT0 and TT1 "operate independently of the E bit in the TC register".
| The testbench counts the cycles to the synchronous port ($3xxxxxxx), the
| ones with CIOUT, with CBREQ, and the instruction fetches.
| ===========================================================================
        WRREG32 %tc, 0
        pflusha
        PHASE   20                       | TT1: $30, supervisor data, CI
        WRREG32 %tt1, 0x30008550
        move.l  #0x1100, %d0             | ED DBE
        movec   %d0, %cacr
        move.l  0x3000C000, %d3
        move.l  0x3000C000, %d4          | not cached: the bus again, CIOUT
        PHASE   21
        CHECK   %d3, PAT3 + 0xC000
        CHECK   %d4, PAT3 + 0xC000
        PHASE   22                       | CI clear: a burst fill, then a hit
        WRREG32 %tt1, 0x30008150
        move.l  #0x1900, %d0             | ED DBE, and CD clears it
        movec   %d0, %cacr
        move.l  0x3000C010, %d3
        move.l  0x3000C010, %d4
        PHASE   23
        CHECK   %d4, PAT3 + 0xC010
        moveq   #0, %d0
        movec   %d0, %cacr
        PHASE   24                       | writes only: R/W 0, RWM 0
        WRREG32 %tt1, 0x30008450
        move.l  0x3000C020, %d3          | a read does not match: no CIOUT
        move.l  %d3, 0x3000C020          | a write does
        PHASE   25
        CHECK   %d3, PAT3 + 0xC020
        PHASE   26                       | reads, RWM clear: TAS does not match
        WRREG32 %tt1, 0x30008650
        tas     0x3000C030
        PHASE   27                       | RWM set: it does, both cycles
        WRREG32 %tt1, 0x30008750
        tas     0x3000C031
        PHASE   28
        CHECK   0x3000C030, PAT3 + 0xC030 + 0x80800000
        PHASE   29                       | FC base 1: user data only
        WRREG32 %tt1, 0x30008510
        move.l  0x3000C040, %d3          | supervisor data: no match
        moveq   #FC_UD, %d0
        movec   %d0, %sfc
        moves.l 0x3000C040, %d4          | user data: a match
        PHASE   30
        CHECK   %d4, PAT3 + 0xC040
        PHASE   31                       | both match: the CI bits ORed
        WRREG32 %tt1, 0x30008550
        WRREG32 %tt0, 0x00308143         | TT0 now $00-$30, no CI
        move.l  0x3000C000, %d3
        WRREG32 %tt0, TT0_SUP
        PHASE   32
        WRREG32 %tt1, 0x30008250         | reads, FC 5, no CI
        lea     0x3000C000, %a0
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0040
        ptestw  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0400
        WRREG32 %tt1, 0
        | The instruction cache, inhibited by TT0's CI: the loop is fetched
        | once with CI clear, and every time round with it set.
        PHASE   33
        moveq   #9, %d0                  | CI (clear it), EI
        movec   %d0, %cacr
        bsr     loop3
        WRREG32 %tt0, 0x00008543         | + CI
        PHASE   34
        moveq   #9, %d0
        movec   %d0, %cacr
        bsr     loop3
        PHASE   35
        WRREG32 %tt0, TT0_SUP
        moveq   #0, %d0
        movec   %d0, %cacr

| ===========================================================================
| Phases 40-44 -- MMUDIS, UM 9.2.3: no ATC lookup and no table search while
| it is asserted, logical addresses go out as they are, TT1 still applies,
| PLOAD still searches -- and the ATC is not flushed. The testbench asserts
| the pin at phase 42's marker and negates it at phase 43's.
| ===========================================================================
        PHASE   40
        WRRP    %crp, 0x7FFF0002, tA
        WRREG32 %tc, 0x80C0AA00          | translation on
        pflusha
        lea     0x01400000, %a0
        lea     0x01401000, %a1
        PHASE   41
        move.l  (%a0), %d3               | a search: A[5], B[0]
        PHASE   42
        bsr     delay
        move.l  (%a0), %d4               | $01400000 as it is: the vector table
        lea     SCR, %a5
        move.l  #0x30008550, (%a5)
        pmovefd (%a5), %tt1              | FD: the ATC kept
        move.l  0x3000C000, %d5          | TT1: CIOUT
        lea     SCR, %a5
        clr.l   (%a5)
        pmovefd (%a5), %tt1              | FD: the ATC kept
        ploadr  #5, (%a1)                | PLOAD searches anyway
        PHASE   43
        bsr     delay
        move.l  (%a0), %d6               | still in the ATC: no search
        PHASE   44
        CHECK   %d3, PATC + 0xC000
        CHECK   %d4, STACK               | vector 0
        CHECK   %d5, PAT3 + 0xC000
        CHECK   %d6, PATC + 0xC000
        ptestr  #5, (%a1), #0
        bsr     mmusr
        CHECK   %d3, 0x0800              | PLOADed under MMUDIS: W
        | Left for the testbench's RESET: TC and both TTs enabled, and an
        | entry in the ATC.
        lea     SCR, %a5
        move.l  #0x30008550, (%a5)
        pmovefd (%a5), %tt1
        ploadr  #5, (%a0)
        FINISH

| ---------------------------------------------------------------------------
mmusr:  lea     SCR, %a5
        pmove   %psr, (%a5)
        moveq   #0, %d3
        move.w  (%a5), %d3
        rts

delay:  moveq   #20, %d0
1:      dbf     %d0, 1b
        rts

        .balign 16
loop3:  moveq   #9, %d5
1:      add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        add.l   %d5, %d6
        dbf     %d5, 1b
        rts

| ---------------------------------------------------------------------------
| The tables: A at $9000 and B at $9100, short descriptors.
| ---------------------------------------------------------------------------
        .section .tables, "aw"
tA:     .long   0, 0, 0, 0, 0            | A[0-4] invalid
        .long   tB + 2                   | A[5] -> B, short
        .long   0, 0
        .balign 256
tB:     .long   0x0000C000 + 1           | B[0]: page $C000
        .long   0x0000D000 + 4 + 1       | B[1]: page $D000, WP
        .long   0                        | B[2]: invalid
        .long   0

        .section .pages, "aw"
        .set    pa, 0xC000
        .rept   64
        .long   PATC + pa
        .set    pa, pa + 4
        .endr
        .balign 0x1000
        .set    pa, 0xD000
        .rept   64
        .long   PATD + pa
        .set    pa, pa + 4
        .endr
