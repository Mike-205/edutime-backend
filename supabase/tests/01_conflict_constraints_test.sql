-- ============================================================================
-- 01: Conflict detection — the core promise of the product
-- ============================================================================
-- "Zero venue double-bookings caused by the system itself" is DISCOVERY's first
-- success criterion, and these two EXCLUDE constraints are the only thing
-- enforcing it:
--
--   events_no_venue_overlap        (venue_id, tstzrange)  where status in ('proposed','scheduled')
--   event_cohorts_no_self_overlap  (cohort_id, tstzrange) where event_status_cache in (...)
--                                                           and confirmation_status <> 'left'
--
-- Everything below goes through create_event / cancel_event / reschedule_event
-- rather than raw INSERTs, so a broken function fails these tests too — which is
-- the point: create_event was unable to insert a single row for four migrations
-- and nothing noticed.
--
-- Fixtures come from seed.sql. Test events are placed ~200 days out so they can
-- never collide with the seeded timetable, which is always anchored to the week
-- after `db reset`.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.slot(d int, h int) returns timestamptz language sql stable as $$
  select date_trunc('week', now() + interval '200 days') + make_interval(days => d - 1, hours => h);
$$;

create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;

create function pg_temp.venue(p_b text, p_r text) returns uuid language sql stable as $$
  select v.id from venues v
  join rooms r     on r.id = v.room_id
  join buildings b on b.id = r.building_id
  where b.abbreviation = p_b and r.number = p_r;
$$;

create function pg_temp.course(p_prog text, p_abbr text) returns uuid language sql stable as $$
  select c.id from courses c
  join programmes p on p.id = c.programme_id
  where p.code = p_prog and c.abbreviation = p_abbr;
$$;

-- One create_event attachment (0022 §1): which cohort attends, and as which
-- unit. Concatenate with || to attach a second cohort. Since 0022 the unit is a
-- property of the attachment rather than of the event, so a combined lecture
-- across two programmes gives each cohort a course from its own programme —
-- passing one cohort a foreign programme's course is now refused outright.
create function pg_temp.att(p_code text, p_intake_year int, p_abbr text) returns jsonb
language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'cohort_id', pg_temp.cohort(p_code, p_intake_year),
    'course_id', pg_temp.course(p_code, p_abbr)
  ));
$$;

-- Forges auth.uid() for the rest of this transaction, the same way seed.sql does.
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create temp table ev (label text primary key, id uuid);

-- Class reps, from seed.sql.
create function pg_temp.cs23() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.cs24() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000021'::uuid $$;
create function pg_temp.acs23() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;


-- ---------------------------------------------------------------------------
-- Rule 1: no two events may share a venue at overlapping times
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.cs23());

insert into ev select 'mon_gt1', create_event(
  pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('S','GT1'),
  'Fredrick O. Ogolla', null,
  pg_temp.slot(1, 7), pg_temp.slot(1, 10), 'none', null, pg_temp.cs23());

select ok(
  (select id from ev where label = 'mon_gt1') is not null,
  'create_event returns an id for a plain single-cohort lecture'
);

-- A different cohort, a different rep, the same room, an overlapping window.
-- Physical venues are shared reference rows (one per room), so both events point
-- at the same venue_id and the constraint sees them.
select pg_temp.act_as(pg_temp.cs24());
select throws_ok(
  format($$ select create_event(%L::jsonb, %L::uuid, 'X', null,
                                %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid) $$,
         pg_temp.att('EB1', 2024,'DBMS'), pg_temp.venue('S','GT1'),
         pg_temp.slot(1, 8), pg_temp.slot(1, 11), pg_temp.cs24()),
  '23P01',
  null,
  'a second cohort cannot book the same room at an overlapping time'
);

-- Adjacent, not overlapping: tstzrange is '[)', so 10:00 may start where 10:00
-- ended. Back-to-back lectures in one room are normal and must be allowed.
insert into ev select 'mon_gt1_late', create_event(
  pg_temp.att('EB1', 2024,'DBMS'), pg_temp.venue('S','GT1'),
  'Fredrick O. Ogolla', null,
  pg_temp.slot(1, 10), pg_temp.slot(1, 13), 'none', null, pg_temp.cs24());

select ok(
  (select id from ev where label = 'mon_gt1_late') is not null,
  'a back-to-back booking in the same room is allowed (ranges are half-open)'
);


