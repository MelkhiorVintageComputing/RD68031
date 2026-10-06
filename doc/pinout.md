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
| `rst_n` | in | **Not an MC68030 pin.** Asynchronous hardware reset for simulation and FPGA bring-up, so that every register has a defined value without power-on initialisation. The architectural reset is `reset_n_i` below. |

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
| `dsack_n_i[1:0]` | in | `[1]` is DSACK1. Terminates an **asynchronous** cycle and gives the port size. **Both bits must be captured by the same flop pair on the same edge** and decoded afterwards, so that skew between them cannot make a 32-bit port look like an 8-bit one for a moment (inherited from RD68021; the MC68030 limit is to be checked against the MC68030EC skew specification at M3). |
| `sterm_n_i` | in | *New.* Synchronous termination (§5.6.9): a 32-bit port, with read data latched on the next falling edge. A cycle terminated by STERM takes two clocks with no wait states. Sampled on the rising edge; it must meet setup and hold, unlike DSACK, which is synchronised. |

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
| `ipend_n_o` | out | An interrupt above the mask has been recognised internally. Never three-stated. |
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
| `berr_n_i` | in | Bus error. With HALT, selects retry rather than exception. |
| `reset_n_i` | in | External reset input. Unlike the MC68000 and MC68010 it does **not** need HALT asserted with it. |
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
| `a_oe`, `fc_oe`, `siz_oe`, `ciout_oe` | address, FC, SIZ, CIOUT | between bus cycles (with `ADDR_HIZ_BETWEEN_CYCLES`), on bus relinquish, in reset | specifications 6, 7, 8: "Clock High to Function Code, Size, RMC, CIOUT, Address, Data High Impedance" |
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
state)". The reset this design has is `rst_n`, and every enable above is
negated while it is asserted; ECS, OCS, BG, REFILL and STATUS are driven
negated, and IPEND by the sequencer. "Once RESET negates, all control signals
are driven to their inactive state, the data bus is in read mode, and the
address bus is driven": the control group is driven at once, R/W high; the
address group follows `ADDR_HIZ_BETWEEN_CYCLES` (`doc/divergences.md`). The
external RESET input is synchronised but does not reset the core
(`doc/divergences.md`), and does not three-state the bus either: it is `rst_n`
that stands for it.

`ecs_n_o`, `ocs_n_o`, `ipend_n_o`, `bg_n_o`, `refill_n_o` and `status_n_o` have
no enable; they are always driven (Table 5-2).

`ADDR_HIZ_BETWEEN_CYCLES` is a parameter, inherited from RD68021, set by
default: it releases the address group at the end of every cycle. Cleared, the
group stays driven between cycles, which is what the MC68030EC read and write
figures draw (`doc/divergences.md`). It changes only the first two groups'
behaviour between cycles, never on relinquish or reset.

`bus_reset_tb` checks every group in reset and after it, `bus_arb_tb` on
relinquish, single-wire arbitration and while halted, and `bus_error_tb` while
halted and while waiting to retry.
