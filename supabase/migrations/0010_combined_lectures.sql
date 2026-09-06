-- ============================================================================
-- 0010: Combined (cross-cohort) lectures
-- ============================================================================
-- Structural shift: events.cohort_id was a single not-null FK. A combined
-- lecture needs ONE event attached to MULTIPLE cohorts, so this migration
-- replaces that column with a proper join table (event_cohorts) carrying
-- the per-cohort proposal/confirmation state, and reworks everything that
-- previously assumed a single cohort per event: the self-overlap conflict
-- constraint, RLS, and the realtime broadcast trigger.
--
-- event_cohorts denormalizes start_time/end_time/status from the parent
-- event (kept in sync by a trigger below). This is necessary because
-- Postgres EXCLUDE constraints can't reference a joined table — the
-- self-overlap check needs cohort_id + a time range on the SAME row.
-- ============================================================================

create type cohort_confirmation_status as enum ('pending', 'confirmed', 'declined');


-- ----------------------------------------------------------------------------
-- 1. event_cohorts join table
-- ----------------------------------------------------------------------------
create table event_cohorts (
  event_id             uuid not null references events (id) on delete cascade,
  cohort_id            uuid not null references cohorts (id) on delete cascade,

  -- The cohort whose rep created the event. Only the initiator can cancel
  -- the event outright; other cohorts can only confirm/decline their own
  -- participation. Exactly one true per event_id — enforced below.
  is_initiator         boolean not null default false,

  confirmation_status  cohort_confirmation_status not null default 'pending',
  decided_by           uuid references users (id),
  decided_at           timestamptz,

  -- Denormalized from events, kept in sync by sync_event_cohorts_from_event()
  -- below. Exists purely so the self-overlap EXCLUDE constraint (section 3)
  -- has a time range + status to check on this table directly.
  start_time           timestamptz not null,
  end_time             timestamptz not null,
  event_status_cache   event_status not null,

  primary key (event_id, cohort_id)
);

create index event_cohorts_cohort_idx on event_cohorts (cohort_id);
create index event_cohorts_event_idx  on event_cohorts (event_id);

create unique index event_cohorts_one_initiator_per_event
  on event_cohorts (event_id)
  where is_initiator = true;

-- Confirmation dashboard for reps of NON-initiating cohorts: "combined
-- lectures waiting on my confirmation".
create index event_cohorts_pending_confirmation_idx
  on event_cohorts (cohort_id, start_time)
  where confirmation_status = 'pending';


-- ----------------------------------------------------------------------------
-- 2. Migrate existing single-cohort events into the join table, then drop
--    the old column and everything keyed on it
-- ----------------------------------------------------------------------------
insert into event_cohorts (
  event_id, cohort_id, is_initiator, confirmation_status,
  decided_by, decided_at, start_time, end_time, event_status_cache
)
select
  id, cohort_id, true, 'confirmed',
  created_by, created_at, start_time, end_time, status
from events;

-- Everything that references events.cohort_id must go BEFORE the column
-- itself, or Postgres refuses the drop (SQLSTATE 2BP01). Views expand
-- `select *` into an explicit column list at creation time, and RLS policy
-- expressions store real parsed column references — both count as hard
-- dependencies. DROP COLUMN ... CASCADE would clear them, but it would also
-- silently take out audit_log_read_own_cohort (on a different table
-- entirely), leaving event_audit_log with RLS on and no SELECT policy —
-- i.e. unreadable to everyone, with nothing in the logs saying so. Explicit
-- drops keep that visible.

-- 0004's convenience view: `select *` pinned cohort_id into its definition.
-- Recreated below, after the column is gone.
drop view if exists events_current;

-- 0006's events policies. These were previously dropped in section 12, far
-- too late to help — moved here. Section 12 recreates the replacement
-- (events_read_attached_cohort).
drop policy if exists events_read_own_cohort           on events;
drop policy if exists events_write_class_rep_own_cohort  on events;
drop policy if exists events_update_class_rep_own_cohort on events;

-- 0006's audit-log policy lives on event_audit_log but reaches into
-- events.cohort_id, so it blocks the drop too. Recreated in section 12
-- against event_cohorts.
drop policy if exists audit_log_read_own_cohort on event_audit_log;

drop index if exists events_cohort_idx;
drop index if exists events_calendar_idx;
alter table events drop constraint if exists events_no_cohort_self_overlap;
alter table events drop column cohort_id;

