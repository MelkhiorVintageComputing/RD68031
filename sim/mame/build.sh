#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Build MAME with only the sun3x driver, from a copy of Inputs/ref/mame (Inputs/
# is immutable and MAME builds in its own tree).
#
#   sim/mame/build.sh [OUT]        OUT defaults to build/mame
#
# SDL2 and GL development headers are needed and are not installed system-wide
# here: SDLPREFIX points at a tree made by apt-get download + dpkg -x of
# libsdl2-dev, libsdl2-ttf-dev, libgl-dev, libegl-dev and libglx-dev
# (doc/oracles.md, "MAME"). -j2: a MAME compile unit can take 1-2 GB, and the
# build is killed if available memory falls under 3 GB (CLAUDE.md).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$R/build/mame}
SDLPREFIX=${SDLPREFIX:-$OUT/sdlprefix}
JOBS=${JOBS:-2}
mkdir -p "$OUT"
[ -d "$OUT/src" ] || rsync -a --exclude .git "$R/Inputs/ref/mame/" "$OUT/src/"
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
wait $MK
