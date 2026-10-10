// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- a real program, instruction by instruction, against UAE030.
//
// The per-opcode sweep (sim/tb/core_vec_tb.sv) runs one instruction at a time
// from a state nobody ever reached by executing anything. This runs a program:
// the instruction mix, the register allocation and the addressing modes are
// GCC's, so they are a mix nobody here designed, and every instruction starts
// from the state the one before it left.
//
// The comparison is at every instruction boundary, so a divergence is reported
// at the instruction that caused it and not at the end of a program that came
// out wrong.
//
// UAE030 (tools/cosim/uae030/uae030_trace.c) writes the trace. It is an ORACLE,
// not a source. Where the two disagree the manual decides.
//
// THE TRACE, read positionally with $fscanf("%h"):
//
//     nstep  nfield
//     per instruction:  pc  then nfield values
//
// and the values, in this order:
//
//     d0..d7  a0..a6  usp  isp  msp  sr  vbr  cacr  caar  sfc  dfc
//     tc  crp_hi  crp_lo  srp_hi  srp_lo  tt0  tt1  mmusr        (M11, nfield 32)
//
// New registers are only ever appended, so this bench reads nfield from the
// header, compares the ones it knows, and skips the rest; a 24-field trace
// is compared without the MMU's.
//
// make cosim-mmu (M11) adds:
//
//   +mmu          the bus-error window the MMU programs use: every cycle to
//                 $4000_0000-$4FFF_FFFF ends with BERR (as in core_mmu_tb),
//                 and the 16-bit, 8-bit and synchronous ports start zeroed
//   +mmubus=FILE  the physical data-access stream, in the format
//                 tools/cosim/uae030/uae030_trace.c -B writes, from the pins:
//                 one line per transfer (per beat of a burst) with the bytes
//                 the port moved, instruction fetches left out, the table
//                 walker's cycles labelled T (or F when the search was for an
//                 instruction fetch's translation), and `I n pc` at each
//                 boundary. tools/bus_diff.py stream compares the two.
//   +maxfail=N    keep going after a register disagreement, up to N of them:
//                 the oracle's registers are deposited and the run goes on, as
//                 long as the program counters still agree. Default 1.

