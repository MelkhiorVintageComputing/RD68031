/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68031 */

/*
 * uae030 -- the WinUAE 68030 CPU core (Hatari's src/cpu copy) as a standalone
 * instruction + MMU + data-cache oracle.  Flat physical RAM from 0, everything
 * above it answers with a bus error.  No chipset, no interrupts.
 *
 * M0 spike interface: one run per process (m68k_go is not re-entrant).
 */
#ifndef UAE030_H
#define UAE030_H

#include <stdint.h>

/* Bus-access kinds reported by the bus hook. */
enum uae030_kind {
	UAE030_KIND_CPU = 0,   /* operand / instruction / stack access issued by the core */
	UAE030_KIND_WALK = 1,  /* MMU table-search descriptor fetch/update */
};

typedef struct uae030_state {
	uint32_t pc;           /* address of the next instruction to execute */
	uint32_t d[8], a[8];   /* a[7] = active stack pointer */
	uint32_t usp, isp, msp;
	uint16_t sr;
	uint32_t vbr, sfc, dfc, cacr, caar;
	uint32_t tc, tt0, tt1;
	uint64_t crp, srp;
	uint16_t mmusr;
	uint64_t insn_count;
	int d_hit, d_miss, i_hit, i_miss; /* cache statistics of the last instruction */
} uae030_state;

/* Called before each instruction is executed (i.e. after the previous one and
 * any exception it raised has been processed).  Return nonzero to stop. */
typedef int (*uae030_insn_hook)(const uae030_state *s, void *user);

/* Called on every physical bus access (cache hits do not appear).
 * size = 1/2/4, write = 0/1, fc = function code (0..7), kind = enum above.
 * A bus error (access above RAM) is reported with berr = 1. */
typedef void (*uae030_bus_hook)(uint32_t pa, int size, int write, uint32_t data,
				int fc, int kind, int berr, void *user);

void uae030_init(uint32_t ram_bytes, int data_cache);
uint8_t *uae030_ram(void);
uint32_t uae030_ram_size(void);
int uae030_load(const char *path, uint32_t phys);
void uae030_set_hooks(uae030_insn_hook ih, uae030_bus_hook bh, void *user);
void uae030_get_state(uae030_state *s);
/* Reset (SSP/PC from physical 0/4) and run until the instruction hook asks
 * to stop or the CPU halts (double bus fault).  Returns 0 on hook stop,
 * 1 on halt. */
int uae030_run(void);

#endif
