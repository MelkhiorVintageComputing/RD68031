# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

# RD68031 -- SystemVerilog MC68030
#
# Targets arrive as the milestones that need them do. `make help` lists what exists.
#
# The three always-available front-ends -- iverilog, Verilator, yosys -- are what
# `make lint` runs and what the RTL is written against day to day. Vivado, Quartus
# and Questa each have their own target and none of them is in `make check`, which
# has to work on a machine with no vendor tools installed.

SHELL := /bin/bash

TOP   ?= rd68031_top
BUILD ?= build

# Overridable build knobs, all documented where they are used.
ICACHE_ENTRIES ?= 64
DCACHE_ENTRIES ?= 64
COPROCESSOR    ?= 0

# Vendor tool locations. Neither is on PATH; the launchers in scripts/ set it up.
VIVADO_SETTINGS ?= /opt/Xilinx/2025.2/Vivado/settings64.sh
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUESTA_ROOTDIR  ?= /opt/Altera/questa_fse
XPART           ?= xc7a100tcsg324-1
AFAMILY         ?= "Cyclone V"
APART           ?= 5CSEMA5F31C6

# ---------------------------------------------------------------------------
# The file list. Dependency-ordered, packages first: Vivado needs a package read
# before its users, and so does Questa.
# ---------------------------------------------------------------------------
# Packages first -- Vivado and Questa need one read before its users, and so does
# iverilog. The generated files are split the same way: a plain wildcard over
# rtl/gen/ sorts rd68031_decode_rom.sv ahead of the package it depends on.
PKGS    := rtl/rd68031_pkg.sv
GENPKG  := $(wildcard rtl/gen/*_pkg.sv)
GENSRC  := $(filter-out $(GENPKG),$(wildcard rtl/gen/*.sv))
SRCS := rtl/rd68031_sync.sv \
        rtl/rd68031_dedge_ff.sv \
        rtl/rd68031_shifter.sv \
        rtl/rd68031_divider.sv \
        rtl/rd68031_bitfield.sv \
        rtl/rd68031_biu.sv \
        rtl/rd68031_icache.sv \
        rtl/rd68031_dcache.sv \
        rtl/rd68031_ifu.sv \
        rtl/rd68031_mmu_xl.sv \
        rtl/rd68031_mmu.sv \
        rtl/rd68031_seq.sv \
        rtl/rd68031_top.sv

RTL  := $(PKGS) $(GENPKG) $(GENSRC) $(SRCS)
VLT  := rtl/rd68031.vlt

IVFLAGS := -g2012 -Wall -Wno-timescale -DTB_ICACHE_ENTRIES=$(ICACHE_ENTRIES) \
           -DTB_DCACHE_ENTRIES=$(DCACHE_ENTRIES)

.PHONY: netbsd-disk netbsd-sun3x netbsd-sun3x-m68030 sunos-disk sunos-sun3x sunos-sun3x-m68030 sim-progs
.PHONY: fpu-mmu
.PHONY: all help dirs lint lint-source lint-iverilog lint-verilator lint-yosys \
        lint-quartus lint-questa quartus synth impl paths audit ucode ucode-check sim sim-bus \
        timing timing-verbose timing-build ea cache cycles cpif check clean \
        vectors vectors-all cosim cosim-long cputest cosim-mmu ap030 \
        virt-bare virt-uae virt-linux virt-linux-solo sun3x sun3x-m68030

all: lint

help:
	@echo "RD68031 -- SystemVerilog MC68030"
	@echo
	@echo "The gate:"
	@echo "  make check       ucode-check, lint, audit, sim and timing, together"
	@echo "  make ucode       regenerate rtl/gen/ from tools/ucode/"
	@echo "  make ucode-check ... or check rtl/gen/ and doc/checkpoint.md are up to date"
	@echo "  make lint        elaborate every rtl module under iverilog, Verilator and yosys"
	@echo "  make audit       prove no register initialises outside reset"
	@echo "  make sim         the directed testbenches"
	@echo "  make sim-bus     ... just the bus-level ones"
	@echo "  make paging      ... just the bus-fault and demand-paging ones"
	@echo "  make cpif        ... just the coprocessor interface, against a scripted coprocessor"
	@echo "  make fpu-mmu     the core with RD68884: FPU memory operands faulting in the MMU, and"
	@echo "                   two tasks sharing the FPU under a scheduler (not in check)"
	@echo "  make timing      AC-specification feasibility, all five MC68030EC grades"
	@echo
	@echo "The oracles, minutes each:"
	@echo "  make uae030      build the UAE030 oracle and its front-ends (build/uae030/)"
	@echo "  make ea          every addressing mode and extension-word shape, against the oracle"
	@echo "  make vectors     instruction groups against the oracle (OP=alu ...; default OP=$(VECGROUPS))"
	@echo "  make vectors-all every group, whatever OP says"
	@echo "  make cosim       real programs, every register at every instruction (STEPS=$(STEPS))"
	@echo "  make cosim-long  ... the whole of each program"
	@echo "  make cosim-mmu   MMU programs: registers and the physical data-access stream (COSIMMMU=...)"
	@echo "  make cache       the same results with no instruction cache at all"
	@echo "  make ap030       AP68030 against the core, pin against pin (AP030PROGS=...)"
	@echo "  make cputest     WinUAE's cputest corpus (CPUTEST_SEL=ADD,MOVE.L CPUTEST_MAX=$(CPUTEST_MAX))"
	@echo "  make cycles      instruction clock counts against UM section 11"
	@echo "  make timing-verbose  the AC solver, with the binding constraint named"
	@echo
	@echo "rd-virt, the deterministic m68k virt machine (M13; heavy builds, run alone):"
	@echo "  make virt-uae       Linux to the shell and a command set on UAE030 alone"
	@echo "  make virt-bare      bare-metal programs (console, timer, MMU and caches), in lockstep"
	@echo "  make virt-linux-solo  Linux on the RTL alone"
	@echo "  make virt-linux     Linux in lockstep with UAE030 (VIRT_CACHES=off, VIRT_OPTS=...)"
	@echo
	@echo "MAME's Sun-3/80 (M14; heavy builds, run alone):"
	@echo "  make sun3x          the boot PROM to the monitor and a command set, on the core,"
	@echo "                      console byte for byte against MAME's m68030 (SUN3X_BIOS=...)"
	@echo "  make sun3x-m68030   ... MAME's m68030 alone"
	@echo "  make netbsd-disk    NetBSD/sun3x 10.2 installed on a disk image, on MAME's m68030"
	@echo "  make netbsd-sun3x-m68030  ... booted to multi-user there, commands typed"
	@echo "  make netbsd-sun3x   ... and on the core with RD68884, answers compared (hours)"
	@echo "  make sunos-disk     SunOS 4.1.1 installed on a disk image from its tape, on MAME's m68030"
	@echo "  make sunos-sun3x-m68030  ... booted to multi-user there, commands typed"
	@echo "  make sunos-sun3x    ... and on the core with RD68884, answers compared (hours)"
	@echo
	@echo "Vendor tools, tens of minutes each:"
	@echo "  make impl         Vivado place and route ($(XPART)), out of context"
	@echo "  make paths        what limits the clock, from the checkpoint make impl leaves"
	@echo "  make synth        Vivado synthesis only"
	@echo "  make quartus      Quartus fit and timing ($(AFAMILY) $(APART))"
	@echo "  make lint-quartus Quartus analysis and synthesis"
	@echo "  make lint-questa  Questa vlog + vopt"
	@echo
	@echo "  make clean        remove build/"
	@echo
	@echo "Knobs: ICACHE_ENTRIES=$(ICACHE_ENTRIES) DCACHE_ENTRIES=$(DCACHE_ENTRIES)" \
	      "COPROCESSOR=$(COPROCESSOR)" \
	      "AFAMILY=$(AFAMILY) APART=$(APART)"

dirs:
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# Lint -- the three that need no vendor installation
# ---------------------------------------------------------------------------
lint: lint-source lint-iverilog lint-verilator lint-yosys

# The two portability rules the three free front-ends do not enforce and the
# three vendor ones do -- declaration before use, and no package-scoped name in a
# port connection. Both are in doc/coding-standard.md and both came back once
# because nothing cheaper than a vendor run looked.
lint-source:
	@python3 tools/src_lint.py $(filter-out $(PKGS) $(GENPKG),$(RTL))
	@echo "PASS: lint"

# Both of these run the tool into a log and decide from its exit status, rather
# than piping it through a filter. `tool | grep -v ... || test $$? -eq 1` looks
# like it keeps the status and does not: with pipefail the pipeline returns the
# tool's 1, and `test 1 -eq 1` then succeeds, so a failing tool reports "ok".
# Measured, on this Makefile, twice.
#
# iverilog prints a "sorry: ..." note for every unique case and for every variable
# part-select in an always_ block, and nothing can turn them off. They are notes,
# not diagnostics, so they are filtered out of what gets shown on a failure.
NOTES := ': sorry: .*\(ignored\|all bits will be included\)\.$$'

lint-iverilog: dirs
	@iverilog $(IVFLAGS) -P$(TOP).ICACHE_ENTRIES=$(ICACHE_ENTRIES) \
	    -P$(TOP).DCACHE_ENTRIES=$(DCACHE_ENTRIES) \
	    -o $(BUILD)/$(TOP).vvp -s $(TOP) $(RTL) \
	    > $(BUILD)/iverilog.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/iverilog.log; exit 1; }
	@echo "  iverilog: ok"

lint-verilator: dirs
	@verilator --lint-only -Wall --top-module $(TOP) \
	    -GICACHE_ENTRIES=$(ICACHE_ENTRIES) -GDCACHE_ENTRIES=$(DCACHE_ENTRIES) \
	    $(VLT) $(RTL) \
	    > $(BUILD)/verilator.log 2>&1 \
	  || { grep -v '^- V e r i l a t i o n\|^- Verilator:' $(BUILD)/verilator.log; exit 1; }
	@echo "  verilator: ok"

# Run the full synth pass, not just read_verilog, so that anything unsynthesisable
# is caught here rather than in Vivado.
#
# yosys returns 0 on a warning, and two of its warnings are defects rather than
# noise: a register driven from two processes ("multiple conflicting drivers"),
# which is what a register written from both edge domains looks like, and an
# inferred latch. Both are gates here, not the exit code -- measured: op_addr was
# driven from both the posedge and the negedge block and `make lint` said PASS.
lint-yosys: dirs
	@set -o pipefail; yosys -p "read_verilog -sv $(RTL); \
	    chparam -set ICACHE_ENTRIES $(ICACHE_ENTRIES) $(TOP); \
	    chparam -set DCACHE_ENTRIES $(DCACHE_ENTRIES) $(TOP); synth -top $(TOP); \
	    write_verilog $(BUILD)/$(TOP)_yosys.v" > $(BUILD)/yosys.log 2>&1 \
	  || { tail -40 $(BUILD)/yosys.log; exit 1; }
	@if grep -q 'multiple conflicting drivers\|Warning: Identifier .* is implicitly declared\|inferring latch' $(BUILD)/yosys.log; then \
	    echo "FAIL: yosys"; \
	    grep -n 'multiple conflicting drivers\|implicitly declared\|inferring latch' $(BUILD)/yosys.log | head -20; \
	    exit 1; fi
	@echo "  yosys: ok"

# ---------------------------------------------------------------------------
# The reset rule
# ---------------------------------------------------------------------------
audit: dirs
	@python3 tools/reset_audit.py --top $(TOP) --build $(BUILD) \
	    --param ICACHE_ENTRIES=$(ICACHE_ENTRIES) \
	    --param DCACHE_ENTRIES=$(DCACHE_ENTRIES) $(RTL)

# ---------------------------------------------------------------------------
# Microcode -- M4
# ---------------------------------------------------------------------------
# The generated files are committed, so a build needs no Python. ucode-check is
# the first thing `make check` runs, so they cannot drift from their source.
ucode: dirs
	@python3 tools/ucode/assemble.py

ucode-check: dirs
	@python3 tools/ucode/assemble.py --check

# ---------------------------------------------------------------------------
# Directed testbenches
#
# Each one runs to completion and prints PASS or FAIL. The loop fails on a FAIL
# and ALSO on a missing PASS: a testbench that stopped early without saying so is
# not a testbench that passed.
# ---------------------------------------------------------------------------
# core_ea_tb is not here: it needs a vector file that `make ea` generates from
# the oracle first, and it runs for minutes. It has its own target.
# The instruction groups whose microcode exists. `make vectors` sweeps these;
# adding a family to tools/ucode/program.py adds its name here, and that is how
# the sweep grows with the milestone instead of being switched on at the end.
#
# Every group the generator knows how to build, since M8. `make vectors-all` is
# the same thing named for the milestone criterion, and the two stay the same
# until M10 adds instructions the generator has no group for yet.
VECGROUPS := all

TBS := $(filter-out core_ea_tb core_vec_tb core_cosim_tb core_cycles_tb core_cputest_tb core_pins_tb,$(patsubst sim/tb/%.sv,%,$(wildcard sim/tb/*_tb.sv)))

# COPROCESSOR=1 builds the coprocessor interface into every core testbench, and
# puts the scripted coprocessor of sim/models/rd68031_cpmodel.sv on the bus.
ifeq ($(COPROCESSOR),1)
IVFLAGS += -DTB_COPROCESSOR
endif

# core_cow_tb runs a real program: a kernel and a user process, built by the
# cross-toolchain. It owns its vector table and its modes, so it is linked
# without crt0, and it lives at a fixed path so that `cache`, which runs `sim`
# with another BUILD, finds it too.
COW := build/programs/cow
$(COW).hex: sim/programs/cow.S sim/programs/flat.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -c -o $(COW).o sim/programs/cow.S
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/flat.ld -o $(COW).elf \
	    $(COW).o 2> $(COW).link.log || { cat $(COW).link.log; exit 1; }
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $(COW).elf $@

# core_mmu_cow_tb runs the same program built for the MC68030's own MMU: the
# kernel protects and maps the pages with translation tables (doc/mmu.md).
COWMMU := build/programs/cow_mmu
$(COWMMU).hex: sim/programs/cow.S sim/programs/flat.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68030 -DCOW_MMU -c -o $(COWMMU).o sim/programs/cow.S
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/flat.ld -o $(COWMMU).elf \
	    $(COWMMU).o 2> $(COWMMU).link.log || { cat $(COWMMU).link.log; exit 1; }
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $(COWMMU).elf $@

# core_m030_tb runs three images on two buses: the MC68030 smoke program, which
# owns its vectors like cow.S and is assembled for the MC68030 so that the MMU
# instructions are the assembler's own encodings, and two of the programs
# `cosim` uses. Fixed paths, for the same reason as COW.
M030 := build/programs/m030
$(M030).hex: sim/programs/m030.S sim/programs/flat.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68030 -c -o $(M030).o sim/programs/m030.S
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/flat.ld -o $(M030).elf \
	    $(M030).o 2> $(M030).link.log || { cat $(M030).link.log; exit 1; }
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $(M030).elf $@

# core_cache_tb runs sim/programs/cache.S, which owns its vectors too: one short
# test per phase, opened by a write of the phase number the testbench watches.
CACHEP := build/programs/cache
$(CACHEP).hex: sim/programs/cache.S sim/programs/flat.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68030 -c -o $(CACHEP).o sim/programs/cache.S
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/flat.ld -o $(CACHEP).elf \
	    $(CACHEP).o 2> $(CACHEP).link.log || { cat $(CACHEP).link.log; exit 1; }
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $(CACHEP).elf $@

# core_mmu_tb runs sim/programs/mmu_*.S: bare-metal programs that set up
# translation tables and check themselves, linked with sim/programs/mmu.ld so
# that their tables and the pages they map are at fixed physical addresses.
# -mcpu=68030 for the MMU instructions. Fixed paths, as for COW.
MMUPROGS := mmu_regs mmu_walk mmu_fault mmu_rerun
MMUHEX   := $(patsubst %,build/programs/%.hex,$(MMUPROGS))
build/programs/mmu_%.hex: sim/programs/mmu_%.S sim/programs/mmu_common.inc sim/programs/mmu.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68030 -Isim/programs -c -o build/programs/mmu_$*.o $<
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/mmu.ld \
	    -o build/programs/mmu_$*.elf build/programs/mmu_$*.o \
	    2> build/programs/mmu_$*.link.log || { cat build/programs/mmu_$*.link.log; exit 1; }
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 build/programs/mmu_$*.elf $@

sim-progs:
	@$(MAKE) --no-print-directory BUILD=build build/programs/arith.hex \
	    build/programs/corners.hex

# The testbenches run SIMJOBS at a time (CLAUDE.md: light simulations, up to
# four in parallel). Each writes its one-line verdict to $(BUILD)/<tb>.simres;
# the verdicts are printed in TBS order once all have finished, so the output
# reads as it did when they ran one after another. A testbench that leaves no
# verdict -- killed, or crashed before writing one -- is a failure.
SIMJOBS ?= 4

sim: dirs $(COW).hex $(COWMMU).hex $(M030).hex $(CACHEP).hex $(MMUHEX) sim-progs
	@rm -f $(addprefix $(BUILD)/,$(addsuffix .simres,$(TBS))); \
	run_tb() { \
	  tb=$$1; r=$(BUILD)/$$tb.simres; \
	  if ! iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/$$tb.vvp -s $$tb \
	      $(RTL) sim/models/*.sv sim/tb/$$tb.sv > $(BUILD)/$$tb.build.log 2>&1; then \
	    { echo "FAIL: $$tb did not elaborate"; \
	      grep -v $(NOTES) $(BUILD)/$$tb.build.log; } > $$r; return; \
	  fi; \
	  vvp $(BUILD)/$$tb.vvp > $(BUILD)/$$tb.log 2>&1; \
	  if grep -q '^FAIL' $(BUILD)/$$tb.log; then \
	    { echo "FAIL: $$tb"; grep -E '^  FAIL|^FAIL' $(BUILD)/$$tb.log | head -30; } > $$r; \
	  elif ! grep -q '^PASS' $(BUILD)/$$tb.log; then \
	    { echo "FAIL: $$tb reported no PASS"; tail -20 $(BUILD)/$$tb.log; } > $$r; \
	  else \
	    echo "  $$(grep -E '^PASS' $(BUILD)/$$tb.log | head -1)" > $$r; \
	  fi; \
	}; \
	export -f run_tb; \
	printf '%s\n' $(TBS) | xargs -P $(SIMJOBS) -I{} bash -c 'run_tb {}'; \
	ok=1; for tb in $(TBS); do \
	  r=$(BUILD)/$$tb.simres; \
	  if [ ! -s $$r ]; then echo "FAIL: $$tb left no verdict"; ok=0; continue; fi; \
	  cat $$r; grep -q '^FAIL' $$r && ok=0; \
	done; test $$ok -eq 1

# The coprocessor interface, UM section 10, against the scripted coprocessor of
# sim/models/rd68031_cpmodel.sv -- doc/coprocessor.md. Part of `sim` as well.
cpif: dirs
	@$(MAKE) --no-print-directory sim TBS=core_cpif_tb

# The core with RD68884 as its MC68881 (sim/mame/rd68031_fpu.sv, as MAME's
# Sun-3/80 has them), coprocessor memory operands faulting in the MMU:
# sim/programs/fpu_mmu.S, a fault on each long word of FETOX/FLOGN/FMOD.D reads
# and FMOVE.D stores, the FPU's context switched in the handler; and
# fpu_sched.S, two user tasks calling libm-style exp/log/fmod under a timer-
# driven scheduler whose ticks write-protect or invalidate their stacks.
# Each checks every result against the unfaulted one. Four light simulations,
# in parallel; not in `check`: it needs Inputs/ip/RD68884.
FPUDIR := Inputs/ip/RD68884/rtl
FPURTL  = $(FPUDIR)/rd68884_pkg.sv $(wildcard $(FPUDIR)/gen/*_pkg.sv) \
          $(filter-out %_pkg.sv,$(wildcard $(FPUDIR)/gen/*.sv)) \
          $(addprefix $(FPUDIR)/rd68884_,$(addsuffix .sv,sync cu_decode biu regfile seq top))
build/programs/fpu_%.hex: sim/programs/fpu_%.S sim/programs/mmu_common.inc sim/programs/mmu.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68030 -m68881 -Isim/programs -c -o build/programs/fpu_$*.o $<
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/mmu.ld \
	    -o build/programs/fpu_$*.elf build/programs/fpu_$*.o \
	    2> build/programs/fpu_$*.link.log || { cat build/programs/fpu_$*.link.log; exit 1; }
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 build/programs/fpu_$*.elf $@

fpu-mmu: dirs build/programs/fpu_mmu.hex build/programs/fpu_sched.hex
	@test -f $(FPUDIR)/rd68884_top.sv || { echo "FAIL: Inputs/ip/RD68884 is missing"; exit 1; }
	@iverilog $(IVFLAGS) -o $(BUILD)/core_fpu_mmu_tb.vvp -s core_fpu_mmu_tb \
	    $(RTL) $(FPURTL) sim/mame/rd68031_fpu.sv sim/models/rd68031_slave.sv \
	    sim/tb/core_fpu_mmu_tb.sv > $(BUILD)/core_fpu_mmu_tb.build.log 2>&1 \
	    || { grep -v $(NOTES) $(BUILD)/core_fpu_mmu_tb.build.log; exit 1; }
	@T=$(BUILD)/core_fpu_mmu_tb; S="+image=build/programs/fpu_sched.hex +timer +limit=12000000"; \
	vvp $$T.vvp > $$T-mmu.log 2>&1 & \
	vvp $$T.vvp +cacr=3111 +waits=2 > $$T-mmu-c.log 2>&1 & \
	vvp $$T.vvp $$S +tbase=800 +tmask=FFF +waits=1 > $$T-sched.log 2>&1 & \
	vvp $$T.vvp $$S +tbase=400 +tmask=1FFF +seed=5A5A +cacr=3111 > $$T-sched-c.log 2>&1 & \
	wait; ok=1; for r in mmu mmu-c sched sched-c; do \
	  if grep -q '^PASS' $$T-$$r.log; then echo "  $$r: $$(grep -h '^PASS' $$T-$$r.log)"; \
	  else echo "FAIL: fpu-mmu $$r ($$T-$$r.log)"; grep -E '^  FAIL' $$T-$$r.log | head; ok=0; fi; \
	  grep -h 'interrupts\|frames' $$T-$$r.log | sed 's/^core_fpu_mmu_tb:/    /'; \
	done; test $$ok -eq 1 && echo "PASS: fpu-mmu"

sim-bus: dirs
	@$(MAKE) --no-print-directory sim TBS="$(filter bus_%,$(TBS))"

# Demand paging: every combination of UM table 5-6 faulted across a page that is
# not there, handled by a real handler, and continued. It is part of `sim`, and
# so of `check`, because it is the milestone's own criterion and a regression in
# it is the kind nothing else finds.
paging: dirs
	@$(MAKE) --no-print-directory sim TBS="core_paging_tb core_fault_tb"

# ---------------------------------------------------------------------------
# The instruction-level oracle
#
# RD68021 used Musashi here. Musashi's MC68030 has a stub for an MMU -- no
# PTEST, no TT0/TT1, no ATC -- and no data cache, so this design does not use
# it. Its replacement is UAE030, the WinUAE MC68030 core as Hatari carries it,
# built out of tree into build/uae030/ (Inputs/ is immutable) by
# tools/cosim/uae030/build.sh as one library, libuae030.a, and linked into
# small front-ends: uae030_trace (cosim), uae030_ea (ea), vectors_gen
# (vectors) and uae030, a tracer for looking at one program by hand.
# doc/oracles.md has what it is trusted for.
#
# The library is built once and reused: build.sh is incremental, and only runs
# again when the harness's own glue changes. The generated cores are compiled
# at -O0/-O1, four at a time, which keeps each compile near 300 MB.
#
# The --wrap options let the glue see a misaligned operand as the one operand
# it is, rather than as the aligned pieces the core splits it into.
# ---------------------------------------------------------------------------
OBUILD  := $(BUILD)/uae030
OSRC    := tools/cosim/uae030
comma   := ,
OWRAP   := mmu030_get_word_unaligned mmu030_get_long_unaligned \
           mmu030_put_word_unaligned mmu030_put_long_unaligned
OLDFLAGS := $(addprefix -Wl$(comma)--wrap=,$(OWRAP)) -lm
OCFLAGS  := -O2 -g -Wall -Wextra -I$(OSRC)

.PHONY: uae030
uae030: $(OBUILD)/uae030 $(OBUILD)/uae030_trace $(OBUILD)/uae030_ea $(OBUILD)/vectors_gen

$(OBUILD)/libuae030.a: $(OSRC)/build.sh $(OSRC)/uae030_glue.c $(OSRC)/uae030.h
	@mkdir -p $(OBUILD)
	@echo "  uae030: building the oracle core into $(OBUILD)"
	@JOBS=4 sh $(OSRC)/build.sh $(OBUILD) > $(OBUILD)/build.log 2>&1 \
	  || { tail -30 $(OBUILD)/build.log; exit 1; }

$(OBUILD)/uae030: $(OSRC)/uae030_main.c $(OBUILD)/libuae030.a
	@$(CC) $(OCFLAGS) -o $@ $< $(OBUILD)/libuae030.a $(OLDFLAGS)

$(OBUILD)/uae030_trace: $(OSRC)/uae030_trace.c $(OBUILD)/libuae030.a
	@$(CC) $(OCFLAGS) -o $@ $< $(OBUILD)/libuae030.a $(OLDFLAGS)

$(OBUILD)/uae030_ea: $(OSRC)/uae030_ea.c $(OBUILD)/libuae030.a
	@$(CC) $(OCFLAGS) -o $@ $< $(OBUILD)/libuae030.a $(OLDFLAGS)

# ---------------------------------------------------------------------------
# Effective addresses, against the oracle
# ---------------------------------------------------------------------------
ea: dirs $(OBUILD)/uae030_ea
	@$(OBUILD)/uae030_ea > $(BUILD)/ea-vectors.hex
	@echo "  ea: $$(head -1 $(BUILD)/ea-vectors.hex | tr -d ' ') vectors from the oracle"
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_ea_tb.vvp -s core_ea_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_ea_tb.sv \
	    > $(BUILD)/core_ea_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_ea_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_ea_tb.vvp +vec=$(BUILD)/ea-vectors.hex \
	    > $(BUILD)/core_ea_tb.log 2>&1; \
	 grep -E '^  FAIL' $(BUILD)/core_ea_tb.log | head -20; \
	 grep -q '^PASS' $(BUILD)/core_ea_tb.log || { tail -3 $(BUILD)/core_ea_tb.log; exit 1; }
	@tail -2 $(BUILD)/core_ea_tb.log

$(OBUILD)/vectors_gen: tools/vectors/gen.c $(OBUILD)/libuae030.a
	@$(CC) $(OCFLAGS) -o $@ $< $(OBUILD)/libuae030.a $(OLDFLAGS)

# ---------------------------------------------------------------------------
# The per-opcode sweep
#
#   make vectors OP=alu        one group
#   make vectors               every group the microcode has reached
#   make vectors-all           every group there is, including the unwritten
#
# OP defaults to the groups M7 has implemented so far rather than to `all`, so
# that `make vectors` is a gate that can stay green while the milestone is being
# built. `vectors-all` is the milestone's own criterion and is expected to fail
# until it closes.
# ---------------------------------------------------------------------------
OP ?= $(VECGROUPS)

vectors: dirs $(OBUILD)/vectors_gen
	@$(OBUILD)/vectors_gen $(OP) > $(BUILD)/vectors.hex 2> $(BUILD)/vectors-gen.log \
	  || { cat $(BUILD)/vectors-gen.log; exit 1; }
	@sed 's/^/  /' $(BUILD)/vectors-gen.log
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_vec_tb.vvp -s core_vec_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_vec_tb.sv \
	    > $(BUILD)/core_vec_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_vec_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_vec_tb.vvp +vec=$(BUILD)/vectors.hex +faillog=$(BUILD)/vectors.fail \
	    > $(BUILD)/core_vec_tb.log 2>&1; \
	 grep -E '^  FAIL' $(BUILD)/core_vec_tb.log | head -20; \
	 grep -q '^PASS' $(BUILD)/core_vec_tb.log || { tail -3 $(BUILD)/core_vec_tb.log; exit 1; }
	@tail -2 $(BUILD)/core_vec_tb.log

vectors-all: dirs
	@$(MAKE) --no-print-directory vectors OP=all

# ---------------------------------------------------------------------------
# Real programs, against the oracle at every instruction boundary
#
# The per-opcode sweep runs one instruction from a state nobody reached by
# executing anything. This runs a program: the instruction mix and the register
# allocation are the compiler's, and every instruction starts where the one
# before it left off.
#
# STEPS caps the trace. A program that runs for a million instructions is a fine
# thing to have and a slow gate, so `cosim` takes the first STEPS of it and
# `cosim-long` takes the lot.
# ---------------------------------------------------------------------------
CROSS   := m68k-linux-gnu-
PROGS   := arith corners
STEPS   ?= 20000
CFLAGS68 := -O2 -fno-builtin -fomit-frame-pointer -nostdlib -ffreestanding \
            -Wall -Wextra

$(BUILD)/programs/%.o: sim/programs/%.c | dirs
	@mkdir -p $(BUILD)/programs
	@$(CROSS)gcc -c $(CFLAGS68) -o $@ $<

$(BUILD)/programs/%.o: sim/programs/%.S | dirs
	@mkdir -p $(BUILD)/programs
	@$(CROSS)gcc -c -o $@ $<

.PRECIOUS: $(BUILD)/programs/%.o $(BUILD)/programs/%.elf \
           $(BUILD)/programs/%.bin $(BUILD)/programs/%.hex \
           $(BUILD)/programs/%.trc

$(BUILD)/programs/%.elf: $(BUILD)/programs/%.o $(BUILD)/programs/crt0.o \
                         sim/programs/flat.ld
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/flat.ld -o $@ \
	    $(BUILD)/programs/crt0.o $< -lgcc 2> $(BUILD)/programs/$*.link.log \
	  || { cat $(BUILD)/programs/$*.link.log; exit 1; }

$(BUILD)/programs/%.bin: $(BUILD)/programs/%.elf
	@$(CROSS)objcopy -O binary $< $@

$(BUILD)/programs/%.hex: $(BUILD)/programs/%.elf
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $< $@

# A trace is as long as STEPS says, so a change of STEPS (cosim-long) remakes it.
$(BUILD)/programs/.steps-$(STEPS):
	@mkdir -p $(BUILD)/programs; rm -f $(BUILD)/programs/.steps-*; touch $@

$(BUILD)/programs/%.trc: $(BUILD)/programs/%.bin $(OBUILD)/uae030_trace $(BUILD)/programs/.steps-$(STEPS)
	@$(OBUILD)/uae030_trace $< $(STEPS) > $@ 2> $(BUILD)/programs/$*.trace.log \
	  || { cat $(BUILD)/programs/$*.trace.log; exit 1; }
	@sed 's/^/  /' $(BUILD)/programs/$*.trace.log

cosim: dirs $(patsubst %,$(BUILD)/programs/%.hex,$(PROGS)) \
             $(patsubst %,$(BUILD)/programs/%.trc,$(PROGS))
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cosim_tb.vvp -s core_cosim_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_cosim_tb.sv \
	    > $(BUILD)/core_cosim_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_cosim_tb.build.log; exit 1; }
	@ok=1; for p in $(PROGS); do \
	  vvp $(BUILD)/core_cosim_tb.vvp +image=$(BUILD)/programs/$$p.hex \
	      +trace=$(BUILD)/programs/$$p.trc > $(BUILD)/cosim-$$p.log 2>&1; \
	  grep -E '^  FAIL' $(BUILD)/cosim-$$p.log | head -5; \
	  if grep -q '^PASS' $(BUILD)/cosim-$$p.log; then \
	    echo "  PASS: $$p -- $$(sed -n 's/^core_cosim_tb: \([0-9]*\) instructions, every.*/\1/p' $(BUILD)/cosim-$$p.log) instructions"; \
	  else \
	    echo "  FAIL: $$p"; tail -3 $(BUILD)/cosim-$$p.log; ok=0; \
	  fi; \
	done; \
	test $$ok -eq 1 && echo "PASS: cosim"

# ---------------------------------------------------------------------------
# Instruction clock counts against UM section 11
#
# One row per instruction, each a regression check against the count frozen in
# tools/cycles.py, and the table in doc/timing-divergences.md regenerated from
# the measurement. Warm is the manual's instruction-cache case; cold is the
# first pass, with the cache empty. The bench is built twice: the 32-bit port
# answering with DSACK (three-clock cycles), and with STERM (two clocks, the
# bus UM section 11 assumes). The two runs are light and go side by side.
# ---------------------------------------------------------------------------
cycles: dirs
	@python3 tools/cycles.py gen > $(BUILD)/cycles.vec
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cycles_tb.vvp -s core_cycles_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_cycles_tb.sv \
	    > $(BUILD)/core_cycles_tb.build.log 2>&1 & a=$$!; \
	 iverilog $(IVFLAGS) -DTB_S32_SYNC=1\'b1 -I sim/tb -o $(BUILD)/core_cycles_sync_tb.vvp \
	    -s core_cycles_tb $(RTL) sim/models/*.sv sim/tb/core_cycles_tb.sv \
	    > $(BUILD)/core_cycles_sync_tb.build.log 2>&1 & b=$$!; \
	 wait $$a || { grep -v $(NOTES) $(BUILD)/core_cycles_tb.build.log; exit 1; }; \
	 wait $$b || { grep -v $(NOTES) $(BUILD)/core_cycles_sync_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_cycles_tb.vvp +vec=$(BUILD)/cycles.vec > $(BUILD)/cycles.out 2>&1 & \
	 vvp $(BUILD)/core_cycles_sync_tb.vvp +vec=$(BUILD)/cycles.vec > $(BUILD)/cycles_sync.out 2>&1; \
	 wait
	@for f in $(BUILD)/cycles.out $(BUILD)/cycles_sync.out; do \
	   grep -E '^  FAIL' $$f | head -20; \
	   grep -q '^PASS' $$f || { tail -5 $$f; exit 1; }; done
	@python3 tools/cycles.py check $(BUILD)/cycles.out $(BUILD)/cycles_sync.out \
	    --doc doc/timing-divergences.md

# ---------------------------------------------------------------------------
# The caches are architecturally invisible
#
# UM section 6: both caches are copies of memory that the program cannot see,
# the data cache write-through, so a core built with no caches at all must give
# the same answers. This runs the directed testbenches, the sweep and the
# effective-address vectors on a core with ICACHE_ENTRIES=0 and DCACHE_ENTRIES=0,
# and then every program on both builds, holding the two to identical writes,
# and to no more data reads and no more instruction fetches with the caches
# than without (tools/cache_diff.py).
# ---------------------------------------------------------------------------
NOCACHE := $(BUILD)/nocache

cache: dirs $(patsubst %,$(BUILD)/programs/%.hex,$(PROGS)) \
            $(patsubst %,$(BUILD)/programs/%.trc,$(PROGS))
	@mkdir -p $(NOCACHE); rm -f $(NOCACHE)/cache.failed
	@echo "  -- ICACHE_ENTRIES=0 DCACHE_ENTRIES=0: the directed testbenches"
	@$(MAKE) --no-print-directory sim ICACHE_ENTRIES=0 DCACHE_ENTRIES=0 BUILD=$(NOCACHE) \
	  || echo sim > $(NOCACHE)/cache.failed
	@echo "  -- ICACHE_ENTRIES=0 DCACHE_ENTRIES=0: the sweep and the effective addresses"
	@$(MAKE) --no-print-directory vectors ICACHE_ENTRIES=0 DCACHE_ENTRIES=0 BUILD=$(NOCACHE) \
	    OBUILD=$(OBUILD) || true
	@# Mismatches the cached core has as well are the RTL's, not the cache's:
	@# the failure list is compared with the last full sweep of the cached core
	@# ($(BUILD)/vectors.fail, from `make vectors-all`), and only a difference
	@# counts here. Without that list the sweep has to pass outright.
	@if [ -f $(BUILD)/vectors.fail ]; then \
	  if diff -q <(cut -d' ' -f1-3 $(BUILD)/vectors.fail) <(cut -d' ' -f1-3 $(NOCACHE)/vectors.fail) \
	      > /dev/null; then echo "  the sweep fails the same $$(wc -l < $(NOCACHE)/vectors.fail) vectors with the cache and without"; \
	  else echo "  FAIL: the sweep fails different vectors with the cache and without (run make vectors-all first?)"; \
	       echo sweep-differs >> $(NOCACHE)/cache.failed; fi; \
	else grep -q '^PASS' $(NOCACHE)/core_vec_tb.log \
	  || { echo "  FAIL: the sweep without the cache, and no $(BUILD)/vectors.fail to compare with"; \
	       echo vectors >> $(NOCACHE)/cache.failed; }; fi
	@$(MAKE) --no-print-directory ea ICACHE_ENTRIES=0 DCACHE_ENTRIES=0 BUILD=$(NOCACHE) \
	    OBUILD=$(OBUILD) || echo ea >> $(NOCACHE)/cache.failed
	@echo "  -- the programs, both ways"
	@ok=1; test -f $(NOCACHE)/cache.failed && { echo "  (failed so far: $$(tr '\n' ' ' < $(NOCACHE)/cache.failed))"; ok=0; }; \
	for e in 0 64; do \
	  iverilog -g2012 -Wall -Wno-timescale -DTB_ICACHE_ENTRIES=$$e \
	      -DTB_DCACHE_ENTRIES=$$e -I sim/tb \
	      -o $(NOCACHE)/cosim$$e.vvp -s core_cosim_tb \
	      $(RTL) sim/models/*.sv sim/tb/core_cosim_tb.sv \
	      > $(NOCACHE)/cosim$$e.build.log 2>&1 \
	    || { grep -v $(NOTES) $(NOCACHE)/cosim$$e.build.log; exit 1; }; \
	done; \
	for p in $(PROGS); do \
	  for e in 0 64; do \
	    vvp $(NOCACHE)/cosim$$e.vvp +image=$(BUILD)/programs/$$p.hex \
	        +trace=$(BUILD)/programs/$$p.trc +buslog=$(NOCACHE)/$$p.$$e.bus \
	        > $(NOCACHE)/cosim-$$p.$$e.log 2>&1; \
	    grep -q '^PASS' $(NOCACHE)/cosim-$$p.$$e.log \
	      || { echo "  FAIL: $$p with $$e entries in each cache"; tail -3 $(NOCACHE)/cosim-$$p.$$e.log; ok=0; }; \
	  done; \
	  r=$$(python3 tools/cache_diff.py $(NOCACHE)/$$p.0.bus $(NOCACHE)/$$p.64.bus) \
	    && echo "  PASS: $$p -- $$r" || { echo "  $$r"; ok=0; }; \
	done; \
	test $$ok -eq 1 && echo "PASS: cache"

cosim-long: dirs
	@$(MAKE) --no-print-directory cosim STEPS=4000000

# ---------------------------------------------------------------------------
# The MMU, against the oracle -- M11
#
# Bare-metal programs with real MC68030 translation tables, run on UAE030 and
# on the core and compared at every instruction boundary on every register,
# the MMU's included, and on the ORDERED PHYSICAL DATA-ACCESS STREAM: every
# operand and stack access at its physical address, every table-search read,
# every U and M write-back (tools/bus_diff.py stream). Instruction fetches are
# not compared, nor reads the data cache may have answered.
#
# The oracle gets the core harness's memory map (rd68031_core_harness.svh):
# the 64 KB 32-bit port repeated through $0FFF_FFFF, the 16-bit, 8-bit and
# synchronous ports at $1000_0000, $2000_0000 and $3000_0000, and a window at
# $4000_0000 that answers with a bus error, which core_cosim_tb +mmu sets up.
#
# mmu_fault's trace is cut at 3,000 instructions: the oracle restarts a faulted
# instruction where the part continues it, and an access its handler abandons
# (DF cleared) is retried forever there (doc/m11-mismatches.md, b8). mmu_rerun's
# is cut at 950, before its phase 11: the oracle stacks the physical address of
# a translated access BERR ended, and reruns it there for ever (b18).
#
#   COSIMMMU=<programs>   which (default all); MMU_MAXFAIL=N register
#                         disagreements to report before a run stops
#                         (each one is followed by a deposit of the
#                         oracle's registers, while the PCs agree)
# ---------------------------------------------------------------------------
COSIMMMU    ?= mmu_regs mmu_walk mmu_fault mmu_rerun mmu_cosim cow_mmu
MMU_MAXFAIL ?= 5000
MMUCMP      := $(BUILD)/cosim-mmu
MMUMAP      := -r 10000000:F0000000:10000 -r 20000000:F0000000:10000 \
               -r 30000000:F0000000:10000 -e 40000000:F0000000

cosim-mmu: dirs $(MMUHEX) build/programs/mmu_cosim.hex $(COWMMU).hex $(OBUILD)/uae030_trace
	@mkdir -p $(MMUCMP)
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cosim_tb.vvp -s core_cosim_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_cosim_tb.sv \
	    > $(BUILD)/core_cosim_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_cosim_tb.build.log; exit 1; }
	@ok=1; for p in $(COSIMMMU); do \
	  n=200000; [ $$p = mmu_fault ] && n=3000; [ $$p = mmu_rerun ] && n=950; \
	  $(CROSS)objcopy -O binary build/programs/$$p.elf $(MMUCMP)/$$p.bin; \
	  $(OBUILD)/uae030_trace $(MMUMAP) -B $(MMUCMP)/$$p.ubus $(MMUCMP)/$$p.bin $$n \
	      > $(MMUCMP)/$$p.trc 2> $(MMUCMP)/$$p.trace.log \
	    || { echo "  FAIL: $$p: the oracle"; cat $(MMUCMP)/$$p.trace.log; ok=0; continue; }; \
	  vvp $(BUILD)/core_cosim_tb.vvp +image=build/programs/$$p.hex +trace=$(MMUCMP)/$$p.trc \
	      +mmu +mmubus=$(MMUCMP)/$$p.cbus +maxfail=$(MMU_MAXFAIL) > $(MMUCMP)/$$p.log 2>&1; \
	  python3 tools/bus_diff.py stream $(MMUCMP)/$$p.ubus $(MMUCMP)/$$p.cbus \
	      > $(MMUCMP)/$$p.diff 2>&1; d=$$?; \
	  if grep -q '^PASS' $(MMUCMP)/$$p.log && [ $$d -eq 0 ]; then \
	    echo "  PASS: $$p -- $$(sed -n 's/^core_cosim_tb: \([0-9]*\) instructions, every.*/\1/p' $(MMUCMP)/$$p.log) instructions, every register and the data-access stream"; \
	  else \
	    echo "  FAIL: $$p"; grep -E "^  FAIL" $(MMUCMP)/$$p.log | head -20; \
	    grep -E '^core_cosim_tb: .*disagreed' $(MMUCMP)/$$p.log; \
	    sed -n '1,40p' $(MMUCMP)/$$p.diff; ok=0; \
	  fi; \
	done; \
	test $$ok -eq 1 && echo "PASS: cosim-mmu"

# ---------------------------------------------------------------------------
# A second core: AP68030, pin against pin -- M11
#
# doc/plan.md layer 2. AP68030 (Inputs/ref/AP68030, GPL-2) is built by
# Verilator into a bench of our own (sim/ap030/ap030_tb.sv) around the slave
# models and memory map of rd68031_core_harness.svh; the core runs the same
# images in core_pins_tb under iverilog; both write their transfers through
# sim/models/rd68031_busmon.sv, and tools/bus_diff.py pins compares the data
# transfers in order -- address, FC, SIZ, R/W, termination, data, RMC, CBREQ,
# CBACK, CIIN, CIOUT -- phase by phase. Clock-level timing is not compared.
#
# The AP68030 build is heavy (CLAUDE.md): it runs once, alone, at -j4, and is
# reused. AP030PROGS picks the programs.
# ---------------------------------------------------------------------------
AP030PROGS ?= busprobe mmu_cosim mmu_walk mmu_regs mmu_fault cow_mmu
APBUILD    := $(BUILD)/ap030
APBENCH    := $(APBUILD)/obj_bench/ap030_tb

build/programs/busprobe.hex: sim/programs/busprobe.S sim/programs/mmu_common.inc sim/programs/mmu.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68030 -Isim/programs -c -o build/programs/busprobe.o $<
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/mmu.ld \
	    -o build/programs/busprobe.elf build/programs/busprobe.o \
	    2> build/programs/busprobe.link.log || { cat build/programs/busprobe.link.log; exit 1; }
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 build/programs/busprobe.elf $@

$(APBENCH): sim/ap030/ap030_tb.sv sim/ap030/build_bench.sh sim/models/rd68031_slave.sv \
            sim/models/rd68031_busmon.sv sim/models/rd68031_knobs.svh
	@echo "  ap030: building AP68030 into $(APBUILD)/obj_bench (Verilator, alone)"
	@sh sim/ap030/build_bench.sh $(abspath $(APBUILD))/obj_bench

ap030: dirs $(APBENCH) build/programs/busprobe.hex build/programs/mmu_cosim.hex $(MMUHEX) $(COWMMU).hex
	@mkdir -p $(APBUILD)/run
	@iverilog $(IVFLAGS) -I sim/tb -I sim/models -o $(BUILD)/core_pins_tb.vvp -s core_pins_tb \
	    $(RTL) sim/models/rd68031_slave.sv sim/models/rd68031_busmon.sv sim/tb/core_pins_tb.sv \
	    > $(BUILD)/core_pins_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_pins_tb.build.log; exit 1; }
	@ok=1; for p in $(AP030PROGS); do \
	  e=; [ $$p = cow_mmu ] && e="+endaddr=2008 +endval=600d"; \
	  $(APBENCH) +image=build/programs/$$p.hex +pins=$(APBUILD)/run/$$p.ap.pins $$e \
	      > $(APBUILD)/run/$$p.ap.log 2>&1; \
	  vvp $(BUILD)/core_pins_tb.vvp +image=build/programs/$$p.hex +pins=$(APBUILD)/run/$$p.rd.pins $$e \
	      > $(APBUILD)/run/$$p.rd.log 2>&1; \
	  grep -h -E '^(PASS|FAIL)' $(APBUILD)/run/$$p.ap.log $(APBUILD)/run/$$p.rd.log | sed 's/^/  /'; \
	  if python3 tools/bus_diff.py pins $(APBUILD)/run/$$p.ap.pins $(APBUILD)/run/$$p.rd.pins \
	      > $(APBUILD)/run/$$p.diff 2>&1; then \
	    echo "  PASS: $$p -- $$(sed -n 1p $(APBUILD)/run/$$p.diff | sed 's/^ *//')"; \
	  else echo "  FAIL: $$p"; sed -n '1,30p' $(APBUILD)/run/$$p.diff; ok=0; fi; \
	done; \
	test $$ok -eq 1 && echo "PASS: ap030"

