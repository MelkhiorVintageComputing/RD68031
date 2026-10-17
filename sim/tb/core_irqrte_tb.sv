// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- an interrupt recognised, interrupted by a bus error, and taken
// after the bus error handler's RTE, with the IPL pins moving in between.
//
// UM 8.1.9: an interrupt is recognised when its level is above the mask (or is
// a transition to level 7), and the acknowledge that follows carries THAT level
// on A3-A1 -- UM 7.4.1, figure 7-42. The level is the one recognised: whatever
// the pins do afterwards, an acknowledge for level 0 is never legal, because
// level 0 is "no interrupt request".
//
// The case that matters here is doc/checkpoint.md rule 9: a user write is
// posted, the next boundary dispatches to the interrupt, and the write's bus
// error lands before the acknowledge. The fault frame (format $B, DF set for a
// write) carries the level being taken in its internal word at +$08, the
// handler returns with RTE, RTE reruns the write and resumes the interrupt
// entry -- and the acknowledge must ask for the level in the frame, not for
// what the pins say by then. NetBSD/sun3x on the core met it twice: the board
// had dropped its request during the bus error handler, the core acknowledged
// level 0, the board answered $00, and vector 0 was taken (doc/bugs-found.md).
//
// The race is narrow: it needs the bus error to land on the entry's FIRST
// microword -- one clock, before the mask is raised -- so that the frame's
// resume point is the entry itself and RTE steps into it again. Two things
// make it reachable. The instructions after the faulting write run out of the
// instruction cache, so the interrupt can be dispatched at any of their
// boundaries while the write is on the bus; and the write goes to a slow
// 16-bit port whose bus error is given k clocks into the cycle. The request
// is raised at clock r around the write, and every (r, k) of a window is run
// with it held until acknowledged ("hold": every acknowledge asks for level 5,
// the handler runs); the testbench fails if none of them puts the fault on
// the entry's first microword. For the first such (r, k) pairs the pins then
// move at every third clock d from the bus error to past RTE's resume:
//
//   drop     to 0. No acknowledge ever asks for level 0, and the first one
//            after the resume asks for the level the frame carries -- 5,
//            once the pins move after the recognition.
//   change   to 3. The same: the level recognised, not the one the pins say.
//
// The bus error handler runs at mask 0, as NetBSD's did, so a request still up
// at its first boundary is simply taken there -- legitimately, at its own
// level. The resume is what is checked.

