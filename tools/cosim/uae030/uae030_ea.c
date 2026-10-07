/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68031 */

/*
 * uae030_ea -- the effective-address oracle for `make ea`.
 *
 * Generates one test per (addressing mode, extension-word shape), runs each
 * through UAE030 as an MC68030, one instruction per test, and prints what the
 * address came out as.
 *
 * There are two instruments. LEA <ea>,A0 computes an address and does nothing
 * else with it, which is what makes it the one to measure an address with; but
 * LEA takes only the control modes, so it cannot reach (An)+, -(An) or the
 * modes that fetch. MOVE.L <ea>,D0 reaches those, and makes the operand fetch
 * itself visible in the access list.
 *
 * UAE030 is an oracle, not a source. Nothing here was written by reading how it
 * computes an address; the point is that two independent readings of PRM
 * section 2 have to agree, and where they do not, the manual decides.
 *
 * The output is a flat stream of hex numbers, read positionally by
 * sim/tb/core_ea_tb.sv with $fscanf("%h") -- unchanged from RD68021's:
 *
 *     ntests
 *     per test:
 *       index  nwords  w0..w5          the instruction, at PROG_BASE
 *       d0..d7 a0..a6                   the registers it starts with
 *       ea                              what A0 came out as
 *       nreads  then nreads pairs of    the operand accesses it made, and
 *               address and space         whether each was in program space (1)
 *                                         or data space (0) -- PRM 2
 *       d0 a0..a6                       the registers it finished with
 *
 * An access is an OPERAND (a misaligned one is one access, not its bus
 * cycles), and its space is the function code the oracle drove -- program for
 * FC 2 and 6 -- except that a program-counter-relative mode's reads are
 * program references whatever the oracle drove (see on_op). Instruction
 * fetches are not operand accesses and do not appear.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uae030.h"

#define MEMSIZE    0x00100000
#define PROG_BASE  0x00001000
#define DATA_BASE  0x00002000

#define MAXREADS 8

struct test {
    int          nwords;
    int          pcrel;
    unsigned int w[6];
    unsigned int d[8];
    unsigned int a[7];
};

#define MAXTESTS 2048
static struct test tests[MAXTESTS];
static int         ntests;

static void add6(int nwords, const unsigned int *w)
{
    struct test *t;
    int i;
    if (ntests >= MAXTESTS) {
        fprintf(stderr, "uae030_ea: more than %d tests\n", MAXTESTS);
        exit(1);
    }
    t = &tests[ntests++];
    t->nwords = nwords;
    /* Mode 111 register 010 or 011 -- the two program-counter-relative modes. */
    t->pcrel = (((w[0] >> 3) & 7) == 7) && ((w[0] & 7) == 2 || (w[0] & 7) == 3);
    for (i = 0; i < 6; i++) t->w[i] = w[i];
    /* Register values that are distinctive, aligned, and inside the store. */
    for (i = 0; i < 8; i++) t->d[i] = 0x00000010 + i * 4;
    for (i = 0; i < 7; i++) t->a[i] = DATA_BASE + 0x100 + i * 0x40;
}

static void add(int nwords, unsigned int w0, unsigned int w1,
                unsigned int w2, unsigned int w3)
{
    unsigned int w[6];
    w[0] = w0; w[1] = w1; w[2] = w2; w[3] = w3; w[4] = 0; w[5] = 0;
    add6(nwords, w);
}

#define LEA(mode, reg)    (0x41C0 | ((mode) << 3) | (reg))
#define MOVEL(mode, reg)  (0x2000 | ((mode) << 3) | (reg))

/* One full-extension-word case. `nbd` is how many words of base displacement
 * follow (0, 1 or 2); the outer displacement's size comes from I/IS. */
static void lea_full_op(int opcode, int ext, int nbd, int iis, int is)
{
    unsigned int w[6];
    int n = 2, nod = 0;
    if ((iis & 3) != 0)
        nod = ((iis & 3) == 2) ? 1 : (((iis & 3) == 3) ? 2 : 0);
    (void)is;
    w[0] = opcode;
    w[1] = ext;
    w[2] = w[3] = w[4] = w[5] = 0;
    /* Displacements that keep every address inside the filled block. */
    if (nbd == 1)      { w[n++] = 0x0040; }
    else if (nbd == 2) { w[n++] = 0x0000; w[n++] = 0x2040; }
    if (nod == 1)      { w[n++] = 0x0004; }
    else if (nod == 2) { w[n++] = 0x0000; w[n++] = 0x0008; }
    add6(n, w);
}

