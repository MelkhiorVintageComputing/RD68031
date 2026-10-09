| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- what every MMU test program (sim/programs/mmu_*.S) shares.
|
| The memory map of sim/tb/rd68031_core_harness.svh: a 64 KB 32-bit port at
| $0000_0000 (repeated through $0FFF_FFFF), a 16-bit port at $1000_0000, an
| 8-bit port at $2000_0000 and a synchronous burst port at $3000_0000, each
| 64 KB; core_mmu_tb makes $4000_0000-$4FFF_FFFF answer every cycle with BERR.
|
|   $0000  vectors            $9000-$BFFF  translation tables (any port)
|   $1000  code               $C000-$DFFF  the pages they map to
|   $8000  results, below     $E000-$EFFF  user stack and scratch
|                             $F000        the supervisor stack, growing down
|
| The supervisor runs untranslated through TT0, which every program loads
| first: logical $00xxxxxx, supervisor spaces, reads and writes, so that the
| code, the stack, the vectors and the results stay where they are whatever
| the tables say. What a test translates is at logical addresses outside
| $00xxxxxx, or in a user space.
|
| Every program checks itself: CHECK compares a value with what it should be
| and logs the ones that are not, and core_mmu_tb prints the log, insists it is
| empty, and checks what a program cannot see -- the bus cycles of each phase,
| opened by a write of its number to MARK.

        .equ    MARK,    0x8000         | phase marker: the testbench watches it
        .equ    NCHK,    0x8004         | checks made
        .equ    NFAIL,   0x8008         | ... and failed
        .equ    LOGP,    0x800C         | the failure log pointer
        .equ    DONE,    0x8010         | $600DD00E when the program finished
        .equ    BERRH,   0x8014         | the bus error hook in use
        .equ    NEXC,    0x8018         | exceptions nobody expected
        .equ    LASTV,   0x801C         | ... the last one's format/vector
        .equ    NBERR,   0x8020         | bus errors taken
        .equ    NCFG,    0x8024         | MMU configuration exceptions taken
        .equ    CFGFV,   0x8028         | the last one: format/vector word
        .equ    CFGPC,   0x802C         | ... its stacked program counter
        .equ    CFGIA,   0x8030         | ... and +$08, the PMOVE's address
        .equ    FSSW,    0x8034         | the last bus error: its SSW
        .equ    FADDR,   0x8038         | ... its fault address, +$10
        .equ    FFV,     0x803C         | ... its format/vector word
        .equ    FPC,     0x8040         | ... its stacked PC
        .equ    FSTB,    0x8044         | ... its stage B address, +$24
        .equ    FMMUSR,  0x8048         | ... and what the hook's PTEST said
        .equ    FDA,     0x804C         | ... and the descriptor address
        .equ    NTRAP,   0x8050         | TRAP #0s taken
        .equ    NCHKX,   0x8058         | the checks the program has, at its end
        .equ    TRAPH,   0x805C         | the TRAP #0 hook in use
        .equ    LOG,     0x8100         | failures: id.w, got.l, want.l
        .equ    SCR,     0x8800         | PMOVE operands and results
        .equ    STACK,   0xF000
        .equ    USTACK,  0xEF00

        .equ    TT0_SUP, 0x00008143     | $00xxxxxx, FC 4-7, R and W
        .equ    FC_UD,   1
        .equ    FC_UP,   2
        .equ    FC_SD,   5
        .equ    FC_SP,   6

| A check. Clobbers D0-D2.
        .set    cid, 0
        .macro  CHECK got, want
        .set    cid, cid + 1
        move.l  \got, %d0
        move.l  #\want, %d1
        move.w  #cid, %d2
        jsr     check
        .endm

| The end of a program: how many checks it has, so that the testbench can tell
| one that stopped early from one that passed.
        .macro  FINISH
        move.l  #cid, NCHKX
        jmp     finish
        .endm

| A phase of the bus traffic the testbench counts.
        .macro  PHASE n
        move.l  #\n, MARK
        .endm

| A register into SCR, so it can be checked: PMOVE takes no Dn (PRM 6).
        .macro  RDREG reg
        lea     SCR, %a5
        pmove   \reg, (%a5)
        .endm

