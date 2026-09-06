-- ============================================================================
-- 12: Recovery email — set, verify, and request a reset
-- ============================================================================
-- 0031, implementing TODO §0.3 / §R.5. Three functions:
--
--   set_recovery_email         self-service, issues a 6-digit setup code
--   verify_recovery_email      self-service, confirms the code
--   request_password_recovery  unauthenticated entry point, service_role only
--
-- People used here (all password-branch unless noted):
--   ...014 Kevin Kariuki    EB1/67358/23  claimed, provisional  — runs the
--                           full set -> fail -> succeed OTP story below.
--   ...015 Aisha Hassan     EB1/67401/23  claimed, OAUTH — public.users.email
--                           is set, so she has no password to recover.
--   ...021 Dennis Kiprono   EB1/71004/24  claimed, provisional, no recovery
--                           email on file at all — the "nothing to send" case.
--   ...054 Ian Maina        EB3/72010/26  no roster row in this seed at all —
--                           used below by reg number only, for the "no such
--                           registration number" case.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(21);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.kevin()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000014'::uuid $$;
create function pg_temp.aisha()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000015'::uuid $$;

create function pg_temp.otp_of(p_user uuid) returns text language sql stable as $$
  select otp_code from user_recovery_email where user_id = p_user;
$$;
create function pg_temp.attempts_of(p_user uuid) returns int language sql stable as $$
  select otp_attempts from user_recovery_email where user_id = p_user;
$$;
create function pg_temp.verified_of(p_user uuid) returns timestamptz language sql stable as $$
  select verified_at from user_recovery_email where user_id = p_user;
$$;


-- ============================================================================
-- §1 set_recovery_email
-- ============================================================================
select pg_temp.act_as(pg_temp.kevin());

select throws_ok(
  format($$ select set_recovery_email('kevin.personal@example.com', %L::uuid) $$,
         pg_temp.aisha()),
  'P0001',
  'p_acting_user must match the calling user',
  'a student cannot set a recovery email for someone else'
);

select throws_ok(
  format($$ select set_recovery_email('not-an-email', %L::uuid) $$, pg_temp.kevin()),
  'P0001',
  'That does not look like a valid email address',
  'a malformed address is refused'
);

select lives_ok(
  format($$ select set_recovery_email('kevin.personal@example.com', %L::uuid) $$,
         pg_temp.kevin()),
  'a student sets their own recovery email'
);

select matches(
  pg_temp.otp_of(pg_temp.kevin()), '^[0-9]{6}$',
  'the stored setup code is six digits'
);

select is(
  pg_temp.attempts_of(pg_temp.kevin()), 0,
  'a fresh code starts with zero attempts'
);

select ok(
  pg_temp.verified_of(pg_temp.kevin()) is null,
  'a fresh address is unverified'
);

select throws_ok(
  format($$ select set_recovery_email('kevin.other@example.com', %L::uuid) $$,
         pg_temp.kevin()),
  'P0001',
  'Please wait a minute before requesting another code',
  'resending a code inside the cooldown is refused'
);


-- ============================================================================
-- §2 verify_recovery_email
-- ============================================================================
select is(
  (select verify_recovery_email('000000', pg_temp.kevin())),
  false,
  'a wrong code is refused, not raised as an error'
);

select is(
  pg_temp.attempts_of(pg_temp.kevin()), 1,
  'the wrong attempt is recorded'
);

select throws_ok(
  format($$ select verify_recovery_email(%L, %L::uuid) $$,
         pg_temp.otp_of(pg_temp.kevin()), pg_temp.aisha()),
  'P0001',
  'p_acting_user must match the calling user',
  'a student cannot verify someone else''s code'
);

-- Exhaust the attempt budget, then prove even the CORRECT code is refused —
-- the cap is a hard stop, not a hint.
update user_recovery_email set otp_attempts = 5 where user_id = pg_temp.kevin();

select throws_ok(
  format($$ select verify_recovery_email(%L, %L::uuid) $$,
         pg_temp.otp_of(pg_temp.kevin()), pg_temp.kevin()),
  'P0001',
  'Too many attempts — request a new code',
  'five failed attempts locks out even the right code'
);

-- A fresh code, written directly rather than through set_recovery_email —
-- this whole test runs inside one transaction, so `now()` is frozen at the
-- transaction's start and the cooldown from §1 would otherwise still be
-- "in effect". Resets the attempt budget and clears the lockout.
update user_recovery_email
  set otp_code = '482913', otp_attempts = 0, otp_expires_at = now() + interval '15 minutes'
  where user_id = pg_temp.kevin();

select is(
  (select verify_recovery_email('482913', pg_temp.kevin())),
  true,
  'the correct code verifies successfully'
);

select ok(
  pg_temp.verified_of(pg_temp.kevin()) is not null,
  'verification is recorded'
);

select ok(
  pg_temp.otp_of(pg_temp.kevin()) is null,
  'the spent code is cleared'
);

-- An expired code fails with the SAME message as a wrong one — no oracle
-- distinguishing "too late" from "just wrong".
select pg_temp.act_as(pg_temp.aisha());
select set_recovery_email('aisha.personal@example.com', pg_temp.aisha());
update user_recovery_email
  set otp_expires_at = now() - interval '1 minute'
  where user_id = pg_temp.aisha();

select is(
  (select verify_recovery_email(pg_temp.otp_of(pg_temp.aisha()), pg_temp.aisha())),
  false,
  'an expired code is refused identically to a wrong one'
);

-- Force it verified for the OAuth-gate test in §3 below — bypassing the OTP
-- flow deliberately, since what §3 tests is the gate, not this path again.
update user_recovery_email
  set verified_at = now(), otp_code = null, otp_expires_at = null
  where user_id = pg_temp.aisha();


-- ============================================================================
-- §3 request_password_recovery
-- ============================================================================
-- The single most important property: nobody signed-in-as-a-student can call
-- this directly. It resolves an arbitrary registration number to an account
-- on no proof at all beyond the number itself.
set local role authenticated;
select throws_ok(
  $$ select request_password_recovery('EB1/67358/23') $$,
  '42501',
  'permission denied for function request_password_recovery',
  'an authenticated student cannot call the recovery lookup directly'
);
reset role;

set local role service_role;

select is(
  (select should_send from jsonb_to_record(request_password_recovery('EB3/72010/26'))
     as x(should_send boolean)),
  false,
  'an unknown registration number sends nothing'
);

select is(
  (select should_send from jsonb_to_record(request_password_recovery('EB1/71004/24'))
     as x(should_send boolean)),
  false,
  'a claimed account with no recovery email on file sends nothing'
);

select is(
  (select should_send from jsonb_to_record(request_password_recovery('EB1/67401/23'))
     as x(should_send boolean)),
  false,
  'an OAuth-linked account has no password to recover'
);

select is(
  (request_password_recovery('EB1/67358/23')),
  jsonb_build_object(
    'should_send', true,
    'auth_email', 'eb1.67358.23@auth.internal',
    'recovery_email', 'kevin.personal@example.com'
  ),
  'a verified password-branch account gets the synthetic address and the recovery address'
);

select is(
  (select should_send from jsonb_to_record(request_password_recovery('EB1/67358/23'))
     as x(should_send boolean)),
  false,
  'a second request inside the cooldown sends nothing'
);

reset role;

select * from finish();
rollback;
