#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
"""Make the Sun-3/80's M48T02 NVRAM image for MAME's sun3x driver.

    mk_timekpr.py eeprom.bin timekpr_380.bin

eeprom.bin is a 2 KB Sun EEPROM image made by tme-sun-eeprom from
sim/mame/eeprom.txt (console on ttya, so the run can be compared on a serial
line). Its first $7D8 bytes are kept; the IDPROM goes at $7D8: format 1,
machine type $47 (Sun-3/80), Ethernet 08:00:20:12:34:56, a date, serial
$001234, and the checksum, the XOR of the fifteen bytes before it. MAME warns
that the image is not its own ("WRONG CHECKSUMS") and runs it.
"""
import sys

IDPROM_AT = 0x7D8
idprom = bytes([0x01, 0x47, 0x08, 0x00, 0x20, 0x12, 0x34, 0x56,
                0x26, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34])
cksum = 0
for b in idprom:
    cksum ^= b

src, dst = sys.argv[1], sys.argv[2]
img = bytearray(open(src, 'rb').read())
if len(img) != 2048:
    sys.exit(f"{src}: {len(img)} bytes, expected 2048")
img[IDPROM_AT:IDPROM_AT + 32] = idprom + bytes([cksum]) + bytes(16)
open(dst, 'wb').write(img)
