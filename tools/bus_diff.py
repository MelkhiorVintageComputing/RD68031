#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

"""Compare two bus streams: an oracle's and this core's.

Generalised from RD68021's suska_diff.py, which compared one core's data cycles
with another's one bus cycle at a time and stopped at the first difference.
Two kinds of stream are compared here, and both are aligned with a sequence
matcher, so that every difference is reported -- an access one side has and
the other has not, two accesses in a different order, the same access with
another value -- and not just the first.

    python3 tools/bus_diff.py stream <oracle.ubus> <core.cbus> [--show N]
    python3 tools/bus_diff.py pins   <ap030.pins>  <core.pins> [--show N]

STREAM (make cosim-mmu). UAE030 (tools/cosim/uae030/uae030_trace.c -B) and
core_cosim_tb (+mmubus=) write the physical data-access stream: every
operand, stack and table-search access, with its physical address, function
code and value; instruction fetches left out, cache hits invisible. The format
is at the top of uae030_trace.c. The two cores do not split an operand alike
-- the oracle moves a misaligned long word as aligned pieces, the core as the
cycles UM table 7-4 gives for the port -- so both are cut into the bytes they
move and put back together within each aligned long word, which is a unit
both agree on. Then:

  * the D stream -- operand accesses, and the table searches for them and for
    PTEST and PLOAD (kind T), U and M write-backs included -- is compared in
    order. A read made while CACR.ED was set on either side is left out: the
    data cache may have answered it on one side and not the other.
  * the F stream -- table searches made to translate an instruction fetch --
    is compared on its own, and its differences are reported but do not fail
    the comparison: when a prefetch runs ahead, and so when it needs a page,
    is not something the manual fixes.
  * two orders are made canonical first (normalise(), below): the oracle's
    vector fetch is put after the frame it belongs to, as UM 8.1 orders
    them, and the writes of a bus fault frame are sorted by address.
  * a long or short bus fault frame (format $B, 92 bytes; $A, 32) is compared
    on the words UM 8.2.1 defines -- SR, PC, format and vector, SSW, the
    pipe's stage C and B, the fault address, the data output buffer, the stage
    B address and the data input buffer. The rest is "internal registers",
    and its bytes are not compared wherever they are later read (by RTE). The
    oracle's exception marker (E 2 or E 3) says where its frames are.

PINS (make ap030). sim/models/rd68031_busmon.sv writes one line per transfer,
one per beat of a burst, from two cores' pins on identical slave models. The
DATA transfers are compared in order -- everything but function codes 2 and 6,
which are instruction fetches and whose number and order depend on how each
core prefetches: address, FC, SIZ, R/W, the termination, RMC, CBREQ, CBACK,
CIIN, CIOUT, and the data of the bytes the port moved (UM 7.2.1). A write's
other lanes (UM table 7-5) are compared separately and reported as their own
class. The stream is cut into phases at each write to $0000_8000 (the MARK of
sim/programs/mmu_common.inc and of the bus probe), so that a difference in one
phase does not misalign the next.

The exit status is 0 when the compared streams agree, 1 otherwise.
"""

import difflib
import sys

DEFINED_B = set()
for lo, hi in ((0x00, 0x08), (0x0A, 0x14), (0x18, 0x1C), (0x24, 0x28), (0x2C, 0x30)):
    DEFINED_B.update(range(lo, hi))
DEFINED_A = set()
for lo, hi in ((0x00, 0x08), (0x0A, 0x14), (0x18, 0x1C)):
    DEFINED_A.update(range(lo, hi))


# --------------------------------------------------------------------------
# stream
# --------------------------------------------------------------------------
def load_stream(path):
    """Events: ('I', n, pc), ('E', vec), or an access dict."""
    ev = []
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == 'I':
            ev.append(('I', int(p[1]), int(p[2], 16)))
        elif p[0] == 'E':
            ev.append(('E', int(p[1])))
        elif p[0] in ('R', 'W'):
            ev.append({'rw': p[0], 'pa': int(p[1], 16), 'n': int(p[2]),
                       'd': int(p[3], 16), 'fc': int(p[4]), 'k': p[5],
                       'c': int(p[6]), 'b': len(p) > 7 and p[7] == 'B'})
    return ev


