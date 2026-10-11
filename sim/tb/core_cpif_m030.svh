// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the coprocessor interface on the MC68030: M12.
//
// Included by core_cpif_tb.sv, inside the module, after its own tasks. The
// interface the MC68020 had is tested above it; this is what the MC68030 adds
// around the same protocol, and the corners of UM section 10 that the M13 tests
// of RD68021 left out:
//
//   - the CIR cycles terminated synchronously, with STERM (UM 10.1.4.2), and
//     never asking for a burst (UM 10.1.4.3: "the MC68030 never requests a
//     burst operation during a coprocessor (CPU space) bus cycle");
//   - the data cache enabled: "nor does it internally cache data read or
//     written during coprocessor (CPU space) bus cycles", while the operands
//     a primitive moves to and from memory are ordinary data accesses;
//   - the MMU enabled: a CPU-space address "is immediately used as a physical
//     address without translation" (UM 9.2.1, figure 9-8), so no TTx matches
//     it and CIOUT is negated for it, while the operands a primitive moves are
//     translated -- and fault, with the long frame, and are resumed by RTE;
//   - a trace on change of flow, which does not hold the dialogue open the way
//     a trace on instruction execution does (UM 10.5.2.5);
//   - busy after a breakpoint acknowledge supplied the instruction (UM 10.4.3);
//   - the cpSAVE and cpRESTORE format words the M13 tests did not reach.
//
// `+m030_only` on the simulator's command line runs these alone.

  // ------------------------------------------------------------------------
  // What the bus does around the coprocessor: CPU-space type $2 cycles, and
  // memory cycles, sampled on every rising edge AS is asserted on.
  // ------------------------------------------------------------------------
  int unsigned cir_ticks, cir_ciout, cir_cbreq, cir_sterm;
  int unsigned mem_ciout, mem_cbreq;
  int unsigned refused;      // memory cycles to a page the test says is refused

  always @(posedge clk) begin
    if (rst_n && !as_n_o) begin
      if (fc_o === 3'b111 && a_o[19:16] === 4'h2) begin
        cir_ticks = cir_ticks + 1;
        if (!ciout_n_o && ciout_oe) cir_ciout = cir_ciout + 1;
        if (!cbreq_n_o && cbreq_oe) cir_cbreq = cir_cbreq + 1;
        if (!sterm_n_i)             cir_sterm = cir_sterm + 1;
      end else if (fc_o !== 3'b111) begin
        if (!ciout_n_o && ciout_oe) mem_ciout = mem_ciout + 1;
        if (!cbreq_n_o && cbreq_oe) mem_cbreq = mem_cbreq + 1;
      end
    end
  end

  task automatic bus_counts_clear();
    cir_ticks = 0; cir_ciout = 0; cir_cbreq = 0; cir_sterm = 0;
    mem_ciout = 0; mem_cbreq = 0; refused = 0;
  endtask

  // ------------------------------------------------------------------------
  // A breakpoint acknowledge responder -- UM 7.4.2: CPU space type 0, answered
  // with DSACK and an instruction word on D31-D16.
  // ------------------------------------------------------------------------
  logic [15:0] bkpt_word;
  bit          bkpt_on;
  int unsigned bkpts;
  initial begin bkpt_on = 1'b0; bkpts = 0; bkpt_word = 16'h4E71; end
  wire bkpt_now = bkpt_on && rst_n && !as_n_o && (fc_o === 3'b111)
               && (a_o[19:16] === 4'h0);
  always @(posedge clk) begin
    if (bkpt_on) begin
      dsack_ext <= bkpt_now ? 2'b00 : 2'b11;
      d_ext     <= {bkpt_word, 16'h0000};
      oe_ext    <= bkpt_now && rw_o;
    end
  end
  always @(negedge bkpt_now) bkpts = bkpts + 1;

  // ------------------------------------------------------------------------
  // Translation tables -- UM 9.5, three levels of short descriptors and 4K
  // pages, as core_mmu_paging_tb has them: TIA = 4, TIB = 8, TIC = 8. Level A
  // entry 0 points at a level-B table whose entry 0 points at the page table;
  // everything else is an early termination page descriptor mapping its block
  // onto itself. The page table maps the low 1M onto itself except:
  //
  //   page $8   onto physical $C000      a mapped page that is not identity
  //   page $9   invalid                  until the pager maps it onto $D000
  //   page $A   invalid                  until the pager maps it onto $E000
  //   pages $20-$2F  invalid             where CPU space type $2 would land if
  //                                      it were translated: $0002_0000 up
  // ------------------------------------------------------------------------
  localparam logic [31:0] TBL_A  = 32'h0000_4000;
  localparam logic [31:0] TBL_B  = 32'h0000_4100;
  localparam logic [31:0] TBL_C  = 32'h0000_4800;
  localparam logic [31:0] RP_IMG = 32'h0000_4C00;
  localparam logic [31:0] TC_IMG = 32'h0000_4C08;
  localparam logic [31:0] TT_IMG = 32'h0000_4C0C;
  localparam logic [31:0] TC_VAL = 32'h80C0_4880;   // E, PS 4K, TIA 4, TIB 8, TIC 8
  localparam logic [31:0] PAGER  = 32'h0000_7100;

  // The pager: a write of a fault address to PAGER maps its page, $9 onto
  // $D000 and $A onto $E000, and keeps a copy of the frame the handler had.
  int unsigned pages_mapped;
  logic [31:0] pg_frame;
  logic [15:0] pg_fmt, pg_ssw, pg_cprim;
  logic [31:0] pg_dfa;
  bit          pager_on;
  initial begin pager_on = 1'b0; pages_mapped = 0; end
  always @(negedge as_n_o) begin
    if (pager_on && rst_n && !rw_o && (a_o & ~32'd3) == PAGER
        && fc_o !== 3'b111) begin
      pg_frame = dut.u_seq.isp_q;
      pg_fmt   = peek_w(pg_frame + 32'h06);
      pg_ssw   = peek_w(pg_frame + 32'h0A);
      pg_dfa   = peek_l(pg_frame + 32'h10);
      pg_cprim = peek_w(pg_frame + 32'h4A);
      poke_l(TBL_C + 4 * pg_dfa[19:12], ((pg_dfa[19:12] + 32'd4) << 12) | 32'h1);
      pages_mapped = pages_mapped + 1;
    end
  end
  // No cycle may reach a page the tables refuse: the MMU aborts the access
  // before AS (UM 9.2.1).
  always @(negedge as_n_o) begin
    if (pager_on && rst_n && fc_o !== 3'b111
        && (a_o[31:12] == 20'h00009 || a_o[31:12] == 20'h0000A)
        && pages_mapped == 0)
      refused = refused + 1;
  end

  task automatic mmu_setup();
    int unsigned v;
    for (v = 0; v < 16; v = v + 1)
      poke_l(TBL_A + 4 * v, (v << 28) | 32'h1);
    poke_l(TBL_A, TBL_B | 32'h2);
    poke_l(TBL_B, TBL_C | 32'h2);
    for (v = 1; v < 256; v = v + 1)
      poke_l(TBL_B + 4 * v, (v << 20) | 32'h1);
    for (v = 0; v < 256; v = v + 1)
      poke_l(TBL_C + 4 * v, (v << 12) | 32'h1);
    poke_l(TBL_C + 4 * 8,  32'h0000_C001);
    poke_l(TBL_C + 4 * 9,  32'h0000_0000);
    poke_l(TBL_C + 4 * 10, 32'h0000_0000);
    for (v = 32'h20; v < 32'h30; v = v + 1)
      poke_l(TBL_C + 4 * v, 32'h0000_0000);
    poke_l(RP_IMG,     32'h7FFF_0002);    // no limit, DT = 2: the level-A table
    poke_l(RP_IMG + 4, TBL_A);
    poke_l(TC_IMG,     TC_VAL);
    // The program's first two instructions: PMOVE (RP_IMG).W,CRP and
    // PMOVE (TC_IMG).W,TC.
    poke_w(CODE + 0,  16'hF038); poke_w(CODE + 2,  16'h4C00);
    poke_w(CODE + 4,  RP_IMG[15:0]);
    poke_w(CODE + 6,  16'hF038); poke_w(CODE + 8,  16'h4000);
    poke_w(CODE + 10, TC_IMG[15:0]);
    pages_mapped = 0;
  endtask

  // MOVE.L #v,D7 and MOVEC D7,CACR at `at`: six bytes and four.
  task automatic put_cacr(input logic [31:0] at, input logic [31:0] v);
    poke_w(at + 0, 16'h2E3C);
    poke_l(at + 2, v);
    poke_w(at + 6, 16'h4E7B);
    poke_w(at + 8, 16'h7002);
  endtask

  task automatic m030_tests();
    logic [31:0] body;

    // ======================================================================
    // The MMU on, and the operands a primitive moves translated -- UM 9.2.1.
    // A CPU-space cycle is not: the tables refuse every page CPU space type
    // $2 would land in, and nothing faults. Eight bytes from (A0) in page $8,
    // which is physical $C000; four to (A1) there; an evaluated address
    // handed over as the LOGICAL address and written through translation; a
    // coprocessor-supplied address read through translation.
    // ======================================================================
    base_setup();
    mmu_setup();
    bus_counts_clear();
    body = CODE + 12;
    poke_w(body + 0,  16'hF210);           // cpGEN (A0)
    poke_w(body + 2,  16'h0101);
    poke_w(body + 4,  16'hF211);           // cpGEN (A1)
    poke_w(body + 6,  16'h0102);
    poke_w(body + 8,  16'hF212);           // cpGEN (A2)
    poke_w(body + 10, 16'h0103);
    poke_w(body + 12, 16'h60FE);
    poke_l(32'h0000_CFF0, 32'h1122_3344);  // what (A0) translates to
    poke_l(32'h0000_CFF4, 32'h5566_7788);
    poke_l(32'h0000_8FF0, 32'hDEAD_DEAD);  // ... and not this
    poke_l(32'h0000_8FF4, 32'hDEAD_DEAD);
    poke_l(32'h0000_C300, 32'hA0A1_A2A3);  // the coprocessor's own address
    poke_l(32'h0000_8100, 32'h0000_0000);
    poke_l(32'h0000_C100, 32'h0000_0000);
    poke_l(32'h0000_C200, 32'h0000_0000);
    cp.push_resp(16'h9708);                // CA, DR=0, any <ea>, 8 bytes
    cp.push_resp(16'h0802);
    cp.push_resp(16'hB704);                // CA, DR=1, any <ea>, 4 bytes
    cp.push_resp(16'h0802);
    cp.push_resp(16'h8A00);                // CA, evaluate and transfer <ea>
    cp.push_resp(16'hA004);                // CA, write 4 bytes there
    cp.push_resp(16'h8504);                // CA, take address, 4 bytes in
    cp.push_resp(16'h0802);
    cp.push_opnd(32'hFACE_B00C);
    cp.push_opnd(32'h600D_F00D);
    cp.push_oadr(32'h0000_8300);
    reset_dut();
    dut.u_seq.areg[0] = 32'h0000_8FF0;
    dut.u_seq.areg[1] = 32'h0000_8100;
    dut.u_seq.areg[2] = 32'h0000_8200;
    run_until(body + 12, 6000, reached);
    check(reached, "MMU: the three instructions end -- no CIR cycle was translated");
    check(dut.u_seq.isp_q === ISP0, "MMU: and no exception was taken");
    check(peek_l(32'h0000_C100) === 32'hFACE_B00C,
          "MMU: the coprocessor's operand went to the physical page");
    check(peek_l(32'h0000_8100) === 32'h0000_0000, "MMU: ... and not to the logical address");
    check(peek_l(32'h0000_C200) === 32'h600D_F00D,
          "MMU: the write to the previously evaluated address is translated");
    expect_cir(1'b0, R_CMD, 2, 32'h0101, "MMU");
    expect_cir(1'b1, R_RESP, 2, 32'h9708, "MMU");
    expect_cir(1'b0, R_OPND, 4, 32'h1122_3344, "MMU: from physical $CFF0");
    expect_cir(1'b0, R_OPND, 4, 32'h5566_7788, "MMU: from physical $CFF4");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "MMU");
    expect_cir(1'b0, R_CMD, 2, 32'h0102, "MMU");
    expect_cir(1'b1, R_RESP, 2, 32'hB704, "MMU");
    expect_cir(1'b1, R_OPND, 4, 32'hFACE_B00C, "MMU: to (A1)");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "MMU");
    expect_cir(1'b0, R_CMD, 2, 32'h0103, "MMU");
    expect_cir(1'b1, R_RESP, 2, 32'h8A00, "MMU");
    expect_cir(1'b0, R_OADR, 4, 32'h0000_8200,
               "MMU: the evaluated address is the logical one -- UM 10.4.8");
    expect_cir(1'b1, R_RESP, 2, 32'hA004, "MMU");
    expect_cir(1'b1, R_OPND, 4, 32'h600D_F00D, "MMU: written to the previous <ea>");
    expect_cir(1'b1, R_RESP, 2, 32'h8504, "MMU");
    expect_cir(1'b1, R_OADR, 4, 32'h0000_8300, "MMU: the coprocessor's address");
    expect_cir(1'b0, R_OPND, 4, 32'hA0A1_A2A3, "MMU: read from physical $C300");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "MMU");
    expect_end("MMU");
    check(cir_ticks > 0 && cir_ciout == 0, "MMU: CIOUT negated on every CIR cycle");

    // ======================================================================
    // An operand a primitive moves faults on a page the MMU refuses -- UM
    // 10.5.2.8, 9.5.2 -- and RTE resumes the primitive at the faulted access.
    // Twelve bytes from (A0) = $8FF8: two long words in page $8, the third in
    // page $9, which is invalid. The handler hands +$10 to the pager, flushes
    // the ATC, and returns. Then eight bytes to -(A1) = $A008: the register
    // steps once, to $A000, in page $A, and the first long word's write is
    // refused there.
    // ======================================================================
    base_setup();
    mmu_setup();
    bus_counts_clear();
    pager_on = 1'b1;
    body = CODE + 12;
    poke_l(32'h0000_0008, HAND);           // vector 2, bus error
    poke_w(HAND + 0,  16'h21EF);           // MOVE.L ($10,A7),(PAGER).W
    poke_w(HAND + 2,  16'h0010);
    poke_w(HAND + 4,  PAGER[15:0]);
    poke_w(HAND + 6,  16'hF000);           // PFLUSHA
    poke_w(HAND + 8,  16'h2400);
    poke_w(HAND + 10, 16'h4E73);           // RTE
    poke_w(body + 0,  16'hF210);           // cpGEN (A0)
    poke_w(body + 2,  16'h0201);
    poke_w(body + 4,  16'hF221);           // cpGEN -(A1)
    poke_w(body + 6,  16'h0202);
    poke_w(body + 8,  16'h60FE);
    poke_l(32'h0000_CFF8, 32'h0102_0304);
    poke_l(32'h0000_CFFC, 32'h0506_0708);
    poke_l(32'h0000_D000, 32'h090A_0B0C);
    poke_l(32'h0000_E000, 32'h0000_0000);
    poke_l(32'h0000_E004, 32'h0000_0000);
    cp.push_resp(16'h970C);                // CA, DR=0, any <ea>, 12 bytes
    cp.push_resp(16'h0802);
    cp.push_resp(16'hB708);                // CA, DR=1, any <ea>, 8 bytes
    cp.push_resp(16'h0802);
    cp.push_opnd(32'hC1C2_C3C4);
    cp.push_opnd(32'hD1D2_D3D4);
    reset_dut();
    dut.u_seq.areg[0] = 32'h0000_8FF8;
    dut.u_seq.areg[1] = 32'h0000_A008;
    run_until(HAND, 6000, reached);
    check(reached, "MMU fault, read: the bus error handler runs");
    run_until(HAND + 6, 6000, reached);
    check(pages_mapped == 1, "MMU fault, read: the handler called the pager");
    check(pg_fmt === 16'hB008, "MMU fault, read: the long frame, vector 2 -- UM 8.2.1");
    check(pg_dfa === 32'h0000_9000, "MMU fault, read: +$10 the refused address");
    check(pg_ssw[8] === 1'b1 && pg_ssw[6] === 1'b1,
          "MMU fault, read: DF and RW set in the special status word -- UM 8.2.1");
    check(pg_cprim === 16'h970C,
          "MMU fault, read: +$4A the primitive being served -- doc/checkpoint.md");
    run_until(HAND, 6000, reached);
    check(reached, "MMU fault, write: the bus error handler runs again");
    run_until(HAND + 6, 6000, reached);
    check(pages_mapped == 2, "MMU fault, write: the handler called the pager");
    check(pg_dfa === 32'h0000_A000, "MMU fault, write: +$10 the refused address");
    check(pg_ssw[8] === 1'b1 && pg_ssw[6] === 1'b0,
          "MMU fault, write: DF set and RW clear");
    check(pg_cprim === 16'hB708, "MMU fault, write: +$4A the primitive");
    run_until(body + 8, 6000, reached);
    check(reached, "MMU fault: RTE resumed both, and they end");
    check(refused == 0, "MMU fault: no cycle reached a refused page");
    check(dut.u_seq.areg[0] === 32'h0000_8FF8, "MMU fault: (A0) left A0 alone");
    check(dut.u_seq.areg[1] === 32'h0000_A000,
          "MMU fault: -(A1) stepped A1 once, not again when resumed");
    check(peek_l(32'h0000_E000) === 32'hC1C2_C3C4 && peek_l(32'h0000_E004) === 32'hD1D2_D3D4,
          "MMU fault: the eight bytes in the page the pager mapped");
    check(dut.u_seq.isp_q === ISP0, "MMU fault: both frames came off");
    expect_cir(1'b0, R_CMD, 2, 32'h0201, "MMU fault");
    expect_cir(1'b1, R_RESP, 2, 32'h970C, "MMU fault");
    expect_cir(1'b0, R_OPND, 4, 32'h0102_0304, "MMU fault: first, once");
    expect_cir(1'b0, R_OPND, 4, 32'h0506_0708, "MMU fault: second, once");
    expect_cir(1'b0, R_OPND, 4, 32'h090A_0B0C, "MMU fault: third, after the pager");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "MMU fault");
    expect_cir(1'b0, R_CMD, 2, 32'h0202, "MMU fault, write");
    expect_cir(1'b1, R_RESP, 2, 32'hB708, "MMU fault, write");
    expect_cir(1'b1, R_OPND, 4, 32'hC1C2_C3C4, "MMU fault, write: first, once");
    expect_cir(1'b1, R_OPND, 4, 32'hD1D2_D3D4, "MMU fault, write: second, once");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "MMU fault, write");
    expect_end("MMU fault");
    pager_on = 1'b0;

    // ======================================================================
    // A transparent translation register with CI set, matching every function
    // code and every address -- UM 9.3. Every memory cycle is cache inhibited
    // and says so on CIOUT; a CPU-space cycle matches no TTx and is never
    // translated, so CIOUT stays negated on every CIR cycle (figure 9-8:
    // "PA <- LA, CIOUT <- 0").
    // ======================================================================
    base_setup();
    bus_counts_clear();
    poke_l(TT_IMG, 32'h00FF_8507);         // E, CI, RWM, FC base 0 mask 7
    poke_w(CODE + 0,  16'hF038);           // PMOVE (TT_IMG).W,TT0
    poke_w(CODE + 2,  16'h0800);
    poke_w(CODE + 4,  TT_IMG[15:0]);
    poke_w(CODE + 6,  16'hF210);           // cpGEN (A0)
    poke_w(CODE + 8,  16'h0301);
    poke_w(CODE + 10, 16'h60FE);
    poke_l(DATA, 32'h7172_7374);
    cp.push_resp(16'h9704);                // CA, DR=0, 4 bytes from (A0)
    cp.push_resp(16'h8C03);                // CA, D3 to the coprocessor
    cp.push_resp(16'hAC05);                // CA, the coprocessor to D5
    cp.push_resp(16'h0802);
    cp.push_opnd(32'h1357_2468);
    reset_dut();
    dut.u_seq.areg[0] = DATA;
    dut.u_seq.dreg[3] = 32'h3333_3333;
    run_until(CODE + 10, 4000, reached);
    check(reached, "TT0 with CI: the instruction ends");
    check(dut.u_seq.dreg[5] === 32'h1357_2468, "TT0 with CI: D5 loaded");
    expect_cir(1'b0, R_CMD, 2, 32'h0301, "TT0 with CI");
    expect_cir(1'b1, R_RESP, 2, 32'h9704, "TT0 with CI");
    expect_cir(1'b0, R_OPND, 4, 32'h7172_7374, "TT0 with CI");
    expect_cir(1'b1, R_RESP, 2, 32'h8C03, "TT0 with CI");
    expect_cir(1'b0, R_OPND, 4, 32'h3333_3333, "TT0 with CI");
    expect_cir(1'b1, R_RESP, 2, 32'hAC05, "TT0 with CI");
    expect_cir(1'b1, R_OPND, 4, 32'h1357_2468, "TT0 with CI");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "TT0 with CI");
    expect_end("TT0 with CI");
    check(mem_ciout > 0, "TT0 with CI: memory cycles assert CIOUT -- UM 9.3");
    check(cir_ticks > 0 && cir_ciout == 0,
          "TT0 with CI: no CIR cycle asserts CIOUT -- UM 9.2.1, CPU space");

    // ======================================================================
    // The data cache on, with burst fills and write allocation -- UM 6.1.2:
    // "the data cache stores data references to any address space except CPU
    // space". The operands are in the synchronous burst port.
    //
    //   a line of it is read into the cache;
    //   the coprocessor writes four bytes there: write-through updates the
    //     cached long word, which a MOVE then reads back;
    //   the operand CIR is read twice, for two registers: two bus cycles, two
    //     values -- neither cached;
    //   sixteen bytes go from (A2) to the coprocessor: ordinary data reads.
    //
    // No CIR cycle asks for a burst, though the operand CIR is a long-word
    // aligned read in a cachable space if CPU space were one.
    // ======================================================================
    base_setup();
    bus_counts_clear();
    put_cacr(CODE + 0, 32'h0000_3111);     // WA, DBE, ED, IBE, EI
    poke_w(CODE + 10, 16'h2610);           // MOVE.L (A0),D3: the line comes in
    poke_w(CODE + 12, 16'hF210);           // cpGEN (A0)
    poke_w(CODE + 14, 16'h0401);
    poke_w(CODE + 16, 16'h2810);           // MOVE.L (A0),D4: from the cache
    poke_w(CODE + 18, 16'hF200);           // cpGEN
    poke_w(CODE + 20, 16'h0402);
    poke_w(CODE + 22, 16'hF212);           // cpGEN (A2)
    poke_w(CODE + 24, 16'h0403);
    poke_w(CODE + 26, 16'h60FE);
    poke_l(32'h3000_0100, 32'h0123_4567);
    poke_l(32'h3000_0104, 32'h89AB_CDEF);
    poke_l(32'h3000_0200, 32'hB0B1_B2B3);
    poke_l(32'h3000_0204, 32'hB4B5_B6B7);
    poke_l(32'h3000_0208, 32'hB8B9_BABB);
    poke_l(32'h3000_020C, 32'hBCBD_BEBF);
    cp.push_resp(16'hB704);                // CA, DR=1, 4 bytes to (A0)
    cp.push_resp(16'h0802);
    cp.push_resp(16'hAC01);                // CA, the coprocessor to D1
    cp.push_resp(16'hAC02);                // CA, the coprocessor to D2
    cp.push_resp(16'h0802);
    cp.push_resp(16'h9710);                // CA, DR=0, 16 bytes from (A2)
    cp.push_resp(16'h0802);
    cp.push_opnd(32'h5566_7788);
    cp.push_opnd(32'h1111_1111);
    cp.push_opnd(32'h2222_2222);
    reset_dut();
    dut.u_seq.areg[0] = 32'h3000_0100;
    dut.u_seq.areg[2] = 32'h3000_0200;
    run_until(CODE + 26, 6000, reached);
    check(reached, "data cache: the program ends");
    check(dut.u_seq.dreg[3] === 32'h0123_4567, "data cache: the line was read");
    check(dut.u_seq.dreg[4] === 32'h5566_7788,
          "data cache: the coprocessor's write reached the cached long word");
    check(peek_l(32'h3000_0100) === 32'h5566_7788, "data cache: ... and memory");
    check(dut.u_seq.dreg[1] === 32'h1111_1111 && dut.u_seq.dreg[2] === 32'h2222_2222,
          "data cache: the operand CIR read twice, two values -- CPU space not cached");
    expect_cir(1'b0, R_CMD, 2, 32'h0401, "data cache");
    expect_cir(1'b1, R_RESP, 2, 32'hB704, "data cache");
    expect_cir(1'b1, R_OPND, 4, 32'h5566_7788, "data cache");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "data cache");
    expect_cir(1'b0, R_CMD, 2, 32'h0402, "data cache");
    expect_cir(1'b1, R_RESP, 2, 32'hAC01, "data cache");
    expect_cir(1'b1, R_OPND, 4, 32'h1111_1111, "data cache: the operand CIR, once");
    expect_cir(1'b1, R_RESP, 2, 32'hAC02, "data cache: the response CIR, again");
    expect_cir(1'b1, R_OPND, 4, 32'h2222_2222, "data cache: the operand CIR, again");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "data cache");
    expect_cir(1'b0, R_CMD, 2, 32'h0403, "data cache");
    expect_cir(1'b1, R_RESP, 2, 32'h9710, "data cache");
    expect_cir(1'b0, R_OPND, 4, 32'hB0B1_B2B3, "data cache: (A2)");
    expect_cir(1'b0, R_OPND, 4, 32'hB4B5_B6B7, "data cache: (A2)+4");
    expect_cir(1'b0, R_OPND, 4, 32'hB8B9_BABB, "data cache: (A2)+8");
    expect_cir(1'b0, R_OPND, 4, 32'hBCBD_BEBF, "data cache: (A2)+12");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "data cache");
    expect_end("data cache");
    check(mem_cbreq > 0, "data cache: memory reads asked for bursts -- DBE is on");
    check(cir_ticks > 0 && cir_cbreq == 0 && cp.cbreq_seen == 0,
          "data cache: no CIR cycle asked for a burst -- UM 10.1.4.3");

    // ======================================================================
    // Synchronous CIR cycles -- UM 10.1.4.2: the coprocessor ends every cycle
    // with STERM and never with DSACK, so a processor that did not take STERM
    // on a CPU-space cycle would wait for ever. The data cache with bursts on
    // as above: no CIR cycle, now on a port that could burst, asks for one.
    // The register moves of the first test, the operand moves of the third,
    // and a cpSAVE and a cpRESTORE.
    // ======================================================================
    base_setup();
    bus_counts_clear();
    cp.sync = 1'b1;
    put_cacr(CODE + 0, 32'h0000_3111);
    poke_w(CODE + 10, 16'hF200);           // cpGEN
    poke_w(CODE + 12, 16'h1234);
    poke_w(CODE + 14, 16'hF210);           // cpGEN (A0)
    poke_w(CODE + 16, 16'h0001);
    poke_w(CODE + 18, 16'hF221);           // cpGEN -(A1)
    poke_w(CODE + 20, 16'h0002);
    poke_w(CODE + 22, 16'hF320);           // cpSAVE -(A0)
    poke_w(CODE + 24, 16'hF35B);           // cpRESTORE (A3)+
    poke_w(CODE + 26, 16'h60FE);
    poke_l(DATA + 0, 32'h0102_0304);
    poke_l(DATA + 4, 32'h0506_0708);
    poke_l(DATA + 8, 32'h090A_0B0C);
    poke_l(DATA + 32'h80, 32'h1804_0000);  // a frame to restore
    poke_l(DATA + 32'h84, 32'h4444_4444);
    cp.push_resp(16'h8C03);                // CA, D3 to the coprocessor
    cp.push_resp(16'hAC0A);                // CA, the coprocessor to A2
    cp.push_resp(16'h0802);
    cp.push_resp(16'h970C);                // CA, 12 bytes from (A0)
    cp.push_resp(16'h0802);
    cp.push_resp(16'hB70A);                // CA, 10 bytes to -(A1)
    cp.push_resp(16'h0802);
    cp.push_opnd(32'hCAFE_F00D);
    cp.push_opnd(32'hA1A2_A3A4);
    cp.push_opnd(32'hB1B2_B3B4);
    cp.push_opnd(32'hC1C2_0000);
    cp.push_save(16'h1804);                // four bytes of state
    cp.push_opnd(32'h3535_3535);
    reset_dut();
    dut.u_seq.dreg[3] = 32'h1122_3344;
    dut.u_seq.areg[0] = DATA;
    dut.u_seq.areg[1] = DATA + 32'h40;
    dut.u_seq.areg[3] = DATA + 32'h80;
    run_until(CODE + 26, 6000, reached);
    check(reached, "STERM: the program ends");
    check(dut.u_seq.areg[2] === 32'hCAFE_F00D, "STERM: A2 loaded");
    check(dut.u_seq.areg[1] === DATA + 32'h36, "STERM: -(A1) stepped back by ten");
    check(peek_l(DATA + 32'h36) === 32'hA1A2_A3A4 && peek_l(DATA + 32'h3A) === 32'hB1B2_B3B4
          && peek_w(DATA + 32'h3E) === 16'hC1C2, "STERM: the ten bytes");
    check(dut.u_seq.areg[0] === DATA - 32'd8, "STERM: cpSAVE -(A0) down by eight");
    check(peek_l(DATA - 32'd8) === 32'h1804_0000 && peek_l(DATA - 32'd4) === 32'h3535_3535,
          "STERM: the saved frame");
    check(dut.u_seq.areg[3] === DATA + 32'h88, "STERM: cpRESTORE (A3)+ past the frame");
    expect_cir(1'b0, R_CMD, 2, 32'h1234, "STERM");
    expect_cir(1'b1, R_RESP, 2, 32'h8C03, "STERM");
    expect_cir(1'b0, R_OPND, 4, 32'h1122_3344, "STERM: D3 out");
    expect_cir(1'b1, R_RESP, 2, 32'hAC0A, "STERM");
    expect_cir(1'b1, R_OPND, 4, 32'hCAFE_F00D, "STERM: A2 in");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "STERM");
    expect_cir(1'b0, R_CMD, 2, 32'h0001, "STERM");
    expect_cir(1'b1, R_RESP, 2, 32'h970C, "STERM");
    expect_cir(1'b0, R_OPND, 4, 32'h0102_0304, "STERM: first");
    expect_cir(1'b0, R_OPND, 4, 32'h0506_0708, "STERM: second");
    expect_cir(1'b0, R_OPND, 4, 32'h090A_0B0C, "STERM: third");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "STERM");
    expect_cir(1'b0, R_CMD, 2, 32'h0002, "STERM");
    expect_cir(1'b1, R_RESP, 2, 32'hB70A, "STERM");
    expect_cir(1'b1, R_OPND, 4, 32'hA1A2_A3A4, "STERM: first out");
    expect_cir(1'b1, R_OPND, 4, 32'hB1B2_B3B4, "STERM: second out");
    expect_cir(1'b1, R_OPND, 2, 32'h0000_C1C2, "STERM: the tail");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "STERM");
    expect_cir(1'b1, R_SAVE, 2, 32'h1804, "STERM: cpSAVE");
    expect_cir(1'b1, R_OPND, 4, 32'h3535_3535, "STERM: cpSAVE's state");
    expect_cir(1'b0, R_REST, 2, 32'h1804, "STERM: cpRESTORE");
    expect_cir(1'b1, R_REST, 2, 32'h1804, "STERM: cpRESTORE's answer");
    expect_cir(1'b0, R_OPND, 4, 32'h4444_4444, "STERM: cpRESTORE's state");
    expect_end("STERM");
    check(cir_sterm > 0, "STERM: the CIR cycles were ended by STERM");
    check(cir_cbreq == 0 && cp.cbreq_seen == 0, "STERM: and none asked for a burst");
    cp.sync = 1'b0;

    // ======================================================================
    // A trace on change of flow does not hold the dialogue -- UM 10.5.2.5.
    // T1 T0 = 01; the coprocessor transfers the status register in (DR = 1),
    // which makes the trace pending, then answers null with CA and PF clear:
    // the processor releases, with no third read of the response CIR, and
    // takes the trace -- "it is possible that the coprocessor is still
    // executing the cpGEN instruction concurrently when the main processor
    // begins execution of the trace exception handler".
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0024, HAND);           // vector 9
    poke_w(CODE + 0,  16'h46FC);           // MOVE #$6700,SR: trace on change of flow
    poke_w(CODE + 2,  16'h6700);
    poke_w(CODE + 4,  16'hF200);
    poke_w(CODE + 6,  16'h0E01);
    poke_w(CODE + 8,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'hA200);                // CA, DR=1: the status register in
    cp.push_resp(16'h0800);                // null, CA clear, PF clear
    cp.push_opnd(32'h6704_0000);           // T0 kept, Z set
    reset_dut();
    run_until(HAND, 4000, reached);
    check(reached, "trace on flow: the trace is taken");
    base = ISP0 - 32'hC;
    check(peek_w(base + 6) === 16'h2024, "trace on flow: format $2, vector 9");
    check(peek_w(base + 0) === 16'h6704, "trace on flow: the status register the coprocessor gave");
    check(peek_l(base + 2) === CODE + 8, "trace on flow: +$02 the next instruction");
    check(peek_l(base + 8) === CODE + 4, "trace on flow: +$08 the coprocessor instruction");
    expect_cir(1'b0, R_CMD, 2, 32'h0E01, "trace on flow");
    expect_cir(1'b1, R_RESP, 2, 32'hA200, "trace on flow");
    expect_cir(1'b1, R_OPND, 2, 32'h0000_6704, "trace on flow: the status register");
    expect_cir(1'b1, R_RESP, 2, 32'h0800, "trace on flow: not finished, and released");
    expect_end("trace on flow");

    // ... and with the flow left alone, a dialogue under T1 T0 = 01 is not
    // traced at all.
    base_setup();
    poke_l(32'h0000_0024, HAND);
    poke_w(CODE + 0,  16'h46FC);
    poke_w(CODE + 2,  16'h6700);
    poke_w(CODE + 4,  16'hF200);
    poke_w(CODE + 6,  16'h0E02);
    poke_w(CODE + 8,  16'h7203);           // MOVEQ #3,D1
    poke_w(CODE + 10, 16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h8C00);                // CA, D0 out
    cp.push_resp(16'h0800);                // not finished, and released
    reset_dut();
    run_until(CODE + 10, 4000, reached);
    check(reached && dut.u_seq.dreg[1] === 32'h0000_0003,
          "trace on flow, no change: not traced");
    expect_cir(1'b0, R_CMD, 2, 32'h0E02, "trace on flow, no change");
    expect_cir(1'b1, R_RESP, 2, 32'h8C00, "trace on flow, no change");
    expect_cir(1'b0, R_OPND, 4, 32'h0000_0000, "trace on flow, no change");
    expect_cir(1'b1, R_RESP, 2, 32'h0800, "trace on flow, no change: released");
    expect_end("trace on flow, no change");

    // ======================================================================
    // Busy after a breakpoint acknowledge supplied the instruction -- UM
    // 10.4.3. With no interrupt pending the instruction is started again
    // from the word the acknowledge gave, and the acknowledge is not run
    // again; with one pending, it is serviced with the four-word frame and
    // "the processor re-executes the breakpoint acknowledge cycle".
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'h4848);           // BKPT #0, standing for a cpGEN
    poke_w(CODE + 2,  16'h0F01);           // ... whose command word follows
    poke_w(CODE + 4,  16'h60FE);
    bkpt_word = 16'hF200;
    bkpt_on   = 1'b1;
    bkpts     = 0;
    cp.push_resp(16'hA400);                // busy
    cp.push_resp(16'h0802);
    reset_dut();
    run_until(CODE + 4, 4000, reached);
    check(reached, "busy after BKPT: the instruction ends");
    check(bkpts == 1, $sformatf("busy after BKPT, no interrupt: one acknowledge (%0d)", bkpts));
    expect_cir(1'b0, R_CMD, 2, 32'h0F01, "busy after BKPT");
    expect_cir(1'b1, R_RESP, 2, 32'hA400, "busy after BKPT");
    expect_cir(1'b0, R_CMD, 2, 32'h0F01, "busy after BKPT: started again");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "busy after BKPT");
    expect_end("busy after BKPT");

    base_setup();
    poke_l(32'h0000_0074, HAND);           // level 5 autovector
    poke_w(CODE + 0,  16'h46FC);           // MOVE #$2000,SR
    poke_w(CODE + 2,  16'h2000);
    poke_w(CODE + 4,  16'h4848);           // BKPT #0, standing for a cpGEN
    poke_w(CODE + 6,  16'h0F02);
    poke_w(CODE + 8,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);
    bkpts = 0;
    cp.push_resp(16'hA400);                // busy
    cp.push_resp(16'h0802);
    reset_dut();
    iacks = 0;
    wait (cp.log_n == 1);
    ipl_n_i = ~3'd5;
    run_until(CODE + 8, 4000, reached);
    check(reached && iacks == 1, "busy after BKPT, interrupt: serviced, and the instruction ends");
    check(bkpts == 2, $sformatf("busy after BKPT, interrupt: the acknowledge again (%0d)", bkpts));
    check(peek_l(ISP0 - 8 + 2) === CODE + 4,
          "busy after BKPT, interrupt: the frame has the breakpoint's address");
    expect_cir(1'b0, R_CMD, 2, 32'h0F02, "busy after BKPT, interrupt");
    expect_cir(1'b1, R_RESP, 2, 32'hA400, "busy after BKPT, interrupt");
    expect_cir(1'b0, R_CMD, 2, 32'h0F02, "busy after BKPT, interrupt: started again");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "busy after BKPT, interrupt");
    expect_end("busy after BKPT, interrupt");
    bkpt_on   = 1'b0;
    dsack_ext = 2'b11;
    oe_ext    = 1'b0;

    // Busy in a conditional instruction -- UM 10.4.3, "this primitive applies
    // to instructions in the general and conditional categories".
    base_setup();
    poke_w(CODE + 0,  16'hF281);           // cpBcc.W
    poke_w(CODE + 2,  16'h0010);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(CODE + 18, 16'h60FE);
    cp.push_resp(16'hA400);                // busy
    cp.push_resp(16'h0801);                // true
    reset_dut();
    run_until(CODE + 18, 4000, reached);
    check(reached, "busy in cpBcc: restarted, and taken");
    expect_cir(1'b0, R_COND, 2, 32'hF281, "busy in cpBcc");
    expect_cir(1'b1, R_RESP, 2, 32'hA400, "busy in cpBcc");
    expect_cir(1'b0, R_COND, 2, 32'hF281, "busy in cpBcc: started again");
    expect_cir(1'b1, R_RESP, 2, 32'h0801, "busy in cpBcc");
    expect_end("busy in cpBcc");

    // ======================================================================
    // cpSAVE's format words -- UM 10.2.3.2.3, 10.5.1.5, 10.5.2.7: the invalid
    // format word, a reserved code ("the MC68030 interprets the reserved format
    // codes ($03-$0F) as invalid format words"), and a valid one whose length
    // is not a multiple of four. Each: the abort mask, then the format error
    // with the four-word frame at the cpSAVE.
    // ======================================================================
    for (n = 0; n < 3; n = n + 1) begin
      base_setup();
      poke_l(32'h0000_0038, HAND);         // vector 14
      poke_w(CODE + 0, 16'hF310);          // cpSAVE (A0)
      poke_w(CODE + 2, 16'h60FE);
      poke_w(HAND + 0, 16'h60FE);
      poke_l(DATA, 32'h5A5A_5A5A);
      cp.push_save((n == 0) ? 16'h0200 : (n == 1) ? 16'h0500 : 16'h1806);
      reset_dut();
      dut.u_seq.areg[0] = DATA;
      run_until(HAND, 3000, reached);
      check(reached, $sformatf("cpSAVE format %0d: the format error", n));
      check(peek_w(ISP0 - 8 + 6) === 16'h0038 && peek_l(ISP0 - 8 + 2) === CODE,
            $sformatf("cpSAVE format %0d: four words, the cpSAVE's address", n));
      check(peek_l(DATA) === 32'h5A5A_5A5A, $sformatf("cpSAVE format %0d: nothing stored", n));
      expect_cir(1'b1, R_SAVE, 2, (n == 0) ? 32'h0200 : (n == 1) ? 32'h0500 : 32'h1806,
                 "cpSAVE format");
      expect_cir(1'b0, R_CTRL, 2, 32'h0001, "cpSAVE format: abort");
      expect_end("cpSAVE format");
    end

    // cpRESTORE: not ready read from the restore CIR -- UM 10.2.3.2.2, "it
    // reads the restore CIR again without servicing any pending interrupts".
    // An interrupt raised after the first access waits for the instruction.
    base_setup();
    poke_l(32'h0000_0074, HAND);           // level 5 autovector
    poke_w(CODE + 0,  16'h46FC);           // MOVE #$2000,SR
    poke_w(CODE + 2,  16'h2000);
    poke_w(CODE + 4,  16'hF350);           // cpRESTORE (A0)
    poke_w(CODE + 6,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    poke_l(DATA + 0, 32'h1804_0000);
    poke_l(DATA + 4, 32'h6666_6666);
    cp.push_rest(16'h0100);                // not ready
    cp.push_rest(16'h0100);                // not ready
    cp.push_rest(16'h1804);
    reset_dut();
    dut.u_seq.areg[0] = DATA;
    iacks = 0;
    wait (cp.log_n == 1);
    ipl_n_i = ~3'd5;
    run_until(HAND, 4000, reached);
    check(reached, "cpRESTORE not ready: the interrupt is taken, after it");
    check(peek_l(ISP0 - 8 + 2) === CODE + 6, "cpRESTORE not ready: the frame has the next instruction");
    expect_cir(1'b0, R_REST, 2, 32'h1804, "cpRESTORE not ready");
    expect_cir(1'b1, R_REST, 2, 32'h0100, "cpRESTORE not ready");
    expect_cir(1'b1, R_REST, 2, 32'h0100, "cpRESTORE not ready: again, at once");
    expect_cir(1'b1, R_REST, 2, 32'h1804, "cpRESTORE not ready: again, valid");
    expect_cir(1'b0, R_OPND, 4, 32'h6666_6666, "cpRESTORE not ready: the state");
    expect_end("cpRESTORE not ready");

    // ... and a reserved code read back from the restore CIR is an invalid
    // format word.
    base_setup();
    poke_l(32'h0000_0038, HAND);
    poke_w(CODE + 0, 16'hF350);            // cpRESTORE (A0)
    poke_w(CODE + 2, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    poke_l(DATA + 0, 32'h1804_0000);
    cp.push_rest(16'h0700);
    reset_dut();
    dut.u_seq.areg[0] = DATA;
    run_until(HAND, 3000, reached);
    check(reached, "cpRESTORE, reserved code: the format error");
    check(peek_w(ISP0 - 8 + 6) === 16'h0038 && peek_l(ISP0 - 8 + 2) === CODE,
          "cpRESTORE, reserved code: four words, the cpRESTORE's address");
    expect_cir(1'b0, R_REST, 2, 32'h1804, "cpRESTORE, reserved code");
    expect_cir(1'b1, R_REST, 2, 32'h0700, "cpRESTORE, reserved code");
    expect_cir(1'b0, R_CTRL, 2, 32'h0001, "cpRESTORE, reserved code: abort");
    expect_end("cpRESTORE, reserved code");

    // ======================================================================
    // The PC bit before an exception -- UM 10.4.2: "if the PC bit is set in
    // one of these response primitives, however, the main processor passes
    // the program counter to the instruction address CIR before it initiates
    // exception processing". An undefined primitive with PC set: the address,
    // then the protocol violation; RTE reads the response CIR again.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0034, HAND);           // vector 13
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0F03);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);
    cp.push_resp(16'h7F00);                // PC set, bits 13:8 = $3F: undefined
    cp.push_resp(16'h0802);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "PC bit, undefined primitive: the protocol violation");
    check(peek_w(ISP0 - 32'h14 + 6) === 16'h9034, "PC bit, undefined primitive: format $9");
    run_until(CODE + 4, 3000, reached);
    check(reached, "PC bit, undefined primitive: RTE, and it ends");
    expect_cir(1'b0, R_CMD, 2, 32'h0F03, "PC bit, undefined");
    expect_cir(1'b1, R_RESP, 2, 32'h7F00, "PC bit, undefined");
    expect_cir(1'b0, R_IADR, 4, CODE, "PC bit, undefined: the address first");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "PC bit, undefined: after RTE");
    expect_end("PC bit, undefined");

    // ======================================================================
    // Transfer multiple coprocessor registers with an address its direction
    // does not allow -- UM 10.4.16: to the coprocessor "the control addressing
    // modes and the postincrement addressing mode are valid", so -(An) is
    // aborted and an F-line exception.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_002C, HAND);           // vector 11
    poke_w(CODE + 0,  16'hF220);           // cpGEN -(A0)
    poke_w(CODE + 2,  16'h0F04);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h810C);                // CA, DR=0, multiple, 12 bytes each
    reset_dut();
    dut.u_seq.areg[0] = DATA + 32'h40;
    run_until(HAND, 3000, reached);
    check(reached, "multiple coprocessor registers from -(A0): F-line");
    check(peek_w(ISP0 - 8 + 6) === 16'h002C && peek_l(ISP0 - 8 + 2) === CODE,
          "multiple coprocessor registers from -(A0): four words, the instruction");
    check(dut.u_seq.areg[0] === DATA + 32'h40, "multiple coprocessor registers from -(A0): A0 untouched");
    expect_cir(1'b0, R_CMD, 2, 32'h0F04, "multiple from -(A0)");
    expect_cir(1'b1, R_RESP, 2, 32'h810C, "multiple from -(A0)");
    expect_cir(1'b0, R_CTRL, 2, 32'h0001, "multiple from -(A0): abort");
    expect_end("multiple from -(A0)");

    // ======================================================================
    // An odd scanPC from the coprocessor -- UM 10.5.2.8: "an address error
    // occurs ... if an odd value is transferred to the scanPC with the
    // transfer status register and the scanPC response primitive".
    // ======================================================================
    base_setup();
    poke_l(32'h0000_000C, HAND);           // vector 3
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0F05);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h2300);                // DR=1, SP=1, CA clear: release
    cp.push_opnd(32'h2700_0000);
    cp.push_iadr(32'h0000_0801);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "odd scanPC: the address error handler runs");
    expect_cir(1'b0, R_CMD, 2, 32'h0F05, "odd scanPC");
    expect_cir(1'b1, R_RESP, 2, 32'h2300, "odd scanPC");
    expect_cir(1'b1, R_OPND, 2, 32'h0000_2700, "odd scanPC: the status register");
    expect_cir(1'b1, R_IADR, 4, 32'h0000_0801, "odd scanPC: the scanPC");
    expect_end("odd scanPC");
  endtask
