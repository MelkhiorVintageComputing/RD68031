# Making it smaller, and making it faster

Each row is a before-and-after on the same tree with one change, from `make impl`
(Artix-7) and `make quartus` (Cyclone V).

| change | kept | what it was worth |
|---|:--:|---|
| M15's starting point: the MC68030 as M14 left it, `COPROCESSOR = 0`, both caches at 64 | -- | Artix-7 **14,835 LUTs**, 5,185 FFs, 6 RAMB36, 4 DSP, **20.87 MHz**; Cyclone V **13,808 ALMs**, 9,827 registers, 22 M10K, 12 DSP, **21.51 MHz**; MAX 10 **34,286 LEs**, 28 M9K, **16.97 MHz**. RD68021 at the same constraint: 8,216 LUTs, 33.68 MHz (`doc/implementation.md`) |
| `COPROCESSOR = 1` | measurement | Artix-7 14,738 LUTs, 21.12 MHz: no difference beyond the router's |
| both caches built out, `ICACHE_ENTRIES = 0`, `DCACHE_ENTRIES = 0` | measurement | Artix-7 11,740 LUTs (−3,095), 3,907 FFs (−1,278), no LUTRAM, **22.84 MHz** (+2.0): the limiting family is unchanged, the ATC's history behind the bus unit's operand continuation |
| the ATC's reset loop indexed by the loop's own variable, not a module-scope `int` | yes | Quartus's `Warning (10240)` latch for the index is gone; no netlist change elsewhere |

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/size-and-speed.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---
