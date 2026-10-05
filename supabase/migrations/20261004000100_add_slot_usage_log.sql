-- Upgrade the slot accounting introduced in 20261004_ez_slot_machine.sql.
-- A stake is a genuine coin debit, so it must be in ez_usage_log for both the
-- user-facing Usage screen and the admin usage ledger. Payouts stay as credit
-- transactions and get merged into the user feed by get-usage-log.
CREATE OR REPLACE FUNCTION public.play_ez_slot_spin(
  p_user_id uuid, p_wager integer, p_payout integer, p_reels jsonb, p_win_lines integer
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_balance integer;
DECLARE v_stake_balance integer;
DECLARE v_user_email text;
BEGIN
  IF p_wager NOT IN (5, 10, 25) OR p_payout < 0 THEN RAISE EXCEPTION 'Invalid slot wager or payout'; END IF;
  SELECT coins_balance INTO v_balance FROM subscriptions WHERE user_id = p_user_id FOR UPDATE;
  IF v_balance IS NULL THEN RAISE EXCEPTION 'No EZ Coin account'; END IF;
  IF v_balance < p_wager THEN RAISE EXCEPTION 'Insufficient EZ Coins'; END IF;
  SELECT email INTO v_user_email FROM auth.users WHERE id = p_user_id;

  v_balance := v_balance - p_wager + p_payout;
  v_stake_balance := v_balance - p_payout;
  UPDATE subscriptions SET coins_balance = v_balance WHERE user_id = p_user_id;

  -- Admin/circulation ledger: every stake and every payout.
  INSERT INTO coin_transactions (user_id, amount, direction, feature, description, balance_after)
  VALUES (p_user_id, p_wager, 'debit', 'brainrot_slots', 'Slot stake: ' || p_wager || ' coins', v_stake_balance);
  IF p_payout > 0 THEN
    INSERT INTO coin_transactions (user_id, amount, direction, feature, description, balance_after)
    VALUES (p_user_id, p_payout, 'credit', 'brainrot_slots',
            format('Slot payout: %s coins across %s winning paylines; reels %s', p_payout, p_win_lines, p_reels::text), v_balance);
  END IF;

  -- User Usage and admin usage logs: a completed debit for each spin.
  INSERT INTO ez_usage_log (user_id, user_email, feature, model, prompt, coins_charged, quantity,
                            running_balance, api_cost_usd, status)
  VALUES (p_user_id, v_user_email, 'brainrot_slots', '3 reels · 5 paylines',
          format('Slot stake: %s coins%s', p_wager,
                 CASE WHEN p_payout > 0 THEN format(' • payout: %s coins', p_payout) ELSE '' END),
          p_wager, 1, v_stake_balance, 0, 'complete');
  RETURN v_balance;
END;
$$;
