#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031

"""The six MC68030 exception stack frames, and the state this design keeps in them.

    python3 tools/ucode/frames.py            # the layouts and the budget
    python3 tools/ucode/frames.py --check    # just the checks

This is the single table. `rtl/gen/rd68031_frame_pkg.sv` is generated from it, the
microcode's frame-build and RTE routines are checked against it, and the tables in
`doc/checkpoint.md` are printed from it. One wrong offset in the long fault frame
is a silent demand-paging failure that no instruction test will catch, so the
offset exists once.

Source, the MC68030 user's manual (UM): Table 8-6 for the layouts and which
exception takes which, 8.1.8 and 8.1.13 for the version word and the format
error, 8.2 and figure 8-9 for the special status word, figure 10-43 for the
coprocessor midinstruction frame, and section 9 for the faults the MMU adds.
The layouts are word for word the MC68020's (UM20 Table 6-5); the special
status word is not -- four of its reserved bits became internal ones. The
frozen set below was inherited from RD68021 and rewritten for this part at M4.
"""

import argparse
import sys
import os
import re

# --------------------------------------------------------------------------
# Architecturally named fields. A slot is (offset, words, field).
#
# `internal` means the manual names it "internal register" or "internal
# information" -- private to the implementation, and on the long frame protected
# by the version number at SP+$36.
#
# `pc` is what UM Table 8-6 says the stacked program counter points to, and
# `taken_for` the exceptions it lists against the frame. They are printed into
# doc/checkpoint.md and are what the testbenches check the frames against.
# --------------------------------------------------------------------------
FRAMES = {
    0x0: dict(words=4, name='four-word', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
    ], pc='the next instruction (interrupt, TRAP #n); the instruction itself '
          '(illegal, A-line, F-line, privilege violation); the RTE or '
          'cpRESTORE (format error); the operation word (cp preinstruction)',
       taken_for='interrupt, format error, TRAP #n, illegal instruction, '
                 'A-line, F-line, privilege violation, coprocessor '
                 'preinstruction'),
    0x1: dict(words=4, name='throwaway four-word', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
    ], pc='the next instruction -- the same as on the master stack',
       taken_for='an interrupt taken with M set, on the interrupt stack -- '
                 'UM 8.1.9'),
    0x2: dict(words=6, name='six-word', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 2, 'instr_addr'),
    ], pc='the next instruction; +$08 is the instruction that caused it',
       taken_for='CHK, CHK2, cpTRAPcc, TRAPcc, TRAPV, trace, zero divide, '
                 'MMU configuration, coprocessor postinstruction'),
    # UM figure 10-43. Table 8-6 draws the same ten words as "internal
    # registers, 4 words" after the instruction address; section 10 names them.
    0x9: dict(words=10, name='coprocessor midinstruction', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'scanpc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 2, 'instr_addr'),   # UM figure 10-43's "program counter"
        (0x0C, 1, 'internal'),
        (0x0E, 1, 'opword'),
        (0x10, 2, 'ea'),
    ], pc='the next word to be fetched (the scanPC); +$08 is the coprocessor '
          'instruction',
       taken_for='coprocessor midinstruction, main-detected protocol '
                 'violation, interrupt during a coprocessor instruction'),
    0xA: dict(words=16, name='short bus fault', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 1, 'internal'),
        (0x0A, 1, 'ssw'),
        (0x0C, 1, 'stage_c'),
        (0x0E, 1, 'stage_b'),
        (0x10, 2, 'dfa'),
        (0x14, 1, 'internal'),
        (0x16, 1, 'internal'),
        (0x18, 2, 'dob'),
        (0x1C, 1, 'internal'),
        (0x1E, 1, 'internal'),
    ], pc='the next instruction',
       taken_for='address error or bus error, execution unit at an '
                 'instruction boundary -- never built by this design'),
    0xB: dict(words=46, name='long bus fault', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 1, 'internal'),
        (0x0A, 1, 'ssw'),
        (0x0C, 1, 'stage_c'),
        (0x0E, 1, 'stage_b'),
        (0x10, 2, 'dfa'),
        (0x14, 1, 'internal'),
        (0x16, 1, 'internal'),
        (0x18, 2, 'dob'),
        (0x1C, 4, 'internal'),
        (0x24, 2, 'stage_b_addr'),
        (0x28, 2, 'internal'),
        (0x2C, 2, 'dib'),
        (0x30, 3, 'internal'),
        (0x36, 1, 'version'),
        (0x38, 18, 'internal'),
    ], pc='the instruction executing when the fault occurred, which may not be '
          'the one that ran the faulted cycle',
       taken_for='address error or bus error, instruction execution in '
                 'progress -- every bus and address error this design takes'),
}

# UM 8.1.13: RTE "examines the stack frame on top of the active supervisor stack
# to determine if it is a valid frame". These six are the MC68030's (UM 8.4,
# "the MC68030 provides six different stack frames"); every other format code
# is a format error, vector 14 -- UM 8.1.8.
VALID_FORMATS = tuple(sorted(FRAMES))

# UM 8.1.13: "the version number is located in the most significant nibble
# (bits 15-12) of the word at location SP+$36 in the long stack frame", and UM
# 8.1.8: RTE "compares the internal version number of the processor to that
# contained in the frame at memory location SP+54 (SP+$36)". The MC68030
# manual's own Table 8-6 draws it there too; the PRM's figure B-12, and the
# MC68020 manual's table, draw it a row lower -- doc/manual-contradictions.md.
VERSION_OFFSET = 0x36
VERSION_HI, VERSION_LO = 15, 12
# This design's number. Not the MC68020 design's (RD68021 stamps 1): the two
# keep different things in the internal words -- doc/checkpoint.md -- and the
# stamp is what stops one reading the other's. The manual does not say what a
# real MC68030 stamps, so nothing can promise to differ from it; a frame from
# a real part that happened to carry this number would be misread, exactly as
# the manual's own check would let it be between two mask sets that shared one.
VERSION = 0x3

# --------------------------------------------------------------------------
# The special status word -- UM 8.2.1, figure 8-9.
#
# (hi, lo, name, what). Every bit of the word is in exactly one row.
#
# The MC68020's figure (UM20 6-8) draws bits 11-9 and 3 as 0. The MC68030's
# draws them X, "for internal use only", and UM 8.2.2 adds that a handler may
# change "DF, RB, and RC; all other bits, including those defined for internal
# use, must remain unchanged". This design keeps nothing in them: they are
# written as zero and RTE ignores them. They are in both bus fault frames, and
# the short one has no version field (rule 1 below), so a private use would
# have to be confined to the long frame -- doc/ssw.md.
# --------------------------------------------------------------------------
SSW = [
    (15, 15, 'FC',       'fault on stage C of the instruction pipe'),
    (14, 14, 'FB',       'fault on stage B of the instruction pipe'),
    (13, 13, 'RC',       'rerun flag for stage C'),
    (12, 12, 'RB',       'rerun flag for stage B'),
    (11,  9, 'internal', 'for internal use only -- written as zero here'),
    ( 8,  8, 'DF',       'fault/rerun flag for the data cycle'),
    ( 7,  7, 'RM',       'read-modify-write on the data cycle'),
    ( 6,  6, 'RW',       'read/write for the data cycle: 1 = read, 0 = write'),
    ( 5,  4, 'SIZE',     'size code for the data cycle -- UM Table 7-2'),
    ( 3,  3, 'internal', 'for internal use only -- written as zero here'),
    ( 2,  0, 'FCODE',    'the address space of the data cycle'),
]
# UM 8.2.2: "The only bits in the SSW that may be modified are DF, RB, and RC."
SSW_HANDLER_MAY_CHANGE = ('DF', 'RB', 'RC')

