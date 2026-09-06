-- ============================================================================
-- 08: Phase 2 — integrity constraints, retention, and the cleanups
-- ============================================================================
-- 0023 and 0024. Four kinds of thing that had been assumed and never enforced:
--
--   1. Uniqueness the schema documented but nothing checked (TODO §2.1).
--   2. A cohort name that could not tell two real cohorts apart (§2.2).
--   3. An account that could never be deleted, because five FK columns refused
--      to let go of it mid-cascade (§2.3).
--   4. Dead columns, a half-filtering view, and an unlogged demotion
--      (§2.5, §2.7, §2.8).
--
-- The account-deletion tests come LAST on purpose: deleting a user cascades
-- through half the dataset, so anything asserted after it would be asserting
-- against a database the earlier tests did not describe.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(32);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.prog(p_code text) returns uuid language sql stable as $$
  select id from programmes where code = p_code;
$$;
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;

create function pg_temp.fst_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.mercy()   returns uuid language sql immutable as   -- primary rep, BSC-CS 2023, created 11 events
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.brian()   returns uuid language sql immutable as   -- assistant rep, BSC-CS 2023
  $$ select '22222222-0000-4000-8000-000000000012'::uuid $$;
create function pg_temp.faith()   returns uuid language sql immutable as   -- plain student, BSC-CS 2023
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;
create function pg_temp.kevin()   returns uuid language sql immutable as   -- plain student, BSC-CS 2023
  $$ select '22222222-0000-4000-8000-000000000014'::uuid $$;


-- ============================================================================
-- §1 Unique constraints (TODO §2.1)
-- ============================================================================

-- users.reg_number mirrors student_roster.reg_number, and 0019's invariant is
-- that the two agree. Nothing stopped them diverging until now.
select throws_ok(
  $$ update users set reg_number = 'EB1/67312/23'
     where id = '22222222-0000-4000-8000-000000000014' $$,
  '23505',
  null,
  'two accounts cannot hold the same registration number'
);

-- The constraint is a plain UNIQUE, not a partial one, and that is deliberate:
-- Postgres permits any number of NULLs under it, and NULL is the correct
-- resting state for an account that has not claimed a roster row.
select cmp_ok(
  (select count(*)::int from users where reg_number is null), '>=', 2,
  'many accounts can share a NULL registration number — plain UNIQUE tolerates NULLs'
);

select throws_ok(
  $$ insert into faculties (name, abbreviation) values ('Faculty of Duplication', 'FST') $$,
  '23505',
  null,
  'two faculties cannot share an abbreviation'
);

-- buildings.abbreviation composes a room's display name
-- (`abbreviation || '-' || number`, 0001), so a duplicate renders two different
-- rooms identically.
select throws_ok(
  $$ insert into buildings (name, abbreviation) values ('Science Annexe', 'S') $$,
  '23505',
  null,
  'two buildings cannot share an abbreviation'
);


-- ============================================================================
-- §2 The cohort identity key, and the name that renders it (§2.1, §2.2)
-- ============================================================================
-- The case the whole naming change exists for: same programme, same intake,
-- DIFFERENT pace. Both are legitimate — §4's pace mechanic is that
-- self-sponsored students run faster through the same programme — and before
-- 0023 they got byte-identical names.
select pg_temp.act_as(pg_temp.fst_rep());

select lives_ok(
  format($$ select create_cohort_with_class_rep(
    %L::uuid, 2023, 5, 'trimester', %L::uuid, %L::uuid) $$,
    pg_temp.prog('EB1'), pg_temp.faith(), pg_temp.fst_rep()),
  'a second BSC-CS 2023 cohort on a different pace is legitimate and allowed'
);

select is(
  (select name from cohorts
    where programme_id = pg_temp.prog('EB1') and intake_year = 2023 and pace = 'trimester'),
  'BSC-CS 2023 (trimester)',
  'the new cohort''s name carries its pace'
);

