# RD68031

A from-scratch SystemVerilog implementation of the Motorola **MC68030**, for FPGA
and ASIC.

It is the successor of [RD68021](https://github.com/MelkhiorVintageComputing/RD68021),
an MC68020 that boots SunOS 4.1.1, and starts from a fork of it. What the MC68030 adds
over the MC68020 is the work of this repository:

- the **paged memory management unit** on chip: TC, CRP, SRP, the transparent
  translation registers TT0/TT1, MMUSR, the 22-entry address translation cache, the
  table search, and PMOVE/PTEST/PLOAD/PFLUSH;
- a 256-byte **data cache**, next to an instruction cache reorganised as the MC68030's
  16 lines of four longwords;
- the **synchronous bus** (`STERM`) and **burst** fills (`CBREQ`/`CBACK`), with
  `CIIN`/`CIOUT`.

## Status

**M0: scaffolding.** The RTL is still RD68021's MC68020, renamed. It passes the same
gate it did there. The milestones that turn it into an MC68030 are listed in
`doc/plan.md`, and the state of each oracle is in `doc/oracles.md`.

## Goals

1. **Software compatibility.** Everything a real MC68030 runs, this runs. Where
   the reference emulators disagree with the core, the Motorola manuals in
   `Inputs/doc/` decide.
2. **Bus compatibility.** The pins follow the MC68030's bus states, asynchronous,
   synchronous and burst, so the core can sit on a real 68030 board's bus.
3. **Cycle counts are allowed to differ, but never silently.** Every divergence
   from the manual's instruction timings is measured and explained in
   `doc/timing-divergences.md`.

## Verification

RD68021 checked itself against Musashi and against TME's Sun-3. Neither covers an
MC68030: TME has no 68030 machine, QEMU does not model its MMU, and Musashi's 68030
MMU is a stub. RD68031 uses four layers instead:

1. **The WinUAE MC68030 core** (`tools/cosim/uae030/`), with its MMU and data cache,
   as the instruction and MMU oracle. It provides the per-opcode vectors, the
   effective-address vectors and the per-instruction traces of real programs. Its
   `cputest` adds vectors from a generator that has been checked against real MC68030s.
2. **A second core, AP68030**, run under Verilator. The bus cycles of the same
   programs are compared, including synchronous and burst cycles and table searches.
3. **rd-virt** (`sim/virt/`), a deterministic machine shaped like Linux's m68k `virt`
   board. The core and the WinUAE core run Linux on it in lockstep: every register
   and every write is compared at every instruction.
4. **A Sun-3/80 in MAME** (`sim/mame/`), the core as a MAME CPU, booting Sun's PROM,
   NetBSD and SunOS 4.1.1 against MAME's own m68030.

## Rules the RTL follows

These are hard rules; breaking one is a bug. `CLAUDE.md` has the full text.

- **Nothing under `Inputs/` is modified.** It holds the manuals and the reference
  implementations, as git submodules.
- **The reference implementations are oracles, never sources.** They are run and
  compared against. No RTL is written from them.
- **No initialisation outside reset.** `make audit` proves it, in the source and in
  the synthesised netlist.
- **Portable SystemVerilog.** The RTL elaborates under iverilog, Verilator,
  yosys, Vivado, Quartus and Questa (`doc/coding-standard.md`).

## Getting started

```sh
git clone --recursive <this repository>
cd RD68031
make check
```

`make help` lists every target.

## Licence

Copyright 2026 Romain Dolbeau.

RD68031 is licensed under the **CERN Open Hardware Licence Version 2 – Strongly
Reciprocal** (SPDX: `CERN-OHL-S-2.0`); the full text is in `LICENSE`. Harness code
that links against a GPL oracle (`tools/cosim/uae030/`, `sim/mame/`) is under the
GPL-2.0-or-later, as its header says; none of it is part of the hardware.

The submodules under `Inputs/` are separate works under their own terms, as are
the Motorola manuals they contain.
