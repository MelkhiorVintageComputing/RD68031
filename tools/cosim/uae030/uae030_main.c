/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68031 */

/*
 * uae030 command-line tracer.
 *
 *   uae030 [-m MB] [-n MAXINSN] [-D] [-b] FILE[@ADDR] ...
 *
 *   -m MB     flat RAM size in MiB (default 16); accesses above it bus-error
 *   -n N      stop after N instructions (default 100000)
 *   -D        disable the data-cache emulation
 *   -b        do not print bus accesses
 *   FILE@ADDR raw binary loaded at physical ADDR (hex, default 0)
 *
 * The run starts with a hard reset (SSP and PC from physical 0 and 4) and
 * stops at N instructions or at the first "BRA.S *" (0x60FE).
 *
 * Output, one line each:
 *   I <count> PC=... SR=... D0..D7 A0..A7 USP ISP MSP VBR SFC DFC CACR CAAR
 *     TC CRP SRP TT0 TT1 MMUSR dc=hit/miss ic=hit/miss
 *       -- the state *before* executing the instruction at PC, i.e. after
 *          the previous instruction and any exception it caused.
 *   B <R|W> <pa> <size> <data> fc=<n> [walk] [BERR]
 *       -- a physical bus access (cache hits never appear).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "uae030.h"

static uint64_t max_insn = 100000;
static int print_bus = 1;

static int on_insn(const uae030_state *s, void *u)
{
	(void)u;
	const uint8_t *r = uae030_ram();
	printf("I %llu PC=%08x SR=%04x", (unsigned long long)s->insn_count, s->pc, s->sr);
	for (int i = 0; i < 8; i++)
		printf(" D%d=%08x", i, s->d[i]);
	for (int i = 0; i < 8; i++)
		printf(" A%d=%08x", i, s->a[i]);
	printf(" USP=%08x ISP=%08x MSP=%08x VBR=%08x SFC=%x DFC=%x CACR=%08x CAAR=%08x"
	       " TC=%08x CRP=%016llx SRP=%016llx TT0=%08x TT1=%08x MMUSR=%04x dc=%d/%d ic=%d/%d\n",
	       s->usp, s->isp, s->msp, s->vbr, s->sfc, s->dfc, s->cacr, s->caar,
	       s->tc, (unsigned long long)s->crp, (unsigned long long)s->srp,
	       s->tt0, s->tt1, s->mmusr, s->d_hit, s->d_miss, s->i_hit, s->i_miss);
	if (s->insn_count >= max_insn)
		return 1;
	/* BRA.S * : end of test (only meaningful while PC is identity-mapped) */
	if (s->pc + 1 < uae030_ram_size() && r[s->pc] == 0x60 && r[s->pc + 1] == 0xfe)
		return 1;
	return 0;
}

static void on_bus(uint32_t pa, int size, int write, uint32_t data, int fc, int kind,
		   int berr, void *u)
{
	(void)u;
	if (!print_bus)
		return;
	printf("B %c %08x %d %0*x fc=%d%s%s\n", write ? 'W' : 'R', pa, size, size * 2,
	       data, fc, kind == UAE030_KIND_WALK ? " walk" : kind == UAE030_KIND_IFETCH ? " ifetch" : "",
	       berr ? " BERR" : "");
}

int main(int argc, char **argv)
{
	uint32_t mb = 16;
	int dcache = 1, c;
	while ((c = getopt(argc, argv, "m:n:Db")) != -1) {
		switch (c) {
		case 'm': mb = strtoul(optarg, NULL, 0); break;
		case 'n': max_insn = strtoull(optarg, NULL, 0); break;
		case 'D': dcache = 0; break;
		case 'b': print_bus = 0; break;
		default:
			fprintf(stderr, "usage: %s [-m MB] [-n N] [-D] [-b] FILE[@ADDR]...\n", argv[0]);
			return 2;
		}
	}
	if (optind >= argc) {
		fprintf(stderr, "no program\n");
		return 2;
	}
	uae030_init(mb << 20, dcache);
	for (int i = optind; i < argc; i++) {
		char *path = strdup(argv[i]), *at = strrchr(path, '@');
		uint32_t addr = 0;
		if (at) {
			*at = 0;
			addr = strtoul(at + 1, NULL, 16);
		}
		if (uae030_load(path, addr) < 0) {
			perror(path);
			return 1;
		}
		free(path);
	}
	setvbuf(stdout, NULL, _IOFBF, 1 << 16);
	uae030_set_hooks(on_insn, on_bus, NULL);
	int r = uae030_run();
	printf("END %s\n", r ? "halted" : "stopped");
	return 0;
}
