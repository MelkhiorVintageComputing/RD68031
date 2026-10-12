# rd-virt: the deterministic `virt` machine, and the lockstep

M13's platform (doc/plan.md, Layer 3). A C++ machine that mirrors the Linux and QEMU
m68k `virt` board, with a CPU socket that takes either the RTL (under Verilator) or the
UAE030 oracle, and a lockstep driver that runs both, each on its own copy of the
machine, and compares them at every instruction boundary. Nothing here is an oracle; it
is the bench the RTL and the oracle run Linux on.

| File | What |
|---|---|
| `sim/virt/machine.{h,cpp}` | RAM, the devices, the bootinfo, the ELF loader, the clock, the bus record |
| `sim/virt/cpu_if.h` | the socket: `reset`, `run_until_retire`, `set_ipl`, `regs()`, `retired()`, `last_iack`, `inject_interrupt` |
| `sim/virt/cpu_rtl.{h,cpp}` | `rd68031_top` under Verilator and the pin-level bus agent |
| `sim/virt/public.vlt` | the `public_flat_rd` signals the RTL socket reads (registers, and where a boundary is) |
| `sim/virt/cpu_uae.{h,cpp}` | the UAE030 core (`tools/cosim/uae030`) as a coroutine behind the socket |
| `sim/virt/rdvirt.cpp` | the solo runs, the lockstep, the console script, the options |
| `sim/virt/build.sh` | `uae`: the oracle-only machine; `rtl`: the Verilator build with both |
| `sim/virt/linux/` | the guest: `rd-virt.config`, `init`, `cpio.list`, `build.sh`, `commands.script` |
| `sim/programs/virt_*.S`, `virt.inc`, `virt.ld` | the bare-metal programs |

The parts linked with UAE030 (`cpu_uae.*`, `rdvirt.cpp`) are GPL-2.0-or-later, like
everything else that links it (doc/oracles.md); the machine and the RTL socket are
CERN-OHL-S-2.0.

## The machine

The map is the one doc/oracles.md recorded at M0, from `arch/m68k/virt/` and QEMU's
`hw/m68k/virt.c`:

| Address | Device | Linux IRQ (PIC, input) |
|---|---|---|
| `$00000000` | RAM, 64 MB by default (`--ram`) | |
| `$FF000000` + i·`$1000` | goldfish-pic i+1 of 6, driving level i+1, autovectored | |
| `$FF006000` | goldfish-rtc, the scheduler's timer | 168 (6, 0) |
| `$FF007000` | goldfish-rtc, the wall clock | 169 (6, 1) |
| `$FF008000` | goldfish-tty, version 1 (physical DMA pointers) | 39 (1, 31) |
| `$FF009000` | virt-ctrl: CMD 1 reset, 2 halt (power off), 3 panic | 8 (1, 0) |
| `$FF010000` + n·`$200` | 128 virtio-mmio transports, legacy, every one empty (device ID 0) | 40 + n |

