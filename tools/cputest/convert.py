#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68031
"""Decode a WinUAE cputest data set (DATA_VERSION 24) into per-test records.

    convert.py DIR/MNEMONIC [--limit N] [--json]

DIR is a generated set, e.g. build/spikes/uae030/cputest/data/3_RD030, holding
lmem.dat, tmem.dat (memory images) and one sub-directory per instruction with
0000.dat (merged container: header chunk, then data chunks).

The decoder is a transcription of the reader in Inputs/ref/winuae/cputest/main.c
(test_mnemo, process_test, restore_data, validate_test, validate_exception) for
cpu_lvl >= 1 and no FPU.  Each test is emitted as a dict:

  name, file, test, sub (ccr index), extraccr
  start_pc, end_pc, opcode (instruction words, hex), srcaddr, dstaddr
  init:     {D[8], A[8] (A7 = USP), SR, SSP, MSP}
  mem_init: [(addr, nbytes, value)]    patches over lmem/tmem for this test
                                      (the opcode bytes themselves are in 'opcode')
  expect:   {D[8], A[8], SR, SR_ignore, PC}     or None when the test is skipped
  mem_writes: [(addr, nbytes, old, new)]
  exception: None, or {vector, extra, frame: {PC, format_vector, addr...}}

Runner conventions (main.c): after the instruction the harness places
NOP_OPCODE (0x2048, MOVEA.L A0,A0) + ILLEGAL (0x4AFC), or ILLEGAL first,
alternating per sub-test; normal completion is "exception 4 at end_pc".
"""
import argparse
import json
import os
import struct
import sys

CT_DREG, CT_AREG, CT_SSP, CT_MSP, CT_SR, CT_PC = 0, 8, 16, 17, 18, 19
CT_FPIAR, CT_FPSR, CT_FPCR, CT_EDATA = 20, 21, 22, 23
CT_CYCLES, CT_ENDPC, CT_BRANCHTARGET, CT_SRCADDR, CT_DSTADDR = 25, 26, 27, 28, 29
CT_MEMWRITE, CT_MEMWRITES = 30, 31
CT_DATA_MASK, CT_EXCEPTION_MASK = 31, 63
CT_SIZE_BYTE, CT_SIZE_WORD, CT_SIZE_LONG, CT_SIZE_FPU = 0x00, 0x20, 0x40, 0x60
CT_SIZE_MASK = 0x60
CT_RELATIVE_START_WORD, CT_ABSOLUTE_WORD, CT_ABSOLUTE_LONG = 0x00, 0x20, 0x40
CT_RELATIVE_START_BYTE = CT_PC_BYTES = 0x60
CT_END, CT_END_FINISH, CT_END_INIT = 0x80, 0xFF, 0xC0
CT_END_SKIP, CT_SKIP_REGS, CT_EMPTY = 0xC1, 0xC2, 0xC0
CT_OVERRIDE_REG, CT_BRANCHED = 0xD0, 0x40
DATA_VERSION = 24


def s8(v):
    return v - 0x100 if v & 0x80 else v


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def peek(self):
        return self.d[self.p]

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def u16(self):
        v = (self.d[self.p] << 8) | self.d[self.p + 1]
        self.p += 2
        return v

    def u32(self):
        v = struct.unpack_from(">I", self.d, self.p)[0]
        self.p += 4
        return v

    # restore_value(): partial replacement of the low byte/word, or a long
    def value(self, old):
        mode = self.u8()
        sz = mode & CT_SIZE_MASK
        if sz == CT_SIZE_BYTE:
            return (old & 0xFFFFFF00) | self.u8(), 0
        if sz == CT_SIZE_WORD:
            return (old & 0xFFFF0000) | self.u16(), 1
        if sz == CT_SIZE_LONG:
            return self.u32(), 2
        raise ValueError("FPU value not supported")

    # restore_rel()
    def rel(self, base):
        mode = self.u8() & CT_SIZE_MASK
        if mode == CT_RELATIVE_START_BYTE:
            return (base + s8(self.u8())) & 0xFFFFFFFF
        if mode == CT_RELATIVE_START_WORD:
            return (base + s16(self.u16())) & 0xFFFFFFFF
        if mode == CT_ABSOLUTE_WORD:
            return s16(self.u16()) & 0xFFFFFFFF
        return self.u32()

    def rel_ordered(self, base):
        if self.peek() == CT_EMPTY:
            self.p += 1
            return base
        return self.rel(base)


