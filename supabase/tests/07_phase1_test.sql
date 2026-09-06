-- ============================================================================
-- 07: Phase 1 — recurrence, the edit path, attendance, promote_class_rep
-- ============================================================================
-- 0022. Everything here had NO code path before that migration: create_event
-- could only ever produce a single occurrence, nothing could confirm
-- attendance, nothing could edit a title or lecturer, and the assistant rank
-- was unreachable from inside the app. See PHASE1_HANDOFF.md for the full
-- spec this file checks against.
--
-- All new events live two calendar years out, in months chosen deliberately:
-- February (Jan-Apr term, valid for every pace), June (May-Aug — a real term
-- for a trimester cohort, the long break for a bimester one) and April
-- (still Jan-Apr, used where §4 needs headroom before the term ceiling).
-- That keeps every row here calendar-disjoint from the seed's own timetable
-- (which is always anchored to "next week" from whenever `db reset` ran) and
-- from every other test file, without depending on what today's date is.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(62);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
create function pg_temp.venue(p_b text, p_r text) returns uuid language sql stable as $$
  select v.id from venues v join rooms r on r.id = v.room_id
  join buildings b on b.id = r.building_id
  where b.abbreviation = p_b and r.number = p_r;
$$;
create function pg_temp.course(p_prog text, p_abbr text) returns uuid language sql stable as $$
  select c.id from courses c join programmes p on p.id = c.programme_id
  where p.code = p_prog and c.abbreviation = p_abbr;
$$;
-- One create_event attachment (0022 §1). Concatenate with || for a second
-- cohort, which is what makes a lecture a combined one.
create function pg_temp.att(p_code text, p_intake_year int, p_abbr text) returns jsonb
language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'cohort_id', pg_temp.cohort(p_code, p_intake_year),
    'course_id', pg_temp.course(p_code, p_abbr)
  ));
$$;

-- Two years out, so nothing here can ever collide with the seed's "next week"
-- timetable regardless of when the suite runs.
create function pg_temp.test_year() returns int language sql immutable as $$
  select extract(year from now())::int + 2
$$;
create function pg_temp.dt(p_month int, p_day int, p_hour int) returns timestamptz
language sql stable as $$
  select make_timestamptz(pg_temp.test_year(), p_month, p_day, p_hour, 0, 0, 'Africa/Nairobi');
$$;
-- What create_event's own loop computes: step weekly from p_start while the
-- occurrence date <= horizon. Independent of the migration's SQL so it is a
-- real check, not a restatement.
create function pg_temp.week_count(p_start date, p_horizon date) returns int
language sql immutable as $$
  select floor((p_horizon - p_start) / 7.0)::int + 1
$$;

create function pg_temp.audit_count(p_event uuid, p_action text) returns int
language sql stable as $$
  select count(*)::int from event_audit_log
  where event_id = p_event and action = p_action::audit_action;
$$;
create function pg_temp.msgs(p_event uuid, p_action text) returns int
language sql stable as $$
  select count(*)::int from realtime.messages
  where payload->>'id' = p_event::text and event = p_action;
$$;
create function pg_temp.att_course(p_event uuid, p_cohort uuid) returns uuid
language sql stable as $$
  select course_id from event_cohorts where event_id = p_event and cohort_id = p_cohort;
$$;

-- Seeded people (see seed.sql §9).
create function pg_temp.fst_rep()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.fhss_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000002'::uuid $$;
create function pg_temp.cs23_rep() returns uuid language sql immutable as    -- Mercy, BSC-CS 2023 (bimester)
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.faith()    returns uuid language sql immutable as    -- BSC-CS 2023, plain student
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;
create function pg_temp.cs24_rep() returns uuid language sql immutable as    -- Dennis, BSC-CS 2024 (trimester)
  $$ select '22222222-0000-4000-8000-000000000021'::uuid $$;
create function pg_temp.grace()    returns uuid language sql immutable as    -- BSC-CS 2024, plain student, oauth-claimed
  $$ select '22222222-0000-4000-8000-000000000022'::uuid $$;
