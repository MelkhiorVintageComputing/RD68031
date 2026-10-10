/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68031 */

/*
 * Glue between Hatari's copy of the WinUAE CPU core (src/cpu) and a bare
 * flat-RAM machine.  Replaces Hatari's memory.c, hatari-glue.c, custom.c and
 * events.c, and stubs every Atari-side symbol the core references.
 *
 * Compiled against Hatari's own headers (src/includes, src/debug, src/falcon)
 * so the core's view of every type is unchanged.
 */
#include <setjmp.h>
#include <stdarg.h>

#include "main.h"
#include "sysconfig.h"
#include "sysdeps.h"
#include "options_cpu.h"
#include "memory.h"
#include "newcpu.h"
#include "cpummu030.h"
#include "mmu_common.h"
#include "savestate.h"
#include "hatari-glue.h"
#include "m68000.h"
#include "log.h"

#include "uae030.h"

/* ------------------------------------------------------------------ */
/* Harness state                                                       */

static uint8_t *ram;
static uint32_t ram_size;
static uint32_t alias_window;
static uae030_insn_hook insn_hook;
static uae030_bus_hook bus_hook;
static uae030_op_hook op_hook;
static uae030_exc_hook exc_hook;
static void *hook_user;
static jmp_buf run_exit;
static int run_status;
static uint64_t insn_count;

/* Set by the patched cpummu030.c right before each physical access
 * (uae030_bus_fc = fc), around table-search descriptor accesses
 * (uae030_bus_walk) and around instruction fetches (uae030_bus_ifetch). */
int uae030_bus_fc = 5;
int uae030_bus_walk = 0;
int uae030_bus_ifetch = 0;
/* Set by the patched table search: the function code of the access it is
 * translating, and whether PTEST or PLOAD started it. */
int uae030_walk_fc = 5;
int uae030_walk_insn = 0;

/* Extra physical regions in front of the RAM (uae030_add_region): each its
 * own store, repeated through its window, or a window that answers every
 * access with a bus error. */
#define UAE030_NREG 8
static struct {
	uint32_t base, mask, size;
	int berr;
	uint8_t *mem;
} region[UAE030_NREG];
static int nregion;

/* A misaligned operand in progress: the core splits it into aligned bus
 * accesses inside mmu030_{get,put}_*_unaligned, which are wrapped at link
 * time (-Wl,--wrap, see UAE030_LDFLAGS in the Makefile) so that the pieces
 * are reported to the operand hook as the one operand they are. */
static struct {
	int active, have, berr, fc;
	uint32_t pa;
} op_pend;

/* ------------------------------------------------------------------ */
/* Hatari / UAE globals the core expects                               */

struct uae_prefs currprefs, changed_prefs;
int pendingInterrupts;
uae_u32 extra_cycle;
int CurrentInstrCycles, nCyclesMainCounter, WaitStateCycles;
uint64_t CyclesGlobalClockCounter;
uint64_t CycInt_ActiveInt_Cycles = UINT64_MAX; /* no Hatari timer events, ever */
bool bDspEnabled, MFP_UpdateNeeded, CpuRunFuncNoret, CpuRunCycleExact, CPU_IACK;
bool bQuitProgram, bVdiAesIntercept;
int LastOpcodeFamily, LastInstrCycles, Pairing;
char PairingArray[MAX_OPCODE_FAMILY][MAX_OPCODE_FAMILY];
cpu_instruction_t CpuInstruction;
uint16_t BlitterPhase;
uint32_t VDI_OldPC;
int ExceptionDebugMask;
uae_u32 hsync_counter, vsync_counter;
int savestate_state;
TCHAR savestate_fname[MAX_DPATH];
evt_t currcycle;
uae_u8 ce_banktype[65536], ce_cachable[65536];
addrbank *mem_banks[MEMORY_BANKS];

