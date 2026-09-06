-- ============================================================================
-- 0028: Splitting a cohort — the precondition, and assigning students
-- ============================================================================
-- Phase S part 3. TODO §S.5.
--
-- THE GAP THIS CLOSES: there is no function today that moves a roster row
-- between cohorts. roster_correct_student does not take a cohort_id at all — it
-- only fixes names and registration numbers — and it refuses claimed rows
-- outright, on the grounds that touching a claimed identity is a dispute rather
-- than a correction. So splitting a cohort was not expressible by any existing
-- API, however many streams 0026 could create.
--
-- Contents
--   §1  create_cohort_stream       — refuses to split a cohort with a timetable
--   §2  assign_students_to_streams — the move, with its audit trail
--   §3  cohort_unstreamed_members  — who has NOT been assigned yet
--   §4  Grants
--
-- WHY THIS IS TWO FUNCTIONS AND NOT ONE `split_cohort_into_streams`. Splits are
-- INCREMENTAL: department stream lists arrive in pieces, and a faculty rep
-- blocked until the complete list exists will do it out-of-band instead. So
-- creating a stream (0026 §4) and populating it (§2 here) are separate acts,
-- and §2 can be called as many times as lists arrive.
--
-- That also means "the parent has no students" is NOT a durable invariant and
-- must not be enforced as one: a student claiming a roster row that still
-- points at the parent lands in the parent, and a faculty rep can write new
-- roster rows against it at any time. "Exhaustive" could only ever mean
-- "exhaustive at the instant the function ran". §3 exists because the answer to
-- that is VISIBILITY, not a constraint.
-- ============================================================================