create function pg_temp.acs23_rep() returns uuid language sql immutable as   -- Samuel, BSC-ACS 2023
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;
create function pg_temp.cynthia()  returns uuid language sql immutable as    -- BSC-ACS 2023, plain student, provisional claim
  $$ select '22222222-0000-4000-8000-000000000032'::uuid $$;

create temp table ev (label text primary key, id uuid);
create temp table grp (label text primary key, id uuid);


-- ============================================================================
-- §1 Recurrence materialization — bounded by the term, p_until earlier/later
-- ============================================================================

-- --- A: no p_until at all -> bounded purely by the term end -----------------
select pg_temp.act_as(pg_temp.cs24_rep());
insert into ev select 'a1', create_event(
  pg_temp.att('EB1', 2024,'DBMS'), pg_temp.venue('S','601'),
  'Fredrick O. Ogolla', 'Weekly DBMS revision',
  pg_temp.dt(2, 3, 7), pg_temp.dt(2, 3, 10), 'week', null, pg_temp.cs24_rep());

select ok(
  (select recurrence_group_id from events where id = (select id from ev where label = 'a1')) is not null,
  'a recurring lecture gets a recurrence_group_id'
);

select is(
  (select count(*)::int from events
   where recurrence_group_id = (select recurrence_group_id from events where id = (select id from ev where label = 'a1'))),
  pg_temp.week_count(make_date(pg_temp.test_year(), 2, 3), make_date(pg_temp.test_year(), 4, 30)),
  'occurrence count matches the term-end horizon exactly'
);

select is(
  (select count(distinct recurrence_group_id)::int from events
   where recurrence_group_id = (select recurrence_group_id from events where id = (select id from ev where label = 'a1'))),
  1,
  'every occurrence in the series shares exactly one group id'
);

select ok(
  (select max(start_time)::date from events
   where recurrence_group_id = (select recurrence_group_id from events where id = (select id from ev where label = 'a1')))
  <= make_date(pg_temp.test_year(), 4, 30),
  'no occurrence is materialized past the term end'
);

-- --- B1: p_until earlier than the term end is respected ---------------------
insert into ev select 'b1', create_event(
  pg_temp.att('EB1', 2024,'SESA'), pg_temp.venue('S','602'),
  'Harun Njenga Ngugi', null,
  pg_temp.dt(2, 4, 7), pg_temp.dt(2, 4, 10), 'week',
  make_date(pg_temp.test_year(), 2, 25), pg_temp.cs24_rep());

select is(
  (select count(*)::int from events
   where recurrence_group_id = (select recurrence_group_id from events where id = (select id from ev where label = 'b1'))),
  pg_temp.week_count(make_date(pg_temp.test_year(), 2, 4), make_date(pg_temp.test_year(), 2, 25)),
  'an earlier p_until shortens the series to match'
);

select is(
  (select max(start_time)::date from events
   where recurrence_group_id = (select recurrence_group_id from events where id = (select id from ev where label = 'b1'))),
  make_date(pg_temp.test_year(), 2, 25),
  'the last occurrence lands exactly on p_until, not before or after it'
);

-- --- B2: p_until later than the term end is clamped --------------------------
insert into ev select 'b2', create_event(
  pg_temp.att('EB1', 2024,'CNDS'), pg_temp.venue('BSL','201'),
  'Peter Kiplang''at Koech', null,
  pg_temp.dt(2, 5, 7), pg_temp.dt(2, 5, 10), 'week',
  make_date(pg_temp.test_year(), 6, 1), pg_temp.cs24_rep());

select is(
  (select count(*)::int from events
   where recurrence_group_id = (select recurrence_group_id from events where id = (select id from ev where label = 'b2'))),
  pg_temp.week_count(make_date(pg_temp.test_year(), 2, 5), make_date(pg_temp.test_year(), 4, 30)),
  'a p_until past the term end is clamped to the term end'
);

