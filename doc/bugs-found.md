# Every defect found in this design, and what stops it coming back

One entry per defect: what it was, what found it, and the test that now fails if it
returns. Kept because the *way* each one was found is the useful part — a defect
found by one thing would usually have survived all the others.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/bugs-found.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---

## M1 · DBEN was active high on the pin

**What:** the bus unit drove `dben_o` high to enable the data buffers. DBEN is
active low on the MC68030 (UM Table 5-2, "Data Buffer Enable ... Output, Low") and
was on the MC68020 too; RD68021 carried the inverted pin from its first bus
milestone, and its own ruler testbench encoded the inversion as the expected
pattern.

**Found by:** reading Table 5-2 while renaming the pin to `dben_n_o`, as the
MC68030 port list in `doc/pinout.md` has it.

**Fixed by:** `dben_n_o`, active low, and the expected patterns in `bus_ruler_tb`
and the event polarity in `rd68031_timing_tb` inverted to match.

**Stops it coming back:** `bus_ruler_tb`, `bus_sync_tb` and `bus_burst_tb` all
check DBEN's level tick by tick against UM 7.1.6, 7.3.4 and 7.3.7, as the pin.

---

## M1 · The strobes were decoded from a multi-bit state, and glitched

**What:** AS, DS, DBEN, ECS, OCS and the write-data enable were combinational
decodes of the two bus-state registers. A decode of a multi-bit register is true
for an instant of any code a transition passes through, so it glitches whenever
two state bits change on one edge and an intermediate code is in the decoded set.
The asynchronous cycle already had such transitions — S2 to S4 changes two bits
and can pass through S0, which ECS, OCS, DBEN and the data enable all decode — and
the burst states added more: BL to BW, inside the set AS is asserted in, changes
two. No encoding can avoid it: the transitions inside AS's set include two
triangles (S1–S3–BL and S3–WL–BL), and a triangle does not fit in a hypercube.

**Found by:** `bus_burst_tb`, whose waited burst counted two bus cycles where there
was one. iverilog evaluates each term of `(st_n == ST_BW) || (st_n == ST_BL)` as a
net of its own, so AS went high for zero time between BW and BL and the harness's
AS counter saw a second cycle. The hazard was there before; the burst made a
simulator show it.

**Fixed by:** every strobe from a flip-flop: AS, DS and CBREQ are falling-edge
registers of the decode applied to the next state, ECS and OCS a rising-edge
register gated by the single term `st_n != S1`, the data enable a rising-edge
register, and DBEN, the one strobe that moves on both edges, `rd68031_dedge_ff` —
which existed for exactly this and was not being used.

**Stops it coming back:** the harness's AS counter in every bus testbench, which a
zero-width glitch on AS increments, and `bus_burst_tb`'s cycle counts on waited
bursts; `doc/coding-standard.md` now says a pin must come from a flop.

---

## M1 · The trace exception traced itself

**What:** with T1 set, the instruction-boundary decode at the end of a trace
exception's own processing was judged against the trace mode latched at the
boundary that started it — the traced instruction's, T1 still set — so it took a
second trace exception, and a second format $2 frame with the handler's address
in it went on the stack before the handler ran. UM 8.1.7: the trace exception
processing clears the trace bits, and the handler's first instruction is the
first that could be traced. An interrupt taken at a boundary had the same flaw
with an instruction that had just set T1.

**Found by:** `core_status_tb`, counting STATUS indications. Table 12-4 asserts
STATUS for two clocks at a boundary where a trace is taken, and a single traced
MOVEQ gave two of them. `core_exc_tb` checked the first frame and the handler's
result, both of which were right.

**Fixed by:** the decode arm marks what it starts as not traced (`notrace_q`) when
what it starts is the trace or the interrupt exception rather than an
instruction.

**Stops it coming back:** `core_status_tb` checks for exactly one two-clock STATUS
indication and exactly one trace frame, with nothing below it on the stack.

---

## M1 · The bus harness left four of the bus unit's inputs floating

**What:** `rd68031_bus_harness.svh` did not connect `req_cpfault`, `req_post`,
`rst_cancel` or `rst_post`, which iverilog floats to z. The posted-write
bookkeeping therefore ran on x in every bus testbench: `op_posted` was x, so was
`req_ack`'s "not posted" term, and the tests passed because `@(posedge req_ack)`
also fires on 0 to x.

