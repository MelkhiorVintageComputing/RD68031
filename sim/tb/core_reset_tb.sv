// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the RESET pin resets the processor: UM 7.8, 5.10.1 and 8.1.1.
//
// `rst_n` is the power-on initialisation, which is not an MC68030 pin
// (doc/pinout.md); the RESET pin is the architectural reset, and this is the
// testbench for it, at the level of the whole processor. bus_reset_tb has the
// pins under it -- the three-state bus, arbitration, the RESET instruction's
// own pulse -- with the bus unit alone.
//
//   1. A program sets every register a reset spares, and some it does not,
//      and is reset in the middle of a loop: during the reset period the bus
//      three-states; after it, "the first bus cycle for reset exception
//      processing" reads the initial interrupt stack pointer from $0 and the
//      program counter from $4, in supervisor program space (UM 4.3, 7.8);
//      STATUS shows three clocks (UM Table 12-4); and UM 8.1.1's ten steps
//      are checked one by one: T1 T0 clear, S set and M clear, the mask at 7,
//      VBR zero, CACR's bits clear, the instruction cache invalidated -- by
//      running code the cache held before the reset, and changed while it was
//      held, with the cache enabled again -- ISP and PC from the vector table.
//      What UM 8.1.1 does not name keeps its value: D0-D7, A0-A6, USP, MSP,
//      SFC, DFC and CAAR.
//   2. "Only an external RESET can restart a processor halted by a double bus
//      fault" (UM 8.1.2): a double bus fault, STATUS asserted continuously,
//      then the pin, and the processor runs again.
//   3. A stopped processor (PRM 6 STOP) is restarted by the pin.
//   4. Reset exception processing is a group-0 window (UM 8.1.1, figure 8-1;
//      UM 12.7.1, "the processor also halts if it receives a bus error or
//      address error during the vector table read operations or the prefetch
//      for the first instruction after an external reset"): a bus error on
//      the vector read, an odd initial program counter, and a bus error on
//      the first prefetch each halt it.
//   5. The RESET instruction drives the pin and reads its own pulse back, and
//      does not reset the processor (UM 5.10.1); a RESET from outside that
//      outlasts the pulse by eight clocks does (UM 7.8).

