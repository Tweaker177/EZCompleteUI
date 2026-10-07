-- Server-owned record of every paid slot win. It is populated from the same
-- coin ledger transaction that credits the prize, so neither client can
-- fabricate leaderboard entries or change a total after the fact.
CREATE TABLE IF NOT EXISTS public.br_slot_winnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_type text NOT NULL CHECK (game_type IN ('brainrot_slots', 'brainrot_penny_slots')),
  payout integer NOT NULL CHECK (payout > 0),
  won_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS br_slot_winnings_daily_idx ON public.br_slot_winnings (won_at DESC, user_id);
CREATE INDEX IF NOT EXISTS br_slot_winnings_big_hit_idx ON public.br_slot_winnings (payout DESC, won_at DESC);
ALTER TABLE public.br_slot_winnings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.br_slot_winnings FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.br_slot_winnings TO service_role;

CREATE OR REPLACE FUNCTION public.capture_br_slot_winning()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.direction = 'credit' AND NEW.feature IN ('brainrot_slots', 'brainrot_penny_slots')
     AND NEW.amount > 0 THEN
    INSERT INTO public.br_slot_winnings (user_id, game_type, payout, won_at)
    VALUES (NEW.user_id, NEW.feature, NEW.amount, COALESCE(NEW.created_at, now()));
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS capture_br_slot_winning_on_credit ON public.coin_transactions;
CREATE TRIGGER capture_br_slot_winning_on_credit
AFTER INSERT ON public.coin_transactions
FOR EACH ROW EXECUTE FUNCTION public.capture_br_slot_winning();

-- Include previously settled slot credits exactly once, so the first board is
-- meaningful immediately after rollout. The trigger handles every new one.
INSERT INTO public.br_slot_winnings (user_id, game_type, payout, won_at)
SELECT ct.user_id, ct.feature, ct.amount, COALESCE(ct.created_at, now())
FROM public.coin_transactions ct
JOIN auth.users u ON u.id = ct.user_id
WHERE direction = 'credit'
  AND feature IN ('brainrot_slots', 'brainrot_penny_slots')
  AND amount > 0;

CREATE OR REPLACE FUNCTION public.get_br_slot_winnings_leaderboard(
  p_user_id uuid,
  p_limit integer DEFAULT 10
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH limits AS (SELECT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 25) AS n),
  day_start AS (SELECT date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS value),
  daily AS (
    SELECT w.user_id, SUM(w.payout)::integer AS total
    FROM br_slot_winnings w, day_start d
    WHERE w.won_at >= d.value GROUP BY w.user_id
  ),
  names AS (
    SELECT u.id AS user_id,
      COALESCE(NULLIF(p.display_name, ''), 'Player ' || right(replace(u.id::text, '-', ''), 4)) AS display_name
    FROM auth.users u LEFT JOIN br_player_profiles p ON p.user_id = u.id
  ),
  daily_rows AS (
    SELECT n.display_name, d.total
    FROM daily d JOIN names n ON n.user_id = d.user_id
    ORDER BY d.total DESC, n.display_name ASC LIMIT (SELECT n FROM limits)
  ),
  hit_rows AS (
    SELECT n.display_name, w.payout, w.won_at
    FROM br_slot_winnings w JOIN names n ON n.user_id = w.user_id
    ORDER BY w.payout DESC, w.won_at ASC LIMIT (SELECT n FROM limits)
  )
  SELECT jsonb_build_object(
    'day_start_utc', (SELECT value FROM day_start),
    'my_today_total', COALESCE((SELECT total FROM daily WHERE user_id = p_user_id), 0),
    'my_best_hit', COALESCE((SELECT MAX(payout) FROM br_slot_winnings WHERE user_id = p_user_id), 0),
    'daily_winnings', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', display_name, 'total', total)) FROM daily_rows), '[]'::jsonb),
    'biggest_hits', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', display_name, 'payout', payout, 'won_at', won_at)) FROM hit_rows), '[]'::jsonb)
  );
$$;
REVOKE ALL ON FUNCTION public.get_br_slot_winnings_leaderboard(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_br_slot_winnings_leaderboard(uuid, integer) TO service_role;
