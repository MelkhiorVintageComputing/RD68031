# Places the MC68030 manuals disagree with themselves

Each entry: what the two sources say, which one this design follows, and why. Read this
before "correcting" something in the RTL that looks wrong against one reading of the
manual.

Transcription defects -- ones in the *document*, found while splitting it -- are recorded
in the READMEs of `Inputs/doc/MC68030_Doc_More_Readable/`. This file is for places where
the manual's own *content* contradicts itself.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/manual-contradictions.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---

## 1. How many long words figure 7-41's burst transfers

**Followed: the figure, and the state descriptions — CIIN ends the burst after the
long word it is asserted with.**

UM 7.3.7's list of figures says: "Figure 7-41 shows a burst operation aborted by
CIIN. Because CBACK corresponds to the next cycle, three long words are transferred
even though CBACK is only asserted for two clock periods." Figure 7-41 itself is
"Long-Word Operand Request from $07 with Burst Request — CBACK and CIIN Asserted"
and shows two transfers, A3:A2 = 01 then 10, with "burst mode ends, data not
cached" at the second.

The sentence describes figure 7-39, the one before ("a burst operation that fails
to complete normally due to CBACK negating prematurely"), whose A3:A2 row shows
three transfers. Read with figure 7-41 it contradicts both that figure and state 4,
where "the assertion of CIIN indicates that the data latched at the end of S4
should not be cached and that the burst should abort", and 6.1.3.2, where CIIN on a
later cycle "causes CBREQ to negate, aborting the burst operation".

`bus_burst_tb` has a burst with CIIN on the third long word end after three, and
one with CBACK for three long words transfer three.

---

## 2. When CBREQ is asserted

**Followed: 7.3.7 and 6.1.3.2 — a tag miss or a line with all four entries
invalid.**

7.3.4 state 1: "If the burst mode is enabled for the appropriate on-chip cache and
all four long words of the cache entry are invalid, (i.e., four long words can be
read in), CBREQ is asserted." 7.3.7 and 6.1.3.2 give two conditions: "the logical
address and function code signals of the current instruction or data fetch do not
match the indexed tag field", or "all four long words corresponding to the indexed
tag ... are marked invalid". The first is missing from 7.3.4.

Both are the caches' to decide (M10), and reach the bus unit as `req_burst` and
`fetch_burst`; what the bus unit decides — not for a read-modify-write, not with
CIOUT, not for the first part of an operand that spans two lines — is common to
all three paragraphs.

---

## 3. Where STERM's timing is described

7.1.7: "Refer to 7.3.2 Asynchronous Write Cycle for timing relationships of
STERM." 7.3.2 does not mention STERM; its timing is in 7.3.4 and 7.3.5, the
synchronous read and write cycles, and in 7.2.10. This design takes it from those.

---

## 4. Is BERR with STERM case 3 or case 4 of Table 7-9?

**Followed: the table and 7.5.1 — case 4, the late bus error, recognised on the
falling edge after STERM.**

The summary before Table 7-9 says: "Bus Error Termination: BERR is asserted in
lieu of, at the same time, or before STERM (case 3) or after STERM (case 4)".
The table's own rows say otherwise. Case 3 is STERM "NA" at N and "A" at N+2
with BERR "A/S" then "S" — BERR *before* STERM; case 4 is STERM "A" and BERR
"A" at N, with N+2 "not part of bus cycle" — BERR *with* STERM. 7.5.1's third
way of recognising a bus error is that same row: "BERR is asserted and
recognized on the next falling clock edge following the rising clock edge on
which STERM is asserted and recognized", and figure 7-51, "Late Bus Error with
STERM", draws it. Retry has the same split between its summary (case 5 "at the
same time") and its rows (case 6, "A" with STERM).

Both readings end in a bus error, so the result is the same either way; what
the choice decides is which edge samples it. This design samples BERR and HALT
on the falling edge after the rising edge that recognises STERM, and
`bus_error_tb` runs cases 4 and 6 with BERR asserted on STERM's edge and cases
3 and 5 one edge before it.

---

## 5. Does a halt or a retry negate RMC?

**Followed: no — RMC stays asserted while the bus is halted or waiting to
retry in the middle of a read-modify-write.**

7.5.2: on a retry "the processor terminates the bus cycle, places the control
signals in their inactive state, and does not begin another bus cycle until the
HALT signal is negated"; and, two paragraphs on, "the processor retries any
read or write cycle of a read-modify-write operation separately; RMC remains
asserted during the entire retry sequence". RMC is one of the bus control
signals (7.1.1, "Bus Control Signals"; 5.6), so the first sentence negates it
and the second keeps it. 7.5.3 says the same of a halt as the first sentence
does of a retry — "bus control signals are driven inactive" — and nothing
about RMC.

The second sentence is the specific one, and it is the one that keeps the
operation indivisible, which is RMC's whole purpose (7.3.3). This design keeps
RMC asserted, and driven, through a retry and through a halt alike;
`bus_error_tb` checks it during a halt, and `bus_arb_tb` that BG stays negated
through a retried write.

---

## 6. "BG will not be asserted while RMC is asserted" — but relinquish and retry

**Followed: 7.7.4 and 7.5.2 — the first read cycle of a read-modify-write may
be relinquished with BERR, HALT and BR.**

The note under figure 7-61: "The BG output will not be asserted while RMC is
asserted." 7.7.4: "One way for an alternate bus master to force the MC68030 to
release the bus applies only to the first read cycle of an read-modify-write
sequence. The MC68030 allows normal bus arbitration during this read cycle; a
normal relinquish and retry operation (asserting BERR, HALT, and BR at the same
time) is used." And 7.5.2: "The MC68030 does not relinquish the bus during a
read-modify-write operation, except during the first read cycle." That
relinquish needs BG, and by entry 5 RMC is asserted through the retry it is
part of.

This design lifts the RMC lock while — and only while — the first bus cycle of
a locked run waits to be retried: BG is asserted, the bus, RMC with it, is
three-stated once granted, and the retried read asserts RMC again. On every
later cycle of the run, BR waits for RMC to negate. `bus_arb_tb` checks both.

---

## 7. Does the bus wait for RMC to be released — single-wire arbitration

**Followed: 7.7.4's single-wire paragraph — BGACK releases the bus between the
cycles of a read-modify-write.**

7.7.4: "If T is true, the address, data, and control buses are placed in the
high-impedance state after the next rising edge following the negation of AS
and RMC." Two pages on, single-wire arbitration "applies to all bus cycles of
a read-modify-write sequence": "an alternate master forces the MC68030 to
release the bus by asserting BGACK and waits for AS to negate before taking the
bus ... AS must be observed to be negated (high) on two consecutive clock
edges". RMC does not negate inside the sequence, so read by the first sentence
the bus would never be released, and an alternate master that followed the
second would drive a bus the processor still drove.

This design releases on AS alone when BGACK is asserted, RMC three-stated with
the rest, and finishes the sequence — RMC asserted again — when the bus comes
back. `bus_arb_tb` checks it.

---

## 8. Which speed grades the MC68030 comes in

**Followed: the MC68030EC data sheet — 20, 25, 33.33, 40 and 50 MHz.**

The user's manual and the data sheet do not agree on what parts exist. UM 14.1,
ordering information, lists 20, 25 and 33.33 MHz parts and no others. UM 12.4.1
goes slower: it gives specification 31 "with a 16.67-MHz processor" as 50 ns, and
Table 12-3 has a column for an MC68030RC16. The data sheet, MC68030EC/D Rev. 1 —
the document UM 13 sends the reader to for "AC timing specifications" — prints
five columns, 20, 25, 33.33, 40 and 50 MHz; no 16.67 MHz, and two grades the
ordering list does not have.

`doc/plan.md` asked for a 16.67 MHz grade, which came from the MC68020's table and
matches the user's manual. It cannot be judged: there is no column of limits for
it. `make timing` judges the five the data sheet prints. Where the two documents
overlap they agree — specification 31 at 20 MHz is 43 ns in both.

---

## 9. Specification 48 is tighter at 20 MHz than at 25 MHz

**Followed: the data sheet as printed — 20 ns at 20 MHz, 25 ns at 25 MHz.**

"DSACKx Asserted to BERR, HALT Asserted", the most a device may take, is 20, 25,
18, 14 and 13 ns at the five grades: the only limit in the AC tables that loosens
as the part gets faster. `MC68030EC_split/README.md` confirms the digits against
the printed page and keeps the crop. Nothing in the user's manual gives the
number; 7.2.8 only says BERR and HALT "must be asserted within the time given as parameter #48 ... in any asynchronous system". The 20 MHz
value may be a misprint for 30, the MC68020's at 16.67 MHz.

It does not matter to this design. The core's side of 48 — the late BERR sample
one clock after DSACK is recognised — leaves 24 ns at 20 MHz against the printed
20, and would leave 14 against a 30. `make timing` uses the printed value.
