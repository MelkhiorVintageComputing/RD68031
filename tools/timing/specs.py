#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

"""The MC68030's AC electrical specifications, as data.

    python3 tools/timing/specs.py --dump           # every row, every grade
    python3 tools/timing/specs.py --dump --freq 50

The source is `Inputs/doc/.../MC68030EC_split/ac-electrical-specifications.csv`,
the AC tables of the MC68030EC/D data sheet (Rev. 1), read off the page images
rather than the text layer (that directory's README says how). This module adds
the judgements the CSV cannot carry: which rows are one specification and which
are two, what an empty cell means, and which unit a row is in.

The limits live here and not in SystemVerilog. The testbenches emit times and
nothing else -- no testbench knows what a specification is. That is what lets a
wrong anchor be fixed with a one-line edit and a re-analysis in milliseconds
instead of a re-simulation, and it is what would let a second core, in another
language, be judged by exactly the same code.
"""

import argparse
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CSV = os.path.join(ROOT, 'Inputs', 'doc', 'MC68030_Doc_More_Readable',
                   'MC68030EC_split', 'ac-electrical-specifications.csv')

# The data sheet prints five speed grades, and these are its column names. There
# is no 16.67 MHz part: doc/plan.md named one, from the MC68020's table, and the
# MC68030EC clock table begins at 20 MHz. A design is conformant only if it is
# conformant at the grade it is built for; `make timing` reports all five.
FREQS = ['20', '25', '33', '40', '50']
FREQ_MHZ = {'20': 20.0, '25': 25.0, '33': 33.33, '40': 40.0, '50': 50.0}

# The clock period each grade's minimum cycle time gives -- specification 1, and
# checked against the CSV on load so that the two cannot drift apart.
FREQ_PERIOD_NS = {'20': 50.0, '25': 40.0, '33': 30.0, '40': 25.0, '50': 20.0}


def _num(text):
    """One printed cell. Returns a float, or None where the source prints an em
    dash -- which the CSV carries as an empty cell (its README)."""
    t = (text or '').strip()
    if not t or t in ('—', '-', '--'):
        return None
    return float(t.replace('–', '-'))


class Spec(object):
    """One row of the AC tables, at all five grades."""

    def __init__(self, row):
        self.num = row['num'].strip()
        self.condition = row['condition'].strip()
        self.characteristic = row['characteristic'].strip()
        self.unit = row['unit'].strip()
        self.footnotes = [f.strip() for f in row['footnotes'].split(',')
                          if f.strip()]
        self.table = row['table'].strip()
        self.limits = {}
        for f in FREQS:
            self.limits[f] = (_num(row['f%s_min' % f]), _num(row['f%s_max' % f]))

    @property
    def key(self):
        """Specifications 45 and 45A each carry two value rows under one
        heading, asynchronous or synchronous read and write; the CSV tells them
        apart by `condition`. Nothing else repeats, so the key is the number
        plus the condition."""
        return (self.num, self.condition)

    @property
    def name(self):
        if self.condition:
            return '%s (%s)' % (self.num, self.condition)
        return self.num

    def ns(self, freq):
        """The limits in nanoseconds at one grade.

        Seven rows are printed in clock periods rather than nanoseconds -- the
        arbitration handshakes, the RESET instruction's pulse and the reset input
        transition time. They are converted here using that grade's minimum cycle
        time, which is specification 1, so that everything downstream works in one
        unit. A limit in clocks is exact at every frequency; a limit in
        nanoseconds is not, which is the whole reason the data sheet mixes them.
        """
        lo, hi = self.limits[freq]
        if self.unit == 'Clks':
            p = FREQ_PERIOD_NS[freq]
            lo = None if lo is None else lo * p
            hi = None if hi is None else hi * p
        elif self.unit != 'ns':
            return (None, None)       # MHz: the frequency row itself
        return (lo, hi)

    def lo(self, freq):
        return self.ns(freq)[0]

    def hi(self, freq):
        return self.ns(freq)[1]


def load(path=CSV):
    """Every specification, keyed by (number, condition)."""
    out = {}
    with open(path) as fh:
        for row in csv.DictReader(fh):
            s = Spec(row)
            if not s.num:
                continue              # the unnumbered "Frequency of Operation" row
            if s.key in out:
                raise SystemExit('specs: duplicate key %r -- the CSV has changed '
                                 'and this module has not' % (s.key,))
            out[s.key] = s
    one = out.get(('1', ''))
    if one is None:
        raise SystemExit('specs: no specification 1 in the CSV')
    for f in FREQS:
        if one.limits[f][0] != FREQ_PERIOD_NS[f]:
            raise SystemExit('specs: specification 1 at %s MHz is %s ns, but '
                             'FREQ_PERIOD_NS says %s' % (f, one.limits[f][0],
                                                         FREQ_PERIOD_NS[f]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--freq', default=None, choices=FREQS)
    args = ap.parse_args()

    specs = load()
    if not args.dump:
        print('%d specifications, %d limits'
              % (len(specs), sum(1 for s in specs.values() for f in FREQS
                                 for v in s.limits[f] if v is not None)))
        return 0

    freqs = [args.freq] if args.freq else FREQS
    def order(k):
        n = k[0].split(',')[0]
        digits = ''.join(c for c in n if c.isdigit())
        return (int(digits) if digits else 0, n, k[1])
    for key in sorted(specs, key=order):
        s = specs[key]
        cells = []
        for f in freqs:
            lo, hi = s.ns(f)
            cells.append('%7s %7s' % ('-' if lo is None else '%.1f' % lo,
                                      '-' if hi is None else '%.1f' % hi))
        print('%-24s %-52s %s  %s' % (s.name, s.characteristic[:52],
                                      ' '.join(cells), ','.join(s.footnotes)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
