-- ============================================================================
-- 0012: Post-scheduling opt-out + notifications
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Widen the self-overlap EXCLUDE to release a cohort's reserved slot the
--    moment they leave, without affecting anyone else's confirmed booking
-- ----------------------------------------------------------------------------
alter table event_cohorts drop constraint if exists event_cohorts_no_self_overlap;

alter table event_cohorts
  add constraint event_cohorts_no_self_overlap
  exclude using gist (
    cohort_id with =,
    tstzrange(start_time, end_time) with &&
  )
  where (
    event_status_cache in ('proposed', 'scheduled')
    and confirmation_status <> 'left'
  );


-- ----------------------------------------------------------------------------
-- 2. Notification helper — inserts one row per matching user, optionally
--    filtered to a single role (e.g. only class reps, for confirmation
--    requests that don't concern regular students yet).
-- ----------------------------------------------------------------------------
create or replace function notify_cohort_members(
  p_cohort_id   uuid,
  p_event_id    uuid,
  p_type        notif_type,
  p_title       text,
  p_message     text,
  p_role_filter user_role default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into notifications (user_id, event_id, title, message, type)
  select u.id, p_event_id, p_title, p_message, p_type
  from users u
  where u.cohort_id = p_cohort_id
    and (p_role_filter is null or u.role = p_role_filter);
end;
$$;

-- Internal helper only — never called directly via RPC, so no execute
-- grant needed for anon/authenticated at all.
revoke execute on function notify_cohort_members(uuid, uuid, notif_type, text, text, user_role) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. leave_event_cohort — a non-initiating rep opts their cohort out of an
--    already-scheduled combined lecture, without cancelling it for anyone
--    else. The initiator cannot use this (must use cancel_event instead) —
--    an event needs exactly one owner at all times.
-- ----------------------------------------------------------------------------
create or replace function leave_event_cohort(
  p_event_id     uuid,
  p_acting_user  uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cohort_id       uuid;
  v_role            user_role;
  v_is_initiator    boolean;
  v_event_status    event_status;
  v_initiator_cohort_id uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_role, v_cohort_id from users where id = p_acting_user;
  if v_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may remove a cohort from an event';
  end if;

  select status into v_event_status from events where id = p_event_id;
  if v_event_status is distinct from 'scheduled' then
    raise exception 'Only a fully scheduled event supports leaving — use decline_event_cohort before confirmation';
  end if;

  select is_initiator into v_is_initiator
  from event_cohorts where event_id = p_event_id and cohort_id = v_cohort_id;

  if v_is_initiator is null then
    raise exception 'Cohort is not attached to event %', p_event_id;
  end if;

  if v_is_initiator then
    raise exception 'The initiating cohort cannot leave its own event — use cancel_event instead';
  end if;

  update event_cohorts
  set confirmation_status = 'left', decided_by = p_acting_user, decided_at = now()
  where event_id = p_event_id and cohort_id = v_cohort_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (p_event_id, 'updated', p_acting_user, jsonb_build_object('reason', 'cohort_left', 'cohort_id', v_cohort_id));

  select cohort_id into v_initiator_cohort_id
  from event_cohorts where event_id = p_event_id and is_initiator = true;

  perform notify_cohort_members(
    v_initiator_cohort_id, p_event_id, 'combined_lecture_declined',
    'A cohort has left your combined lecture',
    'One of the cohorts attached to your combined lecture has opted out. The lecture continues for the remaining cohorts.',
    'class_rep'
  );
end;
$$;

revoke execute on function leave_event_cohort(uuid, uuid) from anon;


-- ----------------------------------------------------------------------------
-- 4. Wire notifications into the existing event-mutation functions
-- ----------------------------------------------------------------------------

-- create_event: proposal -> notify non-initiator reps only (nothing shown
-- to students yet, since it isn't real until everyone confirms). Plain
-- single-cohort event -> notify everyone in that cohort immediately.
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

  if not (v_caller_cohort_id = any(p_cohort_ids)) then
    raise exception 'p_cohort_ids must include the acting rep''s own cohort';
  end if;

  v_initial_status := case
    when array_length(p_cohort_ids, 1) > 1 then 'proposed'
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

  foreach v_cohort_id in array p_cohort_ids loop
    insert into event_cohorts (
      event_id, cohort_id, is_initiator, confirmation_status,
      decided_by, decided_at, start_time, end_time, event_status_cache
    )
    values (
      v_event_id, v_cohort_id, (v_cohort_id = v_caller_cohort_id),
      case when v_cohort_id = v_caller_cohort_id then 'confirmed' else 'pending' end,
      case when v_cohort_id = v_caller_cohort_id then p_acting_user else null end,
      case when v_cohort_id = v_caller_cohort_id then now() else null end,
      p_start, p_end, v_initial_status
    );
  end loop;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    v_event_id, 'created', p_acting_user,
    jsonb_build_object('cohort_ids', p_cohort_ids, 'initial_status', v_initial_status)
  );

  if v_initial_status = 'proposed' then
    foreach v_cohort_id in array p_cohort_ids loop
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

revoke execute on function create_event(uuid[], uuid, uuid, text, timestamptz, timestamptz, recurrence_type, text, uuid) from anon;


-- confirm_event_cohort: once the LAST cohort confirms, notify everyone in
-- every attached cohort — the lecture is now real for all of them.
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
    update events set status = 'scheduled', updated_at = now() where id = p_event_id;

    for v_all_cohort_id in select cohort_id from event_cohorts where event_id = p_event_id loop
      perform notify_cohort_members(
        v_all_cohort_id, p_event_id, 'created',
        'Combined lecture confirmed',
        'Your combined lecture has been confirmed by all attached cohorts.'
      );
    end loop;
  end if;
end;
$$;

revoke execute on function confirm_event_cohort(uuid, uuid) from anon;


-- decline_event_cohort: notify the class reps of every attached cohort —
-- students aren't notified since the event never became real for them.
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
  v_cohort_id     uuid;
  v_role          user_role;
  v_other_cohort  uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_role, v_cohort_id from users where id = p_acting_user;
  if v_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may decline a combined lecture';
  end if;

  update event_cohorts
  set confirmation_status = 'declined', decided_by = p_acting_user, decided_at = now()
  where event_id = p_event_id and cohort_id = v_cohort_id;

  if not found then
    raise exception 'Cohort is not attached to event %', p_event_id;
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

revoke execute on function decline_event_cohort(uuid, uuid) from anon;


-- cancel_event: fully scheduled event cancelled by its initiator — notify
-- EVERYONE in every attached cohort, since this was real and visible.
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
  v_cohort_id uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
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

revoke execute on function cancel_event(uuid, uuid) from anon;


-- reschedule_event: notify everyone attached to the OLD occurrence that it
-- moved; if the new occurrence is a combined proposal again, also notify
-- the non-initiator reps that reconfirmation is needed.
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

  v_new_status := case
    when array_length(v_cohort_ids, 1) > 1 then 'proposed'
    else 'scheduled'
  end;

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
      case when v_cid = v_initiator_cohort_id then 'confirmed' else 'pending' end,
      case when v_cid = v_initiator_cohort_id then p_acting_user else null end,
      case when v_cid = v_initiator_cohort_id then now() else null end,
      p_new_start, p_new_end, v_new_status
    );
  end loop;

  update events
  set status = 'rescheduled', superseded_by = v_new_id, updated_by = p_acting_user, updated_at = now()
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