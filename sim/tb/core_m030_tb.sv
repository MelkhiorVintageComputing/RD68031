// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the walking skeleton: real programs, on two different buses.
//
// Two whole systems side by side, each a processor and one memory:
//
//   sys_s   a 32-bit SYNCHRONOUS port that can burst -- STERM, and CBACK when
//           asked (UM 7.2.10, 7.3.7)
//   sys_a   a 16-bit ASYNCHRONOUS port with a wait state -- DSACK1 alone, so
//           every long word is two cycles (UM 7.2.1)
//
// Each runs the same image from reset to its final BRA *, and the two have to
// arrive at the same place: the same number of instructions, the same sequence
// of instruction addresses, the same registers, the same 64 KB of memory. The
// bus is the only thing that differs, and it is supposed to be invisible.
//
// The images:
//
//   m030     sim/programs/m030.S, the MC68030's instruction set where it is not
//            the MC68020's -- CALLM, RTM, the MMU instructions in both modes,
//            CpID 0 and CpID 1, CACR and CAAR. Its exception log is checked
//            against the table the program carries, entry by entry.
//   corners  sim/programs/corners.S
//   arith    sim/programs/arith.c, compiled by GCC
//
// Nothing answers CPU space but a bus error, which is how the processor finds
// out that no coprocessor is there (UM 10.5.2.8); with TB_COPROCESSOR the
// coprocessor interface is built and asks, and without it the decoder does not
// ask. Either way a CpID 1 instruction is an F-line exception.

