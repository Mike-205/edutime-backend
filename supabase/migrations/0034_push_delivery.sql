-- ============================================================================
-- 0034: Push delivery (FCM) (3.1)
-- ============================================================================
-- Implements TODO §3.1. `notifications` rows have been written correctly
-- since `0012` and nothing has ever dispatched them to a device — the app
-- has had zero push notifications this whole time. This migration adds the
-- device side of that gap; `functions/dispatch-push` (Deno, alongside this
-- migration) adds the FCM side.
--
-- WHY A CRON POLL, NOT A DB WEBHOOK ON INSERT. `0031`'s header rejected
-- `pg_net` for `request_password_recovery` as "new machinery for one call
-- site" — but that call site already had a client-invoked Edge Function in
-- the request path (`functions/recovery-request`) with nowhere else for the
-- HTTP call to live. Nothing invokes an Edge Function when a `notifications`
-- row appears here: inserts happen deep inside `notify_cohort_members`,
-- called from a dozen different mutation functions, so the trigger has to
-- originate in Postgres either way. That makes this a second, structurally
-- different call site, not a reversal of `0031`'s call — and an on-insert
-- webhook has a real cost `0033`'s own accepted-burst case exposes:
-- `notify_cohort_members` inserts one row per matching user, so a combined
-- lecture crossing several of `0033`'s reminder tiers at once can be ~20
-- rows in one transaction, which a webhook turns into ~20 separate Edge
-- Function invocations. A 1-minute poll batches all of them into one.
--
-- SPLIT THE SAME WAY `0033` DID: the claim logic (which notifications are
-- due, mark them attempted) is a plain SQL function, pgTAP-testable exactly
-- like `send_confirmation_nudges()`; the actual FCM call is untestable here
-- (no Flutter client exists yet to hold a real device token) and lives in
-- the Edge Function `dispatch-push` calls out to. `cron.schedule` below is
-- the one-line, untestable trigger connecting them, same as `0033` §3.
--
-- pushed_at ON notifications, NOT A LEDGER TABLE. `0033` needed
-- `confirmation_nudges_sent` because five tiers can each independently fire
-- for the same event — one boolean can't distinguish them. A push is 1:1
-- with the notification row it came from, so a single `pushed_at` column is
-- the whole idempotency mechanism: `claim_pending_pushes()` below stamps it
-- the moment a row is claimed, whether or not the user turns out to have any
-- device registered, so a device-less user's notifications don't get
-- reselected on every run forever (see the function's own comment).
--
-- TOKEN OWNERSHIP, NOT (user_id, token). `token` is the primary key, not a
-- composite with `user_id`, because a token can legitimately belong to a
-- different user than it did yesterday — the same phone resold or handed
-- down logs in as someone else, and FCM hands that install the same
-- registration token it always would. `register_device_token()` deletes any
-- other user's claim on a token before inserting the caller's own, so a
-- stale claim can never survive a real device re-registering. That
-- reassignment crosses a row's ownership, which RLS cannot express, so —
-- same discipline `0006` states for `event_cohorts` et al — device_tokens
-- takes no direct client insert/update/delete privilege at all; every write
-- goes through this one `SECURITY DEFINER` function.
--
-- STALE-TOKEN CLEANUP IS EXACTLY FCM's UNREGISTERED ERROR, PER TODO §3.1 —
-- no general retry/backoff system. That decision lives in
-- `functions/_shared/fcm.ts` and `functions/dispatch-push`, not here: this
-- migration's job is only to hand the Edge Function a batch to send and let
-- it `DELETE FROM device_tokens` (service_role) on that one specific error.
-- ============================================================================


-- ============================================================================
-- 1. device_tokens
-- ============================================================================
create type device_platform as enum ('ios', 'android');

create table device_tokens (
  token         text primary key,
  user_id       uuid not null references users (id) on delete cascade,
  platform      device_platform not null,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);

comment on table device_tokens is
  'One row per FCM registration token (0034, TODO 3.1). token is the primary '
  'key rather than (user_id, token) because a token can be reassigned to a '
  'different user (resold/handed-down device) — register_device_token() is '
  'the only writer and handles that reassignment explicitly.';

create index device_tokens_user_idx on device_tokens (user_id);

alter table device_tokens enable row level security;

create policy device_tokens_read_own
  on device_tokens for select
  using (user_id = auth.uid());

-- Same inherited-default-ACL trap 0014 §4 documents for every table since:
-- TRUNCATE/REFERENCES/TRIGGER land on anon/authenticated whether asked for
-- or not.
revoke all on device_tokens from anon, authenticated;
grant select on device_tokens to authenticated;
grant all    on device_tokens to service_role;


-- ============================================================================
-- 2. register_device_token — the only writer
-- ============================================================================
create function register_device_token(p_token text, p_platform device_platform)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  -- A token handed to a different user (device resold/reissued) must not
  -- keep pushing that user's timetable to whoever holds the phone now.
  delete from device_tokens
  where token = p_token and user_id <> auth.uid();

  insert into device_tokens (token, user_id, platform, last_seen_at)
  values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update
    set platform     = excluded.platform,
        last_seen_at = now();
end;
$$;

comment on function register_device_token(text, device_platform) is
  'Client-facing (0034, TODO 3.1): the mobile app calls this once it has an '
  'FCM registration token. Reassigns the token to the caller if it was '
  'previously claimed by someone else, otherwise upserts last_seen_at.';

revoke execute on function register_device_token(text, device_platform) from public, anon;
grant  execute on function register_device_token(text, device_platform) to authenticated;


-- ============================================================================
-- 3. claim_pending_pushes — batches and stamps, called only by dispatch-push
-- ============================================================================
alter table notifications add column pushed_at timestamptz;

create function claim_pending_pushes(p_limit int default 50)
returns table (
  notification_id uuid,
  token            text,
  platform         device_platform,
  title            text,
  message          text,
  type             notif_type,
  event_id         uuid
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with claimed as (
    select id from notifications
    where pushed_at is null
    order by created_at
    limit p_limit
    for update skip locked
  ),
  -- Stamped for every claimed row, including a user with zero registered
  -- devices — otherwise a device-less user's notifications never leave
  -- pending and get reselected (and re-joined against device_tokens) on
  -- every single run forever. The join below only RETURNS rows that are
  -- actually dispatchable; the stamp above already covers every claimed row
  -- regardless.
  stamped as (
    update notifications n
    set pushed_at = now()
    from claimed c
    where n.id = c.id
    returning n.id, n.user_id, n.title, n.message, n.type, n.event_id
  )
  select s.id, dt.token, dt.platform, s.title, s.message, s.type, s.event_id
  from stamped s
  join device_tokens dt on dt.user_id = s.user_id;
end;
$$;

comment on function claim_pending_pushes(int) is
  'Called only by functions/dispatch-push (0034, TODO 3.1), holding the '
  'service-role key. Atomically claims up to p_limit undelivered '
  'notifications (pushed_at is null), stamps pushed_at on all of them '
  '(FOR UPDATE SKIP LOCKED keeps concurrent invocations from double-claiming '
  'the same row), and returns one row per (notification, device token) pair '
  'for the caller to actually send.';

revoke execute on function claim_pending_pushes(int) from public, anon, authenticated;
grant  execute on function claim_pending_pushes(int) to service_role;


-- ============================================================================
-- 4. invoke_push_dispatch + pg_cron registration
-- ============================================================================
-- Mirrors _shared/axene.ts's swap-for-free discipline at the DB layer: with
-- no push_dispatch_key secret configured yet (fresh local db reset, or a
-- hosted project before the runbook step below is done), this silently
-- no-ops every run instead of hammering net.http_post against a URL/key that
-- doesn't exist. seed.sql seeds both secrets for local dev; a hosted
-- deployment sets them once via vault.create_secret (see TECHNICAL_DISCOVERY
-- §14-style runbook note) pointing at its real functions URL and
-- service_role key — this migration intentionally ships neither value.
create extension if not exists pg_net;
create extension if not exists supabase_vault;

create function invoke_push_dispatch()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_key text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_dispatch_url';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'push_dispatch_key';

  if v_url is null or v_key is null then
    return;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_key,
      'apikey',        v_key
    ),
    body := '{}'::jsonb
  );
end;
$$;

comment on function invoke_push_dispatch() is
  'Called only by pg_cron (0034, every minute) — fires-and-forgets an HTTP '
  'POST at functions/dispatch-push via net.http_post, using the URL/key '
  'pair from Vault (push_dispatch_url / push_dispatch_key). No-ops if either '
  'secret is unset, the same swap-for-free discipline as _shared/axene.ts.';

revoke execute on function invoke_push_dispatch() from public, anon, authenticated;

select cron.schedule(
  'dispatch-push-notifications',
  '* * * * *',
  $$ select invoke_push_dispatch(); $$
);
