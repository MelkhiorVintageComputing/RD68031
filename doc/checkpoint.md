# The checkpoint register set

The MC68030 can recover from a bus error. UM 8.2.1, on what RTE does with a fault
frame:

> If a rerun bit is set when the processor executes an RTE instruction, the
> processor may execute a bus cycle to prefetch the instruction word for the
> corresponding stage of the pipe (if it is required). ... If the DF bit is set
> when the processor reads the stack frame, it reruns the faulted data access.

That constrains the whole microarchitecture. Every scrap of state an instruction
accumulates has to live somewhere the fault frame can save and RTE can reload,
which means the working registers must be a **fixed, named set** and not whatever
a given piece of microcode finds convenient. On the MC68030 it matters more than
on the MC68020 this design was forked from: the on-chip MMU turns every access an
instruction makes into one that can fault, and an operating system pages on it.

This document freezes that set for the MC68030, at M4 (`doc/plan.md`), before
the sequencer, the microcode and the exception processing are reworked for the
part (M5-M9) and before the data cache and the MMU exist (M10, M11). It was
first frozen for the MC68020 in RD68021, before a single instruction existed,
because retrofitting it after the datapath is built is the single largest risk
in the plan; this is that freeze, re-derived from the MC68030 manual, with room
named for what the later milestones add.

Everything below is generated from `tools/ucode/frames.py`, which is the only
place any of these numbers exists. `make ucode-check` fails the build if the
generated `rtl/gen/rd68031_frame_pkg.sv` -- or the tables in this file -- have
drifted from it, and it is the first thing `make check` runs.

---

## What the MC68030 changes

Less than its size suggests. Word for word:

| | MC68020 (UM20) | MC68030 (UM) | here |
|---|---|---|---|
| the six frames | Table 6-5 | Table 8-6: the same six, every field at the same offset | unchanged |
| the version word | `+$36`, 6.1.12 | `+$36`, 8.1.8 and 8.1.13 | unchanged; RTE now **checks** it, below |
| format `$2` | CHK, CHK2, cpTRAPcc, TRAPcc, TRAPV, trace, zero divide, cp postinstruction | the same, and **MMU configuration** (8.1.10) | M11 builds it with the existing `$2` builder |
| format `$9` | figure 7-43 | figure 10-43, the same ten words | unchanged |
| special status word | figure 6-8: bits 11-9 and 3 **zero** | figure 8-9: bits 11-9 and 3 **X, "for internal use only"** | written as zero; a handler may not change them (8.2.2); RTE ignores them |
| bus fault sources | BERR | BERR, and every MMU refusal (8.1.2, 9.5.2) | the same frame and the same bits -- below |
| caches | instruction cache | instruction and data caches, burst fills | not checkpointed -- below |
| the instruction pipe | stages B, C, D and the cache holding register | the same (UM 11.2.2) | unchanged |
| version number | | | `$3`, not RD68021's `$1` |
| CALLM and RTM | module calls, UM20 9.7-9.8 | not implemented: illegal instructions (8.1.5) | removed at M5 -- below |

Four things in the inherited design did not meet the manual, and M4 fixed them
(`doc/bugs-found.md`):

- RTE **never compared the version number**. The document said it refused any
  other with a format error; the microcode read `+$36` back into its registers
  and went on. UM 8.1.8 makes the comparison the condition for taking the frame
  apart at all.
- RTE **did not read both ends of a bus fault frame** before restoring from it
  (UM 8.1.13), so an inaccessible frame faulted half-way through the restore,
  with the machine half put back.
- RTE let the pipe **refetch before the stacked status register was back**, so
  a user program's rerun prefetch ran in supervisor program space (UM 8.2.1).
- RTE took a **short frame** apart by reading three of its internal words --
  `+$08`, `+$14`, `+$16` -- as if this design had written them. It never writes a
  short frame, so the micro-address it resumed at was whatever the frame's
  `+$14` happened to hold.

**CALLM and RTM, removed at M5, freed nothing.** The MC68020's module calls
kept everything they carried between microwords in T0-T3 and the extension-word
latch, which every instruction shares, and their own state -- the descriptor,
the access level -- lived in memory and in the access-level hardware. No
`INTERNAL` row and no `CHECKPOINT` row was theirs, so the budget below is the
one M4 froze: 353 bits of 492, 64 reserved, four words spare. What the M4
freeze already said of the special status word -- no CALLM state -- holds.

---

## Which frame, and when

UM Table 8-6 gives format `$A` for "Address Error or Bus Error -- Execution Unit
at Instruction Boundary" and `$B` for "Instruction Execution in Progress", and UM
8.1.2 says the same in prose: "when the bus error exception is taken at an
instruction boundary, less information is required to recover from the error,
and the processor builds the short bus fault stack frame". Picking the rule is
the irreversible decision; the frames themselves are bookkeeping.

**This design emits `$B` for every bus error and every address error, and never
`$A`.** RTE still accepts a format `$A` frame (below).

Two things decide it, both inherited and both still true of the MC68030:

- **Data faults.** The microcode stalls until its operand completes, or posts a
  write and goes on with the posted write's fault landing on whatever microword
  is running (rule 9). Either way the exception is taken mid-instruction, at a
  microword that is re-executed after RTE and may need any working register --
  which only the long frame carries.
- **Prefetch faults.** One is taken by the microword that needs the missing
  word, which is usually the instruction's own last microword -- the one that
  writes its result and advances the pipe. RTE re-executes that microword, so
  it has to find everything it reads where it left it: the working registers,
  the latched operand size, the extension word. A short frame was built for a
  while in RD68021, for the case that looked like a boundary; it lost the working
  registers to the fault handler, and SunOS found it twice.

The manual licenses this explicitly, UM 8.4:

> The system software should not depend on a particular exception generating a
> particular stack frame. For compatibility with future devices, the software
> should be able to handle any type of stack frame for any type of exception.

