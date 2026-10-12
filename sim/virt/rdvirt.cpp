// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68031

// rd-virt -- the deterministic m68k `virt` machine, with the RTL, the UAE030
// oracle, or both in lockstep (doc/plan.md Layer 3, doc/virt.md).
//
//   rdvirt --cpu uae|rtl|lockstep  (--kernel vmlinux [--initrd f] [--cmdline s]
//                                   | --bare prog.elf) [options]
//
// The lockstep: the RTL leads. After each of its steps the oracle takes the
// same step -- an interrupt the RTL acknowledged is taken by the oracle at the
// same boundary -- and the two are compared: every register, and the stream
// of physical writes. Each side has its own machine; both are told the same
// time at every boundary, so their devices agree without being shared.
//
// Linked with the GPL oracle, hence GPL-2.0-or-later.

#include <sys/time.h>

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <algorithm>
#include <map>
#include <set>
#include <memory>
#include <string>
#include <vector>

#include "cpu_if.h"
#include "cpu_uae.h"
#include "machine.h"
#ifdef RDVIRT_RTL
#include "cpu_rtl.h"
#endif

namespace {

struct Options {
  std::string cpu = "uae";
  std::string kernel, initrd, cmdline, bare, script, dump = "rdvirt-divergence.txt";
  std::vector<std::string> expect;
  MachineConfig mc;
  uint64_t max_steps = 0;            // 0: no limit
  uint64_t progress = 10000000;
  bool dcache = true;
  int icache = 1;
  // lockstep
  bool accept_link_a7 = false;
  bool accept_rte_restart = true;
  bool accept_posted_fault = true;
  bool uae_short_frames = false;
  bool accept_ssw_x = true;
  bool align_frames = true;
  bool accept_fault_an = true;     // lockstep: An of a faulted (An)+/-(An) (c7)       // lockstep: the core's SSW and stage B in the oracle's frame       // lockstep: SSW internal bits in copies (c6)  // lockstep: the oracle stacks $B as the core does
  bool compare_writes = true;
  int maxdiv = 1;
  uint64_t window = 64;
  uint64_t dump_at = 0;
  uint64_t trace_from = UINT64_MAX;  // print every boundary from this step          // dump both buses at this step and stop
#ifdef RDVIRT_RTL
  RtlOptions rtl;
#endif
};

double wall() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return tv.tv_sec + tv.tv_usec * 1e-6;
}

// ---------------------------------------------------------------------------
// The console script: `expect <text>` waits for the text to appear in the
// console after the last match, `send <text>` types it (\n, \r, \t escapes).
// ---------------------------------------------------------------------------
struct Script {
  struct Item { bool send; std::string text; };
  std::vector<Item> items;
  size_t pos = 0, seen = 0;
  bool load(const std::string &path) {
    FILE *f = fopen(path.c_str(), "r");
    if (!f) return false;
    char line[4096];
    while (fgets(line, sizeof line, f)) {
      std::string l(line);
      while (!l.empty() && (l.back() == '\n' || l.back() == '\r')) l.pop_back();
      if (l.empty() || l[0] == '#') continue;
      bool send = l.compare(0, 5, "send ") == 0;
      bool exp = l.compare(0, 7, "expect ") == 0;
      if (!send && !exp) continue;
      std::string t = l.substr(send ? 5 : 7), u;
      for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == '\\' && i + 1 < t.size()) {
          char c = t[++i];
          u.push_back(c == 'n' ? '\n' : c == 'r' ? '\r' : c == 't' ? '\t' : c);
        } else {
          u.push_back(t[i]);
        }
      }
      items.push_back({send, u});
    }
    fclose(f);
    return true;
  }
  // What to type now, given the console so far.
  std::string poll(const std::string &cons) {
    std::string out;
    while (pos < items.size()) {
      Item &it = items[pos];
      if (it.send) { out += it.text; pos++; continue; }
      size_t at = cons.find(it.text, seen);
      if (at == std::string::npos) break;
      seen = at + it.text.size();
      pos++;
    }
    return out;
  }
  bool done() const { return pos >= items.size(); }
};

// ---------------------------------------------------------------------------
// Register comparison, under the bits UM 9.7 gives the MMU's registers (the
// oracle keeps every bit written; doc/oracles.md).
// ---------------------------------------------------------------------------
std::string fmt_regs(const CpuRegs &r) {
  char b[1024];
  snprintf(b, sizeof b,
           "PC %08x SR %04x%s\n"
           "D  %08x %08x %08x %08x %08x %08x %08x %08x\n"
           "A  %08x %08x %08x %08x %08x %08x %08x %08x\n"
           "USP %08x ISP %08x MSP %08x VBR %08x SFC %x DFC %x CACR %08x CAAR %08x\n"
           "TC %08x CRP %016" PRIx64 " SRP %016" PRIx64 " TT0 %08x TT1 %08x MMUSR %04x\n",
           r.pc, r.sr, r.stopped ? " (stopped)" : "", r.d[0], r.d[1], r.d[2], r.d[3],
           r.d[4], r.d[5], r.d[6], r.d[7], r.a[0], r.a[1], r.a[2], r.a[3], r.a[4], r.a[5],
           r.a[6], r.a[7], r.usp, r.isp, r.msp, r.vbr, r.sfc, r.dfc, r.cacr, r.caar, r.tc,
           r.crp, r.srp, r.tt0, r.tt1, r.mmusr);
  return b;
}