# --------------------------------------------------------------------------
# Where this design's private state lives, in the long frame's internal words.
#
# Rules, and they are the reason this file is written before any instruction:
#
#   1. Nothing goes in the SHORT frame's internal words, and RTE reads none out
#      of one. Format $A has no version field -- UM 8.1.13 validates the stamp
#      only for the long frame -- so a short frame could come from anywhere and
#      RTE has no way to know what its internal words mean. Everything format
#      $A needs is either an architectural field or derivable from one, and
#      RTE takes it apart with nothing else (program.py, rte_fault_short).
#   2. The cache holding register is NOT saved. It is a pure cache of the last
#      long word fetched; RTE marks it invalid and the next prefetch re-reads it.
#      One bus cycle, never a wrong answer, and 66 bits of budget back.
#   3. Every register an instruction accumulates has a home here or it does not
#      exist. A microword may not stash a value anywhere else.
# --------------------------------------------------------------------------
INTERNAL = [
    # offset, hi, lo, name, bits, what
    (0x08,  2,  0, 'bytes',      3,  'residual byte count of the faulted operand'),
    (0x08,  4,  4, 'notrace',    1,  'the trace pending for this instruction was cancelled'),
    (0x08,  6,  6, 'eapc',       1,  'the base of the effective address under way is the PC'),
    (0x08,  8,  7, 'opsize',     2,  'the operand size the dispatching microword resolved'),
    (0x08,  9,  9, 'eadst',      1,  'the effective address under way is a MOVE destination'),
    (0x36,  2,  1, 'trmode',     2,  'the trace mode this instruction began with'),
    (0x36,  3,  3, 'flow',       1,  'this instruction has changed the flow'),
    (0x36,  4,  4, 'pc_kept',    1,  'pc_prev was taken at a flush, not at the decode'),
    (0x46, 31,  0, 'pc_prev',   32,  'the address of the instruction before this one'),
    (0x08, 15, 15, 'dvalid',     1,  'stage D holds an instruction word'),
    (0x14, 15,  0, 'upc',       16,  'the micro-address to resume at'),
    (0x16, 15,  0, 'stage_d',   16,  'the instruction word being decoded'),
    (0x1C, 31,  0, 't0',        32,  'working register'),
    (0x20, 31,  0, 't1',        32,  'working register'),
    (0x28, 31,  0, 't2',        32,  'working register'),
    (0x30, 31,  0, 't3',        32,  'working register'),
    (0x34, 15,  0, 'xw',        16,  'the extension-word latch'),
    (0x38, 31,  0, 'ea_latch',  32,  'the address output buffer'),
    (0x3C, 31,  0, 'ea_save',   32,  'the copy of it taken at the fault'),
    (0x40, 31,  0, 'pc_fetch',  32,  'the next long word the pipe will fetch'),
    (0x44, 15,  0, 'link',      16,  'the return address of the subroutine under way'),
    (0x4A, 15,  0, 'cprim',     16,  'the coprocessor response primitive being served'),
    (0x08,  5,  5, 'posted',     1,  'the faulted access was a posted write, which RTE reruns by itself'),
    (0x08, 12, 10, 'irqlvl',     3,  'the level of the interrupt being taken'),
    # M8-M9, out of its reservation: UM 8.2.3, RTE with DF set "reruns the
    # entire instruction" of a read-modify-write, so the frame says where the
    # locked sequence starts.
    (0x52, 15,  0, 'rmwupc',    16,  'the micro-address the read-modify-write under way starts again at'),
]

# --------------------------------------------------------------------------
# Words of the long frame set aside, now, for what M8-M11 add. (offset, words,
# milestone, what for.)
#
# A freeze that leaves the later milestones to find their own room is not one:
# the first of them to need a word would take whatever was free and the budget
# would stop meaning anything. So the room is named here, by milestone, with
# what it is expected to hold. A milestone that needs state takes it from its
# own reservation, turns it into an INTERNAL row and a CHECKPOINT row, and
# shrinks the reservation; one that needs none -- doc/checkpoint.md argues
# that M10 and M11 may need none -- releases it, and the words become spare.
# check() keeps reservations off every allocated bit.
# --------------------------------------------------------------------------
RESERVED = [
    # M11's two words, +$4C -- "MMU instruction state that has to outlive a
    # posted write's fault -- PTEST, PLOAD, PFLUSH, PMOVE -- should one need
    # more than T0-T3 and the extension word" -- are released. PMOVE holds its
    # operand in T0 and T1 and writes the register on a microword that can take
    # no fault; PTEST and PLOAD wait for posted writes before their search
    # starts, so none can land while it runs; PTEST's descriptor address is
    # written to An by the microword after, which can take no fault either; and
    # the walker is the hardware's, never the frame's (rule 11, doc/mmu.md).
    # M8-M9's word, +$52, became `rmwupc` above.
    # M10's word, +$50 -- "the faulted operand's cache disposition, should an
    # RTE rerun need to know how the first attempt left the data cache" -- is
    # released: no rerun needs to. A faulted read filled nothing it did not
    # complete, a faulted write has already updated the cache as UM 6.1.2 says
    # it does, and a rerun takes the bus again (doc/caches.md, rule 12).
]

