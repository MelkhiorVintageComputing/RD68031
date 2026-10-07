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

## UAE030: the WinUAE MC68030 core (instructions, MMU, data cache) -- in production

**What.** Toni Wilen's MC68030 core, with its MMU (`cpummu030`) and data-cache emulation.
It is taken from Hatari's copy of it, in `Inputs/ref/hatari/src/cpu`, which builds on
Linux with far less of an emulator around it than WinUAE's own tree. Since M6 it is the
oracle behind `make ea`, `make vectors`, `make cosim` and `make cache`, the flows RD68021
ran against Musashi. It is GPL code, so everything that links it is GPL-2.0-or-later; the
testbenches that read its output are not linked to it and stay CERN-OHL-S-2.0.

**The harness** (`tools/cosim/uae030/`):

| File | What |
|---|---|
| `build.sh` | copies the core into `build/uae030/`, patches the copy, generates the opcode tables and archives core and glue as `libuae030.a`. Incremental: a second run compiles nothing. |
| `uae030.h` | the library's interface |
| `uae030_glue.c` | stands in for Hatari's memory, chipset and event code; the hooks; `uae030_set_state` and `uae030_run_each` |
| `uae030_trace.c` | the `make cosim` tracer |
| `uae030_ea.c` | the `make ea` generator |
| `uae030_main.c` | `uae030`, a tracer for looking at one program by hand: every instruction's state and every physical access |
| `../../vectors/gen.c` | the `make vectors` generator (`vectors_gen`) |

The Makefile builds the library once (`make uae030` builds it and all four front-ends) and
links each front-end against it. A clean build takes about 40 s at `-j4`; the generated
`cpuemu_*.c` are compiled at `-O0` (`cpuemu_34.c`, the core actually used, at `-O1`), which
keeps each compile near 300 MB.

**Interface** (`uae030.h`):
- `uae030_init(ram_bytes, dcache)`: flat RAM from physical 0; an access outside it is a
  bus error. `uae030_set_alias(window)` folds every address below `window` onto the RAM,
  the way the core harness's partially decoded 32-bit port does.
- `uae030_load`, `uae030_ram`: the image.
- `uae030_set_hooks(insn, bus, user)`: the instruction hook gets the whole state at every
  boundary -- PC, D0-D7, A0-A7, USP, ISP, MSP, SR, VBR, SFC, DFC, CACR, CAAR, TC, CRP, SRP,
  TT0, TT1, MMUSR and the cache hit counts -- and returns nonzero to stop. The bus hook gets
  every physical access: address, size, R/W, data, FC, its kind (operand, table search or
  instruction fetch) and BERR. Cache hits do not appear.
- `uae030_set_op_hook`: one call per *operand* access. A misaligned operand the core moves
  as several aligned accesses is reported once, at its first byte, with its whole size and
  value. Instruction fetches and table searches never appear. This is the unit the core's
  testbenches record (OCS, UM 7.1.1).
- `uae030_set_exc_hook`: the vector number, when exception processing starts.
- `uae030_set_state`, from inside the instruction hook: install a whole programmer's-model
  state (registers, the three stack pointers, SR, VBR, SFC, DFC, CACR, CAAR, PC), invalidate
  both caches and refetch. It arms tracing the way the core does at an instruction boundary,
  so a state with T1 or T0 set is traced exactly as if an RTE had installed it.
- `uae030_run_each(n, setup, result, user, &done)`: n one-instruction tests in one run;
  `setup` writes memory and fills the state, `result` gets the state after. This is how
  `uae030_ea` and `vectors_gen` work. `vectors_gen` also forks a process per batch, so a
  test that halts the core costs that test and not the run.
- `uae030_run`: reset (SSP and PC from physical 0 and 4) and run until the instruction hook
  stops it or the core halts. One run per process.

**Configured as:** `cpu_model` 68030, `mmu_model` 68030, `cpu_compatible`, `cpu_data_cache`.
That is WinUAE's "68030 MMU + cache" core, `op_smalltbl_34`. There is no FPU, and
addressing is 32-bit.

**Patches to the build copy** (sed, in `build.sh`):
- `MMU_DPAGECACHE030` and `MMU_IPAGECACHE030` are off. They are host-speed shortcuts that
  bypass the emulated ATC, so with them on the ATC's behaviour could not be trusted.
- Flags for the function code of each physical access, for table-search accesses and for
  instruction fetches, and a hook at the instruction boundary.
- Not a patch, a link option: the core's misaligned-operand routines are wrapped
  (`-Wl,--wrap`, `OWRAP` in the Makefile) so that the glue sees each misaligned operand as
  the one operand it is.

### The flows

