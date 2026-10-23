| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- a coprocessor's memory operand through the MMU, faulting.
|
| A general coprocessor instruction with a memory operand moves it a long word
| at a time between memory and the operand CIR (UM 10.4); a page fault on one
| of those long words is a bus error in the middle of the instruction, a long
| bus fault frame (UM 8.2), and RTE goes on from where the transfer stopped:
| the faulted cycle rerun, the rest of the operand moved, no long word sent to
| the coprocessor twice or not at all. An operating system meets it at every
| copy-on-write fault on a user stack that libm's `fmoved fp0,sp@-` hits after
| fork, and may switch the FPU to another process before it returns.
|
| Run by core_fpu_mmu_tb, with RD68884 as the MC68881 (sim/mame/rd68031_fpu.sv).
| The results with no fault are the references; each test repeats one with a
| fault, and must give the same bits. The whole set runs twice: the hook only
| repairs the page and returns, then it also switches the FPU's context as
| NetBSD's cpu_switchto does -- FSAVE, FMOVEM out, a null FRESTORE, other FPU
| work, FSAVE, FMOVEM in, FRESTORE -- before it returns.
|
|   1   FETOX.D (A0),FP0, the first long word in an invalid page
|   2   ... the operand across a page boundary, the second page invalid
|   3   FLOGN.D, across, the second invalid
|   4   FMOD.D, across, the second invalid
|   5   FMOD.D, the first long word invalid
|   6   FLOGN.D, the first long word invalid
|   7   FMOVE.D FP0,(A0), the first long word in an invalid page
|   8   ... in a write-protected page (copy-on-write)
|   9   ... across a page boundary, the second page write-protected
|  10   ... across, the second page invalid
|  11   user mode, libm's way: FETOX.D 4(SP),FP0; FMOVE.D FP0,-(SP), the
|       stack page write-protected: the store's first long word faults
|  12   ... the store across a page boundary, its second long word in a
|       write-protected page
|  13   ... the operand read across a page boundary, the second page invalid
|  14   ... the operand read's first long word in an invalid page
|
| PS 256, TIA 12, TIB 12, short descriptors: logical $0100_bb00 is A[16], B[bb],
| and B[bb] maps $C000 + $100 * bb unless the test says otherwise. The
| supervisor's code, stack and results are TT0's.

#include "mmu_common.inc"

        .equ    TCF,    0x8080CC00      | E, PS 8, TIA 12, TIB 12
        .equ    FIXA,   0x8060          | where the hook writes FIXV
        .equ    FIXV,   0x8064
        .equ    ENT,    0x8068          | hook entries, this test
        .equ    CTX,    0x806C          | nonzero: the hook switches the FPU
        .equ    NBUSY,  0x8070          | busy frames the switch saved
        .equ    NFS,    0x8074          | FSAVEs the switch made
        .equ    LASTFR, 0x8078          | the last frame's format long word
        .equ    LSSW,   0x807C          | the last fault's SSW
        .equ    LFV,    0x8080          | ... and format/vector
        .equ    NIDLE,  0x8084          | idle frames the switch saved
        .equ    NNULL,  0x8088          | null frames
        .equ    FBUFA,  0x8A00          | the interrupted context's frame
        .equ    FBUFB,  0x8B00          | the other context's
        .equ    FREGA,  0x8C00          | FP0-FP7, 96 bytes
        .equ    FCTLA,  0x8C60          | FPCR/FPSR/FPIAR
        .equ    JUNK,   0x8C80          | the other context's FP0-FP7
        .equ    NULLF,  0x8CF0          | a null frame
        .equ    RES,    0x8D00          | a result, read back
        .equ    REFE,   0x8D10          | the references: FETOX
        .equ    REFL,   0x8D18          | ... FLOGN
        .equ    REFM,   0x8D20          | ... FMOD
        .equ    CACRV,  0x808C          | the CACR to run with: the testbench's
        .equ    UPC,    0x01001800      | the user's code, B[24]

| A check of a long word against another in memory. Clobbers D0-D2.
        .macro  CHECKM got, want
        .set    cid, cid + 1
        move.l  \got, %d0
        move.l  \want, %d1
        move.w  #cid, %d2
        jsr     check
        .endm

