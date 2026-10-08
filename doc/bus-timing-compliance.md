# What the bus unit does on the pins

The state-by-state behaviour of `rtl/rd68031_biu.sv`, with the citation for each
edge and the test that checks it. This is the document to argue with when a
behaviour is questioned. "UM" is the MC68030 user's manual
(`MC68030UM_split/`); "UM20" is the MC68020's, cited only where an inherited
behaviour has no MC68030 paragraph of its own.

As of M2 it covers the three kinds of bus cycle the MC68030 has — asynchronous
(DSACK), synchronous (STERM) and burst (CBREQ/CBACK) — with dynamic bus sizing,
misaligned operands, CIIN/CIOUT, and the emulator pins STATUS, REFILL and
MMUDIS (M1); and bus exception control, arbitration, CPU space cycles and reset
re-verified against the MC68030 manual on all three kinds of cycle (M2); and,
at M3, every pin and every input against the AC tables of the MC68030EC data
sheet at all five of its grades (`make timing`, `doc/ac-timing.md`). Specification
numbers in this file are the MC68030EC's
(`MC68030EC_split/ac-electrical-specifications.csv`).

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
| rising → S4 | **CIIN latched** — "on the rising edge of bus cycle state 4" | 7.2.8, 7.2.9, 7.3.1 state 4, specs 60, 61 |
| falling → S5 | **read data latched**; **the port size taken from DSACK1/DSACK0**; AS, DS and CBREQ negated; DBEN negated on a read; Table 7-8's second sample | 7.3.1 states 4 and 5, specs 27, 27A, 31A, 12, 41 |
| rising, ending S5 | address group and CIOUT released; write data released; DBEN negated on a write | 7.3.1/7.3.2 state 5, specs 7, 8, 43 |

A **wait state** is one whole clock inserted between S3 and S4, and the sample
repeats: "if wait states are added, the processor continues to sample the DSACKx
signals on the falling edges of the clock until one is recognized" (7.3.1 state
3). *n* waits make the cycle 3 + *n* clocks. The rising edge in each wait tests
STERM too, which is how a synchronous device's wait states fall out of the same
pair of states.

`sim/tb/bus_ruler_tb.sv` asserts every row as a seven-tick pattern from the
rising edge entering S0, and then the widths the pattern implies against the
MC68030EC minima at 20 MHz, the bus harness's clock:

| Spec | What | Minimum (MC68030EC, 20 MHz) | This design |
|---|---|--:|--:|
| 10 | ECS width asserted | 15 ns | 25 ns |
| 11 | address valid to AS asserted | 10 ns | 25 ns |
| 14 | AS and DS width asserted (asynchronous read) | 85 ns | 100 ns |
| 14A | DS width asserted (write) | 38 ns | 50 ns |
| 15 | AS, DS width negated | 38 ns | 50 ns |
| 22 | R/W low to DS asserted (write) | 60 ns | 75 ns |
| 26 | data-out valid to DS asserted | 10 ns | 25 ns |
| 44 | R/W low to DBEN asserted (write) | 10 ns | 25 ns |
| 45 | DBEN width asserted, asynchronous read | 50 ns | 75 ns |
| 45 | DBEN width asserted, asynchronous write | 100 ns | 125 ns |

**This is not the AC-timing conformance analysis.** An RTL model has no pad delays,
so the limits become a feasibility question instead, and that is `make timing`,
which judges these and every other specification at all five grades, on every
kind of cycle (`doc/ac-timing.md`).

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

