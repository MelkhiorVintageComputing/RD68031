# What the bus unit does on the pins

The state-by-state behaviour of `rtl/rd68031_biu.sv`, with the citation for each
edge and the test that checks it. This is the document to argue with when a
behaviour is questioned. "UM" is the MC68030 user's manual
(`MC68030UM_split/`); "UM20" is the MC68020's, cited only where an inherited
behaviour has no MC68030 paragraph of its own.

As of M1 it covers the three kinds of bus cycle the MC68030 has — asynchronous
(DSACK), synchronous (STERM) and burst (CBREQ/CBACK) — with dynamic bus sizing,
misaligned operands, bus exception control, arbitration, CIIN/CIOUT, and the
emulator pins STATUS, REFILL and MMUDIS. The AC solver (`make timing`) still
judges the asynchronous cycle against the MC68020's Section 10 until M3.

## The ruler

UM 7.3 measures a bus cycle in states, **one per CLK half period**. Even-numbered
states begin on a rising edge, odd-numbered ones on a falling edge. The design is
two state registers, one per edge, each computing its next state from the other.

A cycle does not know what kind it is until it ends: "a synchronous read cycle is
terminated differently from an asynchronous read cycle; otherwise, the cycles
assert and respond to the same signals, in the same sequence" (UM 7.3.4). DSACKx
is sampled on the falling edges, STERM on the rising ones, and whichever is
recognised first decides.

**Every strobe is a flip-flop.** AS, DS and CBREQ are falling-edge registers, ECS
and OCS a rising-edge register gated by the single term `st_n != S1`, the write
data enable a rising-edge register, and DBEN — the one pin that moves on both
edges — `rd68031_dedge_ff`. Each is the registered value of its decode applied to
the next state, so the waveform is the one the tables below give, from a flop and
without the glitches a decode of a multi-bit state has (`doc/bugs-found.md`).

### Asynchronous cycle

| Edge | What moves | Source |
|---|---|---|
| rising → S0 | ECS asserted, and OCS with it on the first cycle of an operand; A31–A0, FC2–FC0, SIZ1/SIZ0, CIOUT driven; R/W set; RMC driven | 7.3.1/7.3.2 state 0, 7.1.1, specs 6, 6A, 18, 20 |
| falling → S1 | **AS** asserted; **DS** asserted on a read; **DBEN** asserted on a write; **CBREQ** asserted if this cycle may burst; ECS and OCS negated | 7.3.1/7.3.2 state 1, 7.1.5, 7.1.6, 7.3.4 state 1, specs 9, 12A, 42 |
| rising → S2 | **DBEN** asserted on a read; write data driven on D31–D0; **STERM tested** (not asserted: the cycle carries on) | 7.3.1 state 2, 7.3.2 state 2, 7.3.4 state 2, specs 40, 23 |
| falling → S3 | **DSACK1/DSACK0 sampled** — "as long as at least one of the DSACKx signals is recognized by the end of S2"; **DS** asserted on a write | 7.3.1/7.3.2 state 3, specs 47A, 47B |
| rising → S4 | **CIIN latched** — "on the rising edge of bus cycle state 4" | 7.2.8, 7.2.9, 7.3.1 state 4 |
| falling → S5 | **read data latched**; AS, DS and CBREQ negated; DBEN negated on a read; Table 7-8's second sample | 7.3.1 states 4 and 5, specs 27, 12, 41 |
| rising, ending S5 | address group and CIOUT released; write data released; DBEN negated on a write | 7.3.1/7.3.2 state 5, specs 7, 8, 43 |

A **wait state** is one whole clock inserted between S3 and S4, and the sample
repeats: "if wait states are added, the processor continues to sample the DSACKx
signals on the falling edges of the clock until one is recognized" (7.3.1 state
3). *n* waits make the cycle 3 + *n* clocks. The rising edge in each wait tests
STERM too, which is how a synchronous device's wait states fall out of the same
pair of states.

`sim/tb/bus_ruler_tb.sv` asserts every row as a seven-tick pattern from the
rising edge entering S0, and then the widths the pattern implies against UM20
Section 10's minima at 16.67 MHz — the numbers the AC solver still uses until M3:

