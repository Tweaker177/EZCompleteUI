# Golden Mandarin — server side

The app never decides an outcome. These two pieces do, exactly like Plunder Bay.

## Deploy (in this order)

1. **SQL** — paste `golden_mandarin_slot.sql` into the Supabase SQL editor and run it.
   It creates `ez_golden_mandarin_bonus` and two RPCs, and locks the RPCs so only
   the service role can call them.
2. **Edge function** — create a function named **`ez-golden-mandarin-spin`** and paste
   `ez-golden-mandarin-spin.index.ts` as its `index.ts`. Leave "Verify JWT" at its
   default, same as `ez-plunder-spin`.

The app calls `/functions/v1/ez-golden-mandarin-spin`. Until both are deployed the
game opens but spins report an error and no coins move.

## Protocol

| Request | Result |
|---|---|
| `{"action":"status"}` | `free_spins_remaining, lines, bet_per_line, multiplier, pick_pending, bonus_total` |
| `{"lines":1-9, "bet_per_line":1/5/10/15/25}` | one spin (a free spin automatically if any remain) |
| `{"action":"pick","card":0-2}` | `multiplier, cards[3], picked` — the server decides what each card hides |

Errors: `402` not enough coins, `409` state changed / pick required, `400` bad wager.

## Rules enforced on the server

- 5 reels x 3 rows, 9 paylines, wins pay left to right for 3, 4 or 5 matching symbols.
- Golden hat = scatter. Never more than 5 on a board.
- 3 / 4 / 5 hats = 5-8 / 14-16 / 25-30 free spins, rolled in the RPC.
- Before the first free spin the player picks one of three cards: x2, x3 or x5 multiplies
  every free-spin line win. A retrigger adds spins and keeps the multiplier.
- At most 100 free spins banked.

## Odds (9 lines, simulated)

- Bonus (3+ hats): about **1 spin in 100**.
- Total payback about **90.6%** (base game ~71.7%, free spins ~18.9%).
- Tuning knobs, kept identical in `BRGoldenMandarinEngine.c` and the edge function:
  `HAT_PER_10000` (bonus frequency) and `PAYS` (payback). Re-simulate after any change.

## Ledger name

Rows are written with `feature = 'brainrot_golden_mandarin_slots'`. If `coin_transactions`
or `ez_usage_log` have a CHECK constraint on `feature`, add that value to it.