select isnt(
  (select name from cohorts
    where programme_id = pg_temp.prog('EB1') and intake_year = 2023 and pace = 'trimester'),
  (select name from cohorts
    where programme_id = pg_temp.prog('EB1') and intake_year = 2023 and pace = 'bimester'),
  '...and is therefore distinguishable from its bimester twin, which it was not before 0023'
);

-- The identity key is (programme, intake, pace) — three columns. Repeating an
-- existing combination is refused.
select throws_ok(
  format($$ select create_cohort_with_class_rep(
    %L::uuid, 2023, 5, 'bimester', %L::uuid, %L::uuid) $$,
    pg_temp.prog('EB1'), pg_temp.kevin(), pg_temp.fst_rep()),
  '23505',
  null,
  'a cohort duplicating an existing programme+intake+pace is refused'
);

-- current_semester is deliberately NOT in the key. It is mutable progression
-- state — 0014 grants column-level UPDATE on it precisely so a rep can advance
-- their cohort — and advancing must not vacate an identity slot for someone
-- else to occupy.
select lives_ok(
  $$ update cohorts set current_semester = current_semester + 1
     where programme_id = (select id from programmes where code = 'EB1')
       and intake_year = 2023 and pace = 'trimester' $$,
  'advancing a cohort''s semester is still allowed — semester is not part of its identity'
);


-- ============================================================================
-- §3 The dead columns are gone (§2.8)
-- ============================================================================
-- Cheap, and the thing that actually catches a future migration quietly
-- re-adding one.
select hasnt_column('public', 'events', 'recurrence_rule',
  'events.recurrence_rule is gone — dead text since 0004 called it "display metadata only"');

select hasnt_column('public', 'cohorts', 'join_code',
  'cohorts.join_code is gone — superseded by the roster, per 0.5');


-- ============================================================================
-- §4 Notification indexes (§2.4)
-- ============================================================================
select has_index('public', 'notifications', 'notifications_user_recent_idx',
  'the notification list has an index matching its newest-first query');

select has_index('public', 'notifications', 'notifications_user_unread_idx',
  'the unread badge has a partial index that stays small as history grows');

select hasnt_index('public', 'notifications', 'notifications_user_idx',
  'the bare (user_id) index it replaces is gone rather than left as dead weight');


-- ============================================================================
-- §5 events_current actually filters (§2.5)
-- ============================================================================
-- It filtered 'rescheduled' but not 'canceled', so a canceled lecture appeared
-- in a view whose entire purpose is "what is on" — worse than useless, because
-- it looked like it had already done the job.
select is(
  (select count(*)::int from events_current where status = 'canceled'),
  0,
  'events_current excludes canceled lectures — the half of the predicate that was missing'
);

select is(
  (select count(*)::int from events_current where status = 'rescheduled'),
  0,
  '...and still excludes retired rescheduled occurrences'
);

select cmp_ok(
  (select count(*)::int from events_current where status = 'scheduled'), '>', 0,
  '...while scheduled lectures are still there'
);

-- 'proposed' stays IN deliberately: a combined lecture awaiting confirmation is
-- real for the initiating cohort and already reserves everyone's slot through
-- the event_cohorts EXCLUDE constraint, so hiding it would leave a rep unable
-- to see the thing occupying their calendar.
select cmp_ok(
  (select count(*)::int from events_current where status = 'proposed'), '>', 0,
  '...and a pending proposal is still visible, because it already holds a slot'
);


-- ============================================================================
-- §6 demote_class_rep leaves a trace (§2.7)
-- ============================================================================
-- 0022 created role_audit_log with role_action = {promoted, demoted} and then
-- only ever wrote 'promoted', leaving demotion — which REMOVES a cohort's
-- ability to schedule anything — exactly as unlogged as before the table
-- existed.
select pg_temp.act_as(pg_temp.fst_rep());