**The port size is taken one clock after DSACK terminates the cycle.** Either
DSACK1 or DSACK0 terminates the cycle on the falling edge it is first recognised
on — "as long as at least one of the DSACKx signals is recognized by the end of
S2" (7.3.1 state 3) — and the port size is read from both on the falling edge
that latches the data, one clock later. Specification 31A allows the second to
trail the first by up to 3 ns at 50 MHz and 10 ns at 20 MHz, with "#47A ... met
by DSACK0 or DSACK1" (footnote 3) — by one of them — so on the recognising edge
the other may not have arrived; and "the bus master is responsible for
de-skewing the acknowledge and data signals from the slave devices" (7.3). One
clock later both have, and the device still holds them: it keeps DSACK
"asserted until it detects the negation of AS" (7.3.1 state 5), which is that
same edge. Both bits are still captured by one flop pair on one edge. RD68021
took the port size on the recognising edge, and a 32-bit port with a trailing
DSACK1 read as an 8-bit one (`doc/bugs-found.md`, M3); `make timing` now asserts
the two DSACKs as far apart as a clock allows, both ways round.

## Bus exception control

UM 7.5. Table 7-8 gives the six terminations of an asynchronous cycle and Table
7-9 the six of a synchronous one, with the case numbers the manual gives them.
Both index two samples by "the number of the current even bus state", N being
the one the device terminates on.

| Case | DSACK (Table 7-8) | STERM (Table 7-9) | Result |
|---|---|---|---|
| 1 | DSACK at N | STERM at N | normal terminate and continue |
| 2 | HALT at or before DSACK | HALT before STERM | normal terminate, then halt |
| 3 | BERR in lieu of / at / before DSACK | BERR before STERM, or none | bus error |
| 4 | BERR at N+2, after DSACK | BERR with STERM | bus error, "deferred" |
| 5 | BERR and HALT in lieu of / at / before | BERR and HALT before STERM | retry when HALT negated |
| 6 | BERR and HALT at N+2 | BERR and HALT with STERM | retry, "deferred" |

**Where each is sampled.** BERR and HALT are asynchronous inputs and are
sampled on falling edges, with DSACK: at the end of S2 and of every wait state
(7.3.1 state 3), the falling edges entering `ST_S3` and `ST_WL`. A cycle
DSACK ended gets a second sample one clock later, at the falling edge entering
S5 — "BERR (and HALT) must meet the appropriate setup time (parameter #27A)
prior to the falling clock edge one clock cycle after DSACKx is recognized"
(7.2.9) — and that is cases 4 and 6. A synchronous cycle has no such second
sample: "state N+2 not part of bus cycle". Its late window is "the next falling
clock edge following the rising clock edge on which STERM is asserted and
recognized" (7.5.1), the edge that latches the data and ends the cycle, so a
late bus error or retry does not lengthen a synchronous cycle. BERR asserted
on the same rising edge as STERM is therefore case 4, which is what Table
7-9's own rows say (`doc/manual-contradictions.md`, 4).

A synchronous cycle that is waiting for STERM samples BERR and HALT on the
same falling edges an asynchronous one does, so cases 3 and 5 end it exactly
as they end a DSACK cycle: three clocks at least, "the current bus cycle in
the normal way" (7.5.1). HALT asserted on the same edge as STERM, which Table
7-9 does not list, halts after the cycle as case 2 does: HALT is synchronised,
and the next cycle boundary sees it (7.5.3).

**A faulted cycle moves no bytes.** The residual the fault frame records has to
be the state before the faulted access, because RTE reruns that access; and a
retried cycle moves nothing either, because 7.5.2 reruns it "using the same
access information". `req_fault` is raised with `req_ack`, `req_fault_wr` says
it was a write, and `flt_addr`/`flt_bytes`/`flt_fc`/`flt_rw`/`flt_rmc` carry the
residual. In an operand of several cycles — dynamic bus sizing or misalignment
— the cycles before the faulted one have moved their bytes and the residual
starts at the faulted one; the cycles after it never run.