def chunks(path):
    """Split a merged .dat container (0xAF 'MRG' size data ... size 0)."""
    raw = open(path, "rb").read()
    if raw[:4] != b"\xafMRG":
        yield raw
        return
    off = 0
    while off + 8 <= len(raw) and raw[off:off + 4] == b"\xafMRG":
        size = struct.unpack_from(">I", raw, off + 4)[0]
        if size == 0:
            break
        yield raw[off + 8:off + 8 + size]
        off += 8 + size


def parse_header(h):
    r = Reader(h)
    hd = {}
    if r.u32() != DATA_VERSION:
        raise ValueError("unsupported DATA_VERSION")
    hd["starttime"] = r.u32()
    v = r.u32()
    hd["hmem_rom"], hd["lmem_rom"] = s16(v >> 16), s16(v & 0xFFFF)
    hd["test_memory_start"] = r.u32()
    hd["test_memory_size"] = r.u32()
    hd["opcode_memory_start"] = r.u32()
    v = r.u32()
    hd["cpu_lvl"] = (v >> 16) & 15
    hd["interrupt_mask"] = (v >> 20) & 7
    hd["addressing_mask"] = 0xFFFFFFFF if v & 0x80000000 else 0x00FFFFFF
    hd["interrupttest"] = (v >> 26) & 3
    hd["sr_undefined_mask"] = v & 0xFFFF
    hd["safe_memory_mode"] = (v >> 23) & 7
    v = r.u32()
    hd["initial_interrupt_mask"] = v & 7
    r.u32(), r.u32()
    hd["fpu_model"] = r.u32()
    hd["test_low_memory_start"] = r.u32()
    hd["test_low_memory_end"] = r.u32()
    hd["test_high_memory_start"] = r.u32()
    hd["test_high_memory_end"] = r.u32()
    hd["safe_memory_start"] = r.u32()
    hd["safe_memory_end"] = r.u32()
    hd["user_stack_memory"] = r.u32()
    hd["super_stack_memory"] = r.u32()
    hd["exception_vectors"] = r.u32()
    r.u32(), r.u32(), r.u32()
    hd["inst_name"] = h[r.p:r.p + 16].split(b"\0")[0].decode("ascii", "replace")
    return hd


class Memory:
    """lmem/tmem images plus a sparse overlay."""

    def __init__(self, base, hd):
        self.hd = hd
        self.low = bytearray(open(os.path.join(base, "lmem.dat"), "rb").read()) \
            if os.path.exists(os.path.join(base, "lmem.dat")) else bytearray()
        self.tmem = bytearray(open(os.path.join(base, "tmem.dat"), "rb").read())
        self.tbase = hd["test_memory_start"]

    def _loc(self, a):
        if a < len(self.low):
            return self.low, a
        if self.tbase <= a < self.tbase + len(self.tmem):
            return self.tmem, a - self.tbase
        raise ValueError("address %08x outside test memory" % a)

    def write(self, a, n, v):
        for i in range(n):
            buf, o = self._loc(a + i)
            buf[o] = (v >> (8 * (n - 1 - i))) & 0xFF

    def read(self, a, n):
        out = bytearray()
        for i in range(n):
            buf, o = self._loc(a + i)
            out.append(buf[o])
        return bytes(out)