-- ---------------------------------------------------------------------------
-- Rule 2: one cohort cannot be in two places at once
-- ---------------------------------------------------------------------------
-- Different room, so rule 1 is satisfied — this must still fail, on the cohort.
select pg_temp.act_as(pg_temp.cs23());
select throws_ok(
  format($$ select create_event(%L::jsonb, %L::uuid, 'X', null,
                                %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid) $$,
         pg_temp.att('EB1', 2023,'SESA'), pg_temp.venue('S','GT2'),
         pg_temp.slot(1, 9), pg_temp.slot(1, 12), pg_temp.cs23()),
  '23P01',
  null,
  'a cohort cannot be double-booked into overlapping lectures, even in a free room'
);


-- ---------------------------------------------------------------------------
-- A pending proposal reserves its slot
-- ---------------------------------------------------------------------------
-- Both constraints cover 'proposed' as well as 'scheduled' (0010 §3/§4). Without
-- that, two unrelated proposals could each sail through and only collide when
-- somebody tried to confirm the second one.
insert into ev select 'tue_proposal', create_event(
  pg_temp.att('EB1', 2023,'DBMS') || pg_temp.att('EB3', 2023,'CSND'),
  pg_temp.venue('BSL','101'), 'Fredrick O. Ogolla', null,
  pg_temp.slot(2, 7), pg_temp.slot(2, 10), 'none', null, pg_temp.cs23());

select is(
  (select status::text from events where id = (select id from ev where label = 'tue_proposal')),
  'proposed',
  'a multi-cohort lecture starts life as proposed, not scheduled'
);

select pg_temp.act_as(pg_temp.cs24());
select throws_ok(
  format($$ select create_event(%L::jsonb, %L::uuid, 'X', null,
                                %L::timestamptz, %L::timestamptz, 'none', null, %L::uuid) $$,
         pg_temp.att('EB1', 2024,'DBMS'), pg_temp.venue('BSL','101'),
         pg_temp.slot(2, 8), pg_temp.slot(2, 11), pg_temp.cs24()),
  '23P01',
  null,
  'an unconfirmed proposal still holds its room against other bookings'
);


-- ---------------------------------------------------------------------------
-- Cancelling releases the slot
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.cs24());

insert into ev select 'wed_doomed', create_event(
  pg_temp.att('EB1', 2024,'CNDS'), pg_temp.venue('MS','05'),
  'Peter Kiplang''at Koech', null,
  pg_temp.slot(3, 7), pg_temp.slot(3, 10), 'none', null, pg_temp.cs24());

select lives_ok(
  format($$ select cancel_event(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'wed_doomed'), pg_temp.cs24()),
  'the initiating cohort''s rep can cancel a scheduled lecture'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'wed_doomed')),
  'canceled',
  'the cancelled event is marked canceled, not deleted (history is kept)'
);

-- Same room, same time, now free.
insert into ev select 'wed_replacement', create_event(
  pg_temp.att('EB1', 2024,'CNDS'), pg_temp.venue('MS','05'),
  'Peter Kiplang''at Koech', null,
  pg_temp.slot(3, 7), pg_temp.slot(3, 10), 'none', null, pg_temp.cs24());

select ok(
  (select id from ev where label = 'wed_replacement') is not null,
  'a cancelled event stops blocking its room and time'
);


-- ---------------------------------------------------------------------------
-- Rescheduling into an overlapping window — the 0013 regression
-- ---------------------------------------------------------------------------
-- Same room, shifted one hour, is the single commonest reschedule there is, and
-- it failed before 0013: the replacement row was inserted while the original was
-- still 'scheduled', so both EXCLUDE constraints counted the event twice and it
-- collided with the very occurrence it was replacing.
select pg_temp.act_as(pg_temp.cs23());

insert into ev select 'thu_original', create_event(
  pg_temp.att('EB1', 2023,'SESA'), pg_temp.venue('S','GT3'),
  'Harun Njenga Ngugi', null,
  pg_temp.slot(4, 7), pg_temp.slot(4, 10), 'none', null, pg_temp.cs23());

insert into ev select 'thu_moved', reschedule_event(
  (select id from ev where label = 'thu_original'),
  pg_temp.slot(4, 8), pg_temp.slot(4, 11), pg_temp.venue('S','GT3'), pg_temp.cs23());

