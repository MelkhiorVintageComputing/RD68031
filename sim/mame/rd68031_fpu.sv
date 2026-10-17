// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 in MAME (M14 phase B) -- the core, with its coprocessor interface
// built (COPROCESSOR = 1), and RD68884 (Inputs/ip/RD68884, unmodified) as its
// MC68881, as one Verilator model for sim/mame/rd68031_vlt.cpp. Adapted from
// RD68884's sim/tme/rd68021_tme_rd68884.sv, which does the same for RD68021.
//
// The board side of the FPU is RD68884's sys_tb's: a 32-bit port (SIZE and A0
// strapped, FPU table 9-2), a chip select for CpID 1 decoded from FC = 7,
// A19-A16 = 2, A15-A13 = 1 (UM 10.1), DSACK wired-OR with the board's. RESET
// reaches the FPU from the board and from the core's RESET instruction. The
// FPU runs on the core's clock (BUS_SYNC = 1, its same-clock BIU), and is the
// 68881 build: MAME's m68030 presents a 68881 (its FSAVE idle frame is
// $1F18), and the two machines are compared.
//
// The core's own ports are passed through, so the agent drives this model as
// it drives rd68031_top; fpu_cs says an interface-register cycle is on the
// bus, which the agent leaves to the FPU.

module rd68031_fpu #(
    parameter int ICACHE_ENTRIES = 64,
    parameter int DCACHE_ENTRIES = 64
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic  [2:0] fc_o,
    output logic        fc_oe,
    output logic [31:0] a_o,
    output logic        a_oe,
    input  logic [31:0] d_i,
    output logic [31:0] d_o,
    output logic        d_oe,
    output logic  [1:0] siz_o,
    output logic        siz_oe,
    output logic        ecs_n_o,
    output logic        ocs_n_o,
    output logic        rw_o,
    output logic        rw_oe,
    output logic        rmc_n_o,
    output logic        rmc_oe,
    output logic        as_n_o,
    output logic        as_oe,
    output logic        ds_n_o,
    output logic        ds_oe,
    output logic        dben_n_o,
    output logic        dben_oe,
    input  logic  [1:0] dsack_n_i,
    input  logic        sterm_n_i,
    input  logic        ciin_n_i,
    output logic        ciout_n_o,
    output logic        ciout_oe,
    output logic        cbreq_n_o,
    output logic        cbreq_oe,
    input  logic        cback_n_i,
    input  logic  [2:0] ipl_n_i,
    output logic        ipend_n_o,
    input  logic        avec_n_i,
    input  logic        br_n_i,
    output logic        bg_n_o,
    input  logic        bgack_n_i,
    input  logic        berr_n_i,
    input  logic        reset_n_i,
    output logic        reset_n_o,
    output logic        reset_n_oe,
    input  logic        halt_n_i,
    input  logic        cdis_n_i,
    input  logic        mmudis_n_i,
    output logic        refill_n_o,
    output logic        status_n_o,
    output logic        fpu_cs
);

  logic        cs_n;
  logic [31:0] fpu_d_o;
  logic  [3:0] fpu_d_oe;
  logic  [1:0] fpu_dsack_n;
  logic        fpu_dsack_oe;
  logic [31:0] core_d;

  assign cs_n   = !(fc_o == 3'd7 && a_o[19:16] == 4'h2 && a_o[15:13] == 3'd1);
  assign fpu_cs = !cs_n;
  // The core reads the FPU's lanes when it drives them, the board otherwise.
  always_comb begin
    for (int l = 0; l < 4; l++)
      core_d[8*l +: 8] = fpu_d_oe[l] ? fpu_d_o[8*l +: 8] : d_i[8*l +: 8];
  end

  rd68031_top #(.ICACHE_ENTRIES (ICACHE_ENTRIES), .DCACHE_ENTRIES (DCACHE_ENTRIES),
                .COPROCESSOR (1'b1)) u_cpu (
      .clk (clk), .rst_n (rst_n),
      .fc_o (fc_o), .fc_oe (fc_oe), .a_o (a_o), .a_oe (a_oe),
      .d_i (core_d), .d_o (d_o), .d_oe (d_oe),
      .siz_o (siz_o), .siz_oe (siz_oe),
      .ecs_n_o (ecs_n_o), .ocs_n_o (ocs_n_o),
      .rw_o (rw_o), .rw_oe (rw_oe), .rmc_n_o (rmc_n_o), .rmc_oe (rmc_oe),
      .as_n_o (as_n_o), .as_oe (as_oe), .ds_n_o (ds_n_o), .ds_oe (ds_oe),
      .dben_n_o (dben_n_o), .dben_oe (dben_oe),
      .dsack_n_i (dsack_n_i & (fpu_dsack_oe ? fpu_dsack_n : 2'b11)),
      .sterm_n_i (sterm_n_i), .ciin_n_i (ciin_n_i),
      .ciout_n_o (ciout_n_o), .ciout_oe (ciout_oe),
      .cbreq_n_o (cbreq_n_o), .cbreq_oe (cbreq_oe), .cback_n_i (cback_n_i),
      .ipl_n_i (ipl_n_i), .ipend_n_o (ipend_n_o), .avec_n_i (avec_n_i),
      .br_n_i (br_n_i), .bg_n_o (bg_n_o), .bgack_n_i (bgack_n_i),
      .berr_n_i (berr_n_i),
      .reset_n_i (reset_n_i), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
      .halt_n_i (halt_n_i), .cdis_n_i (cdis_n_i), .mmudis_n_i (mmudis_n_i),
      .refill_n_o (refill_n_o), .status_n_o (status_n_o));

  rd68884_top #(.BUS_SYNC (1), .BUS_SYNC_WAIT (0), .MODEL (68881)) u_fpu (
      .clk (clk), .rst_n (rst_n),
      .reset_n_i (reset_n_i && !(reset_n_oe && !reset_n_o)),
      .cs_n_i (cs_n), .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o),
      .size_n_i (1'b1), .a_i ({a_o[4:1], 1'b1}),
      .d_i (d_o), .d_o (fpu_d_o), .d_oe (fpu_d_oe),
      .dsack_n_o (fpu_dsack_n), .dsack_oe (fpu_dsack_oe));

endmodule
