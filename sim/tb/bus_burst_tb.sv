// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- burst operation: CBREQ and CBACK, UM 7.3.7 and 6.1.3.2.
//
// "When the MC68030 recognizes STERM and CBACK and it has asserted CBREQ, it
// maintains AS, DS, R/W, A0-A31, FC0-FC2, SIZ0-SIZ1 in their current state
// throughout the burst operation. The processor continues to accept data on every
// clock during which STERM is asserted until the burst is complete or an abnormal
// termination occurs." (UM 7.3.7)
//
// No requester in the core asks for a burst until the caches of M10, so this
// drives the bus unit's request port directly: req_burst / fetch_burst say a
// line fill is allowed, and every long word the bus delivers comes back on the
// beat_* port. The device at $4000_0000 (sim/models/rd68031_slave.sv) bursts, and
// increments A3/A2 itself, wrapping in the line, as UM 7.3.7 requires of external
// hardware.
//
// What this checks:
//
//   1. A full four-long-word burst: the pins state by state, CBREQ negated after
//      the third long word, the address held, the wrap, and the operand's own
//      data available after the first long word.
//   2. Wait states in the first access and between beats (figure 7-38).
//   3. CBACK negated early: one, two and three long words (figure 7-39); a
//      device that never bursts; an asynchronous device, whose CBACK is ignored.
//   4. CIIN on the first long word and on a later one (figure 7-41).
//   5. Misaligned operands: within the line, the rest comes from the burst;
//      across a line, the first cycle has no CBREQ (figure 7-40).
//   6. BERR on the first access (an exception), on a later one (no exception;
//      figure 7-52), and on the long word that carried the rest of a misaligned
//      operand, which is read again with CBREQ negated (figure 7-53).
//   7. Retry on the first access asserts CBREQ again (figure 7-56); BERR and HALT
//      on a later access are a bus error and a halt, not a retry.
//   8. HALT and BR during a burst wait for its end: "a burst operation is a
//      single cycle".
//   9. No CBREQ for a write, a read-modify-write, or a CIOUT access (UM 6.1.3.2).
//  10. The instruction fetch port bursts the same way.

