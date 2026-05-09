import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Coin costs ────────────────────────────────────────────────────────────────
// LLM costs are per 1,000 tokens (input + estimated output combined).
// TTS is calculated client-side as ceil(charCount / 50) and passed as
// estimated_coins directly — no feature key needed for TTS, use action="deduct".
//
// Flat-rate features use a fixed coin amount per invocation.

const COIN_COSTS_PER_1K_TOKENS: Record<string, number> = {
  chat_mini:     1,   // gpt-4o-mini, gpt-4.1-mini, o4-mini
  chat_standard: 3,   // gpt-4o, gpt-4.1, gpt-4.5
  chat_premium:  10,  // gpt-5, gpt-5-mini, o3, o1
};

const COIN_COSTS_FLAT: Record<string, number> = {
  // Images
  image_low:          3,
  image_medium:       6,
  image_high:         20,
  dalle3_standard:    8,
  dalle3_hd:          12,

  // Sora — standard
  sora_4s:            60,
  sora_8s:            120,
  sora_10s:           150,
  sora_12s:           180,
  sora_16s:           240,

  // Sora — pro
  sora_pro_4s:        150,
  sora_pro_8s:        300,
  sora_pro_10s:       400,
  sora_pro_12s:       480,
  sora_pro_16s:       600,

  // Voice
  voice_clone:        25,

  // Tools
  web_search:         2,

  // STT
  whisper_minute:     3,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Content-Type":                 "application/json",
  };
}

function jsonResponse(body: object, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders(),
  });
}

// Safe subscription fetch — handles duplicate rows gracefully by always
// taking the most recently updated row. Duplicates can occur when PayPal
// fires multiple activation events with different subscription IDs for the
// same user. Using .single() on duplicates throws an error and breaks the app.
async function fetchSubscription(
  supabase: ReturnType<typeof createClient>,
  userId: string
) {
  const { data, error } = await supabase
    .from("subscriptions")
    .select("coins_balance, tier, status, current_period_end")
    .eq("user_id", userId)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  return { data, error };
}

// ── Main handler ──────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ allowed: false, reason: "No auth" }, 401);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) {
      return jsonResponse({ allowed: false, reason: "Invalid token" }, 401);
    }

    const body   = await req.json();
    const action: string = body.action ?? "check";

    // ── action: refund_tokens ─────────────────────────────────────────────────
    if (action === "refund_tokens") {
      const { tier, estimated_tokens, actual_tokens } = body;
      if (!tier || estimated_tokens == null || actual_tokens == null) {
        return jsonResponse({ success: false, reason: "Missing fields" }, 400);
      }

      const ratePerK = COIN_COSTS_PER_1K_TOKENS[tier];
      if (ratePerK == null) {
        return jsonResponse({ success: false, reason: "Unknown tier" }, 400);
      }

      const estimatedCoins = Math.ceil((estimated_tokens / 1000) * ratePerK);
      const actualCoins    = Math.ceil((actual_tokens    / 1000) * ratePerK);
      const refundCoins    = Math.max(0, estimatedCoins - actualCoins);

      if (refundCoins === 0) {
        return jsonResponse({ success: true, refunded: 0 });
      }

      const { data: sub } = await supabase
        .from("subscriptions")
        .select("coins_balance")
        .eq("user_id", user.id)
        .order("updated_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      const newBalance = (sub?.coins_balance ?? 0) + refundCoins;
      await supabase
        .from("subscriptions")
        .update({ coins_balance: newBalance, updated_at: new Date().toISOString() })
        .eq("user_id", user.id);

      await supabase.from("coin_transactions").insert({
        user_id:       user.id,
        amount:        refundCoins,
        direction:     "credit",
        feature:       tier,
        description:   `Refund: estimated ${estimatedCoins} coins, actual ${actualCoins}`,
        balance_after: newBalance,
      });

      return jsonResponse({ success: true, refunded: refundCoins, balance: newBalance });
    }

    // ── Fetch subscription (all other actions need it) ────────────────────────
    const { data: sub, error: subError } = await fetchSubscription(supabase, user.id);

    if (subError || !sub) {
      console.error(`[check-entitlement] No subscription for user ${user.id}:`, subError?.message);
      return jsonResponse({ allowed: false, reason: "No account found" });
    }

    const currentBalance: number = sub.coins_balance ?? 0;

    // ── action: check_balance ─────────────────────────────────────────────────
    if (action === "check_balance") {
      return jsonResponse({
        allowed: true,
        balance: currentBalance,
        tier:    sub.tier,
        status:  sub.status,
      });
    }

    // ── action: deduct ────────────────────────────────────────────────────────
    // Used for TTS where the client pre-calculates the exact coin cost.
    // Body: { action: "deduct", feature: "tts", coins: 14 }
    if (action === "deduct") {
      const { feature, coins } = body;
      if (!feature || coins == null || coins < 0) {
        return jsonResponse({ allowed: false, reason: "Missing feature or coins" }, 400);
      }

      if (currentBalance < coins) {
        return jsonResponse({
          allowed: false,
          reason:  "Insufficient coins",
          balance: currentBalance,
          cost:    coins,
        });
      }

      const newBalance = currentBalance - coins;
      await supabase
        .from("subscriptions")
        .update({ coins_balance: newBalance, updated_at: new Date().toISOString() })
        .eq("user_id", user.id);

      if (coins > 0) {
        await supabase.from("coin_transactions").insert({
          user_id:       user.id,
          amount:        coins,
          direction:     "debit",
          feature:       feature,
          description:   `Used ${feature}`,
          balance_after: newBalance,
        });
      }

      return jsonResponse({ allowed: true, balance: newBalance, cost: coins, tier: sub.tier });
    }

    // ── action: check — flat-rate or token-based, deducts immediately ─────────
    if (action === "check") {
      const { feature, estimated_tokens } = body;
      if (!feature) {
        return jsonResponse({ allowed: false, reason: "No feature specified" }, 400);
      }

      let coinCost: number;

      if (COIN_COSTS_PER_1K_TOKENS[feature] != null) {
        if (estimated_tokens == null || estimated_tokens <= 0) {
          return jsonResponse({
            allowed: false,
            reason:  "estimated_tokens required for this feature",
          }, 400);
        }
        coinCost = Math.ceil((estimated_tokens / 1000) * COIN_COSTS_PER_1K_TOKENS[feature]);
      } else if (COIN_COSTS_FLAT[feature] != null) {
        coinCost = COIN_COSTS_FLAT[feature];
      } else {
        coinCost = 0; // unknown feature — free but logged
      }

      if (currentBalance < coinCost) {
        return jsonResponse({
          allowed: false,
          reason:  "Insufficient coins",
          balance: currentBalance,
          cost:    coinCost,
        });
      }

      const newBalance = currentBalance - coinCost;
      await supabase
        .from("subscriptions")
        .update({ coins_balance: newBalance, updated_at: new Date().toISOString() })
        .eq("user_id", user.id);

      if (coinCost > 0) {
        await supabase.from("coin_transactions").insert({
          user_id:       user.id,
          amount:        coinCost,
          direction:     "debit",
          feature:       feature,
          description:   `Used ${feature}`,
          balance_after: newBalance,
        });
      }

      return jsonResponse({
        allowed: true,
        balance: newBalance,
        cost:    coinCost,
        tier:    sub.tier,
      });
    }

    return jsonResponse({ allowed: false, reason: "Unknown action" }, 400);

  } catch (e) {
    console.error("[check-entitlement] Uncaught error:", e);
    return jsonResponse({ allowed: false, reason: "Server error" }, 500);
  }
});