# ---------------------------------------------------------------------------
# WinUAE's cputest corpus, on the core
#
# cputestgen (built out of tree into build/cputest/gen/ by
# tools/cputest/build.sh) writes a 68030 corpus from CPUTEST_INI into
# build/cputest/run/data/; tools/cputest/convert.py replays its runner's
# bookkeeping and writes the stream core_cputest_tb runs. doc/oracles.md has
# the conventions it reproduces.
#
#   CPUTEST_INI=<file>   the generator's ini (default tools/cputest/cputestgen.ini)
#   CPUTEST_SEL=ADD,MOVE.L   only these instructions (a bare name takes every size)
#   CPUTEST_MAX=N        at most N tests run per instruction, sampled evenly
#                        across its corpus; 0 runs every one (hours)
#   CPUTEST_TIMEOUT=s    the generator's time limit per instruction (default 120);
#                        one that runs out is listed and left out
#
# The corpus is regenerated only when the ini or the generator changes.
# ---------------------------------------------------------------------------
CTBUILD     := $(BUILD)/cputest
CPUTEST_INI ?= tools/cputest/cputestgen.ini
CPUTEST_SEL ?=
CPUTEST_MAX ?= 40

$(CTBUILD)/gen/cputestgen: tools/cputest/build.sh tools/cputest/compat/cputest_compat.h \
                           tools/cputest/compat/ua_stub.cpp
	@mkdir -p $(CTBUILD)/gen
	@echo "  cputest: building cputestgen into $(CTBUILD)/gen"
	@JOBS=3 sh tools/cputest/build.sh $(CTBUILD)/gen > $(CTBUILD)/gen.log 2>&1 \
	  || { tail -30 $(CTBUILD)/gen.log; exit 1; }

