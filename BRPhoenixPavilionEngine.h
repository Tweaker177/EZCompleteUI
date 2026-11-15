// BRPhoenixPavilionEngine.h
// EZCompleteUI — Phoenix Pavilion (凤凰阁) slot
//
// Pure-C outcome engine: no Foundation/UIKit, so the exact same logic can be
// compiled in the app, in a command-line simulation, or ported to a server
// function. It decides reels, line wins, scatters, and free-spin awards. It
// never touches balances; the caller owns money.
//
// Rules (match the design brief):
//  - 5 reels x 3 rows, up to 25 paylines, wins pay left-to-right from reel 1
//    for 3, 4 or 5 matching symbols.
//  - The golden official's cap is the scatter. It can land on any row of any reel (up to all
//    three rows of a reel) but the board NEVER holds more than 5 in total.
//  - 3 hats = 5-8 free spins, 4 hats = 14-16, 5 hats = 25-30 (random in range).
//  - Free spins pay every line win times a x2 / x3 / x5 multiplier that the
//    player chooses from the three-card shuffle.

#ifndef BRPhoenixPavilionEngine_h
#define BRPhoenixPavilionEngine_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PP_REELS 5
#define PP_ROWS 3
#define PP_MAX_LINES 25
#define PP_MAX_SCATTERS 5
#define PP_MAX_FREE_SPINS_BANKED 100

typedef enum {
    PPSymbolEnvelope = 0,
    PPSymbolTea,
    PPSymbolPeony,
    PPSymbolPagoda,
    PPSymbolCrane,
    PPSymbolRuyi,
    PPSymbolCoins,
    PPSymbolPhoenix,
    PPSymbolHat,          // scatter
    PPSymbolCount
} PPSymbol;

/// Uniform random integer in [0, upper). `upper` is always > 0.
typedef uint32_t (*PPRandomFn)(uint32_t upper, void *context);

typedef struct {
    int grid[PP_REELS][PP_ROWS];      // grid[reel][row], row 0 = top
    int scatterCount;                 // 0...PP_MAX_SCATTERS
    int scatterPerReel[PP_REELS];     // hats landing on each reel
    int activeLines;                  // lines that were played
    int lineSymbol[PP_MAX_LINES];     // winning symbol, or -1
    int lineMatches[PP_MAX_LINES];    // 3/4/5, or 0
    int linePayUnits[PP_MAX_LINES];   // pay in "line bets", before multiplier
    int winningLineCount;
    int totalPayUnits;                // sum of linePayUnits (before multiplier)
    int freeSpinsAwarded;             // 0 unless scatterCount >= 3
} PPSpinResult;

/// Row (0...2) each reel uses on payline `line` (0...24).
int PPPaylineRow(int line, int reel);

/// Pay, in line bets, for `matches` (3...5) of `symbol`; 0 otherwise.
int PPPayoutUnits(int symbol, int matches);

/// Generates one spin. `freeSpin` is currently informational (the same reels
/// are used in the bonus) but is kept so a server can vary it later.
void PPGenerateSpin(PPSpinResult *out, int activeLines, bool freeSpin,
                    PPRandomFn rng, void *context);

/// 3 -> 5...8, 4 -> 14...16, 5 -> 25...30, anything else -> 0.
int PPFreeSpinsForScatters(int scatterCount, PPRandomFn rng, void *context);

/// Fills `cards[3]` with a random permutation of {2, 3, 5}: the hidden
/// multipliers behind the three shuffled cards. cards[i] is what the player
/// wins by picking card i, so every card is a one-in-three chance of each.
void PPShuffleMultiplierCards(int cards[3], PPRandomFn rng, void *context);

/// Default RNG: arc4random_uniform on Apple platforms, xorshift elsewhere.
uint32_t PPDefaultRandom(uint32_t upper, void *context);

#ifdef __cplusplus
}
#endif

#endif /* BRPhoenixPavilionEngine_h */
