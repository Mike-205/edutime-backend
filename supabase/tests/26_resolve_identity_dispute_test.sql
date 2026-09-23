-- ============================================================================
-- 26: resolve_identity_dispute (0052)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5 step 4's escalation ("routes to the faculty rep")
-- had no landing pad until this function: a faculty rep, having investigated
-- out-of-band, clears the disputed account's self-typed identity facts so it
-- can redo claim_identity_personal with corrected data and retry
-- link_school_email_identity against the school identity already sitting in
-- auth.identities from the original attempt.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(13);


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
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
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
create function pg_temp.link_identity(p_id uuid, p_email text) returns void
language sql as $$
  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
$$;
create function pg_temp.fst_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;


-- ---------------------------------------------------------------------------
-- §1 The disputed sequence: mistyped Flow 1 claim, escalated link, resolved,
-- retried successfully.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  'aaaaaaaa-1111-4000-8000-000000000001', 'disputed1@gmail.com'
);
select pg_temp.act_as('aaaaaaaa-1111-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '90104', 2026, %L) $$,
         pg_temp.programme('EB1'), 'aaaaaaaa-1111-4000-8000-000000000001'::uuid),
  'a Flow 1 claim, deliberately wrong -- the real number is 90103'
);

-- Simulates the account having already been let into a cohort it may
-- legitimately belong to (e.g. via a join request) before the dispute --
-- the case resolve_identity_dispute's design note is about: this is not an
-- eviction, so cohort_id must survive the dispute untouched.
update users set cohort_id = pg_temp.cohort('EB1', 2023)
where id = 'aaaaaaaa-1111-4000-8000-000000000001';

select pg_temp.link_identity(
  'aaaaaaaa-1111-4000-8000-000000000001', 'eb1.90103.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('aaaaaaaa-1111-4000-8000-000000000001'::uuid) $$,
  'P0001',
  null,
  'the mismatch escalates -- nobody holds 90103, so this is not a takeover'
);
select is(
  (select claim_method::text from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  'provisional',
  '...the account is still stuck as provisional after the escalation'
);

select pg_temp.act_as(pg_temp.fst_rep());
select lives_ok(
  format($$ select resolve_identity_dispute(%L::uuid, %L::uuid) $$,
         'aaaaaaaa-1111-4000-8000-000000000001', pg_temp.fst_rep()),
  'a faculty rep resolves the dispute'
);
select is(
  (select claim_method from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  null,
  '...claim_method is cleared, dropping the account out of provisional'
);
select is(
  (select student_number from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  null,
  '...the wrong self-typed student_number is cleared too'
);
select is(
  (select cohort_id from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  pg_temp.cohort('EB1', 2023),
  '...cohort_id is deliberately left untouched -- this is not an eviction'
);
select is(
  (select action::text from identity_audit_log
   where target_user = 'aaaaaaaa-1111-4000-8000-000000000001' and action = 'dispute_resolved'
   order by created_at desc limit 1),
  'dispute_resolved',
  '...an audit row records the resolution'
);

select pg_temp.act_as('aaaaaaaa-1111-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '90103', 2026, %L) $$,
         pg_temp.programme('EB1'), 'aaaaaaaa-1111-4000-8000-000000000001'::uuid),
  'the student redoes the Flow 1 claim, this time with the correct number'
);
select lives_ok(
  $$ select link_school_email_identity('aaaaaaaa-1111-4000-8000-000000000001'::uuid) $$,
  'the retry succeeds -- the school identity linked before the dispute is still there'
);
select is(
  (select claim_method::text from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  'oauth',
  '...and the account is fully upgraded this time'
);


-- ---------------------------------------------------------------------------
-- §2 Guards
-- ---------------------------------------------------------------------------
select pg_temp.act_as('aaaaaaaa-1111-4000-8000-000000000001');
select throws_ok(
  format($$ select resolve_identity_dispute(%L::uuid, %L::uuid) $$,
         'aaaaaaaa-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-000000000001'),
  'P0001',
  'Only a faculty_rep may resolve an identity dispute',
  'a non-faculty-rep cannot resolve a dispute'
);

-- §1's account (…0001) reached claim_method = 'oauth' by the end of its
-- sequence -- reused here rather than building a dedicated fixture.
select pg_temp.act_as(pg_temp.fst_rep());
select throws_ok(
  format($$ select resolve_identity_dispute(%L::uuid, %L::uuid) $$,
         'aaaaaaaa-1111-4000-8000-000000000001', pg_temp.fst_rep()),
  'P0001',
  'User aaaaaaaa-1111-4000-8000-000000000001 is already oauth-verified — this function is for resolving a disputed provisional claim, not for clearing a proven identity',
  'a faculty rep cannot resolve a dispute on an already oauth-verified account'
);

select * from finish();
rollback;
