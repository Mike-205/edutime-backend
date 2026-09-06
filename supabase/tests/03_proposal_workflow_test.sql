-- ============================================================================
-- 03: Combined-lecture proposal workflow — the state machine
-- ============================================================================
-- The only transitions the design intends (§7 of TECHNICAL_DISCOVERY):
--
--   proposed  --(every attached cohort confirms)-->  scheduled
--   proposed  --(any cohort declines)-------------->  canceled   (for everyone)
--   proposed  --(initiator cancels)--------------->  canceled
--   scheduled --(initiator cancels)--------------->  canceled
--   scheduled --(initiator reschedules)---------->  rescheduled + new occurrence
--   scheduled --(non-initiator leaves)----------->  scheduled, that cohort 'left'
--
-- None of confirm/decline/cancel checked the current status before 0014, so
-- several transitions outside that set were reachable — including flipping a
-- canceled event back to scheduled. Each one is pinned below.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(20);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.slot(d int, h int) returns timestamptz language sql stable as $$
  select date_trunc('week', now() + interval '400 days') + make_interval(days => d - 1, hours => h);
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
-- One create_event attachment (0022 §1). Concatenate with || per attached cohort.
create function pg_temp.att(p_code text, p_intake_year int, p_abbr text) returns jsonb
language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'cohort_id', pg_temp.cohort(p_code, p_intake_year),
    'course_id', pg_temp.course(p_code, p_abbr)
  ));
$$;
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.cs23()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.cs24()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000021'::uuid $$;
create function pg_temp.acs23() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;

create temp table ev (label text primary key, id uuid);

-- Builds a three-cohort proposal in a given slot, initiated by the BSC-CS 2023
-- rep. Three cohorts is the interesting shape: it is the only one where a
-- decline and a still-pending confirmation can coexist.
--
-- The two BSC-CS cohorts share programme EB1 and attend as DBMS; BSC-ACS 2023 is
-- an EB3 cohort and attends as CSND. Before 0022 all three carried one course_id
-- and the ACS students saw a unit from a programme they are not enrolled in.
create function pg_temp.propose(p_label text, p_room text, p_day int) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  perform pg_temp.act_as(pg_temp.cs23());
  v_id := create_event(
    pg_temp.att('EB1', 2023,'DBMS')
      || pg_temp.att('EB1', 2024,'DBMS')
      || pg_temp.att('EB3', 2023,'CSND'),
    pg_temp.venue('BSR', p_room),
    'Fredrick O. Ogolla', null, pg_temp.slot(p_day, 7), pg_temp.slot(p_day, 10),
    'none', null, pg_temp.cs23());
  insert into ev values (p_label, v_id);
  return v_id;
end;
$$;


-- ---------------------------------------------------------------------------
-- Single cohort skips the proposal step entirely
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.cs23());
insert into ev select 'solo', create_event(
  pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('BSR','201'),
  'Fredrick O. Ogolla', null,
  pg_temp.slot(1, 13), pg_temp.slot(1, 16), 'none', null, pg_temp.cs23());

select is(
  (select status::text from events where id = (select id from ev where label = 'solo')),
  'scheduled',
  'a single-cohort lecture is scheduled immediately — nothing to confirm with yourself'
);

select is(
  (select confirmation_status::text || '/' || is_initiator::text from event_cohorts
   where event_id = (select id from ev where label = 'solo')),
  'confirmed/true',
  'the creating cohort is auto-confirmed and marked initiator'
);


-- ---------------------------------------------------------------------------
-- proposed -> scheduled only on the LAST confirmation
-- ---------------------------------------------------------------------------
select pg_temp.propose('happy', '202', 2);

select is(
  (select status::text from events where id = (select id from ev where label = 'happy')),
  'proposed',
  'a three-cohort lecture starts proposed'
);

select is(
  (select count(*)::int from event_cohorts
   where event_id = (select id from ev where label = 'happy')
     and confirmation_status = 'pending'),
  2,
  'the two non-initiating cohorts start pending'
);

-- First of two confirmations: still proposed.
select pg_temp.act_as(pg_temp.cs24());
select lives_ok(
  format($$ select confirm_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'happy'), pg_temp.cs24()),
  'a non-initiating rep can confirm'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'happy')),
  'proposed',
  'one confirmation short, the event is still only proposed'
);

-- Second confirmation completes it.
select pg_temp.act_as(pg_temp.acs23());
select lives_ok(
  format($$ select confirm_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'happy'), pg_temp.acs23()),
  'the final outstanding cohort can confirm'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'happy')),
  'scheduled',
  'the last confirmation flips the whole event to scheduled'
);