# --------------------------------------------------------------------------
# What each fault looks like in a frame -- this design's encoding of UM 8.1.2,
# 8.1.3, 8.2 and section 9, including the MMU's, which M11 builds against.
#
# (key, milestone, cause, vector, format, special status word, +$10 and the
# rest). Vector None means no exception is taken at all.
#
# The MMU adds no new frame and no new status bit. UM 8.1.2: "a bus error
# exception also occurs when the MMU detects that a successful address
# translation is not possible"; UM 9.5.2: a table search that ends in "an
# invalid descriptor, a limit violation, or a bus error" loads the ATC with the
# B bit set, and "the MC68030 takes an exception on the retry of the cycle". So
# every MMU fault is reported as an ordinary bus error on the LOGICAL access
# that was being translated, and the handler finds out why with PTEST (UM
# 9.10.3). Nothing about the search is in the frame.
# --------------------------------------------------------------------------
FAULTS = [
    ('data', 'M2', 'BERR ending a data cycle -- asynchronous, synchronous, or '
     'a burst\'s first cycle, which carries the operand (UM 6.1.3.2)',
     2, 0xB, 'DF; RM, RW, SIZE and FC2-FC0 of the faulted cycle',
     '+$10 the address of the next byte still to transfer (the residual); '
     '+$18 the operand being written, +$2C what had been read'),
    ('prefetch', 'M2', 'BERR ending an instruction prefetch, taken when the '
     'word is used -- UM 8.1.2', 2, 0xB,
     'FC and/or FB, each with its rerun bit; the low half clear',
     '+$24 the stage B address; stage C is two below it'),
    ('odd', 'M2', 'address error: a prefetch from an odd address, no bus '
     'cycle -- UM 8.1.3', 3, 0xB, 'RC and RB alone (UM 8.2.1)',
     '+$02 the odd address'),
    ('burst_tail', 'M10', 'BERR on a burst beat, or a fill cycle, that '
     'carries none of the operand -- UM 6.1.3.2', None, None,
     'none: the cache entry is marked invalid', 'none'),
    ('icache_fill', 'M10', 'BERR on an instruction cache fill', 2, 0xB,
     'as prefetch, if and when the word is used', 'as prefetch'),
    ('mmu_invalid', 'M11', 'the table search ends at an invalid descriptor '
     '-- UM 9.5.2', 2, 0xB, 'as data or prefetch, for the retried access',
     '+$10 the LOGICAL address of the retried cycle'),
    ('mmu_limit', 'M11', 'a limit violation in the table search', 2, 0xB,
     'as data or prefetch', 'as mmu_invalid'),
    ('mmu_super', 'M11', 'a supervisor-only page at the user privilege level -- UM 9.5.5.3',
     2, 0xB, 'as data or prefetch', 'as mmu_invalid'),
    ('mmu_wp', 'M11', 'a write, or any cycle of a read-modify-write, to a '
     'write-protected page (UM 9.5.5.4) -- "the MMU of the MC68030 treats any bus cycle '
     'with RMC asserted as a write operation for protection checking" (UM '
     '8.2.3)', 2, 0xB, 'as data; a CAS, CAS2 or TAS faults on its READ, '
     'RW = 1 and RM = 1', 'as mmu_invalid'),
    ('mmu_search_berr', 'M11', 'BERR on a table-search cycle: the search '
     'ends, the entry gets B, the retried access faults -- UM 9.4, 9.5.2',
     2, 0xB, 'as data or prefetch, for the retried access; the search '
     'cycle itself appears nowhere', 'as mmu_invalid'),
    ('mmu_b', 'M11', 'an ATC hit on an entry with B set', 2, 0xB,
     'as data or prefetch', 'as mmu_invalid'),
    ('mmu_config', 'M11', 'PMOVE of an invalid configuration to TC, CRP or '
     'SRP: a postinstruction exception -- UM 8.1.10, 9.7.5.3', 56, 0x2, 'none',
     '+$02 the next instruction, +$08 the PMOVE'),
    ('rte_format', 'M4', 'RTE on a format other than $0 $1 $2 $9 $A $B, or '
     'on a $B whose version nibble is not this design\'s -- UM 8.1.8', 14,
     0x0, 'none', '+$02 the RTE; the frame it refused is left intact above'),
    ('rte_access', 'M4', 'RTE on a $A or $B frame it cannot read at one of '
     'its two ends -- UM 8.1.13', 2, 0xB, 'as data, a read', '+$10 the end '
     'it could not read; the frame is left intact and nothing was restored'),
    ('double', 'M8-M9', 'a bus or address error during exception processing '
     'for a bus error, an address error or reset, up to the first instruction '
     'of the handler -- the stacking, the vector read, the handler\'s first '
     'prefetch (UM 8.1.2, 8.1.3, 12.7.1)', None, None,
     'none: the processor halts, STATUS asserted continuously, and only a '
     'reset restarts it (UM 7.5.4)', 'none'),
    ('rte_load', 'M8-M9', 'a bus error while RTE loads a $A or $B frame it has '
     'validated -- UM 8.1.13, "once the processor begins to load the frame"',
     None, None, 'none: a double bus fault, as above', 'none'),
]

# --------------------------------------------------------------------------
# The frozen set: everything that survives a fault, and where it lands.
#
# `slot` is an architectural field of the fault frames, an INTERNAL name, or
# 'derived' with the derivation written out.
# --------------------------------------------------------------------------
CHECKPOINT = [
    # unit,  register,        bits, slot,            note
    #
    # `register` is the name in the RTL, not a pretty one. check_rtl() below
    # reads every clocked process in rtl/ and insists that each register it
    # finds is either in this table or in EXEMPT, with a reason. Driving the
    # check from the MICROWORD DESTINATIONS instead -- which is what it did --
    # cannot see a register the microcode never names: link_q, eapc_q, size_q,
    # eadst_q and cnt_q were all added and all missed, and the first of them
    # would have surfaced in M9 as a wild jump on a demand-paged access.
    ('ifu', 'd_q',              16, 'stage_d',       ''),
    ('ifu', 'd_v_q',             1, 'dvalid',        'a prefetch fault taken with the pipe empty -- after a flush -- has no stage D, and the word at +$16 is whatever the last one was. Restoring it as valid ran it: SunOS\'s forked child executed its parent\'s RTE'),
    ('ifu', 'c_q',              16, 'stage_c',       'frame +$0C'),
    ('ifu', 'b_q',              16, 'stage_b',       'frame +$0E'),
    ('ifu', 'c_f_q',             1, 'ssw',           'SSW FC'),
    ('ifu', 'b_f_q',             1, 'ssw',           'SSW FB'),
    ('ifu', 'pc_d_q',           32, 'pc',            "the frame's own program counter"),
    ('ifu', 'fill_q',           32, 'stage_b_addr',  'long frame +$24; short frame derives it. The same register as pc_fetch: stage B is two before the fill point.'),
    ('ifu', 'fill_q',           32, 'pc_fetch',      ''),
    ('ifu', 'chr_q',            32, 'derived',       'not saved: invalidated by RTE, re-fetched'),
    ('ifu', 'chr_addr_q',       30, 'derived',       'likewise'),
    ('ifu', 'chr_v_q',           1, 'derived',       'likewise -- always restored as invalid'),
    ('ifu', 'chr_f_q',           1, 'derived',       'likewise'),
    ('biu', 'flt_addr',         32, 'dfa',           'frame +$10'),
    ('biu', 'flt_dib',          32, 'dib',           'long frame +$2C'),
    ('biu', 'flt_dob',          32, 'dob',           'frame +$18'),
    ('biu', 'flt_bytes',         3, 'bytes',         'SIZ cannot encode a five-byte residual'),
    ('biu', 'flt_rmc',           1, 'ssw',           'SSW RM'),
    ('biu', 'flt_rw',            1, 'ssw',           'SSW RW'),
    ('biu', 'flt_fc',            3, 'ssw',           'SSW FC2-FC0'),
    ('seq', 'df_q',              1, 'ssw',           'SSW DF -- see biu.flt_df'),
    ('seq', 'flt_upc',          16, 'upc',           'the faulted microword\'s own address, latched at the fault: by the time the frame builder writes +$14 its own upc is deep inside itself'),
    ('seq', 'link_q',           16, 'link',          'seq = RET returns here'),
    ('seq', 't_q',              32, 't0',            'one array of four in the RTL'),
    ('seq', 't_q',              32, 't1',            ''),
    ('seq', 't_q',              32, 't2',            ''),
    ('seq', 't_q',              32, 't3',            ''),
    ('seq', 'ea_q',             32, 'ea_latch',      ''),
    ('seq', 'ea_save',          32, 'ea_save',       "the frame builder's own pointer, so that ea_q -- which is the instruction's and is +$38 -- is not disturbed. RTE ignores what lands in this slot"),
    ('seq', 'xw_q',             16, 'xw',            ''),
    ('seq', 'notrace_q',         1, 'notrace',       'the instruction was never executed, so UM 8.1.7 does not trace it'),
    ('seq', 'eapc_q',            1, 'eapc',          'seq = EADEC latches it; EABASE reads it'),
    ('seq', 'size_q',            2, 'opsize',        'seq = EAMODE latches it; the shared EA routines read it'),
    ('seq', 'eadst_q',           1, 'eadst',         'likewise, and rsel reads it'),
    ('seq', 'trace_mode_q',      2, 'trmode',        'UM 8.1.7 fixes it at the start of the instruction, so a fault may not lose it'),
    ('seq', 'flow_q',            1, 'flow',          'likewise: whether the instruction had changed the flow before it faulted'),
    ('seq', 'pc_prev_q',        32, 'pc_prev',       'a trace frame carries it at +$08'),
    ('seq', 'pc_kept_q',         1, 'pc_kept',      'pc_prev_q was taken at a flush, so the decode must not overwrite it'),
    ('seq', 'sr_q',             16, 'sr',            'frame +$00'),
    ('seq', 'cprim_q',          16, 'cprim',         'UM 10.5.2.8: a bus error on any CIR access but the first, or on an operand a primitive moves, is an ordinary bus error, and RTE goes back to the primitive it interrupted'),
    ('seq', 'post_flt_q',        1, 'posted',        'doc/checkpoint.md rule 9: the faulted access belongs to no microword -- the write was posted and the instruction went on -- so RTE runs it on its own and resumes at the microword that was interrupted'),
    ('seq', 'rmw_upc_q',        16, 'rmwupc',        'UM 8.2.3: with DF set, RTE "reruns the entire instruction" of a read-modify-write -- CAS, CAS2 or TAS -- so it resumes at the start of the locked sequence, which the microword marked RMW latched, and not at the faulted access'),
    ('seq', 'irq_taking_q',      3, 'irqlvl',        'the level of the interrupt being taken, from the dispatch to the acknowledge. A posted write\'s fault can land in between -- doc/checkpoint.md rule 9 -- and the acknowledge after RTE has to ask for the same level'),
]