def normalise(ev, oracle):
    """Two orderings the manual does not fix, or fixes against the oracle,
    are put into one canonical order on both sides:

    * UM 8.1: exception processing builds the frame, then fetches the vector.
      The oracle fetches the vector first (doc/oracles.md, Quirks); after its
      `E v` marker, a long-word read at offset 4v is moved after the run of
      writes that follows it.
    * The order in which the words of a bus fault frame ($A or $B) are
      written: UM 8.2 gives the frame's layout, not the order of its writes.
      A run of consecutive writes that contains a format word $A0xx or $B0xx
      (vector offset 8 or 12) is sorted by address.
    """
    ev = list(ev)
    if oracle:
        i = 0
        while i < len(ev):
            e = ev[i]
            if isinstance(e, tuple) and e[0] == 'E' and i + 1 < len(ev):
                r = ev[i + 1]
                if (isinstance(r, dict) and r['rw'] == 'R' and r['n'] == 4
                        and (r['pa'] & 0x3FF) == 4 * e[1]):
                    j = i + 2
                    while (j < len(ev) and isinstance(ev[j], dict)
                           and ev[j]['rw'] == 'W' and ev[j]['k'] == 'D'):
                        j += 1
                    ev[i + 1:j] = ev[i + 2:j] + [r]
            i += 1
    out = []
    i = 0
    while i < len(ev):
        e = ev[i]
        if isinstance(e, dict) and e['rw'] == 'W' and e['k'] == 'D':
            j = i
            while (j < len(ev) and isinstance(ev[j], dict)
                   and ev[j]['rw'] == 'W' and ev[j]['k'] == 'D'):
                j += 1
            run = ev[i:j]
            if any(x['n'] == 2 and (x['d'] & 0xE000) in (0xA000, 0xB000)
                   and (x['d'] & 0xFFF) in (8, 12) for x in run):
                run = sorted(run, key=lambda x: x['pa'])
            out.extend(run)
            i = j
        else:
            out.append(e)
            i += 1
    return out


SSW_MASK = {0x0A: 0xF1, 0x0B: 0xF7}   # UM figure 8-9: bits 11-9 and 3 are "X"


def frames(ev):
    """The byte addresses of the internal words of every fault frame the
    oracle wrote: after an `E 2`/`E 3`, the writes up to the next boundary.
    Returns {address: mask of the bits compared} -- 0 for an internal byte,
    a partial mask for the SSW's internal-use bits."""
    masked = {}
    nfr = 0
    i = 0
    while i < len(ev):
        e = ev[i]
        if isinstance(e, tuple) and e[0] == 'E' and e[1] in (2, 3):
            ws = []
            j = i + 1
            while j < len(ev) and not (isinstance(ev[j], tuple) and ev[j][0] == 'I'):
                x = ev[j]
                if isinstance(x, dict) and x['rw'] == 'W' and x['k'] == 'D':
                    ws.append(x)
                j += 1
            nbytes = sum(x['n'] for x in ws)
            if ws and nbytes in (92, 32):
                lo = min(x['pa'] for x in ws)
                keep = DEFINED_B if nbytes == 92 else DEFINED_A
                for off in range(nbytes):
                    if off not in keep:
                        masked[lo + off] = 0
                    elif off in SSW_MASK:
                        masked[lo + off] = SSW_MASK[off]
                nfr += 1
            i = j
        else:
            i += 1
    return masked, nfr


