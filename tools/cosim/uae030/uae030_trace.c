/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68031 */

/*
 * uae030_trace -- the instruction-by-instruction oracle for `make cosim`.
 *
 * Loads a flat image at physical 0 (the vectors at 0, the program where the
 * reset vector points), runs it under UAE030 from a hard reset, and prints the
 * architectural state at EVERY instruction boundary. sim/tb/core_cosim_tb.sv
 * runs the same image on the core and compares at the same boundaries, so a
 * divergence is reported at the instruction that caused it rather than at the
 * end of a program that came out wrong.
 *
 *     uae030_trace [-m KB] [-a WINDOW] [-D] [-r BASE:MASK:SIZE]... [-e BASE:MASK]...
 *                  [-B busfile] <image.bin> [limit]
 *
 *   -m KB      RAM size in KiB (default 64, the core harness's 32-bit port)
 *   -a WINDOW  fold physical addresses below WINDOW (hex) onto the RAM, as the
 *              harness's partially decoded port does (default 10000000)
 *   -D         no data-cache emulation
 *   -r B:M:S   one more memory (hex): addresses with (a & M) == B reach a store
 *              of S bytes, zeroed, repeated through the window -- the core
 *              harness's 16-bit, 8-bit and synchronous ports (make cosim-mmu)
 *   -e B:M     a window (hex) that answers every access with a bus error, as
 *              core_cosim_tb +mmu makes $4000_0000-$4FFF_FFFF do
 *   -B FILE    write the physical data-access stream to FILE (below)
 *
 * UAE030 is an ORACLE, not a source. Where the two disagree the manual decides.
 *
 * THE FORMAT, read positionally by core_cosim_tb with $fscanf("%h"):
 *
 *     nstep  nfield
 *     per instruction:  pc  then nfield values
 *
 * The values, in this order (nfield = 32 since M11):
 *
 *     d0..d7  a0..a6  usp  isp  msp  sr  vbr  cacr  caar  sfc  dfc
 *     tc  crp_hi  crp_lo  srp_hi  srp_lo  tt0  tt1  mmusr
 *
 * New registers are only ever appended, and a reader takes nfield from the
 * header and skips what it does not know, so an older bench still reads a
 * newer trace.
 *
 * THE BUS STREAM (-B), read by tools/bus_diff.py, one line each:
 *
 *     I <n> <pc>                       instruction boundary n, before the
 *                                      instruction at pc runs
 *     E <vector>                       exception processing starts
 *     <R|W> <pa> <bytes> <data> <fc> <kind> <c> [B]
 *                                      one physical access: its address, how
 *                                      many bytes and their value (right
 *                                      justified, hex), the function code,
 *                                      kind D (an operand or stack access),
 *                                      T (a table search access for an
 *                                      operand, or for PTEST or PLOAD) or F (a
 *                                      table search access for an instruction
 *                                      fetch's translation -- function code
 *                                      2 or 6 -- whose place in the stream
 *                                      depends on how far a prefetch runs
 *                                      ahead), c = 1 while CACR.ED is set
 *                                      (such a read may be a cache hit on the
 *                                      other side), and B for a bus error.
 *
 * Instruction fetches are not in it, and cache hits are invisible. A table
 * search's accesses are labelled with function code 5 (UM 7.3.3).
 * core_cosim_tb +mmubus= writes the same format from the core's pins.
 *
 * The program stops itself with a branch to itself -- sim/programs/crt0.S --
 * and that is what ends the trace: the first boundary whose program counter
 * is the one before it, at a BRA to itself, has nothing after it worth
 * comparing. (A DBF on itself, which a delay loop is, also repeats its PC.)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "uae030.h"

#define NFIELD 32

static unsigned long limit = 4000000;
static unsigned long steps;
static uint32_t prev_pc = 0xFFFFFFFFu;
static FILE *body;
static FILE *bus;

static void on_bus(uint32_t pa, int size, int write, uint32_t data, int fc, int kind,
		   int berr, void *u)
{
	(void)u;
	if (!bus || kind == UAE030_KIND_IFETCH)
		return;
	char k = 'D';
	if (kind == UAE030_KIND_WALK) {
		int wfc, insn;
		uae030_walk_info(&wfc, &insn);
		k = (!insn && (wfc & 3) == 2) ? 'F' : 'T';
	}
	fprintf(bus, "%c %x %d %x %d %c %d%s\n", write ? 'W' : 'R', pa, size,
		berr ? 0 : data, fc, k, (uae030_cacr() >> 8) & 1, berr ? " B" : "");
}

static void on_exc(int vector, void *u)
{
	(void)u;
	if (bus)
		fprintf(bus, "E %d\n", vector);
}

static int on_insn(const uae030_state *s, void *u)
{
	(void)u;
	/* The end: a branch to itself. A DBF that loops on itself also stays at
	 * one PC, so the instruction is looked at (the programs run from
	 * identity-mapped memory). */
	if (steps >= limit)
		return 1;
	if (s->pc == prev_pc && s->pc + 3 < uae030_ram_size()) {
		const uint8_t *r = uae030_ram() + s->pc;
		if ((r[0] == 0x60 && r[1] == 0xFE)
		    || (r[0] == 0x60 && r[1] == 0x00 && r[2] == 0xFF && r[3] == 0xFE)
		    || (r[0] == 0x60 && r[1] == 0xFF && r[2] == 0xFF && r[3] == 0xFF))
			return 1;
	}
	prev_pc = s->pc;
	if (bus)
		fprintf(bus, "I %lu %x\n", steps, s->pc);
	fprintf(body, "%x", s->pc);
	for (int i = 0; i < 8; i++)
		fprintf(body, " %x", s->d[i]);
	for (int i = 0; i < 7; i++)
		fprintf(body, " %x", s->a[i]);
	fprintf(body, " %x %x %x %x %x %x %x %x %x", s->usp, s->isp, s->msp, s->sr,
		s->vbr, s->cacr, s->caar, s->sfc, s->dfc);
	fprintf(body, " %x %x %x %x %x %x %x %x\n", s->tc, (uint32_t)(s->crp >> 32),
		(uint32_t)s->crp, (uint32_t)(s->srp >> 32), (uint32_t)s->srp, s->tt0, s->tt1,
		s->mmusr);
	steps++;
	return 0;
}

