-- One durable bonus state per player. The wager and active lines are locked
-- to the paid spin that awarded the free games.
CREATE TABLE IF NOT EXISTS public.ez_penny_slot_bonus (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  remaining integer NOT NULL DEFAULT 0 CHECK (remaining >= 0),
  lines integer NOT NULL DEFAULT 9 CHECK (lines BETWEEN 1 AND 9),
  bet_per_line integer NOT NULL DEFAULT 1 CHECK (bet_per_line IN (1,5,10,15,25)),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ez_penny_slot_bonus ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ez_penny_slot_bonus FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ez_penny_slot_bonus TO service_role;

CREATE OR REPLACE FUNCTION public.play_ez_penny_slot_spin(
  p_user_id uuid, p_lines integer, p_bet_per_line integer,
  p_free_spin boolean, p_base_payout integer, p_reels jsonb,
  p_win_lines integer, p_scatter_count integer, p_awarded_spins integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE
  v_balance integer;
  v_stake_balance integer;
  v_email text;
  v_remaining integer;
  v_lines integer;
  v_bet_per_line integer;
  v_wager integer;
  v_payout integer;
  v_result text;
  v_expected_spins integer;
BEGIN
  v_expected_spins := CASE
    WHEN p_scatter_count = 3 THEN 5
    WHEN p_scatter_count = 4 THEN 15
    WHEN p_scatter_count >= 5 THEN 25
    ELSE 0
  END;
  IF p_lines NOT BETWEEN 1 AND 9 OR p_bet_per_line NOT IN (1,5,10,15,25)
     OR p_base_payout < 0 OR p_win_lines NOT BETWEEN 0 AND 9
     OR p_scatter_count NOT BETWEEN 0 AND 15
     OR p_awarded_spins <> v_expected_spins
     OR jsonb_typeof(p_reels) <> 'array' OR jsonb_array_length(p_reels) <> 5
  THEN RAISE EXCEPTION 'Invalid penny slot spin'; END IF;

  -- Lock the account first, then its bonus row, for consistent concurrency.
  SELECT coins_balance INTO v_balance FROM subscriptions WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance IS NULL THEN RAISE EXCEPTION 'Slot account unavailable'; END IF;
  INSERT INTO ez_penny_slot_bonus (user_id) VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;
  SELECT remaining, lines, bet_per_line INTO v_remaining, v_lines, v_bet_per_line
  FROM ez_penny_slot_bonus WHERE user_id = p_user_id FOR UPDATE;
  IF p_free_spin <> (v_remaining > 0) THEN RAISE EXCEPTION 'Free spin state changed; refresh and try again'; END IF;
  IF p_free_spin AND (p_lines <> v_lines OR p_bet_per_line <> v_bet_per_line)
  THEN RAISE EXCEPTION 'Free spin bet changed; refresh and try again'; END IF;
  v_wager := CASE WHEN p_free_spin THEN 0 ELSE p_lines * p_bet_per_line END;
  IF v_balance < v_wager THEN RAISE EXCEPTION 'Insufficient EZ Coins'; END IF;
  v_payout := p_base_payout * CASE WHEN p_free_spin THEN 2 ELSE 1 END;
  v_stake_balance := v_balance - v_wager;
  v_balance := v_stake_balance + v_payout;
  v_remaining := v_remaining - CASE WHEN p_free_spin THEN 1 ELSE 0 END + p_awarded_spins;
  UPDATE subscriptions SET coins_balance = v_balance WHERE user_id = p_user_id;
  UPDATE ez_penny_slot_bonus SET remaining = v_remaining, lines = p_lines,
    bet_per_line = p_bet_per_line, updated_at = now() WHERE user_id = p_user_id;
  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  v_result := format(E'%s | %s | %s | %s | %s\n%s | %s | %s | %s | %s\n%s | %s | %s | %s | %s\nWinning lines: %s • EZCoin scatters: %s • Free spins +%s, %s left',
    p_reels->0->>0,p_reels->1->>0,p_reels->2->>0,p_reels->3->>0,p_reels->4->>0,
    p_reels->0->>1,p_reels->1->>1,p_reels->2->>1,p_reels->3->>1,p_reels->4->>1,
    p_reels->0->>2,p_reels->1->>2,p_reels->2->>2,p_reels->3->>2,p_reels->4->>2,
    p_win_lines,p_scatter_count,p_awarded_spins,v_remaining);
  IF v_wager > 0 THEN
    INSERT INTO coin_transactions (user_id,amount,direction,feature,description,balance_after)
    VALUES (p_user_id,v_wager,'debit','brainrot_penny_slots',format(E'Penny Slots stake: %s coins (%s lines × %s)\n%s',v_wager,p_lines,p_bet_per_line,v_result),v_stake_balance);
  END IF;
  IF v_payout > 0 THEN
    INSERT INTO coin_transactions (user_id,amount,direction,feature,description,balance_after)
    VALUES (p_user_id,v_payout,'credit','brainrot_penny_slots',format(E'Penny Slots %spayout: %s coins\n%s',CASE WHEN p_free_spin THEN 'free-spin 2× ' ELSE '' END,v_payout,v_result),v_balance);
  END IF;
  INSERT INTO ez_usage_log (user_id,user_email,feature,model,prompt,coins_charged,quantity,running_balance,api_cost_usd,status)
  VALUES (p_user_id,v_email,'brainrot_penny_slots','5 reels · 9 paylines',
    format(E'%s\n%s\nPayout: %s coins',CASE WHEN p_free_spin THEN 'Free spin • 2× payout' ELSE format('Stake: %s coins (%s × %s)',v_wager,p_lines,p_bet_per_line) END,v_result,v_payout),
    v_wager,1,v_stake_balance,0,'complete');
  RETURN jsonb_build_object('balance',v_balance,'payout',v_payout,'wager',v_wager,
    'free_spins_remaining',v_remaining,'free_spins_awarded',p_awarded_spins);
END; $$;
REVOKE ALL ON FUNCTION public.play_ez_penny_slot_spin(uuid,integer,integer,boolean,integer,jsonb,integer,integer,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.play_ez_penny_slot_spin(uuid,integer,integer,boolean,integer,jsonb,integer,integer,integer) TO service_role;
