# The MMU

The MC68030's paged memory management unit, as M11 builds it: the six
registers, transparent translation, the 22-entry address translation cache, the
table search, the bus errors the MMU raises, CIOUT and the caches it inhibits,
the four MMU instructions, and MMUDIS. Everything here is UM section 9 unless a
citation says otherwise; section 8 supplies the exceptions (8.1.2, 8.1.10,
8.2.3), section 7 the bus side of the table search (7.3.3), section 6 the
caches (6.1, 6.1.2), section 5 MMUDIS (5.11.2), and PRM 6 the instructions'
encodings ("MC68030 only").

| | |
|---|---|
| RTL | `rtl/rd68031_mmu.sv` (registers, ATC, walker), `rtl/rd68031_mmu_xl.sv` (one lookup); translation of every cycle, and the operand set aside for its second page's search, in `rtl/rd68031_biu.sv`; the instructions in `tools/ucode/program.py` (`mmu_op`) and `rtl/rd68031_seq.sv` |
| Tests | `core_mmu_tb` with `sim/programs/mmu_regs.S`, `mmu_walk.S`, `mmu_fault.S`; `core_m030_tb` for the decode |
| Not here | the oracle comparison (`make cosim-mmu`, the PMMU vector groups, AP68030) -- M11 part 2 |

---

## The registers -- 9.7

| Register | Width | Kept | Reset (`rst_n`) | RESET pin (8.1.1, 9.2.2) |
|---|---|---|---|---|
| TC | 32 | E (31), SRE (25), FCL (24), PS, IS, TIA-TID: `$83FF_FFFF` | 0 | E cleared, the rest kept |
| CRP, SRP | 64 | L/U, LIMIT, DT, table address 31:4: `$FFFF_0003`, `$FFFF_FFF0` | 0 | kept |
| TT0, TT1 | 32 | base, mask, E, CI, R/W, RWM, FC base, FC mask: `$FFFF_8777` | 0 | E cleared, the rest kept |
| MMUSR | 16 | B, L, S, W, I, M, T, N: `$EE47` | 0 | kept |

