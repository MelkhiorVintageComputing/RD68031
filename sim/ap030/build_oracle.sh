#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
# Build AP68030's unmodified program bench plus our bound pin monitor.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
AP=${AP:-$HERE/../../build/ap030/AP68030}
RTL=$AP/rtl
OUT=${OUT:-$HERE/../../build/ap030/obj_oracle}
mkdir -p "$OUT"
verilator --binary --build-jobs 4 --timing -Wno-BLKANDNBLK -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
  --output-split 20000 --output-split-cfuncs 500 -CFLAGS -O1 -I$RTL -I$RTL/core -I$AP/tb \
  --top-module tb_ap030_program --Mdir "$OUT" -o tb_oracle \
  $AP/tb/tb_ap030_program.sv "$HERE/pin_monitor.sv" \
  $RTL/ap030_top.v $RTL/ap030_core.v $RTL/ap030_memsys.v $RTL/ap030_mmu.v $RTL/ap030_cache.v \
  $RTL/ap030_bus.v $RTL/ap030_alu.v $RTL/ap030_muldiv.v $RTL/ap030_regfile.v > "$OUT.log" 2>&1 \
  || { grep -E "^%Error" "$OUT.log" | head; exit 1; }
echo "built $OUT/tb_oracle"
