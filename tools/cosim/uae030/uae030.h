/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68031 */

/*
 * uae030 -- the WinUAE 68030 CPU core (Hatari's src/cpu copy) as a standalone
 * instruction + MMU + data-cache oracle, behind a small library interface.
 *
 * Memory is flat physical RAM from 0. Everything above it answers with a bus
 * error, unless uae030_set_alias() folds a window of the address space onto
 * the RAM the way a partially decoded memory does. No chipset, no interrupts.
 *
 * One run per process: uae030_run() enters the core once and stays there
 * until the instruction hook asks to stop. A front-end that needs many short
 * runs (one instruction per test, say) does it from inside the instruction
 * hook, with uae030_set_state(), which is how vectors_gen and uae030_ea work.
 *
 * The configuration is the one doc/oracles.md describes: 68030, 68030 MMU,
 * compatible prefetch and instruction cache, data-cache emulation (switchable),
 * no FPU, 32-bit addressing, and the ATC's host-side page caches compiled out.
 */
#ifndef UAE030_H
#define UAE030_H

#include <stdint.h>

/* Bus-access kinds reported by the bus hook. */
enum uae030_kind {
	UAE030_KIND_CPU = 0,    /* an operand or stack access issued by the core */
	UAE030_KIND_WALK = 1,   /* an MMU table-search descriptor fetch or update */
	UAE030_KIND_IFETCH = 2, /* an instruction fetch (prefetch or cache fill) */
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
 * A bus error (access outside memory) is reported with berr = 1. */
typedef void (*uae030_bus_hook)(uint32_t pa, int size, int write, uint32_t data,
				int fc, int kind, int berr, void *user);

/* Called once per OPERAND access of kind UAE030_KIND_CPU: a misaligned
 * operand the core splits into several bus accesses is reported here once,
 * at the physical address of its first byte, with its whole size and value.
 * Instruction fetches and table searches never appear. */
typedef void (*uae030_op_hook)(uint32_t pa, int size, int write, uint32_t data,
			       int fc, int berr, void *user);

/* Called when exception processing starts, with the vector number. */
typedef void (*uae030_exc_hook)(int vector, void *user);

void uae030_init(uint32_t ram_bytes, int data_cache);
/* Physical addresses below `window` (a power of two, at least the RAM size)
 * address the RAM modulo its size; 0 turns aliasing off (the default). */
void uae030_set_alias(uint32_t window);
/* One more physical region, consulted before the RAM: addresses with
 * (a & mask) == base reach a zeroed store of `size` bytes (a power of two)
 * repeated through the window, or, with berr set, answer with a bus error --
 * the way the core harness's other ports and its bus-error window answer.
 * Returns the region's number, or -1 when there is no room (eight at most). */
int uae030_add_region(uint32_t base, uint32_t mask, uint32_t size, int berr);
uint8_t *uae030_region_mem(int i);
/* From inside the bus hook, for an access of kind UAE030_KIND_WALK: the
 * function code of the access the search translates, and whether PTEST or
 * PLOAD started it (then 1). */
void uae030_walk_info(int *fc, int *insn);
/* The cache control register, cheaply, from inside a hook. */
uint32_t uae030_cacr(void);
/* From inside the instruction hook (or before the run): install TC, CRP, SRP,
 * TT0, TT1 and MMUSR from *s as PMOVE would, without the configuration check,
 * and flush the ATC. */
void uae030_set_mmu(const uae030_state *s);
uint8_t *uae030_ram(void);
uint32_t uae030_ram_size(void);
int uae030_load(const char *path, uint32_t phys);
void uae030_set_hooks(uae030_insn_hook ih, uae030_bus_hook bh, void *user);
void uae030_set_op_hook(uae030_op_hook oh);
void uae030_set_exc_hook(uae030_exc_hook eh);
void uae030_get_state(uae030_state *s);
/* From inside the instruction hook only: replace the whole programmer's-model
 * state (PC, D0-D7, A0-A6, USP, ISP, MSP, SR, VBR, SFC, DFC, CACR, CAAR;
 * a[7] is ignored and derived from SR), invalidate both caches, and refetch
 * the instruction stream at the new PC. MMU registers are left alone. */
void uae030_set_state(const uae030_state *s);
/* One instruction per test, many tests per run. The RAM must hold reset
 * vectors that lead to a valid instruction. At each instruction boundary the
 * driver calls result() for the test just run (not before the first), then
 * setup() for the next: setup() writes whatever memory the test needs and
 * fills *st (its pc included), which uae030_set_state() then installs.
 * Returns 0 when every test ran, 1 if the oracle halted part way (a double
 * bus fault); *done says how many tests completed. */
typedef void (*uae030_setup_fn)(int i, uae030_state *st, void *user);
typedef void (*uae030_result_fn)(int i, const uae030_state *st, void *user);
int uae030_run_each(int ntests, uae030_setup_fn setup, uae030_result_fn result,
		    void *user, int *done);

/* M13 (sim/virt): a machine with devices.
 *
 * uae030_set_ext_bus: every physical access that no region and no RAM
 * claims goes to these instead of answering with a bus error; read returns
 * nonzero for a bus error (and fills *v otherwise), write likewise.
 * size is 1, 2 or 4, the address is the access's own (no alignment).
 * uae030_set_cachable: the cachability of [base, base+size) in 64 KB steps,
 * as a board's CIIN would give it (default: everything cachable).
 * uae030_interrupt: from inside the instruction hook only -- take the
 * interrupt exception for `level` (autovectored) now, at this boundary, as
 * the processor would between two instructions; the next boundary is the
 * handler's first instruction.
 * uae030_stopped: nonzero while STOP holds the processor.
 * uae030_last_opcode: the core's current operation word, from inside the
 * instruction hook (after a bus fault, the faulted instruction's).
 * uae030_retired: instructions completed, STOP's re-executions excluded. */
typedef int (*uae030_ext_read)(uint32_t pa, int size, uint32_t *v, void *user);
typedef int (*uae030_ext_write)(uint32_t pa, int size, uint32_t v, void *user);
void uae030_set_ext_bus(uae030_ext_read rd, uae030_ext_write wr, void *user);
void uae030_set_cachable(uint32_t base, uint32_t size, int cachable);
void uae030_interrupt(int level);
int uae030_stopped(void);
/* 1 (the default): a fault on an instruction's last write stacks the short
 * bus fault frame ($A), the oracle's own choice; 0: the long one ($B), as the
 * core does for every bus fault (doc/checkpoint.md). */
void uae030_set_short_frames(int on);
/* From inside the instruction hook: write a word or a long word (size 2, 4)
 * at a supervisor data address, through the core's own path -- translation,
 * data cache and bus hook included. */
void uae030_poke(uint32_t addr, int size, uint32_t v);
uint16_t uae030_last_opcode(void);
/* The operation word of the instruction about to run (the prefetch). */
uint16_t uae030_next_opcode(void);

/* Reset (SSP/PC from physical 0/4) and run until the instruction hook asks
 * to stop or the CPU halts (double bus fault).  Returns 0 on hook stop,
 * 1 on halt. */
int uae030_run(void);

#endif
