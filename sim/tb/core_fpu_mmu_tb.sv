// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the core with RD68884 as its MC68881, as MAME's Sun-3/80 has it
// (sim/mame/rd68031_fpu.sv), running sim/programs/fpu_mmu.S: coprocessor
// memory operands through the MMU, page faults on each of their long words,
// and the FPU's context switched in the fault handler. The program checks its
// own results against the same operations unfaulted; this loads it, runs it
// and prints what it found.
//
// A 64 KB 32-bit asynchronous port at $0000_0000 (repeated), as the core
// harness's; no bus errors from outside: every fault is the MMU's. With
// +timer, a level 5 interrupt at random intervals, autovectored -- for
// sim/programs/fpu_sched.S (+image=build/programs/fpu_sched.hex), whose
// scheduler it drives.

`timescale 1ns / 1ps

module core_fpu_mmu_tb;

  localparam real CLK_PERIOD = 10.0;
  localparam logic [31:0] A_NCHK  = 32'h0000_8004;
  localparam logic [31:0] A_NFAIL = 32'h0000_8008;
  localparam logic [31:0] A_LOGP  = 32'h0000_800C;
  localparam logic [31:0] A_DONE  = 32'h0000_8010;
  localparam logic [31:0] A_NEXC  = 32'h0000_8018;
  localparam logic [31:0] A_LASTV = 32'h0000_801C;
  localparam logic [31:0] A_NBERR = 32'h0000_8020;
  localparam logic [31:0] A_NCHKX = 32'h0000_8058;
  localparam logic [31:0] A_NBUSY = 32'h0000_8070;
  localparam logic [31:0] A_NFS   = 32'h0000_8074;
  localparam logic [31:0] A_NIDLE = 32'h0000_8084;
  localparam logic [31:0] A_NNULL = 32'h0000_8088;
  localparam logic [31:0] A_CACRV = 32'h0000_808C;
  localparam logic [31:0] A_LOG   = 32'h0000_8100;

  logic        clk, rst_n;
  logic  [2:0] fc_o;
  logic        fc_oe;
  logic [31:0] a_o, d_o, d_i;
  logic        a_oe, d_oe;
  logic  [1:0] siz_o;
  logic        siz_oe, ecs_n_o, ocs_n_o, rw_o, rw_oe, rmc_n_o, rmc_oe;
  logic        as_n_o, as_oe, ds_n_o, ds_oe, dben_n_o, dben_oe;
  logic  [1:0] dsack_n;
  logic        sterm_n, ciin_n, cback_n;
  logic        ciout_n_o, ciout_oe, cbreq_n_o, cbreq_oe, ipend_n_o, bg_n_o;
  logic        reset_n_o, reset_n_oe, refill_n_o, status_n_o, fpu_cs;
  wire  [31:0] s_d;
  wire         s_oe;

  rd68031_fpu dut (
      .clk (clk), .rst_n (rst_n),
      .fc_o (fc_o), .fc_oe (fc_oe), .a_o (a_o), .a_oe (a_oe),
      .d_i (d_i), .d_o (d_o), .d_oe (d_oe),
      .siz_o (siz_o), .siz_oe (siz_oe),
      .ecs_n_o (ecs_n_o), .ocs_n_o (ocs_n_o),
      .rw_o (rw_o), .rw_oe (rw_oe), .rmc_n_o (rmc_n_o), .rmc_oe (rmc_oe),
      .as_n_o (as_n_o), .as_oe (as_oe), .ds_n_o (ds_n_o), .ds_oe (ds_oe),
      .dben_n_o (dben_n_o), .dben_oe (dben_oe),
      .dsack_n_i (dsack_n), .sterm_n_i (sterm_n), .ciin_n_i (ciin_n),
      .ciout_n_o (ciout_n_o), .ciout_oe (ciout_oe),
      .cbreq_n_o (cbreq_n_o), .cbreq_oe (cbreq_oe), .cback_n_i (cback_n),
      .ipl_n_i (irq ? 3'b010 : 3'b111), .ipend_n_o (ipend_n_o), .avec_n_i (!iack),
      .br_n_i (1'b1), .bg_n_o (bg_n_o), .bgack_n_i (1'b1),
      .berr_n_i (1'b1),
      .reset_n_i (!(reset_n_oe && !reset_n_o)), .reset_n_o (reset_n_o),
      .reset_n_oe (reset_n_oe),
      .halt_n_i (1'b1), .cdis_n_i (1'b1), .mmudis_n_i (1'b1),
      .refill_n_o (refill_n_o), .status_n_o (status_n_o), .fpu_cs (fpu_cs));

  // Memory answers everything but the FPU's interface registers.
  rd68031_slave #(.PORT_BYTES (4), .WAITS (0), .BASE (32'h0000_0000),
                  .MASK (32'hF000_0000), .ABITS (16)) s32 (
      .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
      .as_n_i (as_n_o | (fc_o == 3'd7)), .ds_n_i (ds_n_o), .rw_i (rw_o),
      .cbreq_n_i (cbreq_n_o), .d_i (d_o), .wr_inhibit_i (1'b0),
      .d_o (s_d), .d_oe (s_oe), .dsack_n_o (dsack_n), .sterm_n_o (sterm_n),
      .cback_n_o (cback_n), .ciin_n_o (ciin_n));
  assign d_i = s_oe ? s_d : 32'd0;

  // The timer: a request at level 5 between tbase and tbase + tmask clocks
  // after the last one was acknowledged (200 and 2,247 unless +tbase= and
  // +tmask= say otherwise), the acknowledge answered with AVEC.
  logic        timer_en, irq;
  logic [15:0] lfsr, seed;
  int unsigned tcount, nirq, tbase, tmask;
  wire iack = as_oe && !as_n_o && fc_o == 3'd7 && a_o[19:16] == 4'hF;
  always @(posedge clk) begin
    if (!rst_n || !timer_en) begin
      irq <= 1'b0;
      tcount <= 1000;
      lfsr <= seed;
      nirq <= 0;
    end else if (iack) begin
      if (irq) nirq <= nirq + 1;
      irq <= 1'b0;
      tcount <= tbase + (lfsr & tmask);
      lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end else if (!irq) begin
      if (tcount == 0) irq <= 1'b1;
      else tcount <= tcount - 1;
    end
  end

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2.0) clk = ~clk;
  end

  int unsigned fails, checks;
  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      fails++;
      $display("  FAIL: %s", what);
    end
  endtask

  function automatic logic [31:0] peek_l(input logic [31:0] a);
    return {s32.mem[a[15:0]], s32.mem[a[15:0] + 16'd1], s32.mem[a[15:0] + 16'd2],
            s32.mem[a[15:0] + 16'd3]};
  endfunction
  function automatic logic [15:0] peek_w(input logic [31:0] a);
    return {s32.mem[a[15:0]], s32.mem[a[15:0] + 16'd1]};
  endfunction

  string image;
  int n, i, nlog, limit;
  logic [31:0] cacr;
  logic [15:0] id;

  initial begin
    fails = 0;
    checks = 0;
    if (!$value$plusargs("image=%s", image)) image = "build/programs/fpu_mmu.hex";
    if (!$value$plusargs("limit=%d", limit)) limit = 2_000_000;
    timer_en = $test$plusargs("timer");
    // +seed=<hex>: the timer's intervals; +waits=<n>: the memory's wait states.
    if (!$value$plusargs("seed=%h", seed)) seed = 16'hACE1;
    if ($value$plusargs("waits=%d", i)) s32.waits_rt = i;
    if (!$value$plusargs("tbase=%d", tbase)) tbase = 200;
    if (!$value$plusargs("tmask=%h", tmask)) tmask = 32'h7FF;
    for (n = 0; n < 65536; n = n + 1) s32.mem[n] = 8'h00;
    $readmemh(image, s32.mem);
    // +cacr=<hex>: the CACR the program runs with (0, the caches off).
    if (!$value$plusargs("cacr=%h", cacr)) cacr = 32'd0;
    for (i = 0; i < 4; i = i + 1) s32.mem[A_CACRV[15:0] + i] = cacr[31 - 8*i -: 8];
    rst_n = 1'b0;
    repeat (8) @(negedge clk);
    rst_n = 1'b1;
    n = 0;
    while (peek_l(A_DONE) != 32'h600D_D00E && !dut.u_cpu.u_seq.dbf_q && n < limit) begin
      @(negedge clk);
      n = n + 1;
    end
    repeat (16) @(negedge clk);
    check(!dut.u_cpu.u_seq.dbf_q, "no double bus fault");
    check(peek_l(A_DONE) == 32'h600D_D00E, $sformatf("fpu_mmu: finished cleanly (%0d clocks)", n));
    check(peek_l(A_NEXC) == 0, $sformatf("fpu_mmu: %0d unexpected exceptions, the last format/vector %04h",
                                         peek_l(A_NEXC), peek_l(A_LASTV)));
    nlog = (peek_l(A_LOGP) - A_LOG) / 10;
    check(peek_l(A_NFAIL) == 0, $sformatf("fpu_mmu: %0d of %0d checks failed",
                                          peek_l(A_NFAIL), peek_l(A_NCHK)));
    for (i = 0; i < nlog && i < 64; i = i + 1) begin
      id = peek_w(A_LOG + 10*i);
      $display("  FAIL: fpu_mmu check %0d: %08h, want %08h", id,
               peek_l(A_LOG + 10*i + 2), peek_l(A_LOG + 10*i + 6));
    end
    check(peek_l(A_NCHK) == peek_l(A_NCHKX), $sformatf("fpu_mmu: %0d checks made of the %0d written",
                                                       peek_l(A_NCHK), peek_l(A_NCHKX)));
    $display("core_fpu_mmu_tb: %0d bus errors; the switches saved %0d frames: %0d busy, %0d idle, %0d null",
             peek_l(A_NBERR), peek_l(A_NFS), peek_l(A_NBUSY), peek_l(A_NIDLE), peek_l(A_NNULL));
    if (timer_en)
      $display("core_fpu_mmu_tb: %0d interrupts, %0d of them in the middle of an instruction (format $9); task iterations %0d and %0d",
               nirq, peek_l(32'h0000_8090), peek_l(32'h0000_C300), peek_l(32'h0000_C340));
    if (fails == 0) $display("PASS: core_fpu_mmu_tb, %0d self-checks, %0d clocks, CACR %08h", peek_l(A_NCHK), n, cacr);
    else            $display("FAIL: core_fpu_mmu_tb, %0d of %0d checks failed", fails, checks);
    $finish;
  end

endmodule
