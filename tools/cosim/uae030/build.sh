#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Build the UAE030 oracle: Hatari's copy of the WinUAE CPU core (src/cpu),
# copied out of Inputs/ (never modified in place), patched in the copy, and
# archived with uae030_glue.c into libuae030.a. The front-ends (uae030_trace,
# uae030_ea, vectors_gen, the uae030 dump tool) are linked against it by the
# Makefile, with UAE030_LDFLAGS below.
#
#   tools/cosim/uae030/build.sh [OUT]      (default OUT = build/uae030)
#
# Incremental: the copy keeps the pristine files' timestamps and a patched file
# is only replaced when its content changed, so a second run recompiles nothing.
#
# Memory note: the generated cpuemu_*.c are huge; they are compiled at -O0
# (only cpuemu_34.c, the 68030 MMU+cache core actually used, at -O1) and at
# most JOBS (default 4) at a time -- about 300 MB a compile.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$TOP/build/uae030}
JOBS=${JOBS:-4}
H=$TOP/Inputs/ref/hatari/src
CC=${CC:-gcc}

mkdir -p "$OUT/gen" "$OUT/obj" "$OUT/stubinc" "$OUT/cpu"
OUT=$(cd "$OUT" && pwd)

# 1. a staged copy of the core, patched, then synced into $OUT/cpu file by file
STAGE=$OUT/stage
rm -rf "$STAGE"
cp -rp "$H/cpu" "$STAGE"
cd "$STAGE"
# 1a. no host-side page caches in front of the ATC: every access goes through
#     the emulated ATC, and nothing bypasses the memory banks (bus hook).
sed -i 's/^#define MMU_DPAGECACHE030 1/#define MMU_DPAGECACHE030 0/; s/^#define MMU_IPAGECACHE030 1/#define MMU_IPAGECACHE030 0/' cpummu030.h
# 1b. publish the function code of every physical access, flag table searches,
#     and flag instruction fetches (which share the physical read routine with
#     operand reads, so nothing downstream could tell them apart otherwise).
sed -i 's/^\tcacheablecheck(addr);$/\tuae030_bus_fc = fc; cacheablecheck(addr);/' cpummu030.c
sed -i 's/^\tx_phys_put_long(addr, v);$/\tuae030_bus_walk = 1; x_phys_put_long(addr, v); uae030_bus_walk = 0;/' cpummu030.c
sed -i 's/^\treturn x_phys_get_long(addr);$/\tuae030_bus_walk = 1; uae_u32 v = x_phys_get_long(addr); uae030_bus_walk = 0; return v;/' cpummu030.c
sed -i 's/^\tdescr\[0\] = x_phys_get_long(addr);$/\tuae030_bus_walk = 1; descr[0] = x_phys_get_long(addr);/; s/^\tdescr\[1\] = x_phys_get_long(addr + 4);$/\tdescr[1] = x_phys_get_long(addr + 4); uae030_bus_walk = 0;/' cpummu030.c
sed -i 's/^\tv = x_phys_get_ilong(addr);$/\tuae030_bus_ifetch = 1; v = x_phys_get_ilong(addr); uae030_bus_ifetch = 0;/; s/^\tv = x_phys_get_iword(addr);$/\tuae030_bus_ifetch = 1; v = x_phys_get_iword(addr); uae030_bus_ifetch = 0;/' cpummu030.c
sed -i '0,/^#include "cpummu030.h"/s//#include "cpummu030.h"\nextern int uae030_bus_fc, uae030_bus_walk, uae030_bus_ifetch;/' cpummu030.c
# 1c. per-instruction hook at the top of the 68030 MMU run loop
sed -i 's/^insretry:$/insretry:\n\t\t\t\tuae030_insn_boundary();/' newcpu.c
sed -i '0,/^#include "cpummu030.h"/s//#include "cpummu030.h"\nextern void uae030_insn_boundary(void);/' newcpu.c
grep -q 'uae030_bus_fc = fc' cpummu030.c && grep -q 'uae030_bus_walk = 1; uae_u32 v' cpummu030.c \
  && [ "$(grep -c 'uae030_bus_ifetch = 1; v = x_phys_get_i' cpummu030.c)" = 2 ] \
  && grep -q 'uae030_insn_boundary();' newcpu.c && grep -q 'MMU_IPAGECACHE030 0' cpummu030.h \
  || { echo "patch failed" >&2; exit 1; }
