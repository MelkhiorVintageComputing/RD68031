| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- the MC68030's table search, UM 9.1, 9.5 and figures 9-25 to 9-29.
|
| Every search here is for a supervisor data read (or a PTEST, PLOAD or a
| MOVES in user data space) at a logical address outside TT0's $00xxxxxx, and
| reads its data from a page whose contents are known: the long word at
| physical $C0xx-$CFxx is PATC + its address, at $D0xx PATD + its address, and
| the few long words on the 16- and 8-bit ports are written first.
|
|   1     two levels, short descriptors, 4K pages; U, then M on a write
|   2-3   function code lookup and three levels of long descriptors, 256-byte
|         pages, IS 8; an invalid function code entry
|   4-5   four levels, PTEST at every level with an address register; PTEST
|         sets no U bit
|   6-7   five levels: FCL and TIA-TID
|   8     IS 7 and 32K pages: the ignored bits and the ATC's full compare
|   10    SRE: the supervisor through SRP, the user through CRP
|   12-17 early termination, short and long (with a limit on the next index),
|         and at the root pointer (with and without a limit)
|   18-21 indirect descriptors, short and long, and one to a table descriptor
|   --    limits: the root pointer's upper and lower, a long descriptor's
|   22-23 S and WP, and the history bits around a supervisor violation
|   24-27 tables on the 16-bit, 8-bit and synchronous ports
|   30-36 the ATC: 22 entries and the replacement of a 23rd
|   40-41 a page with CI: CIOUT, and the data cache inhibited

#include "mmu_common.inc"

        .equ    PATC,   0xAB000000
        .equ    PATD,   0xCD000000

        .text
main:
        | What is on the narrow ports: data, and the tables of phases 24-27.
        move.l  #0x16000004, 0x10000004
        move.l  #0x16000010, 0x10000010
        move.l  #0x16003010, 0x10003010
        move.l  #0x16005020, 0x10005020
        move.l  #0x16004040, 0x10004040
        move.l  #0x28002008, 0x20002008
        move.l  #0x20009100 + 2, 0x10009014     | A[5], 16-bit port -> 8-bit port
        move.l  #0x0000C000 + 1, 0x20009104     | B[1]: frame $C000
        move.l  #0x30009100 + 2, 0x30009014     | the same on the synchronous port
        move.l  #0x0000D000 + 1, 0x30009104     | ... frame $D000

| ===========================================================================
| Phase 1 -- PS 4K, TIA 10, TIB 10, short. UM 9.5.2: "the U bit in each
| descriptor that is encountered is checked and set if it is not already set.
| Similarly, when the table search is for a write access and the M bit of the
| page descriptor is clear, the processor sets the bit"; UM 9.4: a write to an
| entry whose M is clear searches again.
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, t1a
        WRREG32 %tc, 0x80C0AA00
        pflusha
        lea     0x01401004, %a0
        PHASE   1
        move.l  (%a0), %d3               | A[5] and B[1], both U written
        move.l  4(%a0), %d4              | the ATC
        move.l  #0x12345678, 12(%a0)     | M clear: B[1] again, M written
        move.l  12(%a0), %d5             | the ATC
        PHASE   51
        CHECK   %d3, PATC + 0xC004
        CHECK   %d4, PATC + 0xC008
        CHECK   %d5, 0x12345678
        CHECK   0x0000C010, 0x12345678
        CHECK   t1a+20, t1b + 2 + 8
        CHECK   t1b+4, 0x0000C019

