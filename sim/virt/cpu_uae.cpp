// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// rd-virt -- the UAE030 socket: the WinUAE MC68030 core of
// tools/cosim/uae030 (MMU and data cache on, as a real 030) behind cpu_if.h.
//
// The library enters the core once and stays in it; the only way back out is
// the instruction hook. So the core runs on its own stack, as a coroutine:
// run_until_retire() switches to it, and the hook switches back at the next
// boundary. Everything the core does between two switches -- its bus
// accesses, its exceptions and the longjmps they make -- stays on its stack.
//
// Linked with the GPL oracle, so GPL-2.0-or-later like everything else that
// links it (doc/oracles.md).

#include "cpu_uae.h"

#include <ucontext.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" {
#include "uae030.h"
}

#include "machine.h"

namespace {

UaeCpu *self;                // the library is a singleton, and so is this
ucontext_t main_ctx, core_ctx;
const size_t CORE_STACK = 16u << 20;

}  // namespace

// ---------------------------------------------------------------------------
// The bus: RAM is the library's own (the machine was built on it); everything
// else is the machine's devices or a hole.
// ---------------------------------------------------------------------------
static int ext_read(uint32_t pa, int size, uint32_t *v, void *user) {
  Machine *m = static_cast<Machine *>(user);
  return m->io_read(pa, size, *v) ? 1 : 0;
}

static int ext_write(uint32_t pa, int size, uint32_t v, void *user) {
  Machine *m = static_cast<Machine *>(user);
  bool berr = m->io_write(pa, size, v);
  if (!berr && self) self->io_written();
  return berr ? 1 : 0;
}

static void bus_hook(uint32_t pa, int size, int write, uint32_t data, int fc,
                     int kind, int berr, void *user) {
  (void)user;
  if (!self) return;
  BusRec r;
  r.step = self->retired();
  r.addr = pa;
  r.data = data;
  r.size = uint8_t(size);
  r.write = uint8_t(write);
  r.fc = uint8_t(fc);
  r.berr = uint8_t(berr);
  r.kind = kind == UAE030_KIND_WALK ? 'T' : kind == UAE030_KIND_IFETCH ? 'F' : 'D';
  self->machine()->log(r);
}

static void exc_hook(int vector, void *user) {
  (void)user;
  if (self) self->exc(vector);
}

static int insn_hook(const uae030_state *s, void *user) {
  (void)user;
  return self->hook(s);
}

static void core_main() {
  uae030_run();
  // A halt (double bus fault): park here for good.
  for (;;) {
    self->halted_ = true;
    swapcontext(&core_ctx, &main_ctx);
  }
}

UaeCpu::UaeCpu(Machine *m, bool dcache) : m_(m) {
  self = this;
  (void)dcache;
  uae030_set_ext_bus(ext_read, ext_write, m);
  // CIIN on the device window, as the RTL's bus agent asserts it.
  uae030_set_cachable(0xFF000000u, 0x01000000u, 0);
  uae030_set_hooks(insn_hook, bus_hook, nullptr);
  uae030_set_exc_hook(exc_hook);
  stack_ = malloc(CORE_STACK);
}

UaeCpu::~UaeCpu() { free(stack_); }

void UaeCpu::init_library(uint32_t ram_bytes, bool dcache) {
  uae030_init(ram_bytes, dcache ? 1 : 0);
}

uint8_t *UaeCpu::library_ram() { return uae030_ram(); }

void UaeCpu::set_short_frames(bool on) { uae030_set_short_frames(on ? 1 : 0); }

void UaeCpu::publish(const uae030_state *s) {
  CpuRegs &r = regs_;
  r.pc = s->pc;
  for (int i = 0; i < 8; i++) { r.d[i] = s->d[i]; r.a[i] = s->a[i]; }
  r.usp = s->usp; r.isp = s->isp; r.msp = s->msp;
  r.sr = s->sr;
  r.vbr = s->vbr; r.sfc = s->sfc; r.dfc = s->dfc; r.cacr = s->cacr; r.caar = s->caar;
  r.tc = s->tc; r.tt0 = s->tt0; r.tt1 = s->tt1; r.crp = s->crp; r.srp = s->srp;
  r.mmusr = s->mmusr;
  r.stopped = uae030_stopped() != 0;
  // STOP leaves the core's program counter on the STOP itself, and the core
  // executes it again at every boundary until an interrupt moves it on (the
  // stacked PC is then the next instruction). The processor's boundary is
  // after the STOP (PRM 6), which is what is reported.
  if (r.stopped) r.pc += 4;
  last_vec_ = vec_now_;
  vec_now_ = -1;
  // What ended at this boundary is what was about to run at the last one.
  last_op_ = next_op_;
  next_op_ = uae030_next_opcode();
}

