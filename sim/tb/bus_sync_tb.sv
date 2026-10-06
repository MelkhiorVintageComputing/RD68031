// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 -- synchronous bus cycles: STERM, UM 7.1.7, 7.2.10, 7.3.4 and 7.3.5.
//
// A synchronous cycle is the asynchronous one terminated differently: "otherwise,
// the cycles assert and respond to the same signals, in the same sequence" (UM
// 7.3.4). STERM is sampled on the RISING edge that starts S2 and on every rising
// edge after it, the data is latched on the falling edge after the one it is
// recognised on, and that falling edge starts S3, in which AS, DS and DBEN are
// negated. So a cycle with no wait states is two clocks, and each wait adds one.
//
// What this checks:
//
//   1. The two-clock read and write, pin by pin, on the manual's ruler (tick 0 is
//      the rising edge entering S0), including the two things that differ from an
//      asynchronous cycle: DS is never asserted in a two-clock write (UM 5.6.6),
//      and DBEN is asserted for half a clock on a read (UM 5.6.7).
//   2. Zero to four wait states, reads and writes: the cycle stretches by one
//      clock per wait, and a waited write asserts DS "at the end of S2".
//   3. STERM is a 32-bit port: every operand size and alignment takes the number
//      of cycles Table 7-6's 32-bit column gives, with the right bytes moved.
//   4. Synchronous and asynchronous cycles mixed, including within one operand.
//   5. Table 7-9, STERM with BERR and HALT: all six cases.
//   6. CIIN, sampled with STERM, and on an asynchronous cycle at S4; ignored on
//      writes. CIOUT, from the request.
//   7. STERM with no cycle in progress is ignored (UM 7.2.10).

