# M11 part 2: what the oracles found about the MMU

This is the list phase B works from. Every MMU flow of `doc/oracles.md` was run on the
RTL as committed at b48ffba (M11 part 1, ec08857, plus the Makefile change after it),
with the harness of this phase, and every disagreement is here, in the classes of
`doc/m6-mismatches.md`:

- **(a)** a likely RTL bug -- the manual says what the core should do, and it does not;
- **(b)** an oracle quirk or a harness issue -- handled in the harness or recorded in
  `doc/oracles.md`, and listed so that nobody changes the RTL for it;
- **(c)** behaviour the manual leaves undefined or does not fix -- recorded, with what each
  side does, for a decision rather than a fix.

Everything is phrased as architectural behaviour with a manual citation and the bus
traffic or register values observed. "UAE030 does X" and "AP68030 does X" mean that oracle
produced X, nothing more. UM is `MC68030UM_split`, PRM is `M68000PRM_split`.

**Two oracles, and where they disagree.** UAE030 is an instruction-level model with a
bus-access hook; AP68030 a pin-level Verilog core. Neither is authoritative. Where both
agree with each other against the core and the manual is silent, the item says so in
bold: those are the ones phase B should weigh first.

## Phase B: what was decided

The user weighed the open questions below and decided:

| | Question | Decision | Done |
|---|---|---|---|
| Q-A | when a misaligned operand's second page is searched | **changed to the oracles' order**: the first page translated, the first part transferred, then the second page translated -- searched on a miss -- then the rest | `rtl/rd68031_biu.sv`: an operand is looked up at its first byte when it is taken and again at the cycle that enters its next page; one whose next page needs a search is set aside (`pk_*`) while the walker uses the engine. `doc/mmu.md` ("Where translation happens"), `doc/divergences.md`, `doc/checkpoint.md` |
| Q-B | which destination CAS2 writes first | **changed to the oracles' order**: destination 2, then destination 1 | `cas2_swap` in `tools/ucode/program.py`; `doc/manual-contradictions.md` 26 (the reason: two independent implementations agree, and PRM 4's operation listing is not a bus-order specification); `doc/m6-mismatches.md` b5 annotated; `core_fault_tb`'s per-access CAS2 cases. The vector generator still reorders UAE030's two writes to destination 1 first (M6's b5, in `gen.c`, which this phase did not touch): `core_vec_tb` puts the core's two in that order before comparing -- six successful CAS2 vectors in the sweep failed on exactly that and nothing else |
| Q-C (c2) | PTEST's N after a bus error during the search | **kept**: the table whose fetch failed counts (N = 2 in `mmu_cosim` phase 8) | recorded here and in `doc/divergences.md`; no change |
| Q-D (c3) | how far a user search goes after a long table descriptor with S set | **kept**: the search goes on to the page descriptor, as UAE030 does; AP68030's stop at the descriptor (b17) stays an oracle difference | recorded here and in `doc/divergences.md`; no change |

Nothing else was changed. Q-E (STATUS and ECS for an ATC miss) has no oracle
evidence either way and stays open.

**One thing the change uncovered (c12, open).** Q-A was put as "both oracles
agree", and for reads and for a read-modify-write's read they do. For a
**write** across into a page the ATC does not have, they do not: UAE030 writes
the first part and then searches the second page, as the core now does for
every operand; AP68030 searches both pages before the write's first part, as
part 1's core did -- which is why no comparison showed it until the core
moved. The change was made uniformly, as decided; AP68030's write order is
listed as c12 for the user to confirm or overrule. The fault frames are the
same either way.

**What the change to Q-A has to hold, and how it does** (`doc/mmu.md` has the
table):

- *The fault frame.* A second page that is refused is refused on the cycle
  that enters it, after the first part has gone -- written, for a write. The
  frame is the one a BERR on that cycle would make: DF, SIZE the residual's,
  +$10 the residual's logical address, +$18 the operand (UM 8.2.2; the FAULTS
  table, `data`/`mmu_*`). RTE with DF set hands back only the residual, which
  is translated afresh (`core_mmu_paging_tb`'s 108 cases, `core_mmu_tb`'s
  `mmu_fault` cases 7 and 8). That was already so; what moved is the second
  page's search, which now comes after the first part.
