# AC-specification conformance

Against the AC tables of the **MC68030EC/D** data sheet, Rev. 1
(`Inputs/doc/MC68030_Doc_More_Readable/MC68030EC_split/ac-electrical-specifications.csv`).
Specification numbers here are that table's.

**Result: feasible at all five speed grades** — 20, 25, 33.33, 40 and 50 MHz,
every grade the data sheet prints — with 3 to 8 ns of room on the binding
constraint. **73 of the 76 numbered specifications are measured**; the other
three are not questions about this design, and each is named with the reason.
Every input is sampled inside its setup and hold window, on the edge the data
sheet names. Getting there found and fixed three defects in the RTL
(`doc/bugs-found.md`, M3).

```
 20.00 MHz  feasible, 73 of 76 specifications measured, 7.0 ns of room on the binding constraint
            31 smp.dsack->smp.data (read, 50.0 ns apart)
            tightest limit in clocks: 0.0 ns, 56 rst.assert->rst.negate (reset, 25600.0 ns apart)
            tightest pad-delay budget: 15.0 ns, 6A ecs.assert
            inputs: 46 windows checked, each sampled on its own edge; tightest 3.5 ns, 27 data_async (setup)
 25.00 MHz  feasible, 73 of 76 specifications measured, 8.0 ns of room on the binding constraint
            28A clk.end->smp.term (read, 80.0 ns apart)
 33.33 MHz  feasible, 73 of 76 specifications measured, 7.0 ns of room on the binding constraint
            10 ecs.assert->ecs.negate (read, 15.0 ns apart)
 40.00 MHz  feasible, 73 of 76 specifications measured, 7.0 ns of room on the binding constraint
            14A ds.assert->ds.negate (write, 25.0 ns apart)
 50.00 MHz  feasible, 73 of 76 specifications measured, 3.0 ns of room on the binding constraint
            28A clk.end->smp.term (read, 40.0 ns apart)
```

`make timing`, and it is in `make check`; `make timing-verbose` prints every grade
in detail — the ten tightest separations, the limits in clocks, a pad assignment
that meets everything, and the input windows.

## The grades

The data sheet prints five: 20, 25, 33.33, 40 and 50 MHz. There is **no 16.67 MHz
grade**, though `doc/plan.md` named one: it came from the MC68020's table, and the
MC68030 user's manual still mentions an MC68030RC16 in its applications section —
a contradiction with the data sheet, `doc/manual-contradictions.md`, 8. A grade
with no column has no limits to be judged against.

| Grade | Clock (spec 1) | Half clock | Binding constraint | Room |
|---|--:|--:|---|--:|
| 20 MHz | 50 ns | 25 ns | 31, DSACK to data valid, the core's side | 7.0 ns |
| 25 MHz | 40 ns | 20 ns | 28A, the synchronous hold, the core's side | 8.0 ns |
| 33.33 MHz | 30 ns | 15 ns | 10, ECS width asserted | 7.0 ns |
| 40 MHz | 25 ns | 12.5 ns | 14A, DS width asserted on a write | 7.0 ns |
| 50 MHz | 20 ns | 10 ns | 28A, the synchronous hold, the core's side | 3.0 ns |

### The binding constraints

**28A at 50 and 25 MHz.** "Clock Low to DSACKx, BERR, HALT, AVEC Negated
(Synchronous Hold)", at most 35 ns at 50 MHz. A device may hold those inputs that
long after the clock low that ends a cycle, so the core must not sample them again
until 35 ns later, plus the sample's own setup time, 2 ns (47A). The next sample is
the falling edge entering S3 of the next cycle, two clocks — 40 ns — after the one
the cycle ended on, back to back, which is as close as cycles come. 40 − 37 = 3 ns.
It is the MC68030's own arithmetic: the part runs the same S0–S3, and 28A is 85,
70, 50, 40 and 35 ns at the five grades against two clocks of 100, 80, 60, 50 and
40. Nothing in this design could widen it without lengthening every cycle.

Next at 50 MHz, with 5 ns: **45A**, DBEN width on a two-clock synchronous read.
DBEN is asserted for half a clock there (UM 7.3.4), 10 ns against 5 — what
footnote 9 means by "the timing on DBEN precludes its use for synchronous READ
cycles with no wait states".

