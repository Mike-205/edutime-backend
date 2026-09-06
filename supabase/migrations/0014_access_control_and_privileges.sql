-- ============================================================================
-- 0014: Access control — RLS recursion, column guards, and privileges
-- ============================================================================
-- Part 1 of 3. 0014/0015/0016 were written as a single pass over the schema
-- while the first pgTAP suite was going in, then split by theme. Apply them in
-- order; they are not independent files.
--
-- This one is the permission layer: who may READ what, which columns a user
-- may write on their own rows, and which roles hold EXECUTE and table
-- privileges at all. Five problems, every one of them invisible until a real
-- client talks to this schema:
--
--   1. event_cohorts' SELECT policy referenced event_cohorts, which Postgres
--      rejects as infinite recursion (42P17). Because the events and
--      event_audit_log policies reach into event_cohorts, that error took the
--      whole calendar read path down with it.
--   2. users_update_own_profile let any student UPDATE their own role /
--      cohort_id / class_rep_rank — i.e. self-promote to class rep of any
--      cohort. That is the exact thing the Faculty Rep -> Class Rep chain
--      exists to prevent. Same missing column restriction on cohorts and
--      notifications.
--   3. Every `REVOKE EXECUTE ... FROM anon` in 0008/0010/0012/0013 was a
--      no-op: Postgres cannot revoke from one role a privilege that came from
--      the implicit GRANT ... TO PUBLIC at function-creation time.
--   4. 0001-0013 enable RLS and write policies but never GRANT anything on any
--      table to anyone. Those are two separate mechanisms and both are
--      required, so nothing in this schema was readable.
--   5. faculties never had RLS enabled at all — the root of the academic
--      hierarchy, and the only table in the schema with no policy.
--
-- Contents
--   §1  RLS recursion on event_cohorts          -> user_can_see_event()
--   §2  Column-level guards for self-service UPDATEs -> three guard triggers
--   §3  Function grants — actually close the anon door
--   §4  Table privileges
--   §5  faculties RLS
--
-- §3 grants EXECUTE on functions that 0015 and 0016 then redefine. That is
-- safe and deliberate: this pass drops no function anywhere, and CREATE OR
-- REPLACE preserves the existing ACL. Grants first, bodies after.
-- ============================================================================


-- ============================================================================
-- 1. RLS recursion on event_cohorts
-- ============================================================================
-- A policy expression is itself subject to RLS on every table it touches, so
-- `event_cohorts` inside `event_cohorts`' own policy is a self-reference and
-- Postgres raises 42P17 rather than looping. The fix is the same escape hatch
-- current_app_user() already uses elsewhere in this schema: put the lookup in
-- a SECURITY DEFINER function, which runs as the table owner and therefore
-- isn't subject to the policy at all.
--
-- Routing events / event_cohorts / event_audit_log through ONE helper also
-- means "who can see this event" is defined in exactly one place instead of
-- three copies of the same join drifting apart.
create or replace function user_can_see_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- A user sees an event iff their own cohort is attached to it. Attachments
  -- that later went 'declined' or 'left' still count for VISIBILITY: a cohort
  -- that walked away from a lecture should still be able to see the row its
  -- own audit trail refers to. Clients filter on
  -- event_cohorts.confirmation_status to decide what belongs on the calendar.
  select exists (
    select 1
    from event_cohorts ec
    where ec.event_id = p_event_id
      -- NULL cohort_id (faculty reps, students not yet admitted to a cohort)
      -- makes this comparison NULL, so the exists() is false. Fails closed.
      and ec.cohort_id = (select u.cohort_id from users u where u.id = auth.uid())
  );
$$;

revoke execute on function user_can_see_event(uuid) from public, anon;
grant  execute on function user_can_see_event(uuid) to authenticated, service_role;


drop policy if exists events_read_attached_cohort on events;

create policy events_read_attached_cohort
  on events for select
  using (user_can_see_event(events.id));


drop policy if exists event_cohorts_read_if_attached on event_cohorts;

-- Reads every attachment row for an event the caller can see — so a rep can
-- render "combined lecture with cohorts X, Y and their confirmation states",
-- which is the whole point of the table. Writes still have no policy; they
-- happen only inside the SECURITY DEFINER functions.
create policy event_cohorts_read_if_attached
  on event_cohorts for select
  using (user_can_see_event(event_cohorts.event_id));


drop policy if exists audit_log_read_own_cohort on event_audit_log;

create policy audit_log_read_own_cohort
  on event_audit_log for select
  using (user_can_see_event(event_audit_log.event_id));