`timescale 1ns / 1ps

// ----------------------------------------------------------------------------
// One system.
// ----------------------------------------------------------------------------
module core_m030_sys #(
    parameter int PORT_BYTES = 4,
    parameter bit SYNC       = 1'b0,
    parameter bit BURST      = 1'b0,
    parameter int WAITS      = 0,
    parameter bit CP         = 1'b0,
    parameter int ICACHE     = 64
) (
    input logic clk,
    input logic rst_n
);

  logic  [2:0] fc_o;
  logic        fc_oe;
  logic [31:0] a_o;
  logic        a_oe;
  logic [31:0] d_o;
  logic        d_oe;
  logic  [1:0] siz_o;
  logic        siz_oe;
  logic        ecs_n_o, ocs_n_o;
  logic        rw_o, rw_oe;
  logic        rmc_n_o, rmc_oe;
  logic        as_n_o, as_oe;
  logic        ds_n_o, ds_oe;
  logic        dben_n_o, dben_oe;
  logic  [1:0] dsack_n;
  logic        sterm_n, cback_n, ciin_n;
  logic        ciout_n_o, ciout_oe;
  logic        cbreq_n_o, cbreq_oe;
  logic        refill_n_o, status_n_o;
  logic        ipend_n_o, bg_n_o;
  logic        reset_n_o, reset_n_oe;
  logic        berr_n;

  wire [31:0] dbus;
  wire [31:0] d_mem;
  logic       oe_mem;
  assign dbus = d_oe   ? d_o   : 32'bz;
  assign dbus = oe_mem ? d_mem : 32'bz;

  rd68031_top #(.ICACHE_ENTRIES (ICACHE), .COPROCESSOR (CP)) dut (
      .clk (clk), .rst_n (rst_n),
      .fc_o (fc_o), .fc_oe (fc_oe),
      .a_o (a_o), .a_oe (a_oe),
      .d_i (dbus), .d_o (d_o), .d_oe (d_oe),
      .siz_o (siz_o), .siz_oe (siz_oe),
      .ecs_n_o (ecs_n_o), .ocs_n_o (ocs_n_o),
      .rw_o (rw_o), .rw_oe (rw_oe),
      .rmc_n_o (rmc_n_o), .rmc_oe (rmc_oe),
      .as_n_o (as_n_o), .as_oe (as_oe),
      .ds_n_o (ds_n_o), .ds_oe (ds_oe),
      .dben_n_o (dben_n_o), .dben_oe (dben_oe),
      .dsack_n_i (dsack_n), .sterm_n_i (sterm_n),
      .ciin_n_i (ciin_n), .ciout_n_o (ciout_n_o), .ciout_oe (ciout_oe),
      .cbreq_n_o (cbreq_n_o), .cbreq_oe (cbreq_oe), .cback_n_i (cback_n),
      .ipl_n_i (3'b111), .ipend_n_o (ipend_n_o), .avec_n_i (1'b1),
      .br_n_i (1'b1), .bg_n_o (bg_n_o), .bgack_n_i (1'b1),
      .berr_n_i (berr_n),
      .reset_n_i (1'b1), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
      .halt_n_i (1'b1),
      .cdis_n_i (1'b1), .mmudis_n_i (1'b1),
      .refill_n_o (refill_n_o), .status_n_o (status_n_o));

  rd68031_slave #(.PORT_BYTES (PORT_BYTES), .WAITS (WAITS), .SYNC (SYNC),
                  .BURST (BURST), .BASE (32'h0000_0000), .MASK (32'hF000_0000),
                  .ABITS (16)) mem (
      .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
      .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .cbreq_n_i (cbreq_n_o),
      .d_i (dbus), .wr_inhibit_i (1'b0),
      .d_o (d_mem), .d_oe (oe_mem), .dsack_n_o (dsack_n), .sterm_n_o (sterm_n),
      .cback_n_o (cback_n), .ciin_n_o (ciin_n));

  // CPU space, function code 111: no coprocessor, no breakpoint device, and no
  // interrupt is ever raised. A coprocessor access ends in a bus error, which
  // is the answer UM 10.5.2.8 expects when the coprocessor is not there.
  assign berr_n = !(rst_n && as_oe && !as_n_o && (fc_o == 3'b111));

  // --------------------------------------------------------------------------
  // What the run did. A boundary is the retirement of a microword that
  // decodes, which is what ends an instruction; stage D still holds that
  // instruction then, so pc_d is its address.
  // --------------------------------------------------------------------------
  wire seq_is_decode =
      (dut.u_seq.uw[rd68031_ucode_pkg::U_SEQ_LSB +: rd68031_ucode_pkg::U_SEQ_W]
       == rd68031_ucode_pkg::U_SEQ_DECODE);
  wire boundary = dut.u_seq.retire && seq_is_decode && !dut.u_seq.fault_now;

  int unsigned      insns;        // instructions retired
  logic [31:0]      path;         // a hash of their addresses, in order
  longint unsigned  clocks;       // from reset to the end
  int unsigned      cycles_sterm, cycles_dsack, cycles_berr, cbreqs;
  // Coprocessor interface cycles -- CPU space type 2 (UM figure 10-3) --
  // and the ones of them addressed to CpID 0, which UM 10.1 says the MC68030
  // never runs.
  int unsigned      cycles_cp, cycles_cp0;
  int unsigned      spins;        // consecutive BRA * at the same address
  logic [31:0]      last_pc;
  bit               done;
  // The writes the program made, in program order: hashed as the sequencer
  // hands each operand to the bus unit, which is the order the program wrote
  // them in whatever the bus did with them after.
  logic [31:0]      wpath;
  int unsigned      writes;

  bit trace;
  initial trace = $test$plusargs("trace");

  task automatic clear();
    insns = 0; path = 32'h811C_9DC5; clocks = 0; spins = 0; last_pc = 32'hFFFF_FFFF;
    cycles_sterm = 0; cycles_dsack = 0; cycles_berr = 0; cbreqs = 0; done = 1'b0;
    cycles_cp = 0; cycles_cp0 = 0;
    wpath = 32'h811C_9DC5; writes = 0;
  endtask

  wire seq_is_write =
      (dut.u_seq.uw[rd68031_ucode_pkg::U_BUS_LSB +: rd68031_ucode_pkg::U_BUS_W]
       == rd68031_ucode_pkg::U_BUS_WRITE);
  initial clear();

  always @(negedge clk) begin
    #(7.5);
    if (rst_n && !done) begin
      clocks = clocks + 1;
      if (dut.u_seq.retire && seq_is_write && !dut.u_seq.fault_now) begin
        writes = writes + 1;
        wpath  = (wpath ^ dut.u_seq.req_addr) * 32'h0100_0193;
        wpath  = (wpath ^ dut.u_seq.req_wdata[31:0]) * 32'h0100_0193;
        wpath  = (wpath ^ {21'd0, dut.u_seq.req_wdata[39:32], dut.u_seq.req_bytes})
                 * 32'h0100_0193;
      end
      if (boundary) begin
        insns = insns + 1;
        path  = (path ^ dut.u_ifu.pc_d) * 32'h0100_0193;
        // A branch to itself is how every one of these programs stops: a BRA
        // at the same address, again and again. Any BRA, not just $60FE --
        // the assembler writes `bra _done` with a word displacement, $6000
        // $FFFE, because the label is global.
        if (dut.u_ifu.pc_d == last_pc && dut.u_ifu.d_q[15:8] == 8'h60)
          spins = spins + 1;
        else
          spins = 0;
        last_pc = dut.u_ifu.pc_d;
        if (spins >= 4) done = 1'b1;
        if (trace && insns < 400)
          $display("%m %0d %08h %04h sr=%04h", insns, dut.u_ifu.pc_d, dut.u_ifu.d_q,
                   dut.u_seq.sr_q);
      end
    end
  end

  // How each bus cycle ended, counted once per cycle at the edge that ends it.
  logic as_q;
  always @(posedge clk) begin
    if (rst_n && !done) begin
      if (!sterm_n && !as_n_o)        cycles_sterm = cycles_sterm + 1;
      if (cbreq_oe && !cbreq_n_o && !as_n_o && !as_q) cbreqs = cbreqs + 1;
    end
    as_q = !as_n_o;
  end
  always @(posedge as_n_o) begin
    if (rst_n && !done) begin
      if (fc_o == 3'b111 && a_o[19:16] == 4'h2) begin
        cycles_cp = cycles_cp + 1;
        if (a_o[15:13] == 3'd0) cycles_cp0 = cycles_cp0 + 1;
      end
      if (!berr_n)               cycles_berr  = cycles_berr + 1;
      else if (dsack_n != 2'b11) cycles_dsack = cycles_dsack + 1;
    end
  end

endmodule


// ----------------------------------------------------------------------------
// The testbench.
// ----------------------------------------------------------------------------
module core_m030_tb;

  localparam real CLK_PERIOD = 60.0;

`ifndef TB_ICACHE_ENTRIES
`define TB_ICACHE_ENTRIES 64
`endif
`ifdef TB_COPROCESSOR
  localparam bit TB_CP = 1'b1;
`else
  localparam bit TB_CP = 1'b0;
