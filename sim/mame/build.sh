#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Build MAME's Sun-3/80 with the RD68031 core (M14; doc/oracles.md, "MAME").
#
#   sim/mame/build.sh mame [OUT]   MAME with only the sun3x driver, from a copy
#                                  of Inputs/ref/mame in OUT/src (Inputs/ is
#                                  immutable and MAME builds in its own tree),
#                                  with sim/mame/sun3x.patch and the
#                                  rd68031_device added: OUT/src/sun3x
#   sim/mame/build.sh vlt [OUT]    the core under Verilator with its bus agent,
#                                  as the shared object that device loads:
#                                  OUT/vlt/rd68031_vlt.so
#
# OUT defaults to build/mame. Both are heavy jobs: run each alone (CLAUDE.md).
#
# SDL2 and GL development headers are needed and are not installed system-wide
# here: SDLPREFIX (OUT/sdlprefix) is a tree made by apt-get download + dpkg -x of
# libsdl2-dev, libsdl2-ttf-dev, libgl-dev, libegl-dev, libglx-dev and
# mesa-common-dev (doc/oracles.md, "MAME"), made here if it is missing. -j2: a MAME compile unit can take 1-2 GB, and the
# build is killed if available memory falls under 3 GB (CLAUDE.md). The
# Verilator build is -j4 at most.
#
# Knobs: JOBS (2 for mame, 4 for vlt), ICACHE_ENTRIES, DCACHE_ENTRIES (64).
# The core is built with its coprocessor interface (COPROCESSOR=1) and RD68884
# (Inputs/ip/RD68884) as its MC68881, in one model (sim/mame/rd68031_fpu.sv);
# the reference m68030 keeps MAME's own FPU, also a 68881 (sun3_80ref).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$R/sim/mame
WHAT=${1:-}
OUT=${2:-$R/build/mame}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# Copy $1 to $2 only if it differs, so that make sees no change otherwise.
install_if_changed() {
  cmp -s "$1" "$2" || cp "$1" "$2"
}

