# RD68031 pinout

Derived from **Table 5-1, Signal Index**, **Table 5-2, Signal Summary** and §5.2–5.12 of
`Inputs/doc/MC68030_Doc_More_Readable/MC68030UM_split/07-section-05-signal-description.pdf`.
This design implements the MC68030, not the MC68EC030, so the MMU signals are present
and the address bus is 32 bits.

**Status: M1 has moved `rtl/rd68031_top.sv` to this list.** Every pin below exists on the
top level and is driven or sampled as described; `doc/bus-timing-compliance.md` has the
behaviour state by state. The rows marked *new* are the MC68030's additions, and
*changed* marks a pin that behaves differently from the MC68020's. MMUDIS is synchronised
and goes to a sink until the MMU of M11; CIOUT is driven from the request, negated by
every requester until M11; CBREQ is asserted only for a request that allows a line fill,
which no requester makes until the caches of M10. M2 settled the output-enable groups
against §7 and Table 5-2 (below).

The original has three-state and bidirectional pins. This core has none: every such pin is
split into an input `_i`, an output `_o` and an output-enable `_oe`. An external wrapper
recombines them:

```systemverilog
assign pad = core_oe ? core_o : 1'bz;   // three-state pin
assign core_i = pad;
assign pad = core_oe ? 1'b0 : 1'bz;     // open-drain pin (RESET)
```

`_oe` is **active high — asserted means the core is driving**. Active-low signals keep the
`_n` suffix and are active-low *on the pin*, so `as_n_o == 0` means AS asserted.

## Port list

### Clock (§5.12)

| Port | Dir | Notes |
|---|---|---|
| `clk` | in | Free-running. Both edges are used: one bus state S0–S5 per half period, so an asynchronous bus cycle with no wait states is three clocks, and a synchronous one two. |
| `rst_n` | in | **Not an MC68030 pin.** Asynchronous hardware reset for simulation and FPGA bring-up, so that every register has a defined value without power-on initialisation, after which the processor runs reset exception processing. The architectural reset is `reset_n_i` below; `rst_n` resets everything it does and more -- the registers UM 8.1.1 leaves alone, and the arbiter (`doc/divergences.md`). |

### Function codes (§5.2)

| Port | Dir | Notes |
|---|---|---|
| `fc_o[2:0]` | out | Table 4-1's eight address spaces. Valid while AS is asserted. `MOVES` drives them from SFC/DFC, so all eight encodings — including the three reserved ones — can appear. |
| `fc_oe` | out | |

### Address bus (§5.3)

| Port | Dir | Notes |
|---|---|---|
| `a_o[31:0]` | out | A1 and A0 are real pins: byte selection is by `A1`, `A0`, `SIZ1`, `SIZ0` and the port size, not by separate data strobes. In CPU space the address is synthesised — §4.2, §7.4. |
| `a_oe` | out | |

### Data bus (§5.4)

| Port | Dir | Notes |
|---|---|---|
| `d_i[31:0]` | in | Latched on the falling edge entering S5 of an asynchronous cycle, or on the falling edge after the rising edge STERM is recognised on (§7.1.4: "on the last falling edge of the clock for that bus cycle"). |
| `d_o[31:0]` | out | **All 32 bits are driven on every write**, duplicated across the lanes, because at the start of a write the port size is not yet known (§7.2.1). |
| `d_oe` | out | |

### Transfer size (§5.5)

| Port | Dir | Notes |
|---|---|---|
| `siz_o[1:0]` | out | The number of bytes **remaining** to be transferred, not the size of the operand — so they change as a multi-cycle transfer proceeds (§7.2.1). |
| `siz_oe` | out | |

### Bus control (§5.6)

