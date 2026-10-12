// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// rd-virt -- the RTL socket: rd68031_top under Verilator, and a pin-level bus
// agent that answers it on behalf of the machine.
//
// THE AGENT answers the way sim/models/rd68031_slave.sv does, for the same
// reasons (UM 7.2-7.3), on a 32-bit port:
//   - RAM: asynchronous by default -- DSACK1/DSACK0 asserted on a rising edge
//     once `ram_waits` rising edges of AS have passed, never combinationally;
//     with `ram_sync`, STERM decoded from the address, held off `ram_waits`
//     rising edges, and with `burst` CBACK while the line has another long
//     word, the long words supplied in turn and wrapping within the line (UM
//     7.3.7). A read drives the whole aligned long word (UM 7.2.7).
//   - the devices: asynchronous, `io_waits` wait states, CIIN on every read
//     (UM 5.7.1: a device whose data must not be cached says so).
//   - CPU space: an interrupt acknowledge is answered with AVEC (every source
//     on this board is autovectored); any other CPU-space cycle -- a
//     breakpoint acknowledge, a coprocessor with none attached -- and every
//     hole in the map with BERR, asserted with AS as the core harness does.
// Writes are latched the way the model latches them: asynchronous on the
// falling edge with DS and the acknowledge, synchronous on the falling edge
// after the rising edge that took STERM (UM 7.3.2, 7.3.5).
//
// A BOUNDARY is the harness's: a microword that decodes retires without a
// fault (`retire && at_decode && !fault_now`), sampled after the falling
// edge; its writes land on the next rising edge, after which the programmer's
// model is read.
//
// Each half clock: the agent's registered state moves on the PRE-edge pins
// (its flip-flops and the core's sample the same instant), then the edge is
// evaluated, then the agent's combinational outputs are recomputed from the
// new pins and evaluated again.

#include "cpu_rtl.h"

#include <cstdio>
#include <cstring>

#include "Vrd68031_top.h"
#include "Vrd68031_top___024root.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include "machine.h"

#define SEQ(x) top->rootp->rd68031_top__DOT__u_seq__DOT__##x
#define MMU(x) top->rootp->rd68031_top__DOT__u_mmu__DOT__##x
#define IFU(x) top->rootp->rd68031_top__DOT__u_ifu__DOT__##x

struct RtlModel {
  VerilatedContext ctx;
  Vrd68031_top *top;
#if VM_TRACE
  VerilatedVcdC *vcd = nullptr;
#endif
  uint64_t clocks = 0, ts = 0;

  // The agent.
  enum Tgt { RAM, IO, HOLE, IACK, CPUX };
  bool active = false;
  Tgt tgt = HOLE;
  uint32_t addr = 0;
  int fc = 0, siz = 0;
  bool rd = true, sync = false, rmc = false;
  unsigned waits = 0, wait_cnt = 0;
  bool answering = false;
  unsigned scnt = 0, beat_cnt = 0, beat_d = 0;
  bool in_burst = false, sterm_taken = false, wrote = false;
  uint32_t io_val = 0, last_d = 0;
  // What the last step saw.
  int iack = 0;
  bool fault = false;
  uint64_t step = 0;

  Machine *m;
  RtlOptions o;
  RtlModel(Machine *mm, const RtlOptions &oo) : m(mm), o(oo) {
    top = new Vrd68031_top{&ctx};
  }
  ~RtlModel() {
#if VM_TRACE
    if (vcd) { vcd->close(); delete vcd; }
#endif
    top->final();
    delete top;
  }

  bool sel() const { return top->as_oe && !top->as_n_o; }

  static int siz_bytes(int s) { return s == 1 ? 1 : s == 2 ? 2 : s == 3 ? 3 : 4; }

  char kind() const {
    if (tgt == IACK) return 'I';
    if (rmc && fc == 5) return 'T';
    if ((fc & 3) == 2) return 'F';
    return 'D';
  }

  void log(uint32_t a, int size, bool write, uint32_t data, bool berr) {
    BusRec r;
    r.step = step;
    r.addr = a;
    r.data = data;
    r.size = uint8_t(size);
    r.write = write;
    r.fc = uint8_t(fc);
    r.berr = berr;
    r.kind = kind();
    m->log(r);
  }

  bool sterm_now() const {
    return sync && (scnt >= (beat_cnt == 0 ? waits : unsigned(o.burst_waits)));
  }
  bool cback_now() const {
    return sync && o.burst && sterm_now() && rd && !top->cbreq_n_o && (beat_cnt + 1) < 4;
  }

