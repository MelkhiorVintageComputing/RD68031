// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- core_mmu_tb: the bus cycles sim/programs/mmu_walk.S's phases make,
// each worked out from UM 9.5 and the program's tables (doc/mmu.md). Included
// inside the testbench's initial block.

      // Two levels, short: A[5] and B[1] with U written, then again for M.
      exp_walk("mmu_walk", 1, 4, 3);
      // FCL, three long levels: two reads each, a U write each.
      exp_walk("mmu_walk", 2, 6, 3);
      exp_walk("mmu_walk", 3, 2, 0);    // PTEST FC1: its long FC descriptor
      // Four levels; then PTEST #1, #2, #3, #4, #7, #7: 1+2+3+4+4+4 reads, no
      // writes at all -- PTEST changes no U bit.
      exp_walk("mmu_walk", 4, 4, 4);
      exp_walk("mmu_walk", 5, 18, 0);
      exp_walk("mmu_walk", 6, 5, 5);    // five levels
      exp_walk("mmu_walk", 7, 5, 0);
      exp_walk("mmu_walk", 8, 2, 1);    // IS: two entries, one U write
      // SRE: SRP's tree and CRP's, U written in each; CRP's again, U set.
      exp_walk("mmu_walk", 10, 6, 4);
      exp_walk("mmu_walk", 12, 2, 1);   // early termination: one read per page
      exp_walk("mmu_walk", 14, 2, 1);   // ... long
      exp_walk("mmu_walk", 15, 4, 0);
      exp_walk("mmu_walk", 16, 0, 0);   // ... at the root: no table at all
      exp_walk("mmu_walk", 17, 0, 0);
      // Indirect: A, the indirect descriptor, the page; U in A and the page
      // only -- the indirect descriptor has none.
      exp_walk("mmu_walk", 18, 3, 2);
      exp_walk("mmu_walk", 19, 6, 0);
      exp_walk("mmu_walk", 20, 6, 2);   // long: two words each
      // The limits and the S/WP PTESTs: 0, 2, 0, 2, 2, 3, then 3 and 3.
      exp_walk("mmu_walk", 21, 15, 0);
      exp_walk("mmu_walk", 22, 3, 0);   // a supervisor violation: no U
      exp_walk("mmu_walk", 23, 3, 2);   // PLOADW, WP: U twice, no M
      // A on the 16-bit port, B on the 8-bit: 2 + 4 cycles a read, 2 + 4 a
      // U write; then both on the synchronous port.
      exp_walk("mmu_walk", 24, 6, 6);
      exp_walk("mmu_walk", 26, 2, 2);
      // The ATC: 22 searches, none, one, none, one, one, one.
      exp_walk("mmu_walk", 30, 22, 0);
      exp_walk("mmu_walk", 31, 0, 0);
      exp_walk("mmu_walk", 32, 1, 0);
      exp_walk("mmu_walk", 33, 0, 0);
      exp_walk("mmu_walk", 34, 1, 0);
      exp_walk("mmu_walk", 35, 1, 0);
      exp_walk("mmu_walk", 36, 1, 0);
      // The CI page: both reads to the bus with CIOUT; the other page once.
      exp_pg("mmu_walk", 40, 2, 2, HAS_DC ? 1 : 2);
      exp_walk("mmu_walk", 40, 4, 3);
      // STATUS: one three-clock indication per search an access starts.
      exp_st3("mmu_walk", 30, 22);
      exp_st3("mmu_walk", 22, 0);       // PLOAD
      $display("  timing: FC, A and B long, a U write at each -- UM 11.7's \"LLLxx\", 53 clocks: %0d",
               c_wclk[2]);
      $display("  timing: one short level, U set -- %0d clocks a search", c_wclk[30] / 22);
      // PS 512 to 16K: one search each, U written by the first.
      exp_walk("mmu_walk", 45, 6, 1);
