-- ============================================================================
-- 02: The trust chain — Superadmin -> Faculty Rep -> Class Rep -> Student
-- ============================================================================
-- §2 of TECHNICAL_DISCOVERY: "A cohort's schedule can only be created or
-- modified by someone whose authority traces back to a real-world election
-- witnessed by a Faculty Rep. Top-down only, no role can skip a level or
-- self-promote."
--
-- Every assertion here is one way that chain could be broken. The two that
-- matter most are the self-promotion pair — before 0014, a student could simply
-- UPDATE their own row to role='class_rep' with any cohort_id they liked and
-- gain scheduling authority over a cohort they had never been elected in.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(20);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.slot(d int, h int) returns timestamptz language sql stable as $$
  select date_trunc('week', now() + interval '300 days') + make_interval(days => d - 1, hours => h);
$$;
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
create function pg_temp.venue(p_b text, p_r text) returns uuid language sql stable as $$
  select v.id from venues v join rooms r on r.id = v.room_id
  join buildings b on b.id = r.building_id
  where b.abbreviation = p_b and r.number = p_r;
$$;
create function pg_temp.course(p_prog text, p_abbr text) returns uuid language sql stable as $$
  select c.id from courses c join programmes p on p.id = c.programme_id
  where p.code = p_prog and c.abbreviation = p_abbr;
$$;
-- One create_event attachment (0022 §1): which cohort attends, and as which
-- unit. Concatenate with || to attach a second cohort.
create function pg_temp.att(p_code text, p_intake_year int, p_abbr text) returns jsonb
language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'cohort_id', pg_temp.cohort(p_code, p_intake_year),
    'course_id', pg_temp.course(p_code, p_abbr)
  ));
$$;
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

-- Seeded people.
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
-- Two DIFFERENT cohortless students. Reusing one for both the promotion test and
-- the join-request test made the promotion turn them into a class rep, which
-- then changed what the join-request test was actually exercising.
create function pg_temp.nominee() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000054'::uuid $$;   -- to be promoted below
create function pg_temp.joiner()   returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000053'::uuid $$;   -- has pending request ...0003


-- ---------------------------------------------------------------------------
-- No self-promotion — via the privilege layer, and via the trigger backstop
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.student());

-- Column-level UPDATE grants refuse this before any trigger runs.
select throws_ok(
  $$ update users set role = 'class_rep', class_rep_rank = 'primary' where id = auth.uid() $$,
  '42501',
  null,
  'a student cannot promote themselves to class_rep'
);

select throws_ok(
  $$ update users set cohort_id = (
       select c.id from cohorts c join programmes p on p.id = c.programme_id
       where p.code = 'BA2' and c.intake_year = 2024)
     where id = auth.uid() $$,
  '42501',
  null,
  'a student cannot move themselves into another cohort'
);

select throws_ok(
  $$ update users set email_verified_at = now() where id = auth.uid() $$,
  '42501',
  null,
  'a student cannot award themselves the verified badge'
);

-- ...but their own name is still theirs to edit.
select lives_ok(
  $$ update users set first_name = 'Renamed' where id = auth.uid() $$,
  'a student CAN still edit their own display name'
);

-- Nor can anyone reach past the functions to write the schedule directly.
select throws_ok(
  $$ update events set attendance_status = 'confirmed' $$,
  '42501',
  null,
  'no client may write to events directly, not even a rep'
);

reset role;


-- ---------------------------------------------------------------------------
-- Only a class rep may schedule, and only for their own cohort
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.student());
select throws_ok(
  format($$ select create_event(%L::jsonb, %L::uuid, 'X', null,
                                %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid) $$,
         pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('S','GT4'),
         pg_temp.slot(1, 7), pg_temp.slot(1, 10), pg_temp.student()),
  'P0001',
  'Only a class_rep may schedule an event',
  'a plain student cannot create a lecture even for their own cohort'
);

-- A rep may not schedule for a cohort they have nothing to do with. The unit is
-- BA-CRIM's own, so nothing but the trust check can be what refuses this.
select pg_temp.act_as(pg_temp.cs23_rep());
select throws_ok(
  format($$ select create_event(%L::jsonb, %L::uuid, 'X', null,
                                %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid) $$,
         pg_temp.att('BA2', 2024,'FCSI'), pg_temp.venue('S','GT4'),
         pg_temp.slot(1, 7), pg_temp.slot(1, 10), pg_temp.cs23_rep()),
  'P0001',
  'p_attachments must include the acting rep''s own cohort',
  'a class rep cannot schedule for a cohort that is not theirs'
);

-- Impersonation: passing somebody else's id as the acting user. This was open
-- until 0008 — any authenticated caller could act as any other user.
select throws_ok(
  format($$ select create_event(%L::jsonb, %L::uuid, 'X', null,
                                %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid) $$,
         pg_temp.att('BA2', 2024,'FCSI'), pg_temp.venue('S','GT4'),
         pg_temp.slot(1, 7), pg_temp.slot(1, 10), pg_temp.crim_rep()),
  'P0001',
  'p_acting_user must match the calling user',
  'a rep cannot claim to be acting as a different rep'
);


-- ---------------------------------------------------------------------------
-- Faculty Rep authority stops at their own faculty (0014 §4)
-- ---------------------------------------------------------------------------
-- Before 0014 these two checked `role = 'faculty_rep'` and nothing else, making
-- a faculty's trust anchor effectively university-wide.
select pg_temp.act_as(pg_temp.fhss_rep());
select throws_ok(
  format($$ select create_cohort_with_class_rep(%L::uuid, 2026, 1, 'bimester', %L::uuid, %L::uuid) $$,
         (select id from programmes where code = 'EB1'),   -- a Science & Tech programme
         pg_temp.nominee(), pg_temp.fhss_rep()),
  'P0001',
  null,
  'a Humanities faculty rep cannot create a cohort under a Science programme'
);

