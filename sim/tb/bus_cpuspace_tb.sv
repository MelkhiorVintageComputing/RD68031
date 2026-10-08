// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- CPU space cycles: UM 7.4 and figure 7-42.
//
// FC2-FC0 = 111 is CPU space, and A19-A16 say which kind of cycle it is. The
// MC68030 implements three (figure 7-42), and each is checked here on an
// asynchronous port of each width and on a synchronous one:
//
//   interrupt acknowledge  type $F; A31-A4 and A0 ones, the level on A3-A1, a
//                          byte (7.4.1.1). "Terminated normally with either
//                          STERM or DSACKx"; by AVEC for an autovector
//                          (7.4.1.2); by BERR for a spurious interrupt, and by
//                          BERR and HALT for a retry (7.4.1.3).
//   breakpoint acknowledge type $0; the breakpoint number on A4-A2, every other
//                          line zero, a word -- "if the first bus cycle
//                          accesses an 8-bit port, a second cycle is required";
//                          DSACKx or STERM, or BERR for "no instruction word
//                          available" (7.4.2).
//   coprocessor            type $2; the CpID on A15-A13 and the interface
//                          register on A4-A0, every other line zero (7.4.3).
//
// A bus error on a CPU-space cycle is the microcode's to interpret -- a
// spurious interrupt, an illegal instruction, an F-line with no coprocessor --
// so the bus unit reports it as an end code and raises no fault, except on a
// coprocessor access the requester marks as one that must fault. The devices
// are rd68031_slave instances with CPUSPACE set, on the harness's spare
// termination inputs.

`timescale 1ns / 1ps

module bus_cpuspace_tb;

`include "rd68031_bus_harness.svh"

  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  string       what;

  // -------------------------------------------------------------------------
  // The devices. BASE and MASK select on the synthesised address.
  // -------------------------------------------------------------------------
  localparam logic [31:0] IACK_MASK = 32'h000F_000E;   // type and level
  localparam logic [31:0] BKPT_MASK = 32'h000F_001C;   // type and number
  localparam logic [31:0] CP_MASK   = 32'h000F_E000;   // type and CpID

  logic [1:0] dk_i1, dk_i2, dk_i3, dk_i7, dk_b0, dk_b1, dk_c1;
  logic       st_i4, st_b2, st_c2;
  wire [31:0] d_i1, d_i2, d_i3, d_i4, d_i7, d_b0, d_b1, d_b2, d_c1, d_c2;
  logic       o_i1, o_i2, o_i3, o_i4, o_i7, o_b0, o_b1, o_b2, o_c1, o_c2;

  assign dsack_ext_n = dk_i1 & dk_i2 & dk_i3 & dk_i7 & dk_b0 & dk_b1 & dk_c1;
  assign sterm_ext_n = st_i4 & st_b2 & st_c2;
  assign dbus = o_i1 ? d_i1 : 32'bz;
  assign dbus = o_i2 ? d_i2 : 32'bz;
  assign dbus = o_i3 ? d_i3 : 32'bz;
  assign dbus = o_i4 ? d_i4 : 32'bz;
  assign dbus = o_i7 ? d_i7 : 32'bz;
  assign dbus = o_b0 ? d_b0 : 32'bz;
  assign dbus = o_b1 ? d_b1 : 32'bz;
  assign dbus = o_b2 ? d_b2 : 32'bz;
  assign dbus = o_c1 ? d_c1 : 32'bz;
  assign dbus = o_c2 ? d_c2 : 32'bz;