select lives_ok(
  format($$ select demote_class_rep(%L::uuid, %L::uuid) $$,
         pg_temp.brian(), pg_temp.fst_rep()),
  'a faculty rep can demote a class rep in their own faculty'
);

select is(
  (select row(role, class_rep_rank) from users where id = pg_temp.brian()),
  row('student'::user_role, null::class_rep_rank),
  '...the demotion actually lands'
);

select is(
  (select count(*)::int from role_audit_log
    where user_id = pg_temp.brian() and action = 'demoted'),
  1,
  '...and writes exactly one ''demoted'' row, an enum value nothing could reach before'
);

select is(
  (select row(actor_id, user_name, snapshot->>'previous_rank')
     from role_audit_log where user_id = pg_temp.brian() and action = 'demoted'),
  row(pg_temp.fst_rep(), 'Brian Otieno'::text, 'assistant'::text),
  '...naming who did it, to whom, and which rank was taken away'
);

select is(
  (select new_rank from role_audit_log
    where user_id = pg_temp.brian() and action = 'demoted'),
  null,
  'new_rank is null on a demotion — they hold no rank now; the old one is in the snapshot'
);


-- ============================================================================
-- §7 Retention: an account can finally be deleted (§2.3)
-- ============================================================================
-- LAST, because deleting a user cascades through half the dataset.
--
-- users.id cascades from auth.users, and that cascade used to hit five columns
-- that refused to give up their reference — three of which TODO §2.3 never
-- listed, because two of them said 'no action' rather than 'restrict' and one
-- (attendance_confirmed_by) only became reachable when 0022 made it writable.
reset role;

select is(
  (select count(*)::int from pg_constraint
    where contype = 'f' and confrelid = 'users'::regclass
      and confdeltype in ('r', 'a')),
  0,
  'no FK into users(id) blocks a delete any more — RESTRICT and NO ACTION both gone'
);

-- The trigger, not the ten functions that write audit rows, is what fills the
-- retained name. Nothing below ever passes it.
select is(
  (select count(*)::int from event_audit_log where changed_by is not null and changed_by_name is null),
  0,
  'every audit row with an actor carries a retained name — filled by trigger, never by a caller'
);

create temp table before_delete as
select
  (select count(*)::int from events where created_by = '22222222-0000-4000-8000-000000000011') as events_created,
  (select count(*)::int from event_audit_log where changed_by = '22222222-0000-4000-8000-000000000011') as audit_rows;

select cmp_ok(
  (select events_created from before_delete), '>', 0,
  'the account about to be deleted really did schedule lectures — otherwise this proves nothing'
);

select lives_ok(
  $$ delete from auth.users where id = '22222222-0000-4000-8000-000000000011' $$,
  'deleting an auth account that scheduled lectures SUCCEEDS — it never could before'
);

select is(
  (select count(*)::int from users where id = pg_temp.mercy()),
  0,
  '...the public.users row cascades away with it'
);

select is(
  (select count(*)::int from event_audit_log where changed_by_name = 'Mercy Wanjiku'),
  (select audit_rows from before_delete),
  '...every audit row survives, because an audit log erasable by deleting its subject is not one'
);

select is(
  (select count(*)::int from event_audit_log
    where changed_by_name = 'Mercy Wanjiku' and changed_by is not null),
  0,
  '...with the actor pointer nulled'
);

select cmp_ok(
  (select count(*)::int from events where created_by is null), '>=',
  (select events_created from before_delete),
  '...and the lectures themselves survive with created_by nulled, not deleted'
);

-- The consequence, recorded rather than discovered later: a UI rendering
-- "scheduled by" from events.created_by shows nothing for these rows and must
-- fall back to the 'created' audit row, which is where the name now lives.
select cmp_ok(
  (select count(*)::int from event_audit_log
    where changed_by_name = 'Mercy Wanjiku' and action = 'created'), '>', 0,
  '...and attribution is still recoverable, from the audit log rather than the event row'
);


select * from finish();
rollback;
