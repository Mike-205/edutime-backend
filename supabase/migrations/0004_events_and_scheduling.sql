-- ============================================================================
-- 0004: Events + scheduling — the heart of the system
-- ============================================================================

create type event_status as enum ('scheduled', 'canceled', 'rescheduled');

-- audit_action: 'rescheduled' is distinct from 'updated' because a
-- reschedule is a two-row event (old row dies with a pointer to the new one
-- via events.superseded_by, new row is 'created'), not a simple field edit.
create type audit_action as enum ('created', 'updated', 'canceled', 'rescheduled');

-- notif_type: drives what a student/rep is actually pinged about.
-- 'confirmation_needed' powers the class rep's "call this lecturer" nudge.
create type notif_type as enum (
  'created', 'updated', 'canceled', 'rescheduled', 'confirmation_needed'
);

-- attendance_status: DAY-OF verification layer, separate from event_status.
-- Answers one narrow question — "has a class rep confirmed with the
-- lecturer that they're actually coming?" No third "absent" value: when a
-- lecturer says they're not coming, that's not an attendance outcome, it's
-- an event_status change (rep cancels/reschedules on the lecturer's
-- behalf). Never affects conflict detection — only event_status does.
create type attendance_status as enum ('pending', 'confirmed');

-- Needed for the EXCLUDE constraints below (uuid equality + tstzrange
-- overlap in one constraint).
create extension if not exists btree_gist;


-- Event ----------------------------------------------------------------------
-- Materialized occurrences (one row per occurrence; recurrence_rule is
-- display metadata only). lecturer_name stays FREE TEXT — lecturer accounts
-- remain out of scope.
create table events (
  id                    uuid primary key default gen_random_uuid(),
  cohort_id             uuid not null references cohorts (id) on delete cascade,
  title                 text,
  venue_id              uuid not null references venues (id) on delete restrict,
  course_id             uuid not null references courses (id) on delete restrict,
  lecturer_name         text not null,
  start_time            timestamptz not null,
  end_time              timestamptz not null,
  recurrence            recurrence_type not null default 'none',
  recurrence_rule       text, -- iCal RRULE string
  recurrence_group_id   uuid,
  status                event_status not null default 'scheduled',

  attendance_status         attendance_status not null default 'pending',
  attendance_confirmed_by   uuid references users (id),
  attendance_confirmed_at   timestamptz,

  -- Set on the OLD row when rescheduled: points to the NEW row that
  -- replaced it. App layer must set this + status='rescheduled' atomically
  -- alongside creating the replacement row (see reschedule_event() below).
  superseded_by         uuid references events (id) on delete set null,

  created_by            uuid not null references users (id) on delete restrict,
  updated_by            uuid references users (id) on delete restrict,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint events_time_order check (end_time > start_time)
);

comment on column events.attendance_status is
  'Day-of verification that the lecturer confirmed attendance. Independent '
  'of event_status; only meaningful while status = scheduled.';
comment on column events.attendance_confirmed_by is
  'The class_rep who made the confirmation call, NOT the lecturer '
  '(lecturers have no accounts). Proxy-action, same pattern as '
  'event_audit_log.changed_by.';
comment on column events.superseded_by is
  'Set on the OLD row when an event is rescheduled: points to the NEW row '
  'that replaced it.';

create index events_cohort_idx   on events (cohort_id);
create index events_venue_idx    on events (venue_id);
create index events_course_idx   on events (course_id);
create index events_group_idx    on events (recurrence_group_id);
-- Calendar reads are always "this cohort, this date window": composite index.
create index events_calendar_idx on events (cohort_id, start_time, end_time);

-- Confirmation dashboard: "what do I need to call about, soonest first".
-- Partial because 'pending' is a small minority of rows at any given time —
-- keeps the index small instead of covering every event ever made.
create index events_pending_confirmation_idx
  on events (start_time)
  where attendance_status = 'pending' and status = 'scheduled';


