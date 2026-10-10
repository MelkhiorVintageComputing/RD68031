// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- one program on the core harness, every transfer at the pins
// written down, for make ap030.
//
// sim/ap030/ap030_tb.sv runs the same image on AP68030 against the same slave
// models (sim/models/rd68031_slave.sv), with the same memory map as
// rd68031_core_harness.svh:
//
//   $0xxx_xxxx  32-bit, asynchronous, no wait states (64 KB, repeated)
//   $1xxx_xxxx  16-bit, asynchronous
//   $2xxx_xxxx   8-bit, asynchronous
//   $3xxx_xxxx  32-bit, synchronous, burst
//   $4xxx_xxxx  every cycle answered with BERR (as core_mmu_tb's window)
//
// and both write their transfers through sim/models/rd68031_busmon.sv, so
// tools/bus_diff.py pins can hold them to the same data transfers.
//
//   +image=<hex>   the program, read into the 32-bit port from $0
//   +pins=<file>   where the transfers go
//
// The run ends when the program writes 99 to $8000 (PHASE 99 in
// sim/programs/mmu_common.inc and sim/programs/busprobe.S), a few clocks
// later, or at a time limit. It is not a pass/fail test of the core: it
// prints PASS when the program reached its end, and the comparison decides.

`timescale 1ns / 1ps

module core_pins_tb;

`include "rd68031_core_harness.svh"

  string image;
  int    n;
  bit    ended;

  rd68031_busmon mon (
      .clk (clk), .rst_n (rst_n), .as_n (as_n_o | ~as_oe), .rw (rw_o), .a (a_o),
      .fc (fc_o), .siz (siz_o), .d (dbus), .dsack_n (dsack_n_i), .sterm_n (sterm_n_i),
      .berr_n (berr_n_i), .halt_n (1'b1), .avec_n (1'b1), .ciin_n (ciin_n_i),
      .cbreq_n (cbreq_n_o | ~cbreq_oe), .cback_n (cback_n_i),
      .ciout_n (ciout_n_o | ~ciout_oe), .rmc_n (rmc_n_o | ~rmc_oe));

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
    if (as_n_o || !as_oe) mark_seen = 1'b0;
    else if (rst_n && !rw_o && dsack_n_i != 2'b11 && !mark_seen) begin
      mark_seen = 1'b1;
      if (a_o == 32'h0000_8000) knob_phase(int'(dbus));
      if (a_o == end_addr && dbus == end_val) ended = 1'b1;
    end

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/programs/busprobe.hex";
    for (n = 0; n < 65536; n = n + 1) begin
      s32.mem[n] = 8'h00;
      s16.mem[n] = 8'h00;
      s8.mem[n]  = 8'h00;
      sB.mem[n]  = 8'h00;
    end
    $readmemh(image, s32.mem);
    berr_base = 32'h4000_0000;
    berr_mask = 32'hF000_0000;
    berr_en   = 1'b1;
    reset_dut();
    n = 0;
    while (!ended && n < 4_000_000) begin
      @(negedge clk);
      n = n + 1;
    end
    repeat (40) @(negedge clk);
    if (ended) $display("PASS: core_pins_tb (%0d clocks)", n);
    else       $display("FAIL: core_pins_tb: the program never reached its end");
    $finish;
  end

endmodule
