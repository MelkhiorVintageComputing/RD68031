# Bugs found in RD68031 that are inherited from RD68021

RD68031 was forked from RD68021's MC68020 at M0. Re-deriving each part against
the MC68030 manual, and running the new oracles, found the defects below in
code that came from RD68021 unchanged. They apply to the MC68020 as well. Each
one was found and fixed in RD68031, and the full entry, with the test that now
catches it, is in `doc/bugs-found.md` under the milestone given here.

None of this has been run on RD68021 itself. "Present in RD68021" means the
code it came from is the same; it is not a confirmation on that tree.
Citations are to the MC68030 manual (UM) and the M68000 PRM; the MC68020
manual's matching sections should be checked before fixing RD68021.

## Bus unit

- **DBEN was active high** (M1). DBEN is active low on both processors. RD68021's
  ruler testbench encoded the inversion as the expected value.
- **Strobes could glitch** (M1). AS, DS, DBEN, ECS, OCS and the data enable were
  decoded from a multi-bit state register. A transition that changes two bits
  (S2→S4) can pass through a decoded code for an instant. Every pin now comes
  from a flip-flop.
- **No single-wire arbitration** (M2). BGACK alone did nothing: the arbiter left
  its idle state only on BR (UM 7.7.4, figure 7-61). Inside a read-modify-write,
  the release also waited for RMC forever.
- **The re-grant pulsed BG** (M2). With two masters on BR, BG was negated and
  re-asserted every two clocks while the first master still held the bus. The
  manual's figure has seven arbiter states; RD68021 had five, because the PDF's
  text layer loses the overbars.
- **HALT on an idle bus did not stop the next cycle** (M2), so single-stepping
  (UM 7.5.3, figure 7-57) did not work from an idle bus.
- **Relinquish-and-retry on the first read of a read-modify-write** was a plain
  retry (UM 7.7.4, 7.5.2), so the other master waited for the whole locked
  sequence.
- **Port size taken on the first DSACK edge** (M3). A 32-bit port whose DSACK1
  trailed DSACK0 by a legal amount was read as an 8-bit port, and the bytes
  were assembled wrongly with no error.
- **The end of a retry read BERR and HALT raw on a rising edge** (M3). Both are
  asynchronous inputs specified around the falling edge, so the sample could be
  metastable.
- **IPEND was combinational** (M3). It moved on both edges and could glitch; it
  is now a registered output.
- **IPEND negated too early** (M8–M9). It went inactive when the interrupt
  exception raised the mask, a few microwords before the acknowledge cycle,
  rather than at the acknowledge's S0 (UM 8.1.9).

## Exceptions and RTE

- **The trace exception traced itself** (M1). With T1 set, a second trace frame,
  holding the handler's address, was stacked before the handler ran. An
  interrupt taken just after an instruction set T1 did the same.
- **A traced instruction that faulted traced its own bus error handler** (M8–M9).
  The trace must be deferred until the instruction completes after RTE (UM 8.1.7).
- **Reset exception processing was not a double-bus-fault window** (M8–M9). A bus
  error on the reset vector read took an ordinary bus error, and a prefetch
  fault there hung the core (UM 8.1.1).
- **RTE never checked the version number** of a long bus fault frame (M4, UM 8.1.8).
- **RTE restored before checking the whole frame was readable** (M4, UM 8.1.13).
  A long frame whose top was on a missing page faulted half-restored.
- **RTE trusted a short frame's internal words** (M4). It could resume at
  whatever micro-address `+$14` held in a frame written by software.
- **RTE's rerun prefetch ran in supervisor space** for a user-mode instruction,
  because the pipe refilled before SR was restored (M4, UM 8.2.1).
- **RTE reran a read-modify-write from the faulted cycle** rather than the start
  (M8–M9, UM 8.2.3). A CAS faulted on its write then wrote its old decision over
  whatever another master had written in the meantime.

## Instructions

- **CAS/CAS2 on a failed compare wrote all 32 bits** of Dc for byte and word
  operands (M6).
- **CAS2 with Dc1 = Dc2** left memory operand 2 in the register; PRM 4 says
  operand 1 (M6).
- **BFFFO with the offset in a register** returned the offset modulo 32 plus the
  bit position (M6). RD68021 chose this on purpose, from a gap in the manual;
  RD68031 now follows PRM 4's full-offset reading (its
  `doc/manual-contradictions.md` entry 14).
- **CMP2/CHK2 with (d16,PC) read their bounds in data space**, and so did the
  memory reads of BFTST, BFEXTU, BFEXTS and BFFFO (M6, UM 2.4.11–2.4.15).
- **CHK2.B/CMP2.B through A7 read the upper bound at A7+2** (M6). The A7
  byte-step rule was applied where it does not belong.
- **MOVEM to -(An) with An in the list** stored An's initial value: the MC68010
  behaviour. The MC68020 and MC68030 store An minus the size (M6, PRM 4).
- **Divide by zero left C unchanged**; PRM 4 says it is always cleared (M6).
- **The A7 byte rule in two-register forms** (M6). ABCD and SBCD stepped both
  registers by one; ADDX, SUBX and CMPM applied the rule from the wrong register.
- **`BTST Dn,#<data>`** was taken as an illegal instruction (M6).
- **cpSAVE/cpRESTORE in user mode without a coprocessor interface** took an F-line
  exception instead of a privilege violation (M6).
- **Illegal effective addresses executed** (M6). PC-relative destinations were
  written to, MOVE to a nonexistent destination ran its source, and so on;
  `EOR.B D7,(d8,PC,Xn)` never returned. They are now refused at decode.
- **UNLK A7** left the old SP + 4 instead of the long word popped (M6). PRM 4
  contradicts itself here; the description and the real part agree on the
  popped value.

## Testbench only

- RD68021's bus harness left four bus-unit inputs floating (`req_cpfault`,
  `req_post`, `rst_cancel`, `rst_post`), so posted-write bookkeeping ran on x in
  every bus testbench and still passed (M1).

## Deliberately not changed

- **LINK A7** pushes the stack pointer after the decrement, as PRM 4's operation
  line says. The real part pushes the value from before it (cputest corpus).
  RD68031 follows the manual by decision, and keeps it as the first suspect if
  real software misbehaves (`doc/divergences.md`).