`timescale 1ns / 1ps

module core_cosim_tb;

`include "rd68031_core_harness.svh"

  integer      trc;
  int unsigned nstep;
  int unsigned nfield;
  logic [31:0] tpc;
  // d0..d7 a0..a6, then the named ones, at these indices -- the trace's order.
  localparam int NKNOWN = 24;
  localparam int T_USP = 15, T_ISP = 16, T_MSP = 17, T_SR = 18, T_VBR = 19,
                 T_CACR = 20, T_CAAR = 21, T_SFC = 22, T_DFC = 23;
  localparam int T_TC = 24, T_CRPH = 25, T_CRPL = 26, T_SRPH = 27, T_SRPL = 28,
                 T_TT0 = 29, T_TT1 = 30, T_MMUSR = 31;
  bit          has_mmu;           // the trace carries the MMU's registers
  int unsigned maxfail, nfail, nrestart, nextra;
  bit          stop;
  logic [31:0] tpc2;
  integer      tpos;
  logic [31:0] treg [0:63];
  logic [31:0] start_pc;

  int unsigned k, n;
  int unsigned shown;
  bit          ok, bad;
  string       image, trace, why;
  // Every register that disagrees at a boundary is reported, not just the
  // first: the run goes on from the oracle's values (+maxfail), and a second
  // disagreement would otherwise be hidden by that deposit.
  // (No ?: on strings, and no automatic task: iverilog 12's vvp asserts on
  // either.)
  string why1;
  task addwhy(input string w);
    if (why == "") why = w;
    else begin why1 = why; $sformat(why, "%s; %s", why1, w); end
  endtask

  // The bus, cycle by cycle, for `make cache` to hold two builds of the core to
  // "the same program makes the same data cycles, and the cache only ever takes
  // instruction fetches away". One line per cycle at the negation of AS: the
  // requester (F for the instruction pipe, D for everything else), the function
  // code, the address, the size, the direction, and what a write wrote.
  integer bus_log;
  string  bus_file;
  initial bus_log = 0;

  always @(posedge as_n_o) if (bus_log != 0 && rst_n)
    $fdisplay(bus_log, "%s %0d %08h %0d %s %08h",
              dut.u_biu.op_isfetch ? "F" : "D", fc_o, a_o, siz_o,
              rw_o ? "R" : "W", rw_o ? 32'd0 : d_o);

  // The physical data-access stream, for make cosim-mmu -- the format is at
  // the top of tools/cosim/uae030/uae030_trace.c. A transfer is recorded when
  // it ends: an asynchronous one at the first falling edge that sees DSACK or
  // BERR (the processor latches read data on a falling edge -- UM 7.3.1), a
  // synchronous one at the falling edge after each rising edge that sampled
  // STERM (UM 7.3.4), one line per beat of a burst. What the line carries is
  // what the port moved: UM 7.2.1 fixes which lanes a port uses, so the bytes
  // are taken from those lanes -- the port of each address is the harness's
  // (rd68031_core_harness.svh): 32 bits at $0xxx_xxxx, 16 at $1xxx_xxxx, 8 at
  // $2xxx_xxxx, 32 synchronous at $3xxx_xxxx.
  integer mbus;
  string  mbus_file;
  bit     mb_async_done, mb_sterm_pend;
  int     mb_beat;
  initial begin
    mbus = 0;
    mb_async_done = 1'b0;
    mb_sterm_pend = 1'b0;
    mb_beat = 0;
  end

  function automatic int port_bytes(input logic [31:0] a);
    case (a[31:28])
      4'h1:    port_bytes = 2;
      4'h2:    port_bytes = 1;
      default: port_bytes = 4;
    endcase
  endfunction

  task automatic mb_emit(input logic [31:0] addr, input int nb, input bit berr);
    int pb, k, lane;
    logic [31:0] v;
    byte kind;
    pb = port_bytes(addr);
    v = 32'd0;
    if (!berr)
      for (k = 0; k < nb; k = k + 1) begin
        lane = (pb == 1) ? 0 : ((addr + k) % pb);
        v = (v << 8) | 32'(dbus[31 - 8*lane -: 8]);
      end
    if (dut.u_biu.op_istw)
      kind = (dut.u_mmu.w_kind == 2'd0 && dut.u_mmu.w_fc[1:0] == 2'b10) ? "F" : "T";
    else
      kind = "D";
    $fdisplay(mbus, "%s %0h %0d %0h %0d %c %0d%s", rw_o ? "R" : "W", addr, nb,
              berr ? 32'd0 : v, fc_o, kind, dut.u_seq.cacr_q[8], berr ? " B" : "");
  endtask

  function automatic int xfer_bytes(input logic [31:0] a, input logic [1:0] s);
    int pb, room, sb;
    pb = port_bytes(a);
    room = pb - (a % pb);
    sb = (s == 2'b00) ? 4 : int'(s);
    xfer_bytes = (sb < room) ? sb : room;
  endfunction

  always @(negedge as_n_o) begin
    mb_async_done = 1'b0;
    mb_sterm_pend = 1'b0;
    mb_beat = 0;
  end
  always @(posedge clk)
    if (mbus != 0 && rst_n && as_oe && !as_n_o && !sterm_n_i && berr_n_i)
      mb_sterm_pend = 1'b1;
  always @(negedge clk) if (mbus != 0 && rst_n && as_oe && !as_n_o) begin
    if (!dut.u_biu.op_isfetch) begin
      if (mb_sterm_pend) begin
        if (mb_beat == 0) mb_emit(a_o, xfer_bytes(a_o, siz_o), 1'b0);
        else mb_emit({a_o[31:4], a_o[3:2] + 2'(mb_beat), 2'b00}, 4, 1'b0);
      end else if (!mb_async_done && (!berr_n_i || dsack_n_i != 2'b11)) begin
        mb_emit(a_o, xfer_bytes(a_o, siz_o), !berr_n_i);
        mb_async_done = 1'b1;
      end
    end
    if (mb_sterm_pend) mb_beat = mb_beat + 1;
    mb_sterm_pend = 1'b0;
  end

  // Where the clocks go, for doc/timing-divergences.md: +stalls counts, from
  // reset to the end, the clocks a bus microword spends stalled, by direction,
  // and how many of each retired -- the ceiling for overlapping operand cycles
  // with the microcode around them.
  bit          stalls;
  longint unsigned st_clk, st_wr, st_rd, n_wr, n_rd, st_other, st_fetch;
  initial begin
    stalls = $test$plusargs("stalls");
    st_clk = 0; st_wr = 0; st_rd = 0; n_wr = 0; n_rd = 0; st_other = 0;
    st_fetch = 0;
  end
  always @(posedge clk) if (stalls && rst_n) begin
    st_clk = st_clk + 1;
    if (dut.u_seq.bus_req) begin
      if (!dut.u_seq.retire) begin
        if (dut.u_seq.other_stall)                     st_other = st_other + 1;
        else if (dut.u_seq.req_kind == rd68031_pkg::CT_WRITE) st_wr = st_wr + 1;
        else                                           st_rd = st_rd + 1;
        if (dut.u_biu.op_active && dut.u_biu.op_isfetch) st_fetch = st_fetch + 1;
      end else if (dut.u_seq.req_kind == rd68031_pkg::CT_WRITE) n_wr = n_wr + 1;
      else                                             n_rd = n_rd + 1;
    end
  end
  final if (stalls)
    $display("core_cosim_tb: stalls: %0d clocks; %0d writes stalled %0d clocks, %0d reads %0d, %0d waiting on other things, %0d of the bus stalls behind a prefetch",
             st_clk, n_wr, st_wr, n_rd, st_rd, st_other, st_fetch);

  initial begin
    if ($value$plusargs("buslog=%s", bus_file)) bus_log = $fopen(bus_file, "w");
    if (!$value$plusargs("image=%s", image)) image = "build/programs/arith.hex";
    if (!$value$plusargs("trace=%s", trace)) trace = "build/programs/arith.trc";
    if ($value$plusargs("mmubus=%s", mbus_file)) mbus = $fopen(mbus_file, "w");
    if (!$value$plusargs("maxfail=%d", maxfail)) maxfail = 1;
    nfail = 0;
    nrestart = 0;
    nextra = 0;
    stop  = 1'b0;
    if ($test$plusargs("mmu")) begin
      berr_base = 32'h4000_0000;
      berr_mask = 32'hF000_0000;
      berr_en   = 1'b1;
      for (n = 0; n < 65536; n = n + 1) begin
        s16.mem[n] = 8'h00;
        s8.mem[n]  = 8'h00;
        sB.mem[n]  = 8'h00;
      end
    end

    // The image IS the memory: the vectors at zero, the program at $1000 and
    // the stack at the top of the first 64 KB.
    for (n = 0; n < 65536; n = n + 1) s32.mem[n] = 8'h00;
    $readmemh(image, s32.mem);

    trc = $fopen(trace, "r");
    if (trc == 0) begin
      $display("FAIL: core_cosim_tb cannot open %s", trace);
      $finish;
    end
    n = $fscanf(trc, "%h %h", nstep, nfield);
    if (n != 2 || nfield < NKNOWN || nfield > 64) begin
      $display("FAIL: core_cosim_tb: %s is not a trace this bench reads (nfield %0d)",
               trace, nfield);
      $finish;
    end
    has_mmu = (nfield >= 32);
    $display("core_cosim_tb: %0d instructions to compare%s", nstep,
             has_mmu ? ", with the MMU's registers" : "");

    // The first entry is the state before the first instruction, which is what
    // reset leaves behind. It is read to get the entry point and is NOT
    // compared: the data registers after a reset are not defined by anything,
    // so the two would be agreeing about nothing.
    void'($fscanf(trc, "%h", start_pc));
    for (n = 0; n < nfield; n = n + 1) void'($fscanf(trc, "%h", treg[n]));

    shown = 0;
    bad   = 1'b0;

    reset_dut();
    run_until(start_pc, 400, ok);
    if (!ok) begin
      $display("  FAIL: the core never reached the entry point %08h", start_pc);
      bad = 1'b1;
    end
    // MC68030 UM 8.1 defines what a reset leaves in VBR, CACR and the status
    // register and nothing else; USP, MSP, CAAR, SFC and DFC are whatever they
    // were. So the oracle's values at the entry point are put into the core
    // before anything runs, and from then on they are compared: the program
    // changes them or it does not, and either way both must agree.
    if (!bad) begin
      dut.u_seq.usp_q  = treg[T_USP];
      dut.u_seq.msp_q  = treg[T_MSP];
      dut.u_seq.caar_q = treg[T_CAAR];
      dut.u_seq.sfc_q  = treg[T_SFC][2:0];
      dut.u_seq.dfc_q  = treg[T_DFC][2:0];
      // UM 9.2.2: a reset clears the E bits and leaves the rest of the MMU's
      // registers as they were -- undefined at power-on, so the oracle's.
      if (has_mmu) begin
        dut.u_mmu.tc_q    = treg[T_TC];
        dut.u_mmu.crp_q   = {treg[T_CRPH], treg[T_CRPL]};
        dut.u_mmu.srp_q   = {treg[T_SRPH], treg[T_SRPL]};
        dut.u_mmu.tt0_q   = treg[T_TT0];
        dut.u_mmu.tt1_q   = treg[T_TT1];
        dut.u_mmu.mmusr_q = treg[T_MMUSR][15:0];
      end
    end

    for (k = 1; k < nstep && !bad && !stop; k = k + 1) begin
      void'($fscanf(trc, "%h", tpc));
      for (n = 0; n < nfield; n = n + 1) void'($fscanf(trc, "%h", treg[n]));

      // A long division is thirty-two clocks and a MOVEM of sixteen registers
      // is more, so the limit is generous; what it is really there for is to
      // turn a hang into a failure.
      step_one(3000, ok);
      if (!ok) begin
        $display("  FAIL: instruction %0d never retired (the core is at %08h)",
                 k - 1, dut.u_ifu.pc_d);
        bad = 1'b1;
      end

      // The oracle restarts an instruction that a bus fault interrupted --
      // RTE runs it again from its first word, so the same boundary appears
      // twice in its trace -- where the MC68030 continues it from the frame
      // (UM 8.2; doc/oracles.md). When the PCs disagree and the oracle's NEXT
      // boundary is where the core is, that boundary is the one compared.
      if (!bad && dut.u_ifu.pc_d !== tpc && k + 1 < nstep) begin
        tpos = $ftell(trc);
        void'($fscanf(trc, "%h", tpc2));
        if (tpc2 === dut.u_ifu.pc_d) begin
          tpc = tpc2;
          for (n = 0; n < nfield; n = n + 1) void'($fscanf(trc, "%h", treg[n]));
          k = k + 1;
          nrestart = nrestart + 1;
          $display("  NOTE: before instruction %0d the oracle ran the instruction at the same PC again (a restart)", k - 1);
        end else void'($fseek(trc, tpos, 0));
      end
      // And the other way: a write the core posted (doc/checkpoint.md rule 9)
      // faults after the next instruction has been decoded, so the core
      // reaches one boundary -- the instruction after the write -- that the
      // oracle, which takes the fault inside the writing instruction, does
      // not. When the PCs disagree and the core's next boundary is the
      // oracle's, that is the one compared.
      if (!bad && dut.u_ifu.pc_d !== tpc) begin
        step_one(3000, ok);
        if (ok && dut.u_ifu.pc_d === tpc) begin
          nextra = nextra + 1;
          $display("  NOTE: before instruction %0d the core passed a boundary at the instruction after a faulting posted write", k - 1);
        end else if (!ok) begin
          $display("  FAIL: instruction %0d never retired (the core is at %08h)", k - 1, dut.u_ifu.pc_d);
          bad = 1'b1;
        end
      end

      why = "";
      if (!bad && dut.u_ifu.pc_d !== tpc)
        addwhy($sformatf("the PC is %08h, UAE030 says %08h", dut.u_ifu.pc_d, tpc));
      for (n = 0; n < 8; n = n + 1)
        if (!bad && dut.u_seq.dreg[n] !== treg[n])
          addwhy($sformatf("D%0d is %08h, UAE030 says %08h",
                   n, dut.u_seq.dreg[n], treg[n]));
      for (n = 0; n < 7; n = n + 1)
        if (!bad && dut.u_seq.areg[n] !== treg[8 + n])
          addwhy($sformatf("A%0d is %08h, UAE030 says %08h",
                   n, dut.u_seq.areg[n], treg[8 + n]));
      if (!bad && dut.u_seq.usp_q !== treg[T_USP])
        addwhy($sformatf("USP is %08h, UAE030 says %08h", dut.u_seq.usp_q, treg[T_USP]));
      if (!bad && dut.u_seq.isp_q !== treg[T_ISP])
        addwhy($sformatf("ISP is %08h, UAE030 says %08h", dut.u_seq.isp_q, treg[T_ISP]));
      if (!bad && dut.u_seq.msp_q !== treg[T_MSP])
        addwhy($sformatf("MSP is %08h, UAE030 says %08h", dut.u_seq.msp_q, treg[T_MSP]));
      if (!bad && dut.u_seq.sr_q !== treg[T_SR][15:0])
        addwhy($sformatf("SR is %04h, UAE030 says %04h",
                 dut.u_seq.sr_q, treg[T_SR][15:0]));
      if (!bad && dut.u_seq.vbr_q !== treg[T_VBR])
        addwhy($sformatf("VBR is %08h, UAE030 says %08h", dut.u_seq.vbr_q, treg[T_VBR]));
      if (!bad && dut.u_seq.cacr_q !== treg[T_CACR])
        addwhy($sformatf("CACR is %08h, UAE030 says %08h", dut.u_seq.cacr_q, treg[T_CACR]));
      if (!bad && dut.u_seq.caar_q !== treg[T_CAAR])
        addwhy($sformatf("CAAR is %08h, UAE030 says %08h", dut.u_seq.caar_q, treg[T_CAAR]));
      if (!bad && {29'd0, dut.u_seq.sfc_q} !== treg[T_SFC])
        addwhy($sformatf("SFC is %0d, UAE030 says %0d", dut.u_seq.sfc_q, treg[T_SFC]));
      if (!bad && {29'd0, dut.u_seq.dfc_q} !== treg[T_DFC])
        addwhy($sformatf("DFC is %0d, UAE030 says %0d", dut.u_seq.dfc_q, treg[T_DFC]));
      // The MMU's registers, on the bits UM 9.7 says each one has: "all
      // unimplemented fields of this register are read as zeros" (TC, 9.7.2),
      // a root pointer's reserved bits are "not alterable" and bits 3-0
      // "ignored when written" (9.5.1.1, 9.7.1), and figures 9-37 and 9-38
      // draw TTx's and MMUSR's other bits as zeros. The oracle keeps whatever
      // was written (doc/oracles.md, Quirks), so the comparison is under
      // those masks -- doc/mmu.md's register table.
      if (has_mmu) begin
        if (!bad && (dut.u_mmu.tc_q & 32'h83FF_FFFF) !== (treg[T_TC] & 32'h83FF_FFFF))
          addwhy($sformatf("TC is %08h, UAE030 says %08h", dut.u_mmu.tc_q, treg[T_TC]));
        if (!bad && (dut.u_mmu.crp_q & 64'hFFFF_0003_FFFF_FFF0)
                                 !== ({treg[T_CRPH], treg[T_CRPL]} & 64'hFFFF_0003_FFFF_FFF0))
          addwhy($sformatf("CRP is %016h, UAE030 says %08h%08h", dut.u_mmu.crp_q,
                   treg[T_CRPH], treg[T_CRPL]));
        if (!bad && (dut.u_mmu.srp_q & 64'hFFFF_0003_FFFF_FFF0)
                                 !== ({treg[T_SRPH], treg[T_SRPL]} & 64'hFFFF_0003_FFFF_FFF0))
          addwhy($sformatf("SRP is %016h, UAE030 says %08h%08h", dut.u_mmu.srp_q,
                   treg[T_SRPH], treg[T_SRPL]));
        if (!bad && (dut.u_mmu.tt0_q & 32'hFFFF_8777) !== (treg[T_TT0] & 32'hFFFF_8777))
          addwhy($sformatf("TT0 is %08h, UAE030 says %08h", dut.u_mmu.tt0_q, treg[T_TT0]));
        if (!bad && (dut.u_mmu.tt1_q & 32'hFFFF_8777) !== (treg[T_TT1] & 32'hFFFF_8777))
          addwhy($sformatf("TT1 is %08h, UAE030 says %08h", dut.u_mmu.tt1_q, treg[T_TT1]));
        if (!bad && (dut.u_mmu.mmusr_q & 16'hEE47) !== (treg[T_MMUSR][15:0] & 16'hEE47))
          addwhy($sformatf("MMUSR is %04h, UAE030 says %04h", dut.u_mmu.mmusr_q,
                   treg[T_MMUSR][15:0]));
      end
      if (mbus != 0) $fdisplay(mbus, "I %0d %0h", k, tpc);

      if (!bad && why != "") begin
        $display("  FAIL: after instruction %0d (at %08h): %s", k - 1, tpc, why);
        nfail = nfail + 1;
        // +maxfail: carry on from the oracle's registers, while the program
        // counters agree -- a different PC is a different program.
        if (nfail >= maxfail || dut.u_ifu.pc_d !== tpc) bad = 1'b1;
        else begin
          for (n = 0; n < 8; n = n + 1) dut.u_seq.dreg[n] = treg[n];
          for (n = 0; n < 7; n = n + 1) dut.u_seq.areg[n] = treg[8 + n];
          // Not the stack pointers: a stack pointer differs when the two
          // build different frames (a format $0 frame against a format $2,
          // a short bus fault frame against a long one), and each side's RTE
          // takes its own frame back.
          dut.u_seq.sr_q   = treg[T_SR][15:0];
          dut.u_seq.vbr_q  = treg[T_VBR];
          dut.u_seq.cacr_q = treg[T_CACR];
          dut.u_seq.caar_q = treg[T_CAAR];
          dut.u_seq.sfc_q  = treg[T_SFC][2:0];
          dut.u_seq.dfc_q  = treg[T_DFC][2:0];
          if (has_mmu) begin
            dut.u_mmu.tc_q    = treg[T_TC];
            dut.u_mmu.crp_q   = {treg[T_CRPH], treg[T_CRPL]};
            dut.u_mmu.srp_q   = {treg[T_SRPH], treg[T_SRPL]};
            dut.u_mmu.tt0_q   = treg[T_TT0];
            dut.u_mmu.tt1_q   = treg[T_TT1];
            dut.u_mmu.mmusr_q = treg[T_MMUSR][15:0];
          end
        end
      end
      if ((k % 2000) == 0) $display("  .. %0d of %0d", k, nstep);
    end

    $fclose(trc);
    // The last instruction's write may still be posted (doc/checkpoint.md
    // rule 9): let it reach the bus before the stream is closed.
    if (mbus != 0) begin
      n = 0;
      while ((dut.u_biu.post_busy || dut.u_biu.op_active) && n < 200) begin
        @(negedge clk);
        n = n + 1;
      end
      repeat (8) @(negedge clk);
      $fclose(mbus);
    end
    if (!bad && nfail != 0) begin
      $display("core_cosim_tb: %0d instructions, %0d boundaries disagreed, %0d oracle restarts, %0d posted-write boundaries", nstep - 1, nfail, nrestart, nextra);
      bad = 1'b1;
    end
    if (!bad) begin
      $display("core_cosim_tb: %0d instructions, every register at every boundary",
               nstep - 1);
      $display("PASS: core_cosim_tb");
    end else begin
      $display("FAIL: core_cosim_tb");
    end
    $finish;
  end

  initial begin
    #8_000_000_000;
    $display("FAIL: core_cosim_tb timed out");
    $finish;
  end

endmodule
