# RD68031 plan: an MC68030, and the cosimulation that replaces TME

## Context

RD68021 (`../RD68021`, read-only for us) is a from-scratch SystemVerilog MC68020 for FPGA and ASIC. It boots a Sun-3 PROM and SunOS 4.1.1 inside TME, and is checked against Musashi, Suska and TME.

RD68031 does the same for the **MC68030**, with the same goals, rules, layout and process. Three things are added:
- an on-chip paged MMU: TC, CRP, SRP, TT0/TT1, MMUSR, a 22-entry ATC, the table walker, and PMOVE/PTEST/PLOAD/PFLUSH;
- a 256-byte data cache, alongside the 256-byte instruction cache reorganised the 030 way (16 lines × 4 longwords);
- the synchronous bus (STERM) with burst fills (CBREQ/CBACK, CIIN/CIOUT).

CALLM/RTM do not exist on the 030.

At the start of M0 the repository was empty: no commits, no submodules.

The oracles RD68021 relied on do not cover a 68030:
- TME has no 68030 machine.
- QEMU does not model the 030 MMU.
- Musashi's "68030" MMU is a 321-line stub, with no PTEST, no TT registers, no ATC, and a `fatalerror` on early termination.

So the cosimulation is new.

**Decisions taken with the user:**
- System cosimulation is a deterministic platform of our own, with a swappable CPU and lockstep comparison, first. MAME follows later as the historical-machine host.
- The real machine is a **Sun-3/80 (sun3x)**, under MAME.
- New oracles:
  - the **WinUAE 68030 core and its cputest**;
  - **AP68030**, a third-party GPL-2 Verilog 68030, `github.com/apolkosnik/AP68030`;
  - **MAME's m68030**.
- Musashi and Suska were not retained.

**Defaults assumed (not asked):**
- The RTL is forked from RD68021 and renamed `rd68021_` → `rd68031_`, rather than rewritten.
- The MC68EC030 variant is out of scope.
- Licence, author line and commit style are as in RD68021.
- The source location is `github.com/MelkhiorVintageComputing/RD68031`.

## 1. Repository and rules (M0)

**Copy from `../RD68021` and adapt; never edit it:**
- `CLAUDE.md`, `README.md`, `LICENSE` (CERN-OHL-S-2.0), `.gitignore`, `Makefile`
- `doc/coding-standard.md`, plus the empty templates for `doc/bugs-found.md`, `divergences.md`, `timing-divergences.md`, `size-and-speed.md` and `manual-contradictions.md`
- `tools/ucode/`, `tools/timing/`, `tools/reset_audit.py`, `tools/src_lint.py`, `tools/cycles.py`, `tools/cache_diff.py`
- `rtl/`, `sim/tb/`, `sim/models/`, `sim/programs/`, `scripts/`

Rename every `rd68021` to `rd68031` and update the SPDX headers' source location.

**The hard rules carry over word for word:**
- `Inputs/` is immutable; copy into `build/` to patch.
- Oracles are never sources for `rtl/`. The list now covers the WinUAE/Hatari core, AP68030, MAME, and the Linux and NetBSD trees.
- No initialisation outside reset; `make audit` checks it.
- Split I/O pins.
- The RTL must elaborate under iverilog, Verilator, yosys, Vivado, Quartus and Questa.

AP68030 needs explicit wording. It is an RTL implementation of the same chip, so nobody writing `rtl/` may open it, not even its docs or test programs. Only `sim/ap030/` harness code may use its *ports*.

**CLAUDE.md documentation map, rewritten for `MC68030UM_split/`:**

| Need | Read |
|---|---|
| Signals | §5 |
| Caches | §6 |
| Bus (106 pp) | §7 |
| Exceptions and SSW | §8 |
| MMU (86 pp) | §9 |
| Coprocessor | §10 |
| Timing | §11 |

- AC limits come from `MC68030EC_split/ac-electrical-specifications.csv` and its figures.
- PRM and `instructions-by-cpu.csv` are used with the 68030 column.
- `MC68020UM_split` is consulted only to understand what was inherited.
- "UM" now means `MC68030UM_split`.

