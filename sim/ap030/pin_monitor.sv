// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031
// RD68031 M0 spike: non-invasive pin-level bus monitor for AP68030's
// tb_ap030_program, attached with `bind` (the bench file is not edited).
// Writes one line per data transfer (one per beat for bursts) to the file
// given by +pintrace=<file>.
// Format (space separated key=value, fixed order):
//   clk=<posedge #> cyc=<bus cycle #> beat=<0..3> R|W a=<A31-0> fc=<n> siz=<b>
//   term=STERM|DSACK32|DSACK16|DSACK8|BERR|AVEC|RETRY d=<D31-0>
//   cbreq=<0/1 asserted> cback=<0/1> ciin=<0/1> ciout=<0/1> rmc=<0/1> ws=<clocks AS low>
// Signal values in the line are "asserted" flags (1 = asserted), not pin levels.
module pin_monitor(
	input clk, input rst_n, input bus_oe, input as_n, input ds_n, input rw, input [31:0] a, input [2:0] fc,
	input [1:0] siz, input [31:0] d_i, input [31:0] d_o, input sterm_n, input dsack0_n,
	input dsack1_n, input berr_n, input halt_n, input avec_n, input ciin_n, input cback_n,
	input cbreq_n, input ciout_n, input rmc_n, input ecs_n, input [31:0] clocks);
	integer fd = 0, cyc = 0, beat = 0, aslen = 0;
	reg as_prev = 0, async_done = 0;
	reg [8*256-1:0] fn;
	initial if ($value$plusargs("pintrace=%s", fn)) fd = $fopen(fn, "w");
	wire as_on = rst_n & bus_oe & ~as_n;   // ignore pin state while RESET is held
	function [8*7-1:0] tname(input s, input d1, input d0, input b, input h, input av);
		if (!b && !h) tname = "RETRY";
		else if (!b) tname = "BERR";
		else if (!av) tname = "AVEC";
		else if (!s) tname = "STERM";
		else if (!d1 && !d0) tname = "DSACK32";
		else if (!d1) tname = "DSACK16";
		else if (!d0) tname = "DSACK8";
		else tname = "?";
	endfunction
	task emit;
		$fdisplay(fd, "clk=%0d cyc=%0d beat=%0d %s a=%08x fc=%0d siz=%b term=%0s d=%08x cbreq=%0d cback=%0d ciin=%0d ciout=%0d rmc=%0d ws=%0d",
		          clocks, cyc, beat, rw ? "R" : "W", a, fc, siz,
		          tname(sterm_n, dsack1_n, dsack0_n, berr_n, halt_n, avec_n),
		          rw ? d_i : d_o, !cbreq_n, !cback_n, !ciin_n, !ciout_n, !rmc_n, aslen);
	endtask
	// The bench drives its synchronous port so that STERM is valid at a rising
	// edge (one beat per edge); asynchronous terminations are reported once per
	// cycle, at the first rising edge where DSACKx/BERR/AVEC is seen.
	always @(posedge clk) if (fd != 0 && rst_n) begin
		if (as_on && !as_prev) begin cyc = cyc + 1; beat = 0; aslen = 0; async_done = 0; end
		if (as_on) begin
			aslen = aslen + 1;
			if (!sterm_n && berr_n) begin emit; beat = beat + 1; end
			else if (!async_done && (!dsack0_n || !dsack1_n || !berr_n || !avec_n)) begin emit; async_done = 1; end
		end
		as_prev = as_on;
	end
	final if (fd != 0) $fclose(fd);
endmodule

bind tb_ap030_program pin_monitor u_pin_monitor(
	.clk(clk), .rst_n(reset_n), .bus_oe(bus_oe), .as_n(as_n), .ds_n(ds_n), .rw(rw), .a(a), .fc(fc), .siz(siz),
	.d_i(d_i), .d_o(d_o), .sterm_n(sterm_n), .dsack0_n(dsack0_n), .dsack1_n(dsack1_n),
	.berr_n(berr_n), .halt_n(halt_n), .avec_n(avec_n), .ciin_n(ciin_n), .cback_n(cback_n),
	.cbreq_n(cbreq_n), .ciout_n(ciout_n), .rmc_n(rmc_n), .ecs_n(ecs_n), .clocks(clocks));
