// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- STATUS and REFILL from the microsequencer to the pins: UM 12.7.1.
//
// bus_status_tb checks the encoder in the bus unit against driven events. This
// runs real code and checks that the events the sequencer reports come out where
// Table 12-4 says:
//
//   1 clock     "sequencer at instruction boundary will begin execution of next
//               instruction"
//   2 clocks    at a boundary, "but will not begin next instruction immediately
//               due to pending trace exception OR pending interrupt exception"
//   3 clocks    "exception processing to begin for reset OR bus error OR ..."
//   continuously   "processor halted due to double bus fault" (core_fault_tb)
//
// and that REFILL marks the refills a branch makes: "instructions that cause
// refills include branches, jumps, instruction traps, returns ... and status
// register manipulations".

`timescale 1ns / 1ps

module core_status_tb;

`include "rd68031_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] HAND = 32'h0000_0500;
  localparam logic [31:0] GONE = 32'h0000_8000;

  bit          reached;
  string       what;
  int unsigned i;

  // -------------------------------------------------------------------------
  // The pins, sampled after every falling edge -- "both STATUS and REFILL
  // assert and negate from the falling edge of the CLK signal".
  // -------------------------------------------------------------------------
  localparam int MAXP = 256;
  int unsigned np;             // STATUS pulses seen
  int unsigned pw [0:MAXP-1];  // ... and how many clocks each was
  int unsigned run;
  int unsigned nrefill;
  int unsigned nflush;         // refills the sequencer asked for
  bit          last_st, last_rf;

  initial begin
    np = 0; run = 0; nrefill = 0; nflush = 0; last_st = 1'b1; last_rf = 1'b1;
  end

  always @(negedge clk) begin
    #(CLK_PERIOD / 8.0);
    if (rst_n) begin
      if (status_n_o === 1'b0) run = run + 1;
      else if (!last_st) begin
        if (np < MAXP) pw[np] = run;
        np = np + 1;
        run = 0;
      end
      last_st = status_n_o;
      if (refill_n_o === 1'b0 && last_rf) nrefill = nrefill + 1;
      last_rf = refill_n_o;
    end
  end

  always @(posedge clk)
    if (rst_n && (dut.u_seq.pf_op == rd68031_ucode_pkg::U_PF_FLUSH)) nflush = nflush + 1;

  task automatic clear_counts();
    np = 0; run = 0; nrefill = 0; nflush = 0;
  endtask

  int unsigned n1, n2, n3, nother;
  task automatic tally();
    n1 = 0; n2 = 0; n3 = 0; nother = 0;
    for (i = 0; i < np && i < MAXP; i = i + 1) begin
      case (pw[i])
        1: n1 = n1 + 1;
        2: n2 = n2 + 1;
        3: n3 = n3 + 1;
        default: nother = nother + 1;
      endcase
    end
  endtask

  task automatic base_setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1)
      poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
  endtask

  int unsigned b0;

  initial begin
    $display("core_status_tb: STATUS and REFILL, UM 12.7.1");

    // =====================================================================
    // Straight-line code and two branches.
    // =====================================================================
    base_setup();
    poke_w(CODE + 0,  16'h7001);   // MOVEQ #1,D0
    poke_w(CODE + 2,  16'h4E71);   // NOP
    poke_w(CODE + 4,  16'h2200);   // MOVE.L D0,D1
    poke_w(CODE + 6,  16'h6002);   // BRA.B +2
    poke_w(CODE + 8,  16'h7455);   // MOVEQ #$55,D2 -- skipped
    poke_w(CODE + 10, 16'h4E71);   // NOP
    poke_w(CODE + 12, 16'h6000);   // BRA.W +4
    poke_w(CODE + 14, 16'h0004);
    poke_w(CODE + 16, 16'h7633);   // MOVEQ #$33,D3 -- skipped
    poke_w(CODE + 18, 16'h4E71);   // NOP
    poke_w(CODE + 20, 16'h60FE);   // BRA * -- spin
    clear_counts();
    reset_dut();
    b0 = instructions;
    run_until(CODE + 20, 600, reached);
    repeat (6) @(negedge clk);
    check(reached, "the program runs");
    tally();
    check(np >= 1 && pw[0] == 3,
          "after reset: STATUS for three clocks, exception processing begins (Table 12-4)");
    $sformat(what, "instruction boundaries: %0d one-clock STATUS pulses for %0d boundaries",
             n1, instructions - b0);
    check(n1 >= 6 && n1 <= instructions - b0, what);
    $sformat(what, "no two- or three-clock pulse without a trace, interrupt or exception (got %0d, %0d)",
             n2, n3 - 1);
    check(n2 == 0 && n3 == 1 && nother == 0, what);
    $sformat(what, "REFILL: one pulse per refill the sequencer requested (%0d pins, %0d requests)",
             nrefill, nflush);
    check(nrefill == nflush, what);
    $sformat(what, "REFILL: the reset and the branches refill the pipe (got %0d)", nrefill);
    check(nrefill >= 3, what);

    // A branch refills: run the spin a few times and count.
    clear_counts();
    repeat (40) @(negedge clk);
    $sformat(what, "the spinning BRA refills the pipe every time round (%0d REFILL, %0d boundaries)",
             nrefill, np);
    check(nrefill >= 2 && nrefill == nflush, what);

    // =====================================================================
    // Trace: STATUS for two clocks at the traced instruction's boundary.
    // =====================================================================
    base_setup();
    poke_l(32'h0000_0024, HAND);   // vector 9
    poke_w(CODE + 0, 16'h46FC);    // MOVE #$8700,SR -- T1 on
    poke_w(CODE + 2, 16'h8700);
    poke_w(CODE + 4, 16'h7006);    // MOVEQ #6,D0 -- traced
    poke_w(CODE + 6, 16'h60FE);
    poke_w(HAND + 0, 16'h7277);    // MOVEQ #$77,D1
    poke_w(HAND + 2, 16'h60FE);
    // Below the trace frame, where a second one would go.
    for (i = 0; i < 12; i = i + 2) poke_w(ISP0 - 24 + i, 16'hEEEE);
    clear_counts();
    reset_dut();
    run_until(HAND + 2, 2000, reached);
    repeat (6) @(negedge clk);
    check(reached, "trace: the handler runs");
    // UM 8.1.7: the trace exception's own processing is not traced -- one
    // frame, and nothing below it (doc/bugs-found.md).
    check(peek_w(ISP0 - 12 + 6) === 16'h2024, "trace: the format $2 trace frame");
    check(peek_w(ISP0 - 24 + 6) === 16'hEEEE && peek_l(ISP0 - 24 + 2) === 32'hEEEE_EEEE,
          "trace: exactly one trace frame -- the exception processing is not itself traced");
    tally();
    $sformat(what, "trace: one two-clock STATUS pulse at the traced boundary (got %0d)", n2);
    check(n2 == 1, what);

    // =====================================================================
    // A bus error: STATUS for three clocks as exception processing begins.
    // =====================================================================
    base_setup();
    poke_l(32'h0000_0008, HAND);   // vector 2
    poke_w(CODE + 0, 16'h207C);    // MOVEA.L #GONE,A0
    poke_l(CODE + 2, GONE);
    poke_w(CODE + 6, 16'h2410);    // MOVE.L (A0),D2 -- faults
    poke_w(CODE + 8, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    berr_base = GONE;
    berr_mask = 32'hFFFF_F000;
    berr_en   = 1'b1;
    clear_counts();
    reset_dut();
    run_until(HAND, 2000, reached);
    repeat (6) @(negedge clk);
    berr_en = 1'b0;
    check(reached, "bus error: the handler runs");
    tally();
    $sformat(what, "bus error: a second three-clock STATUS pulse after reset's (got %0d)", n3);
    check(n3 == 2, what);

    $display("core_status_tb: %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("PASS: core_status_tb");
    else            $display("FAIL: core_status_tb");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: core_status_tb timed out");
    $finish;
  end

endmodule