static void build(void)
{
    int reg, da, ix, wl, sc;

    /* (An) */
    for (reg = 0; reg < 7; reg++) add(1, LEA(2, reg), 0, 0, 0);
    /* (d16,An), both signs */
    for (reg = 0; reg < 7; reg++) {
        add(2, LEA(5, reg), 0x0020, 0, 0);
        add(2, LEA(5, reg), 0xFFE0, 0, 0);
    }
    /* (xxx).W, both signs; (xxx).L */
    add(2, LEA(7, 0), 0x2000, 0, 0);
    add(2, LEA(7, 0), 0x8000, 0, 0);
    add(3, LEA(7, 1), 0x0000, 0x2040, 0);
    /* (d16,PC) */
    add(2, LEA(7, 2), 0x0010, 0, 0);
    add(2, LEA(7, 2), 0xFFF0, 0, 0);
    /* (d8,An,Xn) brief, every index register, both sizes, every scale */
    for (reg = 0; reg < 3; reg++)
        for (da = 0; da < 2; da++)
            for (ix = 0; ix < 8; ix++)
                for (wl = 0; wl < 2; wl++)
                    for (sc = 0; sc < 4; sc++)
                        add(2, LEA(6, reg),
                            (da << 15) | (ix << 12) | (wl << 11) | (sc << 9) | 0x08,
                            0, 0);
    /* (d8,PC,Xn) brief */
    for (da = 0; da < 2; da++)
        for (ix = 0; ix < 8; ix++)
            for (wl = 0; wl < 2; wl++)
                for (sc = 0; sc < 4; sc++)
                    add(2, LEA(7, 3),
                        (da << 15) | (ix << 12) | (wl << 11) | (sc << 9) | 0xF8,
                        0, 0);

    /* The full extension word -- PRM 2.5, tables 2-1 and 2-2. Every combination
     * of base suppress, index suppress, base displacement size, memory indirect
     * action and outer displacement size, with the base both an address register
     * and the program counter. The displacements are chosen to land inside the
     * block the caller filled with known long words, so that a memory indirect
     * address reads something recognisable rather than zero. */
    {
        int bs, is, bd, iis, base, d, ext;
        for (base = 0; base < 2; base++) {
            for (bs = 0; bs < 2; bs++)
                for (is = 0; is < 2; is++)
                    for (bd = 1; bd < 4; bd++)
                        for (iis = 0; iis < 8; iis++) {
                            /* PRM table 2-2 leaves these undefined; this design
                             * does something with them and the manual does not
                             * say what, so they are not compared. */
                            if (is == 0 && iis == 4) continue;
                            if (is == 1 && iis >= 4) continue;
                            ext = 0x0100                        /* full format */
                                | (1 << 15)                     /* D/A: A0 */
                                | (0 << 12)                     /* Xn = A0 */
                                | (1 << 11)                     /* long index */
                                | (0 << 9)                      /* scale 1 */
                                | (bs << 7) | (is << 6)
                                | (bd << 4) | iis;
                            /* The base displacement, then the outer one. */
                            if (bd == 1)      d = 0;            /* null */
                            else if (bd == 2) d = 1;            /* one word */
                            else              d = 2;            /* two words */
                            /* An indexed effective address is mode 110 with the
                             * base register, or mode 111 register 011 with the
                             * program counter -- not mode 010, which takes no
                             * extension word at all. */
                            if (base == 0)
                                lea_full_op(LEA(6, 2), ext, d, iis, is);
                            else
                                lea_full_op(LEA(7, 3), ext, d, iis, is);
                        }
        }
    }

    /* MOVE.L <ea>,D0 -- the modes LEA cannot take, and the operand fetch.
     *
     * LEA is the better instrument for an address because it does nothing else,
     * but it takes only the control modes: PRM table 2-2's (An)+ and -(An) are
     * unreachable through it, and so is the fetch an effective address exists to
     * make. MOVE.L reaches both. The side effect on An is what the final
     * register state is compared for. */
    for (reg = 0; reg < 7; reg++) add(1, MOVEL(3, reg), 0, 0, 0);   /* (An)+ */
    for (reg = 0; reg < 7; reg++) add(1, MOVEL(4, reg), 0, 0, 0);   /* -(An) */

    /* One of each mode LEA also takes, so that the operand read appears in the
     * access list next to whatever the address calculation itself read. */
    add(1, MOVEL(2, 1), 0, 0, 0);                    /* (An)          */
    add(2, MOVEL(5, 1), 0x0020, 0, 0);               /* (d16,An)      */
    add(2, MOVEL(6, 1), 0x1a08, 0, 0);               /* (d8,An,Xn*4)  */
    add(2, MOVEL(7, 0), 0x2000, 0, 0);               /* (xxx).W       */
    add(3, MOVEL(7, 1), 0x0000, 0x2040, 0);          /* (xxx).L       */
    add(2, MOVEL(7, 2), 0x1000, 0, 0);               /* (d16,PC)      */
    add(2, MOVEL(7, 3), 0x1af8, 0, 0);               /* (d8,PC,Xn*4)  */

    /* And the memory-indirect shapes through MOVE.L, where the access list has
     * both the indirection and the fetch in it and their order matters. */
    {
        int iis, base;
        for (base = 0; base < 2; base++)
            for (iis = 1; iis < 8; iis++) {
                int ext;
                if (iis == 4) continue;             /* reserved -- PRM 2-2 */
                ext = 0x0100 | (1 << 15) | (1 << 11) | (2 << 4) | iis;
                if (base == 0) lea_full_op(MOVEL(6, 2), ext, 1, iis, 0);
                else           lea_full_op(MOVEL(7, 3), ext, 1, iis, 0);
            }
    }
}


