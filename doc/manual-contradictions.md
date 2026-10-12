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

**Settled at M11, with the operands.** Section 3's tables and the MC68851's PMOVE
admit register operands; PRM 6's MC68030 pages give PMOVE, PTEST, PLOAD and
PFLUSH FC,MASK,<ea> one addressing-mode table each, every one "control
alterable", with Dn and An marked "--" -- and UM 9.6 lists "only
control-alterable addressing modes supported for MMU instructions" among the
MC68030's differences from the MC68851, adding that the MC68851's other modes
"must be simulated or avoided". So a Dn, An, (An)+, -(An), PC-relative or
immediate operand is an MMU instruction the part does not define: the decoder
sends those operation words to `cp0_unimp`, and the one with no effective
address field at all, $F000, is accepted only with PFLUSHA's and PFLUSH
FC,MASK's command words (`MMUBADC`, `rd68031_seq`; `doc/mmu.md`). In supervisor
mode that is the F-line exception of UM 8.1.5, in user mode the privilege
violation of entry 13. `core_m030_tb` checks PMOVE TC,D0 among five such words.
GNU as does not hold to the table: it encodes `pmove label,%srp` with a `.text`
label as (d16,PC), which is not one of the modes and takes the F-line exception
here, so the test programs address every operand through an address register.

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

---

## 18. What a write-allocation miss invalidates

**Followed: figure 6-4 -- an aligned long word that misses the tag invalidates
the other three entries of the line; any other write that misses the tag
clears only the valid bits of the entries it touches.**

UM 6.1.2.1, as printed: "When a tag miss occurs on a write of long-word data
that is long-word aligned, the corresponding tag is replaced, and only the long
word being written is marked as valid. The other three entries in the cache line
are invalidated when a tag miss occurs on a misaligned long-word write or on a
byte or word write, the data is not written in the cache, the tag is unaltered,
and the valid bit(s) are cleared." Read as one sentence, the second half says
the whole line is invalidated by a misaligned or short write that misses.

Figure 6-4 says otherwise. Example 4, an aligned long word with no tag match,
lists "TAG <- TAG', b4-b7 <- b4'-b7', V0 <- 0, V1 <- 1, V2 <- 0, V3 <- 0": the
other three entries go with the replaced tag. Example 5, a misaligned long word
with no tag match, lists only "V2 <- 0" -- V0 and V3, which the write does not
touch, keep their valid bits (V1 was already clear). And the sentence's own
last clauses -- "the tag is unaltered, and the valid bit(s) are cleared" -- only
make sense one entry at a time: with the tag unaltered, the other entries still
belong to it and there is no reason to invalidate them.

So the paragraph is two sentences with the full stop lost: "... The other three
entries in the cache line are invalidated. When a tag miss occurs on a
misaligned long-word write or on a byte or word write, the data is not written
in the cache, the tag is unaltered, and the valid bit(s) are cleared." The
paragraph's own summary agrees: "an aligned long-word data write may replace a
previously valid entry; whereas, a misaligned data write or a write of data that
is not long word may invalidate a previously valid entry or entries" -- the
entries it writes. `rtl/rd68031_dcache.sv` does that, and `core_cache_tb` checks
all five examples, and the byte writes, in both WA modes.

---

## 19. Whether a read-modify-write cycle that misses in the ATC is searched

**Followed: UM 9.2.1, figure 9-8 and 8.1.2 -- every ATC miss is searched, an
RMW cycle's included.**

UM 9.2.1 step 4: "When no on-chip cache hit occurs (on a read) and no TTx
register matches or valid ATC entry matches, initiate a table search
operation"; figure 9-8 draws "WRITE OR RMW ACCESS" down the same ATC-miss arc
into "TABLE SEARCH OPERATION"; UM 8.1.2: "a miss in the ATC causes the processor
to automatically initiate a table search but does not cause a bus error
exception unless one of the specific conditions mentioned above is
encountered".

UM 9.10.3's example bus error handler says otherwise, in a comment on the case
where PTEST reports nothing: "No MC68030 status bits on. Must be memory
malfunction or RMW cycle with no ATC entry ... If Stack Frame shows RMW
instruction (SSW) then ATC did not have descriptor loaded and MC68030 cannot
search tables to load it. Explicitly load it and allow the task to continue
normally: PLOAD". That describes a part that takes a bus error on an RMW cycle
it has no translation for, and leaves the handler to load one.