`timescale 1ns / 1ps

module bus_burst_tb;

`include "rd68031_bus_harness.svh"

  logic [39:0] got;
  logic [31:0] fgot;
  int unsigned cycles;
  int unsigned t, n, k;
  logic [31:0] addr;
  string       what;

  // -------------------------------------------------------------------------
  // The beat recorder: every long word the bus unit reports.
  // -------------------------------------------------------------------------
  localparam int MAXB = 512;
  int unsigned nb;
  logic [31:0] b_addr [0:MAXB-1];
  logic [31:0] b_data [0:MAXB-1];
  logic  [1:0] b_num  [0:MAXB-1];
  logic        b_ciin [0:MAXB-1];
  logic        b_err  [0:MAXB-1];
  logic        b_fetch[0:MAXB-1];
  initial nb = 0;

  always @(negedge clk) begin
    if (rst_n && (beat_valid || beat_err)) begin
      if (nb < MAXB) begin
        b_addr[nb]  = beat_addr;
        b_data[nb]  = beat_data;
        b_num[nb]   = beat_num;
        b_ciin[nb]  = beat_ciin;
        b_err[nb]   = beat_err;
        b_fetch[nb] = beat_fetch;
      end
      nb = nb + 1;
    end
  end

  // Edge times of the most recent AS, CBREQ and DBEN assertion, and whether
  // CBREQ was asserted in each of the last cycles.
  realtime t_as_lo, t_as_hi, t_cb_lo, t_cb_hi, t_ack, t_dben_lo, t_dben_hi;
  int unsigned cbreq_cycles;
  bit          cbreq_seen;
  initial begin cbreq_cycles = 0; cbreq_seen = 1'b0; end
  always @(negedge as_n_o)    begin t_as_lo = $realtime; cbreq_seen = 1'b0; end
  always @(posedge as_n_o)    t_as_hi = $realtime;
  always @(negedge cbreq_n_o) begin
    t_cb_lo = $realtime;
    if (rst_n) begin cbreq_cycles = cbreq_cycles + 1; cbreq_seen = 1'b1; end
  end
  always @(posedge cbreq_n_o) t_cb_hi = $realtime;
  always @(negedge dben_n_o)  t_dben_lo = $realtime;
  always @(posedge dben_n_o)  t_dben_hi = $realtime;

  // While AS is asserted, the address, SIZ, FC and R/W must not move (UM 7.3.7).
  int unsigned held_violations;
  logic [31:0] a_at_as;
  logic  [1:0] siz_at_as;
  initial held_violations = 0;
  always @(negedge as_n_o) begin #(SNAP); a_at_as = a_o; siz_at_as = siz_o; end
  always @(posedge clk or negedge clk) begin
    #(SNAP);
    if (rst_n && !as_n_o && (t_as_lo < $realtime - SNAP)
        && ((a_o !== a_at_as) || (siz_o !== siz_at_as))) begin
      held_violations = held_violations + 1;
      $display("  FAIL: the address or SIZ moved under AS at %0t", $time);
    end
  end

  function automatic logic [7:0] pat(input logic [31:0] a_);
    pat = 8'h5C ^ a_[7:0] ^ {a_[11:8], 4'h0};
  endfunction

  function automatic logic [31:0] long_at(input logic [31:0] a_);
    long_at = {pat({a_[31:2], 2'b00}), pat({a_[31:2], 2'b01}),
               pat({a_[31:2], 2'b10}), pat({a_[31:2], 2'b11})};
  endfunction

  function automatic logic [39:0] expect_at(input logic [31:0] a_, input int nbytes);
    logic [39:0] v;
    int unsigned i;
    v = '0;
    for (i = 0; i < nbytes; i = i + 1) v = {v[31:0], pat(a_ + i)};
    expect_at = v;
  endfunction

  task automatic paint();
    int unsigned i;
    for (i = 0; i < 4096; i = i + 1) begin
      ss.mem[i]  = pat(i);
      sn.mem[i]  = pat(i);
      s32.mem[i] = pat(i);
    end
  endtask

  task automatic knobs_default();
    ss.waits_rt    = 0;
    ss.bwaits_rt   = 0;
    ss.burst_limit = 4;
    ss.ciin_all    = 1'b0;
    ss.ciin_beats  = 4'b0000;
    req_burst      = 1'b0;
    req_ciout      = 1'b0;
    req_rmc        = 1'b0;
    fetch_burst    = 1'b0;
    cback_force    = 1'b0;
  endtask

  task automatic wait_idle();
    while (!bus_idle) @(negedge clk);
    @(negedge clk);
  endtask

  // Assert BERR (and HALT) on the rising edge that the k-th long word's STERM is
  // tested on, with no wait states -- so that it is recognised on the falling
  // edge that would latch that long word.
  task automatic exc_at_beat(input int kk, input bit berr, input bit halt,
                             input int hold);
    @(negedge as_n_o);
    repeat (kk + 1) @(posedge clk);
    berr_drv = berr;
    halt_drv = halt;
    repeat (hold) @(posedge clk);
    berr_drv = 1'b0;
    halt_drv = 1'b0;
  endtask

  // The beats expected of a burst from a long word at a: k = 0.. n-1.
  task automatic expect_beats(input string name, input int first, input logic [31:0] a_,
                              input int count);
    int unsigned i;
    logic [31:0] ba;
    for (i = 0; i < count; i = i + 1) begin
      ba = {a_[31:4], a_[3:2] + i[1:0], 2'b00};
      $sformat(what, "%s: beat %0d is the long word at %08h, %08h (got %08h, %08h)",
               name, i, ba, long_at(ba), b_addr[first + i], b_data[first + i]);
      check((b_addr[first + i] === ((i == 0) ? a_ : ba))
            && (b_data[first + i] === long_at(ba))
            && (b_num[first + i] == i[1:0]) && !b_err[first + i], what);
    end
  endtask

  int unsigned nb0, as0, oc0;

  initial begin
    $display("bus_burst_tb: burst operation, UM 7.3.7");
    reset_dut();
    paint();
    knobs_default();

    // =====================================================================
    // 1. A full burst. A long word at $4000_0104: A3/A2 = 01, so the line is
    // filled $104, $108, $10C and then, wrapping, $100 -- "the count sequence
    // wraps back to zero" (UM 7.3.7), figure 6-12.
    // =====================================================================
    nb0 = nb; as0 = as_count; oc0 = ocs_count;
    req_burst = 1'b1;
    fork
      op_read(32'h4000_0104, 4, got, cycles);
      begin
        @(posedge req_ack);
        t_ack = $realtime;
        check(!as_n_o, "full burst: the operand is acknowledged while AS is still asserted (UM 6.1.3.2)");
      end
    join
    req_burst = 1'b0;
    wait_idle();
    check(got[31:0] === long_at(32'h104), "full burst: the operand's data");
    check(as_count == as0 + 1, "full burst: one bus cycle, AS asserted once (UM 7.3.7)");
    check(ocs_count == oc0 + 1, "full burst: one OCS");
    $sformat(what, "full burst: four long words reported (got %0d)", nb - nb0);
    check(nb - nb0 == 4, what);
    expect_beats("full burst", nb0, 32'h4000_0104, 4);
    // AS from S1 to the falling edge after the fourth STERM: one clock for the
    // first long word, and one for each of the other three -- "the second,
    // third, and fourth cycles latch data on successive falling edges of the
    // clock at a minimum" (UM 7.2.10).
    $sformat(what, "full burst: AS asserted four clocks (got %0.1f ns)", t_as_hi - t_as_lo);
    check(t_as_hi - t_as_lo == 4.0 * CLK_PERIOD, what);
    // CBREQ with AS in S1, negated "during S7" -- after the third long word
    // (UM 7.3.7, specifications 9 and 12).
    check(t_cb_lo == t_as_lo, "full burst: CBREQ asserted with AS, in S1 (UM 7.3.4 state 1)");
    $sformat(what, "full burst: CBREQ negated after the third long word, three clocks (got %0.1f ns)",
             t_cb_hi - t_cb_lo);
    check(t_cb_hi - t_cb_lo == 3.0 * CLK_PERIOD, what);
    // DBEN from S2 to the end: "the processor maintains AS, DS, and DBEN
    // asserted during S3" (UM 7.3.7 state 3) and negates them in S9.
    $sformat(what, "full burst: DBEN asserted from S2 to the end (got %0.1f ns)",
             t_dben_hi - t_dben_lo);
    check((t_dben_hi == t_as_hi) && (t_dben_hi - t_dben_lo == 3.5 * CLK_PERIOD), what);
    // The operand was ready after the first long word: one clock after S1, plus
    // half a clock to the rising edge that ends the first latch.
    $sformat(what, "full burst: the acknowledge came after the first long word (%0.1f ns after AS)",
             t_ack - t_as_lo);
    check(t_ack - t_as_lo == 1.5 * CLK_PERIOD, what);
    check(req_ciin === 1'b0 && req_end == 3'd6, "full burst: no CIIN, CE_STERM");

    // =====================================================================
    // 2. Wait states -- figure 7-38: "two wait states inserted in the first
    // access and one wait cycle inserted in the subsequent accesses". AS is
    // asserted 1 + 2 for the first long word and 2 for each of the others.
    // =====================================================================
    ss.waits_rt = 2; ss.bwaits_rt = 1;
    nb0 = nb;
    req_burst = 1'b1;
    op_read(32'h4000_0107, 4, got, cycles);
    req_burst = 1'b0;
    wait_idle();
    check(got[31:0] === expect_at(32'h107, 4),
          "waited burst from $07: the operand, half from the first long word, half from the second");
    check(nb - nb0 == 4, "waited burst: four long words");
    expect_beats("waited burst", nb0, 32'h4000_0107, 4);
    $sformat(what, "waited burst: AS asserted 3 + 3 x 2 = 9 clocks (got %0.1f ns)",
             t_as_hi - t_as_lo);
    check(t_as_hi - t_as_lo == 9.0 * CLK_PERIOD, what);
    check(cycles == 1, "waited burst: the misaligned operand took one bus cycle");
    knobs_default();

    // =====================================================================
    // 3. CBACK negated early -- figure 7-39. "The premature negation of the
    // CBACK signal during the burst operation causes the current cycle to
    // complete normally ... However, the burst operation aborts and CBREQ
    // negates" (UM 6.1.3.2). CBACK goes with the long word before: a device
    // that can supply k long words asserts it with the first k - 1.
    // =====================================================================
    for (k = 1; k <= 3; k = k + 1) begin
      ss.burst_limit = k;
      nb0 = nb;
      req_burst = 1'b1;
      op_read(32'h4000_0208, 4, got, cycles);
      req_burst = 1'b0;
      wait_idle();
      $sformat(what, "CBACK for %0d long words: the operand", k);
      check(got[31:0] === long_at(32'h208), what);
      $sformat(what, "CBACK for %0d long words: %0d reported (got %0d)", k, k, nb - nb0);
      check(nb - nb0 == k, what);
      expect_beats("partial burst", nb0, 32'h4000_0208, k);
      $sformat(what, "CBACK for %0d long words: AS asserted %0d clocks", k, k);
      check(t_as_hi - t_as_lo == k * CLK_PERIOD, what);
    end
    knobs_default();

    // A synchronous device that does not burst: it "should not acknowledge the
    // request with the assertion of CBACK" (UM 6.1.3.2). One two-clock cycle.
    nb0 = nb;
    req_burst = 1'b1;
    op_read(32'h5000_0300, 4, got, cycles);
    req_burst = 1'b0;
    wait_idle();
    check(cbreq_seen, "no-burst device: CBREQ was asserted");
    check(got[31:0] === long_at(32'h300) && nb - nb0 == 1,
          "no-burst device: one long word, the operand");
    check(t_as_hi - t_as_lo == CLK_PERIOD, "no-burst device: a two-clock cycle");

    // An asynchronous device with CBACK asserted all along: "the MC68030 ignores
    // the assertion of CBACK during cycles terminated with DSACKx" (UM 6.1.3.2,
    // 7.2.8).
    nb0 = nb;
    req_burst = 1'b1;
    @(posedge clk); cback_force = 1'b1;
    op_read(32'h0000_0300, 4, got, cycles);
    @(posedge clk); cback_force = 1'b0;
    req_burst = 1'b0;
    wait_idle();
    check(cbreq_seen, "DSACK device: CBREQ was asserted (the cycle could have burst)");
    check(got[31:0] === long_at(32'h300) && nb - nb0 == 1 && req_end == 3'd1,
          "DSACK device with CBACK asserted: one asynchronous cycle, CBACK ignored (UM 7.2.8)");
    check(t_as_hi - t_as_lo == 2.0 * CLK_PERIOD, "DSACK device: a three-clock cycle");

    // =====================================================================
    // 4. CIIN. On the first long word: "the data is latched by the processor,
    // and if the requested operand is aligned ... passed on ... However, the
    // data is not loaded into its corresponding cache. In addition, the MC68030
    // negates CBREQ, and the burst operation is aborted" (UM 6.1.3.2).
    // =====================================================================
    ss.ciin_beats = 4'b0001;
    nb0 = nb;
    req_burst = 1'b1;
    op_read(32'h4000_0400, 4, got, cycles);
    req_burst = 1'b0;
    wait_idle();
    check(got[31:0] === long_at(32'h400), "CIIN on the first long word: the operand is used");
    check(req_ciin === 1'b1, "CIIN on the first long word: reported with the operand");
    check(nb - nb0 == 1 && b_ciin[nb0] === 1'b1,
          "CIIN on the first long word: no burst, the long word marked not cachable");

    // On the third: "prevents the data during that cycle from being loaded
    // into the appropriate cache and causes CBREQ to negate, aborting the burst"
    // -- figure 7-41.
    ss.ciin_beats = 4'b0100;
    nb0 = nb;
    req_burst = 1'b1;
    op_read(32'h4000_0400, 4, got, cycles);
    req_burst = 1'b0;
    wait_idle();
    check(nb - nb0 == 3, "CIIN on the third long word: the burst ends with it");
    check(!b_ciin[nb0] && !b_ciin[nb0 + 1] && b_ciin[nb0 + 2],
          "CIIN on the third long word: only that one is marked");
    check(req_ciin === 1'b0, "CIIN on a long word the operand did not use: not the operand's");
    expect_beats("CIIN on the third", nb0, 32'h4000_0400, 3);
    knobs_default();

    // CIIN on the long word that carried the rest of a misaligned operand: "if
    // the data for the cycle contains part of the requested operand, the
    // execution unit uses that data" (UM 6.1.3.2).
    ss.ciin_beats = 4'b0010;
    nb0 = nb; as0 = as_count;
    req_burst = 1'b1;
    op_read(32'h4000_040E - 32'h4, 4, got, cycles);   // $40A: two bytes, then two
    req_burst = 1'b0;
    wait_idle();
    check(got[31:0] === expect_at(32'h40A, 4) && as_count == as0 + 1,
          "CIIN on the second long word of a misaligned operand: used, no extra cycle");
    check(req_ciin === 1'b1, "... and the operand is reported not cachable");
    check(nb - nb0 == 2, "... and the burst stops there");
    knobs_default();

    // =====================================================================
    // 5. Misaligned operands. Within the line, from $07: the operand is the
    // first long word's last byte and the next's first three (figure 7-38).
    // Across a line, from $0E: "the MC68030 does not assert CBREQ during the
    // first portion of a misaligned access if the remainder of the access does
    // not correspond to the same cache line" (UM 7.3.7) -- figure 7-40.
    // =====================================================================
    nb0 = nb; as0 = as_count; oc0 = ocs_count;
    req_burst = 1'b1;
    op_read(32'h4000_0507, 4, got, cycles);
    req_burst = 1'b0;
    wait_idle();
    check(got[31:0] === expect_at(32'h507, 4), "misaligned within the line: the operand");
    check(as_count == as0 + 1 && ocs_count == oc0 + 1,
          "misaligned within the line: one cycle -- the burst brought the rest");
    check(nb - nb0 == 4, "misaligned within the line: the whole line");

    nb0 = nb; as0 = as_count; t = cbreq_cycles;
    req_burst = 1'b1;
    fork
      op_read(32'h4000_050E, 4, got, cycles);
      begin
        @(negedge as_n_o); #(SNAP);
        check(cbreq_n_o === 1'b1, "across a line: the first cycle, at $0E, has no CBREQ (figure 7-40)");
        check(siz_o == 2'b00, "across a line: the first cycle asks for a long word");
        @(posedge as_n_o);
        @(negedge as_n_o); #(SNAP);
        check(cbreq_n_o === 1'b0, "across a line: the second cycle, at $10, asserts CBREQ");
        check(a_o === 32'h4000_0510 && siz_o == 2'b10,
              "across a line: the second cycle is at $10 for the two bytes left");
      end
    join
    req_burst = 1'b0;
    wait_idle();
    check(got[31:0] === expect_at(32'h50E, 4), "across a line: the operand");
    check(as_count == as0 + 2, "across a line: two bus cycles");
    $sformat(what, "across a line: one entry fill then a burst of four (got %0d long words)",
             nb - nb0);
    check(nb - nb0 == 5, what);
    check(b_addr[nb0 + 1] === 32'h4000_0510 && b_addr[nb0 + 4] === 32'h4000_051C,
          "across a line: the burst fills $10..$1C");

    // =====================================================================
    // 6. Bus errors. On the first access: "the data is ignored, the entire
    // cache line is marked invalid, and the burst operation is aborted. ... If
    // the cycle is for a data fetch, the bus error exception is taken
    // immediately" (UM 7.5.1).
    // =====================================================================
    begin
      bit sf;
      nb0 = nb;
      req_burst = 1'b1;
      fork
        begin
          exc_at_beat(0, 1'b1, 1'b0, 1);
          @(posedge req_ack); sf = req_fault;
        end
        op_read(32'h4000_0600, 4, got, cycles);
      join
      req_burst = 1'b0;
      wait_idle();
      check(sf, "BERR on the first access: a bus error exception (UM 7.5.1)");
      check(nb - nb0 == 1 && b_err[nb0], "BERR on the first access: no burst, the long word invalid");
      check(t_as_hi - t_as_lo == CLK_PERIOD, "BERR on the first access: the cycle ends at once");
    end

    // On a later access -- figure 7-52, "late BERR on third access ends burst;
    // no exception taken".
    begin
      bit sf;
      nb0 = nb;
      req_burst = 1'b1;
      fork
        begin
          exc_at_beat(2, 1'b1, 1'b0, 1);
        end
        begin
          op_read(32'h4000_0604, 4, got, cycles);
          sf = req_fault;
        end
      join
      req_burst = 1'b0;
      wait_idle();
      check(!sf, "BERR on the third access: no exception (UM 7.5.1)");
      check(got[31:0] === long_at(32'h604), "BERR on the third access: the operand is good");
      check(nb - nb0 == 3 && !b_err[nb0] && !b_err[nb0 + 1] && b_err[nb0 + 2],
            "BERR on the third access: two long words, the third marked invalid");
      check(t_as_hi - t_as_lo == 3.0 * CLK_PERIOD, "BERR on the third access: the burst ends there");
    end

    // On the second access, which carried the rest of a misaligned operand --
    // figure 7-53: "the processor runs another read cycle for the second
    // portion with CBREQ negated".
    begin
      bit sf;
      nb0 = nb; as0 = as_count;
      req_burst = 1'b1;
      fork
        begin
          exc_at_beat(1, 1'b1, 1'b0, 1);
          @(negedge as_n_o); #(SNAP);
          check(cbreq_n_o === 1'b1, "BERR on the operand's second long word: rerun with CBREQ negated");
          check(a_o === 32'h4000_0708 && siz_o == 2'b11,
                "BERR on the operand's second long word: the rerun is the three bytes at $08");
        end
        begin
          op_read(32'h4000_0707, 4, got, cycles);
          sf = req_fault;
        end
      join
      req_burst = 1'b0;
      wait_idle();
      check(!sf && got[31:0] === expect_at(32'h707, 4),
            "BERR on the operand's second long word: no exception, the operand completes");
      check(as_count == as0 + 2, "... in two bus cycles");
    end

    // "If BERR is asserted again, the MC68030 then takes an exception."
    begin
      bit sf; logic [31:0] fa; logic [2:0] fb;
      req_burst = 1'b1;
      fork
        begin
          exc_at_beat(1, 1'b1, 1'b0, 1);
          @(negedge as_n_o);
          @(posedge clk);
          berr_drv = 1'b1;
          @(posedge req_ack);
          sf = req_fault; fa = flt_addr; fb = flt_bytes;
          @(posedge clk);
          berr_drv = 1'b0;
        end
        op_read(32'h4000_0717, 4, got, cycles);
      join
      req_burst = 1'b0;
      wait_idle();
      check(sf, "BERR again on the rerun of the second portion: the exception is taken");
      check(fa === 32'h4000_0718 && fb == 3'd3,
            "... and the fault is the three bytes at $18");
    end

    // =====================================================================
    // 7. Retry. "On the initial access of a burst operation, a retry ...
    // causes the processor to retry the bus cycle and assert CBREQ again"
    // (UM 7.5.2) -- figure 7-56.
    // =====================================================================
    nb0 = nb; as0 = as_count; t = cbreq_cycles;
    req_burst = 1'b1;
    fork
      exc_at_beat(0, 1'b1, 1'b1, 2);
      op_read(32'h4000_0800, 4, got, cycles);
    join
    req_burst = 1'b0;
    wait_idle();
    check(got[31:0] === long_at(32'h800), "retry on the first access: the operand");
    check(as_count == as0 + 2, "retry on the first access: the cycle runs twice");
    check(cbreq_cycles == t + 2, "retry on the first access: CBREQ asserted again");
    check(nb - nb0 == 4, "retry on the first access: the rerun bursts the whole line");

    // "Signaling a retry with simultaneous BERR and HALT during the second,
    // third, or fourth cycle of a burst operation does not cause a retry
    // operation ... causes independent BERR and HALT operations. The external
    // bus activity remains halted until HALT is negated" (UM 7.5.2).
    begin
      bit sf;
      nb0 = nb; as0 = as_count;
      req_burst = 1'b1;
      fork
        begin
          @(negedge as_n_o);
          repeat (2) @(posedge clk);
          berr_drv = 1'b1; halt_drv = 1'b1;
          @(posedge clk);
          berr_drv = 1'b0;
        end
        begin
          op_read(32'h4000_0810, 4, got, cycles);
          sf = req_fault;
        end
      join
      req_burst = 1'b0;
      repeat (6) @(posedge clk);
      check(!sf && got[31:0] === long_at(32'h810),
            "BERR and HALT on the second access: no retry, no exception");
      check(as_count == as0 + 1 && nb - nb0 == 2 && b_err[nb0 + 1],
            "... the burst ends, the second long word invalid");
      as0 = as_count;
      fork
        begin
          repeat (6) @(posedge clk);
          check(as_count == as0, "... and the bus stays halted while HALT is asserted");
          halt_drv = 1'b0;
        end
        op_read(32'h4000_0820, 4, got, cycles);
      join
      check(got[31:0] === long_at(32'h820), "... until HALT is negated");
      wait_idle();
    end

    // =====================================================================
    // 8. HALT and BR wait for the end of a burst: "for the purposes of halting
    // the processor or arbitrating the bus away from the processor with BR, a
    // burst operation is a single cycle since AS remains asserted during the
    // entire operation" (UM 7.3.7).
    // =====================================================================
    nb0 = nb;
    req_burst = 1'b1;
    fork
      begin
        @(negedge as_n_o);
        @(posedge clk);
        halt_drv = 1'b1;
      end
      op_read(32'h4000_0900, 4, got, cycles);
    join
    req_burst = 1'b0;
    repeat (8) @(posedge clk);
    check(nb - nb0 == 4, "HALT during a burst: the burst completes all four long words");
    check(as_n_o === 1'b1 && !bus_idle, "HALT during a burst: then the bus halts");
    halt_drv = 1'b0;
    wait_idle();

    nb0 = nb;
    req_burst = 1'b1;
    fork
      begin
        @(negedge as_n_o);
        @(posedge clk);
        br_drv = 1'b1;
        while (as_n_o === 1'b0) begin
          @(negedge clk); #(SNAP);
          if (!as_n_o && (!as_oe || !a_oe || bus_granted)) begin
            check(1'b0, "BR during a burst: the bus was released under AS");
          end
        end
      end
      op_read(32'h4000_0A00, 4, got, cycles);
    join
    req_burst = 1'b0;
    repeat (6) @(posedge clk);
    check(nb - nb0 == 4, "BR during a burst: the burst completes");
    check(bus_granted === 1'b1 && bg_n_o === 1'b0,
          "BR during a burst: the bus is granted at its end (UM 7.7)");
    @(posedge clk); bgack_drv = 1'b1; br_drv = 1'b0;
    repeat (4) @(posedge clk);
    bgack_drv = 1'b0;
    repeat (4) @(posedge clk);

    // =====================================================================
    // 9. No CBREQ -- UM 6.1.3.2: "the current operation is the read portion of
    // a read-modify-write operation", "the MMU has inhibited caching for the
    // current page"; and a burst fills a cache, so never on a write.
    // =====================================================================
    t = cbreq_cycles;
    req_burst = 1'b1;
    op_write(32'h4000_0B00, 4, 40'h00_0BADF00D, cycles);
    check(cbreq_cycles == t, "a write: no CBREQ");
    req_rmc = 1'b1;
    op_read(32'h4000_0B00, 4, got, cycles);
    check(cbreq_cycles == t, "a read-modify-write read: no CBREQ (UM 7.3.3)");
    check(got[31:0] === 32'h0BADF00D, "a read-modify-write read: the data");
    req_rmc = 1'b0;
    req_burst = 1'b0;
    op_read(32'h0000_0B00, 4, got, cycles);    // let RMC go
    req_burst = 1'b1;
    req_ciout = 1'b1;
    op_read(32'h4000_0B10, 4, got, cycles);
    check(cbreq_cycles == t, "a CIOUT access: no CBREQ");
    req_ciout = 1'b0;
    req_burst = 1'b0;
    op_read(32'h4000_0B10, 4, got, cycles);
    check(cbreq_cycles == t, "a request that does not ask for a burst: no CBREQ");
    wait_idle();

    // =====================================================================
    // 10. The instruction fetch port: the instruction cache's burst.
    // =====================================================================
    nb0 = nb;
    fetch_burst = 1'b1;
    op_fetch(32'h4000_0C0A, fgot, cycles);
    fetch_burst = 1'b0;
    wait_idle();
    check(fgot === long_at(32'h4000_0C08), "fetch burst: the prefetch long word");
    check(nb - nb0 == 4 && b_fetch[nb0] && b_fetch[nb0 + 3],
          "fetch burst: four long words, marked as instruction fetches");
    expect_beats("fetch burst", nb0, 32'h4000_0C08, 4);

    check(held_violations == 0, "the address and SIZ were held under AS throughout (UM 7.3.7)");
    $display("bus_burst_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_burst_tb");
    else                                     $display("FAIL: bus_burst_tb");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: bus_burst_tb timed out");
    $finish;
  end

endmodule
