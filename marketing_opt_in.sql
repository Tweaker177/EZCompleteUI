-- marketing_opt_in.sql
-- Run this whole file in the Supabase SQL Editor, top to bottom.
--
-- Adds marketing email opt-in tracking, captured at signup regardless of
-- email-confirmation status, plus a token-based unsubscribe mechanism that
-- doesn't require the person to be logged in to use it.
--
-- IMPORTANT: this also fixes the EXISTING handle_new_user_welcome_coins
-- function. Here's why that's necessary, not optional:
--
--   The new opt-in trigger below fires on INSERT into auth.users (signup
--   time) and creates a `subscriptions` row immediately, before the account
--   is even confirmed. Your existing welcome-coins trigger fires later, on
--   UPDATE (when email_confirmed_at gets set), and does:
--     INSERT INTO subscriptions (...) ON CONFLICT (user_id) DO NOTHING
--   Once the opt-in trigger has already created that row, the coins trigger's
--   INSERT hits the conflict and DOES NOTHING -- meaning nobody would ever
--   get their 50 welcome coins again. The fix below changes DO NOTHING to
--   DO UPDATE so it correctly adds coins to whatever row already exists.

-- ── 1. New columns on subscriptions ─────────────────────────────────────────

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS marketing_opt_in   boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS unsubscribe_token  uuid    NOT NULL DEFAULT gen_random_uuid();

-- ── 2. Capture marketing_opt_in at signup ───────────────────────────────────
-- Reads from auth.users.raw_user_meta_data, which is where Supabase stores
-- whatever was passed in signup's "data" field (see EZAuthManager.m's
-- signUpWithEmail:password:marketingOptIn:completion:).

CREATE OR REPLACE FUNCTION public.handle_new_user_marketing_opt_in()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.subscriptions (user_id, marketing_opt_in)
  VALUES (
    NEW.id,
    COALESCE((NEW.raw_user_meta_data->>'marketing_opt_in')::boolean, true)
  )
  ON CONFLICT (user_id) DO UPDATE SET
    marketing_opt_in = EXCLUDED.marketing_opt_in;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_marketing_opt_in ON auth.users;

CREATE TRIGGER on_auth_user_marketing_opt_in
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_marketing_opt_in();

-- ── 3. Fix the existing welcome-coins trigger (see note above) ─────────────
-- Trigger itself (on_auth_user_email_confirmed, AFTER UPDATE) is unchanged --
-- only the function body changes, via CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.handle_new_user_welcome_coins()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.email_confirmed_at IS NOT NULL AND OLD.email_confirmed_at IS NULL THEN

    INSERT INTO public.subscriptions (user_id, coins_balance, provider, status, tier)
    VALUES (NEW.id, 50, 'none', 'coins_only', 'NULL')
    ON CONFLICT (user_id) DO UPDATE SET
      coins_balance = COALESCE(public.subscriptions.coins_balance, 0) + 50,
      provider      = EXCLUDED.provider,
      status        = EXCLUDED.status,
      tier          = EXCLUDED.tier;

    INSERT INTO public.coin_transactions (user_id, amount, direction, feature, description, balance_after)
    SELECT NEW.id, 50, 'credit', 'welcome_bonus', 'Welcome bonus (50 coins)', 50
    WHERE NOT EXISTS (
      SELECT 1 FROM public.coin_transactions
      WHERE user_id = NEW.id AND feature = 'welcome_bonus'
    );

  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. Sanity check ──────────────────────────────────────────────────────
-- Confirm both triggers exist and fire on the events you expect:

select tgname, tgrelid::regclass, pg_get_triggerdef(oid)
from pg_trigger
where tgrelid = 'auth.users'::regclass and not tgisinternal;
