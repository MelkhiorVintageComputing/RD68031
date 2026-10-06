# The oracles, and what each is trusted for

RD68021 checked itself against Musashi, the Suska core and TME. None of them covers an
MC68030:
- TME has no 68030 machine.
- QEMU does not model the 030's MMU.
- Musashi's "68030" MMU is a 321-line stub, with no PTEST, no TT registers, no ATC, and a
  `fatalerror` on early termination.

So RD68031 has its own, chosen at M0 (`doc/plan.md` §2). This file records:
- what each oracle is;
- what M0's spike found when it was first run here;
- what each is *not* authoritative for.

When an oracle and the core disagree, the manual decides and the case goes into
`doc/divergences.md` (CLAUDE.md).

Rules that apply to every oracle:
- Every oracle sits under `Inputs/ref/` and is never modified.
- Each is copied into `build/` to be built.
- None is ever read to write `rtl/`.

---

## UAE030: the WinUAE MC68030 core (instructions, MMU, data cache)

**What.** Toni Wilen's MC68030 core, with its MMU (`cpummu030`) and data-cache emulation.
It is taken from Hatari's copy of it, in `Inputs/ref/hatari/src/cpu`, which builds on
Linux with far less of an emulator around it than WinUAE's own tree. The harness is in
`tools/cosim/uae030/`:
- `build.sh` copies the core into `build/` and generates the opcode tables there.
- `uae030_glue.c` (about 300 lines) stands in for Hatari's memory, custom-chip and event
  code.
- `uae030_main.c` is the tracer.

It is GPL code, so the harness is GPL-2.0-or-later.

**Interface** (`tools/cosim/uae030/uae030.h`):
- `uae030_init(ram_bytes, dcache)`, `uae030_load`, `uae030_set_hooks`, `uae030_run`,
  `uae030_get_state`.
- The instruction hook gets the whole state at every boundary: PC, D0–D7, A0–A7, USP, ISP,
  MSP, SR, VBR, SFC, DFC, CACR, CAAR, TC, CRP, SRP, TT0, TT1, MMUSR and the cache hit counts.
- The bus hook gets every physical access: address, size, R/W, data, FC, whether it is a
  table search, and BERR. Cache hits do not appear.
- Memory is flat from 0, and an access above it is a bus error. There is one run per
  process.

**Configured as:** `cpu_model` 68030, `mmu_model` 68030, `cpu_compatible`, `cpu_data_cache`.
That is WinUAE's "68030 MMU + cache" core, `op_smalltbl_34`. There is no FPU, and
addressing is 32-bit.

**Patches to the build copy** (sed, in `build.sh`):
- `MMU_DPAGECACHE030` and `MMU_IPAGECACHE030` are off. They are host-speed shortcuts that
  bypass the emulated ATC, so with them on the ATC's behaviour could not be trusted.
- Hooks are added for the function code of each physical access, for table-search accesses,
  and for the instruction boundary.

**M0 spike** (commits: Hatari b166d8c, WinUAE 858c5f3). It works. A smoke program
(`tools/cosim/uae030/tests/mmu_smoke.S`) traced correctly against UM §6, §8, §9 and the PRM:
- **Table searches:** a two-level short-format table search, with the U bit written back on
  a read and U|M on a write, plus a fresh search to set M when the ATC entry lacks it.
- **ATC:** the ATC holds page descriptors only, and PFLUSHA forces new searches.
- **PTEST:**
  - mapped page: MMUSR $0202, and An gets the descriptor address;
  - invalid page: MMUSR $0402;
  - U/M are left untouched.
- **TT0:** an access through TT0 needs no search.
- **A bus error through an invalid descriptor** stacks a long format $B frame (92 bytes,
  vector 2) with SSW $0345 and the right fault address. The stacked PC is the faulting
  instruction.
- **Data cache:**
  - CACR $909 reads back $101;
  - the second read hits;
  - with WA=0 there is no write allocation;
  - the cache is logically indexed: another logical address for the same physical one
    misses.
- **A misaligned longword** is split into aligned accesses.

**Not authoritative for, or not modelled:**
- **Clock counts** (`cpu_cycle_exact` is not used) and **burst fills**. The bus stream is
  a stream of accesses, not of bus cycles; layer 2 is for cycles.
