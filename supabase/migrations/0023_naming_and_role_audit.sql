-- ============================================================================
-- 0023: Cohort naming, role audit, and letting go of two dead columns
-- ============================================================================
-- Phase 2 part 1 of 2. TODO §2.2, §2.7 and half of §2.8.
--
-- THIS FILE CHANGES ONE PIECE OF STRUCTURE, AND ONLY TO LOOSEN IT. That is the
-- point of splitting Phase 2 in two. 0024 drops events.recurrence_rule and
-- cohorts.join_code, and three live functions still reference them:
--
--   create_cohort_with_class_rep  writes join_code
--   guard_cohorts_rep_update      names join_code as a protected column
--   reschedule_event              copies recurrence_rule onto the replacement
--
-- A function referencing a dropped column raises at RUNTIME, not at migration
-- time — so doing it the other way round applies perfectly cleanly and then
-- dies on the first seed run. 0021's header says it, 0022's §6 was ordered
-- around it, and it is worth repeating a third time: STRUCTURE CANNOT OUTRUN
-- ITS WRITER. The writers stop referencing the columns here; 0024 drops them.
--
-- Contents
--   §0  cohorts.join_code            — deprecated: NOT NULL dropped
--   §1  create_cohort_with_class_rep — the name gains pace; stops writing join_code
--   §2  guard_cohorts_rep_update     — join_code leaves the protected list
--   §3  reschedule_event             — stops copying recurrence_rule
--   §4  demote_class_rep             — writes role_audit_log
--
-- Every function below is CREATE OR REPLACE, which preserves the ACL 0014 §3
-- granted, so there is no grants section. But every one of them MUST restate
-- `set search_path = public` — see the note on §1.
-- ============================================================================


-- ============================================================================
-- 0. Deprecate cohorts.join_code
-- ============================================================================
-- `join_code text not null unique` (0001). NOT NULL is why §1 cannot simply
-- stop writing it: omitting a NOT NULL column from an INSERT fails immediately,
-- so "stop writing this column" is not a pure behaviour change when the column
-- is NOT NULL. It needs structure to move first — but only to LOOSEN, never to
-- tighten, which is the safe direction.
--
-- This is precisely the dance 0021 §3 did for events.course_id: deprecate and
-- make nullable, let the next migration stop writing it, then drop it. Same
-- three steps, same reason, one phase later.
--
-- The unique constraint is left in place. It costs nothing on a column nobody
-- writes any more, and 0024 takes it away with the column.
alter table cohorts alter column join_code drop not null;

comment on column cohorts.join_code is
  'DEPRECATED as of 0023, dropped in 0024. Superseded by the roster (TODO 0.5): '
  'a join code is a shared secret anyone in the room can use on anyone''s '
  'behalf, while a roster row is per-person and pins the cohort already. '
  'No longer written by create_cohort_with_class_rep.';