| Spec | What | Minimum (UM20, 16.67 MHz) | This design |
|---|---|--:|--:|
| 10 | ECS width asserted | 20 ns | 30 ns |
| 11 | address valid to AS asserted | 15 ns | 30 ns |
| 14 | AS and DS width asserted (read) | 100 ns | 120 ns |
| 14A | DS width asserted (write) | 40 ns | 60 ns |
| 15 | AS, DS width negated | 40 ns | 60 ns |
| 22 | R/W low to DS asserted (write) | 75 ns | 90 ns |
| 26 | data-out valid to DS asserted | 15 ns | 30 ns |
| 44 | R/W low to DBEN asserted (write) | 15 ns | 30 ns |
| 45 | DBEN width asserted, read | 60 ns | 90 ns |
| 45 | DBEN width asserted, write | 120 ns | 150 ns |

**This is not the AC-timing conformance analysis.** An RTL model has no pad delays,
so the limits become a feasibility question instead, and that is `make timing` —
retargeted to the MC68030EC tables at M3.

### Synchronous cycle

STERM "indicates that the addressed port size is 32 bits and that data is to be
latched on the next falling clock edge for a read cycle" (UM 5.6.9). The manual's
synchronous S3 — "the processor negates AS, DS, and DBEN during S3" — is this
design's `ST_S5`, the half clock in which every cycle ends.

| Edge | What moves | Source |
|---|---|---|
| rising → S0, falling → S1 | as above | 7.3.4/7.3.5 states 0 and 1 |
| rising → S2 | **STERM, CBACK and CIIN sampled**; DBEN asserted on a read; write data driven | 7.3.4 state 2, 7.2.10, specs 60, 61 |
| falling → S3 | **read data latched**; AS, DS, CBREQ negated; DBEN negated on a read; **BERR and HALT sampled** — Table 7-9 | 7.3.4 states 2 and 3, 7.5.1 third case, specs 27, 27A |
| rising, ending S3 | address and data released; DBEN negated on a write; the next cycle may begin | 7.3.4/7.3.5 state 3 |

"If STERM is negated at the beginning of S2, wait states are inserted after S2,
and STERM is sampled on every rising edge thereafter" (7.3.4 state 2): with *n*
waits AS is asserted for 1 + *n* clocks and the cycle is 2 + *n*.

Two things differ from the asynchronous cycle, and both are checked:

- **DS is never asserted in a two-clock write** (UM 5.6.6, 7.3.5): the device
  latches with CLK. A waited synchronous write asserts DS "at the end of S2" —
  the edge the asynchronous write asserts it on — and negates it with AS.
- **DBEN is asserted for half a clock on a two-clock read**, S2 only. Specification
  45A asks more than that, which is what UM 5.6.7 means by "the timing of this
  signal may preclude its use in a system that supports two-clock synchronous bus
  cycles".

`sim/tb/bus_sync_tb.sv` (192 checks): the read and write patterns tick by tick; two
cycles back to back two clocks apart; zero to four wait states, reads and writes,
with the DS behaviour; every operand size and alignment against Table 7-6's
32-bit column, both directions, one OCS per operand; asynchronous and synchronous
operands alternating, and one operand split between a DSACK port and a STERM
port; Table 7-9's six cases; CIIN and CIOUT; and a STERM with no cycle in progress,
which "is ignored by the MC68030" (7.2.10).

### Burst

"When the MC68030 recognizes STERM and CBACK and it has asserted CBREQ, it
maintains AS, DS, R/W, A0-A31, FC0-FC2, SIZ0-SIZ1 in their current state
throughout the burst operation. The processor continues to accept data on every
clock during which STERM is asserted until the burst is complete or an abnormal
termination occurs" (7.3.7).

| Edge | What moves | Source |
|---|---|---|
| rising → S2 (or a wait) | STERM, **CBACK** and CIIN sampled | 7.3.7 state 2 |
| falling → S3 (`ST_BL`) | first long word latched; **AS, DS and DBEN held** if CBREQ, CBACK, no CIIN, no BERR | 7.3.7 state 3 |
| rising → S4 (`ST_BH`) | STERM tested for the second long word; CBACK and CIIN latched with it | 7.3.7 state 4 |
| falling → S5 (`ST_BL`) | second long word latched | 7.3.7 states 4, 5 |
| … S6, S7 | third long word; **CBREQ negated** "during S7" | 7.3.7 states 6, 7 |
| … S8, falling → S9 (`ST_S5`) | fourth long word latched; AS, DS, DBEN negated | 7.3.7 states 8, 9 |

