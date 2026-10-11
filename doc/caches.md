# The caches

The MC68030's two on-chip caches, as M10 builds them: the instruction cache
reorganised from the MC68020's 64 single long words into the MC68030's sixteen
lines of four, and the data cache, which the MC68020 did not have. Everything
here is UM section 6 unless a citation says otherwise; section 7 supplies the
bus side (7.2.6, 7.2.7, 7.3.7) and section 12 CDIS.

| | |
|---|---|
| RTL | `rtl/rd68031_icache.sv`, `rtl/rd68031_dcache.sv`; the instruction cache's use in `rtl/rd68031_ifu.sv`, the data cache's in `rtl/rd68031_biu.sv`, CACR's clears in `rtl/rd68031_seq.sv` |
| Build knobs | `ICACHE_ENTRIES`, `DCACHE_ENTRIES` on `rd68031_top`: 0 builds a cache out, anything else builds the MC68030's 64 entries |
| Tests | `core_cache_tb` with `sim/programs/cache.S`; `core_m030_tb`'s burst counts; `make cache` |

---

## Organisation

"Both on-chip caches are 256-byte direct-mapped caches, each organized as 16
lines. Each line consists of four entries, and each entry contains four bytes.
The tag field for each line contains a valid bit for each entry in the line;
each entry is independently replaceable" (6.1).

| | Instruction cache (6.1.1, figure 6-2) | Data cache (6.1.2, figure 6-3) |
|---|---|---|
| line select | A7-A4 | A7-A4 |
| entry select | A3-A2 | A3-A2 |
| tag | A31-A8 and FC2 | A31-A8 and FC2-FC0 |
| what it holds | prefetches, as the pipe asks for them | data reads in any space but CPU space, PC-relative and MOVES ones included |
| data store | one 64 x 32 RAM | four banks (one per A3-A2) of four byte-wide 16 x 8 RAMs |
| tags, valid bits | 16 x 25 and 64 flip-flops, reset | 16 x 27 and 64 flip-flops, reset |

The RAMs have no reset and need none: nothing reads an entry whose valid bit is
clear (`make audit` counts them as memories, not registers). The valid bits are
UM 6.2's "when a hardware reset of the processor occurs, all valid bits of both
caches are cleared" -- by `rst_n`, and by the RESET pin, which resets the fetch
unit and the data cache entirely (UM 8.1.1).

The data cache is banked so that a misaligned operand, which touches two
consecutive long words -- always in two different banks -- is looked up, and
written, in one clock.

### Hit, miss, replacement

A hit is "a tag match and the corresponding valid bit ... set" (6.1.1). A miss
fills the entry when the access is cachable (below). If the line's tag matches
the fill's, the entry's valid bit is set and the others are left as they are --
"a single entry fill operation replaces the required long word only"; if it
does not, the tag is replaced and the other three entries, which belonged to the
old tag, are invalidated.

---

## CACR and CAAR -- 6.3

A MOVEC to CACR keeps WA, DBE, FD, ED, IBE, FI and EI (`CACR_IMPLEMENTED`,
`$3313`); the four clear bits are orders carried out on the edge the MOVEC
commits, and read as zero, as do the reserved bits. Every bit is live:

| Bit | | What it does here | UM |
|---|---|---|---|
| 13 | WA | write allocation for the data cache -- below | 6.3.1.1, 6.1.2.1 |
| 12 | DBE | a data-cache miss on a cold line asks for a burst | 6.3.1.2, 6.1.3.2 |
| 11 | CD | clears every data-cache valid bit; reads as zero | 6.3.1.3 |
| 10 | CED | clears the data-cache entry CAAR bits 7-2 index, whatever its tag, "regardless of the states of the ED and FD bits"; reads as zero | 6.3.1.4 |
| 9 | FD | a data-cache miss replaces nothing, on a read or a write; a write that hits still updates; hits still hit | 6.3.1.5 |
| 8 | ED | the data cache is looked up and filled; clear, neither, and nothing is flushed | 6.3.1.6 |
| 4 | IBE | an instruction-cache miss on a cold line asks for a burst | 6.3.1.7 |
| 3 | CI | clears every instruction-cache valid bit; reads as zero | 6.3.1.8 |
| 2 | CEI | clears the instruction-cache entry CAAR bits 7-2 index, whatever its tag, regardless of EI and FI; reads as zero | 6.3.1.9 |
| 1 | FI | an instruction-cache miss replaces nothing; hits still hit | 6.3.1.10 |
| 0 | EI | the instruction cache is looked up and filled; clear, neither, and nothing is flushed | 6.3.1.11 |

"Each cache is controlled independently of the other, although a similar
operation can be performed for both caches by a single MOVEC instruction" (6.3.1):
the sequencer hands `{CED, CD, CEI, CI}` to the two caches as they were written,
and each lets its clear-all cover its clear-entry.