  uint32_t ram_long(uint32_t a) const {
    const uint8_t *p = m->ram + (a & ~3u);
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
  }
  uint32_t read_addr() const {
    bool whole = sync && (!top->cbreq_n_o || in_burst || beat_d != 0);
    if (!whole) return addr & ~3u;
    return (addr & ~0xFu) | ((((addr >> 2) + beat_d) & 3u) << 2);
  }

  void start_cycle() {
    active = true;
    addr = top->a_o;
    fc = top->fc_o;
    siz = top->siz_o;
    rd = top->rw_o;
    rmc = !top->rmc_n_o;
    wait_cnt = 0;
    answering = false;
    scnt = beat_cnt = beat_d = 0;
    in_burst = sterm_taken = wrote = false;
    sync = false;
    if (fc == 7) {
      if (((addr >> 16) & 0xF) == 0xF) {
        tgt = IACK;
        iack = (addr >> 1) & 7;
        waits = 0;
      } else {
        tgt = CPUX;
      }
      return;
    }
    switch (m->classify(addr)) {
      case Machine::Region::Ram:
        tgt = RAM;
        sync = o.ram_sync;
        waits = o.ram_waits;
        break;
      case Machine::Region::Io:
        tgt = IO;
        waits = o.io_waits;
        if (rd) {
          // Once per cycle: a device register may have a side effect on read.
          if (m->io_read(addr & ~3u, 4, io_val)) tgt = HOLE;
        }
        break;
      default:
        tgt = HOLE;
    }
  }

  void end_cycle() {
    active = false;
    if (tgt == HOLE || tgt == CPUX) {
      log(addr, siz_bytes(siz), !rd, rd ? 0 : top->d_o, true);
    } else if (rd && !(sync && beat_cnt > 0)) {
      log(addr, siz_bytes(siz), false, last_d, false);
    } else if (tgt == IACK) {
      log(addr, 0, false, 0, false);
    }
  }

  void do_write() {
    wrote = true;
    unsigned off = addr & 3u;
    int n = siz_bytes(siz);
    if (n > int(4 - off)) n = 4 - off;
    uint32_t d = top->d_o, v = 0;
    for (int j = 0; j < n; j++) {
      uint8_t b = uint8_t(d >> (8 * (3 - (off + j))));
      v = (v << 8) | b;
      if (tgt == RAM) m->ram[addr + j] = b;
    }
    if (tgt == IO) {
      m->io_write(addr, n, v);
      top->ipl_n_i = ~m->ipl() & 7;
    }
    log(addr, n, true, v, false);
  }

  void pre_posedge() {
    if (!sel()) {
      wait_cnt = 0; answering = false; scnt = 0; beat_cnt = 0;
      in_burst = false; sterm_taken = false;
      return;
    }
    if (!sync) {
      if (wait_cnt >= waits) answering = true;
      else wait_cnt++;
    } else {
      bool st = sterm_now(), cb = cback_now();
      sterm_taken = st && !rd;
      if (st) {
        if (rd) log(read_addr(), 4, false, ram_long(read_addr()), false);
        scnt = 0;
        beat_cnt++;
        if (cb) in_burst = true;
      } else {
        scnt++;
      }
    }
  }

  void pre_negedge() {
    if (!sel()) { beat_d = 0; return; }
    beat_d = beat_cnt;
    if (!rd && !wrote && (tgt == RAM || tgt == IO)) {
      if ((!sync && !top->ds_n_o && answering) || (sync && sterm_taken)) do_write();
    }
  }

  void comb() {
    bool s = sel();
    if (s && !active) start_cycle();
    else if (!s && active) end_cycle();
    unsigned dsack = 3;
    bool sterm = true, cback = true, ciin = true, avec = true, berr = true;
    uint32_t d = 0;
    if (s) {
      switch (tgt) {
        case RAM:
          if (rd) d = ram_long(read_addr());
          if (sync) { sterm = !sterm_now(); cback = !cback_now(); }
          else if (answering) dsack = 0;
          break;
        case IO:
          if (answering) dsack = 0;
          if (rd) { ciin = false; d = io_val; }
          break;
        case IACK:
          if (answering) avec = false;
          break;
        default:
          berr = false;
      }
      if (rd) last_d = d;
    }
    top->dsack_n_i = dsack;
    top->sterm_n_i = sterm;
    top->cback_n_i = cback;
    top->ciin_n_i = ciin;
    top->avec_n_i = avec;
    top->berr_n_i = berr;
    top->d_i = d;
  }