**31 at 20 MHz.** "DSACKx Asserted to Data-In Valid", at most 43 ns. Footnote 2
waives it for a device that meets 47A; this is the device that does not. Its DSACK
just makes one sample, 4 ns (47A) before it, and its data must then make the latch,
one clock later, 4 ns (27) before that: 50 + 4 − 4 = 50 against 43, 7 ns.

**10, 14A — 33.33 and 40 MHz.** ECS is asserted for one half clock, 15 ns against a
minimum of 8; DS on a write for one clock, 25 ns against 18. Both are the widths
UM 7.3 describes, and the room is what the data sheet left between its minimum and
its own cycle.

**Limits in clocks.** Specification 56, the RESET instruction's pulse, is met
exactly — 512 clocks, as UM 7.8 says — and so has no room at any grade; it is
reported on a line of its own for that reason, and so are 35, 37, 58 and 59. The
next tightest of them is 35 and 37 at 50 MHz, 10.5 ns: BR asserted just after a
falling edge reaches BG 59.5 ns later through the two-rank synchroniser, against a
maximum of 3.5 clocks, 70 ns, leaving 10.5 ns for BG's own pad delay.

**The tightest pad-delay budget** is a different number and is reported separately
because it is the data sheet's, not this design's — see "a bound's margin is not a
margin" in `tools/timing/README.md`.

## Why this is decided rather than measured

An RTL model has no pad delays. Every pin in `rd68031_biu` moves exactly on a clock
edge, so a limit of the form "Clock High to Address Valid ≤ 14 ns" cannot be
*measured* from it — there is nothing there to measure.

It can still be answered, because every limit in the data sheet is a statement about
the same unknowns. Each one is either

- a **budget** on one pad delay — `0 ≤ d[as.assert] ≤ 10` — or
- a **separation** between two events — `(t_b + d_b) − (t_a + d_a) ≥ 13`, where the
  two times come from the simulation and are constants.

Both rearrange to `d_x − d_y ≤ c`, which is a weighted edge in a graph whose
shortest-path problem is feasible exactly when there is no negative cycle.
Bellman-Ford answers that, and its potentials are a pad-delay assignment meeting
every limit at once. So the question is not "how fast is this design" but "is there
any set of pads that makes it legal", and that has an exact answer.

Two kinds of event have no pad delay, and are the solver's fixed node: an **input**
as a device drives it (`in.br.assert`), and an **edge inside the core** — the edge
an input is sampled on (`smp.*`) or the clock low a cycle ends on (`clk.end`).
They are what let a requirement on a device be answered from the processor's side.

Every pad delay is **at least zero**: a pin cannot move before the clock edge that
moves it. Without that floor the solver could give a pin with only a maximum —
data-out valid, specification 23 — a negative delay, and meet a separation from it
by moving the pin before its own edge. The RD68021 analysis had no floor.

## One run per grade

The separations are measured in clock edges, so a recording made at one frequency
is evidence about that frequency and nothing else. `make timing` runs the testbench
five times, at each grade's minimum cycle time — 50, 40, 30, 25 and 20 ns — and
judges each log against its own column.

## What the testbench records

`sim/tb/rd68031_timing_tb.sv` runs the bus unit through every kind of cycle the
MC68030 has, each scenario logged separately so that the pairing rule never pairs a
read's AS with a write's DS:

| Scenario | What |
|---|---|
| `read` | asynchronous reads: four back-to-back cycles from an 8-bit port, 32- and 16-bit ports, three wait states |
| `write` | the same, writes |
| `mixed` | asynchronous read, write, read, write — R/W moves |
| `sread` | synchronous reads: two-clock cycles back to back, two wait states, a four-long-word burst, and a burst with a wait before each later beat (CBREQ) |
| `swrite` | two-clock synchronous writes, which assert no DS |
| `swwrite` | synchronous writes with a wait state, which do |
| `smixed` | synchronous read, write, read, write |
| `arb` | three handovers, one with a cycle under way; BR and BGACK each half a nanosecond before a falling edge in one and after one in another; BR negated 1.5 clocks after BGACK, the most 37A allows |
| `status` | STATUS for one, two and three clocks, and REFILL |
| `reset` | the RESET instruction's pulse |

and then the **input probes**, below.

## What is measured, and what is not

`python3 tools/timing/anchors.py` prints the full table; `--unanchored` prints the
rest with a reason each.