| ... a double, both long words.
        .macro  CHECKD got, want
        CHECKM  \got, \want
        CHECKM  \got+4, \want+4
        .endm

| A double from src to the physical address dst.
        .macro  PUT dst, src
        move.l  \src, \dst
        move.l  \src+4, \dst+4
        .endm

| A test begins: the descriptor at desc set to init, what the hook writes there.
        .macro  ARM desc, init, fix
        clr.l   ENT
        move.l  #\init, \desc
        move.l  #\desc, FIXA
        move.l  #\fix, FIXV
        pflusha
        .endm

| A user-mode test: USP, then into the user's code; TRAP #0 comes back to 1:.
        .macro  USER usp
        lea     \usp, %a0
        move.l  %a0, %usp
        lea     1f, %a0
        move.l  %a0, TRAPH
        clr.w   -(%sp)                  | format 0
        move.l  #UPC, -(%sp)
        clr.w   -(%sp)                  | user mode
        rte
1:      addq.l  #8, %sp                 | the TRAP's four-word frame
        lea     trap_rte, %a0
        move.l  %a0, TRAPH
        .endm

        .text
| The tests, before main: the count at its end is of the checks assembled above it.
tests:
| 1 -- FETOX.D, the first long word in B[3], invalid.
        PUT     0xC310, XE
        ARM     tfb + 3*4, 0, 0xC301
        clr.l   RES
        clr.l   RES+4
        lea     0x01000310, %a0
        fmove.d #0r0.5, %fp0
        fetox.d (%a0), %fp0
        fmove.d %fp0, RES
        CHECKD  RES, REFE
        CHECK   ENT, 1

| 2 -- across B[4] (valid) and B[5] (invalid).
        PUT     0xC4FC, XE
        ARM     tfb + 5*4, 0, 0xC501
        lea     0x010004FC, %a0
        fmove.d #0r0.5, %fp0
        fetox.d (%a0), %fp0
        fmove.d %fp0, RES
        CHECKD  RES, REFE
        CHECK   ENT, 1

| 3 -- FLOGN.D across B[6] and B[7] (invalid).
        PUT     0xC6FC, XL
        ARM     tfb + 7*4, 0, 0xC701
        lea     0x010006FC, %a0
        fmove.d #0r0.5, %fp0
        flogn.d (%a0), %fp0
        fmove.d %fp0, RES
        CHECKD  RES, REFL
        CHECK   ENT, 1

| 4 -- FMOD.D across B[8] and B[9] (invalid).
        PUT     0xC8FC, XM
        ARM     tfb + 9*4, 0, 0xC901
        lea     0x010008FC, %a0
        fmove.d DM, %fp1
        fmod.d  (%a0), %fp1
        fmove.d %fp1, RES
        CHECKD  RES, REFM
        CHECK   ENT, 1

| 5 -- FMOD.D, the first long word in B[11], invalid.
        PUT     0xCB20, XM
        ARM     tfb + 11*4, 0, 0xCB01
        lea     0x01000B20, %a0
        fmove.d DM, %fp1
        fmod.d  (%a0), %fp1
        fmove.d %fp1, RES
        CHECKD  RES, REFM
        CHECK   ENT, 1

| 6 -- FLOGN.D, the first long word in B[10], invalid.
        PUT     0xCA40, XL
        ARM     tfb + 10*4, 0, 0xCA01
        lea     0x01000A40, %a0
        fmove.d #0r0.5, %fp0
        flogn.d (%a0), %fp0
        fmove.d %fp0, RES
        CHECKD  RES, REFL
        CHECK   ENT, 1

| 7 -- FMOVE.D FP0,(A0), the first long word in B[13], invalid.
        clr.l   0xCD10
        clr.l   0xCD14
        ARM     tfb + 13*4, 0, 0xCD01
        lea     0x01000D10, %a0
        fetox.d XE, %fp0
        fmove.d %fp0, (%a0)
        CHECKD  0xCD10, REFE
        CHECK   ENT, 1

| 8 -- ... in B[15], write-protected.
        clr.l   0xCF10
        clr.l   0xCF14
        ARM     tfb + 15*4, 0xCF05, 0xCF01
        lea     0x01000F10, %a0
        fetox.d XE, %fp0
        fmove.d %fp0, (%a0)
        CHECKD  0xCF10, REFE
        CHECK   ENT, 1