**Found by:** connecting the MC68030's new request ports by name, which meant
reading the instantiation port by port.

**Fixed by:** every input connected, tied to its inactive value, and every output
named, if only to leave it open.

**Stops it coming back:** nothing automatic for a testbench — iverilog does not
warn about an unconnected input. The rtl/ side is covered by Verilator's
`PINMISSING` under `make lint`.

---

## M2 · BGACK alone did nothing: no single-wire arbitration

**What:** the arbiter left state 0 only on BR. Figure 7-61 also goes from state
0 to state 4 on BGACK, whatever BR is — "as shown by the path from state 0 to
state 4, BGACK alone can be used to place the processor's external bus buffers
in the high-impedance state, providing single-wire arbitration capability"
(UM 7.7.4). An alternate master using it, which "waits for AS to negate before
taking the bus", drove the bus while the processor still drove it, and the
processor went on starting cycles under it. During a read-modify-write the
release, once the arc was there, still waited for RMC to negate, which inside
the sequence it never does (`doc/manual-contradictions.md`, 7). Inherited
from RD68021, which recorded two of the figure's seven states as unreadable.

**Found by:** rendering figure 7-61's page as an image rather than reading its
text layer, which loses the overbars. Every label was then legible, and the
0-to-4 arc and states 5 and 6 were plain.

**Fixed by:** the seven states of the figure, arc for arc (`rd68031_biu`), and
the release not waiting for RMC when BGACK is asserted.

**Stops it coming back:** `bus_arb_tb`'s single-wire cases — an idle bus, a
cycle, a read-modify-write, a burst — and the state 6 to 3 case.

---

## M2 · The re-grant pulsed BG while the old master still held the bus

**What:** with BR still asserted when BGACK came — a second master on the
wire-ORed request — the five-state arbiter went from state 4 back to state 1,
then 2; state 2 leaves on "A is asserted", and A was still asserted by the
first master, so BG was negated again two clocks later, and again, for as long
as the first master kept the bus. The second master saw a train of two-clock
grants rather than one held until it could take over. Figure 7-61's states 5
and 6 exist for exactly this: 6 holds G while A stays asserted and passes to 2
only once A negates.

**Found by:** the same rendering of figure 7-61.

**Fixed by:** states 5 and 6.

**Stops it coming back:** `bus_arb_tb`'s re-grant case, which holds BGACK from
one master for eight clocks with BR still asserted and checks BG throughout,
then the hand-over to the second.

---

## M2 · HALT asserted on an idle bus did not stop the next cycle

**What:** the bus unit consulted HALT only at the end of a cycle. With the bus
idle when HALT came, the next request started a cycle anyway, and the bus
halted only after it. UM 7.5.3: "the MC68030 halts external bus activity at the
next bus cycle boundary" — and single-stepping (figure 7-57) is built on HALT
being asserted between cycles. Fixing it exposed a second fault behind it: the
arbiter deferred a grant while the bus unit "has made an internal decision to
execute a bus cycle", and with HALT holding a pending request off, that
decision was never made and never unmade, so BR was never granted.

**Found by:** writing `bus_error_tb`'s single-step case from figure 7-57.

**Fixed by:** HALT, synchronised, in the condition for starting any cycle, and
in the arbiter's deferral.

**Stops it coming back:** `bus_error_tb`'s "HALT asserted on an idle bus" and
single-step checks; `bus_arb_tb`'s "halted on an idle bus with a request
pending".

---

## M2 · Relinquish and retry did not relinquish on a read-modify-write's first read

**What:** the RMC lock masked BR from the first cycle of a locked run on, so
BERR, HALT and BR on its first read were a plain retry and the alternate master
waited out the whole sequence. UM 7.7.4 makes that read the one exception: "the
MC68030 allows normal bus arbitration during this read cycle; a normal
relinquish and retry operation ... is used"; 7.5.2, "except during the first
read cycle" (`doc/manual-contradictions.md`, 6).

**Found by:** reading 7.7.4 against the RMC inhibit while extending
`bus_arb_tb`.

