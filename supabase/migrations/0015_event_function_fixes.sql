-- ============================================================================
-- 0015: Event function fixes — workflow guards, and the cast that broke create
-- ============================================================================
-- Part 2 of 3; applies after 0014. The event-mutation API surface: the guards
-- the combined-lecture workflow was missing, and the one-token reason none of
-- it had ever actually run.
--
--   1. decline_event_cohort worked on an already-'scheduled' event, letting
--      any attached rep cancel a confirmed lecture for everyone —
--      leave_event_cohort and the initiator-only rule on cancel_event were
--      both bypassable through it.
--   2. confirm_event_cohort could resurrect a canceled event: if one cohort
--      declined (event -> canceled) while another was still 'pending', that
--      other rep's confirmation flipped the event back to 'scheduled'.
--   3. get_venue_occupancy / is_venue_available only counted 'scheduled', but
--      0010 widened events_no_venue_overlap to ('proposed','scheduled'). The
--      venue browser advertised free rooms that create_event then rejected
--      with a raw 23P01.
--   4. A missing ::cohort_confirmation_status cast meant create_event and
--      reschedule_event had NEVER successfully inserted a row since 0010. The
--      events table was empty this whole time for that reason alone — see §3.
--
-- Contents
--   §1  Combined-lecture workflow guards
--         -> confirm_event_cohort / decline_event_cohort / cancel_event
--         -> create_event (input validation + the §3 cast, applied inline)
--   §2  Venue availability must agree with the venue conflict constraint
--   §3  The enum cast that stopped every event from ever being created
--         -> reschedule_event
--   §4  sync_event_cohorts_from_event: make its privilege explicit
--
-- EXECUTE grants for everything redefined here live in 0014 §3. CREATE OR
-- REPLACE keeps them; nothing below needs to re-grant, and where it does so
-- anyway that is belt-and-braces, not a requirement.
-- ============================================================================


-- ============================================================================
-- 1. Combined-lecture workflow guards
-- ============================================================================
-- The proposal state machine only ever intended these transitions:
--
--   proposed  --(every cohort confirms)-->  scheduled
--   proposed  --(any cohort declines)-->    canceled
--   proposed  --(initiator cancels)-->      canceled
--   scheduled --(initiator cancels)-->      canceled
--   scheduled --(initiator reschedules)-->  rescheduled (+ new occurrence)
--   scheduled --(non-initiator leaves)-->   scheduled, that cohort 'left'
--
-- None of confirm/decline/cancel checked the CURRENT status before acting, so
-- several transitions outside that set were reachable. Each function below
-- now takes the events row FOR UPDATE and asserts the state it expects —
-- which also serializes concurrent reps acting on the same event.


