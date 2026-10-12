-- Welcome accounts should receive the original 50 EZ Coins as well as the
-- 15 Brainrot Slots spins. The installation claim remains the sole gate, so
-- this does not create a second signup bonus path or loosen anti-abuse rules.

CREATE OR REPLACE FUNCTION public.handle_new_user_welcome_coins()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_installation uuid;
  v_email text;
  v_balance integer;
BEGIN
  -- Support both confirmation-enabled and immediate-confirmation signups.
  IF TG_OP = 'INSERT' THEN
    IF NEW.email_confirmed_at IS NULL THEN RETURN NEW; END IF;
  ELSIF NEW.email_confirmed_at IS NULL OR OLD.email_confirmed_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_installation := NULLIF(NEW.raw_user_meta_data->>'installation_id', '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_installation := NULL;
  END;
  IF v_installation IS NULL THEN RETURN NEW; END IF;

  INSERT INTO public.br_welcome_installations (installation_id, user_id)
  VALUES (v_installation, NEW.id)
  ON CONFLICT (installation_id) DO NOTHING;
  IF NOT FOUND THEN RETURN NEW; END IF;

  INSERT INTO public.subscriptions
    (user_id, coins_balance, provider, status, tier, free_spins_remaining,
     free_spins_guarantee_pending, free_spins_batch_payout)
  VALUES (NEW.id, 50, 'none', 'coins_only', 'basic', 15, true, 0)
  ON CONFLICT (user_id) DO UPDATE SET
    coins_balance = COALESCE(public.subscriptions.coins_balance, 0) + 50,
    free_spins_remaining = public.subscriptions.free_spins_remaining + 15,
    free_spins_guarantee_pending = true,
    free_spins_batch_payout = 0
  RETURNING coins_balance INTO v_balance;

  SELECT email INTO v_email FROM auth.users WHERE id = NEW.id;

  -- Coin transactions are the balance ledger; retain a separate usage row
  -- for the slots-specific free-spin grant.
  INSERT INTO public.coin_transactions
    (user_id, amount, direction, feature, description, balance_after)
  VALUES
    (NEW.id, 50, 'credit', 'welcome_bonus',
     'Welcome bonus: +50 EZ Coins', v_balance);

  INSERT INTO public.ez_usage_log
    (user_id, user_email, feature, model, prompt, coins_charged, quantity,
     running_balance, api_cost_usd, status)
  VALUES
    (NEW.id, v_email, 'welcome_free_spins', 'Brainrot Slots',
     'Welcome bonus: +15 free spins', 0, 15, v_balance, 0, 'complete');

  RETURN NEW;
END;
$$;
