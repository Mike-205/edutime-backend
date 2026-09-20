-- ============================================================================
-- 09: Streams — a cohort split into parallel lecture groups
-- ============================================================================
-- 0025 and 0026. A large intake is split into Stream A / Stream B because one
-- room cannot hold it. The split is whole-timetable, each stream elects its own
-- class rep, and streams regularly rejoin for combined sessions — so a stream
-- IS a cohort here, and the interesting assertions are about what stops it
-- being a BADLY FORMED one.
--
-- The design turns on one thing: `(programme, intake, pace)` must stay unique
-- for anything that is actually a cohort. Widening that key to include the
-- stream was the obvious move and it is wrong — it would let three rows each
-- claim to be EB1/2023/bimester. So streams are children, and the identity
-- index is partial. §1 is where that is proved.
--
-- §5 covers the naming defect 0023 introduced and 0026 fixed: pace was baked
-- into a name generated once at creation, while reps can still change pace.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(47);


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
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year and c.parent_cohort_id is null;
$$;
create function pg_temp.stream(p_code text, p_intake_year int, p_stream text) returns uuid
language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year and c.stream = p_stream;
$$;

create function pg_temp.fst_rep()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.fhss_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000002'::uuid $$;
create function pg_temp.mercy()    returns uuid language sql immutable as  -- primary rep, BSC-CS 2023
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.faith()    returns uuid language sql immutable as  -- plain student, BSC-CS 2023
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;
create function pg_temp.kevin()    returns uuid language sql immutable as  -- plain student, BSC-CS 2023
  $$ select '22222222-0000-4000-8000-000000000014'::uuid $$;
create function pg_temp.grace()    returns uuid language sql immutable as  -- plain student, BSC-CS 2024
  $$ select '22222222-0000-4000-8000-000000000022'::uuid $$;
create function pg_temp.dennis()   returns uuid language sql immutable as  -- primary rep, BSC-CS 2024 (trimester)
  $$ select '22222222-0000-4000-8000-000000000021'::uuid $$;
create function pg_temp.samuel()   returns uuid language sql immutable as  -- primary rep, BSC-ACS 2023
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;


-- ---------------------------------------------------------------------------
-- Roster fixture
-- ---------------------------------------------------------------------------
-- student_roster is retired in Task 7 of this plan — until then,
-- create_cohort_stream's rep-roster-follow and assign_students_to_streams (§6
-- below) still read it directly. seed.sql no longer builds any roster rows
-- (Task 1), so this file builds the minimal rows it needs by hand, matching
-- the accounts §1 and §6 actually move.
--
-- This has to run BEFORE §1: create_cohort_stream moves whichever roster row
-- is claimed_by its new rep at the moment it is called, so Peter's (fst_rep)
-- and Kevin's/Aisha's/Lydia's/Victor's/Ruth's/Brian's rows all need to exist
-- up front. Peter and Faith are §1's/§6's reps and are asserted on directly;
-- Ruth and Brian are deliberately left where §6's assign calls against them
-- fail (Ruth: an unclaimed row nobody successfully assigns; Brian: a class
-- rep, refused by design) so both remain at the parent cohort for the
-- "who is left" count at the end of §6.
insert into student_roster (
  reg_number, first_name, last_name, middle_name, cohort_id,
  claimed_by, claimed_at, claim_method
) values
  ('EB1/66001/23', 'Peter', 'Kimani',   'Njoroge', pg_temp.cohort('EB1', 2023),
   pg_temp.fst_rep(), now(), 'oauth'),
  ('EB1/67340/23', 'Faith', 'Mueni',    null,      pg_temp.cohort('EB1', 2023),
   pg_temp.faith(), now(), 'oauth'),
  ('EB1/67358/23', 'Kevin', 'Kariuki',  'Mwangi',  pg_temp.cohort('EB1', 2023),
   pg_temp.kevin(), now(), 'provisional'),
  ('EB1/67401/23', 'Aisha', 'Hassan',   null,      pg_temp.cohort('EB1', 2023),
   '22222222-0000-4000-8000-000000000015'::uuid, now(), 'oauth'),
  ('EB1/67312/23', 'Brian', 'Otieno',   null,      pg_temp.cohort('EB1', 2023),
   '22222222-0000-4000-8000-000000000012'::uuid, now(), 'oauth'),
  ('EB1/67455/23', 'Lydia', 'Chebet',   null,      pg_temp.cohort('EB1', 2023),
   null, null, null),
  ('EB1/67470/23', 'Victor','Onyango',  null,      pg_temp.cohort('EB1', 2023),
   null, null, null),
  ('EB1/67488/23', 'Ruth',  'Nyaguthii',null,      pg_temp.cohort('EB1', 2023),
   null, null, null);


