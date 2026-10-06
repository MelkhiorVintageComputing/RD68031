# Where this core takes a different number of clocks

`CLAUDE.md`: instruction cycle timings need not match a real MC68030, but **every
divergence must be measured, reported and justified**. Bus *timing* is a
different matter and is not negotiable -- that is `doc/bus-timing-compliance.md`
and `doc/ac-timing.md`.

`make cycles` measures instructions against UM section 11, and every row is a
regression check: the count this design takes is frozen in `tools/cycles.py`,
and a change to it in either direction fails the target until someone looks at
it and writes the new number down. Until M15 retargets it, `tools/cycles.py`
still holds RD68021's MC68020 rows.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/timing-divergences.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---