| ===========================================================================
| Phases 2-3 -- FCL, PS 256, IS 8, TIA 8, TIB 8, long descriptors throughout.
| The root pointer's limit is zero, and ignored: UM 9.7.2, "when function code
| lookup is enabled ... the limit field of CRP or SRP is ignored".
| ===========================================================================
        WRRP    %crp, 0x00000003, t2f
        WRREG32 %tc, 0x81888800
        pflusha
        lea     0x05123454, %a0          | IS ignores $05; A $12, B $34
        PHASE   2
        move.l  (%a0), %d3               | FC5, A, B: six reads, three U writes
        PHASE   3
        CHECK   %d3, PATC + 0xC154
        CHECK   t2f+40, 0x7FFF000B
        CHECK   t2a+0x90, 0x7FFF000B
        CHECK   t2b+0x1A0, 0x7FFF0009
        ptestr  #FC_UD, (%a0), #7, %a1   | FC1's entry is invalid
        bsr     mmusr
        CHECK   %d3, 0x0401
        CHECK   %a1, t2f+8

| ===========================================================================
| Phases 4-5 -- four levels, PS 4K and four 5-bit indexes. PTEST at each
| level: MMUSR N "contains the actual number of tables accessed", and the
| address register "the physical address of the last descriptor successfully
| fetched" (PRM 6, UM Table 9-3). PTEST "alters neither the used or modified
| bits".
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, t3a
        WRREG32 %tc, 0x80C05555
        pflusha
        lea     0x08864008, %a0          | A 1, B 2, C 3, D 4
        PHASE   4
        move.l  (%a0), %d3
        PHASE   5
        CHECK   %d3, PATD + 0xD008
        ptestr  #5, (%a0), #1, %a1
        bsr     mmusr
        CHECK   %d3, 0x0001
        CHECK   %a1, t3a+4
        ptestr  #5, (%a0), #2, %a1
        bsr     mmusr
        CHECK   %d3, 0x0002
        CHECK   %a1, t3b+8
        ptestr  #5, (%a0), #3, %a1
        bsr     mmusr
        CHECK   %d3, 0x0003
        CHECK   %a1, t3c+12
        ptestr  #5, (%a0), #4, %a1
        bsr     mmusr
        CHECK   %d3, 0x0004
        CHECK   %a1, t3d+16
        ptestr  #5, (%a0), #7, %a1
        bsr     mmusr
        CHECK   %d3, 0x0004
        CHECK   %a1, t3d+16
        lea     0x1000(%a0), %a2         | D 5: its U bit is clear
        ptestw  #5, (%a2), #7, %a1
        bsr     mmusr
        CHECK   %d3, 0x0004
        CHECK   %a1, t3d+20
        CHECK   t3d+20, 0x0000D001       | and stays clear

| ===========================================================================
| Phases 6-7 -- five levels: FCL, then TIA-TID 6 bits each, PS 256.
| ===========================================================================
        WRRP    %crp, 0x00000002, t4f
        WRREG32 %tc, 0x81806666
        pflusha
        lea     0x04104110, %a0
        PHASE   6
        move.l  (%a0), %d3
        PHASE   7
        CHECK   %d3, PATC + 0xC210
        ptestr  #5, (%a0), #7, %a1
        bsr     mmusr
        CHECK   %d3, 0x0005
        CHECK   %a1, t4d+4

| ===========================================================================
| Phase 8 -- IS 7, PS 32K, TIA 10. "Since all 32 bits of the address are
| compared during address translation, bits ignored due to initial shift
| cannot have random values" (UM 9.7.2): two addresses differing only there
| are two ATC entries, and two searches, for the same page.
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, t5a
        WRREG32 %tc, 0x80F7A000
        pflusha
        PHASE   8
        move.l  0xFE008004, %d3
        move.l  0x02008004, %d4
        PHASE   52
        CHECK   %d3, 0x16000004
        CHECK   %d4, 0x16000004

| ===========================================================================
| Phase 10 -- SRE: UM Table 9-2, "the translation tree with its root defined
| by the SRP register is selected only when SRE and FC2 are both set".
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, t6u
        WRRP    %srp, 0x7FFF0002, t6s
        WRREG32 %tc, 0x82C0AA00
        pflusha
        lea     0x01401020, %a0
        moveq   #FC_UD, %d0
        movec   %d0, %sfc
        PHASE   10
        move.l  (%a0), %d3               | supervisor: SRP
        moves.l (%a0), %d4               | user: CRP
        WRREG32 %tc, 0x80C0AA00          | SRE clear
        move.l  (%a0), %d5               | supervisor: CRP now
        PHASE   11
        CHECK   %d3, PATD + 0xD020       | 4K pages: frame $D000, offset $020
        CHECK   %d4, PATC + 0xC020       | ... frame $C000
        CHECK   %d5, PATC + 0xC020