struct AnPair { int reg; uint32_t rtl, uae, frame; };
// `ssw_pairs`: inside a bus fault handler, a data or address register may hold
// a copy of the frame's SSW, whose internal-use bits (UM figure 8-9: 11-9) are
// each implementation's own (doc/m11-mismatches.md c6); the two SSWs of each
// live frame, recorded when it is stacked, are accepted in a register's low
// word.
// `an_pairs`: address register values the two hold for one live bus fault --
// the core's and the oracle's, recorded where the fault is taken -- accepted
// for as long as the frame is live (doc/m13-mismatches.md c7).
[[maybe_unused]] std::vector<std::string> compare(const CpuRegs &a, const CpuRegs &b,
                                                  bool ssw_x = false, int *accepted = nullptr,
                                                  const std::vector<AnPair> *an_pairs = nullptr,
                                                  const std::vector<AnPair> *ssw_pairs = nullptr) {
  std::vector<std::string> why;
  char s[160];
  auto chk = [&](const char *n, uint64_t x, uint64_t y) {
    bool is_an = n[0] == 'A' && n[1] >= '0' && n[1] <= '6';
    bool is_usp = n[0] == 'U' && n[1] == 'S';
    if (x != y && an_pairs && (is_an || is_usp)) {
      int reg = is_usp ? 7 : n[1] - '0';
      for (const AnPair &p : *an_pairs)
        if (p.reg == reg && p.rtl == x && p.uae == y) {
          if (accepted) ++*accepted;
          return;
        }
    }
    if (x != y && ssw_x && ssw_pairs && (n[0] == 'D' || n[0] == 'A') && n[1] >= '0' && n[1] <= '7' &&
        (x >> 16) == (y >> 16)) {
      for (const AnPair &p : *ssw_pairs)
        if ((x & 0xFFFF) == p.rtl && (y & 0xFFFF) == p.uae) {
          if (accepted) ++*accepted;
          return;
        }
    }
    if (x != y) {
      snprintf(s, sizeof s, "%s: rtl %08" PRIx64 " uae %08" PRIx64, n, x, y);
      why.push_back(s);
    }
  };
  chk("PC", a.pc, b.pc);
  chk("SR", a.sr, b.sr);
  static const char *dn[] = {"D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7"};
  static const char *an[] = {"A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7"};
  for (int i = 0; i < 8; i++) chk(dn[i], a.d[i], b.d[i]);
  for (int i = 0; i < 8; i++) chk(an[i], a.a[i], b.a[i]);
  chk("USP", a.usp, b.usp);
  chk("ISP", a.isp, b.isp);
  chk("MSP", a.msp, b.msp);
  chk("VBR", a.vbr, b.vbr);
  chk("SFC", a.sfc, b.sfc);
  chk("DFC", a.dfc, b.dfc);
  chk("CACR", a.cacr, b.cacr);
  chk("CAAR", a.caar, b.caar);
  chk("TC", a.tc & 0x83FFFFFFu, b.tc & 0x83FFFFFFu);
  chk("CRP", a.crp & 0xFFFF0003FFFFFFF0ull, b.crp & 0xFFFF0003FFFFFFF0ull);
  chk("SRP", a.srp & 0xFFFF0003FFFFFFF0ull, b.srp & 0xFFFF0003FFFFFFF0ull);
  chk("TT0", a.tt0 & 0xFFFF8777u, b.tt0 & 0xFFFF8777u);
  chk("TT1", a.tt1 & 0xFFFF8777u, b.tt1 & 0xFFFF8777u);
  chk("MMUSR", a.mmusr & 0xEE47u, b.mmusr & 0xEE47u);
  return why;
}

