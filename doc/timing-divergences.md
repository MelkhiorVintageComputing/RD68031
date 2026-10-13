# Where this core takes a different number of clocks

`CLAUDE.md`: instruction cycle timings need not match a real MC68030, but **every
divergence must be measured, reported and justified**. Bus *timing* is a
different matter and is not negotiable -- that is `doc/bus-timing-compliance.md`
and `doc/ac-timing.md`.

`make cycles` measures instructions against UM section 11, and every row is a
regression check: the count this design takes is frozen in `tools/cycles.py`,
and a change to it in either direction fails the target until someone looks at
it and writes the new number down. Since M15 the manual's figures are the
MC68030's own (below); the table is at the end of this file.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/timing-divergences.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---

## M15: against UM section 11

`make cycles` holds this design against the MC68030's own tables since M15.
Each row's manual figure is UM 11.6's **instruction-cache case** (CC): the
instruction's entry plus the effective-address entry its footnote names
(11.6.1 to 11.6.5), summed in the row; and its **average no-cache case**
(NCC), summed the same way. UM 11.6 assumes "two-clock bus cycles and no wait
states", long-word aligned operands, a 32-bit port and the data cache off, so
the bench is built twice:

- **sync**: the 32-bit port ends its cycles with STERM, two clocks -- the bus
  UM 11.6 assumes, and **the column to hold against the manual**;
- **async**: with DSACK, three clocks -- the bench RD68021 measured with,
  kept as the regression record. Every data access is one clock longer there.

Both warm counts are frozen per row. The cold count -- the first pass, the
instruction cache empty -- is reported against NCC but not frozen.

**The totals** (the integer rows; RESET, the coprocessor rows and the MMU rows
aside):

| | clocks | against UM 11.6's CC |
|---|--:|--:|
| UM 11.6 instruction-cache case | 1,330 | |
| this core, synchronous bus, warm | 1,075 | −19.2 % |
| this core, asynchronous bus, warm | 1,156 | −13.1 % |

Of 131 rows on the synchronous bus, 23 take the manual's count, 74
fewer and 34 more. The totals include the seven data cache rows. Until M15
phase B they also included four rows the bench made slow, which are retired
(below): with them it was 1,138 and 1,228 clocks against 1,370. RD68021's
mix, against the MC68020's figures on the asynchronous bench, was 1,182
against 1,332. Cold on the synchronous bus against the average no-cache case:
1,492 clocks against 1,336 (124 rows).

### Where it is faster, and why

- **One clock where the part takes two.** UM 11.6's floor is two clocks an
  instruction (`NOP`, `MOVEQ`, `ADDQ #,Dn`, `ADDX Dn,Dn`); this sequencer
  retires a one-microword instruction every clock. Every register-only row
  gains a clock or more from it.
- **Single-cycle units.** The barrel shifter does every shift and rotate in one
  clock (`ROXL #1,Dn` 1 against 12); the bit-field unit does `BFFFO` in 3
  against 20; the DSP multiplier `MULU.W` in 4 against 28 and `MULU.L` in 6
  against 46. RD68021's choices, unchanged.
- **The divider takes 44 clocks** whatever the operands, where UM 11.6's
  figures are maxima of 44 (`DIVU.W`) to 92 (`DIVS.L` with its extension
  word): equal on `DIVU.W`, up to 48 fewer elsewhere.
- **Status and control registers** (`MOVE #,SR` 3 against 10, `ANDI #,SR` 3
  against 12, `ORI #,CCR` 2 against 12, `MOVEC` 3 against 6 and 12): two or
  three microwords here, with the extension word already in the prefetch
  queue.

### Where it is slower, and why

Each cause below was traced (`+trace`, the per-clock micro-PC and bus) on the
synchronous bench.

