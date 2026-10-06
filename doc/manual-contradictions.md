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