select throws_ok(
  format($$ select demote_class_rep(%L::uuid, %L::uuid) $$,
         pg_temp.cs23_rep(), pg_temp.fhss_rep()),
  'P0001',
  null,
  'a faculty rep cannot demote a class rep in another faculty'
);

-- Within their own faculty, the same call works.
--
-- The nominee (Ian, …054) carries a real EB3 programme_id since seed's §9.5
-- (plan 5/5, task 1) now derives it from his reg_number even though he has no
-- cohort yet. This test nominates him into an EB1 cohort instead — a
-- deliberate cross-programme promotion for the "atomic first-rep promotion"
-- assertion below — so his own fixture clears that programme_id first,
-- rather than relying on seed leaving it unset.
update users set programme_id = null where id = pg_temp.nominee();
select pg_temp.act_as(pg_temp.fst_rep());
select lives_ok(
  format($$ select create_cohort_with_class_rep(%L::uuid, 2026, 1, 'bimester', %L::uuid, %L::uuid) $$,
         (select id from programmes where code = 'EB1'),
         pg_temp.nominee(), pg_temp.fst_rep()),
  'the Science faculty rep CAN create a cohort under their own programme'
);

select is(
  (select role::text || '/' || class_rep_rank::text from users where id = pg_temp.nominee()),
  'class_rep/primary',
  'the nominated student is promoted to primary class rep atomically'
);

-- The first rep must be an actual student: a non-existent id used to leave the
-- UPDATE matching zero rows and return a cohort with no rep at all, silently
-- breaking the invariant the function exists to uphold.
select throws_ok(
  format($$ select create_cohort_with_class_rep(%L::uuid, 2026, 1, 'bimester',
                    '00000000-0000-4000-8000-000000000000'::uuid, %L::uuid) $$,
         (select id from programmes where code = 'EB3'), pg_temp.fst_rep()),
  'P0001',
  null,
  'a cohort cannot be created with a first rep who does not exist'
);

-- Nor may a faculty rep be demoted into a class rep by being nominated.
select throws_ok(
  format($$ select create_cohort_with_class_rep(%L::uuid, 2026, 1, 'bimester', %L::uuid, %L::uuid) $$,
         (select id from programmes where code = 'EB3'),
         pg_temp.fhss_rep(), pg_temp.fst_rep()),
  'P0001',
  null,
  'a faculty rep cannot be nominated as a cohort''s first class rep'
);


-- ---------------------------------------------------------------------------
-- Faculty Reps never touch the schedule
-- ---------------------------------------------------------------------------
-- Deliberate per §2: scheduling authority belongs to class reps alone. A faculty
-- rep has no cohort_id, so they fail the class_rep check.
select throws_ok(
  format($$ select create_event(%L::jsonb, %L::uuid, 'X', null,
                                %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid) $$,
         pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('S','GT4'),
         pg_temp.slot(1, 7), pg_temp.slot(1, 10), pg_temp.fst_rep()),
  'P0001',
  'Only a class_rep may schedule an event',
  'a faculty rep cannot schedule a lecture'
);


-- ---------------------------------------------------------------------------
-- Join requests are resolved only by the right cohort's rep
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.crim_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(%L::uuid, %L::uuid) $$,
         '33333333-0000-4000-8000-000000000003',   -- a pending request for BSC-CS 2023
         pg_temp.crim_rep()),
  'P0001',
  'Only the class rep of this cohort may approve join requests',
  'a rep from another cohort cannot approve a join request'
);

select pg_temp.act_as(pg_temp.cs23_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(%L::uuid, %L::uuid) $$,
         '33333333-0000-4000-8000-000000000003', pg_temp.cs23_rep()),
  'the cohort''s own rep can approve the request'
);

select is(
  (select u.cohort_id from users u where u.id = pg_temp.joiner()),
  pg_temp.cohort('EB1', 2023),
  'approving a request moves the student into the cohort atomically'
);


-- ---------------------------------------------------------------------------
-- A join request must not carry class-rep authority sideways (0014 §13)
-- ---------------------------------------------------------------------------
-- Found by this suite. approve_cohort_join_request used to move whoever was
-- named straight into the cohort without checking their role, so a sitting class
-- rep could request to join another cohort, get approved by a rep who thought
-- they were admitting a student, and land there still carrying role='class_rep'
-- — scheduling authority over a cohort that never elected them. Nothing blocked
-- it unless the target already held two reps.
reset role;
insert into cohort_join_requests (id, student_id, cohort_id, status)
values ('44444444-0000-4000-8000-000000000001', pg_temp.cs23_rep(),
        pg_temp.cohort('BA2', 2024), 'pending');

select pg_temp.act_as(pg_temp.crim_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(%L::uuid, %L::uuid) $$,
         '44444444-0000-4000-8000-000000000001', pg_temp.crim_rep()),
  'P0001',
  null,
  'approving a sitting class rep''s join request is refused, not silently allowed'
);

select is(
  (select u.cohort_id from users u where u.id = pg_temp.cs23_rep()),
  pg_temp.cohort('EB1', 2023),
  'the rejected request leaves the rep in their original cohort'
);


select * from finish();
rollback;
