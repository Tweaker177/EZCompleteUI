// Five-reel, nine-line EZ Coin slot. All outcomes are generated here and
// settled atomically by play_ez_penny_slot_spin.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type" };
const SYMBOLS = ["cherry", "bar", "double_bar", "triple_bar", "bell", "diamond", "seven", "brain", "ez_coin"] as const;
const WEIGHTS = [32, 20, 14, 10, 8, 6, 4, 3, 3]; // sum = 100
// Per coin per line for 3, 4, or 5 consecutive matches from the left.
const PAYS: Record<string, [number, number, number]> = {
  cherry: [8, 19, 55], bar: [12, 34, 110], double_bar: [19, 55, 172],
  triple_bar: [27, 80, 258], bell: [43, 123, 430], diamond: [74, 221, 738],
  seven: [154, 492, 1476], brain: [308, 923, 3075],
};
const PAYLINES = [
  [1,1,1,1,1], [0,0,0,0,0], [2,2,2,2,2],
  [0,1,2,1,0], [2,1,0,1,2], [0,0,1,2,2],
  [2,2,1,0,0], [1,0,0,0,1], [1,2,2,2,1],
];
const BET_CHOICES = [1, 5, 10, 15, 25];
function secureInt(max: number): number {
  const limit = Math.floor(0x100000000 / max) * max;
  const value = new Uint32Array(1);
  do { crypto.getRandomValues(value); } while (value[0] >= limit);
  return value[0] % max;
}
function nextSymbol(): string {
  let n = secureInt(100);
  for (let i = 0; i < SYMBOLS.length; i++) {
    if (n < WEIGHTS[i]) return SYMBOLS[i];
    n -= WEIGHTS[i];
  }
  throw new Error("Invalid reel weights");
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
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
  const service = createClient(url, admin);
  const body = await req.json().catch(() => ({}));
  const { data: bonus, error: bonusError } = await service.from("ez_penny_slot_bonus")
    .select("remaining,lines,bet_per_line").eq("user_id", user.id).maybeSingle();
  if (bonusError) return json({ error: "bonus_unavailable", reason: bonusError.message }, 500);
  const remaining = bonus?.remaining ?? 0;
  if (body.action === "status") return json({ free_spins_remaining: remaining,
    lines: bonus?.lines ?? 9, bet_per_line: bonus?.bet_per_line ?? 1 });
  const isFreeSpin = remaining > 0;
  const lines = isFreeSpin ? bonus!.lines : body.lines;
  const betPerLine = isFreeSpin ? bonus!.bet_per_line : body.bet_per_line;
  if (!Number.isInteger(lines) || lines < 1 || lines > 9 || !BET_CHOICES.includes(betPerLine))
    return json({ error: "invalid_wager", reason: "Choose 1–9 lines and a valid bet per line." }, 400);

  const reels = Array.from({ length: 5 }, () => Array.from({ length: 3 }, nextSymbol));
  const winningLines: { index: number; rows: number[]; symbol: string; matches: number; coins: number }[] = [];
  let basePayout = 0;
  for (let index = 0; index < lines; index++) {
    const line = PAYLINES[index];
    const symbol = reels[0][line[0]];
    if (symbol === "ez_coin") continue; // scatter pays only through free spins
    let matches = 1;
    while (matches < 5 && reels[matches][line[matches]] === symbol) matches++;
    if (matches < 3) continue;
    const coins = betPerLine * PAYS[symbol][matches - 3] * (isFreeSpin ? 2 : 1);
    basePayout += betPerLine * PAYS[symbol][matches - 3];
    winningLines.push({ index, rows: line, symbol, matches, coins });
  }
  const scatterCount = reels.flat().filter((symbol) => symbol === "ez_coin").length;
  const awardedSpins = scatterCount === 3 ? 5 : scatterCount === 4 ? 15 : scatterCount >= 5 ? 25 : 0;
  const { data, error } = await service.rpc("play_ez_penny_slot_spin", {
    p_user_id: user.id, p_lines: lines, p_bet_per_line: betPerLine,
    p_free_spin: isFreeSpin, p_base_payout: basePayout, p_reels: reels,
    p_win_lines: winningLines.length, p_scatter_count: scatterCount, p_awarded_spins: awardedSpins,
  });
  if (error) return json({ error: "spin_failed", reason: error.message },
    error.message.includes("Insufficient") ? 402 : error.message.includes("changed") ? 409 : 500);
  return json({ reels, winning_lines: winningLines, win_lines: winningLines.length,
    scatter_count: scatterCount, free_spins_awarded: data.free_spins_awarded,
    free_spins_remaining: data.free_spins_remaining, was_free_spin: isFreeSpin,
    lines, bet_per_line: betPerLine, wager: data.wager, payout: data.payout,
    net: data.payout - data.wager, balance: data.balance });
});
