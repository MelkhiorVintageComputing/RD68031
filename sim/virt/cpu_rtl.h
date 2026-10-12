// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// rd-virt -- the RTL socket: rd68031_top under Verilator, with a pin-level bus
// agent in front of the machine. cpu_rtl.cpp says how the agent answers.
#ifndef RDVIRT_CPU_RTL_H
#define RDVIRT_CPU_RTL_H

#include <memory>
#include <string>

#include "cpu_if.h"

struct RtlOptions {
  bool ram_sync = false;   // RAM ends its cycles with STERM rather than DSACK
  bool burst = false;      // ... and answers CBREQ with CBACK (needs ram_sync)
  int  ram_waits = 0;      // wait states before the first (or only) beat
  int  burst_waits = 0;    // ... and before each later beat of a burst
  int  io_waits = 1;       // wait states on the devices
  bool cdis = false;       // hold CDIS asserted: both caches off (UM 5.11)
  uint64_t watchdog = 2000000;  // clocks without a boundary before giving up
  std::string vcd;
  uint64_t vcd_from = 0;
};

class Machine;
struct RtlModel;

class RtlCpu : public CpuIf {
 public:
  RtlCpu(Machine *m, const RtlOptions &o);
  ~RtlCpu() override;
  const char *name() const override { return "rtl"; }
  StepResult reset() override;
  StepResult run_until_retire() override;
  void set_ipl(int level) override;
  const CpuRegs &regs() override { return regs_; }
  uint64_t retired() const override { return retired_; }
  int last_iack() const override { return iack_; }
  void inject_interrupt(int) override {}
  void set_undefined(const CpuRegs &) override {}
  // Whether the last step began exception processing (a fault or an
  // interrupt): its frame's internal words are not compared.
  bool took_exception() const { return took_exc_; }
  uint64_t clocks() const;

 private:
  Machine *m_;
  RtlOptions o_;
  std::unique_ptr<RtlModel> v_;
  CpuRegs regs_;
  uint64_t retired_ = 0;
  int iack_ = 0;
  bool took_exc_ = false;
  void snapshot();
};

#endif