-- confirm_event_cohort -------------------------------------------------------
-- Two fixes:
--   * require status = 'proposed'. Without it, a confirmation arriving after
--     another cohort had already declined (event -> canceled) would find
--     remaining_pending = 0 and run `set status = 'scheduled'`, resurrecting a
--     canceled event — and the sync trigger would then stamp 'scheduled' onto
--     every attachment row including the declined one.
--   * lock the parent events row first. Two reps confirming the last two
--     pending cohorts concurrently could each, under READ COMMITTED, still
--     see the other's row as 'pending' and neither would flip the event to
--     'scheduled' — leaving it stuck in 'proposed' with nothing pending.
create or replace function confirm_event_cohort(
  p_event_id     uuid,
  p_acting_user  uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cohort_id         uuid;
  v_role              user_role;
  v_event_status      event_status;
  v_remaining_pending int;
  v_all_cohort_id     uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_role, v_cohort_id from users where id = p_acting_user;
  if v_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may confirm a combined lecture';
  end if;

  -- Serializes concurrent confirmations on this event; also the read of the
  -- status we are about to assert on.
  select status into v_event_status from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  if v_event_status is distinct from 'proposed' then
    raise exception
      'Event % is % — only a proposed event can be confirmed', p_event_id, v_event_status;
  end if;

  update event_cohorts
  set confirmation_status = 'confirmed', decided_by = p_acting_user, decided_at = now()
  where event_id = p_event_id and cohort_id = v_cohort_id and confirmation_status = 'pending';

  if not found then
    raise exception 'No pending confirmation for this cohort on event %', p_event_id;
  end if;

  select count(*) into v_remaining_pending
  from event_cohorts
  where event_id = p_event_id and confirmation_status = 'pending';

  if v_remaining_pending = 0 then
    -- The real conflict check: flipping to 'scheduled' is what makes both
    -- EXCLUDE constraints bite. A 23P01 here means someone else took the slot
    -- while this proposal was outstanding, which is the intended safety net.
    update events set status = 'scheduled', updated_at = now() where id = p_event_id;

    for v_all_cohort_id in
      select cohort_id from event_cohorts
      where event_id = p_event_id and confirmation_status = 'confirmed'
    loop
      perform notify_cohort_members(
        v_all_cohort_id, p_event_id, 'created',
        'Combined lecture confirmed',
        'Your combined lecture has been confirmed by all attached cohorts.'
      );
    end loop;
  end if;
end;
$$;


-- decline_event_cohort -------------------------------------------------------
-- Restricted to what TECHNICAL_DISCOVERY §7 always described: a decline is a PRE-confirmation
-- action. Previously it had no status guard and no 'pending' filter on the
-- attachment row, so:
--   * any attached rep could decline a fully 'scheduled' lecture and cancel
--     it for every other cohort — the exact outcome leave_event_cohort was
--     written to avoid, and a bypass of "only the initiator may cancel";
--   * the initiator could decline its own event (its row is 'confirmed', and
--     nothing filtered on that), duplicating cancel_event through a path with
--     weaker checks.
-- Requiring status = 'proposed' AND the caller's own row to be 'pending'
-- closes both: post-scheduling opt-out is leave_event_cohort, and the
-- initiator cancels via cancel_event.
create or replace function decline_event_cohort(
  p_event_id     uuid,
  p_acting_user  uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cohort_id    uuid;
  v_role         user_role;
  v_event_status event_status;
  v_other_cohort uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_role, v_cohort_id from users where id = p_acting_user;
  if v_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may decline a combined lecture';
  end if;

  select status into v_event_status from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  if v_event_status is distinct from 'proposed' then
    raise exception
      'Event % is % — declining only applies before confirmation. Use '
      'leave_event_cohort to opt out of a scheduled lecture, or cancel_event '
      'if you are the initiator.', p_event_id, v_event_status;
  end if;

  update event_cohorts
  set confirmation_status = 'declined', decided_by = p_acting_user, decided_at = now()
  where event_id = p_event_id
    and cohort_id = v_cohort_id
    and confirmation_status = 'pending';

  if not found then
    raise exception
      'Cohort has no pending confirmation on event % (the initiating cohort '
      'cannot decline its own proposal — use cancel_event)', p_event_id;
  end if;

  update events set status = 'canceled', updated_at = now() where id = p_event_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    p_event_id, 'canceled', p_acting_user,
    jsonb_build_object('reason', 'declined_by_cohort', 'cohort_id', v_cohort_id)
  );

  for v_other_cohort in
    select cohort_id from event_cohorts where event_id = p_event_id and cohort_id != v_cohort_id
  loop
    perform notify_cohort_members(
      v_other_cohort, p_event_id, 'combined_lecture_declined',
      'Combined lecture declined',
      'A cohort declined the proposed combined lecture, so it has been cancelled.',
      'class_rep'
    );
  end loop;
end;
$$;


-- cancel_event ---------------------------------------------------------------
-- Adds the status guard it never had. Cancelling an already-'canceled' event
-- re-notified every cohort for nothing; cancelling a 'rescheduled' one
-- rewrote a retired occurrence that a superseded_by chain still points at,
-- leaving the live replacement orphaned from its own history.
create or replace function cancel_event(
  p_event_id     uuid,
  p_acting_user  uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_status event_status;
  v_cohort_id    uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select status into v_event_status from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  if v_event_status not in ('proposed', 'scheduled') then
    raise exception 'Event % is already % and cannot be cancelled', p_event_id, v_event_status;
  end if;

  if not exists (
    select 1 from event_cohorts ec
    join users u on u.cohort_id = ec.cohort_id
    where ec.event_id = p_event_id
      and ec.is_initiator = true
      and u.id = p_acting_user
      and u.role = 'class_rep'
  ) then
    raise exception 'Only the initiating cohort''s class_rep may cancel this event';
  end if;

  update events set status = 'canceled', updated_at = now() where id = p_event_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (p_event_id, 'canceled', p_acting_user, jsonb_build_object('reason', 'canceled_by_initiator'));

  for v_cohort_id in
    select cohort_id from event_cohorts
    where event_id = p_event_id and confirmation_status not in ('declined', 'left')
  loop
    perform notify_cohort_members(
      v_cohort_id, p_event_id, 'canceled',
      'Lecture cancelled', 'A scheduled lecture has been cancelled.'
    );
  end loop;
end;
$$;


-- create_event ---------------------------------------------------------------
-- Unchanged behaviour, three added input checks. p_cohort_ids came straight
-- from the client into a FOREACH ... INSERT loop, so a repeated id produced a
-- primary-key violation on event_cohorts and a non-existent id produced an FK
-- violation — both surfacing as raw SQLSTATEs the client can't act on. An
-- empty array raised the bare "FOREACH expression must not be null".
create or replace function create_event(
  p_cohort_ids       uuid[],
  p_venue_id         uuid,
  p_course_id        uuid,
  p_lecturer_name    text,
  p_start            timestamptz,
  p_end              timestamptz,
  p_recurrence       recurrence_type,
  p_recurrence_rule  text,
  p_acting_user      uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_cohort_id uuid;
  v_caller_role      user_role;
  v_event_id         uuid;
  v_initial_status   event_status;
  v_cohort_ids       uuid[];
  v_cohort_id        uuid;
  v_missing          uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_caller_role, v_caller_cohort_id
  from users where id = p_acting_user;

  if v_caller_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may schedule an event';
  end if;

  -- Collapse duplicates before they reach the insert loop: attaching the same
  -- cohort twice is a client mistake, not a conflict.
  select array_agg(distinct c) into v_cohort_ids
  from unnest(coalesce(p_cohort_ids, '{}'::uuid[])) c
  where c is not null;

  if v_cohort_ids is null or array_length(v_cohort_ids, 1) is null then
    raise exception 'p_cohort_ids must contain at least one cohort';
  end if;

  if not (v_caller_cohort_id = any(v_cohort_ids)) then
    raise exception 'p_cohort_ids must include the acting rep''s own cohort';
  end if;

  select c into v_missing
  from unnest(v_cohort_ids) c
  where not exists (select 1 from cohorts where id = c)
  limit 1;

  if v_missing is not null then
    raise exception 'Cohort % does not exist', v_missing;
  end if;

  v_initial_status := case
    when array_length(v_cohort_ids, 1) > 1 then 'proposed'
    else 'scheduled'
  end;

  insert into events (
    title, venue_id, course_id, lecturer_name, start_time, end_time,
    recurrence, recurrence_rule, status, attendance_status,
    created_by, updated_by
  )
  values (
    null, p_venue_id, p_course_id, p_lecturer_name, p_start, p_end,
    p_recurrence, p_recurrence_rule, v_initial_status, 'pending',
    p_acting_user, p_acting_user
  )
  returning id into v_event_id;

  foreach v_cohort_id in array v_cohort_ids loop
    insert into event_cohorts (
      event_id, cohort_id, is_initiator, confirmation_status,
      decided_by, decided_at, start_time, end_time, event_status_cache
    )
    values (
      v_event_id, v_cohort_id, (v_cohort_id = v_caller_cohort_id),
      -- The ::cohort_confirmation_status cast is REQUIRED, and its absence is
      -- why create_event has never once run — see §3 below for the full story.
      (case when v_cohort_id = v_caller_cohort_id then 'confirmed' else 'pending' end
        )::cohort_confirmation_status,
      case when v_cohort_id = v_caller_cohort_id then p_acting_user else null end,
      case when v_cohort_id = v_caller_cohort_id then now() else null end,
      p_start, p_end, v_initial_status
    );
  end loop;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    v_event_id, 'created', p_acting_user,
    jsonb_build_object('cohort_ids', v_cohort_ids, 'initial_status', v_initial_status)
  );

  if v_initial_status = 'proposed' then
    foreach v_cohort_id in array v_cohort_ids loop
      if v_cohort_id != v_caller_cohort_id then
        perform notify_cohort_members(
          v_cohort_id, v_event_id, 'cohort_confirmation_needed',
          'Combined lecture needs your confirmation',
          'A class rep from another cohort has proposed a combined lecture with yours.',
          'class_rep'
        );
      end if;
    end loop;
  else
    perform notify_cohort_members(
      v_caller_cohort_id, v_event_id, 'created',
      'New lecture scheduled', 'A new lecture has been added to your schedule.'
    );
  end if;

  return v_event_id;
end;
$$;


-- ============================================================================
-- 2. Venue availability must agree with the venue conflict constraint
-- ============================================================================
-- events_no_venue_overlap covers ('proposed','scheduled') as of 0010, because
-- a pending combined-lecture proposal tentatively holds its room. These two
-- read functions still filtered on 'scheduled' alone, so the venue browser
-- advertised rooms as free that create_event then rejected with a raw 23P01 —
-- the one error path this whole feature exists to keep clients out of.
create or replace function get_venue_occupancy()
returns table (venue_id uuid, start_time timestamptz, end_time timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select e.venue_id, e.start_time, e.end_time
  from events e
  where e.status in ('proposed', 'scheduled');
$$;


-- ============================================================================
-- 3. The enum cast that stopped every event from ever being created
-- ============================================================================
-- create_event and reschedule_event both build event_cohorts rows with:
--
--   case when <is initiator> then 'confirmed' else 'pending' end
--
-- Both branches are bare quoted literals, so Postgres types the CASE as `text`
-- before the INSERT ever sees it — and there is no implicit text ->
-- cohort_confirmation_status cast, so the statement dies with
--
--   42804: column "confirmation_status" is of type cohort_confirmation_status
--          but expression is of type text
--
-- The subtle part, and the reason this survived four migrations: a BARE literal
-- in an INSERT is fine. `attendance_status` two lines down is populated by a
-- plain 'pending' and always worked, because an unknown-typed literal gets
-- coerced straight to the target column's type. Wrapping the same literals in a
-- CASE forces type resolution to happen first, and `text` is what comes out.
--
-- Consequence: create_event and reschedule_event have NEVER successfully run,
-- since 0010 introduced them. Applying a migration only defines a function, so
-- nothing exercised either one until the seed did. That also explains why the
-- events table has been empty this whole time, and why 0013's DELETE-path fix
-- could only be reasoned about rather than observed.
--
-- create_event is fixed inline in §1 above. reschedule_event's live definition
-- is 0013's, so it is restated here in full with the cast added. Everything else
-- is byte-for-byte 0013 — in particular the ordering fix (retire the old
-- occurrence BEFORE inserting the replacement, so the two do not collide on the
-- partial EXCLUDE indexes) is preserved exactly.
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
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_old from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  -- Same guard the other three mutations gained in §1: rescheduling a canceled
  -- or already-superseded occurrence would fork the superseded_by chain.
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

  -- 0013's ordering fix. Retiring the old occurrence first fires
  -- sync_event_cohorts_from_event, which pushes 'rescheduled' onto the old
  -- event_cohorts rows and releases their reserved slots — without this, the
  -- commonest reschedule of all (same room, shifted half an hour) collides with
  -- the very occurrence it replaces.
  update events
  set status = 'rescheduled', updated_by = p_acting_user, updated_at = now()
  where id = p_event_id;

  insert into events (
    title, venue_id, course_id, lecturer_name, start_time, end_time,
    recurrence, recurrence_rule, recurrence_group_id,
    status, attendance_status, created_by, updated_by
  )
  values (
    v_old.title, p_new_venue_id, v_old.course_id, v_old.lecturer_name,
    p_new_start, p_new_end, v_old.recurrence, v_old.recurrence_rule, v_old.recurrence_group_id,
    v_new_status, 'pending', p_acting_user, p_acting_user
  )
  returning id into v_new_id;

  foreach v_cid in array v_cohort_ids loop
    insert into event_cohorts (
      event_id, cohort_id, is_initiator, confirmation_status,
      decided_by, decided_at, start_time, end_time, event_status_cache
    )
    values (
      v_new_id, v_cid, (v_cid = v_initiator_cohort_id),
      -- The fix.
      (case when v_cid = v_initiator_cohort_id then 'confirmed' else 'pending' end
        )::cohort_confirmation_status,
      case when v_cid = v_initiator_cohort_id then p_acting_user else null end,
      case when v_cid = v_initiator_cohort_id then now() else null end,
      p_new_start, p_new_end, v_new_status
    );
  end loop;

  -- Touches no column the sync trigger watches, so event_cohorts stays put.
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

revoke execute on function reschedule_event(uuid, timestamptz, timestamptz, uuid, uuid) from public, anon;
grant  execute on function reschedule_event(uuid, timestamptz, timestamptz, uuid, uuid) to authenticated, service_role;


-- ============================================================================
-- 4. sync_event_cohorts_from_event: make its privilege explicit
-- ============================================================================
-- The only trigger function in the schema that wasn't SECURITY DEFINER. It
-- writes to event_cohorts, which has RLS on and no UPDATE policy, and it only
-- worked because every path that fires it runs inside a SECURITY DEFINER
-- function owned by the table owner. That is true today and invisible in the
-- function itself — one future non-definer writer to events.start_time and
-- the denormalized cache silently stops tracking the event it mirrors, taking
-- the self-overlap constraint's accuracy with it.
create or replace function sync_event_cohorts_from_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update event_cohorts
  set start_time = NEW.start_time,
      end_time = NEW.end_time,
      event_status_cache = NEW.status
  where event_id = NEW.id;
  return NEW;
end;
$$;

revoke execute on function sync_event_cohorts_from_event() from public, anon, authenticated, service_role;


