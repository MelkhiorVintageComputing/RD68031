#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
"""The answers to typed shell commands in two consoles, compared (M14 phase B).

    answers.py PROMPT CONSOLE_A CONSOLE_B

An OS console differs from one CPU to the other wherever timing shows (when
the clock ticks, when a daemon logs), so `make netbsd-sun3x` compares only
what each command typed at PROMPT answered: the lines between its echo and the
next prompt. Lines a daemon slips in (syslog's `Mon dd hh:mm:ss host ...`) are
left out. Exit status 0 when both consoles answered the same commands with the
same lines; the differences are printed otherwise.
"""
import re
import sys

SYSLOG = re.compile(r'^[A-Z][a-z]{2} [ 0-9]\d \d\d:\d\d:\d\d \S+ ')


def answers(path, prompt):
    # Bit 7 is dropped: SunOS's console can carry a parity bit (stty evenp).
    raw = bytes(c & 0x7f for c in open(path, 'rb').read())
    text = raw.replace(b'\0', b'').replace(b'\r', b'').decode('latin-1')
    out, cmd = [], None
    for line in text.split('\n'):
        if line.startswith(prompt):
            if cmd is not None:
                out.append((cmd, body))
            cmd, body = line[len(prompt):], []
        elif cmd is not None and not SYSLOG.match(line):
            body.append(line)
    return out


def main():
    prompt, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
    ra, rb = answers(a, prompt), answers(b, prompt)
    bad = 0
    for i in range(max(len(ra), len(rb))):
        ca = ra[i] if i < len(ra) else ('(none)', [])
        cb = rb[i] if i < len(rb) else ('(none)', [])
        if ca != cb:
            bad += 1
            print('  differs: %r' % ca[0])
            for l in ca[1]:
                print('    a| ' + l)
            for l in cb[1]:
                print('    b| ' + l)
    print('%d commands, %d answered differently' % (len(ra), bad))
    sys.exit(1 if bad or len(ra) != len(rb) or not ra else 0)


if __name__ == '__main__':
    main()
