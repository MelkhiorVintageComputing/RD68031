// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the MMU, UM section 9, from programs that use it.
//
// Four programs, each built from sim/programs/ with the cross-assembler for
// -mcpu=68030 and each checking itself -- sim/programs/mmu_common.inc:
//
//   mmu_regs    the registers, PMOVE in every form, the configuration
//               exception, PLOAD, PTEST level 0, PFLUSH, TT0/TT1 with CIOUT
//               and both caches inhibited, MMUDIS
//   mmu_walk    the table search: TC's page sizes, initial shift, index splits,
//               SRE and FCL; two to five levels, short and long descriptors,
//               early termination, indirection, limits; U and M; S and WP;
//               tables on 8-, 16-bit and synchronous ports; PTEST at every
//               level with an address register; the ATC's replacement
//   mmu_fault   the bus errors the MMU raises and RTE's rerun: invalid
//               descriptors, limits, supervisor-only and write-protected
//               pages, a bus error during a search, read-modify-writes,
//               operands across a page boundary, instruction fetch faults
//               and a prefetch into an unmapped page that must not fault
//   mmu_rerun   RTE's rerun of a faulted access faulting again: an ordinary
//               bus error, not a double bus fault (UM 8.2.3) -- data reads
//               and writes on invalid pages and on BERR, a prefetch, and
//               SunOS's user-stack growth (LINK, MOVEM)
//
// A program logs every check that fails, and this prints the log and insists
// on it being empty and complete. What the program cannot see, this counts, a
// phase at a time -- a phase opens with a write of its number to $8000:
//
//   - table search cycles: supervisor data space with RMC asserted (UM 7.3.3),
//     to a table ($x000_9000-$x000_BFFF) or to the bus-error region at
//     $4000_0000; reads and writes, and that none asserts CIOUT or CBREQ
//     (UM 12.1, "the MC68030 asserts RMC but not CIOUT"; UM 6.1.3.2);
//   - that RMC stays asserted from a search's first cycle to its last (UM
//     9.5.2, "the RMC signal is asserted on the first bus cycle of the search
//     and remains asserted throughout");
//   - cycles to the synchronous port, cycles with CIOUT, cycles with CBREQ,
//     instruction fetches and the ones with CIOUT, and cycles to two watched
//     physical pages.
//
// $4000_0000-$4FFF_FFFF answers every cycle with BERR. The testbench asserts
// MMUDIS at mmu_regs' phase 42 and negates it at 43, and pulls RESET at the end
// of mmu_regs to check what UM 9.2.2 says it does to the MMU.

