# M6–M7 phase A: what the instruction-level oracles found

This is the list phase B works from. Every flow of `doc/oracles.md` was run on the RTL
as committed at 2afda17, with the harness of this phase, and every disagreement is here,
in one of three classes:

- **(a)** a likely RTL bug — the manual says what the core should do, and it does not;
- **(b)** an oracle quirk or a harness issue — fixed in the harness, or recorded in
  `doc/oracles.md`, and listed here so that nobody fixes the RTL for it;
- **(c)** behaviour the manual leaves undefined — needs an srmask or an exclusion.

Everything is phrased as architectural behaviour with a manual citation. Nothing here
comes from the oracle's implementation; "the oracle says" means "UAE030 produced this
value", nothing more. UM is `MC68030UM_split`, PRM is `M68000PRM_split`.

## Summary

| Flow | Result | Notes |
|---|---|---|
| `make ea` | 703 / 703 pass | after one harness correction (b1) |
| `make cosim` | arith 19,497 and corners 2,157 instructions, every register (USP, ISP, MSP, SR, VBR, CACR, CAAR, SFC, DFC included) at every boundary: pass | |
| `make vectors-all` | 12,042 / 12,200 pass; 158 fail, all class (a) | 4 dropped (odd-PC address errors), 2 dropped (more than 24 accesses) |
| `make cache` | no difference the cache makes | the directed testbenches all pass at `ICACHE_ENTRIES=0`; the sweep fails the same 158 vectors with the same first difference both ways; `make ea` 703 / 703; both programs identical (end of this file) |
| `make cputest` | 6,588 / 6,706 pass; 118 fail: 101 class (a), 3 class (c), 14 open questions Q2/Q3 | details under "cputest" |

