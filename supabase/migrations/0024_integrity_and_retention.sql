-- ============================================================================
-- 0024: Integrity constraints, attribution retention, and the drops
-- ============================================================================
-- Phase 2 part 2 of 2. TODO §2.1, §2.3, §2.4, §2.5, §2.6 and half of §2.8.
--
-- 0023 moved every writer off the two doomed columns and gave cohorts their
-- disambiguated names. This file is the structure that follows.
--
-- Contents
--   §1  Unique constraints                     (TODO §2.1)
--   §2  Notification indexes                   (TODO §2.4)
--   §3  Retained attribution + ON DELETE       (TODO §2.3)
--   §4  Drop the dead columns                  (TODO §2.8)
--   §5  Rebuild events_current                 (TODO §2.5)
--   §6  The audit snapshot contract            (TODO §2.6)
--   §7  Grants
--
-- ORDER IS LOAD-BEARING, for the same reason it was in 0022 §6. events_current
-- is a `select *` view, and Postgres expands that into an explicit column list
-- at CREATE time — so the view holds a real dependency on every column that
-- existed when it was made, and §4's DROP COLUMN fails against it. The view is
-- dropped at the top of §4 and rebuilt once in §5, AFTER every column change.
-- Rebuilding it in between does not help: `select *` simply re-expands over
-- whatever is there at that moment, and the next change fails against the new
-- view instead of the old one.
-- ============================================================================


-- ============================================================================
-- 1. Unique constraints
-- ============================================================================
-- TODO §2.1. Four constraints the schema has always assumed and never enforced.
-- All four apply against the current dataset with zero violations, so none of
-- them needs a cleanup step — but that is a fact about today's data, not a
-- guarantee, which is exactly why they are going in now rather than after there
-- is production data to reconcile.
--
-- Already done elsewhere and deliberately not repeated here: programmes.code
-- and student_roster.reg_number were both pulled forward into 0017, where
-- registration-number parsing made them load-bearing rather than cleanup.

-- users.reg_number mirrors student_roster.reg_number, and the two must not
-- drift: 0019's invariant is that users.reg_number is not null IF AND ONLY IF
-- that account claimed a roster row, and the roster's copy is already unique.
-- Without this, two users rows could hold the same number while the roster
-- insists only one claim exists.
--
-- STAYS NULLABLE, and a plain UNIQUE is correct for that: Postgres permits any
-- number of NULLs under one. NULL is the right resting state for an account
-- that has not claimed — see TECHNICAL_DISCOVERY §10.
alter table users
  add constraint users_reg_number_unique unique (reg_number);

-- THREE columns, not four. TODO §2.1 proposed
-- (programme_id, intake_year, current_semester, pace) and that is wrong:
-- current_semester is mutable progression state, not identity. 0014 grants
-- column-level UPDATE on it to authenticated precisely so a class rep can
-- advance their cohort — and if semester is part of the identity key, advancing
-- a cohort VACATES ITS SLOT and a second cohort can be created in the hole the
-- first one just left. TECHNICAL_DISCOVERY §4 has always said a cohort is "one
-- per programme+intake-year+pace combination". This makes the code agree with
-- the document rather than with the TODO.
alter table cohorts
  add constraint cohorts_identity_unique unique (programme_id, intake_year, pace);

-- Display keys, used as human-facing identifiers all over the seed and the
-- venue browser. buildings.abbreviation composes a room's display name
-- (`abbreviation || '-' || rooms.number`, 0001), so a duplicate would produce
-- two different rooms that render identically.
alter table faculties
  add constraint faculties_abbreviation_unique unique (abbreviation);

alter table buildings
  add constraint buildings_abbreviation_unique unique (abbreviation);


-- ============================================================================
-- 2. Notification indexes
-- ============================================================================
-- TODO §2.4. notifications carried a bare (user_id) — fine for "everything for
-- this user", wrong for both queries the app actually makes.
--
-- The list is newest-first and paginated; the badge is a count of unread. The
-- composite serves the first. The partial serves the second and stays small
-- forever regardless of history depth, because it only indexes rows that are
-- still unread — which is the minority in any account older than a week, and a
-- shrinking fraction over time.
drop index if exists notifications_user_idx;

create index notifications_user_recent_idx
  on notifications (user_id, created_at desc);

create index notifications_user_unread_idx
  on notifications (user_id)
  where read_at is null;