1. **An operand read costs two clocks more than its bus cycle.** The
   sequencer issues the request in one microword; the bus unit starts the
   cycle at the next S0, the data is latched on the falling edge that ends
   it, and the microword retires on the rising edge after -- four clocks for
   a two-clock cycle, where UM 11.6 counts the cycle's two (or three, with
   its own overlap, for `fea (An)`). That is the +1 or +2 of every row that
   reads memory and depends on the value: `(xxx).W` and `(xxx).L` (+1, +2),
   `ADD Dn,(An)` and `ADDI.W #,(An)` (+2, +3: read, then write),
   `BTST`/`BSET Dn,(An)` and `LSL.W (An)` (+1), `UNLK` and `RTD` (+2, +1),
   `MOVES` (+2). Dependent reads pay it each time: `CMPM` (+5: two reads, the
   second not started until the first is consumed), memory indirect
   `([A0])` (+6: the pointer, then the operand), `MOVEP.L` (+4 written, +8
   read: four byte cycles, each its own pair of microwords), `RTR` (+3), and
   `RTE` (+9: the frame's four reads). The part overlaps its next read with
   the current one's bus cycle; this bus unit has one cycle in flight.
2. **Writes are posted one at a time.** A write retires the clock after the
   bus unit takes it, but a second waits for the first to finish: three
   clocks a write on a two-clock bus. `MOVEM.L` to memory (+3 for four
   registers), `LINK` (+2), `BSR` and `JSR` (+3 each: the return address
   written, then the refill at the target), `PEA` (equal).
3. **Exception entry.** `TRAP`, `ILLEGAL` and line A spend six microwords
   before the first frame write, four writes at the spacing of 2, and the vector
   read at the latency of 1: 24 clocks against 18 with the handler in
   a line of its own (`TRAP #0 [own line]`). `ILLEGAL` and line A, 28, also
   pay a line conflict: their handler, the prologue's, shares line 0 of the
   instruction cache with the loop, as the retired `TRAP #0` row's did
   (below).
4. **`CAS2`** (+10): twelve microwords between the second read and the first
   write -- both compares, the condition codes, and the decision which pair
   to write -- where the part overlaps them with its reads.
5. **Indexed addressing** costs one clock more than UM 11.6's 6 for the brief
   format on an aligned operand (9 against 8): three microwords of
   address calculation from the extension word before the read is
   requested, then the read's latency of 1.
6. **`MOVEA.L`** (+1): MOVEA spends a microword sign-extending its source
   (`_move_to_an` in `tools/ucode/program.py`) at long size too, where it
   changes nothing.

### Bench layout, not the design: four rows retired at M15 phase B

Four rows were slower for reasons of the bench, and were kept, frozen, through
M15 phase A because they had been frozen before it, each beside a twin without
the problem. At phase B the user retired them, keeping the twins:

| Retired row | sync / async | why it was slow | the twin kept | sync / async |
|---|--:|---|---|--:|
| `ADD.L (4,A0,D3.L),D4` | 11 / 13 | reads $2009: misaligned, three bytes and one, two bus cycles; UM 11.6 assumes aligned operands | `ADD.L (3,A0,D3.L),D4`, $2008 | 9 / 10 |
| `MOVE.L (4,A0,D3.L),D4` | 11 / 13 | the same | `MOVE.L (3,A0,D3.L),D4` | 9 / 10 |
| `JSR (A3)` | 13 / 14 | calls $3000, line 0 of the instruction cache, which the loop's own code at $0400-$045F needs: the call and the loop take the line from each other every pass (the M10 note below) | `JSR (A4) [own line]`, to $30A0, line 10 | 9 / 9 |
| `TRAP #0` | 28 / 32 | its handler at $3100, line 0 likewise | `TRAP #0 [own line]`, handler at $30A0 | 24 / 27 |

No count changed: the twins were measured beside them since M15 phase A, and
the totals above are the rest of the table, which is what they were "without
the four".

### The data cache (UM 11.4)

The rows marked `[D hit]` turn the data cache on in their setup, so the warm
pass's operand reads hit. UM 11.4's rules take the fea entry's tail off its CC
(down to one clock), count a memory-indirect mode as one read, leave an
operand fetch inside the operation's own CC uncorrected, and let a
read-modify-write's reads always miss. Here a hit saves two clocks of a
synchronous read: `ADD.L (A0),D4` 3 with a hit and 5 without, against UM
11.4's 4; `MOVE.L (A0),(A2)` 4 and 6, against 6; `CMPM` 9 and 13, against 8;
`([A0])` 14 and 18, against 12 -- and `TAS` is unchanged by it, as UM 11.4
says the part's is. The
two `[D hit]` rows whose second address was in the same data cache line as
the first (`CMPM` at $2000 and $2100, `([A0])` pointing at $0000) were moved
to $2010 before they were frozen.

### The MMU instructions

UM section 11 gives no figure for PMOVE, PTEST, PLOAD or PFLUSH (its 11.7 is
the table search alone, above), so these rows are measurements with nothing
to diverge from, frozen like the rest, with the MMU disabled: `PMOVE` to
memory 13 to 15, from memory 18, `PFLUSHA` and `PFLUSH` 7, `PTESTR` at level
0 13.

### The no-cache case

The cold pass is not UM 11.6's NCC -- NCC averages the two alignments and
assumes one bus cycle per two prefetches with nothing cached; the cold pass
is a real first pass, line fills and all -- but it is the nearest thing, and
it is reported beside it: 1,569 against 1,381 on the synchronous bus. The
excess is mostly the rows above that are slow warm, plus a clock or two of
refill after each branch and fill.

---

## M15 phase B: an operand's cycle into a new page

**One clock more on a misaligned operand that crosses a page boundary, with
translation enabled** -- an idle clock between the operand's last cycle in one
page and its first in the next. And when the next page is not in the ATC,
its table search starts that clock later.

Until M15 phase B the bus unit computed the next cycle's address at the end of
S5, looked it up in the 22-entry ATC and decided whether to start it, all in
the half clock between the falling edge that ends the transfer and the rising
edge that starts the next cycle. That chain was the design's limiting path at
20.9 MHz (`doc/critical-path.md`). The ATC is now never asked about an
address computed on that edge: an operand's later cycle in the page it is
already in runs on the translation the bus unit kept for that page -- as it
always did -- and only one entering another page needs a lookup, which it gets
from the operand's registers on the clock after (`rd68031_biu`, `s5_cross`).
The user accepted the clock for the frequency (`doc/size-and-speed.md`:
20.6 MHz to 29.6 on the Artix-7, with F2 and the rest).

| Case | before | M15 phase B |
|---|--:|--:|
| an operand entering a page the ATC has (or a TTx matches) | the next cycle at the end of S5 | one idle clock, then the cycle |
| ... a page the ATC does not have | the search started at the end of S5 | one idle clock, then the search |
| translation impossible: TC.E clear or MMUDIS, and neither TTx enabled; or CPU space | the next cycle at the end of S5 | unchanged: every page is its logical address, and nothing is looked up |
| every other cycle -- an operand's first, a later one in the same page, a cache completion | | unchanged |

How rare it is: a page is at least 256 bytes, and only an operand that is
misaligned across its boundary -- at most five bytes -- has a later cycle in
another page. `make cycles` runs with translation disabled and no row moved;
`core_mmu_tb`'s three programs, which cross pages on purpose, measure it:
`mmu_walk.S` (its reads and writes across a cachable and a CI page) 21,748
clocks against 21,740 before, `mmu_fault.S` (its faults across a boundary)
16,007 against 16,003, `mmu_regs.S` 17,228 unchanged -- 12 clocks over the
three programs, each spent where one of their operands enters a new page. No bus cycle, function code, order or count changes: the gap
between two cycles of the operand is a clock longer, which the bus protocol
allows between any two cycles (UM 7.3).

## M11: the table search

UM 11.7 gives the time of a table search as a table of clock counts for
two-clock bus cycles and a 32-bit port, by tree shape and by how many U and M
bits there are to write. This design's walker is hardware (`doc/mmu.md`), and
`core_mmu_tb` measures it -- the clocks from the search's start to the clock its
ATC entry is written, on the harness's 32-bit asynchronous port (three-clock
cycles, one more than UM 11.7 assumes):

