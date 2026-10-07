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
 *     uae030_trace [-m KB] [-a WINDOW] [-D] <image.bin> [limit]
 *
 *   -m KB      RAM size in KiB (default 64, the core harness's 32-bit port)
 *   -a WINDOW  fold physical addresses below WINDOW (hex) onto the RAM, as the
 *              harness's partially decoded port does (default 10000000)
 *   -D         no data-cache emulation
 *
 * UAE030 is an ORACLE, not a source. Where the two disagree the manual decides.
 *
 * THE FORMAT, read positionally by core_cosim_tb with $fscanf("%h"):
 *
 *     nstep  nfield
 *     per instruction:  pc  then nfield values
 *
 * The values, in this order (nfield = 24 today):
 *
 *     d0..d7  a0..a6  usp  isp  msp  sr  vbr  cacr  caar  sfc  dfc
 *
 * New registers are only ever appended (the MMU's at M11), and a reader takes
 * nfield from the header and skips what it does not know, so an older bench
 * still reads a newer trace.
 *
 * The program stops itself with a branch to itself -- sim/programs/crt0.S --
 * and that is what ends the trace: the first boundary whose program counter
 * is the one before it has nothing after it worth comparing.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "uae030.h"

#define NFIELD 24

static unsigned long limit = 4000000;
static unsigned long steps;
static uint32_t prev_pc = 0xFFFFFFFFu;
static FILE *body;

static int on_insn(const uae030_state *s, void *u)
{
	(void)u;
	if (steps >= limit || s->pc == prev_pc)
		return 1;
	prev_pc = s->pc;
	fprintf(body, "%x", s->pc);
	for (int i = 0; i < 8; i++)
		fprintf(body, " %x", s->d[i]);
	for (int i = 0; i < 7; i++)
		fprintf(body, " %x", s->a[i]);
	fprintf(body, " %x %x %x %x %x %x %x %x %x\n", s->usp, s->isp, s->msp, s->sr,
		s->vbr, s->cacr, s->caar, s->sfc, s->dfc);
	steps++;
	return 0;
}

int main(int argc, char **argv)
{
	uint32_t kb = 64, window = 0x10000000u;
	int dcache = 1, c;
	while ((c = getopt(argc, argv, "m:a:D")) != -1) {
		switch (c) {
		case 'm': kb = strtoul(optarg, NULL, 0); break;
		case 'a': window = strtoul(optarg, NULL, 16); break;
		case 'D': dcache = 0; break;
		default:
			fprintf(stderr, "usage: %s [-m KB] [-a WINDOW] [-D] image.bin [limit]\n", argv[0]);
			return 2;
		}
	}
	if (optind >= argc) {
		fprintf(stderr, "usage: %s [-m KB] [-a WINDOW] [-D] image.bin [limit]\n", argv[0]);
		return 2;
	}
	if (optind + 1 < argc)
		limit = strtoul(argv[optind + 1], NULL, 0);

	uae030_init(kb << 10, dcache);
	uae030_set_alias(window);
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
	uae030_set_hooks(on_insn, NULL, NULL);
	int halted = uae030_run();
	if (halted) {
		fprintf(stderr, "uae030_trace: the oracle halted (double bus fault) after %lu instructions\n",
			steps);
		return 1;
	}

	fprintf(stderr, "trace: %lu instructions\n", steps);
	printf("%lx %x\n", steps, NFIELD);
	rewind(body);
	char buf[1 << 16];
	size_t r;
	fflush(stdout);
	while ((r = fread(buf, 1, sizeof buf, body)) > 0)
		fwrite(buf, 1, r, stdout);
	return 0;
}
