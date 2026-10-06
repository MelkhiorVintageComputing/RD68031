# AC-timing analysis

Judges an event log from `sim/tb/rd68031_timing_tb.sv` against the AC tables of
the MC68030EC/D data sheet (`MC68030EC_split/ac-electrical-specifications.csv`).
`doc/ac-timing.md` is the account of what it found; this is the map.

```sh
make timing                                        # measure and judge, all five grades
make timing-verbose                                # ... and every grade in detail
make timing PADSKEW=5                              # loosen the pad model

python3 tools/timing/specs.py --dump --freq 50     # the limits, in nanoseconds
python3 tools/timing/anchors.py                    # what each specification measures
python3 tools/timing/anchors.py --unanchored       # ... and what it does not
python3 tools/timing/events.py build/timing-50.log # what a log holds, probes included
python3 tools/timing/feasible.py                   # the solver's own self-test
```

| | |
|---|---|
| `specs.py` | the data sheet as data: 76 specifications, five grades (20, 25, 33.33, 40, 50 MHz). Holds the judgements the CSV cannot — that 45 and 45A each carry two rows, that seven rows are in clock periods and need converting, that an empty cell is the data sheet's em dash |
| `anchors.py` | which events each specification separates, read off figures 3 to 8; where each input must be sampled; the counts and the stimulus checks; and, for the three that are not a question about this core at all, why. It fails if a specification is in no table |
| `events.py` | reads a log; the pairing rule, stated once, that every separation depends on |
| `feasible.py` | the difference-constraint system, Bellman-Ford, the margin calculation, and a known-answer self-test, which `make timing` runs first |
| `analyse.py` | the command line and the verdict |

## The things worth knowing before changing any of it

**The limits live here and not in SystemVerilog.** The testbench emits times and
nothing else; no testbench knows what a specification is. That is what lets a
wrong anchor be fixed with a one-line edit and a re-analysis in milliseconds
instead of a re-simulation, and it is what would let a second core, in another
language, be judged by exactly the same code.

**Three kinds of event.** A pin of the core (`as.assert`) has a pad delay, which
the solver chooses. An input as the testbench drives it (`in.br.assert`) and an
edge inside the core (`smp.data`, the edge read data is latched on; `clk.end`,
the clock low a cycle ends on) have none: they are the fixed node `#0`. That is
what lets a requirement on a *device* be answered from the processor's side —
"a device may hold DSACK up to 35 ns after the clock low" becomes "the core's
next sample of DSACK is at least 35 ns, plus its setup time, after it".

**Inputs are probed, not assumed.** An RTL model samples an input at one
instant. The testbench changes each input half a nanosecond before and half a
nanosecond after an edge, and if the core behaves differently the two times, it
sampled inside that nanosecond. The analysis checks that nanosecond against the
input's setup and hold window at each grade, and that the edge is the kind the
data sheet names. A probe that does not split — the same behaviour either side
of the edge — fails: that is how the retry's rising-edge sample of BERR and HALT
was found.

**INFEASIBLE is a proof; FEASIBLE is conditional.** Each pin transition has its own
delay variable, so unless they are tied the solver may give one pin a large delay
when it asserts and a small one when it negates. Real pads do not work that way.
`PADSKEW` is how far apart one pin's transitions may be and defaults to **0** — one
delay per pin. And every pad delay is at least zero: a pin cannot move before the
clock edge that moves it, which the solver would otherwise happily assume for a
pin whose specifications give only a maximum.

**A bound's margin is not a margin.** Bellman-Ford returns an assignment sitting
hard against some corner, so whichever bound it landed on reports zero room
whatever the design does; and a bound's true margin is `hi − lo`, which is what the
data sheet printed and says nothing about this design. The binding constraint is
therefore the tightest **separation** printed in nanoseconds. Limits printed in
clocks — the arbitration handshakes, the RESET instruction's 512 — are reported on
a line of their own: a count met exactly has no room by definition, and would
otherwise be the binding constraint at every grade.

**Nothing is quietly skipped.** A specification the log gives nothing to measure,
a pin that moves on the other edge from the one its specification is measured
from, a probe that does not split, a count that is wrong: each fails the grade.

## One run per speed grade

The separations are measured in clock edges, so a recording made at one frequency
is evidence about that frequency and nothing else: judging a 50 ns recording
against the 50 MHz limits would credit the design with half-clocks it does not
have there. `make timing` runs the testbench five times, at each grade's minimum
cycle time from specification 1, and analyses each log against its own column.