- *Read-modify-write.* RMC is held from the first cycle through the second
  page's search -- itself locked (UM 9.5.2) -- to the last; write protection
  of the second page is found on the read's second part (UM 8.2.3), and RTE
  with DF set reruns the whole instruction (`doc/checkpoint.md` rule 5).
- *Posted writes.* A write set aside for its second page's search is still
  outstanding: nothing else is taken by the bus unit, every microword that
  waits for a posted write waits for it, and its fault is taken where rule 9
  says. PMOVE to an MMU register now waits for posted writes before it
  commits, so that a later instruction cannot change the translation of an
  earlier write's second page; MMUDIS is held for the MMU for as long as an
  operand is under way (UM 9.2.3).
- *The data cache.* A half hit starts or stops the operand's cycles at a long
  word boundary, and a long word is never across a page, so only the page
  the bus reads is ever looked up. A refused write still invalidates the
  entries holding its refused bytes (UM 6.1.2).
- *Bursts and OCS.* The first cycle of an operand that spans two lines asks
  for no burst (UM 6.1.3.2); the operand's CBREQ state is carried across the
  wait. The cycle the operand resumes with is not its first and has no OCS
  (UM 7.1.1).

## Summary

| Flow | Result |
|---|---|
| `make vectors OP=pmmu` | 440 / 440 pass, after five oracle quirks are normalised or left out of the generator (b-pmmu below) |
| `make vectors-all` | 12,640 / 12,640 pass (12,200 in the 31 earlier groups, unchanged, and the 440 of `pmmu`); 2 dropped for room, 4 for a long frame, as before |
| `make cosim-mmu` | `mmu_walk`: 1,414 instructions, every register but one MMUSR bit the manual leaves undefined (c1), and the whole data-access stream -- 893 accesses, 0 differences. The other four programs diverge only on the class (b) and (c) items below; numbers per program at the end |
| `make ea`, `make cosim`, `make cputest` | 703 / 703; arith 19,496 and corners 2,156 instructions, now with the MMU's registers in the trace; 6,639 pass, 0 fail, 10 excluded (LINK A7) of 6,649 |
| `make cache` | pass (191 min): every directed testbench with both caches built out, the sweep (12,640) failing the same 0 vectors both ways, `make ea` 703 / 703, arith and corners with identical writes both ways |
| `make ap030` | the bus probe: every data transfer identical in 11 of its 14 phases (port sizes, misalignment, bursts, CIIN, wait states, CIOUT, the instruction cache's bursts); the differences in the other three, and in the MMU programs, are items below |

**Class (a): none.** No disagreement was found where the manual states what the core
should do and the core does otherwise. Two behaviours where **both oracles agree with
each other against the core** and the manual does not decide were the first open
questions (Q-A, Q-B); in phase B the core was changed to the oracles' behaviour for
both, and the comparison runs at the end show those differences gone.

**doc/mmu.md's six open questions**, answered as far as the evidence goes (details under
"Part 1's questions"):

| | Question | Core | UAE030 | AP68030 | Manual |
|---|---|---|---|---|---|
| 1 | RMW cycle missing in the ATC | searched, as a write (U and M) | searched as a read (U), then again for M | searched, as a write | figure 9-8: an ATC miss is searched; RMW counts as a write for M and WP. Nobody takes the bus error 9.10.3's handler expects -- the core is consistent with figure 9-8 |
| 2 | U at the descriptor whose S bit makes the violation | not written | not written | not written | unanimous; 9.5.1.1 "except after a supervisor violation" |
| 3 | PTEST's N after a bus error during the search | counted (N = 2) | MMUSR left $FFFF | not counted (N = 1) | Table 9-3: "the actual number of tables accessed"; c2 -- **kept**, by the user's decision |
| 4 | PLOAD while a TTx matches | searched | searched | searched | unanimous |
| 5 | ATC replacement; a misaligned operand's second page | replacement: identical search traffic in every pattern run (23 and 30 pages); second page searched before the first cycle -- **since phase B, after the first part** | second page searched after the first part | second page searched after the first part | replacement: agreement; the second page: both oracles against the core, manual silent -- **resolved (Q-A): the core now does what both oracles do** |
| 6 | STATUS for an ATC miss, ECS for an aborted cycle | three clocks; no ECS | -- (no pins) | never asserts STATUS for three clocks, never an ECS without AS | no oracle evidence |