CAAR keeps all 32 bits (6.3.2); only bits 7-2 are used, "the index and a long
word of a cache line", for CEI and CED.

A clear that lands while a fill is still bringing long words in -- the rest of a
burst, or the fetch the pipe asked for before the MOVEC -- stops it: nothing
more of that fill goes in. What it would bring was read from memory around the
clear, and the clear is the program saying the cache's copy is not to be
trusted. The manual does not say which side of the clear such a long word
lands on; this is the side that can never leave stale data behind.

### CDIS -- 6.1, 5.11.1, 12

"The assertion of CDIS disables the caches, regardless of the state of the
enable bits in CACR." Synchronised like the other asynchronous inputs and ANDed
into both enables, so it does exactly what clearing EI and ED does: no lookup,
no fill, nothing flushed -- the entries are back when it is negated.

---

## What is cachable -- 6.1

"An external access is defined as 'cachable' ... when all the following
conditions apply: the cache is enabled with the appropriate bit in the CACR
set; the CDIS signal is negated; the CIIN signal is negated for the access; the
CIOUT signal is negated for the access; the MMU validates the access."

| Access | Instruction cache | Data cache |
|---|---|---|
| a prefetch | filled | -- |
| a data read, any space but 7 | -- | looked up, filled on a miss |
| a PC-relative read (program space) | -- | as any data read, tagged with FC 2 or 6 |
| MOVES | -- | by the SFC or DFC it uses: cached unless it is 7 |
| CPU space (FC 7) | -- | never (6.1.2) |
| the read of a read-modify-write | -- | "always forced to miss", but its data "update[s] a matching entry ... or creates a new entry" (6.1.2.2); no burst, no completing cycles (below) |
| the write of a read-modify-write | -- | as any write, WA included (6.1.2.2) |
| a cycle with CIIN | not filled | not filled; CIIN "interpreted on a bus-cycle-by-bus-cycle basis" and "ignored during all write cycles" (5.7.1, 6.1.2.1) |
| a cycle ending in BERR | the entry invalidated | the entry invalidated |
| a prefetch the pipe has abandoned | filled when it arrives, but asks for no burst if abandoned before the bus took it | -- |

A prefetch carries the space it was asked for in: `fetch_fc` is the privilege
level when the fetch unit decided on the cycle, held with its address, not the
level when the bus unit got round to it. A flush that changes the privilege
level abandons any prefetch in flight, and that long word, read in the old
space, is cached under the old space's FC2 -- which is where it belongs.

### The MMU -- since M11

The MMU's CI bit -- of the ATC entry or the TTx register that maps the access --
drives CIOUT and inhibits both caches: "whenever the appropriate CI bit is set
for either a read or a write access and an external bus cycle is required,
CIOUT is asserted and the instruction and data caches are ignored for the
access" (6.1). The bus unit translates every cycle it starts (`doc/mmu.md`),
drives CIOUT from the translation, and tells each cache:

| Input | When | Effect | UM |
|---|---|---|---|
| `ic_inhibit` (`rd68031_ifu`) | with the prefetch's answer: the prefetch is translated when the bus unit starts it, after the fetch unit asked for it, so the verdict comes back with the long word, as CIIN does | the long word is not cached; the bus unit has already withheld CBREQ | 6.1 |
| `bnow_ci` (`rd68031_dcache`) | with each read beat: that cycle's CIOUT, its own page's CI | the long word it brings is not cached; the bus unit withholds CBREQ on it and completes no long word from a narrow port after it | 6.1 |
| `dc_inhibit` (`rd68031_dcache`) | with a write, as it is taken: the CI of the page the operand starts in, looked up combinationally as the request is presented | the write ignores the data cache altogether for its long word in that page, a hit included | 6.1, 6.1.2.1: "when CIOUT is asserted, the data cache is completely ignored, even on write cycles" |
| `dc_xpage`, `dc_wb_go`, `dc_wb_drop` | a write whose second long word is in another page: when its first cycle in that page starts, or the operand stops short of it | that long word is left alone until then; updated as a write to it would be if the page is cachable (`wb_go`), still left alone if it is CI, invalidated if the page is refused or the operand ends first (`wb_drop`). No read is answered from the cache in between | 6.1, 6.1.2.1 |
| either | -- | a read that HITS is served whatever it says, and is never translated | 6.1: "the MMU is completely ignored ... the state of the corresponding CI bits in the MMU are also ignored"; figure 9-8 |

Cachability is a page's, and an operand across a page boundary has two pages
(`doc/mmu.md`): each cycle is cached or not as its own CIOUT says, never as the
operand's first page says (`doc/bugs-found.md`, M11 phase B). A read that hits
is still served whatever its page says -- including a long word cached from a
page that has since been made CI, which UM 6.1 leaves the program to clear.

