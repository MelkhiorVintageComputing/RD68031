# Implementation

What the design comes to on real FPGA fabric, measured, and how. The targets:

```sh
make impl      # Vivado 2025.2 place and route, xc7a100tcsg324-1, out of context
make paths     # what limits the clock, from the checkpoint make impl leaves,
               # and how deep the logic behind each pin is
make quartus   # Quartus Prime Lite fit and timing, Cyclone V 5CSEMA5F31C6
               # (AFAMILY='"MAX 10"' APART=10M50DAF484C6GES for a MAX 10)
make audit     # every register's reset, and the named exceptions
```

All three take `ICACHE_ENTRIES`, `DCACHE_ENTRIES` and `COPROCESSOR` from the
command line (`DCACHE_ENTRIES` since M15; before it the vendor scripts built the
data cache at its default whatever was asked), and all run with at most four
threads (`set_param general.maxThreads 4`, `NUM_PARALLEL_PROCESSORS 4`): the
host has 15 GB and no swap. A Vivado place and route of this design takes about
seven minutes, a Cyclone V fit seven, a MAX 10 fit nine.

*The entries for the MC68020 design this one was forked from are in RD68021's
`doc/implementation.md`. Its numbers are quoted below where they compare: they
are from its final tree, with `COPROCESSOR = 1`, at the same 33.333 ns.*

---

## The numbers (M15, phase A)

Constrained at **33.333 ns, 30 MHz** (`scripts/rd68031.xdc`,
`scripts/rd68031.sdc`), both caches at 64 entries, the MMU built (it has no
parameter):

