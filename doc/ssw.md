# The special status word

UM 8.2.1, figure 8-9. One word, at `+$0A` of both the short and the long bus
fault frame, and the only part of either frame a handler is allowed to write --
and then only three of its bits.

```
 15   14   13   12   11   10   9    8    7    6    5    4    3    2    1    0
 FC   FB   RC   RB   X    X    X    DF   RM   RW   SIZE      X    FC2  FC1  FC0
                                              \_______/
```

| | | |
|---|---|---|
| `FC` | 15 | stage C was used and found invalid: a bus error on its prefetch |
| `FB` | 14 | stage B likewise |
| `RC` | 13 | stage C is to be rerun -- "a rerun bit is always set when the corresponding fault bit is set" |
| `RB` | 12 | stage B likewise |
| `X` | 11-9 | "for internal use only" -- written as zero here |
| `DF` | 8 | a data fault caused the exception, and is still to be rerun |
| `RM` | 7 | the data cycle was part of a read-modify-write |
| `RW` | 6 | 1 = read, 0 = write |
| `SIZE` | 5:4 | the size of the data cycle, as SIZ1/SIZ0 encodes it -- UM Table 7-2 |
| `X` | 3 | "for internal use only" -- written as zero here |
| `FC2-FC0` | 2:0 | the address space of the data cycle |

The table is `tools/ucode/frames.py`'s `SSW`; `rd68031_frame_pkg` carries the
positions (`SSW_FC` ... `SSW_FCODE_LO`, and `SSW_INTERNAL` for the X bits), and
the sequencer assembles and takes the word apart through them.

## What changed from the MC68020

One thing, and it is in the figure. The MC68020's (UM20 figure 6-8) draws bits
11-9 and 3 as **0**; the MC68030's draws them as **X**, "for internal use only",
and UM 8.2.2 adds: "the only bits in the SSW that may be modified are DF, RB,
and RC; all other bits, including those defined for internal use, must remain
unchanged". So on the MC68030 those four bits may hold anything, and a handler
must preserve them.

**This design keeps nothing in them.** They are written as zero and RTE ignores
what it reads back. Two reasons:

- The word is in both bus fault frames, and the short one has no version field
  (UM 8.1.13 validates the stamp only for the long frame). A private bit there
  could be read back out of a short frame written by something else, which
  `doc/checkpoint.md` rule 1 forbids. A milestone that wants them may use them
  only in the long frame (rule 13).
- The long frame has room: 64 bits are reserved for M8-M11 and 64 more are
  spare (`doc/checkpoint.md`).

Testbenches check them zero in every frame they read, citing this file and not
the manual: zero is this design's choice of content, not the part's.

Everything else -- every bit's meaning, the rerun bits as a promise, which half
belongs to whom -- is the MC68020's word for word, and so is this design's
implementation of it.

## Who owns which half

**The high half is the pipe's and the low half is the bus unit's**, and the two
halves are about different things: UM 8.2.1, "the least significant half of the
SSW applies to data cycles only", and "data and instruction stream faults may be
pending simultaneously; the fault handler should be able to recognize any
combination of the FC, FB, RC, RB, and DF bits". So the word is *assembled* when
the frame is built and *taken apart* when RTE reads it back, and there is no
sixteen-bit register anywhere that holds it.

| bits | lives in | as |
|---|---|---|
| `FC`, `FB` | `rd68031_ifu` | `c_f_q`, `b_f_q` -- already there, already moved along the pipe with the words they describe |
| `RC`, `RB` | `rd68031_ifu` | `stg_c_rerun`, `stg_b_rerun` |
| `DF` | `rd68031_seq` | `df_q`, set by a fault on a data request and cleared at every instruction boundary |
| `RM`, `RW`, `SIZE`, `FC2-FC0` | `rd68031_biu` | the **fault snapshot**, below |
| the X bits | nowhere | zero |

## The fault snapshot

The frame is built by bus cycles. Those cycles run through the same operand
engine that faulted, so by the time the special status word reaches `+$0A` the
registers that would have described the fault have been overwritten four times.
Everything the frame says about the faulted access is therefore **latched on the
clock the fault is recognised** and read from the latch afterwards:

| latch | frame | what |
|---|---|---|
| `flt_addr` | `+$10` | the data fault address, which is the address of the **next** byte still to transfer, not of the operand |
| `flt_dob` | `+$18` | the data output buffer, right justified |
| `flt_dib` | `+$2C` | the data input buffer, long frame only |
| `flt_bytes` | SSW `SIZE`, and an internal word | the residual byte count |
| `flt_fc`, `flt_rw`, `flt_rmc` | SSW | the rest of the low half |

`flt_bytes` is in the frame **twice**, and the second copy is not redundant:
`SIZE` is a two-bit field over UM Table 7-2, which encodes 1, 2, 3 and 4 bytes
and cannot say five. Five is what a bit-field operand spanning five bytes leaves,
so the residual goes in an internal word as well and `SIZE` carries what it can.

## What the MC68030 adds, and does not add, to the word

**Nothing new for the MMU.** UM 8.1.2: "a bus error exception also occurs when
the MMU detects that a successful address translation is not possible". The
MMU's refusals -- an invalid descriptor, a limit violation, a supervisor-only
page, a write-protected page, a bus error during the table search, an ATC entry
with B set -- all arrive as a bus error on the access that was being translated,
on its retry (UM 9.5.2). So when M11 builds them they set exactly what a BERR on
that access sets:

