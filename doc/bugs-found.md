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