void CycInt_CallActiveHandler(uint64_t Clock) { (void)Clock; }
void MFP_UpdateIRQ_All(uint64_t t) { (void)t; }
void MFP_DelayIRQ(void) {}
int MFP_ProcessIACK(int v) { return v; }
int SCC_Process_IACK(void) { return -1; }
int DSP_ProcessIACK(void) { return -1; }
uint8_t DSP_GetHREQ(void) { return 0; }
void DSP_Run(int n) { (void)n; }
void Blitter_HOG_CPU_mem_access_before(int n) { (void)n; }
void Blitter_HOG_CPU_mem_access_after(int n) { (void)n; }
void M68000_ClearIRQ(int n) { (void)n; }
void M68000_Update_intlev(void) {}
void M68000_RestoreDebugger(void) {}
bool M68000_IsVerboseBusError(uint32_t pc, uint32_t addr) { (void)pc; (void)addr; return false; }
int M68000_WaitEClock(void) { return 0; }
void M68000_PatchCpuTables(void)
{
	/* Hatari's private opcodes are plain illegal instructions here. */
	static const int ops[] = { 0x0008, 0x0009, 0x000a, 0x000c, 0x7300, 0x7301 };
	for (unsigned i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
		cpufunctbl[ops[i]] = cpufunctbl[0x4afc];
		cpufunctbl_noret[ops[i]] = cpufunctbl_noret[0x4afc];
	}
}
bool XBios(void) { return false; }
bool Bios(void) { return false; }
bool VDI_AES_Entry(void) { return false; }
const char *Symbols_GetByCpuAddress(uint32_t a, int t) { (void)a; (void)t; return NULL; }
bool Profile_CpuAddr_HasData(uint32_t a) { (void)a; return false; }
int Profile_CpuAddr_DataStr(char *b, int m, uint32_t a) { (void)b; (void)m; (void)a; return 0; }
static void op_flush(void);
/* Called by the core when exception processing starts (exception_debug). A
 * misaligned operand cut short by a bus error is reported first, so that the
 * operand list stays in bus order ahead of the frame the exception writes. */
