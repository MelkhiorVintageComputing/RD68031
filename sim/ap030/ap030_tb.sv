// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- AP68030 on this project's slave models, for make ap030.
//
// AP68030 (Inputs/ref/AP68030, a third party's GPL-2 Verilog MC68030) is
// instantiated through its top-level ports and nothing else; its own program
// bench is not used. Around it is the memory map of
// sim/tb/rd68031_core_harness.svh, built from the same slave model
// (sim/models/rd68031_slave.sv) with the same parameters:
//
//   $0xxx_xxxx  32-bit, asynchronous, no wait states (64 KB, repeated)
//   $1xxx_xxxx  16-bit, asynchronous
//   $2xxx_xxxx   8-bit, asynchronous
//   $3xxx_xxxx  32-bit, synchronous, burst
//   $4xxx_xxxx  every cycle answered with BERR
//
// and the transfers go through the same monitor (sim/models/rd68031_busmon.sv)
// as sim/tb/core_pins_tb.sv's. tools/bus_diff.py pins compares the two files.
//
// The M0 spike drove AP68030 through its own bench, whose map decodes 24
// address bits and puts its ports elsewhere; a bench of our own gives both
// processors identical memory and port behaviour, which is what a pin-level
// comparison needs, and runs our programs unchanged.
//
//   +image=<hex>   the program, read into the 32-bit port from $0
//   +pins=<file>   where the transfers go
//
// The run ends a few clocks after the program writes 99 to $8000, or at a
// time limit. Interrupts, BR/BGACK, CDIS and MMUDIS are held inactive.

