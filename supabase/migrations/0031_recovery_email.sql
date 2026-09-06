-- ============================================================================
-- 0031: Recovery email — set, verify, and request a reset (R.5)
-- ============================================================================
-- Implements TODO §0.3 / §R.5. `user_recovery_email` has existed since 0017
-- as bare structure — this is its first writer. Three functions:
--
--   set_recovery_email       self-service, sends a 6-digit setup code
--   verify_recovery_email    self-service, confirms the code
--   request_password_recovery  unauthenticated entry point (service_role only)
--
-- request_password_recovery does NOT call the auth admin API or send mail
-- itself — Postgres has no HTTP client here, and reaching for one (pg_net,
-- an HTTP extension) would be new machinery for one call site. It does the
-- privileged lookup and throttle, then hands the calling Edge Function
-- (functions/recovery-request) everything needed to mint a GoTrue recovery
-- link and deliver it via Axene: the account's synthetic auth.users address,
-- and where to send the link.
--
-- THE SETUP CODE IS A NONCE, NOT A GOTRUE TOKEN. `generateLink({type:
-- 'recovery'})` cannot prove control of `recovery_email` — GoTrue has never
-- heard of that address, since 0.5 requires it never enter auth.users. So
-- setup verification needs its own short-lived, single-use code, generated
-- here and checked here. No homegrown crypto: it's six digits from
-- pgcrypto's CSPRNG (the same extension 0008/0016 already use for join
-- codes), not a signed or hashed token — the threat this defends against is
-- someone guessing a 6-digit number inside a 15-minute window before it
-- expires, not a cryptographic attacker.
-- ============================================================================


-- ============================================================================
-- 1. Columns
-- ============================================================================
-- Plaintext, like the join-code precedent (0008/0016's
-- `encode(gen_random_bytes(6), 'hex')`) — this is a short-lived, single-use,
-- low-value code, not a password. otp_sent_at is its own column rather than
-- derived from otp_expires_at, so the two throttle windows (resend cooldown,
-- code lifetime) stay independently readable and don't have to agree.
alter table user_recovery_email
  add column otp_code             text,
  add column otp_sent_at          timestamptz,
  add column otp_expires_at       timestamptz,
  add column otp_attempts         int not null default 0,
  add column last_recovery_sent_at timestamptz;

comment on column user_recovery_email.otp_code is
  'Pending setup-verification code. Null once verified or expired-and-unused.';
comment on column user_recovery_email.last_recovery_sent_at is
  'Last time a password-recovery link was actually sent for this account — '
  'the per-account throttle request_password_recovery enforces, independent '
  'of the setup-code cooldown above.';