| ===========================================================================
| Phases 12-17 -- early termination, UM 9.5.3.1: "the physical address in the
| ATC entry is the sum of the page address field in the descriptor plus an
| offset. The offset is the logical address with the bits used in the search
| set to zero", and "the ATC contains one entry for each page mapped".
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, t7a
        pflusha
        PHASE   12
        move.l  0x01803010, %d3          | A 6: $1000_0000 + $3010
        move.l  0x01805020, %d4          | another page: another search
        PHASE   13
        CHECK   %d3, 0x16003010
        CHECK   %d4, 0x16005020
        CHECK   t7a+24, 0x10000009
        | Long, with an upper limit of 3 on the next index -- UM 9.5.1.1: "If
        | the descriptor is an early termination page descriptor, the limit
        | field is still used as a check on the next index field".
        WRRP    %crp, 0x7FFF0003, t7l
        pflusha
        PHASE   14
        move.l  0x01C02008, %d3          | A 7, B 2: within the limit
        PHASE   15
        CHECK   %d3, 0x28002008
        lea     0x01C05008, %a0          | B 5: out of it
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x4401              | L, I, one level
        lea     0x01C02008, %a0
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x0001
        | At the root -- UM 9.7.1, DT = 1: "adding (unsigned) the value in the
        | table address field to the incoming logical address".
        WRRP    %crp, 0x7FFF0001, 0x10000000
        pflusha
        PHASE   16
        move.l  0x01004040, %d3          | $1000_0000 + $0100_4040
        PHASE   17
        CHECK   %d3, 0x16004040
        | ... "the processor performs a limit check, regardless of the state of
        | the FCL bit". An upper limit of 3 on the A index.
        WRRP    %crp, 0x00030001, 0x10000000
        lea     0x01004040, %a0          | A 4
        ptestr  #5, (%a0), #7, %a1
        bsr     mmusr
        CHECK   %d3, 0x4400              | L, I, no table
        CHECK   %a1, 0                   | "If the root pointer's DT field
                                         | indicates page descriptor, the
                                         | returned address is $0"
        lea     0x00C04040, %a0          | A 3: PTEST searches whatever TT0 says
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x0000

| ===========================================================================
| Phases 18-21 -- indirect descriptors, UM 9.5.3.2.
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, t8a
        pflusha
        lea     0x02402010, %a0          | A 9, B 2: indirect
        PHASE   18
        move.l  (%a0), %d3               | A, the indirect descriptor, the page
        PHASE   19
        CHECK   %d3, PATD + 0xD010
        CHECK   t8b+8, t8p + 2           | no U: an indirect descriptor has none
        CHECK   t8p, 0x0000D009
        ptestr  #5, (%a0), #7, %a1
        bsr     mmusr
        CHECK   %d3, 0x0003              | three tables accessed
        CHECK   %a1, t8p
        lea     0x02403010, %a2          | B 3: indirect to a table descriptor
        ptestr  #5, (%a2), #7, %a1
        bsr     mmusr
        CHECK   %d3, 0x0403              | "treated as invalid"
        CHECK   %a1, t8q
        CHECK   t8q, t8b + 2             | ... and not modified
        WRRP    %crp, 0x7FFF0003, t8l
        pflusha
        PHASE   20
        move.l  (%a0), %d4               | long: A, indirect, page, two words each
        PHASE   21
        CHECK   %d4, 0x16000010
        CHECK   t8lp, 0x7FFF0009
        CHECK   t8lb+16, 0x7FFF0003      | the long indirect descriptor: untouched