| Port | Dir | Notes |
|---|---|---|
| `ecs_n_o` | out | External cycle start: one half clock at the beginning of **every** bus cycle. Never three-stated. |
| `ocs_n_o` | out | Operand cycle start: identical, but only for the **first** bus cycle of an operand transfer — so it is driven from the request handshake, not from the cycle. Never three-stated. |
| `rw_o`, `rw_oe` | out | High = read, low = write. |
| `rmc_n_o`, `rmc_oe` | out | Asserted across every bus cycle of a read-modify-write, and inhibits `BG` absolutely while it is up. |
| `as_n_o`, `as_oe` | out | Valid address, FC, SIZ and R/W (§7.1.3). |
| `ds_n_o`, `ds_oe` | out | One strobe. *Changed:* **not asserted in a two-clock synchronous write** (§5.6.6). |
| `dben_n_o`, `dben_oe` | out | Data buffer enable, active low (Table 5-2); three-state per Table 5-2 and specification 16. Its timing may preclude its use with two-clock synchronous cycles (§5.6.7): it is asserted for half a clock on a two-clock read. *Changed:* RD68021 drove it active high (`doc/bugs-found.md`). |
| `dsack_n_i[1:0]` | in | `[1]` is DSACK1. Terminates an **asynchronous** cycle on the falling edge where **either** is first recognised (§7.3.1 state 3; specifications 47A/47B), and gives the port size **one clock later**, on the falling edge that latches the data: MC68030EC specification 31A lets the second DSACK trail the first by up to 10 ns at 20 MHz and 3 ns at 50 MHz, with only one of them meeting 47A (footnote 3). Both bits are captured by one flop pair on that edge. *Changed at M3:* RD68021 took the port size on the recognising edge, which read a 32-bit port with a trailing DSACK1 as an 8-bit one (`doc/bugs-found.md`). |
| `sterm_n_i` | in | *New.* Synchronous termination (§5.6.9): a 32-bit port, with read data latched on the next falling edge. A cycle terminated by STERM takes two clocks with no wait states. Sampled on the **rising** edge, against specifications 60/61 — where DSACK is sampled on the falling edge, against 47A/47B. Neither goes through a synchroniser. |

### Cache control (§5.7) — *new*

| Port | Dir | Notes |
|---|---|---|
| `ciin_n_i` | in | Cache inhibit in: the data of this cycle is not loaded into either cache. Interpreted cycle by cycle, ignored on writes (§5.7.1). |
| `ciout_n_o`, `ciout_oe` | out | Cache inhibit out: the CI bit of the ATC entry or of the matching TTx register, for external caches (§5.7.2). |
| `cbreq_n_o`, `cbreq_oe` | out | Cache burst request: this cycle may be extended into a burst that fills a cache line (§5.7.3, §7.3.7). |
| `cback_n_i` | in | Cache burst acknowledge: the device can supply at least one more longword in burst mode (§5.7.4). |

### Interrupt control (§5.8)

| Port | Dir | Notes |
|---|---|---|
| `ipl_n_i[2:0]` | in | Encoded level, active low; `ipl_n_i[2]` is the most significant. Synchronised internally. |
| `ipend_n_o` | out | An interrupt above the mask has been recognised internally. Never three-stated. A rising-edge register (MC68030EC specification 6, "Clock High to ... IPEND ... Valid"). *Changed at M3:* it was a combinational compare that moved on both edges (`doc/bugs-found.md`). |
| `avec_n_i` | in | Requests an autovector during an interrupt acknowledge cycle; ignored in every other cycle (§7.4.1.2). |

### Bus arbitration (§5.9)

| Port | Dir | Notes |
|---|---|---|
| `br_n_i` | in | Bus request. |
| `bg_n_o` | out | Bus grant. Never three-stated — no `_oe`. The seven-state arbiter of figure 7-61. |
| `bgack_n_i` | in | Bus grant acknowledge. Three-wire arbitration (§7.7), or single-wire: BGACK alone releases the bus (§7.7.4). |

### Bus exception control (§5.10)