cd "$OUT"
( cd "$STAGE" && find . -type f ) | while read -r f; do
	if ! cmp -s "$STAGE/$f" "$OUT/cpu/$f"; then
		mkdir -p "$(dirname "$OUT/cpu/$f")"
		cp -p "$STAGE/$f" "$OUT/cpu/$f"
	fi
done
rm -rf "$STAGE"

# 2. minimal config.h for Hatari's headers
cat > "$OUT/stubinc/config.h.new" <<'EOF'
#define HAVE_STRINGS_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_UTIME_H 1
#define HAVE_BYTESWAP_H 1
#define HAVE_BSWAP_16 1
#define HAVE_BSWAP_32 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_NANOSLEEP 1
#define BIN2DATADIR "."
EOF
cmp -s "$OUT/stubinc/config.h.new" "$OUT/stubinc/config.h" \
  || mv "$OUT/stubinc/config.h.new" "$OUT/stubinc/config.h"
rm -f "$OUT/stubinc/config.h.new"

# 3. generators -> cpudefs.c, cpuemu_*.c, cpustbl.c, cputbl.h
cd "$OUT/gen"
if [ ! -f cpustbl.c ] || [ "$OUT/cpu/gencpu.c" -nt cpustbl.c ] || [ "$OUT/cpu/table68k" -nt cpustbl.c ]; then
	$CC -O1 -I"$OUT/cpu" -I"$H/includes" -o build68k "$OUT/cpu/build68k.c" "$OUT/cpu/writelog.c"
	./build68k < "$OUT/cpu/table68k" > cpudefs.c
	$CC -O1 -I"$OUT/cpu" -I. -I"$H/includes" -o gencpu "$OUT/cpu/gencpu.c" "$OUT/cpu/readcpu.c" cpudefs.c
	./gencpu
fi

# 4. compile
cd "$OUT"
INC="-Istubinc -Icpu -Igen -I$H/includes -I$H/debug -I$H/falcon -I$H -Icpu/softfloat -I$HERE"
CF="-g -fwrapv -w -std=gnu99"
CORE="cpu/cpummu.c cpu/cpummu030.c cpu/debug.c cpu/disasm.c cpu/newcpu_common.c cpu/newcpu.c
      cpu/readcpu.c cpu/writelog.c cpu/fpp.c cpu/fpp_native.c cpu/fpp_softfloat.c
      cpu/softfloat/softfloat.c cpu/softfloat/softfloat_decimal.c cpu/softfloat/softfloat_fpsp.c
      cpu/machdep/m68k.c gen/cpudefs.c gen/cpustbl.c $HERE/uae030_glue.c"
compile() { # src opt
	o=obj/$(basename "$1" .c).o
	if [ ! -f "$o" ] || [ "$1" -nt "$o" ] || [ "$HERE/uae030.h" -nt "$o" ]; then
		$CC $2 $CF $INC -c "$1" -o "$o" || { echo "FAILED $1" >&2; return 1; }
	fi
}
for f in $CORE; do echo "$f -O2"; done > obj/list
for f in gen/cpuemu_*.c; do
	case $f in *cpuemu_34.c) echo "$f -O1";; *) echo "$f -O0";; esac
done >> obj/list
# simple job pool
pids=""; n=0; fail=0
while read -r f o; do
	compile "$f" "$o" & pids="$pids $!"; n=$((n+1))
	if [ $n -ge "$JOBS" ]; then for p in $pids; do wait $p || fail=1; done; pids=""; n=0; fi
done < obj/list
for p in $pids; do wait $p || fail=1; done
[ $fail = 0 ] || exit 1
# The spike's main object, if a spike build was copied here, is not part of the core.
rm -f obj/uae030_main.o
rm -f libuae030.a.new
ar rcs libuae030.a.new obj/*.o
mv libuae030.a.new libuae030.a
echo "built $OUT/libuae030.a"