int main(int argc, char **argv)
{
	uint32_t kb = 64, window = 0x10000000u;
	int dcache = 1, c, nr = 0;
	uint32_t rb[8], rm[8], rs[8];
	int re[8];
	const char *busfile = NULL;
	const char *usage = "usage: %s [-m KB] [-a WINDOW] [-D] [-r B:M:S]... [-e B:M]... [-B busfile] image.bin [limit]\n";
	while ((c = getopt(argc, argv, "m:a:Dr:e:B:")) != -1) {
		switch (c) {
		case 'm': kb = strtoul(optarg, NULL, 0); break;
		case 'a': window = strtoul(optarg, NULL, 16); break;
		case 'D': dcache = 0; break;
		case 'r':
		case 'e':
			if (nr >= 8 || sscanf(optarg, "%x:%x:%x", &rb[nr], &rm[nr], &rs[nr]) < (c == 'r' ? 3 : 2)) {
				fprintf(stderr, usage, argv[0]);
				return 2;
			}
			re[nr++] = (c == 'e');
			break;
		case 'B': busfile = optarg; break;
		default:
			fprintf(stderr, usage, argv[0]);
			return 2;
		}
	}
	if (optind >= argc) {
		fprintf(stderr, usage, argv[0]);
		return 2;
	}
	if (optind + 1 < argc)
		limit = strtoul(argv[optind + 1], NULL, 0);

	uae030_init(kb << 10, dcache);
	uae030_set_alias(window);
	for (int i = 0; i < nr; i++)
		uae030_add_region(rb[i], rm[i], re[i] ? 0 : rs[i], re[i]);
	if (busfile) {
		bus = fopen(busfile, "w");
		if (!bus) {
			perror(busfile);
			return 1;
		}
		setvbuf(bus, NULL, _IOFBF, 1 << 16);
	}
	int n = uae030_load(argv[optind], 0);
	if (n < 0) {
		perror(argv[optind]);
		return 1;
	}
	if (n <= 8) {
		fprintf(stderr, "uae030_trace: %s is %d bytes\n", argv[optind], n);
		return 1;
	}
	body = tmpfile();
	if (!body) {
		perror("tmpfile");
		return 1;
	}
	uae030_set_hooks(on_insn, on_bus, NULL);
	uae030_set_exc_hook(on_exc);
	int halted = uae030_run();
	if (halted) {
		fprintf(stderr, "uae030_trace: the oracle halted (double bus fault) after %lu instructions\n",
			steps);
		return 1;
	}

	fprintf(stderr, "trace: %lu instructions\n", steps);
	if (bus)
		fclose(bus);
	printf("%lx %x\n", steps, NFIELD);
	rewind(body);
	char buf[1 << 16];
	size_t r;
	fflush(stdout);
	while ((r = fread(buf, 1, sizeof buf, body)) > 0)
		fwrite(buf, 1, r, stdout);
	return 0;
}