select ok(
  (select max(start_time)::date from events
   where recurrence_group_id = (select recurrence_group_id from events where id = (select id from ev where label = 'b2')))
  <= make_date(pg_temp.test_year(), 4, 30),
  '...and no occurrence actually lands in the requested-but-clamped tail'
);


-- ============================================================================
-- §2 Recurrence refusals
-- ============================================================================

-- --- A bimester cohort has no term at all in the May-Aug break --------------
select pg_temp.act_as(pg_temp.cs23_rep());
select throws_ok(
  format($$ select create_event(
    pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('S','601'),
    'Fredrick O. Ogolla', null, %L::timestamptz, %L::timestamptz, 'week', null, %L::uuid
  ) $$, pg_temp.dt(6, 1, 7), pg_temp.dt(6, 1, 10), pg_temp.cs23_rep()),
  'P0001',
  -- The message names WHICH cohort as of 0030: a combined series can attach
  -- several, and every one of them must have a teaching term containing the
  -- start date.
  format(
    'Cohort %s has no teaching term containing %s (a bimester cohort does not teach then), '
    'so a recurring series cannot be bounded. A one-off lecture is still allowed.',
    pg_temp.cohort('EB1', 2023)::text, make_date(pg_temp.test_year(), 6, 1)::text
  ),
  'a bimester cohort starting a series in its May-Aug break is refused'
);

select is(
  (select count(*)::int from events where lecturer_name = 'Fredrick O. Ogolla'
     and start_time = pg_temp.dt(6, 1, 7)),
  0,
  '...and nothing was inserted for the refused attempt'
);

-- --- A one-off in the same break is fine — term_bounds gates recurrence only -
select lives_ok(
  format($$ select create_event(
    pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('S','601'),
    'Fredrick O. Ogolla', null, %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid
  ) $$, pg_temp.dt(6, 1, 7), pg_temp.dt(6, 1, 10), pg_temp.cs23_rep()),
  'a one-off make-up lecture in the same break is allowed — term_bounds gates recurrence only'
);

-- --- Recurrence + combined: REFUSED IN PHASE 1, ALLOWED AS OF 0030 -----------
-- This assertion is inverted on purpose rather than deleted. Phase 1 refused a
-- recurring combined lecture, on `0.1` sub-decision 5's reasoning that it would
-- need every attached rep to reconfirm every occurrence. `S.4`/0030 supplied the
-- missing piece — confirm the series once — and lifted the guard, because
-- term-long combined teaching turns out to be ordinary here.
-- Full coverage lives in 11_recurring_combined_test.sql; this is the tombstone.
-- Deliberately starts in OCTOBER: this now really does materialize a series, and
-- the Sep-Dec term is the one window nothing else in this file uses, so those
-- occurrences cannot collide with the February and March assertions below.
select lives_ok(
  format($$ select create_event(
    pg_temp.att('EB1', 2023,'CNDS') || pg_temp.att('EB3', 2023,'CSND'),
    pg_temp.venue('BSR','301'), 'Harun Njenga Ngugi', null,
    %L::timestamptz, %L::timestamptz, 'week', null, %L::uuid
  ) $$, pg_temp.dt(10, 6, 7), pg_temp.dt(10, 6, 10), pg_temp.cs23_rep()),
  'a recurring COMBINED lecture is now allowed — 0030 reversed Phase 1''s refusal'
);


-- ============================================================================
-- §3 All-or-nothing on a clash — the whole series aborts, naming the date
-- ============================================================================
-- The blocker takes a DIFFERENT venue from the series so only the cohort
-- self-overlap constraint fires — isolating which of the two EXCLUDE
-- constraints produced the message being checked.
--
-- On BSC-ACS 2023 rather than BSC-CS 2024: that keeps this scenario's dates
-- on their own weekly cycle, decoupled from §1's CS-2024 series. A "7 days
-- apart" scheme only guarantees two series never collide when they share a
-- cohort; a fresh cohort removes the constraint entirely rather than relying
-- on hand-checked date arithmetic.
select pg_temp.act_as(pg_temp.acs23_rep());
insert into ev select 'e_blocker', create_event(
  pg_temp.att('EB3', 2023,'CSND'), pg_temp.venue('BSR','302'),
  'Harun Njenga Ngugi', null,
  pg_temp.dt(3, 16, 9), pg_temp.dt(3, 16, 12), 'none', null, pg_temp.acs23_rep());

