// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the emulator support pins and the bus during reset.
//
//   STATUS  UM 5.11.4, 12.7.1 and Table 12-4: asserted for one clock at an
//           instruction boundary, two at a boundary where a trace or interrupt
//           exception is taken, three when exception processing begins, and
//           continuously once the processor has halted on a double bus fault.
//   REFILL  UM 5.11.3, 12.7.1: the microsequencer requests a pipeline refill.
//           "Both STATUS and REFILL assert and negate from the falling edge of
//           the CLK signal."
//   MMUDIS  UM 5.11.2: an input, synchronised like CDIS. Its consumer is the MMU
//           of M11; here it is only shown to arrive.
//   Reset   UM 7.8: "during the reset period, the entire bus three-states
//           (except for non-three-statable signals, which are driven to their
//           inactive state)".
//
// The sequencer's events are driven directly, as one-clock pulses from a rising
// edge, which is what rd68031_seq produces; core_status_tb runs the same thing
// end to end.

`timescale 1ns / 1ps

module bus_status_tb;

`include "rd68031_bus_harness.svh"

  string       what;
  int unsigned n;
  logic [39:0] got;
  int unsigned cycles;

  // STATUS and REFILL pulses: their widths, and the edges they moved on.
  realtime st_lo, st_hi, rf_lo, rf_hi;
  int unsigned st_pulses, rf_pulses;
  bit          st_on_rise, rf_on_rise;
  initial begin
    st_pulses = 0; rf_pulses = 0; st_on_rise = 1'b0; rf_on_rise = 1'b0;
  end
  always @(negedge status_n_o) begin
    st_lo = $realtime;
    if (rst_n) st_pulses = st_pulses + 1;
    if (clk) st_on_rise = 1'b1;          // moved with CLK high: a rising edge
  end
  always @(posedge status_n_o) begin st_hi = $realtime; if (clk) st_on_rise = 1'b1; end
  always @(negedge refill_n_o) begin
    rf_lo = $realtime;
    if (rst_n) rf_pulses = rf_pulses + 1;
    if (clk) rf_on_rise = 1'b1;
  end
  always @(posedge refill_n_o) begin rf_hi = $realtime; if (clk) rf_on_rise = 1'b1; end

  // One event, as the sequencer gives it: a one-clock pulse from a rising edge.
  task automatic pulse(input int which);
    @(posedge clk);
    case (which)
      1: sts_bound_drv = 1'b1;
      2: begin sts_bound_drv = 1'b1; sts_pend_drv = 1'b1; end
      3: sts_exc_drv = 1'b1;
      4: sts_refill_drv = 1'b1;
      default: ;
    endcase
    @(posedge clk);
    sts_bound_drv = 1'b0; sts_pend_drv = 1'b0; sts_exc_drv = 1'b0;
    sts_refill_drv = 1'b0;
  endtask

  task automatic settle();
    repeat (8) @(posedge clk);
  endtask

  initial begin
    $display("bus_status_tb: STATUS, REFILL, MMUDIS and the bus in reset");

    // =====================================================================
    // Reset. UM 7.8, and Table 5-2 for which pins three-state.
    // =====================================================================
    rst_n = 1'b0;
    #(CLK_PERIOD * 2.25);
    check(!a_oe && !fc_oe && !siz_oe && !d_oe && !rmc_oe && !ciout_oe,
          "reset: the address group, data, RMC and CIOUT are three-stated (UM 7.8)");
    check(!as_oe && !ds_oe && !rw_oe && !dben_oe && !cbreq_oe,
          "reset: AS, DS, R/W, DBEN and CBREQ are three-stated (UM 7.8)");
    check(ecs_n_o === 1'b1 && ocs_n_o === 1'b1 && bg_n_o === 1'b1
          && status_n_o === 1'b1 && refill_n_o === 1'b1,
          "reset: ECS, OCS, BG, STATUS and REFILL driven inactive (UM 7.8, Table 5-2)");
    check(!reset_n_oe, "reset: RESET is not driven by the processor");
    reset_dut();
    check(as_oe && as_n_o === 1'b1 && rw_oe && cbreq_oe && cbreq_n_o === 1'b1,
          "out of reset: control signals driven inactive (UM 7.8)");

    // =====================================================================
    // STATUS: Table 12-4.
    // =====================================================================
    settle();
    n = st_pulses;
    pulse(1);
    settle();
    $sformat(what, "an instruction boundary: STATUS one clock (got %0.1f ns)", st_hi - st_lo);
    check(st_pulses == n + 1 && st_hi - st_lo == CLK_PERIOD, what);

    n = st_pulses;
    pulse(2);
    settle();
    $sformat(what, "a boundary with a trace or interrupt pending: two clocks (got %0.1f ns)",
             st_hi - st_lo);
    check(st_pulses == n + 1 && st_hi - st_lo == 2.0 * CLK_PERIOD, what);

    n = st_pulses;
    pulse(3);
    settle();
    $sformat(what, "exception processing begins: three clocks (got %0.1f ns)", st_hi - st_lo);
    check(st_pulses == n + 1 && st_hi - st_lo == 3.0 * CLK_PERIOD, what);

    // Two boundaries on consecutive clocks must still read as two: a pulse is
    // followed by a clock negated.
    n = st_pulses;
    @(posedge clk); sts_bound_drv = 1'b1;
    repeat (2) @(posedge clk); sts_bound_drv = 1'b0;
    settle();
    $sformat(what, "two boundaries on consecutive clocks: two one-clock pulses (got %0d)",
             st_pulses - n);
    check(st_pulses == n + 2 && st_hi - st_lo == CLK_PERIOD, what);

    // REFILL: one clock per request.
    n = rf_pulses;
    pulse(4);
    settle();
    $sformat(what, "a pipeline refill: REFILL one clock (got %0.1f ns)", rf_hi - rf_lo);
    check(rf_pulses == n + 1 && rf_hi - rf_lo == CLK_PERIOD, what);

    check(!st_on_rise && !rf_on_rise,
          "STATUS and REFILL move only on falling edges (UM 12.7.1, specifications 62, 63)");

    // A double bus fault: STATUS continuously (UM 7.5.4); the bus still works
    // for an alternate master, which bus_arb_tb checks.
    @(posedge clk); dbf_drv = 1'b1;
    repeat (3) @(posedge clk);
    n = 0;
    repeat (30) begin
      @(negedge clk); #(SNAP);
      if (status_n_o !== 1'b0) n = n + 1;
    end
    check(n == 0, "double bus fault: STATUS asserted continuously (UM 7.5.4, Table 12-4)");
    @(posedge clk); dbf_drv = 1'b0;
    settle();

    // =====================================================================
    // MMUDIS: two falling-edge ranks, like every asynchronous input (UM 7.1).
    // =====================================================================
    check(mmudis_sync_n === 1'b1, "MMUDIS negated");
    @(posedge clk); mmudis_drv = 1'b1;
    @(negedge clk); #(SNAP);
    check(mmudis_sync_n === 1'b1, "MMUDIS: not yet through the first rank");
    @(negedge clk); #(SNAP);
    check(mmudis_sync_n === 1'b0, "MMUDIS: synchronised after two falling edges (UM 7.1)");
    @(posedge clk); mmudis_drv = 1'b0;
    repeat (3) @(negedge clk);
    check(mmudis_sync_n === 1'b1, "MMUDIS: negated again");

    // And the bus goes on working through all of it.
    op_read(32'h4000_0010, 4, got, cycles);
    check(cycles == 1 && req_end == 3'd6, "a synchronous read after all that");

    $display("bus_status_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_status_tb");
    else                                     $display("FAIL: bus_status_tb");
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL: bus_status_tb timed out");
    $finish;
  end

endmodule
