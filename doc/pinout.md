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
which no requester makes until the caches of M10.

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
| `bg_n_o` | out | Bus grant. Never three-stated — no `_oe`. |
| `bgack_n_i` | in | Bus grant acknowledge. Three-wire arbitration (§7.7). |

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

"During the reset period, the entire bus three-states (except for non-three-statable
signals, which are driven to their inactive state)" (§7.8). The reset this design has is
`rst_n`, and every enable below is negated while it is asserted. The external RESET input
is synchronised but does not reset the core (`doc/divergences.md`). With bus relinquish and
the release at the end of each cycle that gives three groups:

| Enable | Covers | Negated when |
|---|---|---|
| `a_oe`, `fc_oe`, `siz_oe`, `rmc_oe`, `ciout_oe` | address, FC, SIZ, RMC, CIOUT | between bus cycles, on bus relinquish, and in reset |
| `d_oe` | data | except from S2 to the end of a write cycle |
| `as_oe`, `ds_oe`, `rw_oe`, `dben_oe`, `cbreq_oe` | AS, DS, R/W, DBEN, CBREQ | on bus relinquish and in reset |
| `reset_n_oe` | RESET | open drain — asserted only to pull low |

CIOUT is in the address group because specifications 6, 7 and 8 measure it with the
address, FC, SIZ and RMC; CBREQ is in the control group because specification 16 is
"Clock High to AS, DS, R/W, DBEN, CBREQ High Impedance".

`ecs_n_o`, `ocs_n_o`, `ipend_n_o`, `bg_n_o`, `refill_n_o` and `status_n_o` have no enable;
they are always driven (Table 5-2).

`ADDR_HIZ_BETWEEN_CYCLES` is a parameter, inherited from RD68021, for a board that needs
the address bus held between cycles. It changes only the first group's behaviour at the end
of a cycle, never on relinquish or reset.
