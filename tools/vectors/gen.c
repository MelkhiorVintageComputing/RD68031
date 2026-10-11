/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68031 */

/*
 * RD68031 -- the per-opcode vector generator.
 *
 * There is no SingleStepTests set for the MC68030, so the mass oracle has to be
 * built rather than downloaded. This is it: for each instruction it knows, it
 * emits a set of opcodes, gives each one several pseudo-random starting states,
 * runs each through UAE030 (tools/cosim/uae030/) as an MC68030, one
 * instruction per test, and prints what came out.
 *
 *     build/uae030/vectors_gen <group>...      # or `all`, or `list`
 *
 * It links the oracle, which is GPL code, so this file is GPL too.
 *
 * UAE030 is an ORACLE, not a source. Nothing here was written by reading how it
 * implements anything; the manual is the arbiter when the two disagree.
 *
 * WHAT IS AND IS NOT SWEPT HERE
 *
 * The addressing modes are NOT swept exhaustively against every opcode. `make
 * ea` already does that -- all eighteen modes and every shape of extension word,
 * against the same oracle, comparing the address and the access list. Repeating
 * it per opcode would multiply the vector count by two hundred to re-check
 * something already checked. What this sweeps is the OPERATION: every opcode,
 * every size, every condition, against varied operands, through a handful of
 * modes chosen to reach each data path into and out of the effective address --
 * a register, an aligned memory operand, a MISALIGNED one, and the two that
 * have a side effect on an address register.
 *
 * The MMU instructions are the `pmmu` group (M11): every test carries the
 * MMU's six registers in and out, and a test that needs translation tables
 * carries them too, as memory laid down before the run and compared after it
 * -- which is how the U and M bits a search writes are checked.
 *
 * THE OUTPUT, read positionally by sim/tb/core_vec_tb.sv with $fscanf("%h"):
 *
 *     ntests
 *     per test:
 *       index  nwords  w0..w5             the instruction, at PROG_BASE
 *       d0..d7  a0..a6  usp  isp  sr      the state it starts from
 *       msp  sfc  dfc  vbr  caar  cacr     and the control registers, because
 *                                          the reset sequence names only VBR
 *                                          and CACR -- the rest are undefined
 *                                          after a reset and MOVEC can read them
 *       npoke  then npoke pairs of        long words put into memory before the
 *         address and value               run, for the few instructions that
 *                                         need something specific there
 *       srmask  bcdfill                   which bits of the status register are
 *                                         worth comparing -- see below -- and
 *                                         whether the data block holds valid
 *                                         binary-coded decimal
 *       d0..d7  a0..a6  usp  isp  sr  pc  the state it finished in
 *       msp  vbr  sfc  dfc  caar  cacr     and the control registers MOVEC
 *                                          reaches
 *       nacc                              how many operand accesses it made
 *         per access: addr  rw  bytes  prog  value  mask
 *       tc crph crpl srph srpl tt0 tt1 mmusr   the MMU's registers it starts
 *                                         from (M11): installed with the ATC
 *                                         empty; zero for every group but pmmu
 *       ntbl  then ntbl pairs of          long words laid down before the run
 *         address and value               -- translation tables -- and
 *                                         compared after it
 *       tc crph crpl srph srpl tt0 tt1 mmusr   the MMU's registers after it
 *       ntbl values                       those long words after it, in order
 *
 * `rw` is 1 for a read. `prog` is 1 for a program-space reference -- UM 2.4.11
 * to 2.4.14 and 4.2; see doc/oracles.md for why the generator decides it from
 * the addressing mode for program-counter-relative reads. `value` is what was
 * written, and is 0 on a read: the reads are covered by the final state, and
 * the writes are how memory is compared without dumping it. `mask` says which
 * bits of a written value to compare: all of them, except in the status
 * register an exception stacks after an instruction that left some condition
 * codes undefined, where it is srmask.
 *
 * An access is an OPERAND, not a bus cycle: a misaligned long word is one
 * access, as the core's recorder (OCS, UM 7.1.1) sees it.
 *
 * `srmask` exists because the manual leaves some condition codes UNDEFINED and
 * an oracle still produces a number for them. PRM 4 says N and V are undefined
 * after ABCD, SBCD and NBCD; N and Z are undefined after a divide that
 * overflowed, and N, Z and V after a divide by zero; CHK leaves Z, V and C
 * undefined (and N, when the operand was in bounds); CMP2 and CHK2 leave N and
 * V undefined. Comparing those bits would be comparing this core against the
 * oracle's choice rather than against the manual, which CLAUDE.md forbids --
 * so they are masked out here and the choice this design made is written down
 * in doc/divergences.md instead.
 *
 * DROPPED TESTS. A test is dropped, and counted, when the oracle made more
 * accesses than there is room to record, when it halted, or when it took a bus
 * error or an address error: the long $A/$B frames (UM 8.2) are mostly
 * internal state the manual does not define, word for word, and those
 * exceptions are M8-M9's directed testbenches' business.
 *
 * MEMORY. Both sides fill DATA_SIZE bytes at DATA_BASE from the test index with
 * the same two truncating multiplications, so neither has to send the other a
 * copy per test and neither can be reading storage the other never wrote.
 * Everything else is zero, except the vector table: every vector points
 * somewhere different. The block is only as big as the addresses a test can
 * reach, because the testbench refills it once per test and that is what the
 * sweep spends its time on.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

#include "uae030.h"

#define MEMSIZE    0x00100000
#define PROG_BASE  0x00001000
#define DATA_BASE  0x00002000
#define DATA_SIZE  0x00000800
#define STACK      0x00002700
#define CACR_IMPL  0x00003313u   /* WA DBE FD ED IBE FI EI: UM figure 6-14 */

#define MAXACC 24

struct test {
    int          nwords;
    unsigned int w[6];
    int          pcrel;
    int          flow;      /* the instruction may legitimately change the PC */
    unsigned int d[8], a[7], usp, isp, sr;
    unsigned int imsp, isfc, idfc, ivbr, icaar, icacr;
    int          npoke;
    unsigned int poke_a[4], poke_v[4];
    unsigned int srmask;      /* which status-register bits to compare */
    int          bcdfill;     /* the data block is to be valid BCD */
    unsigned int imt[8];      /* TC, CRP hi/lo, SRP hi/lo, TT0, TT1, MMUSR */
    int          tables;      /* lay down the pmmu translation tables */
};

#define MAXTESTS 400000
static struct test *tests;
static int          ntests;

/* A deterministic generator, so a failing vector index means the same thing on
 * every run and on every machine. */
static unsigned int rng_state;
static unsigned int rnd(void)
{
    rng_state = rng_state * 1103515245u + 12345u;
    return (rng_state >> 8) ^ (rng_state << 13);
}

/* The data block, filled identically by sim/tb/core_vec_tb.sv. Two truncating
 * 32-bit multiplications and an exclusive or -- nothing that could mean one
 * thing in C and another in SystemVerilog. */
static unsigned int fill_word(int idx, unsigned int off)
{
    return ((unsigned int)idx * 0x9E3779B9u) ^ (off * 0x01000193u);
}

/* Every byte of a long word brought into the range a decimal digit pair can
 * hold. PRM 4 defines ABCD, SBCD and NBCD on binary-coded decimal operands and
 * says nothing about what a digit above nine does, so the sweep does not ask --
 * see doc/divergences.md. */
static unsigned int bcd_word(unsigned int v)
{
    unsigned int out = 0, i, b;
    for (i = 0; i < 4; i++) {
        b = (v >> (i * 8)) & 0xFFu;
        /* Each NIBBLE modulo ten, not the byte: `b % 10` would take $7C to
         * $74 rather than to $72, and the testbench -- which computes the same
         * fill independently -- would disagree about what is in memory. */
        out |= ((((b >> 4) % 10u) << 4) | ((b & 0x0Fu) % 10u)) << (i * 8);
    }
    return out;
}

/* One test. `nw` counts the instruction's words; the caller has put them in w. */
static void emit(int nw, const unsigned int *w, int pcrel, int flow)
{
    struct test *t;
    int i;
    if (ntests >= MAXTESTS) {
        fprintf(stderr, "vectors: more than %d tests\n", MAXTESTS);
        exit(1);
    }
    t = &tests[ntests++];
    t->nwords = nw;
    for (i = 0; i < 6; i++) t->w[i] = w[i];
    t->pcrel = pcrel;
    t->flow  = flow;

    for (i = 0; i < 8; i++) t->d[i] = rnd();
    /* Address registers point into the data block. Half of them land on an odd
     * address on purpose: the MC68030 takes no address error on a data access
     * (UM 8.1.3), so a misaligned operand is ordinary behaviour that the bus
     * unit splits, and an instruction sweep that only ever used even addresses
     * would never reach that path through an instruction. */
    for (i = 0; i < 7; i++)
        t->a[i] = DATA_BASE + 0x100 + (rnd() & 0x3FF);
    t->usp = STACK;
    t->isp = STACK;
    /* Supervisor, interrupts masked, trace off -- the trace group sets it -- and the
     * condition codes varied, because ADDX, SUBX, the rotates through X and
     * every Bcc read them. */
    t->sr  = 0x2700 | (rnd() & 0x1F);
    t->srmask  = 0xFFFF;
    /* Distinctive, and legal: the function codes are three bits and the vector
     * base has to be even. */
    t->imsp  = STACK - 0x80;
    t->isfc  = 3;
    t->idfc  = 5;
    /* Zero, and deliberately. UM 6.1.1 step 4 initialises VBR to zero, so it is
     * the one control register that does NOT need establishing -- and moving it
     * would move the vector table out from under the check below, which is how
     * a test that trapped is recognised. That is exactly what it did: setting
     * VBR to $A000 made every trapping test look like an ordinary one, and CHK
     * stopped being dropped. */
    t->ivbr  = 0x00000000u;
    t->icaar = 0x12345670u;
    /* CACR is zero after a reset (UM 6.3.1), and every test starts there:
     * the caches are off, which is what lets one instruction be compared
     * operand by operand. The movec030 group writes it. */
    t->icacr = 0;
    t->bcdfill = 0;
    memset(t->imt, 0, sizeof t->imt);
    t->tables = 0;
}

/* Several starting states for one instruction. */
static void emitn(int n, int nw, const unsigned int *w, int pcrel, int flow)
{
    while (n-- > 0) emit(nw, w, pcrel, flow);
}

/* ------------------------------------------------------------------ */
/* Addressing modes                                                    */
/*                                                                     */
/* A handful, not eighteen. `make ea` sweeps all eighteen against every */
/* shape of extension word already; what these have to do is reach each */
/* PATH into and out of an operand -- a register, an aligned memory     */
/* operand, a misaligned one, the two with a side effect on an address  */
/* register, an absolute address and a program-space one.               */
/*                                                                     */
/* The indexed modes are absent: their index register is one of the    */
/* randomised data registers, so the address would leave the block.     */
/* But two modes stand in for everything the extension-word decoder     */
/* reaches -- absolute long, and the full-format (bd,An) with the index */
/* suppressed -- because `make ea` sweeps the modes only as a SOURCE,   */
/* and a destination through them is where the address routines' own   */
/* scratch registers met the operand an instruction was holding. Until  */
/* RD68021's M12 that was every one of them.                           */
/* ------------------------------------------------------------------ */

struct eamode {
    int          mode, reg;
    int          next;          /* how many extension words follow */
    unsigned int ext[2];
    int          pcrel;
};

/* (d16,PC): the PC in the calculation is the address of the extension word,
 * PROG_BASE+2 for a one-word opcode. Displacements are chosen so that every
 * address lands inside the filled block. */
#define D16AN  0x0008
#define ABSW   0x2100
#define FULLBD 0x0160   /* full format: BS=0, IS=1, word bd, no indirection */

