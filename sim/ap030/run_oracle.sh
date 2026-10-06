#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
# Usage: run_oracle.sh <prog.bin> <out-prefix> [extra plusargs...]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
AP=${AP:-$HERE/../../build/ap030/AP68030}
bin=$1; out=$2; shift 2
python3 -I "$AP/tb/bin2hex.py" "$bin" "$out.hex"
"${OUT:-$HERE/../../build/ap030/obj_oracle}/tb_oracle" "+prog=$out.hex" "+pintrace=$out.pins" +bustrace "$@" > "$out.log" 2>&1 || true
grep -E 'program reports|ALL TESTS|TEST FAILED|FAIL' "$out.log" | head -5