- **FC of a table-search access.** It is labelled 5 by the harness, and the UM's statement
  of it is still to be found. The reset-vector and vector-fetch accesses carry a stale FC.
- **SSW bit 9** and the other bits the UM calls "internal use" have to be masked in
  comparisons.
- **Interrupts** are not wired yet. M13's lockstep injects them at the boundary where the
  RTL took them.

**Found on the way:** gas assembles `pmove label,%srp`, with a label in `.text`, as
`(d16,PC)`. That is not a control alterable mode (PRM §6), so the part takes an F-line
exception, and UAE030 does too. Test programs address the operands of PMOVE through `(An)`.

## cputest: WinUAE's instruction tester (bulk instruction vectors)

**What.** The vector generator that comes with WinUAE (`Inputs/ref/winuae/cputest/`). It
was written to be run against real CPUs on real hardware, which is why it is here. It is
built on Linux by `tools/cputest/build.sh`, using small shims for Windows-only functions in
`tools/cputest/compat/`.

**M0 spike.** It works. `cputestgen` builds in about 12 s. With
`tools/cputest/cputestgen-m0.ini` (68030; ADD.L, MOVE.W, DIVU.W, CAS.L, BFEXTU) it made
55,042 tests in 1 s, reproducibly. `tools/cputest/convert.py` decodes every one: initial
registers and memory, the instruction, and the expected registers, memory writes and
exception frame. Its counts equal the generator's own. Notes on the format (DATA_VERSION
24) are at the top of `convert.py`.

The testbench has to reproduce two things the corpus assumes:
- **Sentinels.** Each test ends at an ILLEGAL sentinel (exception 4) placed by the
  generator.
- **Starting stack pointers.** SSP is super_stack − $80, MSP is super_stack, and USP is A7.

**Not authoritative for:** the MMU instructions ("not going to happen", says its readme);
68020/030 bus-error frames (only their first 8 bytes are recorded); the cache instructions.
It is the bulk integer corpus. UAE030 and the directed tests cover the rest.

## AP68030: a second core (bus cycles, MMU)

**What.** A third party's GPL-2 Verilog MC68030 (`Inputs/ref/AP68030`, commit 33007df). It
has the caches, the MMU, and synchronous and burst cycles. **It implements this very chip,
so CLAUDE.md's ban is total.** Nobody writing `rtl/` opens any file of it, documentation
included. The harness in `sim/ap030/` uses its ports and its program bench, and nothing
more.

**M0 spike.** It works, under the Verilator 5.032 installed here:
- **Waiver needed.** Its program bench needs `-Wno-BLKANDNBLK`; eight bench signals are
  assigned both ways. `sim/ap030/verilator-wrap` adds the waiver for its own
  `tb/run_tests.sh`.
- **Assembler.** That script also needs vasm (`vasmm68k_mot` 2.0f, built from source into
  `build/tools/`).
- **Its own regression passes:** every program, with and without wait states. The programs
  are t_integer, t_exceptions, t_bus, t_cache, t_mmu, t_cp and t_dblfault.
- **One failure.** Its separate bus-controller unit bench times out on a misaligned word to
  its 16-bit port. That was not investigated, since it would mean reading its RTL. The
  program bench, which is the one used here, does not depend on it.

**How it is driven:**
- `sim/ap030/build_oracle.sh` builds its unmodified program bench into
  `build/ap030/obj_oracle/`, at about 270 MB peak.
- `sim/ap030/pin_monitor.sv` is attached with `bind`, so their bench is not edited.
- `sim/ap030/run_oracle.sh prog.bin out` runs a raw binary built by our cross-assembler,
  with vectors at 0 and code from $400. It writes one line per transfer, and one per beat
  of a burst: address, FC, SIZ, R/W, termination (STERM or DSACK32/16/8 or BERR), data,
  CBREQ, CBACK, CIIN, CIOUT, RMC, wait clocks. Example:
  `sim/ap030/busdemo.S`.
- Their bench's memory map:

| Address | Behaviour |
|---|---|
| $000000 | 1 MB, 32-bit, STERM, burstable |
| $200000 | alias, 16-bit DSACK |
| $300000 | alias, 8-bit DSACK |
| $400000 | alias, 32-bit DSACK with CIIN |
| $F00000 | test registers |
| $FF0000 | bus error |

