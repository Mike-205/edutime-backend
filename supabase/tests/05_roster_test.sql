-- ============================================================================
-- 05: The roster — identity anchoring
-- ============================================================================
-- TODO §0.5. Before 0017, identity was self-asserted: handle_new_auth_user
-- copied raw_user_meta_data ->> 'reg_number' straight from the client, so
-- anyone could sign up as anyone. The roster pre-declares who exists.
--
-- Two groups of assertions matter most.
--
-- The PARSER, because everything downstream keys off it. Programme codes are
-- not "letters then a digit" — 'EB10' exists — and self-sponsored intakes
-- insert an 'S' ('EBS3' is programme 'EB3'). Get this wrong and students are
-- misfiled or reps are mis-scoped, silently.
--
-- The SCOPING, because "class reps may write" plus "the roster row pins the
-- cohort" is a cross-cohort hijack unless the registration number itself
-- constrains who a rep may write. Rep B rostering cohort A's student into
-- cohort B would place that student in the wrong cohort on signup, with no
-- human in the loop to notice.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(27);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.fst_rep()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;   -- FST faculty rep
create function pg_temp.fhss_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000002'::uuid $$;   -- FHSS faculty rep
create function pg_temp.cs23_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;   -- class rep, BSC-CS 2023
create function pg_temp.crim_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000041'::uuid $$;   -- class rep, BA-CRIM 2024
create function pg_temp.student()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;   -- plain student, BSC-CS 2023


-- ---------------------------------------------------------------------------
-- Registration-number parsing
-- ---------------------------------------------------------------------------
select is(
  (parse_reg_number('EB1/67277/23')).programme_code, 'EB1',
  'a plain registration number resolves to its programme'
);

select is(
  (parse_reg_number('EB1/67277/23')).admission_year, 2023,
  'the two-digit suffix expands to the four-digit intake year cohorts store'
);

select is(
  (parse_reg_number('EB1/67277/23')).is_self_sponsored, false,
  'a code with no inserted S is government-sponsored'
);

-- The case a "letters then one digit" regex silently mangles.
select is(
  (parse_reg_number('EB10/12345/23')).programme_code, 'EB10',
  'a multi-digit programme code resolves whole, not truncated to EB1'
);

-- The case a literal-only lookup silently rejects.
select is(
  (parse_reg_number('EBS3/67891/23')).programme_code, 'EB3',
  'a self-sponsored code resolves to the same programmes row as its sponsored twin'
);

select is(
  (parse_reg_number('EBS3/67891/23')).is_self_sponsored, true,
  '...and is flagged as self-sponsored, which is what pace is derived from'
);

select is(
  (parse_reg_number('not a reg number')).programme_id, null,
  'an unparseable number returns null rather than raising'
);

select is(
  (parse_reg_number('ZZ9/12345/23')).programme_id, null,
  'a well-formed number naming an unknown programme returns null'
);

select is(
  (parse_reg_number('eb1/67277/23')).programme_code, 'EB1',
  'input is normalized, so case is not a way to smuggle a duplicate past the unique index'
);


-- ---------------------------------------------------------------------------
-- Scoped writes — the class rep path
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.cs23_rep());