What a register does not keep reads as zero. UM 9.7.2 says that of TC in so
many words ("all unimplemented fields of this register are read as zeros and
must always be written as zeros"); UM 9.5.1.1 makes a root pointer's reserved
bits "not alterable" and UM 9.7.1 its bits 3-0 "ignored when written"; figures
9-37 and 9-38 draw zeros in TTx's and MMUSR's other bits. The ATC is not
touched by either reset beyond `rst_n`'s initialisation: "a reset of the
processor does not invalidate any entries in the ATC" (9.2.2).

**PMOVE checks three registers** (9.7.5.3, 8.1.10): TC written with E set must
have PS of `$8` or more and IS + PS + the TIx fields "added until the first zero
is encountered" equal to 32; SRP and CRP may not have DT zero. A refused value
is written all the same -- TC with E cleared ("the TC register is updated with
the data, and the E bit is cleared", 9.7.2), a root pointer as it was given
("the register is loaded with the new value before the exception is taken") --
and the instruction then takes the MMU configuration exception, vector 56, a
post-instruction exception on the six-word format $2 frame: the next
instruction at +$02, the PMOVE at +$08.

## Transparent translation -- 9.3, 9.7.3

A TTx register matches when it is enabled, the function code agrees with FC
BASE outside FC MASK, A31-A24 agree with the logical base outside its mask,
and either RWM is set or the access's R/W equals the register's -- "if the RWM
bit equals zero, neither the read nor the write of any read-modify-write cycle
is transparently translated" (9.7.3). A match is used as it stands: the
logical address is the physical one, nothing is protected, nothing searched,
and CIOUT is the matching registers' CI bits ORed. TTx are consulted before the
ATC and whatever TC.E and MMUDIS say (9.7.3, 9.2.3); CPU space (FC 7) matches
neither -- figure 9-8 handles it before them. PTEST level 0 reports a match as
T; levels 1-7 ignore TTx (Table 9-3).

## The ATC -- 9.4

Twenty-two entries, fully associative. Each holds the manual's tag (V, FC2-FC0,
LA31-LA8) and data (B, CI, WP, M, PA31-PA8), and one history bit. A lookup
compares FC and the logical address above the page offset: "for larger page
sizes, the appropriate number of least significant bits of this field are
ignored", taken from the current TC.PS.

**Replacement.** UM 9.4: "if possible, when the ATC stores a new address
translation, it replaces an entry that is no longer valid. When all entries in
the ATC are valid, the ATC selects a valid entry to be replaced, using a pseudo
least recently used algorithm. The ATC uses a validity bit and an internal
history bit." The manual does not give the algorithm; this design uses the
one-bit not-recently-used scheme those two bits suggest:

- the history bit is set when an entry is loaded, and when an access the bus
  unit starts was translated by it (not when a TTx or MMUDIS decided it);
- when every valid entry's bit would then be set, all but the ones just set are
  cleared;
- the victim is the lowest-numbered invalid entry, or else the lowest whose
  history bit is clear.

A search's result goes into the entry already holding that logical address and
function code, if one does -- a PLOAD replaces it ("any existing entry in the
ATC that translates the specified address is flushed", 9.8), and so does the
search that sets M ("invalidating the old ATC entry, and creating a new entry
with the M bit set", 9.4).

**Entries with B set** are how a failed search is remembered: "this bit is set
for an entry if a bus error, an invalid descriptor, a supervisor violation, or a
limit violation is encountered during the table search ... When B is set, a
subsequent access to the logical address causes the MC68030 to take a bus error
exception" (9.4). They stay until a PFLUSH, a PLOAD for the address or the
replacement removes them -- so a handler that repairs the tables flushes the
entry before it returns, as the manual's own handler does with PLOAD (9.10.3).

**What the ATC is consulted for**, figure 9-8:

| Access | Verdict |
|---|---|
| CPU space | untranslated, CIOUT negated |
| a TTx matches | untranslated, CIOUT from CI |
| TC.E clear or MMUDIS asserted | untranslated, CIOUT negated |
| no entry | a table search, then the access again |
| an entry with B | a bus error |
| an entry with WP, for a write or any cycle with RMC (8.2.3) | a bus error |
| an entry with M clear, for a write or any cycle with RMC | a table search, then the access again |
| otherwise | the entry's physical address and CI |

A read that hits in either cache never reaches the MMU (figure 9-8's second
branch, UM 6.1): it is served whatever the ATC says.

---

## Where translation happens -- the bus unit

**Every bus cycle is translated before it starts.** The bus unit looks up a
cycle when it is the first of a new operand -- the sequencer's request, a
prefetch, RTE's rerun of a faulted operand, a posted write -- and again when it
is the first cycle of an operand that enters a page other than the one its
cycles have been in (`rd68031_mmu_xl`, one instance for the bus unit). An
operand is at most five bytes and a page at least 256, so that is at most once
more; the bytes the data cache will answer are never in a cycle and are never
looked up. Then:

- **a table search is needed**: the cycle does not start, and the walker runs.
  For the first page that is before anything of the operand has moved; for
  the second it is between the first page's cycles and the second's, so the
  bytes in the first page have already gone -- written, for a write -- and
  the operand is **set aside** (`pk_*` in `rd68031_biu`) while the walker's
  own operands use the engine, then taken back, looked up again, and run on;
- **the page is refused**: the cycle "starts" as `ST_ABT`, which drives no pin
  and ends half a clock later in S5 with a bus error -- which the operand
  engine reports exactly as it reports BERR, so the frame, the SSW, the
  residual, posted writes, prefetch faults and RTE's rerun all work
  unchanged. For the second page, the first part has gone and the frame
  carries the residual: "+$10 the logical address of the retried cycle -- for
  an operand split across a page boundary, of its residual"
  (`doc/checkpoint.md`), SIZE the residual's;
- **otherwise it starts**, and the bus unit keeps the page's translation --
  its physical base and CI -- for the operand's other cycles in it.

So a misaligned operand across two pages, neither in the ATC, is: the first
page's search, the operand's cycles in the first page, the second page's
search, the cycles in the second -- `MOVE.L $010002FE,D1` reads `R $9040, W
$9040, R $9208, W $9208` (the search for page B[2]), `R $C2FE`, `R $9040, R
$920C, W $920C` (B[3]), `R $C300`. That is UM 7.1.1's order applied to each
cycle as it comes -- "if a miss occurs in the address translation cache (ATC)
of the memory management unit (MMU), or if the MMU finds a fault with the
access, the processor aborts the cycle before asserting AS" -- and the
oracles': both of them for a read and for a read-modify-write's read; for a
write, UAE030's, where AP68030 searches both pages before the first part
(`doc/m11-mismatches.md`, Q-A and c12). Until M11 part 2 the core searched
both pages before the first cycle; the user decided to change it.

What follows from it:

| | |
|---|---|
| a read-modify-write across two pages (`CAS.W`, `CAS.L` misaligned) | RMC stays asserted from the operand's first cycle through the second page's search -- whose cycles assert it anyway (UM 9.5.2) -- to the operand's last cycle; the arbiter grants nothing in between (UM 7.7.4). Protection is checked page by page, for an RMW as for a write (UM 8.2.3): a write-protected second page refuses the read's second part, the first having been read, and RTE with DF set reruns the whole instruction (`doc/checkpoint.md` rule 5) |
| a posted write across two pages | the sequencer has gone on; the write is set aside while its second page is searched, and counts as outstanding throughout (`post_busy`): nothing else is taken by the bus unit, and the microwords that wait for posted writes wait for it. A refusal of its second page is its fault, taken where rule 9 says. PMOVE to a register waits for it before it commits, so that an instruction after the write cannot change the translation of the write's second page |
| the data cache, half a hit | a read whose first long word hits starts its cycles at the second, and is looked up there (UM 6.1.2, 7.2.7); one whose last long word hits stops short of it, and its second page is never looked up. The cycles that complete a long word from a narrow port stay inside that long word, and so inside its page |
| a burst | the operand's first cycle never asks for one when it spans two lines (UM 6.1.3.2); the cycle that enters the second page may, as any later cycle of an operand may, once and if CBREQ has not already been asserted for the operand |
| OCS | the cycle the set-aside operand resumes with is not the operand's first, and has no OCS (UM 7.1.1) |
| STATUS | three clocks for the second page's search, as for any search an access starts |

Keeping each page's translation until the operand is out of it is what lets a
PFLUSH run while a prefetch or a posted write is still on the bus without that
page's later cycles finding the ATC changed under them. **MMUDIS** as the MMU
sees it is held from the edge an operand is taken to the edge it finishes,
including while it is set aside: UM 9.2.3, "the disabling of address
translation does not become effective until the entire transfer is complete".
RTE's rerun of an operand is a new candidate: it is translated afresh, page by
page.

The physical address goes to A31-A0; the operand engine, the caches and the
fault frame keep working with the logical one (`cyc_addr` against
`cyc_paddr`).

## The table search -- 9.5.2, 9.5.4, figures 9-25 to 9-29

**A hardware walker, not microcode.** UM 9.1 says the part's search is
"performed by microcode and dedicated logic". What is architectural is its bus
traffic and its results, and both are reproduced; how it is sequenced inside
the part is not. Microcode would have needed the sequencer to stop whatever it
was doing -- or nothing, for a prefetch or a posted write, which belong to no
microword (`doc/checkpoint.md` rule 9) -- run the search, and come back, with
every register the search used kept out of the frame. A walker beside the bus
unit starts from the access that needs it, needs nothing from the sequencer,
and makes `doc/checkpoint.md` rule 11 (a search is never checkpointed and never
interrupted) a property of the hardware. PTEST and PLOAD start the same walker
from the sequencer and stall until it is done.

The walker is a requester of the bus unit like the fetch unit, with priority
over every other one while it runs. Its operands are four-byte reads and writes
at physical addresses, dynamically sized like any other (a table may be on an
8- or 16-bit port), and:

- **in supervisor data space, with RMC asserted from its first cycle to its
  last** -- UM 7.3.3: "table search accesses required for the MMU are always
  read-modify-write cycles to the supervisor data space"; UM 9.5.2: "the
  read-modify-write (RMC) signal is asserted on the first bus cycle of the
  search and remains asserted throughout, ensuring that the entire table search
  completes without interruption". This settles the M0 question of the table
  accesses' function code: FC = 5.
- **never cached, never with CIOUT, never burst** -- "no data is internally
  cached for table search accesses since the MMU uses physical addresses"
  (7.3.3); "the MC68030 asserts RMC but not CIOUT" (12.1); no burst during a
  read-modify-write (7.3.3).

**The search** follows figure 9-25. The root pointer is SRP when SRE and FC2
are both set, CRP otherwise (Table 9-2). With FCL set the first table is
indexed by the function code, and the root pointer's limit is not checked
against it ("the function code level cannot be limited", 9.7.1). Then
levels A to D, each indexed by its TIx field of the logical address after the
IS bits and the fields above it, until a page descriptor, an invalid one, a
limit violation, a bus error, or the last level with a non-zero TIx. A
descriptor's DT says the size of the next table's descriptors (4 or 8 bytes);
a long one is read as two long words.

| Ends at | Physical address of the page (figure 9-27) |
|---|---|
| a page descriptor at the last level | its page address |
| a page descriptor above it -- early termination | its page address plus the logical address with the IS bits, the index fields used so far and the page offset cleared (9.5.3.1) |
| the root pointer with DT = 1 | its table address plus the same offset (9.7.1) |
| a table descriptor at the last level -- indirect | the page address of the descriptor it points at, in the format its DT names; anything but a page descriptor there is invalid (9.5.3.2) |

**Limits** (9.5.2, figure 9-28): a long descriptor's -- and the root pointer's,
unless FCL is set -- L/U and LIMIT bound the index into the next table:
L/U = 1, the index must be at least the limit; L/U = 0, at most. An early
termination descriptor's limit bounds the next index field (9.5.1.1), and the
root pointer's DT = 1 limit is checked "regardless of the state of the FCL bit"
(9.7.1). A violation ends the search: B in the entry, L and I in MMUSR.

**Accrued status** (figure 9-26, 9-29): WP from every descriptor, ORed; S from
every long one, and a supervisor violation when it is set and FC2 is clear;
CI and M from the page descriptor. Nothing from an indirect descriptor, which
has no status bits: a short one's bits 31-2 are the descriptor address (figure
9-17), a long one's first long word is unused (figure 9-18) --
`doc/manual-contradictions.md` 21.

**History** (9.5.1.1, 9.5.2): U is set in every descriptor the search reads
whose U is clear -- "except after a supervisor violation is detected", which
here includes the descriptor whose own S bit makes the violation; M in the
page descriptor for a write (or a read-modify-write, or PLOADW) "if the table
search does not encounter a set WP bit or a supervisor violation". The
update is a write of the descriptor's first long word, still under RMC: "the
read and write operations to update the history bits are guaranteed to be
uninterrupted". Invalid descriptors are never written (9.5.3.4), nor indirect
descriptors (they have no U bit), nor the non-page descriptor an indirect one
points at. PTEST updates nothing.

**A bus error on a search cycle** ends the search with B in the entry (or B and
I in MMUSR) and no exception: the exception comes on the access's retry
(9.5.2, 8.1.2). So does a bus error on a history write (figure 9-29).

| | UM | here |
|---|---|---|
| search start | ATC miss in the bus controller, microcode | the bus unit's lookup, the walker |
| STATUS | three clocks, "MMU address translation cache miss -- processor to begin table search" (Table 8-2) | three clocks when a search for an access starts; none for PTEST or PLOAD, which are instructions |
| ECS | asserted for the aborted cycle | not: no cycle starts (as for a cache hit -- `doc/divergences.md`) |
| clocks | UM 11.7's table | measured by `core_mmu_tb`: 18 clocks for two short levels with nothing to write (UM: 33), 52 for three long levels with three U writes (UM: 53) -- `doc/timing-divergences.md` |

## Faults -- 8.1.2, 8.2

Every refusal is an ordinary bus error on the access, with the long format $B
frame and the special status word a BERR on that access would have -- the
FAULTS table in `tools/ucode/frames.py` and `doc/checkpoint.md`:

| Cause | When the bus error is taken | SSW (data access) |
|---|---|---|
| invalid descriptor, limit violation, supervisor violation, bus error during the search | on the retry, at an entry with B | DF, RW, SIZE, FC of the access |
| WP, for a write | on the retry, at an entry with WP | DF, a write |
| WP, for any cycle of a read-modify-write | on the READ -- UM 8.2.3 | DF, RM, RW = read |
| the second page of a misaligned operand | at the cycle into that page, its first part done -- searched after that part, if the ATC does not have the page | DF, the residual's SIZE; +$10 the residual's logical address |
| an instruction prefetch | when the word is used (8.1.2), as for BERR | FC/FB and RC/RB, the data half clear |

A prefetch into a refused page that is never used takes no exception -- the
pipe carries the fault bit and a flush discards it (`mmu_fault.S`, case 9).
The search for the refused page has still run, and left its entry. RTE reruns
a faulted operand through translation again: a handler that repaired the
tables and flushed the entry gets the access done.

## CIOUT and the caches -- 6.1, 9.3, 9.5.1.1

CIOUT is driven, from S0 with the address, by the CI bit of the ATC entry or
TTx registers that translated the cycle; it is negated for CPU space, for an
untranslated access with no TTx match, and for every table search cycle. With
CI the caches "are ignored for the access" (UM 6.1):

| | Instruction cache | Data cache |
|---|---|---|
| how it is told | `ic_inhibit`, with the prefetch's answer: a prefetch is translated when the bus unit starts it, after the fetch unit asked for it | `dc_inhibit`, with the request: the operand's first page |
| a read that misses | not filled; no CBREQ (the bus unit withholds it) | not filled; no CBREQ |
| a write | -- | the cache not touched at all (6.1.2.1) |
| a read that hits | served (6.1: "the state of the corresponding CI bits in the MMU are also ignored") | served |

A write the MMU refuses invalidates the data-cache entries holding its refused
bytes -- UM 6.1.2, "the write is aborted, the corresponding entry is
invalidated" -- through a port the bus unit drives as the refusal ends. The
cache took the whole write when the bus unit took it (`doc/caches.md`), so a
write refused in its second page would otherwise leave that page's bytes in
the cache and not in memory.

## The instructions -- 9.8, PRM 6

Privileged: in user mode every CpID-0 word is a privilege violation, tested on
the operation word before the command word is read (UM 9.8, 8.1.6 --
`doc/manual-contradictions.md` 13). In supervisor mode the command word is
tested as it is taken; one PRM 6 does not define is an F-line exception (UM
8.1.5), and so is an effective address the instruction does not take: every
one takes the control alterable modes only ("only control-alterable addressing
modes supported for MMU instructions", 9.6) -- not Dn, An, (An)+, -(An),
PC-relative or immediate -- and PFLUSHA and PFLUSH FC,MASK take none.

| Command word | | What it does here |
|---|---|---|
| `000 PPP R FD 0` | PMOVE TT0 (010), TT1 (011) | a long word; FD = 0 flushes the ATC on a write |
| `010 PPP R FD 0` | PMOVE TC (000), SRP (010), CRP (011) | a long word, or a quad word for the root pointers, upper long word first; FD = 0 flushes on a write; the configuration check |
| `011 000 R 0 0` | PMOVE MMUSR | a word; never flushes |
| `001 000 R 0000 FC` | PLOADR / PLOADW | a table search for the address and function code, whatever TC.E and MMUDIS say, and an ATC entry; history as for a read or a write; MMUSR untouched |
| `001 001 0 0 000 0` | PFLUSHA | every entry |
| `001 100 0 0 MMM FC` | PFLUSH FC,MASK | every entry whose function code agrees with FC where MASK has ones |
| `001 110 0 0 MMM FC` | PFLUSH FC,MASK,<ea> | ... and whose page is the address's |
| `100 LLL R A RRR FC` | PTEST | level 0: the ATC (and TTx), MMUSR B, W, I, M or T; levels 1-7: a table search to that many tables, MMUSR B, L, S, W, I, M, N, and with A the last descriptor's physical address in An. Neither the ATC nor the tables change |

FC is `10XXX` immediate, `01DDD` the low three bits of Dn, `00000` SFC, `00001`
DFC. PTEST R/W changes only a level-0 test that a TTx register matches with
RWM clear (9.8).

**How they are built.** The command word is held in T0 across the effective
address routine and put back into the extension word latch (`check_ea_live`).
PMOVE to a register reads the operand into T1 (and T0) and writes the register
on a microword that takes no fault, then branches on the configuration check;
PMOVE from a register is an ordinary, posted, write of it. PTEST and PLOAD wait
for posted writes before their search starts, so nothing can fault while it
runs; PTEST's descriptor address goes into An on the microword after, which
can take no fault either. Every MMU microword waits for a search already under
way -- a prefetch's or an operand's -- before it changes the ATC or the
registers. None of them needs a checkpoint word: the M4 reservation at +$4C is
released (`doc/checkpoint.md`).

**MMUSR after PTEST** (Table 9-3):

| Bit | Level 0 | Levels 1-7 |
|---|---|---|
| B | the entry has B | a bus error during the search |
| L | 0 | a limit violation |
| S | 0 | an S bit met with FC2 clear |
| W | the entry has WP | a WP bit met |
| I | no entry, or B | an invalid descriptor, B or L |
| M | the entry has M | the page descriptor has M |
| T | a TTx matches (and the rest 0) | 0 |
| N | 0 | tables accessed: the function code table, levels A-D and an indirect fetch each count, a fetch ending in a bus error included, a limit violation's level not |

## MMUDIS -- 5.11.2, 9.2.3

Synchronised by two falling-edge ranks, like CDIS. While it is asserted the ATC
is not looked up and no search is made for an access: every logical address is
its physical address, TTx still apply (9.7.3), PTEST and PLOAD still work, and
the ATC is not flushed. An operand already taken finishes with the translation
it was taken with (9.2.3).

## The tests

`core_mmu_tb` runs three bare-metal programs, each checking itself and logging
what fails; the testbench insists the log is empty and complete, and counts per
phase what a program cannot see -- table search cycles (FC 5 with RMC, to a
table), that none has CIOUT or CBREQ, that RMC never drops inside a search,
cycles to the synchronous port, with CIOUT, with CBREQ, instruction fetches and
two watched pages. It drives MMUDIS for `mmu_regs` and pulls RESET at its end.

| Program | What |
|---|---|
| `mmu_regs.S` | every register through PMOVE and what it keeps; the configuration exception for TC (sum, PS, the first-zero rule) and both root pointers, with its frame; PMOVEFD; PLOADR and PLOADW with their history writes counted; PTEST level 0 with each bit; PFLUSHA, PFLUSH by mask and with an address; FC from an immediate, Dn, SFC and DFC; TT1 with CI, R/W, RWM, FC mask, TAS, both registers matching; the instruction and data caches inhibited; MMUDIS; RESET |
| `mmu_walk.S` | every page size, 256 bytes to 32K; two, three, four and five levels; short and long descriptors; FCL; IS with its ATC consequence; SRE; early termination short, long with a limit, and at the root with and without a limit; indirect descriptors short, long and to a table, left unwritten; root and long-descriptor limits upper and lower; S and WP with PTEST's S and W and the history rule around a supervisor violation; tables on 16-bit, 8-bit and synchronous ports; PTEST at every level with An; 23 pages through the ATC, replacement counted; a CI page |
| `mmu_fault.S` | invalid, write-protected, supervisor-only, limit and bus-error faults, each handled with PTEST, repaired and rerun by RTE; CAS on a write-protected page faulting on its read; a long word read and one written across into a refused page, the residual in the frame; a prefetch into an invalid page never used; an instruction in an invalid page; a refused write with the data cache on; a user-mode program fetched, run and given its stack through the tables |

The three programs make 72, 80 and 57 checks of themselves, and the testbench
556 in all, the per-phase bus counts and the RESET pin's effect among them --
and, since M11 part 2, how many search cycles come before a phase's first
operand cycle: for `mmu_fault.S`'s read and write across a page boundary,
only the first page's search (3, where searching both pages up front made 5
and 6).
STATUS is checked too: three clocks for each search an access starts (22 for
the 22 pages of `mmu_walk.S`'s replacement phase), none for PLOAD's. Under
`make cache`, with both caches built out, the counts that depend on a cache
follow the build.

`core_m030_tb` runs every MMU instruction form the assembler produces in
supervisor mode, five command words the part does not define (F-line) and
three in user mode (privilege violation).

`core_cow_tb` and `core_paging_tb` are kept as they were: they page with an
external memory model that answers BERR, which is how an MC68020 system with
an external MMU pages and still how a MC68030 system sees a physical bus
error. Each has an MMU version beside it that runs the same sweep or program
with the refusal made by the core's own tables, and checks that no refused
access reached the bus:

| Testbench | What |
|---|---|
| `core_mmu_paging_tb` | `core_paging_tb`'s 108 cases -- sizes 1, 2 and 4, every alignment, 8-, 16- and 32-bit ports, read, write and CAS -- faulted across, or inside, a page whose descriptor is invalid (three levels of short descriptors, early termination everywhere else); the handler hands +$10 to a pager that writes the descriptor valid, PFLUSHA, RTE. The same frame checks, plus U set in the repaired descriptor and M set for a write or a CAS and clear for a read |
| `core_mmu_cow_tb` | `core_cow_tb` with `sim/programs/cow.S` built `-DCOW_MMU`: the kernel protects the user's pages with WP in a CRP table, keeps its own page table's page invalid in an SRP table (SRE set), and maps a page by rewriting its descriptor and PFLUSH with an address. The same 23 faults -- the nested one, CAS, CAS2 twice, TAS, the misaligned residuals, the stack shapes, the two the kernel completes -- with the same frames and results |

## Open questions

- **An RMW cycle that misses in the ATC.** UM 9.10.3's example handler says of a
  bus error with no MMUSR status bits on: "RMW cycle with no ATC entry ...
  MC68030 cannot search tables to load it. Explicitly load it" -- which implies
  the part takes a bus error rather than search for a locked cycle. Every other
  statement (9.2.1, figure 9-8, 8.1.2) has every ATC miss searched. This design
  searches (`doc/manual-contradictions.md` 19); the oracles should settle it.
- **The history rule at the violating descriptor**: whether a descriptor whose
  own S bit makes a user access a violation gets its U bit (figure 9-29 draws
  the update before the S check; 9.5.1.1 says "except after a supervisor
  violation is detected"). This design does not set it.
- **N after a bus error**: counted here as an accessed table. The oracles
  differ from the core and from each other; at M11 part 2 the user decided to
  keep it (`doc/m11-mismatches.md` c2), and likewise the extent of a user
  search after a long descriptor with S set (c3).
- **PLOAD and TTx**: PLOAD searches whatever TTx say.