  void half(bool rising) {
    if (rising) pre_posedge();
    else pre_negedge();
    top->clk = rising;
    top->eval();
    comb();
    top->eval();
#if VM_TRACE
    if (vcd) vcd->dump(ts);
#endif
    ts += 5;
    if (rising) clocks++;
  }
};

RtlCpu::RtlCpu(Machine *m, const RtlOptions &o) : m_(m), o_(o) {
  v_.reset(new RtlModel(m, o));
  Vrd68031_top *top = v_->top;
  top->clk = 0;
  top->rst_n = 0;
  top->d_i = 0;
  top->dsack_n_i = 3;
  top->sterm_n_i = 1;
  top->ciin_n_i = 1;
  top->cback_n_i = 1;
  top->ipl_n_i = 7;
  top->avec_n_i = 1;
  top->br_n_i = 1;
  top->bgack_n_i = 1;
  top->berr_n_i = 1;
  top->reset_n_i = 1;
  top->halt_n_i = 1;
  top->cdis_n_i = o.cdis ? 0 : 1;
  top->mmudis_n_i = 1;
  top->eval();
#if VM_TRACE
  if (!o.vcd.empty()) {
    Verilated::traceEverOn(true);
  }
#endif
}

RtlCpu::~RtlCpu() {}

uint64_t RtlCpu::clocks() const { return v_->clocks; }

void RtlCpu::snapshot() {
  Vrd68031_top *top = v_->top;
  CpuRegs &r = regs_;
  for (int i = 0; i < 8; i++) r.d[i] = SEQ(dreg)[i];
  for (int i = 0; i < 7; i++) r.a[i] = SEQ(areg)[i];
  r.usp = SEQ(usp_q);
  r.isp = SEQ(isp_q);
  r.msp = SEQ(msp_q);
  r.sr = SEQ(sr_q);
  r.a[7] = (r.sr & 0x2000) ? ((r.sr & 0x1000) ? r.msp : r.isp) : r.usp;
  r.vbr = SEQ(vbr_q);
  r.sfc = SEQ(sfc_q);
  r.dfc = SEQ(dfc_q);
  r.cacr = SEQ(cacr_q);
  r.caar = SEQ(caar_q);
  r.pc = IFU(pc_d);
  r.tc = MMU(tc_q);
  r.crp = MMU(crp_q);
  r.srp = MMU(srp_q);
  r.tt0 = MMU(tt0_q);
  r.tt1 = MMU(tt1_q);
  r.mmusr = MMU(mmusr_q);
  r.stopped = SEQ(stopped_q);
}

StepResult RtlCpu::reset() {
  RtlModel &v = *v_;
  Vrd68031_top *top = v.top;
  top->rst_n = 0;
  for (int i = 0; i < 8; i++) { v.half(true); v.half(false); }
  top->rst_n = 1;
  top->eval();
  v.half(true);
  retired_ = 0;
  StepResult r = run_until_retire();
  retired_ = 0;
  return r;
}

StepResult RtlCpu::run_until_retire() {
  RtlModel &v = *v_;
  Vrd68031_top *top = v.top;
  v.iack = 0;
  v.fault = false;
  v.step = retired_;
  uint64_t start = v.clocks;
  unsigned stopped = 0;
#if VM_TRACE
  if (!o_.vcd.empty() && !v.vcd && retired_ >= o_.vcd_from) {
    v.vcd = new VerilatedVcdC;
    top->trace(v.vcd, 99);
    v.vcd->open(o_.vcd.c_str());
  }
#endif
  for (;;) {
    v.half(false);
    bool b = SEQ(retire) && SEQ(at_decode) && !SEQ(fault_now);
    if (SEQ(fault_now)) v.fault = true;
    v.half(true);
    if (b) {
      retired_++;
      iack_ = v.iack;
      took_exc_ = v.fault || v.iack;
      snapshot();
      return StepResult::Boundary;
    }
    if (SEQ(dbf_q)) {
      snapshot();
      fprintf(stderr, "rtl: double bus fault (halted)\n");
      return StepResult::Halted;
    }
    if (SEQ(stopped_q)) {
      if (++stopped > 16 && !v.active) {
        snapshot();
        return StepResult::Stopped;
      }
    } else {
      stopped = 0;
    }
    if (v.clocks - start > o_.watchdog) {
      snapshot();
      fprintf(stderr, "rtl: no boundary in %llu clocks (pc_d %08x)\n",
              (unsigned long long)o_.watchdog, regs_.pc);
      return StepResult::Halted;
    }
  }
}

void RtlCpu::set_ipl(int level) { v_->top->ipl_n_i = ~level & 7; }