| Port | Dir | Notes |
|---|---|---|
| `berr_n_i` | in | Bus error. With HALT, selects retry rather than exception. Sampled on falling edges only — the termination samples, the late window (specification 27A), and, at M3, the end of a retry too (`doc/bugs-found.md`). |
| `reset_n_i` | in | External reset input: resets the processor (UM 7.8, 8.1.1). Unlike the MC68000 and MC68010 it does **not** need HALT asserted with it. The processor's own RESET instruction pulse, which comes back on it through the wired pin, is ignored, as is a RESET from outside that ends within four clocks of that pulse (UM 7.8 asks eight to be sure of a reset). |
| `reset_n_o`, `reset_n_oe` | out | Open drain. `reset_n_o` is constant 0; the `RESET` instruction asserts `reset_n_oe` for **512 clocks** (§7.8) to reset peripherals without disturbing the core. |
| `halt_n_i` | in | Suspends bus activity at the end of the current cycle; with BERR, requests a retry. *Changed:* **input only** (Table 5-2). The MC68020 drove HALT on a double bus fault; the MC68030 shows the halted state on STATUS instead (§5.11.4). |

### Emulator support (§5.11)

| Port | Dir | Notes |
|---|---|---|
| `cdis_n_i` | in | Dynamically disables **both** on-chip caches, whatever CACR says. It does not flush them: the entries come back when CDIS is negated (§5.11.1). Synchronised internally. |
| `mmudis_n_i` | in | *New.* Dynamically disables address translation. It does not flush the ATC (§5.11.2). Synchronised internally. |
| `refill_n_o` | out | *New.* The instruction pipeline is starting to refill (§5.11.3, §12). Never three-stated. |
| `status_n_o` | out | *New.* Microsequencer status: the number of clocks it is asserted for distinguishes an instruction boundary, a pending exception and the halted state (§5.11.4, §12). Never three-stated. |

## Output-enable domains

Settled at M2 from Table 5-2's "Three-State" column, the MC68030EC
specifications that measure each release, and UM 7.5.3, 7.7.4 and 7.8.

Table 5-2 lists as three-statable: FC0–FC2, A0–A31, D0–D31, SIZ0/SIZ1, R/W, RMC,
AS, DS, DBEN, CIOUT and CBREQ. Not three-statable: OCS, ECS, IPEND, BG, RESET,
REFILL and STATUS. The three-statable ones fall in three groups by when they are
released:

| Enable | Covers | Negated when | Source |
|---|---|---|---|
| `a_oe`, `fc_oe`, `siz_oe`, `ciout_oe` | address, FC, SIZ, CIOUT | between bus cycles (with `ADDR_HIZ_BETWEEN_CYCLES`, the default; `doc/divergences.md`), on bus relinquish, in reset | specifications 6, 7, 8: "Clock High to Function Code, Size, RMC, CIOUT, Address, Data High Impedance" |
| `rmc_oe` | RMC | as the address group, except that it stays driven for the whole of a locked run, gaps included | specification 7; UM 7.1.1 |
| `d_oe` | data | except from S2 to the end of a write cycle; while halted; on relinquish; in reset | 7.3.2, 7.5.3, specification 7 |
| `as_oe`, `ds_oe`, `rw_oe`, `dben_oe`, `cbreq_oe` | AS, DS, R/W, DBEN, CBREQ | on bus relinquish and in reset only | specification 16: "Clock High to AS, DS, R/W, DBEN, CBREQ High Impedance" |
| `reset_n_oe` | RESET | open drain — asserted only to pull low | Table 5-2, 7.8 |

So **CIOUT is in the address group** — specifications 6, 7, 8, 11 and 13 all
measure it with the address, FC, SIZ and RMC — and **CBREQ is in the control
group**, with AS and DS: specification 16 releases it, and specifications 9
and 12 drive it on the edges AS and DS move on. M1 had placed them so
provisionally; §7 and the specifications agree.