A wait between long words is `ST_BW` and the rising edge after it tests STERM
again — "wait states are inserted instead of S4 and S5, and STERM is sampled on
every rising edge of the clock thereafter" (state 4).

The address is held: "if an external memory system requires incrementing of the
long-word base address ... this function must be performed by external
hardware", and the line wraps — "the count sequence wraps back to zero". The bus
unit reports each long word on its `beat_*` port with the address the system put
on A3/A2, for the caches of M10.

**What ends a burst early** (7.3.7, 6.1.3.2): CBACK negated — the current long
word "complete[s] normally" and the burst stops after it; CIIN — that long word is
latched and used but not cachable, and the burst stops; BERR — on the first access
a bus error, on a later one "the cache entry corresponding to that cycle is marked
invalid, but the processor does not take an exception" (7.5.1). BERR with HALT is
a retry on the first access, which "assert[s] CBREQ again", and on a later one "a
bus error condition, which aborts the burst operation. In addition, the processor
remains in the halted state until HALT is negated" (7.3.7, 7.5.2).

**A burst is never asynchronous.** "The MC68030 allows burst filling only from
32-bit ports that terminate bus cycles with STERM and respond to CBREQ by
asserting CBACK" (7.3.7), and "during any bus cycle terminated by DSACKx or BERR,
the assertion of CBACK is completely ignored" (7.2.8).

**Halt and arbitration see one cycle.** "For the purposes of halting the processor
or arbitrating the bus away from the processor with BR, a burst operation is a
single cycle since AS remains asserted during the entire operation" (7.3.7).

`sim/tb/bus_burst_tb.sv` (104 checks): a full burst with its pin timings (AS four
clocks, CBREQ three, DBEN from S2 to S9), the wrap, the address and SIZ held under
AS throughout, and the operand acknowledged after the first long word; figure
7-38's wait states; CBACK for one, two and three long words (figure 7-39); a STERM
device that does not burst and a DSACK device with CBACK asserted; CIIN on the
first and on the third long word (figure 7-41); a misaligned operand within the
line and one across a line (figure 7-40); BERR on the first access, on the third
(figure 7-52), and on the long word that carried the rest of a misaligned operand,
which is read again with CBREQ negated (figure 7-53) and faults if BERR comes
again; retry on the first access (figure 7-56); BERR and HALT on the second; HALT
and BR during a burst; no CBREQ on a write, a read-modify-write or a CIOUT access;
and the instruction fetch port's burst.

## The operand, not the bus cycle

The sequencer and the instruction fetch unit each present one request per
**operand** and stall until it completes: on `req_ack`, or, for a microword the
assembler marks `early`, on `req_early` at the edge that ends S5
(`doc/timing-divergences.md`, "the early retire"). The bus unit owns the split
into however many cycles Table 7-6 requires for that size, that alignment and
whatever port answers; it drives SIZ1/SIZ0 with the number of bytes **remaining**
(7.2.1, Table 7-2), routes the lanes per Tables 7-4 and 7-5, and assembles the
result. Nothing above this line knows how wide the port was, or whether it was
synchronous.

- **OCS is correct for free.** 7.1.1 asserts ECS at the start of every bus cycle
  and OCS only at the start of the first cycle *of an operand* — and "with
  respect to OCS, an 'operand' is any entity required by the execution unit".
  `bus_sizing_tb` counts one OCS per operand and one AS per bus cycle across all
  48 combinations of size, alignment and port width; `bus_sync_tb` does the same
  for the STERM port.
- **The bus introduces no new condition into the microcode.** A microword issues
  exactly one request whatever the alignment and whatever the port.

`req_last` is combinational and true throughout the half clock in which an
operand's last byte arrives — S5, or a burst's BL: the operand completes at the
rising edge after it, and a request already presented by then is taken on that
edge. `fetch_last` is the same signal for the fetch port.

`req_early` is a falling-edge register, set on the edge entering S5 when the data
operand is finishing with no bus error and no retry. Only for the first transfer
of a cycle: an operand finished by a burst beat is taken on the ordinary
acknowledge.