It is a behavioural difference all the same, and `doc/divergences.md` records it.

---

## Why a private encoding of the internal words is legitimate

UM 8.1.8 and 8.1.13:

> For long bus cycle fault format frames, the RTE instruction also compares the
> internal version number of the processor to that contained in the frame at
> memory location SP+54 (SP+$36). This check ensures that the processor can
> correctly interpret internal state information from the stack frame.

> This validity check is required in a multiprocessor system to ensure that the
> data is properly interpreted by the RTE instruction. ... If the frame is
> invalid or inaccessible, the processor takes a format error or a bus error
> exception, respectively.

So Motorola's own contract is: the internal words are private, they are
version-stamped, and a processor that does not recognise the stamp must refuse
the frame rather than misinterpret it. Software that saves a frame and later
restores it -- which is what every operating system does -- cannot tell the
difference. Software that synthesises internal words from scratch was already
not portable across implementations.

RD68031 therefore stamps its own version number, **`$3`**, and refuses any other
with a format error, vector 14. It is not RD68021's `$1`: the two designs will
keep different things in the internal words from M5 on, and a frame from one
read by the other is exactly what the stamp exists to stop. The manual does not
say what a real MC68030 stamps, so nothing can promise to differ from it
(the open questions, at the end).

---

## The short frame: nothing private in it, nothing private out of it

**The short frame has no version field.** UM 8.1.13 validates the stamp only
for the long frame; for a short one "the processor first checks the format value
on the stack for validity" and nothing more. So a short frame could have been
written by anything, and nothing in it says so.

> **Rule 1: format `$A` carries no private state, and RTE reads none out of
> one.** Everything it needs is either an architectural field or derivable
> from one.

This design never builds a short frame, so the first half is kept the simple
way. The second half is RTE's, and since M4 it holds: `rte_fault_short`, in
`tools/ucode/program.py`, reads the status register, the program counter, the
special status word, stage C, stage B, the fault address and the data output
buffer -- the frame's architectural fields -- and nothing else.
`check_short_reads` in `assemble.py` fails the build if it ever reads an
internal word. What the long frame's internal words would have said is what UM
Table 8-6's "at instruction boundary" implies:

- **The pipe** is sequential. UM 8.2: "the address of the pipe stage B word is
  the value in the program counter plus four, and the address of the stage C
  word is the value in the program counter plus two" -- so the operation word
  at the program counter is in stage D, which the frame does not carry. RTE
  reads it from memory, from "the program space for the privilege level
  indicated in the copy of the status register on the stack" (UM 8.2.1), and
  takes stage C and stage B from the frame where `RC` and `RB` are clear and
  refetches them where they are set, exactly as for the long frame.
- **A data fault** still to be rerun is a write: UM 8.2.2, "data read faults
  only generate the long bus fault frame". The instruction that made it has
  finished, so RTE gives it to the bus unit as a posted write of its own (rule
  9) -- address `+$10`, data `+$18`, the size `SIZE` names and the space
  `FC2-FC0` names. `DF` on a read has nowhere to deliver its data and is
  dropped.
- **Resuming** is at `rte_boundary`, a microword that does nothing but decode
  what stage D holds. The short frame carries no micro-address, and does not
  need one.

What makes the rule affordable is that UM 8.2 states the derivation itself, and
that is exactly why the long frame carries a stage B address (`+$24`) and the
short one does not.

---

## The cache holding register is not saved

UM 11.2.2: "Words are loaded into the instruction pipe from the cache holding
register ... the cache holding register is 32 bits wide and contains the entire
long word". That register is 32 bits of data plus its address and validity --
an eighth of the budget.

**It is not checkpointed. RTE restores it as invalid and the next prefetch
re-reads the long word.** It is a pure cache of the last long word fetched: the
cost of discarding it is one bus cycle (or one instruction cache hit) after a
fault, and it can never give a wrong answer. The alternative costs 64 bits and
adds a way for a restored pipe to disagree with memory.

---

## What the MC68030 adds: the MMU, the data cache, the burst

### MMU faults (M11)

**An MMU fault is a bus error on the logical access, and nothing more.** UM
8.1.2: "a bus error exception also occurs when the MMU detects that a
successful address translation is not possible". UM 9.5.2: a table search that
ends in "an invalid descriptor, a limit violation, or a bus error" loads the
address translation cache with the B bit set, "and the MC68030 takes an
exception on the retry of the cycle". UM 9.4: once an entry has B set, "a
subsequent access to the logical address causes the MC68030 to take a bus error
exception". So:

- **The frame is the same frame** (`$B` here), with the same special status
  word, and no bit says the MMU raised it. The handler asks with PTEST (UM
  9.10.3) -- which is what the manual's own paging handler does.
- **`+$10` is the logical address** of the faulted cycle -- for an operand split
  across a page boundary, of its residual, exactly as for a BERR today.
- **The data half of the SSW describes the access, not the search.** `RW`, `RM`,
  `SIZE` and `FC2-FC0` are those of the retried cycle; the search's own reads and
  descriptor writes appear nowhere.
- **A read-modify-write faults on its read** on a write-protected page: UM
  8.2.3, "the MMU of the MC68030 treats any bus cycle with RMC asserted as a
  write operation for protection checking". The frame then has `RW` = 1 and
  `RM` = 1, and RTE with `DF` set reruns the whole operation from that read.
  `core_cow_tb`'s memory model already behaves this way.
- **An instruction-stream refusal** is pending until the word is used, as a
  BERR on a prefetch is: `FC`/`FB` and `RC`/`RB`, and `+$24` the logical
  address of stage B.

