-- Durable, private hand-off for ElevenLabs audio.  The Edge Function writes
-- these rows and the associated Storage objects with the service role, then
-- issues a short-lived signed URL only after confirming the caller owns the
-- request.  Do not add anon/authenticated Storage policies for this bucket.

create table if not exists public.tts_recovery_assets (
  request_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  storage_path text,
  format text not null default 'mp3_44100_128',
  mime_type text not null default 'audio/mpeg',
  model_id text,
  voice_id text,
  char_count integer not null check (char_count >= 0),
  coins_spent integer not null default 0 check (coins_spent >= 0),
  status text not null default 'pending'
    check (status in ('pending', 'complete', 'failed')),
  eleven_request_id text,
  error_text text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists tts_recovery_assets_user_created_idx
  on public.tts_recovery_assets (user_id, created_at desc);

alter table public.tts_recovery_assets enable row level security;

-- This must stay private.  The service-role Edge Function is the sole reader
-- and writer; it scopes every signed URL to the authenticated request owner.
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'tts-assets',
  'tts-assets',
  false,
  26214400,
  array['audio/mpeg', 'audio/wav', 'audio/ogg', 'audio/webm']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
