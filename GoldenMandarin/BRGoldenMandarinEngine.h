// BRGoldenMandarinEngine.h
// EZCompleteUI — Golden Mandarin (金帽福运) slot
//
// Pure-C outcome engine: no Foundation/UIKit, so the exact same logic can be
// compiled in the app, in a command-line simulation, or ported to a server
// function. It decides reels, line wins, scatters, and free-spin awards. It
// never touches balances; the caller owns money.
//
// Rules (match the design brief):
//  - 5 reels x 3 rows, up to 9 paylines, wins pay left-to-right from reel 1
//    for 3, 4 or 5 matching symbols.
//  - Golden Hat is the scatter. It can land on any row of any reel (up to all
//    three rows of a reel) but the board NEVER holds more than 5 in total.
//  - 3 hats = 5-8 free spins, 4 hats = 14-16, 5 hats = 25-30 (random in range).
//  - Free spins pay every line win times a x2 / x3 / x5 multiplier that the
//    player chooses from the three-card shuffle.

#ifndef BRGoldenMandarinEngine_h
#define BRGoldenMandarinEngine_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GM_REELS 5
#define GM_ROWS 3
#define GM_MAX_LINES 9
#define GM_MAX_SCATTERS 5
#define GM_MAX_FREE_SPINS_BANKED 100

typedef enum {
    GMSymbolLantern = 0,
    GMSymbolFan,
    GMSymbolBamboo,
    GMSymbolPlum,
    GMSymbolKoi,
    GMSymbolJade,
    GMSymbolIngot,
    GMSymbolDragon,
    GMSymbolHat,          // scatter
    GMSymbolCount
} GMSymbol;

/// Uniform random integer in [0, upper). `upper` is always > 0.
typedef uint32_t (*GMRandomFn)(uint32_t upper, void *context);

typedef struct {
    int grid[GM_REELS][GM_ROWS];      // grid[reel][row], row 0 = top
    int scatterCount;                 // 0...GM_MAX_SCATTERS
    int scatterPerReel[GM_REELS];     // hats landing on each reel
    int activeLines;                  // lines that were played
    int lineSymbol[GM_MAX_LINES];     // winning symbol, or -1
    int lineMatches[GM_MAX_LINES];    // 3/4/5, or 0
    int linePayUnits[GM_MAX_LINES];   // pay in "line bets", before multiplier
    int winningLineCount;
    int totalPayUnits;                // sum of linePayUnits (before multiplier)
    int freeSpinsAwarded;             // 0 unless scatterCount >= 3
} GMSpinResult;

/// Row (0...2) each reel uses on payline `line` (0...8).
int GMPaylineRow(int line, int reel);

/// Pay, in line bets, for `matches` (3...5) of `symbol`; 0 otherwise.
int GMPayoutUnits(int symbol, int matches);

/// Generates one spin. `freeSpin` is currently informational (the same reels
/// are used in the bonus) but is kept so a server can vary it later.
void GMGenerateSpin(GMSpinResult *out, int activeLines, bool freeSpin,
                    GMRandomFn rng, void *context);

/// 3 -> 5...8, 4 -> 14...16, 5 -> 25...30, anything else -> 0.
int GMFreeSpinsForScatters(int scatterCount, GMRandomFn rng, void *context);

/// Fills `cards[3]` with a random permutation of {2, 3, 5}: the hidden
/// multipliers behind the three shuffled cards. cards[i] is what the player
/// wins by picking card i, so every card is a one-in-three chance of each.
void GMShuffleMultiplierCards(int cards[3], GMRandomFn rng, void *context);

/// Default RNG: arc4random_uniform on Apple platforms, xorshift elsewhere.
uint32_t GMDefaultRandom(uint32_t upper, void *context);

#ifdef __cplusplus
}
#endif

#endif /* BRGoldenMandarinEngine_h */
