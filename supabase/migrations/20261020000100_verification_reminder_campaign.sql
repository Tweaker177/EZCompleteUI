-- Tracks the one-time (with bounded retry) confirmation reminder campaign.
-- This table deliberately stores no email address: auth.users remains the
-- source of truth for contact data and an account can be deleted cleanly.

CREATE TABLE IF NOT EXISTS public.verification_reminder_deliveries (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'sending'
    CHECK (status IN ('sending', 'sent', 'failed')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_attempt_at timestamptz,
  sent_at timestamptz,
  next_attempt_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.verification_reminder_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.verification_reminder_deliveries FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.verification_reminder_deliveries TO service_role;

-- Preview is separate from claim so a dry run never consumes a recipient.
CREATE OR REPLACE FUNCTION public.preview_pending_verification_reminders(
  p_minimum_age interval,
  p_limit integer
)
RETURNS TABLE (user_id uuid, email text, created_at timestamptz)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT u.id, u.email, u.created_at
  FROM auth.users AS u
  LEFT JOIN public.subscriptions AS s ON s.user_id = u.id
  LEFT JOIN public.verification_reminder_deliveries AS d ON d.user_id = u.id
  WHERE u.email_confirmed_at IS NULL
    AND u.email IS NOT NULL
    AND u.created_at <= now() - p_minimum_age
    -- This reminder has promotional copy, so respect the existing preference.
    AND COALESCE(s.marketing_opt_in, true)
    AND (
      d.user_id IS NULL
      OR (d.status = 'failed' AND d.attempt_count < 3
          AND COALESCE(d.next_attempt_at, '-infinity'::timestamptz) <= now())
      -- A crashed invocation may leave a row sending. Release it after 30 min.
      OR (d.status = 'sending' AND d.last_attempt_at < now() - interval '30 minutes')
    )
  ORDER BY u.created_at ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 500);
$$;

CREATE OR REPLACE FUNCTION public.claim_pending_verification_reminders(
  p_minimum_age interval,
  p_limit integer
)
RETURNS TABLE (user_id uuid, email text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT p.user_id, p.email, p.created_at
    FROM public.preview_pending_verification_reminders(p_minimum_age, p_limit) AS p
  ), claimed AS (
    INSERT INTO public.verification_reminder_deliveries
      (user_id, status, attempt_count, last_attempt_at, next_attempt_at, last_error, updated_at)
    SELECT user_id, 'sending', 1, now(), NULL, NULL, now()
    FROM candidates
    ON CONFLICT (user_id) DO UPDATE SET
      status = 'sending',
      attempt_count = public.verification_reminder_deliveries.attempt_count + 1,
      last_attempt_at = now(),
      next_attempt_at = NULL,
      last_error = NULL,
      updated_at = now()
    -- Recheck eligibility at the conflicting row. Without this, two
    -- simultaneous invocations could both turn a newly-created row into
    -- 'sending' and email the same person.
    WHERE (
      public.verification_reminder_deliveries.status = 'failed'
      AND public.verification_reminder_deliveries.attempt_count < 3
      AND COALESCE(public.verification_reminder_deliveries.next_attempt_at,
                   '-infinity'::timestamptz) <= now()
    ) OR (
      public.verification_reminder_deliveries.status = 'sending'
      AND public.verification_reminder_deliveries.last_attempt_at < now() - interval '30 minutes'
    )
    RETURNING verification_reminder_deliveries.user_id
  )
  SELECT c.user_id, c.email, c.created_at
  FROM candidates AS c
  JOIN claimed AS cl USING (user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_verification_reminder(
  p_user_id uuid,
  p_sent boolean,
  p_error text DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.verification_reminder_deliveries
  SET status = CASE WHEN p_sent THEN 'sent' ELSE 'failed' END,
      sent_at = CASE WHEN p_sent THEN now() ELSE sent_at END,
      next_attempt_at = CASE WHEN p_sent THEN NULL ELSE now() + interval '1 hour' END,
      last_error = CASE WHEN p_sent THEN NULL ELSE left(COALESCE(p_error, 'Unknown email error'), 1000) END,
      updated_at = now()
  WHERE user_id = p_user_id;
$$;

REVOKE ALL ON FUNCTION public.preview_pending_verification_reminders(interval, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_verification_reminders(interval, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finish_verification_reminder(uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_pending_verification_reminders(interval, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_pending_verification_reminders(interval, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_verification_reminder(uuid, boolean, text) TO service_role;