**Submodules under `Inputs/`, pinned:**
- `doc/MC68030_Doc_More_Readable`, same URL as RD68021.
- `ref/winuae`, `github.com/tonioni/WinUAE`: the 68030 core with `cpummu030`, the data-cache emulation, and `cputest/`.
- `ref/hatari`: the same core, Linux-buildable in `src/cpu/`. Kept as the fallback if WinUAE's own sources will not build on Linux.
- `ref/AP68030`.
- `ref/mame`, `github.com/mamedev/mame`, a large tree: the m68030 and the sun3x driver.

Software that cannot be a submodule gets a pinned-hash manifest, `Inputs/sw/MANIFEST`, and is fetched into `build/`:
- the Linux kernel tarball;
- a busybox initramfs;
- NetBSD/virt68k and sun3x sets.

**Must come from the user:**
- the Sun-3/80 PROM image (MAME romset `sun3_80`);
- SunOS 4.1.1 **sun3x** install media. The phabrics tapes in RD68021 are sun3 only.

**M0 spikes.** All five ran at M0 and all five are "go", spike 4 only as far as the PROM monitor (see M14); `doc/oracles.md` has the results. What each was to establish:
1. The WinUAE or Hatari CPU core builds as a standalone Linux library with full 030 MMU and data cache enabled. A trivial program traces correctly.
2. WinUAE `cputestgen` builds on Linux, out of tree, and emits a 68030 corpus.
3. AP68030's `tb/run_tests.sh` passes here. That needs `vasmm68k_mot`, which is not installed.
4. MAME, built with `SOURCES=` limited to sun3x, reaches the Sun-3/80 PROM monitor with its own m68030, and boots NetBSD/sun3x.
5. Linux `CONFIG_VIRT` builds with `CONFIG_M68030` and `CONFIG_M68KFPU_EMU`, and boots to a shell under `qemu-system-m68k -M virt`. This uses QEMU's 040 only to validate the kernel image and device model; QEMU's 030 is never an oracle. Also find out whether NetBSD/virt68k supports the 030.

## 2. The cosimulation stack (the new part)

Four layers. Each catches what the one below cannot.

### Layer 1: instruction and MMU oracle, the UAE030 harness (`tools/cosim/uae030/`)

A small C/C++ program linked against the WinUAE 68030 core, built out of tree into `build/uae030/` (copied, as TME was):
- MMU and data cache are configured as a real 030.
- Memory is flat RAM.
- A hook on every physical bus access records logical and physical address, FC, size, R/W, data, and whether it was a cache hit, a burst, or a table-walk access.
- After every instruction it emits `.trc` lines with D0–D7, A0–A6, USP/ISP/MSP, SR, PC, VBR, SFC/DFC, CACR/CAAR, TC, CRP, SRP, TT0/TT1 and MMUSR. RD68021's positional hex format is extended for these.

It takes over every flow that ran on Musashi:
- `make ea`: retarget `musashi_ea.c`.
- `make vectors` / `vectors-all`: retarget `tools/vectors/gen.c`, and add the 030 groups `pmmu`, `cacr`, `movec030`. CALLM/RTM become illegal-instruction vectors.
- `make cosim`: `core_cosim_tb` now also compares MSP, USP and the MMU registers.

**Status (M6–M7 phase A):** in production. `make ea`, `vectors`/`vectors-all`, `cosim`/
`cosim-long` and `make cache` run against UAE030; the vector stream carries CACR, the
trace USP and MSP as well as ISP. The groups are RD68021's plus `movec030`, `illegal030`
(CALLM/RTM), `cmp2`, `cas`, `bitfield_mem` and `packunpk_mem`; `pmmu` came with M11
part 2; `cache` was not written (`make cache` and `core_cache_tb` cover the data cache). The mismatches found on the RTL are triaged in `doc/m6-mismatches.md`.

