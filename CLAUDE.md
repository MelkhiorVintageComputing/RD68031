# RD68031 — SystemVerilog MC68030

A from-scratch SystemVerilog implementation of the Motorola MC68030, targeting FPGA
(short-term priority) and ASIC. It is the successor of RD68021 (an MC68020,
`../RD68021`), whose RTL, tools and process it was forked from at M0 — so until the
milestones below replace them, the RTL in `rtl/` is still an MC68020 and many
documents in `doc/` still describe that design. Each such document says so at its top.

## Goals

1. **100 % software compatibility** with a real MC68030.
2. **Bus-timing compatibility** — the bus-state (S0–S5) behaviour of the original:
   asynchronous cycles with dynamic bus sizing and misaligned operands, synchronous
   cycles (`STERM`), and burst fills (`CBREQ`/`CBACK`).
3. Instruction *cycle* timings need not match, but **every divergence must be measured,
   reported and justified** in `doc/timing-divergences.md`.

## Hard rules

These are not style preferences. Breaking one is a bug.

### `Inputs/` is immutable

Nothing under `Inputs/` may be modified, ever. New inputs may be *added* (as submodules or
new directories), but once added they are frozen too. Anything that builds into its own
tree (WinUAE, Hatari, MAME, AP68030's test scripts) is copied into `build/` first and
built there.

### A reference implementation is never a source for RTL

Everything under `Inputs/ref/` exists **only** to be run and compared against:

- `winuae/` and `hatari/` — the WinUAE MC68030 core (MMU, caches) and its `cputest`;
- `AP68030/` — a third-party Verilog MC68030;
- `mame/` — MAME's m68030 and its Sun-3/80 (`sun3x`) machine;
- `PROMs/` — Sun-3/80 boot PROM images, for that machine. Sun firmware: supplied by the
  user, git-ignored, and checked against `Inputs/sw/PROMS.sha256`.

You may **not** read them to work out how to write our RTL. Anyone (human or agent)
writing code in `rtl/` must not open a file in those directories. **AP68030 is an
implementation of this very chip**: that ban covers its documentation, its testbenches
and its test programs too, not just its RTL. Harness code in `tools/cosim/`, `sim/ap030/`,
`sim/virt/` and `sim/mame/` is written against the oracles' *interfaces* (a CPU core's
API, a module's ports, an emulator's device interface), which is what running them needs.
Nothing in `rtl/` comes from them.

The golden reference is the documentation in `Inputs/doc/`. When an oracle disagrees with
this core, the manual is the arbiter and the disagreement is an investigation, not a bug
report against the RTL. `doc/oracles.md` records what each oracle is trusted for.

### No initialisation outside reset

ASIC is a target, so there is no power-on register state. No `initial` blocks in `rtl/`,
no declaration-site initialisers on anything that infers a register, no relying on `'x`
resolving to a useful value. Every register gets its value from the reset branch of its
`always_ff`. `make audit` proves it, in the source *and* in the yosys netlist.

### Split I/O pins

The original's bidirectional and three-state pins become separate `_i` / `_o` / `_oe`
signals, `_oe` active high meaning the core is driving. An external wrapper converts to
real three-state pins where a design needs them. See `doc/pinout.md`.

### Portable SystemVerilog only

The RTL must elaborate under **iverilog, Verilator, yosys, Vivado, Quartus and Questa**.
See `doc/coding-standard.md` for the permitted subset — yosys is the strictest and
therefore defines it. `make lint` is the gate for the three that need no vendor
installation; `make synth`, `make lint-quartus` and `make lint-questa` are the other
three, and they are not in `make check` for that reason.

### Mind the host's memory

The build machine has 15 GB and no swap, and has crashed out of memory. Heavy jobs —
MAME, the Linux kernel, Verilator builds, the UAE030 core build — are run one at a time,
never alongside each other or alongside anything else, with bounded parallelism (`-j4` at
most; `-j2` for MAME). Simulations that take little memory (the iverilog testbenches,
the oracle runs) may run up to **4 at a time** in parallel, using at most 4 cores.

## Scope