| ===========================================================================
| Limits -- UM 9.5.2: "When the L/U bit is set, the limit is a lower limit,
| and an index less than the limit is out of bounds. When the L/U bit is zero,
| the limit is an upper limit, and an index greater than the limit is out of
| bounds."
| ===========================================================================
        WRRP    %crp, 0x00090002, t9a    | upper limit 9 on A
        pflusha
        lea     0x02800000, %a0          | A 10
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x4400
        lea     0x02400000, %a0          | A 9
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x0002
        WRRP    %crp, 0x80090002, t9a    | lower limit 9
        lea     0x02000000, %a0          | A 8
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x4400
        lea     0x02400000, %a0
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x0002
        WRRP    %crp, 0x7FFF0003, t9l    | a long table descriptor: B <= 1
        lea     0x02402000, %a0          | B 2
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x4401
        lea     0x02401000, %a0          | B 1
        ptestr  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x0002

| ===========================================================================
| Phases 22-23 -- S and WP in a long table descriptor. PTEST's S is "set if
| the S bit of a long ... descriptor encountered during the search is set,
| and the FC2 bit of the function code specified by the PTEST instruction is
| not equal to one" (UM Table 9-3). U "is automatically set ... except after a
| supervisor violation is detected" (UM 9.5.1.1), and a user search ends with
| B in the ATC entry (UM 9.5.5.3).
| ===========================================================================
        WRRP    %crp, 0x7FFF0003, tal
        pflusha
        lea     0x02401000, %a0
        ptestw  #5, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x0802              | W
        ptestw  #FC_UD, (%a0), #7
        bsr     mmusr
        CHECK   %d3, 0x2802              | S and W
        PHASE   22
        ploadr  #FC_UD, (%a0)            | a supervisor violation: no U written
        PHASE   23
        CHECK   tal+72, 0x7FFF0106
        CHECK   talb+4, 0x0000C801
        ptestr  #FC_UD, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x8400              | B
        ploadw  #5, (%a0)                | supervisor: U in both, no M (WP)
        CHECK   tal+72, 0x7FFF010E
        CHECK   talb+4, 0x0000C809
        ptestr  #5, (%a0), #0
        bsr     mmusr
        CHECK   %d3, 0x0800

| ===========================================================================
| Phases 24-27 -- tables on narrow and synchronous ports: the search's
| long-word reads and U writes are sized dynamically like any operand
| (UM 7.2), and never burst (UM 7.3.3).
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, 0x10009000
        pflusha
        PHASE   24
        move.l  0x01401000, %d3          | A on the 16-bit port, B on the 8-bit
        PHASE   25
        CHECK   %d3, PATC + 0xC000
        WRRP    %crp, 0x7FFF0002, 0x30009000
        pflusha
        PHASE   26
        move.l  0x01401000, %d4          | both on the synchronous port
        PHASE   27
        CHECK   %d4, PATD + 0xD000
        WRREG32 %tc, 0
        CHECK   0x10009014, 0x2000910A
        CHECK   0x20009104, 0x0000C009
        CHECK   0x30009014, 0x3000910A
        WRREG32 %tc, 0x80C0AA00

| ===========================================================================
| Phases 30-36 -- the ATC, UM 9.4: 22 entries, "when all entries in the ATC
| are valid, the ATC selects a valid entry to be replaced, using a pseudo
| least recently used algorithm ... a validity bit and an internal history
| bit" -- rd68031_mmu's, doc/mmu.md. One level, 256-byte pages, every
| descriptor's U already set, so each search is one read.
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, tra
        WRREG32 %tc, 0x8089F000          | PS 8, IS 9, TIA 15
        pflusha
        PHASE   30
        bsr     pages22                  | 22 searches
        PHASE   31
        bsr     pages22                  | all 22 resident
        PHASE   32
        move.l  0xFF801600, %d3          | page 22: replaces one
        PHASE   33
        move.l  0xFF801500, %d3          | 21 and 20 stay
        move.l  0xFF801400, %d3
        PHASE   34
        move.l  0xFF800000, %d3          | 0 was replaced
        PHASE   35
        move.l  0xFF800200, %d3          | 2 stays, 1 was replaced
        move.l  0xFF800100, %d3
        PHASE   36
        move.l  0xFF800300, %d3          | and 3
        PHASE   37
        CHECK   %d3, PATD + 0xD000