select throws_ok(
  format($$ select create_event(
    pg_temp.att('EB3', 2023,'AIML'), pg_temp.venue('BSL','301'),
    'Peter Kiplang''at Koech', 'The doomed series',
    %L::timestamptz, %L::timestamptz, 'week', %L::date, %L::uuid
  ) $$, pg_temp.dt(3, 2, 9), pg_temp.dt(3, 2, 12),
        make_date(pg_temp.test_year(), 3, 30), pg_temp.acs23_rep()),
  '23P01',
  -- As of 0030 the error names EVERY clashing date, not just the first. A
  -- term-long combined series has to clear two calendars across fifteen weeks,
  -- so reporting one conflict per attempt would mean a round trip per bad week.
  -- All-or-nothing itself is unchanged (`0.1` decision 3).
  format(
    E'Cannot schedule this series — 1 of 5 occurrence(s) clash:\n'
    '  %s  an attached cohort already has a lecture\n'
    'No occurrences were created.',
    make_date(pg_temp.test_year(), 3, 16)::text
  ),
  'a clash aborts the whole series and names every offending date'
);

select is(
  (select count(*)::int from events where title = 'The doomed series'),
  0,
  '...and genuinely nothing was created — not even the first two clean occurrences'
);


-- ============================================================================
-- §4 cancel_recurrence_group — reaches a rescheduled occurrence too
-- ============================================================================
-- Also on BSC-ACS 2023 (see §3's note), in April rather than §3's March —
-- different month, so this series' own three dates can never coincide with
-- §3's blocker or its failed (and therefore unmaterialized) series.
select pg_temp.act_as(pg_temp.acs23_rep());
insert into ev select 'f1', create_event(
  pg_temp.att('EB3', 2023,'CCDO'), pg_temp.venue('MS','01'),
  'Fredrick O. Ogolla', 'Cancel-me series',
  pg_temp.dt(4, 6, 7), pg_temp.dt(4, 6, 10), 'week',
  make_date(pg_temp.test_year(), 4, 20), pg_temp.acs23_rep());

insert into grp select 'f', recurrence_group_id from events where id = (select id from ev where label = 'f1');

select is(
  (select count(*)::int from events where recurrence_group_id = (select id from grp where label = 'f')),
  3,
  'sanity: the cancel-me series has exactly 3 occurrences (Apr 6/13/20)'
);

-- Reschedule the middle occurrence to a day with nothing else on it.
insert into ev select 'f2', reschedule_event(
  (select id from events where recurrence_group_id = (select id from grp where label = 'f')
     and start_time = pg_temp.dt(4, 13, 7)),
  pg_temp.dt(4, 14, 7), pg_temp.dt(4, 14, 10), pg_temp.venue('MS','01'), pg_temp.acs23_rep());

select is(
  (select recurrence_group_id from events where id = (select id from ev where label = 'f2')),
  (select id from grp where label = 'f'),
  'a rescheduled occurrence keeps its recurrence_group_id — it stays in the series'
);

-- Authorization: only the initiating cohort's rep may cancel the series.
select pg_temp.act_as(pg_temp.cs24_rep());
select throws_ok(
  format($$ select cancel_recurrence_group(%L::uuid, %L::uuid) $$,
         (select id from grp where label = 'f'), pg_temp.cs24_rep()),
  'P0001',
  'Only the initiating cohort''s class_rep may cancel this series',
  'a rep with no stake in the series cannot cancel it'
);

select throws_ok(
  format($$ select cancel_recurrence_group(%L::uuid, %L::uuid) $$,
         gen_random_uuid(), pg_temp.cs24_rep()),
  'P0001',
  null,
  'an unknown group id is refused'
);

select pg_temp.act_as(pg_temp.acs23_rep());
select is(
  cancel_recurrence_group((select id from grp where label = 'f'), pg_temp.acs23_rep()),
  3,
  'cancelling reaches the two untouched occurrences AND the rescheduled replacement — 3, not 2'
);

select is(
  (select status::text from events
   where recurrence_group_id = (select id from grp where label = 'f') and start_time = pg_temp.dt(4, 13, 7)),
  'rescheduled',
  'the retired (superseded) occurrence is left exactly as it was, not overwritten'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'f2')),
  'canceled',
  'its live replacement is the one that actually gets canceled'
);

