-- Restore the welcome free-spin grant for both Supabase signup modes:
--
-- * Email confirmation enabled: auth.users is updated when the email is
--   confirmed.
-- * Email confirmation disabled: the new auth.users row is already
--   confirmed, so no later UPDATE occurs.
--
-- The prior free-spin migration replaced the function body but did not create
-- the trigger.  It also only handled the latter event, so neither path was
-- reliably covered on a fresh deployment.

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS free_spins_remaining integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS free_spins_guarantee_pending boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS free_spins_batch_payout integer NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.br_welcome_installations (
  installation_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  claimed_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.br_welcome_installations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.br_welcome_installations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.br_welcome_installations TO service_role;

-- claim-daily-coins uses this RPC for the four-hour spins outcome. Keep it in
-- this repair migration so the endpoint never depends on a separately applied
-- free-spin migration.
CREATE OR REPLACE FUNCTION public.grant_free_spins(p_user_id uuid, p_spins integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_remaining integer;
  v_email text;
BEGIN
  IF p_spins < 1 OR p_spins > 100 THEN
    RAISE EXCEPTION 'Invalid free spin amount';
  END IF;

  INSERT INTO public.subscriptions
    (user_id, coins_balance, provider, status, tier,
     free_spins_remaining, free_spins_guarantee_pending,
     free_spins_batch_payout)
  VALUES (p_user_id, 0, 'none', 'coins_only', 'basic', p_spins, false, 0)
  ON CONFLICT (user_id) DO UPDATE SET
    free_spins_remaining = public.subscriptions.free_spins_remaining + p_spins
  RETURNING free_spins_remaining INTO v_remaining;

  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  INSERT INTO public.ez_usage_log
    (user_id, user_email, feature, model, prompt, coins_charged, quantity,
     running_balance, api_cost_usd, status)
  SELECT p_user_id, v_email, 'daily_free_spins', 'Brainrot Slots',
         format('4-hour reward: +%s free spins', p_spins), 0, p_spins,
         coins_balance, 0, 'complete'
  FROM public.subscriptions WHERE user_id = p_user_id;

  RETURN v_remaining;
END;
$$;

REVOKE ALL ON FUNCTION public.grant_free_spins(uuid, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_free_spins(uuid, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.handle_new_user_welcome_coins()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_installation uuid;
  v_email text;
BEGIN
  -- On INSERT, only grant when Supabase has already confirmed the account.
  -- On UPDATE, only grant at the one confirmation transition.
  IF TG_OP = 'INSERT' THEN
    IF NEW.email_confirmed_at IS NULL THEN RETURN NEW; END IF;
  ELSIF NEW.email_confirmed_at IS NULL OR OLD.email_confirmed_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- A Keychain-backed UUID is supplied by EZAuthManager at signup.  The
  -- installation table makes this a one-time grant per app installation.
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
  VALUES (NEW.id, 0, 'none', 'coins_only', 'basic', 15, true, 0)
  ON CONFLICT (user_id) DO UPDATE SET
    free_spins_remaining = public.subscriptions.free_spins_remaining + 15,
    free_spins_guarantee_pending = true,
    free_spins_batch_payout = 0;

  SELECT email INTO v_email FROM auth.users WHERE id = NEW.id;
  INSERT INTO public.ez_usage_log
    (user_id, user_email, feature, model, prompt, coins_charged, quantity,
     running_balance, api_cost_usd, status)
  SELECT NEW.id, v_email, 'welcome_free_spins', 'Brainrot Slots',
         'Welcome bonus: +15 free spins', 0, 15, coins_balance, 0, 'complete'
  FROM public.subscriptions WHERE user_id = NEW.id;

  RETURN NEW;
END;
$$;

-- This is the name used by the former confirmation-only setup. Remove it only
-- when it still calls this welcome-bonus function; abort instead of silently
-- removing an unrelated auth trigger that happens to use the same name.
DO $$
DECLARE
  v_trigger_function text;
BEGIN
  SELECT p.proname INTO v_trigger_function
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE t.tgrelid = 'auth.users'::regclass
    AND t.tgname = 'on_auth_user_email_confirmed'
    AND NOT t.tgisinternal;

  IF v_trigger_function IS NOT NULL AND v_trigger_function <> 'handle_new_user_welcome_coins' THEN
    RAISE EXCEPTION
      'Refusing to replace auth.users trigger on_auth_user_email_confirmed because it calls %',
      v_trigger_function;
  END IF;

  IF v_trigger_function IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER on_auth_user_email_confirmed ON auth.users';
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_welcome_bonus_insert ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_welcome_bonus_confirmed ON auth.users;

CREATE TRIGGER on_auth_user_welcome_bonus_insert
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user_welcome_coins();

CREATE TRIGGER on_auth_user_welcome_bonus_confirmed
  AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user_welcome_coins();