-- ============================================================================
-- §1 The identity guarantee survives (0025 §2)
-- ============================================================================
-- 0024 §1 bought: exactly ONE cohort per (programme, intake, pace). Streams must
-- not dilute it. This is the assertion the whole parent/child design exists for.
-- A cohort with a live timetable cannot be split at all (0028 §1). Splitting
-- does NOT migrate events to the streams — each stream needs its own room and
-- time, and re-attaching one event to both would silently book both groups into
-- one room, which neither EXCLUDE constraint can catch.
select pg_temp.act_as(pg_temp.fst_rep());
select throws_like(
  format($$ select create_cohort_stream(%L::uuid, 'A', %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.faith(), pg_temp.fst_rep()),
  '%upcoming lecture%',
  'a cohort with lectures already entered cannot be split — split before the schedule exists'
);

-- The escape hatch the error message names: cancel them first. Doing it through
-- the real API rather than an UPDATE, so this doubles as a check that the
-- documented workaround actually works.
do $$
declare
  v_rep    uuid := '22222222-0000-4000-8000-000000000011';
  v_cohort uuid;
  r        record;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rep::text, 'role', 'authenticated')::text, true);
  select c.id into v_cohort from cohorts c join programmes p on p.id = c.programme_id
    where p.code = 'EB1' and c.intake_year = 2023 and c.parent_cohort_id is null;

  for r in
    select distinct e.id
    from events e
    join event_cohorts ec on ec.event_id = e.id
    where ec.cohort_id = v_cohort and ec.is_initiator
      and e.status in ('scheduled', 'proposed') and e.start_time > now()
  loop
    perform cancel_event(r.id, v_rep);
  end loop;
end $$;

