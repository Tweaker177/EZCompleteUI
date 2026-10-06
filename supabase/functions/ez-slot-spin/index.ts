// Server-authoritative EZ Coin slot machine. Deploy with:
// supabase functions deploy ez-slot-spin
// Authentication is additionally verified below, so all random outcomes and
// coin changes remain private to this function.
//
// CHANGE FROM PREVIOUS VERSION: if the signed-in user has free_spins_remaining
// > 0, the spin is served for free (no wager, no jackpot contribution/payout)
// instead of the normal coin-wager flow. Free spins are always played as
// 5 lines x 1 coin/line regardless of what the client sends for `lines`/
// `bet_per_line` — the server decides that, not the client, so a modified
// client can't stretch a free spin into a bigger real-money-equivalent bet.
// The last spin of a batch is forced to win if the user hasn't won anything
// yet in that batch (free_spins_guarantee_pending), guaranteeing everyone
// experiences at least one win from their free spins.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type" };
const SYMBOLS = ["cherry", "bar", "double_bar", "triple_bar", "bell", "diamond", "seven", "brain"] as const;
// Weighted virtual reel strips. Payouts produce an expected RTP of about 92%.
const WEIGHTS = [32, 19, 14, 10, 9, 7, 5, 4];
const PAYOUTS: Record<string, number> = { cherry: 13, bar: 21, double_bar: 37, triple_bar: 55, bell: 75, diamond: 150, seven: 300, brain: 750 };
const PAYLINES = [[1, 1, 1], [0, 0, 0], [2, 2, 2], [0, 1, 2], [2, 1, 0]];
// The one forced "guarantee" line (index 0, the middle row) always resolves
// to the cheapest symbol so a forced win never looks like an engineered jackpot.
const GUARANTEE_SYMBOL = "cherry";

function secureInt(max: number) { const a = new Uint32Array(1); crypto.getRandomValues(a); return a[0] % max; }
function nextSymbol() { let n = secureInt(WEIGHTS.reduce((a, b) => a + b, 0)); for (let i = 0; i < WEIGHTS.length; i++) { if (n < WEIGHTS[i]) return SYMBOLS[i]; n -= WEIGHTS[i]; } return "cherry"; }
function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } }); }

function evaluateLines(reels: string[][], lines: number, betPerLine: number) {
  let payout = 0, winLines = 0, isJackpot = false;
  const winningLines: { index: number; rows: number[]; symbol: string }[] = [];
  for (let index = 0; index < lines; index++) {
    const line = PAYLINES[index];
    const symbols = line.map((row, col) => reels[col][row]);
    if (symbols[0] === symbols[1] && symbols[1] === symbols[2]) {
      payout += betPerLine * PAYOUTS[symbols[0]];
      winLines++;
      winningLines.push({ index, rows: line, symbol: symbols[0] });
      if (lines === 5 && betPerLine === 5 && symbols[0] === "brain") isJackpot = true;
    }
  }
  return { payout, winLines, isJackpot, winningLines };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const admin = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authorization } } });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json({ error: "unauthorized" }, 401);
  const { wager, action, lines, bet_per_line } = await req.json().catch(() => ({}));
  const service = createClient(url, admin);
  if (action === "jackpot_status") {
    const { data, error } = await service.from("ez_slot_progressive").select("amount").eq("id", true).single();
    if (error) return json({ error: "jackpot_unavailable" }, 500);
    // Piggybacked here (rather than a separate round trip) so the client can
    // show "FREE SPIN" state as soon as the Slots screen appears.
    const { data: profile } = await service.from("subscriptions").select("free_spins_remaining").eq("user_id", user.id).single();
    return json({ progressive_jackpot: data.amount, free_spins_remaining: profile?.free_spins_remaining ?? 0 });
  }

  // Free spins take priority and always use a fixed 5-line/1-coin-per-line
  // shape, decided here, not by whatever the client sent.
  const { data: profile, error: profileError } = await service
    .from("subscriptions")
    .select("free_spins_remaining, free_spins_guarantee_pending")
    .eq("user_id", user.id)
    .single();
  if (profileError) return json({ error: "profile_unavailable" }, 500);

  if ((profile?.free_spins_remaining ?? 0) > 0) {
    const freeLines = 5, freeBetPerLine = 1;
    const reels = Array.from({ length: 3 }, () => Array.from({ length: 3 }, nextSymbol));
    let { payout, winLines, winningLines } = evaluateLines(reels, freeLines, freeBetPerLine);
    const isLastSpinOfBatch = profile.free_spins_remaining === 1;
    let forcedWin = false;
    if (isLastSpinOfBatch && profile.free_spins_guarantee_pending && winLines === 0) {
      // Overwrite the guarantee payline (index 0 / middle row) with three
      // matching low-tier symbols so this spin always resolves to a win.
      const [c0, c1, c2] = PAYLINES[0];
      reels[0][c0] = GUARANTEE_SYMBOL; reels[1][c1] = GUARANTEE_SYMBOL; reels[2][c2] = GUARANTEE_SYMBOL;
      const reEval = evaluateLines(reels, freeLines, freeBetPerLine);
      payout = reEval.payout; winLines = reEval.winLines; winningLines = reEval.winningLines;
      forcedWin = true;
    }
    const { data, error } = await service.rpc("play_ez_free_spin_v1", {
      p_user_id: user.id, p_payout: payout, p_reels: reels, p_win_lines: winLines, p_forced_win: forcedWin,
    });
    if (error) return json({ error: "spin_failed", reason: error.message }, 500);
    return json({
      reels, payout: data.payout, win_lines: winLines, winning_lines: winningLines,
      is_jackpot: false, is_free_spin: true, free_spins_remaining: data.free_spins_remaining,
      pity_bonus_granted: data.pity_bonus_granted, pity_spins: data.pity_spins,
      net: data.payout, balance: data.balance,
    });
  }

  // Normal coin-wager flow (unchanged).
  if (!Number.isInteger(lines) || lines < 1 || lines > 5 || !Number.isInteger(bet_per_line) || bet_per_line < 1 || bet_per_line > 5 || wager !== lines * bet_per_line) return json({ error: "invalid_wager", reason: "Choose 1–5 lines and 1–5 coins per line." }, 400);

  const reels = Array.from({ length: 3 }, () => Array.from({ length: 3 }, nextSymbol));
  const { payout, winLines, isJackpot, winningLines } = evaluateLines(reels, lines, bet_per_line);
  // Atomic RPC deducts the wager, adds the payout, and writes an auditable ledger entry.
  const { data, error } = await service.rpc("play_ez_slot_spin_v2", { p_user_id: user.id, p_wager: wager, p_payout: payout, p_reels: reels, p_win_lines: winLines, p_progressive_winner: isJackpot });
  if (error) return json({ error: "spin_failed", reason: error.message }, error.message.includes("Insufficient") ? 402 : 500);
  return json({ reels, payout: data.payout, win_lines: winLines, winning_lines: winningLines, is_jackpot: isJackpot, is_free_spin: false, progressive_jackpot: data.progressive_jackpot, net: data.payout - wager, balance: data.balance });
});
