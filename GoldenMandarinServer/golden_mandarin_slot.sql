-- Golden Mandarin (金帽福运) — server side, part 1 of 2: table + RPCs.
-- Run this in the Supabase SQL editor, then deploy ez-golden-mandarin-spin
-- (see README.md in this folder). Modeled on play_ez_plunder_slot_spin.
--
-- Money rules, all enforced here and never by the caller:
--   * wager = lines x bet_per_line on a paid spin, 0 on a free spin
--   * free-spin line wins are multiplied by the multiplier STORED on the
--     bonus row (the caller sends only the base payout)
--   * the free-spin award (5-8 / 14-16 / 25-30 for 3 / 4 / 5 hats) is rolled
--     here, in range, so a caller can never invent an award
--   * the multiplier (x2 / x3 / x5) is set once, by pick_..._multiplier, and
--     free spins are refused until it has been picked
--   * banked free spins are capped at 100

create table if not exists public.ez_golden_mandarin_bonus (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  remaining     integer     not null default 0 check (remaining between 0 and 100),
  lines         integer     not null default 9 check (lines between 1 and 9),
  bet_per_line  integer     not null default 1 check (bet_per_line in (1, 5, 10, 15, 25)),
  multiplier    integer     not null default 0 check (multiplier in (0, 2, 3, 5)),
  pick_pending  boolean     not null default false,
  bonus_total   integer     not null default 0,
  updated_at    timestamptz not null default now()
);

-- Only the service role (the edge function) touches this table.
alter table public.ez_golden_mandarin_bonus enable row level security;