// ---------------------------------------------------------------------------
// The write stream, cut into bytes. Each byte address keeps, per side, the
// values written to it in order, and the two queues are matched front to
// front. Two things make a strict comparison wrong:
//   - a write may land on the RTL's bus a step late (a posted write still in
//     flight at the boundary, doc/checkpoint.md rule 9), so a value has
//     `window` steps to appear on the other side;
//   - a value one side writes and then overwrites may never be written by
//     the other (a table search updating a descriptor's U and then its M,
//     where the other sets both at once): when the fronts differ and one
//     side's front appears further down the other's queue, the other's
//     earlier values were overwritten, and are dropped.
// The final value of every byte, and the order of the values that survive,
// are compared. Exception frames are not compared byte for byte: their
// internal words are the implementation's (UM 8.4).
// ---------------------------------------------------------------------------
struct WriteStream {
  // `alt`: another value the byte may match -- for an oracle write of a
  // register value the two hold differently for a live fault (c6, c7), the
  // core's.
  struct Pend { uint64_t step; uint8_t val; int alt; };
  // `last`: the value both sides agree the byte holds. A write of that same
  // value again on one side only (the oracle re-running an instruction a
  // fault interrupted rewrites what it had already written, b8) changes
  // nothing, and is dropped.
  struct Q { std::deque<Pend> r, u; int last = -1; };
  uint64_t repeats = 0;
  // The agreed values of bytes with nothing pending.
  std::map<uint32_t, std::pair<uint8_t, uint64_t>> recent;
  uint64_t now_step = 0, matches = 0;
  uint64_t window = 64;
  // The last step at which either side took a bus fault or the oracle re-ran
  // an instruction, set by the driver, to tell the repeats b5 explains (near
  // one) from any other.
  uint64_t last_fault_step = 0;
  uint64_t repeats_far = 0;
  std::vector<std::string> far_examples;
  void note_repeat(uint32_t a, const Pend &p, bool rtl) {
    repeats++;
    if (p.step > last_fault_step + 5000) {
      repeats_far++;
      if (far_examples.size() < 16) {
        char b[128];
        snprintf(b, sizeof b, "%s byte %08x value %02x step %" PRIu64 " (last fault/restart %" PRIu64 ")",
                 rtl ? "rtl" : "uae", a, p.val, p.step, last_fault_step);
        far_examples.push_back(b);
      }
    }
  }
  uint64_t accepted = 0;
  // Two bytes match when equal -- or, written while a bus fault frame was
  // live, when they differ only where an SSW's internal-use bits would be.
  bool same(const Pend &a, const Pend &b) {
    if (a.val == b.val) return true;
    if ((a.alt >= 0 && a.alt == b.val) || (b.alt >= 0 && b.alt == a.val)) { accepted++; return true; }
    return false;
  }
  std::map<uint32_t, Q> q;
  std::vector<uint32_t> touched;
  int64_t watch = getenv("RDVIRT_WATCH") ? int64_t(strtoul(getenv("RDVIRT_WATCH"), nullptr, 16)) : -1;
  // alts[k]: for the k-th record, the whole alternative value, or -1.
  void add(bool rtl, const std::vector<BusRec> &w, uint64_t step, uint32_t skip_lo,
           uint32_t skip_hi, const std::vector<int64_t> *alts = nullptr) {
    for (size_t k = 0; k < w.size(); k++) {
      const BusRec &r = w[k];
      int64_t altv = alts ? (*alts)[k] : -1;
      if (r.kind == 'I') continue;
      for (int i = 0; i < r.size; i++) {
        uint32_t a = r.addr + i;
        if (a >= skip_lo && a < skip_hi) continue;
        uint8_t v = uint8_t(r.data >> (8 * (r.size - 1 - i)));
        now_step = step;
        auto ins = q.emplace(a, Q());
        Q &e = ins.first->second;
        if (ins.second) {
          auto rc = recent.find(a);
          if (rc != recent.end()) e.last = rc->second.first;
        }
        int alt = altv < 0 ? -1 : int(uint8_t(uint64_t(altv) >> (8 * (r.size - 1 - i))));
        (rtl ? e.r : e.u).push_back({step, v, alt});
        if (int64_t(a) == watch)
          fprintf(stderr, "watch %08x: %s writes %02x at step %" PRIu64 "\n", a, rtl ? "rtl" : "uae", v, step);
        touched.push_back(a);
      }
    }
  }
  bool drop_to(std::deque<Pend> &d, const Pend &v) {
    for (size_t k = 1; k < d.size(); k++)
      if (same(d[k], v)) { d.erase(d.begin(), d.begin() + k); return true; }
    return false;
  }
  void match() {
    for (uint32_t a : touched) {
      auto it = q.find(a);
      if (it == q.end()) continue;
      Q &e = it->second;
      while (!e.r.empty() && !e.u.empty()) {
        if (same(e.r.front(), e.u.front())) {
          e.last = e.r.front().val;
          e.r.pop_front(); e.u.pop_front();
          continue;
        }
        if (e.u.front().val == e.last) { note_repeat(a, e.u.front(), false); e.u.pop_front(); continue; }
        if (e.r.front().val == e.last) { note_repeat(a, e.r.front(), true); e.r.pop_front(); continue; }
        if (drop_to(e.u, e.r.front())) continue;
        if (drop_to(e.r, e.u.front())) continue;
        break;
      }
      // Lone repeats of the agreed value -- only once the other side has had
      // the whole window to write it too, so that an ordinary rewrite of the
      // same value, one side a step behind the other, pairs as usual.
      while (!e.u.empty() && e.r.empty() && e.u.front().val == e.last &&
             e.u.front().step + window < now_step) { note_repeat(a, e.u.front(), false); e.u.pop_front(); }
      while (!e.r.empty() && e.u.empty() && e.r.front().val == e.last &&
             e.r.front().step + window < now_step) { note_repeat(a, e.r.front(), true); e.r.pop_front(); }
      if (e.r.empty() && e.u.empty()) {
        if (e.last >= 0) recent[a] = {uint8_t(e.last), now_step};
        q.erase(it);
      }
    }
    touched.clear();
    // A fault handler may run for a long time between a write and the
    // instruction's re-run, so the agreed values are kept 200,000 steps.
    if (++matches % 4096 == 0)
      for (auto it = recent.begin(); it != recent.end();)
        it = (it->second.second + 200000 < now_step) ? recent.erase(it) : std::next(it);
  }
  // Bytes unmatched for longer than the window.
  std::vector<std::string> stale(uint64_t step, uint64_t window) {
    std::vector<std::string> out;
    char s[160];
    now_step = step;
    for (auto it = q.begin(); it != q.end();) {
      Q &e = it->second;
      while (!e.u.empty() && e.r.empty() && e.u.front().val == e.last &&
             e.u.front().step + window < step) { note_repeat(it->first, e.u.front(), false); e.u.pop_front(); }
      while (!e.r.empty() && e.u.empty() && e.r.front().val == e.last &&
             e.r.front().step + window < step) { note_repeat(it->first, e.r.front(), true); e.r.pop_front(); }
      if (e.r.empty() && e.u.empty()) {
        if (e.last >= 0) recent[it->first] = {uint8_t(e.last), step};
        it = q.erase(it);
      } else {
        ++it;
      }
    }
    for (auto &p : q) {
      const Q &e = p.second;
      const Pend *r = e.r.empty() ? nullptr : &e.r.front();
      const Pend *u = e.u.empty() ? nullptr : &e.u.front();
      if (!((r && step > r->step + window) || (u && step > u->step + window))) continue;
      if (r && u)
        snprintf(s, sizeof s, "byte %08x: rtl wrote %02x (step %" PRIu64 "), uae %02x (step %" PRIu64 ")",
                 p.first, r->val, r->step, u->val, u->step);
      else if (r)
        snprintf(s, sizeof s, "byte %08x: rtl wrote %02x (step %" PRIu64 "), uae did not",
                 p.first, r->val, r->step);
      else
        snprintf(s, sizeof s, "byte %08x: uae wrote %02x (step %" PRIu64 "), rtl did not",
                 p.first, u->val, u->step);
      out.push_back(s);
      if (out.size() >= 32) break;
    }
    return out;
  }
};