-- ============================================================================
-- 2. Column-level guards for the three self-service UPDATE policies
-- ============================================================================
-- RLS in Postgres is row-level only: a policy can say "this row is yours to
-- update", never "these columns are". 0006 left three policies open in
-- exactly that way, and the users one was a straight path to self-promotion.
--
-- These guard triggers are deliberately SECURITY INVOKER (the default) — that
-- is what makes them work. Inside a SECURITY DEFINER function current_user is
-- already the function's owner, so the guard waves the write through; a direct
-- UPDATE over PostgREST arrives as `authenticated` and gets checked. Marking
-- any of these SECURITY DEFINER would make current_user always the owner and
-- silently disable the guard.
--
-- The `current_user in ('authenticated','anon')` test is repeated inline in
-- all three rather than factored into a helper, precisely BECAUSE these run as
-- the invoker: a helper would need EXECUTE granted to authenticated to be
-- callable from here, which is a grant this migration otherwise spends its
-- length taking away. Trigger functions themselves need no EXECUTE — the
-- trigger mechanism isn't privilege-gated (see 0008 §3).

-- users ----------------------------------------------------------------------
create or replace function guard_users_self_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Privileged paths — SECURITY DEFINER functions, the service_role key,
  -- migrations and seeds — all run as something other than the API roles.
  if current_user not in ('authenticated', 'anon') then
    return NEW;
  end if;

  if NEW.id                is distinct from OLD.id
  or NEW.role              is distinct from OLD.role
  or NEW.class_rep_rank    is distinct from OLD.class_rep_rank
  or NEW.cohort_id         is distinct from OLD.cohort_id
  or NEW.reg_number        is distinct from OLD.reg_number
  or NEW.email             is distinct from OLD.email
  or NEW.email_verified_at is distinct from OLD.email_verified_at
  or NEW.faculty_id        is distinct from OLD.faculty_id
  or NEW.department_id     is distinct from OLD.department_id
  or NEW.created_at        is distinct from OLD.created_at
  then
    raise exception
      'Only first_name, last_name and middle_name may be updated directly. '
      'role/cohort_id/class_rep_rank change via create_cohort_with_class_rep, '
      'demote_class_rep or approve_cohort_join_request; email via '
      'mark_email_verified.'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_users_self_update() from public, anon, authenticated;

create trigger guard_users_self_update_trigger
  before update on users
  for each row
  execute function guard_users_self_update();

-- Add the WITH CHECK half the policy never had. Without it Postgres reuses
-- USING for the post-update check, which happens to be equivalent here — but
-- only by accident, and it stops being equivalent the moment USING changes.
drop policy if exists users_update_own_profile on users;

create policy users_update_own_profile
  on users for update
  using (id = auth.uid())
  with check (id = auth.uid());


-- cohorts --------------------------------------------------------------------
-- A class rep legitimately advances their cohort's semester and may correct
-- its pace. They have no business moving the cohort to a different programme
-- or rotating its join_code.
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
  or NEW.join_code    is distinct from OLD.join_code
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

create trigger guard_cohorts_rep_update_trigger
  before update on cohorts
  for each row
  execute function guard_cohorts_rep_update();

drop policy if exists cohorts_update_own_class_rep on cohorts;

create policy cohorts_update_own_class_rep
  on cohorts for update
  using (
    exists (
      select 1 from current_app_user() u
      where u.role = 'class_rep' and u.cohort_id = cohorts.id
    )
  )
  with check (
    exists (
      select 1 from current_app_user() u
      where u.role = 'class_rep' and u.cohort_id = cohorts.id
    )
  );


-- notifications --------------------------------------------------------------
-- The only legitimate client write is marking one read. Rewriting the title,
-- message, type or event_id of a notification the server generated is not.
create or replace function guard_notifications_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return NEW;
  end if;

  if NEW.id         is distinct from OLD.id
  or NEW.user_id    is distinct from OLD.user_id
  or NEW.event_id   is distinct from OLD.event_id
  or NEW.title      is distinct from OLD.title
  or NEW.message    is distinct from OLD.message
  or NEW.type       is distinct from OLD.type
  or NEW.created_at is distinct from OLD.created_at
  then
    raise exception 'Only read_at may be updated on a notification'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_notifications_update() from public, anon, authenticated;

create trigger guard_notifications_update_trigger
  before update on notifications
  for each row
  execute function guard_notifications_update();


