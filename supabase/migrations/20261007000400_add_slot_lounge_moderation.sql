CREATE TABLE IF NOT EXISTS public.br_slot_room_moderation (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  muted_until timestamptz,
  banned_at timestamptz,
  warning_count integer NOT NULL DEFAULT 0 CHECK (warning_count >= 0),
  last_reason text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.br_slot_room_moderation ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.br_slot_room_moderation FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.br_slot_room_moderation TO service_role;
