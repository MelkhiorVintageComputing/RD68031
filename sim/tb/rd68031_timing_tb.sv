// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the AC-timing event log, for the MC68030EC specifications.
//
// Emits times and nothing else. No testbench here knows what a specification is;
// the limits live in tools/timing/specs.py and the reading of the figures in
// tools/timing/anchors.py. That separation is what lets a wrong anchor be fixed
// with a one-line edit and a re-analysis in milliseconds instead of a
// re-simulation -- and it is what would let a second core, in another language,
// be judged by exactly the same code.
//
// An RTL model has no pad delays, so every pin moves exactly on a clock edge.
// What is recorded is therefore which edge, and in which direction: the analysis
// adds the unknown pad delay to it and asks whether any assignment of those
// delays fits inside the data sheet.
//
// Output format, one line per record:
//
//     C <period_ns>                         the clock this run used
//     H <name> <value>                      a fact about the design under test
//     S <scenario>                          the events that follow belong to it
//     T <time_ns> <R|F|X> <event>           a transition, on a rising or falling
//                                           edge, or (X) a stimulus at no edge
//     P <input> <R|F|?> <off_before> <off_after> <out_before> <out_after>
//     Q <name> <value_ns> <ok>
//
// THREE KINDS OF EVENT. `<pin>.<what>` is a pin of the core moving, and gets a
// pad delay. `in.<pin>.<what>` is this testbench moving an input -- a device's
// pin, at the time it moves, with no delay of the core's own. `smp.<what>` and
// `clk.end` are clock edges inside the core: where it samples an input, and the
// edge a cycle ends on; they have no pad delay either. The vocabulary is fixed
// in tools/timing/anchors.py and nothing may invent one that is not in it.
//
// THE PROBES (P). An RTL model samples an input at one instant, and an input's
// setup and hold specifications are a window around one clock edge; the design
// meets them if that instant lies inside the window around the edge the data
// sheet names. A probe finds the instant: it makes the same input change twice,
// once half a nanosecond before an edge and once half a nanosecond after it,
// and records what the core did each time. If the two runs differ, the core
// sampled that input inside that nanosecond -- on that edge. The kind of edge
// (R or F) is read off the clock, not assumed. The analysis then checks the
// nanosecond against the data sheet's window at each grade.
//
// THE SAMPLING EDGES (smp.*) in the scenario logs are read off the bus unit's
// state -- the probes are what prove they are the edges the inputs are really
// sampled on.