-- Recreated now that cohort_id is gone. security_invoker = true so the
-- caller's RLS on events still applies when reading through the view —
-- without it the view runs with the owner's privileges and quietly bypasses
-- events_read_attached_cohort, the same security-definer-view problem 0008
-- fixed for venue_occupancy.
create view events_current with (security_invoker = true) as
select *
from events e
where e.status != 'rescheduled'
   or e.superseded_by is null;

grant select on events_current to authenticated;


-- ----------------------------------------------------------------------------
-- 3. Self-overlap conflict constraint moves to event_cohorts
-- ----------------------------------------------------------------------------
-- Same rule as before ("a cohort can't be in two overlapping lectures"),
-- just relocated to the table that now actually carries cohort_id.
-- Includes BOTH 'proposed' and 'scheduled' so a pending combined-lecture
-- proposal tentatively reserves each attached cohort's slot — without
-- this, two unrelated proposals could both sail through and only collide
-- when someone tries to confirm.
alter table event_cohorts
  add constraint event_cohorts_no_self_overlap
  exclude using gist (
    cohort_id with =,
    tstzrange(start_time, end_time) with &&
  )
  where (event_status_cache in ('proposed', 'scheduled'));


-- ----------------------------------------------------------------------------
-- 4. Venue-overlap constraint: widen to also tentatively hold during
--    'proposed', same reasoning as above
-- ----------------------------------------------------------------------------
alter table events drop constraint if exists events_no_venue_overlap;

alter table events
  add constraint events_no_venue_overlap
  exclude using gist (
    venue_id with =,
    tstzrange(start_time, end_time) with &&
  )
  where (status in ('proposed', 'scheduled'));


-- ----------------------------------------------------------------------------
-- 5. Keep event_cohorts' denormalized columns in sync with events
-- ----------------------------------------------------------------------------
create or replace function sync_event_cohorts_from_event()
returns trigger
language plpgsql
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

create trigger sync_event_cohorts_trigger
  after update of start_time, end_time, status on events
  for each row
  execute function sync_event_cohorts_from_event();