`timescale 1ns / 1ps

module core_reset_tb;

`include "rd68031_core_harness.svh"

  localparam logic [31:0] ISP0  = 32'h0000_1000;
  localparam logic [31:0] ISP1  = 32'h0000_1800;
  localparam logic [31:0] CODE  = 32'h0000_0400;
  localparam logic [31:0] LOOP  = CODE + 32'h92;
  localparam logic [31:0] CODE2 = 32'h0000_0600;
  localparam logic [31:0] CODE3 = 32'h0000_0700;
  localparam logic [31:0] CODE4 = 32'h0000_0780;
  localparam logic [31:0] CODE5 = 32'h0000_0800;
  localparam logic [31:0] SPIN  = 32'h0000_0900;
  localparam logic [31:0] SPIN2 = 32'h0000_0910;
  localparam logic [31:0] BAD   = 32'h0000_E000;   // a region that answers BERR

  bit          reached;
  logic [31:0] d0_at_reset;
  string       what;
  int unsigned n;

  // The bus cycles after a reset, as a device sees them.
  bit          rec_on;
  int unsigned nrec;
  logic [31:0] rec_a  [0:3];
  logic  [2:0] rec_fc [0:3];
  logic        rec_rw [0:3];
  logic  [1:0] rec_siz[0:3];
  initial begin rec_on = 1'b0; nrec = 0; end
  always @(negedge as_n_o)
    if (rst_n && rec_on && nrec < 4) begin
      rec_a[nrec]   = a_o;
      rec_fc[nrec]  = fc_o;
      rec_rw[nrec]  = rw_o;
      rec_siz[nrec] = siz_o;
      nrec = nrec + 1;
    end

  // The first STATUS indication after the reset ends, in clocks.
  int unsigned sts_width;
  bit          sts_meas;
  initial begin sts_width = 0; sts_meas = 1'b0; end
  task automatic measure_status(output int unsigned w);
    int unsigned k;
    k = 0;
    while (status_n_o !== 1'b0 && k < 50) begin @(posedge clk); k = k + 1; end
    w = 0;
    while (status_n_o === 1'b0 && w < 50) begin @(posedge clk); w = w + 1; end
  endtask

  // AS falling edges, for the tests whose subject is that there are none.
  int unsigned starts;
  initial starts = 0;
  always @(negedge as_n_o) if (rst_n) starts = starts + 1;

  // The RESET pin, low from outside for `clocks` clocks. Changed on falling
  // edges, as every input the design samples.
  task automatic pin_reset(input int clocks);
    @(negedge clk);
    reset_in_n = 1'b0;
    repeat (clocks) @(posedge clk);
    @(negedge clk);
    reset_in_n = 1'b1;
  endtask

  task automatic base_setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1)
      poke_l(v * 4, 32'h0000_9000);   // an unexpected vector spins at $9000
    poke_w(32'h0000_9000, 16'h60FE);  // BRA *
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    poke_w(SPIN,  16'h60FE);
    poke_w(SPIN2, 16'h60FE);
  endtask

  // The vector a reset will read next, and the test that the processor got
  // there through reset exception processing and nothing else.
  task automatic expect_boot(input logic [31:0] isp, input logic [31:0] pc,
                             input string when);
    measure_status(sts_width);
    run_until(pc, 4000, reached);
    check(reached, {when, ": the processor runs from the reset vector's program counter"});
    check(nrec >= 2 && rec_a[0] === 32'h0 && rec_fc[0] === 3'd6 && rec_rw[0] === 1'b1
          && rec_siz[0] === 2'b00,
          {when, ": the first cycle reads the initial ISP, a long word at $0 in supervisor program space -- UM 4.3, 7.8"});
    check(nrec >= 2 && rec_a[1] === 32'h4 && rec_fc[1] === 3'd6 && rec_rw[1] === 1'b1,
          {when, ": the second reads the initial PC at $4 -- UM 8.1.1 steps 9 and 10"});
    check(sts_width == 3,
          $sformatf("%s: STATUS three clocks for reset exception processing, got %0d -- UM Table 12-4",
                    when, sts_width));
    check(dut.u_seq.sr_q === 16'h2700,
          {when, ": SR $2700 -- T1 T0 clear, S set, M clear, mask 7 (UM 8.1.1 steps 1-3)"});
    check(dut.u_seq.isp_q === isp, {when, ": ISP from $0 -- UM 8.1.1 step 9"});
  endtask

  initial begin
    $display("core_reset_tb: the RESET pin -- UM 7.8, 5.10.1, 8.1.1");

    // ======================================================================
    // 1. A reset in the middle of a program.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h223C);  // move.l #0x11111111,%d1
    poke_w(CODE + 32'h002, 16'h1111);
    poke_w(CODE + 32'h004, 16'h1111);
    poke_w(CODE + 32'h006, 16'h243C);  // move.l #0x22222222,%d2
    poke_w(CODE + 32'h008, 16'h2222);
    poke_w(CODE + 32'h00A, 16'h2222);
    poke_w(CODE + 32'h00C, 16'h263C);  // move.l #0x33333333,%d3
    poke_w(CODE + 32'h00E, 16'h3333);
    poke_w(CODE + 32'h010, 16'h3333);
    poke_w(CODE + 32'h012, 16'h283C);  // move.l #0x44444444,%d4
    poke_w(CODE + 32'h014, 16'h4444);
    poke_w(CODE + 32'h016, 16'h4444);
    poke_w(CODE + 32'h018, 16'h2A3C);  // move.l #0x55555555,%d5
    poke_w(CODE + 32'h01A, 16'h5555);
    poke_w(CODE + 32'h01C, 16'h5555);
    poke_w(CODE + 32'h01E, 16'h2C3C);  // move.l #0x66666666,%d6
    poke_w(CODE + 32'h020, 16'h6666);
    poke_w(CODE + 32'h022, 16'h6666);
    poke_w(CODE + 32'h024, 16'h2E3C);  // move.l #0x77777777,%d7
    poke_w(CODE + 32'h026, 16'h7777);
    poke_w(CODE + 32'h028, 16'h7777);
    poke_w(CODE + 32'h02A, 16'h43F9);  // lea 0xA1A1A1A0,%a1
    poke_w(CODE + 32'h02C, 16'hA1A1);
    poke_w(CODE + 32'h02E, 16'hA1A0);
    poke_w(CODE + 32'h030, 16'h45F9);  // lea 0xA2A2A2A0,%a2
    poke_w(CODE + 32'h032, 16'hA2A2);
    poke_w(CODE + 32'h034, 16'hA2A0);
    poke_w(CODE + 32'h036, 16'h47F9);  // lea 0xA3A3A3A0,%a3
    poke_w(CODE + 32'h038, 16'hA3A3);
    poke_w(CODE + 32'h03A, 16'hA3A0);
    poke_w(CODE + 32'h03C, 16'h49F9);  // lea 0xA4A4A4A0,%a4
    poke_w(CODE + 32'h03E, 16'hA4A4);
    poke_w(CODE + 32'h040, 16'hA4A0);
    poke_w(CODE + 32'h042, 16'h4BF9);  // lea 0xA5A5A5A0,%a5
    poke_w(CODE + 32'h044, 16'hA5A5);
    poke_w(CODE + 32'h046, 16'hA5A0);
    poke_w(CODE + 32'h048, 16'h4DF9);  // lea 0xA6A6A6A0,%a6
    poke_w(CODE + 32'h04A, 16'hA6A6);
    poke_w(CODE + 32'h04C, 16'hA6A0);
    poke_w(CODE + 32'h04E, 16'h41F8);  // lea 0x3000,%a0
    poke_w(CODE + 32'h050, 16'h3000);
    poke_w(CODE + 32'h052, 16'h4E60);  // move.l %a0,%usp
    poke_w(CODE + 32'h054, 16'h41F8);  // lea 0x2000,%a0
    poke_w(CODE + 32'h056, 16'h2000);
    poke_w(CODE + 32'h058, 16'h4E7B);  // movec %a0,%msp
    poke_w(CODE + 32'h05A, 16'h8803);
    poke_w(CODE + 32'h05C, 16'h7005);  // moveq #5,%d0
    poke_w(CODE + 32'h05E, 16'h4E7B);  // movec %d0,%sfc
    poke_w(CODE + 32'h060, 16'h0000);
    poke_w(CODE + 32'h062, 16'h7006);  // moveq #6,%d0
    poke_w(CODE + 32'h064, 16'h4E7B);  // movec %d0,%dfc
    poke_w(CODE + 32'h066, 16'h0001);
    poke_w(CODE + 32'h068, 16'h203C);  // move.l #0xCAFEBAB0,%d0
    poke_w(CODE + 32'h06A, 16'hCAFE);
    poke_w(CODE + 32'h06C, 16'hBAB0);
    poke_w(CODE + 32'h06E, 16'h4E7B);  // movec %d0,%caar
    poke_w(CODE + 32'h070, 16'h0802);
    poke_w(CODE + 32'h072, 16'h203C);  // move.l #0x2211,%d0 -- WA, FD, IBE, EI
    poke_w(CODE + 32'h074, 16'h0000);
    poke_w(CODE + 32'h076, 16'h2211);
    poke_w(CODE + 32'h078, 16'h4E7B);  // movec %d0,%cacr
    poke_w(CODE + 32'h07A, 16'h0002);
    poke_w(CODE + 32'h07C, 16'h203C);  // move.l #0x8000,%d0
    poke_w(CODE + 32'h07E, 16'h0000);
    poke_w(CODE + 32'h080, 16'h8000);
    poke_w(CODE + 32'h082, 16'h4E7B);  // movec %d0,%vbr
    poke_w(CODE + 32'h084, 16'h0801);
    poke_w(CODE + 32'h086, 16'h41F9);  // lea 0xA0A0A0A0,%a0
    poke_w(CODE + 32'h088, 16'hA0A0);
    poke_w(CODE + 32'h08A, 16'hA0A0);
    poke_w(CODE + 32'h08C, 16'h46FC);  // move.w #0x3700,%sr -- S, M, mask 7
    poke_w(CODE + 32'h08E, 16'h3700);
    poke_w(CODE + 32'h090, 16'h7000);  // moveq #0,%d0
    poke_w(CODE + 32'h092, 16'h5280);  // loop: addq.l #1,%d0
    poke_w(CODE + 32'h094, 16'h60FC);  // bra.s loop
    // After the reset: the cache on again, and back to the loop.
    poke_w(CODE2 + 32'h000, 16'h7001);  // moveq #1,%d0
    poke_w(CODE2 + 32'h002, 16'h4E7B);  // movec %d0,%cacr
    poke_w(CODE2 + 32'h004, 16'h0002);
    poke_w(CODE2 + 32'h006, 16'h4EF8);  // jmp LOOP
    poke_w(CODE2 + 32'h008, LOOP[15:0]);
    // A pending interrupt, which the reset's mask of 7 holds off -- UM 8.1.1
    // step 3 -- so that the first thing the processor does is the program.
    ipl_n_i = ~3'd5;
    reset_dut();
    run_until(LOOP + 2, 4000, reached);
    check(reached, "1: the program reaches its loop");
    repeat (300) @(negedge clk);
    check(dut.u_seq.sr_q === 16'h3700 && dut.u_seq.vbr_q === 32'h8000
          && dut.u_seq.cacr_q === 32'h2211 && dut.u_seq.msp_q === 32'h2000,
          "1: before the reset: SR $3700, VBR $8000, CACR $2211, MSP $2000");
    // The loop in the cache is changed in memory while the reset is held.
    poke_l(32'h0, ISP1);
    poke_l(32'h4, CODE2);
    poke_w(LOOP,     16'h7C5A);          // moveq #0x5A,%d6
    poke_w(LOOP + 2, 16'h60FE);          // bra.s .
    rec_on = 1'b0;
    fork
      pin_reset(20);
      begin
        // Two falling-edge ranks of synchroniser and a rising edge, then one
        // more clock for the retiring microword to finish committing.
        @(posedge dut.crst);
        @(posedge clk);
        d0_at_reset = dut.u_seq.dreg[0];
        repeat (4) @(posedge clk);
        #(CLK_PERIOD / 8.0);
        check(a_oe === 1'b0 && fc_oe === 1'b0 && siz_oe === 1'b0 && d_oe === 1'b0
              && as_oe === 1'b0 && ds_oe === 1'b0 && rw_oe === 1'b0 && rmc_oe === 1'b0
              && dben_oe === 1'b0 && ciout_oe === 1'b0 && cbreq_oe === 1'b0,
              "1: during the reset period the entire bus three-states -- UM 7.8");
        check(status_n_o === 1'b1 && refill_n_o === 1'b1 && ecs_n_o === 1'b1,
              "1: ... and STATUS, REFILL and ECS are driven inactive");
        n = starts;
        repeat (10) @(posedge clk);
        check(starts == n, "1: no bus cycle while the reset is held");
        @(negedge dut.crst);
        nrec = 0;
        rec_on = 1'b1;
      end
    join
    expect_boot(ISP1, CODE2, "1");
    rec_on = 1'b0;
    // Nothing of CODE2 has run: what the reset spared is as the program left it.
    check(dut.u_seq.dreg[0] === d0_at_reset && d0_at_reset > 32'd0,
          $sformatf("1: D0 is the count it had reached, %0d", d0_at_reset));
    check(dut.u_seq.dreg[1] === 32'h1111_1111 && dut.u_seq.dreg[2] === 32'h2222_2222
          && dut.u_seq.dreg[3] === 32'h3333_3333 && dut.u_seq.dreg[4] === 32'h4444_4444
          && dut.u_seq.dreg[5] === 32'h5555_5555 && dut.u_seq.dreg[6] === 32'h6666_6666
          && dut.u_seq.dreg[7] === 32'h7777_7777,
          "1: D1-D7 kept -- UM 8.1.1 does not name them");
    check(dut.u_seq.areg[0] === 32'hA0A0_A0A0 && dut.u_seq.areg[1] === 32'hA1A1_A1A0
          && dut.u_seq.areg[2] === 32'hA2A2_A2A0 && dut.u_seq.areg[3] === 32'hA3A3_A3A0
          && dut.u_seq.areg[4] === 32'hA4A4_A4A0 && dut.u_seq.areg[5] === 32'hA5A5_A5A0
          && dut.u_seq.areg[6] === 32'hA6A6_A6A0,
          "1: A0-A6 kept");
    check(dut.u_seq.usp_q === 32'h3000 && dut.u_seq.msp_q === 32'h2000,
          "1: USP and MSP kept; the reset loaded ISP");
    check(dut.u_seq.sfc_q === 3'd5 && dut.u_seq.dfc_q === 3'd6
          && dut.u_seq.caar_q === 32'hCAFE_BAB0,
          "1: SFC, DFC and CAAR kept");
    check(dut.u_seq.vbr_q === 32'h0, "1: VBR zero -- UM 8.1.1 step 4");
    check(dut.u_seq.cacr_q === 32'h0,
          "1: CACR's enable, freeze, burst enable and write-allocate bits clear -- UM 8.1.1 step 5");
    check(dut.u_seq.trace_mode_q === 2'b00 && !dut.u_seq.dbf_q && !dut.u_seq.stopped_q,
          "1: no trace, not halted, not stopped");
    // UM 8.1.1 step 6: the cache was invalidated. The loop's two words were in
    // it, with the cache enabled, before the reset; they were changed in
    // memory while it was held; with the cache enabled again, the new words
    // run. A cache that kept its entries would go on counting in D0.
    run_until(LOOP + 2, 2000, reached);
    repeat (40) @(negedge clk);
    check(reached && dut.u_seq.dreg[6] === 32'h0000_005A && dut.u_seq.dreg[0] === 32'd1,
          "1: the instruction cache was invalidated -- UM 8.1.1 step 6");
    check(dut.u_seq.cacr_q === 32'h1, "1: and is enabled again by the program");
    check(dut.u_seq.sr_q[10:8] === 3'd7 && ipend_n_o === 1'b1,
          "1: the level-5 request stays masked -- UM 8.1.1 step 3");
    ipl_n_i = 3'b111;

    // ======================================================================
    // 2. A double bus fault, and the RESET pin that restarts it.
    // ======================================================================
    poke_w(CODE3 + 32'h000, 16'h4FF9);  // lea 0xF000,%sp
    poke_w(CODE3 + 32'h002, 16'h0000);
    poke_w(CODE3 + 32'h004, 16'hF000);
    poke_w(CODE3 + 32'h006, 16'h4A57);  // tst.w (%sp) -- a bus error...
    poke_w(CODE3 + 32'h008, 16'h60FE);  // bra.s .
    poke_l(32'h4, CODE3);
    berr_base = BAD;
    berr_mask = 32'hFFFF_E000;          // $E000-$FFFF
    berr_en   = 1'b1;
    pin_reset(12);
    // ... whose frame goes onto a stack in the same region: UM 8.1.2.
    n = 0;
    while (!dut.u_seq.dbf_q && n < 4000) begin @(negedge clk); n = n + 1; end
    check(dut.u_seq.dbf_q === 1'b1, "2: the bus error's own stacking faults: a double bus fault");
    n = starts;
    repeat (60) @(posedge clk);
    check(status_n_o === 1'b0 && starts == n,
          "2: halted -- STATUS asserted continuously, no bus cycles (UM 7.5.4)");
    berr_en = 1'b0;
    poke_l(32'h4, SPIN);
    nrec = 0;
    rec_on = 1'b0;
    fork
      pin_reset(12);
      begin @(negedge dut.crst); nrec = 0; rec_on = 1'b1; end
    join
    expect_boot(ISP1, SPIN, "2: RESET after the double bus fault");
    rec_on = 1'b0;
    check(!dut.u_seq.dbf_q, "2: \"only an external RESET can restart a processor halted by a double bus fault\" -- UM 8.1.2");

    // ======================================================================
    // 3. STOP, and the RESET pin.
    // ======================================================================
    poke_w(CODE4 + 32'h000, 16'h4E72);  // stop #0x2700
    poke_w(CODE4 + 32'h002, 16'h2700);
    poke_w(CODE4 + 32'h004, 16'h60FE);  // bra.s .
    poke_l(32'h4, CODE4);
    pin_reset(12);
    n = 0;
    while (!dut.u_seq.stopped_q && n < 4000) begin @(negedge clk); n = n + 1; end
    check(dut.u_seq.stopped_q === 1'b1, "3: STOP stops the processor");
    poke_l(32'h4, SPIN2);
    fork
      pin_reset(12);
      begin @(negedge dut.crst); nrec = 0; rec_on = 1'b1; end
    join
    expect_boot(ISP1, SPIN2, "3: RESET while stopped");
    rec_on = 1'b0;

    // ======================================================================
    // 4. Faults during reset exception processing: each one a double bus
    // fault, STATUS asserted continuously.
    // ======================================================================
    for (int c = 0; c < 3; c++) begin
      case (c)
        0: begin   // a bus error on the vector read itself
             berr_base = 32'h0; berr_mask = 32'hFFFF_FFF8; berr_en = 1'b1;
             what = "a bus error reading the reset vector";
           end
        1: begin   // an odd initial program counter: an address error
             berr_en = 1'b0; poke_l(32'h4, SPIN + 32'd1);
             what = "an odd initial program counter (an address error)";
           end
        default: begin   // the first prefetch is refused
             poke_l(32'h4, BAD); berr_base = BAD; berr_mask = 32'hFFFF_E000;
             berr_en = 1'b1;
             what = "a bus error on the first prefetch";
           end
      endcase
      pin_reset(12);
      n = 0;
      while (!dut.u_seq.dbf_q && n < 400) begin @(negedge clk); n = n + 1; end
      repeat (20) @(posedge clk);
      check(dut.u_seq.dbf_q === 1'b1 && status_n_o === 1'b0,
            {"4: ", what, " is a double bus fault -- UM 8.1.1, 12.7.1"});
    end
    berr_en = 1'b0;
    poke_l(32'h4, SPIN);
    pin_reset(12);
    run_until(SPIN, 4000, reached);
    check(reached && !dut.u_seq.dbf_q, "4: and a RESET with the vector repaired boots");

    // ======================================================================
    // 5. The RESET instruction: its own pulse resets nothing; one from
    // outside that outlasts it by eight clocks resets the processor.
    // ======================================================================
    poke_w(CODE5 + 32'h000, 16'h7242);  // moveq #0x42,%d1
    poke_w(CODE5 + 32'h002, 16'h4E70);  // reset
    poke_w(CODE5 + 32'h004, 16'h7443);  // moveq #0x43,%d2
    poke_w(CODE5 + 32'h006, 16'h60FE);  // bra.s .
    for (int c = 0; c < 3; c++) begin
      int unsigned past;
      bit crst_seen;
      past = (c == 0) ? 0 : (c == 1) ? 2 : 10;
      poke_l(32'h4, CODE5);
      pin_reset(12);
      run_until(CODE5 + 32'd2, 4000, reached);
      poke_l(32'h4, SPIN2);
      crst_seen = 1'b0;
      fork
        begin
          @(posedge reset_n_oe);
          if (c != 0) begin
            repeat (100) @(posedge clk);
            @(negedge clk);
            reset_in_n = 1'b0;
          end
          @(negedge reset_n_oe);
          repeat (past) @(posedge clk);
          @(negedge clk);
          reset_in_n = 1'b1;
        end
        begin
          n = 0;
          while (n < 700) begin
            @(posedge clk);
            if (dut.crst === 1'b1) crst_seen = 1'b1;
            n = n + 1;
          end
        end
      join
      run_until(CODE5 + 32'd6, 200, reached);
      if (past < 8) begin
        check(!crst_seen && reached && dut.u_seq.dreg[2][7:0] === 8'h43
              && dut.u_seq.sr_q === 16'h2700,
              $sformatf("5: RESET from outside ending %0d clocks after the instruction's pulse: not a reset; the next instruction runs -- UM 5.10.1, 7.8",
                        past));
      end else begin
        run_until(SPIN2, 4000, reached);
        check(crst_seen && reached,
              "5: RESET from outside outlasting the pulse by ten clocks resets the processor -- UM 7.8");
      end
      dut.u_seq.dreg[2] = 32'd0;
    end

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_reset_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_reset_tb");
    else                               $display("FAIL: core_reset_tb");
    $finish;
  end

  initial begin
    #50_000_000;
    $display("FAIL: core_reset_tb timed out");
    $finish;
  end

endmodule
