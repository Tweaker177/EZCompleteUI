// BRPenguinParadeEngine.c
// EZCompleteUI — Penguin Parade . See the header for the rules.
//
// NOTE: the server (PenguinParadeServer/ez-penguin-parade-spin.index.ts) is
// the authority for every real spin. This file is the reference the edge
// function was ported from, and the app uses it only for the pay table
// shown to the player. Keep the tables below identical to the TypeScript.

#include "BRPenguinParadeEngine.h"
#include <string.h>

#ifdef __APPLE__
#include <stdlib.h>
#endif

// ── Paylines ────────────────────────────────────────────────────────────────
// Row used on each of the five reels, 0 = top, 1 = middle, 2 = bottom.
static const int kPaylines[PG_MAX_LINES][PG_REELS] = {
    {1,1,1,1,1},   // 1  middle
    {0,0,0,0,0},   // 2  top
    {2,2,2,2,2},   // 3  bottom
    {0,1,2,1,0},   // 4  V
    {2,1,0,1,2},   // 5  inverted V
    {0,0,1,2,2},   // 6  descending step
    {2,2,1,0,0},   // 7  ascending step
    {1,0,0,0,1},   // 8  top cup
    {1,2,2,2,1}    // 9  bottom cup
};

int PGPaylineRow(int line, int reel) {
    if (line < 0 || line >= PG_MAX_LINES || reel < 0 || reel >= PG_REELS) return 1;
    return kPaylines[line][reel];
}

// ── Symbol weights (per cell, scatter handled separately) ───────────────────
//                                      snowflake fish igloo cocoa seal whale chick emperor
static const int kWeights[PGSymbolEgg] = { 26,    22,  19,    16,  12,  8,    5,    3 };

// Probability of a egg on any given cell, in 1/10000ths. 336 makes the
// bonus (3+ eggs anywhere) trigger about once every 78 spins.
#ifndef PG_SCATTER_PER_10000
#define PG_SCATTER_PER_10000 336
#endif

// ── Paytable: pays in line bets for 3 / 4 / 5 of a kind ─────────────────────
static const int kPay[PGSymbolEgg][3] = {
    /* snowflk */ {  11,   30,   98 },
    /* fish    */ {  15,   41,  125 },
    /* igloo   */ {  20,   55,  160 },
    /* cocoa   */ {  26,   75,  213 },
    /* seal    */ {  41,  123,  338 },
    /* whale   */ {  69,  214,  640 },
    /* chick   */ { 129,  405, 1290 },
    /* emperor */ { 258,  854, 3200 }
};

int PGPayoutUnits(int symbol, int matches) {
    if (symbol < 0 || symbol >= PGSymbolEgg || matches < 3 || matches > 5) return 0;
    return kPay[symbol][matches - 3];
}

uint32_t PGDefaultRandom(uint32_t upper, void *context) {
    (void)context;
    if (upper <= 1) return 0;
#ifdef __APPLE__
    return arc4random_uniform(upper);
#else
    static uint64_t s = 0x9E3779B97F4A7C15ULL;
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    return (uint32_t)((s >> 11) % upper);
#endif
}

static int RandomPlainSymbol(PGRandomFn rng, void *ctx) {
    int total = 0;
    for (int i = 0; i < PGSymbolEgg; i++) total += kWeights[i];
    int roll = (int)rng((uint32_t)total, ctx);
    for (int i = 0; i < PGSymbolEgg; i++) {
        if (roll < kWeights[i]) return i;
        roll -= kWeights[i];
    }
    return PGSymbolSnowflake;
}

void PGGenerateSpin(PGSpinResult *out, int activeLines, bool freeSpin,
                    PGRandomFn rng, void *ctx) {
    (void)freeSpin;
    if (!rng) rng = PGDefaultRandom;
    memset(out, 0, sizeof(*out));
    if (activeLines < 1) activeLines = 1;
    if (activeLines > PG_MAX_LINES) activeLines = PG_MAX_LINES;
    out->activeLines = activeLines;
    for (int line = 0; line < PG_MAX_LINES; line++) out->lineSymbol[line] = -1;

    // 1. Fill the board. A egg may land on any cell, including several rows
    //    of the same reel.
    int eggCells[PG_REELS * PG_ROWS][2];
    int eggs = 0;
    for (int r = 0; r < PG_REELS; r++) {
        for (int row = 0; row < PG_ROWS; row++) {
            if ((int)rng(10000, ctx) < PG_SCATTER_PER_10000) {
                out->grid[r][row] = PGSymbolEgg;
                eggCells[eggs][0] = r; eggCells[eggs][1] = row; eggs++;
            } else {
                out->grid[r][row] = RandomPlainSymbol(rng, ctx);
            }
        }
    }

    // 2. Enforce the board-wide cap of five eggs. Surplus eggs are chosen at
    //    random and turned into ordinary symbols.
    while (eggs > PG_MAX_SCATTERS) {
        int pick = (int)rng((uint32_t)eggs, ctx);
        out->grid[eggCells[pick][0]][eggCells[pick][1]] = RandomPlainSymbol(rng, ctx);
        eggCells[pick][0] = eggCells[eggs - 1][0];
        eggCells[pick][1] = eggCells[eggs - 1][1];
        eggs--;
    }
    out->scatterCount = eggs;
    for (int i = 0; i < eggs; i++) out->scatterPerReel[eggCells[i][0]]++;

    // 3. Score the active lines. Eggs are scatters, so they never form or
    //    extend a line.
    for (int line = 0; line < activeLines; line++) {
        int first = out->grid[0][PGPaylineRow(line, 0)];
        if (first == PGSymbolEgg) continue;
        int run = 1;
        for (int reel = 1; reel < PG_REELS; reel++) {
            int s = out->grid[reel][PGPaylineRow(line, reel)];
            if (s != first) break;
            run++;
        }
        int pay = PGPayoutUnits(first, run);
        if (pay > 0) {
            out->lineSymbol[line] = first;
            out->lineMatches[line] = run;
            out->linePayUnits[line] = pay;
            out->totalPayUnits += pay;
            out->winningLineCount++;
        }
    }

    out->freeSpinsAwarded = PGFreeSpinsForScatters(out->scatterCount, rng, ctx);
}

int PGFreeSpinsForScatters(int scatterCount, PGRandomFn rng, void *ctx) {
    if (!rng) rng = PGDefaultRandom;
    switch (scatterCount) {
        case 3: return 5  + (int)rng(4, ctx);   // 5...8
        case 4: return 14 + (int)rng(3, ctx);   // 14...16
        case 5: return 25 + (int)rng(6, ctx);   // 25...30
        default: return 0;
    }
}

void PGShuffleMultiplierCards(int cards[3], PGRandomFn rng, void *ctx) {
    if (!rng) rng = PGDefaultRandom;
    cards[0] = 2; cards[1] = 3; cards[2] = 5;
    for (int i = 2; i > 0; i--) {                       // Fisher-Yates
        int j = (int)rng((uint32_t)(i + 1), ctx);
        int t = cards[i]; cards[i] = cards[j]; cards[j] = t;
    }
}
