// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- a bus slave with a selectable port width, and a synchronous mode.
//
// Written from UM 7.2.1 and Tables 7-1, 7-4, 7-5 and 7-7, deliberately without
// reference to how rd68031_biu splits an operand: the point of the model is to
// answer the way a device answers, so that the two derivations of the byte-lane
// rules have to agree.
//
//   "Dynamic bus sizing requires that the portion of the data bus used for a
//    transfer to or from a particular port size be fixed. A 32-bit port must
//    reside on data bus bits 0-31, a 16-bit port must reside on data bus bits
//    16-31, and an 8-bit port must reside on data bus bits 24-31."  -- UM 7.2.1
//
// So a device of PORT_BYTES width, addressed at a byte that lands OFF bytes into
// one of its own words, can move at most PORT_BYTES-OFF bytes in one cycle, and it
// puts the byte at address+j on lane OFF+j -- where lane 0 is D31-D24.
//
// TWO WAYS TO END A CYCLE. An asynchronous device (SYNC = 0) asserts DSACK on a
// RISING clock edge, never combinationally from AS: the processor samples it at
// the end of S2, which is a falling edge, and a model that answered
// combinationally would be testing a sample the manual does not describe. A
// synchronous device (SYNC = 1, a 32-bit port only -- UM 7.1.7) asserts STERM
// instead, decoded from the address as UM 7.2.10 allows ("STERM ... does not need
// to be qualified with the AS signal"), so that it is set up for the rising edge
// that starts S2; each wait state holds it off one more rising edge.
//
// A synchronous device may also burst (BURST = 1): when the processor asserts
// CBREQ it answers CBACK with STERM while it can supply another long word, and
// supplies the long words of the line in turn, incrementing A3/A2 itself and
// wrapping within the line -- UM 7.3.7, "if an external memory system requires
// incrementing of the long-word base address to supply successive long words of
// information, this function must be performed by external hardware". A
// cachable read is answered with the whole long word on all four lanes (UM 7.2.7,
// "the slave device ignores A0 and A1 and supplies the long word beginning at the
// long-word boundary").
//
// CIIN can be asserted for the region, or for chosen beats of a burst.
//
// The behaviour knobs are variables, initialised from the parameters, so that a
// testbench can change them between operands without another instance.
//
// Testbenches are not bound by the rtl/ rules; this file uses initial blocks
// and $display freely.

