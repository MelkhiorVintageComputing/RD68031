# What limits the frequency

`make impl` reports the worst path static timing analysis finds. `make paths`
groups the worst paths into families, and checks that the routes which no
microword can take are absent from the netlist -- it fails if one comes back.

Nothing is measured yet for the MC68030: M15 does it.

*Started fresh at M0. The entries for the MC68020 design this one was forked from are
in RD68021's `doc/critical-path.md`; they still describe the parts of `rtl/` not yet
reworked, and are not repeated here.*

---
