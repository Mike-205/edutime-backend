-- ============================================================================
-- 11: Recurring combined lectures
-- ============================================================================
-- 0030. A lecturer takes Applied CS together with Computer Science for a whole
-- semester — ordinary at Chuka, and until now inexpressible: create_event
-- refused recurrence whenever more than one cohort was attached, so a rep had
-- to hand-create fifteen occurrences.
--
-- `0.1` sub-decision 5 DEFERRED this rather than rejecting it, on the grounds
-- that a recurring cross-cohort series would need every attached rep to
-- reconfirm every occurrence. §2 is the piece that answers that — confirm the
-- series once — and it is why the guard could be lifted at all.
--
-- Each test file runs in its own transaction and rolls back, so the only shared
-- state is the seed. Everything here lives two calendar years out, clear of the
-- seed's "next week" timetable.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(19);


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
  where p.code = p_code and c.intake_year = p_intake_year and c.parent_cohort_id is null;
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
create function pg_temp.att(p_code text, p_intake_year int, p_abbr text) returns jsonb
language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'cohort_id', pg_temp.cohort(p_code, p_intake_year),
    'course_id', pg_temp.course(p_code, p_abbr)
  ));
$$;

create function pg_temp.test_year() returns int language sql immutable as $$
  select extract(year from now())::int + 2
$$;
create function pg_temp.dt(p_month int, p_day int, p_hour int) returns timestamptz
language sql stable as $$
  select make_timestamptz(pg_temp.test_year(), p_month, p_day, p_hour, 0, 0, 'Africa/Nairobi');
$$;
create function pg_temp.week_count(p_start date, p_horizon date) returns int
language sql immutable as $$
  select floor((p_horizon - p_start) / 7.0)::int + 1
$$;
create function pg_temp.grp_of(p_event uuid) returns uuid language sql stable as $$
  select recurrence_group_id from events where id = p_event;
$$;

create function pg_temp.cs23_rep()  returns uuid language sql immutable as  -- Mercy, BSC-CS 2023 (bimester)
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.cs24_rep()  returns uuid language sql immutable as  -- Dennis, BSC-CS 2024 (trimester)
  $$ select '22222222-0000-4000-8000-000000000021'::uuid $$;
create function pg_temp.acs23_rep() returns uuid language sql immutable as  -- Samuel, BSC-ACS 2023 (bimester)
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;
create function pg_temp.crim_rep()  returns uuid language sql immutable as  -- Abdul, BA-CRIM 2024 (FHSS)
  $$ select '22222222-0000-4000-8000-000000000041'::uuid $$;

create temp table ev (label text primary key, id uuid);


-- ============================================================================
-- §1 A recurring combined series can now be created at all
-- ============================================================================
-- Two cohorts, two programmes, one lecturer, every week to the end of term —
-- the shape that was refused outright before 0030.
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'series', create_event(
  pg_temp.att('EB1', 2023,'CNDS') || pg_temp.att('EB3', 2023,'AIML'),
  pg_temp.venue('PAV','HALL'), 'Peter Kiplang''at Koech', 'Joint AI/Networks',
  pg_temp.dt(2, 3, 13), pg_temp.dt(2, 3, 16), 'week', null, pg_temp.cs23_rep());

select is(
  (select count(*)::int from events where recurrence_group_id = pg_temp.grp_of((select id from ev where label='series'))),
  pg_temp.week_count(make_date(pg_temp.test_year(), 2, 3), make_date(pg_temp.test_year(), 4, 30)),
  'a recurring COMBINED series materializes to the term end, like a solo one'
);

select is(
  (select count(distinct recurrence_group_id)::int from events
    where recurrence_group_id = pg_temp.grp_of((select id from ev where label='series'))),
  1,
  '...with every occurrence in one recurrence group'
);

select is(
  (select count(*)::int from event_cohorts ec join events e on e.id = ec.event_id
    where e.recurrence_group_id = pg_temp.grp_of((select id from ev where label='series'))),
  2 * pg_temp.week_count(make_date(pg_temp.test_year(), 2, 3), make_date(pg_temp.test_year(), 4, 30)),
  '...and both cohorts attached to every occurrence'
);

