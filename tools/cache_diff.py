#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

"""Hold a run with the caches and a run without them to the same bus.

    python3 tools/cache_diff.py <uncached.bus> <cached.bus>

Each file is one line per bus cycle, as sim/tb/core_cosim_tb.sv writes it with
+buslog: requester (F = instruction pipe, D = anything else), function code,
address, size, direction, write data. A burst is one cycle: one assertion of AS
(UM 7.3.7).

UM section 6: both caches are write-through copies of memory, invisible to the
program, so between a core with them and one built without them:

  - the WRITES must be identical, in the same order, one for one. The data
    cache is write-through -- "when a hit occurs on a write cycle, the data is
    written both to the cache and to external memory" (UM 6.1.2) -- and nothing
    else writes.
  - the data READS may only be fewer: a hit is no cycle at all, and a read half
    of which hits reads only the other half (UM 6.1.2). A cache-filling read
    from a port narrower than 32 bits makes extra cycles to complete the entry
    (UM 6.1.3.1); none of the programs this runs touches one.
  - the instruction fetches may only be fewer.
  Reads and fetches are counts, not sequences: the two runs do not read in the
  same order -- how far the pipe gets ahead of a branch depends on timing, and
  the timing is what the caches change.

The runs stop at the same instruction boundary but not at the same clock, so the
last few cycles of the longer log can be ones the shorter never reached. A write
there is a difference only if it is beyond what the other run wrote at all.
"""

import sys


def load(path):
    f, rd, wr = 0, 0, []
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == 'F':
                f += 1
            elif parts[4] == 'W':
                wr.append(tuple(parts[1:]))
            else:
                rd += 1
    return f, rd, wr


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    f0, r0, w0 = load(sys.argv[1])
    f1, r1, w1 = load(sys.argv[2])

    n = min(len(w0), len(w1))
    for i in range(n):
        if w0[i] != w1[i]:
            print(f'FAIL: write {i} differs: uncached {w0[i]}, cached {w1[i]}')
            return 1
    tail = w0[n:] + w1[n:]
    if len(tail) > 2:
        print(f'FAIL: the runs differ by {len(tail)} trailing writes: {tail[:4]}')
        return 1
    # A read or two of slack, for the same reason as the writes: the run that
    # got further may have started the next instruction's operand.
    if r1 > r0 + 2:
        print(f'FAIL: the cached run made MORE data reads: {r1} against {r0}')
        return 1
    if f1 > f0:
        print(f'FAIL: the cached run made MORE instruction fetches: {f1} against {f0}')
        return 1
    fs = 100.0 * (f0 - f1) / f0 if f0 else 0.0
    rs = 100.0 * (r0 - r1) / r0 if r0 else 0.0
    print(f'{n} writes identical; data reads {r0} -> {r1} ({rs:.1f}% taken by the '
          f'data cache); instruction fetches {f0} -> {f1} ({fs:.1f}% taken by the '
          f'instruction cache)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