**Fixed by:** `rmc_first_q`, set for the first bus cycle of a locked run and
kept through its retries; while that cycle waits to be retried the lock does
not hold the bus.

**Stops it coming back:** `bus_arb_tb`'s relinquish and retry on the first read
(BG asserted, the bus released, the rerun asserting RMC) and on the write (BG
never asserted while RMC is).

---

## M3 · The port size was read from DSACK on the edge that recognised it

**What:** the bus unit captured DSACK1 and DSACK0 into one flop pair on the
falling edge that first saw either, and took the port size from that capture.
MC68030EC specification 31A lets the second DSACK trail the first by up to
10 ns at 20 MHz and 3 ns at 50 MHz, and footnote 3 asks only that "#47A must be
met by DSACK0 or DSACK1" — one of them. So a 32-bit port whose DSACK1 trailed
its DSACK0 by a legal nanosecond was recognised on the edge as an 8-bit port: a
long word became four byte cycles, the operand engine assembled the bytes from
the wrong lanes, and nothing reported an error. The comment above the capture
cited 31A as the reason for capturing both bits together, which prevents a
torn sample but not a late one. Inherited from RD68021, whose own 31A says the
same.

**Found by:** M3's re-reading of 31A and its footnote against the MC68030EC
data sheet, which M1 had flagged; then the new skew test in
`rd68031_timing_tb`, which failed at every grade with the old capture
("a skew of 19.0 ns gave the wrong port size or data" at 50 MHz).

**Fixed by:** the cycle still terminates on the edge either DSACK is first
recognised on (UM 7.3.1 state 3), but the port size is taken one clock later, on
the falling edge that latches the data, when both have arrived and the device
still holds them — it keeps DSACK "asserted until it detects the negation of AS"
(UM 7.3.1 state 5), which is that edge. In the half clock before it, `early_q`
reads the pins directly; nothing on a rising edge does.

**Stops it coming back:** `make timing`'s skew test, DSACK0 first and DSACK1
first, a clock less a nanosecond apart, at every grade; specification 31A fails
if the long word does not arrive whole in one cycle.

---

## M3 · The end of a retry read BERR and HALT on the rising edge

**What:** a retry waits for BERR and HALT both to be negated, and the bus unit
tested that with the raw pins, in the next-state logic of its rising-edge state
register. Both are asynchronous inputs: UM 7.1 latches them "during a sample
window around the falling edge of the clock", specifications 47A and 47B bound
them only there, and UM 7.5 even recommends that a device move them "with the
rising edge". So the one place the core read them was the one instant a
compliant device may be changing them — in silicon, a metastable input to a
multi-bit state register. In simulation it was a race between the testbench's
assignment and the flop.

**Found by:** the input probes of `rd68031_timing_tb`. The retry probe negates
BERR and HALT half a nanosecond either side of a falling edge and times the
rerun; the core reran at the same instant both times — the sample was not at
that edge — and 47A and 47B failed at every grade.

**Fixed by:** `retry_clr_q`, a falling-edge register of "both negated", which
the rising-edge logic reads. No synchroniser rank is added; the rerun is at most
half a clock later than before. `bus_error_tb`, `bus_arb_tb` and `bus_burst_tb`
pass unchanged.

**Stops it coming back:** the `retry_negate` probe, checked against 47A and 47B
at every grade.

---

## M3 · IPEND was combinational and moved on both edges

**What:** `ipend_n_o` was the inverted output of a comparison between the
synchronised interrupt level, a falling-edge register, and the mask in `sr_q`, a
rising-edge one. So it moved on falling edges when a level arrived and on rising
edges when the mask changed, where MC68030EC specification 6 times IPEND from
"Clock High", with the address; and a comparison of several bits of each could
glitch on any edge that changed two of them, which is the decode
`doc/coding-standard.md` forbids on a pin.

**Found by:** going through specification 6's signal list for M3; IPEND is the
one pin it names that the bus unit does not own.

**Fixed by:** `ipend_q`, a rising-edge register of the same comparison. The
sequencer acts on `irq_pending`, not on the pin, so nothing else moves.