-- ============================================================================
-- 3. Retained attribution, and the ON DELETE rework
-- ============================================================================
-- TODO §2.3. The goal is narrow and concrete: DELETING AN auth.users ROW
-- SHOULD SUCCEED. Today it cannot. users.id cascades from auth.users, that
-- cascade reaches five columns that refuse to give up their reference, and the
-- whole delete aborts mid-cascade.
--
-- TODO §2.3 names two of those five. The real set is:
--
--   events.created_by               RESTRICT
--   events.updated_by               RESTRICT    <- unlisted
--   event_audit_log.changed_by      RESTRICT
--   event_cohorts.decided_by        NO ACTION   <- unlisted
--   events.attendance_confirmed_by  NO ACTION   <- unlisted
--
-- NO ACTION blocks a delete exactly as hard as RESTRICT — the only difference
-- is when the check fires — so the three columns that do not say the word
-- "restrict" were never less of a problem, just less visible.
-- events.attendance_confirmed_by is newly one: before 0022 no function could
-- write it, so it was never populated and never blocked anything. Phase 1 made
-- it reachable and Phase 2 inherits it.
--
-- THE SPLIT THAT MATTERS. Two of these are attribution of record and two are
-- current-state pointers, and they want opposite treatment:
--
--   * event_audit_log.changed_by is HISTORY. "Who did this" must survive the
--     person — an audit log that forgets its actor when the actor leaves is not
--     an audit log. It gets a retained name.
--   * events.updated_by, event_cohorts.decided_by and
--     events.attendance_confirmed_by are POINTERS TO CURRENT STATE. Their
--     historical values are already captured in event_audit_log, so losing them
--     on deletion loses nothing that is not recorded elsewhere.
--   * events.created_by sits between the two and is treated as a pointer, on
--     purpose — see the note above its FK below.
--
-- This is the shape role_audit_log already has. 0022 §5 adopted SET NULL plus a
-- retained user_name explicitly citing TODO §2.3's proposed fix, so that table
-- is already in the state this section moves the older ones into. Verified
-- before writing: no RLS policy anywhere references created_by or changed_by,
-- so dropping NOT NULL on either disturbs nothing in the access-control layer.

-- --- The retained name ------------------------------------------------------
alter table event_audit_log add column changed_by_name text;

comment on column event_audit_log.changed_by_name is
  'The actor''s display name at the time of the action, denormalized so the '
  'trail survives the account being deleted (changed_by goes null, this does '
  'not). Filled automatically by a trigger — callers never pass it. Same '
  'reasoning as roster_audit_log.reg_number and role_audit_log.user_name.';

update event_audit_log l
set changed_by_name = u.first_name || ' ' || u.last_name
from users u
where u.id = l.changed_by and l.changed_by_name is null;

-- FILLED BY A TRIGGER, NOT BY ITS CALLERS, and that is the whole design.
-- TEN functions insert into event_audit_log — create_event, update_event,
-- cancel_event, cancel_recurrence_group, reschedule_event, confirm_attendance,
-- unconfirm_attendance, leave_event_cohort, confirm_event_cohort and
-- decline_event_cohort. Editing ten call sites to pass a name every one of them
-- could look up itself would be ten chances to forget one, one migration after
-- 0022 rewrote most of them — and a forgotten one produces an audit row with a
-- null actor AND no name, which is strictly worse than the state this section
-- is fixing. One trigger cannot be forgotten.
--
-- SECURITY DEFINER because it reads users, and search_path pinned per
-- TECHNICAL_DISCOVERY §8. changed_by_name is left nullable deliberately: a
-- NOT NULL here would fire before the FK check and mask a genuine
-- "that user does not exist" error behind a confusing constraint violation.
-- The invariant the tests assert is the useful one — if changed_by was set, the
-- name is retained.
create function retain_event_audit_actor_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.changed_by is not null and NEW.changed_by_name is null then
    select first_name || ' ' || last_name
    into NEW.changed_by_name
    from users where id = NEW.changed_by;
  end if;

  return NEW;
end;
$$;

revoke execute on function retain_event_audit_actor_name()
  from public, anon, authenticated, service_role;

create trigger event_audit_log_retain_actor_name
  before insert on event_audit_log
  for each row
  execute function retain_event_audit_actor_name();

-- --- The FK rework ----------------------------------------------------------
-- event_audit_log.changed_by: history, name retained above.
alter table event_audit_log alter column changed_by drop not null;

alter table event_audit_log drop constraint event_audit_log_changed_by_fkey;
alter table event_audit_log
  add constraint event_audit_log_changed_by_fkey
  foreign key (changed_by) references users (id) on delete set null;

-- events.created_by gets NO retained name column, deliberately — this is a
-- refinement on the obvious "add a name to both NOT NULL columns" plan.
-- Every event already has a 'created' row in event_audit_log (written by
-- create_event and by reschedule_event for the replacement), and that row now
-- carries the retained name. A second copy on events would be two places to
-- keep in sync for one fact, and the audit log is the one that is designed to
-- outlive people.
--
-- Consequence for the client, recorded so it is not a surprise: a UI rendering
-- "scheduled by" from events.created_by shows nothing once that account is
-- deleted, and must fall back to the 'created' audit row.
alter table events alter column created_by drop not null;

alter table events drop constraint events_created_by_fkey;
alter table events
  add constraint events_created_by_fkey
  foreign key (created_by) references users (id) on delete set null;

-- The three pointers. Already nullable, so these are plain FK swaps.
alter table events drop constraint events_updated_by_fkey;
alter table events
  add constraint events_updated_by_fkey
  foreign key (updated_by) references users (id) on delete set null;

alter table events drop constraint events_attendance_confirmed_by_fkey;
alter table events
  add constraint events_attendance_confirmed_by_fkey
  foreign key (attendance_confirmed_by) references users (id) on delete set null;