The general statements are followed: they are three, they are normative, and
the example is an example. A handler written for the example's behaviour
still works here -- the bus error it expects simply does not come. Which one
the part does is for the oracles to say (M11 part 2), and `doc/mmu.md` lists
it as an open question. `core_mmu_tb` (`mmu_fault.S`, case 6) has a CAS miss
in the ATC, searched, and fault on write protection.

---

## 20. Which descriptor's limit the search checks

**Followed: UM 9.5.2, 9.5.1.1 and 9.7.1 -- the limit of the last long descriptor
fetched (or of the root pointer, unless FCL is set) bounds the next index; an
early termination descriptor's bounds the next index field; and the root
pointer's, when its DT is 1, is checked "regardless of the state of the FCL
bit".**

Figure 9-25 sets `y <- 'A'` on entering the level-A search, and figure 9-28's
limit check begins "y = 'RP' and FCL = 1: limit check not required" -- a test
that, with y already 'A', can never be true. Read literally the two give no
rule for the function code descriptor's limit at all. Figure 9-27 sends an
early termination through the same check with `y` left at the root pointer,
which with FCL set would skip an early termination descriptor's own limit --
against 9.5.1.1, "if the descriptor is an early termination page descriptor,
the limit field is still used as a check on the next index field of the
logical address". And the TC register's FCL description says "in this case,
the limit field of CRP or SRP is ignored", while 9.7.1, of a root pointer with
DT = 1, says "the processor performs a limit check, regardless of the state of
the FCL bit".

The prose is consistent once the last two are read as general and particular:
a root pointer's limit is ignored under FCL except when the root pointer is
itself the page descriptor. That is what `rd68031_mmu`'s walker does, and
`mmu_walk.S` checks a long table descriptor's limit, an early termination's,
and the root pointer's upper and lower limits with and without DT = 1.

---

## 21. Whether an indirect descriptor has a U bit, and when U is written

**Followed: figures 9-17 and 9-18 -- an indirect descriptor has no status bits,
so nothing accrues from it and nothing is written to it; and U is not written
in a descriptor whose own S bit makes the access a supervisor violation.**

Figure 9-29, "Fetch descriptor and update history", sets U in any descriptor
of type "4 byte or 8 byte" whose U is clear, and figure 9-25 only decides after
that fetch that a table-type descriptor at the bottom of the tree is an
indirect one. Taken literally, the search writes bit 3 of every indirect
descriptor it reads. But figure 9-17 gives a short indirect descriptor
"DESCRIPTOR ADDRESS" in bits 31-2 and DT in 1-0, and nothing else: bit 3 is an
address bit, and "setting U" there moves the pointer eight bytes -- the
indirect descriptor would point at another page descriptor from then on. Bit 2
is likewise an address bit, so accruing it as WP would write-protect pages at
random. Figure 9-18's long indirect descriptor has only an unused first long
word. So an indirect descriptor is read for its address and nothing else.

The same figure writes U before it accrues S, while 9.5.1.1 says U is set
"except after a supervisor violation is detected". A violation is detected by
reading the descriptor whose S bit makes it; this design does not set U in
that descriptor, nor in any below it, and sets M only "if the table search does
not encounter a set WP bit or a supervisor violation" (9.5.2).

`mmu_walk.S` checks a short and a long indirect descriptor left untouched, and
a PLOAD in user space through a supervisor-only table setting no U anywhere.
RD68031's first walker followed figure 9-29 and corrupted the short indirect
descriptor exactly as described (`doc/bugs-found.md`, M11).

---

## 22. Which DT code is "valid long" in UM 9.5.3.2

**Followed: UM 9.5.1.1 -- DT = 2 is "valid 4 byte", DT = 3 is "valid 8 byte".**

UM 9.5.3.2, on indirection: "If the DT field contains a 'valid long' ($2) or
'valid short' ($3) encoding". 9.5.1.1, 9.7.1 and figure 9-25 all give $2 as the
4-byte, short, descriptor and $3 as the 8-byte, long one, and figures 9-17 and
9-18 agree. The sentence has the two names swapped; the codes are what the
walker follows.

---

## 23. What PRM 6 says PMOVE does to TC when the check passes

**Followed: UM 9.7.2 -- a TC that fails the check is written with E cleared and
the configuration exception is taken; one that passes is written as it is.**

