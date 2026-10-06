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
