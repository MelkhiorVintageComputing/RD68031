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