- **a data access**: `DF`, with `RM`, `RW`, `SIZE` and `FC2-FC0` of the faulted
  cycle and `+$10` its **logical** address -- the residual's, if the operand
  straddled into the refused page;
- **a prefetch**: `FC`/`FB` with `RC`/`RB` when the word is used, and the low half
  clear.

No bit says the MMU raised it. The handler asks with PTEST (UM 9.10.3), and a
handler that has to tell a refused write from a bus timeout does the same.

**A read-modify-write on a write-protected page faults on its read.** UM 8.2.3:
"the MMU of the MC68030 treats any bus cycle with RMC asserted as a write
operation for protection checking, regardless of the state of R/W". The word
then has `DF`, `RM` = 1 and `RW` = 1 -- a read -- even though the page refused a
write. RTE with `DF` set reruns the whole operation from that read (UM 8.2.3).
`core_cow_tb`'s memory model refuses exactly that, and its CAS checks it.

**Nothing about caches or bursts.** A fault frame describes an operand. UM
6.1.3.1: a bus error on a fill cycle that carries none of the operand "no
exception occurs, but the corresponding entry is marked invalid"; one that
carries part of it is the operand's fault. UM 6.1.3.2: BERR on a burst beat
after the first takes no exception. So `SIZE` and `+$10` are the operand's
residual, never a cache line's; and the instruction cache's fill errors become
`FC`/`FB` only if the word is ever used, as a prefetch's do.

**MOVES.** `FC2-FC0` is the space the faulted cycle ran in, which for MOVES is
SFC's or DFC's -- and RTE's rerun runs in the space the word names, which UM
8.2.2 forbids a handler to change.

## The rerun bits are a promise, not a record

UM 8.2.1 defines `RC` and `RB` so that they mean *what RTE will do*, not *what
went wrong* -- `FC` and `FB` are the record. Three consequences the microcode is
written to:

1. **`RC` is always set when `FC` is.** The rerun bit is the superset: a stage
   that faulted must be rerun, and a stage that merely has a prefetch pending
   must also be rerun, so `FC = 1, RC = 0` is not a state this core can produce.
2. **An address error sets the rerun bits and not the fault bits.** UM 8.2.1:
   "if an address error exception occurs, the fault bits written to the stack
   frame are not set ... and the rerun bits alone show the cause of the
   exception. Depending on the state of the pipeline, either RB and RC are both
   set, or RC alone is set." No bus cycle ran, so nothing faulted; the words are
   simply missing.
3. **A handler may clear `RC`, `RB` and `DF`, and nothing else.** UM 8.2.2 is
   explicit, and our RTE trusts exactly those three and re-derives everything
   else from the rest of the frame. A handler that repaired stage C writes the
   word into the stage C image at `+$0C` and clears `RC`; RTE then takes the
   image as valid. It is told not to touch `FC`, so `FC` may be set on a stage
   RTE does not rerun, and that is not a contradiction.

## What RTE does with it

UM 8.2.3. The instruction always executes; what it reruns depends on what the
handler left. RTE reads `RC`, `RB`, `DF`, `RM`, `RW` and `FC2-FC0` back, and
ignores `FC`, `FB`, `SIZE` (the long frame's internal word has the residual) and
the X bits.

| | |
|---|---|
| `DF` set | rerun the faulted data access from `flt_*` restored into the bus unit, and -- if `RM` is also set -- rerun the whole read-modify-write, from its faulted cycle |
| `DF` clear, `RM` set | UM 8.2.2: "the RTE instruction expects the entire operation to have been completed if the RM bit is set and the DF bit is cleared. This is true even if the fault occurred on the first read cycle." **Not yet**: RTE resumes the faulted microword as it does with `RM` clear -- `doc/divergences.md`, M8-M9 |
| `RC` or `RB` set | run the prefetch for that stage. `FC`/`FB` set as well means the cycle faulted and is rerun; clear means the stage was merely pending. This core expresses it as the **queue depth**: RC and RB say which stages RTE still owes a word, the depth comes back from them, and a queue with room asks the bus unit for the next long word by itself. There is no separate rerun path for a prefetch to get wrong, and no flag carried across the rest of the RTE |
| `RC`, `RB`, `DF` all clear | the images on the stack are taken as valid and nothing is rerun |

Out of a **short** frame -- which this design never builds, so one RTE meets
came from somewhere else -- `DF` reruns only a write, as a posted write of its
own, sized by `SIZE`: the short frame has no internal word to carry a residual,
and UM 8.2.2 says "data read faults only generate the long bus fault frame".
`doc/checkpoint.md` has the rest of that restore.

"If a fault occurs when the RTE instruction attempts to rerun the bus cycle(s),
the processor creates a new stack frame on the supervisor stack **after
deallocating the previous frame**" -- so the rerun happens after the stack
pointer has been stepped, and a fault there is an ordinary bus error and not a
double bus fault.

A fault **while RTE is reading the frame** is a different matter. UM 8.1.2
makes it a double bus fault -- "or while the processor is loading internal
state information from the stack during the execution of an RTE instruction" --
and this design does not yet (`doc/divergences.md`). What it does do, since
M4, is read the frame's far end **before** it loads anything (UM 8.1.13), so a
frame that is not all there faults while nothing has been restored, as an
ordinary bus error that its handler can fix and return from.
