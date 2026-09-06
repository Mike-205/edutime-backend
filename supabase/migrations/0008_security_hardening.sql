-- ============================================================================
-- 0008: Security hardening (fixes from Supabase Advisor)
-- ============================================================================
-- Two categories of fix here:
--   1. Lint-level hygiene: search_path pinning, extension schema, the
--      security-definer view.
--   2. A REAL gap the lint indirectly surfaced: several privileged functions
--      took an "acting user" parameter (p_acting_user, p_decided_by,
--      p_created_by, p_demoted_by, p_user_id) and trusted whatever the
--      caller passed in, without checking it actually matched auth.uid().
--      That meant any authenticated user could call these RPCs and claim
--      to be acting as someone else — a class rep impersonating a
--      different class rep, or worse. Fixed by requiring the parameter to
--      equal auth.uid() (or being dropped as a parameter entirely and
--      replaced with auth.uid() directly).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Move btree_gist out of the public schema
-- ----------------------------------------------------------------------------
create schema if not exists extensions;
alter extension btree_gist set schema extensions;
-- Supabase's default search_path already includes "extensions", so the
-- gist operator classes used by the events_no_venue_overlap /
-- events_no_cohort_self_overlap EXCLUDE constraints keep resolving.


-- ----------------------------------------------------------------------------
-- 2. Pin search_path on every function (closes function_search_path_mutable)
-- ----------------------------------------------------------------------------
alter function mark_email_verified(uuid, text)              set search_path = public;
alter function approve_cohort_join_request(uuid, uuid)      set search_path = public;
alter function decline_cohort_join_request(uuid, uuid)      set search_path = public;
alter function create_cohort_with_class_rep(uuid, int, int, cohort_pace, uuid, uuid) set search_path = public;
alter function enforce_max_class_reps()                     set search_path = public;
alter function demote_class_rep(uuid, uuid)                 set search_path = public;
alter function handle_new_auth_user()                       set search_path = public;
alter function reschedule_event(uuid, timestamptz, timestamptz, uuid, uuid) set search_path = public;
alter function notify_cohort_event_change()                 set search_path = public;
alter function current_app_user()                           set search_path = public;
alter function is_venue_available(uuid, timestamptz, timestamptz) set search_path = public;


-- ----------------------------------------------------------------------------
-- 3. Lock down which roles can call which functions directly via the API
-- ----------------------------------------------------------------------------
-- Trigger-only functions: never meant to be called directly as an RPC.
-- Triggers invoke them regardless of grants (trigger execution isn't gated
-- by EXECUTE privilege the way a direct call is), so revoking here doesn't
-- break anything — it just closes the /rest/v1/rpc/... door.
revoke execute on function handle_new_auth_user()       from public, anon, authenticated;
revoke execute on function notify_cohort_event_change() from public, anon, authenticated;
revoke execute on function enforce_max_class_reps()      from public, anon, authenticated;

-- current_app_user() is used INSIDE RLS policies (evaluated as the
-- querying/authenticated role), so authenticated must keep EXECUTE. anon
-- never needs it since every policy that calls it already requires
-- auth.uid() is not null / a matching users row.
revoke execute on function current_app_user() from public, anon;
grant  execute on function current_app_user() to authenticated;

-- Everything below requires a signed-in caller; anon gets nothing.
revoke execute on function mark_email_verified(uuid, text)                          from anon;
revoke execute on function approve_cohort_join_request(uuid, uuid)                  from anon;
revoke execute on function decline_cohort_join_request(uuid, uuid)                  from anon;
revoke execute on function create_cohort_with_class_rep(uuid, int, int, cohort_pace, uuid, uuid) from anon;
revoke execute on function demote_class_rep(uuid, uuid)                             from anon;
revoke execute on function reschedule_event(uuid, timestamptz, timestamptz, uuid, uuid) from anon;
revoke execute on function is_venue_available(uuid, timestamptz, timestamptz)        from anon;


-- ----------------------------------------------------------------------------
-- 4. Close the impersonation gap: require the "acting user" param to match
--    auth.uid(). Re-defining each function with the check added.
-- ----------------------------------------------------------------------------

