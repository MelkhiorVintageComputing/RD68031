#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Run the Sun-3/80 PROM to its monitor, type the monitor commands, and keep
# the console (M14; `make sun3x`, `make sun3x-m68030`).
#
#   sim/mame/run.sh MACHINE DIR PORT TIMEOUT [BIOS]
#
# MACHINE is sun3_80ref (MAME's m68030 without its FPU) or sun3_80rd (the
# core); DIR is made afresh -- no NVRAM survives from an earlier run, so the
# M48T02 starts from the image in the ROM path every time. The console goes
# to DIR/console.out, MAME's output to DIR/console.out.mame, the arrival times
# to DIR/console.out.times. Environment: MAMEDIR (build/mame), CMDS (the
# command file, sim/mame/monitor.cmds).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
M=$1; D=$2; PORT=$3; TMO=$4; BIOS=${5:-rev303}
MAMEDIR=${MAMEDIR:-$R/build/mame}
CMDS=${CMDS:-$R/sim/mame/monitor.cmds}
rm -rf "$D"; mkdir -p "$D"; cd "$D" || exit 1
export RD68031_VLT=$MAMEDIR/vlt/rd68031_vlt.so
python3 "$R/sim/mame/drive.py" --port "$PORT" --timeout "$TMO" --prompt '[>?] *' \
  --log console.out --cmds "$CMDS" -- \
  "$MAMEDIR/src/sun3x" "$M" -bios "$BIOS" -rompath "$MAMEDIR/roms" \
  -video none -sound none -nothrottle -skip_gameinfo \
  -rs232a null_modem -bitb "socket.127.0.0.1:$PORT" \
  -autoboot_script "$R/sim/mame/control.lua" -autoboot_delay 0
