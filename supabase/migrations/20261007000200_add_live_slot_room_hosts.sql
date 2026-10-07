-- Live, shared AI room hosts. Host turns are stored alongside player messages
-- but have no auth user attached, and are explicitly marked for the client.
ALTER TABLE public.br_slot_room_messages
  ALTER COLUMN user_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS is_house_host boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS host_name text;

ALTER TABLE public.br_slot_room_messages
  DROP CONSTRAINT IF EXISTS br_slot_room_messages_host_identity_check;
ALTER TABLE public.br_slot_room_messages
  ADD CONSTRAINT br_slot_room_messages_host_identity_check CHECK (
    (is_house_host = false AND user_id IS NOT NULL)
    OR (is_house_host = true AND user_id IS NULL AND host_name IS NOT NULL)
  );

CREATE TABLE IF NOT EXISTS public.br_slot_room_host_turns (
  room_id text PRIMARY KEY CHECK (char_length(room_id) BETWEEN 1 AND 100),
  last_spoke_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.br_slot_room_host_turns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.br_slot_room_host_turns FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.br_slot_room_host_turns TO service_role;

-- Atomically admits one host generation per room in a given interval. This
-- keeps many clients polling the same busy room from multiplying model calls.
CREATE OR REPLACE FUNCTION public.claim_br_slot_room_host_turn(
  p_room_id text,
  p_min_interval_seconds integer DEFAULT 180
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_claimed boolean := false;
BEGIN
  IF p_room_id IS NULL OR char_length(p_room_id) NOT BETWEEN 1 AND 100
     OR p_min_interval_seconds NOT BETWEEN 30 AND 3600 THEN
    RAISE EXCEPTION 'Invalid room host turn request';
  END IF;

  INSERT INTO public.br_slot_room_host_turns (room_id, last_spoke_at)
  VALUES (p_room_id, now())
  ON CONFLICT (room_id) DO UPDATE
    SET last_spoke_at = EXCLUDED.last_spoke_at
    WHERE public.br_slot_room_host_turns.last_spoke_at
          <= now() - make_interval(secs => p_min_interval_seconds)
  RETURNING true INTO v_claimed;

  RETURN COALESCE(v_claimed, false);
END;
$$;
REVOKE ALL ON FUNCTION public.claim_br_slot_room_host_turn(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_br_slot_room_host_turn(text, integer) TO service_role;