# Rows of CHECKPOINT whose register the RTL does not have YET, and the milestone
# that builds it. They are listed rather than quietly skipped so that the table
# stays a description of the finished design and the check still says which
# parts of it are not there.
PENDING = {
}

# Every register in rtl/ that is NOT checkpointed, and the reason. check_rtl()
# below insists the two lists between them account for every clocked signal in
# the design -- so a register added without a thought about what a fault does to
# it is a build failure, not something M9 discovers.
EXEMPT = [
    # unit, register, why
    ('ifu', 'cnt_q',        'how many words the queue holds. Derived from the '
                            'rerun bits, which say which stages RTE still owes '
                            'a word: none if RC, one if RB alone, two if '
                            'neither.'),
    ('ifu', 'primed_q',     'whether the pipe has ever been flushed. Always set '
                            'once the first instruction has been fetched.'),
    ('ifu', 'fetch_pend_q', 'a prefetch is outstanding. Derived: RTE re-issues '
                            'whatever the refill needs.'),
    ('ifu', 'fetch_addr_q', 'the address that prefetch was issued at. Likewise.'),
    ('ifu', 'fetch_fc2_q',  '... and the space, for the cache tag. Likewise.'),
    ('icache', 'valid_q',   'the instruction cache. A cache, not context: a '
                            'fault leaves it alone and RTE has nothing to put '
                            'back: what it holds is a copy of memory -- rule 12.'),
    ('icache', 'tag_q',     '... its tags'),
    ('icache', 'mem',       '... and its data, which the valid bits gate'),
    ('ifu', 'fetch_fill_q', 'whether the prefetch in flight may be cached. '
                            'Derived like fetch_addr_q: decided again when RTE\'s '
                            'refill asks for the long word'),
    ('ifu', 'fetch_burst_q', '... and whether it asks for a burst. Likewise.'),
    ('ifu', 'ib_ok_q',      '... and whether the rest of its burst may be. A '
                            'burst is cycle-level: it ends before any fault is '
                            'taken (rule 12)'),
    ('dcache', 'valid_q',   'the data cache. A cache, not context, and '
                            'write-through: it never holds the only copy of '
                            'anything, a fault leaves it as it is, and RTE has '
                            'nothing to put back -- rule 12, doc/caches.md'),
    ('dcache', 'tag_q',     '... its tags'),
    ('dcache', 'm',         '... and its data, which the valid bits gate'),
    ('dcache', 'asm_v_q',   'a long word being gathered from a narrow port. '
                            'Cycle-level: a new operand starts afresh'),
    ('dcache', 'asm_ent_q', '... which long word'),
    ('dcache', 'asm_fc_q',  '... in which space'),
    ('dcache', 'asm_mask_q', '... which of its bytes have come'),
    ('dcache', 'asm_data_q', '... and what they are'),
    ('dcache', 'dkill_q',   'a CACR clear landed while a fill was in flight: the '
                            'rest of the fill is not cached. Cycle-level'),
    ('dcache', 'dw_v_q',    'a write the bus unit took last clock, applied to '
                            'the cache this clock. Lives one clock, between two '
                            'edges at which no fault is taken'),
    ('dcache', 'dw_addr_q', '... its address'),
    ('dcache', 'dw_fc_q',   '... its space'),
    ('dcache', 'dw_bytes_q', '... its size'),
    ('dcache', 'dw_data_q', '... its data'),
    ('dcache', 'dw_en_q',   '... whether the cache takes part'),
    ('dcache', 'dw_wa_q',   '... and whether it allocates'),
    ('ifu', 'ckpt_busy_q',  'RTE is in the middle of putting this pipe back, '
                            'so it does not fetch. It cannot be live across a '
                            'fault: a fault while RTE reads its own frame is a '
                            'double bus fault -- UM 8.1.2.'),
    ('ifu', 'discard_q',    'the word in flight belongs to a stream that is '
                            'gone. Likewise -- and RTE flushes anyway.'),

    # The bus unit's cycle-level state. A fault is recognised at the END of a
    # bus cycle and the bus is idle by the time the exception is taken, so none
    # of this is live across one. What IS live is the OPERAND residual, and that
    # is in CHECKPOINT above.
    # The RESET instruction's 512 clocks. No bus cycle runs while the counter
    # does -- the instruction asks for none and the sequencer is stalled, so the
    # pipe stands still too -- and therefore no fault can be taken in the middle
    # of it. PRM 6 also says the processor state other than the PC is
    # unaffected, so there is nothing here an exception handler could want.
    ('biu', 'req_end_q',    'how the last operand ended, as the sequencer is '
                            'told it. A fault is the one end code that outlives '
                            'the cycle, and it is in the SSW, which IS '
                            'checkpointed; the others are consumed by the '
                            'microword after the one that waited.'),

    ('biu', 'rst_pend_q',   'RTE has handed an operand back and the bus unit '
                            'has not picked it up yet. It lives for the clocks '
                            'between the handover and the next S0, inside one '
                            'instruction, and a fault in that window is a fault '
                            'on the rerun -- which UM 8.2.3 makes an ordinary '
                            'bus error with a frame of its own.'),

    ('biu', 'rsto_q',       'the RESET instruction is driving the pin'),
    ('biu', 'rsto_cnt',     '... for this many more clocks'),
    ('biu', 'rsto_arm_q',   '... and the request has been let go since, so the '
                            'count cannot restart itself'),
    ('biu', 'rsto_tail_q',  '... and the clocks after it in which the pin is '
                            'still read as the instruction\'s own -- UM 7.8'),
    ('biu', 'crst_q',       'the RESET pin is resetting the processor -- UM 7.8, '
                            '8.1.1. Nothing survives it to be restored'),

    # The live operand. What a fault frame carries is the SNAPSHOT above, taken
    # on the clock the fault is reported, because the frame is built by bus
    # cycles that run through these very registers -- doc/ssw.md.
    ('biu', 'op_addr',      'the address the operand now running is up to'),
    ('biu', 'op_data',      'its data, assembled or waiting to go out'),
    ('biu', 'op_rem',       'how many bytes of it are left'),
    ('biu', 'op_fc',        'its function code'),
    ('biu', 'op_rw',        'its direction'),
    ('biu', 'op_rmc',       'whether RMC is held across it'),

    # What the data cache said about the operand, and the cycles that complete
    # a cache entry from a narrow port (M10). Cycle-level: they carry none of
    # the operand, and a fault frame describes the operand -- rule 12.
    ('biu', 'op_dfill',     'the operand\'s reads may fill the data cache'),
    ('biu', 'op_fillc',     '... and complete a long word from a narrow port'),
    ('biu', 'op_tail',      'its last bytes hit in the data cache: the bus stops '
                            'short of them. A rerun reads them from the bus'),
    ('biu', 'fl_on',        'a cycle completing a cache entry is due'),
    ('biu', 'fl_addr',      '... at this address'),
    ('biu', 'fl_rem',       '... with this many bytes of the entry to come'),
    ('biu', 'ent_q',        'the long word the last read cycle carried'),
    ('biu', 'ent_got',      '... the bytes of it read so far'),
    ('biu', 'ent_bad',      '... and whether CIIN or BERR met one of them'),
    ('biu', 'cyc_fill',     'the cycle now running completes a cache entry'),
    ('biu', 'burst_tail',   'a burst is landing past its first long word'),

    ('biu', 'st_p',         'the bus state machine, rising-edge half'),
    ('biu', 'st_n',         '... and falling-edge half'),
    ('biu', 'cyc_addr',     'the address of the cycle now running'),
    ('biu', 'cyc_fc',       'its function code'),
    ('biu', 'cyc_rw',       'its direction'),
    ('biu', 'cyc_siz',      'its size code'),
    ('biu', 'cyc_n',        'how many bytes it asks for'),
    ('biu', 'd_latched',    'the data pins latched at S5'),
    ('biu', 'dsack_q',      'the port size the slave reported'),
    ('biu', 'term_q',       'how the cycle terminated'),
    ('biu', 'term_err',     '... bus error'),
    ('biu', 'term_rty',     '... retry'),
    ('biu', 'term_hlt',     '... halt'),
    ('biu', 'term_avc',     '... AVEC, on an interrupt acknowledge cycle'),
    ('biu', 'hiz_q',        'whether the address group is released'),
    ('biu', 'rdata_q',      'the result of the last read, held for the sequencer'),
    ('biu', 'frdata_q',     '... and of the last prefetch'),
    ('biu', 'req_ack',      'the handshake back to the sequencer'),
    ('biu', 'early_q',      '... and its half-clock early form, for one S5'),
    ('seq', 'own_q',        "this microword's posted write has been taken and it "
                            'has not retired; lives until it does, and a fault '
                            'on the write meanwhile is an ordinary one on its '
                            'own request'),
    ('biu', 'op_posted',    'the operand now running is a posted write -- '
                            'doc/checkpoint.md rule 9'),
    ('biu', 'rst_post_q',   'the operand RTE handed back is a posted write; '
                            'lives with rst_pend_q'),
    ('biu', 'req_taken',    'a posted request has been taken: the handshake, '
                            'for one clock'),
    ('biu', 'req_fault_post', '... and the fault being reported is on one'),
    ('seq', 'early_q',      'the last microword retired early; lives one clock, '
                            'and no fault is taken in it from its own bus cycle'),
    ('seq', 'resumed_q',    'the microword now presented is the one RTE resumed; '
                            'lives until it retires'),
    ('biu', 'fetch_ack',    '... and to the fetch unit'),
    ('biu', 'req_fault',    'a fault is being reported this clock'),
    ('biu', 'req_fault_wr', '... on a write'),
    ('biu', 'fetch_fault',  '... on a prefetch'),
    ('biu', 'op_active',    'an operand is under way'),
    ('biu', 'op_first',     'no cycle of it has started yet -- OCS'),
    ('biu', 'op_isfetch',   'which of the two requesters it belongs to'),
    ('biu', 'op_cpflt',     'whether a bus error on it is a fault -- a '
                            'coprocessor register access -- which the next '
                            'request, or a rerun, sets again'),
    ('biu', 'arb',          'the arbiter. UM figure 7-61: it is not part of the '
                            'processor state and a fault does not disturb it.'),
    ('biu', 'bg_n_o',       'the grant pin'),
    ('biu', 'rmc_hold',     'arbitration is inhibited across a read-modify-write'),
    ('biu', 'rmc_first_q',  '... except while its first bus cycle waits to be '
                            'retried -- UM 7.7.4, relinquish and retry'),
    ('biu', 'halt_hold',    'the processor is halted'),
    ('biu', 'retry_clr_q',  'BERR and HALT both negated, as the last falling '
                            'edge saw them: the end of a retry. About the '
                            'pins, sampled afresh every clock'),

    # The MC68030 bus, M1. Cycle-level like the rest: a fault is recognised at
    # the end of a bus cycle (or of a burst), and nothing here outlives it.
    ('biu', 'term_syn',     '... STERM'),
    ('biu', 'term_bfe',     '... a burst fill beat ended by BERR'),
    ('biu', 'sterm_q',      'STERM as the last rising-edge sample saw it'),
    ('biu', 'cback_q',      '... CBACK, latched with it'),
    ('biu', 'ciin_q',       '... CIIN, latched with it or at S4'),
    ('biu', 'beat_q',       'how many long words this cycle has latched'),
    ('biu', 'cyc_brq',      'CBREQ is asserted for the cycle now running'),
    ('biu', 'cyc_ciout',    'CIOUT for it'),
    ('biu', 'cyc_paddr',    'its physical address: the A31-A0 the MMU made of '
                            'cyc_addr'),
    ('biu', 'cyc_abt',      'the MMU refused it, and no pin moves'),
    ('biu', 'op_burst',     'the operand now running may ask for a line fill. '
                            'A request, reissued with the request.'),
    ('biu', 'op_brq_used',  '... and has had its CBREQ'),
    ('biu', 'op_pmask',     'the translation it was taken with: the page '
                            'offset mask. Recomputed from the ATC and the TTx '
                            'registers when RTE hands the operand back'),
    ('biu', 'op_lp1',       '... the logical page of its first byte'),
    ('biu', 'op_pb1',       '... that page\'s physical base'),
    ('biu', 'op_pb2',       '... and the next one\'s, if it crosses'),
    ('biu', 'op_ci1',       '... their cache inhibits'),
    ('biu', 'op_ci2',       '... likewise'),
    ('biu', 'op_f2',        '... and whether the second page refused it'),
    ('biu', 'op_istw',      'the operand is the table walker\'s, which no fault '
                            'is ever taken on (rule 11)'),
    ('biu', 'tw_ack',       'a walker operand has finished: lives one clock'),
    ('biu', 'tw_berr',      '... with a bus error, which ends the search with B'),
    ('biu', 'tw_rdata',     '... and what it read'),
    ('biu', 'fetch_ci',     'the MMU inhibited caching the prefetch just '
                            'answered: reported with it'),
    ('biu', 'op_ciin',      'CIIN seen on one of its cycles so far'),
    ('biu', 'req_ciin',     '... reported with the acknowledge, for one operand'),
    ('biu', 'fetch_ciin',   '... and for the prefetch'),
    ('biu', 'beat_valid',   'a read beat for a cache: lives one clock'),
    ('biu', 'beat_err',     '... ended in a bus error'),
    ('biu', 'beat_data',    '... its data'),
    ('biu', 'beat_addr',    '... its address'),
    ('biu', 'beat_num',     '... its place in a burst'),
    ('biu', 'beat_port',    '... the port that answered'),
    ('biu', 'beat_ciin',    '... its CIIN'),
    ('biu', 'beat_fetch',   '... and whether it was a prefetch'),
    ('biu', 'as_win',       'the AS pin, registered'),
    ('biu', 'ds_q',         'the DS pin, registered'),
    ('biu', 'cbreq_q',      'the CBREQ pin, registered'),
    ('biu', 'ecs_q',        'the ECS pin, registered'),
    ('biu', 'ocs_q',        'the OCS pin, registered'),
    ('biu', 'doe_q',        'the data bus enable, registered'),
    ('biu', 'sts_on_q',     'the STATUS pin: about the sequencer, not the '
                            'instruction, and a fault does not disturb it'),
    ('biu', 'sts_rem_q',    '... the clocks it has still to show'),
    ('biu', 'sts_pend_q',   '... and the indication waiting its turn'),
    ('biu', 'refill_on_q',  'the REFILL pin'),
    ('seq', 'boot_q',       'the first clock after reset, for STATUS'),
    ('seq', 'sts_bound_q',  'an instruction boundary, for STATUS: one clock'),
    ('seq', 'sts_pend_q',   '... with a trace or interrupt taken at it'),
    ('seq', 'sts_exc_q',    'exception processing began, for STATUS'),
    ('seq', 'sts_refill_q', 'a refill was requested, for REFILL'),

    ('seq', 'dreg',         'architectural: D0 to D7'),
    ('seq', 'areg',         'architectural: A0 to A6'),
    ('seq', 'usp_q',        'architectural. A7 is not a register -- it is '
                            'whichever of these three the S and M bits select.'),
    ('seq', 'isp_q',        'architectural'),
    ('seq', 'msp_q',        'architectural'),
    ('seq', 'vbr_q',        'architectural'),
    ('seq', 'sfc_q',        'architectural'),
    ('seq', 'dfc_q',        'architectural'),
    ('seq', 'cacr_q',       'architectural'),
    ('seq', 'caar_q',       'architectural'),
    ('seq', 'ipend_q',      'the IPEND pin, registered: about the pins and '
                            'the mask, recomputed every clock'),
    ('seq', 'iack_due_q',   '... held from the step into an interrupt to its '
                            'acknowledge\'s S0 (UM 8.1.9). A fault in between '
                            'clears it, and the acknowledge after RTE is from '
                            'the frame\'s irqlvl, with the pin as the mask '
                            'then says'),
    ('seq', 'irq_prev_q',   'the interrupt level at the last instruction '
                            'boundary. It is about the PINS, not about the '
                            'instruction: a fault does not change what the '
                            'outside world is asking for, and UM 8.1.9 requires '
                            'the device to hold the level until it is '
                            'acknowledged.'),
    # PRM 6 STOP. The processor runs no bus cycle while stopped, so no fault can
    # be recognised there, and the interrupt that ends the stopped state clears
    # the bit on the same clock it enters exception processing. A stopped
    # processor is not a context worth saving: it has none.
    ('seq', 'stopped_q',    'the processor is stopped'),

    # UM 8.1.2: "if a bus error occurs during the exception processing for a bus
    # error, address error, or reset ... a double bus fault occurs and the
    # processor enters the halted state". So a frame is never built from inside
    # the window this bit marks -- the machine halts instead -- and there is
    # nothing for a frame field to say.
    ('seq', 'g0_q',         'the window in which a second fault is a double bus fault'),
    ('seq', 'flt_odd_q',    'this fault is an address error and not a bus '
                            'error, which is the only thing that differs '
                            'between the two frames they build'),
    ('seq', 'dbf_q',        'a double bus fault has halted the processor. UM '
                            '8.1.2: only an external reset restarts it, so '
                            'there is nothing to restore and nowhere to '
                            'restore it from'),
    ('seq', 'upc',          'the micro-address now running. The one a fault '
                            'frame carries is flt_upc, latched on the clock '
                            'the fault was reported -- by then this one is the '
                            "frame builder's own."),

    # The two halves of the pipe's state arrive in different microwords of the
    # RTE, and these hold them until they can be put together. RTE reading its
    # own frame cannot fault without it being a double bus fault -- UM 8.1.2 --
    # so there is no window in which they must survive one.
    ('seq', 'rs_rc_q',      'the special status word RTE has read back, taken '
                            'apart: RC'),
    ('seq', 'rs_rb_q',      '... RB'),
    ('seq', 'rs_dv_q',      '... and, from the internal word at +$08, whether '
                            'stage D held a word'),
    ('seq', 'rs_df_q',      '... DF'),
    ('seq', 'rs_rm_q',      '... RM'),
    ('seq', 'rs_rw_q',      '... RW'),
    ('seq', 'rs_space_q',   '... and the address space of the data cycle'),
    ('seq', 'rupc_q',       'the micro-address RTE will resume at'),
    ('seq', 'ckpt_hold_q',  'RTE has written the fill point and not yet the '
                            'status register, so the pipe may not fetch -- '
                            'UM 8.2.1. Lives inside one RTE, after its frame '
                            'has been checked, and a fault ends it'),
    ('seq', 'rst_addr_q',   'the faulted operand RTE is handing back to the '
                            'bus unit: its address'),
    ('seq', 'rst_data_q',   '... whichever of its two data buffers the '
                            'direction makes meaningful'),
    ('seq', 'rst_bytes_q',  '... and how much of it is left'),

    ('seq', 'div_go_q',     'the divider is running. A divide makes no bus cycle, '
                            'so nothing can fault inside one: the microword that '
                            'reads the pipe comes after it.'),
    ('seq', 'div_fin_q',    'likewise'),
    ('seq', 'mmu_go_q',     'PTEST or PLOAD has started its search. The '
                            'microword waits for posted writes first and makes '
                            'no bus request of its own, so nothing can fault '
                            'while the search runs -- rule 11'),
    ('seq', 'mmu_fin_q',    '... and it is over'),

    # The MMU -- doc/mmu.md. Its registers are architectural, its ATC a cache,
    # and its walker is never interrupted (rule 11).
    ('mmu', 'tc_q',         'architectural'),
    ('mmu', 'crp_q',        'architectural'),
    ('mmu', 'srp_q',        'architectural'),
    ('mmu', 'tt0_q',        'architectural'),
    ('mmu', 'tt1_q',        'architectural'),
    ('mmu', 'mmusr_q',      'architectural'),
    ('mmu', 'v_q',          'the ATC: a cache of the tables. A fault leaves it '
                            'as it is and RTE has nothing to put back -- a rerun '
                            'searches again if the entry has gone (rule 12)'),
    ('mmu', 'h_q',          '... its replacement history'),
    ('mmu', 'tag_q',        '... its tags'),
    ('mmu', 'dat_q',        '... and its translations'),
    ('mmu', 'ptest_da',     'the last descriptor PTEST fetched, for An. Written '
                            'into An by the microword after the search, which '
                            'can take no fault'),
    ('mmu', 'done_q',       'PTEST or PLOAD is done: lives one clock'),
    ('mmu', 'sts_q',        'a search for an access begins, for STATUS'),
    ('mmu', 'w_st',         'the table walker. A search is never checkpointed '
                            'and never interrupted: it starts after any posted '
                            'write has finished, and a bus error ends it with B '
                            'and no exception -- rule 11'),
    ('mmu', 'w_ret',        '... where it goes after a history write'),
    ('mmu', 'w_kind',       '... what it is for'),
    ('mmu', 'w_la',         '... the logical address'),
    ('mmu', 'w_fc',         '... its space'),
    ('mmu', 'w_rw',         '... PTEST\'s R/W'),
    ('mmu', 'w_wr',         '... a write, for the M bit'),
    ('mmu', 'w_lvl',        '... PTEST\'s level'),
    ('mmu', 'w_x',          '... the level it has reached'),
    ('mmu', 'w_pos',        '... the logical address bits it has used'),
    ('mmu', 'w_ta',         '... the table base'),
    ('mmu', 'w_dt',         '... its descriptor size'),
    ('mmu', 'w_limv',       '... whether a limit applies'),
    ('mmu', 'w_lu',         '... lower or upper'),
    ('mmu', 'w_lim',        '... and what it is'),
    ('mmu', 'w_wp',         '... the accrued WP -- figure 9-26'),
    ('mmu', 'w_s',          '... S'),
    ('mmu', 'w_ci',         '... CI'),
    ('mmu', 'w_m',          '... M'),
    ('mmu', 'w_n',          '... tables accessed'),
    ('mmu', 'w_d0',         '... the descriptor'),
    ('mmu', 'w_d1',         '... its second long word'),
    ('mmu', 'w_daddr',      '... its address'),
    ('mmu', 'w_lastda',     '... the last one fetched whole'),
    ('mmu', 'w_inval',      '... how it ended: an invalid descriptor'),
    ('mmu', 'w_limx',       '... a limit violation'),
    ('mmu', 'w_berr',       '... a bus error'),
    ('mmu', 'w_indir',      '... the fetch is an indirect one'),
    ('mmu', 'w_ebase',      '... an early termination\'s page address'),
    ('mmu', 'w_pfa',        '... the page frame address'),
    ('mmu', 'w_pend',       '... its bus operand is outstanding'),
    ('mmu', 'w_raddr',      '... at this address'),
    ('mmu', 'w_rdat',       '... with this data'),
    ('mmu', 'w_rwr',        '... and this direction'),

    # The divider's own working state, for the same reason.
    ('divider', 'acc',      'the running remainder'),
    ('divider', 'quo',      'the quotient so far'),
    ('divider', 'rem_num',  'what is left of the dividend'),
    ('divider', 'iter',     'the bit counter'),
    ('divider', 'run',      'it is running'),
    ('divider', 'den_q',    'the divisor'),
    ('divider', 'sq',       'the sign the quotient is to carry'),
    ('divider', 'sr',       '... and the remainder'),
    ('divider', 'ovf_q',    'the quotient will not fit'),
    ('divider', 'dz_q',     'the divisor was zero'),
    ('divider', 'mag_num',  'the dividend, unsigned'),
    ('divider', 'mag_den',  '... and the divisor'),

    ('sync',     'q',       'a synchroniser is not state, it is a pipe'),
    ('sync',     'rank0',   'likewise'),
    ('dedge_ff', 'half_p',  'half of a both-edge cell'),
    ('dedge_ff', 'half_n',  '... and the other half'),
]

