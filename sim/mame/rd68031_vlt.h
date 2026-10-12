// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 in MAME (M14) -- the interface between MAME's rd68031_device
// (sim/mame/rd68031.cpp, compiled into MAME) and the core under Verilator with
// its pin-level bus agent (sim/mame/rd68031_vlt.cpp, a shared object MAME loads
// at start). Neither side includes the other's headers: MAME's and Verilator's
// would not mix, and the split lets the RTL be rebuilt without relinking MAME.
#ifndef RD68031_VLT_H
#define RD68031_VLT_H

#include <cstdint>

#define RD68031_VLT_ABI 1

// What the bus agent asks of the machine. Addresses are physical, as on the
// pins; a read or write is of the bytes `mask` selects in the aligned long word
// at `addr & ~3` (big-endian lanes: $FF000000 is the byte at addr & ~3), which
// is what a 32-bit port is asked for in one bus cycle (UM 7.2).
struct rd68031_vlt_bus {
  virtual ~rd68031_vlt_bus() {}
  // Set *berr to end the cycle with BERR instead of DSACK.
  virtual uint32_t read(uint32_t addr, int fc, uint32_t mask, bool *berr) = 0;
  virtual void write(uint32_t addr, int fc, uint32_t data, uint32_t mask, bool *berr) = 0;
  // The interrupt acknowledge of `level` (UM 8.1.9): the vector number, or
  // -1 for an autovector (AVEC), or -2 for a spurious interrupt (BERR).
  virtual int iack(int level) = 0;
  // False: the agent asserts CIIN on reads there (UM 5.7.1).
  virtual bool cacheable(uint32_t addr) = 0;
};

// The programmer's model at the last boundary.
struct rd68031_vlt_regs {
  uint32_t pc, d[8], a[8], usp, isp, msp, vbr, sfc, dfc, cacr, caar;
  uint32_t tc, tt0, tt1;
  uint64_t crp, srp;
  uint16_t sr, mmusr;
};

struct rd68031_vlt {
  virtual ~rd68031_vlt() {}
  // rst_n (the power-on initialisation, doc/pinout.md) low for `clocks` clocks,
  // then high.
  virtual void power_on(int clocks) = 0;
  virtual void set_ipl(int level) = 0;
  // One clock: the falling edge, then the rising edge. True when an
  // instruction boundary passed in it (the end of an instruction, or of the
  // exception processing that starts at a boundary).
  virtual bool clock() = 0;
  // STOP holds the processor and no bus cycle is in flight.
  virtual bool stopped() const = 0;
  // A double bus fault halted the processor.
  virtual bool halted() const = 0;
  virtual void regs(rd68031_vlt_regs &r) const = 0;
  virtual uint32_t pc() const = 0;
  virtual uint64_t clocks() const = 0;
  // Wait states before DSACK, on every cycle (asynchronous, 32-bit port).
  virtual void set_waits(int w) = 0;
};

extern "C" {
typedef int (*rd68031_vlt_abi_fn)();
typedef rd68031_vlt *(*rd68031_vlt_create_fn)(rd68031_vlt_bus *bus);
int rd68031_vlt_abi();
rd68031_vlt *rd68031_vlt_create(rd68031_vlt_bus *bus);
}

#endif
