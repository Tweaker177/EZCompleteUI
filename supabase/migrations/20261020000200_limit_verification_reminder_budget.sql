-- Reserve Resend capacity for password resets, signup links, and other
-- transactional email. Budgets count claimed attempts (not merely completed
-- rows), so concurrent schedulers and accepted-but-not-yet-recorded sends
-- cannot exceed the campaign allocation.

CREATE TABLE IF NOT EXISTS public.verification_reminder_attempts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  claimed_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  sent boolean,
  error text
);

CREATE INDEX IF NOT EXISTS verification_reminder_attempts_claimed_at_idx
  ON public.verification_reminder_attempts (claimed_at);

ALTER TABLE public.verification_reminder_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.verification_reminder_attempts FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.verification_reminder_attempts TO service_role;

DROP FUNCTION IF EXISTS public.claim_pending_verification_reminders(interval, integer);
DROP FUNCTION IF EXISTS public.preview_pending_verification_reminders(interval, integer);
DROP FUNCTION IF EXISTS public.finish_verification_reminder(uuid, boolean, text);

CREATE OR REPLACE FUNCTION public.preview_pending_verification_reminders(
  p_minimum_age interval,
  p_limit integer,
  p_daily_budget integer,
  p_monthly_budget integer
)
RETURNS TABLE (user_id uuid, email text, created_at timestamptz)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  WITH campaign_usage AS (
    SELECT
      count(*) FILTER (
        WHERE claimed_at >= date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      )::integer AS daily_attempts,
      count(*) FILTER (
        WHERE claimed_at >= date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      )::integer AS monthly_attempts
    FROM public.verification_reminder_attempts
  ), capacity AS (
    SELECT LEAST(
      LEAST(GREATEST(p_limit, 1), 500),
      GREATEST(p_daily_budget - daily_attempts, 0),
      GREATEST(p_monthly_budget - monthly_attempts, 0)
    ) AS remaining
    FROM campaign_usage
  )
  SELECT u.id, u.email, u.created_at
  FROM auth.users AS u
  LEFT JOIN public.subscriptions AS s ON s.user_id = u.id
  LEFT JOIN public.verification_reminder_deliveries AS d ON d.user_id = u.id
  WHERE u.email_confirmed_at IS NULL
    AND u.email IS NOT NULL
    AND u.created_at <= now() - p_minimum_age
    AND COALESCE(s.marketing_opt_in, true)
    AND (
      d.user_id IS NULL
      OR (d.status = 'failed' AND d.attempt_count < 3
          AND COALESCE(d.next_attempt_at, '-infinity'::timestamptz) <= now())
      OR (d.status = 'sending' AND d.last_attempt_at < now() - interval '30 minutes')
    )
  ORDER BY u.created_at ASC
  LIMIT (SELECT remaining FROM capacity);
$$;

CREATE OR REPLACE FUNCTION public.claim_pending_verification_reminders(
  p_minimum_age interval,
  p_limit integer,
  p_daily_budget integer,
  p_monthly_budget integer
)
RETURNS TABLE (user_id uuid, email text, created_at timestamptz, attempt_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  -- Serializes only the small database claim, never the outbound email work.
  -- This makes budget enforcement correct even if two schedulers run together.
  PERFORM pg_advisory_xact_lock(hashtext('verification_reminder_campaign_budget'));

  RETURN QUERY
  WITH candidates AS (
    SELECT p.user_id, p.email, p.created_at
    FROM public.preview_pending_verification_reminders(
      p_minimum_age, p_limit, p_daily_budget, p_monthly_budget
    ) AS p
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
  ), attempts AS (
    INSERT INTO public.verification_reminder_attempts (user_id)
    SELECT user_id FROM claimed
    RETURNING id, user_id
  )
  SELECT c.user_id, c.email, c.created_at, a.id
  FROM candidates AS c
  JOIN attempts AS a USING (user_id);
END;
$$;

REVOKE ALL ON FUNCTION public.preview_pending_verification_reminders(interval, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_verification_reminders(interval, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_pending_verification_reminders(interval, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_pending_verification_reminders(interval, integer, integer, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.finish_verification_reminder(
  p_user_id uuid,
  p_attempt_id bigint,
  p_sent boolean,
  p_error text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.verification_reminder_attempts
  SET finished_at = now(),
      sent = p_sent,
      error = CASE WHEN p_sent THEN NULL ELSE left(COALESCE(p_error, 'Unknown email error'), 1000) END
  WHERE id = p_attempt_id AND user_id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Verification reminder attempt does not belong to this user';
  END IF;

  -- A timed-out earlier request must not overwrite a later retry's state.
  UPDATE public.verification_reminder_deliveries AS d
  SET status = CASE WHEN p_sent THEN 'sent' ELSE 'failed' END,
      sent_at = CASE WHEN p_sent THEN now() ELSE d.sent_at END,
      next_attempt_at = CASE WHEN p_sent THEN NULL ELSE now() + interval '1 hour' END,
      last_error = CASE WHEN p_sent THEN NULL ELSE left(COALESCE(p_error, 'Unknown email error'), 1000) END,
      updated_at = now()
  WHERE d.user_id = p_user_id
    AND d.last_attempt_at = (
      SELECT max(a.claimed_at) FROM public.verification_reminder_attempts AS a
      WHERE a.user_id = p_user_id
    );
END;
$$;

REVOKE ALL ON FUNCTION public.finish_verification_reminder(uuid, bigint, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finish_verification_reminder(uuid, bigint, boolean, text) TO service_role;