select ok(
  (select id from ev where label = 'thu_moved') is not null,
  'an occurrence can be moved one hour later in the SAME room (0013 regression)'
);

select is(
  (select o.status::text || '/' || (o.superseded_by = n.id)::text
   from events o join events n on n.id = (select id from ev where label = 'thu_moved')
   where o.id = (select id from ev where label = 'thu_original')),
  'rescheduled/true',
  'the retired occurrence is marked rescheduled and points at its replacement'
);

select is(
  (select status::text || '/' || start_time::text
   from events where id = (select id from ev where label = 'thu_moved')),
  'scheduled/' || pg_temp.slot(4, 8)::text,
  'the replacement occurrence is scheduled at the new time'
);


-- ---------------------------------------------------------------------------
-- leave_event_cohort releases only that cohort's slot
-- ---------------------------------------------------------------------------
-- This is what the `confirmation_status <> 'left'` predicate on the self-overlap
-- constraint exists for: the lecture stays booked for everyone else, but the
-- departing cohort's calendar frees up.
select pg_temp.act_as(pg_temp.cs23());

insert into ev select 'fri_combined', create_event(
  pg_temp.att('EB1', 2023,'DBMS') || pg_temp.att('EB3', 2023,'CSND'),
  pg_temp.venue('BSL','102'), 'Fredrick O. Ogolla', null,
  pg_temp.slot(5, 7), pg_temp.slot(5, 10), 'none', null, pg_temp.cs23());

select pg_temp.act_as(pg_temp.acs23());
select lives_ok(
  format($$ select confirm_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'fri_combined'), pg_temp.acs23()),
  'the last outstanding cohort can confirm a proposal'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'fri_combined')),
  'scheduled',
  'the event flips to scheduled the moment every cohort has confirmed'
);

select lives_ok(
  format($$ select leave_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'fri_combined'), pg_temp.acs23()),
  'a non-initiating rep can opt their cohort out after scheduling'
);

select is(
  (select confirmation_status::text from event_cohorts
   where event_id = (select id from ev where label = 'fri_combined')
     and cohort_id = pg_temp.cohort('EB3', 2023)),
  'left',
  'the departing cohort is marked left, distinct from declined'
);

-- The slot is free for that cohort again, while the lecture itself still stands.
insert into ev select 'fri_acs_rebook', create_event(
  pg_temp.att('EB3', 2023,'AIML'), pg_temp.venue('BSL','103'),
  'Peter Kiplang''at Koech', null,
  pg_temp.slot(5, 7), pg_temp.slot(5, 10), 'none', null, pg_temp.acs23());

select is(
  (select status::text from events where id = (select id from ev where label = 'fri_combined'))
    || '/' || ((select id from ev where label = 'fri_acs_rebook') is not null)::text,
  'scheduled/true',
  'leaving frees that cohort''s slot without disturbing the remaining cohorts'
);


-- ---------------------------------------------------------------------------
-- Online venues are per-event and must never collide
-- ---------------------------------------------------------------------------
-- One venues row per meeting link (0001), so two online lectures never share a
-- venue_id and can never falsely trip the venue constraint.
select pg_temp.act_as(pg_temp.cs23());

with a as (
  insert into venues (type, meeting_link, platform, label)
  values ('online', 'https://meet.google.com/test-a', 'google_meet', 'test A') returning id
)
insert into ev select 'online_a', create_event(
  pg_temp.att('EB1', 2023,'DBMS'), (select id from a),
  'Fredrick O. Ogolla', null,
  pg_temp.slot(6, 7), pg_temp.slot(6, 10), 'none', null, pg_temp.cs23());

select pg_temp.act_as(pg_temp.cs24());
with b as (
  insert into venues (type, meeting_link, platform, label)
  values ('online', 'https://connect.kenet.or.ke/test-b', 'kenet', 'test B') returning id
)
insert into ev select 'online_b', create_event(
  pg_temp.att('EB1', 2024,'DBMS'), (select id from b),
  'Fredrick O. Ogolla', null,
  pg_temp.slot(6, 7), pg_temp.slot(6, 10), 'none', null, pg_temp.cs24());

select is(
  (select count(*)::int from ev where label in ('online_a', 'online_b')),
  2,
  'two online lectures at the same instant do not collide (one venue row per link)'
);


select * from finish();
rollback;