| | |
|---|---|
| In | the full MC68030 integer ISA, all 18 addressing modes, the instruction and data caches, the paged MMU (TC, CRP, SRP, TT0/TT1, MMUSR, the ATC, PMOVE/PTEST/PLOAD/PFLUSH), the coprocessor interface, asynchronous, synchronous and burst bus cycles |
| Out | the MC68EC030 variant; CALLM/RTM, which the MC68030 does not have |

## Layout

| Path | What |
|---|---|
| `rtl/` | the processor, one module per file, prefix `rd68031_` |
| `rtl/gen/` | generated from `tools/ucode/` — microcode store, decoders, frame package |
| `tools/` | microcode assembler, test runners, timing solver, doc generators (Python) |
| `tools/cosim/uae030/` | the harness around the WinUAE MC68030 core: traces, vectors |
| `sim/tb/` | testbenches |
| `sim/models/` | bus-slave models, and the scripted coprocessor `make cpif` talks to |
| `sim/programs/` | real code, built by the cross-compiler and run on the core |
| `sim/ap030/` | harnesses that run the same code on AP68030 (from M1) |
| `sim/virt/` | rd-virt, the deterministic lockstep platform (from M13) |
| `sim/mame/` | the core as a MAME CPU device in the Sun-3/80 (from M14) |
| `scripts/` | Vivado and Quartus synthesis, implementation and timing scripts |
| `doc/` | pinout, coding standard, oracles, checkpoint, coprocessor, compliance, divergence and implementation reports |
| `Inputs/doc/` | Motorola manuals, split by section, with machine-readable AC specs |
| `Inputs/ref/` | reference implementations used as oracles (not as RTL sources) |
| `Inputs/ip/` | RD68884, the MC68881 the MAME harness puts beside the core (M14) |

## Documentation map

Everything authoritative lives in `Inputs/doc/MC68030_Doc_More_Readable/`. **Ignore
`MC68000UM_split`** — a different processor. `MC68020UM_split` is read only to understand
what the forked RTL was built against. `MC68881UM_split/` is the coprocessor's side of
our §10 and is the cross-check for it.

| Need | Read (`MC68030UM_split/` unless named) |
|---|---|
| Pin behaviour | `07-section-05-signal-description.pdf` |
| Processing states, SR, the three stack pointers | `06-section-04-processing-states.pdf` |
| Instruction and data caches, CACR/CAAR | `08-section-06-on-chip-cache-memories.pdf` |
| Bus protocol, sync and burst (106 pp) | `09-section-07-bus-operation.pdf` |
| Exceptions, SSW, stack frames | `10-section-08-exception-processing.pdf` |
| MMU (86 pp) | `11-section-09-memory-management-unit.pdf` |
| Coprocessor interface | `12-section-10-coprocessor-interface.pdf` |
| MC68030 cycle counts | `13-section-11-instruction-execution-timing.pdf` |
| Bus timing figures and AC limits | `MC68030EC_split/` figures + `ac-electrical-specifications.csv` |
| Addressing modes and extension words | `M68000PRM_split/05-section-02-addressing-capabilities.pdf` |
| Instruction semantics | `M68000PRM_split/07-section-04-integer-instructions.pdf`, `09-section-06-supervisor-instructions.pdf` |
| Opcode encodings | `M68000PRM_split/11-section-08-instruction-format-summary.pdf` |
| Which instructions exist | `M68000PRM_split/instructions-by-cpu.csv`, the MC68030 column |
| Condition codes | `M68000PRM_split/CONDITION-CODES.md` |
| Vectors and frame formats | `M68000PRM_split/13-appendix-b-exception-processing-reference.pdf` |