**Stops it coming back:** `core_exc_tb` checks every change of IPEND over the
whole run falls on a rising edge, and that it changes at all. Run against the old
combinational pin, it fails: IPEND moved on a falling edge nine times.

---

## M4 · RTE never compared the version number

**What:** UM 8.1.8: "for long bus cycle fault format frames, the RTE instruction
also compares the internal version number of the processor to that contained in
the frame at memory location SP+54 (SP+$36)", and takes a format error if they
differ. RTE read `+$36` back into the trace-mode, flow and `pc_kept` bits it
carries and went on: a long frame with any version at all was restored. The
frame builder wrote the nibble; nothing read it. `doc/checkpoint.md` had said,
since RD68021's M4, that "RD68021 therefore carries its own version number and
refuses any other with a format error" — the document was right about the
contract and wrong about the design, and RD68021 has the same defect.

**Found by:** re-deriving the checkpoint freeze from UM 8.1.8 and 8.1.13 at M4,
and grepping the RTL and the microcode for the place that compared the nibble.
There was none, and no test had ever handed RTE a frame with another one.

**Fixed by:** `rte_check_long` in `tools/ucode/program.py`: before the walk, RTE
reads `+$36` into the extension-word latch and the condition `VERBAD` sends a
mismatch to the format error, which stacks the RTE's own address below the
untouched frame. The version is now this design's own, `$3`, rather than
RD68021's `$1`.

**Stops it coming back:** `core_fault_tb`'s "version" case: a handler changes
the nibble, RTE must take a format error with the RTE's address in a four-word
frame below the intact long one, and the format error's handler puts the nibble
back and RTEs again to finish the faulted read.

---

## M4 · RTE restored before it knew the frame was all there

**What:** UM 8.1.13: "The RTE instruction also reads from both ends of the stack
frame to make sure it is accessible. If the frame is invalid or inaccessible,
the processor takes a format error or a bus error exception, respectively." RTE
read the format word and then walked the frame from `+$02` upward, writing each
field into its register as it went, so a long frame whose top was on a missing
page faulted part-way through — with the program counter, the pipe and the
special status word already put back, and the new frame describing a machine
that was neither the handler's nor the faulted program's.

**Found by:** reading UM 8.1.13 for the freeze's rule on what RTE checks.

**Fixed by:** `_far_end` in `tools/ucode/program.py`, for both bus fault
formats: before anything is restored, RTE reads the frame's last word. A bus
error there is an ordinary data fault on a microword that has committed nothing
(`doc/checkpoint.md` rule 2), and RTE goes on from it when its handler returns.

**Stops it coming back:** `core_fault_tb`'s "far end" case: the stack straddles a
page that goes away once the frame is on it; RTE must fault on `+$5A` with the
first frame intact and the RTE's own address in the new one, and finish both
when the page comes back.

---

## M4 · RTE read a short frame's internal words

**What:** RTE out of a format `$A` frame read `+$08`, `+$14` and `+$16` — the
long frame's packed word, micro-address and stage D — as if this design had
written the frame. It never writes a short frame (`doc/divergences.md`), so one
RTE meets came from software or from another processor, and has no version
field to say whose its internal words are. The micro-address RTE resumed at was
whatever `+$14` held. `doc/checkpoint.md` rule 1 forbade private state in the
short frame and the check enforced it for the builder only.

**Found by:** reading the freeze's rule 1 against `rte_fault`, at M4.

**Fixed by:** `rte_fault_short`, a walk of its own that reads the architectural
fields alone and supplies what an instruction boundary implies: stage D is read
from memory at the program counter, in the stacked status register's program
space (`fc = FRAMEPROG`); `DF` on a write becomes a posted write of its own,
sized by `SIZE` (`dst = SSWA`); and it resumes at `rte_boundary`, a microword
that only decodes (`asrc = UBOUND`). `check_short_reads` in
`tools/ucode/assemble.py` fails the build if it ever reads an internal word.

**Stops it coming back:** `core_fault_tb`'s short-frame cases, built by hand with
internal words that would wreck the restore if read: images accepted, rerun bits
honoured, a byte write rerun at its size and address, and a user-mode frame whose
stage D is read in user program space.

---

## M4 · RTE's rerun prefetch ran in the handler's program space