`make cosim-mmu` (in production since M11 part 2; `doc/oracles.md`) runs bare-metal kernels with real 030 page tables:
- programs `sim/programs/mmu_*.S`, such as `cow030.S`, TT-mapped I/O, early termination, indirect descriptors, limit faults, U/M updates, PTEST at every level;
- compared on registers **and** on the ordered physical data-access stream, table-walk accesses included.

### Layer 1b: silicon-validated vectors, cputest (`make cputest`)

- `cputestgen`, run for `cpu=68030`, produces a corpus in `build/cputest/`.
- `tools/cputest/convert.py` decodes the cputest data format into our vector stream. That format is the oracle's interface, allowed like TME's element API.
- `sim/tb/core_cputest_tb.sv` runs the converted stream.

This is the closest available thing to real silicon. Instructions, flags and exception frames are covered, MMU is not.

**Status (M6–M7 phase A):** in production. The corpus is generated one instruction at a
time (`tools/cputest/generate.sh`; the generator's `mode=all` stalls on a few
instructions), fits the core harness's 64 KB port, and `make cputest` runs an even sample
of it (`CPUTEST_MAX` per instruction). Results in `doc/m6-mismatches.md`.

### Layer 2: second-core cross-checks

**`make ap030`** (in production since M11 part 2; `doc/oracles.md`). The same bus probe and MMU programs run on AP68030 under Verilator and on our core. `tools/bus_diff.py` (generalised from `suska_diff.py`) compares the pin-level cycle streams:
- data cycles, async versus sync termination, burst requests, CIOUT;
- table-walk reads and the RMC descriptor updates.

The slave model, `sim/models/rd68031_slave.sv`, gains STERM, CBACK and CIIN, with programmable per-region port size, wait states and burstability.

**`make mame030`.** Optional: a third instruction and MMU opinion from MAME's m68030. Extracting it standalone is uncertain because it depends on MAME's `emu` framework, so this is a spike. If it fails, MAME serves only as Layer 4's reference CPU.

Disagreements go to `doc/divergences.md`, and the manual arbitrates.

### Layer 3: the deterministic platform with lockstep, `rd-virt` (`sim/virt/`)

A C++ machine that mirrors the Linux and QEMU m68k `virt` board, so that a stock kernel boots:
- RAM;
- goldfish-pic ×6;
- goldfish-tty;
- goldfish-rtc;
- virt-ctrl;
- virtio-mmio-blk;
- a bootinfo with `MACH_VIRT`, `CPU_68030`, `MMU_68030` and FPU none (`CONFIG_M68KFPU_EMU`). An MC68881 can come later, by reusing RD68021's FPU-protocol idea.

**CPU socket, `cpu_if.h`:** `reset`, `run_until_retire`, `set_ipl`, bus callbacks, `regs()`, `retired()`. Two implementations:
- **rtl**: Verilator `rd68031_top` and a pin-level bus agent. The agent answers AS with DSACK or STERM, bursts on CBREQ, asserts CIIN on MMIO and BERR on holes, and can configure synchronous or asynchronous memory and wait states. The register peeks use `public_flat_rd`, like `sim/tme/public.vlt`. The model is wrapped as in `sim/tme/rd68021_model.cpp`, with the `rdm_*` C API plus `rdm_retired`, `rdm_msp` and `rdm_mmuregs`.
- **uae030**: the Layer 1 core.

**Determinism.**
- Device time is derived from the retired-instruction count, not from host time or clocks. That fixes RD68021's "not lockstep" limitation (doc/sun3.md).
- In lockstep mode the RTL leads. Its interrupt-acknowledge cycle (at instruction K, level L) and any bus error it receives are replayed into the UAE core at the same boundary. Each side keeps its own memory and device instances.
- After every instruction the register files and MMU registers are compared, along with the stream of physical writes (cache-independent, so the same with and without caches).
- On divergence the run stops and dumps both states and the last 4,096 bus cycles.