def chunks(ev, masked):
    """Cut every access into bytes and rejoin them within an aligned long
    word; returns (D list, F list), each element (key, where)."""
    out = {'D': [], 'F': []}
    insn, pc = 0, 0
    cur = None          # the chunk being built

    def flush():
        nonlocal cur
        if cur is not None:
            key = (cur['rw'], '%08x' % cur['pa'], len(cur['bytes']),
                   ''.join('..' if b is None else '%02x' % b for b in cur['bytes']),
                   cur['fc'], cur['k'], 'B' if cur['b'] else '')
            out[cur['s']].append((key, (cur['insn'], cur['pc'])))
            cur = None

    nmasked = 0
    for e in ev:
        if isinstance(e, tuple):
            if e[0] == 'I':
                insn, pc = e[1], e[2]
            continue
        if e['rw'] == 'R' and e['c'] and e['k'] == 'D':
            flush()
            continue
        s = 'F' if e['k'] == 'F' else 'D'
        if e['b']:
            flush()
            cur = {'rw': e['rw'], 'pa': e['pa'], 'bytes': [None] * e['n'],
                   'fc': e['fc'], 'k': e['k'], 'b': True, 's': s,
                   'insn': insn, 'pc': pc}
            flush()
            continue
        for j in range(e['n']):
            a = e['pa'] + j
            b = (e['d'] >> (8 * (e['n'] - 1 - j))) & 0xFF
            if e['k'] == 'D' and a in masked:
                if masked[a] == 0:
                    b = None
                    nmasked += 1
                else:
                    b &= masked[a]
            if (cur is not None and cur['rw'] == e['rw'] and cur['k'] == e['k']
                    and cur['fc'] == e['fc'] and cur['s'] == s
                    and cur['pa'] + len(cur['bytes']) == a and (a & 3) != 0):
                cur['bytes'].append(b)
            else:
                flush()
                cur = {'rw': e['rw'], 'pa': a, 'bytes': [b], 'fc': e['fc'],
                       'k': e['k'], 'b': False, 's': s, 'insn': insn, 'pc': pc}
    flush()
    return out['D'], out['F'], nmasked


def fmt_key(k):
    rw, pa, n, d, fc, kind, b = k
    return f'{rw} {pa} {n} {d} fc{fc} {kind}{" BERR" if b else ""}'


def compare(name, a, b, show, la='oracle', lb='core'):
    ka = [x[0] for x in a]
    kb = [x[0] for x in b]
    sm = difflib.SequenceMatcher(None, ka, kb, autojunk=False)
    diffs = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        cls = 'differ'
        if sorted(ka[i1:i2]) == sorted(kb[j1:j2]):
            cls = 'order'
        elif (i2 - i1) == (j2 - j1) and all(
                x[:3] == y[:3] and x[4:] == y[4:] for x, y in zip(ka[i1:i2], kb[j1:j2])):
            cls = 'value'
        diffs.append((cls, i1, i2, j1, j2))
    # An access one side made a little earlier than the other shows up as a
    # deletion here and an insertion nearby. Pair those up (same access,
    # within MOVED positions) and call them "moved": the order differs, the
    # access does not.
    MOVED = 24
    dels = [(i, ka[i]) for c, i1, i2, j1, j2 in diffs if c == 'differ' for i in range(i1, i2)]
    inss = [(j, kb[j]) for c, i1, i2, j1, j2 in diffs if c == 'differ' for j in range(j1, j2)]
    used = set()
    moved = set()
    off = 0
    jm = {}
    for c, i1, i2, j1, j2 in sm.get_opcodes():
        for i in range(i1, i2):
            jm[i] = j1
    for i, k in dels:
        for j, k2 in inss:
            if j in used or k2 != k or abs(j - jm.get(i, j)) > MOVED:
                continue
            used.add(j)
            moved.add(('a', i))
            moved.add(('b', j))
            break
    kept = []
    for d in diffs:
        cls, i1, i2, j1, j2 = d
        if cls == 'differ' and all(('a', i) in moved for i in range(i1, i2)) \
                and all(('b', j) in moved for j in range(j1, j2)):
            d = ('moved', i1, i2, j1, j2)
        kept.append(d)
    diffs = kept
    print(f'  {name}: {len(ka)} accesses ({la}) and {len(kb)} ({lb}); '
          f'{len(diffs)} differences'
          + (' (' + ', '.join(f'{c} {sum(1 for d in diffs if d[0] == c)}'
                              for c in ('differ', 'value', 'order', 'moved')
                              if any(d[0] == c for d in diffs)) + ')' if diffs else ''))
    for n, (cls, i1, i2, j1, j2) in enumerate(diffs[:show]):
        wa = a[i1][1] if i1 < len(a) else (a[-1][1] if a else (0, 0))
        wb = b[j1][1] if j1 < len(b) else (b[-1][1] if b else (0, 0))
        print(f'    #{n + 1} [{cls}] {la} insn {wa[0]} pc {wa[1]:x} / {lb} insn {wb[0]} pc {wb[1]:x}')
        for x in ka[i1:min(i2, i1 + 12)]:
            print(f'      {la:7s} {fmt_key(x)}')
        if i2 - i1 > 12:
            print(f'      {la:7s} ... {i2 - i1 - 12} more')
        for x in kb[j1:min(j2, j1 + 12)]:
            print(f'      {lb:7s} {fmt_key(x)}')
        if j2 - j1 > 12:
            print(f'      {lb:7s} ... {j2 - j1 - 12} more')
    return diffs


