-- ============================================================================
-- 24: link_school_email_identity (0045)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5: a Flow 1 (provisional) student links a school
-- Google identity to their existing account. Match -> upgrade in place.
-- Mismatch + nobody holds the derived number -> escalate (raise exception,
-- write nothing). Mismatch + another account already holds it -> same
-- takeover shape as Flow 2 (0042): evict unless the holder is already
-- oauth or a class_rep, in which case escalate instead.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(28);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;
create function pg_temp.programme(p_code text) returns uuid language sql stable as $$
  select id from programmes where code = p_code;
$$;

-- A fresh personal-email OAuth signup, with its one starting identity row.
-- auth.identities is never populated by a raw INSERT into auth.users (that's
-- GoTrue's job on a real signup) so this fixture creates it explicitly.
create function pg_temp.new_oauth_signup(p_id uuid, p_email text) returns void
language plpgsql as $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  )
  values (
    '00000000-0000-0000-0000-000000000000',
    p_id, 'authenticated', 'authenticated',
    p_email, 'x', now(), now(),
    jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
    jsonb_build_object('first_name', 'Test', 'last_name', 'Account'),
    now(), now(), '', '', '', ''
  );

  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
end;
$$;

-- Simulates a successful linkIdentity() call: a second auth.identities row
-- for the same user_id, a different address. created_at/updated_at have no
-- column default (confirmed against the running local instance) and
-- link_school_email_identity/link_personal_email_identity order by
-- created_at desc to pick the most-recently-linked candidate -- clock_timestamp()
-- (not now(), which is frozen for the whole transaction these tests run in)
-- is what makes that ordering actually mean something across sequential calls.
create function pg_temp.link_identity(p_id uuid, p_email text) returns void
language sql as $$
  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
$$;


-- ---------------------------------------------------------------------------
-- §1 Match: self-typed Flow 1 identity agrees with what the linked school
-- address derives. Upgrades in place, no rep involved.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000001', 'match.student@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88101', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000001'::uuid),
  'a Flow 1 provisional claim, matching what the school email will later derive'
);

select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000001', 'eb1.88101.26@student.chuka.ac.ke'
);
select lives_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000001'::uuid) $$,
  'linking a school email that matches the stored identity succeeds'
);
select is(
  (select claim_method::text from users where id = '88888888-0000-4000-8000-000000000001'),
  'oauth',
  '...claim_method upgrades to oauth'
);
select is(
  (select school_email from users where id = '88888888-0000-4000-8000-000000000001'),
  'eb1.88101.26@student.chuka.ac.ke',
  '...school_email is recorded'
);
select ok(
  (select school_email_verified_at from users where id = '88888888-0000-4000-8000-000000000001') is not null,
  '...school_email_verified_at is stamped'
);
select is(
  (select action::text from roster_audit_log
   where target_user = '88888888-0000-4000-8000-000000000001' and actor_id = '88888888-0000-4000-8000-000000000001'
   order by created_at desc limit 1),
  'identity_linked',
  '...an identity_linked audit row is written'
);


-- ---------------------------------------------------------------------------
-- §2 Mismatch, nobody holds the derived number: escalate. Nothing is
-- written — not claim_method, not school_email.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000002', 'mismatch.student@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000002');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88102', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000002'::uuid),
  'a Flow 1 provisional claim, deliberately different from the address linked below'
);

select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000002', 'eb1.99999.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000002'::uuid) $$,
  'P0001',
  'The identity derived from this account''s linked school email does not match what was recorded at signup. A faculty rep must resolve this before the school email can be confirmed.',
  'a derived identity that matches nobody escalates rather than auto-correcting'
);
select is(
  (select claim_method::text from users where id = '88888888-0000-4000-8000-000000000002'),
  'provisional',
  '...claim_method is untouched by the escalation'
);
select ok(
  (select school_email from users where id = '88888888-0000-4000-8000-000000000002') is null,
  '...school_email is untouched by the escalation'
);


-- ---------------------------------------------------------------------------
-- §3 Mismatch, and the derived number is already held by another
-- provisional account: same shape as Flow 2's takeover (0042) — the
-- linking account (now proven) wins, the squatter is evicted.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000003', 'squatter3@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000003');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88103', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000003'::uuid),
  'a squatter claims 88103 first'
);

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000004', 'real.owner4@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000004');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88104', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000004'::uuid),
  'the real owner''s own Flow 1 claim is deliberately wrong (88104) -- self-typed data cannot be trusted, that is the whole point of this branch'
);