select lives_ok(
  format($$ select roster_add_student('EB1/99001/23','Faith','Wanjiru','N',%L::uuid,%L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.cs23_rep()),
  'a class rep may add a student whose reg number matches their cohort'
);

-- The hijack this whole scoping rule exists to stop.
select throws_ok(
  format($$ select roster_add_student('EB3/99002/23','Wrong','Programme',null,%L::uuid,%L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.cs23_rep()),
  'P0001',
  null,
  'a rep cannot roster a student from another programme into their cohort'
);

select throws_ok(
  format($$ select roster_add_student('EB1/99003/24','Wrong','Year',null,%L::uuid,%L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.cs23_rep()),
  'P0001',
  null,
  'a rep cannot roster a student from another intake year into their cohort'
);

select throws_ok(
  format($$ select roster_add_student('EB1/99004/24','Other','Cohort',null,%L::uuid,%L::uuid) $$,
         pg_temp.cohort('EB1', 2024), pg_temp.cs23_rep()),
  'P0001',
  null,
  'a class rep cannot write to a cohort that is not their own'
);

-- Unchecked bulk import by a class rep would collapse the roster's authority
-- back onto the class rep, which is the thing it exists to move away from.
select throws_ok(
  format($$ select roster_bulk_import(
              '[{"reg_number":"EB1/99005/23","first_name":"A","last_name":"B"}]'::jsonb,
              %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.cs23_rep()),
  'P0001',
  'Bulk import is a faculty_rep action. A class_rep may add students one at a time.',
  'a class rep is refused bulk import, with a message that explains the rule'
);

select pg_temp.act_as(pg_temp.student());
select throws_ok(
  format($$ select roster_add_student('EB1/99006/23','Plain','Student',null,%L::uuid,%L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.student()),
  'P0001',
  null,
  'a plain student cannot write roster rows at all'
);


-- ---------------------------------------------------------------------------
-- Scoped writes — the faculty rep path
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.fst_rep());

select is(
  roster_bulk_import(
    '[{"reg_number":"EB3/99010/23","first_name":"Grace","last_name":"Achieng"},
      {"reg_number":"EB3/99011/23","first_name":"Peter","last_name":"Otieno","middle_name":"K"}]'::jsonb,
    pg_temp.cohort('EB3', 2023), pg_temp.fst_rep()),
  2,
  'a faculty rep may bulk import into a cohort in their own faculty'
);

select throws_ok(
  format($$ select roster_bulk_import(
              '[{"reg_number":"BA2/99020/24","first_name":"Cross","last_name":"Faculty"}]'::jsonb,
              %L::uuid, %L::uuid) $$,
         pg_temp.cohort('BA2', 2024), pg_temp.fst_rep()),
  'P0001',
  null,
  'a faculty rep is scoped to their own faculty, same as create_cohort_with_class_rep'
);

-- Global, not per-cohort: two reps must not be able to roster the same human
-- into two different cohorts.
select pg_temp.act_as(pg_temp.cs23_rep());
select throws_ok(
  format($$ select roster_add_student('EB1/99001/23','Duplicate','Person',null,%L::uuid,%L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.cs23_rep()),
  'P0001',
  'Registration number EB1/99001/23 is already on the roster',
  'a registration number can only be on the roster once, university-wide'
);


-- ---------------------------------------------------------------------------
-- The roster is write-mostly
-- ---------------------------------------------------------------------------
-- Readable by students, this table is a directory of every classmate's exact
-- official name and registration number — precisely the pair needed to claim
-- someone else's row on the password branch.
set local role authenticated;

select pg_temp.act_as(pg_temp.student());
select is(
  (select count(*) from student_roster), 0::bigint,
  'a plain student cannot see a single roster row, including their own cohort''s'
);

select pg_temp.act_as(pg_temp.cs23_rep());
select cmp_ok(
  (select count(*) from student_roster), '>', 0::bigint,
  'a class rep can see their own cohort''s roster, to know who has not signed up'
);

select is(
  (select count(*) from student_roster
    where cohort_id = pg_temp.cohort('EB3', 2023)), 0::bigint,
  '...but not another cohort''s, even one in the same faculty'
);

select pg_temp.act_as(pg_temp.fst_rep());
select cmp_ok(
  (select count(*) from student_roster), '>', 0::bigint,
  'a faculty rep sees rosters across their own faculty'
);

-- Not "sees nothing" — the seed rosters BA-CRIM 2024, so this rep legitimately
-- sees their own cohort. The claim under test is that the faculty boundary
-- holds: nothing from FST is visible to an FHSS rep.
select pg_temp.act_as(pg_temp.crim_rep());
select is(
  (select count(*) from student_roster r
    where r.cohort_id <> pg_temp.cohort('BA2', 2024)), 0::bigint,
  'a class rep in another faculty sees nothing outside their own cohort'
);

reset role;


-- ---------------------------------------------------------------------------
-- Recovery addresses are self-only
-- ---------------------------------------------------------------------------
-- A recovery email is personal PII that proves nothing about identity. It must
-- not be visible to a class rep, who can see everything else about their cohort.
insert into user_recovery_email (user_id, email)
values (pg_temp.student(), 'someone.personal@example.com');

set local role authenticated;
select pg_temp.act_as(pg_temp.cs23_rep());
select is(
  (select count(*) from user_recovery_email), 0::bigint,
  'a class rep cannot read their own cohort member''s recovery address'
);

select pg_temp.act_as(pg_temp.student());
select is(
  (select email from user_recovery_email), 'someone.personal@example.com',
  '...but the owner can read their own'
);
reset role;


-- ---------------------------------------------------------------------------
-- Corrections
-- ---------------------------------------------------------------------------
-- A mistyped digit locks a real student out with no self-service fix, so the
-- rep who made the typo has to be able to fix it.
select pg_temp.act_as(pg_temp.cs23_rep());

select lives_ok(
  format($$ select roster_correct_student(
              (select id from student_roster where reg_number = 'EB1/99001/23'),
              'EB1/99007/23','Faith','Wanjiru','N',%L::uuid) $$, pg_temp.cs23_rep()),
  'a rep can correct a mistyped registration number while the row is unclaimed'
);

select lives_ok(
  format($$ select roster_remove_student(
              (select id from student_roster where reg_number = 'EB1/99007/23'),
              %L::uuid) $$, pg_temp.cs23_rep()),
  'a rep can remove an unclaimed roster row'
);


select * from finish();
rollback;
