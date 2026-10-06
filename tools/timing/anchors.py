#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

"""What each MC68030EC specification measures, and between which events.

    python3 tools/timing/anchors.py            # the table
    python3 tools/timing/anchors.py --unanchored

The data sheet's figures 3 to 8 draw each limit as an arrow between two things
happening on two pins, or between a clock edge and a pin. This module is that
reading, written down. Every specification is one of these:

PAD     a budget on one pad delay: "Clock High to Address Valid", 0..14 ns.
SEP     a required separation between two events, each a pin of the core (with
        its pad delay), an input as a device moves it, or an edge inside the
        core (neither of which has one).
INPUT   an input's setup or hold window, which the edge the core samples that
        input on must lie inside -- found by the probes of rd68031_timing_tb.
SKEW    the most the core tolerates between two inputs that should move together.
COUNT   an event that must happen a given number of times: that a two-clock
        synchronous write asserts no DS, that a re-grant does not happen.
STIM    the test itself used the whole of what a device is allowed -- so that a
        separation measured from it is the worst case and not a lucky one.
DIRECT  the clock, checked against the run's own period.

and the few that are none of those are listed with the reason. `check_complete`
fails if a specification is in no table.

An RTL model has no pad delays, so a limit measured from a clock edge to a pin
cannot be *measured* from it. It can still be answered. Every PAD and SEP limit
splits into

    a budget on one pad delay           0 <= d[as.assert] <= 30
    a required separation               (t_b + d_b) - (t_a + d_a) >= 15

and both are difference constraints on the unknown delays, whose times come from
the simulation. "Is there any assignment of pad delays inside the budget meeting
every separation" then has an exact answer -- see feasible.py.

REQUIREMENTS ON A DEVICE. About a third of the data sheet is what a device must
do: hold DSACK at most so long after AS, present data at most so long after
DSACK, release the data bus within so long of the clock. Each has a processor
side, and that is what is measured here: a device that uses ALL of its
allowance must still be read correctly. "AS negated to DSACK negated, at most
15 ns" becomes "the core's next sample of DSACK comes at least 15 ns, plus that
sample's own setup time, after AS negates at the pin". The bound is the device's
maximum used as the core's minimum, which is why those rows carry a function and
not the spec's own (lo, hi).

EVENTS. `<pin>.<what>` is a pin of the core, with a pad delay. `in.<pin>.<what>`
is an input as the testbench drives it, and `smp.<what>` and `clk.end` are clock
edges inside the core -- no pad delay. The vocabulary is fixed here and in
sim/tb/rd68031_timing_tb.sv, and nothing else may invent one.
"""

import argparse
import os
import sys

R = 'R'   # the transition happens on a rising clock edge
F = 'F'   # ... or a falling one

# Each scenario is one stretch of the log, recorded separately, because the
# pairing rule -- an occurrence of a with the next occurrence of b after it --
# must never reach across from one kind of cycle into another. A read's AS and a
# write's DS are not a pair, and in one mixed log they would look like one.
ASYNC = ['read', 'write', 'mixed']
SYNC = ['sread', 'swrite', 'swwrite', 'smixed']
BUS = ASYNC + SYNC
READS = ['read', 'sread']
WRITES_DS = ['write', 'swwrite']          # writes that assert DS
WRITES = ['write', 'swrite', 'swwrite']
MIXED = ['mixed', 'smixed']
SCENARIOS = BUS + ['arb', 'status', 'reset']


def _scen(tag):
    if isinstance(tag, (list, tuple)):
        return list(tag)
    return [tag]


def scenarios_for(tag):
    return _scen(tag)