**What:** UM 8.2.1: when RTE reruns a prefetch, "the address space for the bus
cycle is the program space for the privilege level indicated in the copy of the
status register on the stack". RTE writes the pipe's fill point before the
status register — it must write the status register last, because that moves
A7 — and the pipe started refilling the moment the fill point was written,
in the space the status register still named: supervisor program, for a fault
taken in user mode. A memory system that keeps the spaces apart would have
refused the fetch, or answered it from the wrong map.

**Found by:** a check added at M4 to `core_fault_tb`'s "resumed into RTS" case,
recording the function code of the rerun prefetch of the faulted page: 6, where
the stacked status register said user. A probe of the same run showed the
fetch issued with the status register still `$2008`.

**Fixed by:** `ckpt_hold`, from the sequencer to the fetch unit: set when RTE
writes the fill point, cleared when its RESUME — which follows the status
register — commits, or by a fault. The pipe asks for nothing while it is set.

**Stops it coming back:** `core_fault_tb` checks the space of the rerun prefetch
after a long frame and of the refill after a short one, both returning to user
mode.

---

## M4 · Two testbenches counted their checks before their last cases

**What:** `core_fault_tb` and `core_exc_tb` printed "N checks, M failed" before
their posted-write cases, which had been appended after the line; the count was
not the total, though PASS and FAIL were still decided on all of them.

**Found by:** adding cases at the end of both at M4.

**Fixed by:** the summary line moved to the end of each.

**Stops it coming back:** nothing but reading the log; the counts in
`doc/checkpoint.md` are taken from it.

---

## M5 · CALLM and RTM ran

**What:** the decoder sent `$06C0`-`$06FF` to the MC68020's module-call
microcode, with its access-level cycles in CPU space type 1. Neither instruction
exists on the MC68030 (PRM 4 heads both "(MC68020)"; `instructions-by-cpu.csv`),
and UM 8.1.5 makes a first word that is no MC68030 instruction's an illegal
instruction; UM figure 7-42 implements no CPU space type 1.

**Found by:** the M5 comparison of the MC68020 and MC68030 columns of
`instructions-by-cpu.csv`, which the plan had already named.

**Fixed by:** both encodings decode to `exc_illegal`; the microcode, the seven
conditions, the two ALU operations, the `RTM_XW` source and the `ACCESS` CPU
space that only they used are gone, from `tools/ucode/isa.py` and from the RTL.

**Stops it coming back:** `core_insn_tb` and `core_m030_tb` take CALLM and RTM
as illegal instructions, in both modes, and check the four-word frame.

---

## M5 · A CpID-0 word in user mode took an F-line exception

**What:** every F-line word with CpID 0 went to the F-line exception -- through
the decode table with the coprocessor interface built, and through the
decoder's F-line short cut without it. On the MC68030 CpID 0 is the MMU's: UM
9.8 and 8.1.5 make every CpID-0 word a privilege violation in user mode, and
the four MMU instructions are privileged (UM 8.1.6), so a user program that
tried one was told it was unimplemented rather than privileged.

**Found by:** reading UM 9.8, 8.1.5 and 10.1 for the CpID-0 change M5 calls for.

**Fixed by:** CpID 0 goes to the decode table whatever `COPROCESSOR` is, and to
`mmu_op` or `cp0_unimp`, both of which test the S bit before anything else
(`doc/coprocessor.md`).

**Stops it coming back:** `core_m030_tb` runs CpID-0 words of each kind in user
and supervisor mode, with and without the interface built (`make sim
COPROCESSOR=1`), and counts the CPU-space cycles addressed to CpID 0: none.

---

## M5 · CACR kept two bits

**What:** MOVEC to CACR stored E and F of the MC68020's layout (UM20 figure 4-2)
and dropped the rest. The MC68030's CACR also keeps WA, DBE, FD, ED and IBE (UM
6.3.1, figure 6-14), so a MOVEC from CACR read back zero where the part reads
what was written.

**Found by:** comparing UM figure 6-14 with `rd68031_pkg`'s CACR constants.

**Fixed by:** `CACR_IMPLEMENTED` is `$3313` and the bits have the MC68030's
names; the instruction cache's are where they were.

