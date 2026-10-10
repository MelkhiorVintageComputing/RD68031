#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Build AP68030 into our own bench (sim/ap030/ap030_tb.sv) with Verilator,
# for make ap030. AP68030 is copied out of Inputs/ (never modified in place)
# into build/ap030/AP68030 and compiled from there, unmodified.
#
#   sim/ap030/build_bench.sh [OUT]     (default OUT = build/ap030/obj_bench)
#
# A heavy build (CLAUDE.md, host resources): run it alone, -j4 at most.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
AP=$TOP/build/ap030/AP68030
OUT=${1:-$TOP/build/ap030/obj_bench}
if [ ! -d "$AP" ]; then
	mkdir -p "$TOP/build/ap030"
	cp -r "$TOP/Inputs/ref/AP68030" "$AP"
fi
RTL=$AP/rtl
mkdir -p "$OUT"
verilator --binary --build-jobs 4 --timing -Wno-fatal -Wno-lint -Wno-style -Wno-BLKANDNBLK \
  -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN \
  --output-split 20000 --output-split-cfuncs 500 -CFLAGS -O1 -I"$RTL" -I"$RTL/core" \
  -I"$TOP/sim/models" --top-module ap030_tb --Mdir "$OUT" -o ap030_tb \
  "$TOP/sim/models/rd68031_slave.sv" "$TOP/sim/models/rd68031_busmon.sv" "$HERE/ap030_tb.sv" \
  "$RTL/ap030_top.v" "$RTL/ap030_core.v" "$RTL/ap030_memsys.v" "$RTL/ap030_mmu.v" \
  "$RTL/ap030_cache.v" "$RTL/ap030_bus.v" "$RTL/ap030_alu.v" "$RTL/ap030_muldiv.v" \
  "$RTL/ap030_regfile.v" > "$OUT.log" 2>&1 \
  || { grep -E "^%Error" "$OUT.log" | head -20; exit 1; }
echo "built $OUT/ap030_tb"