| Target | Front-end | Bench | What is compared |
|---|---|---|---|
| `make ea` | `uae030_ea` | `core_ea_tb` | LEA's address and MOVE.L's operand fetch for every addressing mode and extension-word shape (703 vectors) |
| `make vectors OP=<group>...` / `vectors-all` | `vectors_gen` | `core_vec_tb` | one instruction from a random state: every register, the three stack pointers, SR (under `srmask`), PC, VBR, SFC, DFC, CACR, CAAR, and the ordered operand-access list with each written value (12,200 vectors in 31 groups) |
| `make cosim` / `cosim-long` | `uae030_trace` | `core_cosim_tb` | real programs, every register at every instruction boundary (arith 19,497 and corners 2,157 instructions: the whole of each, so the two targets are the same today) |
| `make cache` | `uae030_trace` | `core_cosim_tb` | the same programs with `ICACHE_ENTRIES=0` and 64, through `tools/cache_diff.py`, after the directed testbenches, the sweep and the effective addresses at 0 |

`vectors_gen list` names the groups. `VEC_DEBUG=<index>` prints every bus access the
oracle makes for one vector, instruction fetches included. `core_vec_tb +faillog=` (the
Makefile writes `build/vectors.fail`) lists every failing vector with both access lists.

**The trace format** (`uae030_trace` to `core_cosim_tb`): a header `nstep nfield`, then per
instruction the PC and `nfield` values: D0-D7, A0-A6, USP, ISP, MSP, SR, VBR, CACR, CAAR,
SFC, DFC (`nfield` = 24). Registers are only ever appended -- the MMU's at M11 -- and the
bench skips the ones it does not know. The first record is the state at the entry point:
USP, MSP, CAAR, SFC and DFC, which a reset leaves undefined (UM 8.1), are copied from it
into the core before anything runs, and compared from then on.

**The vector stream** (`vectors_gen` to `core_vec_tb`): RD68021's, with CACR added to both
the starting and the final state and a value mask added to each access. The format is at
the top of `tools/vectors/gen.c`. A test whose oracle run took a bus or address error (the
long frames are mostly internal state), made more than 24 accesses, or halted is dropped
and counted. Groups RD68031 adds: `movec030` (CACR's implemented bits, CAAR, the control
registers the MC68030 does not have), `illegal030` (the CALLM/RTM encodings), `cmp2`,
`cas`, `bitfield_mem` and `packunpk_mem` (the memory forms RD68021 could not sweep against
Musashi). Room is left for `cache` (M10) and `pmmu` (M11).

### Quirks, and what the harness does about them

Where the oracle and the manual disagree on something a test compares, the generator
records the manual's answer, and says so in a comment at the place it does. Each of these
moves or relabels accesses the oracle made; none invents one.

| Quirk | Manual | What the generator records |
|---|---|---|
| A program-counter-relative mode's reads are driven in data space | UM 2.4.11-2.4.14: "a program space reference" | program space, for every read of a PC-relative test (ZPC included) |
| The exception vector is fetched before the frame is written | UM 8.1: the third step builds the frame, the last fetches the vector | the vector read after the frame |
| RTE reads the SR first, and on a format error reads the whole frame first | UM 8.1.13: the frame is validated before it is read | the format word first; on a format error, nothing else of the frame |
| CAS2 writes destination 2 before destination 1 | PRM 4, CAS2: "Update 1 -> Destination 1; Update 2 -> Destination 2" | destination 1 first |
| DIVU/DIVS overflow leaves C as it was | PRM 4: "C -- Always cleared" | C clear |
| The format $2 frame's instruction address is the next instruction for CHK2, TRAPcc, TRAPV and the zero divide | UM 8.4, the six-word frame (format $2): "the address of the instruction that caused the exception" | the instruction's address. UM table 8-6 says so for every format $2 exception, and the cputest corpus -- WinUAE's own copy of the core, whose tester is checked against real processors -- stacks the instruction's address for CHK, CHK2 and the zero divide (93 sampled tests); the quirk is Hatari's copy's |
| A misaligned or multi-byte operand is several accesses | (granularity, not behaviour) | one operand: the core's unit; bit fields in memory become one operand of up to five bytes, PACK/UNPK's word becomes the two bytes the core moves |
| An instruction-cache burst fill reads the instruction stream through the data path | -- | labelled an instruction fetch |
| A jump to an odd address takes its address error at the next instruction | UM 8.1.3 | the vector is dropped (long frame either way) |

Two more belong to the harness, not the oracle, and are fixed in it:
- `uae030_set_state` arms tracing itself and refetches before the trace bits are set; a
  refetch after them counted, in the core, as a change of flow and traced a NOP under T0.
- The vector bench enters a test that starts traced through an RTE (the core decides
  whether to trace an instruction as it decodes it, earlier than a deposit reaches), and
  lets the core reach the boundary after the instruction where its trace exception is
  taken.

### The M0 spike

Commits: Hatari b166d8c, WinUAE 858c5f3. It worked. A smoke program
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

## cputest: WinUAE's instruction tester (bulk instruction vectors) -- in production

**What.** The vector generator that comes with WinUAE (`Inputs/ref/winuae/cputest/`). It
was written to be run against real CPUs on real hardware, which is why it is here: it is
the closest thing to silicon this project has for the integer instructions. It is built
on Linux by `tools/cputest/build.sh`, using small shims for Windows-only functions in
`tools/cputest/compat/`.