Class (a), the sweep: **A1** CAS/CAS2 compare-operand load (99 vectors: 45 CAS.B, 45
CAS.W, 9 CAS2.W), **A2** BFFFO offset (18), **A3** CMP2/CHK2 program-counter-relative
reads in data space (24), **A4** MOVEM to `-(An)` storing An (4), **A5** divide by zero
leaves C set (1), **A7** `BTST Dn,#<data>` taken as illegal (12; found by cputest, then
added to the sweep's `bit` group).

### Phase B

Every class (a) item is fixed (A1-A9, A11, and A12, which the corpus reached once
A1 was fixed); A10 turned out to be a reserved trace encoding and is handled as
class (c); Q2 and Q3 are settled. Each fix has a `doc/bugs-found.md` entry and a
directed check in `core_insn_tb`. After phase B:

| Flow | Result |
|---|---|
| `make vectors-all` | 12,200 / 12,200 pass (the same 4 + 2 dropped) |
| `make cputest` | after phase B, 6,692 pass, 4 fail, 10 excluded, of 6,706. The 4 were SBCD on operands that are not BCD (class c); following the user's decision to follow the manual, `convert.py` now excludes every non-BCD operand as undefined (`doc/divergences.md`). The 10 are LINK A7 (Q2), run and set aside by encoding |
| `make ea` | 703 / 703 |
| `make cosim` | arith 19,496 and corners 2,156 instructions: pass |
| `make cache` | pass: directed testbenches at `ICACHE_ENTRIES=0`, the sweep 12,200 / 12,200 uncached, `make ea` 703 / 703, both programs with identical data cycles (fetches 16,347 -> 499 and 2,532 -> 170) |
| `make check`, `make sim COPROCESSOR=1` | pass |

---

## Class (a): likely RTL bugs

### A1. CAS: the compare operand is loaded at 32 bits, not at the operand's size

**Resolved (phase B).** `DST_DREG_XR` writes at the operand size (`rd68031_seq`). The `cas` group and the corpus pass; `core_insn_tb` checks CAS.B, CAS.W and CAS2.W. The corpus then reached a second CAS2 defect, a shared compare register (A12).

- **Instructions:** `CAS.B Dc,Du,<ea>` and `CAS.W Dc,Du,<ea>`, when the comparison fails
  (encodings `0AD1 0142`, `0CD1 0142`: `CAS.x D2,D5,(A1)`, and every other memory mode).
  45 byte and 45 word vectors, and 9 CAS2.W (A1').
- **Inputs (vector $292E):** `CAS.B D2,D5,(A1)`, D2 = $3E05A9F4, A1 = $22EE, the byte at
  $22EE = $19, so the comparison fails.
- **Expected:** D2 = $3E05A919. **Got:** D2 = $00000019. Same for `.W`: D2 = $40848A01,
  word $AACA at the operand → expected $4084AACA, got $0000AACA.
- **Manual:** PRM 4, CAS: "Else Destination → Compare Operand", with Size = byte, word,
  long; an operation of a given size writes only that many low-order bits of a data
  register (PRM 2/3, data register operands: "byte and word operands ... only the
  low-order portion is changed"). The upper bits of Dc must be kept.

**A1'. CAS2.W, the same** (`0CFC 9102 A143`: `CAS2.W D2:D3,D4:D5,(A1):(A2)`): when a
comparison fails the instruction "writes the memory operands (Rn1 and Rn2) to the compare
operands (Dc1 and Dc2)" (PRM 4). Vector $29BE: D2's upper half is lost ($0000FFAD,
expected $C300FFAD).

### A2. BFFFO with a register offset returns the offset modulo 32

**Resolved (phase B).** `BF_FFO` is the whole offset plus the position, register or memory field. RD68021's reading of the gap is withdrawn: `doc/manual-contradictions.md` entry 14.

- **Instruction:** `BFFFO <ea>{Dn:w},Dn` with the offset in a data register (`EDC3 3820`:
  `BFFFO D3{D0:32},D3`; also `3925`, `38A0`). 18 vectors.
- **Inputs (vector $24D8):** D0 = $FEB7AFF7 (the offset), D3 = $F0962F87 (the field
  source); bit 0 of the field (the first one bit) is set.
- **Expected:** D3 = $FEB7AFF7 (the offset plus 0). **Got:** D3 = $00000017.
- **Manual:** PRM 4, BFFFO: "The bit offset of that bit (the bit offset in the instruction
  plus the offset of the first one bit) is placed in Dn. If no bit in the bit field is set
  to one, the value in Dn is the field offset plus the field width." The offset in the
  instruction is the whole signed 32-bit value of Do (PRM 4, bit-field offset: "−2^31 to
  2^31 − 1" for a register offset); taking it modulo 32 selects the *field* in a register
  operand, but the *result* is the offset plus the position, not reduced.

### A3. CMP2 and CHK2 read their bounds through `(d16,PC)` in data space

**Resolved (phase B).** The bounds reads take `fc = EASP`. The same fixed data space was on the memory read of BFTST, BFEXTU, BFEXTS and BFFFO, which take the PC-relative modes too and which no flow exercises that way; fixed with it, and `core_insn_tb` checks both from the access recorder.

- **Instructions:** `CMP2/CHK2.B/.W/.L (d16,PC),Rn` (`00FA`, `02FA`, `04FA`), 24 vectors.
- **Inputs (vector $29E0):** `CMP2.B (d16,PC),D2` with d16 = $10FC, so the bounds are at
  $2100 and $2101.
- **Expected:** two reads at $2100 and $2101 in **program** space (FC 6). **Got:** the
  same reads in data space (FC 5).
- **Manual:** UM 2.4.11: "(d16,PC) ... The reference is a program space reference and is
  only allowed for reads" (UM 4.2, address space types). Every other instruction's
  PC-relative operand reads (`make ea`, and the `sweep_pc` cases of every group) are in
  program space; CMP2/CHK2's bounds fetch is the exception.

### A4. MOVEM to `-(An)` stores An's initial value when An is in the list

**Resolved (phase B).** `REGNR` gives An less the operand size for the addressing register (`rd68031_seq`).

- **Instructions:** `MOVEM.W/.L <list>,-(An)` with An in the list (`48A3 FFFF`,
  `48E3 FFFF`: all sixteen registers to `-(A3)`). 4 vectors.
- **Inputs (vector $2B60):** `MOVEM.L D0-A7,-(A3)`, A3 = $219E.
- **Expected:** the long word stored for A3 is $219A (A3 − 4). **Got:** $219E. (Word
  form, vector $2B48: A3 = $220A, expected $2208, got $220A.)
- **Manual:** PRM 4, MOVEM: "For the MC68020, MC68030, MC68040, and CPU32, if the
  addressing register is also moved to memory, the value written is the initial register
  value decremented by the size of the operation. The MC68000 and MC68010 write the
  initial register value (not decremented)." The core does the MC68000's.

### A5. A divide by zero leaves C as it was

**Resolved (phase B).** `exc_divzero` clears N, Z, V and C (`CLRNZVC`) before the status register is copied; X is kept.

- **Instruction:** `DIVU.W #0,D1` (`82FC 0000`), the traps group's divide by zero.
- **Inputs (vector $2F3E):** SR = $2719 (X, N and C set).
- **Expected:** the SR the zero-divide exception stacks, and the one the handler starts
  with, have C clear ($2712 from the oracle; N, Z and V are undefined and masked).
  **Got:** C still set ($2719).
- **Manual:** PRM 4, DIVU/DIVS: "C — Always cleared." with no exception for a zero
  divisor (N, Z and V carry "undefined if ... divide by zero"; C does not). UM 8.1.4 (the
  zero divide exception) stacks the SR as the instruction left it.

---

## Class (b): oracle quirks and harness issues

Each is handled in the harness (the place is named) and recorded in `doc/oracles.md`
("Quirks"); none needs an RTL change. They are listed because each one, untreated, looks
like an RTL bug.

| | What differed | Manual | Done |
|---|---|---|---|
| b1 | PC-relative operand reads, and the indirect address of the PC memory-indirect modes, came from the oracle in data space | UM 2.4.11–2.4.14: program space | `uae030_ea.c`, `gen.c` take the space from the mode |
| b2 | the exception vector was read before the stack frame was written (every trap, CHK, illegal, privilege violation vector) | UM 8.1: frame (third step), then the vector (last) | `gen.c` puts the vector read after the frame |
| b3 | RTE read SR first; on a format error it read the whole frame | UM 8.1.13: the frame is validated (format word) before it is read | `gen.c`: the format word first; nothing else on a format error |
| b4 | the format $2 frame's instruction address was the *next* instruction for CHK2, TRAPcc, TRAPV and the zero divide (CHK and trace were right) | UM 8.4, table 8-6, the six-word frame (format $2): "INSTRUCTION ADDRESS is the address of the instruction that caused the exception" for CHK, CHK2, cpTRAPcc, TRAPcc, TRAPV, trace, zero divide | `gen.c` records the instruction's address; settled (Q1, below) |
| b5 | CAS2 wrote destination 2 before destination 1 | PRM 4, CAS2: "Update 1 → Destination 1; Update 2 → Destination 2" | `gen.c` records 1 then 2. **Reversed at M11 part 2:** AP68030 writes destination 2 first as well, the listing is not a bus order, and the core now does the same (`doc/manual-contradictions.md` 26, `doc/m11-mismatches.md` Q-B) -- so it is no longer a quirk, and `gen.c` no longer reorders: the stream records UAE030's two writes in the order it makes them |
| b6 | DIVU/DIVS overflow left C unchanged | PRM 4: "C — Always cleared" | `gen.c` clears C |
| b7 | a bit field in memory came as a long word and a byte (or a word and a byte); the core moves it as one operand of up to five bytes | PRM 4 NOTE: only the bytes the field covers — both do | `gen.c` merges the oracle's pieces |
| b8 | PACK/UNPK `-(An)` moved one word; the core two bytes, the higher address first | PRM 4: "two bytes from the source are fetched" | `gen.c` splits the oracle's word |
| b9 | an instruction-cache burst fill (CACR EI and IBE set by a MOVEC test) appeared as three program-space operand reads | — | the glue labels them instruction fetches |
| b10 | a JMP/JSR to an odd address: the core takes the address error inside the instruction, the oracle at the next prefetch | UM 8.1.3 | dropped (long $B frame either way) |
| b11 | RD68021's "DIVU.L #0" vector was `$82BC`, which is OR.L #imm,D1 | — | now `DIVU.W #0` (`$82FC`) |
| b12 | the oracle traced a NOP under T0 | UM 8.1.7: T0 traces changes of flow | harness: the refetch after a state change counted as a flow change; fixed in `uae030_set_state` |
| b13 | the format $2 trace frame's address was stale (an earlier test's) | — | harness: `uae030_set_state` now latches it |
| b14 | traced tests: the core never traced | — | harness: a deposited SR reaches the core after it decides to trace the instruction; `core_vec_tb` now enters traced tests through an RTE, and waits for the boundary after the instruction where the trace is taken |
| b15 | the exception vector read of a PC-relative test was labelled program space | — | harness: the program-space rule stops at the first exception |

---

## Class (c): undefined behaviour

The sweep masks, as RD68021's did, the condition codes PRM 4 leaves undefined — N and V
after ABCD, SBCD, NBCD; N and Z after a divide overflow, N, Z and V after a divide by
zero; N, Z, V, C after CHK; N and V after CMP2/CHK2 — in the final SR and in the SR an
exception stacks. Nothing else needed a mask. Nothing fell into this class in the sweep.

---

## cputest

`make cputest` (default `CPUTEST_MAX=40`): 6,588 of 6,706 tests pass (40 per instruction, from a corpus of about 1.57 million over 176 instruction files); 118 fail: A1 68, A2 8, A4 1, A6 12, A7 3, A8 2, A9 4, A10 1, A11 2, Q2 10, Q3 4, class (c) 3. 80 tests whose result the manual leaves undefined were excluded (below). Every failure below was read
against the decoded test (`python3 tools/cputest/convert.py dump <set> <INSTR>`; the test
numbers map through `build/cputest/cputest.idx`). Instructions are written as cputest
names them. The corpus confirms A1 (CAS.B, CAS.W, CAS2.W, CAS2.L), A2 (BFFFO) and A4
(MOVEM.L to `-(A6)` with A6 in the list: stored $BF00, expected $BEFC), and adds:

### A6. A byte operation through `-(A7)` or `(A7)+`: the "keep A7 even" rule is applied to the wrong register, or not at all

**Resolved (phase B).** A second operand-size source, `OPSIZEW`, applies the rule from Ax (bits 11:9); ADDX, SUBX, CMPM and the BCD pair step Ax by it, and the BCD pair steps Ay by `OPSIZE` instead of a constant one.

- **Instructions:** the two-register forms — `ABCD`, `SBCD`, `ADDX.B`, `SUBX.B`
  `-(Ay),-(Ax)` and `CMPM.B (Ay)+,(Ax)+` — with A7 as one of the two.
- **Inputs and results** (USP = $8400, A6 = $BF00):
  - `ABCD -(A6),-(A7)` (`CF0E`), and the same for SBCD (`8F0E`), ADDX.B (`DF0E`), SUBX.B
    (`9F0E`): expected USP = $83FE; got $83FF, and the byte stored at $83FF instead of
    $83FE.
  - `ABCD -(A7),-(A7)` (`CF0F`): expected USP = $83FC; got $83FE.
  - `ADDX.B -(A7),-(A6)` (`DD0F`): expected A6 = $BEFF; got $BEFE — the rule moved A6.
  - `CMPM.B (A7)+,(A6)+` (`BD0F`): expected A6 = $BF01; got $BF02. `CMPM.B (A6)+,(A7)+`
    (`BF0E`): expected USP = $8402; got $8401.
- **Manual:** UM 2.4.4 and 2.4.5 (address register indirect with postincrement and
  predecrement): "If the address register is the stack pointer and the operand size is
  byte, the address is incremented [decremented] by two to keep the stack pointer aligned
  to a word boundary." The rule belongs to whichever of Ax and Ay is A7, and to no other.

### A7. `BTST Dn,#<data>` is taken as an illegal instruction

**Resolved (phase B).** A pattern for `0000 ddd1 0011 1100` ahead of BTST Dn,<ea>, and three microwords (`btst_d_imm`).

- **Instruction:** `BTST Dn,#imm` (`0D3C 2AFD`, `0F3C 21C2`, `013C 152C`).
- **Expected:** the instruction executes (Z from the immediate byte's bit Dn mod 8) and
  the test ends at the sentinel, $C004. **Got:** vector 4 at $C000.
- **Manual:** PRM 4, BTST, the addressing-mode table for `BTST Dn,<ea>`: `#<data>` is
  allowed (the only bit instruction for which it is).
- **The sweep:** the `bit` group did not emit it; it now does (`033C 00A5`, `033C 005A`:
  `BTST D1,#imm`, 12 vectors, its random stream put back afterwards so no other vector
  changed). All 12 fail the same way: the core stacks a format $0 frame for vector 4
  (ISP $2700 → $26F8); the oracle executes the instruction.

### A8. cpSAVE/cpRESTORE in user mode take the F-line exception, not a privilege violation

**Resolved (phase B).** Without the coprocessor interface, cpSAVE and cpRESTORE with a valid effective address go to `cp_nocp_priv`: privilege violation in user mode, F-line exception in supervisor mode. (With it built, the S bit was already tested first.)

- **Instruction:** `$F557` (cpRESTORE, coprocessor ID 2, `(A7)`), in user mode, with no
  coprocessor 2.
- **Expected:** vector 8, privilege violation, stacked PC $C000. **Got:** vector 11.
  (In supervisor mode both take vector 11.)
- **Manual:** UM 10.2.3.4 (cpRESTORE): "If the MC68030 attempts to execute a cpRESTORE
  instruction while at the user privilege level ... it initiates privilege violation
  exception processing without accessing any of the coprocessor interface registers";
  cpSAVE the same (UM 10.2.3.3). The privilege check comes before the coprocessor is
  addressed at all.

### A9. Two illegal encodings: one has side effects, one hangs the core

**Resolved (phase B).** `tools/ucode/program.py` (`_refuse_modes`) puts refusal patterns in front of the opcode patterns: PC-relative modes for every instruction whose operand is written, MOVE's non-existent destinations (and An for MOVE.B), (An)+ and -(An) for the control-mode instructions (the corpus's `BFCLR -(A3)`, `$ECE3`, which hung the core, surfaced once A1-A11 were fixed), and An as a byte operand of ADD, SUB, CMP, ADDQ, SUBQ.

- `$1BDA` — MOVE.B `(A2)+` to destination mode 7, register 5, which does not exist.
  **Expected:** vector 4, nothing changed. **Got:** vector 4, but A2 incremented ($7FF0
  → $7FF1) and Z set in the stacked SR: the source operand was fetched before the
  destination was found invalid.
- `$BF3B` — EOR.B D7,`(d8,PC,Xn)`: a PC-relative destination, not data alterable.
  **Expected:** vector 4. **Got:** the core never reaches a handler (24 instructions, 3000
  clocks each); the bench resets it and carries on.
- **Manual:** UM 8.1.5 (illegal and unimplemented instructions): an illegal instruction
  is detected at decode and the exception is taken with the PC of the illegal
  instruction; PRM 4, MOVE and EOR, list the legal destination modes.

### A10. A status-register write that sets T1 does not trace the next instruction

**Resolved (phase B) -- reclassified.** `$C534` sets T1 *and* T0, which UM table 8-3 calls "Undefined, Reserved": not a class (a) item but class (c). With T1 alone the core already traced the next instruction (now checked by `core_insn_tb`). For 11 the core now does what the corpus records -- T1 decides (`trace_take`) -- and `doc/divergences.md` records the choice.

- **Instruction:** `ORI #$C534,SR` (`007C C534`) in supervisor mode; the sentinel NOP
  (`MOVEA.L A0,A0`) follows.
- **Expected:** the NOP is traced: vector 9, format $2, PC $C006, address $C004.
  **Got:** no trace; the NOP runs and the ILLEGAL after it takes vector 4.
- **Manual:** UM 8.1.7 (trace): with T1 set, a trace exception follows every instruction;
  the T bits are those in force when an instruction starts. The ORI itself is not traced
  (T was clear when it started); the instruction after it is.
- Note: the sweep's `trace` group passes, but it sets T before the instruction; this is
  the case of T being set *by* the instruction before.

### A11. CHK2.B through A7 reads the wrong upper bound (likely)

**Confirmed and resolved (phase B).** A bug: the step from the lower to the upper bound used `OPSIZE`, which carries the A7 byte rule, so any CHK2.B/CMP2.B whose effective-address register field is 7 read the upper bound at A7+2. `core_insn_tb`'s CHK2.B (A7),D0 failed before the fix. The step is now `OPBYTES`, the operand size with no A7 rule.

- **Instructions:** `CHK2.B (A7),D0` (`00D7 0800`) and `CHK2.B (d16,A7),D0`
  (`00EF 0800 744D`), user mode.
- **Inputs:** USP = $8400, the bytes at $8400 are $31, $4F, $74; D0 = $6A.
- **Expected:** $6A is above the upper bound $4F: vector 6. **Got:** no trap. With
  `(d16,A7)` the opposite. Both results are what the bounds would give if the upper bound
  were read at A7+2 — the A7 byte rule of A6 again, applied to an operand that is
  neither postincrement nor predecrement. CHK2.B through any other address register
  passes. To be confirmed from the core's access list.
- **Manual:** PRM 4, CHK2: the bounds are "a pair of bounds ... the lower bound first",
  at consecutive locations of the operand's size.

### A12. CAS2 with Dc1 = Dc2 keeps memory operand 2 (found in phase B)

- **Instruction:** `CAS2.L D3:D3,D2:D6,(A7):(A6)` (`0EFC F083 E183`), the
  comparison failing. Reached once A1 was fixed.
- **Expected:** D3 = memory operand 1 ($314F7457, at USP). **Got:** memory
  operand 2 ($401D0000).
- **Manual:** PRM 4, CAS2, the Dc1 and Dc2 fields: "If Dc1 and Dc2 specify the
  same data register and the comparison fails, memory operand 1 is stored in
  the data register."

**Resolved (phase B).** `cas2_fail` writes Dc2 first and Dc1 last.

### Class (b) found by cputest

| | What differed | Done |
|---|---|---|
| b16 | the generator's undefined-flag masks are emitted for `feature_undefined_ccr=0`, not 1 as its readme says | ini set to 0 |
| b17 | the runner keeps the last mask it was sent; a test without an SR item inherits it, and the generator left the first CHK2.B test without one | `convert.py` carries the mask over, and adds PRM 4's own undefined flags (as the sweep does) |
| b18 | the generator stalls on some instruction under some seeds (OR.L under seed 1, CHK under seed 2), and aborts on RTS/RTD/RTR/RTE with other splits of 64 KB | generated one instruction at a time, with a time limit and a second seed |

### Class (c) found by cputest

- **T1 = T0 = 1** (A10, reclassified in phase B): UM table 8-3, "Undefined,
  Reserved". The core takes it as T1 alone, as the corpus records the part
  doing (`doc/divergences.md`).
- **MULU.L/MULS.L with a 64-bit product and Dh = Dl** (`4C27 05D0`): PRM 4: "If Dh = Dl
  and size is one, the results of the operation are undefined." Excluded by `convert.py`
  (80 tests, before sampling).
- **SBCD/ABCD on operands that are not BCD** -- *phase B: left failing, as 4
  SBCD tests now (one was hidden behind A6 before); recorded in
  `doc/divergences.md` with the core's result for each.* The original note: (`8906`, SBCD D6,D4 with the destination
  byte $D5): the corpus's operands are random; PRM 4 defines the decimal instructions on
  BCD digits only (the sweep feeds them valid digits). The value and X/C differ. Left in
  the list, not masked: an exclusion needs the operands, and there are 3.

