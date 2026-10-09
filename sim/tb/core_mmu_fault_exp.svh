// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- core_mmu_tb: the table search cycles sim/programs/mmu_fault.S's
// phases make. Each fault is a search that fails, the handler's PTEST (no
// writes), and the rerun's search once the handler has repaired the tables.
// Included inside the testbench's initial block.

      exp_walk("mmu_fault", 1, 6, 2);    // invalid: 2+1, PTEST 2, rerun 2+1
      exp_walk("mmu_fault", 3, 6, 2);    // WP: U, PTEST, M
      exp_walk("mmu_fault", 5, 9, 2);    // S: long A (no U), PTEST, rerun with U
      exp_walk("mmu_fault", 7, 2, 1);    // the root limit: no table, no table, then 2
      exp_walk("mmu_fault", 9, 6, 3);    // bus error: A U, PTEST, the repaired A U
      exp_b4("mmu_fault", 9, 2);         // ... the search's and PTEST's
      exp_walk("mmu_fault", 11, 6, 2);   // CAS: U, PTEST, M
      exp_walk("mmu_fault", 13, 8, 2);   // across, read: both pages, PTEST, residual
      exp_walk("mmu_fault", 15, 8, 3);   // across, write: M, U (WP), PTEST, M
      exp_walk("mmu_fault", 17, 4, 1);   // the code page, and the unused prefetch's
      exp_walk("mmu_fault", 19, 8, 2);   // the code page, the prefetch, PTEST, rerun
      exp_walk("mmu_fault", 20, 4, 2);   // the two pages into the data cache
      exp_walk("mmu_fault", 21, 2, 1);   // the write: M for the first page only