| ===========================================================================
| Phases 40-41 -- a page descriptor with CI: CIOUT on its cycles, and the
| data cache not filled from it (UM 6.1, 9.5.1.1).
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, tci
        WRREG32 %tc, 0x80C0AA00
        pflusha
        move.l  #0x0100, %d0             | ED
        movec   %d0, %cacr
        PHASE   40
        move.l  0x01401B00, %d3          | CI: the bus both times, CIOUT
        move.l  0x01401B00, %d4
        move.l  0x01402C00, %d5          | not CI: filled, then a hit
        move.l  0x01402C00, %d6
        PHASE   41
        moveq   #0, %d0
        movec   %d0, %cacr
        CHECK   %d3, PATC + 0xCB00
        CHECK   %d4, PATC + 0xCB00
        CHECK   %d6, PATC + 0xCC00

| ===========================================================================
| Phase 45 -- the page sizes the other phases do not use, 512 bytes to 16K:
| one level, TIA 15 and IS the rest (UM 9.1.1, Table 9-1). Logical $E000_0000
| is in the IS bits whatever the page size, so the index is 1; the frame is
| $C000, and the offset within the page passes through.
| ===========================================================================
        WRRP    %crp, 0x7FFF0002, tps
        PHASE   45
        moveq   #0, %d7                  | the page sizes that read right
        moveq   #9, %d6                  | PS
1:      moveq   #17, %d0                 | IS = 32 - PS - 15
        sub.l   %d6, %d0
        move.l  %d6, %d1
        swap    %d1
        lsl.l   #4, %d1                  | PS << 20
        swap    %d0                      | IS << 16
        or.l    %d0, %d1
        or.l    #0x8000F000, %d1         | E, TIA 15
        lea     SCR, %a5
        move.l  %d1, (%a5)
        pmove   (%a5), %tc
        moveq   #1, %d0
        lsl.l   %d6, %d0                 | one page up: index 1
        add.l   #0xE0000020, %d0
        move.l  %d0, %a0
        move.l  (%a0), %d3
        cmp.l   #PATC + 0xC020, %d3
        bne.s   2f
        addq.l  #1, %d7
2:      addq.l  #1, %d6
        cmp.l   #15, %d6
        bne     1b
        PHASE   46
        CHECK   %d7, 6
        CHECK   NCFG, 0                  | every one of them consistent

        WRREG32 %tc, 0
        FINISH

| ---------------------------------------------------------------------------
mmusr:  lea     SCR, %a5
        pmove   %psr, (%a5)
        moveq   #0, %d3
        move.w  (%a5), %d3
        rts

pages22:
        move.l  #0xFF800000, %d6
        moveq   #21, %d5
1:      move.l  %d6, %a0
        move.l  (%a0), %d3
        add.l   #0x100, %d6
        dbf     %d5, 1b
        rts

| ---------------------------------------------------------------------------
| The tables, from $9000.
| ---------------------------------------------------------------------------
        .section .tables, "aw"
t1a:    .long   0, 0, 0, 0, 0, t1b + 2, 0, 0
        .org    0x040
t1b:    .long   0, 0x0000C001, 0, 0
        .org    0x100
t2f:    .long   0, 0                     | FC0
        .long   0, 0                     | FC1: invalid
        .long   0, 0, 0, 0, 0, 0         | FC2-4
        .long   0x7FFF0003, t2a          | FC5 -> A, long
        .long   0, 0, 0, 0
        .org    0x200
t2a:    .fill   0x12 * 2, 4, 0
        .long   0x7FFF0003, t2b          | A[$12] -> B, long
        .org    0x300