$(CTBUILD)/run/stamp: $(CTBUILD)/gen/cputestgen $(CPUTEST_INI) tools/cputest/generate.sh
	@rm -rf $(CTBUILD)/run
	@mkdir -p $(CTBUILD)/run/data
	@cp $(CPUTEST_INI) $(CTBUILD)/run/cputestgen.ini
	@echo "  cputest: generating the corpus from $(CPUTEST_INI), one instruction at a time"
	@set -o pipefail; sh tools/cputest/generate.sh $(CTBUILD)/gen/cputestgen $(CPUTEST_INI) $(CTBUILD)/run \
	  | sed 's/^/  /'
	@touch $@

cputest: dirs $(CTBUILD)/run/stamp
	@python3 tools/cputest/convert.py bench $(CTBUILD) $(CTBUILD)/run/data/*/ \
	    --select "$(CPUTEST_SEL)" --max $(CPUTEST_MAX) | sed 's/^/  /'
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cputest_tb.vvp -s core_cputest_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_cputest_tb.sv \
	    > $(BUILD)/core_cputest_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_cputest_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_cputest_tb.vvp +vec=$(CTBUILD)/cputest.vec +mem=$(CTBUILD) \
	    +faillog=$(CTBUILD)/cputest.fail > $(BUILD)/core_cputest_tb.log 2>&1; \
	 grep -E '^  FAIL' $(BUILD)/core_cputest_tb.log | head -25; \
	 grep -E '^core_cputest_tb: ' $(BUILD)/core_cputest_tb.log; \
	 grep -q '^PASS' $(BUILD)/core_cputest_tb.log || { tail -2 $(BUILD)/core_cputest_tb.log; exit 1; }

# ---------------------------------------------------------------------------
# rd-virt (M13): the deterministic m68k `virt` machine, with the RTL, UAE030,
# or both in lockstep. doc/virt.md has the machine, the lockstep and its
# options; doc/m13-mismatches.md what it found.
#
#   make virt-uae          Linux to the shell and the command set on UAE030
#                          alone -- validates the machine, fast
#   make virt-bare         the bare-metal programs, in lockstep
#   make virt-linux-solo   Linux on the RTL alone
#   make virt-linux        Linux in lockstep: no divergence and the expected
#                          console is the pass (VIRT_CACHES=off: CDIS on the
#                          RTL and no data cache in the oracle)
#
#   VIRT_OPTS=...          more rdvirt options (--burst, --ram-waits 2, ...)
#
# The RTL build (Verilator) and the guest build (Linux, BusyBox) are heavy
# jobs: each runs once, alone, at JOBS=4 at most, and is reused (CLAUDE.md).
# None of these is in `make check`.
# ---------------------------------------------------------------------------
VIRT        := $(BUILD)/virt
VGUEST      := $(VIRT)/guest
VIRTBIN     := $(VIRT)/obj/rdvirt
VIRTUAE     := $(VIRT)/rdvirt-uae
VIRT_CMDLINE ?= console=ttyGF0 lpj=250000 rdvirt.shell
VIRT_SCRIPT ?= sim/virt/linux/commands.script
VIRT_OPTS   ?=
VIRT_CACHES ?= on
VIRT_MAXSTEPS ?= 400000000
VIRTPROGS   := virt_hello virt_timer virt_mmu
VIRTSRC     := $(wildcard sim/virt/*.cpp sim/virt/*.h) sim/virt/build.sh
VIRTLINUX   := --kernel $(VGUEST)/vmlinux --initrd $(VGUEST)/initramfs.cpio.gz \
               --cmdline "$(VIRT_CMDLINE)" --script $(VIRT_SCRIPT) --expect done \
               --progress 10000000 --max-steps $(VIRT_MAXSTEPS)
ifeq ($(VIRT_CACHES),off)
VIRTCACHE   := --cdis --no-dcache
endif

$(VIRTUAE): $(VIRTSRC) $(OBUILD)/libuae030.a
	@sh sim/virt/build.sh uae $(VIRT) > /dev/null

$(VIRTBIN): $(VIRTSRC) sim/virt/public.vlt $(OBUILD)/libuae030.a $(RTL)
	@echo "  virt: building the RTL machine into $(VIRT)/obj (Verilator, alone)"
	@sh sim/virt/build.sh rtl $(VIRT) > /dev/null

$(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz: sim/virt/linux/build.sh sim/virt/linux/rd-virt.config \
            sim/virt/linux/init sim/virt/linux/cpio.list
	@echo "  virt: building the guest into $(VGUEST) (Linux and BusyBox, alone)"
	@sh sim/virt/linux/build.sh $(VGUEST) | sed 's/^/  /'

build/programs/virt_%.elf: sim/programs/virt_%.S sim/programs/virt.inc sim/programs/virt.ld
	@mkdir -p build/programs
	@$(CROSS)gcc -mcpu=68030 -Isim/programs -c -o build/programs/virt_$*.o $<
	@$(CROSS)gcc -nostdlib -nostartfiles -Wl,--build-id=none -T sim/programs/virt.ld \
	    -o $@ build/programs/virt_$*.o

virt-bare: $(VIRTBIN) $(patsubst %,build/programs/%.elf,$(VIRTPROGS))
	@ok=1; for p in $(VIRTPROGS); do for m in "" "--burst" "--cdis --no-dcache"; do \
	  $(VIRTBIN) --cpu lockstep --bare build/programs/$$p.elf --quiet --progress 0 \
	      --expect "PASS: $$p" --dump $(VIRT)/$$p.div $$m $(VIRT_OPTS) \
	      > $(VIRT)/$$p.log 2>&1; \
	  if grep -q '^PASS' $(VIRT)/$$p.log; then echo "  PASS: $$p $$m -- $$(grep -o '[0-9]* steps' $(VIRT)/$$p.log | tail -1)"; \
	  else echo "  FAIL: $$p $$m"; tail -5 $(VIRT)/$$p.log; ok=0; fi; done; done; \
	test $$ok -eq 1 && echo "PASS: virt-bare"

virt-uae: $(VIRTUAE) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@$(VIRTUAE) --cpu uae $(VIRTLINUX) --quiet --console-log $(VIRT)/uae.console \
	    $(VIRT_OPTS) > $(VIRT)/uae.log 2>&1; \
	 grep -E '^\[uae030\] end' $(VIRT)/uae.log | sed 's/^/  /'; \
	 grep -q '^PASS' $(VIRT)/uae.log || { tail -12 $(VIRT)/uae.log; exit 1; }
	@echo "PASS: virt-uae (console in $(VIRT)/uae.console)"

virt-linux-solo: $(VIRTBIN) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@$(VIRTBIN) --cpu rtl $(VIRTLINUX) $(VIRTCACHE) --quiet --console-log $(VIRT)/solo.console \
	    $(VIRT_OPTS) > $(VIRT)/solo.log 2>&1; \
	 grep -E '^\[rtl\] end' $(VIRT)/solo.log | sed 's/^/  /'; \
	 grep -q '^PASS' $(VIRT)/solo.log || { tail -12 $(VIRT)/solo.log; exit 1; }
	@echo "PASS: virt-linux-solo (console in $(VIRT)/solo.console)"

virt-linux: $(VIRTBIN) $(VGUEST)/vmlinux $(VGUEST)/initramfs.cpio.gz
	@$(VIRTBIN) --cpu lockstep $(VIRTLINUX) $(VIRTCACHE) --quiet \
	    --console-log $(VIRT)/lockstep-$(VIRT_CACHES).console --dump $(VIRT)/lockstep-$(VIRT_CACHES).div \
	    $(VIRT_OPTS) > $(VIRT)/lockstep-$(VIRT_CACHES).log 2>&1; \
	 grep -E '^\[lockstep\] end' $(VIRT)/lockstep-$(VIRT_CACHES).log | sed 's/^/  /'; \
	 grep -q '^PASS' $(VIRT)/lockstep-$(VIRT_CACHES).log || { grep -A12 '^DIVERGENCE' $(VIRT)/lockstep-$(VIRT_CACHES).log | head -30; tail -3 $(VIRT)/lockstep-$(VIRT_CACHES).log; exit 1; }
	@echo "PASS: virt-linux (console in $(VIRT)/lockstep-$(VIRT_CACHES).console)"

# ---------------------------------------------------------------------------
# MAME's Sun-3/80 (M14): the boot PROM to its monitor on the core, against
# MAME's own m68030. doc/oracles.md ("MAME") has the machine and how the core
# plugs in; doc/m14-mismatches.md what the comparison found.
#
#   make sun3x            the PROM (rev 3.0.3) through its self-test to the
#                         monitor, and sim/mame/monitor.cmds typed at it, on
#                         the core and on MAME's m68030 (no FPU on either);
#                         the two consoles must be the same, byte for byte
#   make sun3x-m68030     ... MAME's m68030 alone (seconds)
#
#   SUN3X_BIOS=rev302|rev30|rev292   another PROM revision
#   SUN3X_TIMEOUT=N       wall seconds the core may take (about 15 minutes)
#
# The PROMs are Sun firmware, supplied by the user and never committed:
# Inputs/ref/PROMs/, checked against Inputs/sw/PROMS.sha256. The NVRAM image
# (console on ttya) is made from sim/mame/eeprom.txt by sim/mame/mk_nvram.py.
# Building MAME (-j2) and the core's shared
# object (Verilator, -j4) are heavy jobs: each runs alone (CLAUDE.md).
# Neither target is in `make check`.
# ---------------------------------------------------------------------------
MAMEB       := $(BUILD)/mame
MAMEBIN     := $(MAMEB)/src/sun3x
MAMEVLT     := $(MAMEB)/vlt/rd68031_vlt.so
MAMEROMS    := $(MAMEB)/roms/sun3_80
SUN3X_BIOS  ?= rev303
SUN3X_TIMEOUT ?= 2400
SUN3XROMS   := $(MAMEROMS)/sun3_80_v3.0.3 $(MAMEROMS)/sun3_80_v3.0.2 \
               $(MAMEROMS)/sun3_80_v3.0 $(MAMEROMS)/sun3_80_v2.9.2 $(MAMEROMS)/timekpr_380.bin

$(MAMEBIN): sim/mame/build.sh sim/mame/sun3x.patch sim/mame/patched.lst sim/mame/rd68031.h \
            sim/mame/rd68031.cpp sim/mame/rd68031_vlt.h
	@echo "  sun3x: building MAME's sun3x driver into $(MAMEB)/src (-j2, alone; 30 min from clean)"
	@bash sim/mame/build.sh mame $(MAMEB) | sed 's/^/  /'

$(MAMEVLT): sim/mame/build.sh sim/mame/rd68031_vlt.h sim/mame/rd68031_vlt.cpp \
            sim/mame/rd68031_fpu.sv sim/virt/public.vlt $(RTL) \
            $(wildcard Inputs/ip/RD68884/rtl/*.sv Inputs/ip/RD68884/rtl/gen/*.sv)
	@echo "  sun3x: building the core into $(MAMEB)/vlt (Verilator, alone)"
	@bash sim/mame/build.sh vlt $(MAMEB) | sed 's/^/  /'

$(MAMEROMS)/sun3_80_%: Inputs/ref/PROMs/sun3_80_%.bin
	@mkdir -p $(MAMEROMS)
	@grep -F "$<" Inputs/sw/PROMS.sha256 | sha256sum -c --quiet - \
	  || { echo "$<: not the PROM Inputs/sw/PROMS.sha256 names"; exit 1; }
	@cp $< $@

$(MAMEROMS)/timekpr_380.bin: sim/mame/eeprom.txt sim/mame/mk_nvram.py
	@mkdir -p $(MAMEROMS)
	@python3 sim/mame/mk_nvram.py sim/mame/eeprom.txt $@

sun3x-m68030: $(MAMEBIN) $(SUN3XROMS)
	@MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/run.sh sun3_80ref $(CURDIR)/$(MAMEB)/m68030 4431 300 $(SUN3X_BIOS) \
	    | sed 's/^/  m68030: /'; \
	 grep -h '^emulated time' $(MAMEB)/m68030/console.out.mame | sed 's/^/  m68030: /'; \
	 tr -d '\r\000' < $(MAMEB)/m68030/console.out | tail -c 2 | grep -q '^>$$' \
	  || { echo "FAIL: sun3x-m68030 (no monitor prompt; $(MAMEB)/m68030/console.out)"; exit 1; }
	@echo "PASS: sun3x-m68030 (console in $(MAMEB)/m68030/console.out)"

sun3x: $(MAMEBIN) $(MAMEVLT) $(SUN3XROMS) sun3x-m68030
	@echo "  rd68031: the PROM on the core (about 15 minutes)"
	@MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/run.sh sun3_80rd $(CURDIR)/$(MAMEB)/rd68031 4432 $(SUN3X_TIMEOUT) $(SUN3X_BIOS) \
	    | sed 's/^/  rd68031: /'; \
	 grep -h '^emulated time\|^rd68031:\|double bus' $(MAMEB)/rd68031/console.out.mame | sed 's/^/  /'
	@if cmp -s $(MAMEB)/m68030/console.out $(MAMEB)/rd68031/console.out; then \
	  echo "PASS: sun3x (the two consoles are identical: $(MAMEB)/rd68031/console.out)"; \
	else \
	  echo "FAIL: sun3x (the consoles differ)"; \
	  diff <(tr -d '\r\000' < $(MAMEB)/m68030/console.out) \
	       <(tr -d '\r\000' < $(MAMEB)/rd68031/console.out) | head -30; exit 1; \
	fi

# ---------------------------------------------------------------------------
# NetBSD/sun3x 10.2 on MAME's Sun-3/80 (M14 phase B; doc/oracles.md, "MAME")
#
#   netbsd-disk           the media of Inputs/sw/MANIFEST-netbsd fetched and
#                         checked, a disk made, and NetBSD installed on it from
#                         its miniroot on MAME's m68030 (sim/mame/netbsd.sh):
#                         build/netbsd/netbsd.hd (a few minutes)
#   netbsd-sun3x-m68030   that disk booted to multi-user on MAME's m68030, root
#                         logged in, sim/mame/netbsd-boot.cmds typed, halted
#   netbsd-sun3x          ... on the core, with RD68884 as its FPU, and each
#                         command's answer compared with the m68030's
#                         (sim/mame/answers.py). Hours: NETBSD_TIMEOUT
#
# Not in `make check`. MAME's runs are light; its and the core's builds are
# the heavy jobs above.
# ---------------------------------------------------------------------------
NETBSDB        := $(BUILD)/netbsd
NETBSD_TIMEOUT ?= 21600

$(NETBSDB)/netbsd.hd: Inputs/sw/MANIFEST-netbsd sim/mame/netbsd.sh sim/mame/mkdisk.py \
                      sim/mame/netbsd-install.cmds $(MAMEBIN) $(SUN3XROMS)
	@echo "  netbsd: fetching, making the disk, installing on MAME's m68030"
	@bash sim/mame/netbsd.sh fetch $(CURDIR)/$(NETBSDB)
	@bash sim/mame/netbsd.sh disk $(CURDIR)/$(NETBSDB)
	@MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/netbsd.sh install $(CURDIR)/$(NETBSDB) | sed 's/^/  netbsd: /'

netbsd-disk: $(NETBSDB)/netbsd.hd

netbsd-sun3x-m68030: $(NETBSDB)/netbsd.hd sim/mame/netbsd-boot.cmds
	@MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/netbsd.sh boot sun3_80ref $(CURDIR)/$(NETBSDB) \
	    $(CURDIR)/$(NETBSDB)/m68030 4461 1800 | sed 's/^/  m68030: /'
	@python3 -I sim/mame/answers.py 'rd68031# ' $(NETBSDB)/m68030/console.out $(NETBSDB)/m68030/console.out \
	    > /dev/null || { echo "FAIL: netbsd-sun3x-m68030 (no shell answers; $(NETBSDB)/m68030/console.out)"; exit 1; }
	@echo "PASS: netbsd-sun3x-m68030 (console in $(NETBSDB)/m68030/console.out)"

netbsd-sun3x: netbsd-sun3x-m68030 $(MAMEVLT)
	@echo "  rd68031: NetBSD on the core (hours)"
	@MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/netbsd.sh boot sun3_80rd $(CURDIR)/$(NETBSDB) \
	    $(CURDIR)/$(NETBSDB)/rd68031 4462 $(NETBSD_TIMEOUT) | sed 's/^/  rd68031: /'
	@grep -h '^rd68031:\|double bus' $(NETBSDB)/rd68031/console.out.mame | sed 's/^/  /'
	@set -o pipefail; if python3 -I sim/mame/answers.py 'rd68031# ' $(NETBSDB)/m68030/console.out \
	      $(NETBSDB)/rd68031/console.out | sed 's/^/  /'; then \
	  echo "PASS: netbsd-sun3x (every command answered as on the m68030: $(NETBSDB)/rd68031/console.out)"; \
	else echo "FAIL: netbsd-sun3x ($(NETBSDB)/rd68031/console.out)"; exit 1; fi

# ---------------------------------------------------------------------------
# SunOS 4.1.1 on MAME's Sun-3/80 (M14 phase B; doc/oracles.md, "MAME")
#
#   sunos-disk            the first ten files of sun3arc's tape 1
#                         (Inputs/sw/MANIFEST-sunos) fetched and checked, a
#                         tape image and a labelled disk made, the miniroot
#                         copied into sd0b by MUNIX booted from the tape, and
#                         SunOS installed by hand from the miniroot's shell,
#                         all on MAME's m68030 (sim/mame/sunos.sh):
#                         build/sunos/sunos.hd (a quarter of an hour)
#   sunos-sun3x-m68030    that disk booted to multi-user on MAME's m68030, root
#                         logged in, sim/mame/sunos-boot.cmds typed, halted
#   sunos-sun3x           ... on the core, with RD68884 as its FPU, and each
#                         command's answer compared with the m68030's
#                         (sim/mame/answers.py). Hours: SUNOS_TIMEOUT
#
# Not in `make check`. MAME's runs are light; its and the core's builds are
# the heavy jobs above.
# ---------------------------------------------------------------------------
SUNOSB        := $(BUILD)/sunos
SUNOS_TIMEOUT ?= 43200

$(SUNOSB)/sunos.hd: Inputs/sw/MANIFEST-sunos sim/mame/sunos.sh sim/mame/mktape.py sim/mame/mkdisk.py \
                    sim/mame/sunos-miniroot.cmds sim/mame/sunos-install.cmds $(MAMEBIN) $(SUN3XROMS)
	@echo "  sunos: fetching, making the tape and the disk, installing on MAME's m68030"
	@bash sim/mame/sunos.sh fetch $(CURDIR)/$(SUNOSB)
	@bash sim/mame/sunos.sh media $(CURDIR)/$(SUNOSB)
	@set -o pipefail; MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/sunos.sh miniroot $(CURDIR)/$(SUNOSB) | sed 's/^/  sunos: /'
	@set -o pipefail; MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/sunos.sh install $(CURDIR)/$(SUNOSB) | sed 's/^/  sunos: /'

sunos-disk: $(SUNOSB)/sunos.hd

sunos-sun3x-m68030: $(SUNOSB)/sunos.hd sim/mame/sunos-boot.cmds
	@MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/sunos.sh boot sun3_80ref $(CURDIR)/$(SUNOSB) \
	    $(CURDIR)/$(SUNOSB)/m68030 4471 1800 | sed 's/^/  m68030: /'
	@python3 -I sim/mame/answers.py 'rd68031# ' $(SUNOSB)/m68030/console.out $(SUNOSB)/m68030/console.out \
	    > /dev/null || { echo "FAIL: sunos-sun3x-m68030 (no shell answers; $(SUNOSB)/m68030/console.out)"; exit 1; }
	@echo "PASS: sunos-sun3x-m68030 (console in $(SUNOSB)/m68030/console.out)"

sunos-sun3x: sunos-sun3x-m68030 $(MAMEVLT)
	@echo "  rd68031: SunOS on the core (hours)"
	@MAMEDIR=$(CURDIR)/$(MAMEB) bash sim/mame/sunos.sh boot sun3_80rd $(CURDIR)/$(SUNOSB) \
	    $(CURDIR)/$(SUNOSB)/rd68031 4472 $(SUNOS_TIMEOUT) | sed 's/^/  rd68031: /'
	@grep -h '^rd68031:\|double bus' $(SUNOSB)/rd68031/console.out.mame | sed 's/^/  /'
	@set -o pipefail; if python3 -I sim/mame/answers.py 'rd68031# ' $(SUNOSB)/m68030/console.out \
	      $(SUNOSB)/rd68031/console.out | sed 's/^/  /'; then \
	  echo "PASS: sunos-sun3x (every command answered as on the m68030: $(SUNOSB)/rd68031/console.out)"; \
	else echo "FAIL: sunos-sun3x ($(SUNOSB)/rd68031/console.out)"; exit 1; fi

# ---------------------------------------------------------------------------
# AC timing, against the MC68030EC data sheet
#
# One run per speed grade. The analysis measures separations in clock edges, so a
# recording made at one frequency is evidence about that frequency and nothing
# else: judging a 50 ns recording against the 50 MHz limits would credit the
# design with half-clocks it does not have there.
#
# Specification 1 gives each grade's minimum cycle time, and those are the five
# periods below: 20, 25, 33.33, 40 and 50 MHz, every grade the data sheet has.
# ---------------------------------------------------------------------------
TIMGRADES := 50:20 40:25 30:33 25:40 20:50
PADSKEW   ?= 0

timing-build: dirs
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/rd68031_timing_tb.vvp \
	    -s rd68031_timing_tb $(RTL) sim/models/*.sv sim/tb/rd68031_timing_tb.sv \
	    > $(BUILD)/timing.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/timing.build.log; exit 1; }
	@python3 tools/timing/feasible.py > $(BUILD)/timing-selftest.log \
	  || { cat $(BUILD)/timing-selftest.log; exit 1; }

timing: timing-build
	@ok=1; for g in $(TIMGRADES); do \
	  p=$${g%%:*}; f=$${g##*:}; \
	  vvp $(BUILD)/rd68031_timing_tb.vvp +period=$$p \
	      +log=$(BUILD)/timing-$$f.log > $(BUILD)/timing-run-$$f.log 2>&1; \
	  grep -q '^PASS' $(BUILD)/timing-run-$$f.log \
	    || { echo "FAIL: the timing testbench did not complete at $$p ns"; ok=0; }; \
	  python3 tools/timing/analyse.py --freq $$f --pad-skew $(PADSKEW) \
	      $(BUILD)/timing-$$f.log || ok=0; \
	done; \
	test $$ok -eq 1 && echo "PASS: timing"

# The same, and then every grade again with its binding constraints, a pad
# assignment that meets every limit, and the input sampling windows.
timing-verbose: timing-build
	@$(MAKE) --no-print-directory timing
	@for g in $(TIMGRADES); do f=$${g##*:}; \
	  python3 tools/timing/analyse.py --freq $$f --pad-skew $(PADSKEW) --verbose \
	      $(BUILD)/timing-$$f.log; done

# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------
check: ucode-check lint audit sim timing
	@echo "PASS: check"

# ---------------------------------------------------------------------------
# Vendor front-ends. Each has its own target and none is in `check`.
# ---------------------------------------------------------------------------
synth: dirs
	@printf '%s\n' $(RTL) > $(BUILD)/rtl.f
	@scripts/vivado.sh -mode batch -nojournal -nolog -source scripts/synth.tcl \
	    -tclargs $(BUILD) $(TOP) $(XPART) $(ICACHE_ENTRIES) $(COPROCESSOR) $(DCACHE_ENTRIES)

# Place and route, for the frequency that means something. Out of context, with
# hierarchy kept. Reports land in $(BUILD)/impl_*.rpt and the checkpoint beside
# them, which `make paths` reads.
impl: dirs
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(BUILD) && $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source $(CURDIR)/scripts/impl.tcl \
	    -tclargs $(XPART) $(TOP) $(CURDIR) $(ICACHE_ENTRIES) $(COPROCESSOR) $(DCACHE_ENTRIES) \
	    > impl.log 2>&1; rc=$$?; \
	  grep -E '^(RD68031|ERROR|CRITICAL WARNING)' impl.log; exit $$rc

# What limits the frequency, with the routes the microcode cannot take excluded
# -- scripts/paths.tcl says which and why. Runs on the checkpoint `make impl`
# left behind. doc/critical-path.md is written from it.
paths: dirs
	@cd $(BUILD) && $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source $(CURDIR)/scripts/paths.tcl -tclargs $(CURDIR) > paths.log 2>&1 || \
	    { grep -E '^(RD68031-PATHS|ERROR)' paths.log; exit 1; }
	@grep -E '^RD68031-PATHS' $(BUILD)/paths.log
	@python3 tools/paths_report.py $(BUILD)/paths_activatable.rpt
	@echo "  the pins, at zero input and output delay (the slowest twelve; all in $(BUILD)/paths_pins.rpt):"
	@sort -k4 -n -r $(BUILD)/paths_pins.rpt | head -12 | cut -c1-160

# quartus_map returns 0 on the one thing that matters most here, so the grep is the
# gate and not the exit code: a package-scoped constant inside an instantiation's
# port expression becomes an implicit one-bit net and a Warning (10236), which is a
# netlist that quietly stops matching the source.
# The pipe into tee would throw the exit status away along with everything else, so
# pipefail is not optional here: without it a Tcl error inside quartus_sh reports
# "quartus: ok" and the gate cannot fail. Measured, on this Makefile.
lint-quartus: dirs
	@printf '%s\n' $(RTL) > $(BUILD)/rtl.f
	@set -o pipefail; scripts/altera.sh quartus_sh -t scripts/quartus.tcl map \
	    $(BUILD) $(TOP) $(AFAMILY) $(APART) $(ICACHE_ENTRIES) $(COPROCESSOR) $(DCACHE_ENTRIES) \
	    | tee $(BUILD)/quartus_map.log
	@if grep -q 'Implicit Net warning\|Warning (10236)' $(BUILD)/quartus_map.log; then \
	    echo "FAIL: quartus found an implicit net -- the netlist does not match the source"; \
	    grep 'Warning (10236)' $(BUILD)/quartus_map.log; exit 1; fi
	@echo "  quartus: ok"

# Quartus place and route and timing, for a second toolchain's number. The fit
# is its own build directory so that a fit and a lint-quartus do not share a
# project. Quartus's Fmax scales both clock edges together, which is what this
# design's edge-to-edge paths need, so it is quoted directly.
QBUILD := $(BUILD)/quartus

quartus: dirs
	@mkdir -p $(QBUILD)
	@printf '%s\n' $(RTL) > $(QBUILD)/rtl.f
	@set -o pipefail; scripts/altera.sh quartus_sh -t scripts/quartus.tcl fit \
	    $(QBUILD) $(TOP) $(AFAMILY) $(APART) $(ICACHE_ENTRIES) $(COPROCESSOR) $(DCACHE_ENTRIES) \
	    > $(QBUILD)/fit.log 2>&1 || { grep -E '^QUARTUS|Error' $(QBUILD)/fit.log | head; exit 1; }
	@if grep -q 'Warning (10236)' $(QBUILD)/fit.log; then \
	    echo "FAIL: quartus found an implicit net"; exit 1; fi
	@grep -E '^QUARTUS' $(QBUILD)/fit.log
	@grep -A12 -E 'Slow 1[12]00mV 85C Model Fmax Summary' $(QBUILD)/quartus_out/$(TOP).sta.rpt \
	    | grep -E 'MHz' | head -3
	@grep -E 'Logic utilization|Total logic elements|Total registers|Total (block )?memory bits|Total DSP|Total RAM Blocks|Embedded Multiplier' \
	    $(QBUILD)/quartus_out/$(TOP).fit.summary

lint-questa: dirs
	@scripts/questa.sh $(BUILD) $(TOP) $(RTL)
	@echo "  questa: ok"

print-rtl:
	@echo $(RTL)

clean:
	rm -rf $(BUILD)
