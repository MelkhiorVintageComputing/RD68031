// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- exceptions together, the three stacks, and the interrupt details.
//
// core_exc_tb has every frame on its own; this is what happens when more than
// one exception is due at once, and the parts of UM section 8 that are about
// state rather than frames:
//
//   - UM 8.1.12 and Table 8-5, the priority groups, through the order the
//     handlers run in -- "the lower the priority of an exception, the sooner
//     the handler routine for that exception executes". Each handler writes a
//     letter to a log, so the log is the order. TRAP with a trace pending,
//     and with a trace and an interrupt (UM 8.1.12's own example); CHK with a
//     trace; an illegal instruction and a privilege violation under trace,
//     which are not traced (UM 8.1.7); a trace and an interrupt due at the end
//     of a long instruction.
//   - Interrupts on instruction boundaries only: one raised during a DIVU.L
//     and during a MOVEM is taken after the instruction completes.
//   - BKPT (UM 8.1.11, 7.4.2) in the whole processor: the breakpoint
//     acknowledge cycle, the word it returns executed in place of the BKPT,
//     a bus error on it taken as an illegal instruction, and trace on change
//     of flow when that word is a branch.
//   - The three stacks (UM 4.1.1, 4.1.3, 8.1.9): MOVEC to and from MSP, ISP
//     and USP, MOVE USP, which register A7 is for each S and M; a TRAP in the
//     master state, which stays there; an interrupt in the master state, which
//     builds the throwaway frame and leaves it; and RTE through two throwaway
//     frames in a row, onto a third stack -- "the second frame may be any
//     format (even another throwaway frame) and may reside on any of the three
//     system stacks" (UM 8.1.13).
//   - The uninitialised interrupt vector, 15 (UM 8.1.9), and IPEND negated in
//     S0 of the acknowledge (UM 8.1.9, figure 8-4).