| 9 -- ... across B[16] and B[17], write-protected.
        clr.l   0xD0FC
        clr.l   0xD100
        ARM     tfb + 17*4, 0xD105, 0xD101
        lea     0x010010FC, %a0
        fetox.d XE, %fp0
        fmove.d %fp0, (%a0)
        CHECKD  0xD0FC, REFE
        CHECK   ENT, 1

| 10 -- ... across B[18] and B[19], invalid.
        clr.l   0xD2FC
        clr.l   0xD300
        ARM     tfb + 19*4, 0, 0xD301
        lea     0x010012FC, %a0
        fetox.d XE, %fp0
        fmove.d %fp0, (%a0)
        CHECKD  0xD2FC, REFE
        CHECK   ENT, 1

| 11 -- user mode: the stack in B[21], write-protected; the operand at 4(SP)
| reads, the result's store at -(SP) faults on its first long word.
        PUT     0xD584, XE
        clr.l   0xD578
        clr.l   0xD57C
        ARM     tfb + 21*4, 0xD505, 0xD501
        fmove.d #0r0.5, %fp0
        USER    0x01001580
        fmove.d %fp0, RES
        CHECKD  RES, REFE
        CHECKD  0xD578, REFE
        CHECK   ENT, 1

| 12 -- the stack at the bottom of B[23], write-protected; B[22] below it
| valid: the store's second long word faults.
        PUT     0xD708, XE
        clr.l   0xD6FC
        clr.l   0xD700
        ARM     tfb + 23*4, 0xD705, 0xD701
        fmove.d #0r0.5, %fp0
        USER    0x01001704
        fmove.d %fp0, RES
        CHECKD  RES, REFE
        CHECKD  0xD6FC, REFE
        CHECK   ENT, 1

| 13 -- the operand at 4(SP) across B[25] and B[26], invalid.
        PUT     0xD9FC, XE
        clr.l   0xD9F0
        clr.l   0xD9F4
        ARM     tfb + 26*4, 0, 0xDA01
        fmove.d #0r0.5, %fp0
        USER    0x010019F8
        fmove.d %fp0, RES
        CHECKD  RES, REFE
        CHECKD  0xD9F0, REFE
        CHECK   ENT, 1

| 14 -- the stack in B[28], invalid: the operand's first long word faults.
        PUT     0xDC44, XE
        clr.l   0xDC38
        clr.l   0xDC3C
        ARM     tfb + 28*4, 0, 0xDC01
        fmove.d #0r0.5, %fp0
        USER    0x01001C40
        fmove.d %fp0, RES
        CHECKD  RES, REFE
        CHECKD  0xDC38, REFE
        CHECK   ENT, 1
        rts

main:
        move.l  CACRV, %d0
        movec   %d0, %cacr
        clr.l   NULLF
        clr.l   CTX
        clr.l   NBUSY
        clr.l   NIDLE
        clr.l   NNULL
        clr.l   NFS
        lea     JUNK, %a0               | the other context's registers: 1.0 ... 8.0
        moveq   #7, %d3
        fmove.d #0r1.0, %fp0
1:      fmove.x %fp0, (%a0)
        fadd.d  #0r1.0, %fp0
        lea     12(%a0), %a0
        dbra    %d3, 1b

| The references, untranslated and unfaulted.
        fetox.d XE, %fp0
        fmove.d %fp0, REFE
        flogn.d XL, %fp0
        fmove.d %fp0, REFL
        fmove.d DM, %fp1
        fmod.d  XM, %fp1
        fmove.d %fp1, REFM

        WRRP    %crp, 0x7FFF0002, tfa
        WRREG32 %tc, TCF
        pflusha
        lea     hook_fix, %a0
        move.l  %a0, BERRH

        PHASE   1
        bsr     tests                   | the hook repairs and returns
        PHASE   2
        move.l  #1, CTX
        bsr     tests                   | ... and switches the FPU first
        PHASE   3
        WRREG32 %tc, 0
        pflusha
        move.l  #2*cid, NCHKX           | FINISH, for tests run twice
        jmp     finish