// One processor on one machine: virt-uae, virt-linux-solo, virt-bare.
int run_solo(Options &o, CpuIf &cpu, Machine &m) {
  Script sc;
  if (!o.script.empty() && !sc.load(o.script)) {
    fprintf(stderr, "rd-virt: cannot read %s\n", o.script.c_str());
    return 2;
  }
  double t0 = wall();
  uint64_t skip = 0;
  StepResult r = cpu.reset();
  uint64_t next_prog = o.progress;
  uint64_t idle_skips = 0;
  while (r != StepResult::Halted && !m.powered_off) {
    r = cpu.run_until_retire();
    if (r == StepResult::Halted) break;
    if (r == StepResult::Stopped) {
      uint64_t t = m.next_event();
      if (t == UINT64_MAX) {
        // Nothing will ever wake it, unless the script types something.
        std::string in = sc.poll(m.console());
        if (in.empty()) { fprintf(stderr, "rd-virt: stopped with nothing armed\n"); break; }
        m.tty_input(in);
      } else if (t > m.now()) {
        skip += t - m.now();
        idle_skips++;
        m.set_time(t);
      }
      cpu.set_ipl(m.ipl());
      continue;
    }
    uint64_t n = cpu.retired();
    if (n >= o.trace_from) {
      const CpuRegs &g = cpu.regs();
      fprintf(stderr, "%10" PRIu64 " %08x %04x d %08x %08x %08x %08x a %08x %08x %08x %08x%s\n", n,
              g.pc, g.sr, g.d[0], g.d[1], g.d[2], g.d[3], g.a[0], g.a[1], g.a[5], g.a[7],
              cpu.last_iack() ? " IRQ" : "");
    }
    m.set_time(n * o.mc.ns_per_step + skip);
    std::string in = sc.poll(m.console());
    if (!in.empty()) m.tty_input(in);
    cpu.set_ipl(m.ipl());
    m.step_writes.clear();
    if (o.progress && n >= next_prog) {
      double dt = wall() - t0;
      fprintf(stderr, "[%s] %" PRIu64 " steps, %.1f s, %.0f steps/s, virtual %.3f s, pc %08x\n",
              cpu.name(), n, dt, n / dt, m.now() * 1e-9, cpu.regs().pc);
      next_prog += o.progress;
    }
    if (o.max_steps && n >= o.max_steps) {
      fprintf(stderr, "rd-virt: step limit reached\n");
      break;
    }
  }
  double dt = wall() - t0;
  uint64_t n = cpu.retired();
  fprintf(stderr, "[%s] end: %" PRIu64 " steps in %.1f s (%.0f steps/s), virtual %.3f s, "
          "%" PRIu64 " idle skips, %s\n",
          cpu.name(), n, dt, n / (dt > 0 ? dt : 1), m.now() * 1e-9, idle_skips,
          r == StepResult::Halted ? "HALTED"
          : m.panicked ? "virt-ctrl PANIC"
          : m.powered_off ? "powered off" : "stopped");
  if (r == StepResult::Halted || !m.powered_off) {
    fprintf(stderr, "%s", fmt_regs(cpu.regs()).c_str());
    m.dump_ring(stderr, getenv("RDVIRT_RING") ? atoi(getenv("RDVIRT_RING")) : 32);
  }
  bool ok = m.powered_off && !m.panicked;
  for (const std::string &e : o.expect)
    if (m.console().find(e) == std::string::npos) {
      fprintf(stderr, "rd-virt: console never showed \"%s\"\n", e.c_str());
      ok = false;
    }
  if (!sc.done()) { fprintf(stderr, "rd-virt: the script did not finish\n"); ok = false; }
  printf("%s: rd-virt %s, %" PRIu64 " steps\n", ok ? "PASS" : "FAIL", cpu.name(), n);
  return ok ? 0 : 1;
}