| Search | UM 11.7 | here |
|---|--:|--:|
| no FC level, two short levels, no U or M to write ("xSSxx", none) | 33 | 18 |
| FC level, A and B long, U written at each level ("LLLxx", all U and M) | 53 | 52 |
| one short level, U already set | -- | 10 |

Each descriptor costs its bus cycles plus two to three clocks of the walker's
own -- choose the next table, check the limit, decide the descriptor -- and a
history write is one more bus cycle. With UM 11.7's two-clock cycles every row
would be shorter here still; the part's microcoded search spends more clocks
between its cycles. The bus cycles themselves -- their number, order, function
code, RMC -- are the part's, and are what `core_mmu_tb` counts. A search starts
the clock after the bus unit sees the miss, and the access is retried the clock
after the entry is written.

One order differs from the part's (`doc/divergences.md`): an operand that
crosses into a page the ATC does not have has that page searched before its
first cycle, where the part would search when the cycle reaches the page.

UM section 11 gives no clock counts for the MMU instructions themselves; since
M15 `make cycles` measures them (above).

---

## M10: the instruction cache's lines

The MC68030's instruction cache tags a LINE of four long words, not a long word
(UM 6.1.1): a miss whose tag does not match takes the whole line, and the three
entries it had are gone. `core_cycles_tb` puts its code at $0400, which is line
0, and two of its rows reach other code in line 0 from an instruction that is
itself in line 0: JSR (A3), at $040C, to the RTS at $3000, and TRAP #0, also at
$040C, to its handler at $3100. On the warm pass the target's fetch takes line 0 from the caller and
the return takes it back, so both miss every pass -- traced with `+trace`: the
warm JSR fetches $3000 from the bus, and the warm TRAP $3100. The MC68020's 64 single long words kept
$040C and $3000 in different entries. The part would pay these misses too; it is
the bench's layout meeting the part's organisation, not a cost of this design.

| Row | Before M10 | M10 |
|---|--:|--:|
| `JSR (A3)` | 9 | 14 |
| `TRAP #0` | 27 | 32 |
| `UNLK A4` | 7 frozen, 8 measured | 8 |

