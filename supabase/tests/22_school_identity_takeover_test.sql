-- ============================================================================
-- 22: commit_school_identity — the takeover path (0042)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §4 step 5: a real school-email owner's approval
-- evicts a provisional squatter on the same student_number automatically,
-- unless the squatter is already oauth (escalate — a red flag, not routine)
-- or holds scheduling authority (escalate — never auto-evict a class rep).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);


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
create function pg_temp.eb1_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;   -- class rep, BSC-CS 2023 (EB1)

-- Both flows are Google OAuth; only the address domain differs (that's what
-- 0039's trigger examines), so one fixture covers both signup shapes.
create function pg_temp.new_oauth_signup(p_id uuid, p_email text) returns void language sql as $$
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
-- §1 A real takeover: a provisional squatter — already placed in a cohort,
-- not just claimed-but-cohortless — is evicted when the real owner is
-- approved. AUTH_FLOW_REFACTOR.md §4 step 5 is explicit that the reset is
-- identical whether the evicted account already made it into a cohort or
-- not; placing the squatter into a real cohort first (via the pre-existing,
-- Plan 2 approval path — rather than leaving cohort_id null, which would
-- make the cohort_id assertion below pass whether or not eviction actually
-- touches it) is what makes that claim mean something.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000001', 'squatter@gmail.com'
);
select pg_temp.act_as('77777777-0000-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '98101', 2026, %L) $$,
         pg_temp.programme('EB1'), '77777777-0000-4000-8000-000000000001'::uuid),
  'a provisional squatter claims the number the real owner will later derive'
);

insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000001', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000001'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'the squatter is placed into a cohort normally first, via the pre-existing (Plan 2) path — claim_method is provisional here, not null, so this goes through the else branch, unrelated to this plan''s new logic'
);
select is(
  (select cohort_id from users where id = '77777777-0000-4000-8000-000000000001'),
  pg_temp.cohort('EB1', 2023),
  '...confirming the squatter really is in a cohort before the takeover below'
);

select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000002', 'eb1.98101.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000002', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000002'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'approving the real owner triggers the takeover'
);

select is(
  (select claim_method from users where id = '77777777-0000-4000-8000-000000000001'),
  null, '...the squatter''s claim_method is reset'
);
select is(
  (select student_number from users where id = '77777777-0000-4000-8000-000000000001'),
  null, '...the squatter''s student_number is cleared, freeing it (ordering proof)'
);
select is(
  (select cohort_id from users where id = '77777777-0000-4000-8000-000000000001'),
  null, '...the squatter''s cohort_id is reset too — even though they had already made it into a cohort, per AUTH_FLOW_REFACTOR.md §4 step 5'
);
select is(
  (select claim_method::text from users where id = '77777777-0000-4000-8000-000000000002'),
  'oauth', '...and the real owner now holds the identity as oauth'
);
select is(
  (select student_number from users where id = '77777777-0000-4000-8000-000000000002'),
  '98101', '...with the exact number that moved from the squatter'
);
select isnt_empty(
  $$ select 1 from notifications
     where user_id = '77777777-0000-4000-8000-000000000001'
       and type = 'account_taken_over' $$,
  'the squatter receives the standard account-taken-over notification'
);
-- reg_number here is the full slash-form registration number derived from
-- the address (EB1/98101/26), NOT the bare student_number (98101) — matching
-- every other writer of this column across the codebase (0017, 0019, 0028,
-- 0029). commit_school_identity computes this exact string as v_reg before
-- ever calling parse_reg_number; it must be reused here, not discarded.
select isnt_empty(
  $$ select 1 from roster_audit_log
     where reg_number = 'EB1/98101/26' and action = 'takeover'
       and target_user = '77777777-0000-4000-8000-000000000001' $$,
  'a takeover audit row is recorded against the squatter, with the full-form reg_number'
);
select isnt_empty(
  $$ select 1 from roster_audit_log
     where reg_number = 'EB1/98101/26' and action = 'claimed'
       and target_user = '77777777-0000-4000-8000-000000000002' $$,
  'a claimed audit row is recorded against the real owner, with the full-form reg_number'
);


-- ---------------------------------------------------------------------------
-- §2 oauth-vs-oauth collision — a red flag, refused and escalated, never
-- silently resolved. Forced fixture state simulates the "should not happen"
-- case directly on an existing, unrelated seeded account — NOT a second
-- signup sharing the first's email address (auth.users.email is unique,
-- and two genuinely different real addresses cannot derive the same
-- number, so a direct force-set is the only way to construct this for a
-- test).
-- ---------------------------------------------------------------------------
update users
set claim_method = 'oauth', student_number = '98102', programme_id = pg_temp.programme('EB1')
where id = '22222222-0000-4000-8000-000000000022';

select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000004', 'eb1.98102.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000004', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000004'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'P0001',
  'Two proven school-email accounts derive the same student number. This '
  'cannot happen under correct operation and needs a faculty rep to '
  'investigate before either account is touched.',
  'an oauth-vs-oauth collision is refused and escalated, not silently resolved'
);


-- ---------------------------------------------------------------------------
-- §3 Class-rep collision — never auto-evict scheduling authority.
-- ---------------------------------------------------------------------------
update users
set claim_method = 'provisional', student_number = '98103'
where id = pg_temp.eb1_rep();

select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000005', 'eb1.98103.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000005', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000005'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'P0001',
  'That identity is held by an account with scheduling authority. A '
  'faculty rep must resolve this.',
  'a collision with an account holding scheduling authority is refused and escalated'
);

select is(
  (select claim_method::text from users where id = pg_temp.eb1_rep()),
  'provisional', '...and the class rep''s own claim is left completely untouched'
);

select * from finish();
rollback;