#ifdef RDVIRT_RTL
int run_lockstep(Options &o, RtlCpu &rtl, Machine &mr, UaeCpu &uae, Machine &mu) {
  Script sc;
  if (!o.script.empty() && !sc.load(o.script)) {
    fprintf(stderr, "rd-virt: cannot read %s\n", o.script.c_str());
    return 2;
  }
  uae.set_follower(true);
  // doc/checkpoint.md: the core stacks the long bus fault frame for every
  // fault; the oracle, by default, the short one for a fault on a last write.
  // With the short one the two stacks are 60 bytes apart through the handler
  // (doc/m11-mismatches.md c4), and every stack address with them.
  UaeCpu::set_short_frames(o.uae_short_frames);
  double t0 = wall();
  uint64_t skip = 0, next_prog = o.progress, restarts = 0, accepted = 0, posted = 0;
  StepResult rr = rtl.reset();
  StepResult ru = uae.reset();
  // A reset defines the status register, VBR and CACR and the MMU's E bits
  // (UM 8.1, 9.2.2); the rest is whatever it was. The oracle takes the RTL's.
  uae.set_undefined(rtl.regs());
  WriteStream ws;
  ws.window = o.window;
  uint64_t ssw_steps = 0, poke_fail = 0;
  std::vector<std::pair<uint32_t, uint32_t>> frame_regions;  // every $B frame stacked
  std::set<uint32_t> live_frames;   // the stack addresses of live $B frames
  int ssw_regs = 0;
  uint64_t frames_aligned = 0, an_writes = 0, ssw_writes = 0;
  std::vector<AnPair> an_pairs, ssw_pairs;
  mr.step_writes.clear();
  mu.step_writes.clear();
  int ndiv = 0;
  FILE *dump = nullptr;
  auto diverge = [&](const char *what, const std::vector<std::string> &why) {
    if (!dump) dump = fopen(o.dump.c_str(), "w");
    FILE *outs[2] = {stderr, dump};
    for (FILE *f : outs) {
      if (!f) continue;
      fprintf(f, "DIVERGENCE (%s) at step %" PRIu64 ", virtual time %" PRIu64 " ns\n", what,
              rtl.retired(), mr.now());
      for (auto &w : why) fprintf(f, "  %s\n", w.c_str());
      fprintf(f, "RTL:\n%sUAE030 (last opcode %04x):\n%s", fmt_regs(rtl.regs()).c_str(),
              uae.last_opcode() & 0xFFFF, fmt_regs(uae.regs()).c_str());
    }
    for (FILE *f : outs) {
      if (!f) continue;
      for (const AnPair &p : an_pairs)
        fprintf(f, "  live An pair: reg %d rtl %08x uae %08x frame %08x\n", p.reg, p.rtl, p.uae, p.frame);
      for (const AnPair &p : ssw_pairs)
        fprintf(f, "  live SSW pair: rtl %04x uae %04x frame %08x\n", p.rtl, p.uae, p.frame);
      for (uint32_t fr : live_frames) fprintf(f, "  live frame at %08x\n", fr);
    }
    if (dump) {
      fprintf(dump, "--- RTL bus, last 4096 transfers\n");
      mr.dump_ring(dump);
      fprintf(dump, "--- UAE030 bus, last 4096 accesses\n");
      mu.dump_ring(dump);
      fflush(dump);
    }
    ndiv++;
  };
  while (rr != StepResult::Halted && ru != StepResult::Halted && !mr.powered_off) {
    rr = rtl.run_until_retire();
    if (rr == StepResult::Halted) break;
    if (rr == StepResult::Stopped) {
      uint64_t t = mr.next_event();
      if (t == UINT64_MAX) {
        std::string in = sc.poll(mr.console());
        if (in.empty()) { fprintf(stderr, "rd-virt: stopped with nothing armed\n"); break; }
        mr.tty_input(in);
        mu.tty_input(in);
      } else if (t > mr.now()) {
        skip += t - mr.now();
        mr.set_time(t);
        mu.set_time(t);
      }
      rtl.set_ipl(mr.ipl());
      continue;
    }
    int lvl = rtl.last_iack();
    if (lvl) uae.inject_interrupt(lvl);
    // An RTE about to pop a long bus fault frame ends that fault.
    bool rte_b = false;
    uint32_t rte_sp = uae.regs().a[7];
    if (!lvl && uae.next_opcode() == 0x4E73)
      rte_b = rte_sp + 8 <= mu.ram_size && (mu.ram[rte_sp + 6] >> 4) == 0xB;
    ru = uae.run_until_retire();
    if (rte_b) {
      live_frames.erase(rte_sp);
      for (std::vector<AnPair> *v : {&an_pairs, &ssw_pairs})
        v->erase(std::remove_if(v->begin(), v->end(),
                                [&](const AnPair &p) { return p.frame == rte_sp; }),
                 v->end());
    }
    if (ru == StepResult::Halted) break;
    uint64_t n = rtl.retired();
    // A bus fault frame is live from the step that stacks it until the
    // stack pointer is back above it (its RTE), or the processor is in user
    // mode.
    // Live faults: one more at each long frame stacked (below), one fewer at
    // each RTE that pops one (above). A fault handler may sleep and the
    // processor run other tasks on other stacks meanwhile, so it is counted,
    // not judged from the stack pointer.
    // A bus fault taken in the middle of an instruction with (An)+ or -(An):
    // the oracle has already moved An (and undoes it at its RTE, b8), the
    // core moves it when the instruction completes after its RTE. Recorded at
    // the fault, when the difference is an operand's size or two.
    // A pair is over once the core has completed the interrupted instruction
    // -- its register holds the oracle's value -- whether or not the RTE that
    // ended the fault was seen.
    an_pairs.erase(std::remove_if(an_pairs.begin(), an_pairs.end(),
                                  [&](const AnPair &p) {
                                    uint32_t x = p.reg < 7 ? rtl.regs().a[p.reg] : rtl.regs().usp;
                                    return x == p.uae;
                                  }),
                   an_pairs.end());
    auto note_fault = [&]() {
      if (!(o.accept_fault_an && rtl.took_exception() && uae.last_vector() == 2)) return;
      for (int r = 0; r < 8; r++) {
        // 7 is the user stack pointer: a user-mode -(A7) or (A7)+.
        uint32_t x = r < 7 ? rtl.regs().a[r] : rtl.regs().usp;
        uint32_t y = r < 7 ? uae.regs().a[r] : uae.regs().usp;
        int32_t d = int32_t(y - x);
        if (d != 0 && d >= -16 && d <= 16) an_pairs.push_back({r, x, y, rtl.regs().a[7]});
      }
      if (an_pairs.size() > 64) an_pairs.erase(an_pairs.begin(), an_pairs.end() - 64);
    };
    note_fault();
    bool ssw_x = o.accept_ssw_x && !live_frames.empty();
    int ssw_before = ssw_regs;
    std::vector<std::string> why = compare(rtl.regs(), uae.regs(), ssw_x, &ssw_regs, &an_pairs, &ssw_pairs);
    // The oracle restarts an instruction a bus fault interrupted from its
    // first word, so it reaches that instruction's own address once more at
    // the boundary after the RTE; the processor resumes it where it stopped
    // (UM 8.2). Take the oracle's extra boundary and compare again.
    if (!why.empty() && o.accept_rte_restart && uae.last_opcode() == 0x4E73 && !lvl) {
      ru = uae.run_until_retire();
      if (ru == StepResult::Halted) break;
      note_fault();
      why = compare(rtl.regs(), uae.regs(), ssw_x, &ssw_regs, &an_pairs, &ssw_pairs);
      restarts++;
    }
    // A posted write that faults is taken at whatever microword is running
    // when its bus error arrives (doc/checkpoint.md rule 9): the RTL may reach
    // the boundary after the writing instruction first, which the oracle,
    // faulting inside the instruction, never shows. Take the RTL's next step
    // and compare again.
    if (!why.empty() && o.accept_posted_fault && uae.last_vector() == 2 && !lvl &&
        !rtl.took_exception()) {
      rr = rtl.run_until_retire();
      if (rr != StepResult::Boundary) break;
      note_fault();
      why = compare(rtl.regs(), uae.regs(), ssw_x, &ssw_regs, &an_pairs, &ssw_pairs);
      posted++;
    }
    if (uae.last_vector() == 2 || rtl.took_exception() || uae.last_opcode() == 0x4E73)
      ws.last_fault_step = n;
    // (After the extra steps above, which may be where the fault is.)
    // Both stacked a long bus fault frame: the oracle's gets the core's SSW
    // (but for the internal-use bits, which the oracle's RTE needs) and the
    // core's stage B address. The stage fault bits and the stage B address of
    // a fetch fault are the pipe's business and the two differ
    // (doc/m11-mismatches.md c8, b10); the kernel decides from them where an
    // instruction fault was, so without this the two take different paths.
    // The oracle's own RTE reads neither in a way that changes (FB/RB and
    // FC/RC only as "fixed by software", which neither frame says).
    if (o.align_frames && rtl.took_exception() && uae.last_vector() == 2) {
      uint32_t sp = rtl.regs().a[7];
      if (sp == uae.regs().a[7] && sp + 92 <= mr.ram_size && (mr.ram[sp + 6] >> 4) == 0xB &&
          (mu.ram[sp + 6] >> 4) == 0xB) {
        uint16_t sr_ = (mr.ram[sp + 10] << 8) | mr.ram[sp + 11];
        uint16_t su = (mu.ram[sp + 10] << 8) | mu.ram[sp + 11];
        uint32_t br = (uint32_t(mr.ram[sp + 0x24]) << 24) | (mr.ram[sp + 0x25] << 16) |
                      (mr.ram[sp + 0x26] << 8) | mr.ram[sp + 0x27];
        uint32_t bu = (uint32_t(mu.ram[sp + 0x24]) << 24) | (mu.ram[sp + 0x25] << 16) |
                      (mu.ram[sp + 0x26] << 8) | mu.ram[sp + 0x27];
        uint16_t sfin = (sr_ & ~0x0E00) | (su & 0x0E00);
        if (((sr_ ^ su) & 0x0100) == 0 && sfin != sr_) ssw_pairs.push_back({-1, sr_, sfin, sp});
        if (ssw_pairs.size() > 64) ssw_pairs.erase(ssw_pairs.begin(), ssw_pairs.end() - 64);
        // Only where both say the same about the data cycle (DF).
        if (((sr_ ^ su) & 0x0100) == 0 && (sfin != su || br != bu)) {
          size_t keep = mu.step_writes.size();
          uae.poke(sp + 10, 2, (sr_ & ~0x0E00) | (su & 0x0E00));
          uae.poke(sp + 0x24, 4, br);
          mu.step_writes.resize(keep);   // the pokes are not the program's
          uint16_t chk = (mu.ram[sp + 10] << 8) | mu.ram[sp + 11];
          uint32_t chb = (uint32_t(mu.ram[sp + 0x24]) << 24) | (mu.ram[sp + 0x25] << 16) |
                         (mu.ram[sp + 0x26] << 8) | mu.ram[sp + 0x27];
          if (chk != ((sr_ & ~0x0E00) | (su & 0x0E00)) || chb != br) poke_fail++;
          frames_aligned++;
        }
      }
    }
    // Writes. A bus fault frame ($A or $B) is not compared byte for byte:
    // its internal words are the implementation's (UM 8.4.6). Only that
    // frame is skipped -- from the stack pointer the handler starts with, the
    // frame's own length -- so that a posted write landing in the same step
    // is still compared. (The supervisor stack is mapped one to one, as
    // Linux and the bare programs have it.)
    uint32_t lo = 0, hi = 0;
    if (rtl.took_exception()) {
      uint32_t sp = rtl.regs().a[7];
      if (sp + 8 <= mr.ram_size) {
        int fmt = mr.ram[sp + 6] >> 4;
        if (fmt == 0xA) { lo = sp; hi = sp + 32; }
        if (fmt == 0xB) { lo = sp; hi = sp + 92; }
        if (fmt == 0xB) { live_frames.insert(sp); frame_regions.push_back({sp, sp + 92}); }
      }
    }
    ssw_x = o.accept_ssw_x && !live_frames.empty();
    // ... and the copies the handler makes of them: an oracle write of the
    // oracle's value may also match the core's.
    std::vector<int64_t> alts(mu.step_writes.size(), -1);
    for (size_t k = 0; k < mu.step_writes.size(); k++) {
      const BusRec &w = mu.step_writes[k];
      for (const AnPair &p : an_pairs)
        if (w.size == 4 && w.data == p.uae) { alts[k] = p.rtl; an_writes++; }
      if (ssw_x)
        for (const AnPair &p : ssw_pairs) {
          if (w.size == 2 && w.data == p.uae) { alts[k] = p.rtl; ssw_writes++; }
          else if (w.size == 4 && (w.data & 0xFFFF) == p.uae) { alts[k] = (w.data & 0xFFFF0000u) | p.rtl; ssw_writes++; }
          else if (w.size == 4 && (w.data >> 16) == p.uae) { alts[k] = (w.data & 0xFFFF) | (p.rtl << 16); ssw_writes++; }
        }
    }
    if (o.compare_writes) {
      ws.add(true, mr.step_writes, n, lo, hi);
      ws.add(false, mu.step_writes, n, lo, hi, &alts);
      ws.match();
    }
    mr.step_writes.clear();
    mu.step_writes.clear();
    if (!why.empty()) {
      diverge("registers", why);
      if (ndiv >= o.maxdiv) break;
    }
    if (o.compare_writes) {
      std::vector<std::string> st = ws.stale(n, o.window);
      if (!st.empty()) {
        diverge("writes", st);
        if (ndiv >= o.maxdiv) break;
        ws.q.clear();
      }
    }
    if (ssw_regs != ssw_before) ssw_steps++;
    if (o.dump_at && n >= o.dump_at) {
      diverge("requested dump", {});
      ndiv--;
      break;
    }
    uint64_t t = n * o.mc.ns_per_step + skip;
    mr.set_time(t);
    mu.set_time(t);
    std::string in = sc.poll(mr.console());
    if (!in.empty()) { mr.tty_input(in); mu.tty_input(in); }
    rtl.set_ipl(mr.ipl());
    if (o.progress && n >= next_prog) {
      double dt = wall() - t0;
      fprintf(stderr, "[lockstep] %" PRIu64 " steps, %.1f s, %.0f steps/s, virtual %.3f s, pc %08x\n",
              n, dt, n / dt, mr.now() * 1e-9, rtl.regs().pc);
      next_prog += o.progress;
    }
    if (o.max_steps && n >= o.max_steps) {
      fprintf(stderr, "rd-virt: step limit reached\n");
      break;
    }
  }
  (void)accepted;
  if (dump) fclose(dump);
  double dt = wall() - t0;
  uint64_t n = rtl.retired();
  fprintf(stderr, "[lockstep] end: %" PRIu64 " steps in %.1f s (%.0f steps/s), virtual %.3f s, "
          "%" PRIu64 " oracle restarts taken, %" PRIu64 " posted-write fault boundaries, "
          "%d+%" PRIu64 " SSW-copy differences accepted, %" PRIu64 " fault frames aligned, %" PRIu64 " An copies, %" PRIu64 " repeated writes, %d divergences, %s\n",
          n, dt, n / (dt > 0 ? dt : 1), mr.now() * 1e-9, restarts, posted, ssw_regs, ssw_writes,
          frames_aligned, an_writes, ws.repeats, ndiv,
          rr == StepResult::Halted ? "RTL HALTED"
          : ru == StepResult::Halted ? "UAE030 HALTED"
          : mr.panicked ? "virt-ctrl PANIC"
          : mr.powered_off ? "powered off" : "stopped");
  if (rr == StepResult::Halted || ru == StepResult::Halted)
    fprintf(stderr, "RTL:\n%sUAE030:\n%s", fmt_regs(rtl.regs()).c_str(), fmt_regs(uae.regs()).c_str());
  // Evidence the acceptances hide nothing: the two machines' RAM, byte for
  // byte, at the end -- every difference either inside a bus fault frame
  // stacked during the run, or listed.
  {
    uint64_t diff = 0, in_frames = 0, outside = 0;
    std::vector<uint32_t> out_addr;
    for (uint32_t a = 0; a < mr.ram_size; a++) {
      if (mr.ram[a] == mu.ram[a]) continue;
      diff++;
      bool f = false;
      for (auto &r : frame_regions)
        if (a >= r.first && a < r.second) { f = true; break; }
      if (f) in_frames++;
      else { outside++; if (out_addr.size() < 64) out_addr.push_back(a); }
    }
    fprintf(stderr, "[lockstep] RAM at the end: %" PRIu64 " bytes differ, %" PRIu64
            " inside the %zu bus fault frames, %" PRIu64 " outside\n",
            diff, in_frames, frame_regions.size(), outside);
    for (uint32_t a : out_addr)
      fprintf(stderr, "  differs outside a frame: %08x rtl %02x uae %02x\n", a, mr.ram[a], mu.ram[a]);
    fprintf(stderr, "[lockstep] repeated writes: %" PRIu64 ", %" PRIu64
            " more than 5,000 steps from a fault or a re-run; SSW copies accepted in %" PRIu64
            " steps; oracle frame pokes not read back: %" PRIu64 "\n",
            ws.repeats, ws.repeats_far, ssw_steps, poke_fail);
    for (auto &e : ws.far_examples) fprintf(stderr, "  far repeat: %s\n", e.c_str());
  }
  bool ok = ndiv == 0 && mr.powered_off && !mr.panicked && mu.console() == mr.console();
  for (const std::string &e : o.expect)
    if (mr.console().find(e) == std::string::npos) {
      fprintf(stderr, "rd-virt: console never showed \"%s\"\n", e.c_str());
      ok = false;
    }
  if (!sc.done()) { fprintf(stderr, "rd-virt: the script did not finish\n"); ok = false; }
  printf("%s: rd-virt lockstep, %" PRIu64 " steps, %d divergences\n", ok ? "PASS" : "FAIL", n, ndiv);
  return ok ? 0 : 1;
}
#endif

