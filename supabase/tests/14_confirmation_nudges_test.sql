-- ============================================================================
-- 14: Confirmation nudge job
-- ============================================================================
-- 0033 (TODO §3.2). send_confirmation_nudges() is called only by pg_cron, so
-- it's exercised directly here rather than through pg_temp.act_as() the way
-- client-facing RPCs are — there is no caller identity to spoof, the same
-- reason 0031's request_password_recovery is tested the same way.
--
-- Events are built through the real create_event() path (not hand-inserted)
-- so this also exercises event_cohorts wiring exactly as the app would
-- produce it. Start times are relative to now(), not the "two calendar years
-- out" convention other files use — the tiers this job checks are windows
-- before now(), so the fixtures have to actually sit inside them.
--
-- People used here (seed.sql §9): Mercy (...011, EB1/2023 primary rep),
-- Dennis (...021, EB1/2024 primary rep), Faith (...013, EB1/2023 plain
-- student — proves the nudge goes to the rep, not the whole cohort).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(22);


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
create function pg_temp.venue(p_n int default 0) returns uuid language sql stable as $$
  select id from venues order by id offset p_n limit 1;
$$;

create function pg_temp.cs23_rep() returns uuid language sql immutable as   -- Mercy, EB1/2023
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.cs24_rep() returns uuid language sql immutable as   -- Dennis, EB1/2024
  $$ select '22222222-0000-4000-8000-000000000021'::uuid $$;
create function pg_temp.faith()    returns uuid language sql immutable as   -- EB1/2023, plain student
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;

create function pg_temp.nudge_count(p_event uuid, p_user uuid) returns int
language sql stable as $$
  select count(*)::int from notifications
  where event_id = p_event and user_id = p_user and type = 'confirmation_needed';
$$;
create function pg_temp.tier_count(p_event uuid) returns int
language sql stable as $$
  select count(*)::int from confirmation_nudges_sent where event_id = p_event;
$$;
create function pg_temp.has_tier(p_event uuid, p_tier text) returns boolean
language sql stable as $$
  select exists(select 1 from confirmation_nudges_sent where event_id = p_event and tier = p_tier);
$$;

create temp table ev (label text primary key, id uuid);

-- seed_slot() anchors the whole seeded timetable to "Monday of next week" so
-- it can never land in the past on any day you reset — but "next Monday" can
-- be as little as ~24-48h out when db reset happens to run on a Saturday or
-- Sunday, which lands inside THIS file's own near-term fixture windows
-- (23h/24h, 11h/12h, 45min/90min, 20h/21h) for the same cohort. When that
-- happens, create_event below trips event_cohorts_no_self_overlap against a
-- real seed lecture instead of testing anything about the nudge job. Clear
-- it: nothing in this file needs the seed's own EB1/2023 or EB1/2024
-- lectures, and 31 days covers every fixture below, including the 30-day-out
-- 'far' case. Scoped to this test's own rolled-back transaction — seed.sql
-- and every other test file are unaffected.
update events set status = 'canceled', updated_at = now()
where status in ('scheduled', 'proposed')
  and start_time between now() and now() + interval '31 days'
  and id in (
    select event_id from event_cohorts
    where cohort_id in (pg_temp.cohort('EB1', 2023), pg_temp.cohort('EB1', 2024))
  );


-- ============================================================================
-- §1 One cohort, one tier crossed, idempotent re-run
-- ============================================================================
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'single', create_event(
  pg_temp.att('EB1', 2023, 'DSA'), pg_temp.venue(), 'Prof. Test One',
  'Single-cohort nudge test', now() + interval '23 hours', now() + interval '24 hours',
  'none', null, pg_temp.cs23_rep());

select send_confirmation_nudges();

select is(
  pg_temp.tier_count((select id from ev where label = 'single')), 1,
  'a lecture 23h out crosses exactly one tier (24h) on first run'
);
select ok(
  pg_temp.has_tier((select id from ev where label = 'single'), '24h'),
  '...and it is the 24h tier, not any other'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'single'), pg_temp.cs23_rep()), 1,
  'the attached cohort''s class_rep gets exactly one confirmation_needed notification'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'single'), pg_temp.faith()), 0,
  '...and a plain student in the same cohort gets none — this nudges the rep, not the cohort'
);
select matches(
  (select message from notifications
   where event_id = (select id from ev where label = 'single') and type = 'confirmation_needed'
     and user_id = pg_temp.cs23_rep()),
  'Prof\. Test One',
  'the nudge names the lecturer to call'
);

select send_confirmation_nudges();
select is(
  pg_temp.tier_count((select id from ev where label = 'single')), 1,
  're-running the job does not re-send an already-sent tier'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'single'), pg_temp.cs23_rep()), 1,
  '...so the rep still has exactly one notification, not two'
);


-- ============================================================================
-- §2 Escalation stops the moment a rep confirms
-- ============================================================================
select confirm_attendance((select id from ev where label = 'single'), pg_temp.cs23_rep());

-- Move it closer in — now inside the 12h tier's window too.
update events set start_time = now() + interval '11 hours', end_time = now() + interval '12 hours'
where id = (select id from ev where label = 'single');

select send_confirmation_nudges();

select is(
  pg_temp.tier_count((select id from ev where label = 'single')), 1,
  'a confirmed lecture never picks up a later tier, even after entering its window'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'single'), pg_temp.cs23_rep()), 1,
  '...the rep is not nagged again once they''ve made the call'
);