-- ============================================================================
-- 1. create_cohort_with_class_rep
-- ============================================================================
-- TODO §2.2. The name is built as `abbreviation || ' ' || intake_year`, so
-- BSC-CS 2023 bimester and BSC-CS 2023 trimester — two genuinely different
-- cohorts, both legal, both expected to exist (§4's whole pace mechanic is that
-- self-sponsored students run faster through the same programme) — get
-- BYTE-IDENTICAL names. A rep picking their cohort from a list cannot tell them
-- apart, and neither can anyone reading a log line.
--
-- Adding `pace` fixes it, and pace is the RIGHT discriminator because it is
-- immutable for the life of the cohort.
--
-- DO NOT ADD current_semester. It is the obvious other candidate and it is
-- wrong for the same reason it is wrong in 0024 §1's identity key: a cohort
-- advances through semesters. 0014 grants column-level UPDATE on
-- current_semester to authenticated precisely so a class rep can advance it. A
-- name embedding it is stale the moment they do — the exact staleness 0021
-- rejected stored semester dates to avoid.
--
-- The stored name is display convenience, not an identifier. programme_id,
-- intake_year and pace are all columns on the row, so a client wanting
-- something terser can compose its own; nothing in this schema reads the name
-- to make a decision, and after this migration nothing in seed.sql or the test
-- suite looks a cohort up by it either.
--
-- RESTATING `set search_path = public` IS MANDATORY. CREATE OR REPLACE discards
-- proconfig, so replacing the body of a SECURITY DEFINER function that 0008
-- pinned silently un-pins it and reopens the privilege-escalation vector 0008
-- existed to close. This bit handle_new_auth_user in 0019 and
-- 00_access_control_test.sql caught it. It applies to all four functions here.
create or replace function create_cohort_with_class_rep(
  p_programme_id     uuid,
  p_intake_year      int,
  p_current_semester int,
  p_pace             cohort_pace,
  p_first_rep_id     uuid,
  p_created_by       uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_programme_abbr    text;
  v_cohort_id         uuid;
  v_creator_role      user_role;
  v_creator_faculty   uuid;
  v_programme_faculty uuid;
  v_rep_role          user_role;
begin
  if p_created_by is distinct from auth.uid() then
    raise exception 'p_created_by must match the calling user';
  end if;

  select role, faculty_id into v_creator_role, v_creator_faculty
  from users where id = p_created_by;

  if v_creator_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may create a cohort';
  end if;

  if v_creator_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot create cohorts';
  end if;

  select p.abbreviation, d.faculty_id
  into v_programme_abbr, v_programme_faculty
  from programmes p
  join departments d on d.id = p.department_id
  where p.id = p_programme_id;

  if v_programme_abbr is null then
    raise exception 'Programme % not found', p_programme_id;
  end if;

  if v_programme_faculty is distinct from v_creator_faculty then
    raise exception 'Programme % belongs to another faculty', p_programme_id;
  end if;

  -- The first rep must be a plain student. Previously p_first_rep_id was
  -- unvalidated: a non-existent id left the UPDATE matching zero rows and
  -- returned a cohort with NO class rep — silently breaking the invariant
  -- this function exists to uphold ("a cohort with no rep has no real-world
  -- meaning") — and a faculty_rep id would have been demoted into a class rep.
  --
  -- NOT checked: that the student's registration number actually belongs to
  -- p_programme_id. Reg numbers are parsed client-side and the Faculty Rep is
  -- promoting someone whose election they personally witnessed, so the
  -- real-world check has already happened by the time this is called.
  select role into v_rep_role from users where id = p_first_rep_id;

  if v_rep_role is null then
    raise exception 'User % not found — cannot promote them to class rep', p_first_rep_id;
  end if;

  if v_rep_role is distinct from 'student' then
    raise exception
      'User % is a % — only a student can be promoted to a new cohort''s first class rep',
      p_first_rep_id, v_rep_role;
  end if;

  -- join_code is deliberately absent from this INSERT. §0 above just dropped
  -- its NOT NULL, which is what makes omitting it legal; new cohorts get a null
  -- one for the one migration this column has left to live.
  insert into cohorts (programme_id, name, intake_year, current_semester, pace)
  values (
    p_programme_id,
    v_programme_abbr || ' ' || p_intake_year || ' (' || p_pace::text || ')',
    p_intake_year,
    p_current_semester,
    p_pace
  )
  returning id into v_cohort_id;

  update users
  set cohort_id = v_cohort_id,
      role = 'class_rep',
      class_rep_rank = 'primary'
  where id = p_first_rep_id;

  return v_cohort_id;
end;
$$;

comment on function create_cohort_with_class_rep(uuid, int, int, cohort_pace, uuid, uuid) is
  'Creates a cohort and promotes its first class rep, atomically. Faculty rep, '
  'own faculty only; the first rep must be a plain student. The generated name '
  'is `abbreviation intake_year (pace)`, which is unique because '
  '(programme, intake_year, pace) is unique — see 0024 §1.';


-- ============================================================================
-- 2. guard_cohorts_rep_update
-- ============================================================================
-- join_code leaves the protected-column list, because in 0024 there is no such
-- column to protect. Everything else about the guard is unchanged: a class rep
-- may still only touch current_semester, pace and name on their own cohort.
--
-- Note this function is NOT security definer, deliberately — 0014 §13.3 keeps
-- the `current_user in ('authenticated','anon')` test inline in each guard
-- precisely because they run as the invoker, and factoring it into a shared
-- helper would need an EXECUTE grant that 0014 spends its whole length taking
-- away. It still carries `set search_path = public`, so it still has to restate
-- it here.
create or replace function guard_cohorts_rep_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return NEW;
  end if;

  if NEW.id           is distinct from OLD.id
  or NEW.programme_id is distinct from OLD.programme_id
  or NEW.intake_year  is distinct from OLD.intake_year
  or NEW.created_at   is distinct from OLD.created_at
  then
    raise exception
      'A class rep may only update current_semester, pace and name on their '
      'own cohort'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_cohorts_rep_update() from public, anon, authenticated;


-- ============================================================================
-- 3. reschedule_event
-- ============================================================================
-- Stops copying v_old.recurrence_rule onto the replacement row, so 0024 can
-- drop the column.
--
-- recurrence_rule was never anything but dead text. 0004's own inline comment
-- called it "display metadata only", 0022 removed it from create_event's
-- parameter list when occurrences started being materialized from the enum plus
-- a horizon, and this line — copying null from one row to the next — is the
-- last thing in the schema that mentions it. There are zero non-null values in
-- the column.
--
-- EVERYTHING ELSE IS PRESERVED BYTE-FOR-BYTE from 0022 §6, which in turn
-- preserved 0015 §3. In particular:
--   * 0013's ordering fix — the old occurrence is retired BEFORE the
--     replacement is inserted, so the two do not collide on the partial EXCLUDE
--     indexes;
--   * 0022's per-attachment course_id carry-over, so a rescheduled combined
--     lecture keeps every cohort seeing its own unit;
--   * recurrence_group_id carried onto the replacement, which is what makes
--     cancel_recurrence_group reach a moved occurrence (TODO §0.1.4).
--
-- This is the fourth restatement of this function. Resist tidying anything
-- else while you are in here; each of the three things above was a bug fix that
-- looked like an oddity to someone passing through.
create or replace function reschedule_event(
  p_event_id      uuid,
  p_new_start     timestamptz,
  p_new_end       timestamptz,
  p_new_venue_id  uuid,
  p_acting_user   uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old        events%rowtype;
  v_new_id     uuid;
  v_cohort_ids uuid[];
  v_initiator_cohort_id uuid;
  v_new_status event_status;
  v_cid        uuid;
  v_att        record;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_old from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  if v_old.status not in ('proposed', 'scheduled') then
    raise exception 'Event % is % and cannot be rescheduled', p_event_id, v_old.status;
  end if;

  select cohort_id into v_initiator_cohort_id
  from event_cohorts where event_id = p_event_id and is_initiator = true;

  if not exists (
    select 1 from users u
    where u.id = auth.uid() and u.role = 'class_rep' and u.cohort_id = v_initiator_cohort_id
  ) then
    raise exception 'Only the initiating cohort''s class_rep may reschedule this event';
  end if;

  select array_agg(cohort_id) into v_cohort_ids
  from event_cohorts where event_id = p_event_id and confirmation_status not in ('declined', 'left');

  if v_cohort_ids is null or array_length(v_cohort_ids, 1) is null then
    raise exception 'Event % has no participating cohorts left to reschedule', p_event_id;
  end if;

  v_new_status := case
    when array_length(v_cohort_ids, 1) > 1 then 'proposed'
    else 'scheduled'
  end;

  update events
  set status = 'rescheduled', updated_by = p_acting_user, updated_at = now()
  where id = p_event_id;

  -- recurrence_group_id is carried over deliberately: a rescheduled occurrence
  -- STAYS IN ITS SERIES (TODO §0.1.4), which is what makes
  -- cancel_recurrence_group reach it.
  insert into events (
    title, venue_id, lecturer_name, start_time, end_time,
    recurrence, recurrence_group_id,
    status, attendance_status, created_by, updated_by
  )
  values (
    v_old.title, p_new_venue_id, v_old.lecturer_name,
    p_new_start, p_new_end, v_old.recurrence, v_old.recurrence_group_id,
    v_new_status, 'pending', p_acting_user, p_acting_user
  )
  returning id into v_new_id;

  -- Attendance deliberately resets to 'pending' on the replacement (it is
  -- inserted with 'pending' above): a lecturer who confirmed they were coming
  -- at 10:00 has not confirmed they are coming at 14:00, and carrying the badge
  -- across would assert a phone call nobody made.

  for v_att in
    select cohort_id, course_id
    from event_cohorts
    where event_id = p_event_id and confirmation_status not in ('declined', 'left')
  loop
    insert into event_cohorts (
      event_id, cohort_id, course_id, is_initiator, confirmation_status,
      decided_by, decided_at, start_time, end_time, event_status_cache
    )
    values (
      v_new_id, v_att.cohort_id, v_att.course_id,
      (v_att.cohort_id = v_initiator_cohort_id),
      (case when v_att.cohort_id = v_initiator_cohort_id then 'confirmed' else 'pending' end
        )::cohort_confirmation_status,
      case when v_att.cohort_id = v_initiator_cohort_id then p_acting_user else null end,
      case when v_att.cohort_id = v_initiator_cohort_id then now() else null end,
      p_new_start, p_new_end, v_new_status
    );
  end loop;

  update events
  set superseded_by = v_new_id
  where id = p_event_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (p_event_id, 'rescheduled', p_acting_user, jsonb_build_object('superseded_by', v_new_id));

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (v_new_id, 'created', p_acting_user, jsonb_build_object('rescheduled_from', p_event_id));

  foreach v_cid in array v_cohort_ids loop
    perform notify_cohort_members(
      v_cid, p_event_id, 'rescheduled',
      'Lecture rescheduled', 'A lecture on your schedule has been moved to a new time.'
    );
    if v_new_status = 'proposed' and v_cid != v_initiator_cohort_id then
      perform notify_cohort_members(
        v_cid, v_new_id, 'cohort_confirmation_needed',
        'Reconfirmation needed', 'A combined lecture involving your cohort was rescheduled and needs reconfirmation.',
        'class_rep'
      );
    end if;
  end loop;

  return v_new_id;
end;
$$;


-- ============================================================================
-- 4. demote_class_rep writes role_audit_log
-- ============================================================================
-- TODO §2.7. 0022 created role_audit_log with
-- `role_action as enum ('promoted', 'demoted')` and then only ever wrote
-- 'promoted' — so 'demoted' has been an unreachable enum value, and demotion
-- has stayed exactly as unlogged as it was before the table existed.
--
-- That is the wrong way round. Of the two operations, DEMOTION IS THE
-- DANGEROUS ONE: promotion grants scheduling authority to someone the faculty
-- rep just vouched for, while demotion REMOVES a cohort's ability to schedule
-- anything, mid-semester, and 0022's own header names "demote_class_rep, which
-- can strip a cohort's scheduling authority and leaves no trace of who did it"
-- as a reason the table needed to exist. It then did not close it.
--
-- No structure changes here — role_audit_log already has its RLS policy,
-- its revoke/grant pair and its index from 0022 §5. This adds a writer.
create or replace function demote_class_rep(
  p_user_id    uuid,
  p_demoted_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_demoter_role    user_role;
  v_demoter_faculty uuid;
  v_target_faculty  uuid;
  v_target_cohort   uuid;
  v_target_name     text;
  v_target_rank     class_rep_rank;
begin
  if p_demoted_by is distinct from auth.uid() then
    raise exception 'p_demoted_by must match the calling user';
  end if;

  select role, faculty_id into v_demoter_role, v_demoter_faculty
  from users where id = p_demoted_by;

  if v_demoter_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may demote a class rep';
  end if;

  if v_demoter_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot demote anyone';
  end if;

  -- The target's faculty is resolved through the cohort chain, per 0002's
  -- note that users.faculty_id is not source of truth for a student.
  --
  -- Name, rank and cohort are read HERE, in the same query, because the UPDATE
  -- below destroys the rank and the audit row has to record what was taken
  -- away. Reading them afterwards would record a null rank on every row.
  select d.faculty_id, u.cohort_id, u.first_name || ' ' || u.last_name, u.class_rep_rank
  into v_target_faculty, v_target_cohort, v_target_name, v_target_rank
  from users u
  join cohorts c    on c.id = u.cohort_id
  join programmes p on p.id = c.programme_id
  join departments d on d.id = p.department_id
  where u.id = p_user_id and u.role = 'class_rep';

  if v_target_faculty is null then
    raise exception 'User % is not a class rep of any cohort', p_user_id;
  end if;

  if v_target_faculty is distinct from v_demoter_faculty then
    raise exception 'User % is a class rep in another faculty', p_user_id;
  end if;

  update users
  set role = 'student', class_rep_rank = null
  where id = p_user_id and role = 'class_rep';

  -- new_rank is null: after a demotion they hold no rank at all. The rank that
  -- was REMOVED goes in the snapshot, which is what makes the row answer the
  -- question anyone reads this log to ask — "who took the primary rep's
  -- authority away, and when?"
  insert into role_audit_log (user_id, user_name, cohort_id, action, new_rank, actor_id, snapshot)
  values (
    p_user_id, v_target_name, v_target_cohort, 'demoted', null, p_demoted_by,
    jsonb_build_object(
      'previous_rank', v_target_rank,
      'previous_role', 'class_rep'
    )
  );
end;
$$;

comment on function demote_class_rep(uuid, uuid) is
  'Empties a class rep slot — no auto-promotion of the assistant. Faculty rep, '
  'own faculty only. Writes a ''demoted'' row to role_audit_log carrying the '
  'rank that was removed.';