| | Specifications | How |
|---|---|---|
| Pad-delay budgets | 6, 6A, 7, 8, 9, 12, 12A, 16, 18, 20, 23, 33, 34, 40, 41, 42, 43, 53, 62, 63 | each on the edge the specification names; a pin that moves on the other edge fails |
| Separations between the core's own pins | 6B, 9A, 9B, 10, 10A, 10B, 11, 13, 14, 14A, 14B, 15, 15A, 17, 21, 22, 24, 25, 25A, 26, 39, 39A, 44, 45 ×2, 45A ×2, 46, 46A, 55, 56, 59 | each on the kinds of cycle it applies to: 14 and 45 asynchronous, 14B and 45A synchronous |
| From an input to a pin | 35, 37, 58 | BR to BG, BGACK to BG negated, BGACK negated to the bus driven again |
| The processor's side of a device's limit | 28, 28A, 29, 29A, 30A, 31, 48 | below |
| Where each input is sampled | 27, 27A, 30, 47A, 47B, 60, 61, and the minimum of 28A | the probes, below |
| DSACK skew | 31A | the two DSACKs a clock less a nanosecond apart, both ways round |
| Counts | 14A (footnote 11), 37A (footnote 6) | no DS on a two-clock synchronous write; no second grant when BR is held 1.5 clocks after BGACK |
| The stimulus | 37A | that the test held BR for all 1.5 clocks |
| The clock | 1, 2/3 | the run's own period and half period, checked directly |

**Not about this design — 3:**

| | |
|---|---|
| 4/5 | clock rise and fall times; an RTL model has no edge ramps, and the clock is the system's |
| 32 | RESET input transition time, a property of the system's reset circuit; RESET goes through two falling-edge ranks whatever its slope |
| 57 | BERR negated to HALT negated on a rerun: an order asked of the device that this design does not rely on — a retry waits for both, in either order |

**Partly:** IPEND, which 6, 6B and 8 name with the address, is the sequencer's pin,
not the bus unit's, and is not in this log. It is a rising-edge register — M3 made it
one — and `core_exc_tb` checks that every change of it falls on a rising edge.

### A device's limits, from the processor's side

About a third of the table is what a device must do. Each has a processor side,
and that is what is measured: a device that uses *all* of its allowance must still
be read correctly. The bound is the device's maximum used as the core's minimum.

| Spec | The device may... | so the core must... |
|---|---|---|
| 28 | hold DSACK, BERR, HALT, AVEC up to max(28) after AS negates | not sample them again until max(28) + min(47A) after AS negates at the pin; and take its last sample of the cycle no later than AS negating (min(28) = 0) |
| 28A | ... up to max(28A) after the clock low ending the cycle | not sample them again until max(28A) + min(47A) after that edge |
| 29 | let the data go as soon as AS negates | latch it no later than AS negating at the pin |
| 29A | drive the data bus up to max(29A) after AS negates | not drive it for a write before then |
| 30A | ... up to max(30A) after the clock low ending a read | not drive it for a write before then |
| 31 | present data up to max(31) after DSACK | latch it at least max(31) + min(27) − min(47A) after the edge DSACK was sampled on |
| 48 | assert BERR or HALT up to max(48) after DSACK | take the late sample at least max(48) + min(27A) − min(47A) after it |

30A is worth a look: at 20, 25 and 33.33 MHz it is *exactly* one and a half clocks,
which is where the next write first drives the data bus — the rising edge entering
its S2. Read followed by write is the case the specification is named for, and the
data sheet sized it to the bus.

### The other half: where this design samples its inputs

An RTL model samples an input at one instant, and setup and hold are a window
around one clock edge. The testbench **probes** each input: it makes the same
change twice, half a nanosecond before an edge and half a nanosecond after, and
records what the core did. If the two differ, the core sampled inside that
nanosecond. The analysis then checks that the edge is the kind the data sheet
names, and that the nanosecond lies inside the window at that grade.

