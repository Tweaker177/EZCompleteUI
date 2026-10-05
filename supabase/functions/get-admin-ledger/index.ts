// index.ts — Admin Ledger Query (Supabase Edge Function)
//
// Purpose:
//   Read-only admin reporting endpoint over coin usage and circulation.
//   Three modes, selected via ?mode=:
//     master — per-user summary rows (ez_master_summary view), sorted by API
//              cost, optionally filtered by email substring.
//     user   — full per-row detail (ez_admin_ledger view) plus an aggregate
//              block: totals for whatever filter set was applied (user_id /
//              email / since / until), and a separate global circulation
//              snapshot that always covers the whole platform regardless of
//              those filters.
//     pnl    — single-row platform P&L snapshot (ez_platform_pnl view).
//
//   Never called from the app itself — call from your own admin dashboard
//   only, with the ADMIN_SECRET header set.
//
// Required environment variables:
//   ADMIN_SECRET — shared secret checked against the x-admin-secret header.
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
//
// Required database objects:
//   ez_master_summary, ez_admin_ledger, ez_usage_log, ez_platform_pnl —
//   pre-existing views, not created by this comment.
//   ez_coin_circulation, ez_coin_balances_total — see
//   coin_circulation_views.sql. Must exist before deploying this version,
//   or the mode=user response will log query errors for those two views
//   and silently return zeros for the global_* aggregate fields.
//
// Changes from previous version:
//   - mode=user now queries ez_all_ledger_rows instead of ez_admin_ledger.
//     ez_all_ledger_rows is a UNION view that adds credit rows (daily claims,
//     top-ups, subscription renewals, adjustments from coin_transactions) to
//     the existing debit rows. Each row now includes a direction field
//     ("credit" or "debit") so the iOS client can display them correctly.
//     The aggregate query still runs against ez_usage_log (debit/spend only)
//     since credits have no API cost and should not skew spend metrics.
//   - Added feature= filter param to mode=user (ilike match on the feature
//     column). Enables filtering to a single feature type, e.g. ?feature=tts,
//     ?feature=daily_reward, ?feature=topup. Applied to both the row query
//     and the aggregate query.
//   - mode=user aggregate includes a global, unfiltered coin circulation
//     snapshot (total issued, redeemed, net circulating, live balance sum,
//     and drift between the two).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Admin auth ────────────────────────────────────────────────────────────────
// This endpoint requires an admin secret header in addition to a valid JWT.
// Set ADMIN_SECRET in your Supabase Edge Function environment variables.
// Never expose this to the client app — call it from your own dashboard only.

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type, x-admin-secret",
    "Content-Type":                 "application/json",
  };
}