`timescale 1ns / 1ps

module core_irqrte_tb;

`include "rd68031_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] USP0 = 32'h0000_3000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] HAND = 32'h0000_0500;  // autovector 5 and 3
  localparam logic [31:0] BEH  = 32'h0000_0600;  // bus error
  localparam logic [31:0] SPIN = 32'h0000_9000;  // every other vector
  localparam logic [31:0] GONE = 32'h1000_8000;  // the 16-bit port, slowed down
  localparam logic [31:0] OKW  = 32'h0000_7000;  // the first pass's write
  localparam logic [31:0] ENDP = CODE + 32'd54;  // the program's last BRA *
  localparam logic [31:0] FRM  = ISP0 - 32'h5C;  // the long frame, UM Table 8-6

  // The interrupt entry's microwords up to its acknowledge -- tools/ucode
  // `exc_irq`: the copy of SR, the mask, the acknowledge.
  localparam logic [15:0] E0 = 16'(rd68031_ucode_pkg::ENTRY_IRQ);

  bit          reached;
  int unsigned d, dmax;
  int          r, k;
  string       what;

  // Clocks since reset was released: the request is raised at a fixed one.
  int unsigned cyc;
  always @(posedge clk) cyc = rst_n ? cyc + 1 : 0;

  // ------------------------------------------------------------------------
  // The bus error: on the first cycle to the faulting page, k rising edges
  // into it -- the port takes 48, so the bus error always comes first.
  // Then the page is ordinary memory, so RTE's rerun completes.
  // ------------------------------------------------------------------------
  bit          fault_en;
  int unsigned fault_k, as_edges, berrs, berr_cyc;
  initial begin fault_en = 1'b0; fault_k = 0; as_edges = 0; berrs = 0; berr_cyc = 0; end
  wire on_gone = rst_n && as_oe && !as_n_o && (a_o[31:12] == GONE[31:12]);
  always @(posedge clk) as_edges = on_gone ? as_edges + 1 : 0;
  wire tb_fault = fault_en && on_gone && (as_edges >= fault_k);
  always @(posedge tb_fault) begin
    if (berrs == 0) berr_cyc = cyc;
    berrs = berrs + 1;
  end
  always @(posedge as_n_o) if (berrs != 0) fault_en = 1'b0;

  // d clocks after the bus error.
  task automatic after_berr(input int unsigned dd);
    while (berrs == 0) @(posedge clk);
    while (cyc < berr_cyc + dd) @(posedge clk);
  endtask

  // ------------------------------------------------------------------------
  // The device on the other end of the acknowledge. It autovectors every level
  // it is asked about (UM 7.4.1.2) except 0, which no device answers -- a bus
  // error, the spurious interrupt. Every acknowledge is recorded with its
  // level, and one for level 0 is a failure wherever it happens.
  // ------------------------------------------------------------------------
  wire iack_now = !as_n_o && (fc_o === 3'b111) && (a_o[19:16] === 4'hF);

  int unsigned iacks, iack0, iack_bad, iacks_resumed, resume_cyc;
  logic  [2:0] iack_resumed;   // the first acknowledge after RTE's resume
  bit          resumed;
  bit          drop_at_iack;
  logic  [2:0] want_level;     // what every acknowledge may ask for, 0 = any
  initial begin
    iacks = 0; iack0 = 0; iack_bad = 0; iacks_resumed = 0; resume_cyc = 0;
    iack_resumed = 3'd0; resumed = 1'b0; drop_at_iack = 1'b0; want_level = 3'd0;
  end

  always @(*) begin
    dsack_ext  = 2'b11;
    avec_n_i   = 1'b1;
    berr_force = tb_fault;
    oe_ext     = 1'b0;
    d_ext      = 32'd0;
    if (iack_now) begin
      if (a_o[3:1] != 3'd0) avec_n_i   = 1'b0;
      else                  berr_force = 1'b1;
    end
  end

  always @(posedge iack_now) begin
    iacks = iacks + 1;
    if (resumed && iacks_resumed == 0) iack_resumed = a_o[3:1];
    if (resumed) iacks_resumed = iacks_resumed + 1;
    if (a_o[3:1] == 3'd0) begin
      iack0 = iack0 + 1;
      $display("  FAIL: at %0t an interrupt acknowledge for level 0 (A=%08h)",
               $time, a_o);
    end else if (want_level != 3'd0 && a_o[3:1] != want_level) begin
      iack_bad = iack_bad + 1;
    end
    if (drop_at_iack) ipl_n_i = 3'b111;   // a device drops its request when acknowledged
  end

  // RTE's resume: the microword that hands the faulted access back.
  always @(posedge clk)
    if (rst_n && dut.u_seq.rst_op_valid && !resumed) begin
      resumed    = 1'b1;
      resume_cyc = cyc;
    end

  // The program: a supervisor prologue that drops to user mode at mask 0, and a
  // user program whose byte write is posted and faults -- the shape of the
  // NetBSD occurrence (SSW $0111: DF, byte, user data).
  task automatic setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1) poke_l(v * 4, SPIN);
    poke_w(SPIN, 16'h60FE);                // BRA *
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    poke_l(32'h0000_0008, BEH);            // vector 2
    poke_l(32'h0000_006C, HAND);           // vector 27 = 24 + 3
    poke_l(32'h0000_0074, HAND);           // vector 29 = 24 + 5
    // Twice round a loop, the instruction cache on: the first pass writes to
    // ordinary memory and fills the cache, so that on the second the ADDQs
    // after the faulting write run out of the cache while the write is still
    // on the bus, and the interrupt can be dispatched at any of their
    // boundaries -- the fault then lands on whichever entry microword is
    // current. Without the cache every boundary after the write waits for the
    // bus, and the fault lands on the instruction instead.
    poke_w(CODE + 0,  16'h207C);           // MOVEA.L #OKW,A0
    poke_l(CODE + 2,  OKW);
    poke_w(CODE + 6,  16'h7601);           // MOVEQ #1,D3 -- two passes
    poke_w(CODE + 8,  16'h7801);           // MOVEQ #1,D4
    poke_w(CODE + 10, 16'h4E7B);           // MOVEC D4,CACR -- EI, UM 6.3.1
    poke_w(CODE + 12, 16'h4002);
    poke_w(CODE + 14, 16'h46FC);           // MOVE #$0000,SR -- user, mask 0
    poke_w(CODE + 16, 16'h0000);
    poke_w(CODE + 18, 16'h1080);           // L: MOVE.B D0,(A0) -- posted; faults
    for (v = 0; v < 12; v = v + 1)         //    the second time
      poke_w(CODE + 20 + 2 * v, 16'h5285); // ADDQ.L #1,D5
    poke_w(CODE + 44, 16'h207C);           // MOVEA.L #GONE,A0
    poke_l(CODE + 46, GONE);
    poke_w(CODE + 50, 16'h51CB);           // DBRA D3,L
    poke_w(CODE + 52, 16'hFFDE);
    poke_w(CODE + 54, 16'h60FE);           // BRA *
    poke_w(HAND + 0,  16'h5286);           // ADDQ.L #1,D6 -- count the handlers
    poke_w(HAND + 2,  16'h4E73);           // RTE
    poke_w(BEH + 0,   16'h4E71);           // NOP -- a bus error handler with
    poke_w(BEH + 2,   16'h4E71);           // NOP    some length to it
    poke_w(BEH + 4,   16'h5287);           // ADDQ.L #1,D7
    poke_w(BEH + 6,   16'h4E73);           // RTE -- format $B, DF set: rerun
    poke_w(GONE, 16'h0000);
    poke_w(OKW, 16'h0000);
    for (v = 0; v < 32'h5C; v = v + 2) poke_w(FRM + v, 16'h0000);
  endtask

  task automatic start(input bit drop, input int unsigned kk);
    setup();
    iacks = 0; iack0 = 0; iack_bad = 0; iacks_resumed = 0; resume_cyc = 0;
    iack_resumed = 3'd0; resumed = 1'b0; drop_at_iack = drop;
    berrs = 0; fault_k = kk;
    ipl_n_i = 3'b111;
    s16.waits_rt = 48;
    reset_dut();
    dut.u_seq.usp_q   = USP0;
    dut.u_seq.dreg[0] = 32'h0000_005B;
    dut.u_seq.dreg[5] = 32'd0;
    dut.u_seq.dreg[6] = 32'd0;
    dut.u_seq.dreg[7] = 32'd0;
    fault_en = 1'b1;
  endtask

  // The level-5 request, raised at clock `at`.
  task automatic raise_at(input int at);
    while (int'(cyc) < at) @(posedge clk);
    ipl_n_i = ~3'd5;
  endtask

  // Where the bus error's frame resumes: in the interrupt entry before its
  // acknowledge (the frame carries the interrupt), or at its first microword.
  function automatic bit frame_in_entry();
    logic [15:0] u;
    u = peek_w(FRM + 32'h14);
    frame_in_entry = (u >= E0) && (u <= E0 + 16'd2);
  endfunction
  function automatic logic [2:0] frame_level();
    frame_level = 3'((peek_w(FRM + 8) >> 10) & 16'h7);
  endfunction
  function automatic bit frame_at_entry();
    frame_at_entry = (peek_w(FRM + 32'h14) == E0);
  endfunction

  // What every run must end with.
  task automatic finish_checks(input string what);
    run_until(ENDP, 8000, reached);
    check(reached, {what, ": the program completes"});
    check(berrs == 1, $sformatf("%s: one bus error, not %0d", what, berrs));
    check(dut.u_seq.dreg[7] === 32'd1, {what, ": the bus error handler ran once"});
    check(peek_w(GONE) === 16'h5B00, {what, ": the faulted byte write was rerun"});
    check(dut.u_seq.dreg[5] === 32'd24, {what, ": every ADDQ ran once a pass"});
    check(peek_w(OKW) === 16'h5B00, {what, ": the first pass's write"});
    check(iack0 == 0, $sformatf("%s: %0d acknowledges for level 0", what, iack0));
    check(dut.u_seq.isp_q === ISP0, {what, ": every frame came off the stack"});
    // The interrupt the frame carries is taken after the resume, at the level
    // recognised -- +$08 bits 12:10 say which, and it is never 0. Where the
    // pins moved before the recognition (a drop or change in the first clocks
    // after the bus error, for a request raised just before it) that level is
    // whatever they then said; `want_level` pins it down where it cannot be.
    if (frame_in_entry()) begin
      check(frame_level() != 3'd0, {what, ": +$08 carries a level, not 0"});
      check(want_level == 3'd0 || frame_level() == want_level,
            $sformatf("%s: +$08 carries level %0d, not %0d", what, frame_level(),
                      want_level));
      check(iacks_resumed != 0 && iack_resumed === frame_level(),
            $sformatf("%s: the acknowledge after RTE asks for level %0d, got %0d (%0d of them)",
                      what, frame_level(), iack_resumed, iacks_resumed));
    end
  endtask

  // The raise window around the write, and the bus error's delay into it.
  localparam int RLO = -8, RHI = 8, RSTEP = 1, KMAX = 15, NSEL = 2;
  int unsigned tw;                      // the clock the write is presented at
  int unsigned in_entry, at_entry, nsel;
  int          sel_r [0:NSEL-1];
  int          sel_k [0:NSEL-1];
  int unsigned to_resume, raced;

  initial begin
    $display("core_irqrte_tb: an interrupt's level kept across a bus error and its RTE");

    // When the write is presented.
    start(1'b1, 0);
    while (!on_gone) @(posedge clk);
    tw = cyc;
    finish_checks("calibration");

    // ======================================================================
    // hold, at every (r, k) -- and which of them put the fault on the
    // entry's first microword.
    // ======================================================================
    in_entry = 0; at_entry = 0; nsel = 0; to_resume = 0;
    for (k = 0; k <= KMAX; k++)
      for (r = RLO; r <= RHI; r += RSTEP) begin
        start(1'b1, k);
        want_level = 3'd5;
        raise_at(int'(tw) + r);
        what = $sformatf("hold, raised at %0d, bus error at +%0d", r, k);
        finish_checks(what);
        check(iack_bad == 0, {what, ": every acknowledge is for level 5"});
        check(dut.u_seq.dreg[6] !== 32'd0, {what, ": the interrupt handler ran"});
        want_level = 3'd0;
        if ($test$plusargs("verbose"))
          $display("  r=%0d k=%0d: frame upc %0d, %0d acknowledges", r, k,
                   peek_w(FRM + 32'h14), iacks);
        if (frame_in_entry()) in_entry++;
        if (frame_at_entry()) begin
          at_entry++;
          if (nsel < NSEL) begin sel_r[nsel] = r; sel_k[nsel] = k; nsel++; end
          if (resume_cyc - berr_cyc > to_resume) to_resume = resume_cyc - berr_cyc;
        end
      end
    $display("  %0d runs: %0d faults in the interrupt entry, %0d on its first microword",
             (KMAX + 1) * ((RHI - RLO) / RSTEP + 1), in_entry, at_entry);
    $fflush;
    // Only with the instruction cache: without it nothing decodes while the
    // write is out (`make cache` builds it out).
    if (`TB_ICACHE_ENTRIES > 0)
      check(at_entry > 0, "some bus error landed on the interrupt entry's first microword");

    // ======================================================================
    // drop and change, for the first pairs that resume at the entry, from
    // the bus error to past RTE's resume.
    // ======================================================================
    dmax = to_resume + 12;
    raced = 0;
    for (int s = 0; s < int'(nsel); s++) begin
      for (d = 0; d <= dmax; d += 3) begin
        start(1'b0, sel_k[s]);
        raise_at(int'(tw) + sel_r[s]);
        after_berr(d);
        ipl_n_i = 3'b111;
        what = $sformatf("drop, raised at %0d, bus error at +%0d, dropped at +%0d",
                         sel_r[s], sel_k[s], d);
        // Dropped after the recognition, the level is 5 whatever happens.
        want_level = (d >= 4) ? 3'd5 : 3'd0;
        finish_checks(what);
        if (frame_at_entry()) raced++;

        start(1'b1, sel_k[s]);
        raise_at(int'(tw) + sel_r[s]);
        after_berr(d);
        if (!resumed) ipl_n_i = ~3'd3;
        what = $sformatf("change, raised at %0d, bus error at +%0d, to 3 at +%0d",
                         sel_r[s], sel_k[s], d);
        want_level = (d >= 4) ? 3'd5 : 3'd0;
        finish_checks(what);
        want_level = 3'd0;
        if (frame_at_entry()) raced++;
      end
    end
    $display("  drop and change: %0d pairs, the pins moved from +0 to +%0d after the bus error; %0d runs resumed at the entry's first microword",
             nsel, dmax, raced);
    if (`TB_ICACHE_ENTRIES > 0)
      check(raced > 0, "drop and change: some run resumed at the entry's first microword");

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_irqrte_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_irqrte_tb");
    else                               $display("FAIL: core_irqrte_tb");
    $finish;
  end

endmodule