`timescale 1ns / 1ps

module rd68031_timing_tb;

`include "rd68031_bus_harness.svh"

  integer      log;
  string       logname;
  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  logic        recording;
  string       edge_c;

  // A device of the testbench's own, at $6000_0000 where no harness slave
  // answers: its DSACK, its STERM and its data, moved at chosen instants.
  logic  [1:0] dk_drv;
  logic        st_drv;
  logic [31:0] pd;
  logic        pdoe;
  // auto_dk answers every cycle with a 32-bit DSACK while AS is asserted: what
  // the skew test leaves behind it, so that a core which split the long word
  // into byte cycles finishes them -- with the wrong bytes -- instead of hanging.
  logic        auto_dk;
  assign dsack_ext_n = dk_drv & ((auto_dk && !as_n_o) ? 2'b00 : 2'b11);
  assign sterm_ext_n = st_drv;
  assign dbus = pdoe ? pd : 32'bz;

  localparam logic [31:0] NOBODY = 32'h6000_0000;
  localparam logic [31:0] DATA_A = 32'hA5A5_A5A5;
  localparam logic [31:0] DATA_B = 32'h5A5A_5A5A;

  // The previous snapshot, so that a transition is a difference.
  logic [31:0] p_a;
  logic  [2:0] p_fc;
  logic  [1:0] p_siz;
  logic        p_rmc, p_ciout, p_aoe;
  logic [31:0] p_d;
  logic        p_doe;
  logic        p_ecs, p_ocs, p_as, p_ds, p_rw, p_dben, p_bg, p_asoe;
  logic        p_cbreq, p_status, p_refill, p_rst;
  logic        primed;

  // A transition seen by the snapshot, which runs SNAP after the edge: logged
  // at the edge itself, so that it lines up with a stimulus logged at the
  // instant it was applied.
  task automatic emit(input string name);
    if (recording) $fdisplay(log, "T %0.3f %s %s", $realtime - SNAP, edge_c, name);
  endtask

  // A stimulus: the time it is applied, at no clock edge.
  task automatic emit_in(input string name);
    if (recording) $fdisplay(log, "T %0.3f X %s", $realtime, name);
  endtask

  task automatic snap(input string which);
    edge_c = which;
    if (primed) begin
      // Clock edges inside the core first, so that the pairing rule -- the
      // first occurrence of b strictly later in the log -- sees a sample before
      // a pin that moves on the same edge. Only falling edges sample
      // DSACK, BERR, HALT and AVEC, and latch data.
      if (which == "F") begin
        // Every falling edge the termination inputs are sampled on: entering
        // S3 and each wait (UM 7.3.1 state 3), the late sample entering S5 and
        // the synchronous verdict (Tables 7-8 and 7-9), and each burst beat.
        if ((dut.st_n == rd68031_pkg::ST_S3) || (dut.st_n == rd68031_pkg::ST_WL)
            || (dut.st_n == rd68031_pkg::ST_S5) || (dut.st_n == rd68031_pkg::ST_BL)
            || (dut.st_n == rd68031_pkg::ST_BW))
          emit("smp.term");
        // DSACK's own samples.
        if ((dut.st_n == rd68031_pkg::ST_S3) || (dut.st_n == rd68031_pkg::ST_WL))
          emit("smp.dsack");
        // The late BERR/HALT sample of a DSACK cycle: S4 into S5.
        if ((dut.st_n == rd68031_pkg::ST_S5) && (dut.st_p == rd68031_pkg::ST_S4))
          emit("smp.late");
        // Read data latched: the end of S4, or the falling edge after STERM.
        if (((dut.st_n == rd68031_pkg::ST_S5) || (dut.st_n == rd68031_pkg::ST_BL))
            && dut.cyc_rw)
          emit("smp.data");
        // The clock low that ends a cycle: the edge AS is negated on.
        if (as_n_o && !p_as) emit("clk.end");
      end

      // The address group -- address, function codes, SIZ, RMC and CIOUT move
      // together and are judged together by specifications 6, 6B, 7, 8, 11 and
      // 13.
      if (a_oe && !p_aoe) begin
        emit("addr.valid");
      end else if (a_oe && p_aoe &&
                   ({a_o, fc_o, siz_o, rmc_n_o, ciout_n_o}
                    !== {p_a, p_fc, p_siz, p_rmc, p_ciout})) begin
        emit("addr.invalid");
        emit("addr.valid");
      end else if (!a_oe && p_aoe) begin
        emit("addr.invalid");
        emit("addr.hiz");
      end

      // The data bus on a write.
      if (d_oe && !p_doe) begin
        emit("dout.valid");
      end else if (d_oe && p_doe && (d_o !== p_d)) begin
        emit("dout.invalid");
        emit("dout.valid");
      end else if (!d_oe && p_doe) begin
        emit("dout.invalid");
        emit("dout.hiz");
      end

      if (!ecs_n_o &&  p_ecs) emit("ecs.assert");
      if ( ecs_n_o && !p_ecs) emit("ecs.negate");
      if (!ocs_n_o &&  p_ocs) emit("ocs.assert");
      if ( ocs_n_o && !p_ocs) emit("ocs.negate");
      if (!as_n_o  &&  p_as)  emit("as.assert");
      if ( as_n_o  && !p_as)  emit("as.negate");
      if (!ds_n_o  &&  p_ds)  emit("ds.assert");
      if ( ds_n_o  && !p_ds)  emit("ds.negate");
      if (!cbreq_n_o &&  p_cbreq) emit("cbreq.assert");
      if ( cbreq_n_o && !p_cbreq) emit("cbreq.negate");

      if (rw_o !== p_rw) begin
        emit("rw.change");
        if (rw_o) emit("rw.high");
        else      emit("rw.low");
      end

      // DBEN is active low on the pin (UM Table 5-2).
      if (!dben_n_o &&  p_dben) emit("dben.assert");
      if ( dben_n_o && !p_dben) emit("dben.negate");

      if (!bg_n_o &&  p_bg) emit("bg.assert");
      if ( bg_n_o && !p_bg) emit("bg.negate");

      // The control group goes high impedance only on relinquish, and is driven
      // again when the bus comes back.
      if (!as_oe && p_asoe) emit("ctl.hiz");
      if ( as_oe && !p_asoe) emit("ctl.drive");

      if (!status_n_o &&  p_status) emit("status.assert");
      if ( status_n_o && !p_status) emit("status.negate");
      if (!refill_n_o &&  p_refill) emit("refill.assert");
      if ( refill_n_o && !p_refill) emit("refill.negate");

      // RESET, as the RESET instruction drives it: open drain, so the enable.
      if ( reset_n_oe && !p_rst) emit("rst.assert");
      if (!reset_n_oe &&  p_rst) emit("rst.negate");
    end

    p_a = a_o; p_fc = fc_o; p_siz = siz_o; p_rmc = rmc_n_o; p_ciout = ciout_n_o;
    p_aoe = a_oe; p_d = d_o; p_doe = d_oe;
    p_ecs = ecs_n_o; p_ocs = ocs_n_o; p_as = as_n_o; p_ds = ds_n_o;
    p_cbreq = cbreq_n_o;
    p_rw = rw_o; p_dben = dben_n_o; p_bg = bg_n_o; p_asoe = as_oe;
    p_status = status_n_o; p_refill = refill_n_o; p_rst = reset_n_oe;
    primed = 1'b1;
  endtask

  // Sample SNAP ns after every edge: late enough that the edge has settled,
  // early enough that nothing else has happened.
  always @(posedge clk) begin #(SNAP); snap("R"); end
  always @(negedge clk) begin #(SNAP); snap("F"); end

  task automatic scenario(input string name);
    $fdisplay(log, "S %s", name);
    recording = 1'b1;
  endtask

  task automatic quiesce();
    repeat (6) @(posedge clk);
    recording = 1'b0;
    repeat (2) @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // The probes
  // ---------------------------------------------------------------------------
  localparam int I_DSACK  = 0;
  localparam int I_STERM  = 1;
  localparam int I_CBACK  = 2;
  localparam int I_CIIN   = 3;
  localparam int I_BERR   = 4;
  localparam int I_HALT   = 5;
  localparam int I_BH     = 6;   // BERR and HALT together
  localparam int I_AVEC   = 7;
  localparam int I_DATA   = 8;
  localparam int I_IPL    = 9;
  localparam int I_CDIS   = 10;
  localparam int I_MMUDIS = 11;
  localparam int I_BR     = 12;
  localparam int I_BGACK  = 13;
  localparam int I_RESET  = 14;

  // Assert (v = 1) or negate an input. I_DATA switches the read data from
  // DATA_A to DATA_B.
  task automatic stim(input int which, input bit v);
    case (which)
      I_DSACK:  dk_drv      = v ? 2'b00 : 2'b11;
      I_STERM:  st_drv      = ~v;
      I_CBACK:  cback_force = v;
      I_CIIN:   ciin_force  = v;
      I_BERR:   berr_drv    = v;
      I_HALT:   halt_drv    = v;
      I_BH:     begin berr_drv = v; halt_drv = v; end
      I_AVEC:   avec_drv    = v;
      I_DATA:   pd          = v ? DATA_B : DATA_A;
      I_IPL:    ipl_drv     = v ? 3'd5 : 3'd0;
      I_CDIS:   cdis_drv    = v;
      I_MMUDIS: mmudis_drv  = v;
      I_BR:     br_drv      = v;
      I_BGACK:  bgack_drv   = v;
      I_RESET:  reset_in_drv = v;
      default:  ;
    endcase
  endtask

  // Apply a stimulus at e + off, and read the kind of edge e is off the clock
  // itself, a quarter nanosecond either side of it.
  task automatic place(input real e, input real off, input int which, input bit v,
                       output string kind);
    logic c0, c1;
    if (off < 0.0) begin
      #(e + off - $realtime);  stim(which, v);
      #(e - 0.25 - $realtime); c0 = clk;
      #(e + 0.25 - $realtime); c1 = clk;
    end else begin
      #(e - 0.25 - $realtime); c0 = clk;
      #(e + 0.25 - $realtime); c1 = clk;
      #(e + off - $realtime);  stim(which, v);
    end
    if (c0 === 1'b1 && c1 === 1'b0)      kind = "F";
    else if (c0 === 1'b0 && c1 === 1'b1) kind = "R";
    else                                 kind = "?";
  endtask

  // The edge kind two runs of a probe agree on, or "?" if they do not.
  function automatic string both(input string a, input string b);
    if (a == b) both = a;
    else        both = "?";
  endfunction

  // Edge times, for the outcomes.
  realtime t_as_lo, t_as_hi;
  always @(negedge as_n_o) t_as_lo = $realtime;
  always @(posedge as_n_o) t_as_hi = $realtime;

  // How a probe's operand starts: a read or a write of four bytes, at addr --
  // or, in CPU space, the one byte of an interrupt acknowledge (UM 7.4.1).
  task automatic op(input bit rd, input logic [31:0] addr);
    if (rd && (req_fc == 3'b111)) op_read(addr, 1, got, cycles);
    else if (rd) op_read (addr, 4, got, cycles);
    else    op_write(addr, 4, 40'h00_0BADF00D, cycles);
  endtask

  // The bus is idle and every stimulus is withdrawn.
  task automatic settle();
    dk_drv = 2'b11; st_drv = 1'b1; pdoe = 1'b0; pd = DATA_A;
    cback_force = 1'b0; ciin_force = 1'b0;
    berr_drv = 1'b0; halt_drv = 1'b0; avec_drv = 1'b0;
    ipl_drv = 3'd0; cdis_drv = 1'b0; mmudis_drv = 1'b0;
    br_drv = 1'b0; bgack_drv = 1'b0; reset_in_drv = 1'b0;
    repeat (8) @(posedge clk);
  endtask

  // One run of a probe on a bus cycle. `which` is applied at the edge `k` half
  // clocks after the rising edge entering S0, plus `off`. `pre` is what the
  // testbench's own device does before that, and `meas` what is recorded.
  localparam int M_ASW   = 0;   // AS width
  localparam int M_FAULT = 1;   // the operand ended in a bus error
  localparam int M_END   = 2;   // how the cycle ended -- rd68031_pkg::cycle_end_e
  localparam int M_DATA  = 3;   // the read returned DATA_B
  localparam int M_CIIN  = 4;   // CIIN was taken with the operand
  localparam int M_CYC   = 5;   // bus cycles the operand took
  localparam int M_ECS2  = 6;   // the next cycle's ECS, from the edge

  localparam int PRE_NONE  = 0;
  localparam int PRE_DSACK = 1;  // DSACK asserted from the start of S2
  localparam int PRE_STERM = 2;  // STERM asserted from the start of S1
  localparam int PRE_BH    = 3;  // BERR and HALT asserted from the start of S2

  task automatic cyc_run(input bit rd, input logic [31:0] addr, input int pre,
                         input bit data, input int k, input real off,
                         input int which, input bit v, input int meas,
                         output real outc, output string kind);
    real t0, e, t_ecs2;
    fork
      op(rd, addr);
      begin
        @(negedge ecs_n_o);
        t0 = $realtime;
        e  = t0 + k * (CLK_PERIOD / 2.0);
        if (data) begin pd = DATA_A; pdoe = 1'b1; end
        if (pre == PRE_STERM) begin
          #(CLK_PERIOD / 2.0 + 1.0); st_drv = 1'b0;
        end else if (pre == PRE_DSACK) begin
          #(CLK_PERIOD + 1.0); dk_drv = 2'b00;
        end else if (pre == PRE_BH) begin
          #(CLK_PERIOD + 1.0); berr_drv = 1'b1; halt_drv = 1'b1;
        end
        place(e, off, which, v, kind);
        if (meas == M_ECS2) begin
          @(negedge ecs_n_o);
          t_ecs2 = $realtime;
        end
        // Withdraw on the negation of AS, as a device does -- for a burst, the
        // last one; or at once, if the stimulus came after it. A retry, a halt
        // and a late exception are withdrawn a little later, so that the core
        // is seen to wait for them.
        wait (as_n_o === 1'b1);
        #(1.0);
        if ((which == I_BH) || (which == I_HALT) || (pre == PRE_BH)) begin
          repeat (2) @(posedge clk);
          #(1.0);
        end
        dk_drv = 2'b11; st_drv = 1'b1; pdoe = 1'b0;
        cback_force = 1'b0; ciin_force = 1'b0; avec_drv = 1'b0;
        berr_drv = 1'b0; halt_drv = 1'b0;
      end
    join
    case (meas)
      M_ASW:   outc = t_as_hi - t_as_lo;
      M_FAULT: outc = req_fault ? 1.0 : 0.0;
      M_END:   outc = req_end;
      M_DATA:  outc = (got[31:0] === DATA_B) ? 1.0 : 0.0;
      M_CIIN:  outc = req_ciin ? 1.0 : 0.0;
      M_CYC:   outc = cycles;
      M_ECS2:  outc = t_ecs2 - e;
      default: outc = -1.0;
    endcase
    settle();
  endtask

  task automatic probe_cyc(input string name, input bit rd,
                           input logic [31:0] addr, input int pre, input bit data,
                           input int k, input int which, input int meas);
    real   ob, oa;
    string kb, ka;
    cyc_run(rd, addr, pre, data, k, -0.5, which, 1'b1, meas, ob, kb);
    cyc_run(rd, addr, pre, data, k,  0.5, which, 1'b1, meas, oa, ka);
    $fdisplay(log, "P %s %s %0.3f %0.3f %0.3f %0.3f", name,
              both(kb, ka), -0.5, 0.5, ob, oa);
  endtask

  // The negation of a retry's BERR and HALT: the cycle is retried from the
  // start of S2, and both are withdrawn around a falling edge three clocks
  // later, while the core waits to rerun it. The outcome is when the rerun's
  // ECS comes, measured from that edge.
  task automatic retry_run(input real off, output real outc, output string kind);
    real t0, e, t1;
    fork
      op(1'b0, 32'h0000_0400);
      begin
        @(negedge ecs_n_o);
        t0 = $realtime;
        e  = t0 + 4.5 * CLK_PERIOD;
        #(CLK_PERIOD + 1.0); berr_drv = 1'b1; halt_drv = 1'b1;
        place(e, off, I_BH, 1'b0, kind);
        @(negedge ecs_n_o);
        t1 = $realtime;
      end
    join
    outc = t1 - e;
    settle();
  endtask

  // An input with no bus cycle: watched through the bus unit's synchroniser,
  // whose output changes one or two clocks after the edge that sampled it.
  task automatic sync_run(input int which, input real off,
                          output real outc, output string kind);
    real e, tc;
    @(negedge clk);
    e = $realtime + CLK_PERIOD;
    fork
      place(e, off, which, 1'b1, kind);
      begin
        case (which)
          I_IPL:    @(ipl_sync_n);
          I_CDIS:   @(cdis_sync_n);
          I_MMUDIS: @(mmudis_sync_n);
          I_HALT:   @(halt_sync_n);
          I_BR:     @(dut.br_sync_n);
          I_BGACK:  @(dut.bgack_sync_n);
          I_RESET:  @(reset_sync_n);
          default:  ;
        endcase
        tc = $realtime;
      end
    join
    outc = tc - e;
    stim(which, 1'b0);
    settle();
  endtask

  task automatic probe_sync(input string name, input int which);
    real   ob, oa;
    string kb, ka;
    sync_run(which, -0.5, ob, kb);
    sync_run(which,  0.5, oa, ka);
    $fdisplay(log, "P %s %s %0.3f %0.3f %0.3f %0.3f", name,
              both(kb, ka), -0.5, 0.5, ob, oa);
  endtask

  // DSACK0 and DSACK1 asserted `skew` apart on a 32-bit port, the first half a
  // nanosecond before the falling edge entering S3: the long word must arrive
  // in one cycle, with the port size both of them give.
  task automatic skew_run(input logic [1:0] first, input real skew);
    real t0, e;
    bit  ok;
    fork
      op_read(NOBODY, 4, got, cycles);
      begin
        @(negedge ecs_n_o);
        t0 = $realtime;
        e  = t0 + 1.5 * CLK_PERIOD;
        pd = 32'h1122_3344; pdoe = 1'b1;
        #(e - 0.5 - $realtime);        dk_drv = first;
        #(e - 0.5 + skew - $realtime); dk_drv = 2'b00;
        @(posedge as_n_o);
        #(1.0);
        dk_drv = 2'b11;
        auto_dk = 1'b1;
      end
    join
    auto_dk = 1'b0;
    pdoe = 1'b0;
    ok = (cycles == 1) && (got[31:0] === 32'h1122_3344);
    if (first == 2'b10)
      $fdisplay(log, "Q dsack_skew_dsack0_first %0.3f %0d", skew, ok);
    else
      $fdisplay(log, "Q dsack_skew_dsack1_first %0.3f %0d", skew, ok);
    settle();
  endtask

  initial begin
    if (!$value$plusargs("log=%s", logname)) logname = "build/timing-events.log";
    log       = $fopen(logname, "w");
    recording = 1'b0;
    primed    = 1'b0;
    dk_drv    = 2'b11;
    auto_dk   = 1'b0;
    st_drv    = 1'b1;
    pd        = DATA_A;
    pdoe      = 1'b0;
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) begin
      s32.mem[t] = 8'h10 + t[7:0];
      s16.mem[t] = 8'h10 + t[7:0];
      s8.mem[t]  = 8'h10 + t[7:0];
      sw.mem[t]  = 8'h10 + t[7:0];
      ss.mem[t]  = 8'h10 + t[7:0];
      sn.mem[t]  = 8'h10 + t[7:0];
    end

    $fdisplay(log, "C %0.3f", CLK_PERIOD);
    $fdisplay(log, "H addr_hiz_between_cycles %0d", dut.ADDR_HIZ_BETWEEN_CYCLES);

    // -------------------------------------------------------------------
    // Asynchronous reads. The four-cycle operand on the 8-bit port is what
    // makes specifications 15, 15A and 10B measure their real minimum: back to
    // back within one operand is the tightest the asynchronous bus gets.
    // -------------------------------------------------------------------
    scenario("read");
    op_read(32'h2000_0100, 4, got, cycles);   // four cycles, back to back
    op_read(32'h0000_0100, 4, got, cycles);   // one cycle
    op_read(32'h0000_0104, 4, got, cycles);
    op_read(32'h1000_0102, 4, got, cycles);   // 16-bit port, two cycles
    op_read(32'h3000_0100, 4, got, cycles);   // three wait states
    quiesce();

    // -------------------------------------------------------------------
    // Asynchronous writes.
    // -------------------------------------------------------------------
    scenario("write");
    op_write(32'h2000_0200, 4, 40'h00_A1B2C3D4, cycles);
    op_write(32'h0000_0200, 4, 40'h00_DEADBEEF, cycles);
    op_write(32'h0000_0204, 2, 40'h00_0000_1234, cycles);
    op_write(32'h3000_0200, 4, 40'h00_CAFEF00D, cycles);
    quiesce();

    // -------------------------------------------------------------------
    // Read, write, read, write. R/W only transitions when a write follows a
    // read or the other way about (UM 7.1.1), so specifications 17, 21, 29A,
    // 30A and 46 have nothing to measure in a log that goes one way.
    // -------------------------------------------------------------------
    scenario("mixed");
    op_read (32'h0000_0300, 4, got, cycles);
    op_write(32'h0000_0300, 4, 40'h00_01020304, cycles);
    op_read (32'h0000_0300, 4, got, cycles);
    op_write(32'h0000_0308, 4, 40'h00_05060708, cycles);
    quiesce();

    // -------------------------------------------------------------------
    // Synchronous reads: two-clock cycles back to back (a misaligned long
    // word), a cycle with two wait states, a burst of four long words, and a
    // burst with a wait state before each later beat (UM 7.3.4, 7.3.7).
    // -------------------------------------------------------------------
    scenario("sread");
    op_read(32'h5000_0101, 4, got, cycles);   // two cycles, back to back
    op_read(32'h5000_0104, 4, got, cycles);
    sn.waits_rt = 2;
    op_read(32'h5000_0200, 4, got, cycles);
    sn.waits_rt = 0;
    req_burst = 1'b1;
    op_read(32'h4000_0104, 4, got, cycles);
    req_burst = 1'b0;
    repeat (8) @(posedge clk);
    ss.bwaits_rt = 1;
    req_burst = 1'b1;
    op_read(32'h4000_0208, 4, got, cycles);
    req_burst = 1'b0;
    repeat (12) @(posedge clk);
    ss.bwaits_rt = 0;
    quiesce();

    // -------------------------------------------------------------------
    // Two-clock synchronous writes, which assert no DS (UM 7.3.5; MC68030EC
    // footnote 11) -- a scenario of their own, so that the analysis can count
    // that there is none.
    // -------------------------------------------------------------------
    scenario("swrite");
    op_write(32'h5000_0300, 4, 40'h00_11223344, cycles);
    op_write(32'h5000_0305, 4, 40'h00_55667788, cycles);  // two, back to back
    quiesce();

    // -------------------------------------------------------------------
    // Synchronous writes with wait states, which do assert DS (UM 7.3.5 state
    // 2).
    // -------------------------------------------------------------------
    scenario("swwrite");
    sn.waits_rt = 1;
    op_write(32'h5000_0400, 4, 40'h00_99AABBCC, cycles);
    op_write(32'h5000_0405, 4, 40'h00_DDEEFF00, cycles);
    sn.waits_rt = 0;
    quiesce();

    // -------------------------------------------------------------------
    // Synchronous read, write, read, write: specifications 46A, and 17, 21,
    // 29A and 30A on two-clock cycles.
    // -------------------------------------------------------------------
    scenario("smixed");
    op_read (32'h5000_0500, 4, got, cycles);
    op_write(32'h5000_0500, 4, 40'h00_01020304, cycles);
    op_read (32'h5000_0500, 4, got, cycles);
    op_write(32'h5000_0508, 4, 40'h00_05060708, cycles);
    quiesce();

    // -------------------------------------------------------------------
    // Arbitration. Three handovers: one with a cycle under way when BR comes,
    // and two on an idle bus. BR and BGACK each arrive half a nanosecond after
    // a falling edge in one and half a nanosecond before one in another --
    // the two ends of the synchroniser's latency, which specifications 35 and
    // 37 bound. The alternate master negates BR one and a half clocks after
    // asserting BGACK, the most MC68030EC specification 37A allows it, and the
    // core must not grant the bus a second time for it.
    // -------------------------------------------------------------------
    scenario("arb");
    fork
      op_read(32'h3000_0300, 4, got, cycles);   // three wait states
      begin
        @(negedge as_n_o);
        @(negedge clk);
        #(0.5);
        br_drv = 1'b1; emit_in("in.br.assert");
      end
    join
    for (t = 0; t < 3; t = t + 1) begin
      if (t != 0) begin
        @(negedge clk);
        if (t == 1) #(CLK_PERIOD - 0.5);
        else        #(0.5);
        br_drv = 1'b1; emit_in("in.br.assert");
      end
      wait (bg_n_o === 1'b0);
      wait (as_n_o === 1'b1);
      repeat (2) @(posedge clk);
      @(negedge clk);
      if (t == 1) #(0.5);
      else        #(CLK_PERIOD - 0.5);
      bgack_drv = 1'b1; emit_in("in.bgack.assert");
      #(1.5 * CLK_PERIOD);
      br_drv = 1'b0; emit_in("in.br.negate");
      repeat (6) @(posedge clk);
      @(negedge clk);
      if (t == 1) #(CLK_PERIOD - 0.5);
      else        #(0.5);
      bgack_drv = 1'b0; emit_in("in.bgack.negate");
      repeat (8) @(posedge clk);
    end
    quiesce();

    // -------------------------------------------------------------------
    // STATUS and REFILL: an instruction boundary, a boundary with an
    // exception pending, the start of exception processing, and a refill
    // (UM 12.7.1).
    // -------------------------------------------------------------------
    scenario("status");
    @(posedge clk); sts_bound_drv = 1'b1;  @(posedge clk); sts_bound_drv = 1'b0;
    repeat (4) @(posedge clk);
    sts_pend_drv = 1'b1;  @(posedge clk); sts_pend_drv = 1'b0;
    repeat (5) @(posedge clk);
    sts_exc_drv = 1'b1;   @(posedge clk); sts_exc_drv = 1'b0;
    repeat (6) @(posedge clk);
    sts_refill_drv = 1'b1; @(posedge clk); sts_refill_drv = 1'b0;
    repeat (4) @(posedge clk);
    quiesce();

    // -------------------------------------------------------------------
    // The RESET instruction's pulse (UM 7.8).
    // -------------------------------------------------------------------
    scenario("reset");
    @(posedge clk); reset_req_drv = 1'b1;
    @(negedge reset_busy);
    @(posedge clk); reset_req_drv = 1'b0;
    quiesce();

    // -------------------------------------------------------------------
    // The probes: where each input is sampled. Not recorded as transitions.
    // -------------------------------------------------------------------
    $fdisplay(log, "S probe");
    settle();

    // Asynchronous termination, at the falling edge entering S3 (k = 3).
    probe_cyc("dsack",    1'b0, NOBODY, PRE_NONE,  1'b0, 3, I_DSACK, M_ASW);
    probe_cyc("berr",     1'b0, NOBODY, PRE_NONE,  1'b0, 3, I_BERR,  M_ASW);
    req_fc = 3'b111; req_cpuspace = rd68031_pkg::CPUS_IACK; req_cpuaddr = 8'd3;
    probe_cyc("avec",     1'b1, NOBODY, PRE_NONE,  1'b0, 3, I_AVEC,  M_ASW);
    req_fc = 3'b101; req_cpuspace = 4'd0; req_cpuaddr = 8'd0;
    // HALT with DSACK: Table 7-8 case 2, decided at the same sample.
    probe_cyc("halt",     1'b0, 32'h0000_0400, PRE_NONE, 1'b0, 3, I_HALT, M_END);
    // The late window: BERR, and BERR with HALT, one clock after DSACK (k = 5),
    // and with STERM, the falling edge after it (k = 3).
    probe_cyc("berr_late_async",  1'b0, 32'h0000_0400, PRE_NONE, 1'b0, 5, I_BERR, M_FAULT);
    probe_cyc("retry_late_async", 1'b0, 32'h0000_0400, PRE_NONE, 1'b0, 5, I_BH,   M_CYC);
    probe_cyc("berr_late_sync",   1'b0, 32'h5000_0400, PRE_NONE, 1'b0, 3, I_BERR, M_FAULT);
    // Read data: latched at the end of S4 (k = 5), or the falling edge after
    // STERM (k = 3).
    probe_cyc("data_async", 1'b1, NOBODY, PRE_DSACK, 1'b1, 5, I_DATA, M_DATA);
    probe_cyc("data_sync",  1'b1, NOBODY, PRE_STERM, 1'b1, 3, I_DATA, M_DATA);
    // The synchronous inputs, at the rising edge entering S2 (k = 2) -- and
    // CIIN of a DSACK cycle at the one entering S4 (k = 4).
    probe_cyc("sterm",      1'b0, NOBODY, PRE_NONE,  1'b0, 2, I_STERM, M_ASW);
    req_burst = 1'b1;
    probe_cyc("cback",      1'b1, NOBODY, PRE_STERM, 1'b1, 2, I_CBACK, M_ASW);
    req_burst = 1'b0;
    probe_cyc("ciin_sync",  1'b1, NOBODY, PRE_STERM, 1'b1, 2, I_CIIN,  M_CIIN);
    probe_cyc("ciin_async", 1'b1, NOBODY, PRE_DSACK, 1'b1, 4, I_CIIN,  M_CIIN);

    begin
      real   ob, oa;
      string kb, ka;
      retry_run(-0.5, ob, kb);
      retry_run( 0.5, oa, ka);
      $fdisplay(log, "P retry_negate %s %0.3f %0.3f %0.3f %0.3f",
                both(kb, ka), -0.5, 0.5, ob, oa);
    end

    probe_sync("ipl",       I_IPL);
    probe_sync("cdis",      I_CDIS);
    probe_sync("mmudis",    I_MMUDIS);
    probe_sync("halt_sync", I_HALT);
    probe_sync("br",        I_BR);
    probe_sync("bgack",     I_BGACK);
    probe_sync("reset_in",  I_RESET);

    // DSACK skew: the second as late as the falling edge after the first
    // allows -- a clock less a nanosecond.
    skew_run(2'b10, CLK_PERIOD - 1.0);
    skew_run(2'b01, CLK_PERIOD - 1.0);

    $fclose(log);
    $display("PASS: rd68031_timing_tb (event log written)");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: rd68031_timing_tb timed out");
    $finish;
  end

endmodule