alter table event_cohorts drop constraint event_cohorts_decided_by_fkey;
alter table event_cohorts
  add constraint event_cohorts_decided_by_fkey
  foreign key (decided_by) references users (id) on delete set null;


-- ============================================================================
-- 4. Drop the dead columns
-- ============================================================================
-- TODO §2.8. Both had their last writer removed in 0023.
--
-- The view goes first. See this file's header for why the order is not
-- cosmetic.
drop view if exists events_current;

-- recurrence_rule was never anything but dead text. 0004's own comment called
-- it "display metadata only"; 0022 removed it from create_event's parameter
-- list once occurrences were materialized from the enum plus a horizon; 0023
-- stopped reschedule_event copying it forward. Zero non-null values have ever
-- existed in it.
alter table events drop column recurrence_rule;

-- join_code was generated for every cohort and read by nothing. TODO 0.5
-- settled permanently that self-service join codes will not ship — a join code
-- is a shared secret anyone in the room can use on anyone's behalf, while the
-- roster is per-person and pins the cohort already. Deprecated in 0023 §0.
-- Takes cohorts_join_code_key with it.
alter table cohorts drop column join_code;


-- ============================================================================
-- 5. Rebuild events_current
-- ============================================================================
-- TODO §2.5. The view filtered 'rescheduled' but not 'canceled', so a canceled
-- lecture appeared in a view whose entire purpose is "what is on". Clients had
-- to filter anyway, which made the view worse than useless — it looked like it
-- had already done the job.
--
-- Considered and rejected: dropping the view outright. It has zero readers
-- anywhere in the repo today, which made that tempting and free. But it is the
-- intended client convenience surface and the Flutter client has not been
-- written yet, so this is the moment to define it properly — before anything
-- depends on it, rather than after.
--
-- `status in ('scheduled', 'proposed')` excludes canceled AND rescheduled.
-- The old `or superseded_by is null` disjunct is gone as dead weight: it existed
-- to catch a 'rescheduled' row not yet pointed at its replacement, and status
-- alone now excludes those.
--
-- 'proposed' stays IN. A combined lecture awaiting confirmation is real for the
-- initiating cohort, it already reserves everyone's slot through the
-- event_cohorts EXCLUDE constraint, and hiding it would leave a rep unable to
-- see the thing occupying their calendar.
--
-- security_invoker stays on: 0008 removed a security-definer view for exactly
-- the right reason (the caller's RLS must apply) and 0010 rebuilt this one with
-- it set.
create view events_current with (security_invoker = true) as
select *
from events e
where status in ('scheduled', 'proposed');

-- Supabase's default privileges grant on relation creation, and a VIEW is no
-- exception — recreating one re-opens anon/authenticated access unless revoked
-- first. This is the trap 0022 §6 tripped and 00_access_control_test.sql
-- caught. Grants do not survive DROP VIEW either, so they are restated.
revoke all on events_current from public, anon, authenticated;

grant select on events_current to authenticated;
grant all    on events_current to service_role;


-- ============================================================================
-- 6. The audit snapshot contract
-- ============================================================================
-- TODO §2.6. 0004's inline comment says snapshot "holds event state (JSON) at
-- the time of the action", and not one writer has ever done that — every one
-- passes a small object naming what changed.
--
-- THE CODE IS RIGHT AND THE DOCUMENT IS WRONG, so the document moves. The full
-- row is still on events to join against; copying it into every audit row would
-- be bloat that also goes stale against schema changes — an events table that
-- gains a column would silently start producing differently-shaped snapshots,
-- and old rows would keep the old shape forever.
--
-- Recorded as a real database comment rather than only a migration comment, so
-- it is visible to anyone inspecting the table rather than only to someone
-- reading 0004.
comment on column event_audit_log.snapshot is
  'The fields relevant to THIS ACTION — not the full event row. Join to events '
  'for full state. Keys vary by action: created carries '
  '{cohort_ids, initial_status, recurrence_group_id}; rescheduled carries '
  '{superseded_by}; confirmed/unconfirmed carry {attendance_status, cohort_id}; '
  'canceled carries {reason}. Deliberately partial — see 0024 §6.';

comment on table event_audit_log is
  'Append-only record of every meaningful change to an event, always attributed '
  'to the acting human (never a lecturer — they have no accounts). changed_by '
  'goes null if the account is deleted; changed_by_name is retained so the '
  'trail survives.';


-- ============================================================================
-- 7. Grants
-- ============================================================================
-- The trigger function in §3 is already revoked from everyone at its
-- definition. Trigger functions need no EXECUTE grant at all — the trigger
-- mechanism is not privilege-gated — so revoking from every role costs nothing
-- and closes the RPC door.
--
-- No new tables, so no table privileges to hand out. event_audit_log's new
-- column inherits the table's existing grants: 0014 §4 gave authenticated
-- SELECT on the whole table, which is what we want — the retained name is no
-- more sensitive than the account name it copies, and both are already visible
-- to every authenticated user through users.
--
-- The rebuilt view's grants are in §5, next to the revoke that has to precede
-- them.