PRM 6, PMOVE: "If the E-bit = 1, consistency checks are performed on the PS and
TIx fields. If the checks fail, the instruction takes an memory management
unit configuration exception after moving the operand to the translation
control register. If the checks pass, the translation control register is
loaded with the operand and the E-bit is cleared." The last clause cannot be
right: it would make translation impossible to enable. UM 9.7.2 has it the
other way round: "If an MMU configuration exception occurs, the TC register is
updated with the data, and the E bit is cleared." `mmu_regs.S` loads a valid TC
with E set and reads E back set, and three invalid ones and reads E back
clear.

---

## 24. Whether PTESTR and PTESTW differ

**Followed: UM 9.8 -- only at level 0, when a TTx register matches with its R/W
bit not masked.**

PRM 6, PTEST's R/W field: "Specifies simulating a read or write bus cycle (no
difference for MC68030 MMU)". Its own description, a page earlier: "When the
level operand is zero, only the transparent translation of either read or
write accesses causes the operations of the PTESTR and PTESTW to return
different results", which is UM 9.8's "PTESTR and PTESTW instructions have
identical results except for PTEST0 when either TTx register matches the
logical address and the R/W bit of that register is not masked". `mmu_regs.S`
checks both against TT1 set for reads.

---

## 25. Whether a cache hit can still fault on an invalid translation

**Followed: figure 9-8 -- a read that hits in either cache is served, and the
MMU is not consulted.**

UM 6.1: "Whenever a read access occurs and the required instruction word or
data operand is resident in the appropriate on-chip cache (no external bus
cycle is required), the MMU is completely ignored, unless an invalid
translation resides in the MMU at that time (see next two paragraphs)." The
next two paragraphs define "cachable" and tell software to flush the caches
when a mapping changes -- "otherwise, if on-chip cache entries are valid for
pages with descriptors in memory marked invalid, processor operation is
unpredictable" -- and say nothing about a hit faulting. Figure 9-8's second
branch exits on "INSTRUCTION OR DATA CACHE HIT" before any TTx or ATC test.
So a hit is served whatever the ATC holds, and keeping the caches coherent
with the tables is the software's, as the paragraphs say.

---

## 26. Which destination CAS2 writes first

**Followed since M11 part 2: destination 2, then destination 1 -- the order of
both oracles. Until then: destination 1 first, from PRM 4's operation listing.**

PRM 4, CAS2, "Operation": "If Z, Update 1 → Destination 1; Update 2 →
Destination 2". UM figure 7-29, the read-modify-write flowchart, does not
order the writes: after a write it says only "if CAS2 instruction and only
one operand written, then go to" the next write. UM 8.2.2 calls the
instruction "up to four long word transfers" and orders none of them. PRM 4
makes the result undefined where it could be seen in memory -- "if the
operands overlap in memory, the results of any memory update are undefined".