**Make targets:**
- `make virt-bare`: bare-metal programs on the platform.
- `make virt-linux`: `vmlinux` plus a busybox initramfs, to the shell and a scripted command set. The pass criterion is a lockstep pass plus the expected console.
- `make virt-linux-solo`: RTL only, for speed.
- `make virt-netbsd`: if spike 5 finds that NetBSD/virt68k supports the 030.

### Layer 4: a real machine, the Sun-3/80 in MAME (`sim/mame/`), the TME equivalent

- A `rd68031_device`, a MAME `cpu_device` subclass, wraps the same Verilator model. It is built into a copy of MAME in `build/mame/`, the way `sim/tme/build.sh` patches TME.
- The sun3x driver gets a slot option to choose `m68030` or `rd68031`.
- As in RD68021, console output is compared byte for byte against MAME's own m68030, and `drive.sh` is reused to type commands.

**Targets:**
- `make sun3x`: PROM to the monitor.
- `make netbsd-sun3x`: netboot or disk. **Needs driver work first**: the M0 spike found that MAME's sun3x has no LANCE, no SCSI DMA, no SCSI/SCC interrupts and no level-5 clock, so no OS boots on it as it stands (`doc/oracles.md`). Those go into our copy of the driver in `sim/mame/`.
- `make sunos3x`: SunOS 4.1.1 sun3x, single-user, then multi-user from disk with `SUNOS_IMG=`.

## 3. RTL milestones (mirroring RD68021's M0–M13 history)

| M | Content | Gate |
|---|---|---|
| M0 | Scaffolding: the RD68021 fork renamed, CLAUDE.md, the 030 pin list in `doc/pinout.md`, submodules, the spikes above | `make check` on the fork (still an MC68020) |
| M1 | BIU: the asynchronous S0–S5 path forked from `rd68021_biu.sv`, plus synchronous STERM cycles, burst (CBREQ/CBACK), CIIN/CIOUT, DBEN, STATUS/REFILL | `bus_*_tb`, `bus_sync_tb`, `bus_burst_tb` |
| M2 | Bus exceptions (BERR/HALT retry and rerun, late BERR on synchronous cycles) and arbitration; CPU space and reset re-checked | `bus_error_tb`, `bus_arb_tb`, `bus_cpuspace_tb`, `bus_reset_tb` |
| M3 | AC feasibility against `MC68030EC` specs at 20/25/33.33/40/50 MHz, every grade the data sheet has — it has no 16.67 MHz (`doc/manual-contradictions.md`, 8) (`tools/timing/specs.py` retargeted) | `make timing` |
| M4 | Checkpoint freeze: 030 frames ($0 $1 $2 $9 $A $B), the 030 SSW (FC/FB/RC/RB/DF/RM/RW/SIZE/FC2-0, no CALLM state); `frames.py` updated, with the MMU fault encoding and room reserved for M8–M11; RTE's format errors (version, both ends) and an architectural `$A` restore | `doc/checkpoint.md`, `doc/ssw.md`, `make ucode-check`; `core_fault_tb`, `core_exc_tb`, `core_paging_tb`, `core_cow_tb` and `core_cpif_tb` check every frame word by word |
| M5 | Walking skeleton: seq, ifu and microcode on the new BIU; CALLM/RTM removed (illegal) | it runs |
| M6–M7 | EA engine and integer core against UAE030; then cputest | `make ea vectors-all cputest cosim` |
| M8–M9 | Exceptions, the three stacks, faults and restart with the 030 SSW, `core_paging_tb` | `core_exc/fault_tb` |
| M10 | Caches: the instruction cache reorganised as 16×4 longwords with burst fill; the new data cache (write-through, write-allocate, logical tags with FC); CACR/CAAR, freeze, clear-entry | `core_cache_tb`; `make cache` extended to the data cache (writes identical, reads ≤) |
| M11 | MMU: TC/CRP/SRP/TT0/TT1/MMUSR, the 22-entry ATC, the table walker on the bus with RMC U/M updates, MMU configuration exceptions, MMUDIS, and PMOVE/PTEST/PLOAD/PFLUSH(A), each instruction implemented in microcode | `core_mmu_tb`, `make cosim-mmu`, `make ap030` |
| M12 | Coprocessor interface carried over; MMU opcodes handled internally; CpID ≠ 0 still external | `make cpif` |
| M13 | rd-virt lockstep: bare metal, then Linux | `make virt-linux` |
| M14 | MAME Sun-3/80: the PROM to the monitor first; then, after the driver work above, NetBSD/sun3x and SunOS 4.1.1 | `make sun3x`, then `make netbsd-sun3x sunos3x` |
| M15 | Performance and FPGA (Vivado/Quartus scripts carried over), plus `make cycles` against UM §11 | `doc/implementation.md` |

