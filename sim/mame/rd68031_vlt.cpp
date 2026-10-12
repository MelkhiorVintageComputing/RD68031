// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 in MAME (M14) -- rd68031_top under Verilator, and a pin-level bus
// agent that turns its bus cycles into the machine's accesses. Built into a
// shared object (sim/mame/build.sh vlt) that MAME's rd68031_device loads; the
// interface is sim/mame/rd68031_vlt.h.
//
// THE AGENT answers every cycle as a 32-bit asynchronous port (UM 7.2-7.3),
// like sim/models/rd68031_slave.sv and rd-virt's (sim/virt/cpu_rtl.cpp), but
// with the machine's accesses made at the moment a board would make them:
//   - a read is made once, when AS is asserted (the address, FC, SIZ and R/W
//     are valid then, UM 7.2.1), so a device register with a side effect on
//     read sees exactly one read per bus cycle. Where the machine says the
//     address is cachable, the whole aligned long word is read, as a cachable
//     read on a 32-bit port must supply it (UM 6.1); elsewhere only the bytes
//     the cycle asks for, and CIIN is asserted (UM 5.7.1).
//   - a write is made once, when the core drives the data bus.
//   - the cycle is then terminated, `waits` rising edges later: DSACK1/0, or
//     BERR when the machine signalled a bus error during the access -- this
//     is how MAME's bus-error input, pulsed from a read or write handler,
//     reaches the core on the cycle in flight.
//   - CPU space: an interrupt acknowledge asks the machine for the vector and
//     ends with AVEC (an autovector), the vector on the data bus with DSACK,
//     or BERR (spurious, UM 8.1.9); every other CPU-space cycle -- a breakpoint
//     acknowledge, a coprocessor with none attached -- ends with BERR.
//
// A BOUNDARY is the core harness's: a microword that decodes retires without a
// fault (`retire && at_decode && !fault_now`), sampled after the falling edge.
//
// Each half clock: the agent's registered state moves on the PRE-edge pins,
// the edge is evaluated, then the agent's combinational outputs are
// recomputed from the new pins and evaluated again (as in cpu_rtl.cpp).

#include "rd68031_vlt.h"

#include "Vrd68031_top.h"
#include "Vrd68031_top___024root.h"
#include "verilated.h"

#define SEQ(x) top->rootp->rd68031_top__DOT__u_seq__DOT__##x
#define MMU(x) top->rootp->rd68031_top__DOT__u_mmu__DOT__##x
#define IFU(x) top->rootp->rd68031_top__DOT__u_ifu__DOT__##x

namespace {

class Agent : public rd68031_vlt {
 public:
  explicit Agent(rd68031_vlt_bus *b) : bus(b) {
    top = new Vrd68031_top{&ctx};
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
    top->cdis_n_i = 1;
    top->mmudis_n_i = 1;
    top->eval();
  }
  ~Agent() override {
    top->final();
    delete top;
  }

  void power_on(int n) override {
    top->rst_n = 0;
    active = false;
    for (int i = 0; i < n; i++) {
      half(false);
      half(true);
    }
    top->rst_n = 1;
    top->eval();
  }

  void set_ipl(int level) override {
    top->ipl_n_i = ~level & 7;
    ipl_chg = true;
  }

  bool clock() override {
    half(false);
    bool b = SEQ(retire) && SEQ(at_decode) && !SEQ(fault_now);
    half(true);
    return b;
  }

  bool stopped() const override { return SEQ(stopped_q) && !active; }
  bool halted() const override { return SEQ(dbf_q); }
  uint32_t pc() const override { return IFU(pc_d); }
  uint64_t clocks() const override { return nclk; }
  void set_waits(int w) override { waits = unsigned(w < 0 ? 0 : w); }

  void regs(rd68031_vlt_regs &r) const override {
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
  }

 private:
  VerilatedContext ctx;
  Vrd68031_top *top;
  rd68031_vlt_bus *bus;
  uint64_t nclk = 0;
  unsigned waits = 0;
  bool ipl_chg = false;

  // The cycle in flight.
  enum Kind { MEM, IACK, CPUX };
  bool active = false, rd = true, done = false, answering = false;
  bool berr = false, avec = false, ciin = false;
  Kind kind = MEM;
  uint32_t addr = 0, mask = 0, rdata = 0;
  int fc = 0;
  unsigned wait_cnt = 0;

  bool sel() const { return top->as_oe && !top->as_n_o; }

  void start_cycle() {
    active = true;
    addr = top->a_o;
    fc = top->fc_o;
    rd = top->rw_o;
    done = answering = berr = avec = ciin = false;
    wait_cnt = 0;
    rdata = 0;
    unsigned off = addr & 3u, n = top->siz_o ? top->siz_o : 4u;
    if (n > 4 - off) n = 4 - off;
    mask = 0;
    for (unsigned j = off; j < off + n; j++) mask |= 0xFFu << (8 * (3 - j));
    if (fc == 7) {
      done = true;
      if (((addr >> 16) & 0xF) == 0xF) {
        kind = IACK;
        int v = bus->iack((addr >> 1) & 7);
        if (v == -1) avec = true;
        else if (v < 0) berr = true;
        else rdata = uint32_t(v & 0xFF) * 0x01010101u;  // whichever lane SIZ/A1:A0 pick
      } else {
        kind = CPUX;
        berr = true;
      }
      return;
    }
    kind = MEM;
    if (rd) {
      ciin = !bus->cacheable(addr);
      rdata = bus->read(addr, fc, ciin ? mask : 0xFFFFFFFFu, &berr);
      done = true;
    }
  }

  void pre_posedge() {
    if (!sel()) {
      answering = false;
      wait_cnt = 0;
      return;
    }
    if (done && !answering) {
      if (wait_cnt >= waits) answering = true;
      else wait_cnt++;
    }
  }

  bool comb() {
    bool s = sel();
    if (s && !active) start_cycle();
    else if (!s && active) active = false;
    if (s && kind == MEM && !rd && !done && top->d_oe) {
      bus->write(addr, fc, top->d_o, mask, &berr);
      done = true;
    }
    unsigned dsack = 3;
    bool b = true, av = true, ci = true;
    if (s && answering) {
      if (berr) b = false;
      else if (avec) av = false;
      else dsack = 0;
    }
    if (s && rd && ciin) ci = false;
    // Only a change of an input needs the model evaluated again.
    bool chg = top->dsack_n_i != dsack || top->berr_n_i != b || top->avec_n_i != av ||
               top->ciin_n_i != ci || top->d_i != rdata;
    top->dsack_n_i = dsack;
    top->berr_n_i = b;
    top->avec_n_i = av;
    top->ciin_n_i = ci;
    top->d_i = rdata;
    return chg;
  }

  void half(bool rising) {
    if (rising) pre_posedge();
    top->clk = rising;
    top->eval();
    if (comb() || ipl_chg) top->eval();
    ipl_chg = false;
    if (rising) nclk++;
  }
};

}  // namespace

extern "C" int rd68031_vlt_abi() { return RD68031_VLT_ABI; }
extern "C" rd68031_vlt *rd68031_vlt_create(rd68031_vlt_bus *bus) { return new Agent(bus); }
