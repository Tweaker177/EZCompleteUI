// BRGoldenMandarinEngine.c
// EZCompleteUI — Golden Mandarin (金帽福运) slot. See the header for the rules.
//
// NOTE: the server (GoldenMandarinServer/ez-golden-mandarin-spin.index.ts) is
// the authority for every real spin. This file is the reference the edge
// function was ported from, and the app uses it only for the pay table
// shown to the player. Keep the tables below identical to the TypeScript.

#include "BRGoldenMandarinEngine.h"
#include <string.h>

#ifdef __APPLE__
#include <stdlib.h>
#endif

// ── Paylines ────────────────────────────────────────────────────────────────
// Row used on each of the five reels, 0 = top, 1 = middle, 2 = bottom.
static const int kPaylines[GM_MAX_LINES][GM_REELS] = {
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

int GMPaylineRow(int line, int reel) {
    if (line < 0 || line >= GM_MAX_LINES || reel < 0 || reel >= GM_REELS) return 1;
    return kPaylines[line][reel];
}

// ── Symbol weights (per cell, scatter handled separately) ───────────────────
//                                      lantern fan bamboo plum koi jade ingot dragon
static const int kWeights[GMSymbolHat] = { 26,    22,  19,    16,  12,  8,    5,    3 };

// Probability of a hat on any given cell, in 1/10000ths. 307 makes the
// bonus (3+ hats anywhere) trigger about once every 100 spins.
#ifndef GM_SCATTER_PER_10000
#define GM_SCATTER_PER_10000 307
#endif

// ── Paytable: pays in line bets for 3 / 4 / 5 of a kind ─────────────────────
static const int kPay[GMSymbolHat][3] = {
    /* lantern */ {  11,   30,   98 },
    /* fan     */ {  15,   41,  125 },
    /* bamboo  */ {  20,   55,  160 },
    /* plum    */ {  26,   75,  213 },
    /* koi     */ {  41,  123,  338 },
    /* jade    */ {  69,  214,  640 },
    /* ingot   */ { 129,  405, 1290 },
    /* dragon  */ { 258,  854, 3200 }
};

int GMPayoutUnits(int symbol, int matches) {
    if (symbol < 0 || symbol >= GMSymbolHat || matches < 3 || matches > 5) return 0;
    return kPay[symbol][matches - 3];
}

uint32_t GMDefaultRandom(uint32_t upper, void *context) {
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

static int RandomPlainSymbol(GMRandomFn rng, void *ctx) {
    int total = 0;
    for (int i = 0; i < GMSymbolHat; i++) total += kWeights[i];
    int roll = (int)rng((uint32_t)total, ctx);
    for (int i = 0; i < GMSymbolHat; i++) {
        if (roll < kWeights[i]) return i;
        roll -= kWeights[i];
    }
    return GMSymbolLantern;
}

void GMGenerateSpin(GMSpinResult *out, int activeLines, bool freeSpin,
                    GMRandomFn rng, void *ctx) {
    (void)freeSpin;
    if (!rng) rng = GMDefaultRandom;
    memset(out, 0, sizeof(*out));
    if (activeLines < 1) activeLines = 1;
    if (activeLines > GM_MAX_LINES) activeLines = GM_MAX_LINES;
    out->activeLines = activeLines;
    for (int line = 0; line < GM_MAX_LINES; line++) out->lineSymbol[line] = -1;

    // 1. Fill the board. A hat may land on any cell, including several rows
    //    of the same reel.
    int hatCells[GM_REELS * GM_ROWS][2];
    int hats = 0;
    for (int r = 0; r < GM_REELS; r++) {
        for (int row = 0; row < GM_ROWS; row++) {
            if ((int)rng(10000, ctx) < GM_SCATTER_PER_10000) {
                out->grid[r][row] = GMSymbolHat;
                hatCells[hats][0] = r; hatCells[hats][1] = row; hats++;
            } else {
                out->grid[r][row] = RandomPlainSymbol(rng, ctx);
            }
        }
    }

    // 2. Enforce the board-wide cap of five hats. Surplus hats are chosen at
    //    random and turned into ordinary symbols.
    while (hats > GM_MAX_SCATTERS) {
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
        int first = out->grid[0][GMPaylineRow(line, 0)];
        if (first == GMSymbolHat) continue;
        int run = 1;
        for (int reel = 1; reel < GM_REELS; reel++) {
            int s = out->grid[reel][GMPaylineRow(line, reel)];
            if (s != first) break;
            run++;
        }
        int pay = GMPayoutUnits(first, run);
        if (pay > 0) {
            out->lineSymbol[line] = first;
            out->lineMatches[line] = run;
            out->linePayUnits[line] = pay;
            out->totalPayUnits += pay;
            out->winningLineCount++;
        }
    }

    out->freeSpinsAwarded = GMFreeSpinsForScatters(out->scatterCount, rng, ctx);
}

int GMFreeSpinsForScatters(int scatterCount, GMRandomFn rng, void *ctx) {
    if (!rng) rng = GMDefaultRandom;
    switch (scatterCount) {
        case 3: return 5  + (int)rng(4, ctx);   // 5...8
        case 4: return 14 + (int)rng(3, ctx);   // 14...16
        case 5: return 25 + (int)rng(6, ctx);   // 25...30
        default: return 0;
    }
}

void GMShuffleMultiplierCards(int cards[3], GMRandomFn rng, void *ctx) {
    if (!rng) rng = GMDefaultRandom;
    cards[0] = 2; cards[1] = 3; cards[2] = 5;
    for (int i = 2; i > 0; i--) {                       // Fisher-Yates
        int j = (int)rng((uint32_t)(i + 1), ctx);
        int t = cards[i]; cards[i] = cards[j]; cards[j] = t;
    }
}
