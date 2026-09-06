-- ============================================================================
-- 04: Realtime broadcasts and notification fan-out
-- ============================================================================
-- These are the regression tests for two bugs that sat dormant through four
-- migrations, both invisible because nothing had ever successfully created an
-- event to fire the triggers:
--
--   * every realtime.broadcast_changes call passed jsonb where the signature
--     wanted `record`, so no broadcast ever resolved (42883);
--   * the events AFTER INSERT trigger looped over event_cohorts to find whom to
--     notify, but create_event inserts the event BEFORE its attachments, so the
--     loop found nothing. Creating a lecture broadcast to nobody — the single
--     most important realtime path in the product.
--
-- Everything is filtered by payload->>'id' so the assertions count only the
-- messages this transaction produced, not the seed's.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.slot(d int, h int) returns timestamptz language sql stable as $$
  select date_trunc('week', now() + interval '500 days') + make_interval(days => d - 1, hours => h);
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
-- One create_event attachment (0022 §1). Concatenate with || to attach a second
-- cohort, which is what makes a combined lecture a proposal.
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
create function pg_temp.acs23() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;

-- Messages carrying a given event id, by action.
create function pg_temp.msgs(p_event uuid, p_action text) returns int
language sql stable as $$
  select count(*)::int from realtime.messages
  where payload->>'id' = p_event::text and event = p_action;
$$;

create temp table ev (label text primary key, id uuid);


-- ---------------------------------------------------------------------------
-- Creating a plain lecture must broadcast 'created' to its cohort
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.cs23());
insert into ev select 'solo', create_event(
  pg_temp.att('EB1', 2023,'DBMS'), pg_temp.venue('BSR','301'),
  'Fredrick O. Ogolla', null,
  pg_temp.slot(1, 7), pg_temp.slot(1, 10), 'none', null, pg_temp.cs23());

select is(
  pg_temp.msgs((select id from ev where label = 'solo'), 'created'),
  1,
  'creating a lecture broadcasts exactly one "created" message'
);

select is(
  (select topic from realtime.messages
   where payload->>'id' = (select id from ev where label = 'solo')::text),
  'cohort:' || pg_temp.cohort('EB1', 2023)::text || ':events',
  'the message goes to that cohort''s channel, one channel per cohort'
);

-- §9: "the payload is {id, action} only — never the full row", so a client is
-- forced into a fresh RLS-checked SELECT and can never patch stale state into a
-- conflict-prevention UI.
select is(
  (select array_agg(k order by k) from realtime.messages,
     lateral jsonb_object_keys(payload) k
   where payload->>'id' = (select id from ev where label = 'solo')::text),
  array['action', 'id'],
  'the payload carries id and action only, never the row'
);

select is(
  (select private from realtime.messages
   where payload->>'id' = (select id from ev where label = 'solo')::text),
  true,
  'broadcasts are private, so subscribing is authorized against RLS'
);


-- ---------------------------------------------------------------------------
-- Notifications for a plain lecture reach every member of the cohort
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from notifications
   where event_id = (select id from ev where label = 'solo')),
  (select count(*)::int from users where cohort_id = pg_temp.cohort('EB1', 2023)),
  'a new lecture notifies every member of the cohort, students included'
);


-- ---------------------------------------------------------------------------
-- A proposal splits: 'created' for the initiator, a confirmation ask for others
-- ---------------------------------------------------------------------------
-- The two cohorts are in different programmes, so each attaches with a unit of
-- its own — since 0022 that is the only legal way to combine across programmes.
insert into ev select 'proposal', create_event(
  pg_temp.att('EB1', 2023,'DBMS') || pg_temp.att('EB3', 2023,'CSND'),
  pg_temp.venue('BSR','302'), 'Fredrick O. Ogolla', null,
  pg_temp.slot(2, 7), pg_temp.slot(2, 10), 'none', null, pg_temp.cs23());

select is(
  pg_temp.msgs((select id from ev where label = 'proposal'), 'created'),
  1,
  'the initiating cohort is told the lecture exists'
);

select is(
  pg_temp.msgs((select id from ev where label = 'proposal'), 'cohort_confirmation_needed'),
  1,
  'the non-initiating cohort is asked to confirm rather than told it is booked'
);

-- Students of the other cohort must NOT be notified yet: until every rep
-- confirms, the lecture is not real for them.
select is(
  (select count(*)::int from notifications n
   join users u on u.id = n.user_id
   where n.event_id = (select id from ev where label = 'proposal')
     and u.cohort_id = pg_temp.cohort('EB3', 2023)
     and u.role <> 'class_rep'),
  0,
  'a pending proposal does not notify the other cohort''s students'
);

select is(
  (select count(*)::int from notifications n
   join users u on u.id = n.user_id
   where n.event_id = (select id from ev where label = 'proposal')
     and u.cohort_id = pg_temp.cohort('EB3', 2023)
     and u.role = 'class_rep'),
  (select count(*)::int from users
   where cohort_id = pg_temp.cohort('EB3', 2023) and role = 'class_rep'),
  'every class rep of the attached cohort is asked, primary and assistant alike'
);


-- ---------------------------------------------------------------------------
-- Confirming broadcasts to every attached cohort
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.acs23());
select confirm_event_cohort((select id from ev where label = 'proposal'), pg_temp.acs23());

select is(
  pg_temp.msgs((select id from ev where label = 'proposal'), 'confirmed'),
  2,
  'confirmation fans out to both attached cohorts'
);

select is(
  (select count(distinct topic)::int from realtime.messages
   where payload->>'id' = (select id from ev where label = 'proposal')::text
     and event = 'confirmed'),
  2,
  'each cohort hears about it on its own channel'
);


-- ---------------------------------------------------------------------------
-- Cancelling broadcasts and notifies everyone, because it was real
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.cs23());
select cancel_event((select id from ev where label = 'proposal'), pg_temp.cs23());

select is(
  pg_temp.msgs((select id from ev where label = 'proposal'), 'canceled'),
  2,
  'cancellation reaches every attached cohort''s channel'
);


select * from finish();
rollback;