`MC68030EC_split/README.md` explains how the AC table was transcribed (e.g. the two
value rows of #45/#45A), and `doc/manual-contradictions.md` records the places found here
where the manuals contradict themselves — read both before "correcting" a spec that looks
wrong.

The PDFs have reconstructed outlines and are best read with
`pdftotext -layout <file> -` for a specific section.

In a comment, `UM` is `MC68030UM_split` and `PRM` is `M68000PRM_split`; specification
numbers refer to `MC68030EC_split/ac-electrical-specifications.csv`. Comments inherited
from RD68021 that cite the MC68020 manual say `UM20`.

## Building and checking

```sh
make lint     # elaborate every rtl module under the three always-available tools
make audit    # prove no register initialises outside reset
make ucode    # regenerate the microcode ROMs from tools/ucode/
make sim      # directed testbenches (iverilog)
make cpif     # the coprocessor interface against a scripted coprocessor (part of sim)
make sim COPROCESSOR=1   # every core testbench with the coprocessor interface built
make check    # the gate: ucode-check, lint, audit, sim, AC timing
```

The oracles, none of which is in `check` because each takes minutes; `doc/oracles.md`
has the state of each, and `doc/m6-mismatches.md`, `doc/m11-mismatches.md`,
`doc/m13-mismatches.md` and `doc/m14-mismatches.md` what they found. rd-virt, the
lockstep machine, is in `doc/virt.md`.

```sh
make uae030           # build the UAE030 oracle and its front-ends (heavy: run it alone)
make ea               # every addressing mode and extension-word shape, against UAE030
make vectors OP=alu   # one instruction group, against UAE030 (OP=pmmu: the MMU instructions)
make vectors-all      # every group there is
make cosim            # real programs, every register at every instruction
make cosim-long       # ... the whole of each program
make cputest          # WinUAE's cputest corpus (CPUTEST_SEL=ADD,MOVE.L CPUTEST_MAX=N)
make cosim-mmu        # MMU programs: every register, and the physical data-access stream
                      # with every table search and U/M write-back (COSIMMMU=...)
make ap030            # AP68030 against the core, pin against pin, on identical slave
                      # models (AP030PROGS=...; its Verilator build is heavy: alone)
make cache            # the same results with no instruction cache (ICACHE_ENTRIES=0 and 64)
make virt-uae         # rd-virt: Linux to the shell and a command set on UAE030 alone
make virt-bare        # rd-virt: bare-metal programs (console, timer, MMU+caches), in lockstep
make virt-linux-solo  # rd-virt: Linux on the RTL alone (Verilator build heavy: alone)
make virt-linux       # rd-virt: Linux in lockstep, RTL against UAE030 (VIRT_CACHES=off)
make sun3x            # MAME's Sun-3/80: the boot PROM to the monitor and a command set on
                      # the core, console byte for byte against MAME's m68030 (SUN3X_BIOS=;
                      # MAME's build -j2 and the core's Verilator build are heavy: alone)
make sun3x-m68030     # ... MAME's m68030 alone
make netbsd-disk      # NetBSD/sun3x 10.2 installed on a disk image, on MAME's m68030
make netbsd-sun3x-m68030  # ... booted to multi-user there, root logged in, commands typed
make netbsd-sun3x     # ... and on the core with RD68884 as its FPU, each command's
                      # answer compared with the m68030's (hours: NETBSD_TIMEOUT)
make sunos-disk       # SunOS 4.1.1 installed from sun3arc's tape 1, on MAME's m68030
make sunos-sun3x-m68030   # ... booted to multi-user there, root logged in, commands typed
make sunos-sun3x      # ... and on the core, answers compared (hours: SUNOS_TIMEOUT)
make timing-verbose   # the AC solver, with the binding constraint named
make cycles           # instruction clock counts, each a regression check
```

Implementation, each a vendor run of tens of minutes:

```sh
make impl             # Vivado place and route, xc7a100t, out of context
make paths            # what limits the clock, and proof the unreachable routes are gone
make quartus          # the Cyclone V fit, for a second toolchain's number
make quartus AFAMILY='"MAX 10"' APART=10M50DAF484C6GES   # ... or a MAX 10
```

`make help` lists every target, grouped as above.

## Tooling notes

- iverilog 12.0, Verilator 5.032, yosys 0.52, ghdl 5.0.1, Vivado 2025.2 in
  `/opt/Xilinx`, and Quartus Prime Lite in `/opt/Altera` with Questa Altera Starter
  Edition. Questa's `vlog`/`vopt` need no licence; `vsim` does, and this machine has
  none, so nothing simulates under Questa.
- `m68k-linux-gnu-gcc` / `-as` / `-objcopy` build test programs. Its default `-mcpu` is
  **68020** and its `libgcc` is built for it, so test programs may link `libgcc`; pass
  `-mcpu=68030` to assemble the MMU instructions.
- No gtkwave — dump VCD and inspect with a text tool or an external viewer.
