// BRStarlightOdysseyEngine.c
// EZCompleteUI — Starlight Odyssey slot. See the header for the rules.
//
// NOTE: the server (StarlightOdysseyServer/ez-starlight-odyssey-spin.index.ts) is
// the authority for every real spin. This file is the reference the edge
// function was ported from, and the app uses it only for the pay table
// shown to the player. Keep the tables below identical to the TypeScript.

#include "BRStarlightOdysseyEngine.h"
#include <string.h>

#ifdef __APPLE__
#include <stdlib.h>
#endif

// ── Paylines ────────────────────────────────────────────────────────────────
// Row used on each of the five reels, 0 = top, 1 = middle, 2 = bottom.
static const int kPaylines[SO_MAX_LINES][SO_REELS] = {
    {1,1,1,1,1},   // 1  middle
    {0,0,0,0,0},   // 2  top
    {2,2,2,2,2},   // 3  bottom
    {0,1,2,1,0},   // 4  V
    {2,1,0,1,2},   // 5  inverted V
    {0,0,1,2,2},   // 6  descending step
    {2,2,1,0,0},   // 7  ascending step
    {1,0,0,0,1},   // 8  top cup
    {1,2,2,2,1},   // 9  bottom cup
    {0,1,1,1,0},   // 10  shallow bowl
    {2,1,1,1,2},   // 11  shallow arch
    {1,0,1,2,1},   // 12  zigzag down-up
    {1,2,1,0,1},   // 13  zigzag up-down
    {0,1,0,1,0},   // 14  top W
    {2,1,2,1,2},   // 15  bottom M
    {1,1,0,1,1},   // 16  middle dip up
    {1,1,2,1,1},   // 17  middle dip down
    {0,0,1,0,0},   // 18  top bump
    {2,2,1,2,2},   // 19  bottom bump
    {0,2,0,2,0},   // 20  top saw
    {2,0,2,0,2},   // 21  bottom saw
    {1,0,2,0,1},   // 22  wide X down
    {1,2,0,2,1},   // 23  wide X up
    {0,2,2,2,0},   // 24  top hook
    {2,0,0,0,2}    // 25  bottom hook
};

int SOPaylineRow(int line, int reel) {
    if (line < 0 || line >= SO_MAX_LINES || reel < 0 || reel >= SO_REELS) return 1;
    return kPaylines[line][reel];
}

// ── Symbol weights (per cell, scatter handled separately) ───────────────────
//                                      rocket moon satellite helmet planet ufo alien galaxy
static const int kWeights[SOSymbolHat] = { 26,    22,  19,    16,  12,  8,    5,    3 };

// Probability of a hat on any given cell, in 1/10000ths. 336 makes the
// bonus (3+ hats anywhere) trigger about once every 78 spins.
#ifndef SO_SCATTER_PER_10000
#define SO_SCATTER_PER_10000 336
#endif

// ── Paytable: pays in line bets for 3 / 4 / 5 of a kind ─────────────────────
static const int kPay[SOSymbolHat][3] = {
    /* rocket */ {  11,   30,   98 },
    /* fan     */ {  15,   41,  125 },
    /* satellite */ {  20,   55,  160 },
    /* helmet  */ {  26,   75,  213 },
    /* planet  */ {  41,  123,  338 },
    /* ufo     */ {  69,  214,  640 },
    /* alien   */ { 129,  405, 1290 },
    /* galaxy  */ { 258,  854, 3200 }
};

int SOPayoutUnits(int symbol, int matches) {
    if (symbol < 0 || symbol >= SOSymbolHat || matches < 3 || matches > 5) return 0;
    return kPay[symbol][matches - 3];
}

uint32_t SODefaultRandom(uint32_t upper, void *context) {
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

static int RandomPlainSymbol(SORandomFn rng, void *ctx) {
    int total = 0;
    for (int i = 0; i < SOSymbolHat; i++) total += kWeights[i];
    int roll = (int)rng((uint32_t)total, ctx);
    for (int i = 0; i < SOSymbolHat; i++) {
        if (roll < kWeights[i]) return i;
        roll -= kWeights[i];
    }
    return SOSymbolRocket;
}

void SOGenerateSpin(SOSpinResult *out, int activeLines, bool freeSpin,
                    SORandomFn rng, void *ctx) {
    (void)freeSpin;
    if (!rng) rng = SODefaultRandom;
    memset(out, 0, sizeof(*out));
    if (activeLines < 1) activeLines = 1;
    if (activeLines > SO_MAX_LINES) activeLines = SO_MAX_LINES;
    out->activeLines = activeLines;
    for (int line = 0; line < SO_MAX_LINES; line++) out->lineSymbol[line] = -1;

    // 1. Fill the board. A hat may land on any cell, including several rows
    //    of the same reel.
    int hatCells[SO_REELS * SO_ROWS][2];
    int hats = 0;
    for (int r = 0; r < SO_REELS; r++) {
        for (int row = 0; row < SO_ROWS; row++) {
            if ((int)rng(10000, ctx) < SO_SCATTER_PER_10000) {
                out->grid[r][row] = SOSymbolHat;
                hatCells[hats][0] = r; hatCells[hats][1] = row; hats++;
            } else {
                out->grid[r][row] = RandomPlainSymbol(rng, ctx);
            }
        }
    }

    // 2. Enforce the board-wide cap of five hats. Surplus hats are chosen at
    //    random and turned into ordinary symbols.
    while (hats > SO_MAX_SCATTERS) {
        int pick = (int)rng((uint32_t)hats, ctx);
        out->grid[hatCells[pick][0]][hatCells[pick][1]] = RandomPlainSymbol(rng, ctx);
        hatCells[pick][0] = hatCells[hats - 1][0];
        hatCells[pick][1] = hatCells[hats - 1][1];
        hats--;
    }
    out->scatterCount = hats;
    for (int i = 0; i < hats; i++) out->scatterPerReel[hatCells[i][0]]++;

    // 3. Score the active lines. Hats are scatters, so they never form or
    //    extend a line.
    for (int line = 0; line < activeLines; line++) {
        int first = out->grid[0][SOPaylineRow(line, 0)];
        if (first == SOSymbolHat) continue;
        int run = 1;
        for (int reel = 1; reel < SO_REELS; reel++) {
            int s = out->grid[reel][SOPaylineRow(line, reel)];
            if (s != first) break;
            run++;
        }
        int pay = SOPayoutUnits(first, run);
        if (pay > 0) {
            out->lineSymbol[line] = first;
            out->lineMatches[line] = run;
            out->linePayUnits[line] = pay;
            out->totalPayUnits += pay;
            out->winningLineCount++;
        }
    }

    out->freeSpinsAwarded = SOFreeSpinsForScatters(out->scatterCount, rng, ctx);
}

int SOFreeSpinsForScatters(int scatterCount, SORandomFn rng, void *ctx) {
    if (!rng) rng = SODefaultRandom;
    switch (scatterCount) {
        case 3: return 5  + (int)rng(4, ctx);   // 5...8
        case 4: return 14 + (int)rng(3, ctx);   // 14...16
        case 5: return 25 + (int)rng(6, ctx);   // 25...30
        default: return 0;
    }
}

void SOShuffleMultiplierCards(int cards[3], SORandomFn rng, void *ctx) {
    if (!rng) rng = SODefaultRandom;
    cards[0] = 2; cards[1] = 3; cards[2] = 5;
    for (int i = 2; i > 0; i--) {                       // Fisher-Yates
        int j = (int)rng((uint32_t)(i + 1), ctx);
        int t = cards[i]; cards[i] = cards[j]; cards[j] = t;
    }
}
