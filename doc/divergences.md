# Where this design does not behave as the part does

Every standing difference between RD68031 and a real MC68030, why it is there, and
how it is checked. Cycle-count differences live in `doc/timing-divergences.md`;
this file is for behaviour.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/divergences.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---

## STATUS is encoded from what the sequencer can say, one clock late

**UM 12.7.1 and Table 12-4.** STATUS is asserted for one clock at an instruction
boundary, two at a boundary where a trace or an interrupt exception is to be taken,
three when exception processing begins "for reset OR bus error OR address error OR
spurious interrupt OR autovectored interrupt OR F-line instruction (no coprocessor
responded)" or on an ATC miss, and continuously once halted by a double bus fault.

**What this design does.** The sequencer reports four events — a boundary, a
boundary with a trace or interrupt taken, the start of exception processing, a
pipeline refill — as one-clock pulses registered on the rising edge after them, and
the bus unit, which owns the pins, shows each as the table's number of clocks from
the next falling edge. Since M8–M9 every exception the table gives three clocks
is told apart, and gets them:

- reset, after `rst_n` and after the RESET pin, and a bus or address error (the
  fault entry);
- a spurious or an autovectored interrupt, once the acknowledge has ended with
  BERR or AVEC (`mark = EXC` on the microword that takes the answer, in
  `tools/ucode/program.py`) — after the two clocks the boundary itself showed;
- an F-line instruction no coprocessor responded to (`exc_line_f_nocp`): the bus
  error on the cycle that starts a coprocessor instruction, or, in a core built
  without the coprocessor interface, the CpID-1-to-7 word itself. A CpID-0 word
  that is no MMU instruction is an F-line exception that asked no coprocessor,
  and shows none.

- an ATC miss, since M11: "MMU address translation cache miss -- processor to
  begin table search" (UM Table 8-2) -- three clocks when the MMU's walker
  starts a search for an access. PTEST and PLOAD are instructions, and their
  searches show none.

What remains:

- **One negated clock between indications.** This core can finish an instruction
  every clock, which a real MC68030 does not, and two one-clock pulses on
  consecutive clocks would read as one two-clock pulse. An event that arrives
  while one is shown waits; two that arrive in that time are shown as the longer
  of them, so a run of very short instructions shows fewer boundaries than it
  had.
- **One and a half clocks late**: the pin moves on the falling edge after the
  rising edge that registers the event, where the part's sequencer drives the pin
  itself.
- **REFILL** is one clock for every pipe flush the microcode requests. The part's
  DBcc "requests a refill before the condition is tested", and again "if the
  condition is false ... to continue with the next sequential instruction"; this
  core's DBcc refills only when it branches, once.

**How it is checked:** `bus_status_tb` drives the events and checks the widths, the
gap, the edges and the halted case; `core_status_tb` runs code and checks reset's
three clocks, one-clock boundaries, a trace's two clocks, a bus error's three, a
vectored, an autovectored and a spurious interrupt (two clocks at the boundary,
and three more for the last two), an F-line instruction no coprocessor answers
(three) against a CpID-0 one (none), and one REFILL per refill requested;
`core_reset_tb` checks the three clocks after the RESET pin; `core_fault_tb` and
`core_reset_tb` check the double bus fault.

---

## `rst_n` is a pin of its own, and resets more than the RESET pin does

**UM 7.8, 5.10.1, 8.1.1:** "the external RESET signal resets the processor and the
entire system", and the reset exception that follows does ten named things to the
processor: T1 T0, S, M and the mask; VBR; CACR's enable, freeze, burst and
write-allocate bits; both caches; TC.E, TT0.E and TT1.E; the ISP and the PC from
the vector table. "During the reset period, the entire bus three-states."

**What this design does.** Since M8–M9 it has two resets.