select is(
  (select count(distinct status)::int || ':' || (select status::text from events
     where recurrence_group_id = pg_temp.grp_of((select id from ev where label='series')) limit 1)
   from events where recurrence_group_id = pg_temp.grp_of((select id from ev where label='series'))),
  '1:proposed',
  'every occurrence starts proposed — a combined lecture is not real until confirmed'
);

-- ONE notification for the whole series, not one per occurrence. Fifteen
-- notifications for a single scheduling decision is the churn 0.1 objected to.
select is(
  (select count(*)::int from notifications n
    join users u on u.id = n.user_id
   where n.event_id = (select id from ev where label='series')
     and u.cohort_id = pg_temp.cohort('EB3', 2023)
     and n.type = 'cohort_confirmation_needed'),
  (select count(*)::int from users where cohort_id = pg_temp.cohort('EB3', 2023) and role = 'class_rep'),
  'the partner cohort''s reps get ONE confirmation request for the whole series'
);


-- ============================================================================
-- §2 One confirmation covers the series
-- ============================================================================
-- The piece that made lifting the guard possible. Without it the partner rep
-- faces one proposal per week.
select pg_temp.act_as(pg_temp.acs23_rep());
select is(
  confirm_recurrence_group(pg_temp.grp_of((select id from ev where label='series')), pg_temp.acs23_rep()),
  pg_temp.week_count(make_date(pg_temp.test_year(), 2, 3), make_date(pg_temp.test_year(), 4, 30)),
  'the partner rep confirms the WHOLE series in one call'
);

select is(
  (select count(*)::int from events
    where recurrence_group_id = pg_temp.grp_of((select id from ev where label='series'))
      and status = 'scheduled'),
  pg_temp.week_count(make_date(pg_temp.test_year(), 2, 3), make_date(pg_temp.test_year(), 4, 30)),
  '...and every occurrence flips to scheduled'
);

select is(
  (select count(*)::int from event_cohorts ec join events e on e.id = ec.event_id
    where e.recurrence_group_id = pg_temp.grp_of((select id from ev where label='series'))
      and ec.confirmation_status = 'pending'),
  0,
  '...leaving nothing pending'
);

select throws_like(
  format($$ select confirm_recurrence_group(%L::uuid, %L::uuid) $$,
         pg_temp.grp_of((select id from ev where label='series')), pg_temp.acs23_rep()),
  '%No pending confirmation%',
  'confirming twice is refused rather than silently counting zero'
);

select pg_temp.act_as(pg_temp.crim_rep());
select throws_like(
  format($$ select confirm_recurrence_group(%L::uuid, %L::uuid) $$,
         pg_temp.grp_of((select id from ev where label='series')), pg_temp.crim_rep()),
  '%No pending confirmation%',
  'a rep with no stake in the series cannot confirm it'
);


-- ============================================================================
-- §3 One decline kills the series
-- ============================================================================
-- Mirrors decline_event_cohort's rule that any decline cancels the lecture for
-- everyone. The series was proposed as one thing, so there is no partial state
-- to land in.
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'doomed', create_event(
  pg_temp.att('EB1', 2023,'DBMS') || pg_temp.att('EB3', 2023,'CCDO'),
  pg_temp.venue('BSL','005'), 'Fredrick O. Ogolla', 'To be declined',
  pg_temp.dt(3, 4, 7), pg_temp.dt(3, 4, 10), 'week',
  make_date(pg_temp.test_year(), 3, 25), pg_temp.cs23_rep());

select pg_temp.act_as(pg_temp.acs23_rep());
select is(
  decline_recurrence_group(pg_temp.grp_of((select id from ev where label='doomed')), pg_temp.acs23_rep()),
  4,
  'the partner rep declines the whole series in one call (Mar 4/11/18/25)'
);

select is(
  (select count(*)::int from events
    where recurrence_group_id = pg_temp.grp_of((select id from ev where label='doomed'))
      and status = 'canceled'),
  4,
  '...cancelling every occurrence, for both cohorts'
);

select is(
  (select count(*)::int from event_audit_log l join events e on e.id = l.event_id
    where e.recurrence_group_id = pg_temp.grp_of((select id from ev where label='doomed'))
      and l.action = 'canceled'
      and l.snapshot->>'reason' = 'recurrence_group_declined'),
  4,
  '...with an audit row per occurrence naming the reason'
);


