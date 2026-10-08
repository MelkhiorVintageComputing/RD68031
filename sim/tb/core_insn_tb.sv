// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- instructions the generated sweep cannot judge.
//
// Every case here is one where Musashi is not authoritative and the expectation
// is written from the manual instead -- doc/divergences.md says which and why
// for each. They are directed tests because there is nothing to compare
// against, not because they are hard.

`timescale 1ns / 1ps

module core_insn_tb;

`include "rd68031_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] DATA = 32'h0000_2000;

  bit          reached;
  logic [15:0] got;
  int unsigned k;

  // UM 7.5.2 and PRM 4: a compare-and-swap holds RMC across every cycle of the
  // sequence, so that nothing else can get at the location in between. These
  // count the cycles that ran while it was asserted and the times it was let
  // go and taken again -- which must be never, within one instruction.
  // ------------------------------------------------------------------------
  // A breakpoint device -- UM 7.4.2. It watches for CPU space type 0, notes the
  // breakpoint number on A4-A2, and either answers with a replacement
  // instruction word or asserts BERR because it has none. A 16-bit port, so
  // the word arrives on D31-D16.
  // ------------------------------------------------------------------------
  logic [15:0] bkpt_word;
  bit          bkpt_answer;
  logic  [2:0] bkpt_num;
  int unsigned bkpt_cycles;
  initial begin
    bkpt_word = 16'h4E71; bkpt_answer = 1'b1; bkpt_num = 3'd0; bkpt_cycles = 0;
  end

  wire bkpt_now = !as_n_o && (fc_o === 3'b111) && (a_o[19:16] === 4'h0);

  always @(*) begin
    dsack_ext  = 2'b11;
    oe_ext     = 1'b0;
    d_ext      = 32'd0;
    berr_force = 1'b0;
    if (bkpt_now) begin
      if (bkpt_answer) begin
        dsack_ext = 2'b01;                 // DSACK1 alone: a 16-bit port
        oe_ext    = 1'b1;
        d_ext     = {bkpt_word, 16'd0};
      end else begin
        berr_force = 1'b1;
      end
    end
  end

  always @(posedge bkpt_now) begin
    bkpt_cycles = bkpt_cycles + 1;
    bkpt_num    = a_o[4:2];
  end

  int unsigned rmc_cycles, rmc_breaks;
  bit          rmc_seen;
  always @(negedge clk) if (rst_n) begin
    if (rmc_oe && !rmc_n_o) begin
      rmc_cycles = rmc_cycles + 1;
      rmc_seen   = 1'b1;
    end else if (rmc_seen) begin
      rmc_breaks = rmc_breaks + 1;
      rmc_seen   = 1'b0;
    end
  end

  // One CMP2 or CHK2: the bounds pair at DATA, the register loaded, and the
  // codes read back out of the status register.
  //
  // `xw` is the instruction's extension word -- bit 15 the register file, bits
  // 14-12 the register, bit 11 CHK2 rather than CMP2.
  task automatic cmp2_case(input logic [15:0] opw, input logic [15:0] xw,
                           input logic [31:0] lb, input logic [31:0] ub,
                           input logic [31:0] rn, input int unsigned nbytes,
                           input bit want_c, input bit want_z,
                           input string what);
    setup();
    // The bounds, lower first -- PRM 4, "the upper bound following the lower".
    case (nbytes)
      1: begin
        poke_w(DATA,     {lb[7:0], ub[7:0]});
      end
      2: begin
        poke_w(DATA,     lb[15:0]);
        poke_w(DATA + 2, ub[15:0]);
      end
      default: begin
        poke_l(DATA,     lb);
        poke_l(DATA + 4, ub);
      end
    endcase
    // MOVEA.L #DATA,A6 ; MOVE.L #rn,D1 or MOVEA.L #rn,A1 ; the instruction.
    poke_w(CODE + 0, 16'h2C7C);            // MOVEA.L #DATA,A6
    poke_l(CODE + 2, DATA);
    if (xw[15]) begin
      poke_w(CODE + 6, 16'h227C | ({13'd0, xw[14:12]} << 9)); // MOVEA.L #rn,An
    end else begin
      poke_w(CODE + 6, 16'h203C | ({13'd0, xw[14:12]} << 9)); // MOVE.L #rn,Dn
    end
    poke_l(CODE + 8, rn);
    poke_w(CODE + 12, opw | 16'h0016);     // ... <ea> = (A6)
    poke_w(CODE + 14, xw);
    poke_w(CODE + 16, 16'h60FE);           // BRA *
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, {what, ": the program finishes"});
    check(dut.u_seq.sr_q[0] === want_c, {what, ": C says in or out of bounds"});
    check(dut.u_seq.sr_q[2] === want_z, {what, ": Z says equal to a bound"});
  endtask

  task automatic setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1) poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
  endtask

  initial begin
    $display("core_insn_tb: instructions with no oracle");

    // ======================================================================
    // PACK -(A3),-(A2),#adj -- PRM 4.
    //
    // The case that needs no reasoning about diagrams: the two bytes of the
    // string "42" are $34 and $32, at increasing addresses, and packing them
    // has to give $42. Adjusting by -$3030 is what turns ASCII into BCD, and
    // it is the only thing the adjustment word is ever used for.
    // ======================================================================
    setup();
    poke_w(DATA, 16'h3432);                // "42", '4' at the lower address
    poke_w(DATA + 8, 16'h0000);            // and somewhere else to land
    poke_w(CODE + 0, 16'h247C);            // MOVEA.L #DATA+9,A2
    poke_l(CODE + 2, DATA + 9);
    poke_w(CODE + 6, 16'h267C);            // MOVEA.L #DATA+2,A3
    poke_l(CODE + 8, DATA + 2);
    poke_w(CODE + 12, 16'h854B);           // PACK -(A3),-(A2),#-$3030
    poke_w(CODE + 14, 16'hCFD0);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, "PACK: the program finishes");
    got = peek_w(DATA + 8);
    check(got[15:8] === 8'h42,
          "PACK: the digits of \"42\" pack into $42, in that order");
    check(dut.u_seq.areg[3] === DATA,
          "PACK: the source register stepped back two bytes");
    check(dut.u_seq.areg[2] === DATA + 8,
          "PACK: and the destination one byte");

    // ======================================================================
    // UNPK -(A3),-(A2),#adj -- the reverse, and the same question about which
    // byte is which. $42 unpacked and adjusted by +$3030 is the string "42",
    // with '4' at the lower address again.
    // ======================================================================
    setup();
    poke_w(DATA + 2, 16'h4200);            // the packed byte at DATA+2
    poke_w(DATA, 16'h0000);
    poke_w(CODE + 0, 16'h247C);            // MOVEA.L #DATA+2,A2
    poke_l(CODE + 2, DATA + 2);
    poke_w(CODE + 6, 16'h267C);            // MOVEA.L #DATA+3,A3
    poke_l(CODE + 8, DATA + 3);
    poke_w(CODE + 12, 16'h858B);           // UNPK -(A3),-(A2),#$3030
    poke_w(CODE + 14, 16'h3030);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, "UNPK: the program finishes");
    check(peek_w(DATA) === 16'h3432,
          "UNPK: $42 unpacks into \"42\", the significant digit first");
    check(dut.u_seq.areg[3] === DATA + 2,
          "UNPK: the source register stepped back one byte");
    check(dut.u_seq.areg[2] === DATA,
          "UNPK: and the destination two");


    // ======================================================================
    // CMP2 -- PRM 4. The manual asks for one instruction that serves both a
    // signed and an unsigned range, and doc/divergences.md works through why
    // no fixed-signedness comparison can. These are the cases that tell the
    // three candidate rules apart.
    //
    //                    op     xw     LB    UB    Rn   sz   C  Z
    // ======================================================================
    // A signed range, -16 to +16 at byte size.
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'h00, 1, 0, 0,
              "CMP2.B signed range, inside");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'hEF, 1, 1, 0,
              "CMP2.B signed range, below");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'h11, 1, 1, 0,
              "CMP2.B signed range, above");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'hF0, 1, 0, 1,
              "CMP2.B signed range, on the lower bound");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'h10, 1, 0, 1,
              "CMP2.B signed range, on the upper bound");

    // An unsigned range, 16 to 240. $80 is inside it and is negative, which is
    // the case a signed comparison gets wrong.
    cmp2_case(16'h00C0, 16'h1000, 32'h10, 32'hF0, 32'h80, 1, 0, 0,
              "CMP2.B unsigned range, inside and negative");
    cmp2_case(16'h00C0, 16'h1000, 32'h10, 32'hF0, 32'h00, 1, 1, 0,
              "CMP2.B unsigned range, below");
    cmp2_case(16'h00C0, 16'h1000, 32'h10, 32'hF0, 32'hFF, 1, 1, 0,
              "CMP2.B unsigned range, above");

    // "If the upper bound equals the lower bound, the valid range is a single
    // value."
    cmp2_case(16'h00C0, 16'h1000, 32'h42, 32'h42, 32'h42, 1, 0, 1,
              "CMP2.B one-value range, on it");
    cmp2_case(16'h00C0, 16'h1000, 32'h42, 32'h42, 32'h43, 1, 1, 0,
              "CMP2.B one-value range, off it");

    // Word and long, so that the size field and the two reads are exercised.
    cmp2_case(16'h02C0, 16'h1000, 32'hFFF0, 32'h0010, 32'h0000, 2, 0, 0,
              "CMP2.W signed range, inside");
    cmp2_case(16'h02C0, 16'h1000, 32'h0010, 32'hFFF0, 32'h8000, 2, 0, 0,
              "CMP2.W unsigned range, inside and negative");
    cmp2_case(16'h04C0, 16'h1000, 32'hFFFFFFF0, 32'h00000010, 32'h00000000,
              4, 0, 0, "CMP2.L signed range, inside");
    cmp2_case(16'h04C0, 16'h1000, 32'h00000010, 32'hFFFFFFF0, 32'h80000000,
              4, 0, 0, "CMP2.L unsigned range, inside and negative");

    // An address register with byte bounds: PRM 4 sign-extends the bounds to
    // thirty-two bits and compares them against the whole of An, so -8 is
    // inside [-16, +16] and $000000F8 is not.
    cmp2_case(16'h00C0, 16'h9000, 32'hF0, 32'h10, 32'hFFFFFFF8, 1, 0, 0,
              "CMP2.B into An, sign extended, inside");
    cmp2_case(16'h00C0, 16'h9000, 32'hF0, 32'h10, 32'h000000F8, 1, 1, 0,
              "CMP2.B into An, the same bits unextended, outside");

    // ... and only the low part of a data register is looked at.
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'hAABBCC00, 1, 0, 0,
              "CMP2.B into Dn looks only at the low byte");

    // ======================================================================
    // CHK2 is the same comparison with a trap on it -- PRM 4, vector 6.
    // ======================================================================
    setup();
    poke_l(32'h0000_0018, 32'h0000_0500);  // vector 6
    poke_w(32'h0000_0500, 16'h7A44);       // MOVEQ #$44,D5
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(DATA, 16'hF010);                // bounds -16 .. +16
    poke_w(CODE + 0, 16'h2C7C);            // MOVEA.L #DATA,A6
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h223C);            // MOVE.L #$EF,D1 -- one below
    poke_l(CODE + 8, 32'h0000_00EF);
    poke_w(CODE + 12, 16'h00D6);           // CHK2.B (A6),D1
    poke_w(CODE + 14, 16'h1800);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "CHK2: out of bounds traps to vector 6");
    check(dut.u_seq.dreg[5] === 32'h0000_0044, "CHK2: and the handler ran");

    setup();
    poke_l(32'h0000_0018, 32'h0000_0500);
    poke_w(32'h0000_0500, 16'h7A44);
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(DATA, 16'hF010);
    poke_w(CODE + 0, 16'h2C7C);
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h223C);            // MOVE.L #0,D1 -- inside
    poke_l(CODE + 8, 32'h0000_0000);
    poke_w(CODE + 12, 16'h00D6);
    poke_w(CODE + 14, 16'h1800);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, "CHK2: in bounds does not trap");
    check(dut.u_seq.dreg[5] === 32'h0000_0000, "CHK2: and the handler did not run");


    // ======================================================================
    // An address register stepped by (An)+ or -(An) holds an ADDRESS, and the
    // whole of it survives whatever the operand size is.
    //
    // PRM 2 sign-extends a word into an address register because the word is a
    // value; the address a postincrement leaves behind is not one. The two go
    // to the same register through the same microword field, and for two
    // milestones they went through the same sign-extending path -- which no
    // test noticed, because every address the sweep uses has the relevant bit
    // clear. These are chosen so that it is set.
    // ======================================================================
    setup();
    poke_w(32'h0000_8000, 16'h1234);
    poke_w(32'h0000_0080, 16'h5678);
    poke_w(CODE +  0, 16'h207C);           // MOVEA.L #$8000,A0
    poke_l(CODE +  2, 32'h0000_8000);
    poke_w(CODE +  6, 16'h227C);           // MOVEA.L #$0080,A1
    poke_l(CODE +  8, 32'h0000_0080);
    poke_w(CODE + 12, 16'h3018);           // MOVE.W (A0)+,D0
    poke_w(CODE + 14, 16'h1219);           // MOVE.B (A1)+,D1
    poke_w(CODE + 16, 16'h3420);           // MOVE.W -(A0),D2
    poke_w(CODE + 18, 16'h60FE);
    reset_dut();
    run_until(CODE + 18, 2000, reached);
    check(reached, "stepping: the program finishes");
    check(dut.u_seq.areg[0] === 32'h0000_8000,
          "stepping: (A0)+ then -(A0) at a word comes back to $00008000");
    check(dut.u_seq.areg[1] === 32'h0000_0081,
          "stepping: (A1)+ at a byte gives $00000081, not a sign extension");
    check(dut.u_seq.dreg[0][15:0] === 16'h1234, "stepping: and the word read");
    check(dut.u_seq.dreg[2][15:0] === 16'h1234, "stepping: ... and read back");


    // ======================================================================
    // CAS -- PRM 4. "Compares the effective address operand to the compare
    // operand (Dc). If the operands are equal, the instruction writes the
    // update operand (Du) to the effective address operand; otherwise, the
    // instruction writes the effective address operand to the compare operand
    // (Dc)."
    //
    // Both outcomes, and RMC held across the whole of each.
    // ======================================================================
    setup();
    poke_l(DATA, 32'h1234_5678);
    poke_w(CODE +  0, 16'h247C);           // MOVEA.L #DATA,A2
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h223C);           // MOVE.L #$12345678,D1  -- matches
    poke_l(CODE +  8, 32'h1234_5678);
    poke_w(CODE + 12, 16'h243C);           // MOVE.L #$AAAABBBB,D2  -- the update
    poke_l(CODE + 14, 32'hAAAA_BBBB);
    poke_w(CODE + 18, 16'h0ED2);           // CAS.L D1,D2,(A2)
    poke_w(CODE + 20, 16'h0081);           //   Du = D2, Dc = D1
    poke_w(CODE + 22, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 22, 2000, reached);
    check(reached, "CAS match: the program finishes");
    check(peek_l(DATA) === 32'hAAAA_BBBB,
          "CAS match: the update operand went to memory");
    check(dut.u_seq.dreg[1] === 32'h1234_5678,
          "CAS match: the compare register is untouched");
    check(dut.u_seq.sr_q[2] === 1'b1, "CAS match: Z says so");
    check(rmc_breaks <= 1,
          "CAS match: RMC was held across the read and the write, unbroken");
    check(rmc_cycles > 0, "CAS match: ... and it was asserted at all");

    setup();
    poke_l(DATA, 32'h1234_5678);
    poke_w(CODE +  0, 16'h247C);
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h223C);           // MOVE.L #$0BADC0DE,D1 -- differs
    poke_l(CODE +  8, 32'h0BAD_C0DE);
    poke_w(CODE + 12, 16'h243C);
    poke_l(CODE + 14, 32'hAAAA_BBBB);
    poke_w(CODE + 18, 16'h0ED2);           // CAS.L D1,D2,(A2)
    poke_w(CODE + 20, 16'h0081);
    poke_w(CODE + 22, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 22, 2000, reached);
    check(reached, "CAS miss: the program finishes");
    check(peek_l(DATA) === 32'h1234_5678,
          "CAS miss: memory is untouched");
    check(dut.u_seq.dreg[1] === 32'h1234_5678,
          "CAS miss: what memory held went into the compare register");
    check(dut.u_seq.sr_q[2] === 1'b0, "CAS miss: Z says so");
    check(rmc_breaks <= 1, "CAS miss: RMC was held and let go once");

    // ======================================================================
    // CAS2 -- PRM 4. Two locations at once, with the whole of it indivisible.
    // "If either comparison fails, the instruction writes the memory operands
    // (Rn1 and Rn2) to the compare operands (Dc1 and Dc2)" -- BOTH of them,
    // which is why both are read before either is compared.
    // ======================================================================
    setup();
    poke_l(DATA,      32'h1111_1111);
    poke_l(DATA + 8,  32'h2222_2222);
    poke_w(CODE +  0, 16'h247C);           // MOVEA.L #DATA,A2
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h267C);           // MOVEA.L #DATA+8,A3
    poke_l(CODE +  8, DATA + 8);
    poke_w(CODE + 12, 16'h203C);           // MOVE.L #$11111111,D0
    poke_l(CODE + 14, 32'h1111_1111);
    poke_w(CODE + 18, 16'h223C);           // MOVE.L #$22222222,D1
    poke_l(CODE + 20, 32'h2222_2222);
    poke_w(CODE + 24, 16'h243C);           // MOVE.L #$AAAA0001,D2
    poke_l(CODE + 26, 32'hAAAA_0001);
    poke_w(CODE + 30, 16'h263C);           // MOVE.L #$BBBB0002,D3
    poke_l(CODE + 32, 32'hBBBB_0002);
    poke_w(CODE + 36, 16'h0EFC);           // CAS2.L
    poke_w(CODE + 38, 16'hA080);           //   Rn1 = A2, Du1 = D2, Dc1 = D0
    poke_w(CODE + 40, 16'hB0C1);           //   Rn2 = A3, Du2 = D3, Dc2 = D1
    poke_w(CODE + 42, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 42, 3000, reached);
    check(reached, "CAS2 match: the program finishes");
    check(peek_l(DATA)     === 32'hAAAA_0001, "CAS2 match: the first update landed");
    check(peek_l(DATA + 8) === 32'hBBBB_0002, "CAS2 match: and the second");
    check(rmc_breaks <= 1,
          "CAS2 match: RMC was held across all four transfers, unbroken");

    // ... and with the SECOND comparison failing, so that both compare
    // registers are loaded although the first one matched.
    setup();
    poke_l(DATA,      32'h1111_1111);
    poke_l(DATA + 8,  32'h9999_9999);      // not what D1 holds
    poke_w(CODE +  0, 16'h247C);
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h267C);
    poke_l(CODE +  8, DATA + 8);
    poke_w(CODE + 12, 16'h203C);
    poke_l(CODE + 14, 32'h1111_1111);
    poke_w(CODE + 18, 16'h223C);
    poke_l(CODE + 20, 32'h2222_2222);
    poke_w(CODE + 24, 16'h243C);
    poke_l(CODE + 26, 32'hAAAA_0001);
    poke_w(CODE + 30, 16'h263C);
    poke_l(CODE + 32, 32'hBBBB_0002);
    poke_w(CODE + 36, 16'h0EFC);
    poke_w(CODE + 38, 16'hA080);
    poke_w(CODE + 40, 16'hB0C1);
    poke_w(CODE + 42, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 42, 3000, reached);
    check(reached, "CAS2 miss: the program finishes");
    check(peek_l(DATA)     === 32'h1111_1111, "CAS2 miss: neither location moved");
    check(peek_l(DATA + 8) === 32'h9999_9999, "CAS2 miss: ... nor the second");
    check(dut.u_seq.dreg[0] === 32'h1111_1111,
          "CAS2 miss: the first compare register took what memory held");
    check(dut.u_seq.dreg[1] === 32'h9999_9999,
          "CAS2 miss: and so did the second, though it was the one that failed");
    check(rmc_breaks <= 1, "CAS2 miss: RMC was held across both reads");


    // ======================================================================
    // BKPT -- UM 7.4.2. The device answers with an instruction, and that
    // instruction runs where the breakpoint was.
    // ======================================================================
    setup();
    poke_w(CODE + 0, 16'h7201);            // MOVEQ #1,D1
    poke_w(CODE + 2, 16'h484D);            // BKPT #5
    poke_w(CODE + 4, 16'h7403);            // MOVEQ #3,D2
    poke_w(CODE + 6, 16'h60FE);
    bkpt_word   = 16'h7C5A;                // MOVEQ #$5A,D6, in its place
    bkpt_answer = 1'b1;
    bkpt_cycles = 0;
    reset_dut();
    run_until(CODE + 6, 2000, reached);
    check(reached, "BKPT: the program carries on past it");
    check(bkpt_cycles == 1, "BKPT: one breakpoint acknowledge cycle");
    check(bkpt_num === 3'd5, "BKPT: with the breakpoint number on A4-A2");
    check(dut.u_seq.dreg[6] === 32'h0000_005A,
          "BKPT: the word the device supplied was executed");
    check(dut.u_seq.dreg[1] === 32'h0000_0001 && dut.u_seq.dreg[2] === 32'h0000_0003,
          "BKPT: and the instructions either side of it ran once each");

    // ... and with nobody to answer, an illegal instruction at the
    // breakpoint's own address.
    setup();
    poke_l(32'h0000_0010, 32'h0000_0500);  // vector 4
    poke_w(32'h0000_0500, 16'h7E77);       // MOVEQ #$77,D7
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(CODE + 0, 16'h4849);            // BKPT #1
    poke_w(CODE + 2, 16'h60FE);
    bkpt_answer = 1'b0;
    bkpt_cycles = 0;
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "BKPT, no answer: an illegal instruction exception");
    check(dut.u_seq.dreg[7] === 32'h0000_0077, "BKPT, no answer: the handler ran");
    check(peek_l(ISP0 - 6) === CODE,
          "BKPT, no answer: the frame points at the breakpoint itself");
    check(peek_w(ISP0 - 2) === 16'h0010,
          "BKPT, no answer: format $0, vector offset $010");
    bkpt_answer = 1'b1;


    // ======================================================================
    // CALLM and RTM: the MC68020's module calls, which the MC68030 does not
    // have. UM 8.1.5: an illegal instruction, vector 4, with the stacked
    // program counter at the instruction -- before any extension word or
    // operand is read. core_m030_tb has the same from a program.
    // ======================================================================
    setup();
    poke_l(32'h0000_0010, 32'h0000_0500);  // vector 4
    poke_w(32'h0000_0500, 16'h7E04);       // MOVEQ #4,D7
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(CODE + 0, 16'h06F9);            // CALLM #4,($3000).L
    poke_w(CODE + 2, 16'h0004);
    poke_l(CODE + 4, 32'h0000_3000);
    poke_w(CODE + 8, 16'h60FE);
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "CALLM: an illegal instruction on the MC68030");
    check(peek_l(ISP0 - 6) === CODE, "CALLM: the frame points at the CALLM");
    check(peek_w(ISP0 - 2) === 16'h0010, "CALLM: format $0, vector offset $010");
    check(dut.u_seq.isp_q === ISP0 - 8, "CALLM: a four-word frame and nothing else");

    setup();
    poke_l(32'h0000_0010, 32'h0000_0500);
    poke_w(32'h0000_0500, 16'h7E04);
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(CODE + 0, 16'h2A7C);            // MOVEA.L #$12345678,A5
    poke_l(CODE + 2, 32'h1234_5678);
    poke_w(CODE + 6, 16'h06CD);            // RTM A5
    poke_w(CODE + 8, 16'h60FE);
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "RTM: an illegal instruction on the MC68030");
    check(peek_l(ISP0 - 6) === CODE + 6, "RTM: the frame points at the RTM");
    check(dut.u_seq.areg[5] === 32'h1234_5678, "RTM: A5 untouched");

    // ======================================================================
    // The fast effective-address paths -- doc/timing-divergences.md. Each of
    // (An), (An)+, -(An) and (d16,An) as a MOVE source and destination and
    // under the read-modify-write forms, and A7 stepping by two at byte size.
    // ======================================================================
    setup();
    poke_l(DATA + 0, 32'h1111_1111);
    poke_l(DATA + 4, 32'h2222_2222);
    poke_l(DATA + 16, 32'h0);
    poke_l(DATA + 20, 32'hFFFF_FFFF);
    poke_w(CODE + 0, 16'h207C);            // MOVEA.L #DATA,A0
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h227C);            // MOVEA.L #DATA+16,A1
    poke_l(CODE + 8, DATA + 16);
    poke_w(CODE + 12, 16'h22D8);           // MOVE.L (A0)+,(A1)+
    poke_w(CODE + 14, 16'h22D8);           // MOVE.L (A0)+,(A1)+
    poke_w(CODE + 16, 16'h1F3C);           // MOVE.B #$5A,-(A7)
    poke_w(CODE + 18, 16'h005A);
    poke_w(CODE + 20, 16'h161F);           // MOVE.B (A7)+,D3
    poke_w(CODE + 22, 16'h42A1);           // CLR.L -(A1)
    poke_w(CODE + 24, 16'h5699);           // ADDQ.L #3,(A1)+
    poke_w(CODE + 26, 16'h4AA1);           // TST.L -(A1)
    poke_w(CODE + 28, 16'h3129);           // MOVE.W (2,A1),-(A0)
    poke_w(CODE + 30, 16'h0002);
    poke_w(CODE + 32, 16'h0C69);           // CMPI.W #3,(2,A1)
    poke_w(CODE + 34, 16'h0003);
    poke_w(CODE + 36, 16'h0002);
    poke_w(CODE + 38, 16'h60FE);
    reset_dut();
    run_until(CODE + 38, 2000, reached);
    check(reached, "fast EA: the program finishes");
    check(peek_l(DATA + 16) === 32'h1111_1111, "fast EA: MOVE.L (A0)+,(A1)+, first");
    check(peek_l(DATA + 20) === 32'h0000_0003,
          "fast EA: the second, cleared by CLR -(A1) and ADDQ #3 into (A1)+");
    got = peek_w(ISP0 - 2);
    check(got[15:8] === 8'h5A,
          "fast EA: MOVE.B to -(A7) wrote the byte at the even address");
    check(dut.u_seq.dreg[3][7:0] === 8'h5A, "fast EA: and (A7)+ read it back");
    check(dut.u_seq.isp_q === ISP0, "fast EA: A7 stepped by two each way");
    check(dut.u_seq.areg[1] === DATA + 20, "fast EA: A1 after (A1)+ and -(A1)");
    check(dut.u_seq.areg[0] === DATA + 6, "fast EA: A0 after two (A0)+ and -(A0)");
    check(peek_l(DATA + 4) === 32'h2222_0003,
          "fast EA: MOVE.W (d16,A1),-(A0) moved the word");
    check(dut.u_seq.sr_q[2] === 1'b1, "fast EA: CMPI.W #3,(d16,A1) found it equal");

    // ======================================================================
    // M6: what the instruction-level oracles found (doc/m6-mismatches.md), each
    // checked from the manual where an oracle flow covers it thinly or not at
    // all. doc/bugs-found.md has the story of each.
    // ======================================================================

    // ---- A1: CAS and CAS2 write a failed compare at the operand size -----
    // PRM 4, CAS: "Destination -> Compare Operand"; UM 2.2.1, a byte or word
    // operation changes only the low-order part of a data register.
    setup();
    poke_w(DATA, 16'h1900);                // the byte at DATA is $19
    poke_w(DATA + 4, 16'hAACA);            // the word at DATA+4
    poke_w(CODE + 0, 16'h227C);            // MOVEA.L #DATA,A1
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h243C);            // MOVE.L #$3E05A9F4,D2
    poke_l(CODE + 8, 32'h3E05_A9F4);
    poke_w(CODE + 12, 16'h0AD1);           // CAS.B D2,D5,(A1)
    poke_w(CODE + 14, 16'h0142);
    poke_w(CODE + 16, 16'h2C02);           // MOVE.L D2,D6
    poke_w(CODE + 18, 16'h243C);           // MOVE.L #$40848A01,D2
    poke_l(CODE + 20, 32'h4084_8A01);
    poke_w(CODE + 24, 16'h5889);           // ADDQ.L #4,A1
    poke_w(CODE + 26, 16'h0CD1);           // CAS.W D2,D5,(A1)
    poke_w(CODE + 28, 16'h0142);
    poke_w(CODE + 30, 16'h60FE);
    reset_dut();
    run_until(CODE + 30, 2000, reached);
    check(reached, "CAS: the program finishes");
    check(dut.u_seq.dreg[6] === 32'h3E05_A919,
          "CAS.B: a failed compare replaces only the low byte of Dc (PRM 4, UM 2.2.1)");
    check(dut.u_seq.dreg[2] === 32'h4084_AACA,
          "CAS.W: a failed compare replaces only the low word of Dc");

    setup();
    poke_w(DATA, 16'hFFAD);
    poke_w(DATA + 4, 16'h5678);
    poke_w(CODE + 0, 16'h227C);            // MOVEA.L #DATA,A1
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h247C);            // MOVEA.L #DATA+4,A2
    poke_l(CODE + 8, DATA + 4);
    poke_w(CODE + 12, 16'h243C);           // MOVE.L #$C3000000,D2
    poke_l(CODE + 14, 32'hC300_0000);
    poke_w(CODE + 18, 16'h263C);           // MOVE.L #$12340000,D3
    poke_l(CODE + 20, 32'h1234_0000);
    poke_w(CODE + 24, 16'h0CFC);           // CAS2.W D2:D3,D4:D5,(A1):(A2)
    poke_w(CODE + 26, 16'h9102);
    poke_w(CODE + 28, 16'hA143);
    poke_w(CODE + 30, 16'h60FE);
    reset_dut();
    run_until(CODE + 30, 2000, reached);
    check(reached, "CAS2.W: the program finishes");
    check(dut.u_seq.dreg[2] === 32'hC300_FFAD && dut.u_seq.dreg[3] === 32'h1234_5678,
          "CAS2.W: both compare registers keep their upper words (PRM 4)");

    // ---- A2: BFFFO adds the whole offset, register or memory --------------
    // PRM 4, BFFFO: "the bit offset in the instruction plus the offset of the
    // first one bit", with a register offset of -2^31 to 2^31-1.
    setup();
    poke_w(CODE + 0, 16'h203C);            // MOVE.L #37,D0
    poke_l(CODE + 2, 32'd37);
    poke_w(CODE + 6, 16'h223C);            // MOVE.L #$04000000,D1 (bit offset 5)
    poke_l(CODE + 8, 32'h0400_0000);
    poke_w(CODE + 12, 16'hEDC1);           // BFFFO D1{D0:4},D2
    poke_w(CODE + 14, 16'h2804);
    poke_w(CODE + 16, 16'h203C);           // MOVE.L #-27,D0 (also 5 modulo 32)
    poke_l(CODE + 18, 32'hFFFF_FFE5);
    poke_w(CODE + 22, 16'hEDC1);           // BFFFO D1{D0:4},D3
    poke_w(CODE + 24, 16'h3804);
    poke_w(CODE + 26, 16'h7200);           // MOVEQ #0,D1
    poke_w(CODE + 28, 16'hEDC1);           // BFFFO D1{D0:4},D4 -- no one bit
    poke_w(CODE + 30, 16'h4804);
    poke_w(CODE + 32, 16'h60FE);
    reset_dut();
    run_until(CODE + 32, 2000, reached);
    check(reached, "BFFFO: the program finishes");
    check(dut.u_seq.dreg[2] === 32'd37, "BFFFO Dn{37:4}: the offset is not reduced modulo 32");
    check(dut.u_seq.dreg[3] === 32'hFFFF_FFE5, "BFFFO Dn{-27:4}: nor is a negative one");
    check(dut.u_seq.dreg[4] === 32'hFFFF_FFE9,
          "BFFFO, no bit set: the offset plus the width");

    // ---- A3: CMP2 and the read-only bit fields read (d16,PC) in program
    // space -- UM 2.4.11, "a program space reference".
    setup();
    poke_w(DATA, 16'h1020);                // CMP2.B bounds $10..$20
    poke_w(DATA + 8, 16'h8000);
    poke_w(CODE + 0, 16'h243C);            // MOVE.L #$15,D2
    poke_l(CODE + 2, 32'h0000_0015);
    poke_w(CODE + 6, 16'h00FA);            // CMP2.B (d16,PC),D2
    poke_w(CODE + 8, 16'h2000);
    poke_w(CODE + 10, 16'(DATA - (CODE + 10)));
    poke_w(CODE + 12, 16'hE8FA);           // BFTST (d16,PC){0:8}
    poke_w(CODE + 14, 16'h0008);
    poke_w(CODE + 16, 16'(DATA + 8 - (CODE + 16)));
    poke_w(CODE + 18, 16'h60FE);
    reset_dut();
    nacc = 0;
    run_until(CODE + 18, 2000, reached);
    check(reached, "PC-relative CMP2 and BFTST: the program finishes");
    k = 0;
    for (int i = 0; i < nacc && i < MAXACC; i++)
      if ((acc_addr[i] == DATA || acc_addr[i] == DATA + 1 || acc_addr[i] == DATA + 8)
          && acc_rw[i]) begin
        k = k + 1;
        check(acc_prog[i], $sformatf("PC-relative read at %08h is in program space (UM 2.4.11)",
                                     acc_addr[i]));
      end
    check(k == 3, "PC-relative CMP2 and BFTST: two bound reads and one field read");

    // ---- A4: MOVEM to -(An) with An in the list stores An less the size --
    // PRM 4, MOVEM: "the value written is the initial register value
    // decremented by the size of the operation" on the MC68020 and MC68030.
    setup();
    poke_w(CODE + 0, 16'h267C);            // MOVEA.L #DATA+$100,A3
    poke_l(CODE + 2, DATA + 32'h100);
    poke_w(CODE + 6, 16'h48E3);            // MOVEM.L D0-A7,-(A3)
    poke_w(CODE + 8, 16'hFFFF);
    poke_w(CODE + 10, 16'h267C);           // MOVEA.L #DATA+$200,A3
    poke_l(CODE + 12, DATA + 32'h200);
    poke_w(CODE + 16, 16'h48A3);           // MOVEM.W D0-A7,-(A3)
    poke_w(CODE + 18, 16'hFFFF);
    poke_w(CODE + 20, 16'h60FE);
    reset_dut();
    run_until(CODE + 20, 4000, reached);
    check(reached, "MOVEM -(An): the program finishes");
    check(peek_l(DATA + 32'hEC) === DATA + 32'hFC,
          "MOVEM.L D0-A7,-(A3): A3 is stored as its initial value less four (PRM 4)");
    check(peek_w(DATA + 32'h1F6) === 16'(DATA + 32'h1FE),
          "MOVEM.W D0-A7,-(A3): A3 is stored as its initial value less two");
    check(dut.u_seq.areg[3] === DATA + 32'h1E0, "MOVEM.W -(A3): A3 left on the last word");

    // ---- A5: a zero divide clears C -- PRM 4, DIVU: "C -- Always cleared"
    setup();
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$2719,SR -- X, N and C set
    poke_w(CODE + 2, 16'h2719);
    poke_w(CODE + 4, 16'h82FC);            // DIVU.W #0,D1
    poke_w(CODE + 6, 16'h0000);
    poke_w(CODE + 8, 16'h60FE);
    reset_dut();
    run_until(32'h0000_9000, 2000, reached);
    check(reached, "DIVU #0: the zero divide is taken");
    check(peek_w(ISP0 - 6) === 16'h2014, "DIVU #0: format $2, vector 5");
    got = peek_w(ISP0 - 12);
    check(got[0] === 1'b0, "DIVU #0: the stacked SR has C clear (PRM 4)");
    check(got[4] === 1'b1, "DIVU #0: and X as it was");

    // ---- A6: the A7 byte rule belongs to whichever register is A7 ---------
    // UM 2.4.4 and 2.4.5: a byte through the stack pointer steps it by two.
    setup();
    poke_w(CODE + 0, 16'h2C7C);            // MOVEA.L #DATA+$10,A6
    poke_l(CODE + 2, DATA + 32'h10);
    poke_w(CODE + 6, 16'hCF0E);            // ABCD -(A6),-(A7)
    poke_w(CODE + 8, 16'h3C0E);            // MOVE.W A6,D6
    poke_w(CODE + 10, 16'h3E0F);           // MOVE.W A7,D7
    poke_w(CODE + 12, 16'hDD0F);           // ADDX.B -(A7),-(A6)
    poke_w(CODE + 14, 16'h3A0E);           // MOVE.W A6,D5
    poke_w(CODE + 16, 16'h380F);           // MOVE.W A7,D4
    poke_w(CODE + 18, 16'hBD0F);           // CMPM.B (A7)+,(A6)+
    poke_w(CODE + 20, 16'h8F0F);           // SBCD -(A7),-(A7)
    poke_w(CODE + 22, 16'hBF0E);           // CMPM.B (A6)+,(A7)+
    poke_w(CODE + 24, 16'h60FE);
    reset_dut();
    run_until(CODE + 24, 2000, reached);
    check(reached, "A7 byte rule: the program finishes");
    check(dut.u_seq.dreg[6][15:0] === 16'(DATA + 32'hF) && dut.u_seq.dreg[7][15:0] === 16'(ISP0 - 2),
          "ABCD -(A6),-(A7): A6 down one, A7 down two");
    check(dut.u_seq.dreg[5][15:0] === 16'(DATA + 32'hE) && dut.u_seq.dreg[4][15:0] === 16'(ISP0 - 4),
          "ADDX.B -(A7),-(A6): A7 down two, A6 down one");
    check(dut.u_seq.areg[6] === DATA + 32'h10 && dut.u_seq.isp_q === ISP0 - 4,
          "CMPM.B both ways and SBCD -(A7),-(A7): each register by its own rule");

    // ---- A7: BTST Dn,#<data> -- PRM 4, BTST: #<data> is a legal operand ----
    setup();
    poke_w(CODE + 0, 16'h7202);            // MOVEQ #2,D1
    poke_w(CODE + 2, 16'h033C);            // BTST D1,#$A5 -- bit 2 is one
    poke_w(CODE + 4, 16'h00A5);
    poke_w(CODE + 6, 16'h57C3);            // SEQ D3
    poke_w(CODE + 8, 16'h7209);            // MOVEQ #9,D1 -- bit 9 mod 8 = 1, zero
    poke_w(CODE + 10, 16'h033C);           // BTST D1,#$A5
    poke_w(CODE + 12, 16'h00A5);
    poke_w(CODE + 14, 16'h57C4);           // SEQ D4
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, "BTST Dn,#imm: executes, no illegal instruction");
    check(dut.u_seq.dreg[3][7:0] === 8'h00, "BTST Dn,#imm: bit 2 of $A5 is one");
    check(dut.u_seq.dreg[4][7:0] === 8'hFF, "BTST Dn,#imm: the number is modulo 8");

    // ---- A8: cpSAVE and cpRESTORE are privileged before anything else ------
    // UM 10.2.3.3 and 10.2.3.4: in user mode, a privilege violation without
    // accessing the coprocessor interface -- and so whether or not there is one.
    for (int w = 0; w < 2; w++) begin
      setup();
      poke_l(32'h0000_0020, 32'h0000_0500); // vector 8
      poke_w(32'h0000_0500, 16'h7E08);      // MOVEQ #8,D7
      poke_w(32'h0000_0502, 16'h60FE);
      poke_w(CODE + 0, 16'h207C);           // MOVEA.L #DATA+$40,A0
      poke_l(CODE + 2, DATA + 32'h40);
      poke_w(CODE + 6, 16'h4E60);           // MOVE A0,USP
      poke_w(CODE + 8, 16'h46FC);           // MOVE #$0000,SR -- user mode
      poke_w(CODE + 10, 16'h0000);
      poke_w(CODE + 12, w ? 16'hF527 : 16'hF557); // cpSAVE -(A7) / cpRESTORE (A7)
      poke_w(CODE + 14, 16'h60FE);
      reset_dut();
      run_until(32'h0000_0502, 2000, reached);
      check(reached, w ? "cpSAVE, user mode: a privilege violation"
                       : "cpRESTORE, user mode: a privilege violation");
      check(peek_l(ISP0 - 6) === CODE + 12 && peek_w(ISP0 - 2) === 16'h0020,
            "cpSAVE/cpRESTORE, user mode: format $0, vector 8, at the instruction");
      check(dut.u_seq.usp_q === DATA + 32'h40, "cpSAVE/cpRESTORE, user mode: A7 untouched");
    end

    // ---- A9: an effective address the instruction does not have is refused
    // at decode -- UM 8.1.5 -- before any operand is touched.
    setup();
    poke_l(32'h0000_0010, 32'h0000_0500); // vector 4
    poke_w(32'h0000_0500, 16'h7E04);
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(CODE + 0, 16'h247C);            // MOVEA.L #DATA,A2
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h1BDA);            // MOVE.B (A2)+,<111/101>
    poke_w(CODE + 8, 16'h60FE);
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "MOVE.B to destination 111/101: an illegal instruction");
    check(peek_l(ISP0 - 6) === CODE + 6, "MOVE.B to 111/101: the frame points at it");
    check(dut.u_seq.areg[2] === DATA, "MOVE.B to 111/101: (A2)+ was never evaluated");

    setup();
    poke_l(32'h0000_0010, 32'h0000_0500);
    poke_w(32'h0000_0500, 16'h7E04);
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(CODE + 0, 16'hBF3B);            // EOR.B D7,(d8,PC,Xn)
    poke_w(CODE + 2, 16'h0000);
    poke_w(CODE + 4, 16'h60FE);
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "EOR.B D7,(d8,PC,Xn): an illegal instruction, not a write");
    check(peek_l(ISP0 - 6) === CODE, "EOR to a PC-relative destination: at the instruction");

    setup();
    poke_l(32'h0000_0010, 32'h0000_0500);
    poke_w(32'h0000_0500, 16'h7E04);
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(CODE + 0, 16'h1240);            // "MOVEA.B D0,A1" -- PRM 4 has none
    poke_w(CODE + 2, 16'h60FE);
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "MOVE.B to An: an illegal instruction");

    // ... and the encodings whose mode the instruction does not have at all:
    // -(An) for a bit field (control modes only, PRM 4), (An)+ for LEA (PRM 4:
    // control), and An as a byte operand of ADDQ and ADD (PRM 4: word and long
    // only). Each an illegal instruction with the register untouched.
    for (int w = 0; w < 4; w++) begin
      setup();
      poke_l(32'h0000_0010, 32'h0000_0500);
      poke_w(32'h0000_0500, 16'h7E04);
      poke_w(32'h0000_0502, 16'h60FE);
      poke_w(CODE + 0, 16'h267C);          // MOVEA.L #DATA+$10,A3
      poke_l(CODE + 2, DATA + 32'h10);
      case (w)
        0: poke_w(CODE + 6, 16'hECE3);     // BFCLR -(A3){..}
        1: poke_w(CODE + 6, 16'h41DB);     // LEA (A3)+,A0
        2: poke_w(CODE + 6, 16'h520B);     // ADDQ.B #1,A3
        default: poke_w(CODE + 6, 16'hD00B); // ADD.B A3,D0
      endcase
      poke_w(CODE + 8, 16'h0000);
      poke_w(CODE + 10, 16'h60FE);
      reset_dut();
      run_until(32'h0000_0502, 2000, reached);
      check(reached && peek_l(ISP0 - 6) === CODE + 6 && dut.u_seq.areg[3] === DATA + 32'h10,
            $sformatf("illegal mode %0d (BFCLR -(An), LEA (An)+, ADDQ.B An, ADD.B An): vector 4, An untouched", w));
    end

    // ---- CAS2 with Dc1 = Dc2: PRM 4, "memory operand 1 is stored" ---------
    setup();
    poke_l(DATA, 32'h1111_1111);
    poke_l(DATA + 4, 32'h2222_2222);
    poke_w(CODE + 0, 16'h227C);            // MOVEA.L #DATA,A1
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h247C);            // MOVEA.L #DATA+4,A2
    poke_l(CODE + 8, DATA + 4);
    poke_w(CODE + 12, 16'h7600);           // MOVEQ #0,D3
    poke_w(CODE + 14, 16'h0EFC);           // CAS2.L D3:D3,D4:D5,(A1):(A2)
    poke_w(CODE + 16, 16'h9103);
    poke_w(CODE + 18, 16'hA143);
    poke_w(CODE + 20, 16'h60FE);
    reset_dut();
    run_until(CODE + 20, 2000, reached);
    check(reached && dut.u_seq.dreg[3] === 32'h1111_1111,
          "CAS2.L with Dc1 = Dc2, failed: the register holds memory operand 1 (PRM 4)");

    // ---- A10: a status register write that sets T1 traces the NEXT one ---
    // UM 8.1.7: the trace mode is the one in force when an instruction starts.
    // T1 T0 = 11 is "undefined, reserved" (UM table 8-3); this core takes it as
    // 10, which is what the cputest corpus records the part doing.
    for (int w = 0; w < 2; w++) begin
      setup();
      poke_l(32'h0000_0024, 32'h0000_0500); // vector 9
      poke_w(32'h0000_0500, 16'h60FE);
      poke_w(CODE + 0, 16'h007C);           // ORI #$8000 / #$C000,SR
      poke_w(CODE + 2, w ? 16'hC000 : 16'h8000);
      poke_w(CODE + 4, 16'h7001);           // MOVEQ #1,D0 -- not a change of flow
      poke_w(CODE + 6, 16'h7002);           // MOVEQ #2,D0
      poke_w(CODE + 8, 16'h60FE);
      reset_dut();
      run_until(32'h0000_0500, 2000, reached);
      check(reached, w ? "ORI #$C000,SR: the next instruction is traced"
                       : "ORI #$8000,SR: the next instruction is traced");
      check(dut.u_seq.dreg[0] === 32'd1, "ORI to SR, T1: traced after the MOVEQ, not before");
      check(peek_w(ISP0 - 6) === 16'h2024 && peek_l(ISP0 - 10) === CODE + 6
            && peek_l(ISP0 - 4) === CODE + 4,
            "ORI to SR, T1: format $2 trace frame, next PC and the MOVEQ's address");
    end

    // ---- A11: CHK2.B through A7 reads its bounds at A7 and A7+1 -----------
    // PRM 4, CHK2: the bounds pair, lower first, at consecutive operand-sized
    // locations; the A7 byte rule is for (A7)+ and -(A7) alone (UM 2.4.4-5).
    for (int w = 0; w < 2; w++) begin
      setup();
      poke_l(32'h0000_0018, 32'h0000_0500); // vector 6
      poke_w(32'h0000_0500, 16'h60FE);
      poke_w(CODE + 0, 16'h2E7C);           // MOVEA.L #DATA+$80,A7
      poke_l(CODE + 2, DATA + 32'h80);
      poke_w(DATA + 32'h80, 16'h314F);      // bounds $31 .. $4F
      poke_w(DATA + 32'h82, 16'h7400);      // what A7+2 holds
      poke_w(CODE + 6, w ? 16'h7040 : 16'h706A); // MOVEQ #$40 / #$6A,D0
      poke_w(CODE + 8, 16'h00D7);           // CHK2.B (A7),D0
      poke_w(CODE + 10, 16'h0800);
      poke_w(CODE + 12, 16'h60FE);
      reset_dut();
      run_until(w ? CODE + 12 : 32'h0000_0500, 2000, reached);
      check(reached, w ? "CHK2.B (A7),D0: $40 is inside $31..$4F, no trap"
                       : "CHK2.B (A7),D0: $6A is above $4F, vector 6");
    end

    // ---- Q2 and Q3: LINK A7 and UNLK A7 -----------------------------------
    // PRM 4, LINK: "SP - 4 -> SP; An -> (SP)" -- the decremented value goes
    // out. UNLK: "loads the address register with the long word pulled from the
    // top of the stack" -- for A7, A7 is that long word. doc/manual-
    // contradictions.md entries 15 and 16.
    setup();
    poke_l(DATA + 32'h20, 32'h0000_3000);
    poke_w(CODE + 0, 16'h2E7C);            // MOVEA.L #DATA+$40,A7
    poke_l(CODE + 2, DATA + 32'h40);
    poke_w(CODE + 6, 16'h4E57);            // LINK.W A7,#-8
    poke_w(CODE + 8, 16'hFFF8);
    poke_w(CODE + 10, 16'h2C0F);           // MOVE.L A7,D6
    poke_w(CODE + 12, 16'h2E7C);           // MOVEA.L #DATA+$20,A7
    poke_l(CODE + 14, DATA + 32'h20);
    poke_w(CODE + 18, 16'h4E5F);           // UNLK A7
    poke_w(CODE + 20, 16'h60FE);
    reset_dut();
    run_until(CODE + 20, 2000, reached);
    check(reached, "LINK A7, UNLK A7: the program finishes");
    check(peek_l(DATA + 32'h3C) === DATA + 32'h3C,
          "LINK.W A7: pushes the stack pointer after the decrement (PRM 4 operation)");
    check(dut.u_seq.dreg[6] === DATA + 32'h34, "LINK.W A7,#-8: A7 is the push less eight");
    check(dut.u_seq.isp_q === 32'h0000_3000,
          "UNLK A7: A7 is the long word pulled from the stack (PRM 4 description)");


    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_insn_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_insn_tb");
    else                               $display("FAIL: core_insn_tb");
    $finish;
  end

endmodule