Only 24 address bits are decoded.

**The plan for M1–M2.** Put both cores in one testbench of ours with identical slave
models, and compare the transaction stream: address, FC, SIZ, R/W, data, RMC, burst and
order. If clock-for-clock comparison turns out to be too fragile, the transaction stream
alone is the fallback.

**Questions it raised, for the manual to answer:**
- The reset vector is read with FC=6.
- Descriptor fetches are RMC reads, with an RMC write-back for U/M.

## MAME: the m68030 and the Sun-3/80

**What.** MAME's m68030, with its MMU, in its `sun3x` driver (`src/mame/sun/sun3x.cpp`,
machines `sun3_80` and `sun3_460`, both flagged `MACHINE_NOT_WORKING`). The source is
`Inputs/ref/mame`, a shallow clone at 9d7b48c. `sim/mame/build.sh` builds just that driver
from a copy in `build/mame/`.

**PROMs.** The Sun-3/80 PROM images are in `Inputs/ref/PROMs/`, supplied by the user and
not committed (`Inputs/sw/PROMS.sha256`). All four of MAME's revisions are there and match
its CRC and SHA1:
- rev 3.0.3, the default; `525_1041_07` is the same image;
- 3.0.2;
- 3.0, the same image as `525_1041_05_sus`;
- 2.9.2.

**NVRAM.** MAME's NVRAM default (`timekpr_380.bin`) is not available. It is not needed:
`sim/mame/mk_timekpr.py` makes one from a Sun EEPROM image built with RD68021's
`tme-sun-eeprom`, from `sim/mame/eeprom.txt`. That image puts the console on ttya, which
is what a comparison wants, and adds an IDPROM.

**M0 spike:**
- **Build.** It builds and runs here, with SDL2 and GL development headers unpacked from
  `apt-get download`ed packages into a private prefix, since nothing is installed
  system-wide. A clean build is about 25–30 min at `-j2`, with more than 9 GB left free
  throughout. The binary is 75 MB.
- **Run.** `sun3x sun3_80 -video none -sound none -nothrottle -rs232a null_modem -bitb
  socket.127.0.0.1:4321` with `sim/mame/serlisten.py` on the other end runs at about
  6× real time. MAME's own m68030 takes PROM 3.0.3 through its self-test to the monitor:

```
Selftest Completed.
 Sun Workstation, Model Sun-3/80 Series.
 ROM Rev 3.0.3, 64MB memory installed, Serial #4660.
 Ethernet address 8:0:20:12:34:56, Host ID 47001234.
Auto-boot in progress...
EEPROM boot device... sd(0,0,0)
sd: Device not found.
>
```

The monitor takes typed commands, such as `b ?`.

**What M14 can and cannot compare.** The PROM, from self-test to monitor and the monitor
commands, can be compared now. **No OS boots on this driver**, because it lacks:
- the LANCE Ethernet;
- the SCSI DMA engine and the SCSI and SCC interrupts;
- the level-5 clock;
- bus errors on unmapped addresses.

Booting NetBSD/sun3x or SunOS 4.1.1 means adding those to our copy of the driver, in
`sim/mame/`. MAME has an am79c90 to start the LANCE from. It is several days of work, and
`doc/plan.md` M14 is sized accordingly.

**How the core plugs in.**
- A `cpu_device` subclass wraps the Verilator model, and a variant machine (`sun3_80rd`) in
  our copy of `sun3x.cpp` uses it. The driver has no CPU slot, but `m_maincpu` is a plain
  `required_device<cpu_device>`.
- MAME's m68030 translates inside the CPU, so **`AS_PROGRAM` is the physical bus**, as it
  is on a real 030's pins. Function codes are not visible on it; only CPU space is separate.
- The driver raises bus error by pulsing `M68K_LINE_BUSERROR` from inside a read or write
  handler. The wrapper has to latch that and give it to the core as BERR on the cycle in
  flight.
- For a fair comparison, the reference m68030 needs `set_fpu_enable(false)` when the core
  has no FPU, since MAME folds a 68882 in.

**Not authoritative for:**
- The driver's own comment calls one PROM mapping a "bad '030 MMU mapping". `b le()`
  bus-errors with a physical address of 0, and that disagreement belongs to the manual.