So the order is visible only on the bus and in a fault on the second write,
and the one sentence that seems to fix it is a statement of the result, not a
bus specification: the same listing puts "Destination 1 → Compare 1;
Destination 2 → Compare 2" in that order too, and a later sentence of the same
page ("If Dc1 and Dc2 specify the same data register and the comparison
fails, memory operand 1 is stored in the data register") makes that
register write land in the other order (`doc/bugs-found.md`, M6).

At M6 UAE030's "destination 2 first" was taken for an oracle quirk on the
strength of the listing (`doc/m6-mismatches.md` b5, normalised in the vector
generator until M11 phase B, which removed the normalisation). At M11 part 2 a second, independent implementation, AP68030 --
a pin-level core -- wrote destination 2 first as well (`doc/m11-mismatches.md`,
Q-B: bus probe phase 6, `W $E048` then `W $E040`). Two implementations that
share no code agree, and the manual's line is not a bus order; the user
decided to follow them. `cas2_swap` in `tools/ucode/program.py` writes
destination 2 first. A fault on either write still reruns the whole locked
sequence with DF set (UM 8.2.3, `doc/checkpoint.md` rule 5); on the second
write, now destination 1's, the rerun reads destination 2's update back and
fails its second compare. `core_fault_tb` faults each of the four accesses.

---

## 27. Which modes transfer multiple coprocessor registers allows

**Followed: UM 10.4.16's text -- to the coprocessor, control and (An)+; from it,
control alterable and -(An).**

UM 10.4.16: "For transfers from the effective address to the coprocessor (DR=0),
the control addressing modes and the postincrement addressing mode are valid. For
transfers from the coprocessor to the effective address (DR = 1), the control
alterable and predecrement addressing modes are valid." Figure 10-38 then draws
two operands written to -(An). Table 10-6, the summary of the exceptions each
primitive can cause, gives the F-line cases as "EA Not Control Alterable or (An)+
for CP to Memory Transfer" and "EA Not Control Alterable or (An) for Memory to CP
Transfer" -- the increment modes the other way round, and control alterable where
the text has control for reads. The MC68020 manual has the same table.

The text, the figure and the instructions an MC68881 builds on the primitive
(FMOVEM to -(An), from (An)+, MC68881 UM section 4) agree; the table is the odd
one out. `cp_mcreg` and the twelve-byte handlers take the text's modes, and
`core_cpif_tb` refuses -(An) for a transfer to the coprocessor.

---

## 28. Which modes cpRESTORE takes

**Followed: UM 10.2.3.4.1 and PRM 6's table -- control, (An)+, and the
immediate.**

UM 10.2.3.4.1: "All memory addressing modes except the predecrement addressing
mode are valid", which includes the immediate and the PC-relative modes. PRM 6's
text for cpRESTORE: "Only postincrement or control addressing modes can be used",
which does not include the immediate; the table under the same sentence lists
`#<data>`, 111 100. Two of the three allow it. With it, the state frame is the
words after the operation word: `cp_restore_imm` takes the format word, its
reserved word and the state from the stream, and the program goes on after them.
`core_cpif_tb` restores a frame from an immediate.

---

## 29. What unit the state frame's length is in

**Followed: bytes.**

UM 10.2.3.1: the processor "writes the long words that form the coprocessor state
frame to descending memory addresses, beginning with the address specified by the
sum of the effective address and the format word-length field multiplied by
four." UM 10.2.3.2, a page later: "The lower byte of the coprocessor format word
specifies the size in bytes (which must be a multiple of four) of the coprocessor
state frame", and UM 10.2.3.2.4 and 10.5.2.7 refuse a length "not a multiple of
four" -- which only means anything for a count of bytes. The MC68881's idle frame
is `$1F18`: "24 bytes of internal state are saved in the idle state frame for the
MC68881" (MC68881 UM 6.4.2.2).

So the length is a byte count and "multiplied by four" is a slip: the frame is the
format word's long word and `length` bytes after it, and the first long word the
coprocessor gives goes at the effective address plus the length, which is the
highest long word of the frame. `core_cpif_tb` saves frames of four, eight and
twenty-four bytes, restores frames of four and eight, and checks where every long
word went.

---

## 30. Whether a trace on change of flow holds the dialogue open

**Followed: UM 10.5.2.5's last paragraph -- it does not; only a trace on
instruction execution does.**
Confirmed by the user after M12.

UM 10.4.4: "If a trace exception is pending, however, the main processor does not
terminate the instruction dialogue until it reads a null, CA=0, PF=1 primitive",
and UM 10.5.2.5: "When a trace exception is pending, however, the main processor
must ensure that all processing associated with a cpGEN instruction has been
completed before it takes the trace exception". Neither says which trace. Under
T1 T0 = 01 a trace becomes pending in the middle of the dialogue, once the
coprocessor has transferred the status register or the scanPC in, and read
literally both sentences would hold the dialogue from then on. UM 10.5.2.5 goes on:
"If T1:T0=01 ... a trace exception is taken for the instruction only when the
coprocessor issues a transfer status register and scanPC primitive with DR = 1
during the execution of that instruction. In this case, it is possible that the
coprocessor is still executing the cpGEN instruction concurrently when the main
processor begins execution of the trace exception handler. A cpSAVE instruction
executed during the trace on change of flow exception handler could thus suspend
the execution of a concurrently operating cpGEN instruction." That cannot happen
if the change of flow held the dialogue until PF = 1.

So "pending" in the first two sentences is a trace on instruction execution,
pending from the start of the instruction, and the trace on change of flow is
taken at the boundary after the dialogue ends however it ends (`trace_hold` in
`rd68031_seq`). RD68021 held the dialogue for both (`doc/bugs-found.md`, M12).
`core_cpif_tb` traces a dialogue under each mode.
