-- 20261012000100_add_music_generation.sql
-- EZCompleteUI — ElevenLabs text-to-music backend
--
-- Purpose:
--   Server-side storage and coin accounting for the ez-music Edge Function.
--   Nothing in this file is readable or writable by the app directly: every
--   table has RLS enabled with no policies, the bucket is private, and each
--   RPC is executable by service_role only.  The Edge Function is the single
--   place that decides prices, so a modified client cannot change a charge.
--
-- Billing model (see ez-music/index.ts for the pricing math):
--   1. reserve_music_generation  debits the full price up front, atomically,
--      and creates one music_entries row + one music_generation_attempts row
--      per requested variant.  Replaying the same generation_id never charges
--      twice, so an app retry after a dropped connection is safe.
--   2. finalize_music_attempt    settles a variant exactly once.  A usable
--      file keeps the charge (or a reduced charge if the track came back
--      noticeably shorter than requested); anything else refunds the
--      reservation.  It is idempotent, so concurrent or repeated calls
--      cannot double-refund.
--   3. reap_stale_music_attempts refunds reservations whose background job
--      died (function timeout, crash) so coins are never stuck.
--
-- Prices and limits live in music_config so they can be tuned with a plain
-- UPDATE instead of an app release.

-- ── Configuration ────────────────────────────────────────────────────────────

create table if not exists public.music_config (
  key text primary key,
  value_numeric numeric not null check (value_numeric >= 0),
  description text,
  updated_at timestamptz not null default now()
);

insert into public.music_config (key, value_numeric, description) values
  ('music_enabled',                    1,    '1 = generation allowed, 0 = kill switch'),
  ('provider_music_rate_usd_per_minute', 0.15, 'ElevenLabs cost per generated minute (recheck before launch)'),
  ('max_song_duration_seconds',        300,  'Longest track a user may request'),
  ('minimum_song_duration_seconds',    10,   'Shortest track a user may request'),
  ('coins_per_minute',                 30,   'User-facing price per generated minute, per variant'),
  ('minimum_generation_charge',        5,    'Smallest coin charge for a single variant'),
  ('variant_count_limit',              3,    'Most variants one request may ask for'),
  ('max_concurrent_generations',       3,    'Most in-flight variants one user may have at once'),
  ('stale_reservation_minutes',        15,   'Age at which an unfinished reservation is refunded'),
  ('provider_deadline_seconds',        140,  'Total time budget for one variant, including retries'),
  ('signed_url_ttl_seconds',           3600, 'Lifetime of playback and download links')
on conflict (key) do nothing;

alter table public.music_config enable row level security;

-- ── Library entries (one row per generated variant) ──────────────────────────

create table if not exists public.music_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  -- Client-chosen id for the whole request; all variants of one request share it.
  generation_id uuid not null,
  title text not null,
  prompt text,
  composition_plan jsonb,
  model_id text not null,
  duration_requested_ms integer not null check (duration_requested_ms > 0),
  duration_actual_ms integer,
  variant_index integer not null check (variant_index >= 0),
  output_format text not null,
  file_path text,
  file_size_bytes bigint,
  elevenlabs_song_id text,
  provider_cost_usd numeric(10, 6),
  coins_reserved integer not null check (coins_reserved >= 0),
  coins_charged integer not null default 0 check (coins_charged >= 0),
  status text not null default 'pending'
    check (status in ('pending', 'complete', 'failed')),
  error_code text,
  error_text text,
  is_downloadable boolean not null default true,
  is_favorite boolean not null default false,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (generation_id, variant_index)
);

create index if not exists music_entries_user_created_idx
  on public.music_entries (user_id, created_at desc);

alter table public.music_entries enable row level security;

-- ── Billing history (survives deletion of the library entry) ─────────────────