select pg_temp.act_as(pg_temp.fst_rep());
select lives_ok(
  format($$ select create_cohort_stream(%L::uuid, 'A', %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.faith(), pg_temp.fst_rep()),
  '...and once its lectures are cancelled, the split goes through'
);

select lives_ok(
  format($$ select create_cohort_stream(%L::uuid, 'B', %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.mercy(), pg_temp.fst_rep()),
  '...and a second stream alongside it'
);

select is(
  (select count(*)::int from cohorts
    where programme_id = pg_temp.prog('EB1') and intake_year = 2023 and pace = 'bimester'),
  3,
  'three rows now share (programme, intake, pace) — one cohort and its two streams'
);

select is(
  (select count(*)::int from cohorts
    where programme_id = pg_temp.prog('EB1') and intake_year = 2023 and pace = 'bimester'
      and parent_cohort_id is null),
  1,
  '...but exactly ONE of them is a cohort. This is the guarantee widening the key would have cost'
);

-- Direct INSERT as postgres: the constraint, not the function, has to hold this.
select throws_ok(
  format($$ insert into cohorts (programme_id, intake_year, current_semester, pace)
            values (%L::uuid, 2023, 5, 'bimester') $$, pg_temp.prog('EB1')),
  '23505',
  null,
  'a second top-level cohort with the same identity is still refused'
);


-- ============================================================================
-- §2 A stream cannot contradict its parent (0025 §5)
-- ============================================================================
-- term_bounds() is a pure function of date AND pace, so a stream claiming a
-- different pace from its parent would compute the wrong academic term and
-- materialize a recurring series against the wrong horizon — surfacing weeks
-- later as wrongly-scheduled lectures rather than as an error.
select throws_ok(
  format($$ insert into cohorts (programme_id, intake_year, current_semester, pace,
                                 parent_cohort_id, stream)
            values (%L::uuid, 2023, 5, 'trimester', %L::uuid, 'X') $$,
         pg_temp.prog('EB1'), pg_temp.cohort('EB1', 2023)),
  '23503',
  null,
  'a stream whose pace contradicts its parent is refused by the composite FK'
);

select throws_ok(
  format($$ insert into cohorts (programme_id, intake_year, current_semester, pace,
                                 parent_cohort_id, stream)
            values (%L::uuid, 2024, 5, 'bimester', %L::uuid, 'X') $$,
         pg_temp.prog('EB1'), pg_temp.cohort('EB1', 2023)),
  '23503',
  null,
  '...and so is one whose intake year contradicts it'
);

-- The same FK blocks changing a parent's pace out from under its streams —
-- which is the worst form of PHASE2_HANDOFF risk 2, closed declaratively.
select throws_ok(
  format($$ update cohorts set pace = 'trimester' where id = %L::uuid $$,
         pg_temp.cohort('EB1', 2023)),
  '23503',
  null,
  'a streamed cohort''s pace cannot be changed out from under its streams'
);


-- ============================================================================
-- §3 Shape and depth (0025 §4, §6)
-- ============================================================================
select throws_ok(
  format($$ insert into cohorts (programme_id, intake_year, current_semester, pace,
                                 parent_cohort_id, stream)
            values (%L::uuid, 2023, 5, 'bimester', %L::uuid, null) $$,
         pg_temp.prog('EB1'), pg_temp.cohort('EB1', 2023)),
  '23514',
  null,
  'a stream must name itself — a parent with no label is refused'
);

select throws_ok(
  format($$ insert into cohorts (programme_id, intake_year, current_semester, pace, stream)
            values (%L::uuid, 2023, 5, 'bimester', 'Z') $$, pg_temp.prog('EB1')),
  '23514',
  null,
  '...and a label with no parent is a stream of nothing'
);

-- STREAMS ARE THE LOWEST LEVEL. The composite FK cannot express this, because a
-- stream row is itself a perfectly valid FK target.
select throws_ok(
  format($$ insert into cohorts (programme_id, intake_year, current_semester, pace,
                                 parent_cohort_id, stream)
            values (%L::uuid, 2023, 5, 'bimester', %L::uuid, 'A1') $$,
         pg_temp.prog('EB1'), pg_temp.stream('EB1', 2023, 'A')),
  'P0001',
  format('Cohort %s is itself a stream — streams are the lowest level and cannot be subdivided',
         pg_temp.stream('EB1', 2023, 'A')),
  'a stream of a stream is refused, with a message that says why'
);

select throws_ok(
  format($$ select create_cohort_stream(%L::uuid, 'A1', %L::uuid, %L::uuid) $$,
         pg_temp.stream('EB1', 2023, 'A'), pg_temp.kevin(), pg_temp.fst_rep()),
  'P0001',
  null,
  '...and the function refuses it before the trigger has to'
);

select throws_ok(
  format($$ select create_cohort_stream(%L::uuid, 'A', %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.kevin(), pg_temp.fst_rep()),
  '23505',
  null,
  'one cohort cannot have two Stream A''s'
);


-- ============================================================================
-- §4 create_cohort_stream — inheritance, scoping, and the sitting rep
-- ============================================================================
select is(
  (select row(programme_id, intake_year, pace) from cohorts
    where id = pg_temp.stream('EB1', 2023, 'A')),
  (select row(programme_id, intake_year, pace) from cohorts
    where id = pg_temp.cohort('EB1', 2023)),
  'a stream inherits programme, intake and pace from its parent rather than taking them'
);

-- Faith was a plain student; Mercy was already the cohort's primary rep. Both
-- are legal first reps for a stream, which is where this function deliberately
-- diverges from create_cohort_with_class_rep.
select is(
  (select row(role, class_rep_rank, cohort_id) from users where id = pg_temp.faith()),
  row('class_rep'::user_role, 'primary'::class_rep_rank, pg_temp.stream('EB1', 2023, 'A')),
  'a plain student can lead a stream, and lands in it'
);

select is(
  (select row(role, class_rep_rank, cohort_id) from users where id = pg_temp.mercy()),
  row('class_rep'::user_role, 'primary'::class_rep_rank, pg_temp.stream('EB1', 2023, 'B')),
  'a SITTING class rep can lead a stream too — create_cohort_with_class_rep would refuse them'
);

select is(
  (select count(*)::int from role_audit_log
    where snapshot->>'reason' = 'stream_created'),
  2,
  'both placements are on the role audit trail, whatever the previous role'
);

select is(
  (select snapshot->>'previous_role' from role_audit_log
    where user_id = pg_temp.mercy() and snapshot->>'reason' = 'stream_created'),
  'class_rep',
  '...and the trail records that this one was already a rep, not a promotion from student'
);

-- Scoping. A stream's rep must come from the cohort being split, or stream
-- creation becomes a sideways route into another cohort's authority —
-- the hole TECHNICAL_DISCOVERY §13.4 describes.
select throws_ok(
  format($$ select create_cohort_stream(%L::uuid, 'C', %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.grace(), pg_temp.fst_rep()),
  'P0001',
  null,
  'a student from another cohort cannot be installed as a stream''s rep'
);

select pg_temp.act_as(pg_temp.fhss_rep());
select throws_ok(
  format($$ select create_cohort_stream(%L::uuid, 'C', %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.kevin(), pg_temp.fhss_rep()),
  'P0001',
  format('Cohort %s belongs to another faculty', pg_temp.cohort('EB1', 2023)),
  'a faculty rep cannot split a cohort in another faculty'
);

select pg_temp.act_as(pg_temp.samuel());
select throws_ok(
  format($$ select create_cohort_stream(%L::uuid, 'C', %L::uuid, %L::uuid) $$,
         pg_temp.cohort('EB1', 2023), pg_temp.kevin(), pg_temp.samuel()),
  'P0001',
  'Only a faculty_rep may create a stream',
  'a class rep cannot split their own cohort — this is a faculty-rep action'
);


-- ============================================================================
-- §5 The name is derived, so it cannot drift (0026 §1, §2)
-- ============================================================================
-- 0023 put pace into a name generated ONCE at creation, while 0014 lets a rep
-- change pace. So the name could end up reading '(bimester)' on a trimester
-- cohort. PHASE2_HANDOFF risk 2 demonstrates it; this is the fix.
select is(
  (select name from cohorts where id = pg_temp.cohort('EB1', 2023)),
  'BSC-CS 2023 (bimester)',
  'a cohort''s name renders its identity key'
);

select is(
  (select name from cohorts where id = pg_temp.stream('EB1', 2023, 'A')),
  'BSC-CS 2023 (bimester) Stream A',
  '...and a stream''s name says which stream it is'
);

-- The headline: change the pace, the name follows.
select pg_temp.act_as(pg_temp.samuel());
select lives_ok(
  format($$ update cohorts set pace = 'trimester' where id = %L::uuid $$,
         pg_temp.cohort('EB3', 2023)),
  'a rep may still change their cohort''s pace'
);

select is(
  (select name from cohorts where id = pg_temp.cohort('EB3', 2023)),
  'BSC-ACS 2023 (trimester)',
  '...and the name RECOMPUTES rather than keeping the pace it was born with'
);

select is(
  (select count(*)::int from cohorts where name like '%(bimester)%'
     and pace = 'trimester'),
  0,
  'no name anywhere contradicts its own row — the 0023 defect, closed'
);

-- Belt and braces (TECHNICAL_DISCOVERY §13.1): the privilege is what actually
-- stops a client renaming a cohort, checked before any trigger runs.
select ok(
  not has_column_privilege('authenticated', 'cohorts', 'name', 'UPDATE'),
  'authenticated cannot UPDATE cohorts.name at all — the grant is gone, not merely guarded'
);

select ok(
  has_column_privilege('authenticated', 'cohorts', 'pace', 'UPDATE')
  and has_column_privilege('authenticated', 'cohorts', 'current_semester', 'UPDATE'),
  '...while the two columns a rep legitimately maintains are still writable'
);

select ok(
  not has_column_privilege('authenticated', 'cohorts', 'stream', 'UPDATE')
  and not has_column_privilege('authenticated', 'cohorts', 'parent_cohort_id', 'UPDATE'),
  'and no client can re-parent a cohort or relabel a stream'
);


-- ============================================================================
-- §6 Assigning students to streams (0028 §2, §3)
-- ============================================================================
-- Splits are INCREMENTAL, so this is callable repeatedly as department lists
-- arrive. Keyed on registration number, because that is how the department's
-- own stream lists are keyed — and because it lets a student who has not signed
-- up yet be assigned in advance.
--
-- Streams A and B exist from §1: Faith reps A, Mercy reps B.
select pg_temp.act_as(pg_temp.fst_rep());

-- create_cohort_stream moved each rep's ROSTER row too, not just their
-- users.cohort_id. Without that a rep's roster row would say "parent" forever,
-- and assign_students_to_streams deliberately refuses class reps, so nothing
-- could fix it.
select is(
  (select cohort_id from student_roster where reg_number = 'EB1/67340/23'),
  pg_temp.stream('EB1', 2023, 'A'),
  'a stream rep''s roster row follows them into the stream'
);

select is(
  assign_students_to_streams(
    '[{"reg_number":"EB1/67358/23","stream":"A"},
      {"reg_number":"EB1/67401/23","stream":"B"},
      {"reg_number":"EB1/67455/23","stream":"A"}]'::jsonb,
    pg_temp.cohort('EB1', 2023), pg_temp.fst_rep()),
  3,
  'a faculty rep assigns three students across two streams in one call'
);

-- REGRESSION: the first draft built its working set with
-- `create temp table _assign on commit drop`, which works exactly ONCE per
-- transaction — a second call fails with "relation already exists", because the
-- drop waits for COMMIT. For a function whose whole design is to be called
-- repeatedly as stream lists arrive, that broke the normal case. Two successful
-- calls in one transaction is the assertion that would have caught it.
select is(
  assign_students_to_streams(
    '[{"reg_number":"EB1/67470/23","stream":"B"}]'::jsonb,
    pg_temp.cohort('EB1', 2023), pg_temp.fst_rep()),
  1,
  'a SECOND successful call in the same transaction works — splits are incremental'
);

select is(
  (select row(u.cohort_id, r.cohort_id)
     from users u join student_roster r on r.claimed_by = u.id
    where u.id = pg_temp.kevin()),
  row(pg_temp.stream('EB1', 2023, 'A'), pg_temp.stream('EB1', 2023, 'A')),
  'a claimed student moves in BOTH places — their account and their roster row'
);

-- Lydia has not signed up. Her roster row still moves, which is the point of
-- keying on registration number: claim_roster_row will place her straight into
-- Stream A whenever she does.
select is(
  (select row(cohort_id, claimed_by is null) from student_roster
    where reg_number = 'EB1/67455/23'),
  row(pg_temp.stream('EB1', 2023, 'A'), true),
  'an UNCLAIMED roster row moves too — the student lands in the stream when they claim'
);

select is(
  (select row(snapshot->>'stream', (snapshot->>'was_claimed')::boolean)
     from roster_audit_log
    where reg_number = 'EB1/67358/23' and action = 'reassigned'),
  row('A'::text, true),
  'every move writes a ''reassigned'' audit row — 0.5''s rule for re-pointing claimed identities'
);

select is(
  (select (snapshot->>'from_cohort_id')::uuid from roster_audit_log
    where reg_number = 'EB1/67455/23' and action = 'reassigned'),
  pg_temp.cohort('EB1', 2023),
  '...recording where they came from, not just where they went'
);

-- --- Refusals ---------------------------------------------------------------
select throws_like(
  format($$ select assign_students_to_streams(
    '[{"reg_number":"EB1/67488/23","stream":"Q"}]'::jsonb, %L::uuid, %L::uuid) $$,
    pg_temp.cohort('EB1', 2023), pg_temp.fst_rep()),
  '%has no stream Q%',
  'assigning to a stream that does not exist is refused, and says which'
);

select throws_like(
  format($$ select assign_students_to_streams(
    '[{"reg_number":"EB9/99999/23","stream":"A"}]'::jsonb, %L::uuid, %L::uuid) $$,
    pg_temp.cohort('EB1', 2023), pg_temp.fst_rep()),
  '%not on the roster%',
  'a registration number nobody has rostered is refused'
);

select throws_like(
  format($$ select assign_students_to_streams(
    '[{"reg_number":"EB1/67488/23","stream":"A"},
      {"reg_number":"EB1/67488/23","stream":"B"}]'::jsonb, %L::uuid, %L::uuid) $$,
    pg_temp.cohort('EB1', 2023), pg_temp.fst_rep()),
  '%more than once%',
  'the same student listed twice has no defensible resolution, so it is refused'
);

-- Brian is BSC-CS 2023's assistant rep. Moving a rep in bulk could collide with
-- users_one_primary_per_cohort and would change who holds scheduling authority
-- as a side effect of a roster batch.
select throws_like(
  format($$ select assign_students_to_streams(
    '[{"reg_number":"EB1/67312/23","stream":"A"}]'::jsonb, %L::uuid, %L::uuid) $$,
    pg_temp.cohort('EB1', 2023), pg_temp.fst_rep()),
  '%class rep%',
  'a class rep cannot be moved by a bulk assignment — that goes through create_cohort_stream'
);

select pg_temp.act_as(pg_temp.samuel());
select throws_like(
  format($$ select assign_students_to_streams(
    '[{"reg_number":"EB1/67488/23","stream":"A"}]'::jsonb, %L::uuid, %L::uuid) $$,
    pg_temp.cohort('EB1', 2023), pg_temp.samuel()),
  '%Only a faculty_rep%',
  'a class rep cannot assign students to streams at all'
);

select pg_temp.act_as(pg_temp.fhss_rep());
select throws_like(
  format($$ select assign_students_to_streams(
    '[{"reg_number":"EB1/67488/23","stream":"A"}]'::jsonb, %L::uuid, %L::uuid) $$,
    pg_temp.cohort('EB1', 2023), pg_temp.fhss_rep()),
  '%another faculty%',
  '...and a faculty rep cannot reach into another faculty'
);

-- --- Who is left ------------------------------------------------------------
-- "The parent has no students" can never be a durable invariant, so
-- incompleteness is SURFACED rather than forbidden.
--
-- One of the three is the FST faculty rep, and that is correct rather than a
-- leak: a faculty rep is a student (TECHNICAL_DISCOVERY §10), belongs to a
-- cohort, and therefore needs assigning to a stream like anyone else. Their
-- faculty-wide authority is `faculty_id` and has nothing to do with which
-- lecture group they sit in.
select pg_temp.act_as(pg_temp.fst_rep());
select is(
  (select count(*)::int from cohort_unstreamed_members(pg_temp.cohort('EB1', 2023))),
  3,
  'the students nobody assigned are still visible rather than silently stranded'
);

select is(
  (select count(*)::int from cohort_unstreamed_members(pg_temp.cohort('EB1', 2023))
    where not claimed),
  1,
  '...including unclaimed rows, which are exactly the ones nobody would otherwise notice'
);

select is(
  (select count(*)::int from cohort_unstreamed_members(pg_temp.cohort('BA2', 2024))),
  0,
  'a cohort that was never split has nobody unstreamed, rather than everybody'
);


-- ============================================================================
-- §7 A pace collision explains itself (0026 §5)
-- ============================================================================
-- (programme, intake, pace) is the identity key, so flipping pace onto an
-- existing twin collides. Without the guard the rep gets a raw 23505 naming an
-- internal index.
-- Give BSC-CS 2024 (trimester) a bimester twin, so Dennis's cohort now has
-- something to collide with. Note this is legal and expected — pace is part of
-- the identity key precisely so both can exist (it is also what makes the
-- branching workaround in "Explicitly not doing" work).
select pg_temp.act_as(pg_temp.fst_rep());
select create_cohort_with_class_rep(
  pg_temp.prog('EB1'), 2024, 5, 'bimester', pg_temp.kevin(), pg_temp.fst_rep());

-- Dennis reps the trimester one. Referenced through his own row rather than
-- pg_temp.cohort(), which is deliberately ambiguous now that two top-level
-- EB1/2024 cohorts exist — the very situation being tested.
select pg_temp.act_as(pg_temp.dennis());
set local role authenticated;
select throws_like(
  format($$ update cohorts set pace = 'bimester'
            where id = (select cohort_id from users where id = %L::uuid) $$,
         pg_temp.dennis()),
  '%already exists for this programme and intake year%',
  'a colliding pace change is explained in a sentence, not a raw constraint name'
);
reset role;


select * from finish();
rollback;