**Status (M8–M9):** exception processing re-derived from UM section 8. The
RESET pin resets the processor (UM 7.8, 8.1.1) and `rst_n` stays the power-on
initialisation; RTE halts on a bus error while it loads a fault frame (UM
8.1.13); a read-modify-write is completed or rerun whole, never resumed at its
faulted access (UM 8.2.2, 8.2.3); STATUS gives every exception Table 12-4
names its three clocks but the ATC miss. Carried forward to **M11**, which
builds the MMU's registers: UM 8.1.1 step 7 -- the reset "clears the enable bit
in the translation control register and the enable bits in both transparent
translation registers" -- goes in the `crst` arm of `rd68031_seq`'s register
process beside SR, VBR and CACR; PMOVE of an invalid TC, CRP or SRP jumps to
`exc_mmu_config` in `tools/ucode/program.py`, vector 56, already built as the
post-instruction format $2 frame UM 8.1.10 describes; and the ATC miss's three
clocks of STATUS are a `mark = EXC` (or its own event) on the table search's
first microword.

**Status (M11, part 1):** the MMU is built and tested from the manual
(`doc/mmu.md`). TC, CRP, SRP, TT0, TT1 and MMUSR, with the configuration
exception from `exc_mmu_config` and the RESET pin clearing the three E bits in
`rd68031_mmu` (not in `rd68031_seq`'s `crst` arm as the note above planned: the
registers are the MMU's); the 22-entry ATC with a documented NRU replacement;
transparent translation; a hardware table walker on the bus unit -- FC 5, RMC
throughout, U and M written back under RMC, never cached, never CIOUT -- with
FCL, SRE, IS, two to five levels, short and long descriptors, early
termination, indirection and limits; every refusal an ordinary format $B bus
error through `ST_ABT`, the frames of `tools/ucode/frames.py`'s FAULTS table
unchanged; CIOUT and both caches' inhibits; PMOVE (and PMOVEFD), PTEST, PLOAD,
PFLUSH and PFLUSHA replacing the `mmu_op` stub; MMUDIS; and the ATC miss's
three clocks of STATUS, as the walker's start. The +$4C checkpoint reservation
is released. The gate is `core_mmu_tb` with three programs (`mmu_regs`,
`mmu_walk`, `mmu_fault`), and `core_mmu_paging_tb` and `core_mmu_cow_tb`, the
MMU versions of `core_paging_tb` and `core_cow_tb`. Part 2 adds the oracle flows: `make cosim-mmu`, the
PMMU vector groups and AP68030 -- and should look first at the open questions
in `doc/mmu.md` (an RMW cycle missing in the ATC, U at the violating
descriptor).

**Status (M11, part 2):** the oracle side of the MMU. UAE030 carries TC, CRP, SRP, TT0,
TT1 and MMUSR in its trace (32 fields) and reports which access each table search
translates; `make cosim-mmu` runs five MMU programs (part 1's three, `cow_mmu`, and
`mmu_cosim`, written for it) on UAE030 and the core and compares every register at every
boundary and the ordered physical data-access stream, table searches and U/M write-backs
included (`tools/bus_diff.py stream`); `make vectors OP=pmmu` sweeps PMOVE, PTEST, PLOAD
and PFLUSH with the MMU's registers and a small tree in the vector stream (440 vectors);
`make ap030` runs a bus probe and the MMU programs on AP68030 and on the core, each on the
same slave models, and compares their pin-level data transfers (`tools/bus_diff.py pins`).
Everything found is in `doc/m11-mismatches.md`: no class (a) item; the oracles' quirks;
what the manual leaves open; and two behaviours where both oracles agree against the core
(the second page of a misaligned operand is searched after its first part; CAS2 writes
destination 2 first) for a decision -- decided in phase B: the core now does both
the oracles' way, and keeps its own answer to two others (PTEST's N after a bus error;
the extent of a search after an S violation). Layer 2 below is in production as described there,
with the two cores in two benches on identical models rather than in one (they need
different simulators).

