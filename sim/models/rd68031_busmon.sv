// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- a pin-level transfer monitor, for comparing two processors on the
// same slave models (make ap030, tools/bus_diff.py pins).
//
// It watches only pins -- nothing inside either processor -- so the same
// module sits in sim/tb/core_pins_tb.sv beside this core and in
// sim/ap030/ap030_tb.sv beside AP68030, and the two files it writes mean the
// same thing.
//
// One line per transfer, one per beat of a burst, to the file given by
// +pins=<file>:
//
//   T <R|W> a=<A31-A0> fc=<n> siz=<SIZ1:SIZ0> term=<STERM|DSACK32|DSACK16|
//     DSACK8|BERR|RETRY|AVEC> d=<D31-D0> rmc=<0|1> cbreq=<0|1> cback=<0|1>
//     ciin=<0|1> ciout=<0|1> beat=<n> clk=<rising edges since reset>
//
// every flag 1 for asserted. A transfer is recorded when it ends, as the
// processor sees it end:
//   - asynchronous: at the first falling edge with DSACKx, BERR or AVEC
//     asserted -- the processor latches read data on a falling edge, at the end
//     of S4 (UM 7.3.1), and the slave models drive it from the rising edge
//     they acknowledge on;
//   - synchronous: at the falling edge after each rising edge that sampled
//     STERM (UM 7.3.4: STERM is sampled on a rising edge, the data latched on
//     the next falling one), with CBACK as it was on that rising edge.
// `d` is the bus as the processor reads it, or as it drives it for a write:
// all four lanes; the comparison picks the lanes the port used.
//
// Testbenches are not bound by the rtl/ rules.

`timescale 1ns / 1ps

module rd68031_busmon (
    input logic        clk,
    input logic        rst_n,
    input logic        as_n,       // qualified: high when the processor is not driving
    input logic        rw,
    input logic [31:0] a,
    input logic  [2:0] fc,
    input logic  [1:0] siz,
    input logic [31:0] d,
    input logic  [1:0] dsack_n,
    input logic        sterm_n,
    input logic        berr_n,
    input logic        halt_n,
    input logic        avec_n,
    input logic        ciin_n,
    input logic        cbreq_n,
    input logic        cback_n,
    input logic        ciout_n,
    input logic        rmc_n
);

  integer fd;
  string  fn;
  int     clocks;
  bit     async_done, sterm_pend, cback_q;
  int     beat;

  initial begin
    fd = 0;
    clocks = 0;
    async_done = 1'b0;
    sterm_pend = 1'b0;
    cback_q = 1'b0;
    beat = 0;
    if ($value$plusargs("pins=%s", fn)) fd = $fopen(fn, "w");
  end

  function automatic string tname(input logic s, input logic [1:0] ds, input logic b,
                                  input logic h, input logic av);
    if (!b && !h)       tname = "RETRY";
    else if (!b)        tname = "BERR";
    else if (!av)       tname = "AVEC";
    else if (!s)        tname = "STERM";
    else if (ds == 2'b00) tname = "DSACK32";
    else if (ds == 2'b01) tname = "DSACK16";
    else if (ds == 2'b10) tname = "DSACK8";
    else                tname = "?";
  endfunction

  task automatic emit(input logic s_n, input logic cb);
    $fdisplay(fd, "T %s a=%08h fc=%0d siz=%0d term=%s d=%08h rmc=%0d cbreq=%0d cback=%0d ciin=%0d ciout=%0d beat=%0d clk=%0d",
              rw ? "R" : "W", a, fc, siz, tname(s_n, dsack_n, berr_n, halt_n, avec_n),
              d, !rmc_n, !cbreq_n, cb, !ciin_n, !ciout_n, beat, clocks);
  endtask

  always @(posedge clk) begin
    if (!rst_n) clocks = 0;
    else        clocks = clocks + 1;
    if (fd != 0 && rst_n && !as_n && !sterm_n && berr_n) begin
      sterm_pend = 1'b1;
      cback_q    = !cback_n;
    end
  end

  always @(negedge as_n) begin
    async_done = 1'b0;
    sterm_pend = 1'b0;
    beat       = 0;
  end

  always @(negedge clk) if (fd != 0 && rst_n && !as_n) begin
    if (sterm_pend) begin
      emit(1'b0, cback_q);
      beat = beat + 1;
      sterm_pend = 1'b0;
    end else if (!async_done && (!berr_n || !avec_n || dsack_n != 2'b11)) begin
      emit(1'b1, 1'b0);
      async_done = 1'b1;
    end
  end

  final if (fd != 0) $fclose(fd);

endmodule