def do_stream(fa, fb, show):
    ea, eb = normalise(load_stream(fa), True), normalise(load_stream(fb), False)
    # The reset vector reads come before the first boundary. They are shown,
    # not compared: UM 8.1.1 has them in supervisor program space, ISP first,
    # and the oracle reads PC first in data space (doc/oracles.md, Quirks).
    for nm, ev in (('oracle', ea), ('core', eb)):
        k = next((i for i, e in enumerate(ev) if isinstance(e, tuple) and e[0] == 'I'), 0)
        pre = [e for e in ev[:k] if isinstance(e, dict)]
        print(f'  reset ({nm}): ' + ', '.join(
            f"{e['rw']} {e['pa']:x} fc{e['fc']}" for e in pre))
        del ev[:k]
    masked, nfr = frames(ea)
    da, fa_, ma = chunks(ea, masked)
    db, fb_, mb = chunks(eb, masked)
    print(f'  {nfr} fault frames from the oracle; {ma} and {mb} bytes of their '
          f'internal words not compared')
    dd = compare('D stream (operands, their table searches, PTEST, PLOAD)', da, db, show)
    df = compare('F stream (table searches for instruction fetches; reported, not failed)',
                 fa_, fb_, min(show, 5))
    return 1 if dd else 0


# --------------------------------------------------------------------------
# pins
# --------------------------------------------------------------------------
def port_bytes(a):
    return {1: 2, 2: 1}.get(a >> 28, 4)


def xfer(a, siz, term):
    pb = {'DSACK16': 2, 'DSACK8': 1}.get(term, 4)
    room = pb - (a % pb)
    sb = 4 if siz == 0 else siz
    return pb, min(sb, room)


def load_pins(path):
    """Per phase, the list of (key, where) of the data transfers; and counts."""
    phases = [[]]
    names = [0]
    nfetch = 0
    for line in open(path):
        f = dict(x.split('=', 1) for x in line.split() if '=' in x)
        p = line.split()
        if len(p) < 3 or p[1] not in ('R', 'W'):
            continue
        rw = p[1]
        a = int(f['a'], 16)
        fc = int(f['fc'])
        siz = int(f['siz'])
        term = f['term']
        # A bus nobody drives (a BERR cycle, an X from a model) reads as
        # z or x: such lanes compare as 'zz'.
        draw = f['d'].lower()
        d = int(''.join(c if c in '0123456789abcdef' else '0' for c in draw), 16)
        undriven = any(c not in '0123456789abcdef' for c in draw)
        beat = int(f.get('beat', '0'))
        if rw == 'R' and fc in (2, 6):
            nfetch += 1
            continue
        pb, n = xfer(a, siz, term)
        if beat:
            n = 4
        lanes = []
        for j in range(n):
            lane = 0 if pb == 1 else ((a + j) % pb)
            lanes.append('%02x' % ((d >> (24 - 8 * lane)) & 0xFF))
        data = ''.join(lanes) if term not in ('BERR', 'RETRY') else '-'
        if undriven and data != '-':
            data = 'zz' * n
        other = ('%08x' % d) if rw == 'W' else ''
        key = (rw, '%08x' % a, fc, siz, term, data, f.get('rmc'), f.get('cbreq'),
               f.get('cback'), f.get('ciin'), f.get('ciout'), beat)
        phases[-1].append((key, (int(f.get('clk', '0')), other)))
        if rw == 'W' and a == 0x8000 and fc in (1, 5):
            phases.append([])
            names.append(d)
    return phases, names, nfetch