**Nothing has to survive a fault in the middle of a table search, because none
is ever taken there.** The search runs with RMC asserted from its first cycle to
its last (UM 9.5.2, "ensuring that the entire table search completes without
interruption"); a bus error on one of its cycles ends it with the B bit, not
with an exception; and the exception comes on the retry, at the access, by
which time the search is over. Interrupts are taken at instruction boundaries.
A posted write's fault cannot land inside one either: the search runs bus
cycles, and the bus unit takes nothing while a posted write is outstanding, so
the write has finished or faulted before the search begins. Whatever the search
did stands: the U and M bits it set in the tables, and the entry it loaded --
UM 9.4 keeps an entry with B set until a PFLUSH, a PLOAD or the replacement
algorithm removes it. A rerun searches again if the entry has gone.

The table walker's registers are therefore cycle-level, like the bus unit's, and
go in `EXEMPT` when M11 writes them.

The MMU instructions (M11) commit the way every instruction does: PMOVE writes
TC, CRP, SRP, TT0, TT1 or MMUSR on the microword that completes it, so a fault on
its memory operand -- an ordinary data fault -- leaves the register as it was
(rule 2). PTEST and PLOAD search the tables and report in MMUSR and the ATC
rather than by exception. PMOVE of an invalid configuration is the MMU
configuration exception, vector 56, a post-instruction exception on the six-word
frame (UM 8.1.10, Table 8-6). If one of them needs working state beyond T0-T3
and the extension word across a microword that can fault, it comes out of the
reservation below.

### The data cache (M10)

**The data cache is not checkpointed, and nothing a fault frame says is about a
cache line.** It is write-through (UM 6.1.2), so it never holds the only copy of
anything, and:

- **A faulted write has already updated it.** UM 6.1.2: "since the write to the
  cache completes before the write to external memory, the cache contains the
  new value even if the external write terminates in a bus error". RTE's rerun
  writes the same bytes again, so the rerun is idempotent and the frame need
  carry nothing about it. A write the MMU refuses instead invalidates the entry
  (UM 6.1.2), which is also idempotent.
- **A fill fault is an operand fault or nothing.** UM 6.1.3.1: "if the bus
  error occurs on a read cycle for a portion of the required operand ... the
  processor immediately takes a bus error exception. If the read cycle in error
  is made only to fill the data cache ... no exception occurs, but the
  corresponding entry is marked invalid." So the frame describes the operand --
  its residual, its size, its space -- and never the line.
- **A rerun recomputes cacheability.** CIIN, the page's CI bit and the CACR are
  sampled again by the rerun, as they are for any access.

### The burst

**A burst is cycle-level state, and only its operand beats can fault.** UM
6.1.3.2: BERR on the first cycle of a burst aborts it and, for a data access,
"exception processing proceeds immediately" -- that is the operand's fault, with
the operand's frame; BERR on a later beat "does not take an exception (the
microsequencer has not yet requested the data)", and a misaligned operand's
second part is then requested again as an ordinary cycle, which faults on its
own if it faults. Everything the bus unit holds about a burst -- `beat_q`,
`cyc_brq`, `op_burst` and the rest -- is already in `EXEMPT` with a reason.

### MOVES

The special status word's `FC2-FC0` is the space of the faulted cycle, which
for MOVES is the SFC or DFC value, not the instruction's own. RTE's rerun uses
the frame's `FC2-FC0`, which UM 8.2.2 forbids a handler to change.

---

## The budget

<!-- generated from tools/ucode/frames.py by assemble.py: do not edit -->

### The frames

UM Table 8-6, word by word. `internal` is the manual's "internal register" or "internal information".

