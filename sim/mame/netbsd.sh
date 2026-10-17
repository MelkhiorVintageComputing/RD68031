#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# NetBSD/sun3x 10.2 on MAME's Sun-3/80 (M14 phase B; doc/oracles.md, "MAME").
#
#   sim/mame/netbsd.sh fetch  DIR      the media of Inputs/sw/MANIFEST-netbsd
#                                      into DIR/dl, each checked
#   sim/mame/netbsd.sh disk   DIR      DIR/disk0.hd (a Sun label; the miniroot
#                                      in b) and DIR/sets.hd (the sets as one
#                                      uncompressed tar)
#   sim/mame/netbsd.sh install DIR     the install, by hand from the miniroot's
#                                      shell (sim/mame/netbsd-install.cmds), on
#                                      MAME's m68030: DIR/netbsd.hd
#   sim/mame/netbsd.sh boot MACHINE DIR OUT PORT TIMEOUT
#                                      a copy of DIR/netbsd.hd booted on MACHINE
#                                      (sun3_80ref or sun3_80rd) to multi-user,
#                                      logged in, sim/mame/netbsd-boot.cmds
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

case $WHAT in
fetch)
  D=$2; mkdir -p "$D/dl"
  grep -v '^#' "$R/Inputs/sw/MANIFEST-netbsd" | while read -r sum name url; do
    [ -n "$sum" ] || continue
    f=$D/dl/$name
    if ! echo "$sum  $f" | sha256sum -c --quiet - 2>/dev/null; then
      curl -sSL -m 900 -o "$f" "$url" || { echo "netbsd.sh: cannot fetch $url" >&2; exit 1; }
      echo "$sum  $f" | sha256sum -c --quiet - || { echo "netbsd.sh: $name: wrong hash" >&2; exit 1; }
    fi
  done
  ;;
disk)
  D=$2
  gzip -dc "$D/dl/netbsd-10.2-sun3-miniroot.fs.gz" > "$D/miniroot.fs"
  python3 -I "$HERE/mkdisk.py" "$D/disk0.hd" --mb 600 --part a:440 --part b:120 \
    --fill "b:$D/miniroot.fs" > /dev/null
  # The sets, one uncompressed tar the miniroot's tar reads from /dev/rsd1c.
  python3 -I - "$D" <<'EOF'
import sys, tarfile
d = sys.argv[1]
out = tarfile.open(d + '/sets.hd', 'w', format=tarfile.GNU_FORMAT)
for s in ['base', 'etc', 'kern-GENERIC3X']:
    with tarfile.open('%s/dl/netbsd-10.2-sun3-%s.tgz' % (d, s), 'r:gz') as t:
        for m in t:
            out.addfile(m, t.extractfile(m) if m.isreg() else None)
out.close()
EOF
  ;;
install)
  D=$2
  cp "$D/disk0.hd" "$D/work.hd"
  CMDS=$HERE/netbsd-install.cmds \
  MAMEARGS="-scsibus:0 harddisk -scsibus:3 harddisk -hard1 $D/work.hd -hard3 $D/sets.hd" \
    bash "$HERE/run.sh" sun3_80ref "$D/install" 4452 3600
  for w in SETS-DONE MAKEDEV-DONE BOOT-DONE ALL-DONE; do
    grep -q "^$w" "$D/install/console.out" \
      || { echo "netbsd.sh: the install did not reach $w ($D/install/console.out)" >&2; exit 1; }
  done
  mv "$D/work.hd" "$D/netbsd.hd"
  ;;
boot)
  M=$2; D=$3; OUT=$4; PORT=$5; TMO=$6
  mkdir -p "$OUT"
  cp "$D/netbsd.hd" "$OUT.hd"
  CMDS=$HERE/netbsd-boot.cmds MAMEARGS="-scsibus:0 harddisk -hard1 $OUT.hd" \
    bash "$HERE/run.sh" "$M" "$OUT" "$PORT" "$TMO"
  ;;
*)
  echo "usage: $0 fetch|disk|install DIR | boot MACHINE DIR OUT PORT TIMEOUT" >&2; exit 2
  ;;
esac
