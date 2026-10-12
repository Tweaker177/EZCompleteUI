-- Welcome bonuses used to be granted directly from an auth.users trigger.
-- Database triggers do not receive the client's network address, so move the
-- decision to claim-welcome-bonus (an authenticated Edge Function) and make
-- the database RPC atomic. A network receives at most one welcome grant.

CREATE TABLE IF NOT EXISTS public.welcome_bonus_claims (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  installation_id uuid,
  ip_address text,
  claimed_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS welcome_bonus_claims_installation_idx
  ON public.welcome_bonus_claims (installation_id)
  WHERE installation_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS welcome_bonus_claims_ip_idx
  ON public.welcome_bonus_claims (ip_address)
  WHERE ip_address IS NOT NULL;

-- Existing accounts must not become eligible again merely because the grant
-- mechanism changed. Retain their installation/user history without inventing
-- an IP that was never captured.
INSERT INTO public.welcome_bonus_claims (user_id, installation_id)
SELECT w.user_id, w.installation_id
FROM public.br_welcome_installations AS w
JOIN auth.users AS u ON u.id = w.user_id
ON CONFLICT DO NOTHING;

INSERT INTO public.welcome_bonus_claims (user_id)
SELECT DISTINCT ct.user_id
FROM public.coin_transactions AS ct
JOIN auth.users AS u ON u.id = ct.user_id
WHERE ct.feature = 'welcome_bonus'
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.claim_welcome_bonus(
  p_user_id uuid,
  p_ip_address text
)
RETURNS TABLE (
  granted boolean,
  reason text,
  coins_balance integer,
  free_spins_remaining integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_installation uuid;
  v_balance integer;
  v_spins integer;
BEGIN
  IF NULLIF(btrim(p_ip_address), '') IS NULL THEN
    RETURN QUERY SELECT false, 'ip_unavailable', NULL::integer, NULL::integer;
    RETURN;
  END IF;

  BEGIN
    SELECT NULLIF(raw_user_meta_data->>'installation_id', '')::uuid
      INTO v_installation
      FROM auth.users WHERE id = p_user_id;
  EXCEPTION WHEN invalid_text_representation THEN
    v_installation := NULL;
  END;
  IF v_installation IS NULL THEN
    RETURN QUERY SELECT false, 'installation_unavailable', NULL::integer, NULL::integer;
    RETURN;
  END IF;

  -- The insert is the concurrency gate. The three unique constraints cover
  -- account, app installation, and network address respectively.
  BEGIN
    INSERT INTO public.welcome_bonus_claims (user_id, installation_id, ip_address)
    VALUES (p_user_id, v_installation, left(p_ip_address, 64));
  EXCEPTION WHEN unique_violation THEN
    RETURN QUERY SELECT false, 'already_claimed', NULL::integer, NULL::integer;
    RETURN;
  END;

  INSERT INTO public.subscriptions
    (user_id, coins_balance, provider, status, tier, free_spins_remaining,
     free_spins_guarantee_pending, free_spins_batch_payout)
  VALUES (p_user_id, 50, 'none', 'coins_only', 'basic', 15, true, 0)
  ON CONFLICT (user_id) DO UPDATE SET
    coins_balance = COALESCE(public.subscriptions.coins_balance, 0) + 50,
    free_spins_remaining = public.subscriptions.free_spins_remaining + 15,
    free_spins_guarantee_pending = true,
    free_spins_batch_payout = 0
  RETURNING coins_balance, free_spins_remaining INTO v_balance, v_spins;

  INSERT INTO public.coin_transactions
    (user_id, amount, direction, feature, description, balance_after, ip_address)
  VALUES
    (p_user_id, 50, 'credit', 'welcome_bonus',
     'Welcome bonus: +50 EZ Coins', v_balance, left(p_ip_address, 64));

  INSERT INTO public.ez_usage_log
    (user_id, user_email, ip_address, feature, model, prompt, coins_charged,
     quantity, running_balance, api_cost_usd, status)
  SELECT p_user_id, email, left(p_ip_address, 64), 'welcome_free_spins',
         'Brainrot Slots', 'Welcome bonus: +15 free spins', 0, 15, v_balance,
         0, 'complete'
  FROM auth.users WHERE id = p_user_id;

  RETURN QUERY SELECT true, 'granted', v_balance, v_spins;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_welcome_bonus(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_welcome_bonus(uuid, text) TO service_role;

-- Keep the existing auth triggers in place but turn their old grant body into
-- a no-op. The authenticated IP-aware claim above is now the only grant path.
CREATE OR REPLACE FUNCTION public.handle_new_user_welcome_coins()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  RETURN NEW;
END;
$$;
