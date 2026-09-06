-- ============================================================================
-- 10: Placement — the account and the roster row move together
-- ============================================================================
-- 0029. Two functions used to move a student's account into a cohort while
-- leaving their roster row behind:
--
--   create_cohort_with_class_rep   installing a new cohort's first rep
--   approve_cohort_join_request    the deferred/transferred/repeated path
--
-- That was a real bug, not an inconsistency. claim_roster_row sets
-- users.cohort_id from the roster row UNCONDITIONALLY, so a student placed by
-- either function and later taken over by an OAuth sign-in was silently dropped
-- back into whatever cohort their stale roster row still named.
--
-- WHY THESE TESTS BUILD THEIR OWN FIXTURES. seed.sql §9 creates every cohort
-- through create_cohort_with_class_rep and §9.5 then builds the roster FROM
-- users — so the dev dataset is self-consistent by construction and the
-- divergence is invisible in it. A test asserting on the seed's steady state
-- passes whether or not the bug exists. Every case below CREATES the placement
-- it then asserts on.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.prog(p_code text) returns uuid language sql stable as $$
  select id from programmes where code = p_code;
$$;
create function pg_temp.cohort_of(p_user uuid) returns text language sql stable as $$
  select c.name from users u join cohorts c on c.id = u.cohort_id where u.id = p_user;
$$;
create function pg_temp.roster_cohort(p_reg text) returns text language sql stable as $$
  select c.name from student_roster r join cohorts c on c.id = r.cohort_id
  where r.reg_number = p_reg;
$$;

create function pg_temp.fst_rep()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.fhss_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000002'::uuid $$;
create function pg_temp.kevin()    returns uuid language sql immutable as  -- EB1/67358/23, claimed
  $$ select '22222222-0000-4000-8000-000000000014'::uuid $$;
create function pg_temp.aisha()    returns uuid language sql immutable as  -- EB1/67401/23, claimed
  $$ select '22222222-0000-4000-8000-000000000015'::uuid $$;
create function pg_temp.ian()      returns uuid language sql immutable as  -- EB3/72010/26, NO roster row
  $$ select '22222222-0000-4000-8000-000000000054'::uuid $$;


-- ============================================================================
-- §1 create_cohort_with_class_rep takes the roster row with it
-- ============================================================================
-- A second EB1 2023 cohort on the trimester pace: same programme, same intake,
-- so Kevin's EB1/…/23 number stays valid under it and the row may legally move.
select pg_temp.act_as(pg_temp.fst_rep());
select lives_ok(
  format($$ select create_cohort_with_class_rep(%L::uuid, 2023, 5, 'trimester', %L::uuid, %L::uuid) $$,
         pg_temp.prog('EB1'), pg_temp.kevin(), pg_temp.fst_rep()),
  'a faculty rep creates a cohort and installs its first rep'
);

select is(
  pg_temp.roster_cohort('EB1/67358/23'),
  'BSC-CS 2023 (trimester)',
  'the new rep''s ROSTER row follows their account — it used to be left behind'
);

-- The property that actually matters: claim_roster_row reads the roster to
-- place an account, so these two agreeing is what makes a later takeover land
-- the student where they really are.
select is(
  pg_temp.cohort_of(pg_temp.kevin()),
  pg_temp.roster_cohort('EB1/67358/23'),
  '...so account and roster agree, which is what makes a later takeover safe'
);

select is(
  (select snapshot->>'reason' from roster_audit_log
    where reg_number = 'EB1/67358/23' and action = 'reassigned'),
  'cohort_created',
  '...and the move is on the audit trail, per 0.5''s rule for re-pointing claimed identities'
);


-- ============================================================================
-- §2 approve_cohort_join_request does too
-- ============================================================================
-- The more important of the two paths: 0.5 keeps join requests alive precisely
-- for students who deferred, transferred or repeated — exactly the people whose
-- roster row goes stale and who then sign in later.
insert into cohort_join_requests (id, student_id, cohort_id, status)
select '44444444-0000-4000-8000-0000000000a1', pg_temp.aisha(), c.id, 'pending'
from cohorts c
where c.programme_id = pg_temp.prog('EB1') and c.intake_year = 2023 and c.pace = 'trimester';

select pg_temp.act_as(pg_temp.kevin());
select lives_ok(
  format($$ select approve_cohort_join_request('44444444-0000-4000-8000-0000000000a1', %L::uuid) $$,
         pg_temp.kevin()),
  'the receiving cohort''s rep approves a join request'
);

select is(
  pg_temp.roster_cohort('EB1/67401/23'),
  'BSC-CS 2023 (trimester)',
  '...and the joining student''s roster row moves with them'
);

select is(
  (select snapshot->>'reason' from roster_audit_log
    where reg_number = 'EB1/67401/23' and action = 'reassigned'),
  'join_request_approved',
  '...with the reason recorded, so the two placement paths are distinguishable'
);


-- ============================================================================
-- §3 Where the move would be ILLEGAL, it is declined — not forced
-- ============================================================================
-- roster_assert_may_write requires a registration number's programme and intake
-- year to match the cohort it is filed under. 0016 deliberately does NOT check
-- that a first rep's number belongs to the cohort's programme, so an EB1
-- student may legally lead a BA2 cohort — and moving their roster row would
-- manufacture a row roster_add_student itself refuses.
select pg_temp.act_as(pg_temp.fhss_rep());
select lives_ok(
  format($$ select create_cohort_with_class_rep(%L::uuid, 2024, 3, 'trimester', %L::uuid, %L::uuid) $$,
         pg_temp.prog('BA2'), pg_temp.ian(), pg_temp.fhss_rep()),
  'an out-of-programme student can still be made a cohort''s first rep — 0016 allows this on purpose'
);

-- Ian has NO roster row at all (seed §9.5 skipped him — his EB3 2026 cohort
-- does not exist). Placement must simply not care.
select is(
  (select count(*)::int from student_roster where claimed_by = pg_temp.ian()),
  0,
  '...and an account with no roster row places without error, since there is nothing to move'
);


-- ============================================================================
-- §4 The residue is surfaced, and scoped
-- ============================================================================
-- Build a genuine divergence: move an account across programmes so its roster
-- row legally cannot follow.
select pg_temp.act_as(pg_temp.fhss_rep());
select create_cohort_with_class_rep(
  pg_temp.prog('BA2'), 2025, 1, 'bimester', pg_temp.aisha(), pg_temp.fhss_rep());

select is(
  pg_temp.roster_cohort('EB1/67401/23'),
  'BSC-CS 2023 (trimester)',
  'an EB1 roster row does NOT follow its account into a BA2 cohort — that row would be illegal'
);

select pg_temp.act_as(pg_temp.fst_rep());
select is(
  (select count(*)::int from roster_placement_divergences()
    where reg_number = 'EB1/67401/23'),
  1,
  '...so the divergence is surfaced to the faculty rep who owns that roster row'
);

select pg_temp.act_as(pg_temp.fhss_rep());
select is(
  (select count(*)::int from roster_placement_divergences()
    where reg_number = 'EB1/67401/23'),
  0,
  '...and not to a rep from another faculty, who has no business seeing it'
);


select * from finish();
rollback;