void usage() {
  fprintf(stderr,
          "usage: rdvirt --cpu uae|rtl|lockstep (--kernel F [--initrd F] [--cmdline S] | --bare ELF)\n"
          "  --ram MB            RAM size (64)\n"
          "  --ns N              virtual nanoseconds per instruction boundary (20)\n"
          "  --max-steps N       stop after N boundaries\n"
          "  --script F          console script: expect/send lines\n"
          "  --expect S          pass only if the console shows S (repeatable)\n"
          "  --console-log F     copy the console to F\n"
          "  --quiet             do not echo the console\n"
          "  --progress N        report every N boundaries (0: never)\n"
          "  --no-dcache         UAE030 without its data-cache emulation\n"
          "  --dump F            the divergence dump (rdvirt-divergence.txt)\n"
          "  --no-writes         lockstep: registers only\n"
          "  --maxdiv N          lockstep: go on after N-1 divergences\n"
          "  --strict-an         lockstep: no tolerance for An of an instruction a fault interrupted\n"
          "  --strict-frames     lockstep: leave the oracle's SSW and stage B address in its frames\n"
          "  --strict-ssw        lockstep: no tolerance for SSW internal bits in copies\n"
          "  --uae-short-frames  lockstep: let the oracle stack $A on a last-write fault\n"
          "  --window N          lockstep: steps a write may lag on either side (64)\n"
          "  --trace-from N      print every boundary's PC, SR and D0-A7 from step N\n"
          "  --dump-at N         lockstep: dump both states and buses at step N, and stop\n"
#ifdef RDVIRT_RTL
          "  --ram-sync          RTL: RAM answers with STERM (synchronous)\n"
          "  --burst             RTL: ... and bursts on CBREQ (implies --ram-sync)\n"
          "  --ram-waits N       RTL: wait states on RAM (0)\n"
          "  --io-waits N        RTL: wait states on the devices (1)\n"
          "  --cdis              RTL: hold CDIS asserted (both caches off)\n"
          "  --vcd F --vcd-from N  RTL: dump a VCD from boundary N\n"
#endif
  );
}

}  // namespace