| Format | Words | Name | Layout |
|---|--:|---|---|
| `$0` | 4 | four-word | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec |
| `$1` | 4 | throwaway four-word | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec |
| `$2` | 6 | six-word | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` instr_addr ×2 |
| `$9` | 10 | coprocessor midinstruction | `+$00` sr, `+$02` scanpc ×2, `+$06` fmtvec, `+$08` instr_addr ×2, `+$0C` internal, `+$0E` opword, `+$10` ea ×2 |
| `$A` | 16 | short bus fault | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` internal, `+$0A` ssw, `+$0C` stage_c, `+$0E` stage_b, `+$10` dfa ×2, `+$14` internal, `+$16` internal, `+$18` dob ×2, `+$1C` internal, `+$1E` internal |
| `$B` | 46 | long bus fault | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` internal, `+$0A` ssw, `+$0C` stage_c, `+$0E` stage_b, `+$10` dfa ×2, `+$14` internal, `+$16` internal, `+$18` dob ×2, `+$1C` internal ×4, `+$24` stage_b_addr ×2, `+$28` internal ×2, `+$2C` dib ×2, `+$30` internal ×3, `+$36` version, `+$38` internal ×18 |

### Which exception takes which frame

| Format | Taken for | The stacked program counter |
|---|---|---|
| `$0` | interrupt, format error, TRAP #n, illegal instruction, A-line, F-line, privilege violation, coprocessor preinstruction | the next instruction (interrupt, TRAP #n); the instruction itself (illegal, A-line, F-line, privilege violation); the RTE or cpRESTORE (format error); the operation word (cp preinstruction) |
| `$1` | an interrupt taken with M set, on the interrupt stack -- UM 8.1.9 | the next instruction -- the same as on the master stack |
| `$2` | CHK, CHK2, cpTRAPcc, TRAPcc, TRAPV, trace, zero divide, MMU configuration, coprocessor postinstruction | the next instruction; +$08 is the instruction that caused it |
| `$9` | coprocessor midinstruction, main-detected protocol violation, interrupt during a coprocessor instruction | the next word to be fetched (the scanPC); +$08 is the coprocessor instruction |
| `$A` | address error or bus error, execution unit at an instruction boundary -- never built by this design | the next instruction |
| `$B` | address error or bus error, instruction execution in progress -- every bus and address error this design takes | the instruction executing when the fault occurred, which may not be the one that ran the faulted cycle |

RTE accepts these six and no other: anything else is a format error, and so is a `$B` whose version nibble at `+$36` is not `$3`.

### The special status word

| Bits | Field | What |
|---|---|---|
| 15 | FC | fault on stage C of the instruction pipe |
| 14 | FB | fault on stage B of the instruction pipe |
| 13 | RC | rerun flag for stage C (a handler may change it) |
| 12 | RB | rerun flag for stage B (a handler may change it) |
| 11–9 | internal | for internal use only -- written as zero here |
| 8 | DF | fault/rerun flag for the data cycle (a handler may change it) |
| 7 | RM | read-modify-write on the data cycle |
| 6 | RW | read/write for the data cycle: 1 = read, 0 = write |
| 5–4 | SIZE | size code for the data cycle -- UM Table 7-2 |
| 3 | internal | for internal use only -- written as zero here |
| 2–0 | FC2–FC0 | the address space of the data cycle |

### The private words of the long frame

| Offset | Bits | Register | What |
|---|---|---|---|
| `+$08` | 2:0 | `bytes` | residual byte count of the faulted operand |
| `+$08` | 4 | `notrace` | the trace pending for this instruction was cancelled |
| `+$08` | 6 | `eapc` | the base of the effective address under way is the PC |
| `+$08` | 8:7 | `opsize` | the operand size the dispatching microword resolved |
| `+$08` | 9 | `eadst` | the effective address under way is a MOVE destination |
| `+$36` | 2:1 | `trmode` | the trace mode this instruction began with |
| `+$36` | 3 | `flow` | this instruction has changed the flow |
| `+$36` | 4 | `pc_kept` | pc_prev was taken at a flush, not at the decode |
| `+$46` | 31:0 | `pc_prev` | the address of the instruction before this one |
| `+$08` | 15 | `dvalid` | stage D holds an instruction word |
| `+$14` | 15:0 | `upc` | the micro-address to resume at |
| `+$16` | 15:0 | `stage_d` | the instruction word being decoded |
| `+$1C` | 31:0 | `t0` | working register |
| `+$20` | 31:0 | `t1` | working register |
| `+$28` | 31:0 | `t2` | working register |
| `+$30` | 31:0 | `t3` | working register |
| `+$34` | 15:0 | `xw` | the extension-word latch |
| `+$38` | 31:0 | `ea_latch` | the address output buffer |
| `+$3C` | 31:0 | `ea_save` | the copy of it taken at the fault |
| `+$40` | 31:0 | `pc_fetch` | the next long word the pipe will fetch |
| `+$44` | 15:0 | `link` | the return address of the subroutine under way |
| `+$4A` | 15:0 | `cprim` | the coprocessor response primitive being served |
| `+$08` | 5 | `posted` | the faulted access was a posted write, which RTE reruns by itself |
| `+$08` | 12:10 | `irqlvl` | the level of the interrupt being taken |

**492 bits available, 353 used, 64 reserved, 4 words spare** (`+$54`, `+$56`, `+$58`, `+$5A`).

### Reserved for the milestones still to come

| Offset | Words | For | What |
|---|--:|---|---|
| `+$4C` | 2 | M11 | MMU instruction state that has to outlive a posted write's fault -- PTEST, PLOAD, PFLUSH, PMOVE -- should one need more than T0-T3 and the extension word |
| `+$50` | 1 | M10 | the faulted operand's cache disposition, should an RTE rerun need to know how the first attempt left the data cache |
| `+$52` | 1 | M8-M9 | exception-processing state, should the rework of exceptions need any beyond the working registers |

### The frozen set

| Unit | Register | Bits | Lands in | |
|---|---|--:|---|---|
| `ifu` | `d_q` | 16 | `stage_d` |  |
| `ifu` | `d_v_q` | 1 | `dvalid` | a prefetch fault taken with the pipe empty -- after a flush -- has no stage D, and the word at +$16 is whatever the last one was. Restoring it as valid ran it: SunOS's forked child executed its parent's RTE |
| `ifu` | `c_q` | 16 | `stage_c` | frame +$0C |
| `ifu` | `b_q` | 16 | `stage_b` | frame +$0E |
| `ifu` | `c_f_q` | 1 | `ssw` | SSW FC |
| `ifu` | `b_f_q` | 1 | `ssw` | SSW FB |
| `ifu` | `pc_d_q` | 32 | `pc` | the frame's own program counter |
| `ifu` | `fill_q` | 32 | `stage_b_addr` | long frame +$24; short frame derives it. The same register as pc_fetch: stage B is two before the fill point. |
| `ifu` | `fill_q` | 32 | `pc_fetch` |  |
| `ifu` | `chr_q` | 32 | `derived` | not saved: invalidated by RTE, re-fetched |
| `ifu` | `chr_addr_q` | 30 | `derived` | likewise |
| `ifu` | `chr_v_q` | 1 | `derived` | likewise -- always restored as invalid |
| `ifu` | `chr_f_q` | 1 | `derived` | likewise |
| `biu` | `flt_addr` | 32 | `dfa` | frame +$10 |
| `biu` | `flt_dib` | 32 | `dib` | long frame +$2C |
| `biu` | `flt_dob` | 32 | `dob` | frame +$18 |
| `biu` | `flt_bytes` | 3 | `bytes` | SIZ cannot encode a five-byte residual |
| `biu` | `flt_rmc` | 1 | `ssw` | SSW RM |
| `biu` | `flt_rw` | 1 | `ssw` | SSW RW |
| `biu` | `flt_fc` | 3 | `ssw` | SSW FC2-FC0 |
| `seq` | `df_q` | 1 | `ssw` | SSW DF -- see biu.flt_df |
| `seq` | `flt_upc` | 16 | `upc` | the faulted microword's own address, latched at the fault: by the time the frame builder writes +$14 its own upc is deep inside itself |
| `seq` | `link_q` | 16 | `link` | seq = RET returns here |
| `seq` | `t_q` | 32 | `t0` | one array of four in the RTL |
| `seq` | `t_q` | 32 | `t1` |  |
| `seq` | `t_q` | 32 | `t2` |  |
| `seq` | `t_q` | 32 | `t3` |  |
| `seq` | `ea_q` | 32 | `ea_latch` |  |
| `seq` | `ea_save` | 32 | `ea_save` | the frame builder's own pointer, so that ea_q -- which is the instruction's and is +$38 -- is not disturbed. RTE ignores what lands in this slot |
| `seq` | `xw_q` | 16 | `xw` |  |
| `seq` | `notrace_q` | 1 | `notrace` | the instruction was never executed, so UM 8.1.7 does not trace it |
| `seq` | `eapc_q` | 1 | `eapc` | seq = EADEC latches it; EABASE reads it |
| `seq` | `size_q` | 2 | `opsize` | seq = EAMODE latches it; the shared EA routines read it |
| `seq` | `eadst_q` | 1 | `eadst` | likewise, and rsel reads it |
| `seq` | `trace_mode_q` | 2 | `trmode` | UM 8.1.7 fixes it at the start of the instruction, so a fault may not lose it |
| `seq` | `flow_q` | 1 | `flow` | likewise: whether the instruction had changed the flow before it faulted |
| `seq` | `pc_prev_q` | 32 | `pc_prev` | a trace frame carries it at +$08 |
| `seq` | `pc_kept_q` | 1 | `pc_kept` | pc_prev_q was taken at a flush, so the decode must not overwrite it |
| `seq` | `sr_q` | 16 | `sr` | frame +$00 |
| `seq` | `cprim_q` | 16 | `cprim` | UM 10.5.2.8: a bus error on any CIR access but the first, or on an operand a primitive moves, is an ordinary bus error, and RTE goes back to the primitive it interrupted |
| `seq` | `post_flt_q` | 1 | `posted` | doc/checkpoint.md rule 9: the faulted access belongs to no microword -- the write was posted and the instruction went on -- so RTE runs it on its own and resumes at the microword that was interrupted |
| `seq` | `irq_taking_q` | 3 | `irqlvl` | the level of the interrupt being taken, from the dispatch to the acknowledge. A posted write's fault can land in between -- doc/checkpoint.md rule 9 -- and the acknowledge after RTE has to ask for the same level |

### Not checkpointed, and why

| | |
|---|---|
| D0-D7, A0-A6 | architectural |
| USP, ISP, MSP | architectural; A7 is not a register, it is whichever of these the S and M bits select |
| VBR, SFC, DFC | architectural |
| CACR, CAAR | architectural |
| TC, CRP, SRP, TT0, TT1, MMUSR (M11) | architectural. PMOVE writes them on the microword that completes it, and a faulted one commits nothing (rule 2) |
| the instruction cache | a cache. What it holds is a copy of memory, and a fault neither needs it nor disturbs it |
| the data cache (M10) | a cache, write-through. A faulted write has already updated it -- UM 6.1.2, "the cache contains the new value even if the external write terminates in a bus error" -- and RTE's rerun writes the same bytes again, so the rerun is idempotent |
| the ATC (M11) | a cache of the tables. A table search's descriptor updates (U, M) and its ATC entry stand whether or not the access then faults -- UM 9.5.2 -- and a rerun searches again if the entry has gone |
| a table search in progress (M11) | never interrupted. It runs with RMC asserted throughout (UM 9.5.2), a bus error ends it with the B bit and no exception, and the exception is taken on the retry of the access -- so no frame is ever built in the middle of one |

### What each fault looks like

| | Built at | Cause | Vector | Frame | Special status word | Fields |
|---|---|---|--:|---|---|---|
| `data` | M2 | BERR ending a data cycle -- asynchronous, synchronous, or a burst's first cycle, which carries the operand (UM 6.1.3.2) | 2 | `$B` | DF; RM, RW, SIZE and FC2-FC0 of the faulted cycle | +$10 the address of the next byte still to transfer (the residual); +$18 the operand being written, +$2C what had been read |
| `prefetch` | M2 | BERR ending an instruction prefetch, taken when the word is used -- UM 8.1.2 | 2 | `$B` | FC and/or FB, each with its rerun bit; the low half clear | +$24 the stage B address; stage C is two below it |
| `odd` | M2 | address error: a prefetch from an odd address, no bus cycle -- UM 8.1.3 | 3 | `$B` | RC and RB alone (UM 8.2.1) | +$02 the odd address |
| `burst_tail` | M10 | BERR on a burst beat, or a fill cycle, that carries none of the operand -- UM 6.1.3.2 | - | - | none: the cache entry is marked invalid | none |
| `icache_fill` | M10 | BERR on an instruction cache fill | 2 | `$B` | as prefetch, if and when the word is used | as prefetch |
| `mmu_invalid` | M11 | the table search ends at an invalid descriptor -- UM 9.5.2 | 2 | `$B` | as data or prefetch, for the retried access | +$10 the LOGICAL address of the retried cycle |
| `mmu_limit` | M11 | a limit violation in the table search | 2 | `$B` | as data or prefetch | as mmu_invalid |
| `mmu_super` | M11 | a supervisor-only page at the user privilege level -- UM 9.5.5.3 | 2 | `$B` | as data or prefetch | as mmu_invalid |
| `mmu_wp` | M11 | a write, or any cycle of a read-modify-write, to a write-protected page (UM 9.5.5.4) -- "the MMU of the MC68030 treats any bus cycle with RMC asserted as a write operation for protection checking" (UM 8.2.3) | 2 | `$B` | as data; a CAS, CAS2 or TAS faults on its READ, RW = 1 and RM = 1 | as mmu_invalid |
| `mmu_search_berr` | M11 | BERR on a table-search cycle: the search ends, the entry gets B, the retried access faults -- UM 9.4, 9.5.2 | 2 | `$B` | as data or prefetch, for the retried access; the search cycle itself appears nowhere | as mmu_invalid |
| `mmu_b` | M11 | an ATC hit on an entry with B set | 2 | `$B` | as data or prefetch | as mmu_invalid |
| `mmu_config` | M11 | PMOVE of an invalid configuration to TC, CRP or SRP: a postinstruction exception -- UM 8.1.10, 9.7.5.3 | 56 | `$2` | none | +$02 the next instruction, +$08 the PMOVE |
| `rte_format` | M4 | RTE on a format other than $0 $1 $2 $9 $A $B, or on a $B whose version nibble is not this design's -- UM 8.1.8 | 14 | `$0` | none | +$02 the RTE; the frame it refused is left intact above |
| `rte_access` | M4 | RTE on a $A or $B frame it cannot read at one of its two ends -- UM 8.1.13 | 2 | `$B` | as data, a read | +$10 the end it could not read; the frame is left intact and nothing was restored |

<!-- end of generated tables -->

`stopped_q` and the RESET instruction's counter (`rsto_q`, `rsto_cnt`,
`rsto_arm_q`) are in `EXEMPT` rather than above, because no bus cycle runs while
either is live: PRM 6 STOP stops the bus, and RESET's 512 clocks stall the
sequencer with the pipe standing still.

---

## How the rules are enforced

Rule 3 -- *every register an instruction accumulates has a home here or it does
not exist* -- is about **registers**, so it is checked against the registers.
`tools/ucode/frames.py`'s `check_rtl` reads every clocked process in `rtl/`,
collects the signal each one writes, and insists that every one is either in the
frozen set above or in `EXEMPT` with a reason. `make ucode` runs it and fails.

It is checked in both directions. A register added without a thought about what
a fault does to it is a build failure; so is a register renamed in the RTL and
not in the table, which shows up twice -- the new name unaccounted for and the
old one missing.

`PENDING` holds the rows whose register does not exist yet, each with the
milestone that builds it, so that this table can describe the finished design
while the check still says which parts of it are not there. A pending register
that arrives without being taken off the list is also a failure.

The scraper itself had to be fixed once, and in the direction that matters: it
required the *whole* left-hand side of a line to be an identifier, which kept
`if (a <= b)` out of the answer but also hid `irq_taking_q`, whose assignment
shared a line with the `else if (...)` guarding it. An invisible register is an
unreported one. It now looks at every `<=` on the line and rejects the ones that
stand inside an expression -- unbalanced parentheses to the left, or a blocking
assignment outside parentheses on the same line.

**This replaced a check that read the microcode's DESTINATIONS.** That one could
not see a register the microcode never names as a destination, and five got past
it: `link_q`, `eapc_q`, `size_q`, `eadst_q` and `cnt_q`, every one of them
per-instruction state. The first would have surfaced as a wild jump on a
demand-paged access -- a fault inside an effective-address subroutine restores
`upc` from the frame and then returns through a link register holding whatever
the handler last put there.

**A home is not enough: it has to be used.** `check_rtl` proves every register
has a slot; `check_frame_fields`, in `tools/ucode/assemble.py`, proves the frame
builder writes each private slot of the long frame from its register and RTE
reads it back. Two slots are exempt with a reason: `ea_save`, which is the
builder's own pointer, and `pc_fetch`, which is the same register as +$24. Until
it existed `cprim` had a slot at +$4A that the builder filled with zero and RTE
skipped. A handler that ran a coprocessor instruction then resumed an
interrupted operand transfer with its own primitive's length.

**The frames, the special status word, the reservations and the fault encodings
are checked against themselves.** `frames.check()` proves each frame gapless and
exactly as long as UM Table 8-6 says; the version word at `+$36` and in the long
frame only; no two private fields on one bit, none on the version nibble and none
in the short frame; every one of the special status word's sixteen bits named
exactly once, with `DF`, `RB` and `RC` among them; no reservation on an allocated
word; and every fault encoding naming a frame the part has. `check_short_reads`
proves rule 1's second half.

## The rules this imposes on the microcode

Thirteen. The first nine were RD68021's and hold unchanged; the last four are
the MC68030's, written now for the milestones that will need them.

1. **No state outside the set.** A microword may not stash a value anywhere but
   the registers above. If a sequence needs a fifth temporary, the answer is to
   restructure it or to add a register here -- with the budget recomputed, out
   of the reservation for its milestone first. `assemble.py` will fail the build
   on a destination with no home.

2. **A faulted microword ends but commits nothing** -- no register write, no pipe
   advance, no address-register update, no condition code, no control-register
   write. The state the frame records is therefore the state at the *start* of
   the faulted access, and resuming at the saved micro-address re-executes the
   microword and reissues exactly the same request. There is no separate
   restart path to get wrong.

3. **The unit of restart is the operand, not the bus cycle.** `rd68031_biu`
   splits an operand into however many cycles the port, the alignment and the
   burst need, and it keeps the residual; a microword that issues an operand
   must be restartable from its own first clock with that residual reloaded.
   What RTE hands back -- the residual with `DF` set, nothing with it clear --
   belongs to the **resumed microword's own request**: the bus unit holds it
   until that request is presented, and drops it when the resumed microword
   retires without one, which is a prefetch fault taken at a boundary.

4. **`stg_b`, `stg_c` and the pipe's fault bits are architectural during a
   fault.** They are frame fields and SSW bits, so they may not be used as
   scratch. `xw` exists for an extension word that must outlive a pipe advance.

5. **RMC sequences are atomic to the handler.** UM 8.2.2: if `RM` is set and
   `DF` cleared, "the RTE instruction expects the entire operation to have been
   completed", "even if the fault occurred on the first read cycle". The
   microcode therefore needs an entry point reachable from RESUME meaning "the
   read-modify-write is already done, retire the instruction". **It does not
   have one yet**: RTE resumes the faulted microword whatever `RM` says. That is
   M8-M9's, and `doc/divergences.md` records it until then.

6. **Only `DF`, `RB` and `RC` may have been modified** by the handler -- UM 8.2.2,
   "the only bits in the SSW that may be modified are DF, RB, and RC; all other
   bits, including those defined for internal use, must remain unchanged". RTE
   honours exactly those three, reads `RM`, `RW` and `FC2-FC0` to rerun the
   access, and ignores `FC`, `FB`, `SIZE` (the residual is in `+$08`) and the
   internal bits.

7. **A condition reads a register as it stands, never as the microword is about
   to leave it.** The write is a non-blocking assignment landing on the edge the
   branch steers, so a microword that writes a register and branches on it
   branches on the value before it. `check_cond_dst` in `assemble.py` fails the
   build on that pairing, for the conditions that read a register -- the ones
   that read the ALU *result* are excluded, because testing what the current
   microword computes is what they exist for. RTE's version test is on the
   microword after the one that loads `xw` for the same reason.

8. **Recompute the budget on every addition.** The tables above are printed
   from the source, so they cannot be out of date; the discipline is that the
   number is looked at.

9. **A posted write belongs to no microword.** UM 11.2.5.2: "the MC68030
   incorporates a single write pending buffer", which the bus controller
   empties while the sequencer goes on. The microword
   that asked for it retires the clock after the bus unit takes it, and its
   commits stand -- the register step, the pipe advance, the condition codes.
   One is outstanding at most: the bus unit takes nothing else until it is done.
   - Its bus error is taken at whatever microword M is presented when it
     arrives, as a data fault on M's own access would be: M commits nothing,
     `upc` is M, the frame has DF, the residual, DOB and the write's function
     code, and **`posted`** at +$08 bit 5.
   - RTE with `posted` and DF set hands the residual to the bus unit, which
     runs it by itself as a posted write again -- not for M's request -- and
     RESUME goes to M. With DF clear the handler did it (UM 8.2.2), and RTE
     only resumes. If the rerun faults, the new frame describes M with a write
     outstanding, which is UM 8.2.3's "new stack frame after deallocating the
     previous frame".
   - So any microword may be M, and one that reads state no frame carries may
     not: it **waits** for writes posted before it instead. `mark_sync` in
     `tools/ucode/assemble.py` marks them -- readers of `ea_save`, of RTE's
     taken-apart status word, of the divider, of an earlier read's data or end
     code; RESUME, RTE's hand-back, STOP and RESET; and NOP, which PRM 4 makes
     wait. The level of an interrupt being taken is in the frame (+$08 bits
     12:10), so the interrupt entry needs no wait and may be M like any other.
     One more waits in the RTL: a microword about to take a prefetch fault --
     for its own posted write too -- so that the write, which came first,
     faults first; its write's fault is then an ordinary one on its own
     request.
   - Not posted: read-modify-write (indivisible), CPU space other than a
     coprocessor interface register past the first access (its bus errors are
     answers), and anything that waits for some other reason than an earlier
     read's data. `check_posted` holds the marking to that, and every core
     testbench checks that no waiting microword ever retires with a write
     outstanding.

10. **RTE validates before it restores.** The format word, then -- for `$A` and
    `$B` -- the far end of the frame, then -- for `$B` -- the version nibble,
    and only then the first field. A format error stacks the RTE's own address
    below a frame nothing has been read out of, and a bus error on the far end
    is an ordinary data fault on a microword that has committed nothing (UM
    8.1.13: "in this way, the faulty stack frame remains intact").

11. **A table search is never checkpointed, and never interrupted (M11).** It
    starts after any posted write has finished, runs with RMC held, ends with an
    ATC entry -- B set or not -- and no exception, and the access it was for is
    then retried and faults on its own. The walker's registers go in `EXEMPT`.
    A microword that consumes a search's result -- PTEST's MMUSR and descriptor
    address, PLOAD's entry -- does so before its next bus request, or the result
    goes into a reserved word.

12. **A cache is never checkpointed (M10).** Neither the data cache nor the ATC
    nor the instruction cache holds the only copy of anything, so a fault leaves
    them as they are and RTE puts nothing back. A rerun recomputes cacheability,
    burst and CIOUT from the pins and the tables, as any access does. A fault
    frame describes an operand and never a cache line.

13. **The internal bits of the special status word stay zero** until a milestone
    takes them, and one that does may use them only in the long frame -- the
    short one, which has no version, can come from anywhere and is never read
    for private state (rule 1).

---

## How RTE puts it back

The restore is one microword per field, read straight into the register the
field came from, in an order in which each one is dead by the time it is
written. Four things about it are worth stating, because each is a decision:

- **It validates first.** Rule 10.
- **The read pointer is `ea_save`.** It is the one register in the set RTE does
  not have to put back: the slot it lands in at `+$3C` held the frame builder's
  own pointer and means nothing afterwards.
- **The queue depth is not in the frame.** `RC` and `RB` are, and they say which
  stages RTE still owes a word; the depth comes back from them. A queue with
  room asks the bus unit for the next long word by itself, so UM 8.2.1's "the
  processor may execute a bus cycle to prefetch the instruction word for the
  corresponding stage of the pipe (if it is required)" happens with no separate
  rerun path at all.
- **Resuming is a jump and nothing else.** Rule 2 is what buys that: the faulted
  microword committed nothing, so re-executing it reissues exactly the same
  request. `seq = RESUME` sets the micro-address from the frame -- or, out of a
  short frame, to `rte_boundary` -- and there is no restart sequence to get
  wrong.

The status register is written last and the stack pointer is stepped before it,
for the reason UM 8.1.13 gives the four-word frame: writing the status register
is what decides which of the three stack pointers A7 means.

The prefetches that refill the pipe after the restore run in "the program space
for the privilege level indicated in the copy of the status register on the
stack" (UM 8.2.1). The status register is written after the fill point, so the
pipe holds its fetches from the one to the RESUME that follows the other
(`ckpt_hold`, since M4: before it, a user-mode frame's rerun prefetch went out
in supervisor program space). Stage D of a short frame, which RTE reads itself
before the status register is back, is read with the stacked one explicitly
(`fc = FRAMEPROG`). `core_fault_tb` checks both function codes, returning to
user mode out of each frame format.

---

## How this is verified

Every frame is compared as **memory**, word by word at the offsets UM Table 8-6
gives: a frame this core writes and reads back consistently, but writes in the
wrong place, would pass any check made through its own registers. Each check
names its figure or paragraph.

| Testbench | What |
|---|---|
| `core_fault_tb` | the long frame for a data write, a late-BERR write, a data read, a prefetch fault, an empty-pipe prefetch fault and an address error, every architecturally defined word of each: `+$00` SR, `+$02` PC, `+$06` format and vector, `+$0A` the SSW bit by bit and its internal bits zero, `+$0C`/`+$0E` the stage images against memory when their rerun bit is clear, `+$10`, `+$18`, `+$24`, `+$2C` and the version nibble; RTE continuation in every shape below; RTE refusing a long frame with another version (format error, the frame left intact, the RTE's address stacked); RTE meeting a frame whose far end is unmapped (a bus error before anything is restored, then completion); and RTE out of hand-built **short** frames -- images accepted, rerun bits honoured, a posted write rerun |
| `core_exc_tb` | every four-word and six-word frame word by word -- illegal, A-line, F-line, privilege, TRAP #n, TRAPV, TRAPcc, CHK, zero divide, trace, the interrupts -- the throwaway frame, and RTE's format error for each of the ten format codes the MC68030 does not have |
| `core_cpif_tb` | the coprocessor midinstruction frame (`$9`) word by word: SR, scanPC, format, instruction address, operation word, effective address |
| `core_paging_tb` | every combination of operand size, alignment and port width faulted across a page boundary, the frame of each checked: format, SSW (DF, RW, SIZE = the residual, FC, internal bits), `+$10` = the residual's address, `+$18`, and the version |
| `core_cow_tb` | a real kernel and user process (`sim/programs/cow.S`) through copy-on-write, its memory model refusing read-modify-write cycles as writes the way the MC68030's MMU does (UM 8.2.3); the kernel logs each frame's format, SSW, fault address, SR and version, and the testbench checks every one |

What each RTE case is really asking, because a check that cannot fail on the bug
it is aimed at is not a check:

| | what would have to be wrong for it to fail |
|---|---|
| `MOVEM.L (A0)+,D0-D7` faulting on its fifth transfer | the remaining mask is not restored, and the address register ends somewhere other than eight steps on |
| a misaligned `MOVE.L` to an 8-bit port faulting on its third cycle | the frame records the operand rather than the **residual**. A sentinel is left over the bytes that already went, because both a correct rerun and a wrong one leave the right four bytes in memory |
| a data fault repaired by the handler, `DF` cleared | RTE redoes the access. The handler writes a value the instruction would not have |
| a data read emulated by the handler into `+$2C`, with the page still missing | RTE runs a bus cycle of its own instead of taking the operand out of the frame |
| a prefetch fault discovered two instructions later | the exception is taken when the cycle faults rather than when the word is wanted |
| the same, repaired in the frame and `RC` cleared | RTE refetches instead of accepting the image. The handler writes an instruction that is **not** the one in memory |
| an address error | a bus cycle runs, or the fault bits are set where UM 8.2.1 says only the rerun bits are |
| a long frame with its version nibble changed | RTE restores it anyway, or refuses it after restoring part of it -- the format error's frame would then carry some other program counter than the RTE's |
| a long frame whose last word is on a missing page | RTE starts restoring before it knows the frame is there |
| a hand-built short frame with stage images that are not memory's | RTE reads the short frame's internal words, or refetches a stage whose rerun bit is clear |
| a hand-built short frame with `DF` set on a byte write | the write is not run, or runs at the wrong size or address, or the instruction at `+$02` does not run after it |
| a double bus fault | `STATUS` is not asserted continuously, or the processor carries on |
| every combination of operand size, alignment and port width faulted across a page boundary | anything above, in a shape the directed cases did not think of. Half the cases straddle and half do not, and the sweep counts its own faults so that it cannot pass by not faulting |
| copy-on-write in every shape -- plain, `(An)+`, `-(An)`, memory to memory, `ADDQ`, `BSET`, `BFINS`, `CAS` faulting on its read, a misaligned long word part-written, one across two protected pages, `JSR`, `LINK`, `MOVEM` to `-(SP)` part-way down its list, `PEA`, a byte to `-(A7)` -- each handled by a kernel that saves registers with `MOVEM`, copies the page with a `DBF` loop, calls a subroutine that uses the bit-field unit and the multiplier, and returns with `DF` set; one page the kernel writes itself and clears `DF`; and the first handler taking a fault of its own, two frames deep | RTE does not put back what the handler's work overwrote, or reruns more than the faulted access, or returns to the wrong mode. The memory model refuses a faulted write, so each write has to land exactly once |

`CAS2` is still without a faulting case, and so is rule 5 (`RM` set, `DF`
cleared), which is not implemented.

---

## Open questions

- **The version number.** `$3` is this design's choice. If a real MC68030's
  number were known, choosing a different one would guarantee that a frame from
  real silicon is refused rather than misread; nothing in `Inputs/doc/` gives it.
- **The internal bits of the special status word.** Zero, and ignored. A program
  that inspects them is not known; if one turns up, `doc/divergences.md` is where
  it goes.
