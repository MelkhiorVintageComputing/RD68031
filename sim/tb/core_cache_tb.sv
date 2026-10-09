// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the MC68030's two caches, UM section 6.
//
// A cache is architecturally invisible except in two ways, and this tests both:
// the bus (a hit makes no cycle, a fill makes the cycles UM 6.1.3 says it makes)
// and memory that changes behind the processor's back (a hit serves the copy the
// cache holds, until something clears it). Everything else -- that programs give
// the same answers with the caches and without them -- is `make cache`.
//
// The program is sim/programs/cache.S. It runs one short test per PHASE, each
// opened by a write of the phase number to MARKA, and this bench:
//   - records every bus cycle with the phase it belongs to -- address, size,
//     direction, space, requester, CBREQ, CBACK, the long words a burst
//     brought, and OCS;
//   - acts at some MARKs: changes memory behind the cache, limits or loads the
//     bursting device, asserts CDIS, arms a bus error;
//   - checks, once the program is done, the cycles of each phase against what
//     UM section 6 says, and the values the program stored at RES.
//
// The memory map is the core harness's, with its synchronous bursting port at
// $3000_0000.

`timescale 1ns / 1ps

module core_cache_tb;

`undef  TB_ICACHE_ENTRIES
`define TB_ICACHE_ENTRIES 64
`undef  TB_DCACHE_ENTRIES
`define TB_DCACHE_ENTRIES 64
`include "rd68031_core_harness.svh"

  localparam logic [31:0] MARKA = 32'h0000_0EF0;
  localparam logic [31:0] EXC   = 32'h0000_0E80;
  localparam logic [31:0] RES   = 32'h0000_C000;
  localparam logic [31:0] SUBA  = 32'h0000_30F0;
  localparam logic [31:0] SUBB  = 32'h3000_30F0;
  localparam logic [31:0] CPUA  = 32'h0003_0000;
  localparam logic [31:0] DONE_MARK = 32'd199;

  // ==========================================================================
  // The memory pattern every data location starts with: a byte that depends on
  // the whole address, so a read from the wrong place is noticed.
  // ==========================================================================
  function automatic logic [7:0] pb(input logic [31:0] a);
    pb = (a[7:0] ^ a[15:8]) + 8'h33 + {a[29:28], 6'd0};
  endfunction
  function automatic logic [31:0] pl(input logic [31:0] a);
    pl = {pb(a), pb(a + 1), pb(a + 2), pb(a + 3)};
  endfunction
  function automatic logic [15:0] pw(input logic [31:0] a);
    pw = {pb(a), pb(a + 1)};
  endfunction

  // ==========================================================================
  // The bus, cycle by cycle
  // ==========================================================================
  localparam int MAXCYC = 16384;
  int unsigned ncyc;
  int unsigned c_ph   [0:MAXCYC-1];
  logic [31:0] c_addr [0:MAXCYC-1];
  logic  [1:0] c_siz  [0:MAXCYC-1];
  logic        c_rw   [0:MAXCYC-1];
  logic  [2:0] c_fc   [0:MAXCYC-1];
  logic        c_f    [0:MAXCYC-1];   // an instruction prefetch
  logic        c_brq  [0:MAXCYC-1];   // CBREQ asserted
  logic        c_back [0:MAXCYC-1];   // CBACK with the first STERM
  int unsigned c_lw   [0:MAXCYC-1];   // long words STERM brought
  logic        c_ocs  [0:MAXCYC-1];   // OCS at its S0

  int unsigned phase;
  int unsigned exc_at_99;
  bit          cur_brq, cur_back, ocs_pend, cur_ocs;
  int unsigned cur_lw;
  bit          as_was;

  // OCS is asserted for the half clock of S0; sample it a quarter period after
  // the rising edge that starts S0, and hand it to the cycle when AS asserts.
  always @(posedge clk) begin
    #(CLK_PERIOD / 4.0);
    if (!ocs_n_o) ocs_pend = 1'b1;
  end
  always @(negedge as_n_o) begin
    cur_ocs  = ocs_pend;
    ocs_pend = 1'b0;
  end

  // Every ECS, against every AS: UM 7.2.7 lets the part start a cycle and abort
  // it on a cache hit, which shows as an ECS with no AS after it. This design
  // decides before it starts one (doc/divergences.md), so the two counts match.
  int unsigned n_ecs, n_as;
  always @(posedge clk) begin
    #(CLK_PERIOD / 4.0);
    if (rst_n && !ecs_n_o) n_ecs = n_ecs + 1;
  end
  always @(negedge as_n_o) if (rst_n) n_as = n_as + 1;

  // CBREQ, CBACK and the long words, at each rising edge inside AS.
  always @(posedge clk) begin
    if (rst_n && !as_n_o) begin
      if (!cbreq_n_o) cur_brq = 1'b1;
      if (!sterm_n_i) begin
        if (cur_lw == 0 && !cback_n_i) cur_back = 1'b1;
        cur_lw = cur_lw + 1;
      end
    end
  end

  // Burst-beat BERR: asserted for the beat whose STERM the device has just
  // given while `berr_beat` is armed -- UM 7.5.1, BERR "recognized on the next
  // falling clock edge following the rising clock edge on which STERM is
  // asserted and recognized".
  int berr_beat;
  always @(posedge clk) begin
    #1;
    berr_force = (berr_beat >= 0) && sB.selected && !as_n_o
              && (sB.beat_cnt == berr_beat + 1) && (sB.beat_d == berr_beat);
  end

  // The cycle ends: record it, and act on a MARK.
  always @(posedge as_n_o) begin
    if (rst_n) begin
      if (ncyc < MAXCYC) begin
        c_ph[ncyc]   = phase;
        c_addr[ncyc] = a_o;
        c_siz[ncyc]  = siz_o;
        c_rw[ncyc]   = rw_o;
        c_fc[ncyc]   = fc_o;
        c_f[ncyc]    = dut.u_biu.op_isfetch && rw_o && fc_o != 3'b111;
        c_brq[ncyc]  = cur_brq;
        c_back[ncyc] = cur_back;
        c_lw[ncyc]   = cur_lw;
        c_ocs[ncyc]  = cur_ocs;
        ncyc = ncyc + 1;
      end
      cur_brq  = 1'b0;
      cur_back = 1'b0;
      cur_lw   = 0;
      if (!rw_o && a_o == MARKA) begin
        phase = d_o;
        mark_action(d_o);
      end
    end
  end

  // CPU space at CPUA: a device that answers with DSACK, as UM figure 7-42's
  // unused types could be given one.
  always @(posedge clk) begin
    if (rst_n && !as_n_o && fc_o == 3'b111 && a_o[19:16] == 4'h3) begin
      dsack_ext <= 2'b00;
      d_ext     <= 32'hC0DE_CAFE;
      oe_ext    <= rw_o;
    end else begin
      dsack_ext <= 2'b11;
      oe_ext    <= 1'b0;
    end
  end

  // ==========================================================================
  // What the testbench does at a MARK
  // ==========================================================================
  logic [31:0] snap [0:255];   // memory as a WA probe will read it, by RES index

  task automatic snap_at(input int idx, input logic [31:0] a);
    snap[idx] = peek_l(a);
  endtask

  // The WA probes (cache.S, WATEST): at each probe MARK, the long words the
  // probe is about to read, as memory holds them -- what the cache, hit or
  // miss, has to return.
  task automatic wa_snap(input int base, input int ph);
    int r;
    r = (base == 20) ? 21 : 32;
    case (ph - base)
      1:  snap_at(r + 0, 32'hA050);
      3:  begin snap_at(r + 1, 32'hA058); snap_at(r + 2, 32'hA054); end
      5:  begin snap_at(r + 3, 32'hA054); snap_at(r + 4, 32'hA050); end
      7:  snap_at(r + 5, 32'hB054);
      9:  snap_at(r + 6, 32'hA050);
      11: begin snap_at(r + 7, 32'hA050); snap_at(r + 8, 32'hA058); end
      13: snap_at(r + 9, 32'hA054);
      15: snap_at(r + 10, 32'hA050);
      default: ;
    endcase
  endtask

  logic [31:0] wt_8050;

  task automatic mark_action(input logic [31:0] m);
    case (m)
      // Memory changes behind the cache: what the program reads next is
      // stale if it hits.
      2:   poke_l(32'h8000, 32'hDEAD_0002);
      11:  poke_l(32'h8030, 32'hDEAD_0011);
      14:  begin wt_8050 = peek_l(32'h8050); poke_l(32'h8050, 32'hDEAD_0014); end
      63:  poke_l(32'h8070, 32'hDEAD_0063);
      // The bursting device: two long words, then CIIN on the third, then CIIN
      // throughout, then a bus error on the third.
      93:  sB.burst_limit = 2;
      95:  begin sB.burst_limit = 4; sB.ciin_beats = 4'b0100; end
      97:  begin sB.ciin_beats = 4'b0000; sB.ciin_all = 1'b1; end
      99:  begin sB.ciin_all = 1'b0; berr_beat = 2; exc_at_99 = peek_l(EXC); end
      101: begin
             berr_beat = -1;
             berr_base = 32'h2000_0021;
             berr_mask = 32'hFFFF_FFFF;
             berr_en   = 1'b1;
           end
      110: berr_en = 1'b0;
      123: sB.burst_limit = 2;
      124: begin sB.burst_limit = 4; sB.ciin_all = 1'b1; end
      125: begin sB.ciin_all = 1'b0; cdis_n_i = 1'b0; end
      126: cdis_n_i = 1'b1;
      127: begin
             berr_base = SUBA + 32'h8;
             berr_mask = 32'hFFFF_FFFC;
             berr_en   = 1'b1;
           end
      130: berr_en = 1'b0;
      default: ;
    endcase
    if (m >= 20 && m < 36) wa_snap(20, m);
    if (m >= 40 && m < 56) wa_snap(40, m);
  endtask

  // ==========================================================================
  // Counting
  // ==========================================================================
  // Data reads (not prefetches, not CPU space) at `a` in phase `ph`.
  function automatic int nrd(input int ph, input logic [31:0] a);
    int n;
    n = 0;
    for (int i = 0; i < ncyc; i++)
      if (c_ph[i] == ph && c_rw[i] && !c_f[i] && c_fc[i] != 3'b111 && c_addr[i] == a)
        n++;
    nrd = n;
  endfunction
  // ... in a given space.
  function automatic int nrd_fc(input int ph, input logic [31:0] a, input logic [2:0] fc);
    int n;
    n = 0;
    for (int i = 0; i < ncyc; i++)
      if (c_ph[i] == ph && c_rw[i] && !c_f[i] && c_fc[i] == fc && c_addr[i] == a)
        n++;
    nrd_fc = n;
  endfunction
  // Data reads in [lo, hi] in phase `ph`.
  function automatic int nrd_r(input int ph, input logic [31:0] lo, input logic [31:0] hi);
    int n;
    n = 0;
    for (int i = 0; i < ncyc; i++)
      if (c_ph[i] == ph && c_rw[i] && !c_f[i] && c_fc[i] != 3'b111
          && c_addr[i] >= lo && c_addr[i] <= hi)
        n++;
    nrd_r = n;
  endfunction
  // Writes at `a` in phase `ph`.
  function automatic int nwr(input int ph, input logic [31:0] a);
    int n;
    n = 0;
    for (int i = 0; i < ncyc; i++)
      if (c_ph[i] == ph && !c_rw[i] && c_addr[i] == a) n++;
    nwr = n;
  endfunction
  // Instruction prefetches at `a` in phase `ph`.
  function automatic int nf(input int ph, input logic [31:0] a);
    int n;
    n = 0;
    for (int i = 0; i < ncyc; i++)
      if (c_ph[i] == ph && c_f[i] && c_addr[i] == a) n++;
    nf = n;
  endfunction
  // Prefetches in [lo, hi] in phase `ph` that asserted CBREQ.
  function automatic int nf_brq(input int ph, input logic [31:0] lo, input logic [31:0] hi);
    int n;
    n = 0;
    for (int i = 0; i < ncyc; i++)
      if (c_ph[i] == ph && c_f[i] && c_brq[i] && c_addr[i] >= lo && c_addr[i] <= hi) n++;
    nf_brq = n;
  endfunction
  // The index of the first data read at `a` in phase `ph`, or -1.
  function automatic int first_rd(input int ph, input logic [31:0] a);
    int k;
    k = -1;
    for (int i = ncyc - 1; i >= 0; i--)
      if (c_ph[i] == ph && c_rw[i] && !c_f[i] && c_addr[i] == a) k = i;
    first_rd = k;
  endfunction

  // The data read cycles of a phase, in order, against a list -- the narrow
  // port figures of UM 6.1.3.1.
  logic [31:0] want_a [0:15];
  logic  [1:0] want_s [0:15];
  task automatic check_seq(input int ph, input int n, input string what);
    int k, j;
    bit ok;
    k  = 0;
    ok = 1'b1;
    for (j = 0; j < ncyc; j++) begin
      if (c_ph[j] == ph && c_rw[j] && !c_f[j] && c_fc[j] != 3'b111
          && c_addr[j] != MARKA) begin
        if (k >= n || c_addr[j] !== want_a[k] || c_siz[j] !== want_s[k]) begin
          if (ok) $display("  ... %s: cycle %0d is %08h size %0d, wanted %08h size %0d",
                           what, k, c_addr[j], c_siz[j],
                           (k < n) ? want_a[k] : 32'hFFFF_FFFF, (k < n) ? want_s[k] : 2'd0);
          ok = 1'b0;
        end
        k++;
      end
    end
    check(ok && k == n, $sformatf("%s: %0d data cycles, as UM 6.1.3.1 lists them", what, n));
  endtask

  function automatic logic [31:0] res(input int i);
    res = peek_l(RES + 32'(i) * 4);
  endfunction

  task automatic check_res(input int i, input logic [31:0] v, input string what);
    check(res(i) === v, $sformatf("%s: RES[%0d] = %08h, wanted %08h", what, i, res(i), v));
  endtask

  // ==========================================================================
  // The run
  // ==========================================================================
  string image;
  bit    reached;

  localparam logic [1:0] SB = rd68031_pkg::SIZ_BYTE;
  localparam logic [1:0] SW = rd68031_pkg::SIZ_WORD;
  localparam logic [1:0] S3 = rd68031_pkg::SIZ_3BYTE;
  localparam logic [1:0] SL = rd68031_pkg::SIZ_LONG;

  initial begin
    int i, b, wa, k;
    string m;
    logic [31:0] lw [0:3];
    rst_n     = 1'b0;
    ncyc      = 0;
    n_ecs     = 0;
    n_as      = 0;
    phase     = 0;
    berr_beat = -1;
    cur_brq = 0; cur_back = 0; cur_lw = 0; ocs_pend = 0; cur_ocs = 0;
    if (!$value$plusargs("image=%s", image)) image = "build/programs/cache.hex";

    // Every location starts as the pattern, then the image goes over it.
    for (i = 0; i < 65536; i++) begin
      s32.mem[i] = pb(32'h0000_0000 + 32'(i));
      s16.mem[i] = pb(32'h1000_0000 + 32'(i));
      s8.mem[i]  = pb(32'h2000_0000 + 32'(i));
      sB.mem[i]  = pb(32'h3000_0000 + 32'(i));
    end
    for (i = 0; i < 'h4000; i++) s32.mem[i] = 8'h00;
    $readmemh(image, s32.mem);
    // The subroutine, on the bursting port too.
    for (i = 0; i < 32; i++) sB.mem[SUBB[15:0] + i] = s32.mem[SUBA[15:0] + i];

    reset_dut();
    reached = 1'b0;
    for (i = 0; i < 400000 && phase != DONE_MARK; i++) @(negedge clk);
    check(phase == DONE_MARK, $sformatf("the program reaches its end (phase %0d)", phase));
    repeat (20) @(negedge clk);

    // ------------------------------------------------------------------------
    // The data cache: hits and misses, enable, clear, clear entry, freeze
    // ------------------------------------------------------------------------
    // UM 6.1.2: "a data read cycle operates exactly like an instruction cache
    // read cycle; when a miss occurs, an external cycle is initiated to obtain
    // the operand from memory, and the data is loaded into the cache".
    check(nrd(1, 32'h8000) == 1, "1: a read that misses goes to the bus");
    check(nrd(2, 32'h8000) == 0, "2: the same read again hits: no bus cycle");
    check_res(0, pl(32'h8000), "1: the miss reads memory");
    check_res(1, pl(32'h8000), "2: the hit is the cached copy, not the memory changed behind it");
    // UM 6.3.1.6: ED clear disables the cache; it does not flush it.
    check(nrd(3, 32'h8000) == 2, "3: disabled, every read is a bus cycle");
    check_res(2, 32'hDEAD_0002, "3: disabled, memory is read");
    check(nrd(4, 32'h8000) == 0, "4: re-enabled, the old entry hits again");
    check_res(4, pl(32'h8000), "4: ... and holds what it held");
    // UM 6.3.1.3: CD clears all; it reads back as zero.
    check(nrd(5, 32'h8000) == 1, "5: CD: the entry is gone");
    check_res(5, 32'hDEAD_0002, "5: CD: memory is read");
    check_res(6, 32'h0000_0101, "5: CD reads back as zero");
    // UM 6.3.1.4: CED clears the entry CAAR's index names, regardless of the tag.
    check(nrd(6, 32'h8010) == 1 && nrd(6, 32'h8014) == 1, "6: two entries filled");
    check(nrd(7, 32'h8010) == 1, "7: CED: the entry CAAR names misses");
    check(nrd(7, 32'h8014) == 0, "7: CED: the one beside it still hits");
    check_res(11, 32'h0000_0101, "7: CED reads back as zero");
    check(nrd(8, 32'h8014) == 1, "8: CED by index alone: the tag is not compared");
    // UM 6.3.1.5: FD -- a miss does not replace; a write hit updates.
    check(nrd(9, 32'h8020) == 2, "9: frozen from the start: nothing is cached");
    check(nrd(10, 32'h8030) == 0, "10: frozen after a fill: the entry hits");
    check(nwr(10, 32'h8030) == 1, "10: a write while frozen goes to memory");
    check(nrd(11, 32'h8030) == 0, "11: ... and updated the entry that hit");
    check_res(17, 32'h10A0_A0A0, "11: the frozen cache serves the value written");
    check(nrd(12, 32'h8040) == 1, "12: frozen, WA is ignored: the write allocated nothing");
    check_res(18, 32'h1212_1212, "12: the write reached memory");
    // UM 6.1.2: write-through.
    check(nwr(13, 32'h8050) == 1, "13: a write that hits goes to memory too");
    check(wt_8050 === 32'h1313_1313, "13: ... with the value written");
    check(nrd(14, 32'h8050) == 0, "14: ... and the cache has it: no bus cycle");
    check_res(20, 32'h1313_1313, "14: the cached value is the one written");

    // ------------------------------------------------------------------------
    // Write allocation -- UM 6.1.2.1, figure 6-4, every example in both modes
    // ------------------------------------------------------------------------
    for (wa = 0; wa < 2; wa++) begin
      b = wa ? 40 : 20;
      k = wa ? 32 : 21;
      m = wa ? "WA" : "no WA";
      check(nwr(b + 0, 32'hA052) == 1, $sformatf("%s, example 1: the word write is on the bus", m));
      check(nrd(b + 1, 32'hA050) == 0, $sformatf("%s, example 1: a word write that hits updates the cache", m));
      check(nrd(b + 3, 32'hA058) == 0, $sformatf("%s, example 2: the half that hit was updated", m));
      check(nrd(b + 3, 32'hA054) == 1, $sformatf("%s, example 2: the half that missed was not allocated", m));
      check(nrd(b + 5, 32'hA054) == (wa ? 0 : 1),
            $sformatf("%s, example 3: an aligned long word, tag matching, entry invalid: %s", m,
                      wa ? "written and validated" : "not allocated"));
      check(nrd(b + 5, 32'hA050) == 0, $sformatf("%s, example 3: the rest of the line is untouched", m));
      check(nrd(b + 7, 32'hB054) == (wa ? 0 : 1),
            $sformatf("%s, example 4: an aligned long word, no tag match: %s", m,
                      wa ? "the tag replaced, the entry valid" : "not allocated"));
      check(nrd(b + 9, 32'hA050) == (wa ? 1 : 0),
            $sformatf("%s, example 4: the old line's other entries %s", m,
                      wa ? "invalidated" : "untouched"));
      check(nrd(b + 11, 32'hA050) == 0, $sformatf("%s, example 5: V0 untouched", m));
      check(nrd(b + 11, 32'hA058) == (wa ? 1 : 0),
            $sformatf("%s, example 5: a misaligned long word, no tag match: V2 %s", m,
                      wa ? "cleared" : "untouched"));
      check(nrd(b + 13, 32'hA054) == 1, $sformatf("%s: a byte write that misses allocates nothing", m));
      check(nrd(b + 15, 32'hA050) == (wa ? 1 : 0),
            $sformatf("%s: a byte write with no tag match %s", m,
                      wa ? "clears the entry it falls in" : "changes nothing"));
      for (i = 0; i < 11; i++)
        check(res(k + i) === snap[k + i],
              $sformatf("%s: probe %0d read %08h, memory holds %08h", m, i, res(k + i), snap[k + i]));
    end

    // ------------------------------------------------------------------------
    // Read-modify-write, CPU space, function codes -- UM 6.1.2, 6.1.2.2
    // ------------------------------------------------------------------------
    check(nrd(60, 32'h8060) == 1, "60: TAS: the read of a cached byte is forced to miss");
    check(nwr(60, 32'h8060) == 1, "60: TAS: the write");
    check(nrd(61, 32'h8060) == 0, "61: TAS: the write updated the entry");
    check_res(44, {24'd0, pb(32'h8060) | 8'h80}, "61: the cached byte has bit 7 set");
    check(nrd(62, 32'h8070) == 1 && nwr(62, 32'h8070) == 1, "62: TAS on a byte not cached");
    check(nrd(63, 32'h8070) == 0, "63: its read created the entry, its write updated it");
    check_res(45, {pb(32'h8070) | 8'h80, pb(32'h8071), pb(32'h8072), pb(32'h8073)},
              "63: the entry holds the long word the TAS read and wrote");
    check(nrd_fc(64, CPUA, 3'b111) == 2, "64: CPU space is never cached: two reads, two cycles");
    check_res(46, 32'hC0DE_CAFE, "64: the CPU-space device's answer");
    check(nrd_fc(65, 32'h8100, 3'd1) == 1, "65: user data space is another entry: it misses");
    check(nrd_fc(66, 32'h8100, 3'd1) == 0, "66: ... and is cached in its own right");
    check(nrd_fc(67, 32'h8100, 3'd6) == 1, "67: supervisor program space is a third");
    check(nrd_r(68, 32'h2000_0030, 32'h2000_0033) == 1 && nwr(68, 32'h2000_0031) == 1,
          "68: TAS on the 8-bit port: one read, one write, no completing cycles");
    check(nrd(69, 32'h2000_0031) == 1 && nrd_r(69, 32'h2000_0030, 32'h2000_0033) == 4,
          "69: the entry TAS could not refresh was left invalid: read and completed again");

    // ------------------------------------------------------------------------
    // Narrow ports -- UM 6.1.3.1, figures 6-5 to 6-10
    // ------------------------------------------------------------------------
    want_a[0] = 32'h2000_0003; want_s[0] = SB;
    want_a[1] = 32'h2000_0000; want_s[1] = S3;
    want_a[2] = 32'h2000_0001; want_s[2] = SW;
    want_a[3] = 32'h2000_0002; want_s[3] = SB;
    check_seq(70, 4, "70: figure 6-5, a byte at $03 from an 8-bit port");
    check(nrd_r(71, 32'h2000_0000, 32'h2000_0003) == 0, "71: the whole long word was cached");
    check_res(49, {24'd0, pb(32'h2000_0003)}, "70: the byte");
    check_res(50, {24'd0, pb(32'h2000_0001)}, "71: another byte of it, from the cache");
    want_a[0] = 32'h1000_0003; want_s[0] = SB;
    want_a[1] = 32'h1000_0000; want_s[1] = SW;
    check_seq(72, 2, "72: figure 6-6, a byte at $03 from a 16-bit port");
    check(nrd_r(73, 32'h1000_0000, 32'h1000_0003) == 0, "73: cached");
    check_res(52, {16'd0, pw(32'h1000_0000)}, "73: the word, from the cache");
    want_a[0] = 32'h2000_0006; want_s[0] = SL;
    want_a[1] = 32'h2000_0007; want_s[1] = S3;
    want_a[2] = 32'h2000_0004; want_s[2] = SW;
    want_a[3] = 32'h2000_0005; want_s[3] = SB;
    want_a[4] = 32'h2000_0008; want_s[4] = SW;
    want_a[5] = 32'h2000_0009; want_s[5] = SB;
    want_a[6] = 32'h2000_000A; want_s[6] = SW;
    want_a[7] = 32'h2000_000B; want_s[7] = SB;
    check_seq(74, 8, "74: figure 6-8, a long word at $06 from an 8-bit port");
    check(nrd_r(75, 32'h2000_0004, 32'h2000_000B) == 0, "75: both entries cached");
    check_res(53, pl(32'h2000_0006), "74: the long word");
    check_res(54, pl(32'h2000_0008), "75: the next, from the cache");
    want_a[0] = 32'h1000_0026; want_s[0] = SL;
    want_a[1] = 32'h1000_0024; want_s[1] = SW;
    want_a[2] = 32'h1000_0028; want_s[2] = SW;
    want_a[3] = 32'h1000_002A; want_s[3] = SW;
    check_seq(76, 4, "76: figure 6-9, a long word at $06 from a 16-bit port");
    check_res(55, pl(32'h1000_0026), "76: the long word");
    want_a[0] = 32'h0000_80A6; want_s[0] = SL;
    want_a[1] = 32'h0000_80A8; want_s[1] = SW;
    check_seq(77, 2, "77: figure 6-10, a long word at $06 from a 32-bit port");
    check(nrd_r(78, 32'h80A4, 32'h80AB) == 0, "78: both entries cached");
    want_a[0] = 32'h2000_0013; want_s[0] = SB;
    check_seq(79, 1, "79: disabled, only the operand's own cycle");

    // ------------------------------------------------------------------------
    // Half hits -- UM 6.1.2, 7.2.7
    // ------------------------------------------------------------------------
    want_a[0] = 32'h0000_80B8; want_s[0] = SW;
    check_seq(80, 1, "80: the first long word hits: only the second is read");
    i = first_rd(80, 32'h80B8);
    check(i >= 0 && c_ocs[i], "80: ... and its cycle has OCS (UM 7.2.7)");
    check_res(59, pl(32'h80B6), "80: the operand, half from the cache");
    want_a[0] = 32'h0000_80C6; want_s[0] = SL;
    check_seq(81, 1, "81: the second long word hits: only the first is read");
    check_res(60, pl(32'h80C6), "81: the operand, half from the cache");

    // ------------------------------------------------------------------------
    // Bursts -- UM 6.1.3.2, 7.3.7
    // ------------------------------------------------------------------------
    i = first_rd(90, 32'h3000_0104);
    check(nrd(90, 32'h3000_0104) == 1, "90: one cycle for a cold line");
    check(i >= 0 && c_brq[i] && c_back[i] && c_lw[i] == 4,
          $sformatf("90: CBREQ, CBACK and four long words (%0d)", (i >= 0) ? c_lw[i] : 0));
    check(nrd_r(91, 32'h3000_0100, 32'h3000_010F) == 0, "91: the whole line was filled");
    lw[0] = 32'h3000_0104; lw[1] = 32'h3000_0100; lw[2] = 32'h3000_0108; lw[3] = 32'h3000_010C;
    for (i = 0; i < 4; i++)
      check_res(61 + i, pl(lw[i]), $sformatf("90-91: long word %0d of the line", i));
    i = first_rd(92, 32'h3000_0114);
    check(nrd(92, 32'h3000_0114) == 1 && nrd(92, 32'h3000_0118) == 1,
          "92: DBE clear: single entries");
    check(i >= 0 && !c_brq[i], "92: DBE clear: no CBREQ");
    i = first_rd(93, 32'h3000_0124);
    check(i >= 0 && c_brq[i] && c_back[i] && c_lw[i] == 2,
          $sformatf("93: the device stops at two long words (%0d)", (i >= 0) ? c_lw[i] : 0));
    check(nrd(94, 32'h3000_0128) == 0, "94: the two long words the burst brought are cached");
    i = first_rd(94, 32'h3000_012C);
    check(i >= 0 && !c_brq[i] && nrd(94, 32'h3000_012C) == 1,
          "94: the rest of the line is a single entry fill, no CBREQ (UM 6.1.1)");
    i = first_rd(94, 32'h3000_0120);
    check(i >= 0 && !c_brq[i] && nrd(94, 32'h3000_0120) == 1,
          "94: ... and so is the entry before it");
    i = first_rd(95, 32'h3000_0134);
    check(i >= 0 && c_brq[i] && c_lw[i] == 3,
          $sformatf("95: CIIN on the third long word ends the burst after it (%0d)",
                    (i >= 0) ? c_lw[i] : 0));
    check(nrd(96, 32'h3000_0138) == 0, "96: the second long word is cached");
    check(nrd(96, 32'h3000_013C) == 1, "96: the third, with CIIN, is not");
    check(nrd(96, 32'h3000_0130) == 1, "96: nor the fourth, which the burst never reached");
    check(nrd(97, 32'h3000_0144) == 2, "97: CIIN throughout: nothing is cached");
    i = first_rd(97, 32'h3000_0144);
    check(i >= 0 && c_lw[i] == 1, "97: CIIN on the first cycle aborts the burst");
    check(nrd(98, 32'h3000_0154) == 0, "98: a write ignores CIIN: with WA it allocated");
    check_res(77, 32'h9898_9898, "98: the allocated entry holds the write");
    i = first_rd(99, 32'h3000_0164);
    check(i >= 0 && c_brq[i] && c_lw[i] == 3, "99: BERR on the third long word ends the burst");
    check(nrd(100, 32'h3000_0168) == 0, "100: the second long word is cached");
    check(nrd(100, 32'h3000_016C) == 1, "100: the third, which faulted, is not");
    want_a[0] = 32'h2000_0023; want_s[0] = SB;
    want_a[1] = 32'h2000_0020; want_s[1] = S3;
    want_a[2] = 32'h2000_0021; want_s[2] = SW;
    check_seq(101, 3, "101: BERR on a cycle that only completes the entry abandons it");
    check(nrd(102, 32'h2000_0023) == 1, "102: the entry was left invalid");
    check_res(81, {24'd0, pb(32'h2000_0023)}, "101: the operand arrived all the same");
    check_res(83, 32'd0, "99-102: no bus error exception for a cycle that carries no operand");

    // ------------------------------------------------------------------------
    // The instruction cache -- UM 6.1.1, 6.3.1
    // ------------------------------------------------------------------------
    check(nf(110, SUBA) > 0, "110: the first call fetches the subroutine");
    check(nf(111, SUBA) == 0 && nf(111, SUBA + 4) == 0, "111: the second is served by the cache");
    check(nf(112, SUBA) >= 9, "112: EI clear: every pass is a bus cycle");
    check(nf(113, SUBA) == 0, "113: re-enabled: the old entries hit (UM 6.3.1.11)");
    check(nf(114, SUBA) >= 9, "114: frozen from empty: nothing is ever cached (UM 6.3.1.10)");
    check(nf(115, SUBA) == 0 && nf(115, SUBA + 4) == 0, "115: frozen after a fill: the entries hit");
    check(nf(116, SUBA) >= 1 && nf(116, SUBA) <= 2, "116: CI: the call misses, then hits");
    check(nf(116, SUBA + 4) >= 1 && nf(116, SUBA + 4) <= 2, "116: CI: ... at both long words");
    check_res(84, 32'h0000_0001, "116: CI reads back as zero");
    check(nf(117, SUBA) >= 1, "117: CEI: the entry CAAR names misses");
    check(nf(117, SUBA + 4) == 0, "117: CEI: the entry beside it does not");
    check(nf(118, SUBA) >= 1, "118: CEI by index: the tag is not compared");
    i = -1;
    for (k = 0; k < ncyc; k++) if (i < 0 && c_ph[k] == 120 && c_f[k] && c_addr[k] == SUBB) i = k;
    check(i >= 0 && c_brq[i] && c_back[i] && c_lw[i] == 4,
          $sformatf("120: IBE: a cold line is one burst of four long words (%0d)",
                    (i >= 0) ? c_lw[i] : 0));
    check(nf(120, SUBB) == 1 && nf(120, SUBB + 4) == 0 && nf(120, SUBB + 8) == 0,
          "120: the rest of the line came with it");
    check(nf(121, SUBB) == 0, "121: and hits");
    check(nf_brq(122, SUBB, SUBB + 15) == 0 && nf(122, SUBB + 4) == 1,
          "122: IBE clear: single entries, no CBREQ");
    i = -1;
    for (k = 0; k < ncyc; k++) if (i < 0 && c_ph[k] == 123 && c_f[k] && c_addr[k] == SUBB) i = k;
    check(i >= 0 && c_lw[i] == 2, "123: the device stops at two long words");
    check(nf(123, SUBB + 8) >= 1 && nf_brq(123, SUBB + 8, SUBB + 8) == 0,
          "123: the next long word of the line is a single entry fill, no CBREQ");
    check(nf(124, SUBB) >= 9, "124: CIIN: no prefetch is cached");
    check(nf(125, SUBA) >= 9, "125: CDIS: the instruction cache is off");
    check(nrd(125, 32'h8200) == 1, "125: CDIS: the data cache is off");
    check(nf(126, SUBA) == 0, "126: CDIS negated: the instruction cache's entries are still there");
    check(nrd(126, 32'h8200) == 0, "126: ... and the data cache's");
    check(nf(127, SUBA + 8) >= 1, "127: the long word past the RTS is prefetched, and faults");
    check(nf(128, SUBA + 8) >= 1, "128: ... and is fetched again: never cached");
    check(nf(128, SUBA) == 0, "128: the rest of the line still hits");
    check_res(85, 32'd18, "131: modified code, no clear: the cache serves the old instruction");
    check_res(86, 32'd36, "132: CI: the new instruction runs");
    check_res(87, 32'd45, "133: CEI on its entry is enough");
    check(peek_w(SUBA) === 16'h5283, "133: the write went to memory");
    check(nf(134, SUBA) == 0, "134: supervisor: hits");
    check(nf(135, SUBA) > 0, "135: user: the supervisor's entries do not hit (FC2)");

    check(n_ecs == n_as && n_as > 0,
          $sformatf("every ECS starts a cycle: a hit aborts none (%0d ECS, %0d AS)", n_ecs, n_as));
    check(peek_l(EXC) == 32'd0, "no exception other than the TRAP #1 was taken");
    check(pipe_fails == 0, "the pipe invariant held throughout");

    if ($test$plusargs("cyclog"))
      for (i = 0; i < ncyc; i++)
        $display("cyc %0d ph %0d %08h siz %0d %s fc %0d %s brq %0d back %0d lw %0d ocs %0d", i,
                 c_ph[i], c_addr[i], c_siz[i], c_rw[i] ? "R" : "W", c_fc[i],
                 c_f[i] ? "F" : "D", c_brq[i], c_back[i], c_lw[i], c_ocs[i]);
    $display("core_cache_tb: %0d bus cycles recorded", ncyc);
    $display("core_cache_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("PASS: core_cache_tb");
    else            $display("FAIL: core_cache_tb");
    $finish;
  end

endmodule