`timescale 1ns / 1ps

module core_mmu_tb;

`include "rd68031_core_harness.svh"

  localparam int NPH = 128;
  // `make cache` runs every core testbench with both caches built out; the
  // counts that depend on them follow the build.
  localparam bit HAS_IC = (`TB_ICACHE_ENTRIES != 0);
  localparam bit HAS_DC = (`TB_DCACHE_ENTRIES != 0);
  localparam logic [31:0] A_NCHK  = 32'h0000_8004;
  localparam logic [31:0] A_NFAIL = 32'h0000_8008;
  localparam logic [31:0] A_LOGP  = 32'h0000_800C;
  localparam logic [31:0] A_DONE  = 32'h0000_8010;
  localparam logic [31:0] A_NEXC  = 32'h0000_8018;
  localparam logic [31:0] A_LASTV = 32'h0000_801C;
  localparam logic [31:0] A_NCHKX = 32'h0000_8058;
  localparam logic [31:0] A_LOG   = 32'h0000_8100;

  int ph;
  int c_wr   [0:NPH-1];   // table search reads
  int c_ww   [0:NPH-1];   // ... and writes
  int c_wbad [0:NPH-1];   // ... with CIOUT or CBREQ
  int c_b4   [0:NPH-1];   // ... to the bus-error region
  int c_c3   [0:NPH-1];   // other cycles to the synchronous port
  int c_cio  [0:NPH-1];   // other cycles with CIOUT
  int c_cbr  [0:NPH-1];   // other cycles to the synchronous port with CBREQ
  int c_pf   [0:NPH-1];   // instruction fetches
  int c_pfci [0:NPH-1];   // ... with CIOUT
  int c_pg   [0:NPH-1];   // cycles to pg_watch
  int c_pgci [0:NPH-1];   // ... with CIOUT
  int c_pg2  [0:NPH-1];   // cycles to pg2_watch
  int c_st3  [0:NPH-1];   // STATUS asserted for three clocks
  int c_wclk [0:NPH-1];   // clocks the walker was busy
  int c_wn   [0:NPH-1];   // ... in how many searches
  int c_wpre [0:NPH-1];   // table search cycles before the phase's first operand cycle
  int c_frc  [0:NPH-1];   // cycles to physical frame $C000 (mmu_walk 60-79)
  int c_frd  [0:NPH-1];   // ... to frame $D000
  int c_frbad[0:NPH-1];   // ... with CIOUT not the frame's: asserted to $C000, negated to $D000
  bit d_seen;             // ... which has been seen
  logic [31:0] pg_watch, pg2_watch;
  bit  frames_ci;         // mmu_walk, phases 60-79: frame $C000 cachable, $D000 CI
  bit  is_regs;
  bit  is_walkp;
  int  rmc_breaks;
  bit  walk_seen;

  task automatic clear_counts();
    int i;
    for (i = 0; i < NPH; i = i + 1) begin
      c_wr[i] = 0; c_ww[i] = 0; c_wbad[i] = 0; c_b4[i] = 0; c_c3[i] = 0;
      c_cio[i] = 0; c_cbr[i] = 0; c_pf[i] = 0; c_pfci[i] = 0; c_pg[i] = 0;
      c_pgci[i] = 0; c_pg2[i] = 0; c_st3[i] = 0; c_wclk[i] = 0; c_wn[i] = 0;
      c_wpre[i] = 0; c_frc[i] = 0; c_frd[i] = 0; c_frbad[i] = 0;
    end
    d_seen = 1'b0;
    ph = 0;
    rmc_breaks = 0;
    walk_seen = 1'b0;
  endtask

  // Every bus cycle, as AS asserts: CBREQ asserts with it (UM 7.3.4 state 1),
  // CIOUT has been valid since S0.
  logic is_walk;
  always @(negedge as_n_o) begin
    #1;
    if (rst_n && as_oe && ph < NPH) begin
      frames_ci = is_walkp && (ph >= 60) && (ph < 80);
      is_walk = (fc_o == 3'd5) && rmc_oe && !rmc_n_o
             && (((a_o[15:12] >= 4'h9) && (a_o[15:12] <= 4'hB)) || (a_o[31:28] == 4'h4));
      if (is_walk) begin
        walk_seen = 1'b1;
        if (rw_o) c_wr[ph] = c_wr[ph] + 1;
        else      c_ww[ph] = c_ww[ph] + 1;
        if (!ciout_n_o || !cbreq_n_o) c_wbad[ph] = c_wbad[ph] + 1;
        if (a_o[31:28] == 4'h4) c_b4[ph] = c_b4[ph] + 1;
        if (!d_seen) c_wpre[ph] = c_wpre[ph] + 1;
      end else begin
        // An operand cycle in data space, other than the phase marker.
        if (((fc_o == 3'd1) || (fc_o == 3'd5)) && (a_o != 32'h0000_8000))
          d_seen = 1'b1;
        if (a_o[31:28] == 4'h3) c_c3[ph] = c_c3[ph] + 1;
        if (!ciout_n_o) c_cio[ph] = c_cio[ph] + 1;
        if (!cbreq_n_o && (a_o[31:28] == 4'h3)) c_cbr[ph] = c_cbr[ph] + 1;
        if (rw_o && (fc_o == 3'd2 || fc_o == 3'd6)) begin
          c_pf[ph] = c_pf[ph] + 1;
          if (!ciout_n_o) c_pfci[ph] = c_pfci[ph] + 1;
        end
        if ((a_o & 32'hFFFF_FF00) == pg_watch) begin
          c_pg[ph] = c_pg[ph] + 1;
          if (!ciout_n_o) c_pgci[ph] = c_pgci[ph] + 1;
        end
        if ((a_o & 32'hFFFF_FF00) == pg2_watch) c_pg2[ph] = c_pg2[ph] + 1;
        // mmu_walk's phases 60-79 map their cachable pages to frame $C000
        // and their CI pages to $D000: CIOUT on each cycle is its frame's.
        if (frames_ci && (a_o[31:12] == 20'h0000C)) begin
          c_frc[ph] = c_frc[ph] + 1;
          if (!ciout_n_o) c_frbad[ph] = c_frbad[ph] + 1;
        end
        if (frames_ci && (a_o[31:12] == 20'h0000D)) begin
          c_frd[ph] = c_frd[ph] + 1;
          if (ciout_n_o) c_frbad[ph] = c_frbad[ph] + 1;
        end
      end
    end
  end

  // A phase marker: a write to $8000, seen as its AS negates.
  always @(posedge as_n_o) begin
    #1;
    if (rst_n && as_oe && !rw_o && (a_o == 32'h0000_8000)) begin
      if (d_o < NPH) ph = d_o;
      d_seen = 1'b0;
      if (is_regs && d_o == 42) mmudis_n_i = 1'b0;
      if (is_regs && d_o == 43) mmudis_n_i = 1'b1;
    end
  end

  // STATUS: UM Table 8-2, "MMU address translation cache miss -- processor to
  // begin table search" is three clocks. Counted per phase, by the length of
  // each assertion; and how long each search keeps the walker busy.
  int  st_run;
  bit  busy_q;
  always @(negedge clk) begin
    if (!rst_n) begin
      st_run = 0;
      busy_q = 1'b0;
    end else begin
      if (!status_n_o) st_run = st_run + 1;
      else begin
        if (st_run == 3 && ph < NPH) c_st3[ph] = c_st3[ph] + 1;
        st_run = 0;
      end
      if (dut.u_mmu.busy && ph < NPH) c_wclk[ph] = c_wclk[ph] + 1;
      if (dut.u_mmu.busy && !busy_q && ph < NPH) c_wn[ph] = c_wn[ph] + 1;
      busy_q = dut.u_mmu.busy;
    end
  end

  // UM 9.5.2: RMC from a search's first cycle to its last.
  always @(posedge clk) begin
    if (!rst_n || !dut.u_mmu.busy) walk_seen <= 1'b0;
    else if (walk_seen && rmc_n_o) rmc_breaks = rmc_breaks + 1;
  end

  // Expectations: -1 is "not checked".
  task automatic exp_walk(input string pn, input int p, input int wr, input int ww);
    if (wr >= 0)
      check(c_wr[p] == wr, $sformatf("%s phase %0d: %0d table search reads, want %0d",
                                     pn, p, c_wr[p], wr));
    if (ww >= 0)
      check(c_ww[p] == ww, $sformatf("%s phase %0d: %0d table search writes, want %0d",
                                     pn, p, c_ww[p], ww));
  endtask

  task automatic exp_bus(input string pn, input int p, input int c3, input int cio,
                         input int cbr);
    if (c3 >= 0)
      check(c_c3[p] == c3, $sformatf("%s phase %0d: %0d cycles to the synchronous port, want %0d",
                                     pn, p, c_c3[p], c3));
    if (cio >= 0)
      check(c_cio[p] == cio, $sformatf("%s phase %0d: %0d cycles with CIOUT, want %0d",
                                       pn, p, c_cio[p], cio));
    if (cbr >= 0)
      check(c_cbr[p] == cbr, $sformatf("%s phase %0d: %0d cycles with CBREQ, want %0d",
                                       pn, p, c_cbr[p], cbr));
  endtask

  task automatic exp_pg(input string pn, input int p, input int pg, input int pgci,
                        input int pg2);
    if (pg >= 0)
      check(c_pg[p] == pg, $sformatf("%s phase %0d: %0d cycles to page %08h, want %0d",
                                     pn, p, c_pg[p], pg_watch, pg));
    if (pgci >= 0)
      check(c_pgci[p] == pgci, $sformatf("%s phase %0d: %0d of them with CIOUT, want %0d",
                                         pn, p, c_pgci[p], pgci));
    if (pg2 >= 0)
      check(c_pg2[p] == pg2, $sformatf("%s phase %0d: %0d cycles to page %08h, want %0d",
                                       pn, p, c_pg2[p], pg2_watch, pg2));
  endtask

  task automatic exp_st3(input string pn, input int p, input int n);
    check(c_st3[p] == n, $sformatf("%s phase %0d: %0d three-clock STATUS indications, want %0d",
                                   pn, p, c_st3[p], n));
  endtask

  // How many of a phase's table search cycles came before its first operand
  // cycle: for an operand that crosses into a page the ATC does not have, the
  // first page's search alone. The second page's is made when the operand's
  // cycles reach it, after the first page's part (doc/mmu.md, M11 part 2).
  task automatic exp_wpre(input string pn, input int p, input int n);
    check(c_wpre[p] == n, $sformatf("%s phase %0d: %0d table search cycles before the first operand cycle, want %0d",
                                    pn, p, c_wpre[p], n));
  endtask

  // mmu_walk's phases 60-79: cycles to the cachable frame and to the CI one.
  task automatic exp_fr(input string pn, input int p, input int fc, input int fd);
    check(c_frc[p] == fc, $sformatf("%s phase %0d: %0d cycles to the cachable frame $C000, want %0d",
                                    pn, p, c_frc[p], fc));
    check(c_frd[p] == fd, $sformatf("%s phase %0d: %0d cycles to the CI frame $D000, want %0d",
                                    pn, p, c_frd[p], fd));
  endtask

  task automatic exp_b4(input string pn, input int p, input int b4);
    check(c_b4[p] == b4, $sformatf("%s phase %0d: %0d search cycles to the bus-error region, want %0d",
                                   pn, p, c_b4[p], b4));
  endtask

  // Load, run to phase 99, and judge what the program says of itself.
  task automatic run_prog(input string pn, input string image, input int limit);
    int n, i, nlog;
    bit reached;
    logic [15:0] id;
    $display("core_mmu_tb: %s", pn);
    for (n = 0; n < 65536; n = n + 1) s32.mem[n] = 8'h00;
    $readmemh(image, s32.mem);
    clear_counts();
    mmudis_n_i = 1'b1;
    reset_dut();
    reached = 1'b0;
    n = 0;
    while (!reached && n < limit) begin
      @(negedge clk);
      if (ph == 99) reached = 1'b1;
      n = n + 1;
    end
    // A posted write still outstanding is waited for -- but not forever: a
    // core halted by a double bus fault never finishes one.
    i = 0;
    while (dut.u_biu.post_busy && i < 10000) begin
      @(negedge clk);
      i = i + 1;
    end
    repeat (4) @(negedge clk);
    check(reached, $sformatf("%s: reached its end (phase %0d after %0d clocks)", pn, ph, n));
    check(peek_l(A_DONE) == 32'h600D_D00E, $sformatf("%s: finished cleanly", pn));
    check(peek_l(A_NEXC) == 0,
          $sformatf("%s: %0d unexpected exceptions, the last format/vector %04h",
                    pn, peek_l(A_NEXC), peek_l(A_LASTV)));
    nlog = (peek_l(A_LOGP) - A_LOG) / 10;
    check(peek_l(A_NFAIL) == 0, $sformatf("%s: %0d of %0d checks failed", pn,
                                          peek_l(A_NFAIL), peek_l(A_NCHK)));
    for (i = 0; i < nlog && i < 64; i = i + 1) begin
      id = peek_w(A_LOG + 10*i);
      $display("  FAIL: %s check %0d: %08h, want %08h", pn, id,
               peek_l(A_LOG + 10*i + 2), peek_l(A_LOG + 10*i + 6));
    end
    check(peek_l(A_NCHK) == peek_l(A_NCHKX),
          $sformatf("%s: %0d checks made of the %0d written", pn, peek_l(A_NCHK),
                    peek_l(A_NCHKX)));
    for (i = 0; i < NPH; i = i + 1)
      check(c_wbad[i] == 0, $sformatf("%s phase %0d: %0d table search cycles with CIOUT or CBREQ",
                                      pn, i, c_wbad[i]));
    for (i = 0; i < NPH; i = i + 1)
      check(c_frbad[i] == 0, $sformatf("%s phase %0d: %0d cycles whose CIOUT is not their page's",
                                       pn, i, c_frbad[i]));
    check(rmc_breaks == 0, $sformatf("%s: RMC negated %0d times inside a table search",
                                     pn, rmc_breaks));
    $display("  %s: %0d self-checks, %0d clocks", pn, peek_l(A_NCHK), n);
  endtask

  task automatic dump_counts(input string pn);
    int i;
    for (i = 0; i < NPH; i = i + 1)
      if (c_wr[i] || c_ww[i] || c_c3[i] || c_cio[i] || c_cbr[i] || c_pg[i] || c_pg2[i])
        $display("  %s phase %0d: walk r%0d w%0d b4 %0d (%0d searches, %0d clocks, %0d before the first operand cycle) | sync %0d ciout %0d cbreq %0d | fetch %0d/%0d | pg %0d/%0d pg2 %0d | status3 %0d | frames %0d/%0d",
                 pn, i, c_wr[i], c_ww[i], c_b4[i], c_wn[i], c_wclk[i], c_wpre[i], c_c3[i], c_cio[i],
                 c_cbr[i], c_pf[i], c_pfci[i], c_pg[i], c_pgci[i], c_pg2[i], c_st3[i],
                 c_frc[i], c_frd[i]);
  endtask

  string img_regs, img_walk, img_fault, img_rerun;
  initial begin
    $display("core_mmu_tb: the MC68030's MMU, from four programs");
    if (!$value$plusargs("regs=%s", img_regs))   img_regs  = "build/programs/mmu_regs.hex";
    if (!$value$plusargs("walk=%s", img_walk))   img_walk  = "build/programs/mmu_walk.hex";
    if (!$value$plusargs("fault=%s", img_fault)) img_fault = "build/programs/mmu_fault.hex";
    if (!$value$plusargs("rerun=%s", img_rerun)) img_rerun = "build/programs/mmu_rerun.hex";
    berr_en   = 1'b1;
    berr_base = 32'h4000_0000;
    berr_mask = 32'hF000_0000;
    pg_watch  = 32'hFFFF_FFFF;
    pg2_watch = 32'hFFFF_FFFF;

    // ======================================================================
    // mmu_regs
    // ======================================================================
    is_regs = 1'b1;
    run_prog("mmu_regs", img_regs, 400_000);
    if ($test$plusargs("counts")) dump_counts("mmu_regs");
    exp_walk("mmu_regs", 2, 0, 0);
    exp_walk("mmu_regs", 4, 2, 2);     // PLOADR: A[5] and B[0], U written in both
    exp_walk("mmu_regs", 6, 2, 1);     // PLOADW, a WP page: U, no M
    exp_walk("mmu_regs", 8, 2, 1);     // PLOADW: M
    exp_walk("mmu_regs", 9, 0, 0);     // PTEST level 0 and PFLUSH search nothing
    exp_walk("mmu_regs", 10, 4, 0);
    exp_walk("mmu_regs", 11, 0, 0);
    exp_walk("mmu_regs", 12, 2, 0);
    exp_walk("mmu_regs", 13, 6, 0);    // three reloads after three flushes
    exp_walk("mmu_regs", 14, 2, 0);    // an invalid page: no U written
    exp_walk("mmu_regs", 15, 2, 0);    // PTEST #7: the same two, no history
    exp_bus("mmu_regs", 20, 2, 2, 0);  // TT1 CI: two reads, both CIOUT, no burst
    if (HAS_DC) exp_bus("mmu_regs", 22, 1, 0, 1);  // CI clear: one burst fill, then a hit
    else        exp_bus("mmu_regs", 22, 2, 0, 0);  // ... with no data cache, two reads
    exp_bus("mmu_regs", 24, 2, 1, 0);  // writes only: the write has CIOUT
    exp_bus("mmu_regs", 26, 2, 0, 0);  // RWM clear: TAS does not match
    exp_bus("mmu_regs", 27, 2, 2, 0);  // RWM set: both its cycles do
    exp_bus("mmu_regs", 29, 2, 1, 0);  // FC: only MOVES's user-data read
    exp_bus("mmu_regs", 31, 1, 1, 0);  // TT0 and TT1 both: CI ORed
    check(c_pf[34] == c_pfci[34] && c_pf[34] > 0,
          $sformatf("mmu_regs phase 34: every instruction fetch has CIOUT (%0d of %0d)",
                    c_pfci[34], c_pf[34]));
    if (HAS_IC)
      check(c_pf[34] >= 2 * c_pf[33],
            $sformatf("mmu_regs: the instruction cache inhibited refetches the loop (%0d fetches against %0d)",
                      c_pf[34], c_pf[33]));
    exp_walk("mmu_regs", 41, 2, 0);    // a search
    exp_walk("mmu_regs", 42, 2, 0);    // MMUDIS: only PLOAD searches
    exp_bus("mmu_regs", 42, 1, 1, -1); // ... and TT1 still gives CIOUT
    exp_walk("mmu_regs", 43, 0, 0);    // the ATC kept its entry
    // STATUS: three clocks for the search an access starts, none for PLOAD.
    exp_st3("mmu_regs", 4, 0);
    exp_st3("mmu_regs", 41, 1);
    // The table search's length, for doc/timing-divergences.md: two short
    // descriptors, no history to write -- UM 11.7's "xSSxx", 33 clocks.
    $display("  timing: a two-level short search with no U or M to write takes %0d clocks (UM 11.7: 33)",
             c_wclk[41]);

    // UM 8.1.1 step 7 and 9.2.2: RESET clears TC.E, TT0.E and TT1.E, and
    // "does not invalidate any entries in the ATC"; the rest stays.
    @(negedge clk);
    reset_in_n = 1'b0;
    repeat (20) @(negedge clk);
    check(dut.u_mmu.tc_q === 32'h00C0_AA00,
          $sformatf("RESET clears TC.E and nothing else (%08h)", dut.u_mmu.tc_q));
    check(dut.u_mmu.tt0_q === 32'h0000_0143,
          $sformatf("RESET clears TT0.E (%08h)", dut.u_mmu.tt0_q));
    check(dut.u_mmu.tt1_q === 32'h3000_0550,
          $sformatf("RESET clears TT1.E (%08h)", dut.u_mmu.tt1_q));
    check(dut.u_mmu.crp_q[33:32] === 2'b10, "RESET leaves CRP");
    check(dut.u_mmu.v_q !== '0, "RESET leaves the ATC");
    reset_in_n = 1'b1;
    repeat (4) @(negedge clk);
    is_regs = 1'b0;

    // ======================================================================
    // mmu_walk
    // ======================================================================
    if (!$test$plusargs("only_regs")) begin
      pg_watch  = 32'h0000_CB00;
      pg2_watch = 32'h0000_CC00;
      is_walkp  = 1'b1;
      run_prog("mmu_walk", img_walk, 1_500_000);
      is_walkp  = 1'b0;
      if ($test$plusargs("counts")) dump_counts("mmu_walk");
      `include "core_mmu_walk_exp.svh"

      pg_watch  = 32'hFFFF_FFFF;
      pg2_watch = 32'hFFFF_FFFF;
      run_prog("mmu_fault", img_fault, 1_500_000);
      if ($test$plusargs("counts")) dump_counts("mmu_fault");
      `include "core_mmu_fault_exp.svh"

      run_prog("mmu_rerun", img_rerun, 300_000);
      if ($test$plusargs("counts")) dump_counts("mmu_rerun");
      check(!dut.u_seq.dbf_q, "mmu_rerun: no double bus fault -- UM 8.2.3, a rerun's fault is an ordinary one");
    end

    if (fails == 0) $display("PASS: core_mmu_tb, %0d checks", checks);
    else            $display("FAIL: core_mmu_tb, %0d of %0d checks failed", fails, checks);
    $finish;
  end

endmodule