**Stops it coming back:** `core_m030_tb`'s three CACR round trips.


---

## M6 · CAS and CAS2 wrote a failed compare into the whole data register

**What:** when the comparison failed, `CAS.B`, `CAS.W` and `CAS2.W` put the
memory operand into the compare register Dc through `DST_DREG_XR`, which wrote
all thirty-two bits: D2 = $3E05A9F4 and a byte $19 left $00000019. PRM 4, CAS:
"Destination → Compare Operand", at the operation's size, and UM 2.2.1: a byte or
word operation changes "only the appropriate low-order byte or word" of a data
register. Inherited from RD68021.

**Found by:** `make vectors-all` (the `cas` group: 45 CAS.B, 45 CAS.W, 9 CAS2.W)
and the cputest corpus (CAS.B, CAS.W, CAS2.W) -- `doc/m6-mismatches.md` A1.

**Fixed by:** `DST_DREG_XR` writes at the effective size, as `DST_DREG` does. Its
other users -- the long multiplies and divides -- are long word microwords.

**Stops it coming back:** the `cas` group of the sweep; `core_insn_tb`'s CAS.B,
CAS.W and CAS2.W failed compares, which check the upper bits.

---

## M6 · BFFFO summed the register offset modulo 32

**What:** `BFFFO <ea>{Dn:w},Dm` with the field in a data register returned the
offset modulo 32 plus the bit position: D0 = $FEB7AFF7 gave $00000017 where PRM 4
gives "the bit offset in the instruction plus the offset of the first one bit",
and a register offset is "in the range of -2^31 to 2^31 - 1". RD68021 chose the
reduced offset on purpose, reading a gap in the manual (its
`doc/manual-contradictions.md`); `doc/manual-contradictions.md` entry 14 here
says why that reading is withdrawn.

**Found by:** `make vectors-all` (18 vectors of the `bitfield` group) and the
cputest corpus -- A2.

**Fixed by:** `BF_FFO` is the whole offset plus the position, register field or
memory field; the reduction stays where it belongs, in locating the field.

**Stops it coming back:** the `bitfield` group; `core_insn_tb`'s BFFFO with
offsets 37 and -27 and with an empty field.

---

## M6 · CMP2, CHK2 and the read-only bit fields read (d16,PC) in data space

**What:** CMP2 and CHK2 read their bounds pair with the function code fixed at
data space, so `CMP2.B (d16,PC),D2` read program-relative bounds as FC 5. UM
2.4.11-2.4.15: every program-counter-relative reference "is a program space
reference". Reading the microcode for it found the same fixed code on the memory
read of BFTST, BFEXTU, BFEXTS and BFFFO, which PRM 4 also allows PC-relative.
Inherited from RD68021.

**Found by:** `make vectors-all` (24 vectors of the `cmp2` group) -- A3; the bit
fields by reading the microcode while fixing it, since the sweep's bit-field
groups do not use the PC-relative modes.

**Fixed by:** those reads take `fc = EASP`, the space of the effective address
under way, as every other read-only operand does.

**Stops it coming back:** the `cmp2` group; `core_insn_tb` checks, from the
operand-access recorder, that CMP2.B (d16,PC) and BFTST (d16,PC) read in program
space.

---

## M6 · MOVEM to -(An) stored An's initial value

**What:** with An in the list, MOVEM to -(An) wrote An as it was before the
instruction. PRM 4, MOVEM: "For the MC68020, MC68030, MC68040, and CPU32, if the
addressing register is also moved to memory, the value written is the initial
register value decremented by the size of the operation. The MC68000 and MC68010
write the initial register value (not decremented)." The core did the MC68010's.
Inherited from RD68021.

**Found by:** `make vectors-all` (4 vectors of the `movem` group) and the cputest
corpus -- A4.

**Fixed by:** the register source the predecrement form walks with (`REGNR`)
gives An less the operand size when the register it names is the addressing
register; An is not written until the loop is over, so that is the initial value
less two or four.

**Stops it coming back:** the `movem` group; `core_insn_tb`'s MOVEM.L and MOVEM.W
D0-A7,-(A3).

---

## M6 · A divide by zero left C as it was

