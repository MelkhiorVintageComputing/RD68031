# M13: what rd-virt found

The lockstep of `doc/virt.md` runs the RTL and UAE030 on two copies of the `virt` machine
and compares them at every instruction boundary. Every disagreement it met is here, in
the classes of `doc/m6-mismatches.md`:

- **(a)** a likely RTL bug -- the manual says what the core should do, and it does not;
- **(b)** an oracle quirk or a harness issue -- handled in the harness, and listed so that
  nobody changes the RTL for it;
- **(c)** a known, decided difference -- with the lockstep option that accepts it.

Everything is phrased architecturally: the instruction, its operands, the registers on
each side, the manual section that decides. UM is `MC68030UM_split`, PRM
`M68000PRM_split`. Step numbers are boundaries since the reset, as `rdvirt` counts them;
`--dump-at N` reproduces the state and both buses at any of them.

## Class (b): oracle quirks and harness issues

| | Observed | Manual | Handling |
|---|---|---|---|
| m13-b1 | A bus fault frame stacked by UAE030 carried a condition code register of zero. `virt_hello`: after `CLR.L D7` (Z set) and `LEA`, a `MOVE.L $FF800000,D0` that ends in a bus error stacks SR $2700 on UAE030, $2704 on the core; `virt_mmu`, a read of an invalid page after `BTST` with X set: $2700 against $2710. | UM 8.1: the processor copies the status register before it changes it for the exception; the faulted MOVE never got its operand, so the flags are the previous instruction's. | A harness defect, not the oracle's intent: the oracle's run loop keeps the flags of the instruction in progress in a local variable to put them back on a bus fault, and in the build copy that variable lost its value across the `longjmp` the fault makes (C11 7.13.2.1). Fixed in `tools/cosim/uae030/build.sh` (1d): the variable is volatile. **Every UAE030 flow is affected.** Checked against the library as committed (b62d20b), rebuilt aside: `make cosim-mmu`'s `mmu_fault` trace is byte for byte the same, and `cow_mmu`'s loses three SR disagreements (2,108 boundaries to 2,105: the handler's flags at 8,670, 10,472, 10,480) and gains none. |
| m13-b2 | After RTE of a bus fault frame UAE030 shows a boundary at the faulted instruction's own address, then runs it again from its first word; the core resumes it and shows the boundary after it. | UM 8.2 | doc/m11-mismatches.md b8. The lockstep takes the oracle's extra boundary when the instruction that just ended was RTE and the registers disagree (on by default; counted as "oracle restarts"). |
| m13-b5 | The oracle writes again what it had already written: a user write of $801CA000 to the stack (physical $03C3FE88) appears twice on the oracle's bus (steps 68,776,609 and 68,776,610), once on the core's (68,776,607). | -- | A consequence of b8 (the restart re-runs the instruction's writes). The write matcher drops a one-sided write of the value both sides already agree the byte holds (counted as "repeated writes") |
| m13-b3 | The kernel's `m68k_fputype` read $0004xxxx (an FPU) under both processors, and `resume()` took an F-line exception on FSAVE ("BAD KERNEL TRAP", "LINE 1111"). | -- | The platform's, not a processor's: with no `BI_FPUTYPE` record head.S's `get_bi_record` leaves its pointer on the bootinfo terminator. rd-virt writes `FPUTYPE` = 0 (doc/virt.md); doc/oracles.md's M0 note is corrected. |
| m13-b4 | virtio-mmio's magic read as $76697274 by the driver ("Wrong magic value") | -- | The platform's: virtio-mmio registers are little-endian; fixed in `machine.cpp`. |

## Class (c): known, decided differences, and how the lockstep accepts them

| | What | Decision | Lockstep |
|---|---|---|---|
| m13-c1 | A posted write that faults: the core can reach the boundary after the writing instruction before the fault is taken; the oracle faults inside the instruction. `virt_mmu`: `MOVE.L #$55AA55AA,$40003008` to an invalid page -- the core's step ends at the next instruction ($117E) with no exception yet, the oracle's in the bus error handler. The core's next step ends in the handler, with every register the same. | doc/checkpoint.md rule 9; doc/m11-mismatches.md b15h | when the oracle's step took a bus error and the core's did not, the core's next step is taken and compared (on by default; counted as "posted-write fault boundaries") |
| m13-c2 | The frame of a fault on an instruction's last write: the core stacks the long frame ($B, 92 bytes), the oracle the short one ($A, 32 bytes), so ISP and every stack address differ by 60 inside the handler. | doc/checkpoint.md "Which frame, and when"; doc/m11-mismatches.md c4 | the oracle is switched to stack $B too (`uae030_set_short_frames(0)`, build.sh 1e); `--uae-short-frames` restores its own choice. The frame's bytes are not compared (internal words, UM 8.4.6) |
| m13-c3 | The SSW's internal-use bits in copies the kernel makes. Linux's `buserr_c` reads the SSW out of the frame (`MOVE.W 54(A3),D2` at $A4E2): $0101 on the core, $0301 on the oracle, at step 68,272,606 of the boot, the first page fault of /init. | doc/m11-mismatches.md c6: UM figure 8-9 gives bits 11-9 to the implementation; the oracle keeps its own state in bit 9 and needs it back at RTE, so it cannot be cleared in its frame | for each long frame the two SSWs (after c5's alignment, different only in bits 11-9) are recorded; until the RTE that pops that frame a register whose low word holds the oracle's where the core's holds the core's is accepted, and an oracle word or long-word write carrying the oracle's may match the core's (counted as "SSW-copy differences"; `--strict-ssw` refuses them). A first version accepted any difference within bits 11-9 of any byte while a frame was live, and matched a written $00 against a $08 -- too loose; it was replaced |
| m13-c5 | The stage fault bits and the stage B address of an instruction-fetch fault. /init's first user-mode fetch from a page not yet present: the kernel's `buserr_c` reads the SSW (`MOVE.W 54(A3),D2` at $A4E2) as $F000 on the core (FC, FB, RC, RB) and $5062 on the oracle (FB, RB, and the data-cycle fields R/W = 1 and FC = 2), and then branches on FC -- different paths (SR $2008 against $2000 at the next boundary), step 68,685,364. The kernel takes the fault's address from the stage B address (+$24) when FC or FB is set, which the oracle fills with the data fault address (b10). | doc/m11-mismatches.md c8 (the stage bits are the pipe's business) and b10; UM 8.2.1 | when both stack a long frame for the same fault, the core's SSW (but for bits 11-9) and stage B address are written into the oracle's frame through its own write path, so the handler sees one frame; the oracle's RTE reads neither in a way that changes. On by default, counted as "fault frames aligned"; `--strict-frames` turns it off |
| m13-c7 | **Decided after M13 phase A: the core is kept.** An address register of an instruction a bus fault interrupts. A user `MOVE.L (A3)+,D2` (opcode $241B) at $80065594 reads a page not yet present (step 68,728,825 of the boot): in the handler the core's A3 is $80182340, the value before the instruction; the oracle's is $80182344, already incremented (it undoes that at its RTE, b8, and runs the instruction again). After the RTE both finish the instruction with A3 = $80182344. The same for the user stack pointer: a user-mode push interrupted by a page fault leaves USP $EFA179F4 on the core and $EFA179F0 on the oracle in the handler (step 72,747,849). | UM 8.2 says what the frame holds and that RTE completes the instruction; it does not say what An reads as in the handler between the two. The core's answer is the one the instruction's own semantics give before it completes. No oracle evidence against it but the oracle's restart model | the (register, core value, oracle value) pairs that differ by at most 16 when the fault is taken are accepted until the RTE that pops that fault's frame, or until the core's register reaches the oracle's value, in the registers; an oracle long-word write of the oracle's value may match the core's (counted as "An copies"). It is not a substitution: the data fault address of a `-(An)` is exactly the oracle's decremented An, and both write it. `--strict-an` refuses them |
| m13-c6 | LINK with A7, decimal arithmetic on non-BCD bytes (doc/divergences.md) | the manual's answer is kept | not met in any run so far |

## Class (a)

None. Linux boots to the shell, runs the command set and powers off on the RTL, in
lockstep with UAE030, with no divergence but the items above, caches on and caches off.

## The runs

The guest is `sim/virt/linux/` built by its `build.sh` (Linux 7.2.9, BusyBox 1.38.0), with
`console=ttyGF0 lpj=250000 rdvirt.shell` and `commands.script`. RAM 64 MB, 20 ns a step,
asynchronous RAM with no wait state and one on the devices unless said. Wall times on
the build machine.

| Run | Result | Steps | Wall | Steps/s |
|---|---|---|---|---|
| `make virt-uae` (UAE030 alone) | PASS: shell, command set, power off | 87,726,384 | 83 s | 1.06 M |
| `make virt-linux-solo` (RTL alone) | PASS: the same console | 87,733,996 | 1,061 s | 82.7 k |
| RTL alone, `--burst --ram-waits 1` (synchronous RAM, bursts, a wait state) | PASS: the same console | 87,733,996 | 837 s | 104.8 k |
| `make virt-linux` (lockstep, caches on) | **PASS: 0 divergences**; RAM of the two machines identical at the end | 87,733,996 | 1,155 s | 76.0 k |
| `make virt-linux VIRT_CACHES=off` (RTL CDIS, oracle without its data cache) | **PASS: 0 divergences** | 87,733,996 | 1,420 s | 61.8 k |
| `make virt-bare` | PASS: `virt_hello` 275, `virt_timer` 17,018, `virt_mmu` 155,176 steps, each in lockstep with asynchronous RAM, with `--burst`, and with the caches off | | seconds | |

What the lockstep accepted on the way, caches on: 594 oracle restarts (b2), 322
posted-write fault boundaries (c1), 1,029 fault frames aligned (c5), SSW copies (c3) in
registers 224,058 times -- one per register per step, over 220,604 steps, the handlers'
lifetimes of 1,029 faults -- and in 1,196 oracle writes, 665 An copies (c7), 144 repeated
writes (b5; 140 within 5,000 steps of a fault or a re-run, the other 4 one long word,
$801CA000, 13,000 steps into a handler that slept), and every frame of a bus fault both
stacked as $B (c2). Every oracle frame poke (c5) read back as written. **At power-off the
two machines' 64 MB of RAM are identical byte for byte.**

(A first version of the matcher dropped a one-sided write of an agreed value at once,
before the other side's identical write, a step behind, could pair with it; it counted
22.7 M such "repeats", nearly all ordinary lagged rewrites. Lone repeats are now dropped
only after the 64-step window, and are counted against the distance to the last fault.) The two consoles are the same byte
for byte, and the RTL-solo console is the same as UAE030-solo's but for where the tty
echoes two typed lines (each solo run takes its interrupts at its own boundaries).

How the run got there, divergence by divergence (each a harness or a decided item, none
an RTL defect): the bootinfo (b3) and virtio (b4) at the platform's first runs; a
posted write's second bus cycle landing up to four steps after its instruction (the write
window, now 64 steps); a posted write landing in an interrupt's step (the frame-skip,
now the bus fault frame alone); the oracle's lost CCR (b1); the SSW (c3) at step
68,272,606; the stage bits (c5) at 68,685,364; An (c7) at 68,728,825; the repeated write
(b5) at 68,776,673; USP (c7) at 72,747,849; and a handler that slept across a context
switch, which ended the first "live frame" rule (frames are now tracked to their RTE).

Reproducing any of them: `build/virt/obj/rdvirt --cpu lockstep --kernel
build/virt/guest/vmlinux --initrd build/virt/guest/initramfs.cpio.gz --cmdline
"console=ttyGF0 lpj=250000 rdvirt.shell" --script sim/virt/linux/commands.script` with
the `--strict-*` option that turns its acceptance off, and `--dump-at N` for the state
and both buses at step N.
