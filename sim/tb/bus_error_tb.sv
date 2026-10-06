// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- bus exception control: UM 7.5, Tables 7-8 and 7-9, on every kind
// of bus cycle.
//
// Part 1 is the six cases of Table 7-8 one by one, and AVEC.
//
// The table indexes two samples by "the number of the current even bus state":
// n is S2, one clock after AS asserts, and n+2 is S4. Every case below asserts
// its signals on the rising edge of exactly those states, which is also what
// UM 7.5 asks an external device to do so that specification 47A and 47B are met
// for the same falling edge.
//
//   1  DSACK, no BERR, no HALT                  normal cycle terminate and continue
//   2  HALT at or before DSACK                  normal terminate and halt
//   3  BERR in lieu of / at / before DSACK      terminate and take a bus error
//   4  BERR one state pair after DSACK          the same, deferred
//   5  BERR and HALT in lieu of / before        terminate and retry when HALT negated
//   6  BERR and HALT after DSACK                the same, deferred
//
// Cases 4 and 6 are the ones that earn their keep. On the MC68010 project the
// equivalent late assertion was detected and never delivered.
//
// Part 2 is the matrix: every case of Table 7-8 in every bus cycle of operands
// on 32-, 16- and 8-bit asynchronous ports, with and without wait states,
// aligned and misaligned; every case of Table 7-9 on a synchronous port with
// and without a wait state; the first access of a burst by Table 7-9; and BERR,
// BERR with HALT, and HALT on each later access of a burst (UM 7.5.1, 7.5.2,
// 7.3.7). Reads and writes, except a burst, which only reads. Each scenario
// checks the bus cycles run, the data or the memory, the fault and its
// residual, the retried cycle's access information, OCS, and the bus while
// halted or waiting to retry.
//
// Part 3 is HALT on its own (UM 7.5.3): on an idle bus, single-stepping
// (figure 7-57), during a read-modify-write, and with BERR on a burst access
// that carried part of a misaligned operand.