# --------------------------------------------------------------------------
# Pad-delay budgets: "Clock High/Low to <pin> <transition>".
#
# edge is what the specification itself measures from, so a design that moves the
# pin on the other edge is not merely slow, it is being judged against the wrong
# half of the clock -- and the analyser says so rather than silently using the
# nearest edge.
# --------------------------------------------------------------------------
PAD = [
    # key,            events,                                 edge, scenarios
    (('6', ''),       ['addr.valid'],                          R, BUS),
    (('6A', ''),      ['ecs.assert', 'ocs.assert'],            R, BUS),
    (('7', ''),       ['addr.hiz', 'dout.hiz'],                R, BUS),
    (('8', ''),       ['addr.invalid'],                        R, BUS),
    (('9', ''),       ['as.assert', 'ds.assert'],              F, BUS),
    (('9', ''),       ['cbreq.assert'],                        F, ['sread']),
    (('12', ''),      ['as.negate', 'ds.negate'],              F, BUS),
    (('12', ''),      ['cbreq.negate'],                        F, ['sread']),
    (('12A', ''),     ['ecs.negate', 'ocs.negate'],            F, BUS),
    (('16', ''),      ['ctl.hiz'],                             R, 'arb'),
    (('18', ''),      ['rw.high'],                             R, MIXED),
    (('20', ''),      ['rw.low'],                              R, WRITES + MIXED),
    (('23', ''),      ['dout.valid'],                          R, WRITES + MIXED),
    (('33', ''),      ['bg.assert'],                           F, 'arb'),
    (('34', ''),      ['bg.negate'],                           F, 'arb'),
    (('40', ''),      ['dben.assert'],                         R, READS),
    (('41', ''),      ['dben.negate'],                         F, READS),
    (('42', ''),      ['dben.assert'],                         F, WRITES),
    (('43', ''),      ['dben.negate'],                         R, WRITES),
    (('53', ''),      ['dout.invalid'],                        R, WRITES + MIXED),
    (('62', ''),      ['status.assert', 'refill.assert'],      F, 'status'),
    (('63', ''),      ['status.negate', 'refill.negate'],      F, 'status'),
]


# --------------------------------------------------------------------------
# Bounds that are not the specification's own (lo, hi): the processor's side of
# a requirement on a device. Each takes the table and a grade and returns
# (lo, hi) in nanoseconds.
# --------------------------------------------------------------------------
def _dev(key, *plus):
    """The device may take up to spec `key`'s maximum, so the core needs at
    least that much, plus (or minus) the named limits -- each (sign, key, end)
    with end 0 for the minimum and 1 for the maximum."""
    def f(S, freq):
        v = S[key].ns(freq)[1]
        for sign, k, end in plus:
            v += sign * S[k].ns(freq)[end]
        return (v, None)
    f.__doc__ = 'max(%s)%s' % (key[0], ''.join(
        ' %s %s(%s)' % ('+' if s > 0 else '-', 'min' if e == 0 else 'max', k[0])
        for s, k, e in plus))
    return f


def _min_only(key):
    def f(S, freq):
        return (S[key].ns(freq)[0], None)
    f.__doc__ = 'min(%s)' % key[0]
    return f


S47A = ('47A', '')
S27 = ('27', '')
S27A = ('27A', '')

