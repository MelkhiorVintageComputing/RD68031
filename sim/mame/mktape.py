#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
"""A SIMH tape image for MAME's SCSI tape (M14 phase B, SunOS 4.1.1).

    mktape.py OUT.tap FILE ...

Each FILE becomes one tape file of 512-byte records, the last one padded with
zeros: a quarter-inch cartridge (QIC-24, the 3/80's tape) has fixed 512-byte
blocks, so what sun3arc's maketape1 wrote with `dd bs=32k` is read back in
512-byte blocks, and the PROM's tape boot asks for exactly that. A tape mark
follows each file, and a second one ends the tape.

SIMH's format, which MAME's simh_tape_image reads: a record is its length
(32-bit little-endian), the data padded to an even length, the length again;
a tape mark is a zero length.
"""
import struct
import sys


def main():
    out = open(sys.argv[1], 'wb')
    for arg in sys.argv[2:]:
        rec = 512
        data = open(arg, 'rb').read()
        data += bytes(-len(data) % 512)
        for i in range(0, len(data), rec):
            r = data[i:i + rec]
            n = struct.pack('<I', len(r))
            out.write(n + r + bytes(len(r) & 1) + n)
        out.write(struct.pack('<I', 0))
    out.write(struct.pack('<I', 0))
    out.close()


if __name__ == '__main__':
    main()