## Open questions

- **Q1 (settled).** The format $2 frame's address for CHK2, TRAPcc, TRAPV and the zero
  divide (b4). UM table 8-6 says the instruction's own address, and the core does that.
  UAE030 (Hatari's copy) stacks the next instruction's for these four. The cputest corpus,
  generated by WinUAE's own copy of the core (the tester written to be checked against
  real processors), stacks the instruction's address: every one of the 93 sampled tests
  with a format $2 frame -- 65 CHK/CHK2 (vector 6), 28 zero divides (vector 5) -- has the
  address equal to the test's start PC, and the core passes all of them. Manual, corpus
  and core agree; b4 is a quirk of the Hatari copy, and the harness's correction stands.
  (No TRAPcc/TRAPV test with a trap was in the sample.)

- **Q2 (settled, phase B).** Follow PRM 4's operation: LINK A7 pushes the
  decremented stack pointer, which the core already did. The corpus's value is
  likely the silicon's, and the difference is recorded in
  `doc/manual-contradictions.md` entry 15 and `doc/divergences.md`;
  `core_cputest_tb` runs the 10 tests and counts them as excluded by encoding
  (`$4E57`, `$480F`), not failed. Original question:
  `LINK An,#d` with An = A7 (`480F`, `4E57`): the value pushed. The core pushes
  A7 after the decrement ($83FC for USP = $8400); the corpus expects the value before it
  ($8400). PRM 4's operation, read literally ("SP − 4 → SP; An → (SP)"), gives the
  core's answer; the oracle -- whose tester was written against real processors --
  the other. Not a register any compiler would use; LINK.W and LINK.L both, 10 tests.
