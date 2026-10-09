# Implementation

What the design comes to on real FPGA fabric, measured, and how. The targets:

```sh
make impl      # Vivado 2025.2 place and route, xc7a100tcsg324-1, out of context
make paths     # what limits the clock, from the checkpoint make impl leaves
make quartus   # Quartus Prime Lite fit and timing, Cyclone V 5CSEMA5F31C6
               # (AFAMILY='"MAX 10"' APART=10M50DAF484C6GES for a MAX 10)
make audit     # every register's reset, and the named exceptions
```

Nothing is measured yet for the MC68030: M15 does it.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/implementation.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---

## The caches (M10)

The caches add, in storage: the instruction cache's 64 x 32 data RAM, sixteen
25-bit tags and 64 valid bits; the data cache's sixteen 16 x 8 RAMs (four banks
of four byte lanes), sixteen 27-bit tags, 64 valid bits, a 69-bit register for a
long word being gathered from a narrow port and an 81-bit one for the write
being applied. The RAMs are written on a rising edge and read without one, which
on the FPGAs this targets is distributed RAM; `make audit` counts the tags,
valid bits and the rest as reset flip-flops (4300 in all at M10, at the
defaults). Both caches can be built out -- `ICACHE_ENTRIES=0`,
`DCACHE_ENTRIES=0` on `rd68031_top` -- for an FPGA that wants the area back;
the core stays software compatible (`doc/caches.md`).

What either costs in LUTs, and what the data cache's lookup -- combinational
from the sequencer's request, through the RAM read and the tag compare, to the
bus unit's decision to start a cycle -- does to the clock, is measured at M15
with the rest. The vendor scripts in `scripts/` still pass only
`ICACHE_ENTRIES`; the data cache is built at its default there.