| | Artix-7 xc7a100t-1 (Vivado) | Cyclone V 5CSEMA5 (Quartus) | MAX 10 10M50DAF484C6GES (Quartus) |
|---|--:|--:|--:|
| logic | **14,835 Slice LUTs (23.4 %)** | **13,808 ALMs (43 %)** | **34,286 LEs (69 %)** |
| registers | 5,185 | 9,827 | 9,298 |
| block memory | 6 RAMB36 (the microcode store) | 22 M10K, 225,280 bits (the store) | 28 M9K, 225,280 bits (the store) |
| distributed RAM | 140 LUTs (both caches' data) | -- | -- |
| DSP | 4 (the multiplier) | 12 (3 the multiplier, 9 the caches' indexing -- below) | 8 9-bit multipliers |
| **frequency, static** | **20.87 MHz** (47.91 ns) | **21.51 MHz** | **16.97 MHz** (slow 1200 mV 85 °C) |

The same tree with `COPROCESSOR = 1`, Artix-7: 14,738 LUTs, 5,188 FFs,
**21.12 MHz** -- the two settings are within place-and-route's noise, as they
were on RD68021. With both caches built out (`ICACHE_ENTRIES=0
DCACHE_ENTRIES=0`), Artix-7: 11,740 LUTs, 3,907 FFs, no distributed RAM,
**22.84 MHz**.

**None of the three meets 30 MHz; all clear the MC68030's 16.67 MHz grade on
static timing, and the Artix-7 and Cyclone V its 20 MHz grade.** RD68021 made
33.68 MHz (Artix-7), 38.57 (Cyclone V) and 32.51 (MAX 10) from the same scripts;
this design is 38 %, 44 % and 48 % slower, and the reason is one path family,
in "What limits the clock" below -- not the sequencer, which has not moved.

Against RD68021 (MC68020, `COPROCESSOR = 1`):

| | RD68021 | RD68031 | |
|---|--:|--:|--:|
| Artix-7 Slice LUTs | 8,216 | 14,738 | +79 % |
| Artix-7 FFs | 1,880 | 5,188 | ×2.8 |
| Artix-7 MHz | 33.68 | 21.12 | −37 % |
| Cyclone V ALMs | 8,085 | 13,808 ¹ | +71 % |
| Cyclone V registers | 5,876 | 9,827 ¹ | +67 % |
| Cyclone V MHz | 38.57 | 21.51 ¹ | −44 % |
| MAX 10 LEs | 18,974 | 34,286 ¹ | +81 % |
| MAX 10 MHz | 32.51 | 16.97 ¹ | −48 % |

¹ `COPROCESSOR = 0`; on the Artix-7 the setting moves nothing measurable.
RD68021's MAX 10 figures are from before its posted writes and coprocessor
dialogue work, by its own footnote; its other two columns are its final
tree's.

## Where the area goes (Artix-7, Slice LUTs)

`impl_utilization_hier.rpt`, `COPROCESSOR = 0`, and RD68021's corresponding
rows:

| | LUTs | FFs | LUTRAM | block RAM | DSP | RD68021 LUTs |
|---|--:|--:|--:|--:|--:|--:|
| sequencer, datapath, register file, coprocessor interface | 4,667 | 1,093 | | | 4 | 4,399 |
| — shifter | 903 | | | | | 910 |
| — bit-field unit | 760 | | | | | 731 |
| — opcode decoder | 553 | | | | | 314 |
| — divider | 431 | 139 | | | | 431 |
| — coprocessor primitive decoder | 102 | | | | | (in the sequencer) |
| — microcode store | 66 | 1 | | 6 RAMB36 | | (in the sequencer) |
| bus unit | 1,355 | 781 | | | | 600 |
| fetch unit | 457 | 219 | | | | 612 with the cache |
| instruction cache | 493 | 464 | 44 | | | |
| data cache | 2,276 | 650 | 96 | | | -- |
| MMU: registers, ATC storage, table walker | 1,392 | 1,818 | | | | -- |
| — translation for the bus unit's access (`u_xl1`) | 865 | | | | | -- |
| — translation for the walker, PTEST, PLOAD, PFLUSH (`u_xl3`) | 498 | | | | | -- |
| **total** | **14,835** | **5,185** | **140** | **6 RAMB36** | **4** | **8,216** |

Of the 6,600 LUTs the MC68030 added, the **MMU is 2,755** (42 %) and its 1,818
flip-flops are a third of the design's: the 22-entry ATC is held in registers,
27 tag and 28 data bits an entry (`doc/mmu.md`), and looked up by two
fully-associative comparators of 22 ways each. The **data cache is 2,276** --
its data is 96 LUTs of distributed RAM, the rest is the four-bank lookup for an
operand that may straddle two entries, the fill and the write merge. The
**bus unit doubled** (+755): synchronous and burst cycles, the cache fills and
completions, and the ATC's verdict on each cycle. The instruction cache's line
organisation cost about 340 LUTs over RD68021's long-word cache.

## The Intel parts: the caches are built from registers

The Cyclone V's per-entity figures tell a different story from the Artix-7's:

| Cyclone V | ALMs needed | registers | DSP |
|---|--:|--:|--:|
| sequencer and its units | 5,738 | 1,412 | 3 |
| data cache | **3,442** | **2,697** | **7** |
| fetch unit and instruction cache | 1,687 (1,408 the cache) | 2,791 (2,541 the cache) | **2** |
| MMU | 1,927 (800 the two lookups) | 2,111 | |
| bus unit | 940 | 816 | |

Both caches' RAMs are written on a clock edge and read without one
(the M10 section below, `doc/caches.md`). Xilinx distributed RAM does
that; an M10K does not, and Quartus builds the 2,048 bits of each cache's data
from registers -- RD68021 met the same with its instruction cache, and it is
most of the 4,000 extra registers here. And the nine extra DSP blocks are the
caches' *indexed part-selects*: `tags[line*TW +: TW]` (`TW` = 27 in the data
cache, 25 in the instruction cache) and `valid_q[line*4 +: 4]` are a variable
index multiplied by a constant, and Quartus builds the products in 9×9
multipliers (`Mult0`..`Mult6` in `rd68031_dcache`, `Mult0`, `Mult1` in
`rd68031_icache`) ahead of a wide shifter, where Vivado makes a multiplexer of
the same source. Neither is a defect; both are opportunities (below).

## What limits the clock

`make paths` names one family, on all three parts: **a half-period path from the
bus unit's falling-edge state, through the residual address of a multi-cycle
operand, the ATC, and the bus unit's decision to start a cycle, into the
registers that decision enables** -- the ATC's history bits, the data cache's
RAM and valid bits, and the bus unit's own operand registers. Artix-7, worst
path, launched on the falling edge and captured on the rising one (16.67 ns):

| from | to | arrives (ns after launch) | what |
|---|---|--:|---|
| `u_biu/beat_q` | `bnow_addr`, `bt_n` | 3.1 | the transfer's byte count from the port size |
| | `nx_addr` (`op_addr + xfer_done`) | 6.9 | a 32-bit add: the residual operand address |
| | `ent_done`, `cyc_fill`, `next_addr` | 12.0 | whether a cache-entry completion goes first, and so the next cycle's address |
| `u_mmu/u_xl1` | `hitv`, `kind` | 17.6 | the 22-way ATC compare and the verdict |
| `u_biu` | `op_active` (fan-out 128) | 21.2 | the bus unit's decision |
| `u_mmu` | `l_take`, `h_after` → `h_q` | 24.9 | the ATC's history update |

24.9 ns of logic and routing against 16.67 ns, 38 levels, 70 % routing: 47.91 ns
as a period. The data cache's RAM write enables are 1.1 ns behind (46.82 ns),
its valid bits 1.6 ns (46.28), the operand address register 2.4 ns (45.55, the
same path through `op_active` and back through the adder). Quartus's worst path
on the Cyclone V is the same shape -- `beat_q`, the address adder, `ent_done`,
`l1_addr`, the ATC's `hitv`, the next bus state, a data cache write enable --
and so is the MAX 10's. Building the caches out removes the cache endpoints and
leaves the ATC's: 22.84 MHz, the same family. **Every path in the 400 worst
starts at `beat_q`.**

Below that family, from `make paths`'s 3,000:

| period | MHz | levels | family |
|--:|--:|--:|---|
| 36.28 | 27.56 | 1 | `u_biu/crst_q` → `d_latched` (half): the RESET pin's synchronous clear, one LUT and a fan-out across the bus unit; 96 % routing |
| 35.46 | 28.20 | 21 | `u_biu/early_q` → the fetch unit's request registers (half): the early retire's half clock, RD68021's Phase 4 limiter |
| 28.92 | 34.58 | 15 | `u_biu/early_q` → the microcode store's address (half) |
| 28.51 | 35.08 | 28 | `u_seq/u_urom/rom_q` → `u_ifu/fill_q` (full) |
| 27.83 | 35.94 | 27 | `u_seq/xw_q` → the data registers (full) |

The sequencer's own paths are where RD68021 left them, 35-36 MHz.

`make paths` checks, as it did on RD68021, that the routes no microword can take
-- the shifter and the bit-field unit into the micro-address, the bit-field
unit into the shifter -- have no path. M15 found the first one present, at 9.6 ns
of slack, and it was not one: the check's endpoints included `irq_taking_q`,
whose D input since RTE's put-back (`doc/checkpoint.md` rule 9) is fed from the
result bus, where the shifter's result legitimately arrives. The endpoint is
dropped (its enable is decoded from `upc_nxt`, whose every path the micro-PC
and the store's address already catch); `scripts/paths.tcl` says why.

## The pins

The constraint files time nothing between a pin and a register: the core is run
out of context and its pins meet whatever logic surrounds it. That was
RD68021's practice and remains this one's, but since M15 `make paths` also
reports, per pin, the logic behind it -- as if the surrounding design launched
every input from a register on the rising edge and captured every output on the
next one (zero input and output delay, set only in the reporting session; the
implementation and the figure above are untouched). `build/paths_pins.rpt`:

- **Every output** comes from a flip-flop: `a_o`, `fc_o`, `siz_o` directly;
  the strobes and the MC68030's new outputs -- `cbreq_n_o`, `ciout_n_o`,
  `refill_n_o`, `status_n_o` -- through one LUT; the `_oe` enables through two
  (`crst` and the arbitration); `d_o` through four, the write data's byte-lane
  multiplexer from `op_rem`. The worst is 11.5 ns of a 33.33 ns budget.
- **The synchronous inputs** -- `sterm_n_i`, `cback_n_i`, `ciin_n_i` -- each
  reach a register through at most two LUTs; `d_i` goes straight into
  `d_latched`. The pins the core synchronises (`ipl_n_i`, `br_n_i`, `bgack_n_i`,
  `reset_n_i`, `halt_n_i`, `cdis_n_i`, `mmudis_n_i`) meet `rd68031_sync`'s first
  rank directly.
- **`berr_n_i`** reaches `term_rty` through 8 levels in a half period (15.6 ns
  of the 16.67), **`avec_n_i`** `term_hlt` through 5: both are sampled at the
  falling edge with the cycle's state decided in front of the flop, as
  specification 27's setup to that edge allows.
- **`dsack_n_i`**'s worst path, 34 levels into the ATC's history, is false:
  `dsack_port` passes the pins only in the half clock before S5, and no
  rising-edge register samples during it (`rd68031_biu`, the comment at
  `dsack_port`). Static timing cannot know the state; a `set_false_path`
  would need the state as a condition, so it is recorded here instead.

So the MC68030's new pins need no constraint the scripts lack: the out-of-context
convention holds, and the pin report is where to look if a board design meets
one.

## What to do about it (M15 phase B: estimates, nothing done yet)

Each estimate is from the measured path and area above; none is built. "Risk"
is the risk to behaviour, and the gate is what would have to stay green.

**Frequency.** The order matters: each family hides the next, so a fix is
worth only what is left above the family after it.

| # | change | gain (Artix-7) | risk |
|---|---|---|---|
| F1 | **Take the ATC out of the operand continuation.** A continuing operand already runs on its registered page translation (`op_pb1`, `op_pmask`); the ATC is consulted only when `next_addr` leaves that page (`in_p2`, `cont_new`). But `next_addr` and `in_p2` are combinational from `beat_q` through the residual-address adder, so the ATC, `kind` and the decision sit behind them structurally on every continuation. Give a page-crossing continuation one idle clock -- register `next_addr` and translate it from the register -- and the ATC's input comes only from registered requests | takes the ATC and its verdict, ≈ 5.5 ns, out of the 24 ns this family needs in its half period: 47.9 → ≈ 37 ns, **≈ 27 MHz** (+30 %), level with F4's family | medium: one clock on an operand that crosses a page mid-way (rare: misaligned across a page boundary) -- a timing divergence to measure, and the bus-level comparisons. Gates: `core_mmu_tb`, `cosim-mmu`, `ap030`, `virt-linux` |
| F2 | The residual address `op_addr + xfer_done` precomputed for the four possible counts at the edge before (carry-select from registers) | ≈ 3.8 ns off the front of the same path: alone 47.9 → ≈ 40 ns (25 MHz); after F1, ≈ 29 ns, under the next families | low: same function. Gates: `make check`, `cosim` |
| F3 | The ATC's history (`h_q`) and the data cache's write enables taken from a registered verdict a clock later | ≈ 3.7 ns off the tail; worth something only with F1 | low-medium: the NRU choice sees a hit a clock late; a data cache write a clock later needs a forward for the read that follows it |
| F4 | `crst_q`'s fan-out: one copy per register bank, or the synchronous clear registered once more | 36.3 → < 30 ns for that family | low |
| F5 | The early retire's half clock (RD68021's Phase 4) given a whole one | 35.5 → the sequencer's 28.5 ns: **≈ 35 MHz**, RD68021's level, after F1 and F4 | medium: it is a clock of posted writes and of the early retire wherever it applies -- `make cycles` measures what it costs |

F1 + F2 + F4 is the step that matters, ≈ 21 → 28 MHz, where the early
retire's half clock is next; with F5, ≈ 35 MHz, the sequencer's own limit,
which `doc/critical-path.md` says has not moved since RD68021. Each figure
doubles the nanoseconds a fix takes out of a half-period path, and none is a
substitute for the place and route that would measure it
(`doc/coding-standard.md`, "Two cautions"). The Intel parts follow the same
chain and should move with it.

**Size.**

| # | change | gain | risk |
|---|---|---|---|
| S1 | **One ATC comparator, not two**: `u_xl3` serves the walker, PTEST, PLOAD and the flushes, which run while the bus unit's access waits on them; time-share `u_xl1` | Artix-7 ≈ 450 LUTs (`u_xl3` is 498), Cyclone V ≈ 200 ALMs | low-medium: the walker's and the access's lookups must never want it on the same clock. Gates: `core_mmu_tb`, `cosim-mmu` |
| S2 | **The caches' tag and valid selects as unpacked arrays** (`tags[line]`), not `tags[line*TW +: TW]` | Cyclone V −9 DSP blocks and the 9×9 multipliers out of the tag compare; a few hundred ALMs at a guess; Vivado no change | very low: the same function; the six front-ends must accept an unpacked net array assigned from a generate, which is to be checked first |
| S3 | **The caches' data in Intel block memory**: a read registered on the falling edge (the bus unit's state already is), or an MLAB | Cyclone V ≈ 4,000 registers and ≈ 2,500 ALMs; MAX 10 ≈ 5,000 LEs | high: a hit's data would arrive half a clock later, on paths that are half-period already; and for Xilinx nothing is gained. A decision, not a fix |
| S4 | The data cache's two-entry lookup -- an operand straddling two long words read from both in one go -- made a lookup and a second step | Artix-7 perhaps 600-900 of its 2,180 logic LUTs; a guess until tried | medium: a clock on a straddling hit, which is a misaligned operand |
| S5 | The ATC's data half (22 × 28 bits) in distributed RAM indexed by the encoded hit, the tags staying registers | ≈ 600 flip-flops and the 22-way data multiplexer | medium: an encoder in a path that is already the critical one -- after F1 only |
| S6 | The divider's `mag_num`, `mag_den`, written and never read | 64 flip-flops in the source, none in any netlist | none: a cleanup |