def mem_addr(r, hd):
    """get_memory_addr(): returns a CPU address."""
    mode = r.u8() & CT_SIZE_MASK
    if mode == CT_ABSOLUTE_WORD:
        off = s16(r.u16())
        return off & 0xFFFFFFFF  # negative = high memory 0xFFFF8000+
    if mode == CT_ABSOLUTE_LONG:
        return r.u32()
    if mode == CT_RELATIVE_START_WORD:
        return (hd["opcode_memory_start"] + s16(r.u16())) & 0xFFFFFFFF
    raise ValueError("bad memory address mode")


def mem_record(r, hd):
    """CT_MEMWRITE: address, old value, new value (size from the encoding)."""
    a = mem_addr(r, hd)
    old, _ = r.value(0)
    new, size = r.value(0)
    return a, 1 << size, old, new


def opcode_bytes(r, mem, hd):
    """CT_MEMWRITES|CT_PC_BYTES: bytes at opcode_memory_start + offset."""
    r.u8()
    if r.peek() == 0xFF:
        r.u8()
        off, ln = r.u8(), r.u8()
        ln = ln or 256
    else:
        v = r.u8()
        off, ln = v >> 5, (v & 31) or 32
    base = hd["opcode_memory_start"] + off
    for i in range(ln):
        mem.write(base + i, 1, r.u8())


def parse_exception(r, hd, exc, state):
    """validate_exception() for cpu_lvl > 0.  Returns a dict."""
    start = r.p
    n = r.u8()
    out = {"vector": exc}
    if n == 0:
        return out
    if n == 0xFF:
        out.update(state.get("last_exc", {}))
        out["same_as_previous"] = True
        out["vector"] = exc
        return out
    extra = r.u8()
    if extra & 0x40:
        out["group2_with_1"] = r.u8()
        extra &= ~0x40
    out["extra"] = extra
    om = hd["opcode_memory_start"]
    if extra & 0x80:
        out["trace_sr"] = r.u16()
        out["trace_pc"] = r.rel_ordered(om)
    if exc != 1:
        fr = {"PC": r.rel_ordered(om), "format_vector": r.u16()}
        fmt = fr["format_vector"] >> 12
        if fmt in (2, 3):
            fr["addr"] = r.rel_ordered(om)
            if fmt == 3 or exc in (11, 55):
                fr["fpeaset"] = r.u8() & 1
        elif fmt == 4:
            fr["addr"] = r.rel_ordered(om)
            fr["addr2"] = r.rel_ordered(om)
            fr["fpeaset"] = r.u8() & 1
        elif fmt == 8:
            fr["PC2"] = r.rel_ordered(om)
            fr["SSW"] = r.u16()
            fr["fault"] = r.rel_ordered(om)
            fr["dout"], fr["din"], fr["insn"], fr["din_prev"] = r.u16(), r.u16(), r.u16(), r.u16()
        elif fmt in (0xA, 0xB):
            pass  # 68020/030 bus/address error: only the first 8 bytes are recorded
        elif fmt != 0:
            raise ValueError("unknown frame %04x" % fr["format_vector"])
        out["frame"] = fr
    if r.p != start + n + 1:
        raise ValueError("exception data length mismatch")
    state["last_exc"] = {k: v for k, v in out.items() if k != "vector"}
    return out