### What the request port gained at M1

| Signal | Meaning | Source |
|---|---|---|
| `req_burst`, `fetch_burst` | a line fill is allowed for this operand: CBREQ on the cycle that qualifies | 7.3.7, 6.1.3.2 |
| `req_ciout`, `fetch_ciout` | CIOUT for this operand's cycles | 5.7.2 |
| `req_ciin`, `fetch_ciin` | CIIN was asserted on a read cycle that carried some of this operand's bytes | 5.7.1 |
| `beat_valid`, `beat_err`, `beat_data`, `beat_addr`, `beat_num`, `beat_port`, `beat_ciin`, `beat_fetch` | every read cycle and every burst long word, as it ends | 7.2.6, 6.1.3 |

The requesters of today tie the inputs off — `req_burst`/`fetch_burst` are the
caches' (M10), `req_ciout`/`fetch_ciout` the MMU's (M11) — and the outputs go to
the top level's sink.

The bus unit decides **which cycle** of a burst-allowed operand asserts CBREQ, by
the conditions of 6.1.3.2 that are the bus's to know: a read, not a
read-modify-write ("CBREQ is not asserted during the read or write cycles of any
read-modify-write operation", 7.3.7), not CIOUT ("the MMU has inhibited caching"),
and not "the first access of an operand that spans two cache lines" — the rest of
the access, from that cycle's address on, must lie in one 16-byte line. It asserts
CBREQ once per operand: a part read again after a burst error goes "with CBREQ
negated" (7.5.1, figure 7-53).

When a burst carries the rest of a misaligned operand, the operand takes it from
the burst: "if the data for the cycle contains part of the requested operand, the
execution unit uses that data" (6.1.3.2). The real part gets the second portion
from its data cache, which the burst has just filled; the bus sees the same
cycles either way.

## Dynamic bus sizing and misalignment

`sim/tb/bus_sizing_tb.sv` reproduces **every row of UM Table 7-6** — the number of
bus cycles for each operand size, each value of A1–A0 and each of the three port
widths — and checks the bytes moved in both directions, against slaves of 8, 16 and
32 bits written from 7.2.1 rather than from this design. 405 checks.

The MC68030 supports the MC68020's dynamic bus sizing "for asynchronous bus cycles
(terminated with DSACKx) with two restrictions", both on cachable accesses: the
port size must be consistent within a long word, and the port must supply as much
data as it signals as port size (7.2.5). Both are requirements on the device. The
extra cycles the MC68030 runs to complete a cache entry from a narrow port
(6.1.3.1, figures 6-5 to 6-10) are the data cache's and come with it at M10; until
then this behaves as an MC68030 with its data cache disabled.

`DSACK1` and `DSACK0` are captured by the same flop pair on the same edge and
decoded afterwards, so that skew between them cannot make a 32-bit port present
transiently as an 8-bit one.

## Bus exception control

UM Table 7-8's six terminations for DSACK, with the case numbers the manual gives
them. The table indexes two samples by "the number of the current even bus state":
N is S2 and N+2 is S4. Here those are the falling edge entering S3 and the falling
edge entering S5.

| Case | At state N | At state N+2 | Result |
|---|---|---|---|
| 1 | DSACK, no BERR, no HALT | — | normal terminate and continue |
| 2 | HALT at or before DSACK | — | normal terminate, then halt |
| 3 | BERR in lieu of / at / before DSACK | — | bus error |
| 4 | DSACK | BERR | bus error, deferred |
| 5 | BERR and HALT in lieu of / at / before | — | retry when HALT is negated |
| 6 | DSACK | BERR and HALT | retry, deferred |

Table 7-9 is the same six for STERM, with one difference: "state N+2 not part of
bus cycle". The late window is "the next falling clock edge following the rising
clock edge on which STERM is asserted and recognized" (7.5.1) — the edge that
latches the data and ends the cycle — so a late BERR does not lengthen a
synchronous cycle. `bus_error_tb` checks Table 7-8, `bus_sync_tb` Table 7-9.

A faulted cycle **moves no bytes**. The residual the fault frame records has to be
the state before the faulted access, because RTE reruns that access; and a retried
cycle moves nothing either, because 7.5.2 reruns it "using the same access
information". `req_fault` is raised with `req_ack`, `req_fault_wr` says it was a
write, and `flt_addr`/`flt_bytes`/`flt_fc`/`flt_rw`/`flt_rmc` carry the residual.

**Retry** terminates the cycle, waits for BERR *and* HALT to be negated, and
reissues it unchanged. **Halt** does not terminate a cycle (7.5.3): the current one
completes, the data bus goes high impedance, the control signals "are driven
inactive (not high-impedance state)", and the address, FC, SIZ and R/W "remain in
the same state". **A double bus fault** shows on STATUS, asserted continuously
(7.5.4); HALT is an input only on the MC68030 (Table 5-2).

## Arbitration

UM 7.7's three steps — BR, then BG, then BGACK — and the state machine of 7.7.4.
RD68021's `doc/divergences.md` records that two of the figure's seven states cannot
be read from the manual's text layer, and which five are implemented; figure 7-61
extracts no better.

- **"The BG output will not be asserted while RMC is asserted."** RMC is a
  qualifier held across a run of ordinary cycles and negated "before the end of
  state 0 for a bus cycle following a read-modify-write operation" (7.1.1).
- **The decision to start a cycle is taken from the arbiter's NEXT state**, so
  that no cycle begins on the edge the arbiter decides to grant. `bus_arb_tb`
  sweeps the phase of BR across all sixteen positions of a four-cycle operand.
- **A burst is one cycle** (7.3.7): the bus is released after it. `bus_burst_tb`.
- "Bus arbitration can still occur" after a double bus fault (7.5.4): `bus_arb_tb`.

## Reset

"During the reset period, the entire bus three-states (except for
non-three-statable signals, which are driven to their inactive state)" (7.8). The
reset this design has is `rst_n` (`doc/pinout.md`), and every output enable drops
with it; ECS, OCS, BG, STATUS and REFILL are driven inactive.
`bus_status_tb` checks both groups.

