// BRStarlightOdysseyEngine.h
// EZCompleteUI — Starlight Odyssey slot
//
// Pure-C outcome engine: no Foundation/UIKit, so the exact same logic can be
// compiled in the app, in a command-line simulation, or ported to a server
// function. It decides reels, line wins, scatters, and free-spin awards. It
// never touches balances; the caller owns money.
//
// Rules (match the design brief):
//  - 5 reels x 3 rows, up to 25 paylines, wins pay left-to-right from reel 1
//    for 3, 4 or 5 matching symbols.
//  - The golden warp star is the scatter. It can land on any row of any reel (up to all
//    three rows of a reel) but the board NEVER holds more than 5 in total.
//  - 3 hats = 5-8 free spins, 4 hats = 14-16, 5 hats = 25-30 (random in range).
//  - Free spins pay every line win times a x2 / x3 / x5 multiplier that the
//    player chooses from the three-card shuffle.

#ifndef BRStarlightOdysseyEngine_h
#define BRStarlightOdysseyEngine_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SO_REELS 5
#define SO_ROWS 3
#define SO_MAX_LINES 25
#define SO_MAX_SCATTERS 5
#define SO_MAX_FREE_SPINS_BANKED 100

typedef enum {
    SOSymbolRocket = 0,
    SOSymbolMoon,
    SOSymbolSatellite,
    SOSymbolHelmet,
    SOSymbolPlanet,
    SOSymbolUfo,
    SOSymbolAlien,
    SOSymbolGalaxy,
    SOSymbolHat,          // scatter
    SOSymbolCount
} SOSymbol;

/// Uniform random integer in [0, upper). `upper` is always > 0.
typedef uint32_t (*SORandomFn)(uint32_t upper, void *context);

typedef struct {
    int grid[SO_REELS][SO_ROWS];      // grid[reel][row], row 0 = top
    int scatterCount;                 // 0...SO_MAX_SCATTERS
    int scatterPerReel[SO_REELS];     // hats landing on each reel
    int activeLines;                  // lines that were played
    int lineSymbol[SO_MAX_LINES];     // winning symbol, or -1
    int lineMatches[SO_MAX_LINES];    // 3/4/5, or 0
    int linePayUnits[SO_MAX_LINES];   // pay in "line bets", before multiplier
    int winningLineCount;
    int totalPayUnits;                // sum of linePayUnits (before multiplier)
    int freeSpinsAwarded;             // 0 unless scatterCount >= 3
} SOSpinResult;

/// Row (0...2) each reel uses on payline `line` (0...24).
int SOPaylineRow(int line, int reel);

/// Pay, in line bets, for `matches` (3...5) of `symbol`; 0 otherwise.
int SOPayoutUnits(int symbol, int matches);

/// Generates one spin. `freeSpin` is currently informational (the same reels
/// are used in the bonus) but is kept so a server can vary it later.
void SOGenerateSpin(SOSpinResult *out, int activeLines, bool freeSpin,
                    SORandomFn rng, void *context);

/// 3 -> 5...8, 4 -> 14...16, 5 -> 25...30, anything else -> 0.
int SOFreeSpinsForScatters(int scatterCount, SORandomFn rng, void *context);

/// Fills `cards[3]` with a random permutation of {2, 3, 5}: the hidden
/// multipliers behind the three shuffled cards. cards[i] is what the player
/// wins by picking card i, so every card is a one-in-three chance of each.
void SOShuffleMultiplierCards(int cards[3], SORandomFn rng, void *context);

/// Default RNG: arc4random_uniform on Apple platforms, xorshift elsewhere.
uint32_t SODefaultRandom(uint32_t upper, void *context);

#ifdef __cplusplus
}
#endif

#endif /* BRStarlightOdysseyEngine_h */