function json(body: object, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders() });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  try {
    // ── Double auth: valid JWT + matching admin secret ────────────────────────
    const authHeader  = req.headers.get("Authorization");
    const adminSecret = req.headers.get("x-admin-secret");

    if (!authHeader) return json({ error: "No auth" }, 401);

    const expectedSecret = Deno.env.get("ADMIN_SECRET");
    if (!expectedSecret || adminSecret !== expectedSecret) {
      return json({ error: "Admin access required" }, 403);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!  // service role — bypasses RLS
    );

    // Verify the JWT is still a valid EZ user (belt + suspenders)
    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) return json({ error: "Invalid token" }, 401);

    const url    = new URL(req.url);
    const mode   = url.searchParams.get("mode") ?? "master";   // master | user | pnl
    const limit  = Math.min(parseInt(url.searchParams.get("limit")  ?? "200"), 1000);
    const offset = parseInt(url.searchParams.get("offset") ?? "0");
    const userId  = url.searchParams.get("user_id");             // filter to one user
    const email   = url.searchParams.get("email");               // filter by email
    const feature = url.searchParams.get("feature");             // filter by feature name (e.g. "tts", "chat")
    const excludeFeature = url.searchParams.get("exclude_feature"); // omit matching feature names
    const since   = url.searchParams.get("since");               // ISO date filter
    const until   = url.searchParams.get("until");

    // ── mode: pnl — global platform P&L snapshot ─────────────────────────────
    if (mode === "pnl") {
      const { data, error } = await supabase
        .from("ez_platform_pnl")
        .select("*")
        .single();

      if (error) {
        console.error("[get-admin-ledger] pnl query error:", error.message);
        return json({ error: "Query failed" }, 500);
      }

      return json({ pnl: data });
    }

    // ── mode: master — all users summary ─────────────────────────────────────
    if (mode === "master") {
      let query = supabase
        .from("ez_master_summary")
        .select("*")
        .order("total_api_cost_usd", { ascending: false })
        .range(offset, offset + limit - 1);

      if (email) query = query.ilike("user_email", `%${email}%`);

      const { data, error } = await query;
      if (error) {
        console.error("[get-admin-ledger] master query error:", error.message);
        return json({ error: "Query failed" }, 500);
      }

      return json({ rows: data ?? [], mode: "master", limit, offset });
    }

    // ── mode: user — full per-row detail for one or all users ────────────────
    if (mode === "user") {
      let query = supabase
        .from("ez_all_ledger_rows")
        .select(`
          id, created_at, user_id, user_email, ip_address, session_id,
          feature, model, prompt,
          coins_charged, quantity, running_balance,
          input_tokens, output_tokens, total_tokens,
          images_returned, images_requested,
          api_cost_usd, cost_per_100_coins, implied_margin_pct,
          status, error_text, direction
        `)
        .order("created_at", { ascending: false })
        .range(offset, offset + limit - 1);

      if (userId)  query = query.eq("user_id", userId);
      if (email)   query = query.ilike("user_email", `%${email}%`);
      if (feature) query = query.ilike("feature", `%${feature}%`);
      if (excludeFeature) query = query.not("feature", "ilike", `%${excludeFeature}%`);
      if (since)   query = query.gte("created_at", since);
      if (until)   query = query.lte("created_at", until);

      const { data: rows, error: rowsErr } = await query;
      if (rowsErr) {
        console.error("[get-admin-ledger] user query error:", rowsErr.message);
        return json({ error: "Query failed" }, 500);
      }

      // Per-query aggregate for this filter set
      let aggQuery = supabase
        .from("ez_usage_log")
        .select("coins_charged, api_cost_usd, input_tokens, output_tokens, images_returned, status")
        .eq("status", "complete");

      if (userId)  aggQuery = aggQuery.eq("user_id", userId);
      if (email)   aggQuery = aggQuery.eq("user_email", email);
      if (feature) aggQuery = aggQuery.ilike("feature", `%${feature}%`);
      if (excludeFeature) aggQuery = aggQuery.not("feature", "ilike", `%${excludeFeature}%`);
      if (since)   aggQuery = aggQuery.gte("created_at", since);
      if (until)   aggQuery = aggQuery.lte("created_at", until);

      const { data: aggRows } = await aggQuery;

      let totalCoins = 0, totalCost = 0, totalIn = 0, totalOut = 0, totalImages = 0;
      for (const r of aggRows ?? []) {
        totalCoins  += r.coins_charged ?? 0;
        totalCost   += parseFloat(r.api_cost_usd ?? "0");
        totalIn     += r.input_tokens  ?? 0;
        totalOut    += r.output_tokens ?? 0;
        totalImages += r.images_returned ?? 0;
      }

      const costPer100 = totalCoins > 0
        ? parseFloat((totalCost / totalCoins * 100).toFixed(4)) : null;
      const margin = totalCoins > 0
        ? parseFloat(((totalCoins * 0.0100 - totalCost) / (totalCoins * 0.0100) * 100).toFixed(2))
        : null;

      // ── Global coin circulation snapshot ──────────────────────────────────
      // Deliberately NOT filtered by user_id/email/since/until like the
      // aggregate above — this is the whole-platform total regardless of
      // whatever page/filter this particular request is looking at.
      //
      // total_circulating comes from summing every credit/debit ever logged
      // to coin_transactions (see coin_circulation_views.sql). total_balances
      // is the actual sum of every live subscriptions.coins_balance row.
      // They should match; global_circulation_drift is the gap between them,
      // and a nonzero value means some coin-mutating path changed a balance
      // without logging a matching transaction — worth investigating, not
      // just displaying.
      const [
        { data: circulation, error: circError },
        { data: balances,    error: balError  },
      ] = await Promise.all([
        supabase.from("ez_coin_circulation").select("*").single(),
        supabase.from("ez_coin_balances_total").select("*").single(),
      ]);

      if (circError) console.error("[get-admin-ledger] ez_coin_circulation query error:", circError.message);
      if (balError)  console.error("[get-admin-ledger] ez_coin_balances_total query error:", balError.message);

      const totalIssued      = circulation?.total_issued       ?? 0;
      const totalRedeemed    = circulation?.total_redeemed     ?? 0;
      const totalCirculating = circulation?.total_circulation  ?? 0;
      const totalInBalances  = balances?.total_balances        ?? 0;

      return json({
        rows:      rows ?? [],
        aggregate: {
          total_calls:         aggRows?.length ?? 0,
          total_coins:         totalCoins,
          total_api_cost_usd:  Math.round(totalCost * 1000000) / 1000000,
          total_input_tokens:  totalIn,
          total_output_tokens: totalOut,
          total_images:        totalImages,
          cost_per_100_coins:  costPer100,
          implied_margin_pct:  margin,

          // Global, unfiltered — see comment above. Distinct key prefix on
          // purpose so these are never confused with the filtered totals
          // above (e.g. total_coins is "coins spent in this filtered view";
          // global_total_circulating is "coins that exist platform-wide").
          global_total_issued:      totalIssued,
          global_total_redeemed:    totalRedeemed,
          global_total_circulating: totalCirculating,
          global_total_balances:    totalInBalances,
          global_circulation_drift: totalCirculating - totalInBalances,
        },
        mode:   "user",
        filter: { user_id: userId, email, feature, exclude_feature: excludeFeature, since, until },
        limit,
        offset,
      });
    }

    return json({ error: "Unknown mode. Use: master | user | pnl" }, 400);

  } catch (e) {
    console.error("[get-admin-ledger] Uncaught error:", e);
    return json({ error: "Server error" }, 500);
  }
});