void DebugUI_Exceptions(int nr, long pc)
{
	(void)pc;
	op_flush();
	if (exc_hook)
		exc_hook(nr, hook_user);
}
void DebugUI(int r) { (void)r; }
void DebugCpu_Check(void) {}
void Dialog_HaltDlg(void)
{
	/* Double bus fault / CPU stuck: end the run. */
	run_status = 1;
	longjmp(run_exit, 1);
}
void Log_Printf(LOGTYPE t, const char *fmt, ...)
{
	if (t > LOG_WARN)
		return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

/* savestate: never used */
void save_u64(uae_u64 d) { (void)d; }
void save_u32(uae_u32 d) { (void)d; }
void save_u16(uae_u16 d) { (void)d; }
void save_u8(uae_u8 d) { (void)d; }
void save_s8(uae_s8 d) { (void)d; }
uae_u64 restore_u64(void) { return 0; }
uae_u32 restore_u32(void) { return 0; }
uae_u16 restore_u16(void) { return 0; }
uae_u8 restore_u8(void) { return 0; }
uae_s8 restore_s8(void) { return 0; }
int save_state(const TCHAR *f, const TCHAR *d) { (void)f; (void)d; savestate_state = 0; return 0; }
void restore_state(const TCHAR *f) { (void)f; }
void savestate_restore_final(void) {}
bool savestate_restore_finish(void) { return false; }

/* hatari-glue.c / custom.c / events.c replacements */
void customreset(void) {}
int intlev(void) { return 0; }
void custom_reset(bool h, bool k) { (void)h; (void)k; }
void reset_frame_rate_hack(void) {}
void fpux_restore(int *v) { (void)v; }
void do_cycles_slow(int c) { currcycle += c; }
void do_cycles_ce(int c) { currcycle += c; }
void do_cycles_ce020(int c) { currcycle += c; }
void do_cycles_ce_hatari_blitter(int c) { currcycle += c; }
bool is_cycle_ce(uaecptr a) { (void)a; return false; }
void fixup_cpu(struct uae_prefs *p)
{
	if (p->cpu_cycle_exact)
		p->cpu_compatible = true;
}
TCHAR *buf_out(TCHAR *buffer, int *bufsize, const TCHAR *format, ...)
{
	va_list ap;
	if (!buffer)
		return NULL;
	va_start(ap, format);
	vsnprintf(buffer, (*bufsize) - 1, format, ap);
	va_end(ap);
	*bufsize -= strlen(buffer);
	return buffer + strlen(buffer);
}


/* ------------------------------------------------------------------ */
/* Physical memory                                                     */

static void bus_report(uint32_t pa, int size, int write, uint32_t data, int berr)
{
	int kind = uae030_bus_walk ? UAE030_KIND_WALK
		 : uae030_bus_ifetch ? UAE030_KIND_IFETCH : UAE030_KIND_CPU;
	int fc = uae030_bus_walk ? 5 : uae030_bus_fc;
	if (bus_hook)
		bus_hook(pa, size, write, data, fc, kind, berr, hook_user);
	if (kind != UAE030_KIND_CPU)
		return;
	if (op_pend.active) {
		/* one piece of a misaligned operand: remember where it began */
		if (!op_pend.have) {
			op_pend.have = 1;
			op_pend.pa = pa;
			op_pend.fc = fc;
		}
		op_pend.berr |= berr;
		return;
	}
	if (op_hook)
		op_hook(pa, size, write, data, fc, berr, hook_user);
}

/* A misaligned operand, bracketing the core's own split. */
static int op_size, op_write;
static uint32_t op_value;

static void op_begin(int size, int write, uint32_t value)
{
	op_pend.active = 1;
	op_pend.have = 0;
	op_pend.berr = 0;
	op_size = size;
	op_write = write;
	op_value = value;
}

static void op_end(uint32_t value)
{
	op_pend.active = 0;
	if (op_pend.have && op_hook)
		op_hook(op_pend.pa, op_size, op_write, value, op_pend.fc, op_pend.berr, hook_user);
	op_pend.have = 0;
}

/* An operand the core abandoned part way through (a bus error longjmps out
 * of the split): report what it reached, once. */
static void op_flush(void)
{
	if (op_pend.active)
		op_end(op_write ? op_value : 0);
}

extern uae_u16 __real_mmu030_get_word_unaligned(uaecptr, uae_u32, int);
extern uae_u32 __real_mmu030_get_long_unaligned(uaecptr, uae_u32, int);
extern void __real_mmu030_put_word_unaligned(uaecptr, uae_u16, uae_u32, int);
extern void __real_mmu030_put_long_unaligned(uaecptr, uae_u32, uae_u32, int);

uae_u16 __wrap_mmu030_get_word_unaligned(uaecptr a, uae_u32 fc, int fl)
{
	op_begin(2, 0, 0);
	uae_u16 v = __real_mmu030_get_word_unaligned(a, fc, fl);
	op_end(v);
	return v;
}
uae_u32 __wrap_mmu030_get_long_unaligned(uaecptr a, uae_u32 fc, int fl)
{
	op_begin(4, 0, 0);
	uae_u32 v = __real_mmu030_get_long_unaligned(a, fc, fl);
	op_end(v);
	return v;
}
void __wrap_mmu030_put_word_unaligned(uaecptr a, uae_u16 v, uae_u32 fc, int fl)
{
	op_begin(2, 1, v);
	__real_mmu030_put_word_unaligned(a, v, fc, fl);
	op_end(v);
}
void __wrap_mmu030_put_long_unaligned(uaecptr a, uae_u32 v, uae_u32 fc, int fl)
{
	op_begin(4, 1, v);
	__real_mmu030_put_long_unaligned(a, v, fc, fl);
	op_end(v);
}

/* The physical address map: the extra regions first, then RAM from 0, or a
 * window folded onto it. Returns where the access's first byte is, or NULL
 * for a bus error. */
static inline uint8_t *map_ptr(uint32_t a, int size)
{
	for (int i = 0; i < nregion; i++) {
		if ((a & region[i].mask) != region[i].base)
			continue;
		if (region[i].berr)
			return NULL;
		uint32_t o = a % region[i].size;
		if ((uint64_t)o + size > region[i].size)
			return NULL;
		return region[i].mem + o;
	}
	if (alias_window && a < alias_window)
		a %= ram_size;
	if (a < ram_size && (uint64_t)a + size <= ram_size)
		return ram + a;
	return NULL;
}

static inline bool in_ram(uint32_t a, int size)
{
	return map_ptr(a, size) != NULL;
}

static uint32_t phys_read(uint32_t a, int size)
{
	uint8_t *p = map_ptr(a, size);
	if (!p) {
		bool ins = uae030_bus_ifetch || (!uae030_bus_walk && (uae030_bus_fc & 3) == 2);
		bus_report(a, size, 0, 0, 1);
		/* The exception longjmps out of whoever set these: a table search
		 * caught by the MMU code would otherwise leave every later access
		 * labelled a table search access. */
		uae030_bus_walk = 0;
		uae030_bus_ifetch = 0;
		hardware_exception2(a, 0, true, ins, size == 1 ? sz_byte : size == 2 ? sz_word : sz_long);
		return 0xffffffff;
	}
	uint32_t v = 0;
	for (int i = 0; i < size; i++)
		v = (v << 8) | p[i];
	bus_report(a, size, 0, v, 0);
	return v;
}

static void phys_write(uint32_t a, int size, uint32_t v)
{
	uint8_t *p = map_ptr(a, size);
	if (!p) {
		bus_report(a, size, 1, v, 1);
		uae030_bus_walk = 0;
		hardware_exception2(a, v, false, false, size == 1 ? sz_byte : size == 2 ? sz_word : sz_long);
		return;
	}
	bus_report(a, size, 1, v, 0);
	for (int i = size - 1; i >= 0; i--) {
		p[i] = (uint8_t)v;
		v >>= 8;
	}
}

uae_u32 memory_get_long(uaecptr a) { return phys_read(a, 4); }
uae_u32 memory_get_word(uaecptr a) { return phys_read(a, 2); }
uae_u32 memory_get_byte(uaecptr a) { return phys_read(a, 1); }
/* The core reads the instruction stream through these when it bypasses the
 * MMU's fetch routines -- the instruction cache's burst fill does -- so they
 * are instruction fetches whatever the last function code was. */
static uint32_t ifetch_read(uint32_t a, int size)
{
	int f = uae030_bus_ifetch, fc = uae030_bus_fc;
	uae030_bus_ifetch = 1;
	uae030_bus_fc = regs.s ? 6 : 2;
	uint32_t v = phys_read(a, size);
	uae030_bus_ifetch = f;
	uae030_bus_fc = fc;
	return v;
}
uae_u32 memory_get_longi(uaecptr a) { return ifetch_read(a, 4); }
uae_u32 memory_get_wordi(uaecptr a) { return ifetch_read(a, 2); }
void memory_put_long(uaecptr a, uae_u32 v) { phys_write(a, 4, v); }
void memory_put_word(uaecptr a, uae_u32 v) { phys_write(a, 2, v & 0xffff); }
void memory_put_byte(uaecptr a, uae_u32 v) { phys_write(a, 1, v & 0xff); }

/* cycle-exact access paths (not selected by this harness, but linked) */
uae_u32 wait_cpu_cycle_read(uaecptr a, int mode)
{
	return mode < 0 ? phys_read(a, 4) : mode > 0 ? phys_read(a, 2) : phys_read(a, 1);
}
void wait_cpu_cycle_write(uaecptr a, int mode, uae_u32 v)
{
	if (mode < 0) phys_write(a, 4, v); else if (mode > 0) phys_write(a, 2, v & 0xffff); else phys_write(a, 1, v & 0xff);
}
uae_u32 wait_cpu_cycle_read_ce020(uaecptr a, int mode) { return wait_cpu_cycle_read(a, mode); }
void wait_cpu_cycle_write_ce020(uaecptr a, int mode, uae_u32 v) { wait_cpu_cycle_write(a, mode, v); }

uae_u8 *memory_get_real_address(uaecptr a) { return map_ptr(a, 1); }
int memory_valid_address(uaecptr a, uae_u32 s) { return in_ram(a, s); }
void memory_clear(void) { /* keep the loaded image across the reset */ }

/* debugger / logging peeks: no bus activity */
static uint8_t peek8(uint32_t a) { uint8_t *p = map_ptr(a, 1); return p ? *p : 0; }
uint32_t STMemory_ReadLong(uint32_t a) { return (peek8(a) << 24) | (peek8(a + 1) << 16) | (peek8(a + 2) << 8) | peek8(a + 3); }
uint16_t STMemory_ReadWord(uint32_t a) { return (peek8(a) << 8) | peek8(a + 1); }
uint8_t STMemory_ReadByte(uint32_t a) { return peek8(a); }

static uae_u32 REGPARAM2 flat_lget(uaecptr a) { return phys_read(a, 4); }
static uae_u32 REGPARAM2 flat_wget(uaecptr a) { return phys_read(a, 2); }
static uae_u32 REGPARAM2 flat_bget(uaecptr a) { return phys_read(a, 1); }
static void REGPARAM2 flat_lput(uaecptr a, uae_u32 v) { phys_write(a, 4, v); }
static void REGPARAM2 flat_wput(uaecptr a, uae_u32 v) { phys_write(a, 2, v & 0xffff); }
static void REGPARAM2 flat_bput(uaecptr a, uae_u32 v) { phys_write(a, 1, v & 0xff); }
static int REGPARAM2 flat_check(uaecptr a, uae_u32 s) { return in_ram(a, s); }
static uae_u8 *REGPARAM2 flat_xlate(uaecptr a) { uint8_t *p = map_ptr(a, 1); return p ? p : ram; }

static addrbank flat_bank = {
	flat_lget, flat_wget, flat_bget, flat_lput, flat_wput, flat_bput,
	flat_xlate, flat_check, NULL, _T("flat"), _T("flat RAM"),
	flat_lget, flat_wget, ABFLAG_RAM
};
/* newcpu.c refuses to start from a PC in dummy_bank: keep it distinct */
addrbank dummy_bank;

/* ------------------------------------------------------------------ */
/* Harness API                                                         */

/* Hook point patched into m68k_run_mmu030() at the top of each instruction. */
void uae030_insn_boundary(void)
{
	static int last_dh, last_dm, last_ih, last_im;
	uae030_state s;
	op_flush();
	uae030_get_state(&s);
	s.d_hit = CpuInstruction.D_Cache_hit - last_dh;
	s.d_miss = CpuInstruction.D_Cache_miss - last_dm;
	s.i_hit = CpuInstruction.I_Cache_hit - last_ih;
	s.i_miss = CpuInstruction.I_Cache_miss - last_im;
	last_dh = CpuInstruction.D_Cache_hit;
	last_dm = CpuInstruction.D_Cache_miss;
	last_ih = CpuInstruction.I_Cache_hit;
	last_im = CpuInstruction.I_Cache_miss;
	if (insn_hook && insn_hook(&s, hook_user)) {
		run_status = 0;
		longjmp(run_exit, 1);
	}
	insn_count++;
}

void uae030_init(uint32_t ram_bytes, int data_cache)
{
	ram_size = ram_bytes;
	ram = calloc(1, ram_bytes);
	for (int i = 0; i < MEMORY_BANKS; i++)
		mem_banks[i] = &flat_bank;
	for (int i = 0; i < 65536; i++) {
		ce_banktype[i] = CE_MEMBANK_FAST32;
		ce_cachable[i] = CACHE_ENABLE_ALL;
	}

	memset(&changed_prefs, 0, sizeof(changed_prefs));
	changed_prefs.cpu_model = 68030;
	changed_prefs.mmu_model = 68030;
	changed_prefs.fpu_model = 0;
	changed_prefs.cpu_compatible = true;     /* prefetch + caches: op_smalltbl_34 */
	changed_prefs.cpu_cycle_exact = false;
	changed_prefs.cpu_memory_cycle_exact = false;
	changed_prefs.cpu_data_cache = data_cache != 0;
	changed_prefs.address_space_24 = false;
	changed_prefs.int_no_unimplemented = true;
	changed_prefs.fpu_no_unimplemented = true;
	changed_prefs.m68k_speed = 0;
	changed_prefs.cpu_clock_multiplier = 2 << 8;
	changed_prefs.cachesize = 0;
	changed_prefs.fpu_mode = 1;
	currprefs = changed_prefs;

	init_m68k();
}

void uae030_set_alias(uint32_t window) { alias_window = window; }

int uae030_add_region(uint32_t base, uint32_t mask, uint32_t size, int berr)
{
	if (nregion >= UAE030_NREG)
		return -1;
	region[nregion].base = base & mask;
	region[nregion].mask = mask;
	region[nregion].size = berr ? 0 : size;
	region[nregion].berr = berr;
	region[nregion].mem = berr ? NULL : calloc(1, size);
	return nregion++;
}

uint8_t *uae030_region_mem(int i) { return (i >= 0 && i < nregion) ? region[i].mem : NULL; }

void uae030_walk_info(int *fc, int *insn)
{
	*fc = uae030_walk_fc;
	*insn = uae030_walk_insn;
}

uint32_t uae030_cacr(void) { return regs.cacr; }

extern void uae030_install_mmu(uae_u32 tc, uae_u64 crp, uae_u64 srp, uae_u32 tt0, uae_u32 tt1, uae_u16 mmusr);
void uae030_set_mmu(const uae030_state *s)
{
	uae030_install_mmu(s->tc, s->crp, s->srp, s->tt0, s->tt1, s->mmusr);
}
uint8_t *uae030_ram(void) { return ram; }
uint32_t uae030_ram_size(void) { return ram_size; }

int uae030_load(const char *path, uint32_t phys)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return -1;
	size_t n = fread(ram + phys, 1, ram_size - phys, f);
	fclose(f);
	return (int)n;
}