t2b:    .fill   0x34 * 2, 4, 0
        .long   0x7FFF0001, 0x0000C100   | B[$34]: page $C100
        .org    0x600
t3a:    .long   0, t3b + 2, 0, 0
        .org    0x640
t3b:    .long   0, 0, t3c + 2, 0
        .org    0x680
t3c:    .long   0, 0, 0, t3d + 2
        .org    0x6C0
t3d:    .long   0, 0, 0, 0, 0x0000D001, 0x0000D001, 0, 0
        .org    0x800
t4f:    .long   0, 0, 0, 0, 0, t4a + 2, 0, 0
        .org    0x840
t4a:    .long   0, t4b + 2, 0, 0
        .org    0x880
t4b:    .long   0, t4c + 2, 0, 0
        .org    0x8C0
t4c:    .long   0, t4d + 2, 0, 0
        .org    0x900
t4d:    .long   0, 0x0000C201, 0, 0
        .org    0xA00
t5a:    .long   0, 0x10000001            | A[1]: the 16-bit port's first 32K
        .org    0xB00
t6u:    .long   0, 0, 0, 0, 0, t6ub + 2, 0, 0
        .org    0xB40
t6ub:   .long   0, 0x0000C001, 0, 0
        .org    0xC00
t6s:    .long   0, 0, 0, 0, 0, t6sb + 2, 0, 0
        .org    0xC40
t6sb:   .long   0, 0x0000D001, 0, 0
        .org    0xD00
t7a:    .long   0, 0, 0, 0, 0, 0, 0x10000001, 0   | A[6]: early termination
        .org    0xD40
t7l:    .fill   14, 4, 0
        .long   0x00030001, 0x20000000   | A[7]: long ET, B <= 3
        .org    0xE00
t8a:    .fill   9, 4, 0
        .long   t8b + 2                  | A[9]
        .org    0xE40
t8b:    .long   0, 0, t8p + 2, t8q + 2   | B[2] -> a page, B[3] -> a table
        .org    0xE80
t8p:    .long   0x0000D001
t8q:    .long   t8b + 2
        .org    0xF00
t8l:    .fill   18, 4, 0
        .long   0x7FFF0003, t8lb         | A[9]
        .org    0xF80
t8lb:   .fill   4, 4, 0
        .long   0x7FFF0003, t8lp         | B[2]: indirect, to a long page
        .org    0xFC0
t8lp:   .long   0x7FFF0001, 0x10000000
        .org    0x1000
t9a:    .fill   8, 4, 0
        .long   t9b + 2, t9b + 2, t9b + 2   | A[8], A[9], A[10]
        .org    0x1040
t9b:    .long   0x0000C701, 0x0000C701, 0x0000C701, 0
        .org    0x1080
t9l:    .fill   18, 4, 0
        .long   0x00010002, t9lb         | A[9]: B <= 1, short
        .org    0x1100
t9lb:   .long   0x0000C701, 0x0000C701, 0x0000C701, 0
        .org    0x1200
tal:    .fill   18, 4, 0
        .long   0x7FFF0106, talb         | A[9]: S, WP
        .org    0x1280
talb:   .long   0, 0x0000C801, 0, 0
        .org    0x1800
tra:    .rept   32
        .long   0x0000D009               | page $D000, U set
        .endr
        .org    0x1900
tci:    .long   0, 0, 0, 0, 0, tcib + 2, 0, 0
        .org    0x1940
tcib:   .long   0, 0x0000C041, 0x0000C001, 0     | B[1] CI, B[2] not
        .org    0x1A00
tps:    .long   0, 0x0000C001, 0, 0              | A[1]: frame $C000, U set by the first

        .section .pages, "aw"
        .set    pa, 0xC000
        .rept   1024
        .long   PATC + pa
        .set    pa, pa + 4
        .endr
        .set    pa, 0xD000
        .rept   64
        .long   PATD + pa
        .set    pa, pa + 4
        .endr