-- ============================================================================
-- 3. Function grants — actually close the anon door this time
-- ============================================================================
-- CREATE FUNCTION implicitly grants EXECUTE to PUBLIC, and a privilege held
-- via PUBLIC cannot be revoked from an individual role. So every
-- `revoke execute ... from anon` in 0008/0010/0012/0013 changed nothing: anon
-- kept EXECUTE through PUBLIC the whole time.
--
-- For the p_acting_user functions that was masked by their own first check —
-- auth.uid() is NULL for anon, so `p_acting_user is distinct from auth.uid()`
-- raised before anything happened. get_venue_occupancy() and
-- is_venue_available() have no such check, which left the university's entire
-- room-booking timetable readable without signing in.
--
-- Correct shape: revoke from PUBLIC, then grant explicitly. service_role is
-- named because revoking PUBLIC takes it away from the superadmin key too.

revoke execute on function mark_email_verified(uuid, text)                               from public, anon;
revoke execute on function approve_cohort_join_request(uuid, uuid)                       from public, anon;
revoke execute on function decline_cohort_join_request(uuid, uuid)                       from public, anon;
revoke execute on function create_cohort_with_class_rep(uuid, int, int, cohort_pace, uuid, uuid) from public, anon;
revoke execute on function demote_class_rep(uuid, uuid)                                  from public, anon;
revoke execute on function create_event(uuid[], uuid, uuid, text, timestamptz, timestamptz, recurrence_type, text, uuid) from public, anon;
revoke execute on function confirm_event_cohort(uuid, uuid)                              from public, anon;
revoke execute on function decline_event_cohort(uuid, uuid)                              from public, anon;
revoke execute on function cancel_event(uuid, uuid)                                      from public, anon;
revoke execute on function leave_event_cohort(uuid, uuid)                                from public, anon;
revoke execute on function reschedule_event(uuid, timestamptz, timestamptz, uuid, uuid)  from public, anon;
revoke execute on function is_venue_available(uuid, timestamptz, timestamptz)            from public, anon;
revoke execute on function get_venue_occupancy()                                         from public, anon;

grant execute on function mark_email_verified(uuid, text)                               to authenticated, service_role;
grant execute on function approve_cohort_join_request(uuid, uuid)                       to authenticated, service_role;
grant execute on function decline_cohort_join_request(uuid, uuid)                       to authenticated, service_role;
grant execute on function create_cohort_with_class_rep(uuid, int, int, cohort_pace, uuid, uuid) to authenticated, service_role;
grant execute on function demote_class_rep(uuid, uuid)                                  to authenticated, service_role;
grant execute on function create_event(uuid[], uuid, uuid, text, timestamptz, timestamptz, recurrence_type, text, uuid) to authenticated, service_role;
grant execute on function confirm_event_cohort(uuid, uuid)                              to authenticated, service_role;
grant execute on function decline_event_cohort(uuid, uuid)                              to authenticated, service_role;
grant execute on function cancel_event(uuid, uuid)                                      to authenticated, service_role;
grant execute on function leave_event_cohort(uuid, uuid)                                to authenticated, service_role;
grant execute on function reschedule_event(uuid, timestamptz, timestamptz, uuid, uuid)  to authenticated, service_role;
grant execute on function is_venue_available(uuid, timestamptz, timestamptz)            to authenticated, service_role;
grant execute on function get_venue_occupancy()                                         to authenticated, service_role;

grant execute on function current_app_user() to service_role;

-- Never callable over /rest/v1/rpc/. Triggers fire their functions regardless
-- of EXECUTE privilege, and the SECURITY DEFINER callers of
-- notify_cohort_members run as its owner, so nothing here loses access.
revoke execute on function handle_new_auth_user()             from public, anon, authenticated, service_role;
revoke execute on function notify_cohort_event_change()        from public, anon, authenticated, service_role;
revoke execute on function notify_new_event_cohort()           from public, anon, authenticated, service_role;
revoke execute on function enforce_max_class_reps()            from public, anon, authenticated, service_role;
revoke execute on function sync_event_cohorts_from_event()     from public, anon, authenticated, service_role;
revoke execute on function notify_cohort_members(uuid, uuid, notif_type, text, text, user_role)
  from public, anon, authenticated, service_role;