`timescale 1ns / 1ps

module bus_error_tb;

`include "rd68031_bus_harness.svh"

  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  int unsigned a0;
  string       what;

  // =========================================================================
  // The matrix: Tables 7-8 and 7-9 on every kind of cycle
  //
  // Each scenario is one operand on one device, with one case of the table
  // injected into its k-th bus cycle, as a read and as a write:
  //
  //   asynchronous (Table 7-8)  32-bit, 32-bit with three wait states, 16-bit
  //                             and 8-bit ports, aligned and misaligned, so that
  //                             k runs over every cycle of a dynamically sized
  //                             or misaligned operand (Table 7-6);
  //   synchronous  (Table 7-9)  a STERM port with no wait state and with one,
  //                             aligned and misaligned;
  //   burst        (7.5.1/7.5.2) the first access by Table 7-9, the later ones
  //                             by the burst paragraphs.
  //
  // "State N" is the rising edge on which the device asserts its termination:
  // S2 plus its wait states. The injector puts BERR and HALT on rising edges,
  // which is what UM 7.5 asks of external logic ("DSACKx, BERR, and HALT can be
  // asserted and negated with the rising edge of the MC68030 clock").
  // =========================================================================
  localparam int H = 6;          // clocks HALT is held past the end of a cycle

  // Every bus cycle, as AS asserts.
  localparam int MAXC = 8192;
  int unsigned ncyc;
  logic [31:0] rc_a     [0:MAXC-1];
  logic  [1:0] rc_siz   [0:MAXC-1];
  logic        rc_rw    [0:MAXC-1];
  logic        rc_cbreq [0:MAXC-1];
  logic        rc_ocs   [0:MAXC-1];
  logic        last_ocs;
  initial begin ncyc = 0; last_ocs = 1'b0; end

  always @(negedge ecs_n_o) begin #(SNAP); last_ocs = !ocs_n_o; end
  always @(negedge as_n_o) begin
    int unsigned ix;
    if (rst_n) begin
      ix   = ncyc;
      ncyc = ncyc + 1;
      #(SNAP);
      if (ix < MAXC) begin
        rc_a[ix]     = a_o;
        rc_siz[ix]   = siz_o;
        rc_rw[ix]    = rw_o;
        rc_cbreq[ix] = !cbreq_n_o;
        rc_ocs[ix]   = last_ocs;
      end
    end
  end

  // Every read beat the bus unit reports, for the burst cases.
  localparam int MAXB = 1024;
  int unsigned nb;
  logic        b_err [0:MAXB-1];
  logic  [1:0] b_num [0:MAXB-1];
  initial nb = 0;
  always @(negedge clk) begin
    if (rst_n && (beat_valid || beat_err)) begin
      if (nb < MAXB) begin
        b_err[nb] = beat_err;
        b_num[nb] = beat_num;
      end
      nb = nb + 1;
    end
  end

  function automatic logic [7:0] pat(input logic [31:0] a_);
    pat = 8'h3C ^ a_[7:0] ^ {a_[11:8], 4'h0} ^ {4'h0, a_[31:28]};
  endfunction

  function automatic logic [7:0] mem_rd(input logic [31:0] a_);
    case (a_[31:28])
      4'h0:    mem_rd = s32.mem[a_[11:0]];
      4'h1:    mem_rd = s16.mem[a_[11:0]];
      4'h2:    mem_rd = s8.mem[a_[11:0]];
      4'h3:    mem_rd = sw.mem[a_[11:0]];
      4'h4:    mem_rd = ss.mem[a_[11:0]];
      default: mem_rd = sn.mem[a_[11:0]];
    endcase
  endfunction

  task automatic mem_wr(input logic [31:0] a_, input logic [7:0] v);
    case (a_[31:28])
      4'h0:    s32.mem[a_[11:0]] = v;
      4'h1:    s16.mem[a_[11:0]] = v;
      4'h2:    s8.mem[a_[11:0]]  = v;
      4'h3:    sw.mem[a_[11:0]]  = v;
      4'h4:    ss.mem[a_[11:0]]  = v;
      default: sn.mem[a_[11:0]]  = v;
    endcase
  endtask

  // The port width of each region (UM 7.2.1; a STERM port is 32 bits).
  function automatic int unsigned port_w(input logic [31:0] a_);
    case (a_[31:28])
      4'h1:    port_w = 2;
      4'h2:    port_w = 1;
      default: port_w = 4;
    endcase
  endfunction

  // The cycles Table 7-6 splits an operand into, worked out here from 7.2.1's
  // rule rather than from the bus unit: each cycle moves as many of the bytes
  // still owed as fit in the port from where the address lands.
  int unsigned pl_n;
  logic [31:0] pl_a [0:7];
  int unsigned pl_b [0:7];

  task automatic make_plan(input logic [31:0] a_, input int unsigned nbytes);
    int unsigned rem, w, b;
    logic [31:0] x;
    rem = nbytes; x = a_; w = port_w(a_); pl_n = 0;
    while (rem > 0) begin
      b = w - (x % w);
      if (b > rem) b = rem;
      pl_a[pl_n] = x;
      pl_b[pl_n] = b;
      pl_n = pl_n + 1;
      x = x + b;
      rem = rem - b;
    end
  endtask

  // One operand, with what the bus unit says at its acknowledge. The fault
  // snapshot is written on the same edge as req_ack, so it is read just after.
  logic [39:0] o_rd;
  bit          o_f, o_fwr, o_frw;
  logic  [2:0] o_end, o_fb;
  logic [31:0] o_fa;
  int unsigned o_ncyc;

  task automatic op_any(input logic [31:0] a_, input int unsigned nbytes,
                        input bit wr, input logic [39:0] wd);
    @(negedge clk);
    req_kind  = wr ? 3'd1 : 3'd0;
    req_addr  = a_;
    req_bytes = nbytes[2:0];
    req_wdata = wr ? wd : 40'd0;
    pending   = 1'b1;
    @(posedge req_ack);
    #1;
    pending = 1'b0;
    o_rd    = req_rdata;
    o_f     = req_fault;
    o_fwr   = req_fault_wr;
    o_end   = req_end;
    o_fa    = flt_addr;
    o_fb    = flt_bytes;
    o_frw   = flt_rw;
    o_ncyc  = ncyc;
    @(negedge clk);
  endtask

  // What the halted or retrying bus looked like, seen by the injector.
  bit          h_quiet;     // no bus cycle began while HALT was held
  bit          h_ctl;       // AS, DS, DBEN negated and driven; data released
  bit          h_addr;      // the address driven, and the halted cycle's
  logic [31:0] h_a;

  task automatic watch_halt(input int unsigned c0, input logic [31:0] a_exp,
                            input bit want_addr);
    int unsigned i;
    h_quiet = 1'b1; h_ctl = 1'b1; h_addr = 1'b1;
    for (i = 0; i < H; i = i + 1) begin
      @(negedge clk); #(SNAP);
      if (ncyc != c0) h_quiet = 1'b0;
      if (!(as_n_o === 1'b1 && as_oe === 1'b1 && ds_n_o === 1'b1 && ds_oe === 1'b1
            && dben_n_o === 1'b1 && dben_oe === 1'b1 && d_oe === 1'b0))
        h_ctl = 1'b0;
      if (want_addr && !(a_oe === 1'b1 && a_o === a_exp)) h_addr = 1'b0;
    end
  endtask

  // ------------------------------------------------------------------------
  // One scenario.
  //   cs     the case of Table 7-8 or 7-9, 1 to 6
  //   k      the bus cycle of the operand it is injected into, from 1
  //   dclk   clocks after S2 that the signals are asserted on
  //   brq    the operand allows a burst
  // ------------------------------------------------------------------------
  task automatic scen(input string tag, input logic [31:0] a_, input int unsigned nbytes,
                      input bit wr, input int cs, input int unsigned k,
                      input int unsigned dclk, input bit brq, input bit sync);
    int unsigned base, i, moved, want_cyc, ocs0;
    logic [39:0] wd, expv;
    logic [31:0] ah;
    string what;
    bit fault_case, retry_case;

    make_plan(a_, nbytes);
    if (brq) pl_n = 1;      // a burst-capable aligned operand: one cycle
    fault_case = (cs == 3) || (cs == 4);
    retry_case = (cs == 5) || (cs == 6);

    // Fresh contents, and the value a read must return.
    for (i = 0; i < nbytes + 8; i = i + 1) mem_wr(a_ + i, pat(a_ + i));
    expv = '0;
    for (i = 0; i < nbytes; i = i + 1) expv = {expv[31:0], pat(a_ + i)};
    wd = {8'h00, 32'hD1E5_0000 ^ a_} ^ {32'h0, cs[3:0], k[3:0]};
    if (nbytes < 5) wd = wd & ((40'd1 << (8 * nbytes)) - 40'd1);

    req_burst = brq;
    base = ncyc;
    ocs0 = ocs_count;
    h_quiet = 1'b1; h_ctl = 1'b1; h_addr = 1'b1; h_a = '0;

    fork
      begin
        if (cs != 1) begin
          wait (ncyc >= base + k);
          @(posedge clk);                        // S2
          repeat (dclk) @(posedge clk);          // state N, or N+2
          berr_drv = (cs >= 3);
          halt_drv = (cs == 2) || retry_case;
          @(posedge as_n_o);
          if (cs == 2) begin
            // UM 7.5.3: the cycle completes; "the data bus is placed in the
            // high-impedance state, and bus control signals are driven
            // inactive ...; the address, function code, size, and read/write
            // signals remain in the same state".
            watch_halt(ncyc, rc_a[base + k - 1], 1'b1);
            @(posedge clk);
            halt_drv = 1'b0;
          end else if (retry_case) begin
            // UM 7.5.2: "the processor terminates the bus cycle, places the
            // control signals in their inactive state, and does not begin
            // another bus cycle until the HALT signal is negated".
            @(posedge clk);
            berr_drv = 1'b0;
            watch_halt(ncyc, 32'd0, 1'b0);
            @(posedge clk);
            halt_drv = 1'b0;
          end else begin
            @(posedge clk);
            berr_drv = 1'b0;
          end
        end
      end
      begin
        op_any(a_, nbytes, wr, wd);
        // Something for the bus to do next, so that a halt has a cycle to hold
        // off even when it came on the operand's last one.
        req_burst = 1'b0;
        op_read(32'h0000_0F00, 4, got, cycles);
      end
    join
    req_burst = 1'b0;

    // How many bus cycles the operand took, and what it returned.
    if (fault_case)      want_cyc = k;
    else if (retry_case) want_cyc = pl_n + 1;
    else                 want_cyc = pl_n;
    $sformat(what, "%s case %0d k=%0d %s: %0d bus cycles (got %0d)", tag, cs, k,
             wr ? "write" : "read", want_cyc, o_ncyc - base);
    check(o_ncyc - base == want_cyc, what);

    if (fault_case) begin
      moved = 0;
      for (i = 0; i + 1 < k; i = i + 1) moved = moved + pl_b[i];
      $sformat(what, "%s case %0d k=%0d %s: a bus error (UM 7.5.1)", tag, cs, k,
               wr ? "write" : "read");
      check(o_f === 1'b1 && o_end == 3'd2, what);
      $sformat(what, "%s case %0d k=%0d %s: reported as a %s", tag, cs, k,
               wr ? "write" : "read", wr ? "write" : "read");
      check(o_fwr === wr && o_frw === !wr, what);
      $sformat(what, "%s case %0d k=%0d %s: the residual is the faulted cycle's -- %08h, %0d bytes (got %08h, %0d)",
               tag, cs, k, wr ? "write" : "read", pl_a[k-1], nbytes - moved, o_fa, o_fb);
      check(o_fa === pl_a[k-1] && o_fb == nbytes - moved, what);
      if (wr) begin
        // The cycles before the faulted one wrote their bytes; the ones after
        // it never ran.
        bit okw;
        okw = 1'b1;
        for (i = 0; i < moved; i = i + 1)
          if (mem_rd(a_ + i) !== wd[(nbytes - 1 - i) * 8 +: 8]) okw = 1'b0;
        for (i = moved + pl_b[k-1]; i < nbytes; i = i + 1)
          if (mem_rd(a_ + i) !== pat(a_ + i)) okw = 1'b0;
        $sformat(what, "%s case %0d k=%0d write: the bytes before the fault written, none after",
                 tag, cs, k);
        check(okw, what);
      end
    end else begin
      $sformat(what, "%s case %0d k=%0d %s: no bus error", tag, cs, k,
               wr ? "write" : "read");
      check(o_f === 1'b0, what);
      if (wr) begin
        bit okw;
        okw = 1'b1;
        for (i = 0; i < nbytes; i = i + 1)
          if (mem_rd(a_ + i) !== wd[(nbytes - 1 - i) * 8 +: 8]) okw = 1'b0;
        $sformat(what, "%s case %0d k=%0d write: the operand is in memory", tag, cs, k);
        check(okw, what);
      end else begin
        $sformat(what, "%s case %0d k=%0d read: the data (want %010h, got %010h)",
                 tag, cs, k, expv, o_rd);
        check(o_rd === expv, what);
      end
      if (cs == 1 && pl_n == 1) begin
        $sformat(what, "%s case 1 %s: ends %s", tag, wr ? "write" : "read",
                 sync ? "CE_STERM" : "CE_DSACK");
        check(o_end == (sync ? 3'd6 : 3'd1), what);
      end
    end

    if (cs == 2) begin
      $sformat(what, "%s case 2 k=%0d %s: no cycle starts while HALT is asserted (UM 7.5.3)",
               tag, k, wr ? "write" : "read");
      check(h_quiet, what);
      $sformat(what, "%s case 2 k=%0d %s: halted -- control inactive and driven, data released",
               tag, k, wr ? "write" : "read");
      check(h_ctl, what);
      $sformat(what, "%s case 2 k=%0d %s: halted -- the address still the halted cycle's",
               tag, k, wr ? "write" : "read");
      check(h_addr, what);
    end

    if (retry_case) begin
      $sformat(what, "%s case %0d k=%0d %s: nothing runs until HALT is negated (UM 7.5.2)",
               tag, cs, k, wr ? "write" : "read");
      check(h_quiet, what);
      $sformat(what, "%s case %0d k=%0d %s: control inactive while waiting to retry",
               tag, cs, k, wr ? "write" : "read");
      check(h_ctl, what);
      // "Retries the previous cycle using the same access information
      // (address, function code, size, etc.)" -- and CBREQ again on a burst's
      // first access.
      $sformat(what, "%s case %0d k=%0d %s: the rerun has the same address, SIZ, R/W, CBREQ and OCS",
               tag, cs, k, wr ? "write" : "read");
      check(rc_a[base + k] === rc_a[base + k - 1]
            && rc_siz[base + k] === rc_siz[base + k - 1]
            && rc_rw[base + k] === rc_rw[base + k - 1]
            && rc_cbreq[base + k] === rc_cbreq[base + k - 1]
            && rc_ocs[base + k] === rc_ocs[base + k - 1], what);
    end

    // UM 7.1.1: OCS on the first bus cycle of the operand only -- and on its
    // rerun, if that is the cycle retried.
    $sformat(what, "%s case %0d k=%0d %s: OCS %0d times", tag, cs, k,
             wr ? "write" : "read", (retry_case && k == 1) ? 2 : 1);
    check(rc_ocs[base] === 1'b1, what);
    repeat (3) @(posedge clk);
  endtask

  // One device's sweep: case 1 once, cases 2 to 6 in each cycle of the operand.
  task automatic sweep(input string tag, input logic [31:0] a_, input int unsigned nbytes,
                       input int unsigned w, input bit sync, input bit brq,
                       input bit do_wr);
    int unsigned kk, c, nk, d, wv;
    make_plan(a_, nbytes);
    nk = brq ? 1 : pl_n;
    for (wv = 0; wv <= (do_wr ? 1 : 0); wv = wv + 1) begin
      scen(tag, a_, nbytes, wv[0], 1, 1, 0, brq && !wv[0], sync);
      for (kk = 1; kk <= nk; kk = kk + 1) begin
        for (c = 2; c <= 6; c = c + 1) begin
          if (!sync) begin
            // Table 7-8: N is where DSACK comes, S2 + w. Cases 3 and 5 put the
            // signals at S2, before or with DSACK; 4 and 6 at N+2, after it;
            // 2 puts HALT at N, with DSACK.
            if (c == 3 || c == 5) d = 0;
            else if (c == 2)      d = w;
            else                  d = w + 1;
            scen(tag, a_, nbytes, wv[0], c, kk, d, brq && !wv[0], sync);
          end else if (c == 4 || c == 6) begin
            // Table 7-9 cases 4 and 6 come with STERM: "BERR is asserted and
            // recognized on the next falling clock edge following the rising
            // clock edge on which STERM is asserted and recognized" (7.5.1).
            scen(tag, a_, nbytes, wv[0], c, kk, w, brq && !wv[0], sync);
          end else if (w > 0) begin
            // Cases 2, 3 and 5 are the table's "NA, A" for STERM: the signals
            // one rising edge before it, which needs a wait state to exist.
            scen(tag, a_, nbytes, wv[0], c, kk, w - 1, brq && !wv[0], sync);
          end
        end
      end
    end
  endtask

  // ------------------------------------------------------------------------
  // A later access of a burst -- UM 7.5.1 and 7.5.2.
  //
  //   kind 0  BERR: "the processor terminates the burst operation, and the
  //           cache entry corresponding to that cycle is marked invalid, but
  //           the processor does not take an exception";
  //   kind 1  BERR and HALT: "does not cause a retry operation ... causes
  //           independent BERR and HALT operations. The external bus activity
  //           remains halted until HALT is negated";
  //   kind 2  HALT: "if the HALT signal is asserted during a burst operation,
  //           the processor halts at the end of the operation".
  //
  // j is the long word of the burst, 2 to 4; bw the wait states before each.
  // ------------------------------------------------------------------------
  task automatic beat_scen(input int unsigned j, input int kind, input int unsigned bw);
    int unsigned base, nb0, i, nerr, nok;
    logic [31:0] a_;
    string what, kn;
    a_ = 32'h4000_0200 + {j[3:0], 4'h0} + {bw[3:0], 6'h0};
    for (i = 0; i < 16; i = i + 1) mem_wr({a_[31:4], 4'h0} + i, pat({a_[31:4], 4'h0} + i));
    ss.bwaits_rt = bw;
    kn = (kind == 0) ? "BERR" : (kind == 1) ? "BERR+HALT" : "HALT";
    req_burst = 1'b1;
    base = ncyc;
    nb0  = nb;
    h_quiet = 1'b1; h_ctl = 1'b1; h_addr = 1'b1;
    fork
      begin
        wait (ncyc >= base + 1);
        @(posedge clk);                                   // S2: the first long word
        repeat ((j - 1) * (bw + 1)) @(posedge clk);       // the j-th one's STERM
        berr_drv = (kind != 2);
        halt_drv = (kind != 0);
        @(posedge as_n_o);
        @(posedge clk);
        berr_drv = 1'b0;
        if (kind != 0) begin
          watch_halt(ncyc, a_, 1'b1);
          @(posedge clk);
          halt_drv = 1'b0;
        end
      end
      begin
        op_any(a_, 4, 1'b0, 40'd0);
        req_burst = 1'b0;
        op_read(32'h0000_0F00, 4, got, cycles);
      end
    join
    req_burst = 1'b0;
    ss.bwaits_rt = 0;

    $sformat(what, "burst %s on long word %0d (%0d waits): the operand, from the first, is intact",
             kn, j, bw);
    check(o_f === 1'b0 && o_rd[31:0] === {pat(a_), pat(a_ + 1), pat(a_ + 2), pat(a_ + 3)}, what);
    $sformat(what, "burst %s on long word %0d (%0d waits): one bus cycle, no retry (got %0d)",
             kn, j, bw, ncyc - base - 1);
    check(ncyc - base - 1 == 1, what);
    nerr = 0; nok = 0;
    for (i = nb0; i < nb; i = i + 1) begin
      if (b_err[i]) nerr = nerr + 1;
      else          nok = nok + 1;
    end
    // The follower is one more valid beat.
    if (kind == 2) begin
      $sformat(what, "burst HALT on long word %0d (%0d waits): the burst completes, four long words",
               j, bw);
      check(nok == 4 + 1 && nerr == 0, what);
      $sformat(what, "burst HALT on long word %0d (%0d waits): then the bus halts (UM 7.3.7)", j, bw);
      check(h_quiet && h_ctl && h_addr, what);
    end else begin
      $sformat(what, "burst %s on long word %0d (%0d waits): %0d long words, then one marked invalid (got %0d, %0d)",
               kn, j, bw, j - 1, nok - 1, nerr);
      check(nok == j - 1 + 1 && nerr == 1, what);
      if (kind == 1) begin
        $sformat(what, "burst BERR+HALT on long word %0d (%0d waits): halted until HALT negates, not retried",
                 j, bw);
        check(h_quiet && h_ctl, what);
      end
    end
    repeat (3) @(posedge clk);
  endtask

  // ------------------------------------------------------------------------
  // HALT on its own -- UM 7.5.3 and figure 7-57.
  // ------------------------------------------------------------------------
  task automatic halt_tests();
    int unsigned base, i, c0;
    bit ok_step, quiet;
    logic [39:0] expv;
    string what;

    // HALT asserted while the bus is idle stops the next cycle from starting:
    // "the MC68030 halts external bus activity at the next bus cycle boundary".
    // Then single-step: "negating and reasserting HALT in accordance with the
    // correct timing requirements provides a single-step (bus cycle to bus
    // cycle) operation". A long word from the 8-bit port is four cycles, so
    // four steps.
    for (i = 0; i < 4; i = i + 1) mem_wr(32'h2000_0300 + i, pat(32'h2000_0300 + i));
    expv = {8'h00, pat(32'h2000_0300), pat(32'h2000_0301), pat(32'h2000_0302),
            pat(32'h2000_0303)};
    @(posedge clk);
    halt_drv = 1'b1;
    repeat (4) @(posedge clk);
    base = ncyc;
    ok_step = 1'b1;
    quiet = 1'b1;
    fork
      op_any(32'h2000_0300, 4, 1'b0, 40'd0);
      begin
        repeat (10) @(posedge clk);
        if (ncyc != base) quiet = 1'b0;
        for (i = 1; i <= 4; i = i + 1) begin
          // One step: negate HALT, and assert it again on the rising edge that
          // starts S2 of the cycle that lets out (figure 7-57).
          halt_drv = 1'b0;
          wait (ncyc >= base + i);
          @(posedge clk);
          halt_drv = 1'b1;
          repeat (8) @(posedge clk);
          if (ncyc != base + i) ok_step = 1'b0;
        end
        halt_drv = 1'b0;
      end
    join
    check(quiet, "HALT asserted on an idle bus: no cycle starts (UM 7.5.3)");
    check(ok_step, "single-step: exactly one bus cycle per negation of HALT (figure 7-57)");
    check(o_rd === expv && o_f === 1'b0, "single-step: the operand assembled across four steps");
    repeat (4) @(posedge clk);

    // HALT during a read-modify-write: the read completes, the bus halts with
    // RMC still asserted -- the lock is not broken by a halt any more than by a
    // retry, during which "RMC remains asserted during the entire retry
    // sequence" (UM 7.5.2) -- and the write runs when HALT negates.
    for (i = 0; i < 4; i = i + 1) mem_wr(32'h0000_0340 + i, pat(32'h0000_0340 + i));
    base = ncyc;
    begin
      bit rmc_kept, no_write, rmc_neg;
      rmc_kept = 1'b1; no_write = 1'b1; rmc_neg = 1'b0;
      fork
        begin
          wait (ncyc >= base + 1);
          @(posedge clk);
          halt_drv = 1'b1;
          @(posedge as_n_o);
          for (i = 0; i < H; i = i + 1) begin
            @(negedge clk); #(SNAP);
            if (!(rmc_n_o === 1'b0 && rmc_oe === 1'b1)) rmc_kept = 1'b0;
            if (ncyc != base + 1) no_write = 1'b0;
          end
          @(posedge clk);
          halt_drv = 1'b0;
        end
        begin
          req_rmc = 1'b1;
          op_any(32'h0000_0340, 1, 1'b0, 40'd0);
          op_any(32'h0000_0340, 1, 1'b1, 40'h80);
          req_rmc = 1'b0;
          op_read(32'h0000_0F00, 4, got, cycles);
          #(SNAP);
          rmc_neg = (rmc_n_o === 1'b1);
        end
      join
      check(no_write, "HALT during an RMC sequence: the write waits for HALT to negate");
      check(rmc_kept, "HALT during an RMC sequence: RMC stays asserted and driven while halted");
      check(mem_rd(32'h0000_0340) === 8'h80, "HALT during an RMC sequence: the write then runs");
      check(rmc_neg, "HALT during an RMC sequence: RMC negated after the sequence");
    end
    repeat (4) @(posedge clk);

    // A misaligned operand whose second part arrives in the burst's second
    // long word, and BERR with HALT on that long word: the burst ends, the
    // bus halts, and once HALT negates the part is read again, with CBREQ
    // negated -- 7.5.1, "if the second cycle is for a portion of a misaligned
    // operand fetch, the processor runs another read cycle for the second
    // portion with CBREQ negated", which the halt only delays.
    for (i = 0; i < 16; i = i + 1) mem_wr(32'h4000_0380 + i, pat(32'h4000_0380 + i));
    base = ncyc;
    req_burst = 1'b1;
    fork
      begin
        wait (ncyc >= base + 1);
        @(posedge clk);
        @(posedge clk);                       // the second long word's STERM
        berr_drv = 1'b1;
        halt_drv = 1'b1;
        @(posedge as_n_o);
        @(posedge clk);
        berr_drv = 1'b0;
        watch_halt(ncyc, 32'h4000_0386, 1'b1);
        @(posedge clk);
        halt_drv = 1'b0;
      end
      op_any(32'h4000_0386, 4, 1'b0, 40'd0);
    join
    req_burst = 1'b0;
    check(o_f === 1'b0 && o_rd[31:0] === {pat(32'h4000_0386), pat(32'h4000_0387),
                                          pat(32'h4000_0388), pat(32'h4000_0389)},
          "misaligned burst, BERR+HALT on the second long word: the operand completes");
    check(o_ncyc - base == 2, "misaligned burst, BERR+HALT on the second long word: one more cycle");
    check(h_quiet && h_ctl && h_addr,
          "misaligned burst, BERR+HALT on the second long word: halted first");
    check(rc_cbreq[base] === 1'b1 && rc_cbreq[base + 1] === 1'b0
          && rc_a[base + 1] === 32'h4000_0388 && rc_siz[base + 1] === 2'b10,
          "misaligned burst: the rest read at $..88, two bytes, CBREQ negated (figure 7-53)");
    repeat (4) @(posedge clk);
  endtask

  initial begin
    $display("bus_error_tb: UM 7.5, Tables 7-8 and 7-9");
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) s32.mem[t] = 8'h10 + t[7:0];

    // -------------------------------------------------------------------
    // Case 1: normal. The baseline the others are measured against.
    // -------------------------------------------------------------------
    op_read(32'h0000_0100, 4, got, cycles);
    check(got[31:0] === 32'h10111213, "case 1: data");
    check(cycles == 1,                "case 1: one bus cycle");
    check(req_end == 3'd1,            "case 1: req_end is CE_DSACK");

    // -------------------------------------------------------------------
    // Case 3: BERR in lieu of DSACK. $8000_0000 is unmapped, so nothing
    // answers and BERR is the only way the cycle can end.
    // -------------------------------------------------------------------
    begin
      bit          saw_fault;
      bit          saw_wr;
      logic [2:0]  saw_end;
      logic [31:0] saw_addr;
      logic  [2:0] saw_bytes;
      saw_fault = 1'b0;
      fork
        begin
          assert_at_n(1'b1, 1'b0);
          // req_fault and the residual are valid with req_ack, which is a
          // one-clock pulse, so they have to be sampled there.
          @(posedge req_ack);
          saw_fault = req_fault;
          saw_wr    = req_fault_wr;
          saw_end   = req_end;
          saw_addr  = flt_addr;
          saw_bytes = flt_bytes;
          release_exc();
        end
        op_read(32'h8000_0000, 4, got, cycles);
      join
      check(cycles == 1,       "case 3: the cycle ends rather than hanging");
      check(saw_fault,         "case 3: req_fault is raised with req_ack");
      check(!saw_wr,           "case 3: req_fault_wr is clear -- it was a read");
      check(saw_end == 3'd2,   "case 3: req_end is CE_BERR");
      check(saw_addr === 32'h8000_0000,
            "case 3: the residual address is the faulted access, not past it");
      check(saw_bytes == 3'd4,
            "case 3: the residual is the whole operand -- nothing was moved");
    end

    // A faulted WRITE reports req_fault_wr, which the special status word needs.
    begin
      bit saw_wr;
      saw_wr = 1'b0;
      fork
        begin
          assert_at_n(1'b1, 1'b0);
          @(posedge req_ack);
          saw_wr = req_fault_wr;
          release_exc();
        end
        op_write(32'h8000_0010, 2, 40'h00_0000_BEEF, cycles);
      join
      check(saw_wr, "a faulted write reports req_fault_wr");
    end

    // -------------------------------------------------------------------
    // Case 5: BERR and HALT in lieu of DSACK -- retry. A mapped address, so the
    // rerun succeeds and the operand completes with the right data.
    // -------------------------------------------------------------------
    a0 = as_count;
    fork
      begin
        assert_at_n(1'b1, 1'b1);
        repeat (2) @(posedge clk);
        berr_drv = 1'b0;
        halt_drv = 1'b0;
      end
      op_read(32'h0000_0100, 4, got, cycles);
    join
    check(got[31:0] === 32'h10111213, "case 5: the retried cycle returns the data");
    $sformat(what, "case 5: two bus cycles -- the original and the rerun (got %0d)", cycles);
    check(cycles == 2, what);

    // -------------------------------------------------------------------
    // Case 6: BERR and HALT one state pair after DSACK -- the late retry.
    // -------------------------------------------------------------------
    fork
      begin
        assert_at_n2(1'b1, 1'b1);
        repeat (2) @(posedge clk);
        berr_drv = 1'b0;
        halt_drv = 1'b0;
      end
      op_read(32'h0000_0104, 4, got, cycles);
    join
    check(got[31:0] === 32'h14151617, "case 6: the retried cycle returns the data");
    $sformat(what, "case 6: two bus cycles (got %0d)", cycles);
    check(cycles == 2, what);

    // -------------------------------------------------------------------
    // Case 2: HALT at state n, no BERR. The cycle completes normally; the next
    // one does not start until HALT is negated. UM 7.5.3: "HALT by itself does
    // not terminate a bus cycle."
    // -------------------------------------------------------------------
    fork
      assert_at_n(1'b0, 1'b1);
      op_read(32'h0000_0108, 4, got, cycles);
    join
    check(got[31:0] === 32'h18191A1B, "case 2: the cycle completes normally");
    check(cycles == 1,                "case 2: one bus cycle");

    // While halted: the data bus is released, AS and DS are negated but still
    // driven, and the address group stays driven (UM 7.5.3).
    repeat (2) @(posedge clk);
    check(d_oe === 1'b0,  "halted: the data bus is high impedance");
    check(as_n_o === 1'b1, "halted: AS is negated");
    check(as_oe === 1'b1,  "halted: AS is negated, not released");
    check(a_oe === 1'b1,   "halted: the address group remains driven");

    // A request made while halted must wait.
    a0 = as_count;
    fork
      begin
        repeat (8) @(posedge clk);
        check(as_count == a0, "halted: no bus cycle starts while HALT is asserted");
        @(posedge clk);
        halt_drv = 1'b0;
      end
      op_read(32'h0000_010C, 4, got, cycles);
    join
    check(got[31:0] === 32'h1C1D1E1F, "halted: the cycle runs once HALT is negated");

    // -------------------------------------------------------------------
    // Case 4: BERR one state pair after DSACK -- the late bus error. The cycle
    // terminated normally and the exception is taken anyway.
    // -------------------------------------------------------------------
    begin
      bit saw_fault;
      saw_fault = 1'b0;
      fork
        begin
          assert_at_n2(1'b1, 1'b0);
          @(posedge req_ack);
          saw_fault = req_fault;
          release_exc();
        end
        op_read(32'h0000_0110, 4, got, cycles);
      join
      check(saw_fault, "case 4: a BERR one state pair after DSACK raises req_fault");
    end

    // -------------------------------------------------------------------
    // AVEC -- UM 7.1.7: "the autovector (AVEC) signal can be used to terminate interrupt
    // acknowledge cycles ... AVEC is ignored during all other bus cycles."
    // A board that ties it low -- a Sun-3/60 replica autovectors everything
    // that way -- must still see its ordinary cycles wait for DSACK. The slave
    // at $3000_0000 inserts three wait states, so a cycle AVEC ended would end
    // at the first sample, before its data, and report CE_AVEC.
    // -------------------------------------------------------------------
    avec_drv = 1'b1;
    op_write(32'h3000_0100, 4, 40'h00_CAFE_F00D, cycles);
    check(req_end == 3'd1, "AVEC on a write: ignored, the cycle ends on DSACK");
    check({sw.mem[12'h100], sw.mem[12'h101], sw.mem[12'h102], sw.mem[12'h103]}
          === 32'hCAFE_F00D, "AVEC on a write: the slave took the data");
    op_read(32'h3000_0100, 4, got, cycles);
    check(req_end == 3'd1, "AVEC on a read: ignored, the cycle ends on DSACK");
    check(got[31:0] === 32'hCAFE_F00D, "AVEC on a read: the data came back");

    // ... and on an interrupt acknowledge it still ends the cycle, with nothing
    // else answering: CPU space type $F, level 5, where no slave lives.
    req_fc       = 3'b111;
    req_cpuspace = 4'hF;
    req_cpuaddr  = 8'd5;
    op_read(32'h0, 1, got, cycles);
    check(req_end == 3'd4, "AVEC on an interrupt acknowledge: ends it, CE_AVEC");
    check(cycles == 1,     "AVEC on an interrupt acknowledge: one cycle");
    req_fc       = 3'b101;
    req_cpuspace = 4'd0;
    req_cpuaddr  = 8'd0;
    avec_drv     = 1'b0;

    // -------------------------------------------------------------------
    // Part 2: the matrix.
    // -------------------------------------------------------------------
    $display("  .. part 1: %0d checks", checks);
    sweep("async 32-bit",                 32'h0000_0100, 4, 0, 1'b0, 1'b0, 1'b1);
    sweep("async 32-bit misaligned",      32'h0000_0123, 4, 0, 1'b0, 1'b0, 1'b1);
    sweep("async 32-bit 3 waits",         32'h3000_0140, 4, 3, 1'b0, 1'b0, 1'b1);
    sweep("async 32-bit 3 waits, word",   32'h3000_0163, 2, 3, 1'b0, 1'b0, 1'b1);
    sweep("async 16-bit misaligned",      32'h1000_0181, 4, 0, 1'b0, 1'b0, 1'b1);
    sweep("async 8-bit",                  32'h2000_01C0, 4, 0, 1'b0, 1'b0, 1'b1);
    $display("  .. Table 7-8 matrix: %0d checks", checks);
    sn.waits_rt = 0;
    sweep("sync",                         32'h5000_0200, 4, 0, 1'b1, 1'b0, 1'b1);
    sweep("sync misaligned",              32'h5000_0222, 4, 0, 1'b1, 1'b0, 1'b1);
    sn.waits_rt = 1;
    sweep("sync 1 wait",                  32'h5000_0240, 4, 1, 1'b1, 1'b0, 1'b1);
    sweep("sync 1 wait misaligned",       32'h5000_0263, 2, 1, 1'b1, 1'b0, 1'b1);
    sn.waits_rt = 0;
    ss.waits_rt = 0;
    sweep("burst, first access",          32'h4000_0100, 4, 0, 1'b1, 1'b1, 1'b0);
    ss.waits_rt = 1;
    sweep("burst 1 wait, first access",   32'h4000_0140, 4, 1, 1'b1, 1'b1, 1'b0);
    ss.waits_rt = 0;
    $display("  .. Table 7-9 matrix: %0d checks", checks);
    begin
      int unsigned jj, kd, bw;
      for (bw = 0; bw < 2; bw = bw + 1)
        for (jj = 2; jj <= 4; jj = jj + 1)
          for (kd = 0; kd < 3; kd = kd + 1)
            beat_scen(jj, kd, bw);
    end
    $display("  .. burst later accesses: %0d checks", checks);

    // -------------------------------------------------------------------
    // Part 3: HALT on its own.
    // -------------------------------------------------------------------
    halt_tests();

    $display("bus_error_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_error_tb");
    else                                     $display("FAIL: bus_error_tb");
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: bus_error_tb timed out");
    $finish;
  end

endmodule