static const struct eamode EA_ALL[] = {      /* data source: anything readable */
    { 0, 0, 0, { 0, 0 }, 0 },                /* Dn      */
    { 0, 5, 0, { 0, 0 }, 0 },
    { 2, 1, 0, { 0, 0 }, 0 },                /* (An)    */
    { 2, 4, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },                /* (An)+   */
    { 4, 3, 0, { 0, 0 }, 0 },                /* -(An)   */
    { 5, 6, 1, { D16AN, 0 }, 0 },            /* (d16,An)*/
    { 7, 0, 1, { ABSW, 0 }, 0 },             /* (xxx).W */
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_ALL ((int)(sizeof EA_ALL / sizeof EA_ALL[0]))

static const struct eamode EA_ALT[] = {      /* data alterable: no PC, no imm */
    { 0, 0, 0, { 0, 0 }, 0 },
    { 2, 1, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },
    { 4, 3, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_ALT ((int)(sizeof EA_ALT / sizeof EA_ALT[0]))

static const struct eamode EA_MEM[] = {      /* memory alterable: no Dn */
    { 2, 1, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },
    { 4, 3, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_MEM ((int)(sizeof EA_MEM / sizeof EA_MEM[0]))

static const struct eamode EA_CTL[] = {      /* control: an address, not a value */
    { 2, 1, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
    { 7, 1, 2, { 0x0000, ABSW }, 0 },        /* (xxx).L */
    { 6, 6, 2, { FULLBD, D16AN }, 0 },       /* (bd,An), full format */
};
#define N_EA_CTL ((int)(sizeof EA_CTL / sizeof EA_CTL[0]))

/* One opcode through one set of modes, with `nper` starting states each.
 * `pre` is any word that comes between the opcode and the mode's extension
 * words -- an immediate operand, or MOVEM's register mask. */
static void sweep(unsigned int base, const struct eamode *set, int nset,
                  int npre, const unsigned int *pre, int nper, int flow)
{
    unsigned int w[6];
    int i, j, n;
    for (i = 0; i < nset; i++) {
        memset(w, 0, sizeof w);
        n = 0;
        w[n++] = base | (unsigned)(set[i].mode << 3) | (unsigned)set[i].reg;
        for (j = 0; j < npre; j++) w[n++] = pre[j];
        for (j = 0; j < set[i].next; j++) w[n++] = set[i].ext[j];
        emitn(nper, n, w, set[i].pcrel, flow);
    }
}

/* A (d16,PC) source, whose displacement depends on how many words precede it. */
static void sweep_pc(unsigned int base, int npre, const unsigned int *pre,
                     int nper, int flow)
{
    unsigned int w[6];
    int j, n = 0;
    memset(w, 0, sizeof w);
    w[n++] = base | (7 << 3) | 2;
    for (j = 0; j < npre; j++) w[n++] = pre[j];
    /* The value of the PC is the address of the extension word. */
    w[n] = (DATA_BASE + 0x100 - (PROG_BASE + (unsigned)n * 2)) & 0xFFFF;
    n++;
    emitn(nper, n, w, 1, flow);
}

/* No effective address at all. */
static void plain(unsigned int w0, int nper, int flow)
{
    unsigned int w[6];
    memset(w, 0, sizeof w);
    w[0] = w0;
    emitn(nper, 1, w, 0, flow);
}

static void plain2(unsigned int w0, unsigned int w1, int nper, int flow)
{
    unsigned int w[6];
    memset(w, 0, sizeof w);
    w[0] = w0; w[1] = w1;
    emitn(nper, 2, w, 0, flow);
}

/* Put a long word somewhere before the run. RTS and its relatives need a return
 * address on the stack that is a real address, not fill. */
static void poke(unsigned int a, unsigned int v)
{
    struct test *t = &tests[ntests - 1];
    if (t->npoke >= 4) { fprintf(stderr, "vectors: too many pokes\n"); exit(1); }
    t->poke_a[t->npoke] = a;
    t->poke_v[t->npoke] = v;
    t->npoke++;
}

/* The same long word into the last `n` tests, which is what emitn just made. */
static void poke_n(int n, unsigned int a, unsigned int v)
{
    int i;
    for (i = 0; i < n; i++) {
        struct test *t = &tests[ntests - 1 - i];
        if (t->npoke >= 4) { fprintf(stderr, "vectors: too many pokes\n"); exit(1); }
        t->poke_a[t->npoke] = a;
        t->poke_v[t->npoke] = v;
        t->npoke++;
    }
}

/* ------------------------------------------------------------------ */
/* The instruction groups                                              */
/*                                                                     */
/* Encodings are from PRM section 8, the instruction format summary.    */
/* ------------------------------------------------------------------ */

#define NPER 6      /* starting states per opcode */

/* MOVE: 00 ss  rrr mmm  eeeeee -- note the destination is register THEN mode.
 * Sizes are 01 byte, 11 word, 10 long, which is not the order anything else
 * uses (PRM 8). */
static const unsigned int MOVE_SZ[3] = { 0x1000, 0x3000, 0x2000 };

static void g_move(void)
{
    int s, i;
    for (s = 0; s < 3; s++) {
        /* <ea> -> D1, every source mode. Byte size takes no address register. */
        for (i = 0; i < N_EA_ALL; i++) {
            if (s == 0 && EA_ALL[i].mode == 1) continue;
            sweep(MOVE_SZ[s] | (1 << 9) | (0 << 6),
                  &EA_ALL[i], 1, 0, NULL, NPER, 0);
        }
        sweep_pc(MOVE_SZ[s] | (1 << 9) | (0 << 6), 0, NULL, NPER, 0);
        /* D3 -> <ea>, every destination mode. */
        for (i = 0; i < N_EA_ALT; i++) {
            unsigned int dst = (unsigned)(EA_ALT[i].reg << 9)
                             | (unsigned)(EA_ALT[i].mode << 6);
            unsigned int w[6];
            int n = 0, j;
            memset(w, 0, sizeof w);
            w[n++] = MOVE_SZ[s] | dst | 3;          /* source D3 */
            for (j = 0; j < EA_ALT[i].next; j++) w[n++] = EA_ALT[i].ext[j];
            emitn(NPER, n, w, 0, 0);
        }
        /* memory to memory, the shape that has a read and a write in one
         * instruction and no register in between */
        {
            unsigned int w[2];
            w[0] = MOVE_SZ[s] | (2 << 9) | (2 << 6) | (2 << 3) | 1;  /* (A1)->(A2) */
            w[1] = 0;
            emitn(NPER, 1, w, 0, 0);
        }
    }
    /* MOVEA, word and long only, sign extending the word form to 32 bits. */
    for (s = 1; s < 3; s++)
        for (i = 0; i < N_EA_ALL; i++)
            sweep(MOVE_SZ[s] | (4 << 9) | (1 << 6), &EA_ALL[i], 1, 0, NULL, NPER, 0);
}

static void g_moveq(void)
{
    /* Bit 8 must be zero or it is not MOVEQ, so the immediate is masked rather
     * than computed: 0x01 + 3 * 0x55 is 0x100, which is a different instruction
     * and an illegal one. The drop counter caught it. */
    static const unsigned int imm[4] = { 0x00, 0x7F, 0x80, 0xFF };
    int r, k;
    for (r = 0; r < 8; r++)
        for (k = 0; k < 4; k++)
            plain(0x7000 | (unsigned)(r << 9) | imm[k], 2, 0);
}

/* The one-operand group: CLR NEG NEGX NOT TST. */
static void g_unary(void)
{
    static const unsigned int op[5] = { 0x4200, 0x4400, 0x4000, 0x4600, 0x4A00 };
    int o, s;
    for (o = 0; o < 5; o++)
        for (s = 0; s < 3; s++)
            sweep(op[o] | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);

    /* TST's MC68020-only operands, PRM 4: an address register at word and long
     * size, an immediate, and the program-counter-relative modes. None of them
     * is alterable, so EA_ALT has none of them -- and the MC68020 decoder once
     * sent all three to illegal instruction, found by a Sun-3 PROM that says
     * TST.L A2. */
    {
        static const struct eamode IMMB[] = {
            { 7, 4, 1, { 0x0080, 0 }, 0 } };
        static const struct eamode AN_IMMW[] = {
            { 1, 3, 0, { 0, 0 }, 0 }, { 7, 4, 1, { 0x8000, 0 }, 0 } };
        static const struct eamode AN_IMML[] = {
            { 1, 3, 0, { 0, 0 }, 0 }, { 7, 4, 2, { 0x8000, 0x0001 }, 0 } };
        sweep(0x4A00, IMMB,    1, 0, NULL, NPER, 0);
        sweep(0x4A40, AN_IMMW, 2, 0, NULL, NPER, 0);
        sweep(0x4A80, AN_IMML, 2, 0, NULL, NPER, 0);
        for (s = 0; s < 3; s++)
            sweep_pc(0x4A00 | (unsigned)(s << 6), 0, NULL, NPER, 0);
    }
}

static void g_misc(void)
{
    int r;
    for (r = 0; r < 8; r++) {
        plain(0x4840 | (unsigned)r, NPER, 0);            /* SWAP    */
        plain(0x4880 | (unsigned)r, NPER, 0);            /* EXT.W   */
        plain(0x48C0 | (unsigned)r, NPER, 0);            /* EXT.L   */
        plain(0x49C0 | (unsigned)r, NPER, 0);            /* EXTB.L  */
    }
    /* EXG, all three register-pair forms. */
    for (r = 0; r < 4; r++) {
        plain(0xC140 | (unsigned)(r << 9) | (unsigned)(7 - r), NPER, 0); /* Dx,Dy */
        plain(0xC148 | (unsigned)(r << 9) | (unsigned)(6 - r), NPER, 0); /* Ax,Ay */
        plain(0xC188 | (unsigned)(r << 9) | (unsigned)(5 - r), NPER, 0); /* Dx,Ay */
    }
    plain(0x4E71, 4, 0);                                 /* NOP     */
}

static void g_addr(void)
{
    int i;
    /* LEA <ea>,A4 and PEA <ea> -- control modes only. */
    for (i = 0; i < N_EA_CTL; i++) {
        sweep(0x41C0 | (4 << 9), &EA_CTL[i], 1, 0, NULL, NPER, 0);
        sweep(0x4840, &EA_CTL[i], 1, 0, NULL, NPER, 0);
    }
    sweep_pc(0x41C0 | (4 << 9), 0, NULL, NPER, 0);
    sweep_pc(0x4840, 0, NULL, NPER, 0);
    /* LINK.W, LINK.L and UNLK. The displacement is negative, as a frame's is. */
    plain2(0x4E50 | 5, 0xFFF0, NPER, 0);                 /* LINK.W A5,#-16 */
    {
        unsigned int w[6];
        memset(w, 0, sizeof w);
        w[0] = 0x4808 | 5; w[1] = 0xFFFF; w[2] = 0xFF00; /* LINK.L A5,#-256 */
        emitn(NPER, 3, w, 0, 0);
    }
    plain(0x4E58 | 5, NPER, 0);                          /* UNLK A5 */
}

/* The two-operand arithmetic and logic group. Each has the same shape:
 * an opmode field selecting size and direction, and an <ea>. */
static void g_alu(void)
{
    static const unsigned int op[5]   = { 0xD000, 0x9000, 0xC000, 0x8000, 0xB000 };
    static const int          mem_ok[5] = { 1, 1, 1, 1, 1 };  /* <ea> as destination */
    /*                        ADD     SUB     AND     OR      EOR/CMP          */
    int o, s, i;

    for (o = 0; o < 4; o++) {           /* ADD SUB AND OR: both directions */
        for (s = 0; s < 3; s++) {
            /* Dn = Dn op <ea>. AND and OR take no address register source. */
            for (i = 0; i < N_EA_ALL; i++) {
                if (EA_ALL[i].mode == 1) continue;   /* no An source for any of
                                                        these at byte size, and
                                                        none at all for AND/OR */
                sweep(op[o] | (2 << 9) | (unsigned)(s << 6),
                      &EA_ALL[i], 1, 0, NULL, NPER, 0);
            }
            sweep_pc(op[o] | (2 << 9) | (unsigned)(s << 6), 0, NULL, NPER, 0);
            /* <ea> = <ea> op Dn, memory destinations only. */
            if (mem_ok[o])
                sweep(op[o] | (6 << 9) | (unsigned)((s + 4) << 6),
                      EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);
        }
        /* ADDA and SUBA: word and long, and no condition codes at all. */
        if (o < 2)
            for (s = 1; s < 3; s++)
                sweep(op[o] | (5 << 9) | (unsigned)((s == 1 ? 3 : 7) << 6),
                      EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);
    }

    /* CMP, CMPA and EOR share the 1011 line. */
    for (s = 0; s < 3; s++) {
        for (i = 0; i < N_EA_ALL; i++) {
            if (s == 0 && EA_ALL[i].mode == 1) continue;
            sweep(0xB000 | (2 << 9) | (unsigned)(s << 6),
                  &EA_ALL[i], 1, 0, NULL, NPER, 0);        /* CMP  <ea>,Dn */
        }
        sweep(0xB000 | (6 << 9) | (unsigned)((s + 4) << 6),
              EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);         /* EOR  Dn,<ea> */
        sweep(0xB000 | (6 << 9) | (unsigned)((s + 4) << 6),
              EA_ALT, 1, 0, NULL, NPER, 0);                /* EOR  Dn,Dn   */
    }
    for (s = 1; s < 3; s++)
        sweep(0xB000 | (5 << 9) | (unsigned)((s == 1 ? 3 : 7) << 6),
              EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);         /* CMPA */

    /* CMPM (Ay)+,(Ax)+ -- the only mode it has. */
    for (s = 0; s < 3; s++)
        plain(0xB108 | (unsigned)(s << 6) | (2 << 9) | 3, NPER, 0);
}

/* The immediate group: ADDI SUBI ANDI ORI EORI CMPI. */
static void g_imm(void)
{
    static const unsigned int op[6] = { 0x0600, 0x0400, 0x0200, 0x0000,
                                        0x0A00, 0x0C00 };
    static const unsigned int imm_b[4] = { 0x0001, 0x007F, 0x0080, 0x00FF };
    static const unsigned int imm_w[4] = { 0x0001, 0x7FFF, 0x8000, 0xFFFF };
    int o, k, i;
    for (o = 0; o < 6; o++) {
        for (k = 0; k < 4; k++) {
            unsigned int pre[2];
            /* byte and word take one extension word, long takes two */
            pre[0] = imm_b[k];
            sweep(op[o] | (0 << 6), EA_ALT, N_EA_ALT, 1, pre, 2, 0);
            pre[0] = imm_w[k];
            sweep(op[o] | (1 << 6), EA_ALT, N_EA_ALT, 1, pre, 2, 0);
            pre[0] = imm_w[k]; pre[1] = imm_w[3 - k];
            sweep(op[o] | (2 << 6), EA_ALT, N_EA_ALT, 2, pre, 2, 0);
        }
    }
    /* ADDQ and SUBQ, every data value including the 8 that zero encodes, and
     * the address-register forms, which touch no condition code. */
    for (i = 1; i <= 8; i++) {
        unsigned int q = (unsigned)(i & 7) << 9;
        int s;
        for (s = 0; s < 3; s++) {
            sweep(0x5000 | q | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, 2, 0);
            sweep(0x5100 | q | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, 2, 0);
        }
        plain(0x5048 | q | 3, 2, 0);          /* ADDQ.W #i,A3 */
        plain(0x5088 | q | 3, 2, 0);          /* ADDQ.L #i,A3 */
        plain(0x5148 | q | 3, 2, 0);          /* SUBQ.W #i,A3 */
        plain(0x5188 | q | 3, 2, 0);          /* SUBQ.L #i,A3 */
    }
}

/* ADDX and SUBX, both forms: register to register and -(Ay) to -(Ax). */
static void g_extend(void)
{
    static const unsigned int op[2] = { 0xD100, 0x9100 };
    int o, s;
    for (o = 0; o < 2; o++)
        for (s = 0; s < 3; s++) {
            plain(op[o] | (unsigned)(s << 6) | (2 << 9) | 5, NPER, 0);
            plain(op[o] | (unsigned)(s << 6) | (2 << 9) | 8 | 3, NPER, 0);
        }
}

/* The shifts and rotates: ASL ASR LSL LSR ROL ROR ROXL ROXR, register forms in
 * all three sizes with both a count in the instruction and a count in a
 * register, and the memory forms, which are one bit of a word. */
static void g_shift(void)
{
    int type, dir, s, c;
    for (type = 0; type < 4; type++)
        for (dir = 0; dir < 2; dir++) {
            for (s = 0; s < 3; s++) {
                /* An immediate count of 1..8, 0 meaning 8. */
                for (c = 0; c < 8; c++)
                    plain(0xE000 | (unsigned)(c << 9) | (unsigned)(dir << 8)
                          | (unsigned)(s << 6) | (unsigned)(type << 3) | 4,
                          2, 0);
                /* A count in D2, which is random: the 68030 takes it modulo 64
                 * for the shifts and modulo the size plus one for the rotates
                 * through X, so the whole range has to be reachable. */
                plain(0xE020 | (2 << 9) | (unsigned)(dir << 8)
                      | (unsigned)(s << 6) | (unsigned)(type << 3) | 4,
                      NPER * 3, 0);
            }
            /* The memory forms shift one bit of a word. */
            sweep(0xE0C0 | (unsigned)(type << 9) | (unsigned)(dir << 8),
                  EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);
        }
}

/* BTST BCHG BCLR BSET, static and dynamic. A byte in memory, a long word in a
 * register -- PRM 4: the bit number is modulo 8 for memory and modulo 32 for a
 * register, and getting that the wrong way round is a real bug this catches. */
static void g_bit(void)
{
    static const unsigned int op[4] = { 0x0000, 0x0040, 0x0080, 0x00C0 };
    int o, b;
    for (o = 0; o < 4; o++) {
        /* Dynamic: the bit number in D1. */
        sweep(0x0100 | (1 << 9) | op[o], EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);
        if (o == 0) {
            /* BTST only: the program-space operands, and BTST Dn,#<data> --
             * the one bit instruction that takes an immediate operand (PRM 4,
             * BTST's addressing-mode table). D1 is random, so the bit number
             * is too, modulo 8. These two were added after the rest; the
             * random stream is put back afterwards so that every other test
             * keeps the starting state it had. */
            unsigned int keep;
            sweep_pc(0x0100 | (1 << 9), 0, NULL, NPER, 0);
            keep = rng_state;
            plain2(0x0100 | (1 << 9) | 0x3C, 0x00A5, NPER, 0);
            plain2(0x0100 | (1 << 9) | 0x3C, 0x005A, NPER, 0);
            rng_state = keep;
        }
        /* Static: the bit number in the word after the opcode. */
        for (b = 0; b < 40; b += 7) {
            unsigned int pre = (unsigned)b;
            sweep(0x0800 | op[o], EA_ALT, N_EA_ALT, 1, &pre, 2, 0);
        }
    }
}

/* Scc, DBcc, Bcc, BRA and BSR over all sixteen conditions. */
static void g_cond(void)
{
    int cc;
    for (cc = 0; cc < 16; cc++) {
        /* Scc: T and F are conditions 0 and 1, and Scc has all sixteen. */
        sweep(0x50C0 | (unsigned)(cc << 8), EA_ALT, N_EA_ALT, 0, NULL, 3, 0);
        /* DBcc Dn,#d -- the count register is random, so both the taken and the
         * exhausted arms are reached. */
        plain2(0x50C8 | (unsigned)(cc << 8) | 6, 0x0004, NPER, 1);
        if (cc >= 2) {
            /* Bcc: the byte, word and long displacements. All three land inside
             * the program area, where a NOP is waiting. */
            plain(0x6000 | (unsigned)(cc << 8) | 0x04, NPER, 1);
            plain2(0x6000 | (unsigned)(cc << 8), 0x0006, NPER, 1);
            {
                unsigned int w[6];
                memset(w, 0, sizeof w);
                w[0] = 0x6000 | (unsigned)(cc << 8) | 0xFF;
                w[1] = 0x0000; w[2] = 0x0008;
                emitn(NPER, 3, w, 0, 1);
            }
        }
    }
    /* BRA and BSR, all three displacement sizes. */
    plain(0x6004, NPER, 1);
    plain2(0x6000, 0x0006, NPER, 1);
    plain(0x6104, NPER, 1);                   /* BSR.B */
    plain2(0x6100, 0x0006, NPER, 1);          /* BSR.W */
    {
        unsigned int w[6];
        memset(w, 0, sizeof w);
        w[0] = 0x61FF; w[1] = 0x0000; w[2] = 0x0008;
        emitn(NPER, 3, w, 0, 1);              /* BSR.L */
    }
}

/* JMP, JSR and the returns. The returns need a real address on the stack, which
 * is what poke_n is for -- fill would send the program counter anywhere. */
static void g_jump(void)
{
    int i;
    for (i = 0; i < N_EA_CTL; i++) {
        sweep(0x4EC0, &EA_CTL[i], 1, 0, NULL, NPER, 1);   /* JMP */
        sweep(0x4E80, &EA_CTL[i], 1, 0, NULL, NPER, 1);   /* JSR */
    }
    sweep_pc(0x4EC0, 0, NULL, NPER, 1);
    sweep_pc(0x4E80, 0, NULL, NPER, 1);

    plain(0x4E75, NPER, 1);                               /* RTS */
    poke_n(NPER, STACK, PROG_BASE + 8);
    /* RTR pops a WORD of condition codes and then a LONG program counter, so
     * the long word at the stack pointer is the codes and the top half of the
     * address, and the next one holds the bottom half. */
    plain(0x4E77, NPER, 1);                               /* RTR */
    poke_n(NPER, STACK,     0x001F0000);
    poke_n(NPER, STACK + 4, ((PROG_BASE + 8) & 0xFFFF) << 16);
    plain2(0x4E74, 0x0010, NPER, 1);                      /* RTD #16 */
    poke_n(NPER, STACK, PROG_BASE + 8);
}

/* MULU MULS DIVU DIVS, the word forms the MC68010 has and the long forms the
 * MC68020 added. A zero divisor traps; the traps group has one on purpose, and
 * a random divisor of zero here traps the same way and is compared like any
 * other exception. */
static void g_muldiv(void)
{
    int i;
    for (i = 0; i < N_EA_ALL; i++) {
        if (EA_ALL[i].mode == 1) continue;
        sweep(0xC0C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* MULU.W */
        sweep(0xC1C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* MULS.W */
        sweep(0x80C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* DIVU.W */
        sweep(0x81C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* DIVS.W */
    }
    /* The 32-bit forms, PRM 4: MULU.L <ea>,Dl and the 64-bit MULU.L <ea>,Dh:Dl,
     * and DIVU.L with a 32- and a 64-bit dividend. */
    {
        unsigned int pre;
        pre = (2 << 12);                 /* Dl = D2, unsigned, 32 bits    */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);           /* MULU.L */
        pre = (2 << 12) | 0x0800;        /* signed                        */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);           /* MULS.L */
        pre = (2 << 12) | 0x0400 | 5;    /* 64-bit product into D5:D2     */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12);                 /* DIVU.L <ea>,Dq                */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12) | 0x0800;        /* DIVS.L                        */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12) | 0x0400 | 5;    /* 64-bit dividend D5:D2         */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
    }
}

/* ABCD SBCD NBCD, both register and memory forms. */
static void bcd_operands(int n)
{
    int i, j;
    for (i = 0; i < n; i++) {
        struct test *t = &tests[ntests - 1 - i];
        t->bcdfill = 1;
        for (j = 0; j < 8; j++) t->d[j] = bcd_word(t->d[j]);
    }
}

/* PACK and UNPK -- PRM 4, new on the MC68020.
 *
 * The adjustment word is the point of the instruction, so it is swept rather
 * than left at zero: $0000 is the identity, and the interesting values are the
 * ones that carry out of a nibble. bcd_operands fills the registers and memory
 * with digits, which is what the instruction is for, but the encoding takes
 * anything and the pack is a bit shuffle, so plain binary is worth running too
 * and is what the registers already hold. */
static void g_packunpk(void)
{
    static const unsigned int ADJ[] = { 0x0000u, 0x0001u, 0x9999u, 0x6666u,
                                        0x0F0Fu, 0xF0F0u, 0x00FFu, 0x8000u };
    int i;
    /* The register forms. The predecrement forms are their own group,
     * packunpk_mem, so that a disagreement about which byte is significant
     * (doc/divergences.md) is reported apart from the arithmetic. */
    for (i = 0; i < (int)(sizeof ADJ / sizeof ADJ[0]); i++) {
        plain2(0x8140u | (2 << 9) | 5, ADJ[i], NPER, 0);   /* PACK D5,D2  */
        bcd_operands(NPER);
        plain2(0x8180u | (2 << 9) | 5, ADJ[i], NPER, 0);   /* UNPK D5,D2  */
        bcd_operands(NPER);
    }
}

/* CMP2 and CHK2 are the cmp2 group, below. */

/* MOVES -- PRM 6. The point of the instruction is the function code it uses, so
 * what this really tests is the SPACE each access goes to: the sweep compares
 * the access list, and the space is part of it. SFC and DFC are part of the
 * initial state the generator randomises, so every test names a different one.
 *
 * Memory alterable modes only. */
static void g_moves(void)
{
    static const unsigned int SZ[] = { 0x0E00u, 0x0E40u, 0x0E80u };
    static const unsigned int XW[] = {
        0x1000u,        /* <ea> -> D1 */
        0x9000u,        /* <ea> -> A1 */
        0x1800u,        /* D1 -> <ea> */
        0x9800u,        /* A1 -> <ea> */
    };
    int i, j;
    for (i = 0; i < 3; i++)
        for (j = 0; j < (int)(sizeof XW / sizeof XW[0]); j++)
            sweep(SZ[i], EA_MEM, N_EA_MEM, 1, &XW[j], NPER, 0);
}

/* The eight bit-field instructions -- PRM 4.
 *
 * The extension word is the instruction: offset and width, each either an
 * immediate or a data register. The immediates are swept over the values that
 * matter -- a field inside one byte, one that straddles a byte, one that fills
 * a long word, and the encoded zero that means thirty-two -- and the register
 * forms let the operand generator's random registers supply offsets that are
 * large, negative, and not multiples of eight, which is where the byte count
 * and the base address are earned.
 *
 * Both the register-direct and the memory forms are run, because they share
 * nothing but the extension word: one wraps inside thirty-two bits and the
 * other walks up to five bytes of memory. */
static void g_bitfield(void)
{
    static const unsigned int OPS[] = {
        0xE8C0u,  /* BFTST  */ 0xE9C0u,  /* BFEXTU */
        0xEAC0u,  /* BFCHG  */ 0xEBC0u,  /* BFEXTS */
        0xECC0u,  /* BFCLR  */ 0xEDC0u,  /* BFFFO  */
        0xEEC0u,  /* BFSET  */ 0xEFC0u,  /* BFINS  */
    };
    /* {Do,offset,Dw,width} as the extension word packs them, plus a data
     * register in bits 14-12 for the four that name one. */
    static const unsigned int XW[] = {
        0x0000u,          /* offset 0,  width 32 (the encoded zero) */
        0x0001u,          /* offset 0,  width 1                     */
        0x0008u,          /* offset 0,  width 8                     */
        0x01C7u,          /* offset 7,  width 7  -- inside one byte  */
        0x0148u,          /* offset 5,  width 8  -- straddles one    */
        0x07C0u,          /* offset 31, width 32 -- five bytes       */
        0x0820u,          /* offset in D0, width 32                  */
        0x0925u,          /* offset in D4, width in D5               */
        0x08A0u,          /* offset in D2, width 32                  */
    };
    int i, j;
    /* The register-direct forms. The memory forms are their own group,
     * bitfield_mem, because PRM 4's NOTE ("accesses only those bytes in memory
     * that contain some portion of the bit field") makes their access list a
     * question of its own, apart from the field arithmetic this one checks. */
    for (i = 0; i < 8; i++)
        for (j = 0; j < (int)(sizeof XW / sizeof XW[0]); j++) {
            unsigned int xw = XW[j] | 0x3000u;   /* D3 for the four that use one */
            plain2(OPS[i] | 0x0003u, xw, NPER, 0);        /* ... on D3 */
        }
}

static void g_bcd(void)
{
    plain(0xC100 | (2 << 9) | 5, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* ABCD D5,D2      */
    plain(0xC108 | (2 << 9) | 3, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* ABCD -(A3),-(A2)*/
    plain(0x8100 | (2 << 9) | 5, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* SBCD D5,D2      */
    plain(0x8108 | (2 << 9) | 3, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* SBCD -(A3),-(A2)*/
    sweep(0x4800, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);/* NBCD <ea>       */
    bcd_operands(NPER * N_EA_ALT);
}

/* TAS: a read-modify-write, and the only instruction in the MC68010 set that
 * holds RMC across two accesses. */
static void g_tas(void)
{
    sweep(0x4AC0, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);
}

/* MOVEM, both directions, both sizes, and the masks that matter: none, one at
 * each end, alternating, and all of them. The predecrement form's mask is
 * reversed, which is the part worth sweeping. */
static void g_movem(void)
{
    static const unsigned int mask[6] = { 0x0000, 0x0001, 0x8000, 0xFFFF,
                                          0xAAAA, 0x0F0F };
    int m, s;
    for (m = 0; m < 6; m++)
        for (s = 0; s < 2; s++) {
            unsigned int sz = (unsigned)(s << 6);       /* 0 word, 1 long */
            unsigned int pre = mask[m];
            /* registers to memory, and the predecrement form */
            sweep(0x4880 | sz, EA_CTL, N_EA_CTL, 1, &pre, 2, 0);
            plain2(0x4880 | sz | (4 << 3) | 3, mask[m], 2, 0);
            /* memory to registers, and the postincrement form */
            sweep(0x4C80 | sz, EA_CTL, N_EA_CTL, 1, &pre, 2, 0);
            plain2(0x4C80 | sz | (3 << 3) | 2, mask[m], 2, 0);
        }
}

/* MOVEP: a word or a long word through every other byte of memory. */
static void g_movep(void)
{
    int op;
    for (op = 4; op < 8; op++)
        plain2(0x0008 | (1 << 9) | (unsigned)(op << 6) | 3, 0x0010, NPER, 0);
}

/* The condition codes as an operand: MOVE to and from CCR, and the three
 * immediate forms. MOVE from CCR is an MC68010 addition. */
static void g_ccr(void)
{
    sweep(0x42C0, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);        /* MOVE  CCR,<ea> */
    sweep(0x44C0, EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);        /* MOVE  <ea>,CCR */
    {
        int k;
        static const unsigned int v[4] = { 0x0000, 0x001F, 0x000A, 0x0015 };
        for (k = 0; k < 4; k++) {
            plain2(0x023C, v[k], 2, 0);                       /* ANDI  #x,CCR   */
            plain2(0x003C, v[k], 2, 0);                       /* ORI   #x,CCR   */
            plain2(0x0A3C, v[k], 2, 0);                       /* EORI  #x,CCR   */
        }
    }
}

/* The exceptions that no other group reaches: the traps, the illegal and
 * unimplemented instruction lines, the privilege violation and the return.
 *
 * These are compared like any other instruction. What makes them a test of
 * exception processing is that the frame they build is in the access list --
 * four or six words, each with its address and its value -- and that the
 * program counter afterwards says which vector was taken, because every vector
 * in the table points somewhere different. */
/* One privileged instruction, run in USER mode, where it must trap.
 *
 * The user stack has to be somewhere real: the frame goes on the SUPERVISOR
 * stack -- UM 6.1 step three builds it on the active supervisor stack, and the
 * first step has already set S -- but the instruction runs with A7 meaning the
 * user one, and an instruction that touches it before trapping would go
 * somewhere undefined otherwise. */
static void user_mode(unsigned int w0, unsigned int w1, int words)
{
    int i;
    if (words) plain2(w0, w1, 2, 1);
    else       plain(w0, 2, 1);
    for (i = 0; i < 2; i++) {
        struct test *t = &tests[ntests - 1 - i];
        t->sr  = (t->sr & ~0x2000u);      /* S clear: the user level */
        t->usp = STACK - 0x100;
    }
}


/* One RTE, with a frame poked under the stack pointer. */
static void rte_frame(unsigned int sr, unsigned int pc, unsigned int fmtvec)
{
    plain(0x4E73, 2, 1);
    poke_n(2, STACK,     (sr << 16) | (pc >> 16));
    poke_n(2, STACK + 4, ((pc & 0xFFFFu) << 16) | fmtvec);
}


static void g_traps(void)
{
    int i;

    /* TRAP #0 to #15. */
    for (i = 0; i < 16; i++)
        plain(0x4E40 | (unsigned)i, 2, 1);

    /* TRAPV, both ways: the condition codes are random, so about half of these
     * trap and about half do nothing. */
    plain(0x4E76, NPER * 2, 1);

    /* TRAPcc over every condition, and all three operand forms. */
    for (i = 0; i < 16; i++) {
        plain(0x50FC | (unsigned)(i << 8), 3, 1);              /* no operand */
        plain2(0x50FA | (unsigned)(i << 8), 0x1234, 3, 1);     /* a word     */
        {
            unsigned int w[6];
            memset(w, 0, sizeof w);
            w[0] = 0x50FB | (unsigned)(i << 8);
            w[1] = 0x1234; w[2] = 0x5678;
            emitn(3, 3, w, 0, 1);                              /* a long word */
        }
    }

    /* ILLEGAL, and the two unimplemented lines -- UM 8.1.5. $F000 and $F5A5
     * are coprocessor IDs 0 and 2 here; cpID 0 is the MMU on the MC68030, and
     * $F000 is not one of its encodings, so it is an F-line trap like the
     * other. */
    plain(0x4AFC, 2, 1);                                       /* ILLEGAL */
    plain(0xA000, 2, 1);                                       /* A-line  */
    plain(0xA5A5, 2, 1);
    plain(0xF000, 2, 1);                                       /* F-line  */
    plain(0xF5A5, 2, 1);

    /* The privileged instructions, run at the supervisor level, where they are
     * legal: this half is the test that each one does what it says. The other
     * half -- that each one TRAPS in user mode -- is user_mode() below, which
     * clears S in the starting state and expects vector 8 every time. */
    /* RTE, over the frames UM 6.1.12 says it understands and one it does not.
     *
     * A frame is a WORD of status register at +$00, a LONG program counter at
     * +$02 and a WORD of format and vector at +$06, so a long-word poke at the
     * base carries the status register and the TOP HALF of the program
     * counter. Writing the obvious thing there instead put $1010 in the format
     * word, which is a throwaway frame, and the test then measured something
     * nobody meant to ask about. */
    rte_frame(0x0000, 0x00001010u, 0x0000);   /* $0, returning to user mode */
    rte_frame(0x2700, 0x00001010u, 0x0000);   /* $0, staying supervisor     */
    rte_frame(0x2000, 0x00001010u, 0x2000);   /* $2, a six-word frame       */
    rte_frame(0x2700, 0x00001010u, 0x7000);   /* and a format error          */
    plain2(0x46FC, 0x2700, 2, 0);                              /* MOVE #imm,SR */
    plain(0x40C0 | 3, 2, 0);                                   /* MOVE SR,D3   */
    plain2(0x027C, 0xF8FF, 2, 0);                              /* ANDI #x,SR   */
    plain2(0x007C, 0x0700, 2, 0);                              /* ORI  #x,SR   */
    plain2(0x0A7C, 0x1000, 2, 0);                              /* EORI #x,SR   */
    plain(0x4E60 | 3, 2, 0);                                   /* MOVE A3,USP  */
    plain(0x4E68 | 3, 2, 0);                                   /* MOVE USP,A3  */

    /* And a divide by zero, which no other group produces on purpose. */
    /* RD68021 had $82BC here, which is OR.L #imm,D1 and divides nothing. */
    plain2(0x82FC, 0x0000, 2, 1);                              /* DIVU.W #0,D1 */
    poke_n(2, DATA_BASE, 0);

    /* UM 6.1.6: "if a user program attempts to execute a privileged
     * instruction, a privilege violation exception occurs". Every one of these
     * is the same instruction as above with the S bit clear, and every one of
     * them must end at vector 8 with a four-word frame carrying the address of
     * the instruction that tried. */
    user_mode(0x4E73, 0, 0);                                   /* RTE          */
    user_mode(0x46FC, 0x2700, 1);                              /* MOVE #imm,SR */
    user_mode(0x40C0 | 3, 0, 0);                               /* MOVE SR,D3   */
    user_mode(0x027C, 0xF8FF, 1);                              /* ANDI #x,SR   */
    user_mode(0x007C, 0x0700, 1);                              /* ORI  #x,SR   */
    user_mode(0x0A7C, 0x1000, 1);                              /* EORI #x,SR   */
    user_mode(0x4E60 | 3, 0, 0);                               /* MOVE A3,USP  */
    user_mode(0x4E68 | 3, 0, 0);                               /* MOVE USP,A3  */
    user_mode(0x4E7A, 0x0000, 1);                              /* MOVEC SFC,D0 */
    user_mode(0x4E7B, 0x0000, 1);                              /* MOVEC D0,SFC */
}

/* Tracing -- UM 6.1.7 and table 6-2.
 *
 * The same instructions run three times: with tracing off, with T1 set (every
 * instruction is traced) and with T0 set (only those that change the flow). The
 * mix is chosen so that the second and third disagree -- a MOVEQ is traced by
 * one and not the other, a BRA by both -- because a test where they agree
 * cannot tell the two modes apart.
 *
 * T1 T0 = 11 is "undefined, reserved" in table 6-2 and is not swept.
 */
static void trace_at(unsigned int w0, unsigned int w1, int words, int flow)
{
    int i, k;
    static const unsigned int mode[3] = { 0x0000u, 0x8000u, 0x4000u };
    for (k = 0; k < 3; k++) {
        if (words) plain2(w0, w1, 2, flow);
        else       plain(w0, 2, flow);
        for (i = 0; i < 2; i++) {
            struct test *t = &tests[ntests - 1 - i];
            t->sr = (t->sr & 0x3FFFu) | mode[k];
        }
    }
}

static void g_trace(void)
{
    /* Instructions that do NOT change the flow. */
    trace_at(0x7042, 0, 0, 0);                  /* MOVEQ #$42,D0   */
    trace_at(0x2200, 0, 0, 0);                  /* MOVE.L D0,D1    */
    trace_at(0xD282, 0, 0, 0);                  /* ADD.L  D2,D1    */
    trace_at(0x4E71, 0, 0, 0);                  /* NOP             */

    /* ... and instructions that do. */
    trace_at(0x6004, 0, 0, 1);                  /* BRA.B  *+6      */
    trace_at(0x6000, 0x0006, 1, 1);             /* BRA.W           */
    trace_at(0x4EF8, 0x1010, 1, 1);             /* JMP $1010.W     */
    trace_at(0x4E40, 0, 0, 1);                  /* TRAP #0         */
    trace_at(0x4E76, 0, 0, 1);                  /* TRAPV           */

    /* A status register write counts as a change of flow -- UM 6.1.7, because
     * a real part re-prefetches after one. */
    trace_at(0x46FC, 0x2700, 1, 1);             /* MOVE #imm,SR    */
    trace_at(0x007C, 0x0000, 1, 1);             /* ORI  #0,SR      */

    /* And an instruction that is never executed, which UM 6.1.7 says is NOT
     * traced however the bits are set. */
    trace_at(0x4AFC, 0, 0, 1);                  /* ILLEGAL         */
    trace_at(0xA000, 0, 0, 1);                  /* A-line          */
}

/* MOVEC, both directions, over the control registers PRM 6 gives the MC68020
 * and the MC68030 alike. CACR, whose layout is the MC68030's own, is the
 * movec030 group. */
static void g_movec(void)
{
    static const unsigned int rc[7] = { 0x000, 0x001, 0x800, 0x801,
                                        0x802, 0x803, 0x804 };
    int i, ad, n;
    for (i = 0; i < 7; i++)
        for (ad = 0; ad < 2; ad++)
            for (n = 1; n < 4; n++) {
                unsigned int ext = (unsigned)(ad << 15)
                                 | (unsigned)(n << 12) | rc[i];
                plain2(0x4E7A, ext, 2, 0);      /* MOVEC Rc,Rn */
                plain2(0x4E7B, ext, 2, 0);      /* MOVEC Rn,Rc */
            }
}

/* CHK, word and long. About half of them trap, and the frame is compared. */
static void g_chk(void)
{
    sweep(0x4180 | (2 << 9), EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);   /* CHK.W */
    sweep(0x4100 | (2 << 9), EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);   /* CHK.L */
}


/* ------------------------------------------------------------------ */
/* The groups RD68031 adds                                             */
/* ------------------------------------------------------------------ */

/* CALLM and RTM -- the MC68020's module instructions. The MC68030 does not
 * have them (PRM table A-1), and their encodings, $06C0-$06FF, are not
 * anything else on it, so every one of them is an illegal instruction:
 * vector 4, a four-word frame, the PC of the instruction itself. */
static void g_illegal030(void)
{
    int r;
    unsigned int w[6];
    for (r = 0; r < 16; r++)
        plain(0x06C0u | (unsigned)r, 2, 1);                  /* RTM Rn          */
    plain2(0x06D0u | 1, 0x0004, 2, 1);                       /* CALLM #4,(A1)   */
    memset(w, 0, sizeof w);
    w[0] = 0x06E8u | 6; w[1] = 0x0008; w[2] = D16AN;         /* CALLM #8,(d16,A6) */
    emitn(2, 3, w, 0, 1);
    memset(w, 0, sizeof w);
    w[0] = 0x06F8u; w[1] = 0x0000; w[2] = ABSW;              /* CALLM #0,(xxx).W */
    emitn(2, 3, w, 0, 1);
    memset(w, 0, sizeof w);
    w[0] = 0x06FAu; w[1] = 0x0000; w[2] = 0x0100;            /* CALLM #0,(d16,PC) */
    emitn(2, 3, w, 1, 1);
}

/* MOVEC on the MC68030's own control registers -- PRM 6 and UM 6.3.1.
 *
 * CACR has the MC68030's layout, figure 6-14: WA DBE CD CED FD ED in the upper
 * byte, IBE CI CEI FI EI in the lower. CD, CED, CI and CEI are commands that
 * read back as zero, and the reserved bits read as zero, so what MOVEC reads
 * back is the written value under CACR_IMPL. This design stores the data-cache
 * bits without acting on them (doc/divergences.md); the read-back is the part
 * a program can see, and the part compared.
 *
 * And the control-register codes the MC68030 does not have -- the MC68040's
 * TC, ITT0-1, DTT0-1, MMUSR, URP and SRP, the MC68060's BUSCR and PCR, and an
 * unassigned one -- which PRM 6 makes illegal instructions. */
static void g_movec030(void)
{
    static const unsigned int vals[] = {
        0xFFFFFFFFu, 0x00003313u, 0x00000C0Cu, 0x00000909u, 0x00000101u,
        0x00002111u, 0x00001010u, 0x00000202u, 0x00000000u, 0x00000001u,
    };
    static const unsigned int bad[] = {
        0x003, 0x004, 0x005, 0x006, 0x007, 0x008, 0x805, 0x806, 0x807,
        0x808, 0x0FF, 0x123,
    };
    int i, n;
    for (i = 0; i < (int)(sizeof vals / sizeof vals[0]); i++) {
        /* MOVEC D1,CACR and MOVEC A1,CACR, with that value in the register */
        plain2(0x4E7B, 0x1002, 1, 0);
        tests[ntests - 1].d[1] = vals[i];
        plain2(0x4E7B, 0x9002, 1, 0);
        tests[ntests - 1].a[1] = vals[i];
        /* MOVEC CACR,D3 and CACR,A3, starting from that value as stored */
        plain2(0x4E7A, 0x3002, 1, 0);
        tests[ntests - 1].icacr = vals[i] & CACR_IMPL;
        plain2(0x4E7A, 0xB002, 1, 0);
        tests[ntests - 1].icacr = vals[i] & CACR_IMPL;
    }
    /* ... and random values, through every data register */
    for (n = 0; n < 8; n++) {
        plain2(0x4E7B, (unsigned)(n << 12) | 0x002, NPER, 0);
        plain2(0x4E7A, (unsigned)(n << 12) | 0x002, NPER, 0);
    }
    /* CAAR both ways, all thirty-two bits (UM 6.3.2) */
    plain2(0x4E7B, 0x5802, NPER, 0);
    plain2(0x4E7A, 0x5802, NPER, 0);
    /* the codes the MC68030 has no register for */
    for (i = 0; i < (int)(sizeof bad / sizeof bad[0]); i++) {
        plain2(0x4E7A, 0x1000u | bad[i], 1, 1);
        plain2(0x4E7B, 0x1000u | bad[i], 1, 1);
    }
    /* and CACR from the user level: a privilege violation */
    user_mode(0x4E7A, 0x1002, 1);
    user_mode(0x4E7B, 0x1002, 1);
}

/* CMP2 and CHK2 -- PRM 4. The bounds are a pair in memory, lower then upper,
 * at the operand's size; for an address register they are sign-extended to
 * thirty-two bits and compared as such, and either way the comparison works
 * for both signed and unsigned ranges (the upper bound below the lower one is
 * what distinguishes them).
 *
 * Random bounds against a random register are nearly always out of range, so
 * half the tests poke a pair that brackets the register -- and one in three of
 * those an inverted pair, the "unsigned" reading of the same two numbers. */
static void cmp2_bounds(int size, unsigned int lo, unsigned int hi)
{
    struct test *t = &tests[ntests - 1];
    unsigned int a = DATA_BASE + 0x100;     /* (xxx).W ABSW */
    if (t->npoke + 2 > 4) return;
    if (size == 0) {
        poke(a, ((lo & 0xFF) << 24) | ((hi & 0xFF) << 16) | 0x0000);
    } else if (size == 1) {
        poke(a, ((lo & 0xFFFF) << 16) | (hi & 0xFFFF));
    } else {
        poke(a, lo);
        poke(a + 4, hi);
    }
}

static void g_cmp2(void)
{
    int sz, chk, rn, k;
    for (sz = 0; sz < 3; sz++)
        for (chk = 0; chk < 2; chk++)
            for (rn = 0; rn < 2; rn++) {
                unsigned int base = (unsigned)(sz << 9) | 0x00C0u;
                unsigned int xw = (rn ? 0xA000u : 0x2000u) | (chk ? 0x0800u : 0);
                /* through every control mode, random bounds */
                sweep(base, EA_CTL, N_EA_CTL, 1, &xw, 2, chk);
                sweep_pc(base, 1, &xw, 2, chk);
                /* (xxx).W with bounds around the register */
                for (k = 0; k < NPER; k++) {
                    unsigned int w[6], v, lo, hi, span;
                    memset(w, 0, sizeof w);
                    w[0] = base | (7 << 3) | 0; w[1] = xw; w[2] = ABSW;
                    emit(3, w, 0, chk);
                    v = rn ? tests[ntests - 1].a[2] : tests[ntests - 1].d[2];
                    span = (unsigned)(k + 1) * 3u;
                    if (sz == 0) v = rn ? v : (v & 0xFF);
                    if (sz == 1) v = rn ? v : (v & 0xFFFF);
                    lo = v - span + (unsigned)(k & 1) * span;   /* on the bound, half the time */
                    hi = v + span;
                    if (k == 4) { unsigned int x = lo; lo = hi; hi = x; }
                    cmp2_bounds(sz, lo, hi);
                }
            }
}

/* CAS and CAS2 -- PRM 4. A compare and a conditional write, as one
 * indivisible read-modify-write cycle (UM 7.6.1). Both outcomes are reached:
 * a random compare operand almost never matches, so for the absolute modes,
 * whose operand the generator can compute from the fill, half the tests are
 * given the operand in Dc. */
static void g_cas(void)
{
    static const unsigned int SZ[3] = { 0x0A00u, 0x0C00u, 0x0E00u };
    int s, k, i;
    for (s = 0; s < 3; s++) {
        unsigned int xw = (5u << 6) | 2u;       /* Du = D5, Dc = D2 */
        sweep(SZ[s] | 0x00C0u, EA_MEM, N_EA_MEM, 1, &xw, NPER, 0);
        for (k = 0; k < NPER; k++) {
            unsigned int w[6], v, off = 0x100;
            memset(w, 0, sizeof w);
            w[0] = SZ[s] | 0x00C0u | (7 << 3) | 0; w[1] = xw; w[2] = ABSW;
            emit(3, w, 0, 0);
            if (k & 1) continue;
            v = fill_word(ntests - 1, off);
            if (s == 0) v >>= 24;
            if (s == 1) v >>= 16;
            tests[ntests - 1].d[2] = (tests[ntests - 1].d[2] & ~(s == 0 ? 0xFFu : s == 1 ? 0xFFFFu : 0xFFFFFFFFu)) | v;
        }
    }
    /* CAS2.W and CAS2.L, (A1) and (A2), Dc1:Dc2 = D2:D3, Du1:Du2 = D4:D5. Both
     * addresses are made even here: CAS2 on a misaligned operand is the
     * subject of no sentence in the manual worth testing against. */
    for (s = 1; s < 3; s++)
        for (i = 0; i < 2; i++)
            for (k = 0; k < NPER; k++) {
                unsigned int w[6];
                struct test *t;
                memset(w, 0, sizeof w);
                w[0] = SZ[s] | 0x00FCu;
                w[1] = 0x9000u | (4u << 6) | 2u;      /* (A1), Du D4, Dc D2 */
                w[2] = 0xA000u | (5u << 6) | 3u;      /* (A2), Du D5, Dc D3 */
                emit(3, w, 0, 0);
                t = &tests[ntests - 1];
                t->a[1] &= ~3u;
                t->a[2] = (t->a[1] + 0x40u) & 0x23FCu;
                if (i) {
                    /* make the first comparison succeed */
                    unsigned int v = fill_word(ntests - 1, t->a[1] - DATA_BASE);
                    t->d[2] = s == 1 ? (t->d[2] & 0xFFFF0000u) | (v >> 16) : v;
                    if (k & 1) {
                        unsigned int v2 = fill_word(ntests - 1, t->a[2] - DATA_BASE);
                        t->d[3] = s == 1 ? (t->d[3] & 0xFFFF0000u) | (v2 >> 16) : v2;
                    }
                }
            }
}

/* The bit-field instructions on MEMORY -- PRM 4. The field arithmetic is the
 * bitfield group's; what this adds is the base address, the byte count, and
 * the NOTE that a bit-field instruction "accesses only those bytes in memory
 * that contain some portion of the bit field". Offsets in a register are
 * signed and reach anywhere in the address space, so the registers that hold
 * one are given small values, positive and negative, that keep the field in
 * the data block. */
static void g_bitfield_mem(void)
{
    static const unsigned int OPS[] = {
        0xE8C0u, 0xE9C0u, 0xEAC0u, 0xEBC0u, 0xECC0u, 0xEDC0u, 0xEEC0u, 0xEFC0u,
    };
    static const unsigned int XW[] = {
        0x0000u, 0x0001u, 0x0008u, 0x01C7u, 0x0148u, 0x07C0u,
        0x0820u, 0x0925u, 0x08A0u,
    };
    static const struct eamode M[] = {
        { 2, 1, 0, { 0, 0 }, 0 },
        { 5, 6, 1, { D16AN, 0 }, 0 },
        { 7, 0, 1, { ABSW, 0 }, 0 },
    };
    int i, j, m, k;
    for (i = 0; i < 8; i++)
        for (j = 0; j < (int)(sizeof XW / sizeof XW[0]); j++)
            for (m = 0; m < 3; m++) {
                unsigned int xw = XW[j] | 0x3000u;
                sweep(OPS[i], &M[m], 1, 1, &xw, 2, 0);
                for (k = 0; k < 2; k++) {
                    struct test *t = &tests[ntests - 1 - k];
                    t->d[0] = (t->d[0] & 0x7Fu) - 0x40u;     /* -64 .. 63 */
                    t->d[2] = (t->d[2] & 0x1FFu) - 0x100u;   /* -256 .. 255 */
                    t->d[4] = (t->d[4] & 0x3Fu) - 0x20u;
                }
            }
}

/* PACK and UNPK on memory, -(Ay),-(Ax),#adj -- PRM 4. PACK reads two bytes and
 * writes one; UNPK reads one and writes two. Which of the two bytes is the
 * significant one is the question (doc/divergences.md). */
static void g_packunpk_mem(void)
{
    static const unsigned int ADJ[] = { 0x0000u, 0x0001u, 0x9999u, 0x6666u,
                                        0x0F0Fu, 0xF0F0u, 0x00FFu, 0x8000u };
    int i;
    for (i = 0; i < (int)(sizeof ADJ / sizeof ADJ[0]); i++) {
        plain2(0x8148u | (2 << 9) | 3, ADJ[i], NPER, 0);    /* PACK -(A3),-(A2) */
        bcd_operands(NPER);
        plain2(0x8188u | (2 << 9) | 3, ADJ[i], NPER, 0);    /* UNPK -(A3),-(A2) */
        bcd_operands(NPER);
    }
}

/* ------------------------------------------------------------------ */
/* The MMU instructions -- M11                                          */
/*                                                                     */
/* PRM 6 ("MC68030 only") and UM 9.7-9.8. One instruction from a state  */
/* that includes the MMU's registers, with the ATC empty, and for the   */
/* instructions that search, a small fixed translation tree:            */
/*                                                                     */
/*   TC  $80888800: E, PS 256, IS 8, TIA 8, TIB 8 -- logical bits 23-16 */
/*       index table A, bits 15-8 table B                              */
/*   CRP = SRP = $7FFF0002:$3000 -- A at $3000, short                   */
/*   A[0] -> B at $3100; A[1] an early-termination page descriptor      */
/*   for $0001xxxx; A[2] invalid; A[3] -> B with WP                     */
/*   B[i] maps page $ii00 to itself for $00-$27 and $30-$3F, and:       */
/*     $28 invalid, $29 WP, $2A U and M already set, $2B CI,            */
/*     $2C indirect, through $3080, to page $2C00                       */
/*   TT0 $00008143 ($00xxxxxx, supervisor spaces), so that the test's   */
/*   own fetches, stack and vectors are never searched.                 */
/*                                                                     */
/* The tables are laid down by the stream and compared after the run,   */
/* which checks the U and M bits PLOAD writes and PTEST must not.       */
/* ------------------------------------------------------------------ */

#define TBL_A   0x3000u
#define TBL_B   0x3100u
#define TBL_IND 0x3080u
#define TC_ON   0x80888800u

static const unsigned int MS_ON[8] = {
    TC_ON, 0x7FFF0002u, TBL_A, 0x7FFF0002u, TBL_A, 0x00008143u, 0, 0
};

/* The tree, as (address, value) pairs: what the stream carries. */
#define NTBL 24
static unsigned int tbl_a[NTBL], tbl_v[NTBL];
static int ntbl_fixed;
static void tbl_build(void)
{
    int n = 0, i;
    if (ntbl_fixed) return;
    tbl_a[n] = TBL_A;       tbl_v[n++] = TBL_B | 2;          /* A[0] */
    tbl_a[n] = TBL_A + 4;   tbl_v[n++] = 0x00000001u;        /* A[1]: early termination */
    tbl_a[n] = TBL_A + 8;   tbl_v[n++] = 0;                  /* A[2]: invalid */
    tbl_a[n] = TBL_A + 12;  tbl_v[n++] = TBL_B | 2 | 4;      /* A[3]: WP */
    for (i = 0x20; i < 0x30; i++) {
        unsigned int v = ((unsigned)i << 8) | 1;
        if (i == 0x28) v = 0;
        if (i == 0x29) v |= 4;
        if (i == 0x2A) v |= 0x18;
        if (i == 0x2B) v |= 0x40;
        if (i == 0x2C) v = TBL_IND | 2;
        tbl_a[n] = TBL_B + 4u * (unsigned)i; tbl_v[n++] = v;
    }
    tbl_a[n] = TBL_IND;     tbl_v[n++] = 0x00002C01u;        /* the indirect's target */
    ntbl_fixed = n;
}

/* The identity entries the test never inspects are written once, as part
 * of the fixed memory image, on both sides: B[$00]-B[$1F] and B[$30]-B[$3F]
 * (core_vec_tb writes the same). */
static void mmu_state(const unsigned int *ms, int tables)
{
    struct test *t = &tests[ntests - 1];
    int i;
    for (i = 0; i < 8; i++) t->imt[i] = ms[i];
    t->tables = tables;
}

/* The address register an instruction's <ea> names, set to an address. */
static void set_a(int r, unsigned int v) { tests[ntests - 1].a[r] = v; }

#define OPND 0x2200u    /* PMOVE's memory operand, through (A1) */

/* PMOVE: command words, PRM 6. */
#define PM_TC    0x4000u
#define PM_SRP   0x4800u
#define PM_CRP   0x4C00u
#define PM_TT0   0x0800u
#define PM_TT1   0x0C00u
#define PM_MMUSR 0x6000u
#define PM_RD    0x0200u   /* register to memory */
#define PM_FD    0x0100u

static void pm_one(unsigned int cw, const unsigned int *ms, unsigned int v0, unsigned int v1,
                   unsigned int r_tc)
{
    unsigned int st[8];
    memcpy(st, ms, sizeof st);
    plain2(0xF011, cw, 1, 0);               /* PMOVE (A1) */
    st[0] = r_tc;
    mmu_state(st, 1);
    set_a(1, OPND);
    poke(OPND, v0);
    poke(OPND + 4, v1);
}

static void g_pmmu(void)
{
    static const unsigned int tcv[] = {
        0x00000000u, TC_ON, 0x82888800u /* SRE */, 0x81888800u /* FCL: 8+8+8+8 + 3 */,
        0x80888700u /* sum 31 */, 0x80788900u /* PS 7 */, 0x80F84500u /* PS 32K, IS 8, 4+5 */,
        0x80888808u /* TID ignored after a zero TIC? */, 0x03FFFFFFu /* E clear */,
        0x80C0AA00u, 0x80D0A900u /* PS 8K */, 0xFFFFFFFFu,
    };
    static const unsigned int rpv[][2] = {
        { 0x7FFF0002u, TBL_A }, { 0x00000002u, TBL_A }, { 0x80000003u, TBL_A },
        { 0x7FFF0001u, 0x00000000u }, { 0x00000000u, TBL_A } /* DT 0 */,
        { 0xFFFFFFFFu, 0xFFFFFFFFu }, { 0x0000FFFCu, 0x0000300Fu } /* reserved bits */,
    };
    static const unsigned int ttv[] = {
        0x00000000u, 0x00008143u, 0xFFFFFFFFu, 0x0000877Fu, 0x40FF8507u, 0x12008270u,
    };
    static const unsigned int regs[] = { PM_TC, PM_SRP, PM_CRP, PM_TT0, PM_TT1, PM_MMUSR };
    unsigned int ms_off_tc[8];
    unsigned int w[6];
    int i, j, fd, r;

    tbl_build();
    memcpy(ms_off_tc, MS_ON, sizeof ms_off_tc);

    /* PMOVE <register> to memory, each register from a varied starting value
     * (TC with E clear: a random enabled TC would translate the test). */
    for (r = 0; r < 6; r++)
        for (i = 0; i < NPER; i++) {
            unsigned int st[8];
            memcpy(st, MS_ON, sizeof st);
            /* Only bits each register has (UM 9.7, doc/mmu.md): the oracle
             * keeps the others (doc/oracles.md), and a value with them set
             * would compare that rather than PMOVE. Those are checked by the
             * writes below, whose final registers are compared under the
             * same masks. */
            st[0] = rnd() & 0x03FFFFFFu;
            st[1] = (rnd() & 0xFFFF0000u) | 2; st[2] = rnd() & 0xFFFFFFF0u;
            st[3] = (rnd() & 0xFFFF0000u) | 3; st[4] = rnd() & 0xFFFFFFF0u;
            st[5] = rnd() & 0xFFFF0777u;        /* not enabled: the test runs through */
            st[6] = rnd() & 0xFFFF0777u;
            st[7] = rnd() & 0xEE47u;
            plain2(0xF011, regs[r] | PM_RD, 1, 0);
            mmu_state(st, 1);
            set_a(1, OPND);
        }
    /* PMOVE memory to <register>, with and without FD, from a state with
     * translation off and the tree ready. */
    for (fd = 0; fd < 2; fd++) {
        for (i = 0; i < (int)(sizeof tcv / sizeof tcv[0]); i++)
            pm_one(PM_TC | (fd ? PM_FD : 0), ms_off_tc, tcv[i], 0, 0);
        for (i = 0; i < (int)(sizeof rpv / sizeof rpv[0]); i++) {
            pm_one(PM_SRP | (fd ? PM_FD : 0), ms_off_tc, rpv[i][0], rpv[i][1], 0);
            pm_one(PM_CRP | (fd ? PM_FD : 0), ms_off_tc, rpv[i][0], rpv[i][1], 0);
            /* ... and with translation on: the new root pointer is used */
            pm_one(PM_CRP | (fd ? PM_FD : 0), ms_off_tc, rpv[i][0], rpv[i][1], TC_ON);
        }
        for (i = 0; i < (int)(sizeof ttv / sizeof ttv[0]); i++) {
            pm_one(PM_TT0 | (fd ? PM_FD : 0), ms_off_tc, ttv[i], 0, 0);
            pm_one(PM_TT1 | (fd ? PM_FD : 0), ms_off_tc, ttv[i], 0, 0);
        }
    }
    for (i = 0; i < NPER; i++) {
        pm_one(PM_MMUSR, ms_off_tc, rnd(), 0, 0);
    }
    pm_one(PM_MMUSR | PM_FD, ms_off_tc, 0x12345678u, 0, 0);     /* FD with MMUSR */
    pm_one(PM_MMUSR | PM_FD | PM_RD, ms_off_tc, 0, 0, 0);

    /* PMOVE through the other control alterable modes, both directions. */
    for (j = 0; j < N_EA_CTL; j++)
        for (r = 0; r < 2; r++) {
            unsigned int cw = PM_TT1 | (r ? PM_RD : 0);
            unsigned int st[8];
            int n = 0, k;
            memcpy(st, MS_ON, sizeof st);
            st[0] = 0;
            memset(w, 0, sizeof w);
            w[n++] = 0xF000u | (unsigned)(EA_CTL[j].mode << 3) | (unsigned)EA_CTL[j].reg;
            w[n++] = cw;
            for (k = 0; k < EA_CTL[j].next; k++) w[n++] = EA_CTL[j].ext[k];
            emitn(2, n, w, 0, 0);
            mmu_state(st, 1);
            tests[ntests - 2].imt[0] = 0;
            memcpy(tests[ntests - 2].imt, st, sizeof st);
            tests[ntests - 2].tables = 1;
        }
    /* ... and the modes PMOVE does not take (UM 9.6, "only control-alterable
     * addressing modes"): Dn, An, (An)+, -(An), (d16,PC), #<data>. */
    {
        static const unsigned int bad_ea[] = { 0x01, 0x09, 0x19, 0x21, 0x3A, 0x3C };
        for (i = 0; i < 6; i++)
            for (r = 0; r < 2; r++) {
                unsigned int st[8];
                memcpy(st, MS_ON, sizeof st);
                st[0] = 0;
                memset(w, 0, sizeof w);
                w[0] = 0xF000u | bad_ea[i];
                w[1] = PM_TC | (r ? PM_RD : 0);
                w[2] = 0x0010; w[3] = 0x0020;
                emit(4, w, bad_ea[i] == 0x3A, 1);
                mmu_state(st, 1);
                set_a(1, OPND);
            }
    }

    /* PTEST: levels 0, 1, 2 and 7, read and write, against every kind of
     * entry in the tree; level 7 also with an address register (A3). The
     * function code from the instruction (#1, #5), and once each from D1,
     * SFC and DFC. A2 holds the logical address. */
    {
        static const unsigned int la[] = {
            0x00002480u, 0x00002800u, 0x00002910u, 0x00002A20u, 0x00002B30u,
            0x00002C40u, 0x00012340u, 0x00022340u, 0x00032340u, 0x00FF2340u,
        };
        static const unsigned int lv[] = { 0, 1, 2, 7 };
        int l, rw, f;
        for (i = 0; i < (int)(sizeof la / sizeof la[0]); i++)
            for (l = 0; l < 4; l++)
                for (rw = 0; rw < 2; rw++)
                    for (f = 0; f < 2; f++) {
                        unsigned int fc = f ? 0x15u : 0x11u;      /* #5, #1 */
                        unsigned int cw = 0x8000u | (lv[l] << 10) | (rw ? 0x200u : 0) | fc;
                        plain2(0xF012, cw, 1, 0);                 /* PTEST (A2) */
                        mmu_state(MS_ON, 1);
                        set_a(2, la[i]);
                        if (lv[l] == 7) {
                            plain2(0xF012, cw | 0x100u | (3u << 5), 1, 0);  /* A3 */
                            mmu_state(MS_ON, 1);
                            set_a(2, la[i]);
                        }
                    }
        /* the function code from D1, SFC, DFC */
        for (i = 0; i < 3; i++) {
            unsigned int fcf = (i == 0) ? 0x09u : (i == 1) ? 0x00u : 0x01u;
            plain2(0xF012, 0x9E00u | fcf, 2, 0);              /* PTESTR level 7 */
            for (j = 0; j < 2; j++) {
                tests[ntests - 1 - j].d[1] = 0x00000001u + 4u * (unsigned)j;
                memcpy(tests[ntests - 1 - j].imt, MS_ON, sizeof MS_ON);
                tests[ntests - 1 - j].tables = 1;
                tests[ntests - 1 - j].a[2] = 0x00002910u;
            }
        }
        /* level 0 under TT1: T, whatever R/W says when RWM is set; when it is
         * clear, R/W decides (UM 9.8, PTEST) */
        for (rw = 0; rw < 2; rw++)
            for (j = 0; j < 2; j++) {
                unsigned int st[8];
                memcpy(st, MS_ON, sizeof st);
                st[6] = j ? 0x00008151u : 0x00008051u;    /* FC 5; RWM, or R/W = 0 (write) */
                plain2(0xF012, 0x8000u | (rw ? 0x200u : 0) | 0x15u, 1, 0);
                mmu_state(st, 1);
                set_a(2, 0x00002480u);
            }
    }

    /* PLOAD, read and write, every kind of entry: the U and M bits it writes
     * (in the tables, compared after), MMUSR untouched. */
    {
        static const unsigned int la[] = {
            0x00002480u, 0x00002800u, 0x00002910u, 0x00002A20u, 0x00002B30u,
            0x00002C40u, 0x00012340u, 0x00022340u, 0x00032340u,
        };
        int rw, f;
        for (i = 0; i < (int)(sizeof la / sizeof la[0]); i++)
            for (rw = 0; rw < 2; rw++)
                for (f = 0; f < 2; f++) {
                    plain2(0xF012, 0x2000u | (rw ? 0x200u : 0) | (f ? 0x15u : 0x11u), 1, 0);
                    mmu_state(MS_ON, 1);
                    set_a(2, la[i]);
                }
    }

    /* PFLUSH: every form, from a state with translation on (the ATC is empty,
     * so what is checked is that each is legal and touches nothing). */
    {
        static const unsigned int cw[] = {
            0x2400u,                    /* PFLUSHA */
            0x30F1u, 0x3015u, 0x3080u,  /* PFLUSH #1,#7 / #5,#0 / SFC,#4 */
            0x30E9u,                    /* PFLUSH D1,#7 */
            0x3001u,                    /* PFLUSH DFC,#0 */
            0x38F5u, 0x3815u, 0x38E9u,  /* PFLUSH ... ,(A2) */
        };
        for (i = 0; i < (int)(sizeof cw / sizeof cw[0]); i++) {
            plain2((cw[i] & 0x0800u) ? 0xF012u : 0xF000u, cw[i], 1, 0);
            mmu_state(MS_ON, 1);
            set_a(2, 0x00002480u);
        }
    }

    /* Undefined command words and forms (F-line, UM 8.1.5): PMOVE group 011
     * with another register, group 111, PFLUSH's undefined modes, PFLUSHA
     * with an <ea>, PTEST level 0 with an address register, PLOAD with its
     * reserved bits. */
    {
        static const unsigned int bad[][2] = {
            /* Not here: command words $C000 and $E000 and PFLUSHA with an
             * <ea>, which PRM 6 does not define and the oracle executes as
             * if they were something (doc/m11-mismatches.md, b-pmmu);
             * core_m030_tb checks the F-line for them. */
            { 0xF011, 0x6400u }, { 0xF011, 0x7000u },
            { 0xF000, 0x2800u }, { 0xF000, 0x3400u },
            { 0xF012, 0x8115u }, { 0xF012, 0x2035u },
            { 0xF011, 0x4400u }, { 0xF011, 0x5000u }, { 0xF011, 0x0000u },
        };
        for (i = 0; i < (int)(sizeof bad / sizeof bad[0]); i++) {
            plain2(bad[i][0], bad[i][1], 1, 1);
            mmu_state(MS_ON, 1);
            set_a(1, OPND);
            set_a(2, 0x00002480u);
        }
    }

    /* Privilege: every instruction in user mode -- UM 9.8, the privilege
     * check is on the operation word. */
    {
        static const unsigned int cw[] = { PM_TC, PM_TC | PM_RD, 0x2400u, 0x9E15u, 0x2215u };
        for (i = 0; i < (int)(sizeof cw / sizeof cw[0]); i++) {
            user_mode(cw[i] == 0x2400u ? 0xF000u : 0xF011u, cw[i], 1);
            for (j = 0; j < 2; j++) {
                memcpy(tests[ntests - 1 - j].imt, MS_ON, sizeof MS_ON);
                tests[ntests - 1 - j].imt[0] = 0;
                tests[ntests - 1 - j].tables = 1;
                tests[ntests - 1 - j].a[1] = OPND;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* The catalogue                                                       */
/* ------------------------------------------------------------------ */

struct group { const char *name; void (*build)(void); };

static const struct group GROUPS[] = {
    { "move",    g_move    },
    { "moveq",   g_moveq   },
    { "unary",   g_unary   },
    { "misc",    g_misc    },
    { "addr",    g_addr    },
    { "alu",     g_alu     },
    { "imm",     g_imm     },
    { "extend",  g_extend  },
    { "shift",   g_shift   },
    { "bit",     g_bit     },
    { "cond",    g_cond    },
    { "jump",    g_jump    },
    { "muldiv",  g_muldiv  },
    { "bcd",     g_bcd     },
    { "packunpk",g_packunpk},
    { "packunpk_mem", g_packunpk_mem },
    { "bitfield",g_bitfield},
    { "bitfield_mem", g_bitfield_mem },
    { "moves",   g_moves   },
    { "tas",     g_tas     },
    { "cas",     g_cas     },
    { "cmp2",    g_cmp2    },
    { "movem",   g_movem   },
    { "movep",   g_movep   },
    { "ccr",     g_ccr     },
    { "chk",     g_chk     },
    { "movec",   g_movec   },
    { "movec030",g_movec030},
    { "illegal030", g_illegal030 },
    { "traps",   g_traps   },
    { "trace",   g_trace   },
    { "pmmu",    g_pmmu    },
    /* M10's "cache" (data-cache behaviour, CACR ED/WA/FD set in the starting
     * state) is not here: make cache and core_cache_tb cover it. */
};
#define NGROUPS ((int)(sizeof GROUPS / sizeof GROUPS[0]))

/* The program area is filled with NOPs before the instruction is written, on
 * both sides, so that a branch has somewhere defined to land and a
 * memory-indirect mode that reads the instruction stream reads the same thing
 * here as it does in the core's memory. */
#define PROG_FILL  0x40

struct acc {
    unsigned int addr, rw, bytes, prog, value, mask;
};

enum { KEEP = 0, DROP_ROOM, DROP_HALT, DROP_BUSERR, NDROP };
static const char *const DROP_WHY[NDROP] = {
    "", "more accesses than there is room to record", "the oracle halted",
    "a bus or address error (long frame)",
};

struct result {
    int          why;
    int          exc;          /* the first exception vector taken, or -1 */
    unsigned int d[8], a[7], usp, isp, sr, pc;
    unsigned int msp, vbr, sfc, dfc, caar, cacr;
    unsigned int srmask;
    int          nacc;
    struct acc   acc[MAXACC];
    unsigned int fmt[8];        /* the MMU's registers after */
    unsigned int tblv[NTBL];    /* the tables after */
};

static struct result *res;      /* shared with the child that runs the oracle */
static volatile int  *progress; /* the test the child is on */

/* ------------------------------------------------------------------ */
/* Running the oracle                                                  */
/* ------------------------------------------------------------------ */

static int          base_idx;   /* the child's first test */
static int          cur;        /* the test being run */
static int          recording;
static int          cur_pcrel;
static int          overflowed;
static int          berr_seen;
static int          nexc;           /* exceptions this test, and where each began */
static int          exc_vec[4], exc_at[4];

static void wr8(unsigned int a, unsigned int v)  { uae030_ram()[a] = (uint8_t)v; }
static void wr16(unsigned int a, unsigned int v) { wr8(a, v >> 8); wr8(a + 1, v); }
static void wr32(unsigned int a, unsigned int v) { wr16(a, v >> 16); wr16(a + 2, v & 0xFFFF); }

static void on_op(uint32_t pa, int size, int write, uint32_t data, int fc, int berr, void *u)
{
    struct result *r = &res[cur];
    struct acc *a;
    (void)u;
    if (!recording) return;
    if (berr) berr_seen = 1;
    if (r->nacc >= MAXACC) { overflowed = 1; return; }
    a = &r->acc[r->nacc++];
    a->addr  = pa;
    a->rw    = !write;
    a->bytes = (unsigned)size;
    /* MC68030 UM 2.4.11-2.4.14: a program-counter-relative mode's reads are
     * program references; the oracle drives data space for them
     * (doc/oracles.md), so the mode decides. Its writes -- PEA's push, a MOVE
     * destination -- go somewhere else by construction and are data. So is
     * whatever exception processing reads, the vector included. */
    a->prog  = ((fc & 3) == 2) || (cur_pcrel && !write && nexc == 0);
    a->value = write ? data : 0;
    a->mask  = 0xFFFFFFFFu;
}

/* VEC_DEBUG=<index> prints every bus access the oracle makes for that test,
 * instruction fetches included, on stderr -- for triage. */
static int debug_idx = -1;

static void on_bus(uint32_t pa, int size, int write, uint32_t data, int fc, int kind,
                   int berr, void *u)
{
    (void)u;
    if (cur != debug_idx || !recording) return;
    fprintf(stderr, "  bus %c %08x %d %0*x fc=%d%s%s\n", write ? 'W' : 'R', pa, size,
            size * 2, data, fc, kind == 1 ? " walk" : kind == 2 ? " ifetch" : "",
            berr ? " BERR" : "");
}

static void on_exc(int vector, void *u)
{
    (void)u;
    if (cur == debug_idx && recording) fprintf(stderr, "  exception %d\n", vector);
    if (recording && res[cur].exc < 0) res[cur].exc = vector;
    if (recording && nexc < 4) {
        exc_vec[nexc] = vector;
        exc_at[nexc]  = res[cur].nacc;
        nexc++;
    }
}

static int mmu_dirty = 1;
static void setup(int i, uae030_state *st, void *u)
{
    struct test *t;
    int j;
    (void)u;
    cur = base_idx + i;
    *progress = cur;
    t = &tests[cur];

    memset(uae030_ram(), 0, 0x10000);
    /* Each exception vector points somewhere DIFFERENT, so that an
     * instruction which trapped through the wrong one shows as a wrong
     * program counter rather than as nothing at all. */
    for (j = 0; j < 256; j++)
        wr32((unsigned)j * 4, 0x00009000u + (unsigned)j * 4);
    wr32(0, STACK);
    wr32(4, PROG_BASE);
    for (j = 0; j < DATA_SIZE; j += 4) {
        unsigned int fw = fill_word(cur, (unsigned)j);
        wr32(DATA_BASE + (unsigned)j, t->bcdfill ? bcd_word(fw) : fw);
    }
    for (j = 0; j < PROG_FILL; j += 2)
        wr16(PROG_BASE + (unsigned)j, 0x4E71);
    for (j = 0; j < t->nwords; j++)
        wr16(PROG_BASE + (unsigned)j * 2, t->w[j]);
    for (j = 0; j < t->npoke; j++)
        wr32(t->poke_a[j], t->poke_v[j]);
    /* The pmmu tree: the identity entries nobody inspects, then the pairs
     * the stream carries. Zero everywhere else, for every other test. */
    for (j = 0; j < 0x40; j++)
        wr32(TBL_B + 4u * (unsigned)j, t->tables ? (((unsigned)j << 8) | 1u) : 0);
    for (j = 0; j < 4; j++) wr32(TBL_A + 4u * (unsigned)j, 0);
    wr32(TBL_IND, 0);
    if (t->tables) {
        tbl_build();
        for (j = 0; j < ntbl_fixed; j++) wr32(tbl_a[j], tbl_v[j]);
    }
    /* Only when this test has MMU state, or the last one did: installing the
     * registers re-decodes them and flushes the ATC, which every other group
     * has no need of (and was generated without, before M11). */
    if (t->tables || mmu_dirty) {
        uae030_state ms;
        mmu_dirty = t->tables;
        memset(&ms, 0, sizeof ms);
        ms.tc    = t->imt[0];
        ms.crp   = ((uint64_t)t->imt[1] << 32) | t->imt[2];
        ms.srp   = ((uint64_t)t->imt[3] << 32) | t->imt[4];
        ms.tt0   = t->imt[5];
        ms.tt1   = t->imt[6];
        ms.mmusr = (uint16_t)t->imt[7];
        uae030_set_mmu(&ms);
    }

    for (j = 0; j < 8; j++) st->d[j] = t->d[j];
    for (j = 0; j < 7; j++) st->a[j] = t->a[j];
    st->usp  = t->usp;
    st->isp  = t->isp;
    st->msp  = t->imsp;
    st->sr   = (uint16_t)t->sr;
    st->sfc  = t->isfc;
    st->dfc  = t->idfc;
    st->vbr  = t->ivbr;
    st->caar = t->icaar;
    st->cacr = t->icacr;
    st->pc   = PROG_BASE;

    res[cur].nacc = 0;
    res[cur].exc  = -1;
    overflowed = 0;
    berr_seen  = 0;
    nexc       = 0;
    cur_pcrel  = t->pcrel;
    recording  = 1;
}

/* PRM 4's undefined condition codes, decided after the run because two of
 * them depend on what happened: a divide only leaves N and Z undefined when
 * it overflowed, and N, Z and V when the divisor was zero. */
static unsigned int undefined_ccr(const struct test *t, unsigned int sr_after, int exc)
{
    unsigned int op = t->w[0], m = 0xFFFFu;
    int is_abcd = ((op & 0xF1F0u) == 0xC100u)     /* ABCD */
               || ((op & 0xF1F0u) == 0x8100u)     /* SBCD */
               || ((op & 0xFFC0u) == 0x4800u);    /* NBCD */
    int is_divw = ((op & 0xF0C0u) == 0x80C0u)     /* DIVU.W, DIVS.W */
               && ((op & 0x01C0u) == 0x00C0u || (op & 0x01C0u) == 0x01C0u);
    int is_divl = ((op & 0xFFC0u) == 0x4C40u);    /* DIVU.L, DIVS.L */
    int is_chk  = ((op & 0xF040u) == 0x4000u)
               && (((op >> 6) & 7) == 6 || ((op >> 6) & 7) == 4)
               && ((op & 0xF000u) == 0x4000u) && ((op & 0x0100u) != 0);
    if (is_abcd)                                  m &= ~0x000Au;  /* N and V   */
    if ((is_divw || is_divl) && exc == 5)         m &= ~0x000Eu;  /* N, Z, V   */
    else if ((is_divw || is_divl) && (sr_after & 2)) m &= ~0x000Cu; /* N and Z */
    if (is_chk)                                   m &= ~0x000Fu;  /* N Z V C   */
    /* CMP2 and CHK2: "N -- undefined. V -- undefined." */
    if ((op & 0xF9C0u) == 0x00C0u && (op & 0x0600u) != 0x0600u
        && ((t->w[1] & 0x07FFu) == 0))           m &= ~0x000Au;
    return m;
}

/* Where the oracle's order of accesses differs from the order the manual
 * gives, the manual's is recorded (doc/oracles.md, "Quirks"). Each case is
 * narrow, and each moves accesses the oracle made; none invents one. */
static void move_acc(struct result *r, int from, int to)
{
    struct acc a = r->acc[from];
    int j;
    if (from < to) for (j = from; j < to; j++) r->acc[j] = r->acc[j + 1];
    else           for (j = from; j > to; j--) r->acc[j] = r->acc[j - 1];
    r->acc[to] = a;
}

static void normalise(const struct test *t, struct result *r, const uae030_state *s)
{
    int e, j, end, vbr;
    /* UM 8.1: the third step of exception processing builds the stack frame,
     * the last fetches the vector. The oracle fetches the vector first. Within
     * each exception's run of accesses, the vector read goes after the frame. */
    for (e = 0; e < nexc; e++) {
        int at = exc_at[e];
        end = (e + 1 < nexc) ? exc_at[e + 1] : r->nacc;
        for (vbr = 0; vbr < 2; vbr++) {
            unsigned int va = (vbr ? s->vbr : t->ivbr) + 4u * (unsigned)exc_vec[e];
            if (at < end && r->acc[at].rw && r->acc[at].bytes == 4 && r->acc[at].addr == va) {
                for (j = at + 1; j < end && !r->acc[j].rw; j++) ;
                move_acc(r, at, j - 1);
                break;
            }
        }
    }
    /* UM 8.1.13 (RTE): the processor checks the frame's format first, then reads
     * the frame. The oracle reads the status register first; the format word
     * (SP+6) is moved to the front. */
    if (t->w[0] == 0x4E73u && r->nacc >= 2) {
        unsigned int sp = (t->sr & 0x2000u) ? ((t->sr & 0x1000u) ? t->imsp : t->isp) : 0;
        for (j = 1; j < r->nacc && r->acc[j].rw; j++)
            if (r->acc[j].bytes == 2 && r->acc[j].addr == sp + 6) { move_acc(r, j, 0); break; }
    }
    /* UM 8.4 (the format $2 frame): for CHK, CHK2, TRAPcc, TRAPV
     * and the zero divide, the instruction address is "the address of the
     * instruction that caused the exception". For all but CHK the oracle
     * stacks the next instruction's address there; the manual's is recorded.
     * The field is the top long word of the instruction's own frame. */
    if (r->exc == 5 || r->exc == 6 || r->exc == 7) {
        unsigned int sp0 = (t->sr & 0x2000u) && (t->sr & 0x1000u) ? t->imsp : t->isp;
        for (j = 0; j < r->nacc; j++)
            if (!r->acc[j].rw && r->acc[j].bytes == 4 && r->acc[j].addr == sp0 - 4) {
                r->acc[j].value = PROG_BASE;
                break;
            }
    }
    /* UM 8.1.13 again: RTE validates the frame before it reads it, so a format
     * error is taken having read the format word and nothing else of the
     * frame. The oracle reads the frame first; those reads are dropped. */
    if (t->w[0] == 0x4E73u && r->exc == 14) {
        for (j = 1; j < r->nacc && r->acc[j].rw; ) {
            for (e = j; e + 1 < r->nacc; e++) r->acc[e] = r->acc[e + 1];
            r->nacc--;
        }
    }
    /* Bit fields in memory (PRM 4): the core moves the bytes the field covers
     * as one operand of up to five bytes; the oracle as a long word and a
     * byte, or a word and a byte. The same bytes either way, and the manual
     * says nothing finer, so the oracle's pieces are put back together. */
    if ((t->w[0] & 0xF8C0u) == 0xE8C0u && ((t->w[0] >> 3) & 7) >= 2) {
        for (j = 0; j + 1 < r->nacc; j++) {
            struct acc *a = &r->acc[j], *b = &r->acc[j + 1];
            if (a->rw == b->rw && b->addr == a->addr + a->bytes && a->bytes + b->bytes <= 5) {
                a->value = (a->value << (8 * b->bytes)) | b->value;
                a->bytes += b->bytes;
                for (e = j + 1; e + 1 < r->nacc; e++) r->acc[e] = r->acc[e + 1];
                r->nacc--;
                j--;
            }
        }
    }
    /* PACK and UNPK on -(An) (PRM 4: "two bytes from the source are fetched
     * and concatenated"): the core moves the two bytes one at a time, the
     * higher address first as the predecrement goes; the oracle as one word.
     * The oracle's word is recorded as those two bytes. */
    if ((t->w[0] & 0xF1F8u) == 0x8148u || (t->w[0] & 0xF1F8u) == 0x8188u) {
        for (j = 0; j < r->nacc && r->nacc < MAXACC; j++) {
            struct acc *a = &r->acc[j];
            if (a->bytes == 2) {
                struct acc hi = *a, lo = *a;
                hi.bytes = lo.bytes = 1;
                lo.addr = a->addr + 1;           /* the higher address, first */
                lo.value = a->value & 0xFFu;
                hi.value = (a->value >> 8) & 0xFFu;
                for (e = r->nacc; e > j + 1; e--) r->acc[e] = r->acc[e - 1];
                r->nacc++;
                r->acc[j] = lo;
                r->acc[j + 1] = hi;
                j++;
            }
        }
    }
    /* UM 8.1.10 and table 8-6: the MMU configuration exception (vector 56)
     * stacks the six-word format $2 frame, with the PMOVE's address at +$08.
     * The oracle stacks a four-word format $0 frame. Its three writes are
     * recorded as the manual's four, in the order the frame is built from
     * the top: the instruction address, the format word, the PC, the SR; and
     * the stack pointer it leaves is four bytes lower. */
    if (r->exc == 56 && r->nacc + 1 <= MAXACC) {
        unsigned int sp0 = t->isp;
        for (j = 0; j + 2 < r->nacc; j++)
            if (!r->acc[j].rw && r->acc[j].bytes == 2 && r->acc[j].addr == sp0 - 2
                && r->acc[j].value == 0x00E0u) {
                struct acc pc = r->acc[j + 1], sr = r->acc[j + 2];
                for (e = r->nacc; e > j + 3; e--) r->acc[e] = r->acc[e - 1];
                r->nacc++;
                r->acc[j] = pc;
                r->acc[j].addr = sp0 - 4; r->acc[j].bytes = 4; r->acc[j].value = PROG_BASE;
                r->acc[j + 1] = sr;
                r->acc[j + 1].addr = sp0 - 6; r->acc[j + 1].bytes = 2; r->acc[j + 1].value = 0x20E0u;
                r->acc[j + 1].mask = 0xFFFFFFFFu;
                r->acc[j + 2] = pc;
                r->acc[j + 2].addr = sp0 - 10;
                r->acc[j + 3] = sr;
                r->acc[j + 3].addr = sp0 - 12;
                r->isp -= 4;
                break;
            }
    }
    /* UM 9.7.2: a TC the configuration check refuses is written all the
     * same, "and the E bit is cleared". The oracle keeps E. */
    if (r->exc == 56 && (t->w[0] & 0xFFC0u) == 0xF000u && (t->w[1] & 0xE200u) == 0x4000u
        && ((t->w[1] >> 10) & 7) == 0)
        r->fmt[0] &= ~0x80000000u;
    /* PRM 6, PMOVE: "only control alterable addressing modes" -- not (An)+
     * or -(An), which are an F-line exception (UM 8.1.5) before anything is
     * done. The oracle takes the exception having updated An; the register
     * is put back. */
    if ((t->w[0] & 0xFFC0u) == 0xF000u && r->exc == 11
        && (((t->w[0] >> 3) & 7) == 3 || ((t->w[0] >> 3) & 7) == 4))
        r->a[t->w[0] & 7] = t->a[t->w[0] & 7];
    /* PRM 4, DIVU and DIVS: "C -- Always cleared." On an overflow the oracle
     * leaves C as it was. */
    {
        unsigned int op = t->w[0];
        int is_div = (((op & 0xF0C0u) == 0x80C0u)
                      && ((op & 0x01C0u) == 0x00C0u || (op & 0x01C0u) == 0x01C0u))
                  || ((op & 0xFFC0u) == 0x4C40u);
        if (is_div && r->exc < 0) r->sr &= ~1u;
    }
}

static void result(int i, const uae030_state *s, void *u)
{
    struct test *t = &tests[base_idx + i];
    struct result *r = &res[base_idx + i];
    int j;
    (void)u;
    recording = 0;
    /* An odd PC after the instruction: the oracle takes the address error
     * (UM 8.1.3) at the next instruction's prefetch, after this boundary, and
     * the core inside the instruction; either way it is a long $B frame. */
    r->why = overflowed ? DROP_ROOM
           : (berr_seen || r->exc == 2 || r->exc == 3 || (s->pc & 1u)) ? DROP_BUSERR : KEEP;
    for (j = 0; j < 8; j++) r->d[j] = s->d[j];
    for (j = 0; j < 7; j++) r->a[j] = s->a[j];
    r->usp  = s->usp;
    r->isp  = s->isp;
    r->sr   = s->sr;
    r->pc   = s->pc;
    r->msp  = s->msp;
    r->vbr  = s->vbr;
    r->sfc  = s->sfc;
    r->dfc  = s->dfc;
    r->caar = s->caar;
    r->cacr = s->cacr;
    r->fmt[0] = s->tc;
    r->fmt[1] = (unsigned int)(s->crp >> 32);
    r->fmt[2] = (unsigned int)s->crp;
    r->fmt[3] = (unsigned int)(s->srp >> 32);
    r->fmt[4] = (unsigned int)s->srp;
    r->fmt[5] = s->tt0;
    r->fmt[6] = s->tt1;
    r->fmt[7] = s->mmusr;
    if (t->tables)
        for (j = 0; j < ntbl_fixed; j++) {
            const uint8_t *m = uae030_ram() + tbl_a[j];
            r->tblv[j] = ((unsigned)m[0] << 24) | ((unsigned)m[1] << 16)
                       | ((unsigned)m[2] << 8) | m[3];
        }
    r->srmask = undefined_ccr(t, s->sr, r->exc);
    normalise(t, r, s);
    /* The status register an exception stacked, at the bottom of the frame
     * (UM 8.2: SR, then the PC, then the format word), carries the same
     * undefined codes the instruction left. */
    if (r->exc >= 0 && r->srmask != 0xFFFFu) {
        unsigned int sp = (s->sr & 0x1000u) ? s->msp : s->isp;
        for (j = 0; j < r->nacc; j++)
            if (!r->acc[j].rw && r->acc[j].bytes == 2 && r->acc[j].addr == sp)
                r->acc[j].mask = r->srmask;
    }
}

/* Run tests [first, ntests) in a child process, so that a test which halts the
 * oracle costs that test and not the run. Returns the index the child stopped
 * at, or ntests when it finished. */
static int run_child(int first)
{
    pid_t pid;
    int status;
    fflush(stdout);
    fflush(stderr);
    pid = fork();
    if (pid < 0) { perror("fork"); exit(1); }
    if (pid == 0) {
        int done, j;
        uae030_init(MEMSIZE, 1);
        wr32(0, STACK);
        wr32(4, PROG_BASE);
        for (j = 0; j < PROG_FILL; j += 2) wr16(PROG_BASE + (unsigned)j, 0x4E71);
        uae030_set_op_hook(on_op);
        uae030_set_exc_hook(on_exc);
        base_idx = first;
        if (getenv("VEC_DEBUG")) {
            debug_idx = (int)strtol(getenv("VEC_DEBUG"), NULL, 0);
            uae030_set_hooks(NULL, on_bus, NULL);
        }
        if (uae030_run_each(ntests - first, setup, result, NULL, &done))
            _exit(3);
        _exit(0);
    }
    if (waitpid(pid, &status, 0) < 0) { perror("waitpid"); exit(1); }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return ntests;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 3) return *progress;
    fprintf(stderr, "vectors: the oracle process died at test %d (status %x)\n",
            *progress, status);
    return *progress;
}

int main(int argc, char **argv)
{
    int i, j, first;
    long kept = 0, dropped[NDROP] = { 0 };
    struct test *t;
    struct result *r;

    tests = calloc(MAXTESTS, sizeof *tests);
    if (!tests) { fprintf(stderr, "vectors: out of memory\n"); return 1; }

    if (argc >= 2 && !strcmp(argv[1], "list")) {
        for (i = 0; i < NGROUPS; i++) printf("%s\n", GROUPS[i].name);
        return 0;
    }
    rng_state = 0x13572468u;
    if (argc < 2 || !strcmp(argv[1], "all")) {
        for (i = 0; i < NGROUPS; i++) GROUPS[i].build();
    } else {
        for (j = 1; j < argc; j++) {
            for (i = 0; i < NGROUPS; i++)
                if (!strcmp(argv[j], GROUPS[i].name)) { GROUPS[i].build(); break; }
            if (i == NGROUPS) {
                fprintf(stderr, "vectors: no group %s. There is:", argv[j]);
                for (i = 0; i < NGROUPS; i++) fprintf(stderr, " %s", GROUPS[i].name);
                fprintf(stderr, "\n");
                return 1;
            }
        }
    }

    res = mmap(NULL, (size_t)ntests * sizeof *res + 64, PROT_READ | PROT_WRITE,
               MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (res == MAP_FAILED) { perror("mmap"); return 1; }
    progress = (volatile int *)(res + ntests);

    for (first = 0; first < ntests; ) {
        int stop = run_child(first);
        if (stop >= ntests) break;
        res[stop].why = DROP_HALT;
        first = stop + 1;
    }

    for (i = 0; i < ntests; i++) {
        if (res[i].why == KEEP) kept++;
        else dropped[res[i].why]++;
    }
    fprintf(stderr, "vectors: %ld tests", kept);
    for (i = 1; i < NDROP; i++)
        if (dropped[i]) fprintf(stderr, "; %ld dropped for %s", dropped[i], DROP_WHY[i]);
    fprintf(stderr, "\n");
    if (kept == 0) { fprintf(stderr, "vectors: nothing to test\n"); return 1; }

    printf("%lx\n", kept);
    for (i = 0; i < ntests; i++) {
        t = &tests[i];
        r = &res[i];
        if (r->why != KEEP) continue;
        printf("%x %x", i, t->nwords);
        for (j = 0; j < 6; j++) printf(" %x", t->w[j]);
        printf("\n");
        for (j = 0; j < 8; j++) printf("%x ", t->d[j]);
        for (j = 0; j < 7; j++) printf("%x ", t->a[j]);
        printf("%x %x %x %x %x %x %x %x %x\n", t->usp, t->isp, t->sr,
               t->imsp, t->isfc, t->idfc, t->ivbr, t->icaar, t->icacr);
        printf("%x", t->npoke);
        for (j = 0; j < t->npoke; j++) printf(" %x %x", t->poke_a[j], t->poke_v[j]);
        printf(" %x %x\n", r->srmask & t->srmask, (unsigned)t->bcdfill);
        for (j = 0; j < 8; j++) printf("%x ", r->d[j]);
        for (j = 0; j < 7; j++) printf("%x ", r->a[j]);
        printf("%x %x %x %x %x %x %x %x %x %x\n", r->usp, r->isp, r->sr, r->pc,
               r->msp, r->vbr, r->sfc, r->dfc, r->caar, r->cacr);
        printf("%x", r->nacc);
        for (j = 0; j < r->nacc; j++)
            printf(" %x %x %x %x %x %x", r->acc[j].addr, r->acc[j].rw,
                   r->acc[j].bytes, r->acc[j].prog, r->acc[j].value, r->acc[j].mask);
        printf("\n");
        for (j = 0; j < 8; j++) printf("%x ", t->imt[j]);
        printf("\n%x", t->tables ? ntbl_fixed : 0);
        if (t->tables)
            for (j = 0; j < ntbl_fixed; j++) printf(" %x %x", tbl_a[j], tbl_v[j]);
        printf("\n");
        for (j = 0; j < 8; j++) printf("%x ", r->fmt[j]);
        printf("\n");
        if (t->tables)
            for (j = 0; j < ntbl_fixed; j++) printf("%x ", r->tblv[j]);
        printf("\n");
    }
    return 0;
}