**Status (M12):** the coprocessor interface re-derived from MC68030 UM section 10,
compared line by line with the MC68020's section 7 that RD68021 built it from
(`doc/coprocessor.md`, no longer marked inherited). The protocol is the same text;
what the MC68030 adds is around it, and it was already in the bus unit, the MMU
and the data cache: CIR cycles may end with STERM, never ask for a burst, are never
cached, never translated, never matched by a TTx register, and never assert CIOUT
(UM 10.1.4, 9.2.1, 6.1.2). Two defects, both inherited (`doc/bugs-found.md`): a
trace on change of flow held the dialogue open as a trace on instruction execution
must (UM 10.5.2.5), and busy after a breakpoint acknowledge ran the acknowledge
again with no interrupt pending (UM 10.4.3). Four places the manual contradicts
itself are recorded (`doc/manual-contradictions.md` 27-30). `core_cpif_tb` gains
`core_cpif_m030.svh` (`+m030_only`): the operands of every memory-side primitive
through a mapped page with the MMU on, a read and a posted write faulted on a page
the tables refuse and resumed by RTE, TT0 with CI against CIOUT on CIR cycles, the
data cache with bursts on, a synchronous coprocessor, the trace and breakpoint
cases, and the cpSAVE and cpRESTORE format words not reached before; the
scripted coprocessor gains a synchronous mode. 620 checks. CpID 0 stays the MMU's
(since M5); CpIDs 1-7 stay external.

**Status (M13, phase A):** rd-virt is built (`doc/virt.md`): the machine, the RTL and
UAE030 sockets, the lockstep, the guest build, and `make virt-bare`, `virt-uae`,
`virt-linux-solo` and `virt-linux`. Linux 7.2.9 boots to the shell, runs a scripted
command set and powers off on the RTL alone and in lockstep with UAE030 -- 87.7 M
instruction boundaries, no divergence, with the caches and MMU on and once with the
caches off. What the lockstep met and how each is accepted is in
`doc/m13-mismatches.md`: no RTL defect; one item (c7) open for a decision.

