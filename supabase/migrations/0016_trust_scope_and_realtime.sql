-- ============================================================================
-- 0016: Trust-chain scoping and realtime delivery
-- ============================================================================
-- Part 3 of 3; applies after 0015. Three fixes that look unrelated but share a
-- property — each was silently doing nothing, and nothing surfaced it until
-- something exercised the path for real.
--
--   1. create_cohort_with_class_rep and demote_class_rep checked
--      `role = 'faculty_rep'` and nothing else, so any faculty rep could
--      create cohorts under any programme in the university and demote any
--      class rep anywhere. TECHNICAL_DISCOVERY §2 describes them as the trust
--      anchor for ONE faculty.
--   2. The broadcast trigger's realtime calls never resolved, and no policy on
--      realtime.messages existed anywhere in 0001-0013 — so the per-cohort
--      channels were both unwritable and unsubscribable. The realtime feature
--      described in TECHNICAL_DISCOVERY §9 had never delivered a message.
--   3. A student already holding class_rep in cohort A could request to join
--      cohort B, and approval carried that authority across — reaching class
--      rep of a cohort that never elected them, sideways.
--
-- Contents
--   §1  Faculty Rep authority is scoped to their own faculty
--   §2  The realtime broadcast calls never resolved either
--   §3  Authorize subscriptions to the per-cohort broadcast channels
--   §4  A join request could carry class-rep authority into a new cohort
-- ============================================================================


-- ============================================================================
-- 1. Faculty Rep authority is scoped to their own faculty
-- ============================================================================
-- Both functions checked `role = 'faculty_rep'` and nothing more, so any
-- faculty rep could create cohorts under any programme in the university and
-- demote any class rep anywhere. TECHNICAL_DISCOVERY §2 describes them as the trust anchor for
-- ONE faculty; this makes the code agree.
--
-- Scoping resolves through users.faculty_id, so a Faculty Rep row with a NULL
-- faculty_id can now do nothing — fail-closed, and something the seed data
-- and the manual out-of-band onboarding both have to get right.

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
  select d.faculty_id into v_target_faculty
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
end;
$$;


-- ============================================================================
-- 2. The realtime broadcast calls never resolved either
-- ============================================================================
-- 0005/0010/0013 all call
--
--   realtime.broadcast_changes(topic, action, TG_OP, TG_TABLE_NAME,
--                              TG_TABLE_SCHEMA, jsonb_build_object(...),
--                              jsonb_build_object(...))
--
-- but the function's actual signature is
--
--   broadcast_changes(topic_name text, event_name text, operation text,
--                     table_name text, table_schema text,
--                     new record, old record, level text default 'ROW')
--
-- `new` and `old` are `record`, and there is no cast from jsonb to record — so
-- every call failed with
--
--   42883: function realtime.broadcast_changes(text, unknown, text, name, name,
--          jsonb, jsonb) does not exist
--
-- Same reason as 0015 §3 that nobody noticed: the trigger only fires when an events
-- row is written, and until create_event was fixed no events row could be
-- written. Two dormant bugs stacked on top of each other.
--
-- The fix is not to build a record for broadcast_changes — it is to stop using
-- broadcast_changes at all. That function exists to ship the full OLD and NEW
-- rows, which is precisely what §9 of TECHNICAL_DISCOVERY says this app must
-- NOT do ("the payload is {id, action} only — never the full row", so clients
-- are forced into a fresh RLS-checked SELECT and can never patch stale state
-- into a conflict-prevention UI). realtime.send takes a jsonb payload directly
-- and is the correct primitive for that design:
--
--   send(payload jsonb, event text, topic text, private boolean default true)
--
-- One behaviour change worth knowing at the client: notify_new_event_cohort
-- used to key its payload 'event_id' while notify_cohort_event_change used
-- 'id'. Both now emit {id, action}, so a Flutter client has one payload shape to
-- decode instead of two.
--
-- private => true keeps these on authorized channels, which needs the
-- realtime.messages policy in §3 below to be subscribable.
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

  -- One broadcast per attached cohort: a combined lecture reaches every
  -- cohort's channel (0010), and on DELETE the BEFORE timing set up in 0013 is
  -- what lets this loop still see the rows about to be cascaded away.
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