`timescale 1ns / 1ps

module bus_sync_tb;

`include "rd68031_bus_harness.svh"

  localparam int NTICK = 6;

  logic [NTICK-1:0] ecs_r, ocs_r, as_r, ds_r, dben_r, aoe_r, doe_r, cbreq_r, ciout_r;

  logic [39:0] got;
  logic [39:0] want;
  int unsigned cycles;
  int unsigned t, n, a, w, oc0;
  logic [31:0] addr;
  string       what;

  task automatic record();
    for (t = 0; t < NTICK; t = t + 1) begin
      if (t == 0) @(negedge ecs_n_o);   // the rising edge that enters S0
      else        @(clk);
      #(SNAP);
      ecs_r[NTICK-1-t]   = ecs_n_o;
      ocs_r[NTICK-1-t]   = ocs_n_o;
      as_r[NTICK-1-t]    = as_n_o;
      ds_r[NTICK-1-t]    = ds_n_o;
      dben_r[NTICK-1-t]  = dben_n_o;
      aoe_r[NTICK-1-t]   = a_oe;
      doe_r[NTICK-1-t]   = d_oe;
      cbreq_r[NTICK-1-t] = cbreq_n_o;
      ciout_r[NTICK-1-t] = ciout_oe ? ciout_n_o : 1'b1;   // as the pin, pulled up
    end
  endtask

  task automatic expect_pattern(input string name, input logic [NTICK-1:0] v,
                                input logic [NTICK-1:0] want_v);
    $sformat(what, "%s over S0..: want %b, got %b", name, want_v, v);
    check(v === want_v, what);
  endtask

  // Edge times of the most recent cycle.
  realtime t_as_lo, t_as_hi, t_ds_lo, t_ds_hi, t_ecs_lo, t_ecs_prev;
  int unsigned ds_count;
  initial ds_count = 0;
  always @(negedge as_n_o)  t_as_lo  = $realtime;
  always @(posedge as_n_o)  t_as_hi  = $realtime;
  always @(negedge ds_n_o)  begin t_ds_lo = $realtime; if (rst_n) ds_count = ds_count + 1; end
  always @(posedge ds_n_o)  t_ds_hi  = $realtime;
  always @(negedge ecs_n_o) begin t_ecs_prev = t_ecs_lo; t_ecs_lo = $realtime; end

  function automatic logic [7:0] pat(input logic [31:0] a_);
    pat = 8'h40 ^ a_[7:0] ^ {a_[11:8], 4'h0};
  endfunction

  task automatic paint();
    int unsigned i;
    for (i = 0; i < 4096; i = i + 1) begin
      ss.mem[i]  = pat(i);
      sn.mem[i]  = pat(i);
      s32.mem[i] = pat(i);
      sw.mem[i]  = pat(i);
    end
  endtask

  // The bytes an n-byte operand at a holds, right justified.
  function automatic logic [39:0] expect_at(input logic [31:0] a_, input int nb);
    logic [39:0] v;
    int unsigned i;
    v = '0;
    for (i = 0; i < nb; i = i + 1) v = {v[31:0], pat(a_ + i)};
    expect_at = v;
  endfunction

  function automatic logic [39:0] mask_n(input int nb);
    mask_n = (40'd1 << (8 * nb)) - 40'd1;
  endfunction

  // Table 7-6, the 32-bit column -- the only one a synchronous port has.
  int unsigned t76 [1:4][0:3];

  initial begin
    $display("bus_sync_tb: STERM-terminated cycles, UM 7.3.4 and 7.3.5");
    t76[1][0]=1; t76[1][1]=1; t76[1][2]=1; t76[1][3]=1;
    t76[2][0]=1; t76[2][1]=1; t76[2][2]=1; t76[2][3]=2;
    t76[3][0]=1; t76[3][1]=1; t76[3][2]=2; t76[3][3]=2;   // no row in the table
    t76[4][0]=1; t76[4][1]=2; t76[4][2]=2; t76[4][3]=2;
    reset_dut();
    paint();

    // =====================================================================
    // 1. The two-clock read. UM 7.3.4:
    //
    //   S0  ECS, OCS; address, FC, SIZ, R/W valid; DBEN inactive; CIOUT valid
    //   S1  AS and DS asserted; ECS, OCS negated
    //   S2  DBEN asserted; STERM sampled at the start of S2; data latched at
    //       the end of S2
    //   S3  AS, DS and DBEN negated; address held
    //   --  the next cycle may begin at the rising edge that ends S3
    // =====================================================================
    fork
      record();
      op_read(32'h4000_0100, 4, got, cycles);
    join
    check(got[31:0] === expect_at(32'h100, 4), "two-clock read: the long word (UM 7.3.4)");
    check(cycles == 1, "two-clock read: one bus cycle");
    check(req_end == 3'd6, "two-clock read: req_end is CE_STERM (UM 7.1.7)");
    check(req_dsack == 2'b00, "two-clock read: reported as a 32-bit port (UM 5.6.9)");
    //                         tick 012345
    expect_pattern("2-clock read ECS",  ecs_r,  6'b011111);
    expect_pattern("2-clock read OCS",  ocs_r,  6'b011111);
    expect_pattern("2-clock read AS",   as_r,   6'b100111);   // negated in S3
    expect_pattern("2-clock read DS",   ds_r,   6'b100111);   // follows AS on a read
    expect_pattern("2-clock read DBEN", dben_r, 6'b110111);   // S2 only (UM 5.6.7)
    expect_pattern("2-clock read A_OE", aoe_r,  6'b111100);   // held through S3
    expect_pattern("2-clock read CBREQ", cbreq_r, 6'b111111); // no burst asked
    expect_pattern("2-clock read CIOUT", ciout_r, 6'b111111);
    $sformat(what, "two-clock read: AS asserted for one clock (got %0.1f ns)",
             t_as_hi - t_as_lo);
    check(t_as_hi - t_as_lo == CLK_PERIOD, what);

    // Two synchronous cycles back to back -- a misaligned long word. The second
    // ECS is two clocks after the first: "a two-clock (minimum) bus cycle for
    // 32-bit ports" (UM 7.3.4).
    op_read(32'h4000_0102, 4, got, cycles);
    check(got[31:0] === expect_at(32'h102, 4), "two-clock cycles back to back: data");
    check(cycles == 2, "misaligned long word on a synchronous port: two cycles");
    $sformat(what, "two-clock cycles back to back: ECS to ECS is two clocks (got %0.1f ns)",
             t_ecs_lo - t_ecs_prev);
    check(t_ecs_lo - t_ecs_prev == 2.0 * CLK_PERIOD, what);

    // =====================================================================
    // The two-clock write. UM 7.3.5:
    //
    //   S0  ECS, OCS; address etc.; R/W low
    //   S1  AS asserted, DBEN asserted
    //   S2  data driven; STERM sampled at the start of S2
    //   S3  AS negated; address, data and DBEN held valid throughout S3
    //
    // and "DS is not asserted for two-clock synchronous write cycles" (UM 7.3.5,
    // 5.6.6) -- the device uses CLK, not DS, to latch the data.
    // =====================================================================
    n = ds_count;
    fork
      record();
      op_write(32'h4000_0200, 4, 40'h00_A1B2C3D4, cycles);
    join
    check({ss.mem[12'h200], ss.mem[12'h201], ss.mem[12'h202], ss.mem[12'h203]}
          === 32'hA1B2C3D4, "two-clock write: the device took the long word");
    check(req_end == 3'd6, "two-clock write: req_end is CE_STERM");
    check(ds_count == n, "two-clock write: DS never asserted (UM 5.6.6)");
    //                          tick 012345
    expect_pattern("2-clock write AS",   as_r,   6'b100111);
    expect_pattern("2-clock write DS",   ds_r,   6'b111111);
    expect_pattern("2-clock write DBEN", dben_r, 6'b100011);  // S1 through S3 (UM 7.3.5)
    expect_pattern("2-clock write D_OE", doe_r,  6'b001100);  // S2 and S3
    expect_pattern("2-clock write A_OE", aoe_r,  6'b111100);

    // =====================================================================
    // 2. Wait states. "If STERM is negated at the beginning of S2, wait states
    // are inserted after S2, and STERM is sampled on every rising edge
    // thereafter until it is recognized" (UM 7.3.4 state 2). n waits: AS is
    // asserted for 1 + n clocks. A waited write asserts DS "at the end of S2"
    // (UM 7.3.5 state 2) and negates it with AS: n clocks.
    // =====================================================================
    for (w = 0; w <= 4; w = w + 1) begin
      ss.waits_rt = w;
      addr = 32'h4000_0300 + 16 * w;
      op_read(addr, 4, got, cycles);
      $sformat(what, "read, %0d wait states: data", w);
      check(got[31:0] === expect_at(addr, 4), what);
      $sformat(what, "read, %0d wait states: AS asserted %0d clocks (got %0.1f ns)",
               w, w + 1, t_as_hi - t_as_lo);
      check(t_as_hi - t_as_lo == (w + 1) * CLK_PERIOD, what);
      $sformat(what, "read, %0d wait states: CE_STERM", w);
      check(req_end == 3'd6, what);

      n = ds_count;
      op_write(addr + 8, 4, {8'h00, 8'h5A, w[7:0], 8'hC3, 8'h3C}, cycles);
      $sformat(what, "write, %0d wait states: data", w);
      check({ss.mem[idx12(addr + 8)], ss.mem[idx12(addr + 9)],
             ss.mem[idx12(addr + 10)], ss.mem[idx12(addr + 11)]}
            === {8'h5A, w[7:0], 8'hC3, 8'h3C}, what);
      $sformat(what, "write, %0d wait states: AS asserted %0d clocks", w, w + 1);
      check(t_as_hi - t_as_lo == (w + 1) * CLK_PERIOD, what);
      if (w == 0) begin
        check(ds_count == n, "write, no wait state: DS not asserted (UM 5.6.6)");
      end else begin
        $sformat(what, "write, %0d wait states: DS asserted once (UM 7.3.5)", w);
        check(ds_count == n + 1, what);
        $sformat(what, "write, %0d wait states: DS asserted at the end of S2, one clock after AS",
                 w);
        check(t_ds_lo - t_as_lo == CLK_PERIOD, what);
        $sformat(what, "write, %0d wait states: DS negated with AS, %0d clocks", w, w);
        check((t_ds_hi == t_as_hi) && (t_ds_hi - t_ds_lo == w * CLK_PERIOD), what);
      end
    end
    ss.waits_rt = 0;
    paint();

    // =====================================================================
    // 3. Table 7-6's 32-bit column, both directions. "Synchronous bus cycles
    // ... can only be used to transfer data to and from 32-bit ports" (UM 7),
    // and STERM "indicates that the addressed port size is 32 bits" (UM 5.6.9).
    // One OCS per operand (UM 7.1.1).
    // =====================================================================
    for (n = 1; n <= 4; n = n + 1) begin
      for (a = 0; a < 4; a = a + 1) begin
        addr = 32'h4000_0400 + 32 * n + a;
        oc0 = ocs_count;
        op_read(addr, n, got, cycles);
        $sformat(what, "STERM port, %0d bytes at A1A0=%0d: %0d cycles, Table 7-6 says %0d",
                 n, a, cycles, t76[n][a]);
        check(cycles == t76[n][a], what);
        $sformat(what, "STERM port, %0d bytes at A1A0=%0d: read data", n, a);
        check((got & mask_n(n)) === expect_at(addr, n), what);
        $sformat(what, "STERM port, %0d bytes at A1A0=%0d: one OCS", n, a);
        check(ocs_count == oc0 + 1, what);

        want = {8'h00, 8'hE0 + n[7:0], 8'hD0 + a[7:0], 8'hB7, 8'h96};
        op_write(addr + 16, n, want, cycles);
        $sformat(what, "STERM port, %0d-byte write at A1A0=%0d: %0d cycles", n, a, cycles);
        check(cycles == t76[n][a], what);
        begin
          logic [39:0] g;
          int unsigned i;
          g = '0;
          for (i = 0; i < n; i = i + 1) g = {g[31:0], ss.mem[idx12(addr + 16 + i)]};
          $sformat(what, "STERM port, %0d-byte write at A1A0=%0d: the bytes", n, a);
          check(g === (want & mask_n(n)), what);
          $sformat(what, "STERM port, %0d-byte write at A1A0=%0d: neighbours untouched",
                   n, a);
          check(ss.mem[idx12(addr + 16 + n)] === pat(addr + 16 + n), what);
        end
      end
    end
    paint();

    // =====================================================================
    // 4. Mixed. Asynchronous and synchronous operands alternating, and one
    // operand that crosses from the asynchronous port at $3xxx_xxxx (three wait
    // states) to the synchronous one at $4000_0000 -- "the MC68030 dynamically
    // interprets the port size of the addressed device during each bus cycle"
    // (UM 7.2.1).
    // =====================================================================
    op_read(32'h0000_0500, 4, got, cycles);
    check(got[31:0] === expect_at(32'h500, 4) && req_end == 3'd1,
          "mixed: an asynchronous read ends CE_DSACK");
    op_read(32'h4000_0500, 4, got, cycles);
    check(got[31:0] === expect_at(32'h500, 4) && req_end == 3'd6,
          "mixed: the synchronous read after it ends CE_STERM");
    op_write(32'h0000_0504, 2, 40'h00_0000_1357, cycles);
    op_write(32'h4000_0504, 2, 40'h00_0000_2468, cycles);
    check({s32.mem[12'h504], s32.mem[12'h505]} === 16'h1357, "mixed: asynchronous write");
    check({ss.mem[12'h504], ss.mem[12'h505]} === 16'h2468, "mixed: synchronous write");

    sw.mem[12'hFFE] = 8'h11; sw.mem[12'hFFF] = 8'h22;
    ss.mem[12'h000] = 8'h33; ss.mem[12'h001] = 8'h44;
    op_read(32'h3FFF_FFFE, 4, got, cycles);
    check(got[31:0] === 32'h11223344,
          "mixed within one operand: two bytes from DSACK, two from STERM");
    check(cycles == 2, "mixed within one operand: two cycles");
    op_write(32'h3FFF_FFFE, 4, 40'h00_99887766, cycles);
    check({sw.mem[12'hFFE], sw.mem[12'hFFF], ss.mem[12'h000], ss.mem[12'h001]}
          === 32'h99887766, "mixed within one operand: the write lands on both");
    paint();

    // =====================================================================
    // 5. Table 7-9: STERM, BERR and HALT. "Asserted on rising edge of state N"
    // is S2. For STERM "state N+2 is not part of bus cycle": the late window is
    // the falling edge after the rising edge STERM was recognised on (UM 7.5.1,
    // third case).
    // =====================================================================
    // Case 1: normal.
    op_read(32'h4000_0600, 4, got, cycles);
    check(got[31:0] === expect_at(32'h600, 4) && !req_fault,
          "Table 7-9 case 1: normal termination");

    // Case 3: BERR in lieu of STERM -- nothing answers at $8000_0000.
    begin
      bit sf; logic [31:0] fa;
      fork
        begin
          assert_at_n(1'b1, 1'b0);
          @(posedge req_ack);
          sf = req_fault; fa = flt_addr;
          release_exc();
        end
        op_read(32'h8000_0000, 4, got, cycles);
      join
      check(sf, "Table 7-9 case 3: BERR in lieu of STERM, bus error");
      check(fa === 32'h8000_0000, "Table 7-9 case 3: the faulted address");
    end

    // Case 4: BERR with STERM -- recognised on the falling edge after STERM.
    // The cycle is still two clocks.
    begin
      bit sf;
      fork
        begin
          assert_at_n(1'b1, 1'b0);
          @(posedge req_ack);
          sf = req_fault;
          release_exc();
        end
        op_read(32'h4000_0604, 4, got, cycles);
      join
      check(sf, "Table 7-9 case 4: BERR with STERM is a bus error (UM 7.5.1)");
      check(t_as_hi - t_as_lo == CLK_PERIOD,
            "Table 7-9 case 4: the cycle still ends after two clocks");
    end
    // ... and on a write.
    begin
      bit sw_f;
      fork
        begin
          assert_at_n(1'b1, 1'b0);
          @(posedge req_ack);
          sw_f = req_fault && req_fault_wr;
          release_exc();
        end
        op_write(32'h4000_0608, 4, 40'h00_DEADBEEF, cycles);
      join
      check(sw_f, "Table 7-9 case 4, a write: a bus error, reported as a write");
    end

    // Case 5: BERR and HALT in lieu of STERM -- retry. The device is held off
    // by three wait states so that BERR and HALT come first.
    ss.waits_rt = 3;
    fork
      begin
        assert_at_n(1'b1, 1'b1);
        repeat (2) @(posedge clk);
        berr_drv = 1'b0;
        halt_drv = 1'b0;
      end
      op_read(32'h4000_060C, 4, got, cycles);
    join
    ss.waits_rt = 0;
    check(got[31:0] === expect_at(32'h60C, 4), "Table 7-9 case 5: the retried cycle's data");
    $sformat(what, "Table 7-9 case 5: two cycles, the original and the retry (got %0d)", cycles);
    check(cycles == 2, what);

    // Case 6: BERR and HALT with STERM -- retry.
    fork
      begin
        assert_at_n(1'b1, 1'b1);
        repeat (2) @(posedge clk);
        berr_drv = 1'b0;
        halt_drv = 1'b0;
      end
      op_read(32'h4000_0610, 4, got, cycles);
    join
    check(got[31:0] === expect_at(32'h610, 4), "Table 7-9 case 6: the retried cycle's data");
    $sformat(what, "Table 7-9 case 6: two cycles (got %0d)", cycles);
    check(cycles == 2, what);

    // Case 2: HALT with STERM -- the cycle completes, then the bus halts until
    // HALT is negated (UM 7.5.3).
    fork
      assert_at_n(1'b0, 1'b1);
      op_read(32'h4000_0614, 4, got, cycles);
    join
    check(got[31:0] === expect_at(32'h614, 4), "Table 7-9 case 2: the cycle completes");
    repeat (2) @(posedge clk);
    check(as_n_o === 1'b1 && as_oe === 1'b1, "halted: AS negated and driven (UM 7.5.3)");
    check(a_oe === 1'b1, "halted: the address remains driven (UM 7.5.3)");
    n = as_count;
    fork
      begin
        repeat (6) @(posedge clk);
        check(as_count == n, "halted: no cycle starts while HALT is asserted");
        halt_drv = 1'b0;
      end
      op_read(32'h4000_0618, 4, got, cycles);
    join
    check(got[31:0] === expect_at(32'h618, 4), "halted: the next cycle runs once HALT negates");

    // =====================================================================
    // 6. CIIN and CIOUT.
    // =====================================================================
    // "The assertion or negation of CBACK and CIIN is internally latched on the
    // rising edge of the clock for which STERM is asserted" (UM 7.2.10).
    ss.ciin_all = 1'b1;
    op_read(32'h4000_0700, 4, got, cycles);
    check(req_ciin === 1'b1, "CIIN on a synchronous read: returned with the operand (UM 5.7.1)");
    check(beat_ciin === 1'b1, "CIIN on a synchronous read: the beat reports it too");
    op_write(32'h4000_0704, 4, 40'h00_01020304, cycles);
    check(req_ciin === 1'b0, "CIIN on a write: ignored (UM 5.7.1)");
    ss.ciin_all = 1'b0;
    op_read(32'h4000_0700, 4, got, cycles);
    check(req_ciin === 1'b0, "CIIN negated: not reported");
    // An asynchronous cycle latches it "on the rising edge of bus cycle state 4"
    // (UM 7.2.8).
    s32.ciin_all = 1'b1;
    op_read(32'h0000_0700, 4, got, cycles);
    check(req_ciin === 1'b1, "CIIN on an asynchronous read: latched at S4 (UM 7.2.8)");
    s32.ciin_all = 1'b0;
    // A misaligned word on the asynchronous 32-bit port is two cycles; CIIN on
    // both is reported once, for the operand.
    s32.ciin_all = 1'b1;
    op_read(32'h0000_0703, 2, got, cycles);
    check(req_ciin === 1'b1 && cycles == 2, "CIIN on a two-cycle operand: reported");
    s32.ciin_all = 1'b0;

    // CIOUT "becomes valid" in S0 with the address, for the whole cycle (UM 7.3.4
    // state 0); it is in the address group, released with it (specification 7).
    req_ciout = 1'b1;
    fork
      record();
      op_read(32'h4000_0710, 4, got, cycles);
    join
    req_ciout = 1'b0;
    //                     tick 012345
    expect_pattern("CIOUT", ciout_r, 6'b000011);
    check(got[31:0] === expect_at(32'h710, 4), "CIOUT: the read is otherwise unchanged");
    op_read(32'h4000_0710, 4, got, cycles);
    check(ciout_n_o === 1'b1, "CIOUT: negated for a request that does not ask for it");

    // =====================================================================
    // 7. "If STERM is asserted and no cycle is in progress ... STERM is
    // ignored by the MC68030" (UM 7.2.10).
    // =====================================================================
    repeat (2) @(posedge clk);
    n = as_count;
    check(bus_idle, "idle before the stray STERM");
    @(posedge clk); sterm_force = 1'b1;
    repeat (4) @(posedge clk);
    sterm_force = 1'b0;
    repeat (2) @(posedge clk);
    check(bus_idle && as_count == n, "a STERM with no cycle in progress is ignored (UM 7.2.10)");
    op_read(32'h0000_0720, 4, got, cycles);
    check(got[31:0] === expect_at(32'h720, 4) && req_end == 3'd1,
          "after a stray STERM, an asynchronous cycle runs normally");

    $display("bus_sync_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_sync_tb");
    else                                     $display("FAIL: bus_sync_tb");
    $finish;
  end

  function automatic int unsigned idx12(input logic [31:0] a_);
    idx12 = a_ % 4096;
  endfunction

  initial begin
    #2_000_000;
    $display("FAIL: bus_sync_tb timed out");
    $finish;
  end

endmodule