select is(
  (select count(*)::int from events
   where recurrence_group_id = (select id from grp where label = 'f') and status = 'canceled'),
  3,
  'all three live occurrences (two original, one replacement) end up canceled'
);


-- ============================================================================
-- §5 Per-cohort courses on a combined lecture, and the unrelated-programme guard
-- ============================================================================
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'g1', create_event(
  pg_temp.att('EB1', 2023,'CNDS') || pg_temp.att('EB3', 2023,'AIML'),
  pg_temp.venue('PAV','HALL'), 'Peter Kiplang''at Koech', null,
  pg_temp.dt(2, 12, 13), pg_temp.dt(2, 12, 16), 'none', null, pg_temp.cs23_rep());

select is(
  pg_temp.att_course((select id from ev where label = 'g1'), pg_temp.cohort('EB1', 2023)),
  pg_temp.course('EB1','CNDS'),
  'the initiating cohort sees the unit from its OWN programme'
);

select is(
  pg_temp.att_course((select id from ev where label = 'g1'), pg_temp.cohort('EB3', 2023)),
  pg_temp.course('EB3','AIML'),
  '...and the partner cohort sees a DIFFERENT unit, from its own programme'
);

select isnt(
  pg_temp.att_course((select id from ev where label = 'g1'), pg_temp.cohort('EB1', 2023)),
  pg_temp.att_course((select id from ev where label = 'g1'), pg_temp.cohort('EB3', 2023)),
  '...the two are not accidentally the same row'
);

-- A course from a programme unrelated to the attached cohort is refused. A
-- single bad attachment, not concatenated with a valid one for the same
-- cohort — two attachments for one cohort with different courses trips the
-- EARLIER "attends as exactly one unit" guard instead, which would make this
-- assert the wrong failure for the right-looking reason.
select throws_ok(
  format($$ select create_event(
    jsonb_build_array(
      jsonb_build_object('cohort_id', pg_temp.cohort('EB1', 2023), 'course_id', pg_temp.course('EB3','AIML'))
    ), pg_temp.venue('S','601'), 'Someone', null, %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid
  ) $$, pg_temp.dt(2, 13, 7), pg_temp.dt(2, 13, 10), pg_temp.cs23_rep()),
  'P0001',
  format('Course %s is not offered by cohort %s''s programme',
         pg_temp.course('EB3','AIML'), pg_temp.cohort('EB1', 2023)),
  'a course from a programme the cohort is not enrolled in is refused'
);


-- ============================================================================
-- §6 update_event — the missing edit path
-- ============================================================================
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'i1', create_event(
  pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('S','602'),
  'Old Lecturer', 'Old title', pg_temp.dt(2, 14, 7), pg_temp.dt(2, 14, 10),
  'none', null, pg_temp.cs23_rep());

select lives_ok(
  format($$ select update_event(%L::uuid, 'New title', 'New Lecturer', %L::uuid, %L::uuid) $$,
         (select id from ev where label = 'i1'), pg_temp.course('EB1','SESA'), pg_temp.cs23_rep()),
  'the initiating rep can edit title, lecturer and their own cohort''s course'
);