# --------------------------------------------------------------------------
# Separations: "<a> to <b>", and widths, which are the same thing with a and b
# on one pin. Each pairs an occurrence of a with the next occurrence of b after
# it, so "AS width asserted" is as.assert to as.negate and "AS width negated" is
# as.negate to the next as.assert, with no special case for either.
# --------------------------------------------------------------------------
SEP = [
    # key,               a,                  b,                scenarios,  bound
    (('6B', ''),         'addr.valid',       'ecs.negate',     BUS,        None),
    (('9A', ''),         'as.assert',        'ds.assert',      READS,      None),
    (('9B', ''),         'as.assert',        'ds.assert',      WRITES_DS,  None),
    (('10', ''),         'ecs.assert',       'ecs.negate',     BUS,        None),
    (('10A', ''),        'ocs.assert',       'ocs.negate',     BUS,        None),
    (('10B', ''),        'ecs.negate',       'ecs.assert',     BUS,        None),
    (('10B', ''),        'ocs.negate',       'ocs.assert',     BUS,        None),
    (('11', ''),         'addr.valid',       'as.assert',      BUS,        None),
    (('11', ''),         'addr.valid',       'ds.assert',      READS,      None),
    (('13', ''),         'as.negate',        'addr.invalid',   BUS,        None),
    (('13', ''),         'ds.negate',        'addr.invalid',   BUS,        None),
    (('14', ''),         'as.assert',        'as.negate',      ASYNC,      None),
    (('14', ''),         'ds.assert',        'ds.negate',      ['read'],   None),
    (('14A', ''),        'ds.assert',        'ds.negate',      WRITES_DS,  None),
    (('14B', ''),        'as.assert',        'as.negate',      SYNC,       None),
    (('14B', ''),        'ds.assert',        'ds.negate',      ['sread'],  None),
    (('15', ''),         'as.negate',        'as.assert',      BUS,        None),
    (('15', ''),         'ds.negate',        'ds.assert',      BUS,        None),
    (('15A', ''),        'ds.negate',        'as.assert',      BUS,        None),
    (('17', ''),         'as.negate',        'rw.change',      MIXED,      None),
    (('17', ''),         'ds.negate',        'rw.change',      MIXED,      None),
    (('21', ''),         'rw.high',          'as.assert',      MIXED,      None),
    (('22', ''),         'rw.low',           'ds.assert',      WRITES_DS,  None),
    (('24', ''),         'dout.valid',       'as.negate',      WRITES,     None),
    (('25', ''),         'as.negate',        'dout.invalid',   WRITES,     None),
    (('25', ''),         'ds.negate',        'dout.invalid',   WRITES_DS,  None),
    (('25A', ''),        'ds.negate',        'dben.negate',    WRITES_DS,  None),
    (('26', ''),         'dout.valid',       'ds.assert',      WRITES_DS,  None),
    (('35', ''),         'in.br.assert',     'bg.assert',      'arb',      None),
    (('37', ''),         'in.bgack.assert',  'bg.negate',      'arb',      None),
    (('39', ''),         'bg.negate',        'bg.assert',      'arb',      None),
    (('39A', ''),        'bg.assert',        'bg.negate',      'arb',      None),
    (('44', ''),         'rw.low',           'dben.assert',    WRITES,     None),
    (('45', 'Asynchronous Read'),  'dben.assert', 'dben.negate', ['read'],  None),
    (('45', 'Asynchronous Write'), 'dben.assert', 'dben.negate', ['write'], None),
    (('45A', 'Synchronous Read'),  'dben.assert', 'dben.negate', ['sread'], None),
    (('45A', 'Synchronous Write'), 'dben.assert', 'dben.negate',
                                                       ['swrite', 'swwrite'], None),
    (('46', ''),         'rw.change',        'rw.change',      ['mixed'],  None),
    (('46A', ''),        'rw.change',        'rw.change',      ['smixed'], None),
    (('55', ''),         'rw.change',        'dout.valid',     WRITES,     None),
    (('56', ''),         'rst.assert',       'rst.negate',     'reset',    None),
    (('58', ''),         'in.bgack.negate',  'ctl.drive',      'arb',      None),
    (('59', ''),         'bg.negate',        'ctl.drive',      'arb',      None),

    # The processor's side of the device's limits.
    #
    # 28: a device may hold DSACK, BERR, HALT or AVEC up to max(28) after AS
    # negates at the pin; the core's next sample of them must come later than
    # that by the sample's own setup time. Its minimum, 0, is the other end:
    # the core's last sample of the cycle -- the late BERR/HALT window and the
    # DSACK port size, one edge -- must not be after AS negates at the pin.
    (('28', ''),         'as.negate',        'smp.term',       BUS,
                                             _dev(('28', ''), (+1, S47A, 0))),
    (('28', ''),         'smp.late',         'as.negate',      ASYNC,
                                             _min_only(('28', ''))),
    # 28A: the same, measured from the clock low the cycle ends on.
    (('28A', ''),        'clk.end',          'smp.term',       BUS,
                                             _dev(('28A', ''), (+1, S47A, 0))),
    # 29: data may go invalid as soon as AS negates at the pin, so the core's
    # latch must not be later.
    (('29', ''),         'smp.data',         'as.negate',      READS,
                                             _min_only(('29', ''))),
    # 29A, 30A: a device may drive the data bus up to max(29A) after AS negates,
    # or max(30A) after the clock low ending the read; the core must not drive
    # it for a write before then.
    (('29A', ''),        'as.negate',        'dout.valid',     MIXED,
                                             _dev(('29A', ''))),
    (('30A', ''),        'clk.end',          'dout.valid',     MIXED,
                                             _dev(('30A', ''))),
    # 31: data may follow DSACK by max(31). DSACK asserted just in time for one
    # sample -- min(47A) before it -- means data by the latch, min(27) before
    # it. Footnote 2 waives 31 for a device that meets 47A; this is the case it
    # does not waive.
    (('31', ''),         'smp.dsack',        'smp.data',       ['read'],
                                             _dev(('31', ''), (+1, S27, 0),
                                                  (-1, S47A, 0))),
    # 48: BERR or HALT may follow DSACK by max(48), and must still make the
    # late sample with its setup, min(27A).
    (('48', ''),         'smp.dsack',        'smp.late',       ASYNC,
                                             _dev(('48', ''), (+1, S27A, 0),
                                                  (-1, S47A, 0))),
]

