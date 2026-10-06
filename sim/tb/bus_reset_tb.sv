// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- reset operation: UM 7.8, figures 7-64 and 7-65.
//
//   1. "During the reset period, the entire bus three-states (except for
//      non-three-statable signals, which are driven to their inactive state)."
//      The reset this design has is rst_n (doc/pinout.md), so that is what is
//      asserted here; Table 5-2 says which pins three-state.
//   2. "Once RESET negates, all control signals are driven to their inactive
//      state, the data bus is in read mode, and the address bus is driven" --
//      except the address bus, which ADDR_HIZ_BETWEEN_CYCLES releases between
//      cycles and which this checks as doc/divergences.md records it.
//   3. "When a reset instruction is executed, the processor drives the RESET
//      signal for 512 clock cycles ... the internal registers of the processor
//      are unaffected": the pulse's length, open drain, and the bus unit still
//      working afterwards although its own RESET pin read low throughout.
//   4. "Bus arbitration requests are recognized during normal processing,
//      RESET assertion, HALT assertion, and even when the processor has halted
//      due to a double bus fault" (7.7): during the RESET instruction and with
//      the RESET pin held low from outside.

`timescale 1ns / 1ps

module bus_reset_tb;

`include "rd68031_bus_harness.svh"

  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  string       what;
  realtime     t_on, t_off;

  task automatic grant_cycle(input string when);
    int unsigned w;
    @(posedge clk);
    br_drv = 1'b1;
    w = 0;
    while (bg_n_o !== 1'b0 && w < 20) begin @(posedge clk); w = w + 1; end
    $sformat(what, "%s: BR is granted (%0d clocks)", when, w);
    check(bg_n_o === 1'b0 && w <= 4, what);
    @(posedge clk);
    bgack_drv = 1'b1;
    @(posedge clk);
    br_drv = 1'b0;
    repeat (3) @(posedge clk);
    $sformat(what, "%s: BGACK releases the bus", when);
    check(bus_granted === 1'b1 && a_oe === 1'b0 && as_oe === 1'b0, what);
    @(posedge clk);
    bgack_drv = 1'b0;
    repeat (4) @(posedge clk);
    $sformat(what, "%s: the bus is driven again when BGACK negates", when);
    check(bus_granted === 1'b0 && as_oe === 1'b1, what);
  endtask

  initial begin
    $display("bus_reset_tb: UM 7.8, reset operation");
    for (t = 0; t < 4096; t = t + 1) s32.mem[t] = 8'h10 + t[7:0];

    // -------------------------------------------------------------------
    // 1. During reset. reset_dut() holds rst_n low for four clocks; look in
    // the middle of it, with BR asserted.
    // -------------------------------------------------------------------
    fork
      reset_dut();
      begin
        #(CLK_PERIOD * 0.25);
        br_drv = 1'b1;
        repeat (3) @(posedge clk);
        #(SNAP);
        check(a_oe === 1'b0 && fc_oe === 1'b0 && siz_oe === 1'b0 && d_oe === 1'b0,
              "in reset: address, FC, SIZ and data three-stated (Table 5-2)");
        check(rw_oe === 1'b0 && rmc_oe === 1'b0 && as_oe === 1'b0 && ds_oe === 1'b0
              && dben_oe === 1'b0, "in reset: R/W, RMC, AS, DS and DBEN three-stated");
        check(ciout_oe === 1'b0 && cbreq_oe === 1'b0, "in reset: CIOUT and CBREQ three-stated");
        check(ecs_n_o === 1'b1 && ocs_n_o === 1'b1 && bg_n_o === 1'b1
              && refill_n_o === 1'b1 && status_n_o === 1'b1,
              "in reset: ECS, OCS, BG, REFILL and STATUS driven inactive -- not three-statable");
        check(reset_n_oe === 1'b0, "in reset: the processor does not drive RESET itself");
        // rst_n is not the RESET pin: arbitration is not recognised under it
        // (doc/divergences.md, "The external RESET input ...").
        br_drv = 1'b0;
      end
    join

    // -------------------------------------------------------------------
    // 2. Just after reset.
    // -------------------------------------------------------------------
    #(SNAP);
    check(as_oe === 1'b1 && as_n_o === 1'b1 && ds_oe === 1'b1 && ds_n_o === 1'b1
          && dben_oe === 1'b1 && dben_n_o === 1'b1 && cbreq_oe === 1'b1 && cbreq_n_o === 1'b1,
          "after reset: the control signals driven inactive (UM 7.8)");
    check(rw_oe === 1'b1 && rw_o === 1'b1 && d_oe === 1'b0,
          "after reset: the data bus in read mode -- R/W high, data not driven");
    check(a_oe === 1'b0,
          "after reset: the address released until the first cycle (ADDR_HIZ_BETWEEN_CYCLES, doc/divergences.md)");
    op_read(32'h0000_0100, 4, got, cycles);
    check(got[31:0] === 32'h10111213, "after reset: the first cycle runs");
    $display("  .. reset period done");

    // -------------------------------------------------------------------
    // 3. The RESET instruction, figure 7-65.
    // -------------------------------------------------------------------
    // The request comes from a microword, so it changes after a rising edge
    // and is seen by the next one.
    @(negedge clk);
    reset_req_drv = 1'b1;
    #(SNAP);
    check(reset_busy === 1'b1, "RESET instruction: busy on the clock it is asked for");
    @(posedge reset_n_oe);
    t_on = $realtime;
    // Arbitration while the processor drives RESET.
    grant_cycle("during the RESET instruction");
    check(reset_sync_n === 1'b0, "during the RESET instruction: the RESET pin reads low");
    @(negedge reset_n_oe);
    t_off = $realtime;
    $sformat(what, "RESET instruction: RESET driven for 512 clocks (got %0.1f)",
             (t_off - t_on) / CLK_PERIOD);
    check((t_off - t_on) == 512.0 * CLK_PERIOD, what);
    check(reset_n_o === 1'b0, "RESET instruction: open drain, the output value is low");
    #(SNAP);
    check(reset_busy === 1'b0, "RESET instruction: busy ends with the pulse");
    // Still asked for: it does not start again.
    repeat (8) @(posedge clk);
    check(reset_n_oe === 1'b0, "RESET instruction: a request still held does not restart it");
    reset_req_drv = 1'b0;
    // "The internal registers of the processor are unaffected": the bus unit,
    // whose own RESET input read low for 512 clocks, carries on.
    op_read(32'h0000_0104, 4, got, cycles);
    check(got[31:0] === 32'h14151617, "after the RESET instruction: the bus unit carries on");

    // A second RESET instruction gives a second pulse.
    @(negedge clk);
    reset_req_drv = 1'b1;
    @(posedge reset_n_oe);
    t_on = $realtime;
    @(negedge reset_n_oe);
    t_off = $realtime;
    reset_req_drv = 1'b0;
    check((t_off - t_on) == 512.0 * CLK_PERIOD, "a second RESET instruction: 512 clocks again");

    // -------------------------------------------------------------------
    // 4. The RESET pin driven low from outside. The core is not reset by it
    // (doc/divergences.md); arbitration goes on, as 7.7 says it does.
    // -------------------------------------------------------------------
    @(posedge clk);
    reset_in_drv = 1'b1;
    repeat (4) @(posedge clk);
    check(reset_sync_n === 1'b0, "external RESET: synchronised");
    grant_cycle("external RESET asserted");
    @(posedge clk);
    reset_in_drv = 1'b0;
    repeat (4) @(posedge clk);
    check(reset_sync_n === 1'b1, "external RESET negated: the synchronised copy follows");

    $display("bus_reset_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_reset_tb");
    else                                     $display("FAIL: bus_reset_tb");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: bus_reset_tb timed out");
    $finish;
  end

endmodule