# Registers that are architectural rather than per-instruction state: a fault does
# not change them and RTE does not put them back.
NOT_CHECKPOINTED = [
    ('D0-D7, A0-A6', 'architectural'),
    ('USP, ISP, MSP', "architectural; A7 is not a register, it is whichever of "
                      "these the S and M bits select"),
    ('VBR, SFC, DFC', 'architectural'),
    ('CACR, CAAR', 'architectural'),
    ('TC, CRP, SRP, TT0, TT1, MMUSR', 'architectural. PMOVE writes them '
                      'on the microword that completes it, and a faulted one '
                      'commits nothing (rule 2)'),
    ('the instruction cache', 'a cache. What it holds is a copy of memory, and a '
                              'fault neither needs it nor disturbs it'),
    ('the data cache', 'a cache, write-through. A faulted write has already '
                       'updated it -- UM 6.1.2, "the cache contains the '
                       'new value even if the external write terminates in '
                       'a bus error" -- and RTE\'s rerun writes the same '
                       'bytes to memory again and leaves the cache alone, so '
                       'the rerun is idempotent. A faulted read filled nothing '
                       'it did not complete (doc/caches.md)'),
    ('the ATC', 'a cache of the tables. A table search\'s descriptor '
                      'updates (U, M) and its ATC entry stand whether or not the '
                      'access then faults -- UM 9.5.2 -- and a rerun searches '
                      'again if the entry has gone'),
    ('a table search in progress', 'never interrupted. It runs with RMC '
                      'asserted throughout (UM 9.5.2), a bus error ends it with '
                      'the B bit and no exception, and the exception is taken '
                      'on the retry of the access -- so no frame is ever built '
                      'in the middle of one'),
]

