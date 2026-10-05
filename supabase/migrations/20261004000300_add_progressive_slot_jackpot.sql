-- Persistent pool: it starts at 1,000 and each completed spin adds one coin.
CREATE TABLE IF NOT EXISTS public.ez_slot_progressive (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  amount integer NOT NULL CHECK (amount >= 0),
  seed_amount integer NOT NULL DEFAULT 1000 CHECK (seed_amount > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.ez_slot_progressive (id, amount, seed_amount) VALUES (true, 1000, 1000) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.play_ez_slot_spin_v2(
  p_user_id uuid, p_wager integer, p_payout integer, p_reels jsonb, p_win_lines integer, p_progressive_winner boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE v_balance integer; DECLARE v_stake_balance integer; DECLARE v_email text;
DECLARE v_pool integer; DECLARE v_seed integer; DECLARE v_final_payout integer; DECLARE v_next_pool integer;
BEGIN
  IF p_wager NOT IN (5,10,25) OR p_payout < 0 THEN RAISE EXCEPTION 'Invalid slot wager or payout'; END IF;
  IF p_progressive_winner AND p_wager <> 25 THEN RAISE EXCEPTION 'Progressive requires max bet'; END IF;
  SELECT coins_balance INTO v_balance FROM subscriptions WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance IS NULL OR v_balance < p_wager THEN RAISE EXCEPTION 'Insufficient EZ Coins'; END IF;
  SELECT amount, seed_amount INTO v_pool, v_seed FROM ez_slot_progressive WHERE id = true FOR UPDATE;
  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  v_final_payout := p_payout + CASE WHEN p_progressive_winner THEN v_pool ELSE 0 END;
  v_next_pool := CASE WHEN p_progressive_winner THEN v_seed ELSE v_pool + 1 END;
  v_balance := v_balance - p_wager + v_final_payout; v_stake_balance := v_balance - v_final_payout;
  UPDATE subscriptions SET coins_balance = v_balance WHERE user_id = p_user_id;
  UPDATE ez_slot_progressive SET amount = v_next_pool, updated_at = now() WHERE id = true;
  INSERT INTO coin_transactions (user_id,amount,direction,feature,description,balance_after) VALUES (p_user_id,p_wager,'debit','brainrot_slots','Slot stake: ' || p_wager || ' coins',v_stake_balance);
  IF v_final_payout > 0 THEN INSERT INTO coin_transactions (user_id,amount,direction,feature,description,balance_after) VALUES (p_user_id,v_final_payout,'credit','brainrot_slots',CASE WHEN p_progressive_winner THEN 'Progressive jackpot payout: ' || v_final_payout || ' coins' ELSE 'Slot payout: ' || v_final_payout || ' coins' END,v_balance); END IF;
  INSERT INTO ez_usage_log (user_id,user_email,feature,model,prompt,coins_charged,quantity,running_balance,api_cost_usd,status) VALUES (p_user_id,v_email,'brainrot_slots','3 reels · 5 paylines','Slot stake: ' || p_wager || ' coins',p_wager,1,v_stake_balance,0,'complete');
  RETURN jsonb_build_object('balance',v_balance,'payout',v_final_payout,'progressive_jackpot',v_next_pool);
END; $$;
REVOKE ALL ON FUNCTION public.play_ez_slot_spin_v2(uuid,integer,integer,jsonb,integer,boolean) FROM PUBLIC;
