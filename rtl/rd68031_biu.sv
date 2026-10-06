// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// RD68031 - SystemVerilog MC68030
//
// Bus interface unit. Owns every pin and every clock.
//
// ONE BUS STATE PER CLK HALF PERIOD. Even-numbered states begin on a rising edge
// and odd-numbered ones on a falling edge, so an asynchronous bus cycle with no
// wait states is three clocks (UM 7.3.1) and a synchronous one two (UM 7.3.4).
// The state machine is two registers, one per edge, each computing its next state
// from the other.
//
// THREE KINDS OF CYCLE, AND THE CYCLE DOES NOT KNOW WHICH IT IS UNTIL IT ENDS.
// Every cycle starts the same way (UM 7.3.4: a synchronous cycle "asserts and
// responds to the same signals, in the same sequence"); the device decides by how
// it terminates it:
//
//   - DSACK1/DSACK0, sampled on the falling edges (UM 7.3.1 state 3): the
//     asynchronous cycle inherited from the MC68020, three clocks at least, with
//     dynamic bus sizing;
//   - STERM, sampled on the rising edges (UM 7.3.4 state 2): a 32-bit port, two
//     clocks at least;
//   - STERM with CBACK on a cycle that asserted CBREQ: a burst, up to four long
//     words with AS held throughout (UM 7.3.7).
//
// THE UNIT OF THE CONTRACT IS AN OPERAND, NOT A BUS CYCLE. A requester presents
// one request and stalls until req_ack; this unit splits it into the one to four
// bus cycles Table 7-6 requires for that size, alignment and port width, drives
// SIZ1/SIZ0 with the number of bytes REMAINING (UM 7.2.1), routes the byte lanes
// per Tables 7-4 and 7-5, and assembles the result. Nothing above this line knows
// how wide the port was, or whether it was synchronous.
//
// That is also what makes OCS correct for free: UM 7.1.1 asserts ECS at the start
// of every bus cycle and OCS only at the start of the first cycle *of an operand*,
// and "operand" there is exactly this handshake.
//
// A burst fills a cache line, which is not an operand: its beats are reported one
// by one on the beat_* port, for the caches of M10, and the operand that asked for
// it completes as soon as its own bytes have arrived (UM 6.1.3.2, "when data from
// the first cycle is returned, it is immediately available for the execution
// unit"), while the burst runs on.

