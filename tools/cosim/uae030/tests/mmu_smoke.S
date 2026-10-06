| SPDX-License-Identifier: GPL-2.0-or-later
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68031
|
| M0 spike smoke test for the uae030 oracle harness.
| Linked at 0, loaded at physical 0, run from reset (SSP/PC from vectors 0/1).
| Exercises: arithmetic, CACR (data cache on), PMOVE CRP/SRP/TC, a 2-level
| short-format table (IS=8 TIA=4 TIB=8 PS=4K) with one remapped page and one
| invalid page, PTEST, a bus error through the invalid page (vector 2), and a
| transparent translation (TT0) window.
|
| Build: m68k-linux-gnu-as -mcpu=68030 -o t.o mmu_smoke.S
|        m68k-linux-gnu-ld -Ttext=0 -o t.elf t.o ; objcopy -O binary t.elf t.bin

	.text
	.globl	_start
vectors:
	.long	0x00008000		| 0: reset SSP
	.long	_start			| 1: reset PC
	.long	buserr			| 2: bus error
	.rept	8
	.long	other			| 3..10
	.endr
	.long	fline			| 11: line F
	.rept	52
	.long	other			| 12..63
	.endr

	.org	0x400
_start:
	| --- plain integer ops ---------------------------------------------
	moveq	#5,%d0
	moveq	#7,%d1
	add.l	%d0,%d1			| d1 = 12
	mulu.w	#3,%d1			| d1 = 36
	move.l	#0x12345678,%d2
	swap	%d2
	sub.w	#1,%d2			| ccr: N=0 Z=0
	divu.w	#7,%d1			| 36/7 = q5 r1 -> d1 = 0x00010005
	bfextu	%d2{#4:#8},%d3
	| --- control registers -------------------------------------------
	lea	0x7000,%a0
	movec	%a0,%vbr
	lea	0,%a0
	movec	%a0,%vbr		| back to 0
	moveq	#1,%d0
	movec	%d0,%sfc
	moveq	#5,%d0
	movec	%d0,%dfc
	move.l	#0x00000909,%d0		| CD|ED|CI|EI : clear + enable both caches
	movec	%d0,%cacr
	| --- MMU on --------------------------------------------------------
	| PMOVE takes control alterable EAs only: gas silently turns an absolute
	| operand in .text into (d16,PC), which the 68030 rejects with a line-F
	| exception (PRM 6, PMOVE).  Keep one as a deliberate trap test.
	pmove	srp_val,%srp		| (d16,PC) -> vector 11, handler skips 6 bytes
	lea	srp_val,%a0
	pmove	(%a0),%srp
	lea	crp_val,%a0
	pmove	(%a0),%crp
	lea	tc_val,%a0
	pmove	(%a0),%tc
	| VA 0x80000 -> PA 0x6000
	move.l	#0xdeadbeef,0x80000
	move.l	0x80000,%d4		| first read: may hit data cache (write-allocate off -> miss)
	move.l	0x80000,%d4		| second read: data cache hit, no bus cycle
	move.l	0x6000,%d5		| identity page, same PA -> deadbeef
	| PTEST the mapped page and the invalid one
	ptestr	#5,0x80000,#7,%a1
	pmove	%psr,mmusr_save
	ptestr	#5,0x81000,#7,%a2
	pmove	%psr,mmusr_save+2
	| bus error through the invalid page
	move.l	%sp,%a5
	move.l	0x81000,%d6		| -> bus error, handler resumes at after_be
after_be:
	| transparent translation: TT0 covers 0x00xxxxxx, all FCs, R and W
	lea	tt0_val,%a0
	pmove	(%a0),%tt0
	move.l	0x81000,%d7		| TT hit -> PA 0x81000, no table walk
	lea	tt0_off,%a0
	pmove	(%a0),%tt0
	pflusha
	| MMU off again
	lea	tc_off,%a0
	pmove	(%a0),%tc
done:
	bra.s	done

buserr:
	move.w	6(%sp),%d6		| format/vector offset
	move.w	10(%sp),%d7		| SSW
	move.l	16(%sp),%a3		| data cycle fault address
	move.l	%a5,%sp			| discard frame
	jmp	after_be

fline:
	addq.l	#6,2(%sp)		| skip the 6-byte PMOVE
	rte

other:
	move.w	6(%sp),%d6
	bra.s	other

	.align	4
tc_val:	.long	0x80C84800		| E, PS=4K, IS=8, TIA=4, TIB=8
tc_off:	.long	0x00000000
crp_val:.long	0x00000002, 0x00004000	| L/U=0 limit=0, DT=2 (4-byte), table A @0x4000
srp_val:.long	0x7FFF0002, 0x00004000	| not enabled (SRE=0), loaded only for display
tt0_val:.long	0x00008107		| base 00 mask 00, E, RWM, FC mask 7
tt0_off:.long	0
mmusr_save:
	.word	0,0

	| --- level A table (16 entries, 1 MB each) --------------------------
	.org	0x4000
tblA:	.long	0x00004100 + 2		| entry 0 -> table B, DT=2
	.rept	15
	.long	0			| invalid
	.endr
	| --- level B table (256 entries, 4 KB pages) for VA 0..1MB ----------
	.org	0x4100
tblB:
	.set	pg,0
	.rept	256
	.if	pg == 0x80
	.long	0x00006000 + 1		| VA 0x80000 -> PA 0x6000
	.elseif	pg == 0x81
	.long	0			| VA 0x81000 invalid
	.else
	.long	(pg << 12) + 1		| identity, DT=1 page
	.endif
	.set	pg,pg+1
	.endr