-- ============================================================================
-- 2. set_recovery_email — self-service, sends a setup code
-- ============================================================================
-- Overwrites any existing address (changing an already-verified address with
-- re-auth + notify-the-old-address is deferred — TODO §R.5 — there is no
-- client yet to exercise that flow against). Every call resets verified_at
-- to null: an unconfirmed change must not inherit trust from a previous one.
create or replace function set_recovery_email(
  p_email       text,
  p_acting_user uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sent_at timestamptz;
  v_bytes   bytea;
  v_num     bigint;
  v_otp     text;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  if p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'That does not look like a valid email address';
  end if;

  select otp_sent_at into v_sent_at
  from user_recovery_email
  where user_id = p_acting_user;

  if v_sent_at is not null and v_sent_at > now() - interval '60 seconds' then
    raise exception 'Please wait a minute before requesting another code';
  end if;

  v_bytes := extensions.gen_random_bytes(4);
  v_num := (get_byte(v_bytes, 0)::bigint << 24)
         | (get_byte(v_bytes, 1)::bigint << 16)
         | (get_byte(v_bytes, 2)::bigint << 8)
         |  get_byte(v_bytes, 3)::bigint;
  v_otp := lpad((v_num % 1000000)::text, 6, '0');

  insert into user_recovery_email (
    user_id, email, otp_code, otp_sent_at, otp_expires_at, otp_attempts
  )
  values (
    p_acting_user, p_email, v_otp, now(), now() + interval '15 minutes', 0
  )
  on conflict (user_id) do update
    set email          = excluded.email,
        verified_at    = null,
        otp_code       = excluded.otp_code,
        otp_sent_at    = excluded.otp_sent_at,
        otp_expires_at = excluded.otp_expires_at,
        otp_attempts   = 0,
        updated_at     = now();

  return v_otp;
end;
$$;

comment on function set_recovery_email(text, uuid) is
  'Self-service: stores/overwrites the caller''s recovery address and returns '
  'a fresh 6-digit setup code for the caller (functions/recovery-email-setup) '
  'to email via Axene. Never returns anything for anyone else — the return '
  'value is only safe because p_acting_user must equal auth.uid().';


-- ============================================================================
-- 3. verify_recovery_email — self-service, confirms the code
-- ============================================================================
-- One generic failure message for a wrong code AND an expired one — same
-- discipline 0.5 imposed on signup matching, so neither leaks which is true.
-- Attempts are capped rather than the code being single-guess: a fat-fingered
-- digit shouldn't force a whole new email round-trip.
create or replace function verify_recovery_email(
  p_code        text,
  p_acting_user uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row user_recovery_email;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_row from user_recovery_email where user_id = p_acting_user;

  if v_row.user_id is null or v_row.otp_code is null then
    raise exception 'No pending verification code — request a new one';
  end if;

  if v_row.otp_attempts >= 5 then
    raise exception 'Too many attempts — request a new code';
  end if;

  -- A wrong or expired code is an ORDINARY false, not an exception. Raising
  -- here would abort this whole function call — including the otp_attempts
  -- increment two lines below it, since Postgres rolls back everything since
  -- the start of the failed statement, not just the raise itself. There is
  -- nothing actually exceptional about a mistyped digit; the true exceptions
  -- above (wrong caller, no pending code, attempts exhausted) don't have this
  -- problem because none of them need to persist new state on the way out.
  if v_row.otp_expires_at < now() or v_row.otp_code is distinct from p_code then
    update user_recovery_email
      set otp_attempts = otp_attempts + 1
      where user_id = p_acting_user;
    return false;
  end if;

  update user_recovery_email
    set verified_at    = now(),
        otp_code       = null,
        otp_sent_at    = null,
        otp_expires_at = null,
        otp_attempts   = 0,
        updated_at     = now()
    where user_id = p_acting_user;

  return true;
end;
$$;

comment on function verify_recovery_email(text, uuid) is
  'Self-service: confirms the setup code sent by set_recovery_email. Returns '
  'false for both a wrong code and an expired one — identical outcome, so '
  'neither leaks which is true — and increments the attempt counter. Raises '
  'only for the genuinely exceptional cases: wrong caller, no pending code, '
  'or five failed attempts already spent.';


-- ============================================================================
-- 4. request_password_recovery — unauthenticated entry point
-- ============================================================================
-- Called by functions/recovery-request with the service-role key, before the
-- caller has proven anything — a reg number typed into a "forgot password"
-- screen. So: one generic-shaped response regardless of match, exactly the
-- no-enumeration-oracle discipline 0.5 imposed on signup (TODO §0.5 step 2).
-- The Edge Function returns the same generic message to the client whether
-- should_send comes back true or false; it only actually calls the auth
-- admin API and Axene when it does.
--
-- Gated to accounts with no verified public.users.email — an OAuth account
-- signs in with Google and was never issued a password to forget. This is
-- specifically the reg-number/password branch's recovery path.
--
-- THROTTLED PER ACCOUNT, NOT PER IP. TODO §R.5 doesn't call this out, but an
-- unthrottled version of this lookup is an email-bombing vector aimed at a
-- student's personal mailbox, not this server — an IP throttle wouldn't stop
-- it. Silent no-op on cooldown, not an error: the caller already gets a
-- generic response either way, so there is nothing extra to leak.
create or replace function request_password_recovery(
  p_reg_number text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm       text;
  v_user_id    uuid;
  v_auth_email text;
  v_recovery   user_recovery_email;
begin
  v_norm := normalize_reg_number(p_reg_number);

  select claimed_by into v_user_id
  from student_roster
  where reg_number = v_norm and claimed_by is not null;

  if v_user_id is null then
    return jsonb_build_object('should_send', false);
  end if;

  if exists (
    select 1 from users where id = v_user_id and email is not null
  ) then
    -- OAuth-linked account: no password to recover.
    return jsonb_build_object('should_send', false);
  end if;

  select * into v_recovery from user_recovery_email where user_id = v_user_id;

  if v_recovery.user_id is null or v_recovery.verified_at is null then
    return jsonb_build_object('should_send', false);
  end if;

  if v_recovery.last_recovery_sent_at is not null
     and v_recovery.last_recovery_sent_at > now() - interval '5 minutes' then
    return jsonb_build_object('should_send', false);
  end if;

  select email into v_auth_email from auth.users where id = v_user_id;

  if v_auth_email is null then
    return jsonb_build_object('should_send', false);
  end if;

  update user_recovery_email
    set last_recovery_sent_at = now()
    where user_id = v_user_id;

  return jsonb_build_object(
    'should_send', true,
    'auth_email', v_auth_email,
    'recovery_email', v_recovery.email
  );
end;
$$;

comment on function request_password_recovery(text) is
  'Privileged reg-number -> (synthetic auth email, recovery email) lookup for '
  'the unauthenticated "forgot password" entry point. Per-account throttled. '
  'service_role only — never exposed to anon or authenticated, since it '
  'resolves an arbitrary registration number to an account on no proof at '
  'all beyond the number itself.';


-- ============================================================================
-- 5. Grants
-- ============================================================================
-- REVOKE FROM PUBLIC FIRST — CREATE FUNCTION implicitly grants EXECUTE to
-- PUBLIC (0014 §3).
revoke execute on function set_recovery_email(text, uuid) from public, anon;
grant  execute on function set_recovery_email(text, uuid) to authenticated, service_role;

revoke execute on function verify_recovery_email(text, uuid) from public, anon;
grant  execute on function verify_recovery_email(text, uuid) to authenticated, service_role;

-- Deliberately NOT granted to authenticated — this is the unauthenticated
-- entry point, reachable only through the Edge Function's service-role key.
revoke execute on function request_password_recovery(text) from public, anon, authenticated;
grant  execute on function request_password_recovery(text) to service_role;