| Input | Edge | Probe outcome | Window |
|---|---|---|---|
| DSACK | falling, entering S3 | AS two clocks or three | 47A, 47B, 28A |
| BERR | falling, entering S3 | AS two clocks or three | 47A, 47B, 28A |
| AVEC | falling, entering S3 of an interrupt acknowledge | AS two clocks or three | 47A, 47B, 28A |
| HALT, with DSACK | falling, entering S3 | the cycle ends halted or not (Table 7-8 case 2) | 47A, 47B |
| BERR and HALT, ending a retry | falling | when the rerun starts | 47A, 47B |
| late BERR, DSACK cycle | falling, entering S5 | bus error or not | 27A, 47B |
| late BERR and HALT, DSACK cycle | falling, entering S5 | retried or not | 27A, 47B |
| late BERR, STERM cycle | falling, after STERM | bus error or not | 27A, 47B, 28A |
| data, DSACK cycle | falling, entering S5 | which data was latched | 27, 30 |
| data, STERM cycle | falling, after STERM | which data was latched | 27, 30 |
| STERM | rising, entering S2 | AS one clock or two | 60, 61 |
| CBACK | rising, with STERM | a burst or not | 60, 61 |
| CIIN, STERM cycle | rising, with STERM | CIIN taken or not | 60, 61 |
| CIIN, DSACK cycle | rising, entering S4 | CIIN taken or not | 60, 61 |
| IPL, CDIS, MMUDIS, HALT, BR, BGACK, RESET | falling | when the synchroniser's output moves | 47A, 47B |

46 windows at every grade. The tightest is 27, data setup, which is 1 ns at 33.33 MHz
and above: the probe's own resolution, ±0.5 ns, leaves 0.5 ns. That is a statement
about the probe, not the design, which samples exactly on the edge.

**DSACK skew, 31A.** Footnote 3: "the maximum allowable skew between DSACK0 to
DSACK1 asserted or DSACK1 to DSACK0 asserted; specification #47A must be met by
DSACK0 or DSACK1" — by one of them. So the port size cannot be taken on the edge
that recognises DSACK, and since M3 it is not: it is taken one clock later, on the
edge that latches the data (`doc/bus-timing-compliance.md`). The testbench asserts
one DSACK half a nanosecond before the recognising edge and the other a clock less
a nanosecond after the first — 49 ns at 20 MHz, against 10 allowed; 19 ns at 50
MHz, against 3 — and the long word must arrive whole, in one cycle.

## `ADDR_HIZ_BETWEEN_CYCLES`

The analysis runs the default, set, which releases the address group at the end of
every cycle after which the bus goes idle (`doc/divergences.md`). The log says so on
its `H` line and `make timing-verbose` prints it. What follows from that:

- **Specification 7**, "Clock High to Function Code, Size, RMC, CIOUT, Address, Data
  High Impedance", is measured at **every** such release — the end of an idle-bound
  cycle — and not only on relinquish, where the data sheet draws it (figure 7). The
  data sheet's read and write figures draw 8 there instead; this design releases.
- **Specification 8**, address invalid, and **13**, AS negated to address invalid,
  are measured at the same edge: the address stops being *driven* there. Nothing
  in this analysis claims it stays valid between cycles.
- Back-to-back cycles change the address without releasing it, and are measured as
  invalid-then-valid on the rising edge entering S0, as the figures draw.

A board that clears the parameter keeps the address driven between cycles; nothing
here runs that setting.

## The pad model

Each pin transition has its own delay variable. Unless they are tied, the solver
may give one pin a large delay when it asserts and a small one when it negates,
which real pads do not do — and it is not a hypothetical: a short pulse can pass a
minimum-width limit only by exploiting exactly that. `PADSKEW` is how far apart one
pin's transition delays may be, and **the analysis defaults to 0**: one delay per
pin. Every delay is at least zero.

> **INFEASIBLE is a proof. FEASIBLE is conditional** on that model.

## Trusting the tool

The design is judged by this code, so the code is judged by cases whose answer is
arithmetic: `python3 tools/timing/feasible.py` runs ten known-answer tests over the
solver — a satisfiable bound, a self-contradicting one, a separation with room, one
that cannot be met, a width shorter than its own minimum, both kinds of margin, a
separation met above the zero floor and one that only a negative delay could meet,
and an internal separation that holds and one that does not. `make timing` runs it
first. (RD68021's copy of this document said that `make timing` ran it; it did not.)

The analysis fails a grade on anything it cannot measure: a specification with no
events in the log, a pin that moves on the other edge from the one its specification
is measured from, a probe whose two runs agree, a count that is wrong.

And it was checked against the defects it found. With M3's two bus-unit fixes undone,
`make timing` fails at every grade: the retry probe's two runs agree — BERR and HALT
were read on the rising edge — and 47A and 47B fail; and the skew test reads the
wrong bytes, failing 31A.

The RD68021 analysis's own end-to-end check, run by hand there: shortening AS from
three bus states to one makes the analysis report INFEASIBLE at every grade, naming
the contradiction and its round trip in nanoseconds.