**Retry** terminates the cycle, places the control signals in their inactive
state, waits for BERR *and* HALT to be negated — sampled on the falling edges, as
every other use of the two pins is, against specifications 47A and 47B; it was
the raw pins on the rising edge until M3 (`doc/bugs-found.md`) — and reissues the cycle unchanged
— address, FC, SIZ, R/W, CBREQ on a burst's first access ("causes the processor
to retry the bus cycle and assert CBREQ again", 7.5.2), and OCS if the cycle
had it. The manual is silent on whether OCS comes again on the rerun of an
operand's first cycle: 5.6.1 says only that "OCS is not asserted for
subsequent cycles that are performed due to dynamic bus sizing or operand
misalignment", and a retry is neither. The rerun is the same cycle "using the
same access information", so this design asserts OCS again on it — on the
retry of a burst's first access too — and the user has confirmed that choice
since M2; it is an interpretation of a silence, not a divergence. Part-way through an operand, only the
faulted cycle is rerun. "The processor retries any read or write cycle of a
read-modify-write operation separately; RMC remains asserted during the entire
retry sequence."

**Halt** does not terminate a cycle (7.5.3): "the MC68030 halts external bus
activity at the next bus cycle boundary" — the next cycle of the same operand
as much as the next operand, and with the bus idle when HALT arrives, the next
cycle does not start. While halted the data bus goes high impedance, the
control signals "are driven inactive (not high-impedance state)", and the
address, FC, SIZ and R/W "remain in the same state". Negating HALT for a short
while lets one cycle out: single-stepping, figure 7-57. During a
read-modify-write the bus halts between the read and the write with RMC still
asserted, as it is through a retry (`doc/manual-contradictions.md`, 5).

**Bursts.** The first access of a burst follows Table 7-9 and a retry of it
asserts CBREQ again. On a later access (7.5.1, 7.5.2):

| On long word 2, 3 or 4 | What happens |
|---|---|
| BERR | the burst ends; that long word is reported on `beat_err`, for the cache entry to be marked invalid; no exception |
| BERR and HALT | the same, and the bus then halts until HALT negates: "independent BERR and HALT operations"; no retry |
| HALT | the burst runs to its end, then the bus halts: "a burst operation is a single cycle" |
| BERR on the long word that carried the rest of a misaligned operand | that part is read again by a cycle of its own "with CBREQ negated", after the halt if HALT came too; BERR on it again is a bus error |

**A double bus fault** shows on STATUS, asserted continuously "until the
processor is reset" (7.5.4, 8.1.2, Table 12-4); HALT is an input only on the
MC68030 (Table 5-2). "Bus arbitration can still occur." A bus error while RTE
loads a frame should be one too (8.1.2) and is not yet (`doc/divergences.md`).

`sim/tb/bus_error_tb.sv` (1346 checks) runs every case of Table 7-8 in every bus
cycle of a long word on 32-, 16- and 8-bit ports and a 32-bit port with three
wait states, aligned and misaligned; every case of Table 7-9 on a STERM port
with no wait state and with one, aligned and misaligned; the first access of a
burst by Table 7-9; and BERR, BERR with HALT and HALT on the second, third and
fourth long words of a burst, with and without wait states between them. Reads
and writes. Each scenario checks the number of bus cycles, the data or the
memory, the fault and its residual, the retried cycle's access information, OCS,
and the bus while halted or waiting to retry. Then HALT on an idle bus,
single-stepping a four-cycle operand, HALT during a read-modify-write, and BERR
with HALT on the burst access that carried part of a misaligned operand.
`bus_sync_tb` and `bus_burst_tb` keep M1's own checks of the same tables.

## Arbitration

UM 7.7's three steps — BR, then BG, then BGACK — and the state machine of
figure 7-61. RD68021 implemented five of its seven states because the overbars
on its labels do not survive the manual's text layer; they survive a rendering
of the page, and this design now has all seven:

