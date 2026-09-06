-- ============================================================================
-- 0013: Three fixes surfaced after the combined-lectures work landed
-- ============================================================================
--   1. reschedule_event inserted the replacement occurrence while the old one
--      was still 'scheduled', so both EXCLUDE constraints saw the event twice
--      and any overlapping move failed.
--   2. The realtime broadcast trigger referenced NEW on DELETE (a runtime
--      error), and had lost the 'deleted' action it had back in 0005.
--   3. The cohort calendar index dropped in 0010 was never rebuilt on
--      event_cohorts, where cohort_id now lives.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. reschedule_event — retire the old occurrence BEFORE inserting the new one
-- ----------------------------------------------------------------------------
-- The old ordering (insert new -> retire old) meant that at the moment the
-- replacement row was written, the original was still status = 'scheduled'
-- and its event_cohorts rows still cached 'scheduled'. Both partial EXCLUDE
-- constraints therefore counted the event twice:
--
--   * events_no_venue_overlap        where status in ('proposed','scheduled')
--   * event_cohorts_no_self_overlap  where event_status_cache in (...)
--
-- So the single most common reschedule — same room, shifted half an hour —
-- collided with the very occurrence it was replacing. Only moves that cleared
-- the original's time range entirely got through.
--
-- Flipping the old row to 'rescheduled' first drops it out of both partial
-- indexes (the sync_event_cohorts_from_event trigger propagates the status to
-- its event_cohorts rows), freeing the slot before the replacement claims it.
-- superseded_by still has to be set afterwards, since it needs the new id —
-- that second UPDATE touches neither start_time, end_time nor status, so it
-- doesn't re-fire the sync trigger.
--
-- The old row stays FOR UPDATE-locked for the whole function, so no
-- concurrent writer can slip into the released slot mid-reschedule.
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

  -- Guard: FOREACH over a null array is a bare "FOREACH expression must not
  -- be null" with no context. Shouldn't be reachable (an event every cohort
  -- walked away from is already canceled), but the clear message is free.
  if v_cohort_ids is null or array_length(v_cohort_ids, 1) is null then
    raise exception 'Event % has no participating cohorts left to reschedule', p_event_id;
  end if;

  v_new_status := case
    when array_length(v_cohort_ids, 1) > 1 then 'proposed'
    else 'scheduled'
  end;

  -- Retire the old occurrence FIRST — this is the ordering fix. Fires
  -- sync_event_cohorts_from_event, which pushes 'rescheduled' onto the old
  -- event_cohorts rows and releases their reserved slots.
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
      case when v_cid = v_initiator_cohort_id then 'confirmed' else 'pending' end,
      case when v_cid = v_initiator_cohort_id then p_acting_user else null end,
      case when v_cid = v_initiator_cohort_id then now() else null end,
      p_new_start, p_new_end, v_new_status
    );
  end loop;

  -- Now that the replacement exists, link the old row to it. Touches no
  -- column the sync trigger watches, so event_cohorts stays as it is.
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

revoke execute on function reschedule_event(uuid, timestamptz, timestamptz, uuid, uuid) from anon;


-- ----------------------------------------------------------------------------
-- 2. Realtime broadcast trigger — make DELETE actually work
-- ----------------------------------------------------------------------------
-- Two problems with the 0010 version:
--
--   a) It opened with `coalesce(NEW.id, OLD.id)`. In a DELETE trigger NEW is
--      an unassigned record, and touching any field of it (or the record as a
--      whole, as the trailing `return coalesce(NEW, OLD)` also did) raises
--      "record new is not assigned yet". A DELETE on events would abort. The
--      app never hard-deletes events — it cancels — so this only ever bites a
--      manual/superadmin cleanup, which is exactly when you least want an
--      opaque trigger error.
--
--   b) The action CASE had no DELETE branch, so a delete would have
--      broadcast 'updated'. 0005 emitted 'deleted' here; 0010 lost it in the
--      multi-cohort rewrite. Restored.
--
-- Timing also has to change for the delete case. event_cohorts.event_id is
-- ON DELETE CASCADE, so by the time an AFTER DELETE trigger on events runs,
-- the rows naming the cohorts to broadcast to may already be gone — the loop
-- would find nothing and silently notify no one. A BEFORE DELETE trigger
-- still sees them. Broadcasting early is safe: realtime.broadcast_changes
-- writes into realtime.messages transactionally, so a rolled-back delete
-- sends nothing.
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
           and OLD.attendance_status = 'pending' then 'confirmation_needed'
      else 'updated'
    end;
  end if;

  for v_cohort_id in select cohort_id from event_cohorts where event_id = v_event_id loop
    perform realtime.broadcast_changes(
      'cohort:' || v_cohort_id || ':events',
      change_action,
      TG_OP,
      TG_TABLE_NAME,
      TG_TABLE_SCHEMA,
      jsonb_build_object('id', v_event_id),
      jsonb_build_object('id', v_event_id)
    );
  end loop;

  -- Never `coalesce(NEW, OLD)` — see (a) above. And returning OLD rather
  -- than NULL matters on the BEFORE DELETE path: NULL would cancel the
  -- delete outright.
  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  return NEW;
end;
$$;

revoke execute on function notify_cohort_event_change() from public, anon, authenticated;

drop trigger if exists events_broadcast_trigger on events;

create trigger events_broadcast_trigger
after insert or update on events
for each row
execute function notify_cohort_event_change();

create trigger events_broadcast_delete_trigger
before delete on events
for each row
execute function notify_cohort_event_change();


-- ----------------------------------------------------------------------------
-- 3. Rebuild the calendar index on event_cohorts
-- ----------------------------------------------------------------------------
-- 0004 had events_calendar_idx (cohort_id, start_time, end_time) for the one
-- query every student runs constantly: "my cohort's lectures in this date
-- window". 0010 dropped it along with events.cohort_id and never rebuilt it
-- on event_cohorts, which is where cohort_id + the denormalized time range
-- now live. Same index, new home.
create index if not exists event_cohorts_calendar_idx
  on event_cohorts (cohort_id, start_time, end_time);

-- event_cohorts_cohort_idx (cohort_id) is now a strict prefix of the above
-- and earns nothing — including for the cohorts FK's cascade lookups, which
-- the composite serves just as well.
drop index if exists event_cohorts_cohort_idx;