void uae030_set_hooks(uae030_insn_hook ih, uae030_bus_hook bh, void *user)
{
	insn_hook = ih;
	bus_hook = bh;
	hook_user = user;
}

void uae030_set_op_hook(uae030_op_hook oh) { op_hook = oh; }
void uae030_set_exc_hook(uae030_exc_hook eh) { exc_hook = eh; }

void uae030_get_state(uae030_state *s)
{
	MakeSR();
	s->pc = m68k_getpc();
	for (int i = 0; i < 8; i++) {
		s->d[i] = m68k_dreg(regs, i);
		s->a[i] = m68k_areg(regs, i);
	}
	s->sr = regs.sr;
	s->usp = regs.s ? regs.usp : s->a[7];
	s->isp = (regs.s && !regs.m) ? s->a[7] : regs.isp;
	s->msp = (regs.s && regs.m) ? s->a[7] : regs.msp;
	s->vbr = regs.vbr;
	s->sfc = regs.sfc;
	s->dfc = regs.dfc;
	s->cacr = regs.cacr;
	s->caar = regs.caar;
	s->tc = tc_030;
	s->tt0 = tt0_030;
	s->tt1 = tt1_030;
	s->crp = crp_030;
	s->srp = srp_030;
	s->mmusr = mmusr_030;
	s->insn_count = insn_count;
}