int main(int argc, char **argv) {
  Options o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) { usage(); exit(2); }
      return argv[++i];
    };
    if (a == "--cpu") o.cpu = next();
    else if (a == "--kernel") o.kernel = next();
    else if (a == "--initrd") o.initrd = next();
    else if (a == "--cmdline") o.cmdline = next();
    else if (a == "--bare") o.bare = next();
    else if (a == "--ram") o.mc.ram_mb = strtoul(next().c_str(), nullptr, 0);
    else if (a == "--ns") o.mc.ns_per_step = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--max-steps") o.max_steps = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--script") o.script = next();
    else if (a == "--expect") o.expect.push_back(next());
    else if (a == "--console-log") o.mc.console_log = next();
    else if (a == "--quiet") o.mc.echo = false;
    else if (a == "--progress") o.progress = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--no-dcache") o.dcache = false;
    else if (a == "--dump") o.dump = next();
    else if (a == "--no-writes") o.compare_writes = false;
    else if (a == "--maxdiv") o.maxdiv = atoi(next().c_str());
    else if (a == "--trace-from") o.trace_from = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--dump-at") o.dump_at = strtoull(next().c_str(), nullptr, 0);
    else if (a == "--uae-short-frames") o.uae_short_frames = true;
    else if (a == "--strict-ssw") o.accept_ssw_x = false;
    else if (a == "--strict-frames") o.align_frames = false;
    else if (a == "--strict-an") o.accept_fault_an = false;
    else if (a == "--window") o.window = strtoull(next().c_str(), nullptr, 0);
