import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Coin pricing tiers (for margin calculation display) ───────────────────────
// cost_per_100_coins vs these breakevens tells you margin per transaction.
const BREAKEVEN_BEST  = 0.80;   // Ultra tier:   $20 / 2500 coins
const BREAKEVEN_WORST = 1.25;   // Basic tier:   $5  / 400  coins
const BREAKEVEN_AVG   = 1.00;   // Rough average across tiers

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Content-Type":                 "application/json",
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "No auth" }), {
        status: 401, headers: corsHeaders(),
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Invalid token" }), {
        status: 401, headers: corsHeaders(),
      });
    }

    const url    = new URL(req.url);
    const limit  = Math.min(parseInt(url.searchParams.get("limit")  ?? "100"), 500);
    // The app sends page; retain offset for direct callers. The prior endpoint
    // treated page=1 as offset 1, producing overlapping pages.
    const page   = Math.max(0, parseInt(url.searchParams.get("page") ?? "0"));
    const offset = Math.max(0, parseInt(url.searchParams.get("offset") ?? String(page * limit)));

    // ── Fetch usage plus non-API credits ───────────────────────────────────────
    // Feature debits live in ez_usage_log. Daily rewards and slot payouts are
    // coin movements rather than billable API work, so merge only those credits
    // from coin_transactions without duplicating ordinary feature debits.
    const { data: usageRows, error: rowsError } = await supabase
      .from("ez_usage_log")
      .select(`
        id, created_at, feature, model, prompt,
        coins_charged, quantity, running_balance,
        input_tokens, output_tokens, total_tokens,
        images_returned, images_requested,
        api_cost_usd, cost_per_100_coins,
        status, error_text
      `)
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .range(0, offset + limit);

    if (rowsError) {
      console.error("[get-usage-log] Query error:", rowsError.message);
      return new Response(JSON.stringify({ error: "Query failed" }), {
        status: 500, headers: corsHeaders(),
      });
    }

    const { data: specialCredits, error: creditsError } = await supabase
      .from("coin_transactions")
      .select("id, created_at, amount, feature, description, balance_after")
      .eq("user_id", user.id)
      .in("feature", ["daily_reward", "brainrot_slots", "brainrot_penny_slots"])
      .eq("direction", "credit")
      .order("created_at", { ascending: false });

    if (creditsError) {
      console.error("[get-usage-log] Daily-credit query error:", creditsError.message);
      return new Response(JSON.stringify({ error: "Query failed" }), {
        status: 500, headers: corsHeaders(),
      });
    }

    const debitRows = (usageRows ?? []).map((row) => ({ ...row, direction: "debit" }));
    const creditRows = (specialCredits ?? []).map((row) => ({
      id: `credit-${row.id}`,
      created_at: row.created_at,
      feature: row.feature,
      model: null,
      prompt: row.description ?? (row.feature === "brainrot_penny_slots" ? "Penny Slots payout" : row.feature === "brainrot_slots" ? "Slot payout" : "Daily free coins"),
      coins_charged: row.amount ?? 0,
      quantity: 1,
      running_balance: row.balance_after,
      input_tokens: null,
      output_tokens: null,
      total_tokens: null,
      images_returned: null,
      images_requested: null,
      api_cost_usd: "0.000000",
      cost_per_100_coins: null,
      status: "complete",
      error_text: null,
      direction: "credit",
    }));
    const allRows = [...debitRows, ...creditRows]
      .sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    const rows = allRows.slice(offset, offset + limit);
    const hasMore = allRows.length > offset + limit;

    // ── Aggregate stats ───────────────────────────────────────────────────────
    const { data: agg } = await supabase
      .from("ez_usage_log")
      .select("coins_charged, api_cost_usd, input_tokens, output_tokens, images_returned")
      .eq("user_id", user.id)
      .eq("status", "complete");

    let totalCoins        = 0;
    let totalApiCostUsd   = 0;
    let totalInputTokens  = 0;
    let totalOutputTokens = 0;
    let totalImages       = 0;
    let totalCalls        = 0;

    for (const row of agg ?? []) {
      totalCoins        += row.coins_charged      ?? 0;
      totalApiCostUsd   += parseFloat(row.api_cost_usd ?? "0");
      totalInputTokens  += row.input_tokens       ?? 0;
      totalOutputTokens += row.output_tokens      ?? 0;
      totalImages       += row.images_returned    ?? 0;
      totalCalls++;
    }

    const globalCostPer100 = totalCoins > 0
      ? Math.round((totalApiCostUsd / totalCoins) * 100 * 10000) / 10000
      : null;

    // Implied margin at average tier pricing ($1.00 per 100 coins)
    const revenueAtAvgTier = totalCoins * BREAKEVEN_AVG / 100;
    const impliedMarginPct = revenueAtAvgTier > 0
      ? Math.round((revenueAtAvgTier - totalApiCostUsd) / revenueAtAvgTier * 100 * 100) / 100
      : null;

    return new Response(JSON.stringify({
      rows,
      aggregate: {
        total_calls:          totalCalls,
        total_coins_charged:  totalCoins,
        total_api_cost_usd:   Math.round(totalApiCostUsd * 1000000) / 1000000,
        total_input_tokens:   totalInputTokens,
        total_output_tokens:  totalOutputTokens,
        total_tokens:         totalInputTokens + totalOutputTokens,
        total_images:         totalImages,
        cost_per_100_coins:   globalCostPer100,
        implied_margin_pct:   impliedMarginPct,
        breakeven_best:       BREAKEVEN_BEST,   // Ultra tier
        breakeven_worst:      BREAKEVEN_WORST,  // Basic tier
      },
      pagination: { limit, offset },
      has_more: hasMore,
    }), {
      status: 200,
      headers: corsHeaders(),
    });

  } catch (e) {
    console.error("[get-usage-log] Uncaught error:", e);
    return new Response(JSON.stringify({ error: "Server error" }), {
      status: 500, headers: corsHeaders(),
    });
  }
});