None of these changes the instruction set or the bus protocol; F1, F3, F5 and
S3 change clock counts, and would each be a row in `doc/timing-divergences.md`.

## The reset audit

`make audit` at M15: 6,592 flip-flops, every one reset, 110 exempted -- the
microcode store's read register, one per microword bit, as on RD68021. The
caches' arrays are memories, not registers, gated by reset valid bits
(`doc/caches.md`).

## Six tools, one subset

All six front-ends accept the design at M15: `make lint` (iverilog, Verilator,
yosys), `make synth` (Vivado), `make lint-quartus` and `make lint-questa`; and
`make impl` and `make quartus` place and route it. The M10 caches' generate
loops and the M11 MMU went through a vendor tool for the first time here.
Quartus found one thing to say about them, a latch inferred for the ATC's
reset-loop index, which was a module-scope variable; it is the loop's own now
(`doc/coding-standard.md`). Vivado's synthesis summary had counted 0 DSP and 0
block RAM for a netlist with 4 and 6 since the scripts were carried over --
two `PRIMITIVE_GROUP` names that do not exist in 2025.2 -- and counts by cell
name now. What each tool warns about that remains:

| tool | warning | why it stays |
|---|---|---|
| Vivado | `[Synth 8-7129]` port unconnected or no load (95) | the deliberate sinks: CACR bits a unit does not read, MMU command bits the walker ignores, the `unused_*` buses |
| Vivado | `[Synth 8-6014]` `mag_num_reg`, `mag_den_reg` removed | the divider's two magnitude registers, inherited from RD68021, written and never read -- 64 flip-flops that synthesis deletes; harmless, and a two-line cleanup |
| Vivado | `[Timing 38-242]` `HD.CLK_SRC` not set | out-of-context: no clock source to estimate skew from |
| Quartus | `Warning (10036)` object assigned and never read (12) | the same `unused_*` sinks |
| Quartus | `Warning (10335)` `rom_style` not recognised | the Vivado attribute on the store; Quartus needs none (`doc/coding-standard.md`) |
| Quartus | `Critical Warning (15725)` clock fed by virtual pin | inherited from RD68021's script: `VIRTUAL_PIN ON -to *` is applied before the `OFF` for `clk`, and Quartus routes `clk` onto a global anyway (GCLK11, 5,899 loads on RD68021's fit). It does here too (GCLK1, 9,853 loads). Fixing it changes the method the RD68021 numbers were measured with, so it is left for phase B with the rest |

---

## The caches (M10)

The caches add, in storage: the instruction cache's 64 x 32 data RAM, sixteen
25-bit tags and 64 valid bits; the data cache's sixteen 16 x 8 RAMs (four banks
of four byte lanes), sixteen 27-bit tags, 64 valid bits, a 69-bit register for a
long word being gathered from a narrow port and an 81-bit one for the write
being applied. The RAMs are written on a rising edge and read without one, which
on the FPGAs this targets is distributed RAM; `make audit` counts the tags,
valid bits and the rest as reset flip-flops (4300 in all at M10, at the
defaults). Both caches can be built out -- `ICACHE_ENTRIES=0`,
`DCACHE_ENTRIES=0` on `rd68031_top` -- for an FPGA that wants the area back;
the core stays software compatible (`doc/caches.md`).

What either costs, and what the data cache's lookup does to the clock, is
measured at M15 above: 3,095 LUTs and 1,278 flip-flops for the two on the
Artix-7, and 2.0 MHz -- the cache's RAM write enables and valid bits sit
just behind the ATC's history on the limiting path. The vendor scripts pass
`DCACHE_ENTRIES` since M15.
