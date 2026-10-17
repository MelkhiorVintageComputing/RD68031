#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
"""Make the Sun-3/80's M48T02 NVRAM image for MAME's sun3x driver.

    mk_nvram.py eeprom.txt timekpr_380.bin

The first $7D8 bytes are the Sun EEPROM, made from eeprom.txt: one `name value`
a line, the names and the layout of the Sun-3 monitor's EEPROM (the same text
format as TME's tme-sun-eeprom, which made this image until M14 phase B; for
the file in this directory the two give the same bytes). Fields not named are
zero, but the test pattern, $55AA at $B8. Then the IDPROM at $7D8: format 1, machine type $42 (architecture $40,
Sun-3x; model 2, the 3/80 -- NetBSD's ID_SUN3X_80), Ethernet 08:00:20:12:34:56,
a date, serial $001234, and the checksum, the XOR of the fifteen bytes before
it. The last eight bytes, the clock, are set by MAME. MAME warns that the image
is not its own ("WRONG CHECKSUMS") and runs it.
"""
import struct
import sys

# offset, name, type, (value names): the Sun-3 monitor's EEPROM.
FIELDS = [
    (0x014, 'installed-#megs', 'dec', None),
    (0x015, 'selftest-#megs', 'dec', None),
    (0x016, 'screen-resolution', 'hex', {'1152x900': 0x00, '1024x1024': 0x12, '1600x1280': 0x13,
                                         '1440x1440': 0x14, '640x480': 0x15, '1280x1024': 0x16}),
    (0x050, 'screen-#columns', 'dec', None),
    (0x051, 'screen-#rows', 'dec', None),
    (0x01f, 'console-device', 'hex', {'onboard-bwtwo': 0x00, 'ttya': 0x10, 'ttyb': 0x11,
                                      'color-fb': 0x12, 'p4-option': 0x20}),
    (0x017, 'watchdog-reboot?', 'bool', None),
    (0x018, 'boot-device?', 'bool', None),
    (0x019, 'boot-device', 'bootdev', None),
    (0x020, 'oem-banner?', 'bool', None),
    (0x068, 'oem-banner', ('str', 80), None),
    (0x18f, 'oem-logo?', 'bool', None),
    (0x290, 'oem-logo', ('str', 512), None),
    (0x01e, 'keyboard-type', 'hex', {'sun': 0x00}),
    (0x18d, 'keyboard-locale', 'hex', None),
    (0x18e, 'keyboard-id', 'hex', None),
    (0x021, 'keyboard-click?', 'bool', None),
    (0x022, 'diag-device', 'bootdev', None),
    (0x028, 'diag-file', ('str', 40), None),
    (0x027, 'inverse-video?', 'bool', None),
    (0x058, 'ttya-mode', 'tty', None),
    (0x060, 'ttyb-mode', 'tty', None),
    (0x492, 'security-mode', 'hex', {'none': 0x00, 'command': 0x01, 'full': 0x5e}),
    (0x493, 'security-password', ('str', 8), None),
    (0x70b, 'diag-switch?', 'hex', {'false': 0x06, 'true': 0x12}),
    (0x010, 'last-hardware-update', 'long', None),
]
EEPROM_SIZE = 0x7D8
IDPROM = bytes([0x01, 0x42, 0x08, 0x00, 0x20, 0x12, 0x34, 0x56,
                0x26, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34])


def pack(kind, names, v):
    if v == '':
        return None                       # empty: left zero
    if kind == 'dec':
        return bytes([int(v)])
    if kind == 'hex':
        return bytes([names[v] if names and v in names else int(v, 16)])
    if kind == 'bool':
        return bytes([{'true': 0x12, 'false': 0x00}[v]])
    if kind == 'bootdev':                 # dv(ctlr,unit,part)
        dev, rest = v[:2], v[3:-1].split(',')
        return dev.encode() + bytes(int(x) for x in rest)
    if kind == 'tty':                     # baud,8,n,1,flow: 'h' is hardware flow control
        baud, _, _, _, flow = v.split(',')
        return struct.pack('>BHBI', 0x00 if int(baud) == 9600 else 0x12, int(baud),
                           0x00 if flow == 'h' else 0x12, 0)
    if kind == 'long':
        return struct.pack('>I', int(v, 16))
    if isinstance(kind, tuple) and kind[0] == 'str':
        return v.encode()[:kind[1]]
    raise ValueError(kind)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    img = bytearray(2048)
    img[0x0b8:0x0ba] = b'\x55\xaa'      # the test pattern the monitor checks
    byname = {f[1]: f for f in FIELDS}
    for line in open(src):
        line = line.rstrip('\n')
        if not line.strip() or line.startswith('#'):
            continue
        name, _, value = line.partition(' ')
        if name not in byname:
            sys.exit(f"{src}: unknown field {name}")
        off, _, kind, names = byname[name]
        b = pack(kind, names, value.strip())
        if b is not None:
            img[off:off + len(b)] = b
    cksum = 0
    for b in IDPROM:
        cksum ^= b
    img[EEPROM_SIZE:EEPROM_SIZE + 16] = IDPROM + bytes([cksum])
    open(dst, 'wb').write(img)


if __name__ == '__main__':
    main()
