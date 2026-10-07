-- Opt-in social layer for Brainrot Slots. All client traffic is mediated by
-- br-slot-social; direct table access is denied.
CREATE TABLE IF NOT EXISTS public.br_player_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL DEFAULT 'New Player' CHECK (char_length(display_name) BETWEEN 2 AND 28),
  avatar_path text,
  music_enabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.br_slot_room_presence (
  room_id text NOT NULL CHECK (char_length(room_id) BETWEEN 1 AND 100),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, user_id)
);
CREATE INDEX IF NOT EXISTS br_slot_room_presence_active_idx ON public.br_slot_room_presence(room_id, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS public.br_slot_room_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id text NOT NULL CHECK (char_length(room_id) BETWEEN 1 AND 100),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 280),
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);
CREATE INDEX IF NOT EXISTS br_slot_room_messages_room_idx ON public.br_slot_room_messages(room_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.br_slot_room_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES public.br_slot_room_messages(id) ON DELETE CASCADE,
  reporter_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reason text NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 200),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(message_id, reporter_id)
);

ALTER TABLE public.br_player_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.br_slot_room_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.br_slot_room_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.br_slot_room_reports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.br_player_profiles, public.br_slot_room_presence, public.br_slot_room_messages, public.br_slot_room_reports FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.br_player_profiles, public.br_slot_room_presence, public.br_slot_room_messages, public.br_slot_room_reports TO service_role;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('br-slot-avatars', 'br-slot-avatars', false, 3145728, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

-- Welcome/free-spin grants are balance-like events and must be auditable.
-- The deployed grant function may already exist; this replacement retains its
-- semantics and writes a zero-coin audit row for every granted batch.
CREATE OR REPLACE FUNCTION public.grant_free_spins(p_user_id uuid, p_spins integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE v_remaining integer; v_email text;
BEGIN
  IF p_spins < 1 OR p_spins > 100 THEN RAISE EXCEPTION 'Invalid free spin amount'; END IF;
  INSERT INTO public.subscriptions (user_id, free_spins_remaining, free_spins_guarantee_pending, free_spins_batch_payout)
  VALUES (p_user_id, p_spins, false, 0)
  ON CONFLICT (user_id) DO UPDATE SET free_spins_remaining = public.subscriptions.free_spins_remaining + p_spins
  RETURNING free_spins_remaining INTO v_remaining;
  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  INSERT INTO public.ez_usage_log (user_id, user_email, feature, model, prompt, coins_charged, quantity, running_balance, api_cost_usd, status)
  SELECT p_user_id, v_email, 'daily_free_spins', 'Brainrot Slots', format('4-hour reward: +%s free spins', p_spins), 0, p_spins, coins_balance, 0, 'complete'
  FROM public.subscriptions WHERE user_id = p_user_id;
  RETURN v_remaining;
END; $$;
REVOKE ALL ON FUNCTION public.grant_free_spins(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_free_spins(uuid, integer) TO service_role;

-- One welcome batch per Keychain-backed app installation. The identifier is
-- passed in auth.users.raw_user_meta_data.installation_id at signup; it is
-- deliberately never exposed to clients or used for advertising/tracking.
CREATE TABLE IF NOT EXISTS public.br_welcome_installations (
  installation_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  claimed_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.br_welcome_installations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.br_welcome_installations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.br_welcome_installations TO service_role;

CREATE OR REPLACE FUNCTION public.handle_new_user_welcome_coins()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE v_installation uuid; v_email text;
BEGIN
  IF NEW.email_confirmed_at IS NULL OR OLD.email_confirmed_at IS NOT NULL THEN RETURN NEW; END IF;
  BEGIN v_installation := NULLIF(NEW.raw_user_meta_data->>'installation_id', '')::uuid; EXCEPTION WHEN invalid_text_representation THEN v_installation := NULL; END;
  -- No installation marker means no bonus: this fails closed rather than
  -- allowing a modified client to create unlimited confirmed accounts.
  IF v_installation IS NULL THEN RETURN NEW; END IF;
  INSERT INTO public.br_welcome_installations (installation_id, user_id) VALUES (v_installation, NEW.id)
  ON CONFLICT (installation_id) DO NOTHING;
  IF NOT FOUND THEN RETURN NEW; END IF;
  INSERT INTO public.subscriptions (user_id, coins_balance, free_spins_remaining, free_spins_guarantee_pending, free_spins_batch_payout)
  VALUES (NEW.id, 0, 15, true, 0)
  ON CONFLICT (user_id) DO UPDATE SET
    free_spins_remaining = public.subscriptions.free_spins_remaining + 15,
    free_spins_guarantee_pending = true,
    free_spins_batch_payout = 0;
  SELECT email INTO v_email FROM auth.users WHERE id = NEW.id;
  INSERT INTO public.ez_usage_log (user_id, user_email, feature, model, prompt, coins_charged, quantity, running_balance, api_cost_usd, status)
  SELECT NEW.id, v_email, 'welcome_free_spins', 'Brainrot Slots', 'Confirmed-email welcome bonus: +15 free spins', 0, 15, coins_balance, 0, 'complete'
  FROM public.subscriptions WHERE user_id = NEW.id;
  RETURN NEW;
END; $$;