-- ============================================================================
-- 4. Table privileges — without these, nothing in this schema is readable
-- ============================================================================
-- 0001-0013 enable RLS and write policies, but never GRANT anything on a table
-- to anyone. Those are two different mechanisms and BOTH are required: a policy
-- filters which rows a role may see, table privileges decide whether the role
-- may touch the table at all. With policies but no grants, every client query
-- fails before RLS is ever consulted:
--
--   42501: permission denied for table events
--
-- Supabase normally hides this with ALTER DEFAULT PRIVILEGES, but in this
-- database there are two default-ACL entries for schema public and the one that
-- applies to tables owned by `postgres` — which is every table here — grants
-- only `Dxtm`:
--
--   postgres=arwdDxtm/supabase_admin  anon=arwdDxtm/...  authenticated=arwdDxtm/...
--   postgres=arwdDxtm/postgres        anon=Dxtm/postgres authenticated=Dxtm/postgres
--
-- D=TRUNCATE, x=REFERENCES, t=TRIGGER, m=MAINTAIN. No r/a/w/d, so no SELECT,
-- INSERT, UPDATE or DELETE for anon or authenticated — and, worse, a TRUNCATE
-- privilege that anon should never hold, since TRUNCATE ignores RLS completely.
--
-- So: clear the inherited grants, then hand back exactly what each policy needs
-- and nothing more. Column-level UPDATE grants do the heavy lifting here —
-- they enforce at the privilege layer what §2's guard triggers enforce at the
-- trigger layer, and Postgres checks them before the trigger ever runs.
revoke all on all tables in schema public from anon, authenticated;

-- Reference data and profiles: readable by any signed-in user.
grant select on
  faculties, departments, programmes, courses, cohorts,
  buildings, rooms, venues, users
  to authenticated;

-- Faculty Rep manages their own faculty's academic structure. 0006's policies
-- for these three are FOR ALL, so the privileges have to match.
grant insert, update, delete on departments, programmes, courses to authenticated;

-- Class rep advances their own cohort's semester or corrects its pace. Creating
-- cohorts stays Faculty-Rep-only via create_cohort_with_class_rep, hence no
-- INSERT, and nothing may be deleted.
grant update (name, current_semester, pace) on cohorts to authenticated;

-- A user edits their own display name. The three columns here are the same
-- three guard_users_self_update allows — role, cohort_id and class_rep_rank are
-- absent by design, so self-promotion is now refused by the privilege system
-- before the trigger is even reached.
grant update (first_name, last_name, middle_name) on users to authenticated;

-- Student raises a join request; the rep's decision goes through
-- approve_/decline_cohort_join_request, so no UPDATE.
grant select, insert on cohort_join_requests to authenticated;

-- Marking a notification read is the only client write, and read_at is the only
-- column it may touch.
grant select on notifications to authenticated;
grant update (read_at) on notifications to authenticated;

-- The scheduling tables are strictly READ-ONLY to clients. Every mutation goes
-- through a SECURITY DEFINER function (0010 §12), so granting INSERT or UPDATE
-- here would reopen exactly the direct-write path those functions replaced.
grant select on events, event_cohorts, event_audit_log to authenticated;
grant select on events_current to authenticated;

-- anon is deliberately left with nothing: every policy in this schema requires
-- auth.uid() to be non-null, so anon could never read a row anyway — this just
-- stops it holding privileges (TRUNCATE above) that RLS does not mediate.

-- service_role is the Superadmin key from §10 of TECHNICAL_DISCOVERY: it seeds
-- reference data and bootstraps the first Faculty Reps. It bypasses RLS, but
-- bypassing RLS is not the same as holding table privileges — it needs these.
grant all on all tables in schema public to service_role;


-- ============================================================================
-- 5. faculties was never given RLS at all
-- ============================================================================
-- 0006 enables row level security on twelve tables and 0010 adds event_cohorts,
-- but `faculties` is absent from both — no ALTER ... ENABLE ROW LEVEL SECURITY
-- and no policy. It is the root of the whole academic hierarchy
-- (faculties -> departments -> programmes -> courses -> cohorts) and the table
-- every Faculty Rep's authority is scoped by after 0016 §1, so it is a conspicuous
-- one to have slipped: Supabase's Advisor reports an unprotected table in a
-- PostgREST-exposed schema as an error, not a warning.
--
-- Actual exposure right now is read-only, because §4 grants authenticated
-- nothing but SELECT here — but that is a privilege-layer accident, not an
-- intent expressed anywhere. Faculties are created by the Superadmin
-- out-of-band (there are only 5-10 university-wide per DISCOVERY), so the rule
-- is the same as buildings/rooms/venues: everyone signed in may read, nobody
-- may write, and service_role bypasses this entirely.
alter table faculties enable row level security;

drop policy if exists faculties_read_all on faculties;

create policy faculties_read_all
  on faculties for select
  using (auth.uid() is not null);


