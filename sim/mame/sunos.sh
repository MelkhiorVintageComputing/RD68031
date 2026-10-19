#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# SunOS 4.1.1 on MAME's Sun-3/80 (M14 phase B; doc/oracles.md, "MAME").
#
#   sim/mame/sunos.sh fetch    DIR     the media of Inputs/sw/MANIFEST-sunos
#                                      into DIR/dl, each checked
#   sim/mame/sunos.sh media    DIR     DIR/tape1.tap (sim/mame/mktape.py, the
#                                      files in the manifest's order) and
#                                      DIR/blank.hd (a Sun label: a 24 MB
#                                      root, 48 MB of swap, 520 MB of /usr)
#   sim/mame/sunos.sh miniroot DIR     MUNIX booted from the tape copies the
#                                      miniroot into sd0b (sim/mame/sunos-
#                                      miniroot.cmds), on MAME's m68030:
#                                      DIR/miniroot.hd
#   sim/mame/sunos.sh install  DIR     the install, by hand from the miniroot's
#                                      shell (sim/mame/sunos-install.cmds), on
#                                      MAME's m68030: DIR/sunos.hd
#   sim/mame/sunos.sh boot MACHINE DIR OUT PORT TIMEOUT
#                                      a copy of DIR/sunos.hd booted on MACHINE
#                                      (sun3_80ref or sun3_80rd) to multi-user,
#                                      logged in, sim/mame/sunos-boot.cmds
#                                      typed: OUT/console.out
#
# Environment: MAMEDIR (build/mame). MAME's runs are light; none of this is in
# `make check`.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$R/sim/mame
WHAT=${1:-}
MAMEDIR=${MAMEDIR:-$R/build/mame}
export MAMEDIR

files() { grep -v '^#' "$R/Inputs/sw/MANIFEST-sunos" | awk 'NF { print $2 }'; }

case $WHAT in
fetch)
  D=$2; mkdir -p "$D/dl"
  grep -v '^#' "$R/Inputs/sw/MANIFEST-sunos" | while read -r sum name url; do
    [ -n "$sum" ] || continue
    f=$D/dl/$name
    if ! echo "$sum  $f" | sha256sum -c --quiet - 2>/dev/null; then
      curl -sSL -m 900 -o "$f" "$url" || { echo "sunos.sh: cannot fetch $url" >&2; exit 1; }
      echo "$sum  $f" | sha256sum -c --quiet - || { echo "sunos.sh: $name: wrong hash" >&2; exit 1; }
    fi
  done
  ;;
media)
  D=$2
  (cd "$D/dl" && python3 -I "$HERE/mktape.py" "$D/tape1.tap" $(files))
  python3 -I "$HERE/mkdisk.py" "$D/blank.hd" --mb 600 --part a:24 --part b:48 --part g:520 > /dev/null
  ;;
miniroot)
  D=$2
  cp "$D/blank.hd" "$D/work.hd"
  PROMPT='Enter a 1 or 2: *' CMDS=$HERE/sunos-miniroot.cmds \
  MAMEARGS="-scsibus:0 harddisk -hard1 $D/work.hd -tap $D/tape1.tap" \
    bash "$HERE/run.sh" sun3_80ref "$D/miniroot" 4462 3600 \
    || { echo "sunos.sh: MUNIX did not finish ($D/miniroot/console.out)" >&2; exit 1; }
  # The console has 7-bit characters with a parity bit (stty evenp).
  tr '\200-\377' '\000-\177' < "$D/miniroot/console.out" | grep -q 'Mini-root installation complete' \
    || { echo "sunos.sh: MUNIX did not install the miniroot ($D/miniroot/console.out)" >&2; exit 1; }
  mv "$D/work.hd" "$D/miniroot.hd"
  ;;
install)
  D=$2
  cp "$D/miniroot.hd" "$D/work.hd"
  CMDS=$HERE/sunos-install.cmds \
  MAMEARGS="-scsibus:0 harddisk -hard1 $D/work.hd -tap $D/tape1.tap" \
    bash "$HERE/run.sh" sun3_80ref "$D/install" 4462 3600 \
    || { echo "sunos.sh: the install did not finish ($D/install/console.out)" >&2; exit 1; }
  for w in NEWFS-A NEWFS-G MOUNT ROOT USR KVM INSTALL NETWORKING MAKEDEV FSTAB HOST SBIN BOOT ALL; do
    tr '\200-\377' '\000-\177' < "$D/install/console.out" | grep -q "^$w-DONE" \
      || { echo "sunos.sh: the install did not reach $w-DONE ($D/install/console.out)" >&2; exit 1; }
  done
  mv "$D/work.hd" "$D/sunos.hd"
  ;;
boot)
  M=$2; D=$3; OUT=$4; PORT=$5; TMO=$6
  mkdir -p "$OUT"
  cp "$D/sunos.hd" "$OUT.hd"
  CMDS=$HERE/sunos-boot.cmds MAMEARGS="-scsibus:0 harddisk -hard1 $OUT.hd" \
    bash "$HERE/run.sh" "$M" "$OUT" "$PORT" "$TMO"
  ;;
*)
  echo "usage: $0 fetch|media|miniroot|install DIR | boot MACHINE DIR OUT PORT TIMEOUT" >&2; exit 2
  ;;
esac
