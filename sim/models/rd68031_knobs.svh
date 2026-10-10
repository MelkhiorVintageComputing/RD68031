// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- the slave models' knobs, changed at sim/programs/busprobe.S's
// phases, identically in sim/tb/core_pins_tb.sv and sim/ap030/ap030_tb.sv
// (make ap030). Included inside a module that has the four slaves s32, s16,
// s8 and sB of rd68031_core_harness.svh's map, and calls knob_phase(n) when
// the program writes phase n to $8000.
//
//   8   CIIN on every read of the synchronous port
//   9   ... on the third beat of a burst only
//   10  wait states: 2 on the 32-bit port, 1 on the 16-bit port, 1 before the
//       synchronous port's first beat and 1 before each later one
//   11  back to none

task automatic knob_phase(input int ph);
  case (ph)
    8:  sB.ciin_all = 1'b1;
    9:  begin sB.ciin_all = 1'b0; sB.ciin_beats = 4'b0100; end
    10: begin
          sB.ciin_beats = 4'b0000;
          s32.waits_rt = 2; s16.waits_rt = 1; sB.waits_rt = 1; sB.bwaits_rt = 1;
        end
    11: begin s32.waits_rt = 0; s16.waits_rt = 0; sB.waits_rt = 0; sB.bwaits_rt = 0; end
    default: ;
  endcase
endtask