def decode(setdir, mnemonic, limit=None):
    path = os.path.join(setdir, mnemonic, "0000.dat")
    it = chunks(path)
    hd = parse_header(next(it))
    if hd["cpu_lvl"] < 1 or hd["fpu_model"]:
        raise SystemExit("only cpu_lvl >= 1 without FPU is decoded")
    mem = Memory(setdir, hd)
    count = 0
    state = {}
    for ci, data in enumerate(it):
        r = Reader(data)
        if r.u32() != DATA_VERSION or r.u32() != hd["starttime"]:
            raise ValueError("chunk header mismatch")
        r.u32(), r.u32()
        cur = {"regs": [0] * 16, "sr": hd["interrupt_mask"] << 8, "pc": hd["opcode_memory_start"],
               "endpc": hd["opcode_memory_start"], "srcaddr": 0xFFFFFFFF, "dstaddr": 0xFFFFFFFF,
               "branchtarget": 0xFFFFFFFF}
        startpc = endpc = hd["opcode_memory_start"]
        test_no = 0
        while True:
            cur["endpc"], cur["pc"] = endpc, startpc
            hist = []  # memory set-up, rolled back after the test
            # ---- restore_data() stream up to CT_END_INIT ----
            while r.peek() not in (CT_END_INIT, CT_END_FINISH):
                v = r.peek()
                mode = v & CT_DATA_MASK
                if mode < CT_AREG + 8:
                    cur["regs"][mode], _ = r.value(cur["regs"][mode])
                elif mode == CT_SR:
                    cur["sr"], _ = r.value(cur["sr"])
                elif mode in (CT_PC, CT_ENDPC, CT_SRCADDR, CT_DSTADDR):
                    key = {CT_PC: "pc", CT_ENDPC: "endpc", CT_SRCADDR: "srcaddr", CT_DSTADDR: "dstaddr"}[mode]
                    cur[key], _ = r.value(cur[key])
                elif mode == CT_BRANCHTARGET:
                    cur["branchtarget"], _ = r.value(cur["branchtarget"])
                    cur["branchtarget_mode"] = r.u8()
                elif mode == CT_MEMWRITE:
                    a, size, old, new = mem_record(r, hd)
                    hist.append((a, size, old, new))
                    mem.write(a, size, new)
                elif mode == CT_MEMWRITES:
                    opcode_bytes(r, mem, hd)
                elif mode == CT_EDATA:
                    r.u8(), r.u8(), r.u8()
                elif mode == CT_CYCLES:
                    r.value(0)
                else:
                    raise ValueError("unexpected init item %02x at %d" % (v, r.p))
            if r.u8() == CT_END_FINISH:
                break
            startpc, endpc = cur["pc"], cur["endpc"]
            lregs = {"regs": list(cur["regs"]), "sr": cur["sr"], "pc": cur["pc"]}
            extraccr = 0
            while True:
                sr_mask = ((0x2000 if extraccr & 1 else 0) | (0x4000 if extraccr & 2 else 0) |
                           (0x8000 if extraccr & 4 else 0) | (0x1000 if extraccr & 8 else 0))
                ccrmode = r.u8()
                maxccr = ccrmode & 0x3F
                for ccrcnt in range(maxccr):
                    ccr = ccrcnt & (maxccr - 1)
                    if maxccr >= 32:
                        sr = ccr & 0xFF
                    else:
                        sr = 31 if ccr & 1 else 0
                    sr |= sr_mask | (hd["initial_interrupt_mask"] << 8)
                    test_regs = list(cur["regs"])
                    if hd["interrupttest"] == 1:
                        r.u8()
                    while r.peek() == CT_OVERRIDE_REG:
                        r.u8()
                        v = r.u8()
                        reg, size = v & CT_DATA_MASK, v & CT_SIZE_MASK
                        if reg == CT_SR:
                            sr = (sr & 0xFF00) | r.u8() if size == CT_SIZE_BYTE else r.u16()
                        elif reg < 16:
                            cur["regs"][reg] = r.u32()  # main.c: affects cur_regs only
                        else:
                            r.u32()
                    cur["sr"] = sr
                    if not sr_mask and not ccr:
                        lregs["sr"] = sr
                    rec = {
                        "name": hd["inst_name"], "file": path, "chunk": ci, "test": test_no,
                        "sub": ccrcnt, "extraccr": extraccr,
                        "start_pc": startpc, "end_pc": endpc,
                        "opcode": mem.read(startpc, max(0, endpc - startpc)).hex(),
                        "srcaddr": cur["srcaddr"], "dstaddr": cur["dstaddr"],
                        "init": {"D": test_regs[:8], "A": test_regs[8:], "SR": sr,
                                 "SSP": (hd["super_stack_memory"] - 0x80) & 0xFFFFFFFF,
                                 "MSP": hd["super_stack_memory"]},
                        "mem_init": [(a, s, n) for (a, s, o, n) in hist],
                        "expect": None, "mem_writes": [], "exception": None,
                    }
                    if r.peek() == CT_END_SKIP:
                        r.u8()
                    else:
                        # ---- validate_test() stream up to CT_END|exc ----
                        skip_regs = False
                        while True:
                            v = r.peek()
                            if v == CT_SKIP_REGS:
                                r.u8()
                                skip_regs = True
                                continue
                            if v & CT_END:
                                r.u8()
                                exc = v & CT_EXCEPTION_MASK
                                rec["branched"] = bool(v & CT_BRANCHED)
                                if exc:
                                    rec["exception"] = parse_exception(r, hd, exc, state)
                                break
                            mode = v & CT_DATA_MASK
                            if mode < CT_AREG + 8:
                                lregs["regs"][mode], _ = r.value(lregs["regs"][mode])
                            elif mode == CT_SR:
                                lregs["sr"], _ = r.value(lregs["sr"])
                            elif mode == CT_PC:
                                lregs["pc"] = r.rel(lregs["pc"])
                            elif mode == CT_CYCLES:
                                r.value(0)
                            elif mode == CT_MEMWRITE:
                                rec["mem_writes"].append(mem_record(r, hd))
                            elif mode == CT_MEMWRITES:
                                opcode_bytes(r, mem, hd)
                            else:
                                raise ValueError("unexpected result item %02x at %d" % (v, r.p))
                        rec["expect"] = {"D": lregs["regs"][:8], "A": lregs["regs"][8:],
                                         "SR": lregs["sr"] & 0xFFFF,
                                         "SR_ignore": (lregs["sr"] >> 16) & 0xFFFF,
                                         "PC": lregs["pc"], "skip_regs": skip_regs}
                    yield rec
                    count += 1
                    if limit and count >= limit:
                        return
                if r.peek() == CT_END:
                    r.u8()
                    break
                extraccr = r.u8()
            # roll back the memory set-up (restoreahist)
            for a, size, old, new in reversed(hist):
                mem.write(a, size, old)
            test_no += 1


