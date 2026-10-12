-- Durable entitlement for accounts that have completed at least one paid
-- EZComplete purchase. It is deliberately never reset on cancellation/expiry.
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS has_ever_purchased boolean NOT NULL DEFAULT false;

-- Preserve access for historical purchasers, including cancelled or expired
-- subscriptions and one-time coin top-ups recorded before this column existed.
UPDATE public.subscriptions AS s
SET has_ever_purchased = true
WHERE NOT s.has_ever_purchased
  AND (
    s.status = 'active'
    OR EXISTS (
      SELECT 1
      FROM public.coin_transactions AS ct
      WHERE ct.user_id = s.user_id
        AND ct.direction = 'credit'
        AND ct.feature IN ('topup', 'topup_bonus', 'subscription_renewal', 'subscription_bonus')
    )
  );
