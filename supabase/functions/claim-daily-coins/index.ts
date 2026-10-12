// supabase/functions/claim-daily-coins/index.ts
// EZCompleteUI v1.2
//
// Purpose:
//   Awards a free reward on a strict 4-hour server-side cooldown. As of
//   v1.2 the reward is randomized 50/50 between coins and free Brainrot
//   Slots spins — subscription status is still verified directly in the
//   database, never trusted from the client.
//
//   GET  ?check=1  →  Cooldown status only; nothing awarded
//                     { available: bool, coins_to_award: int, next_claim_at: ISO | null }
//                     coins_to_award is what a coin-outcome WOULD award if
//                     claimed right now — the actual roll (coins vs spins)
//                     only happens on POST.
//
//   POST           →  Claim the reward (if cooldown has elapsed)
//                     Success (coins):  { success: true, reward_type: "coins", coins_added: int, balance: int, next_claim_at: ISO }
//                     Success (spins):  { success: true, reward_type: "spins", spins_added: int, free_spins_remaining: int, next_claim_at: ISO }
//                     Too soon:         { success: false, error: "too_soon", next_claim_at: ISO }  (HTTP 429)
//
//   Award amounts:
//     - Coins outcome: 5 coins (no subscription) / 10 coins (active subscription)
//     - Spins outcome: 4 free spins (no subscription) / 8 free spins (active subscription)
//       Spins are plain 5-line x 1-coin/line Brainrot Slots spins (~92% RTP,
//       no multiplier) — see play_ez_free_spin_v1 / ez-slot-spin.
//     - Which outcome: a 50/50 coin flip, server-side, per claim.
//
// Required database objects:
//   daily_coin_claims table (already exists):
//     CREATE TABLE IF NOT EXISTS daily_coin_claims (
//       user_id         uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
//       last_claimed_at timestamptz NOT NULL DEFAULT now()
//     );
//   increment_coin_balance() RPC — unchanged, see atomic_coin_increment.sql.
//   grant_free_spins() RPC — supplied by the welcome-free-spins migration.
//
// v1.2 — Reduced award sizes, randomized coins-vs-spins reward, 24h expiry
//   - FREE_USER_COINS 10→5, MEMBER_COINS 20→10. The old flat amounts were
//     compounding too fast for early, highly-engaged users who never
//     convert to a purchase.
//   - New: half the time the claim awards free spins instead of coins
//     (FREE_USER_SPINS / MEMBER_SPINS), via the new grant_free_spins() RPC.
//   - New: a claim that becomes available but sits unclaimed for more than
//     CLAIM_EXPIRY_HOURS (24h) is forfeited — the cooldown silently resets
//     from "now" instead of remaining claimable indefinitely. No new column
//     needed: "available since" is derived from last_claimed_at + COOLDOWN_HOURS.
//
// v1.1 — Race condition fix + reliable transaction logging (unchanged below)
//   - Balance increment uses the increment_coin_balance() Postgres RPC
//     instead of reading coins_balance into the edge function and writing
//     back a computed total, to close a lost-update race window.
//   - coin_transactions insert is awaited with up to 3 retries.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Configuration ─────────────────────────────────────────────────────────────

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const FREE_USER_COINS   = 5;    // Users with no active subscription — coins outcome
const MEMBER_COINS      = 10;   // Users with an active subscription — coins outcome
const FREE_USER_SPINS   = 4;    // Users with no active subscription — spins outcome
const MEMBER_SPINS      = 8;    // Users with an active subscription — spins outcome
const COOLDOWN_HOURS    = 4;
const CLAIM_EXPIRY_HOURS = 24;  // unclaimed-availability window before it's forfeited
const LOG_MAX_RETRIES   = 3;    // Attempts to write the coin_transactions ledger entry

// ── CORS + response helpers ───────────────────────────────────────────────────

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Content-Type":                 "application/json",
  };
}

function jsonResponse(body: object, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders() });
}