create or replace function mark_email_verified(p_user_id uuid, p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is distinct from auth.uid() then
    raise exception 'Cannot verify email for another user';
  end if;

  update public.users
  set email = p_email,
      email_verified_at = now()
  where id = p_user_id;
end;
$$;


create or replace function approve_cohort_join_request(
  p_request_id uuid,
  p_decided_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_cohort_id  uuid;
begin
  if p_decided_by is distinct from auth.uid() then
    raise exception 'p_decided_by must match the calling user';
  end if;

  select student_id, cohort_id
  into v_student_id, v_cohort_id
  from cohort_join_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    raise exception 'No pending join request with id %', p_request_id;
  end if;

  -- Caller must actually be the class rep of THIS cohort — not just any
  -- authenticated user, and not a class rep of a different cohort.
  if not exists (
    select 1 from users u
    where u.id = auth.uid()
      and u.role = 'class_rep'
      and u.cohort_id = v_cohort_id
  ) then
    raise exception 'Only the class rep of this cohort may approve join requests';
  end if;

  update cohort_join_requests
  set status = 'approved', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;

  update users
  set cohort_id = v_cohort_id
  where id = v_student_id;
end;
$$;


create or replace function decline_cohort_join_request(
  p_request_id uuid,
  p_decided_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cohort_id uuid;
begin
  if p_decided_by is distinct from auth.uid() then
    raise exception 'p_decided_by must match the calling user';
  end if;

  select cohort_id into v_cohort_id
  from cohort_join_requests
  where id = p_request_id and status = 'pending';

  if not found then
    raise exception 'No pending join request with id %', p_request_id;
  end if;

  if not exists (
    select 1 from users u
    where u.id = auth.uid()
      and u.role = 'class_rep'
      and u.cohort_id = v_cohort_id
  ) then
    raise exception 'Only the class rep of this cohort may decline join requests';
  end if;

  update cohort_join_requests
  set status = 'declined', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;
end;
$$;


create or replace function create_cohort_with_class_rep(
  p_programme_id       uuid,
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
  v_programme_abbr text;
  v_cohort_id    uuid;
  v_creator_role user_role;
begin
  if p_created_by is distinct from auth.uid() then
    raise exception 'p_created_by must match the calling user';
  end if;

  select role into v_creator_role from users where id = p_created_by;
  if v_creator_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may create a cohort';
  end if;

  select abbreviation into v_programme_abbr from programmes where id = p_programme_id;
  if v_programme_abbr is null then
    raise exception 'programme % not found', p_programme_id;
  end if;

  insert into cohorts (programme_id, name, join_code, intake_year, current_semester, pace)
  values (
    p_programme_id,
    v_programme_abbr || ' ' || p_intake_year,
    encode(extensions.gen_random_bytes(6), 'hex'),
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


create or replace function demote_class_rep(
  p_user_id uuid,
  p_demoted_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_demoter_role user_role;
begin
  if p_demoted_by is distinct from auth.uid() then
    raise exception 'p_demoted_by must match the calling user';
  end if;

  select role into v_demoter_role from users where id = p_demoted_by;
  if v_demoter_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may demote a class rep';
  end if;

  update users
  set role = 'student', class_rep_rank = null
  where id = p_user_id and role = 'class_rep';
end;
$$;


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
  v_old events%rowtype;
  v_new_id uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_old from events where id = p_event_id for update;
  if not found then
    raise exception 'Event % not found', p_event_id;
  end if;

  -- Caller must be a class rep of THIS event's cohort.
  if not exists (
    select 1 from users u
    where u.id = auth.uid()
      and u.role = 'class_rep'
      and u.cohort_id = v_old.cohort_id
  ) then
    raise exception 'Only the class rep of this cohort may reschedule this event';
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


-- ----------------------------------------------------------------------------
-- 5. Replace the SECURITY DEFINER view with a SECURITY DEFINER function
-- ----------------------------------------------------------------------------
-- Views that bypass RLS silently are flagged as an ERROR by Supabase for
-- good reason: unlike a function, there's no explicit call site making the
-- privilege escalation visible, and no easy place to layer parameter
-- validation. A function achieves the same "expose only venue_id + time
-- range across all cohorts" goal but is auditable the same way every other
-- privileged function in this schema is.
drop view if exists venue_occupancy;

create or replace function get_venue_occupancy()
returns table (venue_id uuid, start_time timestamptz, end_time timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select e.venue_id, e.start_time, e.end_time
  from events e
  where e.status = 'scheduled';
$$;

revoke execute on function get_venue_occupancy() from anon;
grant  execute on function get_venue_occupancy() to authenticated;

-- is_venue_available now reads from the function instead of the dropped view.
create or replace function is_venue_available(
  p_venue_id uuid,
  p_start    timestamptz,
  p_end      timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from get_venue_occupancy() vo
    where vo.venue_id = p_venue_id
      and tstzrange(vo.start_time, vo.end_time) && tstzrange(p_start, p_end)
  );
$$;