---

## Class (b): oracle quirks and harness issues

None needs an RTL change. Where the harness corrects for one, the place is named.

### UAE030

| | What differed | Manual | Done |
|---|---|---|---|
| b1 | The MMU registers keep every bit PMOVE writes: TT1 $12345678 reads back $12345678 (core $12340670), TC $7CFFFFFF (core $00FFFFFF), CRP $FFFFFFFF:FFFFFFFF (core $FFFF0003:FFFFFFF0), MMUSR $FFFF (core $EE47) -- `mmu_regs` | UM 9.7.2: TC's "unimplemented fields ... are read as zeros"; 9.5.1.1, 9.7.1 for the root pointers; figures 9-37, 9-38 | `core_cosim_tb` and `core_vec_tb` compare the registers under the bits each has; the read-backs `mmu_regs` stores still differ (its D0 at instructions 132, 156, 181, 197, 227, 249) |
| b2 | The MMU configuration exception (vector 56) stacks a four-word format $0 frame: SR, PC, $00E0 -- `mmu_regs` (6 times), `pmmu` (18 vectors) | UM 8.1.10 and table 8-6: the six-word format $2 frame with the PMOVE's address at +$08 (AP68030 stacks it, $20E0) | `gen.c` records the format $2 frame's four writes and ISP 4 lower; the cosim reports it (ISP $EFF4 against $EFF8 in the handler) |
| b3 | A TC the configuration check refuses keeps E: $80888700 written, $80888700 read (core $00888700) -- `pmmu` 6 vectors; `mmu_regs` at each of its TC configuration exceptions ($80C08800 against $00C08800) | UM 9.7.2: "the TC register is updated with the data, and the E bit is cleared" | `gen.c` clears E in the oracle's result |
| b4 | PLOAD and PTEST with TC.E clear use a stale tree layout: with TC = $00C0AA00 (PS 4K, TIA 10, TIB 10) PLOADR #5 of $01400000 reads A[1] at $9004 instead of A[5] at $9014 -- `mmu_regs` phase 4 onwards | UM 9.7.2: "the MMU instructions (PTEST, PLOAD, PMOVE, PFLUSH) can be executed successfully, regardless of the state of the E bit" | -- (every later search in `mmu_regs` differs as a consequence) |
| b5 | PMOVE through `(A1)+` or `-(A1)` takes the F-line exception after updating A1 (A1 $2204 / $21FC; the core leaves $2200) -- `pmmu` 4 vectors | PRM 6, PMOVE: control alterable modes only; the exception is taken before the instruction does anything (UM 8.1.5) | `gen.c` puts An back |
| b6 | Command words $C000 and $E000 (`F011 C000`, `F011 E000`) and PFLUSHA with an effective address (`F011 2400`) run as instructions; the core takes the F-line exception | PRM 6 defines none of them (UM 8.1.5) | not generated; `core_m030_tb` checks the core's F-line |
| b7 | A read-modify-write cycle is searched as a read: TAS of an unmapped page writes U ($D009) in one search, then searches again and writes M ($D019); a CAS whose compare fails leaves M clear ($D309; the core $D319) -- `mmu_cosim` phase 3 | Figure 9-8 and UM 9.2.1: "(M = 0) and (write or RMW cycle)" leads to the table search that sets M; RMW counts as a write. AP68030 agrees with the core | -- |
| b8 | A bus fault is recovered by restarting the instruction from its first word: RTE of a format $B frame runs the faulted instruction again, so its boundary appears twice in the trace, and an access abandoned with DF clear (UM 8.2.2) is attempted again, forever (`mmu_fault` loops; `mmu_cosim`'s first version did) | UM 8.2: the MC68030 continues the instruction from the frame; DF = 0 means "do not rerun" | `core_cosim_tb` skips the oracle's repeated boundary ("a restart"); `mmu_cosim` repairs instead of abandoning; `mmu_fault`'s abandoned access loops on the oracle and its trace is cut at 3,000 instructions |
| b9 | After PTEST level 7 hits a bus error during the search (a table at $4000_0000), MMUSR is $FFFF and An $00009000 (the root table's address); the core gives MMUSR $8402 and An $000090C0, the descriptor it last fetched -- `mmu_cosim` phase 8 | PRM 6, PTEST: An gets "the physical address of the last descriptor successfully fetched"; Table 9-3 | -- |
| b10 | The long frame's stage B address (+$24) is the data fault address ($01000100 for a fault at that address), and the data input buffer (+$2C) the same | UM 8.2, table 8-7: "stage B address" | not compared (bus_diff compares it, and reports it as a value difference) |
| b11 | Reset reads the initial PC (4) before the initial SSP (0), both in data space (FC 5) | UM 8.1.1: SSP then PC, supervisor program space (AP68030 agrees with the core: FC 6, 0 then 4) | `bus_diff.py` shows the reset reads and does not compare them |
| b12 | The exception vector is read before the frame is written (M6's b2, again) | UM 8.1 | `bus_diff.py` moves it after the frame |
| b13 | A table search that ends in a bus error left every later access labelled a table search (harness) | -- | fixed in `uae030_glue.c` |
| b14 | Installing zeroed MMU registers before a test made the oracle halt in 40 MOVEM and MOVEC vectors (harness) | -- | `gen.c` installs them only around `pmmu` tests |
| b15h | For a posted write that faults, the core's trace has a boundary at the next instruction before the exception, which the oracle's has not; the registers are the same and both stack that next instruction's address (harness) | doc/checkpoint.md rule 9 | `core_cosim_tb` steps the core past it ("a posted-write boundary") |

### AP68030

| | What differed | Manual | Done |
|---|---|---|---|
| b15 | After a CAS whose compare fails, RMC stays asserted into the next, unrelated read: `R $E045 siz2 RMC` for the `MOVE.W` after `CAS.L` -- bus probe phase 6, on every port | UM figure 7-29: when the operands do not match the processor goes straight to "unlock bus: negate RMC" | -- |
| b16 | The unused lane of a three-byte write: `W $E020 SIZ=3` with operand $11223344 drives $22334422; the core $22334411 -- bus probe phases 1-4 and 10, `mmu_fault` phase 15 | UM table 7-5: three bytes at A1:A0 = 00 put OP0 on D7-D0 ("output but never used") | reported by `bus_diff.py` as its own class |
| b17 | A user access through a long table descriptor with S set ends the search at that descriptor: the page descriptor below it is not read, and PTEST reports N = 1 and no W although the same descriptor has WP set ($7FFF0106 gives MMUSR $2001; the core and UAE030 give $2802) -- `mmu_walk` phase 22, `mmu_cosim` phases 5-6, `mmu_fault` phase 6 | UM 9.5.5.3: "the table search is completed and an ATC descriptor ... is created with the B bit set"; Table 9-3: W "set if a descriptor ... is encountered with the WP bit set". See c3 | -- |

### The pmmu group (b-pmmu)

b2, b3, b5 and b6 are what the 25 failures of the first `pmmu` run were; with them
normalised (b2, b3, b5) or not generated (b6), 440 / 440 pass. Every PTEST, PLOAD and
PFLUSH vector -- every level, read and write, every kind of descriptor, FC from the
instruction, D1, SFC and DFC, TT1 matching with RWM set and clear, U and M in the tables
after -- agreed from the first run.

---

## Class (c): what the manual does not fix

| | What | Core | UAE030 | AP68030 | Manual |
|---|---|---|---|---|---|
| c1 | MMUSR W (and M, S) after PTEST level 0 finds an entry with B: `ptestr #1,(A0),#0` after a supervisor violation gives $8400 here, $8C00 on UAE030 -- `mmu_walk` instruction 877 | W clear | W set | -- | Table 9-3: W "is undefined if the I bit is set"; `core_vec_tb` masks W, M and S when I is set, and every bit but T when T is set |
| c2 | PTEST levels 1-7, N when a table fetch ends in a bus error | the failed fetch counts: MMUSR $8402 | $FFFF (b9) | not counted: $8401 | "the actual number of tables accessed during the search" (Table 9-3). **Decided in phase B: the core's behaviour is kept** |
| c3 | A user search meeting S in a long table descriptor: does it go on to the levels below? | goes on (reads the page descriptor, N = 2) | goes on | stops (b17) | 9.5.5.3: "the table search is completed" -- read here, and by UAE030, as "carried to its end". **Decided in phase B: the core's behaviour is kept** |
| c4 | Which fault frame a data fault at an instruction boundary uses | always the long format $B (doc/divergences.md) | the short format $A for a write that faults after its instruction (32 bytes; ISP 60 higher in the handler) | -- | UM 8.1.2: the short frame "when the bus error exception is taken at an instruction boundary" -- the processor's choice |
| c5 | The program counter in the frame of a write that faults after its instruction has retired (a posted write, or a write at the end of its instruction) | the next instruction: $0200001E for the write at $02000014 | the next instruction, $0200001E, in a short frame | the writing instruction, $02000014 | UM 8.1.2: "the address of the instruction that was executing at the time the fault was detected. This is not necessarily the instruction that initiated the bus cycle" |
| c6 | The frame's internal words, the SSW's internal-use bits (UAE030 sets SSW bit 9: $0345 where the core has $0145; AP68030 sets RC and RB: $3145), the version number at +$36 (core 3, AP68030 0) | | | | UM figure 8-9 ("X = for internal use only"), table 8-7. `bus_diff.py` masks them in the stream; a handler that copies the SSW into memory still shows the difference |
| c7 | The order and width of the frame's writes | words, from the top | words, its own order | long words, from the bottom | not fixed; `bus_diff.py` sorts a fault frame's writes |
| c8 | The stage fault bits of an instruction fetched from an invalid page (`mmu_fault` phase 19: the RTS at the first word of page B[15]) | FC and FB both set, SSW $F000 | FB set, SSW $5066, stage B address +$24 = the faulted word, so `mmu_fault`'s handler (which repairs the page of +$24 minus 2) repairs the wrong page and loops | FC set, SSW $B046 | UM 8.2.1: FC "fault on stage C", FB "fault on stage B"; which stage holds the word is the pipe's business |
| c9 | When a prefetch needs its page searched (the F stream) | | searches again after a flush where the core does not prefetch | later than the core | not fixed; reported, not failed |
| c10 | CBREQ on the second cycle of a long word read from a 16-bit port, data cache on: `R $1000E032 SIZ=2` | not asserted | -- | asserted | UM 7.3.7: CBREQ is asserted for a cachable read that misses; 6.1.3.1 for a misaligned access. Whether the second cycle of a dynamically sized long word is one is not said |
| c11 | ATC replacement | not-recently-used (doc/mmu.md) | its own | its own | "pseudo least recently used" (9.4). In every pattern run -- 23 pages (`mmu_walk` 30-36), 30 pages then the last 8 then the first 8 (`mmu_cosim` 19-21) -- all three made the same searches |
| c12 | *(found in phase B)* A misaligned **write** across into a page the ATC does not have: when is the second page searched? | after the first part (since phase B, Q-A) | after the first part | **before the first part**, with the first page's: `mmu_cosim` phase 1 (`MOVE.L #$11223344,$010008FD`: AP68030 `R $9040, R $9220, W $9220, R $9040, R $9224, W $9224, W $C8FD, W $C900`), phase 23 (`W $D9FE`, user data), `mmu_fault` phase 15 (`W $CBFF`), `cow_mmu` (`W $47FE`, `W $48FF`, `W $4AFE`) | not fixed (UM 7.1.1 aborts "the cycle" on a miss, which reads as per cycle). The part-1 comparison had the core searching every operand's pages up front, which matched AP68030 on writes and hid this; Q-A's "both oracles agree" holds for reads and read-modify-write reads only. The frames are the same either way -- AP68030 also writes the first part and faults on the residual (`mmu_fault` phase 15: SSW $0135 on both). Left as Q-A decided, for the user to confirm |

---

## Open questions

**Q-A. A misaligned operand across a page boundary: when is the second page searched?**
**Resolved in phase B: the core now searches it after the first part, as both
oracles do** (the decisions above; `doc/mmu.md`). What follows is the question
as it was put. **Both oracles agree with each other against the core.** The core searches both pages
before the operand's first bus cycle (doc/mmu.md, "Where translation happens"); UAE030
and AP68030 transfer the first part, then search the second page, then transfer the
rest. `mmu_cosim` phase 1, `MOVE.L $010002FE,D1` (pages B[2] and B[3], neither in the
ATC):

| | |
|---|---|
| core | R $9040, W $9040 (U), R $9208, W $9208 (U); R $9040, R $920C, W $920C (U); R $C2FE (2 bytes); R $C300 (2 bytes) |
| UAE030, AP68030 | R $9040, W $9040, R $9208, W $9208; **R $C2FE**; R $9040, R $920C, W $920C; R $C300 |

The same on every page-crossing read of that phase and on the CAS.W across pages of
phase 3. *(Phase B: not on the write. UAE030 searches a crossing write's second page
after the first part as well; AP68030 searches both pages before the first part of a
write -- c12. Part 1's core did the same as AP68030 there, which hid it.)* The faults are the same either way (the first part
is done, the residual faults -- doc/checkpoint.md); what differs is the order of the
search cycles against the first part, and so whether the first part has reached the
bus when a bus error during the second search is taken. UM 9.2.1 and figure 9-8
describe the translation of an access, not of an operand split across two pages;
nothing orders them. A decision rather than a fix: if the core is changed it should be
to the oracles' order.

**Q-B. CAS2: which destination is written first?** **Resolved in phase B: the core now
writes destination 2 first, as both oracles do** (`doc/manual-contradictions.md`
26). What follows is the question as it was put. **Both oracles write destination 2
first** (bus probe phase 6: AP68030 `W $E048` then `W $E040`; UAE030 likewise, M6's b5).
The core writes destination 1 first, following PRM 4's operation ("Update 1 ->
Destination 1; Update 2 -> Destination 2"). UM figure 7-29 does not order the writes.
At M6 the oracle's order was taken for a quirk on the strength of the PRM's listing;
with a second, independent core doing the same, it is less clear that the listing is a
bus order. A decision for the user.

**Q-C. PTEST's N after a bus error** (c2) and **Q-D. the extent of a search after an S
violation** (c3): three different answers between them; the manual's words fit more
than one. **Decided in phase B: both kept as the core has them**; nothing changed.

**Q-E. STATUS and ECS for an ATC miss** (part 1's question 6): neither oracle can
speak to it. AP68030 never asserts STATUS for three clocks and never starts a cycle
(ECS) it then abandons; UAE030 has no pins.

---

## Part 1's questions, in detail

1. **An RMW cycle that misses in the ATC is searched.** All three search; none takes
   the bus error UM 9.10.3's example handler is written for. The core and AP68030
   search once, as for a write, and write U and M together (TAS of `$01001000`: one
   search, `W $9240 $D019`); UAE030 searches as for a read (`$D009`) and then again to
   set M (b7). A CAS whose compare fails: the core and AP68030 have set M (the search
   was for an RMW, which figure 9-8 treats as a write); UAE030 has not. The core is
   consistent with figure 9-8 and with the other pin-level core.
2. **U is not written at the descriptor whose own S bit makes the violation, nor below
   it.** Unanimous (`mmu_cosim` phase 5: reads of $9580, $9584, $9604 and no write on
   any of the three sides; the U bits are written only by the rerun after the handler
   clears S).
3. **PTEST's N after a bus error during the search**: the core counts the table whose
   fetch failed (N = 2 for root, A, then a B table at $4000_0000); AP68030 does not
   (N = 1); UAE030's MMUSR is $FFFF. c2: kept, by the user's decision.
4. **PLOAD while TT1 matches searches the table**: unanimous (`mmu_cosim` phase 10:
   $9140, $9484 read and U written on all three).
5. **Replacement**: identical traffic in every pattern run (c11). **The second page of
   a misaligned operand**: Q-A, resolved -- searched after the first part.
6. **STATUS and ECS**: Q-E.

---

## The runs

### `make cosim-mmu` (UAE030), per program

| Program | Instructions | Boundaries that disagreed | D-stream differences | What they are |
|---|---|---|---|---|
| `mmu_walk` | 1,414 | 1 | 0 of 893 accesses | c1 |
| `mmu_regs` | 1,787 | 59 | 44 | b1, b2, b4 and their consequences |
| `mmu_cosim` | 482 | 26 (3 oracle restarts, 2 posted-write boundaries) | 46 (11 moved); 56 (21 moved) before phase B | b7, b8, b9, b10, c4-c6. Q-A and Q-B gone: the reads across pages and the CAS.W, and CAS2 at instruction 60 (`W $D500` then `W $D400` on both) |
| `mmu_fault` | 3,000 (cut: b8, c8) | 88 | 84 (6 moved); 87 (9 moved) before phase B | b8, c4-c8; the three that went were the operands across pages (Q-A) |
| `cow_mmu` | 11,369 of 14,704 | 2,108 -- 2,091 of them the ISP inside the handler, 60 bytes apart (c4), and the flags of the kernel's tests of the frame | 137 (frame writes and the handler's copies of frame words); 140 before phase B | identical through the first ten copy-on-write faults (the same faults, at the same instructions, with the same search traffic); at the eleventh the instruction at which a write's fault is taken differs by one (c5), and the comparison stops there |

### `make ap030` (AP68030), per program

| Program | Data transfers (AP68030 / core) | Phases that differ | What they are |
|---|---|---|---|
| bus probe | 658 / 732 | 6, 10, 11 of 14 | b15, c10, c6-c7 (the bus error frames); 6 three-byte writes b16. Phase 6: 12 differences before phase B, 4 after -- the CAS2 writes (Q-B) gone, b15 left |
| `mmu_walk` | 929 / 920 | 21, 22 of 42 | b17 / c3 |
| `mmu_cosim` | 741 / 789 | 1, 5, 6, 8, 23, 25 of 30 (1, 3, 5, 6, 8, 23, 25 before phase B) | c12 (phase 1: the write, 2 differences where the three reads made 6; phase 23: one more, 14 for 13), b17/c3, c2, c5, c6, c7, c9. Phase 3 (the CAS.W across pages, Q-A, and CAS2, Q-B) now identical |
| `mmu_regs` | 812 / 836 | 2 of 38 | c7 (the configuration exception's frame: the same format $2 frame, written as long words) |
| `mmu_fault` | 1,278 / 1,406 | 15 of 26 | c5-c8, b17, c2, b16; phase 13 (the read across) 9 differences before phase B, 8 after; phase 15 (the write across) 7 before, 8 after -- c12 |
| `cow_mmu` | 10,699 / 11,016 | (one phase) 238; 237 before phase B | c6 (the version number the kernel logs: core $3008, AP68030 $0003), c7, c9 and ATC traffic differences after them; c12 at the three user writes across pages |