# --------------------------------------------------------------------------
# Where the core samples its inputs. Each row names the probes (the P lines of
# the log) whose sampling instant must lie inside the specification's window
# around an edge of the given kind: 'setup' checks the instant is no earlier
# than min(spec) before the edge, 'hold' no later than min(spec) after it.
# --------------------------------------------------------------------------
ASYNC_PROBES = ['dsack', 'berr', 'avec', 'halt', 'retry_negate',
                'ipl', 'cdis', 'mmudis', 'halt_sync', 'br', 'bgack', 'reset_in']
SYNC_PROBES = ['sterm', 'cback', 'ciin_sync', 'ciin_async']
LATE_PROBES = ['berr_late_async', 'retry_late_async', 'berr_late_sync']

INPUT = [
    # key,          probes,                            edge, side
    (('47A', ''),   ASYNC_PROBES,                      F,   'setup'),
    (('47B', ''),   ASYNC_PROBES + LATE_PROBES,        F,   'hold'),
    (('27', ''),    ['data_async', 'data_sync'],       F,   'setup'),
    (('27A', ''),   LATE_PROBES,                       F,   'setup'),
    (('30', ''),    ['data_sync', 'data_async'],       F,   'hold'),
    (('28A', ''),   ['dsack', 'berr', 'avec', 'berr_late_sync'], F, 'hold'),
    (('60', ''),    SYNC_PROBES,                       R,   'setup'),
    (('61', ''),    SYNC_PROBES,                       R,   'hold'),
]

# The most skew between DSACK0 and DSACK1 the core was shown to tolerate (the Q
# lines), which must be at least max(31A).
SKEW = [
    (('31A', ''),   ['dsack_skew_dsack0_first', 'dsack_skew_dsack1_first']),
]

# Counts: (key, scenario, event, expected) where expected is a number or the
# name of another event whose count it must equal.
COUNT = [
    # Footnote 11, on 14A, 25, 25A and 26: "DS will not be asserted for
    # synchronous write cycles with no wait states".
    (('14A', ''),   'swrite', 'ds.assert',  0),
    # Footnote 6: if BR is held more than max(37A) after BGACK, "BG may be
    # reasserted" -- and so, held for exactly that long, it must not be.
    (('37A', ''),   'arb',    'bg.assert',  'in.br.assert'),
]

# The stimulus used the device's whole allowance: every a-to-b gap in the log is
# at least max(spec).
STIM = [
    (('37A', ''),   'in.bgack.assert', 'in.br.negate', 'arb'),
]

# The clock: the run's own period (the C line) against specification 1, and its
# half against 2/3.
DIRECT = {
    ('1', ''):    'period',
    ('2, 3', ''): 'half',
}

# --------------------------------------------------------------------------
# What this analysis is not about, and why. Every one of these is a real
# specification; none of them is a question about this design.
# --------------------------------------------------------------------------
UNANCHORED = {
    ('4, 5', ''): 'clock rise and fall times; an RTL model has no edge ramps, '
                  'and the clock is the system\'s',
    ('32', ''):   'RESET input transition time, a property of the system\'s '
                  'reset circuit; this design synchronises RESET through two '
                  'falling-edge ranks whatever its slope',
    ('57', ''):   'BERR negated to HALT negated on a rerun: an order the data '
                  'sheet asks of the device, which this design does not rely on '
                  '-- a retry waits for both to be negated, in either order',
}

