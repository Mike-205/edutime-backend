-- ============================================================================
-- 17: Identity schema — structure only (0037)
-- ============================================================================
-- Covers AUTH_FLOW_REFACTOR.md §2's four identity columns and four email
-- columns on `users`, before any function writes them. Three properties
-- matter: student_number is globally unique, a user's programme_id can never
-- disagree with their own cohort's programme_id (the composite FK), and none
-- of the eight new columns are client-writable — matching the "column-level
-- grants gate first, the guard trigger backstops" discipline `0014`/`0032`
-- already established for every other identity column.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
create function pg_temp.programme(p_code text) returns uuid language sql stable as $$
  select id from programmes where code = p_code;
$$;
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;
-- Plain student, BSC-CS 2023 (programme code 'EB1') — same fixture id 05_roster_test.sql uses.
create function pg_temp.student() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;


-- ---------------------------------------------------------------------------
-- §1 student_number uniqueness
-- ---------------------------------------------------------------------------
update users set student_number = 'DUP001' where id = pg_temp.student();

select throws_ok(
  format($$ update users set student_number = 'DUP001'
            where id = (select id from users where role = 'student' and id != %L limit 1) $$,
         pg_temp.student()),
  '23505',
  null,
  'student_number is globally unique — a second account cannot hold the same one'
);

select lives_ok(
  $$ update users set student_number = null where id = '22222222-0000-4000-8000-000000000013' $$,
  'student_number can be cleared back to null (multiple nulls are not a uniqueness violation)'
);


-- ---------------------------------------------------------------------------
-- §2 Composite FK: users(cohort_id, programme_id) -> cohorts(id, programme_id)
-- ---------------------------------------------------------------------------
-- The fixture student is already in cohort EB1/2023 (cohort_id set). Both
-- sides null, or both agreeing, must be allowed; disagreeing must not.
select throws_ok(
  format($$ update users set programme_id = %L where id = %L $$,
         pg_temp.programme('EB3'), pg_temp.student()),
  '23503',
  null,
  'setting programme_id to a DIFFERENT programme than the existing cohort is refused'
);

select lives_ok(
  format($$ update users set programme_id = %L where id = %L $$,
         pg_temp.programme('EB1'), pg_temp.student()),
  'setting programme_id to the SAME programme as the existing cohort is allowed'
);

select lives_ok(
  format($$ update users set cohort_id = null, programme_id = null where id = %L $$,
         pg_temp.student()),
  'both sides null satisfies the FK (pre-claim state)'
);

select lives_ok(
  format($$ update users set programme_id = %L where id = %L $$,
         pg_temp.programme('EB3'), pg_temp.student()),
  'programme_id alone, with cohort_id null, satisfies the FK (claimed-but-cohortless state, AUTH_FLOW_REFACTOR.md §3 step 5)'
);

-- ---------------------------------------------------------------------------
-- §3 The eight new columns are not client-writable
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.student());

select throws_ok(
  $$ update users set programme_id = (select id from programmes limit 1) where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own programme_id directly'
);
select throws_ok(
  $$ update users set self_sponsored = true where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own self_sponsored directly'
);
select throws_ok(
  $$ update users set student_number = 'EB1/99999/23' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own student_number directly'
);
select throws_ok(
  $$ update users set admission_year = 2099 where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own admission_year directly'
);
select throws_ok(
  $$ update users set school_email = 'nobody@student.chuka.ac.ke' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own school_email directly'
);
select throws_ok(
  $$ update users set school_email_verified_at = now() where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own school_email_verified_at directly'
);
select throws_ok(
  $$ update users set personal_email = 'nobody@gmail.com' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own personal_email directly'
);
select throws_ok(
  $$ update users set personal_email_verified_at = now() where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own personal_email_verified_at directly'
);

select lives_ok(
  $$ update users set first_name = 'Renamed' where id = auth.uid() $$,
  'a student can still edit their own display name — the guard extension did not regress the allowed path'
);

reset role;

select * from finish();
rollback;
