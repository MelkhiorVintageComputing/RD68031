// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the per-opcode sweep, against UAE030.
//
// tools/vectors/gen.c builds one test per (opcode, starting state), runs it
// through UAE030 as an MC68030 and records the state it finished in and every
// operand access it made. This replays each one through the core and compares
// all of it: fifteen registers, the three stack pointers, the status register,
// the program counter, VBR, SFC, DFC, CACR and CAAR, and the ordered access
// list with the size, direction, space and written value of each.
//
// The stream's format is documented at the top of tools/vectors/gen.c.
//
// UAE030 is an ORACLE, not a source. Where the two disagree the manual decides.
//
// The access list is the core harness's (rd68031_core_harness.svh), which since
// M10 records each operand where the bus unit ACCEPTS it, as the program asked
// for it, rather than at the OCS of its first bus cycle: with the data cache
// enabled -- a vector's CACR may set ED -- a read can be answered with no bus
// cycle, or start its cycles at its second long word (UM 6.1.2, 7.2.7). Both
// are invisible to the program, and the oracle reports the operand either way.
//
// Memory is filled from the test index by the same two multiplications on both
// sides, so neither has to send the other four kilobytes per test and neither
// can be reading storage the other never wrote.

`timescale 1ns / 1ps

module core_vec_tb;

`include "rd68031_core_harness.svh"

  localparam logic [31:0] PROG_BASE = 32'h0000_1000;
  localparam logic [31:0] DATA_BASE = 32'h0000_2000;
  localparam int          DATA_SIZE = 'h800;
  localparam int          PROG_FILL = 'h40;
  localparam logic [31:0] RTE_STUB  = 32'h0000_8100;
  localparam logic [31:0] RTE_FRAME = 32'h0000_7FF0;

  integer      vec, flog;
  int unsigned ntests;
  int unsigned idx, nwords, npoke, nread;
  logic [31:0] w    [0:5];
  logic [31:0] dv   [0:7];
  logic [31:0] av   [0:6];
  logic [31:0] uspv, ispv, srv;
  logic [31:0] mspv, sfcv, dfcv, vbrv, caarv, cacrv;
  logic [31:0] pa   [0:3];
  logic [31:0] pv   [0:3];
  logic [31:0] srmask;
  logic [31:0] bcdfill;
  logic [31:0] fd   [0:7];
  logic [31:0] fa   [0:6];
  logic [31:0] fusp, fisp, fsr, fpc;
  logic [31:0] fmsp, fvbr, fsfc, fdfc, fcaar, fcacr;
  logic [31:0] fw;
  logic [31:0] racc [0:23];
  logic [31:0] rrw  [0:23];
  logic [31:0] rby  [0:23];
  logic [31:0] rpg  [0:23];
  logic [31:0] rval [0:23];
  logic [31:0] rmsk [0:23];
  // M11: the MMU's registers in and out, and the translation tables laid down
  // before the run and compared after it (tools/vectors/gen.c, pmmu).
  logic [31:0] imt  [0:7];
  logic [31:0] fmt  [0:7];
  int unsigned ntbl;
  logic [31:0] tba  [0:31];
  logic [31:0] tbv  [0:31];
  logic [31:0] tbf  [0:31];
  logic [31:0] got, msk;
  // The bits each MMU register has (UM 9.7; doc/mmu.md): the comparison is
  // under these, since the oracle keeps the others (doc/oracles.md).
  function automatic logic [31:0] mmsk(input int unsigned i);
    case (i)
      0:       mmsk = 32'h83FF_FFFF;
      1, 3:    mmsk = 32'hFFFF_0003;
      2, 4:    mmsk = 32'hFFFF_FFF0;
      5, 6:    mmsk = 32'hFFFF_8777;
      default: mmsk = 32'h0000_EE47;
    endcase
  endfunction
  localparam logic [31:0] TBL_A = 32'h0000_3000, TBL_B = 32'h0000_3100,
                          TBL_IND = 32'h0000_3080;

  int unsigned t, n;
  int unsigned passed, failed, shown;
  bit          ok, bad;
  string       what, why;

  // The same arithmetic as gen.c's fill_word: two truncating 32-bit
  // multiplications and an exclusive or.
  function automatic logic [31:0] fill_word(input int unsigned i,
                                            input int unsigned off);
    fill_word = (32'(i) * 32'h9E37_79B9) ^ (32'(off) * 32'h0100_0193);
  endfunction

  // A byte, and a long word, with every nibble brought into the range a decimal
  // digit can hold -- the same arithmetic as gen.c's bcd_word. These read only
  // their arguments, which is what makes them safe as functions.
  function automatic logic [3:0] bcd_digit(input logic [3:0] d);
    // A nibble is at most fifteen, so "modulo ten" is one conditional subtract.
    // Written that way rather than with `%` because the two sides of this
    // comparison must agree bit for bit and a conditional subtract cannot be
    // read two ways.
    bcd_digit = (d >= 4'd10) ? (d - 4'd10) : d;
  endfunction

  function automatic logic [7:0] bcd_byte(input logic [7:0] b);
    bcd_byte = {bcd_digit(b[7:4]), bcd_digit(b[3:0])};
  endfunction

  function automatic logic [31:0] bcd_word32(input logic [31:0] v);
    bcd_word32 = {bcd_byte(v[31:24]), bcd_byte(v[23:16]),
                  bcd_byte(v[15:8]),  bcd_byte(v[7:0])};
  endfunction

  // Everything this sweep touches is in the first slave, so the fill goes
  // straight into its array: a poke per long word through the harness would be
  // four task calls times a thousand words times seven thousand tests.
  task automatic put_l(input logic [31:0] a, input logic [31:0] v);
    s32.mem[a[15:0]]     = v[31:24];
    s32.mem[a[15:0] + 1] = v[23:16];
    s32.mem[a[15:0] + 2] = v[15:8];
    s32.mem[a[15:0] + 3] = v[7:0];
  endtask

  task automatic put_w(input logic [31:0] a, input logic [15:0] v);
    s32.mem[a[15:0]]     = v[15:8];
    s32.mem[a[15:0] + 1] = v[7:0];
  endtask

  initial begin
    // +faillog=<file>: every failing vector, one line each, for triage.
    flog = 0;
    if ($value$plusargs("faillog=%s", why)) flog = $fopen(why, "w");
    if (!$value$plusargs("vec=%s", what)) what = "build/vectors.hex";
    vec = $fopen(what, "r");
    if (vec == 0) begin
      $display("FAIL: core_vec_tb cannot open the vector file");
      $finish;
    end
    n = $fscanf(vec, "%h", ntests);
    $display("core_vec_tb: %0d vectors from UAE030", ntests);

    passed = 0;
    failed = 0;
    shown  = 0;

    for (n = 0; n < 65536; n = n + 1) s32.mem[n] = 8'h00;

    // The vector table and the reset vectors are the same for every test, so
    // they are written once. Refilling them per test was a third of the work
    // this sweep did.
    //
    // Every vector points somewhere DIFFERENT -- tools/vectors/gen.c lays it
    // out the same way -- so that an instruction which trapped through the
    // wrong vector shows as a wrong program counter.
    for (n = 0; n < 256; n = n + 1)
      put_l(32'(n) * 4, 32'h0000_9000 + 32'(n) * 4);
    put_l(32'h0, 32'h0000_2700);
    put_w(RTE_STUB, 16'h4E73);
    put_l(32'h4, PROG_BASE);

    for (t = 0; t < ntests; t = t + 1) begin
      n = $fscanf(vec, "%h %h %h %h %h %h %h %h",
                  idx, nwords, w[0], w[1], w[2], w[3], w[4], w[5]);
      for (n = 0; n < 8; n = n + 1) void'($fscanf(vec, "%h", dv[n]));
      for (n = 0; n < 7; n = n + 1) void'($fscanf(vec, "%h", av[n]));
      void'($fscanf(vec, "%h", uspv));
      void'($fscanf(vec, "%h", ispv));
      void'($fscanf(vec, "%h", srv));
      void'($fscanf(vec, "%h", mspv));
      void'($fscanf(vec, "%h", sfcv));
      void'($fscanf(vec, "%h", dfcv));
      void'($fscanf(vec, "%h", vbrv));
      void'($fscanf(vec, "%h", caarv));
      void'($fscanf(vec, "%h", cacrv));
      void'($fscanf(vec, "%h", npoke));
      for (n = 0; n < npoke; n = n + 1) begin
        void'($fscanf(vec, "%h", pa[n]));
        void'($fscanf(vec, "%h", pv[n]));
      end
      void'($fscanf(vec, "%h", srmask));
      void'($fscanf(vec, "%h", bcdfill));
      for (n = 0; n < 8; n = n + 1) void'($fscanf(vec, "%h", fd[n]));
      for (n = 0; n < 7; n = n + 1) void'($fscanf(vec, "%h", fa[n]));
      void'($fscanf(vec, "%h", fusp));
      void'($fscanf(vec, "%h", fisp));
      void'($fscanf(vec, "%h", fsr));
      void'($fscanf(vec, "%h", fpc));
      void'($fscanf(vec, "%h", fmsp));
      void'($fscanf(vec, "%h", fvbr));
      void'($fscanf(vec, "%h", fsfc));
      void'($fscanf(vec, "%h", fdfc));
      void'($fscanf(vec, "%h", fcaar));
      void'($fscanf(vec, "%h", fcacr));
      void'($fscanf(vec, "%h", nread));
      for (n = 0; n < nread; n = n + 1) begin
        void'($fscanf(vec, "%h", racc[n]));
        void'($fscanf(vec, "%h", rrw[n]));
        void'($fscanf(vec, "%h", rby[n]));
        void'($fscanf(vec, "%h", rpg[n]));
        void'($fscanf(vec, "%h", rval[n]));
        void'($fscanf(vec, "%h", rmsk[n]));
      end
      for (n = 0; n < 8; n = n + 1) void'($fscanf(vec, "%h", imt[n]));
      void'($fscanf(vec, "%h", ntbl));
      for (n = 0; n < ntbl; n = n + 1) begin
        void'($fscanf(vec, "%h", tba[n]));
        void'($fscanf(vec, "%h", tbv[n]));
      end
      for (n = 0; n < 8; n = n + 1) void'($fscanf(vec, "%h", fmt[n]));
      for (n = 0; n < ntbl; n = n + 1) void'($fscanf(vec, "%h", tbf[n]));

      // ------------------------------------------------------------------
      // Memory, exactly as the oracle laid it out.
      // ------------------------------------------------------------------
      // Written straight into the slave's array rather than through put_l: a
      // task call per long word, times five hundred words, times seven
      // thousand tests, is most of what this sweep costs.
      for (n = 0; n < DATA_SIZE; n = n + 4) begin
        fw = fill_word(idx, n);
        // The decimal instructions are defined on binary-coded decimal operands
        // and nothing says what a digit above nine does, so the sweep gives
        // them digits. tools/vectors/gen.c does the same to the same bytes.
        if (bcdfill[0]) fw = bcd_word32(fw);
        s32.mem[DATA_BASE[15:0] + 16'(n)]     = fw[31:24];
        s32.mem[DATA_BASE[15:0] + 16'(n) + 1] = fw[23:16];
        s32.mem[DATA_BASE[15:0] + 16'(n) + 2] = fw[15:8];
        s32.mem[DATA_BASE[15:0] + 16'(n) + 3] = fw[7:0];
      end
      for (n = 0; n < PROG_FILL; n = n + 2)
        put_w(PROG_BASE + 32'(n), 16'h4E71);
      for (n = 0; n < nwords; n = n + 1)
        put_w(PROG_BASE + 32'(n * 2), w[n][15:0]);
      for (n = 0; n < npoke; n = n + 1) put_l(pa[n], pv[n]);
      // The pmmu tree (gen.c, setup): B[$00]-B[$3F] identity when the test
      // has tables, A[0]-A[3] and the indirect's target cleared, then the
      // pairs the stream carries; zero for every other test.
      for (n = 0; n < 'h40; n = n + 1)
        put_l(TBL_B + 32'(n) * 4, (ntbl != 0) ? ((32'(n) << 8) | 32'd1) : 32'd0);
      for (n = 0; n < 4; n = n + 1) put_l(TBL_A + 32'(n) * 4, 32'd0);
      put_l(TBL_IND, 32'd0);
      for (n = 0; n < ntbl; n = n + 1) put_l(tba[n], tbv[n]);

      // ------------------------------------------------------------------
      // Run to the instruction, deposit the state, run exactly one.
      // ------------------------------------------------------------------
      // A test that starts traced is entered through an RTE: the core decides
      // whether to trace an instruction from the T bits as it starts it (UM
      // 8.1.7), which is earlier than a deposit can reach, so they have to
      // arrive the way a program's would. The reset vector points at an RTE
      // whose frame, outside the data block, holds the test's SR and PC.
      put_l(32'h4, (srv[15:14] != 2'b00) ? RTE_STUB : PROG_BASE);
      reset_dut();
      if (srv[15:14] != 2'b00) begin
        put_w(RTE_FRAME, srv[15:0]);
        put_l(RTE_FRAME + 2, PROG_BASE);
        put_w(RTE_FRAME + 6, 16'h0000);
        run_until(RTE_STUB, 300, ok);
        dut.u_seq.isp_q = RTE_FRAME;
        // Step to the boundary that starts the test instruction: it is that
        // decode that takes the T bits the RTE restored.
        for (n = 0; ok && n < 4 && !(n > 0 && dut.u_ifu.pc_d == PROG_BASE); n = n + 1)
          step_one(400, ok);
        ok = ok && (dut.u_ifu.pc_d == PROG_BASE);
      end else begin
        run_until(PROG_BASE, 300, ok);
      end
      if (ok) begin
        for (n = 0; n < 8; n = n + 1) dut.u_seq.dreg[n] = dv[n];
        for (n = 0; n < 7; n = n + 1) dut.u_seq.areg[n] = av[n];
        dut.u_seq.usp_q = uspv;
        dut.u_seq.isp_q = ispv;
        if (srv[15:14] == 2'b00) dut.u_seq.sr_q = srv[15:0];
        // UM 8.1.1 does not say what reset leaves in these, so the test says.
        dut.u_seq.msp_q  = mspv;
        dut.u_seq.sfc_q  = sfcv[2:0];
        dut.u_seq.dfc_q  = dfcv[2:0];
        dut.u_seq.vbr_q  = vbrv;
        dut.u_seq.caar_q = caarv;
        // CACR is zero after a reset (UM 6.3.1); the few tests that start
        // elsewhere hold only bits a MOVEC could have left there.
        dut.u_seq.cacr_q = cacrv;
        // The MMU's registers, with the ATC empty (UM 9.7, 9.4).
        dut.u_mmu.tc_q    = imt[0];
        dut.u_mmu.crp_q   = {imt[1], imt[2]};
        dut.u_mmu.srp_q   = {imt[3], imt[4]};
        dut.u_mmu.tt0_q   = imt[5];
        dut.u_mmu.tt1_q   = imt[6];
        dut.u_mmu.mmusr_q = imt[7][15:0];
        dut.u_mmu.v_q     = '0;
        dut.u_mmu.h_q     = '0;
        nacc = 0;
        step_one(400, ok);
        // A trace exception is taken where the next instruction would be
        // decoded, after the boundary that ends this one. When the oracle
        // finished in a handler (every vector points into $9000-$93FF) and
        // the core is not there yet, it is given that boundary too.
        for (n = 0; ok && n < 2 && dut.u_ifu.pc_d !== fpc && fpc[31:10] == 22'h24; n = n + 1)
          step_one(400, ok);
      end

      // ------------------------------------------------------------------
      // Compare.
      // ------------------------------------------------------------------
      bad = 1'b0;
      why = "";
      if (!ok) begin
        bad = 1'b1;
        why = "the instruction never retired";
      end
      for (n = 0; n < 8; n = n + 1)
        if (!bad && dut.u_seq.dreg[n] !== fd[n]) begin
          bad = 1'b1;
          $sformat(why, "D%0d is %08h, UAE030 says %08h",
                   n, dut.u_seq.dreg[n], fd[n]);
        end
      for (n = 0; n < 7; n = n + 1)
        if (!bad && dut.u_seq.areg[n] !== fa[n]) begin
          bad = 1'b1;
          $sformat(why, "A%0d is %08h, UAE030 says %08h",
                   n, dut.u_seq.areg[n], fa[n]);
        end
      if (!bad && dut.u_seq.usp_q !== fusp) begin
        bad = 1'b1;
        $sformat(why, "USP is %08h, UAE030 says %08h", dut.u_seq.usp_q, fusp);
      end
      if (!bad && dut.u_seq.isp_q !== fisp) begin
        bad = 1'b1;
        $sformat(why, "ISP is %08h, UAE030 says %08h", dut.u_seq.isp_q, fisp);
      end
      // Only the bits the manual defines. PRM 4 leaves some condition codes
      // undefined and the oracle still produces a number for them; comparing
      // those would compare this core against the oracle's choice rather than
      // against the manual. doc/divergences.md records what this design does
      // with each of them.
      if (!bad && ((dut.u_seq.sr_q ^ fsr[15:0]) & srmask[15:0]) !== 16'd0) begin
        bad = 1'b1;
        $sformat(why, "SR is %04h, UAE030 says %04h (comparing %04h)",
                 dut.u_seq.sr_q, fsr[15:0], srmask[15:0]);
      end
      // The control registers MOVEC reaches.
      if (!bad && dut.u_seq.msp_q !== fmsp) begin
        bad = 1'b1;
        $sformat(why, "MSP is %08h, UAE030 says %08h", dut.u_seq.msp_q, fmsp);
      end
      if (!bad && dut.u_seq.vbr_q !== fvbr) begin
        bad = 1'b1;
        $sformat(why, "VBR is %08h, UAE030 says %08h", dut.u_seq.vbr_q, fvbr);
      end
      if (!bad && {29'd0, dut.u_seq.sfc_q} !== fsfc) begin
        bad = 1'b1;
        $sformat(why, "SFC is %0d, UAE030 says %0d", dut.u_seq.sfc_q, fsfc);
      end
      if (!bad && {29'd0, dut.u_seq.dfc_q} !== fdfc) begin
        bad = 1'b1;
        $sformat(why, "DFC is %0d, UAE030 says %0d", dut.u_seq.dfc_q, fdfc);
      end
      if (!bad && dut.u_seq.caar_q !== fcaar) begin
        bad = 1'b1;
        $sformat(why, "CAAR is %08h, UAE030 says %08h", dut.u_seq.caar_q, fcaar);
      end
      if (!bad && dut.u_seq.cacr_q !== fcacr) begin
        bad = 1'b1;
        $sformat(why, "CACR is %08h, UAE030 says %08h", dut.u_seq.cacr_q, fcacr);
      end
      // The MMU's registers, on the bits each has.
      for (n = 0; n < 8; n = n + 1) begin
        case (n)
          0: got = dut.u_mmu.tc_q;
          1: got = dut.u_mmu.crp_q[63:32];
          2: got = dut.u_mmu.crp_q[31:0];
          3: got = dut.u_mmu.srp_q[63:32];
          4: got = dut.u_mmu.srp_q[31:0];
          5: got = dut.u_mmu.tt0_q;
          6: got = dut.u_mmu.tt1_q;
          default: got = {16'd0, dut.u_mmu.mmusr_q};
        endcase
        // UM Table 9-3: with I set, W, M and S are undefined; with T set
        // (PTEST level 0), every other bit is.
        msk = mmsk(n);
        if (n == 7 && fmt[7][10]) msk = msk & ~32'h0000_2A00;
        if (n == 7 && fmt[7][6])  msk = 32'h0000_0040;
        if (!bad && ((got ^ fmt[n]) & msk) !== 32'd0) begin
          bad = 1'b1;
          $sformat(why, "%s is %08h, UAE030 says %08h",
                   n == 0 ? "TC" : n == 1 ? "CRP(hi)" : n == 2 ? "CRP(lo)" :
                   n == 3 ? "SRP(hi)" : n == 4 ? "SRP(lo)" : n == 5 ? "TT0" :
                   n == 6 ? "TT1" : "MMUSR", got, fmt[n]);
        end
      end
      // The tables: the U and M bits a search wrote, and nothing else.
      for (n = 0; n < ntbl; n = n + 1)
        if (!bad && peek_l(tba[n]) !== tbf[n]) begin
          bad = 1'b1;
          $sformat(why, "the descriptor at %08h is %08h, UAE030 says %08h",
                   tba[n], peek_l(tba[n]), tbf[n]);
        end
      if (!bad && dut.u_ifu.pc_d !== fpc) begin
        bad = 1'b1;
        $sformat(why, "the PC is %08h, UAE030 says %08h", dut.u_ifu.pc_d, fpc);
      end
      if (!bad && nacc !== nread) begin
        bad = 1'b1;
        $sformat(why, "it made %0d operand accesses, UAE030 made %0d",
                 nacc, nread);
      end
      for (n = 0; n < nread; n = n + 1)
        if (!bad && (acc_addr[n] !== racc[n] || acc_rw[n] !== rrw[n][0]
                     || {29'd0, acc_bytes[n]} !== rby[n]
                     || acc_prog[n] !== rpg[n][0]
                     || (!acc_rw[n] && ((acc_data[n] ^ rval[n]) & rmsk[n]) !== 32'd0))) begin
          bad = 1'b1;
          $sformat(why, "access %0d is %s %0d bytes at %08h in %s space of %08h, UAE030 says %s %0d bytes at %08h in %s space of %08h",
                   n, acc_rw[n] ? "a read of" : "a write of", acc_bytes[n],
                   acc_addr[n], acc_prog[n] ? "program" : "data", acc_data[n],
                   rrw[n][0] ? "a read of" : "a write of", rby[n],
                   racc[n], rpg[n][0] ? "program" : "data", rval[n]);
        end

      if (bad) begin
        failed = failed + 1;
        if (flog != 0) begin
          // ... and both access lists, so a disagreement about their shape
          // can be read without rerunning anything.
          $fwrite(flog, "%0h %04h %04h %04h %04h | %s | core:", idx, w[0][15:0], w[1][15:0],
                  w[2][15:0], w[3][15:0], why);
          for (n = 0; n < nacc && n < MAXACC; n = n + 1)
            $fwrite(flog, " %s%0d@%0h%s", acc_rw[n] ? "R" : "W", acc_bytes[n], acc_addr[n],
                    acc_prog[n] ? "p" : "");
          $fwrite(flog, " | oracle:");
          for (n = 0; n < nread; n = n + 1)
            $fwrite(flog, " %s%0d@%0h%s", rrw[n][0] ? "R" : "W", rby[n], racc[n],
                    rpg[n][0] ? "p" : "");
          $fdisplay(flog, "");
        end
        if (shown < 15) begin
          shown = shown + 1;
          $display("  FAIL: vector %0d (%04h %04h %04h): %s",
                   idx, w[0][15:0], w[1][15:0], w[2][15:0], why);
        end
      end else begin
        passed = passed + 1;
      end
    end

    $fclose(vec);
    if (flog != 0) $fclose(flog);
    $display("core_vec_tb: %0d passed, %0d failed, of %0d", passed, failed, ntests);
    if (failed == 0) $display("PASS: core_vec_tb");
    else             $display("FAIL: core_vec_tb");
    $finish;
  end

  initial begin
    #4_000_000_000;
    $display("FAIL: core_vec_tb timed out");
    $finish;
  end

endmodule