case $WHAT in
mame)
  SDLPREFIX=${SDLPREFIX:-$OUT/sdlprefix}
  JOBS=${JOBS:-2}
  if [ ! -d "$SDLPREFIX/usr/include/SDL2" ]; then
    # Unprivileged: the packages' contents unpacked into a private prefix.
    mkdir -p "$OUT/debs" "$SDLPREFIX"
    (cd "$OUT/debs" && apt-get download libsdl2-dev libsdl2-ttf-dev libgl-dev libegl-dev \
       libglx-dev mesa-common-dev > /dev/null) || { echo "build.sh: apt-get download failed" >&2; exit 1; }
    for d in "$OUT"/debs/*.deb; do dpkg -x "$d" "$SDLPREFIX"; done
  fi
  [ -d "$OUT/src" ] || rsync -a --exclude .git "$R/Inputs/ref/mame/" "$OUT/src/"
  # The files sun3x.patch changes (patched.lst: the driver, its list, the
  # m68030's MMU), patched from the pristine sources. sim/mame/mkpatch.sh makes
  # the patch from an edited build copy.
  T=$(mktemp -d)
  for f in $(cat "$HERE/patched.lst"); do
    mkdir -p "$T/$(dirname "$f")"; cp "$R/Inputs/ref/mame/$f" "$T/$f"
  done
  (cd "$T" && patch -s -p1 < "$HERE/sun3x.patch") || { rm -rf "$T"; exit 1; }
  for f in $(cat "$HERE/patched.lst"); do
    install_if_changed "$T/$f" "$OUT/src/$f"
  done
  rm -rf "$T"
  # The device, beside the driver: MAME's makedep picks up rd68031.cpp from
  # the driver's #include. rd68031_vlt.cpp is not copied: it is the shared
  # object's, and is never compiled into MAME.
  for f in rd68031.h rd68031.cpp rd68031_vlt.h; do
    install_if_changed "$HERE/$f" "$OUT/src/src/mame/sun/$f"
  done
  cd "$OUT/src" || exit 1
  export PKG_CONFIG_PATH=$SDLPREFIX/usr/lib/x86_64-linux-gnu/pkgconfig
  export PATH=$SDLPREFIX/usr/bin:$PATH
  make REGENIE=1 SUBTARGET=sun3x SOURCES=src/mame/sun/sun3x.cpp NOWERROR=1 NO_OPENGL=1 NO_USE_MIDI=1 \
    NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 USE_QTDEBUG=0 TOOLS=0 \
    SDL_INSTALL_ROOT=$SDLPREFIX/usr ARCHOPTS="-I$SDLPREFIX/usr/include -I$SDLPREFIX/usr/include/x86_64-linux-gnu" \
    LDOPTS="-L$SDLPREFIX/usr/lib/x86_64-linux-gnu" -j"$JOBS" > "$OUT/build.log" 2>&1 &
  MK=$!
  while kill -0 $MK 2>/dev/null; do
    a=$(free -m | awk '/Mem:/{print $7}')
    if [ "$a" -lt 3000 ]; then
      echo "build.sh: only ${a} MB available, stopping the MAME build" >&2
      kill -TERM -- $MK 2>/dev/null; pkill -TERM -P $MK
    fi
    sleep 5
  done
  wait $MK; rc=$?
  [ $rc -eq 0 ] || { grep -E "error|Error" "$OUT/build.log" | head -20; exit $rc; }
  echo "built $OUT/src/sun3x"
  ;;
vlt)
  JOBS=${JOBS:-4}
  RTL="$R/rtl/rd68031_pkg.sv $(ls "$R"/rtl/gen/*_pkg.sv) $(ls "$R"/rtl/gen/*.sv | grep -v _pkg.sv)"
  for m in sync dedge_ff shifter divider bitfield biu icache dcache ifu mmu_xl mmu seq top; do
    RTL="$RTL $R/rtl/rd68031_$m.sv"
  done
  # RD68884 beside it, as its MC68881 (M14 phase B; sim/mame/rd68031_fpu.sv).
  F=$R/Inputs/ip/RD68884/rtl
  [ -f "$F/rd68884_top.sv" ] || { echo "build.sh: Inputs/ip/RD68884 is missing (git submodule update --init Inputs/ip/RD68884)" >&2; exit 1; }
  FPU="$F/rd68884_pkg.sv $(ls "$F"/gen/*_pkg.sv) $(ls "$F"/gen/*.sv | grep -v _pkg.sv)"
  for m in sync cu_decode biu regfile seq top; do
    FPU="$FPU $F/rd68884_$m.sv"
  done
  rm -f "$OUT/vlt/rd68031_vlt.so"
  # public.vlt is rd-virt's: the registers and the boundary signals.
  verilator --cc --exe --build --build-jobs "$JOBS" --threads 1 -O3 \
    -Wno-fatal -Wno-lint -Wno-style --top-module rd68031_fpu \
    -GICACHE_ENTRIES="${ICACHE_ENTRIES:-64}" -GDCACHE_ENTRIES="${DCACHE_ENTRIES:-64}" \
    --output-split 20000 --output-split-cfuncs 500 --Mdir "$OUT/vlt" -o rd68031_vlt.so \
    -CFLAGS "-O3 -fPIC -std=c++17 -I$HERE" -LDFLAGS "-shared -fPIC" \
    "$R/rtl/rd68031.vlt" "$F/rd68884.vlt" "$R/sim/virt/public.vlt" $RTL $FPU \
    "$HERE/rd68031_fpu.sv" "$HERE/rd68031_vlt.cpp" \
    > "$OUT/vlt.log" 2>&1 \
    || { grep -E "%Error|error:" "$OUT/vlt.log" | head -20; exit 1; }
  echo "built $OUT/vlt/rd68031_vlt.so"
  ;;
*)
  echo "usage: $0 mame|vlt [OUT]" >&2; exit 2
  ;;
esac
