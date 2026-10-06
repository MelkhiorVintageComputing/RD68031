// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- bus arbitration: UM 7.7 and the state machine of 7.7.4.
//
// The protocol, in the manual's own three steps:
//
//   1. An external device asserts BR.
//   2. The processor asserts BG to indicate that the bus will become available
//      at the end of the current bus cycle.
//   3. The external device asserts BGACK to indicate that it has assumed bus
//      mastership.
//
// and the two rules that are easy to get wrong:
//
//   - "The BG output will not be asserted while RMC is asserted" (the note under
//     figure 7-61). For the duration of a read-modify-write the BR input is
//     ignored entirely.
//   - "If T is true, the address, data, and control buses are placed in the
//     high-impedance state after the next rising edge following the negation of
//     AS and RMC" -- so the release waits for the cycle to finish, and a cycle
//     must never begin on an edge where the bus is about to go away. The harness
//     watches that one continuously, for every testbench, as drive_violations.
//
// Then all seven states of figure 7-61, read off a rendering of the figure:
// the re-grant through states 5 and 6 with two masters on a wire-ORed BR, and
// 6 back to 3; single-wire arbitration (0 to 4) on an idle bus, during a
// cycle, during a read-modify-write and during a burst; relinquish and retry
// on the first read of a read-modify-write (allowed) and on its write (not);
// BR at every clock of a burst and every phase of a synchronous operand;
// arbitration while halted (figure 7-57) and on an idle bus held by HALT; and
// specifications 35, 37, 39, 39A and 59 in clocks.