| State | G | T | Arcs (R = BR, A = BGACK, both synchronised; ' = negated) |
|---|---|---|---|
| 0 | 0 | 0 | R'A' → 0, RA' → 1, A → 4 |
| 1 | 1 | 1 | → 2 |
| 2 | 1 | 1 | RA' → 2, A or R' → 3 |
| 3 | 0 | 1 | → 4 |
| 4 | 0 | 1 | R'A → 4, R'A' → 0, R → 5 |
| 5 | 1 | 1 | → 6 |
| 6 | 1 | 1 | RA → 6, RA' → 2, R' → 3 |

- **0-1-2-3-4-0** is the ordinary relinquish. BG moves "on the falling edge of
  the clock after a state is reached during which G changes"; specifications
  35 (BR to BG, 1.5–3.5 clocks), 37 (BGACK to BG negated, 1.5–3.5), 39 and 39A
  (BG widths) and 59 (BG negated to the bus driven, at least one clock) hold in
  clocks.
- **0-4** is single-wire arbitration: "BGACK alone can be used to place the
  processor's external bus buffers in the high-impedance state" (7.7.4, figure
  7-62). BG is never asserted. It "applies to all bus cycles of a
  read-modify-write sequence", so with A asserted the release does not wait for
  RMC (`doc/manual-contradictions.md`, 7).
- **4-5-6** is the re-grant: "if a BR is still pending after the assertion of
  BGACK, another BG is asserted within a few clocks of the negation of BG", and
  "the processor does not perform any external bus cycles before it reasserts
  BG" (7.7.3). State 6 holds the second grant for as long as the old master
  still asserts BGACK, and hands over to state 2 to wait for the new one's.
- **"The BG output will not be asserted while RMC is asserted"**, except to
  relinquish on the first read of a read-modify-write: "the MC68030 allows
  normal bus arbitration during this read cycle; a normal relinquish and retry
  operation (asserting BERR, HALT, and BR at the same time) is used" (7.7.4).
  While that first cycle waits to be retried, the lock does not hold the bus;
  on any later cycle of the sequence a relinquish and retry is a retry, and BR
  waits for RMC to negate (`doc/manual-contradictions.md`, 6).
- **The decision to start a cycle is taken from the arbiter's NEXT state**, so
  that no cycle begins on the edge the arbiter decides to grant; and BG is
  "deferred until the bus cycle has begun" when the bus unit has decided to
  start one — which a bus held by HALT has not.
- **A burst is one cycle** (7.3.7). BG may be asserted during it, as during any
  cycle — "the bus will become available at the end of the current bus cycle"
  — and nothing interrupts it: neither BR nor BGACK, which an alternate master
  may only act on once AS negates.
- **While halted** "the halt operation has no effect on bus arbitration": the
  address and control are released on a grant and "again driven to their
  previous states" when the bus comes back with HALT still asserted (7.5.3,
  figure 7-57). After a double bus fault too (7.5.4), and while RESET is
  asserted, by the RESET instruction or from outside (7.7).

`sim/tb/bus_arb_tb.sv` (140 checks): the ordinary sequence and what it releases;
BR during a cycle; the RMC inhibit; relinquish and retry; BR at sixteen phases
of a four-cycle asynchronous operand and ten of a two-cycle synchronous one;
the specifications above; the re-grant through states 5 and 6 with two masters
and the processor's own request pending throughout; 6 to 3; single-wire
arbitration on an idle bus, during a cycle, during a read-modify-write and
during a burst; relinquish and retry on the first read of a read-modify-write
and on its write; BR at every clock of a burst; arbitration while halted, on an
idle bus held by HALT, and after a double bus fault. `bus_reset_tb` covers the
RESET cases.

## CPU space cycles

UM 7.4 and figure 7-42. FC2–FC0 = 111, and the type on A19–A16:

| Cycle | Type | Address | Size | Terminated by |
|---|---|---|---|---|
| Interrupt acknowledge | $F | A31–A4 and A0 ones, the level on A3–A1 | byte | DSACK or STERM, the vector on the port's least significant byte; AVEC for an autovector; BERR for a spurious interrupt, BERR and HALT for a retry (7.4.1) |
| Breakpoint acknowledge | $0 | the number on A4–A2, all else zero | word, two cycles from an 8-bit port | DSACK or STERM; BERR for "no instruction word available" (7.4.2) |
| Coprocessor | $2 | CpID on A15–A13, the register on A4–A0, all else zero | as the access | DSACK or STERM (7.4.3, section 10) |