def fmt_rec(t):
    h = lambda v: "%08x" % v
    s = ["%s chunk%d test%d sub%d x%d pc=%08x op=%s" % (t["name"], t["chunk"], t["test"], t["sub"],
                                                       t["extraccr"], t["start_pc"], t["opcode"])]
    i = t["init"]
    s.append("  in : SR=%04x D=%s A=%s" % (i["SR"], " ".join(map(h, i["D"])), " ".join(map(h, i["A"]))))
    if t["mem_init"]:
        s.append("  mem: " + " ".join("%08x.%d=%x" % m for m in t["mem_init"]))
    e = t["expect"]
    if e is None:
        s.append("  (skipped)")
    else:
        s.append("  out: SR=%04x(ign %04x) PC=%08x D=%s A=%s" % (e["SR"], e["SR_ignore"], e["PC"],
                                                                 " ".join(map(h, e["D"])), " ".join(map(h, e["A"]))))
        for a, sz, o, n in t["mem_writes"]:
            s.append("  wr : %08x.%d %x -> %x" % (a, sz, o, n))
        if t["exception"]:
            s.append("  exc: %s" % json.dumps(t["exception"]))
    return "\n".join(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="data/<lvl>_<name> directory")
    ap.add_argument("mnemonic", help="sub-directory, e.g. ADD.L")
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--json", action="store_true", help="one JSON object per line")
    ap.add_argument("--header", action="store_true", help="print the set header")
    a = ap.parse_args()
    if a.header:
        print(json.dumps(parse_header(next(chunks(os.path.join(a.set, a.mnemonic, "0000.dat")))), indent=1))
    for t in decode(a.set, a.mnemonic, a.limit or None):
        print(json.dumps(t) if a.json else fmt_rec(t))


if __name__ == "__main__":
    main()