-- ============================================================================
-- §4 The horizon respects EVERY attached cohort's calendar
-- ============================================================================
-- The subtlety the old guard hid. With one cohort there was one pace to read;
-- with several, using only the initiator's would let a TRIMESTER initiator
-- materialize a series straight through a BIMESTER partner's May-Aug break —
-- booking a cohort into weeks it does not teach.
--
-- BSC-CS 2024 is trimester (it HAS a May-Aug term); BSC-CS 2023 is bimester (it
-- does not). A June series initiated by the trimester cohort must still be
-- refused, and must name the cohort that cannot host it.
select pg_temp.act_as(pg_temp.cs24_rep());
select throws_like(
  format($$ select create_event(
    pg_temp.att('EB1', 2024,'SESA') || pg_temp.att('EB1', 2023,'SESA'),
    pg_temp.venue('S','602'), 'Harun Njenga Ngugi', null,
    %L::timestamptz, %L::timestamptz, 'week', null, %L::uuid
  ) $$, pg_temp.dt(6, 2, 7), pg_temp.dt(6, 2, 10), pg_temp.cs24_rep()),
  '%bimester cohort does not teach then%',
  'a trimester initiator cannot drag a bimester partner into their May-Aug break'
);

select is(
  (select count(*)::int from events where lecturer_name = 'Harun Njenga Ngugi'
     and start_time = pg_temp.dt(6, 2, 7)),
  0,
  '...and nothing was created for the refused attempt'
);

-- The same pair in a term BOTH cohorts teach in is fine.
select lives_ok(
  format($$ select create_event(
    pg_temp.att('EB1', 2024,'SESA') || pg_temp.att('EB1', 2023,'SESA'),
    pg_temp.venue('S','602'), 'Harun Njenga Ngugi', null,
    %L::timestamptz, %L::timestamptz, 'week', %L::date, %L::uuid
  ) $$, pg_temp.dt(10, 6, 7), pg_temp.dt(10, 6, 10),
        make_date(pg_temp.test_year(), 10, 27), pg_temp.cs24_rep()),
  '...while the same pair in a term they BOTH teach is allowed'
);


-- ============================================================================
-- §5 A clash names every offending date
-- ============================================================================
-- All-or-nothing is unchanged (`0.1` decision 3). What changed is that a series
-- clearing TWO calendars across a term reports all its conflicts at once,
-- rather than one per attempt.
select pg_temp.act_as(pg_temp.acs23_rep());
insert into ev select 'blocker1', create_event(
  pg_temp.att('EB3', 2023,'CSND'), pg_temp.venue('BSR','302'),
  'Blocker One', null, pg_temp.dt(4, 7, 9), pg_temp.dt(4, 7, 12), 'none', null, pg_temp.acs23_rep());
insert into ev select 'blocker2', create_event(
  pg_temp.att('EB3', 2023,'CSND'), pg_temp.venue('BSR','302'),
  'Blocker Two', null, pg_temp.dt(4, 21, 9), pg_temp.dt(4, 21, 12), 'none', null, pg_temp.acs23_rep());

select throws_like(
  format($$ select create_event(
    pg_temp.att('EB3', 2023,'AIML'), pg_temp.venue('BSL','301'),
    'Peter Kiplang''at Koech', 'Doomed twice',
    %L::timestamptz, %L::timestamptz, 'week', %L::date, %L::uuid
  ) $$, pg_temp.dt(4, 7, 9), pg_temp.dt(4, 7, 12),
        make_date(pg_temp.test_year(), 4, 28), pg_temp.acs23_rep()),
  '%2 of 4 occurrence(s) clash%',
  'a series with two bad weeks reports BOTH, not just the first'
);

select throws_like(
  format($$ select create_event(
    pg_temp.att('EB3', 2023,'AIML'), pg_temp.venue('BSL','301'),
    'Doomed twice', 'Doomed twice',
    %L::timestamptz, %L::timestamptz, 'week', %L::date, %L::uuid
  ) $$, pg_temp.dt(4, 7, 9), pg_temp.dt(4, 7, 12),
        make_date(pg_temp.test_year(), 4, 28), pg_temp.acs23_rep()),
  '%' || make_date(pg_temp.test_year(), 4, 21)::text || '%',
  '...and the SECOND clashing date appears in the message, which is the whole point'
);

select is(
  (select count(*)::int from events where title = 'Doomed twice'),
  0,
  '...while still creating nothing — all-or-nothing is unchanged'
);


select * from finish();
rollback;
