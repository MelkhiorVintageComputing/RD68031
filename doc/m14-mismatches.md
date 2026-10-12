# M14: what the Sun-3/80 PROM found

`make sun3x` runs the Sun-3/80 boot PROM in MAME's `sun3x` driver twice: on the core
(`sun3_80rd`, the RTL under Verilator behind a pin-level bus agent) and on MAME's own
m68030 with its FPU turned off (`sun3_80ref`, since the core has none). Each goes through
the PROM's self-test to the monitor prompt, then `sim/mame/monitor.cmds` is typed at it
over the serial console, and the two consoles are compared byte for byte.
`doc/oracles.md` ("MAME") has the machine and the harness.

The classes are those of `doc/m6-mismatches.md`: **(a)** a likely RTL bug, **(b)** an
oracle quirk or a harness issue, **(c)** a known, decided difference. Everything is
phrased architecturally; UM is `MC68030UM_split`, PRM `M68000PRM_split`. The Sun PROM
was disassembled to read what it does with the results (it is the software under test,
not an oracle). PC values are the PROM's, rev 3.0.3, at its virtual addresses
($FEFExxxx).

## The runs

Wall times on the build machine, one run at a time unless said (four ran in parallel for
the other revisions, one core each).

| PROM | Run | Monitor prompt | Commands | Console |
|---|---|---|---|---|
| 3.0.3 (default) | core | 610-670 s wall, ~19 emulated s | `monitor.cmds`, all answered | **identical** to the m68030's |
| 3.0.3 | m68030 | 2.3 s wall, ~20 emulated s | all answered | (reference) |
| 3.0.2 | core | 625 s wall | all answered | **identical** |
| 3.0 | core | 182 s wall | all answered | **identical** |
| 2.9.2 | core | 185 s wall | all answered | **identical** |
| 3.0.3 | core, `mmu.cmds` | 633 s wall | all answered | differs: m14-b1, m14-b2 |

The self-test is silent: nearly all of the time before the first character is the PROM
clearing and reading back memory (`MOVE.L #0,(A0)` / `MOVE.L (A0)+,D2` / `SUBQ.L` /
`BNE` at $FEFEB0E6-$FEFEB0F0, in an outer loop of four). Revs 3.0.3 and
3.0.2 size the driver's 64 MB; revs 3.0 and 2.9.2 find 4 MB, so their self-test is
shorter. In emulated time the core reaches the prompt slightly earlier than the m68030
(its clock counts are its own, `doc/timing-divergences.md`); nothing the PROM prints
depends on it.

**Performance.** The core runs at **0.028 to 0.032 emulated seconds per wall second**
(560 k to 645 k clocks/s at the 20 MHz clock, about 120 k instructions/s; 5.0 clocks per
instruction on this code): the PROM's 19 emulated seconds to the monitor take about ten
minutes, the whole `make sun3x` about twelve. MAME's m68030 runs the same at about 10×
real time, some 330 times faster. Nothing was profiled (there is no profiler on this
host), but the Verilator model is evaluated two to four times a clock, and skipping the
second evaluation of a half clock when no input of the core changed gained 17 %.

The scripted commands (`sim/mame/monitor.cmds`): `b ?`; `f` long and byte fills through
the PROM's MMU mapping, and `v` long and byte displays that show them merged; `l` opening
a long word, stepping, writing a new value and stepping again; the PROM's vectors
displayed through its own mapping; `s` (the function code the memory commands use).

## Class (b): oracle quirks