-- ============================================================================
-- 1. A cohort with a live timetable cannot be split
-- ============================================================================
-- THE DECISION THIS ENCODES, because it is the least obvious part of Phase S:
-- when a cohort is split, its existing events are NOT migrated to the streams.
-- Not because migrating is hard, but because it is WRONG.
--
-- Streams exist precisely because one room cannot hold the intake. So after a
-- split, Stream A's and Stream B's lectures are different events — different
-- rooms, usually different times. Re-attaching one event to both streams would
-- put both groups in one room at one hour, which is exactly what the split
-- existed to prevent.
--
-- AND NEITHER EXCLUDE CONSTRAINT WOULD CATCH IT. events_no_venue_overlap is on
-- events(venue_id, tstzrange) — a single row has nothing to self-overlap.
-- event_cohorts_no_self_overlap is on event_cohorts(cohort_id, tstzrange) — the
-- two streams are different cohort_ids, so they do not conflict. The schema
-- would accept it silently, because "two cohorts, one room, one time" is
-- exactly what a legitimate combined lecture looks like. It is only illegitimate
-- when the two cohorts exist BECAUSE the room cannot hold them both. That error
-- surfaces as an overfull lecture hall weeks later, not as a constraint
-- violation.
--
-- There is also no bulk answer even in principle: streams rejoin for combined
-- sessions regularly, so after a split some lectures stay whole-cohort and some
-- divide — a per-lecture judgement about room capacity and unit that no bulk
-- function can make.
--
-- So the assumption becomes a precondition. Refusing degrades to manual work
-- (cancel, split, re-enter per stream) which is annoying, recoverable, and
-- fully expressible with today's API. Guessing at a migration degrades to
-- subtly wrong data.
--
-- ONLY FUTURE EVENTS BLOCK. Past lectures legitimately belong to the parent —
-- the whole cohort really did attend them, and that is the historically
-- accurate record. A mid-semester split stays possible as long as the rep has
-- not entered the rest of the term yet. It also means adding Stream C to an
-- already-split cohort works: by then the parent's students have moved, so it
-- has no upcoming lectures of its own.
--
-- The escape hatch lives in the error message, where it cannot rot the way a
-- comment can.
--
-- `set search_path = public` restated — CREATE OR REPLACE discards proconfig
-- (TECHNICAL_DISCOVERY §12). Everything else is preserved from 0026 §4.
create or replace function create_cohort_stream(
  p_parent_cohort_id   uuid,
  p_stream             text,
  p_first_rep_id       uuid,
  p_acting_faculty_rep uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role     user_role;
  v_actor_faculty  uuid;
  v_parent         record;
  v_parent_faculty uuid;
  v_stream         text;
  v_rep_role       user_role;
  v_rep_cohort     uuid;
  v_rep_name       text;
  v_stream_id      uuid;
  v_upcoming       int;
  v_rep_roster_id  uuid;
begin
  if p_acting_faculty_rep is distinct from auth.uid() then
    raise exception 'p_acting_faculty_rep must match the calling user';
  end if;

  select role, faculty_id into v_actor_role, v_actor_faculty
  from users where id = p_acting_faculty_rep;

  if v_actor_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may create a stream';
  end if;

  if v_actor_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot create streams';
  end if;

  select c.id, c.programme_id, c.intake_year, c.current_semester, c.pace,
         c.parent_cohort_id
  into v_parent
  from cohorts c
  where c.id = p_parent_cohort_id;

  if v_parent.id is null then
    raise exception 'Cohort % does not exist', p_parent_cohort_id;
  end if;

  if v_parent.parent_cohort_id is not null then
    raise exception
      'Cohort % is itself a stream — streams are the lowest level and cannot be subdivided',
      p_parent_cohort_id;
  end if;

  select d.faculty_id into v_parent_faculty
  from programmes p
  join departments d on d.id = p.department_id
  where p.id = v_parent.programme_id;

  if v_parent_faculty is distinct from v_actor_faculty then
    raise exception 'Cohort % belongs to another faculty', p_parent_cohort_id;
  end if;

  -- --- The precondition ----------------------------------------------------
  select count(*)::int into v_upcoming
  from event_cohorts ec
  join events e on e.id = ec.event_id
  where ec.cohort_id = p_parent_cohort_id
    and e.status in ('scheduled', 'proposed')
    and e.start_time > now();

  if v_upcoming > 0 then
    raise exception
      'Cohort % has % upcoming lecture(s). Split it before its schedule is '
      'entered, or cancel those lectures first — a split does not move them, '
      'because each stream needs its own room and time.',
      p_parent_cohort_id, v_upcoming;
  end if;

  v_stream := nullif(btrim(coalesce(p_stream, '')), '');
  if v_stream is null then
    raise exception 'A stream needs a label (''A'', ''B'', ...)';
  end if;

  select u.role, u.cohort_id, u.first_name || ' ' || u.last_name
  into v_rep_role, v_rep_cohort, v_rep_name
  from users u where u.id = p_first_rep_id;

  if v_rep_role is null then
    raise exception 'User % not found — cannot make them this stream''s class rep',
      p_first_rep_id;
  end if;

  if v_rep_cohort is distinct from p_parent_cohort_id then
    raise exception
      'User % is not in cohort % — a stream''s first rep must come from the cohort being split',
      p_first_rep_id, p_parent_cohort_id;
  end if;

  if v_rep_role not in ('student', 'class_rep') then
    raise exception
      'User % is a % — only a student or a sitting class_rep of this cohort can lead a stream',
      p_first_rep_id, v_rep_role;
  end if;

  insert into cohorts (
    programme_id, intake_year, current_semester, pace, parent_cohort_id, stream
  )
  values (
    v_parent.programme_id, v_parent.intake_year, v_parent.current_semester,
    v_parent.pace, p_parent_cohort_id, v_stream
  )
  returning id into v_stream_id;

  update users
  set cohort_id = v_stream_id,
      role = 'class_rep',
      class_rep_rank = 'primary'
  where id = p_first_rep_id;

  -- THE REP'S ROSTER ROW FOLLOWS THEM. S.3's rule is that the roster points at
  -- the cohort a student is actually in, and a rep is no exception. Without
  -- this their roster row would say "parent" forever while they rep a stream —
  -- and there would be no way to correct it, because §2 deliberately refuses to
  -- move class reps in bulk. So the only function that may move a rep has to
  -- move both halves.
  update student_roster
  set cohort_id = v_stream_id
  where claimed_by = p_first_rep_id
  returning id into v_rep_roster_id;

  if v_rep_roster_id is not null then
    insert into roster_audit_log (
      roster_id, reg_number, action, actor_id, target_user, snapshot
    )
    select v_rep_roster_id, r.reg_number, 'reassigned', p_acting_faculty_rep, p_first_rep_id,
           jsonb_build_object(
             'from_cohort_id', p_parent_cohort_id,
             'to_cohort_id',   v_stream_id,
             'stream',         v_stream,
             'was_claimed',    true,
             'reason',         'stream_created'
           )
    from student_roster r where r.id = v_rep_roster_id;
  end if;

  insert into role_audit_log (
    user_id, user_name, cohort_id, action, new_rank, actor_id, snapshot
  )
  values (
    p_first_rep_id, v_rep_name, v_stream_id, 'promoted', 'primary',
    p_acting_faculty_rep,
    jsonb_build_object(
      'previous_role',   v_rep_role,
      'previous_cohort', p_parent_cohort_id,
      'stream',          v_stream,
      'reason',          'stream_created'
    )
  );

  return v_stream_id;
end;
$$;


-- ============================================================================
-- 2. assign_students_to_streams
-- ============================================================================
-- Argument order and return type mirror roster_bulk_import(p_rows, p_cohort_id,
-- p_acting_user) returns int, because this is the same shape of operation: a
-- bulk roster write scoped to one cohort, performed by a faculty rep.
--
-- KEYED ON REGISTRATION NUMBER, not user id. The department's own stream lists
-- are keyed that way, and it means a student who has not signed up yet can
-- still be assigned — their roster row moves now and `claim_roster_row` will
-- place them straight into the right stream when they eventually claim. That is
-- the whole reason S.3 has the roster point at the student's real cohort rather
-- than permanently at the parent.
--
-- FACULTY REP ONLY. A class rep must not re-point roster rows in bulk — the
-- same reasoning that made roster_bulk_import faculty-rep-only in 0.5, so the
-- higher role performs the operation rather than reviewing it afterwards.
create function assign_students_to_streams(
  p_assignments      jsonb,   -- [{"reg_number": "EB1/67312/23", "stream": "A"}, ...]
  p_parent_cohort_id uuid,
  p_acting_user      uuid
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role    user_role;
  v_actor_faculty uuid;
  v_parent        record;
  v_parent_faculty uuid;
  v_count         int := 0;
  v_distinct      int;
  v_total         int;
  v_bad           int;
  v_row           record;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, faculty_id into v_actor_role, v_actor_faculty
  from users where id = p_acting_user;

  if v_actor_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may assign students to streams';
  end if;

  if v_actor_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot assign students';
  end if;

  select c.id, c.programme_id, c.parent_cohort_id into v_parent
  from cohorts c where c.id = p_parent_cohort_id;

  if v_parent.id is null then
    raise exception 'Cohort % does not exist', p_parent_cohort_id;
  end if;

  if v_parent.parent_cohort_id is not null then
    raise exception
      'Cohort % is a stream. Assign students against the cohort being split, not one of its streams',
      p_parent_cohort_id;
  end if;

  select d.faculty_id into v_parent_faculty
  from programmes p
  join departments d on d.id = p.department_id
  where p.id = v_parent.programme_id;

  if v_parent_faculty is distinct from v_actor_faculty then
    raise exception 'Cohort % belongs to another faculty', p_parent_cohort_id;
  end if;

  if p_assignments is null or jsonb_typeof(p_assignments) is distinct from 'array' then
    raise exception
      'p_assignments must be a JSON array of {"reg_number": ..., "stream": ...} objects';
  end if;

  -- --- Normalize and sanity-check the batch --------------------------------
  -- A CTE rather than a temp table, deliberately. `create temp table _assign on
  -- commit drop` works exactly once per transaction: the second call in the
  -- same transaction fails with "relation already exists", because the drop
  -- does not happen until COMMIT. Since splits are incremental and a caller is
  -- expected to run this repeatedly as lists arrive — and since the whole test
  -- suite runs inside one transaction — that would have broken the normal case.
  select count(*)::int,
         count(distinct reg_number)::int,
         count(*) filter (where reg_number is null or stream is null)::int
  into v_total, v_distinct, v_bad
  from (
    select normalize_reg_number(a ->> 'reg_number') as reg_number,
           nullif(btrim(coalesce(a ->> 'stream', '')), '') as stream
    from jsonb_array_elements(p_assignments) a
  ) t;

  if v_total = 0 then
    raise exception 'p_assignments is empty — nothing to assign';
  end if;

  if v_bad > 0 then
    raise exception 'Every assignment needs both a reg_number and a stream';
  end if;

  -- A registration number listed twice, possibly against two different streams,
  -- has no defensible resolution — and silently taking either would put a
  -- student in a lecture group nobody chose for them.
  if v_distinct <> v_total then
    raise exception
      'A registration number appears more than once in p_assignments — each student belongs to exactly one stream';
  end if;

  -- --- Move ----------------------------------------------------------------
  for v_row in
    select a.reg_number,
           a.stream,
           s.id  as stream_id,
           r.id  as roster_id,
           r.cohort_id  as from_cohort_id,
           r.claimed_by
    from (
           select normalize_reg_number(x ->> 'reg_number') as reg_number,
                  nullif(btrim(coalesce(x ->> 'stream', '')), '') as stream
           from jsonb_array_elements(p_assignments) x
         ) a
    left join cohorts s
           on s.parent_cohort_id = p_parent_cohort_id and s.stream = a.stream
    left join student_roster r
           on r.reg_number = a.reg_number
  loop
    if v_row.stream_id is null then
      raise exception
        'Cohort % has no stream %. Create it with create_cohort_stream first',
        p_parent_cohort_id, v_row.stream;
    end if;

    if v_row.roster_id is null then
      raise exception 'Registration number % is not on the roster', v_row.reg_number;
    end if;

    -- The row must already belong to this cohort, or to one of its streams (so
    -- a student can be moved from Stream A to Stream B). Anything else would be
    -- reaching into another cohort's roster through a stream assignment, which
    -- is the sideways-authority shape TECHNICAL_DISCOVERY §13.4 warns about.
    if v_row.from_cohort_id is distinct from p_parent_cohort_id
       and not exists (
         select 1 from cohorts c
         where c.id = v_row.from_cohort_id
           and c.parent_cohort_id = p_parent_cohort_id
       )
    then
      raise exception
        'Registration number % does not belong to cohort % or any of its streams',
        v_row.reg_number, p_parent_cohort_id;
    end if;

    -- A class rep's placement is set by create_cohort_stream, promote_class_rep
    -- and demote_class_rep, never here. Moving one in bulk could silently
    -- collide with users_one_primary_per_cohort, and would change who holds
    -- scheduling authority over a stream as a side effect of a roster batch.
    if v_row.claimed_by is not null
       and (select role from users where id = v_row.claimed_by) = 'class_rep' then
      raise exception
        'Registration number % belongs to a class rep. Move a rep with '
        'create_cohort_stream or demote them first — not through a bulk assignment',
        v_row.reg_number;
    end if;

    update student_roster
    set cohort_id = v_row.stream_id
    where id = v_row.roster_id;

    -- Only if they have actually claimed. An unclaimed row still moves — that
    -- is the point of keying on registration number — and claim_roster_row will
    -- place them into the stream when they sign up.
    if v_row.claimed_by is not null then
      update users set cohort_id = v_row.stream_id where id = v_row.claimed_by;
    end if;

    insert into roster_audit_log (
      roster_id, reg_number, action, actor_id, target_user, snapshot
    )
    values (
      v_row.roster_id, v_row.reg_number, 'reassigned', p_acting_user, v_row.claimed_by,
      jsonb_build_object(
        'from_cohort_id', v_row.from_cohort_id,
        'to_cohort_id',   v_row.stream_id,
        'stream',         v_row.stream,
        'was_claimed',    (v_row.claimed_by is not null),
        'reason',         'stream_assignment'
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function assign_students_to_streams(jsonb, uuid, uuid) is
  'Moves named students, and their roster rows, into streams of the given '
  'cohort. Faculty rep, own faculty only. Keyed on registration number so a '
  'student who has not signed up yet can still be assigned. Safe to call '
  'repeatedly as stream lists arrive — splits are incremental by design.';


-- ============================================================================
-- 3. Who has NOT been assigned yet
-- ============================================================================
-- The other half of the incremental decision. Because "the parent has no
-- students" can never be a durable invariant, incompleteness is surfaced rather
-- than forbidden — and a student stranded in the parent, seeing an empty
-- timetable once the streams hold the lectures, is a VISIBILITY problem.
--
-- Returns roster rows still pointing at the cohort itself rather than at one of
-- its streams. Includes unclaimed rows deliberately: a student who has not
-- signed up yet still needs assigning, and is exactly the one nobody would
-- otherwise notice.
create function cohort_unstreamed_members(p_cohort_id uuid)
returns table (
  reg_number text,
  full_name  text,
  claimed    boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select r.reg_number,
         r.first_name || ' ' || coalesce(r.middle_name || ' ', '') || r.last_name,
         r.claimed_by is not null
  from student_roster r
  where r.cohort_id = p_cohort_id
    and exists (select 1 from cohorts c
                where c.parent_cohort_id = p_cohort_id)
  order by r.reg_number;
$$;

comment on function cohort_unstreamed_members(uuid) is
  'Roster rows still sitting on a cohort that has streams — i.e. students who '
  'have not been assigned to one yet. Empty for a cohort that was never split.';


-- ============================================================================
-- 4. Grants
-- ============================================================================
-- REVOKE FROM PUBLIC FIRST. CREATE FUNCTION implicitly grants EXECUTE to
-- PUBLIC, so revoking from `anon` alone is a no-op — the mistake 0008/0010/
-- 0012/0013 all made and 0014 §3 had to undo.
--
-- cohort_unstreamed_members is SECURITY DEFINER because it reads
-- student_roster, which students cannot read at all (0.5: it would be a
-- directory of exactly the name+number pairs needed to attack the claim flow).
-- The definer wrapper is what lets a rep see their own cohort's stragglers
-- without opening the table. Granted to authenticated because a class rep of a
-- streamed cohort legitimately needs to chase them.
revoke execute on function assign_students_to_streams(jsonb, uuid, uuid) from public, anon;
grant  execute on function assign_students_to_streams(jsonb, uuid, uuid) to authenticated, service_role;

revoke execute on function cohort_unstreamed_members(uuid) from public, anon;
grant  execute on function cohort_unstreamed_members(uuid) to authenticated, service_role;