`timescale 1ns / 1ps

module rd68031_slave #(
    parameter int PORT_BYTES  = 4,      // 1, 2 or 4
    parameter int WAITS       = 0,      // wait states to insert (the first beat)
    parameter bit SYNC        = 1'b0,   // terminate with STERM rather than DSACK
    parameter bit BURST       = 1'b0,   // answer CBREQ with CBACK
    parameter int BURST_WAITS = 0,      // wait states before each later beat
    parameter bit CIIN        = 1'b0,   // assert CIIN on every read
    parameter logic [31:0] BASE = 32'h0000_0000,
    parameter logic [31:0] MASK = 32'hFF00_0000,  // address & MASK == BASE selects
    parameter int ABITS       = 12                // bytes of store, as a power of two
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] a_i,
    input  logic  [1:0] siz_i,
    input  logic  [2:0] fc_i,
    input  logic        as_n_i,
    input  logic        ds_n_i,
    input  logic        rw_i,
    input  logic        cbreq_n_i,
    input  logic [31:0] d_i,            // from the processor, on a write
    // A write the system is refusing: the MMU in front of this memory has
    // answered the cycle with a bus error, so the memory must not change. The
    // model acknowledges regardless, as a device behind an MMU would; only
    // the store is inhibited.
    input  logic        wr_inhibit_i,
    output logic [31:0] d_o,
    output logic        d_oe,
    output logic  [1:0] dsack_n_o,
    output logic        sterm_n_o,
    output logic        cback_n_o,
    output logic        ciin_n_o
);

  // Byte-addressable store. A plain unpacked array rather than an associative one,
  // so that a testbench can reach into it hierarchically under every simulator.
  localparam int NBYTES = (1 << ABITS);
  logic [7:0] mem [0:NBYTES-1];

  // The knobs.
  int unsigned waits_rt;        // wait states before the first STERM or DSACK
  int unsigned bwaits_rt;       // ... and before each later burst beat
  int unsigned burst_limit;     // long words it will supply in one burst, 1..4
  bit          ciin_all;        // CIIN on every read
  logic  [3:0] ciin_beats;      // ... or on these beats of a burst (bit n = beat n)
  int unsigned writes;          // write cycles accepted, for a testbench to count

  initial begin
    waits_rt    = WAITS;
    bwaits_rt   = BURST_WAITS;
    burst_limit = BURST ? 4 : 1;
    ciin_all    = CIIN;
    ciin_beats  = 4'b0000;
    writes      = 0;
  end

  function automatic int unsigned idx(input logic [31:0] a);
    idx = a % NBYTES;
  endfunction

  function automatic int unsigned siz_bytes(input logic [1:0] s);
    case (s)
      2'b01:   siz_bytes = 1;
      2'b10:   siz_bytes = 2;
      2'b11:   siz_bytes = 3;
      default: siz_bytes = 4;
    endcase
  endfunction

  function automatic int unsigned port_off(input logic [31:0] a);
    port_off = a % PORT_BYTES;
  endfunction

  // How many bytes this device can move this cycle.
  function automatic int unsigned xfer_n(input logic [31:0] a, input logic [1:0] s);
    int unsigned room;
    room   = PORT_BYTES - port_off(a);
    xfer_n = (siz_bytes(s) < room) ? siz_bytes(s) : room;
  endfunction

  logic selected;
  // A memory is never selected by a CPU-space cycle. UM figure 7-42: function
  // code 111 is where the processor talks to the things that are not memory --
  // the interrupt acknowledge, the breakpoint acknowledge, the coprocessor --
  // and its addresses are synthesised, so they fall wherever they fall. A
  // breakpoint acknowledge for BKPT #5 is at $00000014, which is inside this
  // model's range, and without this the memory and the breakpoint device both
  // answered it.
  assign selected = !as_n_i && (fc_i != 3'b111) && ((a_i & MASK) == BASE);

  // The DSACK encoding for this port width -- UM Table 7-1, active low. A
  // localparam and an assign, not an always_comb: a process that reads only
  // parameters has no sensitivities, and iverilog says so for every instance.
  localparam logic [1:0] MY_DSACK = (PORT_BYTES == 1) ? 2'b10    // DSACK0 only
                                  : (PORT_BYTES == 2) ? 2'b01    // DSACK1 only
                                  :                     2'b00;   // both

  // -------------------------------------------------------------------------
  // Asynchronous: DSACK after waits_rt rising edges of AS.
  // -------------------------------------------------------------------------
  int unsigned wait_cnt;
  logic        answering;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wait_cnt  <= 0;
      answering <= 1'b0;
    end else if (selected && !SYNC) begin
      if (wait_cnt >= waits_rt) answering <= 1'b1;
      else                      wait_cnt  <= wait_cnt + 1;
    end else begin
      wait_cnt  <= 0;
      answering <= 1'b0;
    end
  end

  assign dsack_n_o = (!SYNC && selected && answering) ? MY_DSACK : 2'b11;

  // -------------------------------------------------------------------------
  // Synchronous: STERM, and the burst.
  //
  // scnt counts the rising edges this beat has waited; STERM is asserted once it
  // reaches the beat's wait count. beat_cnt counts the beats the processor has
  // taken -- incremented on the rising edge it samples STERM on -- and beat_d,
  // the one whose data is on the bus, follows it on the falling edge after,
  // which is the edge the processor latches on (UM 7.3.4 state 2). STERM is not
  // negated between beats that need no wait: "STERM need not be negated if
  // subsequent accesses do not require wait cycles" (UM 7.3.7 state 3).
  // -------------------------------------------------------------------------
  int unsigned scnt;
  int unsigned beat_cnt;
  int unsigned beat_d;
  logic        sterm_now;
  logic        in_burst;      // CBACK has been given: the cycle is a burst

  assign sterm_now = SYNC && selected
                  && (scnt >= ((beat_cnt == 0) ? waits_rt : bwaits_rt));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scnt     <= 0;
      beat_cnt <= 0;
      in_burst <= 1'b0;
    end else if (!selected) begin
      scnt     <= 0;
      beat_cnt <= 0;
      in_burst <= 1'b0;
    end else if (sterm_now) begin
      scnt     <= 0;
      beat_cnt <= beat_cnt + 1;
      if (!cback_n_o) in_burst <= 1'b1;
    end else begin
      scnt     <= scnt + 1;
    end
  end

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n)          beat_d <= 0;
    else if (!selected)  beat_d <= 0;
    else                 beat_d <= beat_cnt;
  end

  // CBACK with STERM while there is another long word to give -- UM 5.7.4, "the
  // accessed device can operate in the burst mode and can supply at least one
  // more long word". Only when asked: "if a cache burst is not requested, the
  // assertion of CBACK is ignored" (UM 7.2.10), but a polite device does not
  // assert it then either.
  logic cback_now;
  assign cback_now = SYNC && BURST && sterm_now && rw_i && !cbreq_n_i
                  && ((beat_cnt + 1) < burst_limit);

  assign sterm_n_o = ~sterm_now;
  assign cback_n_o = ~cback_now;

  // CIIN is decoded from the address as STERM is, so it is valid on the rising
  // edge with STERM and on the rising edge that starts S4 alike (UM 7.2.8).
  logic ciin_now;
  assign ciin_now = selected && rw_i
                 && (ciin_all || (SYNC && ciin_beats[beat_cnt[1:0]]));
  assign ciin_n_o = ~ciin_now;

  // The address of the long word the burst is on: the cycle's own for the first,
  // then the next in the line, wrapping.
  logic [31:0] beat_a;
  always_comb begin
    beat_a = {a_i[31:4], a_i[3:2] + beat_d[1:0], 2'b00};
  end

  // Read data. Driven whenever this device is selected and answering a read; the
  // lanes it does not own are left at zero, which a 32-bit test would notice --
  // except for a cachable read on a synchronous port asking for a burst, which
  // has to have the whole long word (UM 7.2.7, 7.3.7 state 2: "all of the byte
  // sections ... of the data bus must be driven since the burst operation
  // latches 32 bits on every cycle").
  logic [7:0] rd_lane [0:3];
  int unsigned j;
  logic        whole;
  assign whole = SYNC && (!cbreq_n_i || in_burst || (beat_d != 0));

  always_comb begin
    for (j = 0; j < 4; j = j + 1) rd_lane[j] = 8'h00;
    if (selected && rw_i) begin
      if (whole) begin
        for (j = 0; j < 4; j = j + 1) rd_lane[j] = mem[idx(beat_a + j)];
      end else begin
        for (j = 0; j < 4; j = j + 1) begin
          if (j < xfer_n(a_i, siz_i)) begin
            rd_lane[port_off(a_i) + j] = mem[idx(a_i + j)];
          end
        end
      end
    end
  end

  assign d_o  = {rd_lane[0], rd_lane[1], rd_lane[2], rd_lane[3]};
  assign d_oe = selected && rw_i && (SYNC || answering);

  // Write. An asynchronous device latches on the edge it acknowledges, using
  // R/W, DS, SIZ1, SIZ0, A1 and A0 to pick its bytes (UM 7.3.2 state 3). A
  // synchronous one "uses R/W, CLK, SIZ0-SIZ1, and A0-A1 to latch data" (UM 7.3.5
  // state 2) -- not DS, which a two-clock write never asserts -- on the falling
  // edge after the rising edge it gave STERM on: the data is driven from the
  // start of S2 and held through S3.
  logic [7:0] wr_lane [0:3];
  assign wr_lane[0] = d_i[31:24];
  assign wr_lane[1] = d_i[23:16];
  assign wr_lane[2] = d_i[15:8];
  assign wr_lane[3] = d_i[7:0];

  logic sterm_taken;   // STERM was given on the rising edge just past
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sterm_taken <= 1'b0;
    else        sterm_taken <= sterm_now && !rw_i;
  end

  int unsigned k;
  always_ff @(negedge clk) begin
    if (rst_n && selected && !rw_i && !wr_inhibit_i
        && ((!SYNC && !ds_n_i && answering) || (SYNC && sterm_taken))) begin
      for (k = 0; k < 4; k = k + 1) begin
        if (k < xfer_n(a_i, siz_i)) begin
          mem[idx(a_i + k)] = wr_lane[port_off(a_i) + k];
        end
      end
      if (SYNC) writes = writes + 1;
    end
  end

  // Test access. A testbench may also reach mem[] directly.
  task automatic poke(input logic [31:0] a, input logic [7:0] v);
    mem[idx(a)] = v;
  endtask

  function automatic logic [7:0] peek(input logic [31:0] a);
    peek = mem[idx(a)];
  endfunction

  task automatic fill(input logic [7:0] v);
    int unsigned n;
    for (n = 0; n < NBYTES; n = n + 1) mem[n] = v;
  endtask

endmodule
