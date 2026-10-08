// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- reset operation: UM 7.8, figures 7-64 and 7-65.
//
//   1. "During the reset period, the entire bus three-states (except for
//      non-three-statable signals, which are driven to their inactive state)",
//      under rst_n -- the power-on initialisation, which is not an MC68030 pin
//      (doc/pinout.md) -- and Table 5-2 says which pins three-state.
//   2. "Once RESET negates, all control signals are driven to their inactive
//      state, the data bus is in read mode, and the address bus is driven" --
//      except the address bus, which ADDR_HIZ_BETWEEN_CYCLES releases between
//      cycles and which this checks as doc/divergences.md records it.
//   3. "When a reset instruction is executed, the processor drives the RESET
//      signal for 512 clock cycles ... the internal registers of the processor
//      are unaffected": the pulse's length, open drain, and the bus unit still
//      working afterwards although its own RESET pin read low throughout --
//      `crst`, the bus unit's verdict that the processor is being reset, never
//      rises for its own pulse.
//   4. "The external RESET signal resets the processor and the entire system"
//      (UM 7.8, 5.10.1): RESET alone, with no HALT, held low from outside
//      three-states the bus as rst_n does, ends a bus cycle in progress
//      ("resetting the processor causes any bus cycle in progress to
//      terminate"), starts nothing while it is held, and lets the processor
//      run again when it negates. "Bus arbitration requests are recognized
//      during normal processing, RESET assertion, HALT assertion, and even
//      when the processor has halted due to a double bus fault" (7.7): BR is
//      granted under it.
//   5. "An external RESET signal that is asserted to the processor during
//      execution of a reset instruction must extend beyond the reset period of
//      the instruction by at least eight clock cycles to reset the processor"
//      (UM 7.8): one that ends with the pulse, or two clocks after it, does
//      not; one that goes on eight clocks past it does.

`timescale 1ns / 1ps

module bus_reset_tb;

`include "rd68031_bus_harness.svh"

  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  string       what;
  realtime     t_on, t_off;
  int unsigned as_cnt_at_reset;
  bit          crst_seen;
  always @(posedge clk) if (crst === 1'b1) crst_seen = 1'b1;

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
    for (t = 0; t < 64; t = t + 1) sw.mem[t] = 8'h10 + t[7:0];

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
    check(crst === 1'b0, "during the RESET instruction: its own pulse does not reset the processor");
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
    // 4. The RESET pin driven low from outside, which resets the processor
    // (UM 7.8). First on an idle bus.
    // -------------------------------------------------------------------
    @(posedge clk);
    as_cnt_at_reset = as_count;
    reset_in_drv = 1'b1;
    repeat (4) @(posedge clk);
    #(SNAP);
    check(reset_sync_n === 1'b0, "external RESET: synchronised");
    check(crst === 1'b1, "external RESET: the processor is being reset (crst)");
    check(a_oe === 1'b0 && fc_oe === 1'b0 && siz_oe === 1'b0 && d_oe === 1'b0
          && rw_oe === 1'b0 && rmc_oe === 1'b0 && as_oe === 1'b0 && ds_oe === 1'b0
          && dben_oe === 1'b0 && ciout_oe === 1'b0 && cbreq_oe === 1'b0,
          "external RESET: the entire bus three-states (UM 7.8)");
    check(ecs_n_o === 1'b1 && ocs_n_o === 1'b1 && bg_n_o === 1'b1
          && status_n_o === 1'b1 && reset_n_oe === 1'b0,
          "external RESET: ECS, OCS, BG and STATUS inactive, RESET not driven");
    // A request presented while it is held starts nothing.
    fork
      op_read(32'h0000_0108, 4, got, cycles);
      begin
        repeat (12) @(posedge clk);
        check(as_cnt_at_reset == as_count,
              "external RESET: no bus cycle starts while it is held");
        // Arbitration goes on (UM 7.7).
        br_drv = 1'b1;
        t = 0;
        while (bg_n_o !== 1'b0 && t < 20) begin @(posedge clk); t = t + 1; end
        check(bg_n_o === 1'b0, "external RESET: BR is granted under it (UM 7.7)");
        bgack_drv = 1'b1;
        @(posedge clk);
        br_drv = 1'b0;
        repeat (3) @(posedge clk);
        check(bus_granted === 1'b1, "external RESET: BGACK takes the bus");
        bgack_drv = 1'b0;
        repeat (3) @(posedge clk);
        check(bus_granted === 1'b0 && bg_n_o === 1'b1,
              "external RESET: and gives it back");
        @(posedge clk);
        reset_in_drv = 1'b0;
      end
    join
    check(crst === 1'b0, "external RESET negated: the reset ends");
    check(got[31:0] === 32'h18191A1B,
          "external RESET negated: the request runs once it is over");

    // ... and in the middle of a bus cycle: "resetting the processor causes
    // any bus cycle in progress to terminate as if DSACKx, BERR, or STERM had
    // been asserted" (UM 7.8). The 32-bit port at $3000_0000 has three wait
    // states, so the cycle is still waiting when the pin goes low.
    as_cnt_at_reset = as_count;
    fork
      op_read(32'h3000_0010, 4, got, cycles);
      begin
        @(negedge as_n_o);
        @(posedge clk);
        reset_in_drv = 1'b1;
        // Two falling-edge ranks and a rising edge, then a half clock.
        repeat (3) @(posedge clk);
        @(negedge clk);
        #(SNAP);
        check(crst === 1'b1 && as_oe === 1'b0 && a_oe === 1'b0 && ds_oe === 1'b0,
              "external RESET mid-cycle: the cycle is abandoned and the bus three-stated");
        check(req_ack === 1'b0, "external RESET mid-cycle: the operand is not acknowledged");
        repeat (10) @(posedge clk);
        reset_in_drv = 1'b0;
      end
    join
    check(as_count == as_cnt_at_reset + 2,
          "external RESET mid-cycle: the operand is run again, from its start, after it");
    check(got[31:0] === 32'h20212223,
          "external RESET mid-cycle: and reads what is there");

    // -------------------------------------------------------------------
    // 5. The RESET instruction's own pulse, with the pin held low from outside
    // as well -- UM 7.8, eight clocks past the instruction's reset period.
    // -------------------------------------------------------------------
    for (int ext = 0; ext < 3; ext++) begin
      int unsigned past;
      past = (ext == 0) ? 0 : (ext == 1) ? 2 : 8;
      crst_seen = 1'b0;
      @(negedge clk);
      reset_req_drv = 1'b1;
      @(posedge reset_n_oe);
      repeat (100) @(posedge clk);
      reset_in_drv = 1'b1;        // from outside, during the pulse
      @(negedge reset_n_oe);
      repeat (past) @(posedge clk);
      reset_in_drv = 1'b0;
      reset_req_drv = 1'b0;
      repeat (12) @(posedge clk);
      $sformat(what, "RESET from outside during the instruction, %0d clocks past it: %s",
               past, (past >= 8) ? "resets the processor" : "does not reset it");
      check(crst_seen === (past >= 8), what);
    end

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