module rd68031_biu #(
    parameter bit ADDR_HIZ_BETWEEN_CYCLES = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    // Operand request from the sequencer ------------------------------------
    input  logic        req_valid,
    input  logic  [2:0] req_kind,
    input  logic  [2:0] req_fc,
    input  logic [31:0] req_addr,
    input  logic  [2:0] req_bytes,
    input  logic [39:0] req_wdata,
    input  logic        req_rmc,
    input  logic  [3:0] req_cpuspace,
    input  logic  [7:0] req_cpuaddr,
    input  logic        req_cpfault,
    // A line fill may be requested for this operand: CBREQ is asserted on the
    // cycle that qualifies (UM 7.3.7, 6.1.3.2). The caches of M10 drive it;
    // today's requesters tie it off.
    input  logic        req_burst,
    // CIOUT for this operand: the CI bit of the ATC entry or of the TTx register
    // that matched (UM 5.7.2). The MMU of M11 drives it; tied off today.
    input  logic        req_ciout,
    // A posted write -- UM20 8.1.3, doc/checkpoint.md rule 9. It gets no
    // acknowledge: `req_taken` says it has been taken, the clock after, and
    // the requester goes on. `post_busy` says one is still outstanding, and a
    // fault on it is `req_fault` with `req_fault_post`.
    input  logic        req_post,
    output logic        req_taken,
    output logic        post_busy,
    output logic        req_fault_post,
    output logic        req_ack,
    output logic        req_last,
    // The data operand finishes cleanly at the rising edge that ends S5 -- no
    // bus error, no retry. A falling-edge register, valid for that half clock.
    output logic        req_early,
    output logic [39:0] req_rdata,
    output logic  [2:0] req_end,
    output logic        req_fault,
    output logic        req_fault_wr,
    output logic  [1:0] req_dsack,
    // CIIN was asserted on a read cycle that carried bytes of this operand --
    // UM 5.7.1, "interpreted on a bus-cycle-by-bus-cycle basis", "ignored
    // during all write cycles". Valid with req_ack.
    output logic        req_ciin,

    // The residual of the in-flight operand, for the fault frame -------------
    output logic [31:0] flt_addr,
    output logic  [2:0] flt_bytes,
    output logic  [2:0] flt_fc,
    output logic        flt_rw,
    output logic        flt_rmc,
    output logic [31:0] flt_dob,
    output logic [31:0] flt_dib,

    // ... and back in, when RTE says to finish it ----------------------------
    input  logic        rst_op_valid,
    // The microword RTE resumed has retired without asking for an operand: the
    // fault was an instruction prefetch at a boundary, and there is nothing to
    // hand back. Whatever is pending is dropped.
    input  logic        rst_cancel,
    // The operand handed back is a posted write: run it now, for nobody.
    input  logic        rst_post,
    input  logic [31:0] rst_addr,
    input  logic  [2:0] rst_bytes,
    input  logic  [2:0] rst_fc,
    input  logic        rst_rw,
    input  logic        rst_rmc,
    input  logic [31:0] rst_dob,

    // Instruction fetch ------------------------------------------------------
    input  logic        fetch_valid,
    input  logic [31:0] fetch_addr,
    input  logic  [2:0] fetch_fc,
    input  logic        fetch_burst,
    input  logic        fetch_ciout,
    output logic        fetch_ack,
    output logic        fetch_last,
    output logic [31:0] fetch_rdata,
    output logic        fetch_fault,
    output logic        fetch_ciin,
    input  logic        bus_abort,

    // Every read bus cycle, and every beat of a burst, as it ends ------------
    // One clock per beat, registered on the rising edge that ends it. This is
    // what fills a cache entry: the whole of the 32 bits latched, the address
    // of the long word they are (for a burst beat, A3/A2 as the system
    // incremented them -- UM 7.3.7), the port that answered and its CIIN.
    output logic        beat_valid,   // the beat ended normally
    output logic        beat_err,     // ... or with a bus error: its entry is invalid
    output logic [31:0] beat_data,
    output logic [31:0] beat_addr,
    output logic  [1:0] beat_num,     // 0 is the cycle the requester asked for
    output logic  [1:0] beat_port,    // the DSACK encoding; a synchronous beat is 32
    output logic        beat_ciin,
    output logic        beat_fetch,   // the operand was an instruction prefetch

    // Status -----------------------------------------------------------------
    input  logic        reset_req,
    output logic        reset_busy,
    input  logic        dbf,
    // What the microsequencer tells the STATUS and REFILL pins -- UM 12.7.1.
    // Each a one-clock pulse, registered on a rising edge.
    input  logic        sts_bound,    // an instruction boundary
    input  logic        sts_pend,     // ... at which a trace or interrupt is taken
    input  logic        sts_exc,      // exception processing begins
    input  logic        sts_refill,   // the pipeline is refilled
    output logic  [2:0] ipl_sync_n,
    output logic        reset_sync_n,
    output logic        halt_sync_n,
    output logic        cdis_sync_n,
    output logic        mmudis_sync_n,
    output logic        bus_idle,
    output logic        bus_granted,

    // Pins -------------------------------------------------------------------
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
    output logic        status_n_o
);

  // iverilog rejects a declaration inside an unnamed begin/end, so every loop
  // variable lives at module scope -- and each always_comb needs its own, or a
  // shared one is reported as MULTIDRIVEN by the lint pass.
  int unsigned i_v;
  int unsigned i_rv;
  int unsigned i_rd;
  int unsigned i_wr;

  // ==========================================================================
  // Input synchronisers -- UM 7.1, figures 7-1 and 7-2
  //
  // "For all asynchronous inputs, the processor latches the level of the input
  // during a sample window around the falling edge of the clock signal", so both
  // ranks are negedge. DSACK, BERR, HALT and AVEC are not here: they go straight
  // to the falling-edge next-state logic, which is the sample UM 7.3.1 describes
  // and which must not have a rank of latency added to it. STERM, CBACK and CIIN
  // are not here either: they are SYNCHRONOUS inputs (UM 7.1), "externally
  // synchronized to the processor clock", and are sampled on the rising edges.
  // ==========================================================================
  rd68031_sync #(.WIDTH (3), .RESET_VAL (3'b111)) u_sync_ipl (
      .clk (clk), .rst_n (rst_n), .d (ipl_n_i), .q (ipl_sync_n));

  rd68031_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_reset (
      .clk (clk), .rst_n (rst_n), .d (reset_n_i), .q (reset_sync_n));

  rd68031_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_halt (
      .clk (clk), .rst_n (rst_n), .d (halt_n_i), .q (halt_sync_n));

  rd68031_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_cdis (
      .clk (clk), .rst_n (rst_n), .d (cdis_n_i), .q (cdis_sync_n));

  // UM 5.11.2: MMUDIS "dynamically disables the translation of addresses by the
  // MMU". The MMU is M11; until then the synchronised level goes to the top
  // level's sink.
  rd68031_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_mmudis (
      .clk (clk), .rst_n (rst_n), .d (mmudis_n_i), .q (mmudis_sync_n));

  logic br_sync_n;
  logic bgack_sync_n;
  logic hiz_q;

  rd68031_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_br (
      .clk (clk), .rst_n (rst_n), .d (br_n_i), .q (br_sync_n));

  rd68031_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_bgack (
      .clk (clk), .rst_n (rst_n), .d (bgack_n_i), .q (bgack_sync_n));

  // ==========================================================================
  // The operand in flight
  //
  // op_rem is the number of bytes still to move. It is what drives SIZ1/SIZ0, it
  // is what the fault frame records as the residual, and it reaching zero is what
  // acknowledges the request.
  // ==========================================================================
  logic        op_active;
  logic [31:0] op_addr;
  logic  [2:0] op_rem;
  logic  [2:0] op_fc;
  logic        op_rw;        // 1 = read
  logic        op_rmc;
  logic        op_first;     // no bus cycle of this operand has started yet -- OCS
  logic        op_isfetch;   // the request came from the instruction fetch unit
  logic        op_posted;    // a posted write: no acknowledge -- rule 9
  logic        rst_post_q;   // the operand RTE handed back is a posted write
  // A bus error on this CPU-space operand is a bus error and not an answer: a
  // coprocessor interface register other than the one that starts an
  // instruction -- UM20 7.5.2.8.
  logic        op_cpflt;
  // A line fill may be asked for (req_burst / fetch_burst), and whether one has
  // been: UM 6.1.3.2 asserts CBREQ once, and a second read cycle for the rest of
  // a misaligned operand goes "with CBREQ negated".
  logic        op_burst;
  logic        op_brq_used;
  logic        op_ciout;
  logic        op_ciin;      // CIIN seen on a cycle that carried operand bytes

  // Declared here, above the logic that reads them, rather than beside the
  // logic that drives them: Quartus, Vivado and Questa all refuse a use above
  // the declaration, and tools/src_lint.py holds `make lint` to that.
  logic        rst_pend_q;
  logic        rsto_q;
  logic [39:0] op_data;      // write data, or the read accumulator, right justified

  // The result of the last completed operand of each kind, held until the next
  // one of that kind completes. op_data cannot serve: it is the accumulator of
  // the operand in flight, and the instruction fetch unit refills the pipe by
  // itself, so a prefetch starting in the clock after a data read would destroy
  // the data before the sequencer had read it.
  logic [39:0] rdata_q;
  logic [31:0] frdata_q;

  // The cycle in flight, latched at the rising edge entering S0 so that every pin
  // is stable for the whole cycle whatever the operand state does. A burst holds
  // all of them for its whole length: "the address bus of the MC68030 remains
  // driven to a constant value for the duration of a burst transfer operation"
  // (UM 7.3.7).
  logic [31:0] cyc_addr;
  logic  [2:0] cyc_fc;
  logic  [1:0] cyc_siz;
  logic  [2:0] cyc_n;        // bytes this cycle asks for: min(op_rem, 4)
  logic        cyc_rw;
  logic        cyc_brq;      // CBREQ is asserted for this cycle
  logic        cyc_ciout;

  // ==========================================================================
  // Bus state. Two registers, one per edge.
  //
  //   st_p holds S0, S2, S4, WH, BH, IDLE, HALT or RETRY  (rising edge)
  //   st_n holds S1, S3, WL, S5, BL, BW or IDLE           (falling edge)
  //
  // WH/WL are the wait pair inserted between S3 and S4: UM 7.3.1 state 3, "if wait
  // states are added, the processor continues to sample the DSACKx signals on the
  // falling edges of the clock until one is recognized", so one wait is one whole
  // clock and the sample repeats at ST_WL. The same pair serves a synchronous
  // cycle's waits, whose STERM sample is at ST_WH: "if STERM is negated at the
  // beginning of S2, wait states are inserted after S2, and STERM is sampled on
  // every rising edge thereafter until it is recognized" (UM 7.3.4 state 2).
  //
  // ST_S5 is the half clock in which a cycle ENDS, whichever way it ends: the
  // asynchronous cycle's S5, and the synchronous cycle's S3, which UM 7.3.4
  // describes in the same words -- "the processor negates AS, DS, and DBEN"; the
  // address and the rest stay valid; the next cycle may start at the rising edge
  // that ends it.
  //
  // BL, BH and BW are the burst: BL is the half clock after a long word has been
  // latched with the burst continuing (the manual's S3, S5 and S7, AS held), BH
  // the rising edge that tests STERM for the next long word (S4, S6, S8), and BW
  // a wait state between them (UM 7.3.7 state 4, "wait states are inserted
  // instead of S4 and S5").
  // ==========================================================================
  rd68031_pkg::bus_state_e st_p, st_p_nxt;
  rd68031_pkg::bus_state_e st_n, st_n_nxt;

  logic [1:0] dsack_q;       // the port size sampled by DSACKx
  logic [2:0] end_now;       // how the cycle now ending ended, live
  logic [2:0] req_end_q;     // ... and the copy the sequencer is given
  logic       term_q;        // ... and whether it terminated the cycle at all
  logic       term_err;      // ... as a bus error (Table 7-8 cases 3 and 4)
  logic       term_rty;      // ... as a retry (cases 5 and 6)
  logic       term_hlt;      // ... normally, but with HALT asserted (case 2)
  logic       term_avc;      // ... by AVEC, on an interrupt acknowledge cycle
  logic       term_syn;      // ... by STERM
  logic       term_bfe;      // ... a burst fill beat ended by BERR (UM 7.5.1)

  // The synchronous inputs as the last rising-edge sample saw them -- UM 7.2.10:
  // "the assertion or negation of CBACK and CIIN is internally latched on the
  // rising edge of the clock for which STERM is asserted". For a cycle ended
  // by DSACKx, CIIN is "latched on the rising edge of bus cycle state 4"
  // (UM 7.2.8, 7.2.9), and that is the same register.
  logic       sterm_q;
  logic       cback_q;
  logic       ciin_q;

  // How many long words this cycle has latched, counted on the falling edges
  // that latch them. A burst stops at four (UM 7.3.7), and CBREQ is negated
  // after the third (state 7).
  logic [2:0] beat_q;

  // RMC is a qualifier held across a run of ordinary cycles, not a cycle kind
  // (UM 7.3.3). It is raised by the first request of the run and stays up until
  // a request without it starts a cycle -- which is exactly UM 7.1.1's "RMC is
  // guaranteed to be negated before the end of state 0 for a bus cycle following
  // a read-modify-write operation" -- or until the bus goes idle without one.
  logic rmc_hold;

  // UM 7.5.3: HALT alone does not terminate a cycle; it stops the next one. While
  // halted the data bus goes high impedance and the bus control signals are driven
  // inactive, but the address, FC, SIZ and R/W "remain in the same state" --
  // driven, not released, which is what distinguishes this from an ordinary idle
  // bus.
  logic halt_hold;

  // ---------------------------------------------------------------------------
  // Bus arbitration -- UM 7.7.4
  // ---------------------------------------------------------------------------
  rd68031_pkg::arb_state_e arb, arb_nxt;

  logic arb_r;   // BR, synchronised and in positive logic
  logic arb_a;   // BGACK, likewise
  assign arb_r = ~br_sync_n;
  assign arb_a = ~bgack_sync_n;

  // "The BG output will not be asserted while RMC is asserted" -- the note under
  // figure 7-61, and 7.7.4: the arbiter ignores "bus requests (assertions of BR)
  // that occur after the first read cycle of the read-modify-write sequence".
  //
  // The one exception is that first read cycle: "the MC68030 allows normal bus
  // arbitration during this read cycle; a normal relinquish and retry operation
  // (asserting BERR, HALT, and BR at the same time) is used" (UM 7.7.4), and
  // "the MC68030 does not relinquish the bus during a read-modify-write
  // operation, except during the first read cycle" (UM 7.5.2). So while the
  // first bus cycle of a locked run is waiting to be retried, the lock does not
  // hold the bus.
  logic rmc_first_q;   // the cycle under way is the first of a locked run
  logic rmc_lock;
  assign rmc_lock = rmc_hold
                 && !(rmc_first_q && (st_p == rd68031_pkg::ST_RETRY));

  logic arb_req;
  assign arb_req = arb_r && !rmc_lock;

  function automatic logic arb_g_of(input rd68031_pkg::arb_state_e st);
    arb_g_of = (st == rd68031_pkg::ARB_GRANT) || (st == rd68031_pkg::ARB_WAIT)
            || (st == rd68031_pkg::ARB_REGRANT) || (st == rd68031_pkg::ARB_REWAIT);
  endfunction

  function automatic logic arb_t_of(input rd68031_pkg::arb_state_e st);
    arb_t_of = (st != rd68031_pkg::ARB_IDLE);
  endfunction

  // The operand finishes with the cycle (or the burst beat) that is ending now.
  // This is the signal the whole handshake turns on: req_last exports it, and the
  // sequencer is expected to have the next request already presented by the
  // rising edge that consumes it -- which is what the microword's successor
  // previews are for.
  logic op_finishing;
  logic op_continuing;

  // A request is available to start a bus cycle. Data beats instruction fetch:
  // the sequencer is stalled on a data operand and the pipe is not.
  //
  // The arbiter's NEXT state decides whether a cycle may start, not its current
  // one. Reading the current state there is a real bug with a real failure mode:
  // on the single edge where the arbiter reaches its granting state, a cycle
  // begins anyway and then runs with its address bus already in high impedance,
  // which on the MC68010 project cost a long-word read one of its two words every
  // few thousand DMA transfers.
  logic want_cycle;
  // RTE has a posted write to rerun, and the edge a posted write faults on.
  logic rst_self, post_flt_end;
  // Nothing new starts on the edge a posted write ends in a bus error: the
  // sequencer is about to take it, and with nothing taken the state machine
  // would go to S0 by its retry arm and run the faulted write again.
  assign want_cycle = op_continuing
                   || (!post_flt_end && (req_valid || fetch_valid || rst_self));

  logic bus_is_idle;
  assign bus_is_idle = (st_p == rd68031_pkg::ST_IDLE)
                       && (st_n == rd68031_pkg::ST_IDLE);

  // HALT stops the NEXT cycle from starting, whether the bus was busy or idle
  // when it came: "the MC68030 halts external bus activity at the next bus
  // cycle boundary" (UM 7.5.3). Synchronised, as every asynchronous input
  // other than the termination samples is.
  logic start_ok;
  assign start_ok = want_cycle && halt_sync_n && !arb_t_of(arb_nxt);

  // Retry clears when BOTH BERR and HALT have been negated -- UM 7.5.2, "does not
  // begin another bus cycle until the HALT signal is negated by external logic",
  // and BERR "should be negated before S2 of the read cycle".
  //
  // Sampled on the FALLING edge, like every other use of these two pins. They
  // are asynchronous inputs, which UM 7.1 latches "during a sample window around
  // the falling edge of the clock" and specifications 47A and 47B bound only
  // there; a device is free to move them at a rising edge -- UM 7.5 even
  // recommends it. This was the raw pins, read by the rising-edge state
  // register's next-state logic, which is a metastable sample of a multi-bit
  // register exactly where a device changes them (doc/bugs-found.md, M3). One
  // falling-edge flop, as the termination samples are: no synchroniser rank is
  // added, so the restart is at most half a clock later than it was.
  logic retry_clr_q;
  logic retry_clear;
  assign retry_clear = retry_clr_q;

  // The asynchronous termination inputs, in positive logic, for the falling-edge
  // samples; and the synchronous ones, for the rising-edge samples.
  logic berr_s, halt_s, avec_s;
  logic sterm_s, cback_s, ciin_s;
  assign berr_s  = ~berr_n_i;
  // AVEC is active low and is sampled on the same edge as DSACK. Only an
  // interrupt acknowledge cycle means anything by it -- UM 7.1.7.
  assign avec_s  = avec_n_i;
  assign halt_s  = ~halt_n_i;
  assign sterm_s = ~sterm_n_i;
  assign cback_s = ~cback_n_i;
  assign ciin_s  = ~ciin_n_i;

  // The burst goes on past the long word being latched at this falling edge.
  // UM 7.3.7: "burst mode is only initiated if both of these signals [CBREQ and
  // CBACK] are asserted for a synchronous cycle"; it is aborted by "CIIN
  // asserted, BERR asserted, or CBACK negated prematurely"; and "the MC68030
  // allows a burst of as many as four long words".
  logic burst_go;
  assign burst_go = cyc_brq && sterm_q && cback_q && !ciin_q && !berr_s
                 && (beat_q < 3'd3);

  // The if/else inside each case item is not a style choice: iverilog rejects a
  // ternary of two enum values assigned to an enum variable with "This assignment
  // requires an explicit cast" (doc/coding-standard.md, measured).
  always_comb begin
    st_p_nxt = st_p;
    if (st_p == rd68031_pkg::ST_RETRY) begin
      // UM 7.5.2: "after a synchronization delay, the processor retries the
      // previous cycle using the same access information". Nothing in cyc_* or
      // op_* was updated by the faulted cycle, so re-entering S0 reissues it --
      // with CBREQ again, if it had it: "on the initial access of a burst
      // operation, a retry ... causes the processor to retry the bus cycle and
      // assert CBREQ again".
      if (retry_clear && !arb_t_of(arb_nxt)) st_p_nxt = rd68031_pkg::ST_S0;
      else                                   st_p_nxt = rd68031_pkg::ST_RETRY;
    end else if (st_p == rd68031_pkg::ST_HALT) begin
      if (!halt_sync_n)                st_p_nxt = rd68031_pkg::ST_HALT;
      else if (start_ok)               st_p_nxt = rd68031_pkg::ST_S0;
      else                             st_p_nxt = rd68031_pkg::ST_IDLE;
    end else begin
      unique case (st_n)
      rd68031_pkg::ST_IDLE: begin
        if (start_ok) st_p_nxt = rd68031_pkg::ST_S0;
        else          st_p_nxt = rd68031_pkg::ST_IDLE;
      end
      rd68031_pkg::ST_S1: st_p_nxt = rd68031_pkg::ST_S2;
      rd68031_pkg::ST_S3: begin
        if (term_q) st_p_nxt = rd68031_pkg::ST_S4;
        else        st_p_nxt = rd68031_pkg::ST_WH;
      end
      rd68031_pkg::ST_WL: begin
        if (term_q) st_p_nxt = rd68031_pkg::ST_S4;
        else        st_p_nxt = rd68031_pkg::ST_WH;
      end
      // A burst: the next long word is tested for on this rising edge, whether
      // the last one was latched (state 4) or not yet (a wait state).
      rd68031_pkg::ST_BL,
      rd68031_pkg::ST_BW: st_p_nxt = rd68031_pkg::ST_BH;
      // The rising edge that ends S5. Table 7-8 decides where it goes. A burst
      // passes through here once, at its end: "for the purposes of halting the
      // processor or arbitrating the bus away from the processor with BR, a
      // burst operation is a single cycle" (UM 7.3.7).
      rd68031_pkg::ST_S5: begin
        if (term_rty)                st_p_nxt = rd68031_pkg::ST_RETRY;
        else if (term_hlt || !halt_sync_n)
                                     st_p_nxt = rd68031_pkg::ST_HALT;
        else if (start_ok)           st_p_nxt = rd68031_pkg::ST_S0;
        else                         st_p_nxt = rd68031_pkg::ST_IDLE;
      end
      default: st_p_nxt = rd68031_pkg::ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // The arbiter's next state -- UM figure 7-61, all seven states
  //
  // Read off a rendering of the figure (its overbars are lost in the text
  // layer, not on the page). R is BR and A is BGACK, both synchronised; G is
  // BG and T the three-state control. Each arc is the figure's label:
  //
  //   0 --RA'--> 1    0 --XA--> 4    0 --R'A'--> 0
  //   1 --XX---> 2
  //   2 --RA'--> 2    2 --XA or R'A'--> 3
  //   3 --XX---> 4
  //   4 --R'A--> 4    4 --R'A'--> 0  4 --RX--> 5
  //   5 --XX---> 6
  //   6 --RA---> 6    6 --RA'--> 2   6 --R'X--> 3
  //
  // 0-1-2-3-4-0 is the ordinary relinquish 7.7.4 walks through in prose. 0-4 is
  // single-wire arbitration: "BGACK alone can be used to place the processor's
  // external bus buffers in the high-impedance state". 4-5-6 is the re-grant of
  // 7.7.3, "if a BR is still pending after the assertion of BGACK, another BG is
  // asserted within a few clocks of the negation of BG", with "the processor
  // does not perform any external bus cycles before it reasserts BG" -- T stays
  // asserted throughout -- and state 6 holds that grant for as long as the old
  // master still asserts BGACK, handing over to state 2 to wait for the new
  // one's.
  //
  // R is the request as the RMC lock leaves it wherever it can assert G:
  // "the BG output will not be asserted while RMC is asserted".
  // ---------------------------------------------------------------------------
  always_comb begin
    arb_nxt = arb;
    unique case (arb)
      // "Request R and acknowledge A keep the arbiter in state 0 as long as they
      // are both negated. When a request R is received, both grant G and signal T
      // are asserted" -- "except when the MC68030 has made an internal decision
      // to execute a bus cycle. Then, the assertion of BG is deferred until the
      // bus cycle has begun" (UM 7.7).
      //
      // That deferral is exactly one edge: the edge on which an idle bus with a
      // request pending enters S0. Testing st_p_nxt for it would be the direct
      // transcription and is a combinational loop -- st_p_nxt depends on
      // start_ok, which depends on this state -- so the test is on the registered
      // state instead, which says the same thing one expression earlier. A bus
      // held by HALT has made no such decision, and does not defer.
      rd68031_pkg::ARB_IDLE: begin
        if (arb_a)
          arb_nxt = rd68031_pkg::ARB_HELD;
        else if (arb_req && !(bus_is_idle && want_cycle && halt_sync_n))
          arb_nxt = rd68031_pkg::ARB_GRANT;
        else
          arb_nxt = rd68031_pkg::ARB_IDLE;
      end
      // "The next clock causes a change to state 2."
      rd68031_pkg::ARB_GRANT: arb_nxt = rd68031_pkg::ARB_WAIT;
      // "The bus arbiter remains in that state until acknowledge A is asserted or
      // request R is negated."
      rd68031_pkg::ARB_WAIT: begin
        if (arb_a || !arb_r) arb_nxt = rd68031_pkg::ARB_DROP;
        else                 arb_nxt = rd68031_pkg::ARB_WAIT;
      end
      // "The next clock takes the arbiter to state 4."
      rd68031_pkg::ARB_DROP: arb_nxt = rd68031_pkg::ARB_HELD;
      // "With acknowledge A asserted, the arbiter remains in state 4 until A is
      // negated or request R is again asserted. When A is negated, the arbiter
      // returns to the original state."
      rd68031_pkg::ARB_HELD: begin
        if (arb_req)     arb_nxt = rd68031_pkg::ARB_REGRANT;
        else if (!arb_a) arb_nxt = rd68031_pkg::ARB_IDLE;
        else             arb_nxt = rd68031_pkg::ARB_HELD;
      end
      rd68031_pkg::ARB_REGRANT: arb_nxt = rd68031_pkg::ARB_REWAIT;
      rd68031_pkg::ARB_REWAIT: begin
        if (!arb_r)      arb_nxt = rd68031_pkg::ARB_DROP;
        else if (!arb_a) arb_nxt = rd68031_pkg::ARB_WAIT;
        else             arb_nxt = rd68031_pkg::ARB_REWAIT;
      end
      default: arb_nxt = rd68031_pkg::ARB_IDLE;
    endcase
  end

  // The falling-edge state. Two of the rising-edge states, S2 and WH, are where a
  // synchronous cycle may have been terminated, and BH is where a burst beat is:
  // "once STERM is recognized, data is latched on the next falling edge of the
  // clock (corresponding to the beginning of S3)" (UM 7.3.4 state 2).
  always_comb begin
    st_n_nxt = st_n;
    unique case (st_p)
      rd68031_pkg::ST_S0:   st_n_nxt = rd68031_pkg::ST_S1;
      rd68031_pkg::ST_S2: begin
        if (!sterm_q)      st_n_nxt = rd68031_pkg::ST_S3;
        else if (burst_go) st_n_nxt = rd68031_pkg::ST_BL;
        else               st_n_nxt = rd68031_pkg::ST_S5;
      end
      rd68031_pkg::ST_S4:   st_n_nxt = rd68031_pkg::ST_S5;
      rd68031_pkg::ST_WH: begin
        if (!sterm_q)      st_n_nxt = rd68031_pkg::ST_WL;
        else if (burst_go) st_n_nxt = rd68031_pkg::ST_BL;
        else               st_n_nxt = rd68031_pkg::ST_S5;
      end
      // A burst beat. BERR recognised here, with or without STERM, ends the
      // burst (UM 7.5.1: "when a bus error occurs after the burst mode has been
      // entered ... the processor terminates the burst operation").
      rd68031_pkg::ST_BH: begin
        if (!sterm_q && !berr_s) st_n_nxt = rd68031_pkg::ST_BW;
        else if (burst_go)       st_n_nxt = rd68031_pkg::ST_BL;
        else                     st_n_nxt = rd68031_pkg::ST_S5;
      end
      default:              st_n_nxt = rd68031_pkg::ST_IDLE;
    endcase
  end

  // The falling edge that latches a long word and ends a synchronous transfer --
  // the first cycle's, or a burst beat's.
  logic syn_edge;
  assign syn_edge = ((st_p == rd68031_pkg::ST_S2) || (st_p == rd68031_pkg::ST_WH)
                     || (st_p == rd68031_pkg::ST_BH))
                 && ((st_n_nxt == rd68031_pkg::ST_S5)
                     || (st_n_nxt == rd68031_pkg::ST_BL));

  // The rising edge that consumes a transfer: the end of S5, or the end of a
  // burst beat's BL.
  logic beat_end;
  assign beat_end = (st_n == rd68031_pkg::ST_S5) || (st_n == rd68031_pkg::ST_BL);

  // ==========================================================================
  // Dynamic bus sizing -- UM 7.2.1, Tables 7-1, 7-4, 7-5, 7-6 and 7-7
  //
  // "Dynamic bus sizing requires that the portion of the data bus used for a
  // transfer to or from a particular port size be fixed. A 32-bit port must reside
  // on data bus bits 0-31, a 16-bit port must reside on data bus bits 16-31, and
  // an 8-bit port must reside on data bus bits 24-31."
  //
  // So the number of bytes a cycle actually moves is however many of the ones it
  // asked for fit in the port from the offset the address lands on. That single
  // expression reproduces every row of Table 7-6. STERM is a 32-bit port (UM
  // 5.6.9, "the addressed port size is 32 bits").
  // ==========================================================================
  logic [1:0] port_code;     // the DSACK encoding of the port that answered
  logic [2:0] port_bytes;    // 1, 2 or 4
  logic [1:0] port_off;      // the address's offset within the port
  logic [2:0] xfer_n;        // bytes this transfer will actually move

  // The port size of a DSACK cycle is taken one clock after the edge that
  // recognised DSACK, at the falling edge that latches the data -- see the
  // falling-edge block. In the half clock before that edge (S4, after the
  // rising edge that entered it) it is the pins themselves, for early_q, the
  // only register clocked on that edge that reads it; no rising-edge register
  // ever sees this arm, because st_n is S5 again before the next rising edge.
  logic [1:0] dsack_port;
  assign dsack_port = ((st_p == rd68031_pkg::ST_S4) && (st_n != rd68031_pkg::ST_S5))
                    ? dsack_n_i : dsack_q;

  assign port_code = sterm_q ? rd68031_pkg::DSACK_32 : dsack_port;

  // The long word a transfer carries. The first is the cycle's own address; a
  // burst beat is the next long word in the line, wrapping -- "the count
  // sequence wraps back to zero and continues as necessary" (UM 7.3.7) -- which
  // the system, not this unit, puts on A3/A2.
  logic [1:0]  bt_k;
  logic [31:0] bt_addr;
  logic [2:0]  bt_n;         // bytes of the operand the transfer may carry

  always_comb begin
    if (beat_q == 3'd0) bt_k = 2'd0;
    else                bt_k = beat_q[1:0] - 2'd1;
  end

  always_comb begin
    if (bt_k == 2'd0) bt_addr = cyc_addr;
    else              bt_addr = {cyc_addr[31:4], cyc_addr[3:2] + bt_k, 2'b00};
  end

  // A burst beat carries operand bytes only if the operand's next byte is in
  // it: the rest of an operand misaligned within the line (UM 6.1.3.2, "if the
  // data for the cycle contains part of the requested operand, the execution
  // unit uses that data").
  always_comb begin
    if (bt_k == 2'd0)
      bt_n = cyc_n;
    else if (op_active && (op_rem != 3'd0) && (op_addr == bt_addr))
      bt_n = (op_rem > 3'd4) ? 3'd4 : op_rem;
    else
      bt_n = 3'd0;
  end

  always_comb begin
    unique case (port_code)
      rd68031_pkg::DSACK_8:  port_bytes = 3'd1;
      rd68031_pkg::DSACK_16: port_bytes = 3'd2;
      rd68031_pkg::DSACK_32: port_bytes = 3'd4;
      default:               port_bytes = 3'd4;
    endcase
  end

  always_comb begin
    unique case (port_code)
      rd68031_pkg::DSACK_8:  port_off = 2'd0;
      rd68031_pkg::DSACK_16: port_off = {1'b0, bt_addr[0]};
      rd68031_pkg::DSACK_32: port_off = bt_addr[1:0];
      default:               port_off = bt_addr[1:0];
    endcase
  end

  always_comb begin
    xfer_n = port_bytes - {1'b0, port_off};
    if (xfer_n > bt_n) xfer_n = bt_n;
  end

  // What the transfer actually moved. A bus error moves nothing -- the frame has
  // to record the residual as it was BEFORE the faulted access, because RTE
  // reruns that access -- and a retried cycle moves nothing either, because UM
  // 7.5.2 reruns it "using the same access information". A burst beat ended by
  // BERR moves nothing too: if it carried part of the operand, that part is read
  // again by a cycle of its own (UM 7.5.1, figure 7-53).
  logic [2:0] xfer_done;
  always_comb begin
    if (term_err || term_rty || term_bfe) xfer_done = 3'd0;
    else                                  xfer_done = xfer_n;
  end

  // ==========================================================================
  // Read: which lane each byte arrives on -- UM Table 7-4
  //
  // The most significant byte still owed lands on the lane the address selects
  // (D31-D24 is lane 0), and the rest follow on successively lower lanes. A 16-bit
  // port offsets within its own two lanes; an 8-bit port always uses lane 0.
  // ==========================================================================
  // UM 7.3.1 state 4: "at the end of S4, the processor latches the incoming
  // data" -- the falling edge entering S5; and UM 7.3.4, at the falling edge
  // after STERM. The lanes below are that latched copy, so the merge that
  // follows on the next rising edge is not looking at the pins.
  logic [31:0] d_latched;

  logic [7:0] lane [0:3];
  assign lane[0] = d_latched[31:24];
  assign lane[1] = d_latched[23:16];
  assign lane[2] = d_latched[15:8];
  assign lane[3] = d_latched[7:0];

  // The operand as a byte array, least significant first, so that every index
  // below is a plain 3-bit number rather than a part-select whose width the tools
  // disagree about. Eight entries for a five-byte operand: the top three are never
  // read, and having them removes every out-of-range index warning.
  logic [7:0] opv [0:7];

  always_comb begin
    for (i_v = 0; i_v < 8; i_v = i_v + 1) begin
      opv[i_v] = (i_v < 5) ? op_data[i_v * 8 +: 8] : 8'h00;
    end
  end

  logic [7:0] rdv [0:7];
  logic [2:0] rd_sel;
  logic [1:0] rd_lane;
  logic [39:0] rd_merged;

  always_comb begin
    for (i_rv = 0; i_rv < 8; i_rv = i_rv + 1) begin
      rdv[i_rv] = opv[i_rv];
    end
    rd_sel  = '0;
    rd_lane = '0;
    for (i_rd = 0; i_rd < 4; i_rd = i_rd + 1) begin
      if (i_rd < xfer_done) begin
        // Byte i_rd of this transfer is the (op_rem-1-i_rd)-th byte of the
        // operand, counting up from the least significant.
        rd_sel  = op_rem - 3'd1 - i_rd[2:0];
        // ... and it arrives on the lane the address offset selects. The sum
        // never exceeds three: xfer_n is capped at port_bytes - port_off.
        rd_lane = port_off + i_rd[1:0];
        rdv[rd_sel] = lane[rd_lane];
      end
    end
    rd_merged = {rdv[4], rdv[3], rdv[2], rdv[1], rdv[0]};
  end

  // ==========================================================================
  // Write: the internal-to-external multiplexer -- UM Table 7-5
  //
  // Transcribed rather than reduced to a formula, because two of its entries are
  // footnoted "due to the current implementation, this byte is output but never
  // used" and a formula would quietly disagree with the manual about them.
  //
  // opb[j] is the j-th byte of the group this cycle is presenting, j = 0 being the
  // most significant. The manual names them OP0..OP3 by position in the whole
  // operand, so for a size of n bytes its OPk is our opb[k - (4 - n)].
  //
  // All four lanes are always driven: "the MC68030 always drives all sections of
  // the data bus because, at the start of a write cycle, the bus controller does
  // not know the port size" (UM 7.2.4).
  // ==========================================================================
  logic [7:0] opb [0:3];
  logic [2:0] wr_sel;

  always_comb begin
    wr_sel = '0;
    for (i_wr = 0; i_wr < 4; i_wr = i_wr + 1) begin
      if (op_rem > i_wr[2:0]) begin
        wr_sel     = op_rem - 3'd1 - i_wr[2:0];
        opb[i_wr]  = opv[wr_sel];
      end else begin
        opb[i_wr]  = 8'h00;
      end
    end
  end

  // The byte just above the ones still to send -- the operand byte the previous
  // cycle of this operand sent last. op_data keeps the whole operand and only
  // op_rem counts down, so it is still there. Table 7-5 puts it on D7-D0 of a
  // three-byte transfer at A1A0 = 00, which only arises as the rest of a long
  // word begun at A1A0 = 11: the manual's OP0.
  logic [7:0] op_above;
  assign op_above = opv[op_rem];

  logic [31:0] wr_lanes;

  always_comb begin
    unique case ({cyc_siz, cyc_addr[1:0]})
      // Byte: OP3 on every lane, whatever A1 and A0 are.
      {rd68031_pkg::SIZ_BYTE,  2'b00},
      {rd68031_pkg::SIZ_BYTE,  2'b01},
      {rd68031_pkg::SIZ_BYTE,  2'b10},
      {rd68031_pkg::SIZ_BYTE,  2'b11}: wr_lanes = {opb[0], opb[0], opb[0], opb[0]};

      // Word: A1 is a don't care.
      {rd68031_pkg::SIZ_WORD,  2'b00},
      {rd68031_pkg::SIZ_WORD,  2'b10}: wr_lanes = {opb[0], opb[1], opb[0], opb[1]};
      {rd68031_pkg::SIZ_WORD,  2'b01},
      {rd68031_pkg::SIZ_WORD,  2'b11}: wr_lanes = {opb[0], opb[0], opb[1], opb[0]};

      // 3 bytes. The D7-D0 entry of the first row is OP0, the byte sent
      // before these three -- footnoted "output but never used", and Table 7-7
      // leaves the lane disabled, but it is what the part drives and so what
      // this drives.
      {rd68031_pkg::SIZ_3BYTE, 2'b00}: wr_lanes = {opb[0], opb[1], opb[2], op_above};
      {rd68031_pkg::SIZ_3BYTE, 2'b01}: wr_lanes = {opb[0], opb[0], opb[1], opb[2]};
      {rd68031_pkg::SIZ_3BYTE, 2'b10}: wr_lanes = {opb[0], opb[1], opb[0], opb[1]};
      {rd68031_pkg::SIZ_3BYTE, 2'b11}: wr_lanes = {opb[0], opb[0], opb[1], opb[0]};

      // Long word.
      {rd68031_pkg::SIZ_LONG,  2'b00}: wr_lanes = {opb[0], opb[1], opb[2], opb[3]};
      {rd68031_pkg::SIZ_LONG,  2'b01}: wr_lanes = {opb[0], opb[0], opb[1], opb[2]};
      {rd68031_pkg::SIZ_LONG,  2'b10}: wr_lanes = {opb[0], opb[1], opb[0], opb[1]};
      {rd68031_pkg::SIZ_LONG,  2'b11}: wr_lanes = {opb[0], opb[0], opb[1], opb[0]};

      default:                         wr_lanes = {opb[0], opb[1], opb[2], opb[3]};
    endcase
  end

  // ==========================================================================
  // The strobes, declared here because the rising-edge block below uses as_win
  // and Questa and Vivado both reject a variable read above its own declaration
  // -- (vlog-2730) and [Synth 8-6901], which scripts/synth.tcl promotes from an
  // info to an error for exactly this reason. The two lint front-ends invent an
  // implicit net instead and say nothing.
  //
  // EVERY STROBE IS A FLIP-FLOP, NOT A DECODE OF THE STATE. A strobe decoded
  // from a multi-bit state register glitches whenever two of its bits change on
  // the same edge and the decode is true of a code in between: the burst states
  // made that visible -- AS went high for zero time between BL and BW in
  // simulation (doc/bugs-found.md) -- and the asynchronous cycle had the same
  // hazard on ECS, OCS, DBEN and the data enable at S2 -> S4. So each pin is
  // the registered value of the same decode applied to the NEXT state, which
  // is the same waveform from a flop. A pin that moves on one edge is a flop on
  // that edge; DBEN, which moves on both, is rd68031_dedge_ff.
  // ==========================================================================

  // The states AS is asserted in: from the falling edge entering S1 to the
  // falling edge entering S5 -- the asynchronous S5 and the synchronous S3
  // alike. A burst holds it: "it maintains AS, DS, R/W, A0-A31, FC0-FC2,
  // SIZ0-SIZ1 in their current state throughout the burst operation" (UM 7.3.7).
  function automatic logic as_set(input rd68031_pkg::bus_state_e st);
    as_set = (st == rd68031_pkg::ST_S1) || (st == rd68031_pkg::ST_S3)
          || (st == rd68031_pkg::ST_WL) || (st == rd68031_pkg::ST_BL)
          || (st == rd68031_pkg::ST_BW);
  endfunction

  // DBEN, active high here, as a function of the two states -- UM 7.1.6:
  // "during a read operation, DBEN is asserted one clock cycle after the
  // beginning of the bus cycle and is negated as DS is negated. In a write
  // operation, DBEN is asserted at the time AS is asserted and is held active
  // for the duration of the cycle" -- through S5 (UM 7.3.2 state 5), and
  // through a synchronous write's S3 (UM 7.3.5 state 3, "R/W, SIZ0-SIZ1,
  // FC0-FC2, and DBEN also remain valid throughout S3"). A burst keeps it
  // asserted with AS and DS (UM 7.3.7 state 3).
  function automatic logic dben_of(input rd68031_pkg::bus_state_e p,
                                   input rd68031_pkg::bus_state_e n,
                                   input logic rw);
    if (rw)
      dben_of = ((p == rd68031_pkg::ST_S2) || (p == rd68031_pkg::ST_S4)
                 || (p == rd68031_pkg::ST_WH) || (p == rd68031_pkg::ST_BH))
                && (n != rd68031_pkg::ST_S5);
    else
      dben_of = as_set(n)
                || ((n == rd68031_pkg::ST_S5)
                    && ((p == rd68031_pkg::ST_S4) || (p == rd68031_pkg::ST_S2)
                        || (p == rd68031_pkg::ST_WH)));
  endfunction

  logic as_win;     // AS asserted: a falling-edge register
  logic ds_q;       // DS asserted: likewise
  logic cbreq_q;    // CBREQ asserted: likewise
  logic ecs_q;      // the rising edge entering S0 has passed
  logic ocs_q;      // ... and it began an operand
  logic doe_q;      // write data driven: a rising-edge register
  logic [2:0] beat_nxt;

  // The long words latched so far, as the coming falling edge leaves them: none
  // at the start of a cycle, one more on each edge that latches one. A
  // continuous assignment: written as an always_comb, this crashes iverilog 12
  // (ivl_nexus_ptrs: Assertion `net' failed) -- doc/coding-standard.md.
  assign beat_nxt = (st_n_nxt == rd68031_pkg::ST_S1) ? 3'd0
                  : ((st_n_nxt == rd68031_pkg::ST_S5) || (st_n_nxt == rd68031_pkg::ST_BL))
                    ? (beat_q + 3'd1) : beat_q;

  // ==========================================================================
  // Starting a cycle, and starting an operand
  // ==========================================================================
  logic        take_rst;
  logic        take_req;
  logic        take_fetch;
  logic [31:0] next_addr;
  logic  [2:0] next_rem;
  logic  [2:0] next_fc;
  logic        next_rw;
  logic        next_rmc;
  logic        next_burst;
  logic        next_ciout;
  logic        next_spent;

  // A new operand may be taken when none is active, or at the very edge the
  // active one completes.
  // UM20 6.2.3: RTE "reruns the faulted data access". It is the SAME operand, not
  // a new one -- doc/checkpoint.md rule 3, the unit of restart is the operand --
  // so it comes in with the residual the frame carried and the bytes already
  // gathered, and outranks anything the sequencer or the pipe is asking for.
  // A restored operand outlives the microword that handed it over. The
  // sequencer gives it to the bus unit and jumps to the microword that faulted
  // in the same clock, and the bus is not necessarily idle on that clock -- so
  // this is a latched request and not a level. Without the latch the handover
  // was simply missed, the resumed microword issued its own full-length request
  // instead, and RTE rewrote the bytes that had already gone.
  //
  // ... and it is handed to the resumed microword's OWN request, not to
  // whichever request comes first. RTE resumes at the microword that faulted;
  // when that one has a bus request, its request is the first presented, and it
  // takes the operand. When it has none -- an instruction prefetch fault taken
  // while the pipe was empty, at a boundary -- the operand is for nobody, and
  // the sequencer cancels it when that microword retires. Taking it without a
  // request gave its acknowledge, and its data, to the next instruction's first
  // bus microword: an RTS at the resumed address jumped to the frame's data
  // input buffer without reading its stack (RD68021 doc/bugs-found.md).
  //
  // A prefetch is not held up behind it either: the resumed microword may be
  // waiting for exactly that word.
  //
  // A posted write handed back is run at once, for nobody: the microword RTE
  // resumed is not the one that wrote it -- doc/checkpoint.md rule 9.
  //
  // And nothing new is taken on the edge a posted write ends in a bus error.
  // The sequencer is about to take the fault at whatever microword it is on,
  // and a request that microword had presented must not run.
  assign rst_self     = rst_pend_q && rst_post_q && (rst_bytes != 3'd0);
  assign post_flt_end = op_finishing && op_posted && term_err;
  assign take_rst   = !op_continuing && !post_flt_end && rst_pend_q
                   && (req_valid || rst_post_q) && (rst_bytes != 3'd0);
  assign take_req   = !op_continuing && !post_flt_end && !rst_pend_q
                   && req_valid;
  assign take_fetch = !op_continuing && !post_flt_end && !req_valid && fetch_valid
                   && !rst_self;

  // UM20 6.2.2: with DF cleared "it assumes that the data input buffer value on
  // the stack is valid for a read or that the data has been correctly written
  // to memory for a write". The sequencer says so by handing back an operand
  // with nothing left of it, and the answer is the buffer out of the frame.
  //
  // It still has to be handed back rather than skipped: the microword that
  // faulted is re-executed -- doc/checkpoint.md rule 2 -- and everything else
  // it does has to happen exactly once. Satisfying its request from the frame
  // is what lets it run again without running the access again.
  logic rst_done;
  assign rst_done = rst_pend_q && !rst_post_q && !op_continuing && req_valid
                 && (rst_bytes == 3'd0);

  // A posted write is outstanding, or RTE has one to rerun.
  assign post_busy = (op_active && op_posted) || rst_self;

  // OCS for a cycle starting at this edge: the first of a new operand, or the
  // next of one none of whose cycles has finished yet (op_first, as this edge
  // leaves it).
  logic first_now;
  assign first_now = take_rst || take_req || take_fetch
                  || (op_first && !(beat_end && op_active));

  // CPU space synthesises its address from the type field -- UM figure 7-42.
  logic [31:0] cpu_space_addr;
  always_comb begin
    unique case (req_cpuspace)
      rd68031_pkg::CPUS_IACK:
        // UM 7.4.1.1: A1-A3 the level, A20-A31, A4-A15 and A0 set to one.
        cpu_space_addr = {28'hFFF_FFFF, req_cpuaddr[2:0], 1'b1};
      rd68031_pkg::CPUS_BKPT:
        // The breakpoint number on A4-A2 -- UM 7.4.2.
        cpu_space_addr = {12'h000, rd68031_pkg::CPUS_BKPT, 11'h000,
                          req_cpuaddr[2:0], 2'b00};
      rd68031_pkg::CPUS_COPROC:
        // UM 7.4.3: the CpID on A13-A15 and the interface register on A0-A4,
        // and figure 7-42 shows every other address line zero.
        cpu_space_addr = {12'h000, rd68031_pkg::CPUS_COPROC, req_cpuaddr[7:5],
                          8'h00, req_cpuaddr[4:0]};
      default:
        cpu_space_addr = {12'h000, req_cpuspace, req_cpuaddr, 8'h00};
    endcase
  end

  always_comb begin
    if (take_rst) begin
      next_addr  = rst_addr;
      next_rem   = rst_bytes;
      next_fc    = rst_fc;
      next_rw    = rst_rw;
      next_rmc   = rst_rmc;
      next_burst = 1'b0;
      next_ciout = 1'b0;
      next_spent = 1'b0;
    end else if (take_req) begin
      next_addr  = (req_fc == rd68031_pkg::FC_CPU) ? cpu_space_addr : req_addr;
      next_rem   = req_bytes;
      next_fc    = req_fc;
      next_rw    = (req_kind != rd68031_pkg::CT_WRITE);
      next_rmc   = req_rmc;
      next_burst = req_burst;
      next_ciout = req_ciout;
      next_spent = 1'b0;
    end else if (take_fetch) begin
      next_addr  = {fetch_addr[31:2], 2'b00};  // always long-word aligned
      next_rem   = 3'd4;
      next_fc    = fetch_fc;
      next_rw    = 1'b1;
      next_rmc   = 1'b0;
      next_burst = fetch_burst;
      next_ciout = fetch_ciout;
      next_spent = 1'b0;
    end else if (st_n == rd68031_pkg::ST_S5) begin
      // Continuing a multi-cycle operand on the edge that ends S5. op_addr and
      // op_rem are updated by this same edge, so what the next cycle must carry
      // is the residual *after* this transfer, not before it -- and so is
      // whether this operand has had its CBREQ.
      next_addr  = op_addr + {29'd0, xfer_done};
      next_rem   = op_rem - xfer_done;
      next_fc    = op_fc;
      next_rw    = op_rw;
      next_rmc   = op_rmc;
      next_burst = op_burst;
      next_ciout = op_ciout;
      next_spent = op_brq_used || (cyc_brq && !term_rty);
    end else begin
      // Re-entering S0 from anywhere else -- which means a retry (UM 7.5.2,
      // "retries the previous cycle using the same access information"). The
      // residual is already whatever the faulted cycle left it as, and it must
      // NOT be advanced again: xfer_done is only meaningful while the cycle that
      // produced it is still current, and by now term_rty has been cleared, so
      // adding it here would retry at the wrong address with a residual of zero.
      next_addr  = op_addr;
      next_rem   = op_rem;
      next_fc    = op_fc;
      next_rw    = op_rw;
      next_rmc   = op_rmc;
      next_burst = op_burst;
      next_ciout = op_ciout;
      next_spent = op_brq_used;
    end
  end

  logic [2:0] this_n;
  always_comb begin
    this_n = (next_rem > 3'd4) ? 3'd4 : next_rem;
  end

  logic [1:0] this_siz;
  always_comb begin
    unique case (this_n)
      3'd1:    this_siz = rd68031_pkg::SIZ_BYTE;
      3'd2:    this_siz = rd68031_pkg::SIZ_WORD;
      3'd3:    this_siz = rd68031_pkg::SIZ_3BYTE;
      default: this_siz = rd68031_pkg::SIZ_LONG;
    endcase
  end

  // Whether the cycle about to start asserts CBREQ -- UM 6.1.3.2's list of
  // the cases in which "the processor does not assert CBREQ", the ones that are
  // the bus unit's to know:
  //   - "the current operation is the read portion of a read-modify-write
  //     operation" (and UM 7.3.3: "no burst filling of the data cache occurs
  //     during a read-modify-write operation");
  //   - "the MMU has inhibited caching for the current page" -- CIOUT;
  //   - "the cycle is for the first access of an operand that spans two cache
  //     lines (crosses a modulo 16 boundary)": the rest of the access, from
  //     this cycle's address on, must lie in the same 16-byte line;
  // and it is a read, of course: a burst fills a cache. The others -- the cache
  // enabled, its burst enable, its freeze bit, a tag miss -- are the
  // requester's, and are what req_burst and fetch_burst say.
  logic [31:0] next_last;
  logic        next_brq;
  assign next_last = next_addr + {29'd0, next_rem} - 32'd1;
  assign next_brq  = next_burst && !next_spent && next_rw && !next_rmc
                  && !next_ciout && (next_fc != rd68031_pkg::FC_CPU)
                  && (next_last[31:4] == next_addr[31:4]);

  // A faulted operand finishes too: the requester has to be unstalled either way,
  // and req_fault is what tells it which happened.
  //
  // An operand may finish part-way through a burst, at the rising edge that ends
  // a BL, as soon as its last byte has arrived. The burst carries on without it.
  assign op_finishing  = op_active
                         && (((st_n == rd68031_pkg::ST_S5)
                              && !term_rty
                              && ((op_rem == xfer_done) || term_err))
                             || ((st_n == rd68031_pkg::ST_BL)
                                 && (xfer_done != 3'd0) && (op_rem == xfer_done)));
  assign op_continuing = op_active && !op_finishing;

  // Combinational, and true throughout S5: the operand completes at the rising
  // edge that ends S5, which gives the sequencer half a clock to present the next
  // request. That half clock is the design's tightest path, by construction.
  assign req_last   = op_finishing && !op_isfetch && !op_posted;
  assign fetch_last = op_finishing &&  op_isfetch;

  // CIIN, for the operand: seen on a read transfer that carried some of its bytes.
  logic ciin_now;
  assign ciin_now = ciin_q && op_rw && (xfer_done != 3'd0);

  // ==========================================================================
  // Rising-edge domain
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_p       <= rd68031_pkg::ST_IDLE;
      op_active  <= 1'b0;
      op_addr    <= '0;
      op_rem     <= '0;
      op_fc      <= '0;
      op_rw      <= 1'b1;
      op_rmc     <= 1'b0;
      op_first   <= 1'b1;
      op_isfetch <= 1'b0;
      op_cpflt   <= 1'b0;
      op_burst   <= 1'b0;
      op_brq_used <= 1'b0;
      op_ciout   <= 1'b0;
      op_ciin    <= 1'b0;
      op_data    <= '0;
      cyc_addr   <= '0;
      cyc_fc     <= '0;
      cyc_siz    <= rd68031_pkg::SIZ_LONG;
      cyc_n      <= '0;
      cyc_rw     <= 1'b1;
      cyc_brq    <= 1'b0;
      cyc_ciout  <= 1'b0;
      sterm_q    <= 1'b0;
      cback_q    <= 1'b0;
      ciin_q     <= 1'b0;
      ecs_q      <= 1'b0;
      ocs_q      <= 1'b0;
      doe_q      <= 1'b0;
      req_ack    <= 1'b0;
      req_end_q  <= rd68031_pkg::CE_NONE;
      req_ciin   <= 1'b0;
      rst_pend_q <= 1'b0;
      rst_post_q <= 1'b0;
      op_posted  <= 1'b0;
      req_taken  <= 1'b0;
      req_fault_post <= 1'b0;
      fetch_ack  <= 1'b0;
      fetch_ciin <= 1'b0;
      rdata_q    <= '0;
      frdata_q   <= '0;
      req_fault    <= 1'b0;
      req_fault_wr <= 1'b0;
      fetch_fault  <= 1'b0;
      beat_valid <= 1'b0;
      beat_err   <= 1'b0;
      beat_data  <= '0;
      beat_addr  <= '0;
      beat_num   <= '0;
      beat_port  <= rd68031_pkg::DSACK_32;
      beat_ciin  <= 1'b0;
      beat_fetch <= 1'b0;
      arb        <= rd68031_pkg::ARB_IDLE;
      hiz_q      <= 1'b0;
      rmc_hold   <= 1'b0;
      rmc_first_q <= 1'b0;
      halt_hold  <= 1'b0;
    end else begin
      st_p      <= st_p_nxt;
      req_ack   <= 1'b0;
      req_taken <= 1'b0;

      if (rst_op_valid) begin
        rst_pend_q <= 1'b1;
        rst_post_q <= rst_post;
      end else if (take_rst && (st_p_nxt == rd68031_pkg::ST_S0))
        rst_pend_q <= 1'b0;
      else if (rst_done) begin
        rst_pend_q <= 1'b0;
        // A posted microword is satisfied by being taken, not acknowledged; an
        // acknowledge would be read by the microword after it.
        req_ack    <= !req_post;
        req_taken  <= req_post;
        req_end_q  <= rd68031_pkg::CE_DSACK;
        req_ciin   <= 1'b0;
        rdata_q    <= {8'd0, rst_dob};
      end else if (rst_pend_q && rst_post_q && (rst_bytes == 3'd0))
        // The handler wrote it -- UM20 6.2.2 -- and there is nothing to run.
        rst_pend_q <= 1'b0;
      else if (rst_cancel && !rst_post_q)
        rst_pend_q <= 1'b0;

      fetch_ack <= 1'b0;
      req_fault    <= 1'b0;
      req_fault_wr <= 1'b0;
      req_fault_post <= 1'b0;
      fetch_fault  <= 1'b0;
      beat_valid   <= 1'b0;
      beat_err     <= 1'b0;

      arb <= arb_nxt;

      // "If T is true, the address, data, and control buses are placed in the
      // high-impedance state after the next rising edge following the negation of
      // AS and RMC" -- UM 7.7.4. Registered on the way up, so the release waits
      // for that edge; combinational on the way down, because "the bus control
      // signals (controlled by T) are driven by the processor, immediately
      // following a state change, when bus mastership is returned".
      //
      // RMC holds the bus only while it locks it. Single-wire arbitration is
      // the other exception: it "applies to all bus cycles of a
      // read-modify-write sequence" -- "an alternate master forces the MC68030
      // to release the bus by asserting BGACK and waits for AS to negate before
      // taking the bus" (UM 7.7.4) -- so with A asserted the release does not
      // wait for RMC.
      hiz_q <= arb_t_of(arb_nxt) && !as_win && (!rmc_lock || arb_a);

      halt_hold <= (st_p_nxt == rd68031_pkg::ST_HALT);

      // ECS and OCS from the rising edge entering S0 (specification 6A); write
      // data from the rising edge entering S2 to the one that ends S5 (UM 7.3.2
      // state 2, specification 23). cyc_rw is already this cycle's at S2.
      ecs_q <= (st_p_nxt == rd68031_pkg::ST_S0);
      ocs_q <= (st_p_nxt == rd68031_pkg::ST_S0) && first_now;
      doe_q <= !cyc_rw && ((st_p_nxt == rd68031_pkg::ST_S2)
                           || (st_p_nxt == rd68031_pkg::ST_S4)
                           || (st_p_nxt == rd68031_pkg::ST_WH));

      // The synchronous inputs. STERM is tested at the start of S2 and on every
      // rising edge after it while the cycle waits (UM 7.3.4 state 2), and at
      // the start of each burst beat (UM 7.3.7 state 4); CBACK and CIIN are
      // latched with it. A cycle DSACKx is ending has its CIIN latched "on the
      // rising edge of bus cycle state 4" (UM 7.2.9). CIIN "is ignored during
      // write cycles" (UM 5.7.1).
      if (st_p_nxt == rd68031_pkg::ST_S0) begin
        sterm_q <= 1'b0;
        cback_q <= 1'b0;
        ciin_q  <= 1'b0;
      end else if ((st_p_nxt == rd68031_pkg::ST_S2)
                   || (st_p_nxt == rd68031_pkg::ST_WH)
                   || (st_p_nxt == rd68031_pkg::ST_BH)) begin
        sterm_q <= sterm_s;
        cback_q <= sterm_s && cback_s;
        ciin_q  <= sterm_s && ciin_s && cyc_rw;
      end else if (st_p_nxt == rd68031_pkg::ST_S4) begin
        ciin_q  <= ciin_s && cyc_rw;
      end

      // The rising edge that consumes a transfer -- the end of S5, or the end
      // of a burst beat. Take the bytes it moved and advance the residual.
      // Every register the operand owns is written here and in the S0 arm
      // below, both in this one block -- a register written from both edge
      // domains is two conflicting drivers, which is a defect `make lint` now
      // fails on.
      if (beat_end) begin
        // The beat, for whoever fills a cache from it. A retried cycle is not
        // one: it moved nothing and will be run again.
        beat_valid <= cyc_rw && !term_rty && !term_err && !term_bfe;
        beat_err   <= cyc_rw && (term_err || term_bfe);
        beat_data  <= d_latched;
        beat_addr  <= bt_addr;
        beat_num   <= bt_k;
        beat_port  <= port_code;
        beat_ciin  <= ciin_q;
        beat_fetch <= op_isfetch;
      end

      if (beat_end && op_active) begin
        // A retried cycle is rerun "using the same access information" (UM
        // 7.5.2), and that includes OCS if the cycle had it: a retry of the
        // first cycle of an operand is still the first cycle of the operand.
        if (!term_rty) op_first <= 1'b0;
        if (op_rw) op_data <= rd_merged;
        op_addr <= op_addr + {29'd0, xfer_done};
        op_rem  <= op_rem - xfer_done;
        if (ciin_now) op_ciin <= 1'b1;
        if ((st_n == rd68031_pkg::ST_S5) && cyc_brq && !term_rty)
          op_brq_used <= 1'b1;
        if (op_finishing) begin
          op_active <= 1'b0;
          op_first  <= 1'b1;
          if (op_isfetch) begin
            fetch_ack   <= 1'b1;
            fetch_fault <= term_err;
            fetch_ciin  <= op_ciin || ciin_now;
            if (op_rw) frdata_q <= rd_merged[31:0];
          end else begin
            // A posted write is acknowledged to nobody.
            req_ack      <= !op_posted;
            req_end_q    <= end_now;
            req_ciin     <= op_ciin || ciin_now;
            // A bus error on a CPU-SPACE cycle is not a bus error. UM 8.1.9
            // makes one on an interrupt acknowledge the spurious interrupt, and
            // UM 7.4.2 makes one on a breakpoint acknowledge an illegal
            // instruction; the microcode reads it off the end code and decides.
            // Raising a fault here as well would take the bus error exception
            // instead, and the spurious interrupt would be unreachable.
            req_fault    <= term_err && ((op_fc != rd68031_pkg::FC_CPU)
                                         || op_cpflt);
            req_fault_wr <= term_err && ((op_fc != rd68031_pkg::FC_CPU)
                                         || op_cpflt)
                                     && !op_rw;
            req_fault_post <= term_err && op_posted;
            if (op_rw) rdata_q <= rd_merged;
          end
        end
      end

      // Entering S0: latch everything the pins will carry for this whole cycle,
      // and start a new operand if this is the first cycle of one. This arm runs
      // after the one above in the same edge when a cycle follows immediately,
      // which is why next_addr and next_rem are written to see the post-transfer
      // residual.
      if (st_p_nxt == rd68031_pkg::ST_S0) begin
        rmc_hold  <= next_rmc;
        // The first bus cycle of a locked run, and it stays the first through
        // however many times it is retried.
        if (st_p != rd68031_pkg::ST_RETRY)
          rmc_first_q <= next_rmc && !rmc_hold;
        cyc_addr  <= next_addr;
        cyc_fc    <= next_fc;
        cyc_siz   <= this_siz;
        cyc_n     <= this_n;
        cyc_rw    <= next_rw;
        cyc_brq   <= next_brq;
        cyc_ciout <= next_ciout;

        if (take_rst || take_req || take_fetch) begin
          op_active  <= 1'b1;
          op_addr    <= next_addr;
          op_rem     <= next_rem;
          op_fc      <= next_fc;
          op_rw      <= next_rw;
          op_rmc     <= next_rmc;
          op_first   <= 1'b1;
          op_isfetch <= take_fetch;
          op_burst   <= next_burst;
          op_brq_used <= 1'b0;
          op_ciout   <= next_ciout;
          op_ciin    <= 1'b0;
          // Posted: the operand RTE reruns by itself, or a posted request --
          // which may be taking a hand-back of its own.
          op_posted  <= take_rst ? (rst_post_q || req_post)
                                 : (take_req && req_post);
          req_taken  <= req_post && (take_req || (take_rst && !rst_post_q));
          // An operand RTE hands back in CPU space can only be a coprocessor
          // access that faulted, so it faults again if it has to.
          op_cpflt   <= take_rst ? 1'b1 : (take_req && req_cpfault);
          // A restarted operand keeps what it had already transferred: the
          // residual says how much is left, and the buffer holds the rest.
          // A read starts from nothing. Its bytes are gathered right justified
          // into this register, and a read of fewer than four bytes leaves the
          // rest as they started -- which, taken from the request's write data,
          // was whatever the requesting microword's ALU was producing. That was
          // always zero until a read began to compute its own result.
          if (take_rst)        op_data <= {8'd0, rst_dob};
          else if (take_fetch) op_data <= '0;
          else if (next_rw)    op_data <= '0;
          else                 op_data <= req_wdata;
        end
      end else if ((st_p_nxt == rd68031_pkg::ST_IDLE) && !req_rmc) begin
        // Nothing locked is pending and the bus is going idle, so let go of RMC
        // rather than blocking arbitration until the next cycle happens along.
        rmc_hold <= 1'b0;
      end
    end
  end

  // ==========================================================================
  // Falling-edge domain
  //
  // Three things happen here and nowhere else: the asynchronous termination
  // inputs are sampled at the end of S2 (UM 7.3.1 state 3, "as long as at least
  // one of the DSACKx signals is recognized by the end of S2"), the read data is
  // latched (at the end of S4, or at the falling edge after STERM), and the
  // verdict of a synchronous cycle is taken on that same edge.
  //
  // DSACK1 and DSACK0 TERMINATE the cycle on the edge where either is first
  // recognised, and give the PORT SIZE one clock later, on the edge that
  // latches the data. MC68030EC specification 31A, footnote 3: "the maximum
  // allowable skew between DSACK0 to DSACK1 asserted or DSACK1 to DSACK0
  // asserted; specification #47A must be met by DSACK0 or DSACK1" -- by one of
  // them, so the other may arrive after the recognising edge. UM 7.3.1 state 3
  // terminates "as long as at least one of the DSACKx signals is recognized",
  // and UM 7.3 makes "the bus master ... responsible for de-skewing the
  // acknowledge and data signals from the slave devices". A port size taken on
  // the recognising edge read a 32-bit port whose DSACK1 trailed DSACK0 by a
  // legal 3 ns as an 8-bit port, and the operand engine assembled the wrong
  // bytes with no error anywhere (doc/bugs-found.md, M3). One clock later both
  // are valid whenever 31A + 47A fits in a clock, which it does at every grade,
  // and the device still holds them: it "keeps its data and DSACKx signals
  // asserted until it detects the negation of AS" (UM 7.3.1 state 5), which is
  // this same edge. Both bits are still captured by one flop pair on one edge.
  // ==========================================================================
  // The six acceptable asynchronous terminations -- UM Table 7-8, with the case
  // numbers the manual gives them. The table indexes on two samples a clock
  // apart, "asserted on rising edge of state N" and "N+2"; here those are the
  // falling edge entering S3 (the end of S2) and the falling edge entering S5 (the
  // end of S4).
  //
  //   1  DSACK, no BERR, no HALT          normal
  //   2  HALT at or before DSACK          normal, then halt
  //   3  BERR in lieu of / at / before    bus error
  //   4  BERR one state pair after DSACK  bus error, deferred -- the late window
  //   5  BERR and HALT in lieu of / at / before   retry
  //   6  BERR and HALT after DSACK        retry, deferred
  //
  // Table 7-9 is the same six for STERM, with one difference that matters: there
  // is no state N+2 -- "state N+2 not part of bus cycle". The late window is the
  // falling edge after the rising edge that recognised STERM (UM 7.5.1, "BERR is
  // asserted and recognized on the next falling clock edge following the rising
  // clock edge on which STERM is asserted and recognized"), which is the edge
  // that latches the data and ends the cycle.
  //
  // Cases 4 and 6 are the ones worth being careful about. On the MC68010 project
  // the equivalent late assertion was detected and then never delivered, because
  // the late path set an end code without raising the fault; the exception was
  // simply not taken. Here the late sample writes term_err and term_rty, which is
  // the same place the early sample writes them.
  // The cycle under way is an interrupt acknowledge: CPU space, type $F on
  // A19-A16 -- UM figure 7-42. Both were latched at S0 and hold for the cycle.
  logic cyc_iack;
  assign cyc_iack = (cyc_fc == rd68031_pkg::FC_CPU)
                 && (cyc_addr[19:16] == rd68031_pkg::CPUS_IACK);
  logic early_q;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_n      <= rd68031_pkg::ST_IDLE;
      dsack_q   <= rd68031_pkg::DSACK_WAIT;
      term_q    <= 1'b0;
      term_err  <= 1'b0;
      term_rty  <= 1'b0;
      term_avc  <= 1'b0;
      term_hlt  <= 1'b0;
      term_syn  <= 1'b0;
      term_bfe  <= 1'b0;
      beat_q    <= 3'd0;
      as_win    <= 1'b0;
      ds_q      <= 1'b0;
      cbreq_q   <= 1'b0;
      d_latched <= '0;
      bg_n_o    <= 1'b1;
      early_q   <= 1'b0;
      retry_clr_q <= 1'b1;
    end else begin
      st_n <= st_n_nxt;

      // BERR and HALT both negated, for the end of a retry -- see retry_clear.
      retry_clr_q <= berr_n_i && halt_n_i;

      // The rising edge that ended S5, or a burst beat's BL, has consumed the
      // verdict; clear it for the next transfer. A retried cycle keeps nothing
      // either: UM 7.5.2 reruns it from the same access information, and the
      // rerun takes its own samples. This comes first, so that a burst beat
      // being latched on this same edge writes its own verdict over it.
      if ((st_n == rd68031_pkg::ST_S5) || (st_n == rd68031_pkg::ST_BL)) begin
        term_q   <= 1'b0;
        term_err <= 1'b0;
        term_rty <= 1'b0;
        term_avc <= 1'b0;
        term_hlt <= 1'b0;
        term_syn <= 1'b0;
        term_bfe <= 1'b0;
      end

      // Decided on the edge entering S5, which is where the last sample is
      // taken: after it nothing can turn this cycle into a bus error or a retry,
      // and the residual after it is known. Everything the sequencer does with
      // it is a half clock -- the early retire, doc/timing-divergences.md. Only
      // for the first transfer of a cycle: a burst beat's operand bytes, if any,
      // are taken on the ordinary acknowledge.
      early_q <= (st_n_nxt == rd68031_pkg::ST_S5) && op_active && !op_isfetch
              && !op_posted && (beat_q == 3'd0)
              && !term_err && !term_rty && !berr_s && (op_rem == xfer_n);

      // "The BG signal transitions on the falling edge of the clock after a state
      // is reached during which G changes" -- UM 7.7.4.
      bg_n_o <= ~arb_g_of(arb);

      beat_q <= beat_nxt;

      // AS, DS and CBREQ move on falling edges only.
      //
      // DS: on a read it follows AS (UM 7.1.5, "it is asserted at the same time
      // as AS during a read cycle"). On a write it waits until S3, "one full
      // clock cycle after the assertion of AS", indicating that the data is
      // stable (UM 7.3.2 state 3). A synchronous write with no wait state never
      // reaches S3, and so never asserts it: "DS is not asserted for two-clock
      // synchronous write cycles" (UM 5.6.6, 7.3.5); one with wait states
      // asserts it "at the end of S2" (UM 7.3.5 state 2), which is the same
      // edge.
      //
      // CBREQ: "if the burst mode is enabled for the appropriate on-chip cache
      // and all four long words of the cache entry are invalid ... CBREQ is
      // asserted" in S1 (UM 7.3.4 state 1), with AS (specification 9), and
      // negated with it -- or, in a full burst, "during S7", once the third
      // long word is latched, "indicating that the MC68030 only requests one
      // more long word" (UM 7.3.7).
      as_win  <= as_set(st_n_nxt);
      ds_q    <= cyc_rw ? as_set(st_n_nxt)
                        : ((st_n_nxt == rd68031_pkg::ST_S3)
                           || (st_n_nxt == rd68031_pkg::ST_WL));
      cbreq_q <= cyc_brq && as_set(st_n_nxt) && (beat_nxt < 3'd3);

      // The asynchronous sample: entering S3, and again at every ST_WL while
      // waiting.
      if (st_n_nxt == rd68031_pkg::ST_S3 || st_n_nxt == rd68031_pkg::ST_WL) begin
        if (berr_s && halt_s) begin
          term_q   <= 1'b1;  term_rty <= 1'b1;               // case 5
        end else if (berr_s) begin
          term_q   <= 1'b1;  term_err <= 1'b1;               // case 3
        end else if (!avec_s && cyc_iack) begin
          // UM 7.4.1.2 and 7.1.7: AVEC terminates an interrupt acknowledge
          // cycle in place of DSACK or STERM and says "use the autovector for
          // this level". It is sampled on the same edge as DSACK. On any other
          // cycle it is not a termination at all -- UM 7.1.7, "AVEC is ignored
          // during all other bus cycles" -- and the cycle waits for DSACK: a
          // board that ties AVEC low to autovector everything must still get
          // its wait states. Ending the cycle on it lost the writes of a
          // Sun-3/60 replica's PROM (RD68021 doc/bugs-found.md).
          term_q   <= 1'b1;  term_avc <= 1'b1;
        end else if (dsack_n_i != rd68031_pkg::DSACK_WAIT) begin
          term_q   <= 1'b1;  term_hlt <= halt_s;             // cases 1 and 2
        end else begin
          term_q   <= 1'b0;
        end
      end

      // A long word is latched: at the end of S4 (UM 7.3.1 state 4), or at the
      // falling edge after STERM (UM 7.3.4 state 2, 7.3.7 state 4). "During a
      // read cycle, the data is latched by the processor on the last falling
      // edge of the clock for that bus cycle" (UM 7.1.4).
      if ((st_n_nxt == rd68031_pkg::ST_S5) || (st_n_nxt == rd68031_pkg::ST_BL))
        d_latched <= d_i;

      // Table 7-8's second sample, for a cycle DSACKx ended. It applies only to
      // a cycle that terminated normally -- a cycle already in error does not get
      // a second verdict. The port size is taken here too, one clock after the
      // recognising edge -- specification 31A, above.
      if ((st_p == rd68031_pkg::ST_S4) && (st_n_nxt == rd68031_pkg::ST_S5)) begin
        dsack_q <= dsack_n_i;
        if (!term_err && !term_rty) begin
          if (berr_s && halt_s)   term_rty <= 1'b1;          // case 6
          else if (berr_s)        term_err <= 1'b1;          // case 4
        end
      end

      // The verdict of a synchronous transfer.
      if (syn_edge) begin
        term_q <= 1'b1;
        if (st_p == rd68031_pkg::ST_BH) begin
          // A burst fill beat. UM 7.5.1: "the cache entry corresponding to that
          // cycle is marked invalid, but the processor does not take an
          // exception"; and UM 7.5.2: BERR with HALT "during the second, third,
          // or fourth cycle of a burst operation does not cause a retry
          // operation" -- it "causes independent BERR and HALT operations".
          // BERR without STERM ends a beat too.
          term_syn <= sterm_q;
          term_bfe <= berr_s;
          term_hlt <= halt_s;
        end else begin
          // The first cycle: Table 7-9. HALT alone is case 2.
          term_syn <= 1'b1;
          if (berr_s && halt_s)   term_rty <= 1'b1;          // cases 5 and 6
          else if (berr_s)        term_err <= 1'b1;          // cases 3 and 4
          else                    term_hlt <= halt_s;        // cases 1 and 2
        end
      end
    end
  end

  // ==========================================================================
  // Pins
  //
  // Each is written as the manual states it, in terms of the two state
  // registers, and each comes from a flip-flop -- see "The strobes" above.
  // ==========================================================================

  // ECS: one half clock at the start of every bus cycle. Asserted on the rising
  // edge entering S0 (specification 6A) and negated on the falling edge entering
  // S1 (specification 12A), which is the whole of specification 10's width.
  // ecs_q is set only for that half clock, and the one edge in it at which st_n
  // moves is the one that takes it into S1, so the AND moves once.
  assign ecs_n_o = ~(ecs_q && (st_n != rd68031_pkg::ST_S1));

  // OCS: identical, but only for the first bus cycle of an operand (UM 7.1.1).
  assign ocs_n_o = ~(ocs_q && (st_n != rd68031_pkg::ST_S1));

  assign as_n_o = ~as_win;

  assign ds_n_o = ~ds_q;

  // DBEN, active low (Table 5-2), from rd68031_dedge_ff: its value after each
  // edge is dben_of() of the states after that edge. At the rising edge into S0
  // it is negated whatever the direction, which is what lets the new cycle's
  // R/W, latched on that same edge, not matter there.
  logic dben_q, dben_rise, dben_fall, dben_tp, dben_tn;
  always_comb begin
    if (st_p_nxt == rd68031_pkg::ST_S0) dben_rise = 1'b0;
    else                                dben_rise = dben_of(st_p_nxt, st_n, cyc_rw);
    dben_fall = dben_of(st_p, st_n_nxt, cyc_rw);
  end
  assign dben_tp   = dben_rise ^ dben_q;
  assign dben_tn   = dben_fall ^ dben_q;

  rd68031_dedge_ff #(.RESET_VAL (1'b0)) u_dben (
      .clk (clk), .rst_n (rst_n), .toggle_p (dben_tp), .toggle_n (dben_tn),
      .q (dben_q));

  assign dben_n_o = ~dben_q;

  assign cbreq_n_o = ~cbreq_q;

  // CIOUT "becomes valid" in S0 with the address (UM 7.3.1 state 0,
  // specification 6), and is held for the cycle.
  assign ciout_n_o = ~cyc_ciout;

  assign fc_o    = cyc_fc;
  assign a_o     = cyc_addr;
  assign siz_o   = cyc_siz;
  assign rw_o    = cyc_rw;
  // UM 7.1.1 makes RMC a qualifier over a RUN of cycles, not a property of one:
  // it "is asserted at the beginning of the first bus cycle of a read-modify-write
  // operation and remains asserted until completion of the final bus cycle of
  // the operation", INCLUDING the clocks between them, because that is the whole
  // point -- nothing else may get at the location in the gap. `rmc_hold` is
  // exactly that run, and is already what inhibits arbitration.
  assign rmc_n_o = ~rmc_hold;
  assign d_o     = wr_lanes;

  // Bus relinquish. Combinational on the way down so that the processor drives
  // again "immediately following a state change, when bus mastership is returned".
  assign bus_granted = hiz_q && arb_t_of(arb);

  // Output enables.
  //
  // UM 7.8: "during the reset period, the entire bus three-states (except for
  // non-three-statable signals, which are driven to their inactive state)". The
  // reset this design has is rst_n -- doc/pinout.md -- and every enable below
  // drops with it.
  //
  // The address group is driven from S0 and released at the rising edge that ends
  // S5 (specification 7) -- except while halted, where UM 7.5.3 says the address,
  // function code, size and read/write signals "remain in the same state",
  // driven rather than released. That is the one thing that distinguishes a
  // halted bus from an idle one on these pins. CIOUT is in this group:
  // specifications 6, 7 and 8 measure it with the address.
  logic cyc_drive;
  assign cyc_drive = (st_p != rd68031_pkg::ST_IDLE);

  logic addr_drive;
  assign addr_drive = ADDR_HIZ_BETWEEN_CYCLES ? (cyc_drive || halt_hold) : 1'b1;

  assign a_oe     = addr_drive && !bus_granted && rst_n;
  assign fc_oe    = a_oe;
  assign siz_oe   = a_oe;
  assign ciout_oe = a_oe;
  // ... and it is DRIVEN for the whole of that run as well. The address may go
  // to high impedance between cycles -- ADDR_HIZ_BETWEEN_CYCLES -- and if RMC
  // followed it there, an external wrapper would three-state the one signal
  // whose job is to stay asserted in the gap.
  assign rmc_oe = (addr_drive || rmc_hold) && !bus_granted && rst_n;

  // Write data is driven from the rising edge entering S2 and held through S5.
  // "When the processor completes a bus cycle with the HALT signal asserted, the
  // data bus is placed in the high-impedance state" -- so no halt term here.
  assign d_oe = doe_q && !bus_granted && rst_n;

  // The control group is driven except on relinquish and reset. UM 7.5.3 is
  // explicit that halting drives these inactive rather than releasing them, and
  // 7.7.4's T is what releases them. CBREQ is in this group: specification 16
  // is "Clock High to AS, DS, R/W, DBEN, CBREQ High Impedance".
  assign as_oe    = !bus_granted && rst_n;
  assign ds_oe    = !bus_granted && rst_n;
  assign rw_oe    = !bus_granted && rst_n;
  assign dben_oe  = !bus_granted && rst_n;
  assign cbreq_oe = !bus_granted && rst_n;

  // RESET is open drain: the output value is a constant zero and the enable is
  // what asserts it. HALT is an input only on the MC68030 (Table 5-2); the
  // halted state shows on STATUS instead (UM 7.5.4).
  assign reset_n_o  = 1'b0;
  assign reset_n_oe = rsto_q;

  // ==========================================================================
  // STATUS and REFILL -- UM 5.11.3, 5.11.4 and 12.7.1
  //
  // Table 12-4: STATUS asserted for one clock is an instruction boundary; for
  // two, a boundary at which a trace or interrupt exception is to be taken; for
  // three, the start of exception processing (reset, bus error, address error,
  // ...); continuously, "processor halted due to double bus fault". REFILL
  // "identifies when the microsequencer requests an instruction pipeline
  // refill". "Both STATUS and REFILL assert and negate from the falling edge of
  // the CLK signal" (UM 12.7.1, specifications 62 and 63), so both are
  // falling-edge registers, and neither is ever three-stated (Table 5-2).
  //
  // The sequencer reports each event as a one-clock pulse. A pulse is followed
  // by at least one clock negated, or two pulses would read as one longer one;
  // an event that arrives while one is being shown is held, and two that
  // arrive in that time are shown as the longer of them -- doc/divergences.md.
  // ==========================================================================
  logic [1:0] sts_code;       // what the sequencer reports this clock
  logic [1:0] sts_rem_q;      // clocks still to show after this one
  logic [1:0] sts_pend_q;     // an event waiting for its turn
  logic       sts_on_q;
  logic       refill_on_q;
  logic [1:0] sts_take;

  always_comb begin
    if (sts_exc)        sts_code = 2'd3;
    else if (sts_pend)  sts_code = 2'd2;
    else if (sts_bound) sts_code = 2'd1;
    else                sts_code = 2'd0;
  end

  always_comb begin
    sts_take = (sts_pend_q > sts_code) ? sts_pend_q : sts_code;
  end

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sts_rem_q   <= 2'd0;
      sts_pend_q  <= 2'd0;
      sts_on_q    <= 1'b0;
      refill_on_q <= 1'b0;
    end else begin
      refill_on_q <= sts_refill;
      if (dbf) begin
        // UM 7.5.4: "continuously asserting the STATUS signal until the
        // processor is reset".
        sts_on_q   <= 1'b1;
        sts_rem_q  <= 2'd0;
        sts_pend_q <= 2'd0;
      end else if (sts_rem_q != 2'd0) begin
        sts_on_q   <= 1'b1;
        sts_rem_q  <= sts_rem_q - 2'd1;
        sts_pend_q <= sts_take;
      end else if (sts_on_q) begin
        // The clock negated between two indications.
        sts_on_q   <= 1'b0;
        sts_pend_q <= sts_take;
      end else if (sts_take != 2'd0) begin
        sts_on_q   <= 1'b1;
        sts_rem_q  <= sts_take - 2'd1;
        sts_pend_q <= 2'd0;
      end else begin
        sts_on_q   <= 1'b0;
      end
    end
  end

  assign status_n_o = ~sts_on_q;
  assign refill_n_o = ~refill_on_q;

  // ==========================================================================
  // Back to the sequencer
  // ==========================================================================
  assign req_rdata   = rdata_q;
  assign req_early   = early_q;
  assign fetch_rdata = frdata_q;

  // How the cycle ended, as the samples of Tables 7-8 and 7-9 leave it. This is
  // the live verdict, and it lives only until the rising edge that ends S5
  // consumes it.
  always_comb begin
    if (term_err)                            end_now = rd68031_pkg::CE_BERR;
    else if (term_rty)                       end_now = rd68031_pkg::CE_RETRY;
    else if (term_avc)                       end_now = rd68031_pkg::CE_AVEC;
    else if (term_hlt)                       end_now = rd68031_pkg::CE_HALT;
    else if (term_syn)                       end_now = rd68031_pkg::CE_STERM;
    else if (term_q)                         end_now = rd68031_pkg::CE_DSACK;
    else                                     end_now = rd68031_pkg::CE_NONE;
  end

  // What the SEQUENCER is told, which has to outlive it.
  //
  // The verdict is cleared on the falling edge that ends S5 and `req_ack` is
  // raised on the rising edge inside it, so the sequencer -- which retires on
  // the rising edge AFTER it sees the acknowledge -- looked at a verdict that
  // had already been cleared half a clock earlier. Every microword that tests
  // how a cycle ended read CE_NONE: the interrupt acknowledge never saw its
  // AVEC and never saw its bus error, so the autovector and the spurious
  // interrupt were both unreachable, and a vectored interrupt was the only
  // one that worked. Latched with `req_ack`, it holds until the next operand
  // finishes, which is what lets `exc_irq` test AVEC on one microword and BERR
  // on the next.
  assign req_end   = req_end_q;
  assign req_dsack = port_code;

  // ==========================================================================
  // The fault snapshot -- doc/ssw.md
  //
  // Everything the fault frame says about the faulted access, latched on the
  // clock the fault is recognised. It has to be a latch and not a view of the
  // live operand registers, because the frame is BUILT BY BUS CYCLES: by the
  // time the special status word reaches +$0A of the frame, four writes have
  // gone through the same operand engine and op_addr, op_rem and op_data are
  // about the last of them.
  //
  // The address is the operand's residual address -- the next byte still to
  // transfer -- and not the address the microword asked for. UM20 6.2.2 has the
  // handler "transfer the properly sized data from the data output buffer on
  // the stack frame to the location indicated by the data fault address", and
  // what is left to transfer is what it has to move.
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      flt_addr  <= '0;
      flt_bytes <= 3'd0;
      flt_fc    <= 3'd0;
      flt_rw    <= 1'b1;
      flt_rmc   <= 1'b0;
      flt_dob   <= '0;
      flt_dib   <= '0;
    end else if (st_n == rd68031_pkg::ST_S5 && op_finishing && !op_isfetch
                 && term_err && ((op_fc != rd68031_pkg::FC_CPU) || op_cpflt)) begin
      flt_addr  <= op_addr;
      flt_bytes <= op_rem;
      flt_fc    <= op_fc;
      flt_rw    <= op_rw;
      flt_rmc   <= op_rmc;
      // The two buffers are the same register, because an operand is either
      // being read or being written and op_data is whichever applies. They are
      // separate frame fields, and separate here, so that a handler reads the
      // one the direction makes meaningful and RTE writes back only that one.
      flt_dob   <= op_rw ? flt_dob : op_data[31:0];
      flt_dib   <= op_rw ? op_data[31:0] : flt_dib;
    end
  end

  // PRM 6 RESET: "asserts the RSTO signal for 512 clock periods, resetting all
  // external devices" -- and UM 7.8: "the processor drives the RESET signal for
  // 512 clock cycles". The counter is nine bits plus the state bit that
  // qualifies it, so the pin is driven on the 512 clocks in which rsto_q is set.
  //
  // `reset_busy` answers on the same clock the request arrives, before the
  // counter has started. Without that the sequencer's microword would see an
  // idle bus unit and retire immediately; with it, the one clock in which the
  // request is presented and the counter is not yet running is still a busy
  // one. The arming bit is the other half of the same problem at the other end:
  // the request is still asserted on the clock the count expires, and must not
  // be allowed to start it again.
  logic [8:0] rsto_cnt;
  logic       rsto_arm_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsto_cnt   <= 9'd0;
      rsto_q     <= 1'b0;
      rsto_arm_q <= 1'b1;
    end else if (rsto_q) begin
      rsto_arm_q <= 1'b0;
      if (rsto_cnt == 9'd0) rsto_q   <= 1'b0;
      else                  rsto_cnt <= rsto_cnt - 9'd1;
    end else if (reset_req && rsto_arm_q) begin
      rsto_q     <= 1'b1;
      rsto_cnt   <= 9'd511;
      rsto_arm_q <= 1'b0;
    end else if (!reset_req) begin
      rsto_arm_q <= 1'b1;
    end
  end

  assign reset_busy  = rsto_q || (reset_req && rsto_arm_q);
  assign bus_idle    = bus_is_idle;

  // ==========================================================================
  // Inputs this unit does not consume yet. The list shrinks visibly as the design
  // fills in, which is why it is written out rather than waived wholesale.
  // ==========================================================================
  logic unused_biu;
  assign unused_biu = &{1'b1,
                        rst_op_valid, rst_addr, rst_bytes, rst_fc, rst_rw,
                        rst_rmc, rst_dob,
                        fetch_addr[1:0], bus_abort,
                        reset_req, dbf,
                        avec_n_i,
                        op_data[39:32],
                        next_last[3:0]};

endmodule
