#!/bin/sh
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Build rd-virt (doc/virt.md):
#
#   sim/virt/build.sh uae  OUT     the UAE030-only machine (OUT/rdvirt-uae)
#   sim/virt/build.sh rtl  OUT     the RTL under Verilator, with UAE030 for the
#                                  lockstep (OUT/obj/rdvirt)
#
# The Verilator build is a heavy job (CLAUDE.md): run it alone. It is
# incremental, and single-threaded (--threads 1): the design is one clock
# domain small enough that thread hand-offs cost more than they give.
# Knobs from the environment: ICACHE_ENTRIES, DCACHE_ENTRIES, COPROCESSOR (0:
# a machine with no FPU takes an F-line exception on every coprocessor
# opcode, which is what this board needs), JOBS (4).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
WHAT=$1
OUT=$2
[ -n "$WHAT" ] && [ -n "$OUT" ] || { echo "usage: $0 uae|rtl OUT" >&2; exit 2; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
LIB=$TOP/build/uae030/libuae030.a
WRAP="-Wl,--wrap=mmu030_get_word_unaligned -Wl,--wrap=mmu030_get_long_unaligned -Wl,--wrap=mmu030_put_word_unaligned -Wl,--wrap=mmu030_put_long_unaligned"
SRCS="$HERE/rdvirt.cpp $HERE/machine.cpp $HERE/cpu_uae.cpp"
JOBS=${JOBS:-4}

case $WHAT in
uae)
	${CXX:-g++} -O2 -g -std=c++17 -Wall -I"$HERE" -I"$TOP/tools/cosim/uae030" \
		-o "$OUT/rdvirt-uae" $SRCS "$LIB" $WRAP -lm
	echo "built $OUT/rdvirt-uae"
	;;
rtl)
	RTL="$TOP/rtl/rd68031_pkg.sv $(ls "$TOP"/rtl/gen/*_pkg.sv) $(ls "$TOP"/rtl/gen/*.sv | grep -v _pkg.sv)"
	for m in sync dedge_ff shifter divider bitfield biu icache dcache ifu mmu_xl mmu seq top; do
		RTL="$RTL $TOP/rtl/rd68031_$m.sv"
	done
	# the archive is not a dependency Verilator's makefile knows: relink always
	rm -f "$OUT/obj/rdvirt"
	verilator --cc --exe --build --build-jobs "$JOBS" --threads 1 -O3 \
		-Wno-fatal -Wno-lint -Wno-style --top-module rd68031_top \
		-GCOPROCESSOR="${COPROCESSOR:-0}" -GICACHE_ENTRIES="${ICACHE_ENTRIES:-64}" \
		-GDCACHE_ENTRIES="${DCACHE_ENTRIES:-64}" \
		--output-split 20000 --output-split-cfuncs 500 --Mdir "$OUT/obj" -o rdvirt \
		-CFLAGS "-O2 -std=c++17 -DRDVIRT_RTL -I$HERE -I$TOP/tools/cosim/uae030" \
		-LDFLAGS "$LIB $WRAP -lm" \
		"$TOP/rtl/rd68031.vlt" "$HERE/public.vlt" $RTL $SRCS "$HERE/cpu_rtl.cpp" \
		> "$OUT/verilator.log" 2>&1 \
		|| { grep -E "%Error|error:" "$OUT/verilator.log" | head -20; exit 1; }
	echo "built $OUT/obj/rdvirt"
	;;
*)
	echo "usage: $0 uae|rtl OUT" >&2; exit 2
	;;
esac