- **The RESET pin** (`reset_n_i`) resets the processor as the manual describes
  it. The bus unit synchronises it, ignores its own RESET instruction's pulse
  and the four clocks after it (UM 7.8: an external RESET during the instruction
  "must extend beyond the reset period of the instruction by at least eight
  clock cycles to reset the processor"), and registers the rest as `crst`.
  While `crst` is asserted the bus three-states, a cycle in progress is
  abandoned ("as if DSACKx, BERR, or STERM had been asserted"), the sequencer,
  the fetch unit and the instruction cache are held reset, and SR, VBR and CACR
  take their reset values; when it negates, reset exception processing begins
  -- three clocks of STATUS, the ISP from $0 and the PC from $4 in supervisor
  program space. What UM 8.1.1 does not name keeps its value: D0-D7, A0-A6,
  USP, MSP, SFC, DFC and CAAR. The arbiter keeps running: "bus arbitration
  requests are recognized during normal processing, RESET assertion, HALT
  assertion" (UM 7.7). Since M11 the pin also clears TC.E, TT0.E and TT1.E
  and nothing else of the MMU's: the rest of those registers, CRP, SRP, MMUSR
  and the ATC keep their values -- UM 9.2.2, "a reset of the processor does not
  invalidate any entries in the ATC" -- and a table search in progress is
  abandoned with the bus cycle it was running.
- **`rst_n`**, which is not an MC68030 pin (`doc/pinout.md`), is the power-on
  initialisation ASIC needs: every register, the architectural ones included,
  takes its value from it, and the processor then runs the same reset exception.

Three differences from the part remain, all about `rst_n` or the edges of the
pin:

- **Arbitration under `rst_n`.** `rst_n` resets the arbiter with everything
  else, and BG stays negated while it is asserted. This is a deliberate choice,
  decided by the user after M2: arbitration stays off while `rst_n` is
  asserted, and it is not to be revisited. Under the RESET pin it is on.
- **A RESET shorter than the manual asks for.** "Asserting RESET for 10 clock
  periods is sufficient for resetting the processor logic"; this design resets
  on any assertion its synchroniser sees on two consecutive falling edges. The
  manual says what is enough, not what is ignored.
- **The address bus after reset.** "Once RESET negates, all control signals are
  driven to their inactive state, the data bus is in read mode, and the address
  bus is driven" (7.8, figure 7-64). With `ADDR_HIZ_BETWEEN_CYCLES` set, the
  default, the address group is released between cycles, and so also from the
  end of either reset to the first cycle; with it clear the address is driven
  there as the figure draws it. The default is the user's decision — see "The
  address group is released between bus cycles" below.

**How it is checked:** `bus_reset_tb` checks the three-stating under `rst_n` and
the pins after it; the RESET instruction's own pulse resetting nothing; the pin
from outside three-stating the bus, abandoning a cycle in progress, starting
nothing while held, granting BR under it, and letting the abandoned operand run
afterwards; and a RESET from outside during the instruction's pulse that ends
with it, two clocks after it, and eight clocks after it -- only the last resets.
`core_reset_tb` resets a running program and checks UM 8.1.1 step by step, the
registers it spares, the cache invalidated, a restart from a double bus fault
and from STOP, the double bus faults of reset exception processing, and the
RESET instruction against a RESET from outside. `core_mmu_tb` pulls RESET at
the end of `mmu_regs.S` and checks the three E bits cleared, the rest of TC,
TT0, TT1 and CRP kept, and the ATC still holding its entry.

---

## The address group is released between bus cycles

**UM 7.8 and the MC68030EC figures.** Nothing in the MC68030 manual says the
address bus is released between cycles, and what it draws could suggest it is not. The four
read and write cycle figures of MC68030EC (figures 3 to 6) mark specification
8, "Clock High to Function Code, Size, RMC, IPEND, CIOUT, Address Invalid", at
the end of a cycle; specification 7, "Clock High to Function Code, Size, RMC,
CIOUT, Address, Data High Impedance", appears on the bus arbitration figure
(figure 7) alone; and after reset "the address bus is driven" (7.8, figure
7-64). Read alone, that suggests the part keeps the address group — A31–A0, FC2–FC0,
SIZ1/SIZ0, CIOUT — driven from one cycle to the next and three-states it only
on bus relinquish and in reset.

**What this design does:** with `ADDR_HIZ_BETWEEN_CYCLES` set, the default, the
address group's enables (`a_oe`, `fc_oe`, `siz_oe`, `ciout_oe`) drop on the
rising edge that ends S5 when the bus unit goes idle, and rise again at S0 of
the next cycle; they are also low from `rst_n` negating to the first cycle.
Back-to-back cycles, a cycle waiting to be retried and a halted bus keep them
driven (7.5.3: "the address, function code, size, and read/write signals
remain in the same state"). RMC follows the same enable outside a locked
run (`doc/pinout.md`). The control group is unaffected: it is released
only on relinquish and in reset (`doc/pinout.md`).

**What the MC68020 manual says.** The MC68030's asynchronous bus cycles are
compatible with the MC68020's, and where the MC68030 documentation is ambiguous
the MC68020's is the tie-breaker. It is not ambiguous here: the MC68020's read
and write cycle figures (`MC68020UM_split/figure-10-03-read-cycle.md` and
`figure-10-04-write-cycle.md`, UM20 figures 10-3 and 10-4) list specification 7,
"Clock High to Address, Data, FC, Size, RMC High Impedance", among the
specifications of an ordinary read and write cycle -- a release at the end of
every cycle, not only on relinquish. RD68021 implements exactly that, with the
same default (its `doc/divergences.md`, "The address group is released between
bus cycles"). The MC68030EC data sheet, drawing specification 7 only on
relinquish, is silent rather than contrary: it does not say the address is held.

**Why:** the user's decision, after M2 and M3 raised the question: keep the
release, on the MC68020 evidence above. The MC68030EC reading -- the address
held between cycles -- remains available as `ADDR_HIZ_BETWEEN_CYCLES` = 0 on
`rd68031_top`, inherited from RD68021, which keeps the group driven between
cycles and after reset; it changes nothing on relinquish or in reset. The user
does not expect a board to need it, and it is not tested (below).

**How it is checked:** `bus_ruler_tb` and `bus_sync_tb` check the address enable
cycle by cycle — driven from S0 and released on the edge that ends the cycle —
on asynchronous and synchronous reads and writes; `bus_reset_tb` checks it
released after `rst_n` until the first cycle; `bus_error_tb` and `bus_arb_tb`
check it held while halted; `bus_arb_tb` checks it released on relinquish. All
of them run with the default; nothing runs or elaborates the cleared setting,
which differs only in `addr_drive` being constant. Since M3 `make timing`
measures the release against MC68030EC specifications 7, 8 and 13 at every
cycle end it happens on, at all five grades — specification 7 there, where the
data sheet draws it only on relinquish — and says in its log which setting it
ran (`doc/ac-timing.md`, "`ADDR_HIZ_BETWEEN_CYCLES`").

---

## Every bus and address error builds the long frame

**UM 8.1.2:** "When the bus error exception is taken at an instruction boundary,
less information is required to recover from the error, and the processor
builds the short bus fault stack frame ... When the exception is taken during
the execution of an instruction, the processor must save its entire state for
recovery and uses the long bus fault stack frame". UM 8.1.3 says the same of an
address error, and Table 8-6 assigns format `$A` to "Address Error or Bus Error
— Execution Unit at Instruction Boundary".

**What this design does:** format `$B` for every bus error and every address
error, and never `$A`. A data fault is always taken mid-instruction here: the
microcode stalls on its operand, or posts a write and takes the write's fault
at whatever microword is running. A prefetch fault is taken by the microword
that needs the word, usually the instruction's last, which RTE re-executes and
which may read any working register — carried only by the long frame. RD68021
built a short frame for a while, for the case that looked like a boundary, and
SunOS found the working registers it lost (RD68021's `doc/bugs-found.md`).

**Why it is allowed:** UM 8.4, "The system software should not depend on a
particular exception generating a particular stack frame. For compatibility
with future devices, the software should be able to handle any type of stack
frame for any type of exception." The cost is stack — 92 bytes a fault where
the part would sometimes use 32 — and the time to write and read them. RTE
still accepts a format `$A` frame, restoring it from its architectural fields
alone (`doc/checkpoint.md`, rule 1).

**How it is checked:** `core_fault_tb`, `core_paging_tb` and `core_cow_tb`
compare every fault frame's format word with `$B`; `core_fault_tb` runs RTE out
of hand-built `$A` frames.

---

## The MMU: where the manual is silent, and what this design chose

*Closes M5's "The MMU instructions take an F-line exception in supervisor mode
(until M11)": PMOVE, PTEST, PLOAD, PFLUSH and PFLUSHA execute (`doc/mmu.md`),
and only a command word the part does not define takes the F-line exception
(UM 8.1.5).*

**UM section 9** describes the MMU's architecture -- the registers, transparent
translation, the ATC, the table search, the faults -- and the design follows it
(`doc/mmu.md`). Where it is silent or contradicts itself the choice is below;
the contradictions themselves are `doc/manual-contradictions.md` 19-25.

| | UM | here |
|---|---|---|
| ATC replacement | "a pseudo least recently used algorithm ... a validity bit and an internal history bit" (9.4), no more | the lowest invalid entry, else the lowest whose history bit is clear; set on load and on use, all but the newest cleared once every valid entry's is set (`doc/mmu.md`). A program cannot tell the difference unless it counts table searches |
| who searches | "microcode and dedicated logic" (9.1) | a hardware walker beside the bus unit; the same bus cycles, the same results (`doc/mmu.md`) |
| when a misaligned operand's second page is searched | not said; the part presumably searches when the cycle reaches the page | before the operand's first cycle, with the first page's: the same cycles in a different order, only for an operand that crosses into a page the ATC does not have |
| ECS for a cycle the MMU aborts | "the processor aborts the cycle before asserting AS" -- after ECS (7.1.1) | no ECS: no cycle starts, as for a cache hit |
| an RMW cycle that misses in the ATC | searched (9.2.1, figure 9-8) -- or a bus error for the handler to PLOAD (9.10.3's example) | searched -- manual-contradictions 19 |
| U in the descriptor whose S bit makes the violation | figure 9-29 writes it, 9.5.1.1 does not | not written -- manual-contradictions 21 |
| PTEST's N after a bus error | "the actual number of tables accessed" | the table whose fetch failed counts |
| PLOAD with a TTx register matching | not said | PLOAD searches the tables anyway |
| reserved bits of TTx and MMUSR | not said | not kept: they read zero, as TC's and the root pointers' do by the manual |
| PMOVE register-to-memory with FD set | not said; the format has the bit | accepted, FD ignored |

**How it is checked:** `core_mmu_tb` (`doc/mmu.md`, the tests), which counts
the table search cycles of every phase -- and so would see a different search
order or a different replacement.

---

## The caches: where the manual is silent, and what this design chose

*Closes M5's "CACR's data-cache and burst bits are stored and do nothing (until
M10)": every CACR bit now acts (`doc/caches.md`), both caches have the MC68030's
organisation, and both ask for bursts.*

**UM section 6** describes the caches' architecture and their bus traffic, and
the design follows it -- the organisation, every CACR bit, write-through, every
case of figure 6-4, the single-entry fills of figures 6-5 to 6-10 cycle for
cycle, the burst requests of 6.1.3.2 and what CIIN, CBACK and BERR do to them.
Where the manual says nothing, this design had to choose, and each choice is
one that can never leave the caches holding something memory does not:

- **A hit shows nothing on the bus.** UM 7.2.7: the part "may also initiate an
  external bus cycle in case the requested item is not resident", so a hit can
  show as an ECS -- even several in a row -- with no AS after it. Here the
  lookup is combinational and decides before the bus unit is asked, so a hit
  never starts a cycle and never asserts ECS. ECS is an indication of an
  internal decision, not part of any cycle a device answers.
- **The read of a read-modify-write gets no completing cycles.** UM 6.1.2.2 has
  its data "update a matching entry ... or create a new entry", and 6.1.3.1 has a
  narrow port's entry completed by extra cycles; neither says whether the
  locked sequence includes them. Here it does not: from a 32-bit port the read
  fills its entry, and from a narrower one the entry is left invalid, so a stale
  copy cannot survive the read.
- **A CACR clear stops a fill in flight.** The rest of a burst, or a long word
  the pipe asked for before the MOVEC, is not written into a cache CI, CEI, CD or
  CED has just cleared. The manual does not say which side of the clear such a
  long word lands on; this side cannot leave stale data behind.
- **A prefetch abandoned before the bus took it asks for no burst.** Its own long
  word is still cached when it arrives (it is a cachable prefetch, in the space
  it was asked in), but nothing is waiting for the rest of the line.
- **An operand whose last long word hits starts with SIZ for the whole
  operand.** UM 6.1.2 treats the two halves independently but shows no cycle for
  this case; the first cycle is the one the operand would have started with,
  SIZ counting what it would have counted, and the bus unit stops after it. The
  case where the FIRST long word hits is UM 7.2.7's, and its cycle has OCS.
- **RTE's rerun of a faulted operand is not cached** (`doc/checkpoint.md` rule
  12): it is the frame's operand, run on the bus as it stands.
- **A read the bus unit would take on the edge a data-cache fill lands is held
  one clock and looked up again**, so that it never reads from the bus a long
  word the cache is being given on that edge. The part's microsequencer "must
  wait for the burst operation to complete before requesting the second
  portion" (UM 6.1.3.2); this is the same wait, one clock long, and it moves no
  cycle a device sees except in time.

**Why it is allowed:** each is a choice among behaviours the manual permits or
does not describe, and none changes a value a program can read. The caches stay
invisible -- `make cache` holds a core with them to the same writes as one
without.

**How it is checked:** `core_cache_tb` checks that every ECS starts a cycle,
TAS on the 8-bit port (one read, one write, the entry left invalid), and both
half hits cycle for cycle; the clear landing mid-fill, the abandoned prefetch,
the rerun and the one-clock hold are not provoked by any bench, and are argued
in `doc/caches.md`. `core_m030_tb` and `make cache` hold the caches to
invisibility.

---

## LINK A7 pushes the stack pointer after the decrement

**PRM 4, LINK:** "SP - 4 → SP; An → (SP); SP → An; SP + dn → SP." The cputest
corpus, whose generator was validated against real processors, records the part
pushing A7's value from *before* the decrement: every one of the 10 sampled tests
of `LINK.W A7,#d` (`$4E57`) and `LINK.L A7,#d` (`$480F`) expects it
(`doc/m6-mismatches.md` Q2).

**What this design does:** what the operation says. The stack pointer is stepped
down four, and the push goes through it, so LINK A7 stores the decremented value;
A7 then ends at that value plus the displacement, as on the part.

**Why it is allowed:** the manual is literal and the design follows it
(`doc/manual-contradictions.md` entry 15). The difference is the one long word
pushed, only for A7 as LINK's register, which no compiler or hand-written frame
pointer convention uses -- the frame pointer it would establish is the stack
pointer itself. The stack pointer, the displacement and every other register come
out as on the part.

**How it is checked:** `core_insn_tb` checks the pushed value and A7 after
`LINK.W A7,#-8`. `core_cputest_tb` runs the corpus's LINK A7 tests and counts
them as excluded, by encoding, rather than failed.

**Watch for it with real software.** The user decided, after phase B of M6-M7,
to follow the manual here -- and to keep this in mind. If Linux, NetBSD, SunOS
or the Sun-3/80 PROM (M13, M14) ever misbehaves around a stack frame, or the
lockstep run of `sim/virt/` diverges on a `LINK A7` (`$4E57`, `$480F`), suspect
this first: the part pushes the value from *before* the decrement, and the fix
is one microword.

---

## T1 and T0 both set trace every instruction

**UM 8.1.7, table 8-3:** T1 T0 = 10 traces every instruction, 01 traces changes
of flow, and 11 is "Undefined, Reserved".

**What this design does:** takes 11 as 10 -- T1 decides, and T0 matters only
when T1 is clear. A status register write that sets both traces the instruction
after it, with the format $2 frame tracing any instruction takes. RD68021 traced
nothing under 11.

**Why it is allowed:** the encoding is reserved, so the manual asks nothing of
it; the choice is the one the cputest corpus records the part making, so that a
program that sets both bits by accident -- `ORI #$C534,SR` in the corpus --
behaves as it would on the silicon (`doc/m6-mismatches.md` A10).

**How it is checked:** `core_insn_tb` sets T1 alone, and T1 with T0, with ORI to
SR, and checks that the next instruction (not a change of flow) is traced, with
the frame's program counter and instruction address.

---

## ABCD, SBCD and NBCD on bytes that are not BCD

**PRM 4** defines the decimal instructions on packed BCD operands -- two digits
of 0 to 9 per byte -- and says nothing about a byte with a nibble of $A-$F. The
result and the X and C bits are then undefined by the manual.

**What this design does:** its decimal adjust (`rd68031_seq`, `bcd_*`) treats a
result outside $00-$99 as a decimal carry or borrow: SBCD, after the low digit's
correction, takes a difference that is below zero *or above $99* as a borrow,
adds $A0, and sets X and C. For BCD operands the difference is never above $99
and the two conditions are one. On non-BCD operands the part, as the cputest
corpus records it, borrows only when the subtraction goes below zero, and keeps
the high digit as it fell.
The four cases in the default sample (`make cputest`, all SBCD, `doc/m6-mismatches.md`
class c):

| Test | Operands (destination - source - X) | Core | Corpus (the part) |
|---|---|---|---|
| `SBCD D6,D4` | $D5 - $10 - 1 | $64, X = C = 1 | $C4, X = C = 0 |
| `SBCD -(A6),-(A7)` | $D3 - $00 - 1 | $72, X = C = 1 | $D2, X = C = 0 |
| `SBCD D7,D2` | $FF - $24 - 0 | $7B, X = C = 1 | $DB, X = C = 0 |
| `SBCD D6,D3` | $FF - $04 - 0 | $9B, X = N = C = 1 | $FB, X = C = 0 |

**Why it is allowed:** the user decided, after phase B of M6-M7, to follow the
manual rather than match the part on these bytes. The operands are outside the
instructions' domain, and
every valid BCD operand gives the part's result -- the sweep feeds only decimal
digits and passes, as does the rest of the corpus's ABCD, SBCD and NBCD sample.
A program relying on the part's behaviour here relies on something the manual
does not promise.

**How it is checked:** the sweep checks every decimal-digit operand.
`tools/cputest/convert.py` excludes, before sampling, every ABCD, SBCD and NBCD
test with an operand byte that is not BCD -- reading the register, or the byte at
the predecremented address (computed from the registers, since with Ax = Ay the
corpus records one address for both operands) -- and counts them as tests "whose
result the manual leaves undefined". With `CPUTEST_SEL=ABCD,SBCD,NBCD`, 416 tests
are excluded and the 61 sampled pass; the default `make cputest` then passes in
full: 6,639 of 6,649, the other 10 being LINK A7, set aside above.