**Status (M14, phase A):** the core runs in MAME's Sun-3/80 (`doc/oracles.md`,
"MAME"): `rd68031_device` loads the core, Verilator-built as a shared object with its
pin-level bus agent, and our copy of the sun3x driver (`sim/mame/sun3x.patch`) gains
`sun3_80rd` (the core) and `sun3_80ref` (MAME's m68030 without its FPU). `make sun3x`
runs boot PROM rev 3.0.3 through its self-test to the monitor and a scripted command set
on both: the consoles are identical byte for byte; revs 3.0.2, 3.0 and 2.9.2 are too. The
core takes about ten minutes (0.03 emulated s per wall s). One difference, MAME's
m68030's PTEST returning the translated address instead of the last descriptor's
(`doc/m14-mismatches.md` b1, b2), is kept out of the scripted set. No RTL defect. The
driver work before an OS boots -- LANCE and IOMMU, ESP DMA, the device interrupts and the
level-5 clock, bus errors on unmapped addresses, a fixed RTC -- is estimated at five to
eight working days in `doc/oracles.md`. The user chose to move to M15 before that
work (phase B), so three things stay open for then: patching PTEST in the build copy
of MAME's m68030, replacing the dependency on RD68021's `tme-sun-eeprom` with an NVRAM
generator of our own, and the driver work itself.

**Status (M15, phase A):** measured, nothing optimised. All six front-ends accept the
design; the M10 caches and M11 MMU met a vendor tool for the first time and Quartus
found one latch, the ATC reset loop's module-scope index, fixed. Artix-7 14,835 LUTs,
5,185 FFs, 6 RAMB36, 4 DSP, 20.87 MHz; Cyclone V 13,808 ALMs, 21.51 MHz; MAX 10 34,286
LEs, 16.97 MHz -- against RD68021's 8,216 LUTs and 33.68 MHz. The limit on all three is
one half-period family: a multi-cycle operand's residual address through the ATC into
the bus unit's decision (`doc/critical-path.md`). `make cycles` is against UM section
11 now, on a two-clock synchronous bench as well as the three-clock one, with the data
cache and MMU instructions added (`doc/timing-divergences.md`). Phase B's candidates,
each with an estimate, are in `doc/implementation.md`, "What to do about it".

**Status (M15, phase B):** the user's choice from that list built -- F1, F2, F4 for the
frequency, S1, S2, S6 for the size; S3 declined for now, S4, S5, F5 not approved; the
Quartus clock arrangement kept for comparability. Artix-7 14,327 LUTs, 29.61 MHz;
Cyclone V 12,884 ALMs, 3 DSP, 31.82 MHz; MAX 10 30,361 LEs, 25.71 MHz. The price is one clock on a
misaligned operand across a page boundary with translation enabled
(`doc/timing-divergences.md`). The limit is now the back-to-back operand handshake into
the data cache's writes (`doc/critical-path.md`); each step is a row of
`doc/size-and-speed.md`. `make cycles` lost the four rows the bench made slow.

**Known suspects when real software misbehaves (M13, M14):** the deliberate
differences from the part that follow the manual instead -- `LINK A7` pushes the
decremented stack pointer where the part pushes the value before it, and the
decimal instructions on non-BCD bytes (`doc/divergences.md`). Check these first.

Each milestone's commit follows RD68021's style: an `Mn:` prefix, a prose subject, a body explaining the reasoning and the coverage, and the attribution line. Every defect found goes into `doc/bugs-found.md`, and every disagreement with an oracle into `doc/divergences.md`.

## 4. Verification

- `make check` is the gate, unchanged in shape: `ucode-check`, `lint` (iverilog, Verilator, yosys), `audit`, `sim` (now including the sync, burst, cache and MMU testbenches), and `timing` against the MC68030EC specs.
- The oracle targets, minutes each, are not in `check`:
  - `ea`, `vectors-all`, `cputest`, `cosim`, `cosim-mmu`, `cache`;
  - `ap030`, `mame030`, `cycles`;
  - `virt-bare`, `virt-linux`, `sun3x`, `netbsd-sun3x`, `sunos3x`.
- Before M1, every M0 spike passes or has a documented fallback in `doc/oracles.md`.
- Lockstep acceptance: a full Linux boot to shell under `make virt-linux`, with zero register or write-stream divergences, run with caches and MMU on and once with caches off.

## Critical paths to read and reuse (all in `../RD68021`, copied, never modified)

- `CLAUDE.md`, `Makefile` (about 820 lines; the TME targets near lines 507–700 become the templates for virt and MAME), `doc/coding-standard.md`
- `rtl/rd68021_{biu,seq,ifu,icache,top,pkg}.sv`; `tools/ucode/{isa,program,frames,assemble}.py`
- `sim/tme/rd68021_model.cpp/.h`, `rd68021.c`, `build.sh`, `drive.sh`, `public.vlt`: the pattern for embedding Verilator in a host emulator
- `tools/vectors/gen.c`, `tools/cosim/musashi_*.c`: retargeted to UAE030
- `tools/suska_diff.py`, `tools/cache_diff.py`: generalised into `bus_diff.py` and the data-cache-aware `cache_diff.py`
- `sim/tb/core_{cosim,vec,ea,paging,cow}_tb.sv`