// Server-side 50/50 coin flip for the reward type. crypto, not Math.random,
// since this decides a real payout.
function rollRewardType(): "coins" | "spins" {
  const a = new Uint32Array(1);
  crypto.getRandomValues(a);
  return a[0] % 2 === 0 ? "coins" : "spins";
}

// Edge requests are passed through Supabase's proxy/CDN. Prefer the provider
// header, then use the first forwarded address (the original client) as a
// fallback. This is audit data only; it is never used as an authorization
// factor. Keep the value bounded before it reaches the ledger.
function requestIPAddress(req: Request): string | null {
  const value = req.headers.get("cf-connecting-ip")
    ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim()
    ?? req.headers.get("x-real-ip");
  if (!value || value.toLowerCase() === "unknown") return null;
  return value.slice(0, 64);
}

// ── Main handler ──────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    // ── Authentication ────────────────────────────────────────────────────────

    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing or invalid Authorization header" }, 401);
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false },
    });

    const { data: authData, error: authError } = await supabase.auth.getUser(authHeader.slice(7));
    if (authError || !authData?.user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    const userId = authData.user.id;
    const ipAddress = requestIPAddress(req);

    // ── Subscription status ───────────────────────────────────────────────────

    const { data: sub, error: subError } = await supabase
      .from("subscriptions")
      .select("status, tier, provider")
      .eq("user_id", userId)
      .maybeSingle();

    if (subError) {
      console.error("[claim-daily-coins] subscription fetch error:", subError.message);
      return jsonResponse({ error: "Could not read account data" }, 500);
    }

    const hasMembership = sub?.status === "active";
    const coinsToAward   = hasMembership ? MEMBER_COINS : FREE_USER_COINS;
    const spinsToAward    = hasMembership ? MEMBER_SPINS : FREE_USER_SPINS;

    // ── Cooldown + expiry check ───────────────────────────────────────────────

    const { data: claimRecord } = await supabase
      .from("daily_coin_claims")
      .select("last_claimed_at")
      .eq("user_id", userId)
      .maybeSingle();

    const now                      = new Date();
    let   isAvailable              = true;
    let   nextClaimAt: Date | null = null;

    if (claimRecord?.last_claimed_at) {
      const lastClaim           = new Date(claimRecord.last_claimed_at);
      const availableSince      = new Date(lastClaim.getTime() + COOLDOWN_HOURS * 60 * 60 * 1000);
      const hoursSinceLastClaim = (now.getTime() - lastClaim.getTime()) / (1000 * 60 * 60);

      if (hoursSinceLastClaim < COOLDOWN_HOURS) {
        isAvailable = false;
        nextClaimAt = availableSince;
      } else {
        const hoursUnclaimed = (now.getTime() - availableSince.getTime()) / (1000 * 60 * 60);
        if (hoursUnclaimed > CLAIM_EXPIRY_HOURS) {
          // Sat available too long without being claimed — forfeit it and
          // restart the cooldown from now rather than leaving it claimable.
          await supabase
            .from("daily_coin_claims")
            .upsert({ user_id: userId, last_claimed_at: now.toISOString() }, { onConflict: "user_id" });
          isAvailable = false;
          nextClaimAt = new Date(now.getTime() + COOLDOWN_HOURS * 60 * 60 * 1000);
        }
      }
    }

    // ── GET: Cooldown status only — no reward is rolled or awarded ────────────

    if (req.method === "GET") {
      return jsonResponse({
        available:      isAvailable,
        coins_to_award: coinsToAward,
        next_claim_at:  nextClaimAt?.toISOString() ?? null,
      });
    }

    // ── POST: Attempt to claim ────────────────────────────────────────────────

    if (!isAvailable) {
      return jsonResponse({
        success:       false,
        error:         "too_soon",
        next_claim_at: nextClaimAt!.toISOString(),
      }, 429);
    }

    const rewardType = rollRewardType();
    const nextClaimTime = new Date(now.getTime() + COOLDOWN_HOURS * 60 * 60 * 1000);

    // Credit first, then start the cooldown. The previous order consumed a
    // player's four-hour claim when grant_free_spins was unavailable or failed.
    // (The app already disables the claim button while this request is active.)
    const startCooldown = async (): Promise<boolean> => {
      const { error } = await supabase
        .from("daily_coin_claims")
        .upsert(
          { user_id: userId, last_claimed_at: now.toISOString() },
          { onConflict: "user_id" }
        );
      if (error) {
        console.error("[claim-daily-coins] cooldown record upsert error:", error.message);
        return false;
      }
      return true;
    };

    // ── Spins outcome ──────────────────────────────────────────────────────────

    if (rewardType === "spins") {
      const { data: newRemaining, error: spinsError } = await supabase
        .rpc("grant_free_spins", { p_user_id: userId, p_spins: spinsToAward });

      if (spinsError || newRemaining === null) {
        console.error("[claim-daily-coins] free spins grant error:", spinsError?.message);
        return jsonResponse({ error: "Failed to credit free spins" }, 500);
      }

      if (!await startCooldown()) {
        return jsonResponse({ error: "Free spins were credited, but the cooldown could not be saved" }, 500);
      }

      console.log(
        `[claim-daily-coins] +${spinsToAward} free spins → user=${userId} ` +
        `membership=${hasMembership} free_spins_remaining=${newRemaining as number}`
      );

      return jsonResponse({
        success:              true,
        reward_type:          "spins",
        spins_added:          spinsToAward,
        free_spins_remaining: newRemaining as number,
        next_claim_at:        nextClaimTime.toISOString(),
      });
    }

    // ── Coins outcome ──────────────────────────────────────────────────────────
    // Atomic balance increment — single Postgres statement, no read-then-write
    // race. For new users with no subscriptions row yet, the RPC inserts one
    // using the fallback values. Returns the authoritative balance after write.

    const { data: newBalance, error: incrementError } = await supabase
      .rpc("increment_coin_balance", {
        target_user_id:    userId,
        coins_delta:       coinsToAward,
        fallback_provider: sub?.provider ?? "none",
        fallback_status:   sub?.status   ?? "coins_only",
        fallback_tier:     sub?.tier     ?? "basic",
      });

    if (incrementError || newBalance === null) {
      console.error("[claim-daily-coins] balance increment error:", incrementError?.message);
      return jsonResponse({ error: "Failed to credit coins" }, 500);
    }

    if (!await startCooldown()) {
      return jsonResponse({ error: "Coins were credited, but the cooldown could not be saved" }, 500);
    }

    // ── Log transaction ───────────────────────────────────────────────────────
    // Awaited with retries so ledger entries aren't silently lost on a transient
    // DB hiccup. Still non-fatal — the user keeps their coins even if all
    // attempts fail — but failures are retried before giving up.

    const transactionDescription = hasMembership
      ? `4-hour member bonus (${MEMBER_COINS} coins)`
      : `4-hour login reward (${FREE_USER_COINS} coins)`;

    let logError;
    for (let attempt = 0; attempt < LOG_MAX_RETRIES; attempt++) {
      const { error } = await supabase.from("coin_transactions").insert({
        user_id:       userId,
        amount:        coinsToAward,
        direction:     "credit",
        feature:       "daily_reward",
        description:   transactionDescription,
        balance_after: newBalance as number,
        ip_address:    ipAddress,
      });
      logError = error;
      if (!error) break;
      if (attempt < LOG_MAX_RETRIES - 1) {
        await new Promise(resolve => setTimeout(resolve, 300 * (attempt + 1)));
      }
    }

    if (logError) {
      console.error(
        `[claim-daily-coins] transaction log failed after ${LOG_MAX_RETRIES} attempts:`,
        logError.message
      );
    }

    console.log(
      `[claim-daily-coins] +${coinsToAward} coins → user=${userId} ` +
      `membership=${hasMembership} balance=${newBalance as number}`
    );

    return jsonResponse({
      success:       true,
      reward_type:   "coins",
      coins_added:   coinsToAward,
      balance:       newBalance as number,
      next_claim_at: nextClaimTime.toISOString(),
    });

  } catch (err) {
    console.error("[claim-daily-coins] unhandled error:", err);
    return jsonResponse({ error: "Internal server error" }, 500);
  }
});