- **Q3 (settled, phase B).** The manual contradicts itself: the operation line
  gives the long word plus four, the description ("loads the address register
  with the long word pulled from the top of the stack") the long word. The
  core now follows the description, which the corpus agrees with; the core's
  old answer matched neither (`doc/manual-contradictions.md` entry 16,
  `doc/bugs-found.md`). Original question: `UNLK A7` (`4E5F`): the corpus expects A7 = the long word loaded from the stack
  ($314F7457); the core leaves the incremented stack pointer ($8404). PRM 4's operation
  ("An → SP; (SP) → An; SP + 4 → SP") read literally gives neither (the loaded value plus
  four). The manual does not settle it; the oracle's answer is the natural one for "the
  load is the last write to A7". 4 tests.

---

## `make cache`

The instruction cache is architecturally invisible (UM 6.1: it holds instruction
prefetches only), so a core built without it must give every answer the cached core
gives. Run at 2afda17's RTL with this phase's harness:

| Step | `ICACHE_ENTRIES=0` |
|---|---|
| the directed testbenches (`make sim`) | all 22 pass |
| the sweep (`make vectors`, 12,200 vectors) | 12,042 pass; the 158 failures are the cached core's 158, vector for vector, with the same first difference -- every one is A1, A2, A3, A4, A5 or A7 above, none the cache's |
| `make ea` | 703 / 703 |
| arith, 19,496 instructions, both builds | 2,318 data cycles identical; instruction fetches 16,347 → 499 with the cache (96.9 % taken by it) |
| corners, 2,156 instructions, both builds | 608 data cycles identical; instruction fetches 2,532 → 170 (93.3 %) |

Nothing here is a mismatch. The target used to fail on the sweep's RTL failures alone;
it now compares the uncached sweep's failure list with the cached core's last full sweep
(`build/vectors.fail`, from `make vectors-all`) and fails only on a difference, or, with
no list to compare with, on any failure.
