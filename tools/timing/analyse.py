#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

"""Is there any pad-delay assignment that meets the MC68030EC data sheet?

    python3 tools/timing/analyse.py --freq 50 build/timing-50.log
    python3 tools/timing/analyse.py --freq 50 --verbose build/timing-50.log
    python3 tools/timing/analyse.py --freq 50 --pad-skew 5 build/timing-50.log

Builds the difference-constraint system that anchors.py describes out of the
times that the testbench recorded at one grade, and solves it against that
grade's column. The answer is exact: either an assignment exists, in which case
one can be printed, or a set of limits contradict each other, in which case
those limits are printed.

Then the checks that are not about pad delays: that every input is sampled
inside its setup and hold window, on the edge the data sheet names; that DSACK
skew is tolerated; the counts; the stimulus; the clock. Any of them failing
fails the grade, as does a specification the log gave nothing to measure, and a
pin that moved on the other edge from the one its specification is measured
from.

INFEASIBLE is a proof. FEASIBLE is conditional on the pad model: --pad-skew is
how far apart the delays of one pin's transitions may be, and it defaults to 0,
which is one delay per pin.
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import anchors                                                  # noqa: E402
import events as events_mod                                     # noqa: E402
import feasible                                                 # noqa: E402
import specs as specs_mod                                       # noqa: E402

INTERNAL = ('smp.', 'in.', 'clk.')


def var_of(event):
    """The delay variable an event carries: its own for a pin of the core, none
    -- the fixed node -- for an input as the device drives it or an edge inside
    the core."""
    return '#0' if event.startswith(INTERNAL) else event


def pin_of(event):
    return event.split('.')[0]


class Result(object):
    def __init__(self):
        self.measured = set()
        self.fails = []          # (spec name, why)
        self.notes = []          # (spec name, what), for --verbose
        self.inputs = []         # (room, spec name, probe, side)


def build(log, S, freq, pad_skew):
    """The whole system, plus everything that is checked outside it."""
    sys_ = feasible.System()
    res = Result()

    # Pad-delay budgets.
    for key, evs, edge, tag in anchors.PAD:
        spec = S[key]
        lo, hi = spec.ns(freq)
        for ev in evs:
            seen = 0
            wrong = None
            for scen in anchors.scenarios_for(tag):
                for occ in events_mod.occurrences(log.get(scen), ev):
                    seen += 1
                    if occ.edge != edge and wrong is None:
                        wrong = occ
            if seen == 0:
                res.fails.append((spec.name, 'no %s in the %s log'
                                  % (ev, '/'.join(anchors.scenarios_for(tag)))))
                continue
            if wrong is not None:
                res.fails.append((spec.name,
                                  'measured from CLK %s, but %s moved on a %s edge '
                                  'at %.1f ns' % ('high' if edge == 'R' else 'low',
                                                  ev, 'rising' if wrong.edge == 'R'
                                                  else 'falling', wrong.t)))
                continue
            sys_.bound(ev, lo, hi, '%s %s' % (spec.name, ev))
            res.measured.add(key)

    # Separations.
    for key, a, b, tag, bound in anchors.SEP:
        spec = S[key]
        lo, hi = bound(S, freq) if bound else spec.ns(freq)
        n = 0
        for scen in anchors.scenarios_for(tag):
            for ea, eb in events_mod.pairs(log.get(scen), a, b):
                sys_.sep(var_of(ea.name), ea.t, var_of(eb.name), eb.t, lo, hi,
                         '%s %s->%s (%s, %.1f ns apart)'
                         % (spec.name, a, b, scen, eb.t - ea.t))
                n += 1
        if n == 0:
            res.fails.append((spec.name, 'no %s followed by %s in the %s log'
                              % (a, b, '/'.join(anchors.scenarios_for(tag)))))
        else:
            res.measured.add(key)

    # Pad delays are not negative, and one pin has one delay -- or several,
    # within pad_skew of each other.
    by_pin = {}
    for v in sorted(sys_.vars):
        if v.startswith('#'):
            continue
        sys_.floor(v)
        by_pin.setdefault(pin_of(v), []).append(v)
    for pin, vs in sorted(by_pin.items()):
        for i in range(len(vs) - 1):
            sys_.le(vs[i], vs[i + 1], pad_skew, None)
            sys_.le(vs[i + 1], vs[i], pad_skew, None)

    # Where the inputs are sampled.
    for key, probes, edge, side in anchors.INPUT:
        spec = S[key]
        v = spec.ns(freq)[0]
        ok = True
        for name in probes:
            p = log.probes.get(name)
            if p is None:
                res.fails.append((spec.name, 'no probe of %s in the log' % name))
                ok = False
                continue
            if not p.split:
                res.fails.append((spec.name,
                                  '%s: the same outcome %+.1f and %+.1f ns from the '
                                  'CLK %s edge, so it is not sampled there'
                                  % (name, p.off_b, p.off_a,
                                     'low' if edge == 'F' else 'high')))
                ok = False
                continue
            if p.edge != edge:
                res.fails.append((spec.name,
                                  '%s is sampled on a %s edge; the data sheet '
                                  'measures it from CLK %s'
                                  % (name, {'R': 'rising', 'F': 'falling'}.get(
                                      p.edge, 'unknown'),
                                     'low' if edge == 'F' else 'high')))
                ok = False
                continue
            # The instant lies in (off_b, off_a]; the window is [-v, +v'].
            if side == 'setup':
                room = v + p.off_b
            else:
                room = v - p.off_a
            if room < -1e-9:
                res.fails.append((spec.name,
                                  '%s is sampled up to %.1f ns %s the edge, outside '
                                  'the %.1f ns window' % (name, abs(
                                      p.off_b if side == 'setup' else p.off_a),
                                      'before' if side == 'setup' else 'after', v)))
                ok = False
                continue
            res.inputs.append((room, spec.name, name, side))
        if ok:
            res.measured.add(key)

    # DSACK skew.
    for key, names in anchors.SKEW:
        spec = S[key]
        need = spec.ns(freq)[1]
        ok = True
        for name in names:
            got = log.skews.get(name)
            if not got:
                res.fails.append((spec.name, 'no %s in the log' % name))
                ok = False
                continue
            for val, good in got:
                if not good:
                    res.fails.append((spec.name, '%s: a skew of %.1f ns gave the '
                                      'wrong port size or data' % (name, val)))
                    ok = False
                elif val < need - 1e-9:
                    res.fails.append((spec.name, '%s: only %.1f ns of skew tried, '
                                      'and the limit is %.1f' % (name, val, need)))
                    ok = False
                else:
                    res.notes.append((spec.name, '%s: %.1f ns tolerated, %.1f '
                                      'allowed' % (name, val, need)))
        if ok:
            res.measured.add(key)

    # Counts.
    for key, scen, ev, exp in anchors.COUNT:
        spec = S[key]
        evs = log.get(scen)
        got = len(events_mod.occurrences(evs, ev))
        want = exp if isinstance(exp, int) else len(events_mod.occurrences(evs, exp))
        what = 'count(%s) in %s is %d, %s %d' % (
            ev, scen, got, 'and must be' if isinstance(exp, int)
            else 'and count(%s) is' % exp, want)
        if not evs:
            res.fails.append((spec.name, 'no %s log' % scen))
        elif got != want:
            res.fails.append((spec.name, what))
        else:
            res.notes.append((spec.name, what))
            res.measured.add(key)

    # The stimulus used the device's whole allowance.
    for key, a, b, scen in anchors.STIM:
        spec = S[key]
        need = spec.ns(freq)[1]
        prs = events_mod.pairs(log.get(scen), a, b)
        if not prs:
            res.fails.append((spec.name, 'no %s followed by %s in %s' % (a, b, scen)))
            continue
        short = [eb.t - ea.t for ea, eb in prs if eb.t - ea.t < need - 1e-9]
        if short:
            res.fails.append((spec.name, 'the test\'s %s->%s was %.1f ns, short of '
                              'the %.1f ns a device may take' % (a, b, short[0], need)))
        else:
            res.notes.append((spec.name, 'the test used %.1f ns of %s->%s, all a '
                              'device may take' % (min(eb.t - ea.t for ea, eb in prs),
                                                   a, b)))
            res.measured.add(key)

    # The clock.
    for key, what in sorted(anchors.DIRECT.items()):
        spec = S[key]
        lo, hi = spec.ns(freq)
        if log.period is None:
            res.fails.append((spec.name, 'the log does not say its clock period'))
            continue
        val = log.period if what == 'period' else log.period / 2.0
        if (lo is not None and val < lo - 1e-9) or (hi is not None and val > hi + 1e-9):
            res.fails.append((spec.name, 'the clock\'s %s is %.2f ns, outside '
                              '%s..%s' % (what, val, lo, hi)))
        else:
            res.notes.append((spec.name, 'the clock\'s %s is %.2f ns, inside '
                              '%s..%s' % (what, val, lo, hi)))
            res.measured.add(key)

    return sys_, res


def run(path, freq, pad_skew, verbose):
    log = events_mod.read(path)
    S = specs_mod.load()

    missing, stale = anchors.check_complete(S)
    if missing or stale:
        print('FAIL: the anchor table does not cover the data sheet: '
              'missing %s, stale %s' % (missing, stale))
        return 1

    sys_, res = build(log, S, freq, pad_skew)
    ok, dist, cycle = sys_.solve()
    mhz = specs_mod.FREQ_MHZ[freq]
    n_all = len(S)
    n_meas = len(res.measured)
    n_expl = len(anchors.UNANCHORED)
    bad = 0

    if not ok:
        bad = 1
        print('%6.2f MHz  INFEASIBLE -- these limits contradict each other:' % mhz)
        total = 0.0
        for y, x, c, why in cycle:
            total += c
            print('           d[%s] - d[%s] <= %7.1f   %s'
                  % (x, y, c, why if why else '(one pin, one delay)'))
        print('           round trip: %.1f ns, which cannot be met' % total)
    else:
        margins = sys_.margins()
        # A limit printed in clocks -- the arbitration handshakes, the RESET
        # instruction's 512 -- is a count the design meets by construction or
        # not at all, and one met exactly has no room by definition: the
        # RESET instruction drives RESET for exactly the 512 clocks the data
        # sheet asks. Those are reported on their own line, so that the binding
        # constraint is the tightest limit printed in nanoseconds, which is the
        # one a faster clock or slower pads would break first.
        clks = set(s.num for s in S.values() if s.unit == 'Clks')
        def in_clks(why):
            return why.split()[0] in clks
        seps = [(m, why) for m, why, kind in margins
                if kind == 'sep' and not in_clks(why)]
        cseps = [(m, why) for m, why, kind in margins
                 if kind == 'sep' and in_clks(why)]
        bnds = [(m, why) for m, why, kind in margins if kind == 'bound']
        # The binding constraint is the tightest SEPARATION. A bound's margin
        # is the width the data sheet printed for that pad delay and says
        # nothing about this design.
        tight = seps[0] if seps else (float('inf'), 'nothing')
        print('%6.2f MHz  feasible, %d of %d specifications measured, '
              '%.1f ns of room on the binding constraint'
              % (mhz, n_meas, n_all, tight[0]))
        print('           %s' % tight[1])
        if cseps:
            print('           tightest limit in clocks: %.1f ns, %s'
                  % (cseps[0][0], cseps[0][1]))
        if bnds:
            print('           tightest pad-delay budget: %.1f ns, %s'
                  % (bnds[0][0], bnds[0][1]))
    if res.inputs:
        res.inputs.sort()
        r = res.inputs[0]
        print('           inputs: %d windows checked, each sampled on its own edge; '
              'tightest %.1f ns, %s %s (%s)'
              % (len(res.inputs), r[0], r[1], r[2], r[3]))
    for name, why in res.fails:
        bad = 1
        print('           FAIL %-22s %s' % (name, why))
    if n_meas + n_expl != n_all and not res.fails:
        bad = 1
        print('           FAIL %d specifications neither measured nor explained'
              % (n_all - n_meas - n_expl))

    if verbose:
        print('           -- %.2f MHz in detail --' % mhz)
        print('           the clock: %.3f ns; %s' % (
            log.period or 0.0, ', '.join('%s = %s' % kv
                                         for kv in sorted(log.facts.items()))))
        if ok:
            print('           tightest separations, one per specification:')
            seen = set()
            n = 0
            for m, why in seps:
                k = why.rsplit(' (', 1)[0]
                if k in seen:
                    continue
                seen.add(k)
                print('             %6.1f ns  %s' % (m, why))
                n += 1
                if n == 10:
                    break
            print('           limits in clocks:')
            seen = set()
            for m, why in cseps:
                k = why.split()[0]
                if k in seen:
                    continue
                seen.add(k)
                print('             %6.1f ns  %s' % (m, why))
            print('           a pad assignment that meets every limit:')
            for v in sorted(dist):
                if not v.startswith('#'):
                    print('             %-16s %6.1f ns' % (v, dist[v] - dist['#0']))
        print('           input windows, tightest first:')
        for room, name, probe, side in res.inputs[:12]:
            print('             %6.1f ns  %-6s %-18s %s' % (room, name, probe, side))
        for name, what in res.notes:
            print('           %-24s %s' % (name, what))
        for key, why in sorted(anchors.UNANCHORED.items()):
            print('           not measured %-10s %s' % (key[0], why))
        for key, why in sorted(anchors.PARTIAL.items()):
            print('           partly       %-10s %s' % (key[0], why))

    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--freq', required=True, choices=specs_mod.FREQS)
    ap.add_argument('--pad-skew', type=float, default=0.0,
                    help='how far apart one pin\'s transition delays may be '
                         '(default 0: one delay per pin)')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()
    return run(args.log, args.freq, args.pad_skew, args.verbose)


if __name__ == '__main__':
    sys.exit(main())