select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000004', 'eb1.88103.26@student.chuka.ac.ke'
);
select lives_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000004'::uuid) $$,
  'the real owner links the school email deriving 88103 -- already held by the squatter -- and wins'
);
select is(
  (select student_number from users where id = '88888888-0000-4000-8000-000000000004'),
  '88103',
  '...the real owner now holds the derived (not self-typed) student_number'
);
select is(
  (select claim_method::text from users where id = '88888888-0000-4000-8000-000000000003'),
  null,
  '...the squatter is evicted: claim_method reset to null'
);
select is(
  (select student_number from users where id = '88888888-0000-4000-8000-000000000003'),
  null,
  '...the squatter is evicted: student_number reset to null'
);
select is(
  (select action::text from roster_audit_log
   where target_user = '88888888-0000-4000-8000-000000000003' and action = 'takeover'
   order by created_at desc limit 1),
  'takeover',
  '...a takeover audit row is written for the evicted squatter'
);


-- ---------------------------------------------------------------------------
-- §4 Mismatch, and the derived number is already held by an account that
-- is ALREADY oauth: escalate rather than picking a winner between two
-- proven claims -- confirmed unreachable in correct operation, so this is
-- a red flag needing investigation, not a routine outcome.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000010', 'already.oauth10@gmail.com'
);
update users
set programme_id   = pg_temp.programme('EB1'),
    self_sponsored = false,
    student_number = '88110',
    admission_year = 2026,
    claim_method   = 'oauth'
where id = '88888888-0000-4000-8000-000000000010';

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000008', 'linker8@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000008');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88108', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000008'::uuid),
  'a provisional claim, deliberately wrong -- about to link a school email deriving the already-oauth account''s number'
);
select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000008', 'eb1.88110.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000008'::uuid) $$,
  'P0001',
  'Two proven school-email accounts derive the same student number. This cannot happen under correct operation and needs a faculty rep to investigate before either account is touched.',
  'a derived number already held by an oauth account escalates instead of picking a winner'
);


-- ---------------------------------------------------------------------------
-- §5 Mismatch, and the derived number is already held by a class_rep:
-- escalate rather than auto-evicting scheduling authority.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000011', 'rep11@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000011');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88111', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000011'::uuid),
  'a provisional claim for the account that will hold scheduling authority'
);
-- cohort_id is left null, so enforce_max_class_reps_trigger (0003) -- which
-- only fires when NEW.cohort_id is not null -- does not apply here.
update users set role = 'class_rep' where id = '88888888-0000-4000-8000-000000000011';

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000009', 'linker9@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000009');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88109', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000009'::uuid),
  'a provisional claim, deliberately wrong -- about to link a school email deriving the class_rep''s number'
);
select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000009', 'eb1.88111.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000009'::uuid) $$,
  'P0001',
  'That identity is held by an account with scheduling authority. A faculty rep must resolve this.',
  'a derived number already held by a class_rep escalates instead of auto-evicting scheduling authority'
);


-- ---------------------------------------------------------------------------
-- §6 Guards
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000005', 'not.provisional@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000005');
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000005'::uuid) $$,
  'P0001',
  'Only a provisional-claim account can link a school email this way',
  'an account that never made a Flow 1 claim cannot use this path'
);

select pg_temp.act_as('88888888-0000-4000-8000-000000000005');
select throws_ok(
  $$ select link_school_email_identity('99999999-0000-4000-8000-000000000099'::uuid) $$,
  'P0001',
  'p_actor_id must match the calling user',
  'the acting-user parameter must match auth.uid()'
);

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000006', 'no.link.yet@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000006');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88106', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000006'::uuid),
  'a provisional claim with no school identity linked yet'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000006'::uuid) $$,
  'P0001',
  'No linked school-email identity was found for this account',
  'calling this before linkIdentity() has actually succeeded is refused'
);


-- ---------------------------------------------------------------------------
-- §7 A genuine school address that does not shape-check to a registration
-- number (e.g. a staff-style mailbox) cannot be derived from at all.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000007', 'unparseable7@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000007');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88107', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000007'::uuid),
  'a provisional claim, about to link an unparseable school address'
);
select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000007', 'j.doe@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000007'::uuid) $$,
  'P0001',
  'Could not derive a student identity from this school email. A faculty rep must resolve this.',
  'a school address that does not shape-check to a reg number cannot be derived from'
);

select * from finish();
rollback;