| An immediate into an MMU register, through SCR.
        .macro  WRREG32 reg, val
        lea     SCR, %a5
        move.l  #\val, (%a5)
        pmove   (%a5), \reg
        .endm

        .macro  WRRP reg, hi, lo
        lea     SCR, %a5
        move.l  #\hi, (%a5)
        move.l  #\lo, 4(%a5)
        pmove   (%a5), \reg
        .endm

        .section .vectors, "a"
        .long   STACK                   | 0: the initial interrupt stack pointer
        .long   _start                  | 1: the initial program counter
        .long   berr_entry              | 2: bus error
        .rept   29
        .long   unexpected              | 3-31
        .endr
        .long   trap0                   | 32: TRAP #0
        .rept   23
        .long   unexpected              | 33-55
        .endr
        .long   cfg_entry               | 56: MMU configuration
        .rept   199
        .long   unexpected              | 57-255
        .endr

        .text
        .globl  _start
_start:
        move.l  #STACK, %sp
        moveq   #0, %d0
        move.l  %d0, NCHK
        move.l  %d0, NFAIL
        move.l  %d0, NEXC
        move.l  %d0, NBERR
        move.l  %d0, NCFG
        move.l  %d0, NTRAP
        move.l  %d0, DONE
        move.l  %d0, NCHKX
        move.l  #LOG, LOGP
        lea     berr_none, %a0
        move.l  %a0, BERRH
        lea     trap_rte, %a0
        move.l  %a0, TRAPH
        movec   %d0, %cacr              | caches off unless a test says so
        WRREG32 %tt0, TT0_SUP
        WRREG32 %tt1, 0
        WRREG32 %tc, 0
        pflusha
        jmp     main

| ---------------------------------------------------------------------------
| The end: the testbench waits for the spin.
| ---------------------------------------------------------------------------
finish:
        move.l  #0x600DD00E, DONE
        PHASE   99
        .globl  _done
_done:
        bra     _done

| ---------------------------------------------------------------------------
| CHECK's body: D0 what it is, D1 what it should be, D2 the check's number.
| ---------------------------------------------------------------------------
check:
        addq.l  #1, NCHK
        cmp.l   %d0, %d1
        beq.s   1f
        addq.l  #1, NFAIL
        move.l  %a0, -(%sp)
        move.l  LOGP, %a0
        move.w  %d2, (%a0)+
        move.l  %d0, (%a0)+
        move.l  %d1, (%a0)+
        move.l  %a0, LOGP
        move.l  (%sp)+, %a0
1:      rts

| ---------------------------------------------------------------------------
| Exceptions. A bus error records its frame and goes through the hook a test
| installs; an MMU configuration exception records its frame and returns; a
| TRAP #0 counts; anything else is logged as unexpected and returned past.
| ---------------------------------------------------------------------------
berr_entry:
        addq.l  #1, NBERR
        move.w  10(%sp), FSSW+2         | +$0A, the special status word
        move.l  16(%sp), FADDR          | +$10, the fault address
        move.w  6(%sp), FFV+2           | +$06, format and vector
        move.l  2(%sp), FPC             | +$02
        move.l  36(%sp), FSTB           | +$24, the stage B address
        move.l  BERRH, -(%sp)
        rts                             | to the hook, the frame at (SP)

| The default hook: a bus error nobody expected. Count it as unexpected and
| stop the program, rather than loop on it.
berr_none:
        addq.l  #1, NEXC
        move.w  6(%sp), LASTV+2
        bra     finish

cfg_entry:
        addq.l  #1, NCFG
        move.w  6(%sp), CFGFV+2
        move.l  2(%sp), CFGPC
        move.l  8(%sp), CFGIA
        rte

trap0:
        addq.l  #1, NTRAP
        move.l  TRAPH, -(%sp)
        rts
trap_rte:
        rte

unexpected:
        addq.l  #1, NEXC
        move.w  6(%sp), LASTV+2
        bra     finish

| The special status word with DF cleared: the hook did the access, or
| abandons it -- UM 8.2.2.
clear_df:
        bclr    #0, 4+10(%sp)           | bit 8 of the word at +$0A
        rts
