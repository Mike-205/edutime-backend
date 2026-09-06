-- ============================================================================
-- 0022: The event API closes
-- ============================================================================
-- Phase 1 part 3 of 3, and the last structural change before the Flutter client
-- is written. TODO §1.1-§1.4 and §1.7 all land here, in one migration, because
-- there is no code generation between this repo and the Flutter repo — every
-- signature below has to be mirrored into Dart by hand, and doing them in one
-- pass costs one round of client work instead of five.
--
-- What has no code path at all before this file:
--
--   1. ATTENDANCE CONFIRMATION — the headline feature. attendance_status can
--      never leave 'pending', which makes attendance_confirmed_by,
--      attendance_confirmed_at and events_pending_confirmation_idx dead weight
--      and means the lecturer-reliability story motivating the whole product
--      does not work (TECHNICAL_DISCOVERY §5).
--   2. RECURRENCE — decided in TODO §0.1, never built. create_event stores
--      `recurrence` and never sets recurrence_group_id, so a rep can only ever
--      create one-off lectures.
--   3. AN EDIT PATH — reps can create, reschedule and cancel, but nothing can
--      change a title, a lecturer or a unit. create_event hardcodes title to
--      null and takes no title parameter.
--   4. promote_class_rep — the assistant rank is unreachable from inside the
--      app; seed.sql does it with a direct UPDATE as postgres.
--
-- Contents
--   §1  create_event               — rewritten: per-cohort courses, title,
--                                    recurrence materialization
--   §2  cancel_recurrence_group    — cancel a whole series
--   §3  update_event               — the missing edit path
--   §4  confirm_attendance / unconfirm_attendance   (+ broadcast action rename)
--   §5  role_audit_log + promote_class_rep          (with 0.5's attestation)
--   §6  reschedule_event, events_current, and the two ends 0021 left open
--   §7  Grants
--
-- ORDER IS LOAD-BEARING. §6 tightens event_cohorts.course_id to NOT NULL and
-- drops events.course_id, and it can only do that once every function that
-- writes either column has been redefined above it. 0021's header says it and
-- it is worth repeating: structure cannot outrun the function that maintains
-- it. Tightening either end early applies cleanly against the empty table at
-- migration time and then fails on the first seed run.
-- ============================================================================


-- ============================================================================
-- 1. create_event
-- ============================================================================
-- The signature changes substantially. Old:
--
--   create_event(p_cohort_ids uuid[], p_venue_id uuid, p_course_id uuid,
--                p_lecturer_name text, p_start timestamptz, p_end timestamptz,
--                p_recurrence recurrence_type, p_recurrence_rule text,
--                p_acting_user uuid)
--
-- Two parameters go away and two arrive.
--
-- p_course_id -> p_attachments. TODO §1.7: events.course_id was a single FK
-- into programme-scoped `courses`, so a combined lecture spanning two
-- programmes had no course row valid for both and one cohort's students saw a
-- unit from a programme they are not enrolled in. The course is now a property
-- of the ATTACHMENT, so the parameter has to be too. A jsonb array of
-- {cohort_id, course_id} objects is used rather than two parallel uuid[]s: it
-- is self-describing, it cannot be silently misaligned by a client that builds
-- one array correctly and the other not, and it matches roster_bulk_import's
-- existing convention.
--
-- p_recurrence_rule -> p_until. The rule was always dead text — 0004's own
-- comment calls it "display metadata only" — and it is redundant now that
-- occurrences are materialized from the enum plus a horizon. p_until is the
-- rep's real last teaching date; see the recurrence block below for how it
-- interacts with the term ceiling.
--
-- p_title is new (TODO §1.3), and nullable: a null title falls back to the
-- course name in the UI, which is what every event created before this
-- migration relied on.
--
-- This is a DROP and CREATE rather than a CREATE OR REPLACE, because the
-- parameter list changed — replacing with a different signature would create a
-- second overload and leave the old one callable. Dropping discards the ACL
-- that 0014 §3 granted, which is why §7 re-grants explicitly rather than
-- relying on the replace-preserves-privileges rule the rest of this schema
-- leans on.
drop function if exists create_event(
  uuid[], uuid, uuid, text, timestamptz, timestamptz, recurrence_type, text, uuid
);

create function create_event(
  p_attachments   jsonb,          -- [{"cohort_id": "...", "course_id": "..."}, ...]
  p_venue_id      uuid,
  p_lecturer_name text,
  p_title         text,
  p_start         timestamptz,
  p_end           timestamptz,
  p_recurrence    recurrence_type,
  p_until         date,
  p_acting_user   uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_cohort_id uuid;
  v_caller_role      user_role;
  v_cohort_ids       uuid[];
  v_course_ids       uuid[];
  v_distinct_cohorts int;
  v_missing          uuid;
  v_bad_cohort       uuid;
  v_bad_course       uuid;
  v_title            text;
  v_lecturer         text;
  -- A null p_recurrence is read as 'none' rather than left to fall through the
  -- recurrence branch, where `p_recurrence = 'none'` would be null, the step
  -- CASE would yield null, and the loop would never terminate.
  v_recurrence       recurrence_type := coalesce(p_recurrence, 'none');
  v_initial_status   event_status;
  v_pace             cohort_pace;
  v_term             term_window;
  v_horizon          date;
  v_step             interval;
  v_duration         interval;
  v_group_id         uuid;
  v_starts           timestamptz[] := '{}';
  v_occ_start        timestamptz;
  v_n                int;
  v_i                int;
  v_event_id         uuid;
  v_first_event_id   uuid;
  v_constraint       text;
  v_cohort_id        uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_caller_role, v_caller_cohort_id
  from users where id = p_acting_user;

  if v_caller_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may schedule an event';
  end if;

  -- --- Attachments ---------------------------------------------------------
  if p_attachments is null or jsonb_typeof(p_attachments) is distinct from 'array' then
    raise exception
      'p_attachments must be a JSON array of {"cohort_id": ..., "course_id": ...} objects';
  end if;

  -- `distinct` collapses a genuinely repeated attachment, which is the same
  -- forgiveness the old uuid[] path gave a repeated cohort id: attaching the
  -- same cohort to the same unit twice is a client mistake, not a conflict.
  -- Ordering by cohort_id keeps the two arrays aligned with each other; nothing
  -- downstream depends on the client's ordering, since the initiator is
  -- identified by matching the caller's own cohort rather than by position.
  with raw as (
    select distinct
      (a ->> 'cohort_id')::uuid as cohort_id,
      (a ->> 'course_id')::uuid as course_id
    from jsonb_array_elements(p_attachments) a
  )
  select array_agg(cohort_id order by cohort_id),
         array_agg(course_id order by cohort_id)
  into v_cohort_ids, v_course_ids
  from raw;

  if v_cohort_ids is null or array_length(v_cohort_ids, 1) is null then
    raise exception 'p_attachments must contain at least one cohort';
  end if;

  if exists (select 1 from unnest(v_cohort_ids) c where c is null)
     or exists (select 1 from unnest(v_course_ids) c where c is null) then
    raise exception
      'Every attachment needs both a cohort_id and a course_id';
  end if;

  -- What `distinct` above could NOT collapse: the same cohort listed twice with
  -- two different units. There is no defensible way to pick one, and silently
  -- taking either would put a unit on a cohort's calendar that its rep did not
  -- choose. Refuse instead.
  select count(distinct c)::int into v_distinct_cohorts from unnest(v_cohort_ids) c;

  if v_distinct_cohorts <> array_length(v_cohort_ids, 1) then
    raise exception
      'A cohort appears more than once in p_attachments with different courses — '
      'each cohort attends the lecture as exactly one unit';
  end if;

  if not (v_caller_cohort_id = any(v_cohort_ids)) then
    raise exception 'p_attachments must include the acting rep''s own cohort';
  end if;

  select c into v_missing
  from unnest(v_cohort_ids) c
  where not exists (select 1 from cohorts where id = c)
  limit 1;

  if v_missing is not null then
    raise exception 'Cohort % does not exist', v_missing;
  end if;

  -- The check TODO §1.7 exists to make possible. `courses` is programme-scoped,
  -- so a course from an unrelated programme was never meaningful on a cohort's
  -- calendar — it was merely unreachable to complain about while one FK had to
  -- serve every attached cohort. Now that each attachment carries its own unit,
  -- there is no reason left to accept a mismatch, and accepting one through a
  -- brand-new API would be perverse.
  select t.cohort_id, t.course_id
  into v_bad_cohort, v_bad_course
  from unnest(v_cohort_ids, v_course_ids) as t(cohort_id, course_id)
  join cohorts c on c.id = t.cohort_id
  left join courses crs on crs.id = t.course_id
  where crs.id is null
     or crs.programme_id is distinct from c.programme_id
  limit 1;

  if v_bad_cohort is not null then
    raise exception
      'Course % is not offered by cohort %''s programme', v_bad_course, v_bad_cohort;
  end if;

  -- --- Scalars -------------------------------------------------------------
  v_title := nullif(btrim(coalesce(p_title, '')), '');

  v_lecturer := nullif(btrim(coalesce(p_lecturer_name, '')), '');
  if v_lecturer is null then
    raise exception 'p_lecturer_name is required';
  end if;

  v_initial_status := case
    when array_length(v_cohort_ids, 1) > 1 then 'proposed'
    else 'scheduled'
  end;

  v_duration := p_end - p_start;

  -- --- Recurrence (TODO §0.1, §1.2) ----------------------------------------
  -- Materialize on create. Lazy expansion at read time is ruled out for good:
  -- the EXCLUDE constraints need real rows to conflict against, and conflict
  -- prevention is the product.
  if v_recurrence = 'none' then
    if p_until is not null then
      -- Refusing rather than ignoring. A rep who set an end date and got back a
      -- single lecture has been silently disobeyed, and would have no way to
      -- tell from the result which of the two inputs was the one that lost.
      raise exception
        'p_until only applies to a recurring lecture — pass p_recurrence to create a series';
    end if;

    v_starts := array[p_start];
  else
    -- Out of scope, per DISCOVERY and TECHNICAL_DISCOVERY §7/§11: a recurring
    -- cross-cohort series would need every attached cohort's rep to reconfirm
    -- every single occurrence. Refusing it here is also what makes the horizon
    -- unambiguous — with exactly one cohort there is exactly one pace to read.
    if array_length(v_cohort_ids, 1) > 1 then
      raise exception
        'A recurring lecture cannot be a combined lecture — recurring cross-cohort '
        'series are out of scope. Create the occurrences individually.';
    end if;

    select pace into v_pace from cohorts where id = v_caller_cohort_id;

    v_term := term_bounds(p_start::date, v_pace);

    if (v_term).term_end is null then
      -- A bimester cohort in the May-Aug break. It has no teaching term
      -- containing that date, so there is no ceiling to materialize against —
      -- and a series starting there is a mistake worth catching rather than a
      -- horizon to guess at. Note this gates RECURRENCE ONLY: a one-off
      -- make-up class in the break takes the branch above and never consults
      -- term_bounds at all.
      raise exception
        'Cohort has no teaching term containing % (a % cohort does not teach then), '
        'so a recurring series cannot be bounded. A one-off lecture is still allowed.',
        p_start::date, v_pace;
    end if;

    -- p_until is the rep's real last teaching date; the term end is the hard
    -- ceiling. Teaching does not fill a term — a series might genuinely stop on
    -- Apr 10 while the term runs to Apr 30 — so the rep's date is honoured when
    -- it is earlier and clamped when it is later. Passing nothing means "to the
    -- end of the term".
    v_horizon := least(coalesce(p_until, (v_term).term_end), (v_term).term_end);

    if p_start::date > v_horizon then
      raise exception
        'A series cannot start after its horizon (starts %, horizon %)',
        p_start::date, v_horizon;
    end if;

    v_step := case v_recurrence
      when 'day'   then interval '1 day'
      when 'week'  then interval '1 week'
      when 'month' then interval '1 month'
    end;

    v_n := 0;
    loop
      v_occ_start := p_start + (v_n * v_step);
      exit when v_occ_start::date > v_horizon;

      v_starts := v_starts || v_occ_start;
      v_n := v_n + 1;

      -- Sanity cap. Nothing reachable through term_bounds can produce this —
      -- a term is at most four months, so a daily series tops out around 123 —
      -- but a future caller with a hand-supplied horizon should hit a named
      -- limit rather than spin.
      if v_n > 200 then
        raise exception 'A recurring series may not exceed 200 occurrences';
      end if;
    end loop;

    v_group_id := gen_random_uuid();
  end if;

  -- --- Materialize ---------------------------------------------------------
  -- All-or-nothing. This is one transaction, so a clash anywhere aborts
  -- everything written above it; skip-and-report would cost a savepoint per
  -- occurrence and leave the rep with a series full of holes they did not ask
  -- for. The catch block exists only to name the date — the client gets
  -- something actionable instead of a raw 23P01 with no indication of WHICH
  -- week of fifteen was the problem.
  foreach v_occ_start in array v_starts loop
    begin
      insert into events (
        title, venue_id, lecturer_name, start_time, end_time,
        recurrence, recurrence_group_id, status, attendance_status,
        created_by, updated_by
      )
      values (
        v_title, p_venue_id, v_lecturer, v_occ_start, v_occ_start + v_duration,
        v_recurrence, v_group_id, v_initial_status, 'pending',
        p_acting_user, p_acting_user
      )
      returning id into v_event_id;

      for v_i in 1 .. array_length(v_cohort_ids, 1) loop
        insert into event_cohorts (
          event_id, cohort_id, course_id, is_initiator, confirmation_status,
          decided_by, decided_at, start_time, end_time, event_status_cache
        )
        values (
          v_event_id, v_cohort_ids[v_i], v_course_ids[v_i],
          (v_cohort_ids[v_i] = v_caller_cohort_id),
          -- The ::cohort_confirmation_status cast is REQUIRED. A CASE over
          -- quoted literals resolves to `text` before the INSERT sees it, and
          -- there is no implicit text -> enum cast; a BARE literal would have
          -- been fine. Its absence is why create_event never once ran between
          -- 0010 and 0015 (TECHNICAL_DISCOVERY §3).
          (case when v_cohort_ids[v_i] = v_caller_cohort_id then 'confirmed' else 'pending' end
            )::cohort_confirmation_status,
          case when v_cohort_ids[v_i] = v_caller_cohort_id then p_acting_user else null end,
          case when v_cohort_ids[v_i] = v_caller_cohort_id then now() else null end,
          v_occ_start, v_occ_start + v_duration, v_initial_status
        );
      end loop;

    exception when exclusion_violation then
      get stacked diagnostics v_constraint = CONSTRAINT_NAME;

      raise exception
        'Cannot schedule the occurrence on %: %. No occurrences were created.',
        v_occ_start::date,
        case v_constraint
          when 'events_no_venue_overlap'       then 'that venue is already booked at that time'
          when 'event_cohorts_no_self_overlap' then 'an attached cohort already has a lecture at that time'
          else 'it clashes with an existing booking'
        end
        using errcode = 'exclusion_violation';
    end;

    if v_first_event_id is null then
      v_first_event_id := v_event_id;
    end if;

    insert into event_audit_log (event_id, action, changed_by, snapshot)
    values (
      v_event_id, 'created', p_acting_user,
      jsonb_build_object(
        'cohort_ids', v_cohort_ids,
        'initial_status', v_initial_status,
        'recurrence_group_id', v_group_id
      )
    );
  end loop;

  -- --- Notify --------------------------------------------------------------
  -- ONE notification per cohort for the whole series, not one per occurrence. A
  -- fifteen-week series would otherwise write fifteen rows to every student in
  -- the cohort for a single action by a single rep. The realtime broadcasts are
  -- deliberately still per-occurrence — those carry {id, action} and nothing
  -- else, and the client genuinely does need to learn about each new row.
  if v_initial_status = 'proposed' then
    foreach v_cohort_id in array v_cohort_ids loop
      if v_cohort_id != v_caller_cohort_id then
        perform notify_cohort_members(
          v_cohort_id, v_first_event_id, 'cohort_confirmation_needed',
          'Combined lecture needs your confirmation',
          'A class rep from another cohort has proposed a combined lecture with yours.',
          'class_rep'
        );
      end if;
    end loop;
  else
    perform notify_cohort_members(
      v_caller_cohort_id, v_first_event_id, 'created',
      'New lecture scheduled',
      case
        when array_length(v_starts, 1) > 1 then
          format('%s lectures have been added to your schedule.', array_length(v_starts, 1))
        else
          'A new lecture has been added to your schedule.'
      end
    );
  end if;

  -- Returns the FIRST occurrence's id, not the recurrence_group_id. Callers
  -- always get back something they can immediately pass to reschedule_event,
  -- cancel_event or confirm_attendance, and the group id is one column away on
  -- the row they were just handed. A group id would have been useless for the
  -- single-occurrence case, which is the overwhelming majority.
  return v_first_event_id;
end;
$$;

comment on function create_event(jsonb, uuid, text, text, timestamptz, timestamptz, recurrence_type, date, uuid) is
  'Creates a lecture, or a whole recurring series, for one or more cohorts. '
  'p_attachments is [{"cohort_id":...,"course_id":...}] — each cohort attends as '
  'its own unit. Recurrence is materialized one row per occurrence, bounded by '
  'least(p_until, the initiating cohort''s term end), and is refused for combined '
  'lectures. Returns the first occurrence''s id.';


-- ============================================================================
-- 2. cancel_recurrence_group
-- ============================================================================
-- The other half of materialization. Fifteen rows created by one action need
-- one action that can retire them; without this a rep who scheduled a term of
-- weekly lectures into the wrong room would have to cancel each one by hand.
--
-- The subtlety is which rows it has to reach. TODO §0.1.4 settled that a
-- rescheduled occurrence STAYS IN ITS SERIES — reschedule_event copies
-- recurrence_group_id onto the replacement row — so an occurrence somebody
-- moved from Tuesday to Wednesday is still part of the series and must still be
-- cancelled with it. Selecting on the group id rather than walking from the
-- original rows is what makes that fall out for free.
create function cancel_recurrence_group(
  p_group_id    uuid,
  p_acting_user uuid
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_initiator_cohort uuid;
  v_event_id         uuid;
  v_first_event_id   uuid;
  v_count            int := 0;
  v_cohort_id        uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  -- Every occurrence in a series shares one initiating cohort — recurrence is
  -- refused for combined lectures, so there is only ever one cohort to be the
  -- initiator of — but read it from the group rather than assuming.
  select ec.cohort_id into v_initiator_cohort
  from event_cohorts ec
  join events e on e.id = ec.event_id
  where e.recurrence_group_id = p_group_id
    and ec.is_initiator = true
  limit 1;

  if v_initiator_cohort is null then
    raise exception 'No recurring series with group id %', p_group_id;
  end if;

  if not exists (
    select 1 from users u
    where u.id = p_acting_user
      and u.role = 'class_rep'
      and u.cohort_id = v_initiator_cohort
  ) then
    raise exception 'Only the initiating cohort''s class_rep may cancel this series';
  end if;

  for v_event_id in
    select id from events
    where recurrence_group_id = p_group_id
      and status in ('proposed', 'scheduled')
    order by start_time
    for update
  loop
    update events
    set status = 'canceled', updated_by = p_acting_user, updated_at = now()
    where id = v_event_id;

    insert into event_audit_log (event_id, action, changed_by, snapshot)
    values (
      v_event_id, 'canceled', p_acting_user,
      jsonb_build_object('reason', 'recurrence_group_canceled', 'recurrence_group_id', p_group_id)
    );

    if v_first_event_id is null then
      v_first_event_id := v_event_id;
    end if;

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception
      'Series % has no live occurrences left to cancel', p_group_id;
  end if;

  -- One notification per cohort, for the same reason create_event writes one:
  -- this is a single action by a single rep, however many rows it touched. The
  -- per-occurrence broadcasts still fire from the events UPDATE trigger.
  for v_cohort_id in
    select distinct ec.cohort_id
    from event_cohorts ec
    join events e on e.id = ec.event_id
    where e.recurrence_group_id = p_group_id
      and ec.confirmation_status not in ('declined', 'left')
  loop
    perform notify_cohort_members(
      v_cohort_id, v_first_event_id, 'canceled',
      'Recurring lecture cancelled',
      format('A recurring lecture has been cancelled (%s occurrences).', v_count)
    );
  end loop;

  return v_count;
end;
$$;

comment on function cancel_recurrence_group(uuid, uuid) is
  'Cancels every live occurrence of a recurring series, including occurrences '
  'that were individually rescheduled (they keep their recurrence_group_id). '
  'Initiating cohort''s class rep only. Returns the number cancelled.';


-- ============================================================================
-- 3. update_event
-- ============================================================================
-- TODO §1.3. DISCOVERY says a class rep can "create, edit, reschedule and
-- cancel"; three of those four existed. There was no way to fix a typo in a
-- lecturer's name, no way to change which unit a lecture is, and no way to set
-- a title at all — create_event hardcoded it to null and took no parameter.
--
-- Time and venue changes deliberately stay with reschedule_event, which is a
-- different operation with different consequences: it retires the occurrence,
-- creates a replacement, re-opens confirmation for a combined lecture and
-- re-evaluates both EXCLUDE constraints. Nothing here can cause a conflict,
-- which is exactly why it can be a plain UPDATE.
--
-- NULL MEANS "LEAVE UNCHANGED" for all three fields. To clear a title, pass an
-- empty string — the one field where null is itself a legitimate stored value,
-- so it needs a separate way to say "make it null".
create function update_event(
  p_event_id      uuid,
  p_title         text,
  p_lecturer_name text,
  p_course_id     uuid,
  p_acting_user   uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_status     event_status;
  v_caller_cohort_id uuid;
  v_programme_id     uuid;
  v_lecturer         text;
  v_new_title        text;
  v_cohort_id        uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  if p_title is null and p_lecturer_name is null and p_course_id is null then
    raise exception 'Nothing to update — pass at least one of title, lecturer or course';
  end if;

  select status into v_event_status from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  -- Same guard shape as cancel_event. Editing a canceled lecture would put a
  -- corrected lecturer name on something nobody is attending; editing a
  -- 'rescheduled' one would edit a retired occurrence while the live
  -- replacement it points at kept the old values.
  if v_event_status not in ('proposed', 'scheduled') then
    raise exception 'Event % is % and cannot be edited', p_event_id, v_event_status;
  end if;

  -- Initiator-only, like cancel_event and reschedule_event. A non-initiating
  -- rep who dislikes the arrangement has leave_event_cohort; rewriting the
  -- shared row would change it for every other attached cohort too.
  select u.cohort_id into v_caller_cohort_id
  from event_cohorts ec
  join users u on u.cohort_id = ec.cohort_id
  where ec.event_id = p_event_id
    and ec.is_initiator = true
    and u.id = p_acting_user
    and u.role = 'class_rep';

  if v_caller_cohort_id is null then
    raise exception 'Only the initiating cohort''s class_rep may edit this event';
  end if;

  -- The course is per-attachment, so a rep changes only the unit THEIR OWN
  -- cohort attends as. Another cohort on the same combined lecture owns its
  -- own, and that is the whole point of moving the column in 0021.
  if p_course_id is not null then
    select c.programme_id into v_programme_id
    from cohorts c where c.id = v_caller_cohort_id;

    if not exists (
      select 1 from courses
      where id = p_course_id and programme_id = v_programme_id
    ) then
      raise exception
        'Course % is not offered by cohort %''s programme', p_course_id, v_caller_cohort_id;
    end if;

    update event_cohorts
    set course_id = p_course_id
    where event_id = p_event_id and cohort_id = v_caller_cohort_id;
  end if;

  if p_lecturer_name is not null then
    v_lecturer := nullif(btrim(p_lecturer_name), '');
    if v_lecturer is null then
      raise exception 'p_lecturer_name cannot be blank';
    end if;
  end if;

  if p_title is not null then
    v_new_title := nullif(btrim(p_title), '');
  end if;

  -- Always touch the events row, even when only the course changed. Two
  -- reasons: updated_by/updated_at should reflect who last edited the lecture
  -- whatever they edited, and events_broadcast_trigger fires on UPDATE of
  -- `events` — a course-only edit that skipped this would silently never reach
  -- any client.
  update events
  set title         = case when p_title is not null then v_new_title else title end,
      lecturer_name = coalesce(v_lecturer, lecturer_name),
      updated_by    = p_acting_user,
      updated_at    = now()
  where id = p_event_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    p_event_id, 'updated', p_acting_user,
    jsonb_build_object(
      'title',         case when p_title is not null then to_jsonb(v_new_title) else null end,
      'lecturer_name', to_jsonb(v_lecturer),
      'course_id',     to_jsonb(p_course_id),
      'cohort_id',     to_jsonb(v_caller_cohort_id)
    )
  );

  for v_cohort_id in
    select cohort_id from event_cohorts
    where event_id = p_event_id and confirmation_status not in ('declined', 'left')
  loop
    perform notify_cohort_members(
      v_cohort_id, p_event_id, 'updated',
      'Lecture details changed',
      'The details of a lecture on your schedule have been updated.'
    );
  end loop;
end;
$$;

comment on function update_event(uuid, text, text, uuid, uuid) is
  'Edits a lecture''s title and lecturer, and the CALLING rep''s own '
  'event_cohorts.course_id. Null means leave unchanged; an empty p_title clears '
  'it. Time and venue changes go through reschedule_event. Initiator-only.';


-- ============================================================================
-- 4. Attendance confirmation
-- ============================================================================
-- TODO §1.1. THE HEADLINE FEATURE, and it has had no code path since 0004
-- created the columns.
--
-- DISCOVERY's problem statement is two things: cohorts cannot see a trustworthy
-- schedule, AND "even a 'correct' schedule doesn't tell a student whether the
-- lecture is actually going to happen", because some lecturers are present one
-- week and absent the next. The only safeguard today is a class rep phoning the
-- lecturer the day before — "an invisible, easily-forgotten task with no system
-- support". attendance_status is the whole of that second half, and until this
-- section it could never leave 'pending': no function wrote it, and `events`
-- has no client UPDATE policy or privilege (deliberately — every mutation goes
-- through a definer function, TECHNICAL_DISCOVERY §8).
--
-- Which made attendance_confirmed_by, attendance_confirmed_at,
-- notif_type = 'confirmation_needed' and events_pending_confirmation_idx all
-- dead weight carried through eighteen migrations.
--
-- Two decisions worth keeping:
--
--   * ANY ATTACHED COHORT'S REP may confirm, not just the initiator's. Any of
--     them may have been the one who made the call, and a combined lecture that
--     only its initiator could vouch for would leave the other cohorts' reps
--     re-phoning a lecturer somebody already reached.
--   * UN-CONFIRMING IS ALLOWED (decided 2026-08-01, reversing an earlier
--     one-way lean). A rep who mis-taps otherwise leaves their cohort a
--     confirmation nobody actually made, which is worse than no confirmation at
--     all — the entire value of the badge is that it means somebody phoned.

create function confirm_attendance(
  p_event_id    uuid,
  p_acting_user uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_status      event_status;
  v_attendance        attendance_status;
  v_caller_cohort_id  uuid;
  v_cohort_id         uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select status, attendance_status into v_event_status, v_attendance
  from events where id = p_event_id for update;

  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  -- 'proposed' has nothing to confirm attendance FOR — the lecture is not real
  -- for every cohort yet. 'canceled' and 'rescheduled' are not happening at all.
  if v_event_status is distinct from 'scheduled' then
    raise exception
      'Event % is % — attendance can only be confirmed for a scheduled lecture',
      p_event_id, v_event_status;
  end if;

  select ec.cohort_id into v_caller_cohort_id
  from event_cohorts ec
  join users u on u.cohort_id = ec.cohort_id
  where ec.event_id = p_event_id
    and ec.confirmation_status not in ('declined', 'left')
    and u.id = p_acting_user
    and u.role = 'class_rep';

  if v_caller_cohort_id is null then
    raise exception
      'Only a class_rep of a cohort attending this lecture may confirm attendance';
  end if;

  if v_attendance = 'confirmed' then
    raise exception 'Attendance for event % is already confirmed', p_event_id;
  end if;

  update events
  set attendance_status       = 'confirmed',
      attendance_confirmed_by = p_acting_user,
      attendance_confirmed_at = now(),
      updated_by              = p_acting_user,
      updated_at              = now()
  where id = p_event_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    p_event_id, 'confirmed', p_acting_user,
    jsonb_build_object('attendance_status', 'confirmed', 'cohort_id', v_caller_cohort_id)
  );

  for v_cohort_id in
    select cohort_id from event_cohorts
    where event_id = p_event_id and confirmation_status not in ('declined', 'left')
  loop
    perform notify_cohort_members(
      v_cohort_id, p_event_id, 'attendance_confirmed',
      'Lecturer confirmed',
      'A class rep has confirmed the lecturer is attending this lecture.'
    );
  end loop;
end;
$$;


create function unconfirm_attendance(
  p_event_id    uuid,
  p_acting_user uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_status     event_status;
  v_attendance       attendance_status;
  v_caller_cohort_id uuid;
  v_cohort_id        uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select status, attendance_status into v_event_status, v_attendance
  from events where id = p_event_id for update;

  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  if v_event_status is distinct from 'scheduled' then
    raise exception
      'Event % is % — attendance can only be un-confirmed for a scheduled lecture',
      p_event_id, v_event_status;
  end if;

  select ec.cohort_id into v_caller_cohort_id
  from event_cohorts ec
  join users u on u.cohort_id = ec.cohort_id
  where ec.event_id = p_event_id
    and ec.confirmation_status not in ('declined', 'left')
    and u.id = p_acting_user
    and u.role = 'class_rep';

  if v_caller_cohort_id is null then
    raise exception
      'Only a class_rep of a cohort attending this lecture may un-confirm attendance';
  end if;

  if v_attendance = 'pending' then
    raise exception 'Attendance for event % is not confirmed', p_event_id;
  end if;

  -- Clears all three fields together. attendance_confirmed_by outliving the
  -- status it justifies would leave a row asserting that somebody vouched for a
  -- lecture whose badge has been withdrawn.
  update events
  set attendance_status       = 'pending',
      attendance_confirmed_by = null,
      attendance_confirmed_at = null,
      updated_by              = p_acting_user,
      updated_at              = now()
  where id = p_event_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    p_event_id, 'unconfirmed', p_acting_user,
    jsonb_build_object('attendance_status', 'pending', 'cohort_id', v_caller_cohort_id)
  );

  for v_cohort_id in
    select cohort_id from event_cohorts
    where event_id = p_event_id and confirmation_status not in ('declined', 'left')
  loop
    perform notify_cohort_members(
      v_cohort_id, p_event_id, 'attendance_unconfirmed',
      'Lecturer no longer confirmed',
      'The confirmation that the lecturer is attending this lecture has been withdrawn.'
    );
  end loop;
end;
$$;


-- The broadcast action for an attendance change was named 'confirmation_needed'
-- by 0016 — a value it borrowed from notif_type, where it means the OPPOSITE
-- thing: the nudge asking a rep to go and phone the lecturer (TODO §3.2). A
-- client decoding the channel would have read "attendance was just confirmed"
-- as "somebody needs to confirm attendance".
--
-- Nothing was ever wrong with it in practice because attendance_status could
-- never change, so the branch was unreachable. It becomes reachable four
-- sections up, and this is the last moment to rename it for free — the Flutter
-- client does not exist yet, so there is nothing to migrate.
--
-- RESTATING `set search_path = public` IS MANDATORY. CREATE OR REPLACE discards
-- proconfig, so replacing the body of a SECURITY DEFINER function that 0008
-- pinned silently un-pins it and reopens the escalation vector. This bit
-- handle_new_auth_user in 0019; 00_access_control_test.sql caught it.
create or replace function notify_cohort_event_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id    uuid;
  v_cohort_id   uuid;
  change_action text;
begin
  if TG_OP = 'DELETE' then
    v_event_id := OLD.id;
    change_action := 'deleted';
  else
    v_event_id := NEW.id;
    change_action := case
      when TG_OP = 'INSERT' then 'created'
      when NEW.status = 'canceled'    and OLD.status != 'canceled'    then 'canceled'
      when NEW.status = 'rescheduled' and OLD.status != 'rescheduled' then 'rescheduled'
      when NEW.status = 'scheduled'   and OLD.status =  'proposed'    then 'confirmed'
      when NEW.attendance_status = 'confirmed'
           and OLD.attendance_status = 'pending' then 'attendance_confirmed'
      when NEW.attendance_status = 'pending'
           and OLD.attendance_status = 'confirmed' then 'attendance_unconfirmed'
      else 'updated'
    end;
  end if;

  for v_cohort_id in select cohort_id from event_cohorts where event_id = v_event_id loop
    perform realtime.send(
      jsonb_build_object('id', v_event_id, 'action', change_action),
      change_action,
      'cohort:' || v_cohort_id || ':events',
      true
    );
  end loop;

  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  return NEW;
end;
$$;

revoke execute on function notify_cohort_event_change() from public, anon, authenticated, service_role;


-- ============================================================================
-- 5. promote_class_rep
-- ============================================================================
-- TODO §1.4. create_cohort_with_class_rep installs only the FIRST rep and
-- demote_class_rep only empties a slot, so appointing an assistant — or
-- replacing a primary after demoting them — is impossible from inside the app.
-- seed.sql does it with a direct UPDATE as postgres, and 0014 now blocks a
-- client from writing users.role at all. So the assistant rank, i.e. the whole
-- "fallback if the primary needs replacing" mechanism DISCOVERY describes, is
-- currently unreachable.

-- --- role_audit_log ---------------------------------------------------------
-- A promotion needs somewhere to be recorded and there was nowhere to put it:
-- event_audit_log is event-scoped (event_id is NOT NULL) and roster_audit_log
-- is about identity, not authority. So role changes have been entirely
-- unlogged — including demote_class_rep, which can strip a cohort's scheduling
-- authority and leaves no trace of who did it.
--
-- This matters more than ordinary bookkeeping here, because of the attestation
-- below: a faculty rep asserting "I physically verified this person" is exactly
-- the kind of human override TECHNICAL_DISCOVERY §4 says must never be
-- unlogged. Same append-only idiom as the other two logs — actor, target,
-- snapshot.
--
-- Creating a NEW enum type and using it in the same migration is fine; the
-- restriction that forced 0009/0011/0018/0020 into their own files applies only
-- to ALTER TYPE ... ADD VALUE on an existing type.
create type role_action as enum ('promoted', 'demoted');

-- user_id is ON DELETE SET NULL with the name retained alongside it, rather
-- than the ON DELETE RESTRICT that events.created_by and
-- event_audit_log.changed_by use. Those two are why you can currently never
-- delete an auth account that has scheduled anything — the restrict fires
-- mid-cascade from auth.users (TODO §2.3) — and §2.3's own proposed fix is
-- "set null with a retained display name on the audit row". Adopting that shape
-- here means this table is already in the state that clean-up wants, instead of
-- being a fourth thing it has to unpick. The same reasoning roster_audit_log
-- gives for denormalizing reg_number applies: an audit log erasable by deleting
-- the thing it audits is not one.
create table role_audit_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references users (id) on delete set null,
  user_name  text not null,
  cohort_id  uuid references cohorts (id) on delete set null,
  action     role_action not null,
  new_rank   class_rep_rank,
  actor_id   uuid references users (id) on delete set null,
  snapshot   jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index role_audit_log_user_idx on role_audit_log (user_id, created_at desc);

comment on table role_audit_log is
  'Append-only record of role and rank changes. Carries the identity '
  'attestation a faculty rep makes when promoting someone whose account is not '
  'OAuth-verified.';

alter table role_audit_log enable row level security;

-- Readable by the person it is about, and by faculty reps — who are the people
-- who resolve disputes about who legitimately holds a rank. Deliberately not
-- narrowed to the rep's own faculty: doing so needs a cohorts -> programmes ->
-- departments join inside a policy expression, and TECHNICAL_DISCOVERY §13.2 is
-- explicit that policies which need to join belong in a definer function. The
-- rows carry no personal data beyond a name already visible to every
-- authenticated user, so the narrower scope is not worth the machinery.
create policy role_audit_read_own_or_faculty_rep
  on role_audit_log
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from users u where u.id = auth.uid() and u.role = 'faculty_rep'
    )
  );

-- Supabase ships default privileges that GRANT on newly created tables in
-- `public` to anon and authenticated, so this table arrived with privileges
-- nobody asked for. 0014 §4 cleared exactly this for the original fourteen
-- tables and 0017's three had to do it again — EVERY new table has to.
-- 00_access_control_test.sql fails if this is forgotten.
revoke all on role_audit_log from anon, authenticated;
grant select on role_audit_log to authenticated;
grant all    on role_audit_log to service_role;


create function promote_class_rep(
  p_user_id            uuid,
  p_rank               class_rep_rank,
  p_acting_faculty_rep uuid,
  p_identity_attested  boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role    user_role;
  v_actor_faculty uuid;
  v_target_role   user_role;
  v_target_cohort uuid;
  v_target_faculty uuid;
  v_target_name   text;
  v_existing_reps int;
  v_rank_holder   uuid;
  v_claim         claim_method;
begin
  if p_acting_faculty_rep is distinct from auth.uid() then
    raise exception 'p_acting_faculty_rep must match the calling user';
  end if;

  select role, faculty_id into v_actor_role, v_actor_faculty
  from users where id = p_acting_faculty_rep;

  if v_actor_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may promote a class rep';
  end if;

  if v_actor_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot promote anyone';
  end if;

  -- Same scoping as create_cohort_with_class_rep and demote_class_rep (0016
  -- §1): the target's faculty is resolved through the cohort chain, because
  -- users.faculty_id is not source of truth for a student.
  select u.role, u.cohort_id, d.faculty_id, u.first_name || ' ' || u.last_name
  into v_target_role, v_target_cohort, v_target_faculty, v_target_name
  from users u
  left join cohorts c     on c.id = u.cohort_id
  left join programmes p  on p.id = c.programme_id
  left join departments d on d.id = p.department_id
  where u.id = p_user_id;

  if v_target_role is null then
    raise exception 'User % not found', p_user_id;
  end if;

  if v_target_cohort is null then
    raise exception 'User % is not in a cohort and cannot be a class rep', p_user_id;
  end if;

  if v_target_faculty is distinct from v_actor_faculty then
    raise exception 'User % is in another faculty', p_user_id;
  end if;

  -- Only a plain student, for the same reason create_cohort_with_class_rep
  -- checks it: promoting a faculty_rep would demote the trust anchor into the
  -- role it is supposed to appoint, and re-promoting a sitting class_rep is a
  -- rank change that should go through demote first so every transition is
  -- deliberate.
  if v_target_role is distinct from 'student' then
    raise exception
      'User % is a % — only a student can be promoted to class rep', p_user_id, v_target_role;
  end if;

  -- enforce_max_class_reps would raise anyway, but with a message about a
  -- trigger rather than about what the faculty rep just tried to do.
  select count(*)::int into v_existing_reps
  from users
  where cohort_id = v_target_cohort and role = 'class_rep' and id <> p_user_id;

  if v_existing_reps >= 2 then
    raise exception
      'Cohort % already has 2 class reps — demote one before promoting another',
      v_target_cohort;
  end if;

  -- users_one_primary_per_cohort / users_one_assistant_per_cohort are partial
  -- unique indexes, so without this the caller gets a raw 23505 naming an index.
  select id into v_rank_holder
  from users
  where cohort_id = v_target_cohort
    and role = 'class_rep'
    and class_rep_rank = p_rank
    and id <> p_user_id
  limit 1;

  if v_rank_holder is not null then
    raise exception
      'Cohort % already has a % class rep (user %)', v_target_cohort, p_rank, v_rank_holder;
  end if;

  -- --- The attestation (TODO §0.5) -----------------------------------------
  -- The faculty rep sees a NAME in a list. They cannot tell from it that the
  -- account behind that name was claimed provisionally — i.e. through the
  -- unauthenticated password branch, which anyone who knows a classmate's
  -- registration number and full name can use (TECHNICAL_DISCOVERY §10). For a
  -- student account that is a bounded problem, because takeover undoes it. For
  -- a class rep it is not: scheduling authority is the one thing in this schema
  -- that cannot be handed back by rebinding a roster row.
  --
  -- Deliberately NOT a hard "must be OAuth-verified" rule. That would stop a
  -- first-year cohort ever having a rep, since nobody has a university mailbox
  -- yet — and first-year cohorts are exactly the ones that need one.
  select claim_method into v_claim
  from student_roster where claimed_by = p_user_id;

  if v_claim is distinct from 'oauth' and not coalesce(p_identity_attested, false) then
    raise exception
      'User % has not proved their identity with a university email (%). Promote '
      'them only after physically verifying who they are, and pass '
      'p_identity_attested => true to record that you did.',
      p_user_id, coalesce(v_claim::text, 'no roster claim');
  end if;

  update users
  set role = 'class_rep', class_rep_rank = p_rank
  where id = p_user_id;

  insert into role_audit_log (user_id, user_name, cohort_id, action, new_rank, actor_id, snapshot)
  values (
    p_user_id, v_target_name, v_target_cohort, 'promoted', p_rank, p_acting_faculty_rep,
    jsonb_build_object(
      'identity_attested', coalesce(p_identity_attested, false),
      'claim_method',      v_claim,
      'previous_role',     v_target_role
    )
  );
end;
$$;

comment on function promote_class_rep(uuid, class_rep_rank, uuid, boolean) is
  'Promotes a student to class rep at a given rank. Faculty rep, own faculty '
  'only. A target whose roster claim is not ''oauth'' requires '
  'p_identity_attested => true, which is recorded on role_audit_log.';


-- ============================================================================
-- 6. Closing the two ends 0021 left open
-- ============================================================================
-- 0021 added event_cohorts.course_id nullable and made events.course_id
-- nullable, deferring both halves of the tightening to here — because 0015's
-- create_event and reschedule_event were the live definitions until now and
-- neither knew about the new column. create_event was replaced in §1. This is
-- reschedule_event.

-- --- reschedule_event -------------------------------------------------------
-- Restated in full (CREATE OR REPLACE, so it keeps 0014 §3's grant), with two
-- changes and everything else preserved byte-for-byte from 0015 §3 — in
-- particular 0013's ordering fix, which retires the old occurrence BEFORE
-- inserting the replacement so the two do not collide on the partial EXCLUDE
-- indexes.
--
--   1. It no longer copies v_old.course_id onto the new events row. That column
--      is dropped a few lines below, and a function referencing a dropped
--      column raises at runtime, not at migration time — which is precisely the
--      failure mode 0021 deferred this work to avoid.
--   2. Each replacement attachment carries over its OWN cohort's course_id,
--      so a rescheduled combined lecture keeps every cohort seeing its own unit
--      instead of collapsing back onto one.
--
-- `set search_path = public` restated, per the CREATE OR REPLACE / proconfig
-- trap noted in §4.
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
  -- cancel_recurrence_group reach it in §2.
  insert into events (
    title, venue_id, lecturer_name, start_time, end_time,
    recurrence, recurrence_rule, recurrence_group_id,
    status, attendance_status, created_by, updated_by
  )
  values (
    v_old.title, p_new_venue_id, v_old.lecturer_name,
    p_new_start, p_new_end, v_old.recurrence, v_old.recurrence_rule, v_old.recurrence_group_id,
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


-- --- events_current, and the two ends ---------------------------------------
-- The view has to be dropped BEFORE the column and recreated AFTER it, and the
-- order is not cosmetic. events_current was written as `select *`, but Postgres
-- expands that into an explicit column list at CREATE time, so the view holds a
-- real dependency on every column that existed when it was created — including
-- course_id, which makes DROP COLUMN fail with a dependency error. Recreating
-- it first does not help: `select *` simply re-expands over the column that is
-- still there, and the drop fails against the new view instead of the old one.
drop view if exists events_current;

-- Now, and only now: every function that writes either column has been
-- redefined above.
alter table event_cohorts alter column course_id set not null;

alter table events drop column course_id;

-- Rebuilt against the narrowed table. Grants do not survive DROP VIEW, so they
-- are restated. security_invoker stays on: 0008 removed a security-definer view
-- for exactly the reason it should (the caller's RLS must apply), and 0010
-- rebuilt this one with it set.
--
-- The predicate is unchanged, including the fact that it filters 'rescheduled'
-- but not 'canceled' — that inconsistency is TODO §2.5's to settle, and quietly
-- changing what the view means while removing a column would bury a behaviour
-- change inside a mechanical one.
create view events_current with (security_invoker = true) as
select *
from events e
where status <> 'rescheduled' or superseded_by is null;

-- Supabase's default privileges grant on relation creation (the same trap
-- PHASE1_HANDOFF.md's traps list calls out for tables), and a view is no
-- exception: recreating it re-opens anon/authenticated access unless revoked
-- first.
revoke all on events_current from public, anon, authenticated;

grant select on events_current to authenticated;
grant all    on events_current to service_role;

comment on column event_cohorts.course_id is
  'The unit THIS cohort is attending the lecture as. Per-attachment because a '
  'combined lecture may span programmes, and courses are programme-scoped. '
  'Required as of 0022, which is the first version of create_event that '
  'populates it.';


-- ============================================================================
-- 7. Grants
-- ============================================================================
-- REVOKE FROM PUBLIC FIRST. CREATE FUNCTION implicitly grants EXECUTE to
-- PUBLIC, and a privilege held via PUBLIC cannot be revoked from one role — so
-- every `revoke execute ... from anon` in 0008/0010/0012/0013 was a NO-OP and
-- anon kept EXECUTE the whole time. 0014 §3 had to undo all of them.
-- 00_access_control_test.sql regression-tests this.
revoke execute on function create_event(jsonb, uuid, text, text, timestamptz, timestamptz, recurrence_type, date, uuid) from public, anon;
grant  execute on function create_event(jsonb, uuid, text, text, timestamptz, timestamptz, recurrence_type, date, uuid) to authenticated, service_role;

revoke execute on function cancel_recurrence_group(uuid, uuid) from public, anon;
grant  execute on function cancel_recurrence_group(uuid, uuid) to authenticated, service_role;

revoke execute on function update_event(uuid, text, text, uuid, uuid) from public, anon;
grant  execute on function update_event(uuid, text, text, uuid, uuid) to authenticated, service_role;

revoke execute on function confirm_attendance(uuid, uuid) from public, anon;
grant  execute on function confirm_attendance(uuid, uuid) to authenticated, service_role;

revoke execute on function unconfirm_attendance(uuid, uuid) from public, anon;
grant  execute on function unconfirm_attendance(uuid, uuid) to authenticated, service_role;

revoke execute on function promote_class_rep(uuid, class_rep_rank, uuid, boolean) from public, anon;
grant  execute on function promote_class_rep(uuid, class_rep_rank, uuid, boolean) to authenticated, service_role;
