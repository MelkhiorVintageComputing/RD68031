// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- copy-on-write through the MC68030's MMU: core_cow_tb with the
// pages protected by the core's own translation tables instead of by the
// testbench. sim/programs/cow.S built with -DCOW_MMU; core_cow_tb.sv has the
// whole description.

`define COW_MMU
`include "core_cow_tb.sv"