#ifdef RDVIRT_RTL
    else if (a == "--ram-sync") o.rtl.ram_sync = true;
    else if (a == "--burst") { o.rtl.ram_sync = true; o.rtl.burst = true; }
    else if (a == "--ram-waits") o.rtl.ram_waits = atoi(next().c_str());
    else if (a == "--io-waits") o.rtl.io_waits = atoi(next().c_str());
    else if (a == "--cdis") o.rtl.cdis = true;
    else if (a == "--vcd") o.rtl.vcd = next();
    else if (a == "--vcd-from") o.rtl.vcd_from = strtoull(next().c_str(), nullptr, 0);
#endif
    else { usage(); return 2; }
  }
  if (o.kernel.empty() == o.bare.empty()) { usage(); return 2; }

  auto load = [&](Machine &m) {
    return o.bare.empty() ? m.load_linux(o.kernel, o.initrd, o.cmdline) : m.load_bare(o.bare);
  };

  if (o.cpu == "uae") {
    UaeCpu::init_library(o.mc.ram_mb << 20, o.dcache);
    Machine m(o.mc, UaeCpu::library_ram());
    if (!load(m)) return 2;
    UaeCpu cpu(&m, o.dcache);
    return run_solo(o, cpu, m);
  }
#ifdef RDVIRT_RTL
  if (o.cpu == "rtl") {
    Machine m(o.mc);
    if (!load(m)) return 2;
    RtlCpu cpu(&m, o.rtl);
    return run_solo(o, cpu, m);
  }
  if (o.cpu == "lockstep") {
    MachineConfig mcu = o.mc;
    mcu.echo = false;
    mcu.console_log.clear();
    UaeCpu::init_library(o.mc.ram_mb << 20, o.dcache);
    Machine mu(mcu, UaeCpu::library_ram());
    Machine mr(o.mc);
    if (!load(mr) || !load(mu)) return 2;
    RtlCpu rtl(&mr, o.rtl);
    UaeCpu uae(&mu, o.dcache);
    return run_lockstep(o, rtl, mr, uae, mu);
  }
#endif
  usage();
  return 2;
}