select is(
  (select title from events where id = (select id from ev where label = 'i1')),
  'New title', 'title changed'
);
select is(
  (select lecturer_name from events where id = (select id from ev where label = 'i1')),
  'New Lecturer', 'lecturer changed'
);
select is(
  pg_temp.att_course((select id from ev where label = 'i1'), pg_temp.cohort('EB1', 2023)),
  pg_temp.course('EB1','SESA'),
  'the course changed to the new unit'
);
select is(
  pg_temp.audit_count((select id from ev where label = 'i1'), 'updated'),
  1,
  'an ''updated'' audit row is written'
);

-- Null means "leave unchanged": lecturer untouched by a title-only edit.
select lives_ok(
  format($$ select update_event(%L::uuid, 'Title only', null, null, %L::uuid) $$,
         (select id from ev where label = 'i1'), pg_temp.cs23_rep()),
  'a partial edit is allowed'
);
select is(
  (select lecturer_name from events where id = (select id from ev where label = 'i1')),
  'New Lecturer', 'null means leave unchanged — the lecturer survived a title-only edit'
);

-- A course from an unrelated programme is refused on the edit path too.
select throws_ok(
  format($$ select update_event(%L::uuid, null, null, %L::uuid, %L::uuid) $$,
         (select id from ev where label = 'i1'), pg_temp.course('EB3','AIML'), pg_temp.cs23_rep()),
  'P0001',
  null,
  'update_event refuses a course from a programme the rep''s cohort is not enrolled in'
);

-- Non-initiator refused. Build a combined lecture and have the PARTNER cohort's
-- rep — attached, but not the initiator — try to edit it.
insert into ev select 'i2', create_event(
  pg_temp.att('EB1', 2023,'DBMS') || pg_temp.att('EB1', 2024,'DBMS'),
  pg_temp.venue('PAV','HALL'), 'Fredrick O. Ogolla', null,
  pg_temp.dt(2, 15, 7), pg_temp.dt(2, 15, 10), 'none', null, pg_temp.cs23_rep());

select pg_temp.act_as(pg_temp.cs24_rep());
select confirm_event_cohort((select id from ev where label = 'i2'), pg_temp.cs24_rep());

select throws_ok(
  format($$ select update_event(%L::uuid, 'Hijacked', null, null, %L::uuid) $$,
         (select id from ev where label = 'i2'), pg_temp.cs24_rep()),
  'P0001',
  'Only the initiating cohort''s class_rep may edit this event',
  'an attached but non-initiating rep cannot edit the lecture'
);


-- ============================================================================
-- §7 Attendance confirmation — the headline feature
-- ============================================================================
-- Combined lecture so the "any attached rep, not just the initiator" claim is
-- actually exercised rather than merely permitted.
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'j1', create_event(
  pg_temp.att('EB1', 2023,'DBMS') || pg_temp.att('EB1', 2024,'DBMS'),
  pg_temp.venue('S','601'), 'Fredrick O. Ogolla', null,
  pg_temp.dt(2, 16, 7), pg_temp.dt(2, 16, 10), 'none', null, pg_temp.cs23_rep());

select pg_temp.act_as(pg_temp.cs24_rep());
select confirm_event_cohort((select id from ev where label = 'j1'), pg_temp.cs24_rep());

select is(
  (select status::text from events where id = (select id from ev where label = 'j1')),
  'scheduled', 'sanity: both sides confirmed, the lecture is live'
);

-- The NON-initiating rep confirms attendance.
select lives_ok(
  format($$ select confirm_attendance(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'j1'), pg_temp.cs24_rep()),
  'a non-initiating attached rep may confirm attendance'
);

