-- campaign_segments.sql
-- Run these SELECTs individually in the SQL Editor to preview each segment
-- before any automated sending exists. Nothing here sends anything or
-- modifies data -- it's just the audience definitions.
--
-- All three respect marketing_opt_in, so nobody who unchecked/unsubscribed
-- shows up here regardless of behavior.

-- ── Segment A: Signed up, never came back ──────────────────────────────────
-- Confirmed their email (so they're a real account), but last_sign_in_at
-- hasn't moved since -- meaning the only session they ever had was the one
-- created at signup itself. Gives it 14 days before considering someone
-- "gone" rather than just mid-onboarding.

SELECT u.id, u.email, u.created_at
FROM auth.users u
JOIN public.subscriptions s ON s.user_id = u.id
WHERE u.email_confirmed_at IS NOT NULL
  AND u.created_at < now() - interval '14 days'
  AND (u.last_sign_in_at IS NULL OR u.last_sign_in_at <= u.email_confirmed_at + interval '5 minutes')
  AND s.marketing_opt_in = true;

-- ── Segment B: Collected free coins, never spent one ───────────────────────
-- Has at least one credit (welcome bonus, daily free coins, etc.) but zero
-- debit transactions ever. NOTE: "logged in multiple times" can't be
-- verified precisely yet -- auth.users only stores last_sign_in_at (a single
-- timestamp), not a count. The condition below approximates repeat visits as
-- "last sign-in is well after account creation," which is directional but
-- not exact. See the note below the queries if you want real login counts.

SELECT u.id, u.email, u.last_sign_in_at
FROM auth.users u
JOIN public.subscriptions s ON s.user_id = u.id
WHERE s.marketing_opt_in = true
  AND u.last_sign_in_at > u.created_at + interval '3 days'  -- approximate "came back"
  AND EXISTS (
    SELECT 1 FROM public.coin_transactions ct
    WHERE ct.user_id = u.id AND ct.direction = 'credit'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.coin_transactions ct
    WHERE ct.user_id = u.id AND ct.direction = 'debit'
  );

-- ── Segment C: Was active, then went quiet — win-back ───────────────────────
-- Had real engagement before (several coin_transactions rows, meaning they
-- were actually using features, not just collecting free coins), but
-- nothing in the last 21 days.

SELECT u.id, u.email, u.last_sign_in_at, MAX(ct.created_at) AS last_activity
FROM auth.users u
JOIN public.subscriptions s ON s.user_id = u.id
JOIN public.coin_transactions ct ON ct.user_id = u.id
WHERE s.marketing_opt_in = true
GROUP BY u.id, u.email, u.last_sign_in_at
HAVING COUNT(ct.id) >= 5                               -- had real engagement
   AND MAX(ct.created_at) < now() - interval '21 days'  -- but gone quiet
ORDER BY last_activity DESC;

-- ── On login-count precision ────────────────────────────────────────────────
-- If Segment B's approximation isn't good enough (e.g. you want "logged in
-- 3+ times" exactly, not just "came back once a few days later"), that needs
-- a small login-event log that doesn't exist yet -- a table with one row per
-- sign-in, populated either by a DB trigger on auth.users' last_sign_in_at
-- changing, or by the client calling a tiny Edge Function after each
-- successful signInWithEmail:. Say the word and I'll build whichever fits
-- better.
