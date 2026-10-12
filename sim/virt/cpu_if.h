// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// rd-virt -- the CPU socket (doc/plan.md, Layer 3).
//
// One processor behind one interface, so that the machine, the solo runs and
// the lockstep driver do not care whether the processor is the RTL under
// Verilator or the UAE030 oracle. A STEP is one instruction boundary: the end
// of an instruction, or the end of the exception processing that starts at a
// boundary (an interrupt: the boundary after it is the handler's first
// instruction). Both sockets count the same things as steps, which is what
// lets the lockstep driver pair them one to one.
#ifndef RDVIRT_CPU_IF_H
#define RDVIRT_CPU_IF_H

#include <cstdint>
#include <string>

class Machine;

// The programmer's model at a boundary: everything the lockstep compares.
struct CpuRegs {
  uint32_t pc = 0;
  uint32_t d[8] = {}, a[8] = {};   // a[7] is the active stack pointer
  uint32_t usp = 0, isp = 0, msp = 0;
  uint16_t sr = 0;
  uint32_t vbr = 0, sfc = 0, dfc = 0, cacr = 0, caar = 0;
  uint32_t tc = 0, tt0 = 0, tt1 = 0;
  uint64_t crp = 0, srp = 0;
  uint16_t mmusr = 0;
  bool     stopped = false;        // STOP holds the processor
};

// One physical bus transfer, for the divergence dump and the write stream.
struct BusRec {
  uint64_t step;                   // the boundary count when it happened
  uint32_t addr, data;
  uint8_t  size;                   // bytes moved
  uint8_t  write, fc, berr;
  char     kind;                   // D operand, T table search, F fetch, I iack
};

enum class StepResult {
  Boundary,   // reached the next instruction boundary
  Stopped,    // STOP holds the processor and nothing it can take is pending
  Halted,     // double bus fault, or the model gave up
};

class CpuIf {
 public:
  virtual ~CpuIf() {}
  virtual const char *name() const = 0;
  // Reset and run to the first boundary (the reset exception's end), which is
  // step 0.
  virtual StepResult reset() = 0;
  // Run to the next boundary.
  virtual StepResult run_until_retire() = 0;
  // The interrupt priority level the machine presents (0 = none).
  virtual void set_ipl(int level) = 0;
  // The state at the last boundary.
  virtual const CpuRegs &regs() = 0;
  // Boundaries passed since reset (STOP's waiting excluded).
  virtual uint64_t retired() const = 0;
  // The level of the interrupt acknowledged during the last step, or 0.
  virtual int last_iack() const = 0;
  // Lockstep follower only: take this interrupt at the boundary the socket is
  // at, as the leader did. The next run_until_retire() ends at the handler.
  virtual void inject_interrupt(int level) = 0;
  // Install the registers a reset leaves undefined (USP, MSP, CAAR, SFC, DFC,
  // the MMU's but for the E bits), so that both sides start from one state.
  virtual void set_undefined(const CpuRegs &r) = 0;
  // The opcode of the instruction that ended at this boundary, if known.
  virtual int last_opcode() const { return -1; }
};

#endif
