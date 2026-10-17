#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Regenerate sim/mame/sun3x.patch from the edited build copy of MAME
# (build/mame/src), against the pristine Inputs/ref/mame. Run after editing
# the driver (or the m68030's MMU) in the build copy, before sim/mame/build.sh
# mame, which re-applies the patch to fresh copies of the same files.
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-$R/build/mame/src}
cd "$R/Inputs/ref/mame"
{
  for f in $(cat "$R/sim/mame/patched.lst"); do
    diff -u --label "a/$f" --label "b/$f" "$f" "$SRC/$f" || true
  done
} > "$R/sim/mame/sun3x.patch"
echo "wrote sim/mame/sun3x.patch ($(grep -c '^+++' "$R/sim/mame/sun3x.patch") files)"
