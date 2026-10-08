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

What remains:

- **The ATC miss** is M11's: there is no ATC yet.
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
  assertion" (UM 7.7). TC.E, TT0.E and TT1.E are M11's, which builds the
  registers and adds them to the same reset (`doc/plan.md`).
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
RESET instruction against a RESET from outside.

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

## The MMU instructions take an F-line exception in supervisor mode (until M11)

**UM 9.8 and PRM 6:** PMOVE, PTEST, PLOAD and PFLUSH (with PFLUSHA) are
privileged instructions that move MMU registers, search and load the address
translation cache, and flush it. UM 8.1.5: "Instructions that have word patterns
with bits [15:12] equal to $F, bits [11:9] equal to $0, and defined word patterns
for subsequent words are legal MMU instructions."

**What this design does:** the decoder sends their first words -- CpID 0, type
000, an effective address field of zero or control alterable -- to `mmu_op` in
`tools/ucode/program.py`. In user mode that is a privilege violation, vector 8,
as the part does (UM 8.1.6, 9.8). In supervisor mode it is an F-line exception,
vector 11, with the instruction's own address in a four-word frame: what the
part does for a CpID-0 word whose command word it does not define, applied to
every one, because there is no MMU yet to execute them. M11 builds the MMU and
replaces the stub with the instructions. Every other CpID-0 word is final
already: a privilege violation in user mode and an F-line exception in
supervisor mode (`cp0_unimp`).

**Why it is allowed:** it is not; it is provisional. An operating system that
runs with translation disabled and never executes an MMU instruction sees no
difference; one that does gets an F-line exception, which a handler can
recognise and emulate. M11's gate (`core_mmu_tb`, `make cosim-mmu`) retires
this entry.

**How it is checked:** `core_m030_tb` runs every MMU instruction form the
assembler produces for `-mcpu=68030` -- PMOVE to and from TC, CRP, MMUSR and TT0,
PFLUSHA, PFLUSH by function code and by address, PTESTR, PTESTW with an address
register, PLOADR and PLOADW -- in supervisor mode and three of them in user
mode, and checks the vector, the stacked program counter and the stacked S bit
of each.

---

## CACR's data-cache and burst bits are stored and do nothing (until M10)

**UM 6.3.1 and figure 6-14:** WA selects write allocation, DBE and IBE enable
burst filling of the data and instruction caches, ED and FD enable and freeze
the data cache, and CD and CED clear all of it or the entry CAAR names.

**What this design does:** a MOVEC to CACR keeps WA, DBE, FD, ED, IBE, FI and EI
and reads them back, and reads every reserved bit and the four clear bits as
zero, as the figure says. EI, FI, CI and CEI act on the instruction cache, with
the meanings the MC68020's E, F, C and CE had in the same bit positions (UM20
figure 4-2) -- CEI clears the one long word CAAR's index names, which is the
MC68030's granularity too (UM 6.3.1.9). The other seven do nothing yet: there is
no data cache, and neither cache asks for a burst (`req_burst` and `fetch_burst`
are tied off in `rd68031_top`), so CBREQ is never asserted by a running program.
The instruction cache is still the MC68020's 64 long words rather than the
MC68030's 16 lines of four. M10 builds the data cache, reorganises the
instruction cache and connects the burst requests.

**Why it is allowed:** a disabled or absent data cache is architecturally a
cache that never hits, and the part's caches are allowed to be disabled; a
program that set ED or DBE runs correctly and only more slowly. What a handler
can observe -- the value MOVEC reads back -- is the part's.

**How it is checked:** `core_m030_tb` writes all ones, a mixture, and zero to
CACR and checks `$3313`, `$2211` and zero back, and CAAR's thirty-two bits;
`core_cache_tb` checks EI, FI, CI and CEI against the cache; `core_m030_tb`
reports the burst requests a program made on a burst-capable port, today none.

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