`timescale 1ns / 1ps

module ap030_tb;

  localparam real CLK_PERIOD = 60.0;

  logic clk;
  logic reset_n;

  wire [31:0] a, d_o;
  wire  [2:0] fc;
  wire  [1:0] siz;
  wire        rw, rmc_n, as_n, ds_n, dben_n, ecs_n, ocs_n, ciout_n, cbreq_n, bus_oe, d_oe;
  wire        bg_n, ipend_n, reset_n_oe, refill_n, status_n, dbg_halted, dbg_inst;
  wire [31:0] dbg_pc;
  wire [15:0] dbg_sr;
  wire  [7:0] dbg_state;

  wire  [1:0] dsack_n;
  wire        sterm_n, cback_n, ciin_n, berr_n;
  wire [31:0] dbus;

  ap030_top dut (
      .clk (clk),
      .a (a), .fc (fc), .siz (siz), .rw (rw), .rmc_n (rmc_n), .as_n (as_n), .ds_n (ds_n),
      .dben_n (dben_n), .ecs_n (ecs_n), .ocs_n (ocs_n), .ciout_n (ciout_n),
      .cbreq_n (cbreq_n), .bus_oe (bus_oe), .d_o (d_o), .d_oe (d_oe), .d_i (dbus),
      .dsack0_n (dsack_n[0]), .dsack1_n (dsack_n[1]), .sterm_n (sterm_n),
      .berr_n (berr_n), .halt_n (1'b1), .avec_n (1'b1), .ciin_n (ciin_n),
      .cback_n (cback_n), .br_n (1'b1), .bg_n (bg_n), .bgack_n (1'b1),
      .ipl_n (3'b111), .ipend_n (ipend_n),
      .reset_n_i (reset_n), .reset_n_oe (reset_n_oe),
      .cdis_n (1'b1), .mmudis_n (1'b1), .refill_n (refill_n), .status_n (status_n),
      .fast_req (), .fast_addr (), .fast_fc (), .fast_rw (), .fast_ci (), .fast_burst (),
      .fast_be (), .fast_wdata (), .fast_match (1'b0), .fast_ready (1'b0),
      .fast_valid (1'b0), .fast_last (1'b0), .fast_word (2'b00), .fast_rdata (32'd0),
      .dbg_pc (dbg_pc), .dbg_sr (dbg_sr), .dbg_state (dbg_state), .dbg_inst (dbg_inst),
      .dbg_halted (dbg_halted), .dbg_vbr (), .dbg_cacr (), .dbg_cache_clear (),
      .snoop_we (1'b0), .snoop_addr (32'd0), .nmi_vec_nocache (1'b0));

  // The pins as a board sees them: nothing driven while the processor has
  // let go of the bus.
  wire        as_q  = as_n | ~bus_oe;
  wire        ds_q  = ds_n | ~bus_oe;

  wire [1:0] dsack32, dsack16, dsack8, dsackb;
  wire [31:0] d32, d16, d8, db;
  wire       oe32, oe16, oe8, oeb;
  wire       sterm32, sterm16, sterm8, stermb;
  wire       cback32, cback16, cback8, cbackb;
  wire       ciin32, ciin16, ciin8, ciinb;

  assign dsack_n = dsack32 & dsack16 & dsack8 & dsackb;
  assign sterm_n = sterm32 & sterm16 & sterm8 & stermb;
  assign cback_n = cback32 & cback16 & cback8 & cbackb;
  assign ciin_n  = ciin32 & ciin16 & ciin8 & ciinb;
  assign dbus = d_oe ? d_o : oe32 ? d32 : oe16 ? d16 : oe8 ? d8 : oeb ? db : 32'd0;
  assign berr_n = ~(reset_n && !as_q && a[31:28] == 4'h4);

  rd68031_slave #(.PORT_BYTES (4), .WAITS (0), .BASE (32'h0000_0000),
                  .MASK (32'hF000_0000), .ABITS (16)) s32 (
      .clk (clk), .rst_n (reset_n), .a_i (a), .siz_i (siz), .fc_i (fc),
      .as_n_i (as_q), .ds_n_i (ds_q), .rw_i (rw), .cbreq_n_i (cbreq_n),
      .d_i (dbus), .wr_inhibit_i (1'b0),
      .d_o (d32), .d_oe (oe32), .dsack_n_o (dsack32), .sterm_n_o (sterm32),
      .cback_n_o (cback32), .ciin_n_o (ciin32));
  rd68031_slave #(.PORT_BYTES (2), .WAITS (0), .BASE (32'h1000_0000),
                  .MASK (32'hF000_0000), .ABITS (16)) s16 (
      .clk (clk), .rst_n (reset_n), .a_i (a), .siz_i (siz), .fc_i (fc),
      .as_n_i (as_q), .ds_n_i (ds_q), .rw_i (rw), .cbreq_n_i (cbreq_n),
      .d_i (dbus), .wr_inhibit_i (1'b0),
      .d_o (d16), .d_oe (oe16), .dsack_n_o (dsack16), .sterm_n_o (sterm16),
      .cback_n_o (cback16), .ciin_n_o (ciin16));
  rd68031_slave #(.PORT_BYTES (1), .WAITS (0), .BASE (32'h2000_0000),
                  .MASK (32'hF000_0000), .ABITS (16)) s8 (
      .clk (clk), .rst_n (reset_n), .a_i (a), .siz_i (siz), .fc_i (fc),
      .as_n_i (as_q), .ds_n_i (ds_q), .rw_i (rw), .cbreq_n_i (cbreq_n),
      .d_i (dbus), .wr_inhibit_i (1'b0),
      .d_o (d8), .d_oe (oe8), .dsack_n_o (dsack8), .sterm_n_o (sterm8),
      .cback_n_o (cback8), .ciin_n_o (ciin8));
  rd68031_slave #(.PORT_BYTES (4), .WAITS (0), .SYNC (1'b1), .BURST (1'b1),
                  .BASE (32'h3000_0000), .MASK (32'hF000_0000), .ABITS (16)) sB (
      .clk (clk), .rst_n (reset_n), .a_i (a), .siz_i (siz), .fc_i (fc),
      .as_n_i (as_q), .ds_n_i (ds_q), .rw_i (rw), .cbreq_n_i (cbreq_n),
      .d_i (dbus), .wr_inhibit_i (1'b0),
      .d_o (db), .d_oe (oeb), .dsack_n_o (dsackb), .sterm_n_o (stermb),
      .cback_n_o (cbackb), .ciin_n_o (ciinb));

  rd68031_busmon mon (
      .clk (clk), .rst_n (reset_n), .as_n (as_q), .rw (rw), .a (a), .fc (fc),
      .siz (siz), .d (dbus), .dsack_n (dsack_n), .sterm_n (sterm_n), .berr_n (berr_n),
      .halt_n (1'b1), .avec_n (1'b1), .ciin_n (ciin_n), .cbreq_n (cbreq_n | ~bus_oe),
      .cback_n (cback_n), .ciout_n (ciout_n | ~bus_oe), .rmc_n (rmc_n | ~bus_oe));

  // +status=<file>: every run of STATUS asserted, in clocks, and every ECS
  // pulse that no AS followed in the same cycle -- UM table 8-2 (STATUS) and
  // 7.1.1 (ECS: "an aborted cycle"), for doc/mmu.md's open question 6.
  integer sfd;
  string  sfn;
  int     srun, sclk, ecs_wait;
  initial begin
    sfd = 0; srun = 0; sclk = 0; ecs_wait = 0;
    if ($value$plusargs("status=%s", sfn)) sfd = $fopen(sfn, "w");
  end
  always @(posedge clk) if (reset_n && sfd != 0) begin
    sclk = sclk + 1;
    if (!status_n) srun = srun + 1;
    else begin
      if (srun != 0) $fdisplay(sfd, "STATUS %0d clocks, ending at clk %0d", srun, sclk);
      srun = 0;
    end
    if (!ecs_n && bus_oe) ecs_wait = 3;
    else if (ecs_wait != 0) begin
      if (!as_q) ecs_wait = 0;
      else begin
        ecs_wait = ecs_wait - 1;
        if (ecs_wait == 0) $fdisplay(sfd, "ECS without AS at clk %0d (a=%08h fc=%0d)", sclk, a, fc);
      end
    end
  end

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2.0) clk = ~clk;
  end

  string image;
  int    n;
  bit    ended;
`include "rd68031_knobs.svh"

  // A write to MARK, taken when the port acknowledges it.
  bit mark_seen;
  // +endaddr=/+endval= (hex): the write that ends the run; by default 99 to
  // $8000, PHASE 99. sim/programs/cow.S ends with $600D at $2008.
  logic [31:0] end_addr, end_val;
  initial begin
    if (!$value$plusargs("endaddr=%h", end_addr)) end_addr = 32'h0000_8000;
    if (!$value$plusargs("endval=%h", end_val)) end_val = 32'd99;
  end
  initial begin ended = 1'b0; mark_seen = 1'b0; end
  always @(negedge clk)
    if (as_q) mark_seen = 1'b0;
    else if (reset_n && !rw && dsack_n != 2'b11 && !mark_seen) begin
      mark_seen = 1'b1;
      if (a == 32'h0000_8000) knob_phase(int'(dbus));
      if (a == end_addr && dbus == end_val) ended = 1'b1;
    end

  initial begin
    reset_n = 1'b0;
    if (!$value$plusargs("image=%s", image)) image = "build/programs/busprobe.hex";
    for (n = 0; n < 65536; n = n + 1) begin
      s32.mem[n] = 8'h00;
      s16.mem[n] = 8'h00;
      s8.mem[n]  = 8'h00;
      sB.mem[n]  = 8'h00;
    end
    $readmemh(image, s32.mem);
    repeat (20) @(posedge clk);
    @(negedge clk);
    reset_n = 1'b1;
    n = 0;
    while (!ended && !dbg_halted && n < 4_000_000) begin
      @(negedge clk);
      n = n + 1;
    end
    repeat (40) @(negedge clk);
    if (ended)           $display("PASS: ap030_tb (%0d clocks)", n);
    else if (dbg_halted) $display("FAIL: ap030_tb: the processor halted at %08h", dbg_pc);
    else                 $display("FAIL: ap030_tb: the program never reached its end (pc %08h)", dbg_pc);
    $finish;
  end

endmodule
