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
static uae030_insn_hook insn_hook;
static uae030_bus_hook bus_hook;
static void *hook_user;
static jmp_buf run_exit;
static int run_status;
static uint64_t insn_count;

/* Set by the patched cpummu030.c right before each physical access
 * (uae030_bus_fc = fc), and to -1 around table-search descriptor accesses. */
int uae030_bus_fc = 5;
int uae030_bus_walk = 0;

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
void DebugUI_Exceptions(int nr, long pc) { (void)nr; (void)pc; }
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
/* Flat physical memory                                                */

static void bus_report(uint32_t pa, int size, int write, uint32_t data, int berr)
{
	if (bus_hook)
		bus_hook(pa, size, write, data, uae030_bus_walk ? 5 : uae030_bus_fc,
			 uae030_bus_walk ? UAE030_KIND_WALK : UAE030_KIND_CPU, berr, hook_user);
}

static inline bool in_ram(uint32_t a, int size)
{
	return a < ram_size && (uint64_t)a + size <= ram_size;
}

static uint32_t phys_read(uint32_t a, int size)
{
	if (!in_ram(a, size)) {
		bool ins = !uae030_bus_walk && (uae030_bus_fc & 3) == 2;
		bus_report(a, size, 0, 0, 1);
		hardware_exception2(a, 0, true, ins, size == 1 ? sz_byte : size == 2 ? sz_word : sz_long);
		return 0xffffffff;
	}
	uint32_t v = 0;
	for (int i = 0; i < size; i++)
		v = (v << 8) | ram[a + i];
	bus_report(a, size, 0, v, 0);
	return v;
}

static void phys_write(uint32_t a, int size, uint32_t v)
{
	if (!in_ram(a, size)) {
		bus_report(a, size, 1, v, 1);
		hardware_exception2(a, v, false, false, size == 1 ? sz_byte : size == 2 ? sz_word : sz_long);
		return;
	}
	bus_report(a, size, 1, v, 0);
	for (int i = size - 1; i >= 0; i--) {
		ram[a + i] = (uint8_t)v;
		v >>= 8;
	}
}

uae_u32 memory_get_long(uaecptr a) { return phys_read(a, 4); }
uae_u32 memory_get_word(uaecptr a) { return phys_read(a, 2); }
uae_u32 memory_get_byte(uaecptr a) { return phys_read(a, 1); }
uae_u32 memory_get_longi(uaecptr a) { return phys_read(a, 4); }
uae_u32 memory_get_wordi(uaecptr a) { return phys_read(a, 2); }
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

uae_u8 *memory_get_real_address(uaecptr a) { return in_ram(a, 1) ? ram + a : NULL; }
int memory_valid_address(uaecptr a, uae_u32 s) { return in_ram(a, s); }
void memory_clear(void) { /* keep the loaded image across the reset */ }

/* debugger / logging peeks: no bus activity */
uint32_t STMemory_ReadLong(uint32_t a) { return in_ram(a, 4) ? (ram[a] << 24) | (ram[a + 1] << 16) | (ram[a + 2] << 8) | ram[a + 3] : 0; }
uint16_t STMemory_ReadWord(uint32_t a) { return in_ram(a, 2) ? (ram[a] << 8) | ram[a + 1] : 0; }
uint8_t STMemory_ReadByte(uint32_t a) { return in_ram(a, 1) ? ram[a] : 0; }

static uae_u32 REGPARAM2 flat_lget(uaecptr a) { return phys_read(a, 4); }
static uae_u32 REGPARAM2 flat_wget(uaecptr a) { return phys_read(a, 2); }
static uae_u32 REGPARAM2 flat_bget(uaecptr a) { return phys_read(a, 1); }
static void REGPARAM2 flat_lput(uaecptr a, uae_u32 v) { phys_write(a, 4, v); }
static void REGPARAM2 flat_wput(uaecptr a, uae_u32 v) { phys_write(a, 2, v & 0xffff); }
static void REGPARAM2 flat_bput(uaecptr a, uae_u32 v) { phys_write(a, 1, v & 0xff); }
static int REGPARAM2 flat_check(uaecptr a, uae_u32 s) { return in_ram(a, s); }
static uae_u8 *REGPARAM2 flat_xlate(uaecptr a) { return in_ram(a, 1) ? ram + a : ram; }

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

int uae030_run(void)
{
	if (setjmp(run_exit))
		return run_status;
	quit_program = UAE_RESET_HARD;
	m68k_go(true);
	return 1;
}