# Specifications that cover a pin this analysis cannot see, and what covers it.
PARTIAL = {
    ('6', ''):  'IPEND is the sequencer\'s, not the bus unit\'s, and is not in '
                'this log: it is a rising-edge register (rd68031_seq.sv), '
                'checked to move only on rising edges by core_exc_tb',
    ('8', ''):  'IPEND, as for 6',
    ('6B', ''): 'IPEND, as for 6',
}


def _evs():
    out = set()
    for _, evs, _, _ in PAD:
        out.update(evs)
    for row in SEP:
        out.add(row[1])
        out.add(row[2])
    for _, _, ev, exp in COUNT:
        out.add(ev)
        if isinstance(exp, str):
            out.add(exp)
    for _, a, b, _ in STIM:
        out.add(a)
        out.add(b)
    return sorted(out)


EVENTS = _evs()


def anchored_keys():
    keys = set(k for k, _, _, _ in PAD)
    keys |= set(row[0] for row in SEP)
    keys |= set(k for k, _, _, _ in INPUT)
    keys |= set(k for k, _ in SKEW)
    keys |= set(k for k, _, _, _ in COUNT)
    keys |= set(k for k, _, _, _ in STIM)
    keys |= set(DIRECT)
    return keys


def check_complete(specs):
    """Every specification is either anchored or explained. Nothing falls down
    the gap between the two."""
    anchored = anchored_keys()
    missing = [k for k in specs if k not in anchored and k not in UNANCHORED]
    stale = [k for k in UNANCHORED if k not in specs]
    stale += [k for k in anchored if k not in specs]
    stale += [k for k in PARTIAL if k not in specs]
    both = [k for k in UNANCHORED if k in anchored]
    return missing, stale + both


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--unanchored', action='store_true')
    args = ap.parse_args()

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import specs as specs_mod
    specs = specs_mod.load()

    def ch(key):
        s = specs.get(key)
        return s.characteristic if s else '?'

    if args.unanchored:
        for key, why in sorted(UNANCHORED.items()):
            print('%-8s %-50s %s' % (key[0], ch(key)[:50], why))
        for key, why in sorted(PARTIAL.items()):
            print('%-8s %-50s (partly) %s' % (key[0], ch(key)[:50], why))
    else:
        print('# pad-delay budgets')
        for key, evs, edge, scen in PAD:
            print('  %-6s %-4s %-28s %s'
                  % (key[0], 'CLK' + edge, ','.join(evs), ch(key)[:44]))
        print('# separations')
        for key, a, b, scen, bound in SEP:
            print('  %-24s %-16s -> %-14s %s'
                  % (key[0] + (':' + key[1] if key[1] else ''), a, b,
                     bound.__doc__ if bound else ch(key)[:36]))
        print('# input sampling windows')
        for key, probes, edge, side in INPUT:
            print('  %-6s CLK%s %-5s %s' % (key[0], edge, side, ', '.join(probes)))
        print('# skew, counts, stimulus, clock')
        for key, qs in SKEW:
            print('  %-6s %s' % (key[0], ', '.join(qs)))
        for key, scen, ev, exp in COUNT:
            print('  %-6s %s: count(%s) == %s' % (key[0], scen, ev, exp))
        for key, a, b, scen in STIM:
            print('  %-6s %s: %s -> %s >= max' % (key[0], scen, a, b))
        for key, what in sorted(DIRECT.items()):
            print('  %-6s the clock %s' % (key[0], what))

    missing, stale = check_complete(specs)
    if missing:
        print('\nFAIL: %d specifications are neither anchored nor explained: %s'
              % (len(missing), ', '.join(k[0] for k in sorted(missing))))
        return 1
    if stale:
        print('\nFAIL: %d anchors or exclusions name a specification that does '
              'not exist, or both anchor and exclude one: %s'
              % (len(stale), ', '.join(str(k) for k in sorted(stale))))
        return 1
    print('\n%d specifications: %d anchored, %d explained'
          % (len(specs), len(specs) - len(UNANCHORED), len(UNANCHORED)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