**Relinquish** is the arbiter's T (UM 7.7.4, figure 7-61): every group above is
released "after the next rising edge following the negation of AS and RMC",
and driven again "immediately following a state change, when bus mastership is
returned". RMC does not hold the bus while BGACK alone asserts T — single-wire
arbitration "applies to all bus cycles of a read-modify-write sequence" — nor
while the first read of a read-modify-write waits to be retried
(`doc/manual-contradictions.md`, 6 and 7).

**Halted** (UM 7.5.3): the data bus is released, the control group is driven
inactive — "not high-impedance state" — and the address group stays driven
with the halted cycle's values, released on a grant and driven again with the
same values when the bus comes back.

**Reset** (UM 7.8): "during the reset period, the entire bus three-states
(except for non-three-statable signals, which are driven to their inactive
state)". Both resets do it -- `rst_n`, and the RESET pin from outside -- and
every enable above is negated while either is asserted; ECS, OCS, REFILL and
STATUS are driven negated, and IPEND by the sequencer. BG is the arbiter's,
which runs under the RESET pin (UM 7.7) and is held negated under `rst_n`.
"Once RESET negates, all control signals are driven to their inactive state,
the data bus is in read mode, and the address bus is driven": the control group
is driven at once, R/W high; the address group follows
`ADDR_HIZ_BETWEEN_CYCLES` (`doc/divergences.md`).

`ecs_n_o`, `ocs_n_o`, `ipend_n_o`, `bg_n_o`, `refill_n_o` and `status_n_o` have
no enable; they are always driven (Table 5-2).

`ADDR_HIZ_BETWEEN_CYCLES` is a parameter of `rd68031_top`, inherited from
RD68021, set by default: it releases the address group whenever the bus unit
goes idle at the end of a cycle. Cleared, the group stays driven between
cycles, which is what the MC68030EC read and write figures draw. The default
is the user's decision, kept after M2 raised the question; a board that needs
the address held between cycles clears it (`doc/divergences.md`, "The address
group is released between bus cycles"). It changes only the address group's
behaviour between cycles and after reset, never on relinquish or in reset.

`bus_reset_tb` checks every group in reset and after it, `bus_arb_tb` on
relinquish, single-wire arbitration and while halted, and `bus_error_tb` while
halted and while waiting to retry.

## Where each input is sampled

Settled at M3 against the MC68030EC data sheet; specification numbers are its
own. Every row is measured: `rd68031_timing_tb` moves the input half a
nanosecond before and half a nanosecond after the edge named, and the core
behaves differently the two times (`doc/ac-timing.md`).

| Input | Edge | How | Specifications |
|---|---|---|---|
| `dsack_n_i` | falling: entering S3 and each wait to terminate; entering S5 for the port size | directly, no synchroniser (§7.3.1 state 3) | 47A, 47B, 28A; 31A, the skew |
| `berr_n_i`, `halt_n_i` | falling: with DSACK; the late window entering S5, or after STERM; each burst beat; each clock of a retry | directly | 47A, 47B; 27A for the late window; 28A |
| `avec_n_i` | falling, with DSACK | directly | 47A, 47B, 28A |
| `sterm_n_i` | rising: entering S2, each wait, each burst beat | directly (§7.1, a synchronous input) | 60, 61 |
| `cback_n_i` | rising, with STERM | directly | 60, 61 |
| `ciin_n_i` | rising, with STERM; or entering S4 of a DSACK cycle (§7.2.8) | directly | 60, 61 |
| `d_i` | falling: entering S5, or after STERM | directly | 27, 30; 29 for the asynchronous hold |
| `ipl_n_i`, `br_n_i`, `bgack_n_i`, `halt_n_i`, `cdis_n_i`, `mmudis_n_i`, `reset_n_i` | falling | two falling-edge ranks, `rd68031_sync` (§7.1, figure 7-1) | 47A, 47B |

HALT appears twice: the termination samples read the pin (Table 7-8 case 2),
and the halt itself goes through the synchroniser (§7.5.3).