-- ============================================================================
-- §3 Combined lecture: both attached reps get it, a declined one does not
-- ============================================================================
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'combined', create_event(
  pg_temp.att('EB1', 2023, 'OOP') || pg_temp.att('EB1', 2024, 'OOP'),
  pg_temp.venue(), 'Prof. Test Two', 'Combined nudge test',
  now() + interval '23 hours', now() + interval '24 hours', 'none', null, pg_temp.cs23_rep());

-- Still 'proposed' until the non-initiating cohort confirms — same reason
-- confirm_attendance refuses a 'proposed' lecture (0022): it isn't real for
-- every cohort yet, so there is nothing to nudge anyone about.
select pg_temp.act_as(pg_temp.cs24_rep());
select confirm_event_cohort((select id from ev where label = 'combined'), pg_temp.cs24_rep());

select send_confirmation_nudges();

select is(
  pg_temp.nudge_count((select id from ev where label = 'combined'), pg_temp.cs23_rep()), 1,
  'the initiating cohort''s rep is nudged'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'combined'), pg_temp.cs24_rep()), 1,
  '...and so is the non-initiating attached cohort''s rep — any attached rep may confirm (0022), so both get asked'
);

select pg_temp.act_as(pg_temp.cs24_rep());
update event_cohorts set confirmation_status = 'declined', decided_by = pg_temp.cs24_rep(), decided_at = now()
where event_id = (select id from ev where label = 'combined') and cohort_id = pg_temp.cohort('EB1', 2024);

delete from confirmation_nudges_sent where event_id = (select id from ev where label = 'combined');
delete from notifications where event_id = (select id from ev where label = 'combined');

select send_confirmation_nudges();

select is(
  pg_temp.nudge_count((select id from ev where label = 'combined'), pg_temp.cs23_rep()), 1,
  'after declining, the still-attached cohort''s rep is still nudged'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'combined'), pg_temp.cs24_rep()), 0,
  '...but the cohort that declined this lecture is not — nothing to confirm for'
);


-- ============================================================================
-- §4 Escalating tiers: a lecture first seen very close in fires every tier
-- crossed so far in one run (the accepted burst case), and picks up the next
-- one once it's crossed too.
-- ============================================================================
select pg_temp.act_as(pg_temp.cs23_rep());
insert into ev select 'burst', create_event(
  pg_temp.att('EB1', 2023, 'OSSA'), pg_temp.venue(), 'Prof. Test Three',
  'Burst nudge test', now() + interval '45 minutes', now() + interval '90 minutes',
  'none', null, pg_temp.cs23_rep());

select send_confirmation_nudges();

select is(
  pg_temp.tier_count((select id from ev where label = 'burst')), 4,
  '45 minutes out crosses 24h/12h/5h/1h all at once on a never-before-seen event, but not 30m yet'
);
select ok(
  pg_temp.has_tier((select id from ev where label = 'burst'), '1h')
  and not pg_temp.has_tier((select id from ev where label = 'burst'), '30m'),
  '...specifically 1h fired and 30m did not — 45 minutes is inside the former, outside the latter'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'burst'), pg_temp.cs23_rep()), 4,
  'the rep gets one notification per tier that fired, not one for the whole burst'
);

update events set start_time = now() + interval '20 minutes', end_time = now() + interval '65 minutes'
where id = (select id from ev where label = 'burst');

select send_confirmation_nudges();

select is(
  pg_temp.tier_count((select id from ev where label = 'burst')), 5,
  'once inside 30 minutes, the last tier fires — and only the last one, not a re-send of the first four'
);
select is(
  pg_temp.nudge_count((select id from ev where label = 'burst'), pg_temp.cs23_rep()), 5,
  '...five tiers crossed so far, five notifications total'
);


-- ============================================================================
-- §5 Untouched by design: canceled events, and events outside every window
-- ============================================================================
select pg_temp.act_as(pg_temp.cs23_rep());
-- A time and venue neither 'single' (11h-12h) nor 'combined' (23h-24h) is
-- using — EB1/2023 is attached to both, and the self-overlap constraint
-- (0004) is cohort+time, not venue-scoped, so reusing either window here
-- would trip a real conflict rather than testing anything about nudges.
insert into ev select 'canceled', create_event(
  pg_temp.att('EB1', 2023, 'CNDS'), pg_temp.venue(1), 'Prof. Test Four',
  'Canceled nudge test', now() + interval '20 hours', now() + interval '21 hours',
  'none', null, pg_temp.cs23_rep());
select cancel_event((select id from ev where label = 'canceled'), pg_temp.cs23_rep());

insert into ev select 'far', create_event(
  pg_temp.att('EB1', 2023, 'DBMS'), pg_temp.venue(), 'Prof. Test Five',
  'Far-out nudge test', now() + interval '30 days', now() + interval '30 days 1 hour',
  'none', null, pg_temp.cs23_rep());

select send_confirmation_nudges();

select is(
  pg_temp.tier_count((select id from ev where label = 'canceled')), 0,
  'a canceled event never gets nudged, even sitting inside the 24h window'
);
select is(
  pg_temp.tier_count((select id from ev where label = 'far')), 0,
  'an event 30 days out has not crossed any tier yet'
);


-- ============================================================================
-- §6 Scheduling is registered
-- ============================================================================
select ok(
  exists(select 1 from cron.job where jobname = 'send-confirmation-nudges' and active),
  'the job is registered with pg_cron and active'
);
select is(
  (select schedule from cron.job where jobname = 'send-confirmation-nudges'),
  '*/15 * * * *',
  '...running every 15 minutes, tighter than the closest gap between tiers (1h -> 30m)'
);

select finish();
rollback;