-- Confirming twice is not a silent no-op.
select throws_ok(
  format($$ select confirm_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'happy'), pg_temp.acs23()),
  'P0001',
  null,
  'a cohort cannot confirm the same event twice'
);


-- ---------------------------------------------------------------------------
-- Any decline cancels the whole event
-- ---------------------------------------------------------------------------
select pg_temp.propose('declined', '203', 3);

select pg_temp.act_as(pg_temp.acs23());
select lives_ok(
  format($$ select decline_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'declined'), pg_temp.acs23()),
  'an attached rep can decline a proposal'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'declined')),
  'canceled',
  'one decline cancels the event for every cohort — no partial continuation'
);


-- ---------------------------------------------------------------------------
-- REGRESSION: a confirmation must not resurrect a canceled event (0014 §3)
-- ---------------------------------------------------------------------------
-- BSC-CS 2024 was still 'pending' on the event ACS23 just declined. Before 0014,
-- confirm_event_cohort found remaining_pending = 0 and ran
-- `update events set status = 'scheduled'` — bringing a canceled event back to
-- life, and the sync trigger then stamped 'scheduled' onto every attachment row
-- including the declined one.
select pg_temp.act_as(pg_temp.cs24());
select throws_ok(
  format($$ select confirm_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'declined'), pg_temp.cs24()),
  'P0001',
  null,
  'confirming after somebody declined cannot resurrect the canceled event'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'declined')),
  'canceled',
  'the declined event stays canceled'
);


-- ---------------------------------------------------------------------------
-- REGRESSION: decline must not work on an already-scheduled event (0014 §3)
-- ---------------------------------------------------------------------------
-- 'happy' is fully scheduled. Before 0014, decline_event_cohort had no status
-- guard and no 'pending' filter on the attachment row, so any attached rep could
-- cancel a confirmed lecture for everyone — bypassing both leave_event_cohort
-- and the initiator-only rule on cancel_event.
select pg_temp.act_as(pg_temp.acs23());
select throws_ok(
  format($$ select decline_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'happy'), pg_temp.acs23()),
  'P0001',
  null,
  'a scheduled lecture cannot be destroyed via decline_event_cohort'
);

select is(
  (select status::text from events where id = (select id from ev where label = 'happy')),
  'scheduled',
  'the scheduled lecture survives the attempted decline'
);


-- ---------------------------------------------------------------------------
-- Cancel is initiator-only; leave is non-initiator-only
-- ---------------------------------------------------------------------------
-- Exactly one owner at all times: a non-initiator wanting out uses leave, and
-- the initiator cannot leave its own event.
select pg_temp.act_as(pg_temp.acs23());
select throws_ok(
  format($$ select cancel_event(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'happy'), pg_temp.acs23()),
  'P0001',
  'Only the initiating cohort''s class_rep may cancel this event',
  'a non-initiating rep cannot cancel the whole event'
);

select pg_temp.act_as(pg_temp.cs23());
select throws_ok(
  format($$ select leave_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'happy'), pg_temp.cs23()),
  'P0001',
  'The initiating cohort cannot leave its own event — use cancel_event instead',
  'the initiating rep cannot leave its own event'
);

-- And leaving is only for events that got as far as scheduled.
select pg_temp.propose('unconfirmed', '204', 4);
select pg_temp.act_as(pg_temp.acs23());
select throws_ok(
  format($$ select leave_event_cohort(%L::uuid, %L::uuid) $$,
         (select id from ev where label = 'unconfirmed'), pg_temp.acs23()),
  'P0001',
  null,
  'leave_event_cohort is refused while the event is still only proposed'
);


-- ---------------------------------------------------------------------------
-- Rescheduling a combined lecture re-opens confirmation
-- ---------------------------------------------------------------------------
-- A new time may not suit everyone who agreed to the old one, so every
-- non-initiating cohort goes back to pending.
select pg_temp.act_as(pg_temp.cs23());
insert into ev select 'moved', reschedule_event(
  (select id from ev where label = 'happy'),
  pg_temp.slot(2, 13), pg_temp.slot(2, 16), pg_temp.venue('BSR','202'), pg_temp.cs23());

select is(
  (select status::text from events where id = (select id from ev where label = 'moved')),
  'proposed',
  'the replacement occurrence of a combined lecture is proposed again'
);

select is(
  (select count(*)::int from event_cohorts
   where event_id = (select id from ev where label = 'moved')
     and confirmation_status = 'pending'),
  2,
  'both non-initiating cohorts must reconfirm the new time'
);


select * from finish();
rollback;