void uae030_set_state(const uae030_state *s)
{
	int sb = (s->sr >> 13) & 1, mb = (s->sr >> 12) & 1;

	op_flush();
	/* Leave nothing of the last instruction behind: no pending trace, no
	 * STOP, no restart state. */
	regs.stopped = 0;
	regs.t0 = regs.t1 = 0;
	unset_special(SPCFLAG_TRACE | SPCFLAG_DOTRACE | SPCFLAG_STOP);
	for (int i = 0; i < 8; i++)
		m68k_dreg(regs, i) = s->d[i];
	for (int i = 0; i < 7; i++)
		m68k_areg(regs, i) = s->a[i];
	regs.usp = s->usp;
	regs.isp = s->isp;
	regs.msp = s->msp;
	/* S and M first, so that MakeFromSR() swaps no stack pointer, and A7 is
	 * the one they select. */
	regs.s = sb;
	regs.m = mb;
	m68k_areg(regs, 7) = sb ? (mb ? s->msp : s->isp) : s->usp;
	regs.vbr = s->vbr;
	regs.sfc = s->sfc & 7;
	regs.dfc = s->dfc & 7;
	regs.cacr = s->cacr;
	regs.caar = s->caar;
	set_cpu_caches(true);
	/* Refetch at the new PC while the trace bits are still clear: the core
	 * counts a refill as a change of flow, and under T0 that would arm a
	 * trace the instruction never asked for. */
	m68k_setpc_normal(s->pc);
	mmu030_opcode_stageb = -1;
	mmu030_fake_prefetch = -1;
	fill_prefetch();
	/* Then the status register: MakeFromSR() takes the flags, the mask and
	 * the trace bits from it. */
	regs.intmask = (s->sr >> 8) & 7;
	regs.sr = s->sr;
	MakeFromSR();
	/* The core arms tracing between instructions, before the hook runs: it
	 * latches the address of the instruction about to be traced (the format
	 * $2 frame's address field) and, for T1, schedules the trace exception
	 * for after it. A state installed here missed that step, so it is done
	 * here, the same way. */
	if (regs.t1 || regs.t0) {
		regs.trace_pc = s->pc;
		if (regs.t1) {
			unset_special(SPCFLAG_TRACE);
			set_special(SPCFLAG_DOTRACE);
		}
	}
}

static struct {
	int n, i, started;
	uae030_setup_fn setup;
	uae030_result_fn result;
	void *user;
} each;

static int each_hook(const uae030_state *s, void *u)
{
	(void)u;
	if (each.started) {
		each.result(each.i, s, each.user);
		each.i++;
	}
	if (each.i >= each.n)
		return 1;
	uae030_state st;
	memset(&st, 0, sizeof st);
	each.setup(each.i, &st, each.user);
	each.started = 1;
	uae030_set_state(&st);
	return 0;
}

int uae030_run_each(int ntests, uae030_setup_fn setup, uae030_result_fn result,
		    void *user, int *done)
{
	each.n = ntests;
	each.i = 0;
	each.started = 0;
	each.setup = setup;
	each.result = result;
	each.user = user;
	insn_hook = each_hook;
	hook_user = user;
	int r = uae030_run();
	if (done)
		*done = each.i;
	return r;
}

int uae030_run(void)
{
	if (setjmp(run_exit))
		return run_status;
	quit_program = UAE_RESET_HARD;
	m68k_go(true);
	return 1;
}
