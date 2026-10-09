// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- demand paging through the MMU: core_paging_tb's sweep, with the
// page that is not there made absent by the translation tables instead of by
// a memory that answers BERR.
//
// core_paging_tb pages the way an MC68020 system with an external MMU does:
// the bus cycle starts and the memory refuses it. On the MC68030 the MMU
// refuses it before AS (UM 9.2.1, figure 9-8: "the memory cycle is aborted")
// and the processor takes the same bus error exception (UM 8.1.2, 9.5.2) --
// the same format $B frame, the same special status word, the same residual
// when an operand straddles into the refused page. This sweep holds the MMU's
// refusal to that: every combination of
//
//     operand size   1, 2 and 4 bytes
//     alignment      A1A0 = 00, 01, 10, 11
//     port size      8, 16 and 32 bits
//     direction      read, write, and read-modify-write (CAS)
//
// faulted across, or inside, a page whose page descriptor is invalid (UM
// 9.5.1.1, DT = 0). The tables are three levels of short descriptors, 4K
// pages: TIA = 4, TIB = 8, TIC = 8. The level-A entry of the port under test
// points at a level-B table whose first entry points at a page table; every
// other level-A and level-B entry is an early termination page descriptor
// (UM 9.5.3.1) mapping its block onto itself; the page table maps each page
// onto itself, except the page under test, which is invalid.
//
// The handler is real code, an MMU-aware version of core_paging_tb's: it hands
// the data fault address at +$10 to the pager -- which here writes a valid page
// descriptor into the page table -- flushes the ATC entry with B set that the
// failed search left (UM 9.4: "The B bit remains set until a PFLUSH
// instruction ... invalidates the entry"), and returns with DF still set so
// that RTE reruns the access through translation (UM 8.2.3).
//
// Besides core_paging_tb's checks of the frame, the operand and the next
// instruction, this one checks that no cycle reached the refused page before
// the pager ran -- the refusal was the MMU's, not the bus's.