**The flow** (`make cputest`, about 40 minutes on this machine once the corpus exists):

1. `build/cputest/gen/cputestgen`, built once (about 1 min at `-j3`, `-O0` for the
   generated test cores).
2. The corpus, generated once per ini into `build/cputest/run/data/` by
   `tools/cputest/generate.sh`, **one instruction per generator run** with a time limit
   (`CPUTEST_TIMEOUT`, 120 s). The generator's own `mode=all` stops the whole corpus at
   the first instruction it cannot finish -- it retries one effective address forever:
   OR.L under seed 1, CHK under seed 2. An instruction that runs out of time is tried once
   more with the next seed, into a set of its own (`3_RD030S3`), since each set has its own
   memory images; one that fails twice is listed and left out. Today: 176 instruction
   files, about 1.57 million tests, in 2 min 15 s; CHK comes from seed 3, nothing is left
   out.
3. `tools/cputest/convert.py bench` replays the corpus the way the target-side runner
   (`main.c`) reads it, and writes `build/cputest/cputest.vec` (the format is
   `BENCH_FORMAT` in `convert.py`), the memory images (`lmem<N>.hex`, `tmem<N>.hex`) and
   `cputest.idx`, which maps a test number back to its instruction, sub-test and opcode.
   It runs `CPUTEST_MAX` tests per instruction (default 40), evenly spread over that
   instruction's corpus; the memory effects of the tests it does not run are folded into
   the next one it does, so the core's memory is what the runner's would be.
   `CPUTEST_SEL=ADD,MOVE.L` restricts it to some instructions (a bare name takes every
   size). About 6,500 tests run by default, about 2 min of conversion.
4. `sim/tb/core_cputest_tb.sv` is the runner, with the core as the target.

**The memory map** (`tools/cputest/cputestgen.ini`). The corpus is generated for the core
harness's 64 KB 32-bit port: low memory $0000-$7FFF (reached by `(xxx).W`), test memory
$8000-$FFFF (instructions, operands, both stacks). A larger port costs iverilog many
minutes of elaboration per doubling (64 KB: about 7 min; 128 KB: more than 10), and every
other split of the 64 KB that was tried made the generator abort on RTS, RTD, RTR and RTE.
The bench's vector table and its handlers live on the 16-bit port at $1000_0000, where no
generated address reaches.

**What the bench reproduces of the runner:**
- **Entry.** Each test is entered with an RTE from a frame at SSP-8, with USP = A7,
  ISP = SSP = super_stack - $80 and MSP = super_stack; the corpus's SR (user mode for most
  tests) comes in through that RTE, so trace bits and S/M take the architectural path.
- **Sentinels.** After the instruction the runner places a NOP (`MOVEA.L A0,A0`, $2048)
  and an ILLEGAL, or the ILLEGAL first, alternating per sub-test; a branch target holds a
  NOP or an ILLEGAL, toggled per sub-test. A test that completes normally ends at vector
  4 with the stacked PC at the ILLEGAL.
- **Stack copy.** Up to 32 bytes at the user A7 are copied to SSP before each test.
- **Memory.** Each expected write is checked and then its old value put back; a test
  group's set-up writes are rolled back at its end, as the runner does. Writes the runner
  does not check (an exception's frame) persist, as on the target.
- **Ending.** Every vector points at its own RTE; the PC says which vector was taken, and
  that RTE starts the next test.

**What is compared:** the vector; the stacked PC; for an exception the test is about, the
frame's format word and, for a format $2 frame, its address; the stacked SR under the
corpus's own mask of undefined flags (`feature_undefined_ccr=0`, which -- whatever its readme says -- is the setting that emits them: DIVx, CHK, CHK2); D0-D7,
A0-A6 and USP (the runner's A7); every memory write. A long $A/$B bus-fault frame is
compared in its first eight bytes, which is all the corpus records. `+faillog=` (the
Makefile writes `build/cputest/cputest.fail`) lists every difference of every failing
test.

**Not authoritative for:** the MMU instructions ("not going to happen", says its readme);
68020/030 bus-error frames (only their first 8 bytes are recorded); the cache instructions;
the access *order* (it checks memory contents, not bus order -- the sweep does that). It
is the bulk integer corpus; UAE030 and the directed tests cover the rest.

**Found on the way:**
- The generator stalls forever on some instruction under some seeds (above).
- With `feature_full_extension_format`, in this memory map, it generates nothing for most
  instructions, so the corpus has the MC68000 addressing modes only; `make ea` sweeps the
  full-format ones.
- Not every test it emits is run: its own skipped tests (`CT_END_SKIP`) and those that
  end in an exception followed by a trace (two frames) are counted, not run.

The M0 spike (`cputestgen-m0.ini`: 68030; ADD.L, MOVE.W, DIVU.W, CAS.L, BFEXTU; 55,042
tests) proved the build and the decoder; `convert.py dump` still prints decoded tests.

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