All three may be synchronous: 7.4.1.1 terminates the interrupt acknowledge
"with either STERM or DSACKx", 7.4.2 the breakpoint acknowledge "with DSACKx or
STERM". AVEC is sampled where DSACK is and "is ignored during all other bus
cycles" (7.1.7). CBREQ is never asserted in CPU space. A bus error on a
CPU-space cycle is reported as an end code and raises no fault — the spurious
interrupt and the illegal instruction are the microcode's to take — except on a
coprocessor access the requester marks as one that must fault. Nothing here
changed from the MC68020 design; the MMU's own CPU-space accesses are M11's.

`sim/tb/bus_cpuspace_tb.sv` (56 checks): interrupt acknowledges on 32-, 16- and
8-bit ports, a STERM port and a port with wait states, with the address, size
and vector lane; the autovector, and AVEC ignored on the other two kinds; the
spurious interrupt, its retry, and a late bus error with STERM; breakpoint
acknowledges on 32- and 8-bit ports and by STERM, with the number on A4–A2 and a
bus error; coprocessor reads and writes, asynchronous and synchronous, a bus
error with and without a fault, and a retry.

## Reset

"During the reset period, the entire bus three-states (except for
non-three-statable signals, which are driven to their inactive state)" (7.8).
Since M8-M9 both resets do it: `rst_n`, which is not an MC68030 pin
(`doc/pinout.md`), and the RESET pin from outside. Every output enable drops
with either, and ECS, OCS, STATUS and REFILL, which Table 5-2 lists as not
three-stated, are driven inactive; BG is the arbiter's, which runs under the
RESET pin (7.7) and not under `rst_n` (`doc/divergences.md`). A bus cycle in
progress when the pin goes low is abandoned -- "resetting the processor causes
any bus cycle in progress to terminate as if DSACKx, BERR, or STERM had been
asserted" -- and nothing starts while it is held. "Once RESET negates, all
control signals are driven to their inactive state, the data bus is in read
mode" -- R/W high, the data not driven -- "and the address bus is driven": not
with `ADDR_HIZ_BETWEEN_CYCLES` set, its default by the user's decision, which
releases it until the first cycle (`doc/divergences.md`).

The RESET instruction drives RESET for 512 clocks -- "the processor drives the
RESET signal for 512 clock cycles ... the internal registers of the processor
are unaffected" -- open drain, from a request the microword holds; it is not
restarted by a request still held when it ends. Its own pulse comes back on
the RESET input and does not reset the processor, and neither does a RESET
from outside that ends within four clocks of it; "an external RESET signal that
is asserted to the processor during execution of a reset instruction must
extend beyond the reset period of the instruction by at least eight clock
cycles to reset the processor" (7.8), and one that does, does.

`sim/tb/bus_reset_tb.sv` (38 checks): the pins in `rst_n`, with BR asserted;
the pins after it; the pulse's length, twice, and that it resets nothing;
arbitration during the RESET instruction; the RESET pin from outside --
the bus three-stated, nothing started, BR granted and given back under it, a
cycle in progress abandoned and its operand run again afterwards; and a RESET
from outside overlapping the instruction's pulse by none, two and eight clocks.
`core_reset_tb` has the processor's side of it.

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

## Known gaps at M3

| | |
|---|---|
| The cycle aborted before AS on a cache hit, an ATC miss or an MMU fault (7.1.1) | M10, M11 |
| The extra cycles that complete a cache entry from an 8- or 16-bit port (6.1.3.1) | M10 |
| Which requests are cachable and burstable — CACR's enables, freeze, burst enables | M10 |
| CIOUT's value — the ATC entry's or the TTx register's CI bit | M11 |
| STATUS's ATC-miss, spurious/autovector and F-line indications | `doc/divergences.md` |
| A bus error while RTE loads a frame is not a double bus fault | M8–M9, `doc/divergences.md` |
| The external RESET input resetting the processor | M8–M9, `doc/divergences.md` |
| The MMU's CPU-space accesses, and the internal bus error of an MMU fault (7.5) | M11 |
| Idle clocks between operands | `doc/timing-divergences.md` |