-- ----------------------------------------------------------------------------
-- Conflict detection: two independent EXCLUDE constraints
-- ----------------------------------------------------------------------------
-- Both are scoped to status = 'scheduled' only — canceled/rescheduled rows
-- must never block a new booking, they're historical.

-- Rule 1: no two cohorts (or the same cohort) can hold overlapping events in
-- the SAME VENUE. Physical venues are shared reference rows (one per room,
-- see venues_room_idx in 0001), so this catches cross-cohort double-booking.
-- Online venues are created fresh per-event and never share venue_id, so
-- they never falsely trip this.
alter table events
  add constraint events_no_venue_overlap
  exclude using gist (
    venue_id with =,
    tstzrange(start_time, end_time) with &&
  )
  where (status = 'scheduled');

-- Rule 2: "no self-overlap" — the SAME cohort cannot have two events
-- scheduled at overlapping times regardless of venue (a class can't be in
-- two places at once, or double-booked into two lectures back to back with
-- no travel time even in different rooms).
alter table events
  add constraint events_no_cohort_self_overlap
  exclude using gist (
    cohort_id with =,
    tstzrange(start_time, end_time) with &&
  )
  where (status = 'scheduled');


-- Convenience view: walk past dead 'rescheduled' rows to the live occurrence.
create or replace view events_current as
select *
from events e
where e.status != 'rescheduled'
   or e.superseded_by is null;


-- EventAuditLog --------------------------------------------------------------
-- Append-only. snapshot holds event state (JSON) at the time of the action.
create table event_audit_log (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references events (id) on delete cascade,
  action     audit_action not null,
  changed_by uuid not null references users (id) on delete restrict,
  changed_at timestamptz not null default now(),
  snapshot   jsonb not null
);

create index event_audit_log_event_idx on event_audit_log (event_id);


-- ----------------------------------------------------------------------------
-- Reschedule as an atomic operation
-- ----------------------------------------------------------------------------
-- Wraps: mark old row rescheduled + linked, insert new row, write BOTH
-- audit log entries ('rescheduled' on old, 'created' on new). Doing this as
-- one function instead of separate client-side writes is what actually
-- guarantees the audit trail and superseded_by link stay consistent —
-- something RLS alone can't enforce across two tables and two rows.
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
as $$
declare
  v_old events%rowtype;
  v_new_id uuid;
begin
  select * into v_old from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  insert into events (
    cohort_id, title, venue_id, course_id, lecturer_name,
    start_time, end_time, recurrence, recurrence_rule, recurrence_group_id,
    status, attendance_status, created_by, updated_by
  )
  values (
    v_old.cohort_id, v_old.title, p_new_venue_id, v_old.course_id, v_old.lecturer_name,
    p_new_start, p_new_end, v_old.recurrence, v_old.recurrence_rule, v_old.recurrence_group_id,
    'scheduled', 'pending', p_acting_user, p_acting_user
  )
  returning id into v_new_id;

  update events
  set status = 'rescheduled',
      superseded_by = v_new_id,
      updated_by = p_acting_user,
      updated_at = now()
  where id = p_event_id;

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    p_event_id, 'rescheduled', p_acting_user,
    jsonb_build_object('superseded_by', v_new_id, 'old_start', v_old.start_time, 'old_end', v_old.end_time)
  );

  insert into event_audit_log (event_id, action, changed_by, snapshot)
  values (
    v_new_id, 'created', p_acting_user,
    jsonb_build_object('rescheduled_from', p_event_id, 'start', p_new_start, 'end', p_new_end)
  );

  return v_new_id;
end;
$$;


-- Notification ---------------------------------------------------------------
create table notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users (id) on delete cascade,
  event_id   uuid references events (id) on delete set null,
  title      text not null,
  message    text not null,
  type       notif_type not null,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_user_idx on notifications (user_id);