select is(
  (select attendance_status::text from events where id = (select id from ev where label = 'j1')),
  'confirmed', 'attendance_status flips to confirmed'
);
select is(
  (select attendance_confirmed_by from events where id = (select id from ev where label = 'j1')),
  pg_temp.cs24_rep(), 'attendance_confirmed_by records who made the call'
);
select is(
  pg_temp.audit_count((select id from ev where label = 'j1'), 'confirmed'),
  1, 'a ''confirmed'' audit row is written'
);
select is(
  pg_temp.msgs((select id from ev where label = 'j1'), 'attendance_confirmed'),
  2, 'the broadcast action is attendance_confirmed (not the borrowed confirmation_needed name), one per attached cohort'
);

select pg_temp.act_as(pg_temp.cs23_rep());
select throws_ok(
  format($$ select confirm_attendance(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'j1'), pg_temp.cs23_rep()),
  'P0001',
  format('Attendance for event %s is already confirmed', (select id from ev where label = 'j1')),
  'confirming an already-confirmed lecture is refused'
);

-- A plain student, not a class rep of any attached cohort, may not confirm.
select pg_temp.act_as(pg_temp.faith());
select throws_ok(
  format($$ select confirm_attendance(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'j1'), pg_temp.faith()),
  'P0001',
  'Only a class_rep of a cohort attending this lecture may confirm attendance',
  'a plain student cannot confirm attendance'
);

-- Un-confirming. Any attached rep, including one who did not make the original
-- call, may withdraw it.
select pg_temp.act_as(pg_temp.cs23_rep());
select lives_ok(
  format($$ select unconfirm_attendance(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'j1'), pg_temp.cs23_rep()),
  'un-confirming is allowed, and by a different rep than the one who confirmed'
);

select is(
  (select attendance_status::text from events where id = (select id from ev where label = 'j1')),
  'pending', 'attendance_status returns to pending'
);
select ok(
  (select attendance_confirmed_by is null and attendance_confirmed_at is null
     from events where id = (select id from ev where label = 'j1')),
  '...and both confirmed_by and confirmed_at are cleared, not just the status'
);
select is(
  pg_temp.audit_count((select id from ev where label = 'j1'), 'unconfirmed'),
  1, 'an ''unconfirmed'' audit row is written'
);
select is(
  pg_temp.msgs((select id from ev where label = 'j1'), 'attendance_unconfirmed'),
  2, 'the withdrawal broadcasts attendance_unconfirmed to every attached cohort'
);

select pg_temp.act_as(pg_temp.cs24_rep());
select throws_ok(
  format($$ select unconfirm_attendance(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'j1'), pg_temp.cs24_rep()),
  'P0001',
  format('Attendance for event %s is not confirmed', (select id from ev where label = 'j1')),
  'un-confirming an already-pending lecture is refused'
);

-- Refused on a canceled lecture.
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'j2', create_event(
  pg_temp.att('EB1', 2023,'SESA'), pg_temp.venue('MS','02'),
  'Harun Njenga Ngugi', null, pg_temp.dt(2, 17, 7), pg_temp.dt(2, 17, 10),
  'none', null, pg_temp.cs23_rep());
select cancel_event((select id from ev where label = 'j2'), pg_temp.cs23_rep());

select throws_ok(
  format($$ select confirm_attendance(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'j2'), pg_temp.cs23_rep()),
  'P0001',
  format('Event %s is canceled — attendance can only be confirmed for a scheduled lecture',
         (select id from ev where label = 'j2')),
  'attendance cannot be confirmed for a canceled lecture'
);

-- Refused on a still-proposed lecture (nothing is real for every cohort yet).
insert into ev select 'j3', create_event(
  pg_temp.att('EB1', 2023,'CNDS') || pg_temp.att('EB3', 2023,'CSND'),
  pg_temp.venue('BSL','005'), 'Harun Njenga Ngugi', null,
  pg_temp.dt(2, 18, 7), pg_temp.dt(2, 18, 10), 'none', null, pg_temp.cs23_rep());

select throws_ok(
  format($$ select confirm_attendance(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'j3'), pg_temp.cs23_rep()),
  'P0001',
  format('Event %s is proposed — attendance can only be confirmed for a scheduled lecture',
         (select id from ev where label = 'j3')),
  'attendance cannot be confirmed while a combined lecture is still only proposed'
);


