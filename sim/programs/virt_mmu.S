| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031

| RD68031 -- rd-virt bare metal: the MMU on, with both caches.
|
| A two-level short-format tree (TC $80C0AA00: 4 KB pages, 10 + 10 index
| bits), as Linux builds one on an MC68030 (UM 9.5):
|   A[0]       a B table mapping 0-4 MB page by page, identity
|   A[1..3]    early-termination page descriptors, 4-16 MB, identity
|   A[256]     a B table for $40000000: page 0 -> $300000, page 1 invalid,
|              page 2 -> $302000 write-protected, page 3 invalid
| TT1 maps the devices at $FFxxxxxx untranslated and cache-inhibited, as
| Linux's head.S does. CACR enables both caches with bursts and write
| allocation.
|
| Then: a checksum over 64 KB written and read twice through the caches; a
| write through the alias read back through the identity mapping; a read and
| a write that fault on invalid pages and a write that faults on a
| write-protected one, each repaired by the bus error handler and resumed by
| RTE (UM 8.2); PTEST's verdicts on a valid, an invalid and a write-protected
| page.

#include "virt.inc"

        .equ    ROOT,   0x00010000
        .equ    B0,     0x00011000
        .equ    B1,     0x00012000
        .equ    BUF,    0x00100000
        .equ    ALIAS,  0x40000000
        .equ    APHYS,  0x00300000

        .text
        .globl  _start
_start:
        PUTS    m_start
        clr.l   %d7                     | bus errors taken
        | the tree
        lea     ROOT, %a0
        move.w  #1023, %d0
1:      clr.l   (%a0)+
        dbra    %d0, 1b
        move.l  #B0 + 2, ROOT
        move.l  #0x00400001, ROOT + 4
        move.l  #0x00800001, ROOT + 8
        move.l  #0x00C00001, ROOT + 12
        move.l  #B1 + 2, ROOT + 256*4
        lea     B0, %a0
        move.l  #1, %d1
        move.w  #1023, %d0
2:      move.l  %d1, (%a0)+
        add.l   #0x1000, %d1
        dbra    %d0, 2b
        lea     B1, %a0
        move.w  #1023, %d0
3:      clr.l   (%a0)+
        dbra    %d0, 3b
        move.l  #APHYS + 1, B1
        move.l  #APHYS + 0x2000 + 4 + 1, B1 + 8
        | data the faulting read will find once its page is mapped
        move.l  #0x12345678, APHYS + 0x1004
        | translation on
        lea     regs, %a5
        pmove   8(%a5), %tt1
        pmove   (%a5), %crp
        pflusha
        pmove   12(%a5), %tc
        move.l  #0x00003919, %d0        | WA DBE CD DE IBE CI IE (UM 6.3)
        movec   %d0, %cacr
        PUTS    m_on

        | 1. a checksum through the caches
        lea     BUF, %a0
        move.l  #0x9E3779B9, %d1
        clr.l   %d2
        move.w  #16383, %d0
4:      move.l  %d1, (%a0)+
        add.l   %d1, %d2
        rol.l   #5, %d1
        add.l   #0x7F4A7C15, %d1
        dbra    %d0, 4b
        moveq   #1, %d4
5:      lea     BUF, %a0
        clr.l   %d3
        move.w  #16383, %d0
6:      add.l   (%a0)+, %d3
        dbra    %d0, 6b
        cmp.l   %d2, %d3
        bne     fail
        dbra    %d4, 5b

        | 2. a write through the alias, read through the identity mapping
        move.l  #0xCAFEBABE, ALIAS + 0x10
        cmp.l   #0xCAFEBABE, APHYS + 0x10
        bne     fail

        | 3. PTEST: valid, invalid, write-protected (UM 9.6.2: MMUSR I, WP)
        lea     ALIAS, %a1
        ptestr  #5, (%a1), #7
        pmove   %psr, 16(%a5)
        move.w  16(%a5), %d0
        and.w   #0x0C00, %d0            | I and WP
        bne     fail
        lea     ALIAS + 0x1000, %a1
        ptestr  #5, (%a1), #7
        pmove   %psr, 16(%a5)
        btst    #2, 16(%a5)             | I (bit 10)
        beq     fail
        lea     ALIAS + 0x2000, %a1
        ptestw  #5, (%a1), #7
        pmove   %psr, 16(%a5)
        btst    #3, 16(%a5)             | WP (bit 11)
        beq     fail

        | 4. faults, each repaired and resumed
        move.l  ALIAS + 0x1004, %d0     | invalid page: read
        cmp.l   #0x12345678, %d0
        bne     fail
        move.l  #0x55AA55AA, ALIAS + 0x3008   | invalid page: write
        cmp.l   #0x55AA55AA, APHYS + 0x3008
        bne     fail
        move.l  #0x600DF00D, ALIAS + 0x2000   | write-protected page
        cmp.l   #0x600DF00D, APHYS + 0x2000
        bne     fail
        cmp.l   #3, %d7
        bne     fail

        | caches off, translation off, and done
        move.l  #0x00000808, %d0
        movec   %d0, %cacr
        pmove   20(%a5), %tc
        PUTS    m_pass
        POWEROFF 2
fail:   PUTS    m_fail
        move.l  %d7, %d1
        bsr     puthex
        move.l  #10, TTY
        POWEROFF 3

| A bus error: a page fault on the alias. The fault address is +$10 of the
| short and the long bus fault frames alike (UM 8.4.6); its page is mapped
| (write protection cleared), the ATC flushed, and RTE runs the faulted cycle
| again (UM 8.2).
vec_2:  movem.l %d0-%d1/%a0, -(%sp)
        addq.l  #1, %d7
        move.l  12+16(%sp), %d0         | the fault address
        move.l  %d0, %d1
        and.l   #0xFFFF0000, %d1
        cmp.l   #ALIAS, %d1
        bne     fail
        and.l   #0x0000F000, %d0
        lsr.l   #8, %d0
        lsr.l   #2, %d0                 | page index x 4
        lea     B1, %a0
        move.l  %d0, %d1
        lsl.l   #8, %d1
        lsl.l   #2, %d1
        add.l   #APHYS + 1, %d1
        move.l  %d1, (%a0, %d0.l)
        pflusha
        movem.l (%sp)+, %d0-%d1/%a0
        rte

        COMMON
        .even
regs:   .long   0x7FFF0002, ROOT        | CRP: short table descriptors, upper limit $7FFF (none)
        .long   0xFF008507              | TT1: $FFxxxxxx, CI, R and W, every FC
        .long   0x80C0AA00              | TC
        .word   0, 0                    | MMUSR
        .long   0x00C0AA00              | TC, disabled
m_start: .asciz "virt_mmu: building the tables\n"
m_on:    .asciz "virt_mmu: translation and caches on\n"
m_pass:  .asciz "PASS: virt_mmu\n"
m_fail:  .asciz "FAIL: virt_mmu, bus errors "
        .even
        VECTORS