- Clock counts.

## rd-virt: the Linux m68k `virt` machine

**What.** Not an oracle itself. It is the deterministic machine of M13 on which the core and
UAE030 run Linux in lockstep. The spike checked that a stock kernel can be built for it,
and wrote down the board the kernel expects.

**Software.** The kernel and busybox are pinned by sha256 in `Inputs/sw/MANIFEST`: Linux
7.2.9 and BusyBox 1.38.0. The guest configuration is in `sim/virt/linux/`:
- `rd-virt.config` is applied over `allnoconfig` and selects `VIRT`, `M68030` + `M68040`
  (VIRT forces the 040 on) and `M68KFPU_EMU`. It also turns on goldfish tty/rtc/timer,
  virtio-mmio-blk and virt-ctrl, with no network and no modules.
- `init` and `cpio.list` make the initramfs, packed by the kernel's own `gen_init_cpio`,
  so no root is needed.
- BusyBox is `defconfig`, static, with `-mcpu=68030`.
- With the `M68030` option on, the kernel's C code is built for the 68020 baseline.
  `head.S` picks the 030 or the 040 paths at run time from the bootinfo. On an 030 it maps
  the I/O window at $FF000000 through **TT1**, with CI set.

**M0 spike:**
- The kernel builds in 52 s at -j4, BusyBox in 15 s.
- On QEMU 11.1.2 `-M virt -cpu m68040` it boots to the shell and powers off: 104.7 M
  instructions, or 81.4 M with `lpj=` given.
- **The 030 path cannot be checked on QEMU.** QEMU accepts `-cpu m68030` and passes the
  right bootinfo, but it does not decode the 030's PMOVE, PTEST or PFLUSH, so the kernel
  dies in `paging_init`. Its first run will be on rd-virt, with UAE030 as the reference.

**The board** (from `arch/m68k/virt/` and QEMU's `hw/m68k/virt.c`):

- **Loading.**
  - The ELF is loaded with physical = virtual, and entry is at $2000. The CPU starts in
    the reset state with the MMU off.
  - The bootinfo goes at `(_end + 1) & ~1`. The initrd goes page-aligned at the top of RAM.
- **Bootinfo.** Records are `{u16 tag, u16 size, data}`, big-endian, ending with tag 0:
  - `MACHTYPE` = 14 (VIRT)
  - `CPUTYPE` = 2 (68030)
  - `MMUTYPE` = 2 (68030)
  - `FPUTYPE`, left out when there is no FPU
  - `MEMCHUNK`, `RAMDISK`, `COMMAND_LINE`
  - `RNG_SEED`, fixed for determinism
  - `VIRT_*`, the base address and IRQ of each device below
- **Interrupts.** Six goldfish PICs at $FF000000 + i·$1000 drive levels 1–6 with
  **autovectors**. Linux numbers the IRQs 8 + (pic−1)·32 + (n−1).
- **Devices:**
  - the scheduler timer, a goldfish-rtc at $FF006000, IRQ 168;
  - the wall-clock goldfish-rtc at $FF007000;
  - the goldfish-tty at $FF008000, IRQ 39;
  - virt-ctrl at $FF009000 (power-off is CMD 2);
  - 128 virtio-mmio transports at $FF010000 + n·$200, IRQs 40–167. They are legacy,
    version 1.
- **Time.** The timer is a 64-bit nanosecond counter with a one-shot alarm. rd-virt makes
  it *retired instructions × K ns*.
- **What rd-virt must do as a consequence:**
  - When the kernel idles on `STOP`, jump time forward deterministically to the next alarm
    or interrupt.
  - The tty and virtio **DMA into RAM**. Those writes have to reach both lockstep
    memories.

**Cautions:**
- **The FPU.** Linux's FPU emulation leaves the transcendental functions as placeholders,
  and Debian's static libm uses 68881 instructions. Userspace floating point is therefore
  right only with a real 68881/68882 on the coprocessor interface, reported as FPU_68882,
  or with a soft-float userspace. `atan2(1,1)*4` in awk is the check.
- **NetBSD/virt68k (NetBSD 11.0)** lists `M68030` in GENERIC, but has no FPU emulation and
  has surely never run on an 030. It is a second guest after Linux.