-- ============================================================================
-- §8 promote_class_rep — the assistant rank, and 0.5's identity attestation
-- ============================================================================

-- Rank uniqueness: BSC-ACS 2023 already has a primary (Samuel). Promoting
-- Cynthia to primary too is refused before the attestation question even
-- arises.
select pg_temp.act_as(pg_temp.fst_rep());
select throws_ok(
  format($$ select promote_class_rep(%L::uuid, 'primary', %L::uuid, true) $$,
         pg_temp.cynthia(), pg_temp.fst_rep()),
  'P0001',
  null,
  'a cohort cannot get a second primary class rep'
);

-- Cross-faculty refused: Grace is FST (BSC-CS 2024); the FHSS rep has no
-- authority over her.
select pg_temp.act_as(pg_temp.fhss_rep());
select throws_ok(
  format($$ select promote_class_rep(%L::uuid, 'assistant', %L::uuid, true) $$,
         pg_temp.grace(), pg_temp.fhss_rep()),
  'P0001',
  format('User %s is in another faculty', pg_temp.grace()),
  'a faculty rep cannot promote a student outside their own faculty'
);

-- Third rep refused: BSC-CS 2023 already has both a primary and an assistant
-- (Mercy and Brian, from seed §9.6).
select pg_temp.act_as(pg_temp.fst_rep());
select throws_ok(
  format($$ select promote_class_rep(%L::uuid, 'assistant', %L::uuid, true) $$,
         pg_temp.faith(), pg_temp.fst_rep()),
  'P0001',
  format('Cohort %s already has 2 class reps — demote one before promoting another',
         pg_temp.cohort('EB1', 2023)),
  'a cohort already holding two reps refuses a third'
);

-- The attestation. Cynthia's account is provisionally claimed (auth.internal,
-- password branch) — the faculty rep cannot tell that from her name alone.
select throws_ok(
  format($$ select promote_class_rep(%L::uuid, 'assistant', %L::uuid, false) $$,
         pg_temp.cynthia(), pg_temp.fst_rep()),
  'P0001',
  null,
  'promoting an unverified target without the attestation flag is refused'
);

select ok(
  (select role from users where id = pg_temp.cynthia()) = 'student',
  '...and the refused attempt left her role untouched'
);

select lives_ok(
  format($$ select promote_class_rep(%L::uuid, 'assistant', %L::uuid, true) $$,
         pg_temp.cynthia(), pg_temp.fst_rep()),
  'the same promotion succeeds once the rep explicitly attests to physical verification'
);

select is(
  (select row(role, class_rep_rank) from users where id = pg_temp.cynthia()),
  row('class_rep'::user_role, 'assistant'::class_rep_rank),
  'Cynthia is now the assistant class rep of BSC-ACS 2023'
);

select is(
  (select row(action, new_rank, (snapshot->>'identity_attested')::boolean, snapshot->>'claim_method')
     from role_audit_log where user_id = pg_temp.cynthia()),
  row('promoted'::role_action, 'assistant'::class_rep_rank, true, 'provisional'::text),
  'the attestation and the claim method it overrode are both on the audit row'
);

-- An OAuth-verified target needs no attestation at all.
select lives_ok(
  format($$ select promote_class_rep(%L::uuid, 'assistant', %L::uuid) $$,
         pg_temp.grace(), pg_temp.fst_rep()),
  'an oauth-claimed target can be promoted with no attestation flag'
);

select is(
  (select row(role, class_rep_rank) from users where id = pg_temp.grace()),
  row('class_rep'::user_role, 'assistant'::class_rep_rank),
  'Grace is now the assistant class rep of BSC-CS 2024'
);

select is(
  (select row((snapshot->>'identity_attested')::boolean, snapshot->>'claim_method')
     from role_audit_log where user_id = pg_temp.grace()),
  row(false, 'oauth'::text),
  'her audit row correctly records no attestation was needed'
);


select * from finish();
rollback;
