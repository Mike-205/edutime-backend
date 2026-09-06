-- ============================================================================
-- 20: claim_identity_personal and the approval programme-match guard (0040)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §3 (Flow 1) end to end: a fresh personal-email OAuth
-- account claims its identity facts immediately, collisions on
-- student_number are caught at that exact moment, an oauth-verified account
-- can never be downgraded by this path, and a class rep's approval refuses a
-- programme mismatch with a readable error before the composite FK would.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(17);


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
-- Plain student, BSC-CS 2023 (programme code 'EB1') — same fixture id
-- 05_roster_test.sql / 17_identity_schema_test.sql / 18 use. programme_id is
-- still null on this fixture (never gone through Flow 1/2) — used for the
-- backward-compat regression check.
create function pg_temp.old_style_student() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;
-- The two seeded class reps needed to exercise approve_cohort_join_request's
-- real (0029) authorization surface — its class-rep-of-this-cohort check
-- means the guard can only be reached by the actual rep of the target
-- cohort, not by an arbitrary caller. Same fixture ids 02_trust_chain_test.sql
-- uses (cs23_rep) plus the seeded BSC-ACS 2023 (EB3) rep.
create function pg_temp.eb1_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;   -- class rep, BSC-CS 2023 (EB1)
create function pg_temp.eb3_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;   -- class rep, BSC-ACS 2023 (EB3)

-- Claimant A: succeeds, later used for the matching-programme approval.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
  'claimant.a@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'A'),
  now(), now(), '', '', '', ''
);
-- Claimant B: attempts, never succeeds (used only for the failure paths).
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
  'claimant.b@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'B'),
  now(), now(), '', '', '', ''
);
-- Claimant C: succeeds with a different student_number, later used for the
-- mismatched-programme approval.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
  'claimant.c@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'C'),
  now(), now(), '', '', '', ''
);
-- Claimant D: already oauth-claimed (simulating a Flow 2 account), used only
-- for the refusal test — force-set directly, bypassing the guard the same
-- way 17/18's own setup does (default test role is not 'authenticated').
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000004', 'authenticated', 'authenticated',
  'claimant.d@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'D'),
  now(), now(), '', '', '', ''
);
update users set claim_method = 'oauth' where id = '55555555-0000-4000-8000-000000000004';


-- ---------------------------------------------------------------------------
-- §1 The claim itself
-- ---------------------------------------------------------------------------
select pg_temp.act_as('55555555-0000-4000-8000-000000000001');

select lives_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0001', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000001'::uuid),
  'a fresh personal-email account can claim an identity'
);

select is(
  (select claim_method::text from users where id = '55555555-0000-4000-8000-000000000001'),
  'provisional', '...and the claim is marked provisional'
);

select is(
  (select student_number from users where id = '55555555-0000-4000-8000-000000000001'),
  'SP0001', '...and the student_number really was written'
);

select lives_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0001', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000001'::uuid),
  'reclaiming the SAME student_number is idempotent, not an error'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP9999', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000001'::uuid),
  'P0001', null,
  'claiming a DIFFERENT student_number on an already-claimed account is refused'
);


-- ---------------------------------------------------------------------------
-- §2 Collisions and validation, via claimant B (never succeeds)
-- ---------------------------------------------------------------------------
select pg_temp.act_as('55555555-0000-4000-8000-000000000002');

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0001', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'a second account cannot claim a student_number another account already holds'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0003', 2024, %L) $$,
         gen_random_uuid(), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'claiming with a programme_id that does not exist is refused'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, '   ', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'a blank/whitespace-only student_number is refused'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0003', 1990, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'an implausible admission_year is refused'
);

-- A non-student account (a seeded class rep) must never be able to claim a
-- student_number — this is the takeover-safety property elsewhere in this
-- codebase: an account holding scheduling authority must never be able to
-- grab an identity that then can't be auto-evicted.
select pg_temp.act_as(pg_temp.eb1_rep());
select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0005', 2024, %L) $$,
         pg_temp.programme('EB1'), pg_temp.eb1_rep()),
  'P0001', null,
  'a non-student account (class rep) cannot claim a personal-email identity'
);


-- ---------------------------------------------------------------------------
-- §3 An oauth-verified account can never be downgraded by this path
-- ---------------------------------------------------------------------------
select pg_temp.act_as('55555555-0000-4000-8000-000000000004');

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0004', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000004'::uuid),
  'P0001', null,
  'a personal-email claim can never overwrite an existing oauth claim'
);


-- ---------------------------------------------------------------------------
-- §3b The reverse of §4's guard: claim first, existing cohort second
-- ---------------------------------------------------------------------------
-- old_style_student() already has a cohort_id (BSC-CS 2023 / EB1, from seed
-- data) but has never called claim_identity_personal — its claim_method and
-- programme_id are still null at this point. Claiming a mismatched programme
-- (EB3) must be refused with a readable message instead of the raw
-- users_cohort_programme_fk violation. NOTE — ordering dependency: this test
-- must run BEFORE §4, which relies on old_style_student() still having
-- programme_id = null; since the function body rolls back entirely on any
-- raised exception, this rejected claim attempt leaves it untouched.
select pg_temp.act_as(pg_temp.old_style_student());
select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0006', 2024, %L) $$,
         pg_temp.programme('EB3'), pg_temp.old_style_student()),
  'P0001', null,
  'a student with an existing cohort cannot claim a programme that does not match that cohort'
);


-- ---------------------------------------------------------------------------
-- §4 approve_cohort_join_request's programme-match guard
-- ---------------------------------------------------------------------------
-- Claimant C claims EB1 with a distinct student_number, to use against a
-- mismatched (EB3) cohort target.
select pg_temp.act_as('55555555-0000-4000-8000-000000000003');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0002', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000003'::uuid),
  'claimant C claims EB1 with its own student_number, for the mismatch check below'
);

insert into cohort_join_requests (student_id, cohort_id)
values ('55555555-0000-4000-8000-000000000003', pg_temp.cohort('EB3', 2023));

-- The actual rep of the target (EB3) cohort must be the one calling — the
-- pre-existing class-rep-of-this-cohort check (0029) gates this exactly as
-- it always did; the new programme-match guard sits behind it.
select pg_temp.act_as(pg_temp.eb3_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '55555555-0000-4000-8000-000000000003'::uuid),
              %L) $$,
         pg_temp.eb3_rep()),
  'P0001',
  'This student''s programme does not match this cohort''s programme — approval refused',
  'approving a student into a cohort whose programme does not match theirs is refused'
);

insert into cohort_join_requests (student_id, cohort_id)
values ('55555555-0000-4000-8000-000000000001', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '55555555-0000-4000-8000-000000000001'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'approving a student into a cohort whose programme DOES match theirs succeeds'
);

select is(
  (select cohort_id from users where id = '55555555-0000-4000-8000-000000000001'),
  pg_temp.cohort('EB1', 2023),
  '...and cohort_id really was set'
);

-- Regression: an old-style roster account with programme_id still null is
-- approved exactly as before this migration, regardless of target cohort.
-- Same seeded plain-student fixture 02_trust_chain_test.sql uses, approved
-- by the actual rep of the (mismatched) target cohort.
insert into cohort_join_requests (student_id, cohort_id)
values (pg_temp.old_style_student(), pg_temp.cohort('EB3', 2023));

select pg_temp.act_as(pg_temp.eb3_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = %L),
              %L) $$,
         pg_temp.old_style_student(), pg_temp.eb3_rep()),
  'an old-style account with no programme_id is approved unaffected by the new guard'
);

select * from finish();
rollback;
