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
      // Operands across a cachable page (frame $C000) and a CI page (frame
      // $D000), the data cache on: each cycle's cachability is its own page's
      // (doc/bugs-found.md, M11 phase B). Every cycle's CIOUT is checked
      // against its frame by run_prog; these are how many there are, and the
      // values that depend on whether there is a data cache to hold them.
      exp_fr("mmu_walk", 60, 1, 2);              // the long; then the CI long word, again
      exp_fr("mmu_walk", 61, HAS_DC ? 0 : 1, 0); // the cachable long word was cached
      exp_fr("mmu_walk", 62, 1, 2);              // the same for a word
      exp_fr("mmu_walk", 64, 1, 1);              // CI then cachable
      exp_fr("mmu_walk", 65, HAS_DC ? 0 : 1, 1); // the cachable part cached, the CI part not
      exp_fr("mmu_walk", 66, 1, 1);
      exp_fr("mmu_walk", 67, HAS_DC ? 0 : 1, 0);
      exp_fr("mmu_walk", 68, 1, 1);              // writes: each part its cycle
      exp_fr("mmu_walk", 69, HAS_DC ? 0 : 1, HAS_DC ? 0 : 1);
      exp_fr("mmu_walk", 70, 1, 1);
      exp_fr("mmu_walk", 71, HAS_DC ? 0 : 1, 1);
      exp_fr("mmu_walk", 72, 1, 1);
      exp_fr("mmu_walk", 73, HAS_DC ? 0 : 1, 1);
      exp_fr("mmu_walk", 74, 1, 1);
      exp_fr("mmu_walk", 75, HAS_DC ? 0 : 1, 1);
      // A read of the cachable page's long word, after memory changed behind
      // the cache: the copy the crossing read cached, or memory.
      check(peek_l(32'h0000_8A18) == (HAS_DC ? 32'hE0E1E2E3 : 32'hE4E5E6E7),
            $sformatf("mmu_walk phase 65: the cachable page's long word reads %08h",
                      peek_l(32'h0000_8A18)));
      check(peek_l(32'h0000_8A24) == (HAS_DC ? 32'hF0F1F2F3 : 32'hF4F5F6F7),
            $sformatf("mmu_walk phase 67: the cachable page's long word reads %08h",
                      peek_l(32'h0000_8A24)));
      // The CI page's long word, valid in the cache from before its page was
      // made CI: the write's CI part left it alone (UM 6.1.2.1), and a read
      // hits it whatever CI says (UM 6.1). With no cache, memory.
      check(peek_l(32'h0000_8A2C) == (HAS_DC ? 32'hB0B1B2B3 : 32'h5678B2B3),
            $sformatf("mmu_walk phase 69: the CI page's long word reads %08h",
                      peek_l(32'h0000_8A2C)));
