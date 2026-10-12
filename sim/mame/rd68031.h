// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 in MAME (M14): a cpu_device whose processor is the RTL, rd68031_top
// under Verilator, behind a pin-level bus agent (sim/mame/rd68031_vlt.cpp,
// loaded from the shared object $RD68031_VLT at start).
//
// - AS_PROGRAM is the physical bus, 32 bits wide, as on the pins.
// - AS_CPU_SPACE (4, as for MAME's 68000 family) answers the interrupt
//   acknowledge: a byte at $FFFFFFF1 | level << 1, autovectors by default.
// - Input lines 1-7 are the interrupt levels, wire-ORed into IPL2-0; a fall
//   of level 7 is held on the pins for a few clocks so that the core sees the
//   new edge (UM 8.1.9). bus_error() ends the bus cycle in flight with BERR:
//   a driver calls it from a read or write handler.
// - Time: one MAME cycle is one clock of the core.
//
// Copied into MAME's tree by sim/mame/build.sh, beside the sun3x driver.
#ifndef MAME_SUN_RD68031_H
#define MAME_SUN_RD68031_H

#pragma once

#include "rd68031_vlt.h"

#include <chrono>
#include <vector>

class rd68031_device : public cpu_device, private rd68031_vlt_bus
{
public:
	enum { AS_CPU_SPACE = 4 };

	rd68031_device(const machine_config &mconfig, const char *tag, device_t *owner, u32 clock);
	virtual ~rd68031_device();

	// The bus cycle in flight ends with BERR (from a read or write handler).
	void bus_error() { m_berr = true; }
	// Reads in [start, end] are cachable; elsewhere the agent asserts CIIN.
	// With no range given, everything is.
	void add_cacheable(offs_t start, offs_t end) { m_cacheable.emplace_back(start, end); }
	// Wait states on every bus cycle.
	void set_waits(int w) { m_waits = w; }

protected:
	virtual void device_start() override ATTR_COLD;
	virtual void device_reset() override ATTR_COLD;
	virtual void device_stop() override ATTR_COLD;

	virtual u32 execute_min_cycles() const noexcept override { return 1; }
	virtual u32 execute_max_cycles() const noexcept override { return 64; }
	virtual void execute_run() override;
	virtual void execute_set_input(int inputnum, int state) override;
	virtual bool execute_input_edge_triggered(int inputnum) const noexcept override { return inputnum == 7; }

	virtual space_config_vector memory_space_config() const override;

	virtual void state_export(const device_state_entry &entry) override;

	virtual std::unique_ptr<util::disasm_interface> create_disassembler() override;

private:
	// rd68031_vlt_bus
	virtual uint32_t read(uint32_t addr, int fc, uint32_t mask, bool *berr) override;
	virtual void write(uint32_t addr, int fc, uint32_t data, uint32_t mask, bool *berr) override;
	virtual int iack(int level) override;
	virtual bool cacheable(uint32_t addr) override;

	void cpu_space_map(address_map &map) ATTR_COLD;
	void present_ipl();

	address_space_config m_program_config, m_cpu_space_config;
	address_space *m_program = nullptr, *m_cpu_space = nullptr;
	int m_icount = 0;

	void *m_dl = nullptr;
	rd68031_vlt *m_vlt = nullptr;
	rd68031_vlt_regs m_r{};
	u32 m_pc = 0, m_sr = 0, m_sp = 0;

	std::vector<std::pair<offs_t, offs_t>> m_cacheable;
	int m_waits = 0;
	bool m_berr = false;
	u8 m_lines = 0;          // input lines 1-7 asserted, bit n for line n
	int m_ipl7_low = 0;      // clocks left that level 7 is held off the pins
	int m_ipl = -1;          // the level on the pins
	bool m_need_reset = true;
	bool m_halt_reported = false;
	int m_stop_clocks = 0;
	u64 m_boundaries = 0;
	bool m_watching = false;
	u32 m_watch = 0, m_last_pc = 0;
	std::chrono::steady_clock::time_point m_wall0;
};

DECLARE_DEVICE_TYPE(RD68031, rd68031_device)

#endif // MAME_SUN_RD68031_H