A write the MMU refuses "is aborted, the corresponding entry is invalidated, and
a bus error exception is taken" (6.1.2). The cache takes a write when the bus
unit takes it, which for an operand refused in its second page is before the
refusal: the bus unit then invalidates the entries holding the refused bytes
(`inv_*`, as the refusal ends), so the cache is never left holding bytes memory
did not get. `core_mmu_tb` checks it (`mmu_fault.S`, case 11).

---

## Filling

### Single entries -- 6.1.3.1

"When a cachable access is initiated and a burst mode operation is not requested
by the MC68030 or is not supported by external hardware, the bus controller
transfers a single long word for the corresponding cache entry. An entire long
word is required. If the port size of the responding device is smaller than 32
bits, the MC68030 executes all bus cycles necessary to fill the long word."

A prefetch is always a whole aligned long word, so the instruction cache gets
its entry from the cycles the bus unit runs anyway. A data operand need not be,
and the bus unit runs the cycles that complete each entry it touches: once the
operand's bytes in a long word have been read, the rest of that long word, from
the byte after the last one received, wrapping, with SIZ giving the bytes still
missing -- and only then the operand's next long word. That one rule produces
every figure of 6.1.3.1, and `core_cache_tb` checks them cycle for cycle:

| Figure | Operand | Port | Cycles (address, SIZ) |
|---|---|---|---|
| 6-5 | byte at $03 | 8 | $03 byte, $00 3-byte, $01 word, $02 byte |
| 6-6 | byte at $03 | 16 | $03 byte, $00 word |
| 6-8 | long at $06 | 8 | $06 long, $07 3-byte, $04 word, $05 byte, $08 word, $09 byte, $0A word, $0B byte |
| 6-9 | long at $06 | 16 | $06 long, $04 word, $08 word, $0A word |
| 6-10 | long at $06 | 32 | $06 long, $08 word |

The completing cycles carry none of the operand: the residual a fault frame
records, OCS and the operand's CIIN are the operand's own. One that ends in a
bus error abandons the completion with no exception -- "if the read cycle in
error is made only to fill the data cache (the data is not part of the target
operand), no exception occurs, but the corresponding entry is marked invalid"
-- and one with CIIN abandons it too, since the entry is not going to be
cached. None is run for a read-modify-write, whose locked sequence is the
operand's cycles and nothing else, nor after CIIN or a bus error on the
operand's own cycle.