/* ------------------------------------------------------------------ */
/* Running them                                                        */

static unsigned int read_addr[MAXREADS];
static int          read_prog[MAXREADS];
static int          nreads;
static int          recording;
static int          cur_pcrel;

static void wr16(unsigned int a, unsigned int v)
{
    uint8_t *m = uae030_ram();
    m[a] = (uint8_t)(v >> 8);
    m[a + 1] = (uint8_t)v;
}
static void wr32(unsigned int a, unsigned int v) { wr16(a, v >> 16); wr16(a + 2, v & 0xFFFF); }

static void on_op(uint32_t pa, int size, int write, uint32_t data, int fc, int berr, void *u)
{
    (void)size; (void)data; (void)berr; (void)u;
    if (!recording || nreads >= MAXREADS) return;
    read_addr[nreads] = pa;
    /* MC68030 UM 2.4.11-2.4.14: every read a program-counter-relative mode
     * makes -- the operand, and the intermediate address of the memory
     * indirect forms, ZPC included -- "is a program space reference". The
     * oracle drives data space for them (doc/oracles.md), so the space is
     * taken from the addressing mode the test was built with. */
    read_prog[nreads] = ((fc & 3) == 2) || (cur_pcrel && !write);
    nreads++;
}

static void setup(int i, uae030_state *st, void *u)
{
    struct test *t = &tests[i];
    int j;
    (void)u;
    for (j = 0; j < 6; j++) wr16(PROG_BASE + j * 2, t->w[j]);
    wr16(PROG_BASE + t->nwords * 2, 0x4E71);   /* NOP */
    for (j = 0; j < 8; j++) st->d[j] = t->d[j];
    for (j = 0; j < 7; j++) st->a[j] = t->a[j];
    st->isp = 0x8000;
    st->sr  = 0x2700;
    st->pc  = PROG_BASE;
    nreads = 0;
    cur_pcrel = t->pcrel;
    recording = 1;
}

static void result(int i, const uae030_state *s, void *u)
{
    struct test *t = &tests[i];
    int j;
    (void)u;
    recording = 0;
    printf("%x %x", i, t->nwords);
    for (j = 0; j < 6; j++) printf(" %x", t->w[j]);
    printf("\n");
    for (j = 0; j < 8; j++) printf("%x ", t->d[j]);
    for (j = 0; j < 7; j++) printf("%x ", t->a[j]);
    printf("\n%x\n", s->a[0]);
    printf("%x", nreads);
    for (j = 0; j < nreads; j++) printf(" %x %x", read_addr[j], read_prog[j]);
    printf("\n%x", s->d[0]);
    for (j = 0; j < 7; j++) printf(" %x", s->a[j]);
    printf("\n");
}

int main(void)
{
    int i, done;

    build();

    uae030_init(MEMSIZE, 1);
    /* Something recognisable wherever a memory-indirect address might land. */
    for (i = 0; i < 1024; i += 4) wr32(DATA_BASE + i, 0x00003000 + i);
    wr32(0, 0x00008000);
    wr32(4, PROG_BASE);
    for (i = 0; i < 6; i++) wr16(PROG_BASE + i * 2, 0x4E71);

    uae030_set_op_hook(on_op);
    printf("%x\n", ntests);
    if (uae030_run_each(ntests, setup, result, NULL, &done)) {
        fprintf(stderr, "uae030_ea: the oracle halted at test %d\n", done);
        return 1;
    }
    return 0;
}