## Cache control pins

| Pin | Behaviour | Source | Test |
|---|---|---|---|
| CIIN | sampled with STERM, or at the rising edge entering S4 of a DSACK cycle; ignored on writes; returned with the operand and with each beat | 5.7.1, 7.2.8–7.2.10 | `bus_sync_tb`, `bus_burst_tb` |
| CIOUT | from the request, valid from S0 with the address, released with it | 5.7.2, 7.3.1 state 0, specs 6–8 | `bus_sync_tb` |
| CBREQ | asserted with AS in S1, negated with it or after the third long word of a burst; in the control group for three-stating | 7.3.4 state 1, 7.3.7, specs 9, 12, 16 | `bus_burst_tb` |
| CBACK | sampled with STERM; ignored unless CBREQ was asserted and the cycle is synchronous | 5.7.4, 7.2.8, 7.2.10 | `bus_burst_tb` |

## Emulator support pins

**STATUS** encodes Table 12-4 as the number of clocks it is asserted for: one at an
instruction boundary, two at a boundary where a trace or interrupt is taken, three
when exception processing begins (reset, bus error, address error), continuously
after a double bus fault. **REFILL** is asserted for one clock per pipeline refill
the sequencer requests. "Both STATUS and REFILL assert and negate from the falling
edge of the CLK signal" (12.7.1, specifications 62 and 63). The sequencer reports
each event as a one-clock pulse and the bus unit encodes it, with one negated clock
between indications. `bus_status_tb` checks the encoding against driven events;
`core_status_tb` checks it end to end on real code. Where it differs from the part
is in `doc/divergences.md`.

**MMUDIS** is synchronised by two falling-edge ranks, like CDIS, and goes to the
top level's sink until the MMU of M11 (`bus_status_tb`).

## Known gaps at M1

| | |
|---|---|
| The cycle aborted before AS on a cache hit, an ATC miss or an MMU fault (7.1.1) | M10, M11 |
| The extra cycles that complete a cache entry from an 8- or 16-bit port (6.1.3.1) | M10 |
| Which requests are cachable and burstable — CACR's enables, freeze, burst enables | M10 |
| CIOUT's value — the ATC entry's or the TTx register's CI bit | M11 |
| STATUS's ATC-miss, spurious/autovector and F-line indications | `doc/divergences.md` |
| AC limits against the MC68030EC tables | M3 |
| Idle clocks between operands | `doc/timing-divergences.md` |
