-- Server-side, transactional accounting for ez-slot-spin. Run this migration
-- before deploying the function. Coin transactions never trust an app client.
CREATE OR REPLACE FUNCTION public.play_ez_slot_spin(
  p_user_id uuid, p_wager integer, p_payout integer, p_reels jsonb, p_win_lines integer
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_balance integer;
BEGIN
  IF p_wager NOT IN (5, 10, 25) OR p_payout < 0 THEN RAISE EXCEPTION 'Invalid slot wager or payout'; END IF;
  SELECT coins_balance INTO v_balance FROM subscriptions WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance IS NULL THEN RAISE EXCEPTION 'No EZ Coin account'; END IF;
  IF v_balance < p_wager THEN RAISE EXCEPTION 'Insufficient EZ Coins'; END IF;
  v_balance := v_balance - p_wager + p_payout;
  UPDATE subscriptions SET coins_balance = v_balance WHERE user_id = p_user_id;
  -- Keep the stake and the reward as separate entries; this matches the
  -- existing ledger convention (positive amount + debit/credit direction).
  INSERT INTO coin_transactions (user_id, amount, direction, feature, description, balance_after)
  VALUES (p_user_id, p_wager, 'debit', 'brainrot_slots',
          format('Slot stake: %s coins', p_wager), v_balance - p_payout);
  IF p_payout > 0 THEN
    INSERT INTO coin_transactions (user_id, amount, direction, feature, description, balance_after)
    VALUES (p_user_id, p_payout, 'credit', 'brainrot_slots',
            format('Slot payout: %s coins across %s winning paylines; reels %s', p_payout, p_win_lines, p_reels::text), v_balance);
  END IF;
  RETURN v_balance;
END;
$$;
REVOKE ALL ON FUNCTION public.play_ez_slot_spin(uuid, integer, integer, jsonb, integer) FROM PUBLIC;