Everything else is a hole and answers with a bus error. The initramfs flow needs no disk,
so virtio-mmio-blk is the empty transport the plan allowed; its registers are
little-endian, as the virtio-mmio specification has them (the driver's `readl` swaps).

**Loading.** The kernel's ELF goes in physical = virtual; the reset vectors at 0 (the
ELF header's page, which nothing uses) give the entry and a harmless SSP, since head.S
loads its own; the bootinfo goes at `(_end + 1) & ~1` with `MACHTYPE` 14, `MMUTYPE` and
`CPUTYPE` 2, **`FPUTYPE` 0**, `MEMCHUNK`, the `VIRT_*` records, the command line, a
fixed `RNG_SEED`, and `RAMDISK` with the initrd page-aligned at the top of RAM.
The M0 note "FPUTYPE left out when there is no FPU" (QEMU's behaviour) is wrong for an
030 kernel: head.S's `get_bi_record` leaves its pointer on the terminator's size field
when a record is missing, `m68k_fputype` reads as `$0004xxxx`, and `resume()` executes
FSAVE -- an F-line exception the kernel calls a bad trap. With the record at 0 the FPU
emulation is used.

**Time.** The machine is told the time at every boundary: steps × `--ns` (20 ns, so
50 M steps per virtual second) plus whatever was skipped while STOP held the processor,
when the clock jumps to the next armed alarm. Both goldfish-rtc count
`epoch + time` (the epoch is 2027-01-01). Nothing reads the host's clock, so a run is
the same from one execution to the next, and the two sides of a lockstep see the same
time at the same instruction.

**Interrupts.** The highest PIC with something pending and enabled sets the level. The
RTL socket re-reads it after every device write as well as at every boundary, as a
board's wiring would; the oracle socket takes it at boundaries.

## The RTL socket

`rd68031_top` with `COPROCESSOR=0` (no FPU: every coprocessor opcode takes the F-line
exception the kernel's FPU emulation handles) and both caches, under Verilator,
single-threaded. A **boundary** is the core harness's: a microword that decodes retires
without a fault (`retire && at_decode && !fault_now` in `rd68031_seq`), sampled after
the falling edge; the registers are read after the next rising edge. An interrupt is
therefore two steps: the boundary it is taken at, and the boundary at the handler's
first instruction.

**The bus agent** answers as `sim/models/rd68031_slave.sv` does, on a 32-bit port:

| | |
|---|---|
| RAM | asynchronous by default: DSACK1/0 on a rising edge after `--ram-waits` rising edges of AS; `--ram-sync`: STERM decoded from the address; `--burst`: CBACK while the line has a long word left, the line's long words in turn, wrapping (UM 7.3.7) |
| devices | asynchronous, `--io-waits` (1), CIIN on every read, each register read once per bus cycle |
| CPU space | an interrupt acknowledge is answered with AVEC; anything else (a breakpoint acknowledge, a coprocessor) with BERR |
| holes | BERR with AS |

`--cdis` holds CDIS asserted (both caches off, UM 5.11). Writes are latched as the slave
model latches them. Every transfer goes into the bus record (the last 4,096) and every
write into the step's write list.

## The UAE030 socket

The core of `tools/cosim/uae030`, configured as a real 030 (MMU and data cache on;
`--no-dcache` turns its data cache off). The library enters the core once and only comes
back through the instruction hook, so the core runs on its own stack as a coroutine:
`run_until_retire` switches to it and the hook switches back. The library gained, for
M13: devices behind the RAM (`uae030_set_ext_bus`), CIIN on the device window
(`uae030_set_cachable`), taking an interrupt at the hook's boundary
(`uae030_interrupt`), STOP's state, the operation word about to run, and the short-frame
switch below (`tools/cosim/uae030/uae030.h`).

STOP: the oracle keeps its program counter on the STOP and executes it again at every
boundary until an interrupt moves it on; the socket reports the processor's boundary
(after the STOP) once and hides the repeats.

## The lockstep

The RTL leads. After each of its steps:

1. if the RTL acknowledged an interrupt (level L) during the step, the oracle is told to
   take it at the boundary it is at;
2. the oracle takes the same step;
3. every register is compared: D0-D7, A0-A7, USP, ISP, MSP, SR, PC, VBR, SFC, DFC, CACR,
   CAAR, and TC, CRP, SRP, TT0, TT1, MMUSR under the bits UM 9.7 gives each (the oracle
   keeps every bit written; doc/oracles.md);
4. the physical writes of both are cut into bytes and matched address by address, in
   order: a byte may lag up to `--window` steps (64) on either side -- a posted write
   still in flight at the boundary lands on the RTL's bus up to a few register-only
   instructions later -- and a value one side writes and overwrites but the other never
   writes is dropped (a table search updating U and then M, where the other sets both
   at once), as is a write on one side only of the value both already agree the byte
   holds (the oracle re-running an instruction's writes after a fault), once the other
   side has had the whole window to write it too. At the end of a lockstep the two
   machines' RAM is compared byte for byte, and every difference outside a bus fault
   frame is listed. A bus fault frame's bytes are not compared, since its internal words are
   the implementation's (UM 8.4.6);
5. both machines are told the new time; the console script may type.

Both sides answer every hole with a bus error from their own machine, so a bus error
needs no replay; interrupts are the only thing the oracle takes from the RTL.

At the first boundary (the end of the reset) the oracle takes the RTL's values of the
registers a reset leaves undefined (USP, MSP, CAAR, SFC, DFC, the MMU's but for the E
bits; UM 8.1, 9.2.2).

**On a divergence** the run stops (`--maxdiv N` goes on after N-1), and the dump
(`--dump`, `make virt-linux` writes `build/virt/lockstep-on.div, or -off`) holds both states and the
last 4,096 transfers of each bus. `--dump-at N` writes the same at step N and stops;
`--trace-from N` prints every boundary from step N; `RDVIRT_WATCH=<hex address>` prints
every write either side makes to that byte.

**Accepted differences** (doc/m13-mismatches.md has each, with its decision):

| | Default | What |
|---|---|---|
| the oracle restarts an instruction a bus fault interrupted | on | after an RTE of a bus fault frame the oracle shows one boundary more (the faulted instruction, again); it is taken and compared past (doc/m11-mismatches.md b-list) |
| a posted write's fault after the next boundary | on | the RTL may reach the boundary after the writing instruction before the fault is taken (doc/checkpoint.md rule 9); the RTL's next step is taken and compared |
| copies of the SSW's internal-use bits | on (`--strict-ssw` turns it off) | for each long bus fault frame, the core's SSW and the oracle's (after the alignment below, they differ only in bits 11-9, UM figure 8-9; the oracle keeps its own state in bit 9 and needs it at its RTE) are recorded, and until the RTE that pops that frame -- the handler may sleep and other tasks run meanwhile -- a register whose low word holds the oracle's where the core's holds the core's is accepted, and the oracle's word and long-word writes of it are compared as the core's (doc/m11-mismatches.md c6) |
| the stage fault bits and stage B address of a fetch fault | on (`--strict-frames` turns it off) | when both stack a long frame, the core's SSW (but for bits 11-9) and stage B address are written into the oracle's frame through its own write path (doc/m11-mismatches.md c8, b10): the kernel finds an instruction fault's address from them |
| An of an instruction a fault interrupted | on (`--strict-an` turns it off) | the oracle has already applied (An)+ / -(An) when a bus fault interrupts the instruction, the core has not; the pairs recorded at the fault are accepted until the RTE that pops that fault's frame, in the registers and in the long words the handler saves (doc/m13-mismatches.md c7) |
| the long bus fault frame for every fault | on (`--uae-short-frames` turns it off) | the core stacks `$B` for every bus fault (doc/checkpoint.md); the oracle is switched to do the same, so the two stacks stay in step through the handler (doc/m11-mismatches.md c4) |

## Options

`rdvirt --help` lists them. The ones a run usually wants:

| | |
|---|---|
| `--cpu uae\|rtl\|lockstep` | which processor, or both |
| `--kernel F --initrd F --cmdline S` / `--bare ELF` | what to run |
| `--script F`, `--expect S` | the console script (`expect <text>` / `send <text>`), and what the console must show for a pass |
| `--ram-sync`, `--burst`, `--ram-waits N`, `--io-waits N`, `--cdis` | the RTL's bus and caches |
| `--no-dcache` | the oracle without its data cache |
| `--max-steps N`, `--progress N` | limits and reporting |

A run passes when the machine powered off through virt-ctrl (not a panic), the console
showed every `--expect` string and the script finished -- and, in lockstep, there was no
divergence and the two consoles are the same.

## The guest

`sim/virt/linux/build.sh` fetches the sources `Inputs/sw/MANIFEST` pins (or copies them
from the M0 spike's download directory), checks their sha256, builds the kernel with
`rd-virt.config` over `allnoconfig`, a static BusyBox for the 030, and the initramfs with
every timestamp at 0. `/init` prints the machine's view of itself; with `rdvirt.shell` on
the command line it then starts a shell on the console, which `commands.script` drives:
arithmetic, `uname`, `/proc/cpuinfo`, an `md5sum` of `seq 1 200`, a file written and
read back, the RTC, a pipeline, and `poweroff -f`. Typing goes through the tty's receive
interrupt and its DMA into RAM, which the boot alone never exercises.

The kernel is booted with `lpj=250000` (50 BogoMIPS at 20 ns a step), so that it does
not calibrate its delay loop. Floating point in user space is the kernel's FPU
emulation, which leaves the transcendental functions out: `/init`'s `awk` atan2 line
prints a wrong number and the kernel says so. That is the caution doc/oracles.md
recorded at M0, not a fault of the machine or of either processor.