`UNLK A4` is not M10's: the design at the start of M10 already took 8 clocks
(measured on that tree with the same bench), and the frozen 7 was older than
it -- `make cycles` had not been run since, and could not have passed, because
this file had no table markers for it to fill. Both are put right here. Every
other row is unchanged: the bench runs with EI only, so the data cache takes no
part.

---

## The table

`make cycles`'s, regenerated on every run: UM 11.6's instruction-cache case
(CC) and how it adds up; this core warm on the synchronous bench and the
asynchronous one, each with its difference from CC; UM 11.6's average
no-cache case (NCC); and this core cold, on each bench, with the synchronous
one's difference from NCC. Differences in bold are slower than the manual.

<!-- cycles:begin -- generated by tools/cycles.py; do not edit -->
| Instruction | UM 11 CC | | sync, warm | Δ | async, warm | Δ | UM 11 NCC | sync, cold | Δ | async, cold |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `NOP` | 2 | 2 | 1 | -1 | 1 | -1 | 2 | 6 | **+4** | 7 |
| `MOVEQ #1,D4` | 2 | 2 | 1 | -1 | 1 | -1 | 2 | 6 | **+4** | 7 |
| `ADD.L D0,D4` | 2 | 2 | 2 |  | 2 |  | 2 | 6 | **+4** | 7 |
| `ADD.L (A0),D4` | 5 | 2 + fea (An) 3 | 5 |  | 6 | **+1** | 5 | 8 | **+3** | 10 |
| `ADD.L (A0)+,D4` | 5 | 2 + fea (An)+ 3 | 5 |  | 6 | **+1** | 5 | 8 | **+3** | 10 |
| `ADD.L -(A1),D4` | 6 | 2 + fea -(An) 4 | 5 | -1 | 6 |  | 6 | 8 | **+2** | 10 |
| `ADD.L (8,A0),D4` | 6 | 2 + fea (d16,An) 4 | 6 |  | 7 | **+1** | 6 | 11 | **+5** | 13 |
| `ADD.L ($2000).W,D4` | 6 | 2 + fea (xxx).W 4 | 7 | **+1** | 8 | **+2** | 6 | 11 | **+5** | 13 |
| `ADD.L ($2000).L,D4` | 6 | 2 + fea (xxx).L 4 | 8 | **+2** | 9 | **+3** | 7 | 15 | **+8** | 18 |
| `ADD.L #imm,D4` | 6 | 2 + fea #.L 4 | 4 | -2 | 4 | -2 | 6 | 13 | **+7** | 15 |
| `ADD.L (3,A0,D3.L),D4` | 8 | 2 + fea (d8,An,Xn) 6 | 9 | **+1** | 10 | **+2** | 8 | 13 | **+5** | 15 |
| `ADD.L ([A0]),D4` | 12 | 2 + fea ([B]) 10 | 18 | **+6** | 20 | **+8** | 12 | 23 | **+11** | 27 |
| `ADD.L D4,(A0)` | 6 | 3 + fea (An) 3 | 8 | **+2** | 9 | **+3** | 7 | 8 | **+1** | 10 |
| `CMP.L D0,D4` | 2 | 2 | 2 |  | 2 |  | 2 | 6 | **+4** | 7 |
| `CMPA.L A0,A2` | 4 | 4 | 3 | -1 | 3 | -1 | 4 | 6 | **+2** | 7 |
| `MULU.W D1,D4` | 28 | 28 + fea Dn 0 | 4 | -24 | 4 | -24 | 28 | 6 | -22 | 7 |
| `MULU.L D1,D4` | 46 | 44 + fiea #.W,Dn 2 | 6 | -40 | 6 | -40 | 46 | 11 | -35 | 12 |
| `DIVU.W D1,D4` | 44 | 44 | 44 |  | 44 |  | 44 | 44 |  | 44 |
| `DIVS.W D1,D4` | 56 | 56 | 44 | -12 | 44 | -12 | 56 | 44 | -12 | 44 |
| `DIVU.L D1,D4` | 80 | 78 + fiea #.W,Dn 2 | 44 | -36 | 44 | -36 | 80 | 49 | -31 | 50 |
| `DIVS.L D1,D4` | 92 | 90 + fiea #.W,Dn 2 | 44 | -48 | 44 | -48 | 92 | 49 | -43 | 50 |
| `ADDQ.L #1,D4` | 2 | 2 | 1 | -1 | 1 | -1 | 2 | 6 | **+4** | 7 |
| `ADDQ.L #1,(A0)` | 6 | 3 + fea (An) 3 | 6 |  | 7 | **+1** | 7 | 9 | **+2** | 11 |
| `ADDI.L #imm,D4` | 6 | 2 + fiea #.L,Dn 4 | 4 | -2 | 4 | -2 | 6 | 13 | **+7** | 15 |
| `ADDI.W #1,(A0)` | 6 | 3 + fiea #.W,(An) 3 | 9 | **+3** | 10 | **+4** | 8 | 15 | **+7** | 18 |
| `ABCD D0,D4` | 4 | 4 | 1 | -3 | 1 | -3 | 4 | 6 | **+2** | 7 |
| `ABCD -(A1),-(A2)` | 13 | 13 | 14 | **+1** | 16 | **+3** | 14 | 14 |  | 17 |
| `ADDX.L D0,D4` | 2 | 2 | 1 | -1 | 1 | -1 | 2 | 6 | **+4** | 7 |
| `CMPM.L (A0)+,(A1)+` | 8 | 8 | 13 | **+5** | 15 | **+7** | 8 | 13 | **+5** | 16 |
| `PACK D0,D4,#0` | 6 | 6 | 3 | -3 | 3 | -3 | 6 | 8 | **+2** | 9 |
| `UNPK D0,D4,#0` | 8 | 8 | 3 | -5 | 3 | -5 | 8 | 8 |  | 9 |
| `CLR.L D4` | 2 | 2 | 2 |  | 2 |  | 2 | 6 | **+4** | 7 |
| `CLR.L (A0)` | 5 | 3 + cea (An) 2 | 2 | -3 | 2 | -3 | 6 | 7 | **+1** | 8 |
| `NEG.L D4` | 2 | 2 | 2 |  | 2 |  | 2 | 6 | **+4** | 7 |
| `EXT.L D4` | 4 | 4 | 1 | -3 | 1 | -3 | 4 | 6 | **+2** | 7 |
| `NBCD D4` | 6 | 6 | 2 | -4 | 2 | -4 | 6 | 6 |  | 7 |
| `ST D4` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `TAS D4` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `TAS (A0)` | 14 | 12 + cea (An) 2 | 11 | -3 | 13 | -1 | 14 | 11 | -3 | 14 |
| `TST.L D4` | 2 | 2 | 2 |  | 2 |  | 2 | 6 | **+4** | 7 |
| `TST.L (A0)` | 5 | 2 + fea (An) 3 | 5 |  | 6 | **+1** | 5 | 8 | **+3** | 10 |
| `LSL.L #1,D4` | 4 | 4 | 1 | -3 | 1 | -3 | 4 | 6 | **+2** | 7 |
| `LSL.L D1,D4` | 6 | 6 (count <= size) | 1 | -5 | 1 | -5 | 6 | 6 |  | 7 |
| `ASL.L #1,D4` | 6 | 6 | 1 | -5 | 1 | -5 | 6 | 6 |  | 7 |
| `ASR.L #1,D4` | 4 | 4 | 1 | -3 | 1 | -3 | 4 | 6 | **+2** | 7 |
| `ROL.L #1,D4` | 6 | 6 | 1 | -5 | 1 | -5 | 6 | 6 |  | 7 |
| `ROXL.L #1,D4` | 12 | 12 | 1 | -11 | 1 | -11 | 12 | 6 | -6 | 7 |
| `LSL.W (A0)` | 7 | 4 + fea (An) 3 | 8 | **+1** | 9 | **+2** | 7 | 8 | **+1** | 10 |
| `BTST #3,D4` | 4 | 4 | 3 | -1 | 3 | -1 | 4 | 8 | **+4** | 9 |
| `BTST D1,D4` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `BSET D1,D4` | 6 | 6 | 2 | -4 | 2 | -4 | 6 | 6 |  | 7 |
| `BTST D1,(A0)` | 7 | 4 + fea (An) 3 | 8 | **+1** | 9 | **+2** | 7 | 8 | **+1** | 10 |
| `BSET D1,(A0)` | 9 | 6 + fea (An) 3 | 10 | **+1** | 11 | **+2** | 9 | 10 | **+1** | 12 |
| `BTST #3,(A0)` | 7 | 4 + fiea #.W,(An) 3 | 10 | **+3** | 11 | **+4** | 8 | 15 | **+7** | 18 |
| `BFTST D4{0:8}` | 8 | 8 | 2 | -6 | 2 | -6 | 8 | 7 | -1 | 8 |
| `BFEXTU D4{0:8},D5` | 10 | 10 | 3 | -7 | 3 | -7 | 10 | 8 | -2 | 9 |
| `BFINS D5,D4{0:8}` | 12 | 12 | 4 | -8 | 4 | -8 | 12 | 9 | -3 | 10 |
| `BFFFO D4{0:8},D5` | 20 | 20 | 3 | -17 | 3 | -17 | 20 | 8 | -12 | 9 |
| `BFCHG D4{0:8}` | 14 | 14 | 4 | -10 | 4 | -10 | 14 | 9 | -5 | 10 |
| `BFEXTU (A0){0:8},D5` | 14 | 12 + ciea #.W,(An) 2 | 11 | -3 | 12 | -2 | 14 | 16 | **+2** | 18 |
| `BFINS D5,(A0){0:8}` | 14 | 12 + ciea #.W,(An) 2 | 13 | -1 | 14 |  | 14 | 18 | **+4** | 20 |
| `BFTST (A0){4:32}` | 16 | 14 (5 bytes) + ciea #.W,(An) 2 | 12 | -4 | 14 | -2 | 16 | 17 | **+1** | 20 |
| `BRA.S (taken)` | 6 | Bcc taken 6 | 6 |  | 6 |  | 8 | 7 | -1 | 8 |
| `BRA.W (taken)` | 6 | Bcc taken 6 | 6 |  | 6 |  | 8 | 13 | **+5** | 15 |
| `BRA.L (taken)` | 6 | Bcc taken 6 | 8 | **+2** | 8 | **+2** | 8 | 14 | **+6** | 16 |
| `BEQ.S (not taken)` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `BEQ.W (not taken)` | 6 | 6 | 3 | -3 | 3 | -3 | 6 | 7 | **+1** | 8 |
| `BEQ.L (not taken)` | 6 | 6 | 5 | -1 | 5 | -1 | 8 | 13 | **+5** | 15 |
| `DBF (count not expired)` | 6 | 6 | 6 |  | 6 |  | 8 | 9 | **+1** | 10 |
| `DBF (count expired)` | 10 | 10 | 4 | -6 | 4 | -6 | 13 | 7 | -6 | 8 |
| `DBT (cc true)` | 6 | 6 | 3 | -3 | 3 | -3 | 8 | 7 | -1 | 8 |
| `EXG D0,D4` | 4 | 4 | 3 | -1 | 3 | -1 | 4 | 6 | **+2** | 7 |
| `SWAP D4` | 4 | 4 | 1 | -3 | 1 | -3 | 4 | 6 | **+2** | 7 |
| `MOVE SR,D4` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `MOVE D0,CCR` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `MOVE #$2700,SR` | 10 | 8 + fea #.W 2 | 3 | -7 | 3 | -7 | 12 | 7 | -5 | 8 |
| `MOVE A0,USP` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `MOVEC CACR,D4` | 6 | 6 | 3 | -3 | 3 | -3 | 6 | 7 | **+1** | 8 |
| `MOVEC D4,SFC` | 12 | 12 (SFC, DFC, CACR) | 3 | -9 | 3 | -9 | 12 | 7 | -5 | 8 |
| `MOVEM.L D0-D3,(A2)` | 14 | 4 + 2x4 + ciea #.W,(An) 2 | 17 | **+3** | 17 | **+3** | 14 | 22 | **+8** | 24 |
| `MOVEM.L (A0),D4-D5` | 18 | 8 + 4x2 + ciea #.W,(An) 2 | 15 | -3 | 17 | -1 | 18 | 20 | **+2** | 24 |
| `MOVEP.L D4,(0,A2)` | 14 | 14 | 18 | **+4** | 18 | **+4** | 14 | 24 | **+10** | 26 |
| `MOVEP.L (0,A0),D4` | 14 | 14 | 22 | **+8** | 26 | **+12** | 14 | 27 | **+13** | 32 |
| `MOVES.L (A0),D4` | 9 | 7 + ciea #.W,(An) 2 | 11 | **+2** | 12 | **+3** | 9 | 15 | **+6** | 17 |
| `MOVE.L D0,D4` | 2 | Rn,Dn 2 | 2 |  | 2 |  | 2 | 6 | **+4** | 7 |
| `MOVEA.L A0,A4` | 2 | Rn,An 2 | 3 | **+1** | 3 | **+1** | 2 | 6 | **+4** | 7 |
| `MOVE.W #1,D4` | 4 | EA,Dn 2 + fea #.W 2 | 2 | -2 | 2 | -2 | 4 | 7 | **+3** | 8 |
| `MOVE.L #imm,D4` | 6 | EA,Dn 2 + fea #.L 4 | 4 | -2 | 4 | -2 | 6 | 13 | **+7** | 15 |
| `MOVE.L D0,(A2)` | 3 | Rn,(An) 3 | 3 |  | 3 |  | 4 | 7 | **+3** | 8 |
| `MOVE.L D0,-(A2)` | 4 | Rn,-(An) 4 | 4 |  | 4 |  | 4 | 6 | **+2** | 7 |
| `MOVE.L (A0),D4` | 5 | EA,Dn 2 + fea (An) 3 | 5 |  | 6 | **+1** | 5 | 8 | **+3** | 10 |
| `MOVE.L (8,A0),D4` | 6 | EA,Dn 2 + fea (d16,An) 4 | 6 |  | 7 | **+1** | 6 | 11 | **+5** | 13 |
| `MOVE.L (3,A0,D3.L),D4` | 8 | EA,Dn 2 + fea (d8,An,Xn) 6 | 9 | **+1** | 10 | **+2** | 8 | 13 | **+5** | 15 |
| `MOVE.L (A0),(A2)` | 7 | Source,(An) 4 + fea (An) 3 | 6 | -1 | 7 |  | 8 | 9 | **+1** | 11 |
| `MOVE.L (A0)+,(A2)+` | 7 | Source,(An)+ 4 + fea (An)+ 3 | 7 |  | 8 | **+1** | 8 | 8 |  | 10 |
| `ORI #0,CCR` | 12 | 12 | 2 | -10 | 2 | -10 | 14 | 7 | -7 | 8 |
| `ANDI #$FFFF,SR` | 12 | 12 | 3 | -9 | 3 | -9 | 14 | 7 | -7 | 8 |
| `LEA (A0),A4` | 4 | 2 + cea (An) 2 | 3 | -1 | 3 | -1 | 4 | 6 | **+2** | 7 |
| `LEA (8,A0),A4` | 4 | 2 + cea (d16,An) 2 | 3 | -1 | 3 | -1 | 4 | 7 | **+3** | 8 |
| `PEA (A0)` | 6 | 4 + cea (An) 2 | 6 |  | 6 |  | 6 | 7 | **+1** | 8 |
| `LINK.W A4,#-8` | 4 | 4 | 6 | **+2** | 6 | **+2** | 5 | 7 | **+2** | 8 |
| `LINK.L A4,#-8` | 6 | 6 | 8 | **+2** | 8 | **+2** | 7 | 13 | **+6** | 15 |
| `UNLK A4` | 5 | 5 | 7 | **+2** | 8 | **+3** | 5 | 7 | **+2** | 9 |
| `JMP (A5)` | 6 | 4 + jea (An) 2 | 6 |  | 6 |  | 8 | 7 | -1 | 8 |
| `JSR (A4) [own line]` | 6 | 4 + jea (An) 2 | 9 | **+3** | 9 | **+3** | 9 | 13 | **+4** | 15 |
| `BSR.S` | 6 | 6 | 9 | **+3** | 9 | **+3** | 9 | 11 | **+2** | 12 |
| `RTS` | 9 | 9 | 7 | -2 | 9 |  | 11 | 7 | -4 | 9 |
| `RTR` | 12 | 12 | 15 | **+3** | 17 | **+5** | 14 | 15 | **+1** | 19 |
| `RTD #4` | 10 | 10 | 11 | **+1** | 12 | **+2** | 12 | 11 | -1 | 12 |
| `RTE (format 0)` | 18 | 18 (four word) | 27 | **+9** | 31 | **+13** | 20 | 27 | **+7** | 31 |
| `RTE (coprocessor)` | 26 | 26 | 55 | **+29** | 63 | **+37** | 26 | 55 | **+29** | 64 |
| `CHK.L D1,D4 (in range)` | 8 | 8 | 5 | -3 | 5 | -3 | 8 | 6 | -2 | 7 |
| `CHK2.L (A0),D4` | 21 | 18 + fiea #.W,(An) 3 | 20 | -1 | 22 | **+1** | 22 | 25 | **+3** | 29 |
| `CMP2.L (A0),D4` | 23 | 20 + fiea #.W,(An) 3 | 19 | -4 | 21 | -2 | 24 | 24 |  | 28 |
| `CAS.L (unsuccessful)` | 13 | 11 + ciea #.W,(An) 2 | 12 | -1 | 13 |  | 13 | 17 | **+4** | 20 |
| `CAS.L (successful)` | 15 | 13 + ciea #.W,(An) 2 | 15 |  | 17 | **+2** | 15 | 15 |  | 17 |
| `CAS2.L (successful)` | 24 | 24 | 34 | **+10** | 38 | **+14** | 26 | 39 | **+13** | 46 |
| `TRAPV (no trap)` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `TRAPF` | 4 | 4 | 2 | -2 | 2 | -2 | 4 | 6 | **+2** | 7 |
| `TRAPF.W` | 6 | 6 | 3 | -3 | 3 | -3 | 6 | 8 | **+2** | 9 |
| `TRAPF.L` | 8 | 8 | 4 | -4 | 4 | -4 | 8 | 13 | **+5** | 15 |
| `TRAP #0 [own line]` | 18 | 18 | 24 | **+6** | 27 | **+9** | 20 | 28 | **+8** | 32 |
| `ILLEGAL` | 18 | 18 | 28 | **+10** | 32 | **+14** | 20 | 28 | **+8** | 32 |
| `line A` | 18 | 18 | 28 | **+10** | 32 | **+14** | 20 | 28 | **+8** | 32 |
| `RESET` | 518 | 518 | 515 | -3 | 515 | -3 | 518 | 515 | -3 | 515 |
| `FNOP` | 18 | MC68881 8-7 18 | 18 |  | 18 |  | -- | 18 |  | 18 |
| `FBEQ.W (taken)` | 20 | MC68881 8-7 20 | 21 | **+1** | 21 | **+1** | -- | 21 |  | 21 |
| `FBEQ.W (not taken)` | 18 | MC68881 8-7 18 | 18 |  | 18 |  | -- | 18 |  | 18 |
| `FSEQ D0` | 18 | MC68881 8-7 18 | 22 | **+4** | 22 | **+4** | -- | 28 |  | 30 |
| `FMOVE.L D0,FPCR` | 28 | MC68881 8-6 28 | 25 | -3 | 25 | -3 | -- | 31 |  | 33 |
| `FMOVE.L FPCR,D0` | 31 | MC68881 8-6 31 | 27 | -4 | 27 | -4 | -- | 33 |  | 35 |
| `FMOVE.L (A0),FPCR` | 35 | MC68881 8-6 33 + (An) 2 | 28 | -7 | 29 | -6 | -- | 34 |  | 37 |
| `FMOVEM.L FPcr*3,(A0)` | 47 | MC68881 8-6 27+6n + (An) 2 | 43 | -4 | 45 | -2 | -- | 49 |  | 53 |
| `FMOVEM.X (A0),FP0-FP2` | 130 | MC68881 8-6 35+31n + (An) 2 | 87 | -43 | 96 | -34 | -- | 93 |  | 104 |
| `FMOVEM.X FP0-FP2,-(A7)` | 118 | MC68881 8-6 37+25n + -(An) 6 | 91 | -27 | 97 | -21 | -- | 97 |  | 105 |
| `FSAVE -(A7) (idle)` | 58 | MC68881 8-8 52 + -(An) 6 | 63 | **+5** | 63 | **+5** | -- | 64 |  | 65 |
| `FRESTORE (A7)+ (idle)` | 63 | MC68881 8-8 57 + (An)+ 6 | 65 | **+2** | 72 | **+9** | -- | 65 |  | 73 |
| `ADD.L (A0),D4 [D hit]` | 4 | 2 + fea (An) 3, tail 1 -> 2 | 3 | -1 | 3 | -1 | -- | 8 |  | 10 |
| `ADD.L -(A1),D4 [D hit]` | 5 | 2 + fea -(An) 4, tail 2 -> 3 | 4 | -1 | 4 | -1 | -- | 8 |  | 10 |
| `ADD.L (8,A0),D4 [D hit]` | 5 | 2 + fea (d16,An) 4, tail 2 -> 3 | 4 | -1 | 4 | -1 | -- | 11 |  | 13 |
| `ADD.L ([A0]),D4 [D hit]` | 12 | 2 + fea ([B]) 10, tail 0 | 14 | **+2** | 14 | **+2** | -- | 18 |  | 20 |
| `MOVE.L (A0),(A2) [D hit]` | 6 | Source,(An) 4 + fea (An) 3, tail 1 -> 2 | 4 | -2 | 4 | -2 | -- | 9 |  | 11 |
| `CMPM.L (A0)+,(A1)+ [D hit]` | 8 | 8, not corrected (11.4 note) | 9 | **+1** | 9 | **+1** | -- | 13 |  | 16 |
| `TAS (A0) [D hit]` | 14 | 12 + cea (An) 2, RMC misses | 11 | -3 | 13 | -1 | -- | 11 |  | 14 |
| `PMOVE TC,(A0)` | -- | -- | 13 |  | 13 |  | -- | 17 |  | 18 |
| `PMOVE (A0),TC` | -- | -- | 18 |  | 19 |  | -- | 22 |  | 24 |
| `PMOVE (A0),TT0` | -- | -- | 18 |  | 19 |  | -- | 22 |  | 24 |
| `PMOVE.Q CRP,(A0)` | -- | -- | 15 |  | 15 |  | -- | 19 |  | 20 |
| `PMOVE MMUSR,(A0)` | -- | -- | 13 |  | 13 |  | -- | 17 |  | 18 |
| `PFLUSHA` | -- | -- | 7 |  | 7 |  | -- | 11 |  | 12 |
| `PFLUSH #0,#0` | -- | -- | 7 |  | 7 |  | -- | 11 |  | 12 |
| `PTESTR #1,(A0),#0` | -- | -- | 13 |  | 13 |  | -- | 17 |  | 18 |
<!-- cycles:end -->