def fmt_pin(k):
    rw, a, fc, siz, term, data, rmc, cbreq, cback, ciin, ciout, beat = k
    fl = ''.join(n for n, v in (('rmc ', rmc), ('cbreq ', cbreq), ('cback ', cback),
                                ('ciin ', ciin), ('ciout ', ciout)) if v == '1')
    return f'{rw} {a} fc{fc} siz{siz} {term} {data} {fl}' + (f'beat{beat}' if beat else '')


def do_pins(fa, fb, show):
    pa, na, fta = load_pins(fa)
    pb, nb, ftb = load_pins(fb)
    print(f'  {sum(len(x) for x in pa)} data transfers (AP68030) and '
          f'{sum(len(x) for x in pb)} (core) in {len(pa)} and {len(pb)} phases; '
          f'instruction fetches {fta} and {ftb}, not compared')
    bad = 0
    lane_diff = 0
    lane_show = []
    if na != nb:
        print(f'  the phases differ: AP68030 {na[:40]} core {nb[:40]}')
        bad = 1
    for i in range(min(len(pa), len(pb))):
        a, b = pa[i], pb[i]
        ka = [x[0] for x in a]
        kb = [x[0] for x in b]
        sm = difflib.SequenceMatcher(None, ka, kb, autojunk=False)
        ops = [o for o in sm.get_opcodes() if o[0] != 'equal']
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == 'equal':
                for x, y in zip(a[i1:i2], b[j1:j2]):
                    if x[1][1] != y[1][1]:
                        lane_diff += 1
                        if lane_diff <= 8:
                            lane_show.append(f'    phase {na[i]}: {fmt_pin(x[0])}: AP68030 drives '
                                             f'{x[1][1]}, the core {y[1][1]}')
        if not ops:
            continue
        bad = 1
        print(f'  phase {na[i]}: {len(ka)} and {len(kb)} transfers, {len(ops)} differences')
        for tag, i1, i2, j1, j2 in ops[:show]:
            cls = 'order' if sorted(ka[i1:i2]) == sorted(kb[j1:j2]) else tag
            print(f'    [{cls}] AP68030 clk {a[i1][1][0] if i1 < len(a) else "-"} / '
                  f'core clk {b[j1][1][0] if j1 < len(b) else "-"}')
            for x in ka[i1:min(i2, i1 + 10)]:
                print(f'      AP68030 {fmt_pin(x)}')
            if i2 - i1 > 10:
                print(f'      AP68030 ... {i2 - i1 - 10} more')
            for x in kb[j1:min(j2, j1 + 10)]:
                print(f'      core    {fmt_pin(x)}')
            if j2 - j1 > 10:
                print(f'      core    ... {j2 - j1 - 10} more')
    if lane_diff:
        print(f'  {lane_diff} matching writes differ on the lanes the port does not use '
              f'(UM table 7-5)')
        for x in lane_show:
            print(x)
    return bad


def main():
    args = [x for x in sys.argv[1:] if not x.startswith('--')]
    show = 10
    for x in sys.argv[1:]:
        if x.startswith('--show='):
            show = int(x.split('=', 1)[1])
    if len(args) != 3 or args[0] not in ('stream', 'pins'):
        sys.exit(__doc__)
    if args[0] == 'stream':
        return do_stream(args[1], args[2], show)
    return do_pins(args[1], args[2], show)


if __name__ == '__main__':
    sys.exit(main())
