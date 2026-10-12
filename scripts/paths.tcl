# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

# What limits this design's frequency, and proof that nothing unreachable does.
#
#   vivado -mode batch -source scripts/paths.tcl -tclargs <repo-root>
#
# Until the routes below were taken out of the RTL, the worst path static timing
# found was one the microcode could not take -- an operand into the bit-field
# unit or the shifter whose result then decided the next micro-address -- and
# this script cut those routes out of a report to show what was left. Now they
# do not exist: the conditions on a microword's own result and the status
# register a decoding microword writes are computed from the registers it reads
# (tools/ucode/assemble.py's check_live_shape holds each to its one shape), and
# the shifter has an operand multiplexer of its own (check_shift_src). So static
# timing is the real answer, and what this script does is check that it stays
# that way: each route must have no path at all, and the build fails if one
# comes back. Then it groups the worst paths into families. doc/critical-path.md.
#
# Runs on the checkpoint `make impl` leaves behind, so it costs minutes, not an
# hour.

set root [lindex $argv 0]
set dcp  $root/build/rd68031_top_impl.dcp
if {![file exists $dcp]} {
    puts "RD68031-PATHS: no $dcp -- run `make impl` first"
    exit 1
}
set_param general.maxThreads 4
open_checkpoint $dcp
source $root/scripts/fmax.tcl
rd_report_fmax "RD68031-PATHS: static"

# Each route is a PAIR of -through points on module pins, which survive
# -flatten_hierarchy none where nets get merged and renamed. Everything upc_nxt
# feeds: the microcode store's address and the micro-PC itself.
#
# The latch that notes an interrupt being entered, irq_taking_q, was an
# endpoint too until M15, and is not now: since RTE puts the level back from
# the fault frame (doc/checkpoint.md rule 9) its D input is also fed from the
# result bus `y`, where every unit's result legitimately arrives, so the
# shifter has a real structural path to it -- found at M15, 9.6 ns of slack,
# through the RTE put-back and not through upc_nxt. Its enable, irq_enter, is
# decoded from upc_nxt, and upc_nxt's every path already ends at upc_reg and
# the store's address, so dropping it loses nothing the check is for.
set to_upc [concat \
    [get_pins -quiet u_seq/u_urom/addr[*]] \
    [get_pins -quiet -filter {REF_PIN_NAME == D || REF_PIN_NAME == CE} \
         -of_objects [get_cells -quiet {u_seq/upc_reg[*]}]]]
set bf_out [filter [get_pins -quiet u_seq/u_bf/*] {DIRECTION == OUT}]
set routes [list \
    [list shifter-to-upc \
          [filter [get_pins -quiet u_seq/u_shifter/*] {DIRECTION == OUT}] $to_upc] \
    [list bitfield-to-upc $bf_out $to_upc] \
    [list bitfield-to-shifter $bf_out \
          [filter [get_pins -quiet u_seq/u_shifter/*] {DIRECTION == IN}]] \
]

set bad 0
foreach r $routes {
    lassign $r name frm to
    if {[llength $frm] == 0 || [llength $to] == 0} {
        puts "RD68031-PATHS: route $name names nothing\
              ([llength $frm] and [llength $to] pins) -- ABORT"
        exit 1
    }
    set p [get_timing_paths -quiet -delay_type max -max_paths 1 \
               -through $frm -through $to]
    if {[llength $p] == 0} {
        puts "RD68031-PATHS: $name: no path, as intended"
    } else {
        puts "RD68031-PATHS: FAIL: $name has a path again, slack [get_property SLACK $p] ns"
        set bad 1
    }
}

report_timing -delay_type max -max_paths 3000 -unique_pins -nworst 1 \
    -file paths_activatable.rpt

# The pins. The constraint files time nothing between a pin and a register --
# this is a core run out of context, and its pins meet whatever logic the
# design around it puts there -- so the depth of the logic behind each pin is
# not in the figure above. Report it here, on the routed checkpoint, as if the
# design around the core launched every input from a register on CLK's rising
# edge and captured every output on the next one: a zero input and output
# delay. A pin the core samples on a falling edge then has half a period, as it
# would. These constraints exist only in this session; the figure above and
# the implementation itself are unchanged by them.
set p_in  [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}]
set p_out [get_ports -filter {DIRECTION == OUT}]
set_input_delay  -clock clk 0 $p_in
set_output_delay -clock clk 0 $p_out
set period [get_property PERIOD [get_clocks clk]]
array set pin_worst {}
foreach port [concat $p_in $p_out] {
    if {[get_property DIRECTION $port] eq "IN"} {
        set p [get_timing_paths -quiet -delay_type max -max_paths 1 -from $port]
    } else {
        set p [get_timing_paths -quiet -delay_type max -max_paths 1 -to $port]
    }
    if {[llength $p] == 0} { continue }
    set req [get_property REQUIREMENT $p]
    if {$req <= 0} { continue }
    set need [expr {([get_property REQUIREMENT $p] - [get_property SLACK $p]) * $period / $req}]
    regsub {\[[0-9]+\]$} [get_property NAME $port] {} base
    if {![info exists pin_worst($base)] || [lindex $pin_worst($base) 0] < $need} {
        set pin_worst($base) [list $need $req [get_property LOGIC_LEVELS $p] \
            [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
    }
}
set pf [open paths_pins.rpt w]
foreach base [lsort [array names pin_worst]] {
    lassign $pin_worst($base) need req lv sp ep
    set line [format "RD68031-PINS: %-12s needs %6.2f ns (%6.2f MHz), %2d levels, requirement %s ns: %s -> %s" \
        $base $need [expr {1000.0 / $need}] $lv $req $sp $ep]
    puts $pf $line
}
close $pf
if {$bad} { exit 1 }
exit 0