`endif

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2.0) clk = ~clk;
  end

  core_m030_sys #(.PORT_BYTES (4), .SYNC (1'b1), .BURST (1'b1), .WAITS (0),
                  .CP (TB_CP), .ICACHE (`TB_ICACHE_ENTRIES))
      sys_s (.clk (clk), .rst_n (rst_n));
  core_m030_sys #(.PORT_BYTES (2), .SYNC (1'b0), .BURST (1'b0), .WAITS (1),
                  .CP (TB_CP), .ICACHE (`TB_ICACHE_ENTRIES))
      sys_a (.clk (clk), .rst_n (rst_n));

  int unsigned fails;
  int unsigned checks;
  initial begin
    fails  = 0;
    checks = 0;
  end

  task automatic check(input bit ok, input string what);
    checks = checks + 1;
    if (!ok) begin
      fails = fails + 1;
      $display("  FAIL: %s", what);
    end
  endtask

  // Memory, as the program sees it: sys_s's port is 32 bits wide and sys_a's
  // 16, but both models keep bytes at their own addresses.
  function automatic logic [15:0] peek_w(input logic [31:0] a);
    peek_w = {sys_s.mem.mem[a[15:0]], sys_s.mem.mem[a[15:0] + 1]};
  endfunction
  function automatic logic [31:0] peek_l(input logic [31:0] a);
    peek_l = {peek_w(a), peek_w(a + 2)};
  endfunction

  // Reset released on a falling edge -- rd68031_core_harness.svh says why.
  task automatic reset_both();
    rst_n = 1'b0;
    sys_s.clear();
    sys_a.clear();
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  endtask

  task automatic load(input string image);
    int unsigned n;
    for (n = 0; n < 65536; n = n + 1) begin
      sys_s.mem.mem[n] = 8'h00;
      sys_a.mem.mem[n] = 8'h00;
    end
    $readmemh(image, sys_s.mem.mem);
    $readmemh(image, sys_a.mem.mem);
  endtask

  // Run both until each has stopped on its BRA *, then hold them to each other.
  task automatic run_and_compare(input string name, input string image,
                                 input longint unsigned limit);
    longint unsigned n;
    int unsigned k;
    int unsigned diffs;
    load(image);
    reset_both();
    n = 0;
    while (!(sys_s.done && sys_a.done) && n < limit) begin
      @(negedge clk);
      n = n + 1;
    end
    check(sys_s.done, {name, ": the synchronous system reaches its BRA *"});
    check(sys_a.done, {name, ": the asynchronous system reaches its BRA *"});
    check(sys_s.insns == sys_a.insns,
          $sformatf("%s: the same number of instructions (%0d, %0d)",
                    name, sys_s.insns, sys_a.insns));
    check(sys_s.path == sys_a.path,
          {name, ": the same instruction addresses, in the same order"});
    check(sys_s.writes == sys_a.writes && sys_s.wpath == sys_a.wpath,
          $sformatf("%s: the same writes, in the same order (%0d, %0d)",
                    name, sys_s.writes, sys_a.writes));
    check(sys_s.dut.u_ifu.pc_d == sys_a.dut.u_ifu.pc_d,
          {name, ": stopped at the same place"});
    for (k = 0; k < 8; k = k + 1)
      check(sys_s.dut.u_seq.dreg[k] === sys_a.dut.u_seq.dreg[k],
            $sformatf("%s: D%0d %08h, %08h", name, k,
                      sys_s.dut.u_seq.dreg[k], sys_a.dut.u_seq.dreg[k]));
    for (k = 0; k < 7; k = k + 1)
      check(sys_s.dut.u_seq.areg[k] === sys_a.dut.u_seq.areg[k],
            $sformatf("%s: A%0d %08h, %08h", name, k,
                      sys_s.dut.u_seq.areg[k], sys_a.dut.u_seq.areg[k]));
    check(sys_s.dut.u_seq.usp_q  === sys_a.dut.u_seq.usp_q,  {name, ": USP"});
    check(sys_s.dut.u_seq.isp_q  === sys_a.dut.u_seq.isp_q,  {name, ": ISP"});
    check(sys_s.dut.u_seq.msp_q  === sys_a.dut.u_seq.msp_q,  {name, ": MSP"});
    check(sys_s.dut.u_seq.sr_q   === sys_a.dut.u_seq.sr_q,   {name, ": SR"});
    check(sys_s.dut.u_seq.cacr_q === sys_a.dut.u_seq.cacr_q, {name, ": CACR"});
    check(sys_s.dut.u_seq.caar_q === sys_a.dut.u_seq.caar_q, {name, ": CAAR"});
    // The last posted write has long finished: each has spun four times.
    diffs = 0;
    for (k = 0; k < 65536; k = k + 1)
      if (sys_s.mem.mem[k] !== sys_a.mem.mem[k]) diffs = diffs + 1;
    check(diffs == 0, $sformatf("%s: the same memory (%0d bytes differ)", name, diffs));
    // Each bus was the one it was built to be.
    check(sys_s.cycles_sterm > 0 && sys_s.cycles_dsack == 0,
          {name, ": the synchronous system's cycles all ended with STERM"});
    check(sys_a.cycles_sterm == 0 && sys_a.cycles_dsack > 0,
          {name, ": the asynchronous system's cycles all ended with DSACK"});
    $display("core_m030_tb: %s -- %0d instructions, %0d writes; synchronous %0d clocks, %0d STERM cycles, %0d burst requests; asynchronous 16-bit %0d clocks, %0d DSACK cycles",
             name, sys_s.insns, sys_s.writes, sys_s.clocks, sys_s.cycles_sterm,
             sys_s.cbreqs, sys_a.clocks, sys_a.cycles_dsack);
  endtask

  string image_m030, image_corners, image_arith;

  initial begin
    int unsigned k, nexp, nlog;
    logic [31:0] exp_at, log_at, res_at;
    logic [15:0] want_fv, want_s, got_fv, got_sr;
    logic [31:0] want_pc, got_pc;

    if (!$value$plusargs("m030=%s", image_m030))
      image_m030 = "build/programs/m030.hex";
    if (!$value$plusargs("corners=%s", image_corners))
      image_corners = "build/programs/corners.hex";
    if (!$value$plusargs("arith=%s", image_arith))
      image_arith = "build/programs/arith.hex";

    $display("core_m030_tb: the MC68030 smoke program and two real programs, synchronous against asynchronous");
    rst_n = 1'b0;

    // ========================================================================
    // m030.S, and what it logged.
    // ========================================================================
    if (!$test$plusargs("skip_m030")) run_and_compare("m030", image_m030, 200_000);

    exp_at = peek_l(32'h0400);
    nexp   = peek_l(32'h0404);
    log_at = peek_l(32'h0408);
    res_at = peek_l(32'h040C);
    nlog   = (peek_l(32'h8000) - log_at) / 8;
    check(nexp == 30, $sformatf("m030: the program expects thirty exceptions (%0d)", nexp));
    check(nlog == nexp, $sformatf("m030: %0d exceptions taken, %0d expected", nlog, nexp));
    for (k = 0; k < nexp && k < nlog; k = k + 1) begin
      want_fv = peek_w(exp_at + 8*k);
      want_s  = peek_w(exp_at + 8*k + 2);
      want_pc = peek_l(exp_at + 8*k + 4);
      got_fv  = peek_w(log_at + 8*k);
      got_sr  = peek_w(log_at + 8*k + 2);
      got_pc  = peek_l(log_at + 8*k + 4);
      check(got_fv === want_fv,
            $sformatf("m030 exception %0d at %08h: format/vector %04h, UM section 8 says %04h",
                      k, want_pc, got_fv, want_fv));
      check(got_pc === want_pc,
            $sformatf("m030 exception %0d: stacked PC %08h, the instruction is at %08h",
                      k, got_pc, want_pc));
      check((got_sr & 16'h2000) === want_s,
            $sformatf("m030 exception %0d at %08h: stacked SR %04h, from %s mode",
                      k, want_pc, got_sr, (want_s != 0) ? "supervisor" : "user"));
    end
    // UM figure 6-14 and 6.3.2.
    check(peek_l(res_at + 32'h00) === 32'h0000_3313,
          $sformatf("m030: CACR written all ones reads $3313 (%08h)", peek_l(res_at)));
    check(peek_l(res_at + 32'h04) === 32'h0000_2211,
          $sformatf("m030: CACR written $2A15 reads $2211, CD and CEI as zero (%08h)",
                    peek_l(res_at + 4)));
    check(peek_l(res_at + 32'h08) === 32'h0000_0000, "m030: CACR written zero reads zero");
    check(peek_l(res_at + 32'h0C) === 32'hFFFF_FFFF, "m030: CAAR keeps all 32 bits");
    check(peek_l(res_at + 32'h10) === 32'h1234_5678, "m030: CAAR reads back what was written");
    check(peek_l(res_at + 32'h14) === 32'h0000_F000, "m030: MOVEC ISP is the stack");
    check(sys_s.dut.u_seq.dreg[6] === 32'h0000_005A,
          "m030: the program reached its end");
    check(sys_s.dut.u_seq.sr_q[13] === 1'b0, "m030: ... in user mode");
    check(sys_s.dut.u_seq.cacr_q === 32'h0000_0001,
          "m030: CACR is EI again, as the program left it");
    // UM 10.1: "The MC68030 never generates coprocessor interface bus cycles
    // with the CpID equal to zero." With the interface built, the two CpID 1
    // instructions each make the one access that finds nobody there; without
    // it, there are none at all.
    check(sys_s.cycles_cp0 == 0 && sys_a.cycles_cp0 == 0,
          "m030: no coprocessor interface cycle to CpID 0");
    check(sys_s.cycles_cp == (TB_CP ? 2 : 0) && sys_a.cycles_cp == (TB_CP ? 2 : 0),
          $sformatf("m030: %0d coprocessor interface cycles, for the two CpID 1 instructions (%0d, %0d)",
                    TB_CP ? 2 : 0, sys_s.cycles_cp, sys_a.cycles_cp));

    // ========================================================================
    // Two real programs.
    // ========================================================================
    if (!$test$plusargs("only_m030")) begin
      run_and_compare("corners", image_corners, 400_000);
      run_and_compare("arith", image_arith, 1_000_000);
    end

    $display("core_m030_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("PASS: core_m030_tb");
    else            $display("FAIL: core_m030_tb");
    $finish;
  end

endmodule