| ---------------------------------------------------------------------------
| The hook: repair the page, flush the ATC, perhaps switch the FPU, return
| with the frame as it is, so that RTE reruns the faulted cycle.
| ---------------------------------------------------------------------------
hook_fix:
        movem.l %d0/%a0, -(%sp)
        addq.l  #1, ENT
        lea     8(%sp), %a0             | the frame
        move.w  10(%a0), LSSW+2
        move.w  6(%a0), LFV+2
        move.l  FIXA, %a0
        move.l  FIXV, (%a0)
        pflusha
        tst.l   CTX
        beq.s   1f
        bsr.s   ctxsw
1:      movem.l (%sp)+, %d0/%a0
        rte

| NetBSD's: FSAVE; if the frame is not null, FMOVEM out. The other context
| (a null FRESTORE, some work, its FSAVE); then FMOVEM in if not null, and
| FRESTORE. Clobbers D0.
ctxsw:
        fsave   FBUFA
        addq.l  #1, NFS
        move.l  FBUFA, %d0
        move.l  %d0, LASTFR
        bne.s   1f
        addq.l  #1, NNULL
        bra.s   3f
1:      swap    %d0
        cmp.b   #0x18, %d0              | the 68881's idle frame
        bne.s   2f
        addq.l  #1, NIDLE
        bra.s   4f
2:      addq.l  #1, NBUSY
4:      fmovem.x %fp0-%fp7, FREGA
        fmovem.l %fpcr/%fpsr/%fpiar, FCTLA
3:      frestore NULLF
        fmovem.x JUNK, %fp0-%fp7
        fmove.d #0r1.25, %fp0
        fetox.x %fp0
        flogn.x %fp0
        fmove.d #0r7.5, %fp1
        fmod.x  %fp0, %fp1
        fsin.x  %fp1
        fsave   FBUFB
        tst.l   FBUFA
        beq.s   5f
        fmovem.l FCTLA, %fpcr/%fpsr/%fpiar
        fmovem.x FREGA, %fp0-%fp7
5:      frestore FBUFA
        rts

| The operands.
        .balign 4
XE:     .long   0x40160A62, 0x23E18698  | 0x1.60a6223e18698p+2: libm's exp input
XL:     .long   0x400AA973, 0x96D0917D  | 0x1.aa97396d0917dp+1
XM:     .long   0x400D9999, 0x9999999A  | 3.7
DM:     .long   0x40C81CD6, 0xC8B43958  | 12345.678 or so

| ---------------------------------------------------------------------------
| The user's code, on a page of its own: libm's exp(), then back.
| ---------------------------------------------------------------------------
        .balign 256
ucode:  fetox.d 4(%sp), %fp0
        fmove.d %fp0, -(%sp)
        trap    #0

| ---------------------------------------------------------------------------
| The tables.
| ---------------------------------------------------------------------------
        .section .tables, "aw"
tfa:    .fill   16, 4, 0
        .long   tfb + 2                 | A[16]
        .fill   15, 4, 0
        .org    0x100
tfb:    .long   0xC001, 0xC101, 0xC201
        .long   0                       | B[3]: test 1
        .long   0xC401                  | B[4]
        .long   0                       | B[5]: test 2
        .long   0xC601                  | B[6]
        .long   0                       | B[7]: test 3
        .long   0xC801                  | B[8]
        .long   0                       | B[9]: test 4
        .long   0                       | B[10]: test 6
        .long   0                       | B[11]: test 5
        .long   0xCC01
        .long   0                       | B[13]: test 7
        .long   0xCE01
        .long   0                       | B[15]: test 8
        .long   0xD001                  | B[16]
        .long   0                       | B[17]: test 9
        .long   0xD201                  | B[18]
        .long   0                       | B[19]: test 10
        .long   0xD401
        .long   0                       | B[21]: test 11
        .long   0xD601                  | B[22]
        .long   0                       | B[23]: test 12
        .long   ucode + 1               | B[24]: the user's code
        .long   0xD901                  | B[25]
        .long   0                       | B[26]: test 13
        .long   0xDB01
        .long   0                       | B[28]: test 14
        .fill   35, 4, 0
