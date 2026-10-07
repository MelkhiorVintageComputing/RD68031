#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
#
# Generate the cputest corpus one instruction at a time.
#
#   tools/cputest/generate.sh CPUTESTGEN INI RUNDIR [MNEMONIC...]
#
# cputestgen's `mode=all` runs every instruction in one process, and a single
# instruction the generator cannot finish (it retries one effective address
# forever: seen on OR.L with seed 1, and on CHK) stops the whole corpus. So the
# instructions are generated one per run, each with a time limit (CPUTEST_TIMEOUT,
# default 120 s), into the same set directories. One that runs out of time is
# tried once more with the next seed, into a set of its own name (each set has
# its own memory images), and listed in RUNDIR/reseeded; one that fails twice
# is listed in RUNDIR/timeouts and left out. The memory images every run of a
# set writes come from the same seed and are the same.
#
# With no MNEMONIC, the MC68030 integer instructions cputest knows (its own
# names: MVSR2 is MOVE from SR, MVMLE MOVEM to memory, MULL and DIVL the long
# forms, and so on). Left out: the FPU, the MC68040 cache and MOVE16
# instructions, the MMU ones (cputest has none for an MC68030), LPSTOP, HALT
# and PULSE (not MC68030 instructions), RESET (it would reset the runner) and
# BKPT (its acknowledge cycle needs a device the bench does not have).
#
# The ini's sections are kept as they are, except that every `mode=` line is
# replaced by the instruction being generated; a section whose mode lists only
# some instructions (RD030EA) is generated only for those.
set -e
GEN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
INI=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
RUN=$3
shift 3
T=${CPUTEST_TIMEOUT:-120}
ALL="OR CHK CHK2 AND EOR ORSR ANDSR EORSR SUB SUBA SUBX SBCD ADD ADDA ADDX ABCD
     NEG NEGX NBCD CLR NOT TST BTST BCHG BCLR BSET CMP CMPM CMPA MVPRM MVPMR MOVE MOVEA
     MVSR2 MV2SR SWAP EXG EXT MVMEL MVMLE TRAP MVR2USP MVUSP2R NOP RTE RTD LINK UNLK RTS
     STOP TRAPV RTR JSR JMP BSR Bcc LEA PEA DBcc Scc DIVU DIVS MULU MULS ASR ASL LSR LSL
     ROL ROR ROXL ROXR ASRW ASLW LSRW LSLW ROLW RORW ROXLW ROXRW MOVE2C MOVEC2 CAS CAS2
     MULL DIVL BFTST BFEXTU BFCHG BFEXTS BFCLR BFFFO BFSET BFINS PACK UNPK TAS TRAPcc MOVES ILLEGAL"
LIST=${*:-$ALL}

mkdir -p "$RUN/data"
cd "$RUN"
: > timeouts
: > reseeded
: > gen.log
# One instruction under one seed: 0 on success, 1 if it ran out of time.
gen_one() { # mnemonic seed setsuffix
	awk -v m="$1" -v seed="$2" -v suf="$3" '
		/^\[test=/ { if (suf != "") sub(/\]/, suf "]") }
		/^seed=/ { if (seed != "") { print "seed=" seed; next } }
		/^mode=/ {
			if ($0 == "mode=all") { print "mode=" m; next }
			n = split(substr($0, 6), l, ",")
			keep = ""
			for (i = 1; i <= n; i++) {
				b = l[i]; sub(/\..*/, "", b)
				if (tolower(b) == tolower(m)) keep = keep (keep == "" ? "" : ",") l[i]
			}
			if (keep != "") print "mode=" keep; else print "enabled=0"
			next
		}
		{ print }' "$INI" > cputestgen.ini
	before=$(ls -d data/*/*/ 2>/dev/null | sort)
	if timeout "$T" "$GEN" >> gen.log 2>&1; then
		return 0
	fi
	# a run cut short leaves unmerged files behind: remove what it made
	after=$(ls -d data/*/*/ 2>/dev/null | sort)
	echo "$after" | while read -r d; do
		if [ -n "$d" ] && ! echo "$before" | grep -qx "$d"; then rm -rf "$d"; fi
	done
	return 1
}

seed0=$(sed -n 's/^seed=//p' "$INI" | head -1)
seed0=${seed0:-0}
for m in $LIST; do
	if gen_one "$m" "" ""; then
		echo "  cputest: $m" >> gen.log
		continue
	fi
	# Each seed has its few instructions the generator cannot finish; the next
	# seed is tried, into a set of its own (sets carry their own memory images).
	s1=$((seed0 + 1))
	if gen_one "$m" "$s1" "S$s1"; then
		echo "  cputest: $m (seed $s1, set suffix S$s1)" >> gen.log
		echo "$m" >> reseeded
	else
		echo "$m" >> timeouts
		echo "  cputest: $m TIMED OUT after $T s twice, left out" >> gen.log
	fi
done
n=$(wc -l < timeouts)
r=$(wc -l < reseeded)
echo "cputest: $(ls -d data/*/*/ | wc -l) instruction files; $r generated with the next seed$( [ "$r" -gt 0 ] && printf ' (%s)' "$(tr '\n' ' ' < reseeded | sed 's/ $//')"); $n left out$( [ "$n" -gt 0 ] && printf ': %s' "$(tr '\n' ' ' < timeouts)")"