ARCH_FIELDS = {
    'sr': 'status register',
    'pc': 'program counter',
    'fmtvec': 'format and vector offset',
    'instr_addr': 'instruction address',
    'ssw': 'special status word',
    'stage_c': 'instruction pipe stage C',
    'stage_b': 'instruction pipe stage B',
    'stage_b_addr': 'stage B address',
    'dfa': 'data cycle fault address',
    'dob': 'data output buffer',
    'dib': 'data input buffer',
    'version': 'version number and internal information',
    'internal': 'internal register',
    'scanpc': 'scan program counter',
    'opword': 'operation word',
    'ea': 'effective address',
}


def internal_words(fmt):
    """The offsets of the private words in one frame."""
    out = []
    for off, n, field in FRAMES[fmt]['slots']:
        if field == 'internal':
            out.extend(off + 2 * i for i in range(n))
        elif field == 'version':
            out.append(off)
    return out


# --------------------------------------------------------------------------
# The checks. These are the point of the file.
# --------------------------------------------------------------------------
def check():
    bad = []

    # 1. Every frame is contiguous, gapless and exactly its declared length.
    for fmt, f in sorted(FRAMES.items()):
        want = 0
        for off, n, field in f['slots']:
            if off != want:
                bad.append('format $%X: slot %r starts at +$%02X, expected +$%02X'
                           % (fmt, field, off, want))
            if field not in ARCH_FIELDS:
                bad.append('format $%X: slot %r is not a known field' % (fmt, field))
            want = off + 2 * n
        if want != 2 * f['words']:
            bad.append('format $%X: slots cover %d bytes, the manual says %d words '
                       '(%d bytes)' % (fmt, want, f['words'], 2 * f['words']))

    # 2. The version word is where UM 8.1.13 says, and only the long frame has one.
    for fmt, f in sorted(FRAMES.items()):
        vs = [off for off, n, field in f['slots'] if field == 'version']
        if fmt == 0xB:
            if vs != [VERSION_OFFSET]:
                bad.append('format $B: the version word is at %s, UM 8.1.13 says '
                           '+$%02X' % (vs, VERSION_OFFSET))
        elif vs:
            bad.append('format $%X: has a version word, which only the long frame '
                       'does' % fmt)

    # 3. The private assignment fits in the long frame's internal words, with no
    #    two registers on the same bits.
    avail = set(internal_words(0xB))
    used = {}
    for off, hi, lo, name, bits, _ in INTERNAL:
        if hi - lo + 1 != bits:
            bad.append('internal %r: %d bits declared, bit range %d..%d is %d'
                       % (name, bits, hi, lo, hi - lo + 1))
        nwords = (bits + 15) // 16
        for w in range(nwords):
            o = off + 2 * w
            if o not in avail:
                bad.append('internal %r: +$%02X is not an internal word of the '
                           'long frame' % (name, o))
            # A field of 16 bits or fewer occupies the bits it names in one word;
            # a wider one occupies whole words.
            span = range(lo, hi + 1) if bits <= 16 else range(0, 16)
            for b in span:
                k = (o, b)
                if k in used:
                    bad.append('internal %r: +$%02X bit %d is already %r'
                               % (name, o, b, used[k]))
                used[k] = name
    for b in range(VERSION_LO, VERSION_HI + 1):
        k = (VERSION_OFFSET, b)
        if k in used:
            bad.append('internal %r sits on the version nibble at +$%02X bit %d'
                       % (used[k], VERSION_OFFSET, b))

    # 4. NOTHING private is in the short frame. Format $A has no version field,
    #    so anything this design put there could be read by something else with
    #    no way to know it should not.
    short = set(internal_words(0xA))
    for off, hi, lo, name, bits, _ in INTERNAL:
        nwords = (bits + 15) // 16
        for w in range(nwords):
            if off + 2 * w in short and off + 2 * w not in avail:
                bad.append('internal %r is in the short frame, which has no '
                           'version field' % name)

    # 5. Every checkpointed register has a home, and every home is real.
    names = set(n for _, _, _, n, _, _ in INTERNAL)
    for unit, reg, bits, slot, _ in CHECKPOINT:
        if slot == 'derived':
            continue
        if slot in names:
            continue
        if slot in ARCH_FIELDS:
            continue
        bad.append('%s.%s: slot %r is neither an internal name nor an '
                   'architectural field' % (unit, reg, slot))

    # 6. Every internal word this design allocated is actually used by something.
    #    An allocation nobody claims is a budget nobody will re-examine.
    claimed = set(slot for _, _, _, slot, _ in CHECKPOINT)
    for off, hi, lo, name, bits, _ in INTERNAL:
        if name not in claimed:
            bad.append('internal %r at +$%02X is allocated but no checkpointed '
                       'register uses it' % (name, off))


    # 7. The special status word: sixteen bits, each named exactly once, and the
    #    three a handler may change are among them -- UM figure 8-9, UM 8.2.2.
    seen = {}
    for hi, lo, name, _ in SSW:
        for b in range(lo, hi + 1):
            if b in seen:
                bad.append('SSW bit %d is both %s and %s' % (b, seen[b], name))
            seen[b] = name
    if sorted(seen) != list(range(16)):
        bad.append('SSW: bits %s are not described'
                   % sorted(set(range(16)) - set(seen)))
    for name in SSW_HANDLER_MAY_CHANGE:
        if name not in [n for _, _, n, _ in SSW]:
            bad.append('SSW: %s may be changed by a handler and is not a field'
                       % name)

    # 8. A reservation is room, not a register: it may not sit on an allocated
    #    bit, on the version word, or outside the long frame's internal words.
    words = {}
    for off, hi, lo, name, bits, _ in INTERNAL:
        for w in range((bits + 15) // 16):
            words.setdefault(off + 2 * w, []).append(name)
    for off, n, ms, _ in RESERVED:
        for w in range(n):
            o = off + 2 * w
            if o not in avail:
                bad.append('reserved +$%02X (%s) is not an internal word of the '
                           'long frame' % (o, ms))
            if o == VERSION_OFFSET:
                bad.append('reserved +$%02X (%s) is the version word' % (o, ms))
            if o in words:
                bad.append('reserved +$%02X (%s) is already %s'
                           % (o, ms, ', '.join(words[o])))

    # 9. Every fault encoding names a frame the part has and a vector.
    for key, ms, _, vec, fmt, _, _ in FAULTS:
        if (vec is None) != (fmt is None):
            bad.append('fault %r: a vector without a frame, or a frame without '
                       'a vector' % key)
        if fmt is not None and fmt not in FRAMES:
            bad.append('fault %r: format $%X is not an MC68030 frame' % (key, fmt))
    return bad


# --------------------------------------------------------------------------
# The check that reads the RTL
# --------------------------------------------------------------------------
_MODULES = ('ifu', 'icache', 'dcache', 'biu', 'seq', 'mmu', 'divider', 'shifter', 'sync', 'dedge_ff', 'top')


def _unparen(text):
    """`text` with every parenthesised span removed."""
    out, depth = [], 0
    for ch in text:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    return ''.join(out)


def rtl_registers(rtl_dir):
    """Every signal a clocked process writes, by module.

    A non-blocking assignment ends with an identifier and optional index
    expressions, and stands at a statement boundary; a comparison stands inside
    an expression. Unbalanced parentheses to the left of the name is what tells
    the two apart, so `if (a <= b)` and `for (i = 0; i <= 7; ...)` are rejected
    while a `q <= d` sharing its line with the `else if (...)` that guards it is
    not. Missing one of those would leave a register silently unchecked.
    """
    found = {}
    for name in _MODULES:
        path = os.path.join(rtl_dir, 'rd68031_%s.sv' % name)
        if not os.path.exists(path):
            continue
        text = re.sub(r'//[^\n]*', '', open(path).read())
        regs = set()
        for line in text.split('\n'):
            if '<=' not in line:
                continue
            for a in re.finditer('<=', line):
                left = line[:a.start()]
                m = re.search(r'([a-z_][a-z_0-9]*)((?:\[[^\]]*\])*)\s*$', left)
                if not m:
                    continue
                before = left[:m.start()]
                # Inside an expression -- `if (a <= b)`, `for (i = 0; i <= 7;)`
                # -- the parentheses are still open.
                if before.count('(') != before.count(')'):
                    continue
                # A blocking assignment on the same line means this `<=` is the
                # comparison in `y = a <= b`, not a register. Parenthesised `=`
                # belongs to a for-loop header, which may still guard one.
                if re.search(r'(?<![<>=!])=(?!=)', _unparen(before)):
                    continue
                regs.add(m.group(1))
        found[name] = regs
    return found


def check_rtl(rtl_dir):
    """Every register in the design is accounted for, one way or the other.

    doc/checkpoint.md rule 3: every register an instruction accumulates has a
    home in the frame or it does not exist. This is that rule, enforced against
    the SOURCE rather than against the microcode -- because a register the
    microcode never names as a destination is exactly the kind the old check
    could not see, and five of them got past it.
    """
    bad = []
    found = rtl_registers(rtl_dir)
    if not found:
        return ['checkpoint: no RTL was read, so this check proved nothing']

    kept   = {(u, r) for u, r, _, _, _ in CHECKPOINT}
    waived = {(u, r) for u, r, _ in EXEMPT}

    for unit, regs in sorted(found.items()):
        for r in sorted(regs):
            if (unit, r) not in kept and (unit, r) not in waived:
                bad.append('%s.%s is a register and is neither checkpointed nor '
                           'exempt -- doc/checkpoint.md rule 3' % (unit, r))

    # And the other way: a row naming a register that is not there is a rename
    # nobody followed through, which would leave the real one unaccounted for.
    for unit, r in sorted(kept | waived):
        if unit in found and r not in found[unit] and (unit, r) not in PENDING:
            bad.append('%s.%s is in the checkpoint tables and is not a register '
                       'in rtl/rd68031_%s.sv' % (unit, r, unit))

    # A pending register that has arrived is one nobody removed from the list,
    # and the list is what stops it being forgotten.
    for (unit, r), why in sorted(PENDING.items()):
        if unit in found and r in found[unit]:
            bad.append('%s.%s exists now; take it out of PENDING (%s)'
                       % (unit, r, why))
    return bad


def pending_summary():
    return sorted('%s.%s (%s)' % (u, r, w) for (u, r), w in PENDING.items())


def budget():
    """(bits available, bits used, spare words). Reserved words are not spare."""
    words = internal_words(0xB)
    have = len(words) * 16 - (VERSION_HI - VERSION_LO + 1)
    use = sum(bits for _, _, _, _, bits, _ in INTERNAL)
    touched = set()
    for off, hi, lo, name, bits, _ in INTERNAL:
        for w in range((bits + 15) // 16):
            touched.add(off + 2 * w)
    for off, n, _, _ in RESERVED:
        for w in range(n):
            touched.add(off + 2 * w)
    spare = [w for w in words if w not in touched and w != VERSION_OFFSET]
    return have, use, spare


def reserved_bits():
    """The bits RESERVED sets aside for later milestones."""
    return sum(16 * n for _, n, _, _ in RESERVED)
