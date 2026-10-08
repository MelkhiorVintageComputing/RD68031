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
20, and would leave 14 against a 30. `make timing` uses the printed value. The user's decision, after M3: keep it
as printed, and revisit the value only if it ever binds.

---

## 10. Where the long frame's version number is

**Followed: UM 8.1.8, 8.1.13 and Table 8-6 — the top nibble of the word at
`SP+$36`.**

UM 8.1.8: RTE "compares the internal version number of the processor to that
contained in the frame at memory location SP+54 (SP+$36)"; UM 8.1.13: "the
version number is located in the most significant nibble (bits 15–12) of the
word at location SP+$36 in the long stack frame"; and the MC68030 manual's own
Table 8-6 draws `VERSION #` on the `+$36` row. The programmer's reference
manual's figure B-12, "MC68020 and MC68030 Long Bus Cycle Stack Frame, Format
$B", draws it on the row labelled `+$38`, with "INTERNAL REGISTERS, 3 WORDS"
spanning `+$30` to `+$36`. The MC68020 manual's Table 6-5 has the same slip, and
RD68021 recorded it there.

Arithmetic settles it: three words from `+$30` end at `+$35`, and eighteen
from `+$38` end at `+$5B`, the last byte of a 46-word frame. A version at
`+$38` would leave one word unaccounted for and make the frame 47 words.
`tools/ucode/frames.py` checks the frame gapless and 46 words long with the
version at `+$36`.

---

## 11. "A short format stack frame" for the format error

**Followed: Table 8-6 and UM 10.5.2.7 — the four-word frame, format `$0`.**

UM 8.1.8, on the format error: "This exception saves a short format stack
frame, generates exception vector number 14". In the same section "short" names
format `$A`, the short bus fault frame (8.1.2, 8.2.1, Table 8-6: "SHORT BUS CYCLE
FAULT STACK FRAME (16 WORDS)"). Table 8-6 lists "Format Error" under the four-word
frame, format `$0`, with the stacked program counter pointing to the "RTE or
cpRESTORE instruction", and UM 10.5.2.7 says of the coprocessor's format errors
"the MC68030 uses the four-word pre-instruction stack frame and the format error
vector number 14".

The format error is not a bus fault, has nothing to put in a special status
word, and is restarted by RTE as a pre-instruction exception; "short" in 8.1.8
means "four-word". `core_exc_tb` checks the four-word frame for all ten format
codes the MC68030 does not have, and `core_fault_tb` for a long frame of another
version.

---

## 12. Section 3's MMU instructions are the MC68040's

**Followed: UM 9.8 and PRM 6, "(MC68030 only)" -- PFLUSH by function code and
mask, PTEST with a function code, a level and an optional address register, and
neither touching what the other does.**

UM 3.2.10: "The PFLUSH instructions flush the address translation caches (ATCs)
and can optionally select only nonglobal entries for flushing. PTEST performs a
search of the address translation tables, storing results in the MMU status
register and loading the entry into the ATC." Table 3-10 lists PFLUSHA,
PFLUSHA.N, PFLUSH (An), PFLUSH.N (An) and PTEST (An), and Table 3-14 gives PFLUSH
the syntaxes PFLUSH (An), PFLUSHN (An), PFLUSHA and PFLUSHAN and PTEST only
PTESTR (An) and PTESTW (An), with "entry → ATC".

Those are the MC68040's forms. The MC68030 has no global or nonglobal ATC entries
(UM 9.6 lists "ATC Entries Defined as Shared Globally" among the MC68851 features
it does not have), and UM 9.8 says of its PTEST: "The PTEST instruction does not
alter the ATC." PRM 6's MC68030 pages give PFLUSHA, PFLUSH FC,MASK and PFLUSH
FC,MASK,<ea>; PTESTR and PTESTW FC,<ea>,#level with an optional An; PLOADR and
PLOADW FC,<ea>; and PMOVE and PMOVEFD -- the forms the assembler produces for
`-mcpu=68030`, and the encodings `mmu_op` accepts. Table 3-14's PLOAD and PMOVE
rows agree with section 9.

---

## 13. Which exception a CpID-0 word takes in user mode

**Followed: UM 9.8 and 8.1.5 -- a privilege violation, for every CpID-0 word,
implemented or not.**

UM 10.5.2.2: "Any F-line operation word with bits [8:6] = 110 or 111 causes the
MC68030 to initiate exception processing without initiating any communication
with the coprocessor", in a section about F-line emulator exceptions, and UM
10.1 calls the CpID-0 words with a nonzero type "unimplemented instructions that
cause the MC68030 to begin exception processing" without naming the exception.
UM 9.8 is explicit: "If execution of a[n] unimplemented F-line instruction with
CpID = 0 is attempted in the user mode, the MC68030 takes a privilege violation
exception", and in supervisor mode an F-line exception; UM 8.1.5 says the same.

The two readings meet once UM 10.1's first sentence is applied -- "F-line
operation words, in which the CpID is zero, are not coprocessor instructions
for the MC68030" -- so section 10's rules about types 110 and 111 are about
CpIDs 1 to 7. `core_m030_tb` checks a type-001 and a type-111 CpID-0 word in
each mode.

---

## 14. Which offset BFFFO adds, when the field is in a data register

**Followed: the literal reading -- the instruction's whole offset, reduced modulo
32 only to locate the field.**

PRM 4, BFFFO: "The bit offset of that bit (the bit offset in the instruction plus
the offset of the first one bit) is placed in Dn. If no bit in the bit field is
set to one, the value in Dn is the field offset plus the field width." A register
offset is "in the range of -2^31 to 2^31 - 1". For a field in a data register
the manual never says what happens to an offset outside 0-31 -- UM 2.2.1 only
says the field "wraps around within the register" -- so it leaves open whether
the sum uses the register's value or the value reduced modulo 32 that the field
was actually found at. The two are congruent modulo 32 and address the same
field when fed back.