create table if not exists public.music_generation_attempts (
  id uuid primary key default gen_random_uuid(),
  music_entry_id uuid references public.music_entries(id) on delete set null,
  user_id uuid not null references auth.users(id) on delete cascade,
  request_payload jsonb,
  model_id text not null,
  requested_duration_ms integer not null,
  provider_request_id text,
  provider_attempts integer not null default 0,
  status text not null default 'reserved'
    check (status in ('reserved', 'complete', 'failed')),
  provider_cost_usd numeric(10, 6),
  coins_reserved integer not null check (coins_reserved >= 0),
  coins_settled integer,
  error_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists music_attempts_user_status_idx
  on public.music_generation_attempts (user_id, status, created_at desc);

alter table public.music_generation_attempts enable row level security;

-- ── Private storage bucket ───────────────────────────────────────────────────
-- No anon/authenticated Storage policies on purpose: the Edge Function uploads
-- with the service role and hands out short-lived signed URLs to the owner.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('music-assets', 'music-assets', false, 26214400, array['audio/mpeg'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- ── RPC: reserve coins and create the pending rows ───────────────────────────

create or replace function public.reserve_music_generation(
  p_user_id uuid,
  p_generation_id uuid,
  p_title text,
  p_prompt text,
  p_composition_plan jsonb,
  p_model_id text,
  p_duration_ms integer,
  p_variant_count integer,
  p_output_format text,
  p_coins_per_variant integer,
  p_max_active integer,
  p_request_payload jsonb
) returns table (
  entry_id uuid,
  attempt_id uuid,
  variant_index integer,
  coins_reserved integer,
  balance_after integer,
  already_existed boolean
)
language plpgsql security definer set search_path = public, auth as $$
declare
  v_balance integer;
  v_total integer;
  v_active integer;
  v_index integer;
  v_entry_id uuid;
  v_attempt_id uuid;
begin
  if p_variant_count < 1 or p_duration_ms < 1 or p_coins_per_variant < 0 then
    raise exception 'invalid_music_request';
  end if;

  -- Locking the balance row serializes every request from one user, which
  -- makes the concurrency check and the debit below race-free.
  select coins_balance into v_balance
  from public.subscriptions where user_id = p_user_id for update;
  if v_balance is null then raise exception 'no_coin_account'; end if;

  -- Replay of an earlier request: hand back the existing rows, charge nothing.
  if exists (select 1 from public.music_entries e where e.generation_id = p_generation_id) then
    if exists (select 1 from public.music_entries e
               where e.generation_id = p_generation_id and e.user_id <> p_user_id) then
      raise exception 'generation_id_conflict';
    end if;
    return query
      select e.id, a.id, e.variant_index, e.coins_reserved, v_balance, true
      from public.music_entries e
      left join public.music_generation_attempts a on a.music_entry_id = e.id
      where e.generation_id = p_generation_id
      order by e.variant_index;
    return;
  end if;

  select count(*) into v_active
  from public.music_generation_attempts a
  where a.user_id = p_user_id and a.status = 'reserved';
  if v_active + p_variant_count > p_max_active then
    raise exception 'too_many_active_generations';
  end if;

  v_total := p_coins_per_variant * p_variant_count;
  if v_balance < v_total then raise exception 'insufficient_coins'; end if;

  v_balance := v_balance - v_total;
  update public.subscriptions set coins_balance = v_balance where user_id = p_user_id;

  if v_total > 0 then
    insert into public.coin_transactions (user_id, amount, direction, feature, description, balance_after)
    values (p_user_id, v_total, 'debit', 'music',
            format('Music generation: %s variant(s), %s s each', p_variant_count, round(p_duration_ms / 1000.0)),
            v_balance);
  end if;

  for v_index in 0 .. p_variant_count - 1 loop
    insert into public.music_entries
      (user_id, generation_id, title, prompt, composition_plan, model_id,
       duration_requested_ms, variant_index, output_format, coins_reserved)
    values
      (p_user_id, p_generation_id, p_title, p_prompt, p_composition_plan, p_model_id,
       p_duration_ms, v_index, p_output_format, p_coins_per_variant)
    returning id into v_entry_id;

    insert into public.music_generation_attempts
      (music_entry_id, user_id, request_payload, model_id, requested_duration_ms, coins_reserved)
    values
      (v_entry_id, p_user_id, p_request_payload, p_model_id, p_duration_ms, p_coins_per_variant)
    returning id into v_attempt_id;

    entry_id := v_entry_id;
    attempt_id := v_attempt_id;
    variant_index := v_index;
    coins_reserved := p_coins_per_variant;
    balance_after := v_balance;
    already_existed := false;
    return next;
  end loop;
end;
$$;

-- ── RPC: settle one variant exactly once ─────────────────────────────────────
-- Returns {"applied": bool, "balance": int}.  applied = false means the
-- attempt was already settled (for example by the stale-reservation reaper);
-- the caller should then discard any file it just uploaded.

create or replace function public.finalize_music_attempt(
  p_attempt_id uuid,
  p_outcome text,
  p_coins_charged integer,
  p_error_code text,
  p_error_text text,
  p_provider_cost_usd numeric,
  p_provider_request_id text,
  p_provider_attempts integer,
  p_duration_actual_ms integer,
  p_file_path text,
  p_file_size_bytes bigint,
  p_song_id text
) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_attempt public.music_generation_attempts%rowtype;
  v_entry public.music_entries%rowtype;
  v_charge integer;
  v_refund integer;
  v_balance integer;
  v_email text;
begin
  if p_outcome not in ('complete', 'failed') then
    raise exception 'invalid_music_outcome';
  end if;

  select * into v_attempt from public.music_generation_attempts
  where id = p_attempt_id for update;
  if not found then raise exception 'music_attempt_not_found'; end if;

  if v_attempt.status <> 'reserved' then
    select coins_balance into v_balance from public.subscriptions where user_id = v_attempt.user_id;
    return jsonb_build_object('applied', false, 'balance', coalesce(v_balance, 0));
  end if;

  v_charge := case
    when p_outcome = 'complete' then greatest(0, least(coalesce(p_coins_charged, v_attempt.coins_reserved), v_attempt.coins_reserved))
    else 0
  end;
  v_refund := v_attempt.coins_reserved - v_charge;

  select coins_balance into v_balance
  from public.subscriptions where user_id = v_attempt.user_id for update;
  v_balance := coalesce(v_balance, 0) + v_refund;
  if v_refund > 0 then
    update public.subscriptions set coins_balance = v_balance where user_id = v_attempt.user_id;
    insert into public.coin_transactions (user_id, amount, direction, feature, description, balance_after)
    values (v_attempt.user_id, v_refund, 'credit', 'music',
            case when p_outcome = 'complete'
                 then 'Music refund: track was shorter than requested'
                 else 'Music refund: generation did not complete' end,
            v_balance);
  end if;

  update public.music_generation_attempts
  set status = p_outcome,
      coins_settled = v_charge,
      provider_cost_usd = p_provider_cost_usd,
      provider_request_id = p_provider_request_id,
      provider_attempts = coalesce(p_provider_attempts, provider_attempts),
      error_code = p_error_code,
      completed_at = now()
  where id = p_attempt_id;

  update public.music_entries
  set status = p_outcome,
      coins_charged = v_charge,
      duration_actual_ms = p_duration_actual_ms,
      file_path = p_file_path,
      file_size_bytes = p_file_size_bytes,
      elevenlabs_song_id = p_song_id,
      provider_cost_usd = p_provider_cost_usd,
      error_code = p_error_code,
      error_text = p_error_text,
      completed_at = now()
  where id = v_attempt.music_entry_id
  returning * into v_entry;

  -- Charged generations appear in the user's usage list like every other feature.
  if p_outcome = 'complete' and v_charge > 0 then
    select email into v_email from auth.users where id = v_attempt.user_id;
    insert into public.ez_usage_log
      (user_id, user_email, feature, model, prompt, coins_charged, quantity,
       running_balance, api_cost_usd, status)
    values
      (v_attempt.user_id, v_email, 'elevenlabs_music', v_attempt.model_id,
       left(coalesce(v_entry.title, v_entry.prompt, 'Music'), 200),
       v_charge, 1, v_balance, coalesce(p_provider_cost_usd, 0), 'complete');
  end if;

  return jsonb_build_object('applied', true, 'balance', v_balance);
end;
$$;

-- ── RPC: refund reservations whose background job never reported back ────────

create or replace function public.reap_stale_music_attempts(
  p_user_id uuid,
  p_older_than_minutes integer
) returns integer
language plpgsql security definer set search_path = public, auth as $$
declare
  v_stale record;
  v_count integer := 0;
begin
  for v_stale in
    select id from public.music_generation_attempts
    where user_id = p_user_id
      and status = 'reserved'
      and created_at < now() - make_interval(mins => p_older_than_minutes)
  loop
    perform public.finalize_music_attempt(
      v_stale.id, 'failed', 0, 'stale_timeout',
      'The generation did not finish in time and was refunded.',
      null, null, null, null, null, null, null);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.reserve_music_generation(uuid, uuid, text, text, jsonb, text, integer, integer, text, integer, integer, jsonb) from public, anon, authenticated;
revoke all on function public.finalize_music_attempt(uuid, text, integer, text, text, numeric, text, integer, integer, text, bigint, text) from public, anon, authenticated;
revoke all on function public.reap_stale_music_attempts(uuid, integer) from public, anon, authenticated;
grant execute on function public.reserve_music_generation(uuid, uuid, text, text, jsonb, text, integer, integer, text, integer, integer, jsonb) to service_role;
grant execute on function public.finalize_music_attempt(uuid, text, integer, text, text, numeric, text, integer, integer, text, bigint, text) to service_role;
grant execute on function public.reap_stale_music_attempts(uuid, integer) to service_role;
