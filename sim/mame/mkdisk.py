#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Make a raw SCSI disk image for MAME's Sun-3/80 (M14 phase B): a Sun disk
# label in block 0 and, optionally, a file system image written into one of its
# partitions -- NetBSD's miniroot into the swap partition, as its INSTALL
# describes ("copy a miniroot image into the swap partition, then b sd(,,1)").
#
#   mkdisk.py OUT --mb 600 --part a:400 --part b:100 [--fill b:miniroot.fs]
#
# Partition sizes are in MB, laid out in the order given, each on a cylinder
# boundary; c is always the whole disk. The geometry is 16 heads of 32 sectors
# (256 KB a cylinder). MAME takes any file that is not a CHD as a raw image.
import argparse
import struct
import sys

SECT = 512
NHEAD, NSECT = 16, 32
CYL = NHEAD * NSECT  # blocks per cylinder


def label(ncyl, parts):
    """The 512-byte Sun disk label (NetBSD's struct sun_disklabel)."""
    b = bytearray(SECT)
    text = b"RD68031 MAME disk cyl %d alt 2 hd %d sec %d" % (ncyl, NHEAD, NSECT)
    b[0:len(text)] = text
    struct.pack_into(">HHH", b, 420, 3600, ncyl + 2, 0)      # rpm, pcyl, spares
    struct.pack_into(">H", b, 430, 1)                         # interleave
    struct.pack_into(">HHHH", b, 432, ncyl, 2, NHEAD, NSECT)  # ncyl, acyl, heads, sectors
    for i, (cyl0, nblk) in enumerate(parts):
        struct.pack_into(">II", b, 444 + 8 * i, cyl0, nblk)
    struct.pack_into(">H", b, 508, 0xDABE)
    ck = 0
    for i in range(0, 510, 2):
        ck ^= struct.unpack_from(">H", b, i)[0]
    struct.pack_into(">H", b, 510, ck)
    return bytes(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--mb", type=int, required=True)
    ap.add_argument("--part", action="append", default=[], help="letter:MB")
    ap.add_argument("--fill", action="append", default=[], help="letter:file")
    a = ap.parse_args()

    ncyl = a.mb * 1024 * 1024 // (CYL * SECT)
    parts = [(0, 0)] * 8
    parts[2] = (0, ncyl * CYL)
    cyl = 0
    for p in a.part:
        letter, mb = p.split(":")
        n = int(mb) * 1024 * 1024 // (CYL * SECT)
        if cyl + n > ncyl:
            sys.exit("mkdisk: partitions larger than the disk")
        parts["abcdefgh".index(letter)] = (cyl, n * CYL)
        cyl += n

    with open(a.out, "wb") as f:
        f.truncate(ncyl * CYL * SECT)
        f.write(label(ncyl, parts))
        for p in a.fill:
            letter, path = p.split(":", 1)
            cyl0, nblk = parts["abcdefgh".index(letter)]
            data = open(path, "rb").read()
            if len(data) > nblk * SECT:
                sys.exit("mkdisk: %s does not fit in partition %s" % (path, letter))
            f.seek(cyl0 * CYL * SECT)
            f.write(data)
    print("%s: %d MB, %d cylinders; %s" % (a.out, a.mb, ncyl, " ".join(
        "%s=%d+%d" % ("abcdefgh"[i], c * CYL, n) for i, (c, n) in enumerate(parts) if n)))


if __name__ == "__main__":
    main()
