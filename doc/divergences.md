# Where this design does not behave as the part does

Every standing difference between RD68031 and a real MC68030, why it is there, and
how it is checked. Cycle-count differences live in `doc/timing-divergences.md`;
this file is for behaviour.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/divergences.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---

## STATUS is encoded from what the sequencer can say, one clock late

**UM 12.7.1 and Table 12-4.** STATUS is asserted for one clock at an instruction
boundary, two at a boundary where a trace or an interrupt exception is to be taken,
three when exception processing begins "for reset OR bus error OR address error OR
spurious interrupt OR autovectored interrupt OR F-line instruction (no coprocessor
responded)" or on an ATC miss, and continuously once halted by a double bus fault.

**What this design does.** The sequencer reports four events — a boundary, a
boundary with a trace or interrupt taken, the start of exception processing, a
pipeline refill — as one-clock pulses registered on the rising edge after them, and
the bus unit, which owns the pins, shows each as the table's number of clocks from
the next falling edge:

- **Three clocks** for reset and for a bus or address error (the fault entry).
  The spurious and autovectored interrupts and the F-line with no coprocessor are
  decided in microcode, after the interrupt or F-line has already been reported
  as a boundary, and are not told apart yet; the ATC miss is M11.
- **One negated clock between indications.** This core can finish an instruction
  every clock, which a real MC68030 does not, and two one-clock pulses on
  consecutive clocks would read as one two-clock pulse. An event that arrives
  while one is shown waits; two that arrive in that time are shown as the longer
  of them, so a run of very short instructions shows fewer boundaries than it
  had.
- **One and a half clocks late**: the pin moves on the falling edge after the
  rising edge that registers the event, where the part's sequencer drives the pin
  itself.
- **REFILL** is one clock for every pipe flush the microcode requests. The part's
  DBcc "requests a refill before the condition is tested", and again "if the
  condition is false ... to continue with the next sequential instruction"; this
  core's DBcc refills only when it branches, once.

**How it is checked:** `bus_status_tb` drives the events and checks the widths, the
gap, the edges and the halted case; `core_status_tb` runs code and checks reset's
three clocks, one-clock boundaries, a trace's two clocks, a bus error's three, and
one REFILL per refill requested; `core_fault_tb` checks the double bus fault.

---

## The external RESET input does not reset the processor

**UM 7.8:** "the external RESET signal resets the processor and the entire system",
and "during the reset period, the entire bus three-states".

**What this design does:** `reset_n_i` is synchronised (`reset_sync_n`) and nothing
consumes it. The processor is reset by `rst_n`, which is not an MC68030 pin
(`doc/pinout.md`), and it is `rst_n` that three-states the bus. Inherited from
RD68021, which never acted on the RESET input either; it belongs with the reset
exception, in the M8–M9 rework of exception processing.

Two consequences on the bus:

- **Arbitration under `rst_n`.** "Bus arbitration requests are recognized during
  normal processing, RESET assertion, HALT assertion, and even when the
  processor has halted due to a double bus fault" (7.7). Under the RESET pin
  they are — the arbiter does not see the pin either — but `rst_n` resets the
  arbiter with everything else, and BG stays negated while it is asserted.
- **The address bus after reset.** "Once RESET negates, all control signals are
  driven to their inactive state, the data bus is in read mode, and the address
  bus is driven" (7.8, figure 7-64). With `ADDR_HIZ_BETWEEN_CYCLES` set, the
  default, the address group is released between cycles, and so also from
  `rst_n` negating to the first cycle; with it clear the address is driven
  there as the figure draws it. The default is RD68021's reading of
  specification 7 as a release at the end of every cycle (its
  `doc/divergences.md`, "The address group is released between bus cycles").
  The MC68030EC figures do not support it: the four read and write cycle
  figures mark specification 8, "Clock High to ... Address Invalid", at the end
  of a cycle, and specification 7, "... High Impedance", appears on the bus
  arbitration figure alone. So the part most likely keeps the address driven
  between cycles, as 7.8 says it does after reset. M3, which retargets the
  timing to those tables, is where to settle the default.

**How it is checked:** `bus_status_tb` and `bus_reset_tb` check the three-stating
under `rst_n` and the pins after it; `bus_reset_tb` checks that the RESET pin,
held low from outside or by the RESET instruction, leaves the bus unit running
and arbitration working.

---

## A bus error while RTE reads its frame is not a double bus fault

**UM 8.1.2:** "If a bus error occurs during the exception processing for a bus
error, address error, or reset or while the processor is loading internal state
information from the stack during the execution of an RTE instruction, a double
bus fault occurs"; and 8.1.13, Return from Exception: "once the processor
begins to load the frame to restore its internal state, the assertion of the
BERR signal causes the processor to enter the halted state with the continuous
assertion of the STATUS signal".

**What this design does:** the sequencer declares a double bus fault for a bus
error during exception processing for a bus error, address error or reset —
the cases UM20 6.1.2 lists, which is where RD68021 took them from — and not
during RTE's frame reads, which take an ordinary bus error exception. The
halted state itself, STATUS asserted continuously, is as the MC68030 has it
(7.5.4). The RTE case belongs with the M8–M9 rework of exception processing.

**How it is checked:** `core_fault_tb` checks the double bus fault that is
implemented; `bus_arb_tb` checks STATUS and arbitration in it. Nothing checks
the RTE case, because it is not implemented.
