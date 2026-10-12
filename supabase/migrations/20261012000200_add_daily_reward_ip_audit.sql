-- Daily-reward credits are represented by coin_transactions rather than an
-- API usage row. Store the request IP on that ledger source so the admin
-- ledger can surface accounts repeatedly claiming from the same network.
--
-- This deliberately records only future claims: a historical transaction
-- cannot be assigned an IP reliably after the request has completed.

ALTER TABLE public.coin_transactions
  ADD COLUMN IF NOT EXISTS ip_address text;

CREATE INDEX IF NOT EXISTS coin_transactions_daily_reward_ip_created_at_idx
  ON public.coin_transactions (ip_address, created_at DESC)
  WHERE feature = 'daily_reward' AND ip_address IS NOT NULL;