`timescale 1ns / 1ps

module bus_arb_tb;

`include "rd68031_bus_harness.svh"

  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  int unsigned a0;
  int unsigned waited;
  string       what;
  bit          saw_bg_during_rmc;
  bit          saw_rmc;
  bit          rmc_watch;

  initial begin
    $display("bus_arb_tb: UM 7.7 bus arbitration");
    saw_bg_during_rmc = 1'b0;
    saw_rmc           = 1'b0;
    rmc_watch         = 1'b1;
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) begin
      s32.mem[t] = 8'h10 + t[7:0];
      s16.mem[t] = 8'h10 + t[7:0];
      s8.mem[t]  = 8'h10 + t[7:0];
      sw.mem[t]  = 8'h10 + t[7:0];
    end

    // -------------------------------------------------------------------
    // The bus is idle. BR alone must produce BG.
    // -------------------------------------------------------------------
    check(bg_n_o === 1'b1, "idle: BG is negated with no request");
    check(a_oe === 1'b0 || a_oe === 1'b1, "idle: the address enable is defined");

    @(posedge clk);
    br_drv = 1'b1;
    waited = 0;
    while (bg_n_o !== 1'b0 && waited < 20) begin
      @(posedge clk);
      waited = waited + 1;
    end
    $sformat(what, "BR asserted: BG follows within %0d clocks", waited);
    check(bg_n_o === 1'b0, what);
    $display("  .. BG granted");

    // -------------------------------------------------------------------
    // BGACK: the external device takes the bus. Everything the processor drives
    // must go high impedance -- address, data, FC, SIZ, RMC, AS, DS, R/W, DBEN.
    // -------------------------------------------------------------------
    @(posedge clk);
    bgack_drv = 1'b1;
    @(posedge clk);
    br_drv = 1'b0;
    repeat (4) @(posedge clk);

    check(bus_granted === 1'b1, "BGACK asserted: the core reports the bus relinquished");
    check(a_oe    === 1'b0, "granted: the address bus is released");
    check(fc_oe   === 1'b0, "granted: the function codes are released");
    check(siz_oe  === 1'b0, "granted: SIZ is released");
    check(rmc_oe  === 1'b0, "granted: RMC is released");
    check(as_oe   === 1'b0, "granted: AS is released");
    check(ds_oe   === 1'b0, "granted: DS is released");
    check(rw_oe   === 1'b0, "granted: R/W is released");
    check(dben_oe === 1'b0, "granted: DBEN is released");
    check(d_oe    === 1'b0, "granted: the data bus is released");
    check(bg_n_o  === 1'b1, "granted: BG is negated once BGACK is asserted and BR is not");
    $display("  .. relinquish checks done");

    // A request made while another master holds the bus must not start a cycle.
    a0 = as_count;
    pending   = 1'b1;
    req_kind  = 3'd0;
    req_addr  = 32'h0000_0100;
    req_bytes = 3'd4;
    repeat (8) @(posedge clk);
    check(as_count == a0, "granted: no bus cycle starts while the bus is held");
    check(a_oe === 1'b0,  "granted: still released with a request pending");
    $display("  .. pending-while-granted done");

    // -------------------------------------------------------------------
    // Returning the bus. "When A is negated, the arbiter returns to the original
    // state, state 0, and negates signal T."
    // -------------------------------------------------------------------
    @(posedge clk);
    bgack_drv = 1'b0;
    @(posedge req_ack);
    pending = 1'b0;
    check(req_rdata[31:0] === 32'h10111213,
          "the pending cycle runs once the bus is returned");
    check(bus_granted === 1'b0, "bus returned: the core drives again");
    $display("  .. bus returned");
    @(negedge clk);

    // -------------------------------------------------------------------
    // Arbitration during a cycle: BR asserted mid-cycle must not disturb it, and
    // the grant must wait for the cycle to finish.
    // -------------------------------------------------------------------
    fork
      begin
        @(negedge as_n_o);       // the cycle has begun
        @(posedge clk);
        br_drv = 1'b1;
        @(posedge as_n_o);       // AS negated: the cycle is over
        check(1'b1, "BR during a cycle: the cycle completed");
      end
      op_read(32'h0000_0120, 4, got, cycles);
    join
    check(got[31:0] === 32'h30313233, "BR during a cycle: the data is intact");
    check(cycles == 1,                "BR during a cycle: still one bus cycle");
    $display("  .. BR during a cycle done");

    @(posedge clk);
    br_drv    = 1'b0;
    bgack_drv = 1'b0;
    repeat (6) @(posedge clk);

    // -------------------------------------------------------------------
    // The RMC inhibit. "The BG output will not be asserted while RMC is
    // asserted"; "for the duration of this sequence, the MC68020 ignores the BR
    // input."
    //
    // A locked sequence is a run of ordinary cycles with req_rmc raised on each
    // of them -- there is no RMW cycle kind on this part (UM 7.5.2).
    // -------------------------------------------------------------------
    begin
      fork
        // Watch BG for as long as the locked sequence runs. Both branches end by
        // themselves: a join_any with a disable would kill an operand task in
        // mid-flight and leave its request asserted.
        begin
          while (rmc_watch) begin
            @(posedge clk);
            if (rmc_n_o === 1'b0 && bg_n_o === 1'b0) saw_bg_during_rmc = 1'b1;
            if (rmc_n_o === 1'b0) saw_rmc = 1'b1;
          end
        end
        begin
          @(posedge clk);
          br_drv  = 1'b1;          // ask for the bus throughout
          req_rmc = 1'b1;
          op_read (32'h0000_0140, 4, got, cycles);
          op_write(32'h0000_0140, 4, 40'h00_CAFEF00D, cycles);
          req_rmc = 1'b0;
          // One more, unlocked, so RMC negates at the start of it -- UM 7.1.1,
          // "RMC is guaranteed to be negated before the end of state 0 for a bus
          // cycle following a read-modify-write operation".
          op_read (32'h0000_0150, 4, got, cycles);
          rmc_watch = 1'b0;
        end
      join

      check(saw_rmc,
            "the locked sequence actually asserted RMC");
      check(!saw_bg_during_rmc,
            "RMC asserted: BG is never asserted, even with BR held throughout");
      check({s32.mem[32'h140], s32.mem[32'h141], s32.mem[32'h142], s32.mem[32'h143]}
            === 32'hCAFEF00D, "the locked sequence wrote its operand");

      // With RMC gone, the same standing BR is granted.
      waited = 0;
      while (bg_n_o !== 1'b0 && waited < 20) begin
        @(posedge clk);
        waited = waited + 1;
      end
      $sformat(what, "RMC negated: the held BR is granted within %0d clocks", waited);
      check(bg_n_o === 1'b0, what);
      $display("  .. RMC inhibit done");
      @(posedge clk);
      br_drv = 1'b0;
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Relinquish and retry: BERR, HALT and BR together. UM 7.5.2.
    // -------------------------------------------------------------------
    begin
      a0 = as_count;
      fork
        begin
          assert_at_n(1'b1, 1'b1);
          br_drv = 1'b1;
          repeat (2) @(posedge clk);
          berr_drv = 1'b0;
          halt_drv = 1'b0;
          repeat (4) @(posedge clk);
          br_drv = 1'b0;
        end
        op_read(32'h0000_0160, 4, got, cycles);
      join
      check(got[31:0] === 32'h70717273,
            "relinquish and retry: the operand completes with the right data");
      check(cycles == 2, "relinquish and retry: the cycle is rerun once");
      $display("  .. relinquish and retry done");
    end

    // -------------------------------------------------------------------
    // BR at every phase of a multi-cycle operand.
    //
    // This is the one that catches the MC68010 project's arbitration bug. A
    // four-byte read on an 8-bit port is four bus cycles (UM Table 7-6), so a bus
    // request arriving part-way through has to be granted at the end of a cycle
    // and the rest of the operand resumed afterwards. If the decision to start a
    // cycle is taken from the arbiter's current state while the bus release
    // follows its next one, then at exactly one phase a fifth cycle begins on the
    // edge the bus goes away: it drives nothing, no slave answers, and the
    // operand hangs or returns the wrong bytes.
    //
    // Sweeping the phase is what makes that reachable -- a single fixed delay
    // misses it, which a first attempt at this test duly did.
    // -------------------------------------------------------------------
    begin
      int unsigned ph;
      for (ph = 0; ph < 16; ph = ph + 1) begin
        fork
          begin
            repeat (ph) @(posedge clk);
            br_drv = 1'b1;
            repeat (6) @(posedge clk);
            br_drv = 1'b0;
          end
          op_read(32'h2000_0100, 4, got, cycles);
        join
        $sformat(what,
                 "BR at phase %0d of a four-cycle operand: data (got %08h)",
                 ph, got[31:0]);
        check(got[31:0] === 32'h10111213, what);
        $sformat(what, "BR at phase %0d: still four bus cycles (got %0d)",
                 ph, cycles);
        check(cycles == 4, what);
        @(posedge clk);
        br_drv    = 1'b0;
        bgack_drv = 1'b0;
        repeat (4) @(posedge clk);
      end
      $display("  .. BR phase sweep done");
    end

    // ===================================================================
    // M2: the rest of UM 7.7, figure 7-61's seven states, and the MC68030's
    // own cycles.
    // ===================================================================
    repeat (6) @(posedge clk);

    // -------------------------------------------------------------------
    // Specifications 35, 37, 39A: BR asserted to BG asserted 1.5 to 3.5
    // clocks (RMC not asserted), BGACK asserted to BG negated 1.5 to 3.5
    // clocks, BG asserted at least 1.5 clocks wide (75 ns at 20 MHz, the
    // slowest MC68030 grade). Measured from the rising edge the input is
    // driven on.
    // -------------------------------------------------------------------
    begin
      realtime t0, t1, t2, t3;
      @(posedge clk);
      br_drv = 1'b1;
      t0 = $realtime;
      @(negedge bg_n_o);
      t1 = $realtime;
      repeat (2) @(posedge clk);
      bgack_drv = 1'b1;
      t2 = $realtime;
      @(posedge bg_n_o);
      t3 = $realtime;
      @(posedge clk);
      br_drv = 1'b0;
      $sformat(what, "spec 35: BR to BG asserted is 1.5 to 3.5 clocks (got %0.1f)",
               (t1 - t0) / CLK_PERIOD);
      check((t1 - t0) >= 1.5 * CLK_PERIOD && (t1 - t0) <= 3.5 * CLK_PERIOD, what);
      $sformat(what, "spec 37: BGACK to BG negated is 1.5 to 3.5 clocks (got %0.1f)",
               (t3 - t2) / CLK_PERIOD);
      check((t3 - t2) >= 1.5 * CLK_PERIOD && (t3 - t2) <= 3.5 * CLK_PERIOD, what);
      $sformat(what, "spec 39A: BG asserted at least 1.5 clocks (got %0.1f)",
               (t3 - t1) / CLK_PERIOD);
      check((t3 - t1) >= 1.5 * CLK_PERIOD, what);
      repeat (2) @(posedge clk);
      bgack_drv = 1'b0;
      // Specification 59: BG negated to the bus driven, at least one clock.
      wait (a_oe === 1'b1 || as_oe === 1'b1);
      $sformat(what, "spec 59: BG negated to the bus driven is at least one clock (got %0.1f)",
               ($realtime - t3) / CLK_PERIOD);
      check(($realtime - t3) >= 1.0 * CLK_PERIOD, what);
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Figure 7-61, states 4-5-6-2-3-4-0: the re-grant. "If a BR is still
    // pending after the assertion of BGACK, another BG is asserted within a
    // few clocks of the negation of BG ... Note that the processor does not
    // perform any external bus cycles before it reasserts BG in this case"
    // (UM 7.7.3). Two masters on a wire-ORed BR; a request of the processor's
    // own pending throughout, to show it never gets a cycle in.
    // -------------------------------------------------------------------
    begin
      bit quiet, rel, held6, held2;
      int unsigned c0, w0;
      realtime tn, ta;
      c0 = as_count;
      quiet = 1'b1; rel = 1'b1; held6 = 1'b1; held2 = 1'b1;
      fork
        begin
          @(posedge clk);
          br_drv = 1'b1;                           // master 1
          @(negedge bg_n_o);
          @(posedge clk);
          bgack_drv = 1'b1;                        // master 1 takes the bus,
          // and BR stays asserted: master 2 is now asking.
          @(posedge bg_n_o);                       // state 3
          tn = $realtime;
          w0 = 0;
          while (bg_n_o !== 1'b0 && w0 < 20) begin
            @(posedge clk); #(SNAP); w0 = w0 + 1;
          end
          ta = $realtime;
          $sformat(what, "re-grant: BG asserted again with BGACK still asserted (state 5), after %0.1f clocks",
                   (ta - tn) / CLK_PERIOD);
          check(bg_n_o === 1'b0 && w0 < 6, what);
          $sformat(what, "re-grant: BG negated for at least 1.5 clocks between grants (spec 39, got %0.1f)",
                   (ta - tn) / CLK_PERIOD);
          check((ta - tn) >= 1.5 * CLK_PERIOD, what);
          // State 6: held for as long as master 1 holds BGACK.
          repeat (8) begin
            @(negedge clk); #(SNAP);
            if (bg_n_o !== 1'b0) held6 = 1'b0;
          end
          @(posedge clk);
          bgack_drv = 1'b0;                        // master 1 lets go: state 2
          repeat (6) begin
            @(negedge clk); #(SNAP);
            if (bg_n_o !== 1'b0) held2 = 1'b0;
            if (a_oe !== 1'b0 || as_oe !== 1'b0) rel = 1'b0;
          end
          @(posedge clk);
          bgack_drv = 1'b1;                        // master 2 takes it
          @(posedge clk);
          br_drv = 1'b0;
          repeat (8) @(posedge clk);
          check(bg_n_o === 1'b1, "re-grant: BG negated once the second master acknowledges");
          check(as_count == c0, "re-grant: no processor cycle at any point of the hand-over");
          @(posedge clk);
          bgack_drv = 1'b0;                        // state 4 to state 0
        end
        begin
          // The processor's own request, presented from the first grant on --
          // presented earlier, it would run first: BG is "deferred until the
          // bus cycle has begun".
          @(negedge bg_n_o);
          @(posedge clk);
          op_read(32'h0000_0100, 4, got, cycles);
        end
        begin
          // The bus stays released from the first grant to the end.
          @(posedge bgack_drv);
          @(posedge clk);
          while (bgack_drv || br_drv) begin
            @(negedge clk); #(SNAP);
            if (bgack_drv && (a_oe !== 1'b0 || as_oe !== 1'b0 || rw_oe !== 1'b0))
              rel = 1'b0;
          end
        end
      join
      check(held6, "re-grant: BG held while the old master still asserts BGACK (state 6)");
      check(held2, "re-grant: BG held after the old master lets go, until the new one acknowledges (state 2)");
      check(rel, "re-grant: the bus stays released through the hand-over");
      check(got[31:0] === 32'h10111213, "re-grant: the processor's cycle runs once the bus is returned");
      check(as_count == c0 + 1, "re-grant: ... as one bus cycle");
      $display("  .. re-grant (states 5 and 6) done");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Figure 7-61, 6 to 3: in state 6 the request goes away. G drops, T stays
    // until the old master's BGACK does.
    // -------------------------------------------------------------------
    begin
      bit kept;
      @(posedge clk);
      br_drv = 1'b1;
      @(negedge bg_n_o);
      @(posedge clk);
      bgack_drv = 1'b1;
      @(posedge bg_n_o);
      @(negedge bg_n_o);                          // state 5
      @(posedge clk);
      br_drv = 1'b0;                              // 6 -> 3 -> 4
      repeat (6) @(posedge clk);
      check(bg_n_o === 1'b1, "state 6, BR negated: BG negates (states 3 and 4)");
      kept = (a_oe === 1'b0 && as_oe === 1'b0);
      check(kept, "state 6, BR negated: the bus stays released while BGACK is asserted");
      @(posedge clk);
      bgack_drv = 1'b0;
      repeat (6) @(posedge clk);
      check(bus_granted === 1'b0 && as_oe === 1'b1, "state 4, BGACK negated: the processor drives again");
      $display("  .. 6 -> 3 -> 4 -> 0 done");
    end

    // -------------------------------------------------------------------
    // Single-wire arbitration, figure 7-61's 0 to 4: "BGACK alone can be used
    // to place the processor's external bus buffers in the high-impedance
    // state" (UM 7.7.4, figure 7-62).
    // -------------------------------------------------------------------
    begin
      bit no_bg;
      int unsigned c0;
      no_bg = 1'b1;
      c0 = as_count;
      fork
        begin
          @(posedge clk);
          bgack_drv = 1'b1;
          repeat (4) @(posedge clk);
          check(bus_granted === 1'b1 && a_oe === 1'b0 && as_oe === 1'b0 && rw_oe === 1'b0
                && cbreq_oe === 1'b0 && ciout_oe === 1'b0,
                "single-wire, idle bus: BGACK alone releases the bus");
          repeat (6) @(posedge clk);
          check(as_count == c0, "single-wire: a pending request waits for BGACK to negate");
          bgack_drv = 1'b0;
        end
        begin
          wait (bus_granted === 1'b1);
          op_read(32'h0000_0104, 4, got, cycles);
        end
        begin
          while (bgack_drv !== 1'b1) @(posedge clk);
          while (bgack_drv === 1'b1) begin
            @(negedge clk); #(SNAP);
            if (bg_n_o !== 1'b1) no_bg = 1'b0;
          end
        end
      join
      check(no_bg, "single-wire: BG is never asserted");
      check(got[31:0] === 32'h14151617, "single-wire: the request runs once BGACK negates");
      repeat (4) @(posedge clk);

      // ... and during a cycle: the cycle completes, then the bus goes. The
      // alternate master "waits for AS to negate before taking the bus".
      no_bg = 1'b1;
      fork
        begin
          @(negedge as_n_o);
          @(posedge clk);
          bgack_drv = 1'b1;
          @(posedge as_n_o);
          @(posedge clk); #(SNAP);
          check(a_oe === 1'b0 && as_oe === 1'b0,
                "single-wire during a cycle: released at the rising edge after AS negates (UM 7.7.4)");
          repeat (4) @(posedge clk);
          bgack_drv = 1'b0;
        end
        op_read(32'h3000_0108, 4, got, cycles);
      join
      check(got[31:0] === 32'h18191A1B && cycles == 1,
            "single-wire during a cycle: the cycle completes with its data");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Single-wire arbitration during a read-modify-write. It "applies to all
    // bus cycles of a read-modify-write sequence" (UM 7.7.4): the read
    // completes, and the bus is released with the write still to come and
    // RMC still logically asserted -- it is three-stated with the rest.
    // -------------------------------------------------------------------
    begin
      bit released, no_wr;
      int unsigned c0;
      released = 1'b0; no_wr = 1'b1;
      s32.mem[12'h180] = 8'h00;
      fork
        begin
          @(negedge as_n_o);
          #(SNAP);
          c0 = as_count;
          @(posedge clk);
          bgack_drv = 1'b1;
          @(posedge as_n_o);
          repeat (3) @(posedge clk);
          #(SNAP);
          released = (a_oe === 1'b0 && as_oe === 1'b0 && rmc_oe === 1'b0);
          repeat (6) @(posedge clk);
          if (as_count != c0) no_wr = 1'b0;
          bgack_drv = 1'b0;
        end
        begin
          req_rmc = 1'b1;
          op_read (32'h0000_0180, 1, got, cycles);
          op_write(32'h0000_0180, 1, 40'h80, cycles);
          req_rmc = 1'b0;
          op_read (32'h0000_0F00, 4, got, cycles);
        end
      join
      check(released, "single-wire during RMC: the bus, RMC included, is released after the read");
      check(no_wr, "single-wire during RMC: the write waits for BGACK to negate");
      check(s32.mem[12'h180] === 8'h80, "single-wire during RMC: the write then completes");
      $display("  .. single-wire arbitration done");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Relinquish and retry on the first read of a read-modify-write: "the
    // MC68030 allows normal bus arbitration during this read cycle; a normal
    // relinquish and retry operation (asserting BERR, HALT, and BR at the same
    // time) is used" (UM 7.7.4); "the MC68030 does not relinquish the bus
    // during a read-modify-write operation, except during the first read
    // cycle" (UM 7.5.2).
    // -------------------------------------------------------------------
    begin
      bit saw_bg, saw_rel, rmc_rerun;
      int unsigned c0;
      saw_bg = 1'b0; saw_rel = 1'b0; rmc_rerun = 1'b0;
      s32.mem[12'h184] = 8'h5A;
      c0 = as_count;
      fork
        begin
          assert_at_n(1'b1, 1'b1);
          br_drv = 1'b1;
          @(posedge as_n_o);
          @(posedge clk);
          berr_drv = 1'b0;
          halt_drv = 1'b0;
          // The retry waits for the bus to come back.
          while (bg_n_o !== 1'b0) @(posedge clk);
          saw_bg = 1'b1;
          @(posedge clk);
          bgack_drv = 1'b1;
          @(posedge clk);
          br_drv = 1'b0;
          repeat (3) @(posedge clk);
          #(SNAP);
          saw_rel = (bus_granted === 1'b1 && a_oe === 1'b0 && rmc_oe === 1'b0);
          repeat (4) @(posedge clk);
          bgack_drv = 1'b0;
          @(negedge as_n_o);
          #(SNAP);
          rmc_rerun = (rmc_n_o === 1'b0 && rmc_oe === 1'b1);
        end
        begin
          req_rmc = 1'b1;
          op_read (32'h0000_0184, 1, got, cycles);
          op_write(32'h0000_0184, 1, 40'hA5, cycles);
          req_rmc = 1'b0;
          op_read (32'h0000_0F00, 4, got, cycles);
        end
      join
      check(saw_bg, "relinquish and retry on an RMC's first read: BG is asserted");
      check(saw_rel, "relinquish and retry on an RMC's first read: the bus is released");
      check(rmc_rerun, "relinquish and retry on an RMC's first read: the rerun asserts RMC");
      check(as_count == c0 + 4, "relinquish and retry on an RMC's first read: read, rerun, write, next");
      check(s32.mem[12'h184] === 8'hA5, "relinquish and retry on an RMC's first read: the write completes");
      repeat (6) @(posedge clk);
    end

    // ... and on the WRITE of one, which is not the first read cycle: the bus
    // is not relinquished, the write is retried with RMC held, and only then
    // is the request granted.
    begin
      bit bg_in_rmc;
      bg_in_rmc = 1'b0;
      s32.mem[12'h188] = 8'h00;
      rmc_watch = 1'b1;
      fork
        begin
          @(negedge as_n_o);                       // the read
          @(posedge as_n_o);
          assert_at_n(1'b1, 1'b1);                 // the write
          br_drv = 1'b1;
          @(posedge as_n_o);
          @(posedge clk);
          berr_drv = 1'b0;
          halt_drv = 1'b0;
        end
        begin
          req_rmc = 1'b1;
          op_read (32'h0000_0188, 1, got, cycles);
          op_write(32'h0000_0188, 1, 40'h3C, cycles);
          req_rmc = 1'b0;
          rmc_watch = 1'b0;
        end
        begin
          while (rmc_watch) begin
            @(negedge clk); #(SNAP);
            if (rmc_n_o === 1'b0 && bg_n_o === 1'b0) bg_in_rmc = 1'b1;
          end
        end
      join
      check(!bg_in_rmc, "relinquish and retry on an RMC's write: BG is not asserted while RMC is");
      check(s32.mem[12'h188] === 8'h3C, "relinquish and retry on an RMC's write: the retried write lands");
      waited = 0;
      while (bg_n_o !== 1'b0 && waited < 20) begin @(posedge clk); waited = waited + 1; end
      check(bg_n_o === 1'b0, "relinquish and retry on an RMC's write: BR granted after the sequence");
      @(posedge clk);
      br_drv = 1'b0;
      $display("  .. relinquish and retry during RMC done");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Bursts. "For the purposes of ... arbitrating the bus away from the
    // processor with BR, a burst operation is a single cycle since AS remains
    // asserted during the entire operation" (UM 7.3.7): BG may be asserted
    // during the burst, as during any cycle -- "the bus will become available
    // at the end of the current bus cycle" (7.7) -- and the burst runs to its
    // end before the bus is released. BR at every clock of the burst.
    // -------------------------------------------------------------------
    begin
      int unsigned ph, b0, c0;
      bit bg_under_as;
      for (t = 0; t < 4096; t = t + 1) ss.mem[t] = t[7:0] ^ 8'h66;
      for (ph = 0; ph < 7; ph = ph + 1) begin
        b0 = 0;
        bg_under_as = 1'b0;
        c0 = as_count;
        req_burst = 1'b1;
        fork
          begin
            @(negedge as_n_o);
            repeat (ph) @(posedge clk);
            br_drv = 1'b1;
            while (as_n_o === 1'b0) begin
              @(negedge clk); #(SNAP);
              if (bg_n_o === 1'b0 && as_n_o === 1'b0) bg_under_as = 1'b1;
            end
            while (bg_n_o !== 1'b0) @(posedge clk);
            @(posedge clk);
            bgack_drv = 1'b1;
            br_drv = 1'b0;
            repeat (4) @(posedge clk);
            bgack_drv = 1'b0;
          end
          begin
            op_read(32'h4000_0100 + {ph[3:0], 4'h0}, 4, got, cycles);
            req_burst = 1'b0;
            op_read(32'h0000_0F00, 4, got, cycles);
          end
          begin
            // Every long word of the burst, counted as the bus unit reports it.
            int unsigned guard;
            guard = 0;
            while (b0 < 5 && guard < 400) begin
              @(negedge clk);
              if (beat_valid) b0 = b0 + 1;
              guard = guard + 1;
            end
          end
        join
        $sformat(what, "BR %0d clocks into a burst: four long words, then the next cycle (got %0d)",
                 ph, b0);
        check(b0 == 5, what);
        $sformat(what, "BR %0d clocks into a burst: two bus cycles in all (got %0d)", ph,
                 as_count - c0);
        check(as_count - c0 == 2, what);
        if (ph == 0) check(bg_under_as, "BR at the start of a burst: BG asserted before the burst ends");
        repeat (4) @(posedge clk);
      end
      // Single-wire arbitration does not cut a burst short either: the
      // alternate master "waits for AS to negate before taking the bus"
      // (UM 7.7.4), and AS stays asserted for the whole burst (7.3.7).
      begin
        int unsigned c0;
        bit cut;
        b0 = 0; cut = 1'b0;
        c0 = as_count;
        req_burst = 1'b1;
        fork
          begin
            @(negedge as_n_o);
            @(posedge clk);
            @(posedge clk);                       // the second long word
            bgack_drv = 1'b1;
            while (as_n_o === 1'b0) begin
              @(negedge clk); #(SNAP);
              if (as_n_o === 1'b0 && (as_oe !== 1'b1 || a_oe !== 1'b1)) cut = 1'b1;
            end
            repeat (2) @(posedge clk); #(SNAP);
            check(a_oe === 1'b0 && as_oe === 1'b0,
                  "BGACK during a burst: the bus is released after the burst");
            repeat (4) @(posedge clk);
            bgack_drv = 1'b0;
          end
          begin
            op_read(32'h4000_0180, 4, got, cycles);
            req_burst = 1'b0;
          end
          begin
            int unsigned guard;
            guard = 0;
            while (b0 < 4 && guard < 400) begin
              @(negedge clk);
              if (beat_valid) b0 = b0 + 1;
              guard = guard + 1;
            end
          end
        join
        check(b0 == 4 && !cut && as_count == c0 + 1,
              "BGACK during a burst: the burst completes, four long words, AS and the address driven");
      end
      $display("  .. arbitration during bursts done");
    end

    // -------------------------------------------------------------------
    // BR at every phase of a synchronous operand of two cycles (a long word
    // at offset 2 of a STERM port), as the asynchronous sweep above.
    // -------------------------------------------------------------------
    begin
      int unsigned ph;
      for (t = 0; t < 4096; t = t + 1) sn.mem[t] = t[7:0] ^ 8'h99;
      for (ph = 0; ph < 10; ph = ph + 1) begin
        fork
          begin
            repeat (ph) @(posedge clk);
            br_drv = 1'b1;
            repeat (6) @(posedge clk);
            br_drv = 1'b0;
          end
          op_read(32'h5000_0102, 4, got, cycles);
        join
        $sformat(what, "BR at phase %0d of a synchronous two-cycle operand: data (got %08h)",
                 ph, got[31:0]);
        check(got[31:0] === {8'h02 ^ 8'h99, 8'h03 ^ 8'h99, 8'h04 ^ 8'h99, 8'h05 ^ 8'h99}, what);
        $sformat(what, "BR at phase %0d: two bus cycles (got %0d)", ph, cycles);
        check(cycles == 2, what);
        @(posedge clk);
        br_drv    = 1'b0;
        bgack_drv = 1'b0;
        repeat (4) @(posedge clk);
      end
      $display("  .. synchronous BR phase sweep done");
    end

    // -------------------------------------------------------------------
    // Arbitration while halted, figure 7-57: "the halt operation has no effect
    // on bus arbitration. When bus arbitration occurs while the MC68030 is
    // halted, the address and control signals are also placed in the
    // high-impedance state. Once bus mastership is returned to the MC68030, if
    // HALT is still asserted, the address, function code, size, and
    // read/write signals are again driven to their previous states" (7.5.3).
    // -------------------------------------------------------------------
    begin
      logic [31:0] ah;
      logic  [2:0] fh;
      logic  [1:0] zh;
      logic        rh;
      bit rel, back;
      int unsigned c0;
      fork
        assert_at_n(1'b0, 1'b1);
        op_read(32'h0000_010C, 4, got, cycles);
      join
      repeat (2) @(posedge clk); #(SNAP);
      ah = a_o; fh = fc_o; zh = siz_o; rh = rw_o;
      check(a_oe === 1'b1 && ah === 32'h0000_010C, "halted: the address held, driven");
      c0 = as_count;
      fork
        begin
          @(posedge clk);
          br_drv = 1'b1;
          @(negedge bg_n_o);
          @(posedge clk);
          bgack_drv = 1'b1;
          @(posedge clk);
          br_drv = 1'b0;
          repeat (3) @(posedge clk); #(SNAP);
          rel = (a_oe === 1'b0 && fc_oe === 1'b0 && siz_oe === 1'b0 && rw_oe === 1'b0
                 && as_oe === 1'b0 && ds_oe === 1'b0);
          @(posedge clk);
          bgack_drv = 1'b0;
          repeat (4) @(posedge clk); #(SNAP);
          back = (a_oe === 1'b1 && a_o === ah && fc_oe === 1'b1 && fc_o === fh
                  && siz_oe === 1'b1 && siz_o === zh && rw_oe === 1'b1 && rw_o === rh
                  && as_oe === 1'b1 && as_n_o === 1'b1);
          repeat (4) @(posedge clk);
          halt_drv = 1'b0;
        end
        begin
          @(posedge clk);
          op_read(32'h0000_0110, 4, got, cycles);
        end
      join
      check(rel, "halted, bus granted: address and control are released (UM 7.5.3)");
      check(back, "halted, bus returned: address, FC, SIZ and R/W driven again to their previous states");
      check(got[31:0] === 32'h20212223, "halted: the pending cycle runs when HALT negates");
      check(as_count == c0 + 1, "halted: no cycle ran while halted or granted");

      // HALT asserted on an idle bus, with a request pending: no cycle starts,
      // so there is no "internal decision to execute a bus cycle" to defer the
      // grant behind (UM 7.7), and BR is granted as on any idle bus.
      c0 = as_count;
      @(posedge clk);
      halt_drv = 1'b1;
      repeat (4) @(posedge clk);
      fork
        begin
          repeat (4) @(posedge clk);
          br_drv = 1'b1;
          waited = 0;
          while (bg_n_o !== 1'b0 && waited < 20) begin @(posedge clk); waited = waited + 1; end
          $sformat(what, "halted on an idle bus with a request pending: BR granted (%0d clocks)", waited);
          check(bg_n_o === 1'b0 && waited <= 4, what);
          check(as_count == c0, "halted on an idle bus: the pending request did not start");
          @(posedge clk);
          br_drv = 1'b0;
          repeat (4) @(posedge clk);
          halt_drv = 1'b0;
        end
        op_read(32'h0000_0114, 4, got, cycles);
      join
      check(got[31:0] === 32'h24252627, "halted on an idle bus: the request runs once HALT negates");
      $display("  .. arbitration while halted done");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Double bus fault. The MC68020 drove HALT; the MC68030 has HALT as an
    // input only (UM Table 5-2) and "indicates that a double bus fault
    // condition has occurred by continuously asserting the STATUS signal until
    // the processor is reset" (UM 7.5.4). Arbitration still works while it is
    // halted -- "bus arbitration can still occur" -- which the BR checks above
    // do not depend on, so it is checked here with the fault standing.
    // -------------------------------------------------------------------
    check(status_n_o === 1'b1, "no double bus fault: STATUS is negated");
    @(posedge clk);
    dbf_drv = 1'b1;
    @(posedge clk);
    begin
      bit held;
      held = 1'b1;
      repeat (20) begin
        @(negedge clk); #(SNAP);
        if (status_n_o !== 1'b0) held = 1'b0;
      end
      check(held, "double bus fault: STATUS is asserted continuously (UM 7.5.4)");
      br_drv = 1'b1;
      waited = 0;
      while (bg_n_o !== 1'b0 && waited < 20) begin
        @(posedge clk);
        waited = waited + 1;
      end
      check(bg_n_o === 1'b0, "double bus fault: arbitration still grants the bus (UM 7.5.4)");
      br_drv = 1'b0;
      repeat (6) @(posedge clk);
    end
    dbf_drv = 1'b0;

    $display("bus_arb_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_arb_tb");
    else                                     $display("FAIL: bus_arb_tb");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: bus_arb_tb timed out");
    $finish;
  end

endmodule