The device has to supply its whole port width on a read (UM 7.2.7: "the slave
device must supply as much aligned data on the data bus as its port size allows,
regardless of the requested operand size"), and the data cache takes the bytes
the port size says are there, gathering a long word over several cycles of a
narrow port. Until all four bytes are in the entry is invalid.

### Bursts -- 6.1.3.2, 7.3.7

A burst is asked for (CBREQ) when the cache is enabled and not frozen, its burst
enable is set, and the read "misses due to the indexed tag not matching" or the
tag "matches, but all long words in the line are invalid". The bus unit adds the
conditions that are the bus's to know: not a read-modify-write, not CIOUT, and
not "the first access of an operand that spans two cache lines" -- the data
cache evaluates the request for the line holding the operand's last byte, which
is the line the burst would fill. A device that answers CBACK gives up to four
long words, wrapping in the line, and each is written into its entry as it
lands; the operand itself completes as soon as its own bytes have arrived.

- CBACK negated early: the long words that came are cached, the rest of the line
  is not, and a later miss there is a single entry fill without CBREQ.
- CIIN on a long word: it is not cached and the burst ends; on the first, the
  operand is still served.
- BERR on the first long word: the operand's fault (data) or the prefetch's
  (taken if the word is used), and the whole line is invalidated. On a later
  one: that entry invalidated, no exception.

### When the arrays are written

| Update | Lands on | Why there |
|---|---|---|
| a long word the bus read, for the data cache | the rising edge that ends its bus cycle (`bnow_*`) | a read taken to the bus on that same edge is held back a clock and looked up again, so it never misses on a long word being written |
| a long word for the instruction cache | the edge after (`fetch_ack`, the registered `beat_*`) | the fetch unit asks for nothing while a burst is landing (`burst_tail`) or a beat is about to be written, for the same reason |
| a write | captured on the edge the bus unit takes it, applied a clock later | the earliest any request can read it back is a clock after that; and a read cycle that ended on the take edge has been written by then, so the two never land together and the write lands second, as it came second on the bus |
| CACR's clears | the edge the MOVEC commits, after everything else that edge does | |

---

## Writes -- 6.1.2, 6.1.2.1

Write-through, with no write-back: the bus unit writes memory whatever the
cache does, "and the cache contains the new value even if the external write
terminates in a bus error". Each of the (at most two) entries a write touches is
treated on its own -- figure 6-4's five examples, and the byte write the text
adds:

| | WA clear | WA set |
|---|---|---|
| hit (any size, aligned or not, frozen or not) | updated | updated |
| miss, aligned long word, tag matches (example 3) | nothing | written, validated |
| miss, aligned long word, tag differs (example 4) | nothing | tag replaced, written, the line's other entries invalidated |
| miss, anything else, tag differs (example 5) | nothing | the entry's valid bit cleared; data and tag untouched |
| miss, anything else, tag matches | nothing | nothing (the entry was already invalid) |

"If the data cache is disabled or frozen, the WA bit is ignored" (6.3.1.1): a
frozen cache allocates nothing on a write miss. CIIN is ignored on writes, so with
WA set "cache entries may be created for noncachable data"; CIOUT (the MMU hook)
is not -- the cache is "completely ignored". A five-byte bit-field write is not
"long-word data" and allocates nothing.

### Writes, posted writes and faults

The write is captured when the bus unit takes it, which for a posted write is
before it is on the bus and before its bus error, if any, can be known: that is
UM 6.1.2's "since the write to the cache completes before the write to external
memory". RTE's rerun of a faulted write (`doc/checkpoint.md` rule 9) does not
update the cache again: the first attempt already did, and a handler that
cleared the cache in between left nothing to update. A read that hits may be
answered while a posted write is still on the bus -- "the value in the data
cache might be used by another instruction before the external write cycle has
completed" (UM 7.6) -- and NOP waits for the bus as it always has.

---

## Reads that hit, half and whole -- 6.1.2, 7.2.7

A read the data cache holds whole is answered on the next edge with no bus cycle,
whatever the bus is doing -- a prefetch, a posted write, the rest of a burst. "The
hit and miss are treated independently": an operand whose first long word hits
starts its bus cycles at the second, and that cycle has OCS ("OCS is asserted for
the second portion of the operand", 7.2.7); one whose second long word hits stops
its cycles after the first, SIZ still counting the whole operand from its start.
A misaligned read that misses both is the bus unit's ordinary two cycles, each
filling its entry.

The read of a read-modify-write is never looked up, nor CPU space, nor anything
while ED is clear or CDIS asserted. RTE's hand-back of a faulted read goes to the
bus: it is the frame's operand, not a new request.

---

## Self-modifying code, and the two caches

"The instruction cache is not snooped": a write -- through the data cache or not
-- never touches the instruction cache, and a cached long word goes on serving
the instructions it held until CI, or CEI on its entry, clears it. That is the
software's to do, as UM 6.3.1.8 says it is ("operating systems and other
software set this bit to clear instructions from the cache"). `core_cache_tb`
modifies a subroutine with an ordinary write and checks both: the old
instruction runs until the clear, the new one after.

The data cache is logically addressed, so UM 6.1's rule that the caches "should
be flushed during a task switch or at any time the logical-to-physical address
mapping changes" is the operating system's too; WA exists for the aliasing case
(6.1.2.1).

---

## Checkpoints -- `doc/checkpoint.md` rule 12

No cache state is in any frame, and the reserved word `+$50` is released: UM
requires nothing there. A fault leaves both caches as they are: a faulted read
fills nothing it did not complete, a faulted write has already updated the data
cache as the manual says it does, and a fill's fault is either the operand's --
with the operand's frame -- or nothing.

---

## The tests

| Where | What |
|---|---|
| `core_cache_tb` + `sim/programs/cache.S` | one short test per phase, checked against the bus cycles it made and the values it read: hits, misses and fills for both caches; disable and re-enable; CD, CED, CI, CEI and by-index clearing; FD and FI, empty and full; write-through; figure 6-4's examples in both WA modes, and the byte cases; TAS's forced miss and its entry; CPU space; FC tagging, both caches; figures 6-5, 6-6, 6-8, 6-9 and 6-10 cycle for cycle; half hits and OCS; bursts for both caches, DBE/IBE clear, CBACK stopping at two, CIIN on a beat and throughout, CIIN ignored on a write, BERR on a beat and on a completing cycle; CDIS; a faulted prefetch not cached; self-modifying code with and without CI and CEI |
| | ... and TAS on the 8-bit port, which completes nothing and leaves the entry invalid; and that every ECS starts a cycle -- a hit aborts none |
| `core_m030_tb` | three programs with both caches and both burst enables on, over a synchronous bursting port and a 16-bit asynchronous one: the same results, and bursts for each cache on the first |
| `make cache` | every directed testbench, the sweep and the effective-address vectors with both caches built out; the programs both ways, with identical writes and no more data reads or instruction fetches with the caches |
| `core_vec_tb`, `core_ea_tb`, `core_insn_tb`, `core_fault_tb` | the operand-access recorder takes the operand where the bus unit accepts it, so a read the data cache answers is still an access, as an oracle reports it |

Area and timing are M15's.