`define CPDEV(name, pb, wt, sy, base, mask, dk, st, dd, oo) \
  rd68031_slave #(.PORT_BYTES (pb), .WAITS (wt), .SYNC (sy), .CPUSPACE (1'b1), \
                  .BASE (base), .MASK (mask)) name ( \
      .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o), \
      .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .cbreq_n_i (cbreq_n_o), \
      .d_i (dbus), .wr_inhibit_i (1'b0), \
      .d_o (dd), .d_oe (oo), .dsack_n_o (dk), .sterm_n_o (st), \
      .cback_n_o (), .ciin_n_o ());

  logic [1:0] dk_unused_i4, dk_unused_b2, dk_unused_c2;
  logic       st_unused_i1, st_unused_i2, st_unused_i3, st_unused_i7;
  logic       st_unused_b0, st_unused_b1, st_unused_c1;

  // Interrupt acknowledge: levels 1, 2, 3 on 32-, 16- and 8-bit ports, 4 on a
  // STERM port, 7 on a 32-bit port with two wait states. Nothing answers 5 or 6.
  `CPDEV(i1, 4, 0, 1'b0, 32'h000F_0002, IACK_MASK, dk_i1, st_unused_i1, d_i1, o_i1)
  `CPDEV(i2, 2, 0, 1'b0, 32'h000F_0004, IACK_MASK, dk_i2, st_unused_i2, d_i2, o_i2)
  `CPDEV(i3, 1, 0, 1'b0, 32'h000F_0006, IACK_MASK, dk_i3, st_unused_i3, d_i3, o_i3)
  `CPDEV(i4, 4, 0, 1'b1, 32'h000F_0008, IACK_MASK, dk_unused_i4, st_i4, d_i4, o_i4)
  `CPDEV(i7, 4, 2, 1'b0, 32'h000F_000E, IACK_MASK, dk_i7, st_unused_i7, d_i7, o_i7)
  // Breakpoint acknowledge: #0 on a 32-bit port, #1 on an 8-bit one, #2 on a
  // STERM port. Nothing answers #3.
  `CPDEV(b0, 4, 0, 1'b0, 32'h0000_0000, BKPT_MASK, dk_b0, st_unused_b0, d_b0, o_b0)
  `CPDEV(b1, 1, 0, 1'b0, 32'h0000_0004, BKPT_MASK, dk_b1, st_unused_b1, d_b1, o_b1)
  `CPDEV(b2, 4, 0, 1'b1, 32'h0000_0008, BKPT_MASK, dk_unused_b2, st_b2, d_b2, o_b2)
  // Coprocessors: CpID 1 asynchronous, 2 synchronous. Nobody is CpID 3.
  `CPDEV(c1, 4, 0, 1'b0, 32'h0002_2000, CP_MASK, dk_c1, st_unused_c1, d_c1, o_c1)
  `CPDEV(c2, 4, 0, 1'b1, 32'h0002_4000, CP_MASK, dk_unused_c2, st_c2, d_c2, o_c2)

  // -------------------------------------------------------------------------
  // Every bus cycle, as AS asserts, and how long AS stayed asserted.
  // -------------------------------------------------------------------------
  localparam int MAXC = 256;
  int unsigned ncyc;
  logic [31:0] rc_a     [0:MAXC-1];
  logic  [2:0] rc_fc    [0:MAXC-1];
  logic  [1:0] rc_siz   [0:MAXC-1];
  logic        rc_rw    [0:MAXC-1];
  logic        rc_cbreq [0:MAXC-1];
  logic        rc_ocs   [0:MAXC-1];
  realtime     rc_w     [0:MAXC-1];
  realtime     t_as;
  logic        last_ocs;
  initial begin ncyc = 0; last_ocs = 1'b0; end

  always @(negedge ecs_n_o) begin #(SNAP); last_ocs = !ocs_n_o; end
  always @(negedge as_n_o) begin
    int unsigned ix;
    if (rst_n) begin
      ix   = ncyc;
      ncyc = ncyc + 1;
      t_as = $realtime;
      #(SNAP);
      if (ix < MAXC) begin
        rc_a[ix]     = a_o;
        rc_fc[ix]    = fc_o;
        rc_siz[ix]   = siz_o;
        rc_rw[ix]    = rw_o;
        rc_cbreq[ix] = !cbreq_n_o;
        rc_ocs[ix]   = last_ocs;
      end
    end
  end
  always @(posedge as_n_o) if (rst_n && ncyc > 0 && ncyc <= MAXC)
    rc_w[ncyc - 1] = $realtime - t_as;

  // -------------------------------------------------------------------------
  // One CPU-space operand, with what the bus unit says at its acknowledge.
  // -------------------------------------------------------------------------
  logic [39:0] o_rd;
  bit          o_f;
  logic  [2:0] o_end, o_ffc;
  int unsigned o_base, o_n;

  task automatic cpu_op(input logic [3:0] typ, input logic [7:0] field,
                        input int unsigned nbytes, input bit wr,
                        input logic [39:0] wd);
    @(negedge clk);
    o_base       = ncyc;
    req_fc       = 3'b111;
    req_cpuspace = typ;
    req_cpuaddr  = field;
    req_kind     = wr ? 3'd1 : 3'd0;
    req_addr     = 32'hDEAD_BEEF;     // ignored in CPU space
    req_bytes    = nbytes[2:0];
    req_wdata    = wd;
    req_burst    = 1'b1;              // never honoured in CPU space (UM 6.1.3.2)
    pending      = 1'b1;
    @(posedge req_ack);
    #1;
    pending   = 1'b0;
    o_rd      = req_rdata;
    o_f       = req_fault;
    o_end     = req_end;
    o_ffc     = flt_fc;
    o_n       = ncyc - o_base;
    req_fc    = 3'b101;
    req_burst = 1'b0;
    @(negedge clk);
  endtask

  // BERR (and HALT) for the cycle about to run, at S2 + d, held until AS
  // negates; HALT held a few clocks longer for a retry.
  task automatic exc_on_next(input bit halt, input int unsigned d);
    int unsigned c0;
    c0 = ncyc;
    wait (ncyc > c0);
    @(posedge clk);
    repeat (d) @(posedge clk);
    berr_drv = 1'b1;
    halt_drv = halt;
    @(posedge as_n_o);
    @(posedge clk);
    berr_drv = 1'b0;
    repeat (3) @(posedge clk);
    halt_drv = 1'b0;
  endtask

  int unsigned lv;
  logic  [7:0] vec;

  initial begin
    $display("bus_cpuspace_tb: UM 7.4, CPU space cycles");
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) begin
      i1.mem[t] = 8'h40 + t[7:0];  i2.mem[t] = 8'h50 + t[7:0];
      i3.mem[t] = 8'h60 + t[7:0];  i4.mem[t] = 8'h70 + t[7:0];
      i7.mem[t] = 8'h80 + t[7:0];  b0.mem[t] = 8'h90 + t[7:0];
      b1.mem[t] = 8'hA0 + t[7:0];  b2.mem[t] = 8'hB0 + t[7:0];
      c1.mem[t] = 8'hC0 + t[7:0];  c2.mem[t] = 8'hD0 + t[7:0];
    end

    // =====================================================================
    // Interrupt acknowledge, vectored -- 7.4.1.1 and figure 7-44. The vector
    // is "on the least significant byte of the data port (depends on port
    // size)": D7-D0 of a 32-bit port, D23-D16 of a 16-bit one, D31-D24 of an
    // 8-bit one -- which is where Table 7-4 puts a byte at A1-A0 = 11.
    // =====================================================================
    for (lv = 1; lv <= 7; lv = lv + 1) if (lv != 5 && lv != 6) begin
      // The device's vector, at the byte the synthesised address selects.
      vec = 8'h40 + lv[7:0] * 8'h11;
      case (lv)
        1: i1.mem[12'hFF0 | (lv * 2 + 1)] = vec;
        2: i2.mem[12'hFF0 | (lv * 2 + 1)] = vec;
        3: i3.mem[12'hFF0 | (lv * 2 + 1)] = vec;
        4: i4.mem[12'hFF0 | (lv * 2 + 1)] = vec;
        default: i7.mem[12'hFF0 | (lv * 2 + 1)] = vec;
      endcase
      cpu_op(4'hF, lv[7:0], 1, 1'b0, 40'd0);
      $sformat(what, "IACK level %0d: one bus cycle", lv);
      check(o_n == 1, what);
      $sformat(what, "IACK level %0d: FC 111, A31-A4 and A0 ones, the level on A3-A1 (got %08h)",
               lv, rc_a[o_base]);
      check(rc_fc[o_base] === 3'b111
            && rc_a[o_base] === {28'hFFF_FFFF, lv[2:0], 1'b1}, what);
      $sformat(what, "IACK level %0d: a byte read, no CBREQ", lv);
      check(rc_siz[o_base] === 2'b01 && rc_rw[o_base] === 1'b1
            && rc_cbreq[o_base] === 1'b0, what);
      $sformat(what, "IACK level %0d: the vector (want %02h, got %02h)", lv, vec, o_rd[7:0]);
      check(o_rd[7:0] === vec, what);
      $sformat(what, "IACK level %0d: ends %s, no fault", lv, (lv == 4) ? "CE_STERM" : "CE_DSACK");
      check(o_end == ((lv == 4) ? 3'd6 : 3'd1) && !o_f, what);
      if (lv == 4) begin
        // UM 7.4.1.1: "terminated normally with either STERM or DSACKx" --
        // a synchronous interrupt acknowledge is a two-clock cycle.
        $sformat(what, "IACK level 4 by STERM: AS asserted one clock (got %0.1f)",
                 rc_w[o_base] / CLK_PERIOD);
        check(rc_w[o_base] == CLK_PERIOD, what);
      end
    end

    // =====================================================================
    // Autovector -- 7.4.1.2 and figure 7-45: "the device asserts the
    // autovector signal (AVEC) to terminate the cycle", sampled as DSACK is.
    // =====================================================================
    fork
      begin
        wait (ncyc > 0 && !as_n_o);
        @(posedge clk);
        avec_drv = 1'b1;
        @(posedge as_n_o);
        @(posedge clk);
        avec_drv = 1'b0;
      end
      cpu_op(4'hF, 8'd5, 1, 1'b0, 40'd0);
    join
    check(o_n == 1 && o_end == 3'd4 && !o_f, "IACK level 5 by AVEC: one cycle, CE_AVEC, no fault");
    check(rc_a[o_base] === 32'hFFFF_FFFB, "IACK level 5: the address");
    check(rc_w[o_base] == 2.0 * CLK_PERIOD,
          "IACK by AVEC: a three-clock cycle, AVEC sampled where DSACK is (figure 7-45)");

    // ... and AVEC held asserted through a breakpoint acknowledge and a
    // coprocessor access is ignored: "AVEC is ignored during all other bus
    // cycles" (7.1.7).
    avec_drv = 1'b1;
    cpu_op(4'h0, 8'd0, 2, 1'b0, 40'd0);
    check(o_end == 3'd1 && o_rd[15:0] === 16'h9091,
          "AVEC during a breakpoint acknowledge: ignored, DSACK ends it");
    cpu_op(4'h2, {3'd1, 5'h00}, 2, 1'b0, 40'd0);
    check(o_end == 3'd1 && o_rd[15:0] === 16'hC0C1,
          "AVEC during a coprocessor access: ignored, DSACK ends it");
    avec_drv = 1'b0;

    // =====================================================================
    // Spurious interrupt -- 7.4.1.3: "when a device does not respond ... the
    // external logic typically returns BERR. The MC68030 automatically
    // generates the spurious interrupt vector number ... If HALT is also
    // asserted, the processor retries the cycle."
    // =====================================================================
    fork
      exc_on_next(1'b0, 0);
      cpu_op(4'hF, 8'd6, 1, 1'b0, 40'd0);
    join
    check(o_n == 1 && o_end == 3'd2, "IACK level 6, BERR: one cycle, CE_BERR");
    check(!o_f, "IACK level 6, BERR: no bus error exception -- it is the spurious interrupt");
    fork
      begin
        exc_on_next(1'b1, 0);
        exc_on_next(1'b0, 0);
      end
      cpu_op(4'hF, 8'd6, 1, 1'b0, 40'd0);
    join
    check(o_n == 2 && o_end == 3'd2 && !o_f,
          "IACK level 6, BERR and HALT then BERR: retried, then spurious");
    check(rc_a[o_base + 1] === rc_a[o_base] && rc_fc[o_base + 1] === 3'b111,
          "IACK retry: the same CPU-space address again");
    // A late bus error on a synchronous acknowledge, with STERM (Table 7-9
    // case 4), is the same.
    fork
      exc_on_next(1'b0, 0);
      cpu_op(4'hF, 8'd4, 1, 1'b0, 40'd0);
    join
    check(o_n == 1 && o_end == 3'd2 && !o_f,
          "IACK level 4, BERR with STERM: CE_BERR, the spurious interrupt");

    // =====================================================================
    // Breakpoint acknowledge -- 7.4.2 and figures 7-46 to 7-48.
    // =====================================================================
    cpu_op(4'h0, 8'd0, 2, 1'b0, 40'd0);
    check(o_n == 1 && rc_a[o_base] === 32'h0000_0000 && rc_fc[o_base] === 3'b111
          && rc_siz[o_base] === 2'b10 && rc_rw[o_base] === 1'b1,
          "BKPT #0: CPU space type 0, number 0, a word read");
    check(o_rd[15:0] === 16'h9091 && o_end == 3'd1, "BKPT #0: the instruction word, by DSACK");

    cpu_op(4'h0, 8'd1, 2, 1'b0, 40'd0);
    check(rc_a[o_base] === 32'h0000_0004, "BKPT #1: the number on A4-A2");
    check(o_n == 2, "BKPT #1 from an 8-bit port: \"a second cycle is required\"");
    check(rc_a[o_base + 1] === 32'h0000_0005 && rc_siz[o_base + 1] === 2'b01,
          "BKPT #1: the second cycle for the low byte");
    check(rc_ocs[o_base] === 1'b1 && rc_ocs[o_base + 1] === 1'b0,
          "BKPT #1: OCS on the first cycle only (7.1.1)");
    check(o_rd[15:0] === 16'hA4A5, "BKPT #1: the word assembled from two bytes");

    cpu_op(4'h0, 8'd2, 2, 1'b0, 40'd0);
    check(rc_a[o_base] === 32'h0000_0008 && o_end == 3'd6 && o_rd[15:0] === 16'hB8B9,
          "BKPT #2: by STERM -- \"if the external hardware terminates the cycle with DSACKx or STERM\"");

    fork
      exc_on_next(1'b0, 0);
      cpu_op(4'h0, 8'd3, 2, 1'b0, 40'd0);
    join
    check(rc_a[o_base] === 32'h0000_000C && o_n == 1 && o_end == 3'd2 && !o_f,
          "BKPT #3, BERR: CE_BERR and no bus error -- the illegal instruction is the microcode's");
    // The full field: #7 on A4-A2, nothing else.
    fork
      exc_on_next(1'b0, 0);
      cpu_op(4'h0, 8'd7, 2, 1'b0, 40'd0);
    join
    check(rc_a[o_base] === 32'h0000_001C, "BKPT #7: 111 on A4-A2, every other line zero");

    // =====================================================================
    // Coprocessor communication -- 7.4.3 and figure 7-42.
    // =====================================================================
    cpu_op(4'h2, {3'd1, 5'h00}, 2, 1'b0, 40'd0);
    check(rc_a[o_base] === 32'h0002_2000 && rc_fc[o_base] === 3'b111
          && rc_siz[o_base] === 2'b10 && rc_rw[o_base] === 1'b1,
          "CpID 1, response CIR: type 2, CpID on A15-A13, register on A4-A0, a word read");
    check(o_rd[15:0] === 16'hC0C1 && o_end == 3'd1, "CpID 1: the response, by DSACK");
    cpu_op(4'h2, {3'd1, 5'h0A}, 2, 1'b1, 40'h00_0000_5A3C);
    check(rc_a[o_base] === 32'h0002_200A && rc_rw[o_base] === 1'b0 && !o_f,
          "CpID 1, command CIR: a word written at register $0A");
    check(c1.mem[12'h00A] === 8'h5A && c1.mem[12'h00B] === 8'h3C,
          "CpID 1, command CIR: the coprocessor took the word");
    cpu_op(4'h2, {3'd1, 5'h10}, 4, 1'b0, 40'd0);
    check(rc_a[o_base] === 32'h0002_2010 && rc_siz[o_base] === 2'b00
          && o_rd[31:0] === 32'hD0D1D2D3, "CpID 1, operand CIR: a long word read at register $10");
    cpu_op(4'h2, {3'd2, 5'h00}, 2, 1'b0, 40'd0);
    check(rc_a[o_base] === 32'h0002_4000 && o_end == 3'd6 && o_rd[15:0] === 16'hD0D1,
          "CpID 2: a coprocessor on a STERM port");
    cpu_op(4'h2, {3'd2, 5'h14}, 4, 1'b1, 40'h00_1234_5678);
    check(c2.mem[12'h014] === 8'h12 && c2.mem[12'h017] === 8'h78 && !o_f,
          "CpID 2: a synchronous write to the operand CIR");

    // Nobody answers CpID 3. A bus error there is the F-line exception's
    // business when the access starts an instruction, and a bus error
    // exception otherwise: the requester says which (UM 10.5.2.8).
    fork
      exc_on_next(1'b0, 0);
      cpu_op(4'h2, {3'd3, 5'h00}, 2, 1'b0, 40'd0);
    join
    check(rc_a[o_base] === 32'h0002_6000 && o_end == 3'd2 && !o_f,
          "CpID 3, BERR on the access that starts an instruction: CE_BERR, no fault");
    req_cpfault = 1'b1;
    fork
      exc_on_next(1'b0, 0);
      cpu_op(4'h2, {3'd3, 5'h10}, 4, 1'b0, 40'd0);
    join
    req_cpfault = 1'b0;
    check(o_f && o_end == 3'd2 && o_ffc === 3'b111,
          "CpID 3, BERR on a later access: a bus error, in CPU space");
    // ... and a retry on a coprocessor access reruns it.
    fork
      exc_on_next(1'b1, 0);
      cpu_op(4'h2, {3'd1, 5'h00}, 2, 1'b0, 40'd0);
    join
    check(o_n == 2 && rc_a[o_base + 1] === 32'h0002_2000 && o_rd[15:0] === 16'hC0C1,
          "CpID 1, BERR and HALT: the access is retried");

    $display("bus_cpuspace_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_cpuspace_tb");
    else                                     $display("FAIL: bus_cpuspace_tb");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: bus_cpuspace_tb timed out");
    $finish;
  end

endmodule
