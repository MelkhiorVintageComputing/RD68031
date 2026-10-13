# What limits the frequency

`make impl` reports the worst path static timing analysis finds. `make paths`
groups the worst paths into families, and checks that the routes which no
microword can take are absent from the netlist -- it fails if one comes back.

## M15 phase B: the operand's end, the next request, the data cache

`make impl` at 33.333 ns, `COPROCESSOR = 0`, both caches at 64: **29.61 MHz**
(33.78 ns), from 20.87; Cyclone V **31.82 MHz** from 21.51; MAX 10 **25.71 MHz** from 16.97, limited there by the full-period family third in the table below.
F2, F1 and F4 (`doc/size-and-speed.md`, `doc/implementation.md`) took the
ATC out of the half clock at the end of S5 and the RESET pin's clear off the
falling-edge registers. What limits it now, on both toolchains, is half a
period, from the falling-edge bus state `st_n` to the rising edge:

```
st_n ─▶ the port, the bytes moved, op_finishing, req_last    ~ 7 ns
     ─▶ u_seq: req_valid drops (the operand is done)
     ─▶ u_biu: take_req, the decision to start a cycle      ~ 12
     ─▶ dc_wr_take / dc_wb_go ─▶ the data cache's RAM write  16.9   of 16.67
```

20 levels, 82 % routing. It is the handshake that makes back-to-back operands
possible: on the edge that ends one operand's S5 the sequencer's next request
is taken, and that decision gates the data cache's write of a write being
taken and of a write's second page -- and, a little behind (33.67 ns), the
ATC's history bits, through `l_take`. The ATC's comparison itself is no longer
on any half-period path: its address comes from registers and requesters, and
its verdict is ready long before the decision needs it. The Cyclone V's worst
paths are the same family, into the data cache's data, which Quartus builds
from registers.

What follows it (`make paths`, 3,000 paths):

| period | MHz | family |
|--:|--:|---|
| 33.23 | 30.09 | `st_n` → the data cache's valid bits (half), the same family |
| 30.50 | 32.79 | `early_q` → the fetch unit's request registers (half): the early retire, F5, not approved |
| 30.45 | 32.84 | `u_seq/u_urom/rom_q` → `u_biu/pk_*` (full): the microcode store through the effective address, the data cache's lookup and the ATC |
| 28.93 | 34.56 | `st_n` → `op_data`, `rdata_q`, `op_addr` (half): the operand engine's own update |

The `crst_q` family (36.28 ns at phase A) is not among the 3,000; the routes
no microword can take are still absent.

## M15: the operand continuation through the ATC

`make impl` at 33.333 ns, `COPROCESSOR = 0`, both caches at 64: **20.87 MHz**
(47.91 ns). The limiting path is half a period, launched on the falling edge by
the bus unit's beat counter `beat_q` and captured on the rising edge:

```
beat_q ─▶ port size, bytes moved (bt_n)               3.1 ns
       ─▶ op_addr + xfer_done  (the residual address)  6.9
       ─▶ ent_done, cyc_fill ─▶ next_addr (l1_addr)   12.0
       ─▶ u_mmu/u_xl1: 22-way tag compare, hitv, kind  17.6
       ─▶ u_biu: op_active (fan-out 128)               21.2
       ─▶ u_mmu: l_take, h_after ─▶ h_q (ATC history)  24.9   of 16.67
```

38 levels, 70 % routing. On the edge that ends S5 of a cycle that did not
finish its operand (a narrow port, a misaligned operand) or that leaves a data
cache entry to complete, the bus unit computes the next cycle's address,
asks the ATC whether it may run, decides, and starts it -- all in the half
clock before the next rising edge. Every one of the 400 worst paths starts at
`beat_q`; the endpoints after the ATC's history are the data cache's RAM write
enables (46.82 ns), its valid bits (46.28) and the bus unit's own operand
registers (45.55). Quartus's worst path on the Cyclone V (21.51 MHz) and the
MAX 10 (16.97 MHz) is the same chain. With the caches built out it is still
the limit, at 22.84 MHz.

What follows it, with the family above out of the way:

| period | MHz | family |
|--:|--:|---|
| 36.28 | 27.56 | `crst_q` → the bus unit's registers (half): the RESET pin's synchronous clear, one LUT, its fan-out |
| 35.46 | 28.20 | `early_q` → the fetch unit's request (half): the early retire, RD68021's Phase 4 path |
| 28.92 | 34.58 | `early_q` → the microcode store's address (half) |
| 28.51 | 35.08 | `rom_q` → `u_ifu/fill_q` (full) |
| 27.83 | 35.94 | `xw_q` → the data registers (full) |

The sequencer's paths are where RD68021 left them. `doc/implementation.md`
has the estimates for taking each family out.

`make paths` found the shifter-to-micro-address route present at M15, and it
was the check that was wrong: its endpoints included `irq_taking_q`, whose D
input the RTE put-back (`doc/checkpoint.md` rule 9) feeds from the result bus.
`scripts/paths.tcl` drops that endpoint and says why; the three routes are
absent.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/critical-path.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---