create or replace function public.play_ez_golden_mandarin_spin(
  p_user_id uuid,
  p_lines integer,
  p_bet_per_line integer,
  p_free_spin boolean,
  p_base_payout integer,
  p_scatter_count integer,
  p_reels jsonb,
  p_win_lines integer,
  p_ip_address text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_balance integer;
  v_stake_balance integer;
  v_email text;
  v_remaining integer;
  v_lines integer;
  v_bet integer;
  v_mult integer;
  v_pending boolean;
  v_bonus_total integer;
  v_new_remaining integer;
  v_total_bet integer;
  v_wager integer;
  v_payout integer;
  v_awarded integer := 0;
  v_report_total integer;
  v_applied_mult integer := 0;
  v_result text;
begin
  -- 3,200 is the largest single-line pay (5 dragons) in line bets.
  if p_lines not between 1 and 9
     or p_bet_per_line not in (1, 5, 10, 15, 25)
     or p_base_payout < 0
     or p_base_payout > p_lines * p_bet_per_line * 3200
     or p_win_lines not between 0 and p_lines
     or p_scatter_count not between 0 and 5
     or jsonb_typeof(p_reels) <> 'array' or jsonb_array_length(p_reels) <> 5
  then raise exception 'Invalid golden mandarin spin'; end if;

  -- Lock the account first, then its bonus row, for consistent concurrency.
  select coins_balance into v_balance from subscriptions where user_id = p_user_id for update;
  if v_balance is null then raise exception 'Slot account unavailable'; end if;
  insert into ez_golden_mandarin_bonus (user_id) values (p_user_id) on conflict (user_id) do nothing;
  select remaining, lines, bet_per_line, multiplier, pick_pending, bonus_total
    into v_remaining, v_lines, v_bet, v_mult, v_pending, v_bonus_total
  from ez_golden_mandarin_bonus where user_id = p_user_id for update;

  if p_free_spin <> (v_remaining > 0) then
    raise exception 'Free spin state changed; refresh and try again';
  end if;
  if p_free_spin then
    if v_pending or v_mult not in (2, 3, 5) then
      raise exception 'Free spin multiplier not chosen; state changed, refresh and try again';
    end if;
    if p_lines <> v_lines or p_bet_per_line <> v_bet then
      raise exception 'Free spin bet changed; refresh and try again';
    end if;
  end if;

  v_total_bet := p_lines * p_bet_per_line;
  v_wager := case when p_free_spin then 0 else v_total_bet end;
  if v_balance < v_wager then raise exception 'Insufficient EZ Coins'; end if;

  v_applied_mult := case when p_free_spin then v_mult else 1 end;
  v_payout := p_base_payout * v_applied_mult;

  v_awarded := case p_scatter_count
    when 3 then 5 + floor(random() * 4)::int     -- 5..8
    when 4 then 14 + floor(random() * 3)::int    -- 14..16
    when 5 then 25 + floor(random() * 6)::int    -- 25..30
    else 0 end;

  v_stake_balance := v_balance - v_wager;
  v_balance := v_stake_balance + v_payout;

  v_new_remaining := v_remaining - case when p_free_spin then 1 else 0 end;
  v_awarded := least(v_awarded, 100 - v_new_remaining);   -- bank at most 100
  v_new_remaining := v_new_remaining + v_awarded;

  if p_free_spin then v_bonus_total := v_bonus_total + v_payout; end if;

  -- A paid spin that wins free spins opens the bonus: remember the wager
  -- and require the card pick before the first free spin.
  if not p_free_spin and v_awarded > 0 then
    v_lines := p_lines; v_bet := p_bet_per_line;
    v_mult := 0; v_pending := true; v_bonus_total := 0;
  end if;
  v_report_total := v_bonus_total;

  update subscriptions set coins_balance = v_balance where user_id = p_user_id;
  update ez_golden_mandarin_bonus set
    remaining    = v_new_remaining,
    lines        = v_lines,
    bet_per_line = v_bet,
    multiplier   = case when v_new_remaining = 0 then 0 else v_mult end,
    pick_pending = case when v_new_remaining = 0 then false else v_pending end,
    bonus_total  = case when v_new_remaining = 0 then 0 else v_bonus_total end,
    updated_at   = now()
  where user_id = p_user_id;

  select email into v_email from auth.users where id = p_user_id;
  v_result := format(E'%s | %s | %s | %s | %s\n%s | %s | %s | %s | %s\n%s | %s | %s | %s | %s\nWinning lines: %s • Golden hats: %s • Free spins +%s, %s left',
    p_reels->0->>0, p_reels->1->>0, p_reels->2->>0, p_reels->3->>0, p_reels->4->>0,
    p_reels->0->>1, p_reels->1->>1, p_reels->2->>1, p_reels->3->>1, p_reels->4->>1,
    p_reels->0->>2, p_reels->1->>2, p_reels->2->>2, p_reels->3->>2, p_reels->4->>2,
    p_win_lines, p_scatter_count, v_awarded, v_new_remaining);

  if v_wager > 0 then
    insert into coin_transactions (user_id, amount, direction, feature, description, balance_after, ip_address)
    values (p_user_id, v_wager, 'debit', 'brainrot_golden_mandarin_slots',
      format(E'Golden Mandarin stake: %s coins\n%s', v_wager, v_result), v_stake_balance, p_ip_address);
  end if;
  if v_payout > 0 then
    insert into coin_transactions (user_id, amount, direction, feature, description, balance_after, ip_address)
    values (p_user_id, v_payout, 'credit', 'brainrot_golden_mandarin_slots',
      format(E'Golden Mandarin %spayout: %s coins\n%s', case when p_free_spin then 'free-spin ' else '' end, v_payout, v_result), v_balance, p_ip_address);
  end if;
  insert into ez_usage_log (user_id, user_email, feature, model, prompt, coins_charged, quantity, running_balance, api_cost_usd, status, ip_address)
  values (p_user_id, v_email, 'brainrot_golden_mandarin_slots', '5 reels · 9 paylines',
    format(E'%s\n%s\nPayout: %s coins', case when p_free_spin then format('Free spin • line wins x%s', v_applied_mult) else format('Stake: %s coins', v_wager) end, v_result, v_payout),
    v_wager, 1, v_stake_balance, 0, 'complete', p_ip_address);

  return jsonb_build_object(
    'balance', v_balance,
    'payout', v_payout,
    'wager', v_wager,
    'multiplier', case when p_free_spin then v_applied_mult else 0 end,
    'free_spins_remaining', v_new_remaining,
    'free_spins_awarded', v_awarded,
    'pick_pending', (v_new_remaining > 0 and v_pending),
    'bonus_total', v_report_total);
end;
$function$;

-- Sets the bonus multiplier exactly once. The edge function rolls which
-- card hides which multiplier; this only commits the chosen value.
create or replace function public.pick_ez_golden_mandarin_multiplier(
  p_user_id uuid,
  p_multiplier integer
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_remaining integer;
  v_pending boolean;
begin
  if p_multiplier not in (2, 3, 5) then raise exception 'Invalid multiplier'; end if;
  select remaining, pick_pending into v_remaining, v_pending
  from ez_golden_mandarin_bonus where user_id = p_user_id for update;
  if v_remaining is null or v_remaining <= 0 or not v_pending then
    raise exception 'No multiplier pick pending';
  end if;
  update ez_golden_mandarin_bonus
    set multiplier = p_multiplier, pick_pending = false, updated_at = now()
  where user_id = p_user_id;
  return jsonb_build_object('multiplier', p_multiplier, 'free_spins_remaining', v_remaining);
end;
$function$;

-- These move coins. Without this, PostgREST would let any signed-in user
-- call them directly with a made-up payout. Only the edge function (service
-- role) may execute them.
revoke all on function public.play_ez_golden_mandarin_spin(uuid, integer, integer, boolean, integer, integer, jsonb, integer, text) from public, anon, authenticated;
grant execute on function public.play_ez_golden_mandarin_spin(uuid, integer, integer, boolean, integer, integer, jsonb, integer, text) to service_role;
revoke all on function public.pick_ez_golden_mandarin_multiplier(uuid, integer) from public, anon, authenticated;
grant execute on function public.pick_ez_golden_mandarin_multiplier(uuid, integer) to service_role;
