-- ============================================================================
-- 21: commit_school_identity — Flow 2 first-claim path (0041)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §4: a school-email account's identity is derived and
-- committed only at approval time. Covers a clean first claim (including the
-- self-sponsored S-prefix variant), the two refusal paths (unparseable
-- address, programme mismatch), a student_number collision being resolved by
-- graceful eviction of the prior provisional holder (not a raw constraint
-- failure), and — the one most likely to regress silently — that an
-- already-placed account with a proven-but-unclaimed school email does NOT
-- get swept into this new branch.
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
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
-- Real seeded class reps, same ids 20_claim_identity_personal_test.sql uses.
create function pg_temp.eb1_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;   -- class rep, BSC-CS 2023 (EB1)
create function pg_temp.eb3_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;   -- class rep, BSC-ACS 2023 (EB3)
-- Faith Mueni: proven school email, never claimed via either flow, but
-- ALREADY placed in BSC-CS 2023 by the pre-redesign seed process. This is
-- the exact fixture the discriminator's cohort_id-is-null clause exists for.
create function pg_temp.already_placed_school_account() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;

create function pg_temp.new_school_signup(p_id uuid, p_email text) returns void language sql as $$
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
$$;


-- ---------------------------------------------------------------------------
-- §1 A clean first claim
-- ---------------------------------------------------------------------------
select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000001', 'eb1.98001.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000001', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000001'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'a fresh school-email account is approved and its identity derived and committed'
);

select is(
  (select claim_method::text from users where id = '66666666-0000-4000-8000-000000000001'),
  'oauth', '...as claim_method = oauth'
);
select is(
  (select student_number from users where id = '66666666-0000-4000-8000-000000000001'),
  '98001', '...with the student_number correctly derived from the address'
);
select is(
  (select self_sponsored from users where id = '66666666-0000-4000-8000-000000000001'),
  false, '...and self_sponsored is correctly derived (false for a non-S-prefixed code)'
);
select is(
  (select admission_year from users where id = '66666666-0000-4000-8000-000000000001'),
  2026, '...and admission_year is correctly derived'
);
select is(
  (select cohort_id from users where id = '66666666-0000-4000-8000-000000000001'),
  pg_temp.cohort('EB1', 2023),
  '...and cohort_id set, same as any other approval'
);

-- reg_number here is the full slash-form registration number the address
-- derives (EB1/98001/26), NOT the bare student_number (98001) — matching
-- every other writer of this column across the codebase.
select isnt_empty(
  $$ select 1 from roster_audit_log
     where reg_number = 'EB1/98001/26' and action = 'claimed'
       and target_user = '66666666-0000-4000-8000-000000000001' $$,
  'a claimed audit row is recorded, with the full-form reg_number'
);


-- ---------------------------------------------------------------------------
-- §2 Refusals
-- ---------------------------------------------------------------------------
-- Unparseable local part — the same address 06_claim_and_takeover_test.sql
-- uses to demonstrate this exact non-parsing shape.
select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000002', 'j.doe@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000002', pg_temp.cohort('EB1', 2023));

select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000002'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'P0001',
  'Could not derive a student identity from this school email. A faculty rep must resolve this.',
  'an address that does not parse to a student number is refused'
);

-- Derived programme (EB1) does not match the requested cohort's (EB3).
select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000003', 'eb1.98003.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000003', pg_temp.cohort('EB3', 2023));

select pg_temp.act_as(pg_temp.eb3_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000003'::uuid),
              %L) $$,
         pg_temp.eb3_rep()),
  'P0001',
  'The identity derived from this school email does not match this cohort''s programme',
  'a derived programme that does not match the requested cohort is refused'
);


-- ---------------------------------------------------------------------------
-- §3 A student_number collision is resolved by eviction, not a raw
-- constraint failure (0042 replaces the accepted interim state from 0041 —
-- see 0042's own migration comment).
-- ---------------------------------------------------------------------------
update users
set student_number = '98004', claim_method = 'provisional'
where id = '22222222-0000-4000-8000-000000000015';

select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000004', 'eb1.98004.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000004', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000004'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'a student_number collision is now resolved by eviction, not a raw constraint failure'
);
select is(
  (select claim_method from users where id = '22222222-0000-4000-8000-000000000015'),
  null, '...the evicted provisional holder''s claim_method is reset'
);
select is(
  (select student_number from users where id = '66666666-0000-4000-8000-000000000004'),
  '98004', '...and the real owner now holds the number'
);


-- ---------------------------------------------------------------------------
-- §4 The discriminator's cohort_id-is-null clause: an already-placed account
-- with a proven-but-unclaimed school email must NOT be swept into this
-- branch.
-- ---------------------------------------------------------------------------
-- already_placed_school_account()'s programme_id is no longer null by the
-- time seed finishes (plan 5/5 task 1's §9.5 now derives it from every
-- reg-numbered account, this one included) — null it here, in this test's
-- own fixture, to recreate the "proven-but-unclaimed" premise the
-- discriminator check actually needs.
update users set programme_id = null where id = pg_temp.already_placed_school_account();

insert into cohort_join_requests (student_id, cohort_id)
values (pg_temp.already_placed_school_account(), pg_temp.cohort('EB3', 2023));

select pg_temp.act_as(pg_temp.eb3_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = %L),
              %L) $$,
         pg_temp.already_placed_school_account(), pg_temp.eb3_rep()),
  'an already-placed account with a proven school email is approved via the plain path, unaffected by the new branch'
);

select is(
  (select programme_id from users where id = pg_temp.already_placed_school_account()),
  null,
  '...and its programme_id is still null — proof it was NOT swept into commit_school_identity'
);

-- ---------------------------------------------------------------------------
-- §5 The self-sponsored (S-prefix) variant is correctly derived and written
-- ---------------------------------------------------------------------------
-- The S goes BEFORE the digit (EBS1), not after (EB1S) — parse_reg_number's
-- S-stripping only recognizes the former shape. No EBS-prefixed programme
-- code exists in this dataset, so the S-stripped candidate ('EB1') is what
-- actually resolves.
select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000006', 'ebs1.98006.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000006', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000006'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'an S-prefixed school address (self-sponsored) is approved and derived correctly'
);
select is(
  (select self_sponsored from users where id = '66666666-0000-4000-8000-000000000006'),
  true, '...with self_sponsored correctly derived as true'
);
select is(
  (select student_number from users where id = '66666666-0000-4000-8000-000000000006'),
  '98006', '...and the student_number derived correctly despite the S prefix'
);

select * from finish();
rollback;