-- ----------------------------------------------------------------------------
-- 6. create_event — replaces ad-hoc client inserts. Handles both the plain
--    single-cohort case and the combined-lecture proposal case in one call.
-- ----------------------------------------------------------------------------
create or replace function create_event(
  p_cohort_ids       uuid[],   -- must include the caller's own cohort
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
  v_initial_status    event_status;
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

  -- Single-cohort events skip the proposal step entirely — nothing to
  -- confirm with yourself. Combined events start 'proposed'.
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

  return v_event_id;
end;
$$;

revoke execute on function create_event(uuid[], uuid, uuid, text, timestamptz, timestamptz, recurrence_type, text, uuid) from anon;


-- ----------------------------------------------------------------------------
-- 7. confirm_event_cohort — a non-initiating rep confirms their cohort's
--    participation. Flips the whole event to 'scheduled' once every
--    attached cohort has confirmed.
-- ----------------------------------------------------------------------------
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
  v_cohort_id      uuid;
  v_role           user_role;
  v_remaining_pending int;
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
    -- Last confirmation: flip to scheduled. This is where the venue/
    -- self-overlap EXCLUDE constraints actually get evaluated for real —
    -- if something else took the slot in the meantime, this update fails
    -- with a conflict error, which is the intended safety net.
    update events set status = 'scheduled', updated_at = now() where id = p_event_id;
  end if;
end;
$$;

revoke execute on function confirm_event_cohort(uuid, uuid) from anon;


-- ----------------------------------------------------------------------------
-- 8. decline_event_cohort — any attached rep declines; whole event cancels
-- ----------------------------------------------------------------------------
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
  v_cohort_id uuid;
  v_role      user_role;
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
end;
$$;

revoke execute on function decline_event_cohort(uuid, uuid) from anon;


-- ----------------------------------------------------------------------------
-- 9. cancel_event — initiator-only, full cancellation
-- ----------------------------------------------------------------------------
-- Deliberately restricted to the initiating cohort's rep. A non-initiating
-- rep who wants out before confirmation should use decline_event_cohort
-- instead. Opting a single cohort OUT of an already-scheduled combined
-- lecture (without cancelling it for everyone else) is NOT handled here —
-- flagged as a known open item.
create or replace function cancel_event(
  p_event_id     uuid,
  p_acting_user  uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
end;
$$;

revoke execute on function cancel_event(uuid, uuid) from anon;


-- ----------------------------------------------------------------------------
-- 10. reschedule_event — rewritten for multi-cohort events
-- ----------------------------------------------------------------------------
-- For a combined lecture, rescheduling re-opens confirmation: the new
-- occurrence starts 'proposed' again with every non-initiating cohort
-- reset to 'pending', since a new time may not work for everyone who
-- agreed to the old one. For a single-cohort event, behaves as before —
-- goes straight back to 'scheduled'.
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
  from event_cohorts where event_id = p_event_id;

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

  return v_new_id;
end;
$$;


-- ----------------------------------------------------------------------------
-- 11. Realtime broadcast: fan out to EVERY attached cohort, not just one
-- ----------------------------------------------------------------------------
create or replace function notify_cohort_event_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id   uuid;
  v_cohort_id  uuid;
  change_action text;
begin
  v_event_id := coalesce(NEW.id, OLD.id);

  change_action := case
    when TG_OP = 'INSERT' then 'created'
    when TG_OP = 'UPDATE' and NEW.status = 'canceled' and OLD.status != 'canceled' then 'canceled'
    when TG_OP = 'UPDATE' and NEW.status = 'rescheduled' and OLD.status != 'rescheduled' then 'rescheduled'
    when TG_OP = 'UPDATE' and NEW.status = 'scheduled' and OLD.status = 'proposed' then 'confirmed'
    when TG_OP = 'UPDATE' and NEW.attendance_status = 'confirmed' and OLD.attendance_status = 'pending' then 'confirmation_needed'
    else 'updated'
  end;

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

  return coalesce(NEW, OLD);
end;
$$;
-- Trigger definition (events_broadcast_trigger) from 0005 still applies —
-- create or replace above updates its underlying function in place.

-- Also broadcast when a NEW cohort gets attached (i.e. when a proposal is
-- first created) so the non-initiating rep's device gets pinged even
-- though the events row itself isn't being updated at that instant.
create or replace function notify_new_event_cohort()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.confirmation_status = 'pending' then
    perform realtime.broadcast_changes(
      'cohort:' || NEW.cohort_id || ':events',
      'cohort_confirmation_needed',
      TG_OP,
      TG_TABLE_NAME,
      TG_TABLE_SCHEMA,
      jsonb_build_object('event_id', NEW.event_id),
      jsonb_build_object('event_id', NEW.event_id)
    );
  end if;
  return NEW;
end;
$$;

create trigger event_cohorts_broadcast_trigger
after insert on event_cohorts
for each row
execute function notify_new_event_cohort();


-- ----------------------------------------------------------------------------
-- 12. RLS updates
-- ----------------------------------------------------------------------------
-- events: mutations now happen exclusively through the SECURITY DEFINER
-- functions above (create_event, confirm/decline_event_cohort, cancel_event,
-- reschedule_event), each of which does its own auth.uid()/role/scope
-- checks inline. So events no longer needs (or should have) direct
-- client-facing INSERT/UPDATE policies — the old 0006 ones were already
-- dropped in section 2 (they had to be, to unblock the column drop).

create policy events_read_attached_cohort
  on events for select
  using (
    exists (
      select 1 from event_cohorts ec
      join users u on u.cohort_id = ec.cohort_id
      where ec.event_id = events.id and u.id = auth.uid()
    )
  );

-- event_cohorts: readable by any user whose cohort is attached to that same
-- event (so they can see "this is a combined lecture with cohorts X, Y").
-- No direct insert/update/delete policy — all writes go through the
-- functions above.
alter table event_cohorts enable row level security;

create policy event_cohorts_read_if_attached
  on event_cohorts for select
  using (
    exists (
      select 1 from event_cohorts ec2
      join users u on u.cohort_id = ec2.cohort_id
      where ec2.event_id = event_cohorts.event_id and u.id = auth.uid()
    )
  );

-- event_audit_log: same rule as before ("readable by members of the cohort
-- this event belongs to"), rerouted through event_cohorts now that events
-- has no cohort_id. For a combined lecture every attached cohort sees the
-- trail, which matches who can see the event itself.
-- Still no insert/update/delete policy — writes stay inside the
-- SECURITY DEFINER functions.
create policy audit_log_read_own_cohort
  on event_audit_log for select
  using (
    exists (
      select 1 from event_cohorts ec
      join users u on u.cohort_id = ec.cohort_id
      where ec.event_id = event_audit_log.event_id and u.id = auth.uid()
    )
  );