**What:** DIVU and DIVS with a zero divisor took the zero-divide exception with
the condition codes untouched, so the stacked SR carried a C that was set before
the instruction. PRM 4: "C -- Always cleared", with no exception for a zero
divisor (only N, Z and V are "undefined" then). Inherited from RD68021.

**Found by:** `make vectors-all` (the `traps` group's DIVU.W #0) -- A5.

**Fixed by:** the first microword of `exc_divzero`, before the status register is
copied, clears N, Z, V and C and leaves X (`CLRNZVC`).

**Stops it coming back:** the `traps` group; `core_insn_tb`'s DIVU.W #0 with C set
reads the stacked SR.

---

## M6 · The A7 byte rule was applied to the wrong register, or to none

**What:** UM 2.4.4 and 2.4.5 step the stack pointer by two for a byte through
(A7)+ or -(A7). In the two-register memory forms the rule belongs to whichever of
Ax and Ay is A7. ABCD and SBCD -(Ay),-(Ax) stepped both registers by one; ADDX.B,
SUBX.B and CMPM.B stepped Ax by two when Ay was A7 and by one when Ax was. So
`ABCD -(A6),-(A7)` left A7 odd and `ADDX.B -(A7),-(A6)` moved A6 by two. The
operand-size source applied the rule from the effective-address register field
(Ay), and the BCD forms did not use it. Inherited from RD68021.

**Found by:** the cputest corpus (ABCD, SBCD, ADDX.B, SUBX.B, CMPM.B with A7) --
A6. The sweep's `extend` and `bcd` groups never use A7 in these forms.

**Fixed by:** a second operand-size source, `OPSIZEW`, which applies the rule from
the register bits 11:9 name (Ax); every Ax step uses it, and the BCD forms step
by the operand size instead of a constant one.

**Stops it coming back:** `core_insn_tb` runs ABCD, ADDX.B, CMPM.B both ways and
SBCD -(A7),-(A7), and checks each register's step.

---

## M6 · BTST Dn,#<data> was an illegal instruction

**What:** PRM 4, BTST: the dynamic form's addressing-mode table lists #<data> --
the only bit instruction that has it. The decoder sent it to the memory form,
whose addressing-mode dispatch has no immediate, so it took vector 4. Inherited
from RD68021.

**Found by:** the cputest corpus -- A7; the sweep's `bit` group did not emit it
and now does.

**Fixed by:** a pattern for `0000 ddd1 0011 1100` ahead of BTST Dn,<ea>, and
three microwords: the immediate byte from the low half of the extension word,
the bit modulo eight, the end.

**Stops it coming back:** the `bit` group (12 vectors); `core_insn_tb`'s two
BTST Dn,#$A5.

---

## M6 · cpSAVE and cpRESTORE took an F-line exception in user mode without a coprocessor interface

**What:** built without the interface (`COPROCESSOR=0`, the default), every
F-line word with a CpID other than zero went to the F-line exception -- including
cpSAVE and cpRESTORE in user mode, which UM 10.2.3.3 and 10.2.3.4 make a
privilege violation "without accessing any of the coprocessor interface
registers": the check comes first, and does not depend on there being an
interface. Inherited from RD68021.

**Found by:** the cputest corpus (`$F557`, cpRESTORE (A7), user mode) -- A8.

**Fixed by:** with no interface built, the two operation words go, when the
decode table accepts their effective address, to `cp_nocp_priv`: a privilege
violation in user mode and the F-line exception in supervisor mode. With the
interface built, `cp_save` and `cp_restore` already tested the S bit first.

**Stops it coming back:** `core_insn_tb`'s user-mode cpSAVE -(A7) and cpRESTORE
(A7), in both builds (`make sim` and `make sim COPROCESSOR=1`).

---

## M6 · Effective addresses an instruction does not have were found too late

**What:** the opcode patterns took every mode, and the addressing-mode table --
consulted when the instruction asks for its address -- refused only the modes no
instruction computes an address from. Two kinds of illegal word therefore ran:
an alterable destination given a PC-relative mode computed the address and wrote
there (`EOR.B D7,(d8,PC,Xn)` never came back at all), and MOVE, which evaluates
its source first, found a non-existent destination only after the source had
been read and an (An)+ stepped (`$1BDA` incremented A2 and set Z before taking
vector 4). UM 8.1.5: an illegal instruction is found at decode and nothing is
executed. Inherited from RD68021.

**Found by:** the cputest corpus -- A9.

**Fixed by:** `tools/ucode/program.py` puts refusal patterns, to `exc_illegal`, in
front of each pattern that would otherwise claim the words: the two PC-relative
modes for every instruction whose <ea> is written (PRM 4 and 6: data, memory or
control alterable), and for MOVE the destinations 111/010-111 and, for MOVE.B,
An. A refusal is inserted only where it takes something no earlier pattern
claims, so TRAPcc and cpTRAPcc, which own the Scc and cpScc PC-relative slots,
are untouched.

The same mechanism refuses (An)+ and -(An) for the instructions whose operand
is a control address (PRM 2.2) -- JMP, JSR, LEA, PEA, CMP2/CHK2, the bit fields
in memory and MOVEM's control forms -- which the table would otherwise compute,
stepping the register: `BFCLR -(A3)` (`$ECE3`, from the corpus's ILLEGAL set)
never came back. And it refuses An as a byte operand of ADD, SUB, CMP, ADDQ and
SUBQ, which PRM 4 gives word and long forms only.

**Stops it coming back:** `core_insn_tb` runs `$1BDA`, `EOR.B D7,(d8,PC,Xn)`, a
MOVE.B to An, `BFCLR -(A3)`, `LEA (A3)+,A0`, `ADDQ.B #1,A3` and `ADD.B A3,D0`,
and checks the frame and that no register was touched.

---

## M6 · CHK2.B and CMP2.B through A7 read the upper bound at A7+2

**What:** the step from the lower to the upper bound used the operand size with
the A7 byte rule, so through any mode based on A7 -- (A7), (d16,A7) -- a byte
pair was read at A7 and A7+2. The rule is for stepping the register through
(A7)+ and -(A7) (UM 2.4.4, 2.4.5); PRM 4 puts the bounds at consecutive
operand-sized locations. Inherited from RD68021.

**Found by:** the cputest corpus (`CHK2.B (A7),D0`, `CHK2.B (d16,A7),D0`) -- A11,
confirmed by `core_insn_tb`, which failed on it before the fix.

**Fixed by:** a third operand-size source, `OPBYTES`, with no A7 rule; CMP2 and
CHK2 step between the bounds by it.

**Stops it coming back:** `core_insn_tb`'s CHK2.B (A7),D0, in and out of bounds.

---

## M6 · UNLK A7 left the stack pointer stepped past the long word

**What:** UNLK read the saved frame pointer into An and then wrote SP = An + 4.
For UNLK A7 the last write won, so A7 ended as the old stack pointer plus four.
PRM 4's description makes the address register the last thing loaded -- "loads
the address register with the long word pulled from the top of the stack" --
and its operation line, read literally, ends on the long word plus four; the
core gave neither. Inherited from RD68021.

**Found by:** the cputest corpus (`$4E5F`) -- `doc/m6-mismatches.md` Q3, settled
in `doc/manual-contradictions.md` entry 16.

**Fixed by:** UNLK steps the stack pointer first and loads An last, from the read
itself.

**Stops it coming back:** `core_insn_tb`'s UNLK A7.

---

## M6 · CAS2 with one compare register for both kept memory operand 2

**What:** a failed CAS2 wrote memory operand 1 into Dc1 and then memory operand 2
into Dc2, the order of the operation line, so with Dc1 = Dc2 the register ended
holding operand 2. PRM 4, CAS2, on the Dc1 and Dc2 fields: "If Dc1 and Dc2
specify the same data register and the comparison fails, memory operand 1 is
stored in the data register." Inherited from RD68021.

**Found by:** the cputest corpus (`CAS2.L D3:D3,D2:D6,(A7):(A6)`, `0EFC F083
E183`), once A1 was fixed and the comparison of the compare registers reached
it.

**Fixed by:** `cas2_fail` writes Dc2 first and Dc1 last.

**Stops it coming back:** `core_insn_tb`'s failed CAS2.L D3:D3.