-- Third dormant bug in the same area: creating a lecture broadcast NOTHING.
--
-- events_broadcast_trigger fired AFTER INSERT on events and looped over
-- event_cohorts to find the cohorts to notify — but create_event inserts the
-- events row FIRST and its attachments after, so at trigger time the loop found
-- zero rows and emitted zero messages. The old notify_new_event_cohort only
-- covered `confirmation_status = 'pending'`, i.e. non-initiating cohorts of a
-- proposal. Net effect: a class rep adding an ordinary lecture produced no
-- broadcast to anyone, and the seeded database confirmed it — 23 events, zero
-- 'created' messages. That is the single most important realtime path in the
-- product (DISCOVERY, first-use journey step 6: "the student's calendar updates
-- within seconds, and they get a push notification").
--
-- Attaching a cohort IS the moment that cohort learns of an event, so the
-- attachment trigger is the right place to signal it. This now covers both
-- cases and the events trigger below is narrowed to UPDATE, where it actually
-- has attachments to read.
create or replace function notify_new_event_cohort()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text;
begin
  v_action := case
    -- Non-initiating cohort of a proposal: their rep has a decision to make.
    when NEW.confirmation_status = 'pending' then 'cohort_confirmation_needed'
    -- The initiating cohort, or any cohort of a rescheduled occurrence: this is
    -- a new row on their calendar.
    else 'created'
  end;

  perform realtime.send(
    jsonb_build_object('id', NEW.event_id, 'action', v_action),
    v_action,
    'cohort:' || NEW.cohort_id || ':events',
    true
  );
  return NEW;
end;
$$;

revoke execute on function notify_new_event_cohort() from public, anon, authenticated, service_role;

-- Narrow the events trigger to UPDATE. The INSERT half could never do anything
-- (see above), and leaving it attached would keep implying otherwise. DELETE
-- keeps its own BEFORE trigger from 0013, which is what lets it still see the
-- attachment rows the cascade is about to remove.
drop trigger if exists events_broadcast_trigger on events;

create trigger events_broadcast_trigger
after update on events
for each row
execute function notify_cohort_event_change();


-- ============================================================================
-- 3. Authorize subscriptions to the per-cohort broadcast channels
-- ============================================================================
-- With private => true, Supabase Realtime authorizes every subscribe against
-- RLS on realtime.messages. No policy existed anywhere in 0001-0013, so the
-- channels §9 of TECHNICAL_DISCOVERY describes were unsubscribable — the server
-- would have written broadcasts (had they resolved at all) that no client could
-- ever receive.
--
-- A user may read exactly one topic: their own cohort's. That is strictly
-- narrower than the events they can SELECT (a combined lecture broadcasts to
-- every attached cohort's channel, and each rep only listens on their own),
-- which is the right way round — the payload carries no data, so the channel
-- only needs to reveal "something on your cohort's calendar changed".
drop policy if exists cohort_members_read_own_cohort_broadcasts on realtime.messages;

create policy cohort_members_read_own_cohort_broadcasts
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.topic() = 'cohort:' || (
      select u.cohort_id from users u where u.id = auth.uid()
    )::text || ':events'
  );


-- ============================================================================
-- 4. A join request could carry class-rep authority into a new cohort
-- ============================================================================
-- Surfaced by the trust-chain test suite, not by reading the code.
--
-- approve_cohort_join_request ends with a bare
--
--   update users set cohort_id = v_cohort_id where id = v_student_id;
--
-- and never looks at what that user currently IS. Nothing stops a sitting class
-- rep from opening a join request against another cohort — join_requests_student_create
-- only checks `student_id = auth.uid()`, with no role restriction. So:
--
--   1. the class rep of cohort A requests to join cohort B;
--   2. B's rep approves, believing they are admitting a student;
--   3. the UPDATE moves them to B while leaving role = 'class_rep' and
--      class_rep_rank intact.
--
-- They are now a class rep OF COHORT B, with full scheduling authority over a
-- cohort that never elected them — reached sideways through a student-initiated
-- request, which is exactly the "no role may skip a level or self-promote" rule
-- in TECHNICAL_DISCOVERY §2. It only fails today when the target cohort already holds two reps, and
-- then only by accident, via enforce_max_class_reps.
--
-- Fixed by refusing rather than by silently demoting. DISCOVERY is explicit that
-- primary/assistant hand-off is always a manual Faculty Rep action with no
-- automatic promotion; the mirror of that is no automatic DEMOTION either. A rep
-- who is genuinely changing cohorts gets demoted by their faculty rep first, so
-- every role transition still originates top-down. Refusing also keeps the
-- approving rep from quietly changing somebody else's role as a side effect of
-- what looks like an admissions decision.
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
  v_role       user_role;
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

  if not exists (
    select 1 from users u
    where u.id = auth.uid()
      and u.role = 'class_rep'
      and u.cohort_id = v_cohort_id
  ) then
    raise exception 'Only the class rep of this cohort may approve join requests';
  end if;

  select role into v_role from users where id = v_student_id;

  if v_role is distinct from 'student' then
    raise exception
      'User % is a % and cannot be admitted by join request. A class rep must be '
      'demoted by their faculty rep before changing cohorts, so that every role '
      'change still originates top-down.',
      v_student_id, v_role
      using errcode = 'P0001';
  end if;

  update cohort_join_requests
  set status = 'approved', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;

  update users set cohort_id = v_cohort_id where id = v_student_id;
end;
$$;

revoke execute on function approve_cohort_join_request(uuid, uuid) from public, anon;
grant  execute on function approve_cohort_join_request(uuid, uuid) to authenticated, service_role;
