| SPDX-License-Identifier: GPL-2.0-or-later
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031
| RD68031 M0 spike: small bus-cycle demo for the AP68030 program bench.
| Assembled with m68k-linux-gnu-as -mcpu=68030, linked at 0, raw binary.
	.text
	.org	0
	.long	0x3400			| initial ISP
	.long	start			| initial PC
	.rept	254
	.long	bad			| all other vectors -> bad
	.endr
	.org	0x400
start:
	| plain accesses, caches off
	move.l	#0x11223344,%d0
	move.l	%d0,0x2000		| 32-bit sync port, aligned long write
	move.w	%d0,0x2005		| misaligned word write
	move.l	0x2000,%d1		| long read
	move.l	%d0,0x200101		| 16-bit async port, misaligned long write
	move.l	0x200101,%d2		| read it back via 16-bit port
	move.b	0x300003,%d3		| 8-bit port byte read
	move.l	0x400010,%d4		| CIIN window long read
	| caches + burst on (EI, IBE, ED, DBE)
	move.l	#0x1111,%d0
	movec	%d0,%cacr
	move.l	0x3000,%d5		| data miss -> burst fill (CBREQ)
	move.l	0x3004,%d5		| should hit
	tas	0x2010			| RMW cycle
	| MMU: one-level table, early-termination page descriptors, identity
	lea	table,%a0
	moveq	#15,%d1
	move.l	#0x00000001,%d2		| page descriptor, DT=1
1:	move.l	%d2,(%a0)+
	add.l	#0x00100000,%d2
	dbra	%d1,1b
	move.l	#1,table+48		| logical 0xCxxxxx -> physical 0x0xxxxx
	pmove	crp_val:l,%crp
	pmove	tc_val:l,%tc		| E=1 PS=15 IS=8 TIA=4 TIB=5
	move.l	0xC05000,%d6		| triggers a table walk, translated to 0x5000
	move.l	%d6,0x5004
	move.w	#0x600d,0xF00102	| report pass
2:	bra.s	2b
bad:
	move.w	#0xbad0,0xF00102
3:	bra.s	3b
	.balign	16
crp_val:	.long	0x7fff0002, table
tc_val:		.long	0x80F84500
	.balign	16
table:	.fill	16,4,0