RD68021 took the reduced one (its own `doc/manual-contradictions.md`, "What
BFFFO adds to its scan result"). This design withdraws that reading: the
sentence names "the bit offset in the instruction", which for a register offset
is the register's value, and nothing in the paragraph reduces it. The two
instruction-level oracles of M6 agree with the literal reading -- the sweep's
oracle and the cputest corpus, whose generator was validated against real
processors (`doc/m6-mismatches.md` A2) -- which is evidence about the part, not
the reason. `core_insn_tb` checks offsets 37 and -27 and an empty field.

---

## 15. What LINK A7 pushes

**Followed: PRM 4's operation -- the stack pointer after the decrement.**

PRM 4, LINK: "Operation: SP - 4 → SP; An → (SP); SP → An; SP + dn → SP." With
An = A7 the second step stores the decremented stack pointer. The description --
"Pushes the contents of the specified address register onto the stack. Then
loads the updated stack pointer into the address register" -- does not say which
value of A7 "the contents" are, so it does not contradict the operation, but it
does not confirm it either.

The cputest corpus records the other value: in all 10 sampled tests of
`LINK.W A7` (`$4E57`) and `LINK.L A7` (`$480F`) the long word pushed is A7 from
before the decrement ($8400 for A7 = $8400, where the operation gives $83FC).
The corpus's generator was validated against real processors, so this is likely
what the silicon does: the part reads An before it steps the stack pointer. It
is still not what the manual writes, and nothing about it is needed by code a
compiler produces (A7 as a frame pointer makes no sense), so this design follows
the manual. `doc/divergences.md` records the difference from the part, and
`core_cputest_tb` sets the two encodings aside, by name, as excluded rather than
failed. `core_insn_tb` checks the manual's value.

---

## 16. What UNLK A7 leaves in A7

**Followed: PRM 4's description -- A7 is the long word pulled from the stack.**

PRM 4, UNLK: "Operation: An → SP; (SP) → An; SP + 4 → SP." Read literally with
An = A7, the last step adds four to the long word just loaded. The description
says the opposite order: "Loads the stack pointer from the specified address
register, then loads the address register with the long word pulled from the
top of the stack" -- the stack pointer is stepped as part of the pull, and the
address register is loaded last. For any An but A7 the two are the same; for A7
they differ by four, and the manual contradicts itself.

The description is followed, for two reasons: it is the sentence that says what
ends up in the address register, which is the question; and the cputest corpus
agrees with it -- all 4 sampled tests of `UNLK A7` (`$4E5F`) expect A7 to be the
long word loaded (`doc/m6-mismatches.md` Q3). RD68021 gave a third answer, the
old stack pointer plus four (`doc/bugs-found.md`, M6). `core_insn_tb` checks
UNLK A7.

---

## 17. When a trap's trace is taken

**Followed: UM 8.1.12 -- straight after the trap's exception processing, before
the trap handler runs.**

UM 8.1.4, on TRAP, TRAPcc, TRAPV, cpTRAPcc, CHK, CHK2 and the zero divide: "If
tracing is enabled for the instruction that caused the trap, a trace exception
is taken after the RTE instruction from the trap handler is executed, and the
trace corresponds to the trap instruction; the trap handler routine is not
traced." Read literally, the trace handler runs once the trap handler has
returned.

UM 8.1.12, with Table 8-5 putting the traps in group 2 and the trace in group 4:
"if simultaneous trap, trace, and interrupt exceptions are pending, the
exception processing for the trap occurs first, followed immediately by
exception processing for the trace and then for the interrupt. When the
processor resumes normal instruction execution, it is in the interrupt handler,
which returns to the trace handler, which returns to the trap exception
handler." UM 8.1.7 says the same of an exception an instruction forces: "the
forced exception processing occurs before the trace exception is processed". In
this reading the trace handler runs first, and its frame's program counter is
the trap handler's address.

The two agree that the trap handler is not traced and that the trace is the
trap instruction's; they disagree about when it is taken. This design follows
8.1.12 and 8.1.7, which say it twice, give it a priority table and a worked
example, and are what RD68021 did as well: the trace frame stacked straight
after the trap's has +$08 the trap instruction and +$02 the trap handler.
`core_excpri_tb` checks it for TRAP and CHK, and 8.1.12's own example with an
interrupt.