`timescale 1ns / 1ps

module core_mmu_paging_tb;

`include "rd68031_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] HAND = 32'h0000_0500;
  localparam logic [31:0] PAGER = 32'h0000_7000;  // the pager's control word
  localparam logic [31:0] BODY  = CODE + 12;      // after the two PMOVEs

  // The translation tables, in the 32-bit memory, and the images of CRP and TC
  // the program loads with PMOVE.
  localparam logic [31:0] TBL_A  = 32'h0000_2000; // 16 short descriptors
  localparam logic [31:0] TBL_B  = 32'h0000_3000; // 256
  localparam logic [31:0] TBL_C  = 32'h0000_3400; // 256: the page table
  localparam logic [31:0] RP_IMG = 32'h0000_1800;
  localparam logic [31:0] TC_IMG = 32'h0000_1808;
  // UM 9.7.2: E, PS = $C (4K), IS = 0, TIA = 4, TIB = 8, TIC = 8, TID = 0 --
  // 12 + 4 + 8 + 8 = 32.
  localparam logic [31:0] TC_VAL = 32'h80C0_4880;

  // The page under test, and the page_at the operands straddle.
  localparam logic [31:0] PAGE_MASK = 32'hFFFF_F000;

  int unsigned nsize, nalign, nport, ndir;
  int unsigned isize, ialign, iport, idir;
  int unsigned opsize;
  logic [31:0] port_base;
  logic [31:0] page_at;
  logic [31:0] addr;
  logic [31:0] want;
  logic [31:0] upd;
  logic [31:0] spin;
  logic [31:0] mask;
  logic [15:0] got_w;
  bit          reached;
  string       what;
  int unsigned faults;
  int unsigned cases_run;
  int unsigned faults_before;
  int unsigned early;        // cycles to the refused page before the pager ran
  int unsigned searches;     // table search cycles: FC 5 with RMC, to a table

  // The frame, as the handler saw it when it called the pager.
  logic [15:0] f_sr, f_fmt, f_ssw, f_ver;
  logic [31:0] f_pc, f_dfa, f_dob;

  // The pager. A write to its control word maps whatever page the value names,
  // which here means letting the access through.
  always @(negedge as_n_o) begin
    if (rst_n && !rw_o && (a_o[31:0] & ~32'd3) == PAGER) begin
      // A valid page descriptor for the page, U and M clear.
      poke_l(TBL_C + 4 * page_at[19:12], page_at | 32'h1);
      faults  = faults + 1;
      f_sr  = peek_w(dut.u_seq.isp_q);
      f_pc  = peek_l(dut.u_seq.isp_q + 32'h02);
      f_fmt = peek_w(dut.u_seq.isp_q + 32'h06);
      f_ssw = peek_w(dut.u_seq.isp_q + 32'h0A);
      f_dfa = peek_l(dut.u_seq.isp_q + 32'h10);
      f_dob = peek_l(dut.u_seq.isp_q + 32'h18);
      f_ver = peek_w(dut.u_seq.isp_q + 32'h36);
    end
  end

  // No cycle may reach the refused page until the pager has made it valid: the
  // MMU aborts the access before AS (UM 9.2.1).
  always @(negedge as_n_o) begin
    if (rst_n && faults == faults_before && fc_o != 3'b111
        && (a_o & PAGE_MASK) == page_at)
      early = early + 1;
    if (rst_n && fc_o == 3'b101 && !rmc_n_o
        && ((a_o & 32'hFFFF_F000) == TBL_A || (a_o & 32'hFFFF_F000) == (TBL_B & 32'hFFFF_F000)))
      searches = searches + 1;
  end

  // What is left of the operand when the page runs out: from the boundary
  // to its end if it straddles, the whole of it if it does not.
  logic [31:0] r_addr;
  int unsigned r_bytes;
  logic  [1:0] r_size;

  task automatic setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1) poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    poke_l(32'h0000_0008, HAND);          // vector 2, bus error

    // The handler: hand the data fault address at +$10 of the frame to the
    // pager, flush the entry the failed search left, and return with DF
    // untouched so that RTE reruns the access.
    poke_w(HAND + 0, 16'h21EF);           // MOVE.L ($10,A7),($7000).W
    poke_w(HAND + 2, 16'h0010);
    poke_w(HAND + 4, PAGER[15:0]);
    poke_w(HAND + 6, 16'hF000);           // PFLUSHA
    poke_w(HAND + 8, 16'h2400);
    poke_w(HAND + 10, 16'h4E73);          // RTE

    // The tables -- UM 9.5.1, figure 9-10 (short page descriptor, DT = 1) and
    // figure 9-12 (short table descriptor, DT = 2).
    for (v = 0; v < 16; v = v + 1)
      poke_l(TBL_A + 4 * v, (v << 28) | 32'h1);
    poke_l(TBL_A + 4 * port_base[31:28], TBL_B | 32'h2);
    poke_l(TBL_B, TBL_C | 32'h2);
    for (v = 1; v < 256; v = v + 1)
      poke_l(TBL_B + 4 * v, port_base | (v << 20) | 32'h1);
    for (v = 0; v < 256; v = v + 1)
      poke_l(TBL_C + 4 * v, port_base | (v << 12) | 32'h1);
    poke_l(TBL_C + 4 * page_at[19:12], 32'h0);   // DT = 0: invalid
    // CRP: an upper limit of $7FFF (none), DT = 2, the level-A table.
    poke_l(RP_IMG,     32'h7FFF_0002);
    poke_l(RP_IMG + 4, TBL_A);
    poke_l(TC_IMG,     TC_VAL);

    // The program's first two instructions turn translation on.
    poke_w(CODE + 0,  16'hF038);          // PMOVE (RP_IMG).W,CRP
    poke_w(CODE + 2,  16'h4C00);
    poke_w(CODE + 4,  RP_IMG[15:0]);
    poke_w(CODE + 6,  16'hF038);          // PMOVE (TC_IMG).W,TC
    poke_w(CODE + 8,  16'h4000);
    poke_w(CODE + 10, TC_IMG[15:0]);
  endtask

  initial begin
    $display("core_mmu_paging_tb: every operand shape faulted across a page the MMU refuses");
    faults    = 0;
    cases_run = 0;
    early     = 0;
    searches  = 0;

    for (idir = 0; idir < 3; idir = idir + 1)
    for (iport = 0; iport < 3; iport = iport + 1)
    for (isize = 0; isize < 3; isize = isize + 1)
    for (ialign = 0; ialign < 4; ialign = ialign + 1) begin
      opsize = (isize == 0) ? 1 : (isize == 1) ? 2 : 4;
      case (iport)
        0: begin port_base = 32'h0000_0000; what = "32-bit port"; end
        1: begin port_base = 32'h1000_0000; what = "16-bit port"; end
        default: begin port_base = 32'h2000_0000; what = " 8-bit port"; end
      endcase

      // The page under test is page 8 of the port. An operand at alignment
      // `ialign` STRADDLES the boundary exactly when it runs off the end of its
      // own long word -- ialign + size > 4 -- and then it is placed in the long
      // word below, so its first cycles are in the page that is there and a
      // later one is not. When it cannot straddle, it goes inside the missing
      // page instead and faults on its first cycle. Both are worth running:
      // the first is the one that leaves a partial residual for the frame to
      // carry, and the second is the one every byte access is.
      page_at = port_base + 32'h8000;
      if (ialign + opsize > 4) addr = page_at - 4 + ialign;
      else                     addr = page_at + ialign;

      setup();
      want = 32'h1234_5678 >> (8 * (4 - opsize));
      upd  = 32'hA5C3_9E71 >> (8 * (4 - opsize));
      spin = (idir == 2) ? BODY + 20 : BODY + 16;

      // The program. The operand goes to or from D0 through (A0).
      poke_w(BODY + 0, 16'h207C);                    // MOVEA.L #addr,A0
      poke_l(BODY + 2, addr);
      poke_w(BODY + 6, 16'h203C);                    // MOVE.L #want,D0
      poke_l(BODY + 8, want);
      if (idir == 0) begin
        // A write: MOVE.<size> D0,(A0)
        poke_w(BODY + 12, (opsize == 1) ? 16'h1080 :
                          (opsize == 2) ? 16'h3080 : 16'h2080);
        poke_w(BODY + 14, 16'h7455);                 // MOVEQ #$55,D2
        poke_w(BODY + 16, 16'h60FE);                 // BRA *
      end else if (idir == 1) begin
        // A read into D1: MOVE.<size> (A0),D1
        poke_w(BODY + 12, (opsize == 1) ? 16'h1210 :
                          (opsize == 2) ? 16'h3210 : 16'h2210);
        poke_w(BODY + 14, 16'h7455);                 // MOVEQ #$55,D2
        poke_w(BODY + 16, 16'h60FE);                 // BRA *
      end else begin
        // CAS.<size> D0,D3,(A0): the compare operand is what memory holds.
        poke_w(BODY + 12, (opsize == 1) ? 16'h0AD0 :
                          (opsize == 2) ? 16'h0CD0 : 16'h0ED0);
        poke_w(BODY + 14, 16'h00C0);                 // Du = D3, Dc = D0
        poke_w(BODY + 16, 16'h42C4);                 // MOVE.W CCR,D4
        poke_w(BODY + 18, 16'h7455);                 // MOVEQ #$55,D2
        poke_w(BODY + 20, 16'h60FE);                 // BRA *
      end

      // For a read, put the answer where the instruction will look for it --
      // in memory that is about to be unmapped, which is the point.
      if (idir != 0) begin
        case (opsize)
          1: poke_w(addr & ~32'd1, (addr[0] ? {8'h00, want[7:0]}
                                            : {want[7:0], 8'h00}));
          2: poke_w(addr, want[15:0]);
          default: begin poke_w(addr, want[31:16]); poke_w(addr + 2, want[15:0]); end
        endcase
      end

      reset_dut();
      dut.u_seq.dreg[3] = upd;
      f_fmt     = 16'h0;
      faults_before = faults;
      early     = 0;
      searches  = 0;
      if (ialign + opsize > 4) begin
        r_addr  = page_at;
        r_bytes = addr + opsize - page_at;
      end else begin
        r_addr  = addr;
        r_bytes = opsize;
      end
      // UM Table 7-2: SIZ1/SIZ0 00 is four bytes, 01 one, 10 two, 11 three.
      r_size = (r_bytes == 4) ? 2'b00 : r_bytes[1:0];

      run_until(spin, 6000, reached);
      cases_run = cases_run + 1;
      check(reached, $sformatf("%s size %0d at %08h (%s): the program finishes",
                               what, opsize, addr,
                               (idir == 0) ? "write" : (idir == 1) ? "read" : "CAS"));
      check(dut.u_seq.dreg[2] === 32'h0000_0055,
            $sformatf("%s size %0d at %08h: the next instruction ran",
                      what, opsize, addr));
      check(dut.u_seq.isp_q === ISP0,
            $sformatf("%s size %0d at %08h: the stack is unwound",
                      what, opsize, addr));
      check(faults == faults_before + 1,
            $sformatf("%s size %0d at %08h: the pager ran once", what, opsize, addr));
      check(early == 0,
            $sformatf("%s size %0d at %08h: %0d cycles reached the refused page before the pager -- UM 9.2.1",
                      what, opsize, addr, early));
      // Two searches at least: the code page and the page under test, each
      // through levels A, B and C (or A alone for an early termination).
      check(searches >= 2,
            $sformatf("%s size %0d at %08h: %0d table search cycles", what, opsize, addr, searches));
      check((peek_l(TBL_C + 4 * page_at[19:12]) & 32'h8) != 0,
            $sformatf("%s size %0d at %08h: U set in the repaired descriptor -- UM 9.5.1.1",
                      what, opsize, addr));
      check(((peek_l(TBL_C + 4 * page_at[19:12]) & 32'h10) != 0) === (idir != 1),
            $sformatf("%s size %0d at %08h: M set in the repaired descriptor for a write or CAS, clear for a read -- UM 9.5.1.1",
                      what, opsize, addr));
      // The frame.
      check(f_fmt === 16'hB008,
            $sformatf("%s size %0d at %08h: +$06 format $B, vector 2 -- UM Table 8-6",
                      what, opsize, addr));
      check(f_sr === 16'h2700,
            $sformatf("%s size %0d at %08h: +$00 the status register", what, opsize, addr));
      check(f_ver >> 12 === rd68031_frame_pkg::FRAME_VERSION,
            $sformatf("%s size %0d at %08h: +$36 the version nibble -- UM 8.1.13",
                      what, opsize, addr));
      check(f_dfa === r_addr,
            $sformatf("%s size %0d at %08h: +$10 is %08h, the residual's first byte %08h -- UM 8.2.2",
                      what, opsize, addr, f_dfa, r_addr));
      check(f_ssw[8] === 1'b1,
            $sformatf("%s size %0d at %08h: SSW DF -- UM figure 8-9", what, opsize, addr));
      check(f_ssw[7] === (idir == 2),
            $sformatf("%s size %0d at %08h: SSW RM -- UM figure 8-9", what, opsize, addr));
      check(f_ssw[6] === (idir != 0),
            $sformatf("%s size %0d at %08h: SSW RW -- UM figure 8-9", what, opsize, addr));
      check(f_ssw[5:4] === r_size,
            $sformatf("%s size %0d at %08h: SSW SIZE %b, the %0d bytes left, want %b -- UM figure 8-9, Table 7-2",
                      what, opsize, addr, f_ssw[5:4], r_bytes, r_size));
      check(f_ssw[2:0] === 3'd5,
            $sformatf("%s size %0d at %08h: SSW FC2-FC0 supervisor data", what, opsize, addr));
      check((f_ssw & rd68031_frame_pkg::SSW_INTERNAL) === 16'h0,
            $sformatf("%s size %0d at %08h: SSW internal bits zero -- doc/ssw.md",
                      what, opsize, addr));
      if (idir != 0)
        check(f_pc === BODY + 12,
              $sformatf("%s size %0d at %08h: +$02 the read's own instruction", what, opsize, addr));
      else
        check(f_dob === want,
              $sformatf("%s size %0d at %08h: +$18 the operand, right justified -- UM 8.2.2",
                        what, opsize, addr));
      if (idir == 0) begin
        case (opsize)
          1: begin
            got_w = peek_w(addr & ~32'd1);
            check((addr[0] ? got_w[7:0] : got_w[15:8]) === want[7:0],
                  $sformatf("%s byte at %08h: the byte landed", what, addr));
          end
          2: check(peek_w(addr) === want[15:0],
                   $sformatf("%s word at %08h: the word landed", what, addr));
          default: check({peek_w(addr), peek_w(addr + 2)} === want,
                   $sformatf("%s long at %08h: the long word landed", what, addr));
        endcase
      end else if (idir == 1) begin
        mask = (opsize == 1) ? 32'h0000_00FF
             : (opsize == 2) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
        check((dut.u_seq.dreg[1] & mask) === (want & mask),
              $sformatf("%s size %0d at %08h: the operand was read",
                        what, opsize, addr));
      end else begin
        // The whole CAS ran again: compared equal, and the update written,
        // every byte, once -- UM 8.2.3.
        check(dut.u_seq.dreg[4][2] === 1'b1,
              $sformatf("CAS %s size %0d at %08h: Z, the compare was equal", what, opsize, addr));
        case (opsize)
          1: begin
            got_w = peek_w(addr & ~32'd1);
            check((addr[0] ? got_w[7:0] : got_w[15:8]) === upd[7:0],
                  $sformatf("CAS %s byte at %08h: the update landed", what, addr));
          end
          2: check(peek_w(addr) === upd[15:0],
                   $sformatf("CAS %s word at %08h: the update landed", what, addr));
          default: check({peek_w(addr), peek_w(addr + 2)} === upd,
                   $sformatf("CAS %s long at %08h: the update landed", what, addr));
        endcase
      end
    end

    $display("core_mmu_paging_tb: %0d cases, %0d faults handled, %0d checks, %0d failed",
             cases_run, faults, checks, fails);
    // Every case must have faulted, or the sweep is testing the plain bus.
    if (fails == 0 && faults == cases_run) $display("PASS: core_mmu_paging_tb");
    else                                   $display("FAIL: core_mmu_paging_tb");
    $finish;
  end

endmodule