int UaeCpu::pending_level() {
  if (inject_) { int l = inject_; inject_ = 0; return l; }
  if (follower_) return 0;
  int mask = (regs_.sr >> 8) & 7;
  return (ipl_ > mask || (ipl_ == 7 && prev_ipl_ != 7)) ? ipl_ : 0;
}

void UaeCpu::yield(StepResult r) {
  result_ = r;
  swapcontext(&core_ctx, &main_ctx);
}

// At every boundary of the core. Returns to it only when the socket's caller
// wants the next instruction run.
int UaeCpu::hook(const uae030_state *s) {
  bool stopped = uae030_stopped() != 0;
  if (!(stopped && stop_reported_)) {
    publish(s);
    retired_++;
    iack_ = 0;
    stop_reported_ = stopped;
    yield(StepResult::Boundary);
  }
  for (;;) {
    int l = pending_level();
    if (l) {
      prev_ipl_ = ipl_;
      uae030_interrupt(l);
      uae030_state st;
      uae030_get_state(&st);
      stop_reported_ = false;
      publish(&st);
      retired_++;
      iack_ = l;
      yield(StepResult::Boundary);
      continue;
    }
    if (uae030_stopped()) {
      yield(StepResult::Stopped);
      continue;
    }
    break;
  }
  prev_ipl_ = ipl_;
  return 0;
}

StepResult UaeCpu::reset() {
  getcontext(&core_ctx);
  core_ctx.uc_stack.ss_sp = stack_;
  core_ctx.uc_stack.ss_size = CORE_STACK;
  core_ctx.uc_link = &main_ctx;
  makecontext(&core_ctx, core_main, 0);
  retired_ = 0;
  // The reset itself is the first boundary; retired() counts from there.
  StepResult r = run_until_retire();
  retired_ = 0;
  for (BusRec &b : m_->ring) b.step = 0;
  return r;
}

StepResult UaeCpu::run_until_retire() {
  if (halted_) return StepResult::Halted;
  swapcontext(&main_ctx, &core_ctx);
  return halted_ ? StepResult::Halted : result_;
}

void UaeCpu::set_ipl(int level) { ipl_ = level; }

void UaeCpu::inject_interrupt(int level) { inject_ = level; }

void UaeCpu::set_undefined(const CpuRegs &r) {
  // Only from a boundary, which is where the core is parked; and only what
  // differs, since installing a state refetches and installing the MMU's
  // registers decodes them.
  uae030_state s;
  uae030_get_state(&s);
  if (s.usp != r.usp || s.msp != r.msp || s.caar != r.caar || s.sfc != r.sfc ||
      s.dfc != r.dfc) {
    s.usp = r.usp;
    s.msp = r.msp;
    s.caar = r.caar;
    s.sfc = r.sfc;
    s.dfc = r.dfc;
    uae030_set_state(&s);
  }
  uint32_t tc = (r.tc & 0x7FFFFFFFu) | (s.tc & 0x80000000u);
  uint32_t tt0 = (r.tt0 & ~0x8000u) | (s.tt0 & 0x8000u);
  uint32_t tt1 = (r.tt1 & ~0x8000u) | (s.tt1 & 0x8000u);
  if (tc != s.tc || r.crp != s.crp || r.srp != s.srp || tt0 != s.tt0 || tt1 != s.tt1 ||
      r.mmusr != s.mmusr) {
    s.tc = tc;
    s.crp = r.crp;
    s.srp = r.srp;
    s.tt0 = tt0;
    s.tt1 = tt1;
    s.mmusr = r.mmusr;
    uae030_set_mmu(&s);
  }
  uae030_get_state(&s);
  publish(&s);
}

void UaeCpu::io_written() {}

void UaeCpu::poke(uint32_t addr, int size, uint32_t v) { uae030_poke(addr, size, v); }
