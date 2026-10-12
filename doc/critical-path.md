# What limits the frequency

`make impl` reports the worst path static timing analysis finds. `make paths`
groups the worst paths into families, and checks that the routes which no
microword can take are absent from the netlist -- it fails if one comes back.

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
