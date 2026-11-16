-- GitHub connections for the chat github tool (ez-github / ez-chat).
-- Run once in the Supabase SQL editor.

create table if not exists public.github_connections (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  github_login    text not null,
  token_encrypted text not null,                      -- AES-GCM; key lives in the GITHUB_TOKEN_ENC_KEY secret
  allow_writes    boolean not null default false,     -- server-owned: gates the model's write actions
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

alter table public.github_connections enable row level security;
revoke all on public.github_connections from anon, authenticated;
-- Deliberately no policies: only the edge functions (service role) can touch
-- this table, so the app and other users can never read a stored token.

-- Private bucket for download_archive zips (ez-github keeps one per user and
-- hands the app a short-lived signed URL).
insert into storage.buckets (id, name, public, file_size_limit)
values ('github-archives', 'github-archives', false, 50000000)
on conflict (id) do nothing;