`timescale 1ns / 1ps

module core_excpri_tb;

`include "rd68031_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] MSP0 = 32'h0000_2000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] LOG  = 32'h0000_3800;   // A6: one letter per handler run
  localparam logic [31:0] LOG2 = 32'h0000_3900;   // A5: long words some handlers record

  // The handlers, and their vectors -- UM Table 8-1.
  localparam logic [31:0] H_T = 32'h0000_0500;    // 9 trace: 'T', +$08, +$02
  localparam logic [31:0] H_P = 32'h0000_0520;    // 33 TRAP #1: 'P'
  localparam logic [31:0] H_I = 32'h0000_0540;    // interrupts: 'I', +$02
  localparam logic [31:0] H_C = 32'h0000_0560;    // 6 CHK: 'C'
  localparam logic [31:0] H_L = 32'h0000_0580;    // 4 illegal: 'L', step +$02 by 2
  localparam logic [31:0] H_V = 32'h0000_05A0;    // 8 privilege: 'V', step +$02 by 4
  localparam logic [31:0] H_U = 32'h0000_05C0;    // 15 uninitialised: 'U'
  localparam logic [31:0] H_E = 32'h0000_05E0;    // 34, 35 TRAP #2, #3: 'E', stop
  localparam logic [31:0] H_M = 32'h0000_0600;    // 36 TRAP #4, 64: SR and A7 to D7, A4

  bit          reached;
  string       what;
  logic [31:0] H;

  // ------------------------------------------------------------------------
  // The device on the other end of an interrupt acknowledge (UM 7.4.1) and of
  // a breakpoint acknowledge (UM 7.4.2). Both are CPU space, FC = 7: type $F
  // on A19-A16 with the level on A3-A1, and type 0 with the breakpoint number
  // on A4-A2 (UM figure 7-42).
  // ------------------------------------------------------------------------
  localparam int IACK_VECTOR = 0;
  localparam int IACK_AUTO   = 1;
  logic  [7:0] iack_vec;
  int unsigned iack_mode;
  int unsigned iacks, bkpts;
  initial begin iack_vec = 8'd64; iack_mode = IACK_VECTOR; iacks = 0; bkpts = 0; end

  wire iack_now = !as_n_o && (fc_o === 3'b111) && (a_o[19:16] === 4'hF);
  wire bkpt_now = !as_n_o && (fc_o === 3'b111) && (a_o[19:16] === 4'h0);

  always @(*) begin
    dsack_ext  = 2'b11;
    avec_n_i   = 1'b1;
    berr_force = 1'b0;
    oe_ext     = 1'b0;
    d_ext      = 32'd0;
    if (iack_now) begin
      if (iack_mode == IACK_AUTO) avec_n_i = 1'b0;
      else begin
        dsack_ext = 2'b10;               // an 8-bit port: the vector on D31-D24
        oe_ext    = 1'b1;
        d_ext     = {iack_vec, 24'd0};
      end
    end else if (bkpt_now) begin
      // UM 7.4.2: "the external hardware can return either BERR, DSACKx, or
      // STERM with an instruction word on the data bus". A 32-bit port puts the
      // word on D31-D16.
      unique case (a_o[4:2])
        3'd3: begin dsack_ext = 2'b00; oe_ext = 1'b1; d_ext = 32'h7012_0000; end  // MOVEQ #$12,D0
        3'd5: begin dsack_ext = 2'b00; oe_ext = 1'b1; d_ext = 32'h6004_0000; end  // BRA.S *+6
        3'd6: begin dsack_ext = 2'b00; oe_ext = 1'b1; d_ext = 32'h7633_0000; end  // MOVEQ #$33,D3
        default: berr_force = 1'b1;                                              // nobody
      endcase
    end
  end

  // The acknowledges, as the device sees them; a device drops its request
  // when it is acknowledged.
  logic [31:0] bkpt_a [0:7];
  always @(posedge iack_now) begin iacks++; ipl_n_i = 3'b111; end
  always @(posedge bkpt_now) begin if (bkpts < 8) bkpt_a[bkpts] = a_o; bkpts++; end

  // IPEND against the acknowledge's S0 -- UM 8.1.9: "the IPEND signal is
  // negated during state 0 (S0) of an interrupt acknowledge cycle". S0 begins
  // on the rising edge before AS asserts on the falling one (UM 7.3.1).
  realtime t_ipend_off, t_iack_as;
  always @(posedge ipend_n_o) if (rst_n === 1'b1) t_ipend_off = $realtime;
  always @(posedge iack_now) t_iack_as = $realtime;

  // Raise a request when the instruction at `at` is being decoded: the only
  // way to have it arrive DURING an instruction rather than at a boundary.
  task automatic irq_during(input logic [31:0] at, input logic [2:0] level);
    int n;
    n = 0;
    while (!(dut.u_ifu.pc_d === at && dut.u_ifu.pf_dvalid) && n < 4000) begin
      @(negedge clk); n = n + 1;
    end
    ipl_n_i = ~level;
  endtask

  task automatic base_setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1)
      poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);       // an unexpected vector spins
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    poke_l(9 * 4,  H_T);
    poke_l(33 * 4, H_P);
    poke_l(64 * 4, H_I);
    poke_l(27 * 4, H_I);                   // the level 3 autovector
    poke_l(6 * 4,  H_C);
    poke_l(4 * 4,  H_L);
    poke_l(8 * 4,  H_V);
    poke_l(15 * 4, H_U);
    poke_l(34 * 4, H_E);
    poke_l(35 * 4, H_E);
    poke_l(36 * 4, H_M);
    for (v = 0; v < 64; v = v + 4) begin
      poke_l(LOG + v, 32'h0);
      poke_l(LOG2 + v, 32'h0);
    end
    poke_w(H_T + 32'h000, 16'h1CFC);  // move.b #'T',(%a6)+
    poke_w(H_T + 32'h002, 16'h0054);
    poke_w(H_T + 32'h004, 16'h2AEF);  // move.l 8(%a7),(%a5)+
    poke_w(H_T + 32'h006, 16'h0008);
    poke_w(H_T + 32'h008, 16'h2AEF);  // move.l 2(%a7),(%a5)+
    poke_w(H_T + 32'h00A, 16'h0002);
    poke_w(H_T + 32'h00C, 16'h4E73);  // rte
    poke_w(H_P + 32'h000, 16'h1CFC);  // move.b #'P',(%a6)+
    poke_w(H_P + 32'h002, 16'h0050);
    poke_w(H_P + 32'h004, 16'h4E73);  // rte
    poke_w(H_I + 32'h000, 16'h1CFC);  // move.b #'I',(%a6)+
    poke_w(H_I + 32'h002, 16'h0049);
    poke_w(H_I + 32'h004, 16'h2AEF);  // move.l 2(%a7),(%a5)+
    poke_w(H_I + 32'h006, 16'h0002);
    poke_w(H_I + 32'h008, 16'h4E73);  // rte
    poke_w(H_C + 32'h000, 16'h1CFC);  // move.b #'C',(%a6)+
    poke_w(H_C + 32'h002, 16'h0043);
    poke_w(H_C + 32'h004, 16'h4E73);  // rte
    poke_w(H_L + 32'h000, 16'h1CFC);  // move.b #'L',(%a6)+
    poke_w(H_L + 32'h002, 16'h004C);
    poke_w(H_L + 32'h004, 16'h54AF);  // addq.l #2,2(%a7)
    poke_w(H_L + 32'h006, 16'h0002);
    poke_w(H_L + 32'h008, 16'h4E73);  // rte
    poke_w(H_V + 32'h000, 16'h1CFC);  // move.b #'V',(%a6)+
    poke_w(H_V + 32'h002, 16'h0056);
    poke_w(H_V + 32'h004, 16'h58AF);  // addq.l #4,2(%a7)
    poke_w(H_V + 32'h006, 16'h0002);
    poke_w(H_V + 32'h008, 16'h4E73);  // rte
    poke_w(H_U + 32'h000, 16'h1CFC);  // move.b #'U',(%a6)+
    poke_w(H_U + 32'h002, 16'h0055);
    poke_w(H_U + 32'h004, 16'h4E73);  // rte
    poke_w(H_E + 32'h000, 16'h1CFC);  // move.b #'E',(%a6)+
    poke_w(H_E + 32'h002, 16'h0045);
    poke_w(H_E + 32'h004, 16'h60FE);  // bra.s .
    poke_w(H_M + 32'h000, 16'h40C7);  // move.w %sr,%d7
    poke_w(H_M + 32'h002, 16'h284F);  // move.l %a7,%a4
    poke_w(H_M + 32'h004, 16'h4E73);  // rte
    iack_vec  = 8'd64;
    iack_mode = IACK_VECTOR;
    ipl_n_i   = 3'b111;
  endtask

  // The spin is reached as the last instruction before it decodes, and a
  // trace of that instruction is taken after that: wait for it to be over.
  task automatic code_spin(input logic [31:0] at, input int limit);
    run_until(at, limit, reached);
    repeat (400) @(negedge clk);
  endtask

  function automatic string logstr(input int n);
    string s;
    logic [7:0] c;
    bit done;
    s = "";
    done = 1'b0;
    for (int i = 0; i < n; i++) begin
      c = s32.mem[LOG[15:0] + i];
      if (c == 8'h00) done = 1'b1;
      if (!done) s = {s, string'(c)};
    end
    return s;
  endfunction

  initial begin
    $display("core_excpri_tb: exceptions together, the three stacks, interrupts");

    // ======================================================================
    // TRAP with a trace pending. UM 8.1.12: "if an instruction forces an
    // exception as part of its normal execution, the forced exception
    // processing occurs before the trace exception is processed" -- and the
    // trace is then taken at once, before the trap handler's first
    // instruction, so the trace handler runs first and returns into the trap
    // handler (Table 8-5: TRAP is group 2, trace 4.1). The trace frame's +$08
    // is the TRAP, its +$02 the trap handler.
    //
    // UM 8.1.4 says otherwise in one sentence -- "a trace exception is taken
    // after the RTE instruction from the trap handler is executed" --
    // doc/manual-contradictions.md, entry 17.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h46FC);  // move.w #0x2000,%sr
    poke_w(CODE + 32'h00A, 16'h2000);
    poke_w(CODE + 32'h00C, 16'h007C);  // ori.w #0x8000,%sr
    poke_w(CODE + 32'h00E, 16'h8000);
    poke_w(CODE + 32'h010, 16'h4E41);  // trap #1
    poke_w(CODE + 32'h012, 16'h027C);  // andi.w #0x7FFF,%sr
    poke_w(CODE + 32'h014, 16'h7FFF);
    poke_w(CODE + 32'h016, 16'h60FE);  // bra.s .
    reset_dut();
    code_spin(CODE + 32'h016, 6000);
    check(reached && logstr(8) == "TPT",
          {"TRAP under trace: the trace handler, then the trap handler, then the ANDI's trace -- UM 8.1.12; log ", logstr(8)});
    check(peek_l(LOG2 + 0) === CODE + 32'h010 && peek_l(LOG2 + 4) === H_P,
          "TRAP under trace: the trace frame names the TRAP at +$08 and the trap handler at +$02");
    check(peek_l(LOG2 + 8) === CODE + 32'h012 && peek_l(LOG2 + 12) === CODE + 32'h016,
          "TRAP under trace: the ANDI traced after the trap handler's RTE");

    // UM 8.1.12's own example: "if simultaneous trap, trace, and interrupt
    // exceptions are pending, the exception processing for the trap occurs
    // first, followed immediately by exception processing for the trace and
    // then for the interrupt. When the processor resumes normal instruction
    // execution, it is in the interrupt handler, which returns to the trace
    // handler, which returns to the trap exception handler."
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h46FC);  // move.w #0x2000,%sr
    poke_w(CODE + 32'h00A, 16'h2000);
    poke_w(CODE + 32'h00C, 16'h007C);  // ori.w #0x8000,%sr
    poke_w(CODE + 32'h00E, 16'h8000);
    poke_w(CODE + 32'h010, 16'h4E41);  // trap #1
    poke_w(CODE + 32'h012, 16'h027C);  // andi.w #0x7FFF,%sr
    poke_w(CODE + 32'h014, 16'h7FFF);
    poke_w(CODE + 32'h016, 16'h60FE);  // bra.s .
    reset_dut();
    irq_during(CODE + 32'h010, 3'd3);
    code_spin(CODE + 32'h016, 6000);
    check(reached && logstr(8) == "ITPT",
          {"TRAP, trace and interrupt: interrupt handler, trace handler, trap handler -- UM 8.1.12; log ", logstr(8)});
    check(peek_l(LOG2 + 0) === H_T,
          "TRAP, trace and interrupt: the interrupt frame returns into the trace handler");
    check(peek_l(LOG2 + 4) === CODE + 32'h010 && peek_l(LOG2 + 8) === H_P,
          "TRAP, trace and interrupt: the trace frame returns into the trap handler");

    // ======================================================================
    // An illegal instruction under trace is not traced -- UM 8.1.7, "that
    // instruction does not cause a trace exception since it is not executed".
    // The ANDI after it, which the handler returns to, is.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h007C);  // ori.w #0x8000,%sr
    poke_w(CODE + 32'h00A, 16'h8000);
    poke_w(CODE + 32'h00C, 16'h4AFC);  // illegal
    poke_w(CODE + 32'h00E, 16'h027C);  // andi.w #0x7FFF,%sr
    poke_w(CODE + 32'h010, 16'h7FFF);
    poke_w(CODE + 32'h012, 16'h60FE);  // bra.s .
    reset_dut();
    code_spin(CODE + 32'h012, 6000);
    check(reached && logstr(8) == "LT",
          {"illegal under trace: the illegal handler only, then the ANDI's trace -- UM 8.1.7; log ", logstr(8)});
    check(peek_l(LOG2 + 0) === CODE + 32'h00E,
          "illegal under trace: the trace that follows is the ANDI's");

    // A privilege violation in user mode under trace, likewise (UM 8.1.6:
    // processing "begins ... before executing the instruction"). The TRAP the
    // handler returns to is traced, and its trace handler runs before the
    // trap's.
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h41F8);  // lea 0x3000,%a0
    poke_w(CODE + 32'h00A, 16'h3000);
    poke_w(CODE + 32'h00C, 16'h4E60);  // move.l %a0,%usp
    poke_w(CODE + 32'h00E, 16'h46FC);  // move.w #0x8000,%sr
    poke_w(CODE + 32'h010, 16'h8000);
    poke_w(CODE + 32'h012, 16'h46FC);  // move.w #0x2700,%sr
    poke_w(CODE + 32'h014, 16'h2700);
    poke_w(CODE + 32'h016, 16'h4E42);  // trap #2
    reset_dut();
    code_spin(H_E + 32'h004, 6000);
    check(reached && logstr(8) == "VTE",
          {"privilege violation under trace: not traced; the TRAP after it is -- UM 8.1.7; log ", logstr(8)});
    check(peek_l(LOG2 + 0) === CODE + 32'h016,
          "privilege violation under trace: the only instruction traced before the TRAP's handler is the TRAP");

    // ======================================================================
    // CHK under trace: the CHK exception, then the trace -- UM 8.1.12.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h70FF);  // moveq #-1,%d0
    poke_w(CODE + 32'h00A, 16'h007C);  // ori.w #0x8000,%sr
    poke_w(CODE + 32'h00C, 16'h8000);
    poke_w(CODE + 32'h00E, 16'h41BC);  // chk.w #5,%d0
    poke_w(CODE + 32'h010, 16'h0005);
    poke_w(CODE + 32'h012, 16'h027C);  // andi.w #0x7FFF,%sr
    poke_w(CODE + 32'h014, 16'h7FFF);
    poke_w(CODE + 32'h016, 16'h60FE);  // bra.s .
    reset_dut();
    code_spin(CODE + 32'h016, 6000);
    check(reached && logstr(8) == "TCT",
          {"CHK under trace: trace handler, then CHK handler, then the ANDI's trace -- UM 8.1.12; log ", logstr(8)});
    check(peek_l(LOG2 + 0) === CODE + 32'h00E && peek_l(LOG2 + 4) === H_C,
          "CHK under trace: the trace frame names the CHK at +$08 and the CHK handler at +$02");

    // ======================================================================
    // A trace and an interrupt due at the same boundary, the end of a long
    // instruction: UM 8.1.7, "if an interrupt is pending at the completion of
    // an instruction, the trace exception processing occurs before the
    // interrupt exception processing starts" -- so the interrupt handler runs
    // first and returns into the trace handler. The interrupt arrives while
    // DIVU.L is running and is taken only at its end (UM 8.1.9).
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h243C);  // move.l #100000,%d2
    poke_w(CODE + 32'h00A, 16'h0001);
    poke_w(CODE + 32'h00C, 16'h86A0);
    poke_w(CODE + 32'h00E, 16'h7207);  // moveq #7,%d1
    poke_w(CODE + 32'h010, 16'h46FC);  // move.w #0x2000,%sr
    poke_w(CODE + 32'h012, 16'h2000);
    poke_w(CODE + 32'h014, 16'h007C);  // ori.w #0x8000,%sr
    poke_w(CODE + 32'h016, 16'h8000);
    poke_w(CODE + 32'h018, 16'h4C41);  // divu.l %d1,%d2
    poke_w(CODE + 32'h01A, 16'h2002);
    poke_w(CODE + 32'h01C, 16'h027C);  // andi.w #0x7FFF,%sr
    poke_w(CODE + 32'h01E, 16'h7FFF);
    poke_w(CODE + 32'h020, 16'h60FE);  // bra.s .
    reset_dut();
    irq_during(CODE + 32'h018, 3'd3);
    code_spin(CODE + 32'h020, 8000);
    check(reached && logstr(8) == "ITT",
          {"trace and interrupt at the end of DIVU.L: interrupt handler, trace handler, the ANDI's trace -- UM 8.1.7; log ", logstr(8)});
    check(peek_l(LOG2 + 0) === H_T,
          "trace and interrupt: the interrupt was taken after the trace's exception processing");
    check(peek_l(LOG2 + 4) === CODE + 32'h018 && peek_l(LOG2 + 8) === CODE + 32'h01C,
          "trace and interrupt: the DIVU.L completed and was traced");
    check(dut.u_seq.dreg[2] === 32'd14285, "trace and interrupt: DIVU.L's quotient");

    // An interrupt raised during MOVEM is taken after it, with the next
    // instruction stacked -- UM 8.1.9, Table 8-6.
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h41F8);  // lea 0x3A00,%a0
    poke_w(CODE + 32'h00A, 16'h3A00);
    poke_w(CODE + 32'h00C, 16'h46FC);  // move.w #0x2000,%sr
    poke_w(CODE + 32'h00E, 16'h2000);
    poke_w(CODE + 32'h010, 16'h4CD0);  // movem.l (%a0),%d0-%d7/%a1-%a4
    poke_w(CODE + 32'h012, 16'h1EFF);
    poke_w(CODE + 32'h014, 16'h4E71);  // nop
    poke_w(CODE + 32'h016, 16'h60FE);  // bra.s .
    for (int k = 0; k < 12; k++) poke_l(32'h3A00 + 4 * k, 32'h1000_0000 + k);
    reset_dut();
    irq_during(CODE + 32'h010, 3'd3);
    code_spin(CODE + 32'h016, 6000);
    check(reached && logstr(8) == "I" && peek_l(LOG2 + 0) === CODE + 32'h014,
          "interrupt during MOVEM: taken after it, the next instruction stacked -- UM 8.1.9");
    check(dut.u_seq.dreg[7] === 32'h1000_0007 && dut.u_seq.areg[4] === 32'h1000_000B,
          "interrupt during MOVEM: every register was loaded first");

    // ======================================================================
    // BKPT -- UM 8.1.11, figure 8-7, and 7.4.2.
    //   #3  DSACK with MOVEQ #$12,D0: "the processor uses the data returned to
    //       replace the breakpoint instruction in the internal instruction
    //       pipe and begins execution of that instruction".
    //   #4  BERR: "the processor performs illegal instruction exception
    //       processing", with the BKPT's own address stacked.
    //   #5  under trace on change of flow (T1 T0 = 01), DSACK with BRA.S: "the
    //       execution of the BKPT instruction causes a change of flow if the
    //       opcode replacing the BKPT is an instruction that causes a change
    //       of flow" -- traced, at the BKPT's address.
    //   #6  under the same trace mode, DSACK with MOVEQ: no change of flow, no
    //       trace.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h7400);  // moveq #0,%d2
    poke_w(CODE + 32'h00A, 16'h484B);  // bkpt #3
    poke_w(CODE + 32'h00C, 16'h484C);  // bkpt #4
    poke_w(CODE + 32'h00E, 16'h46FC);  // move.w #0x6700,%sr
    poke_w(CODE + 32'h010, 16'h6700);
    poke_w(CODE + 32'h012, 16'h484D);  // bkpt #5
    poke_w(CODE + 32'h014, 16'h7477);  // moveq #0x77,%d2
    poke_w(CODE + 32'h016, 16'h7478);  // moveq #0x78,%d2
    poke_w(CODE + 32'h018, 16'h484E);  // bkpt #6
    poke_w(CODE + 32'h01A, 16'h027C);  // andi.w #0x3FFF,%sr
    poke_w(CODE + 32'h01C, 16'h3FFF);
    poke_w(CODE + 32'h01E, 16'h60FE);  // bra.s .
    reset_dut();
    code_spin(CODE + 32'h01E, 6000);
    check(reached, "BKPT: the program runs through four breakpoints");
    check(bkpts == 4, $sformatf("BKPT: four breakpoint acknowledge cycles, got %0d", bkpts));
    check(bkpt_a[0] === 32'h0000_000C && bkpt_a[1] === 32'h0000_0010
          && bkpt_a[2] === 32'h0000_0014 && bkpt_a[3] === 32'h0000_0018,
          "BKPT: CPU space type 0, the number on A4-A2 -- UM figure 7-42");
    check(dut.u_seq.dreg[0] === 32'h12 && dut.u_seq.dreg[3] === 32'h33,
          "BKPT: the returned words were executed in place of the BKPTs");
    check(dut.u_seq.dreg[2] === 32'h0,
          "BKPT: the returned BRA.S ran from the BKPT's address, over the two MOVEQs");
    check(logstr(8) == "LTT",
          {"BKPT: the BERR one an illegal instruction; the BRA traced, the MOVEQ not; the ANDI to SR traced -- log ", logstr(8)});
    check(peek_l(LOG2 + 0) === CODE + 32'h012 && peek_l(LOG2 + 4) === CODE + 32'h018,
          "BKPT: the change-of-flow trace names the BKPT and its branch's target");

    // ======================================================================
    // The three stacks -- UM 4.1.1, PRM 6 MOVEC and MOVE USP.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h41F8);  // lea 0x2000,%a0
    poke_w(CODE + 32'h002, 16'h2000);
    poke_w(CODE + 32'h004, 16'h4E7B);  // movec %a0,%msp
    poke_w(CODE + 32'h006, 16'h8803);
    poke_w(CODE + 32'h008, 16'h41F8);  // lea 0x1100,%a0
    poke_w(CODE + 32'h00A, 16'h1100);
    poke_w(CODE + 32'h00C, 16'h4E7B);  // movec %a0,%isp
    poke_w(CODE + 32'h00E, 16'h8804);
    poke_w(CODE + 32'h010, 16'h41F8);  // lea 0x3000,%a0
    poke_w(CODE + 32'h012, 16'h3000);
    poke_w(CODE + 32'h014, 16'h4E7B);  // movec %a0,%usp
    poke_w(CODE + 32'h016, 16'h8800);
    poke_w(CODE + 32'h018, 16'h4E7A);  // movec %msp,%d1
    poke_w(CODE + 32'h01A, 16'h1803);
    poke_w(CODE + 32'h01C, 16'h4E7A);  // movec %isp,%d2
    poke_w(CODE + 32'h01E, 16'h2804);
    poke_w(CODE + 32'h020, 16'h4E7A);  // movec %usp,%d3
    poke_w(CODE + 32'h022, 16'h3800);
    poke_w(CODE + 32'h024, 16'h280F);  // move.l %a7,%d4
    poke_w(CODE + 32'h026, 16'h46FC);  // move.w #0x3700,%sr
    poke_w(CODE + 32'h028, 16'h3700);
    poke_w(CODE + 32'h02A, 16'h2A0F);  // move.l %a7,%d5
    poke_w(CODE + 32'h02C, 16'h4E69);  // move.l %usp,%a1
    poke_w(CODE + 32'h02E, 16'h45F8);  // lea 0x3100,%a2
    poke_w(CODE + 32'h030, 16'h3100);
    poke_w(CODE + 32'h032, 16'h4E62);  // move.l %a2,%usp
    poke_w(CODE + 32'h034, 16'h4E7A);  // movec %usp,%d6
    poke_w(CODE + 32'h036, 16'h6800);
    poke_w(CODE + 32'h038, 16'h46FC);  // move.w #0x0700,%sr
    poke_w(CODE + 32'h03A, 16'h0700);
    poke_w(CODE + 32'h03C, 16'h2E0F);  // move.l %a7,%d7
    poke_w(CODE + 32'h03E, 16'h4E43);  // trap #3
    reset_dut();
    code_spin(H_E + 32'h004, 6000);
    check(reached, "stacks: the program reaches its TRAP");
    check(dut.u_seq.dreg[1] === 32'h2000 && dut.u_seq.dreg[2] === 32'h1100
          && dut.u_seq.dreg[3] === 32'h3000,
          "stacks: MOVEC reads back MSP, ISP and USP as written");
    check(dut.u_seq.dreg[4] === 32'h1100,
          "stacks: S set, M clear: A7 is the ISP, and MOVEC to ISP moved it -- UM 4.1.1");
    check(dut.u_seq.dreg[5] === 32'h2000, "stacks: M set: A7 is the MSP -- UM 4.1.1");
    check(dut.u_seq.areg[1] === 32'h3000 && dut.u_seq.dreg[6] === 32'h3100,
          "stacks: MOVE USP reads and writes the one MOVEC names -- PRM 6");
    check(dut.u_seq.dreg[7] === 32'h3100, "stacks: S clear: A7 is the USP -- UM 4.1.2");
    check(dut.u_seq.isp_q === 32'h1100 - 32'd8 && peek_w(32'h1100 - 32'd8) === 16'h0700,
          "stacks: a TRAP from user mode with M clear stacks on the ISP -- UM 8.1");
    check(dut.u_seq.msp_q === 32'h2000 && dut.u_seq.usp_q === 32'h3100,
          "stacks: and leaves the other two alone");

    // A TRAP in the master state: the frame on the MSP, and M stays set --
    // UM 4.1.1, "the processor automatically saves the M-bit value and clears
    // it in the SR as part of the exception processing for interrupts" and
    // for nothing else.
    base_setup();
    poke_w(CODE + 32'h000, 16'h41F8);  // lea 0x2000,%a0
    poke_w(CODE + 32'h002, 16'h2000);
    poke_w(CODE + 32'h004, 16'h4E7B);  // movec %a0,%msp
    poke_w(CODE + 32'h006, 16'h8803);
    poke_w(CODE + 32'h008, 16'h46FC);  // move.w #0x3700,%sr
    poke_w(CODE + 32'h00A, 16'h3700);
    poke_w(CODE + 32'h00C, 16'h4E44);  // trap #4
    poke_w(CODE + 32'h00E, 16'h7011);  // moveq #0x11,%d0
    poke_w(CODE + 32'h010, 16'h60FE);  // bra.s .
    reset_dut();
    code_spin(CODE + 32'h010, 6000);
    check(reached && dut.u_seq.dreg[0] === 32'h11, "master TRAP: the program runs on after RTE");
    check(dut.u_seq.dreg[7][15:0] === 16'h3700,
          "master TRAP: the handler runs with S and M set, T clear -- UM 8.1 step one");
    check(dut.u_seq.areg[4] === MSP0 - 32'd8, "master TRAP: on the master stack");
    check(peek_w(MSP0 - 8) === 16'h3700 && peek_l(MSP0 - 6) === CODE + 32'h00E
          && peek_w(MSP0 - 2) === 16'h0090,
          "master TRAP: the format $0 frame: SR, the next instruction, vector 36");
    check(dut.u_seq.isp_q === ISP0 && dut.u_seq.msp_q === MSP0
          && dut.u_seq.sr_q === 16'h3700,
          "master TRAP: the ISP untouched; RTE put the MSP and the SR back");

    // An interrupt in the master state, from supervisor mode: the frame on the
    // MSP, then M cleared and the throwaway format $1 on the ISP -- UM 8.1.9,
    // "the copy of the status register saved on the throwaway frame is
    // exactly the same as that placed on the master stack except that the S
    // bit is set". It is set in both here; M is set in both.
    base_setup();
    poke_w(CODE + 32'h000, 16'h41F8);  // lea 0x2000,%a0
    poke_w(CODE + 32'h002, 16'h2000);
    poke_w(CODE + 32'h004, 16'h4E7B);  // movec %a0,%msp
    poke_w(CODE + 32'h006, 16'h8803);
    poke_w(CODE + 32'h008, 16'h46FC);  // move.w #0x3000,%sr
    poke_w(CODE + 32'h00A, 16'h3000);
    poke_w(CODE + 32'h00C, 16'h4E71);  // nop
    poke_w(CODE + 32'h00E, 16'h7022);  // moveq #0x22,%d0
    poke_w(CODE + 32'h010, 16'h60FE);  // bra.s .
    poke_l(64 * 4, H_M);                   // the device's vector 64 records SR and A7
    ipl_n_i = ~3'd3;                       // held off by the mask until the MOVE
    reset_dut();
    code_spin(CODE + 32'h010, 6000);
    check(reached && dut.u_seq.dreg[0] === 32'h22, "master interrupt: the program runs on");
    check(dut.u_seq.dreg[7][15:0] === 16'h2300,
          "master interrupt: the handler runs with S set, M clear, the mask at 3 -- UM 8.1.9");
    check(dut.u_seq.areg[4] === ISP0 - 32'd8, "master interrupt: on the interrupt stack");
    check(peek_w(MSP0 - 8) === 16'h3000 && peek_l(MSP0 - 6) === CODE + 32'h00C
          && peek_w(MSP0 - 2) === 16'h0100,
          "master interrupt: format $0 on the MSP: SR, the NOP, vector 64");
    check(peek_w(ISP0 - 8) === 16'h3000 && peek_l(ISP0 - 6) === CODE + 32'h00C
          && peek_w(ISP0 - 2) === 16'h1100,
          "master interrupt: format $1 on the ISP, the same PC and vector -- UM 8.1.9");
    check(dut.u_seq.isp_q === ISP0 && dut.u_seq.msp_q === MSP0
          && dut.u_seq.sr_q === 16'h3000,
          "master interrupt: RTE took both frames off and is back in the master state");

    // RTE through two throwaway frames on the ISP onto a four-word frame on
    // the MSP, returning to user mode -- UM 8.1.13 and figure 8-8.
    base_setup();
    poke_l(32'h0000_0000, ISP0 - 32'd16);
    poke_w(ISP0 - 16, 16'h2000);           // S, M clear: the next frame is on the ISP
    poke_l(ISP0 - 14, 32'hDEAD_0001);
    poke_w(ISP0 - 10, 16'h1100);
    poke_w(ISP0 - 8,  16'h3000);           // S, M set: the next frame is on the MSP
    poke_l(ISP0 - 6,  32'hDEAD_0002);
    poke_w(ISP0 - 2,  16'h1100);
    poke_w(MSP0 - 8,  16'h0000);           // user mode
    poke_l(MSP0 - 6,  CODE + 32'h40);
    poke_w(MSP0 - 2,  16'h0000);
    poke_w(CODE + 32'h40, 16'h705A);       // MOVEQ #$5A,D0
    poke_w(CODE + 32'h42, 16'h60FE);
    poke_w(CODE + 32'h000, 16'h41F8);  // lea 0x1FF8,%a0
    poke_w(CODE + 32'h002, 16'h1FF8);
    poke_w(CODE + 32'h004, 16'h4E7B);  // movec %a0,%msp
    poke_w(CODE + 32'h006, 16'h8803);
    poke_w(CODE + 32'h008, 16'h4E73);  // rte
    reset_dut();
    code_spin(CODE + 32'h42, 6000);
    check(reached && dut.u_seq.dreg[0] === 32'h5A && dut.u_seq.sr_q === 16'h0000,
          "two throwaway frames: RTE reaches the four-word frame on the MSP, in user mode -- UM 8.1.13");
    check(dut.u_seq.isp_q === ISP0 && dut.u_seq.msp_q === MSP0,
          "two throwaway frames: eight bytes off each of the three frames' stacks");

    // ======================================================================
    // The uninitialised interrupt vector -- UM 8.1.9: a peripheral that was
    // never given a vector "usually returns the vector number for the
    // uninitialized interrupt vector, 15". And IPEND, negated in S0 of the
    // acknowledge.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h46FC);  // move.w #0x2000,%sr
    poke_w(CODE + 32'h00A, 16'h2000);
    poke_w(CODE + 32'h00C, 16'h4E71);  // nop
    poke_w(CODE + 32'h00E, 16'h7033);  // moveq #0x33,%d0
    poke_w(CODE + 32'h010, 16'h60FE);  // bra.s .
    iack_vec = 8'd15;
    ipl_n_i  = ~3'd4;
    reset_dut();
    code_spin(CODE + 32'h010, 6000);
    check(reached && logstr(8) == "U" && dut.u_seq.dreg[0] === 32'h33,
          "uninitialised interrupt: vector 15's handler, and back");
    check(peek_w(ISP0 - 2) === 16'h003C && peek_w(ISP0 - 8) === 16'h2000
          && peek_l(ISP0 - 6) === CODE + 32'h00C,
          "uninitialised interrupt: format $0, vector offset $3C -- UM Table 8-1");
    check(t_iack_as - t_ipend_off == CLK_PERIOD / 2.0,
          $sformatf("IPEND negates on the rising edge that starts the acknowledge's S0, %0.1f ns before AS -- UM 8.1.9",
                    t_iack_as - t_ipend_off));

    // ======================================================================
    // CHK2 out of bounds -- UM 8.1.4, Table 8-6: vector 6, the six-word frame,
    // the next instruction at +$02 and the CHK2 at +$08.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h4DF8);  // lea 0x3800,%a6
    poke_w(CODE + 32'h002, 16'h3800);
    poke_w(CODE + 32'h004, 16'h4BF8);  // lea 0x3900,%a5
    poke_w(CODE + 32'h006, 16'h3900);
    poke_w(CODE + 32'h008, 16'h41F8);  // lea 0x3A00,%a0
    poke_w(CODE + 32'h00A, 16'h3A00);
    poke_w(CODE + 32'h00C, 16'h72EF);  // moveq #-17,%d1
    poke_w(CODE + 32'h00E, 16'h00D0);  // chk2.b (%a0),%d1
    poke_w(CODE + 32'h010, 16'h1800);
    poke_w(CODE + 32'h012, 16'h7033);  // moveq #0x33,%d0
    poke_w(CODE + 32'h014, 16'h60FE);  // bra.s .
    poke_w(32'h3A00, 16'hF010);        // bounds -16 .. +16
    reset_dut();
    code_spin(CODE + 32'h014, 6000);
    check(reached && logstr(8) == "C" && dut.u_seq.dreg[0] === 32'h33,
          "CHK2 out of bounds: vector 6, and RTE returns to the next instruction");
    check((peek_w(ISP0 - 12) & 16'hFF05) === 16'h2701 && peek_l(ISP0 - 10) === CODE + 32'h012
          && peek_w(ISP0 - 6) === 16'h2018 && peek_l(ISP0 - 4) === CODE + 32'h00E,
          "CHK2 out of bounds: format $2 -- SR with C set and Z clear (N and V undefined, PRM 4), the next instruction, vector offset $018, the CHK2 -- UM Table 8-6");

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_excpri_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_excpri_tb");
    else                               $display("FAIL: core_excpri_tb");
    $finish;
  end

  initial begin
    #80_000_000;
    $display("FAIL: core_excpri_tb timed out");
    $finish;
  end

endmodule