| | Observed | Manual | Handling |
|---|---|---|---|
| m14-b1 | **PTEST's address register.** The monitor's `p fefe0000` (open the page map entry) prints `PageMap FEFE0000 [03FFB900] = 63000009` on the core and `PageMap FEFE0000 [FEF60C00] = FEF60C00` on the m68030. The PROM runs `PTESTR #7,(A0),#3,A0` (at $FEFE0822) and `PTESTR #7,(A0),#2,A0` ($FEFE08B0), maps the page holding the address A0 returns into a window at $FEF74000 and reads the descriptor through it; it prints the level-2 descriptor's table address and the level-3 descriptor. With TC = $80D07660 (8 K pages, TIA 7, TIB 6, TIC 6) and CRP = $7FFF0003 / $03FFA000, the tables in memory give, for $FEFE0000: level-1 long descriptor at $03FFA3F8 (table $03FFA500), level-2 short descriptor at $03FFA57C = $03FFB90A (table $03FFB900), level-3 page descriptor at $03FFB9C0 = $63000009 (page $63000000, the PROM's physical window, U set). The core's answers are exactly these. The m68030's are what a PTEST that loads An with the *translated physical address* of the operand gives: $63000000, through which the PROM reads the PROM's own first long word, $FEF60C00 (its reset stack pointer, as `v fefe0000` shows). | UM 9.8 and PRM 6 (PTEST): with an address register, PTEST loads it with "the physical address of the last descriptor fetched" (for a long descriptor, its first long word; $0 if the root pointer is a page descriptor). | An oracle defect: the core is right. `p` is left out of `monitor.cmds`; `sim/mame/mmu.cmds` has it (`CMDS=sim/mame/mmu.cmds make sun3x` shows the difference). |
| m14-b2 | **A consequence of b1 in the PROM's own set-up.** The PROM also *writes* page descriptors through that window, at the address PTEST returns (`PTESTR #7,(A0),#3,A0` at $FEFE08F6, then `MOVE.L 8(SP),(A0)` at $FEFE0934). On the core, during the self-test (18.88 emulated s), it maps the Ethernet controller's page $FEF82000 with the descriptor $03FF4041 at $03FFB904 -- the level-3 entry the tables give for $FEF82000 -- and the table search then sets U and M ($03FF4059). On the m68030 that write never lands on the descriptor (the routine's one write in the self-test goes to $03FFB8E8, the window's own descriptor, with $FFF00059), so $FEF82000 stays invalid. The monitor then shows `p fef82000` as `[03FFB900] = 03FF4059` on the core and `[00000000] = 00000000` on the m68030, and **`b le()`** (boot from the Ethernet) ends differently: on the m68030 a bus error, `Vaddr: FEF82002, Paddr: 00000002, Write, FC 5, Size 2 at 0xFEFF22CA` (an invalid-descriptor fault on the LANCE's register, the Paddr computed with b1's PTEST); on the core `le: cannot initialize`, `Retrying`, `le: cannot initialize`, `le: Device not found.` -- the PROM's answer when the chip, here absent from the driver, does not respond. | UM 9.5, 9.8 | Not the core's. This is also what the driver's own comment calls a "bad '030 MMU mapping: L fef82000 -> P 00000000", and what `doc/oracles.md` recorded at M0 as "`b le()` bus-errors with a physical address of 0": both are the m68030's PTEST, not the PROM's tables. In `mmu.cmds`, not `monitor.cmds`. |

Until the m68030's PTEST is fixed in the build copy (a decision for the user, below), any
PROM path that uses PTEST to find a descriptor diverges, silently when it only maps a
page: the self-test's console is identical although the two machines' page tables differ
at $03FFB904 from 18.9 emulated seconds on.

## Class (c)

None met. LINK with A7 and the decimal instructions on non-BCD bytes
(`doc/divergences.md`) were checked first, as the plan asks: nothing in these runs
depended on them.

## Class (a)

None. Four PROM revisions reach the monitor on the core with a console identical to the
m68030's, and the monitor's commands give the same answers but where the m68030 is
wrong.

## Decisions for the user

1. **Fix PTEST in the reference.** MAME's m68030 lives in `build/mame/` as a copy, so its
   PTEST could be patched (by `sim/mame/build.sh`, like `sun3x.patch`) to return the last
   descriptor's address; `mmu.cmds` would then be comparable, and the PROM's tables would
   stay the same on both. Without it, `p` and `b le()` stay out of the comparison.
2. **The command set.** `monitor.cmds` is what both agree on today. `k 2` (system reset)
   reruns the whole self-test (another ten minutes on the core) and is not in it.
