-- ============================================================================
-- 0030: Recurring combined lectures
-- ============================================================================
-- TODO §S.4, the last item in Phase S. Picks up `0.1`'s sub-decision 5, which
-- DEFERRED this rather than rejecting it.
--
-- `0.1` refused recurrence for combined lectures because a recurring
-- cross-cohort series would need every attached cohort's rep to reconfirm every
-- single occurrence — fifteen proposals landing on a partner rep for one
-- scheduling decision. That was a fair call at the time. What changed is that
-- `0022` built `cancel_recurrence_group`, i.e. the "act on a whole series at
-- once" shape, so the churn now has an obvious answer: confirm the
-- recurrence_group ONCE.
--
-- And it matters, because term-long combined teaching is ordinary at Chuka: a
-- lecturer takes Applied CS together with Computer Science for a whole
-- semester, and again in another unit. Until now a rep had to hand-create
-- fifteen occurrences for that.
--
-- Contents
--   §1  create_event               — the guard lifts; clashes report in full
--   §2  confirm_recurrence_group   — one decision, not fifteen
--   §3  decline_recurrence_group   — the other half
--   §4  Grants
--
-- NOTE ON SCOPE: a ONE-OFF combined lecture has worked since 0010 and is
-- untouched here. This migration is only about letting one repeat.
-- ============================================================================


-- ============================================================================
-- 1. create_event
-- ============================================================================
-- Three changes; everything else preserved from 0022 §1.
--
-- (a) THE GUARD LIFTS. `if array_length(v_cohort_ids,1) > 1 then raise` is gone.
--
-- (b) THE HORIZON NOW CONSIDERS EVERY ATTACHED COHORT, not just the initiator's.
--     The old guard made "whose pace?" moot by allowing only one cohort. With
--     several, using the initiator's term alone would let a trimester initiator
--     materialize a series straight through a bimester partner's May–Aug break —
--     booking a cohort into weeks it does not teach. So: refuse if ANY attached
--     cohort has no teaching term containing p_start, and take the EARLIEST term
--     end among them as the ceiling. The most restrictive calendar wins, which
--     is the only reading that cannot put a lecture on a cohort's holiday.
--
-- (c) A CLASH NOW REPORTS EVERY OFFENDING DATE, not just the first. All-or-
--     nothing is unchanged — that is `0.1` decision 3 and it stays the same rule
--     for solo and combined series alike — but a term-long combined series has
--     to clear TWO calendars across fifteen weeks, so "the first date that
--     failed" would mean fifteen round trips to discover three conflicts. The
--     occurrences are now pre-checked as a set before anything is inserted, and
--     every conflict is named in one error.
--
--     Skip-and-report was considered and rejected again: it needs a savepoint
--     per occurrence (the cost `0.1` priced and declined), it silently hands
--     back a series full of holes, and it would make combined series behave
--     differently from solo ones.
--
--     The per-insert `exception when exclusion_violation` block is KEPT as a
--     backstop. The pre-check is a read, so a concurrent booking could still
--     land between checking and inserting; the constraints remain the actual
--     guarantee and the catch turns a raw 23P01 into a sentence.
--
-- `set search_path = public` restated — CREATE OR REPLACE discards proconfig.
create or replace function create_event(
  p_attachments   jsonb,          -- [{"cohort_id": "...", "course_id": "..."}, ...]
  p_venue_id      uuid,
  p_lecturer_name text,
  p_title         text,
  p_start         timestamptz,
  p_end           timestamptz,
  p_recurrence    recurrence_type,
  p_until         date,
  p_acting_user   uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_cohort_id uuid;
  v_caller_role      user_role;
  v_cohort_ids       uuid[];
  v_course_ids       uuid[];
  v_distinct_cohorts int;
  v_missing          uuid;
  v_bad_cohort       uuid;
  v_bad_course       uuid;
  v_title            text;
  v_lecturer         text;
  v_recurrence       recurrence_type := coalesce(p_recurrence, 'none');
  v_initial_status   event_status;
  v_no_term_cohort   uuid;
  v_no_term_pace     cohort_pace;
  v_term_end         date;
  v_horizon          date;
  v_step             interval;
  v_duration         interval;
  v_group_id         uuid;
  v_starts           timestamptz[] := '{}';
  v_occ_start        timestamptz;
  v_n                int;
  v_i                int;
  v_event_id         uuid;
  v_first_event_id   uuid;
  v_constraint       text;
  v_cohort_id        uuid;
  v_clashes          int;
  v_clash_list       text;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_caller_role, v_caller_cohort_id
  from users where id = p_acting_user;

  if v_caller_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may schedule an event';
  end if;

  -- --- Attachments ---------------------------------------------------------
  if p_attachments is null or jsonb_typeof(p_attachments) is distinct from 'array' then
    raise exception
      'p_attachments must be a JSON array of {"cohort_id": ..., "course_id": ...} objects';
  end if;

  with raw as (
    select distinct
      (a ->> 'cohort_id')::uuid as cohort_id,
      (a ->> 'course_id')::uuid as course_id
    from jsonb_array_elements(p_attachments) a
  )
  select array_agg(cohort_id order by cohort_id),
         array_agg(course_id order by cohort_id)
  into v_cohort_ids, v_course_ids
  from raw;

  if v_cohort_ids is null or array_length(v_cohort_ids, 1) is null then
    raise exception 'p_attachments must contain at least one cohort';
  end if;

  if exists (select 1 from unnest(v_cohort_ids) c where c is null)
     or exists (select 1 from unnest(v_course_ids) c where c is null) then
    raise exception
      'Every attachment needs both a cohort_id and a course_id';
  end if;

  select count(distinct c)::int into v_distinct_cohorts from unnest(v_cohort_ids) c;

  if v_distinct_cohorts <> array_length(v_cohort_ids, 1) then
    raise exception
      'A cohort appears more than once in p_attachments with different courses — '
      'each cohort attends the lecture as exactly one unit';
  end if;

  if not (v_caller_cohort_id = any(v_cohort_ids)) then
    raise exception 'p_attachments must include the acting rep''s own cohort';
  end if;

  select c into v_missing
  from unnest(v_cohort_ids) c
  where not exists (select 1 from cohorts where id = c)
  limit 1;

  if v_missing is not null then
    raise exception 'Cohort % does not exist', v_missing;
  end if;

  select t.cohort_id, t.course_id
  into v_bad_cohort, v_bad_course
  from unnest(v_cohort_ids, v_course_ids) as t(cohort_id, course_id)
  join cohorts c on c.id = t.cohort_id
  left join courses crs on crs.id = t.course_id
  where crs.id is null
     or crs.programme_id is distinct from c.programme_id
  limit 1;

  if v_bad_cohort is not null then
    raise exception
      'Course % is not offered by cohort %''s programme', v_bad_course, v_bad_cohort;
  end if;

  -- --- Scalars -------------------------------------------------------------
  v_title := nullif(btrim(coalesce(p_title, '')), '');

  v_lecturer := nullif(btrim(coalesce(p_lecturer_name, '')), '');
  if v_lecturer is null then
    raise exception 'p_lecturer_name is required';
  end if;

  v_initial_status := case
    when array_length(v_cohort_ids, 1) > 1 then 'proposed'
    else 'scheduled'
  end;

  v_duration := p_end - p_start;

  -- --- Recurrence ----------------------------------------------------------
  if v_recurrence = 'none' then
    if p_until is not null then
      raise exception
        'p_until only applies to a recurring lecture — pass p_recurrence to create a series';
    end if;

    v_starts := array[p_start];
  else
    -- (b) EVERY attached cohort must have a teaching term containing p_start.
    -- A bimester cohort has none between May and August (0021 §1), and putting
    -- a partner's lectures in their holiday is exactly as wrong as putting the
    -- initiator's there.
    select c.id, c.pace into v_no_term_cohort, v_no_term_pace
    from unnest(v_cohort_ids) cid
    join cohorts c on c.id = cid
    where (term_bounds(p_start::date, c.pace)).term_end is null
    limit 1;

    if v_no_term_cohort is not null then
      raise exception
        'Cohort % has no teaching term containing % (a % cohort does not teach then), '
        'so a recurring series cannot be bounded. A one-off lecture is still allowed.',
        v_no_term_cohort, p_start::date, v_no_term_pace;
    end if;

    -- The EARLIEST term end among the attached cohorts. With one cohort this is
    -- identical to the old behaviour; with several, the most restrictive
    -- calendar governs.
    select min((term_bounds(p_start::date, c.pace)).term_end)
    into v_term_end
    from unnest(v_cohort_ids) cid
    join cohorts c on c.id = cid;

    v_horizon := least(coalesce(p_until, v_term_end), v_term_end);

    if p_start::date > v_horizon then
      raise exception
        'A series cannot start after its horizon (starts %, horizon %)',
        p_start::date, v_horizon;
    end if;

    v_step := case v_recurrence
      when 'day'   then interval '1 day'
      when 'week'  then interval '1 week'
      when 'month' then interval '1 month'
    end;

    v_n := 0;
    loop
      v_occ_start := p_start + (v_n * v_step);
      exit when v_occ_start::date > v_horizon;

      v_starts := v_starts || v_occ_start;
      v_n := v_n + 1;

      if v_n > 200 then
        raise exception 'A recurring series may not exceed 200 occurrences';
      end if;
    end loop;

    v_group_id := gen_random_uuid();
  end if;

  -- --- (c) Pre-check: name EVERY clash, not just the first ------------------
  -- A read, so it cannot be the guarantee — the EXCLUDE constraints still are,
  -- and the catch block below still fires on a race. What this buys is that a
  -- rep planning a fifteen-week combined series learns about all three bad
  -- weeks at once instead of one per attempt.
  select count(*)::int,
         string_agg(format('  %s  %s', d.occ::date, d.reason), E'\n' order by d.occ)
  into v_clashes, v_clash_list
  from (
    select s.occ,
           case when exists (
                  select 1 from events e
                  where e.venue_id = p_venue_id
                    and e.status in ('proposed', 'scheduled')
                    and tstzrange(e.start_time, e.end_time)
                        && tstzrange(s.occ, s.occ + v_duration)
                ) then 'that venue is already booked'
                else 'an attached cohort already has a lecture'
           end as reason
    from unnest(v_starts) as s(occ)
    where exists (
            select 1 from events e
            where e.venue_id = p_venue_id
              and e.status in ('proposed', 'scheduled')
              and tstzrange(e.start_time, e.end_time)
                  && tstzrange(s.occ, s.occ + v_duration)
          )
       or exists (
            select 1 from event_cohorts ec
            where ec.cohort_id = any(v_cohort_ids)
              and ec.event_status_cache in ('proposed', 'scheduled')
              and ec.confirmation_status <> 'left'
              and tstzrange(ec.start_time, ec.end_time)
                  && tstzrange(s.occ, s.occ + v_duration)
          )
  ) d;

  if v_clashes > 0 then
    raise exception
      E'Cannot schedule this series — % of % occurrence(s) clash:\n%\nNo occurrences were created.',
      v_clashes, array_length(v_starts, 1), v_clash_list
      using errcode = 'exclusion_violation';
  end if;

  -- --- Materialize ---------------------------------------------------------
  foreach v_occ_start in array v_starts loop
    begin
      insert into events (
        title, venue_id, lecturer_name, start_time, end_time,
        recurrence, recurrence_group_id, status, attendance_status,
        created_by, updated_by
      )
      values (
        v_title, p_venue_id, v_lecturer, v_occ_start, v_occ_start + v_duration,
        v_recurrence, v_group_id, v_initial_status, 'pending',
        p_acting_user, p_acting_user
      )
      returning id into v_event_id;

      for v_i in 1 .. array_length(v_cohort_ids, 1) loop
        insert into event_cohorts (
          event_id, cohort_id, course_id, is_initiator, confirmation_status,
          decided_by, decided_at, start_time, end_time, event_status_cache
        )
        values (
          v_event_id, v_cohort_ids[v_i], v_course_ids[v_i],
          (v_cohort_ids[v_i] = v_caller_cohort_id),
          -- The ::cohort_confirmation_status cast is REQUIRED — a CASE over
          -- quoted literals resolves to `text` and there is no implicit cast.
          -- Its absence is why create_event never once ran between 0010 and
          -- 0015 (TECHNICAL_DISCOVERY §3).
          (case when v_cohort_ids[v_i] = v_caller_cohort_id then 'confirmed' else 'pending' end
            )::cohort_confirmation_status,
          case when v_cohort_ids[v_i] = v_caller_cohort_id then p_acting_user else null end,
          case when v_cohort_ids[v_i] = v_caller_cohort_id then now() else null end,
          v_occ_start, v_occ_start + v_duration, v_initial_status
        );
      end loop;

    exception when exclusion_violation then
      -- Backstop for a booking that landed between the pre-check and here.
      get stacked diagnostics v_constraint = CONSTRAINT_NAME;

      raise exception
        'Cannot schedule the occurrence on %: %. No occurrences were created.',
        v_occ_start::date,
        case v_constraint
          when 'events_no_venue_overlap'       then 'that venue was just booked by someone else'
          when 'event_cohorts_no_self_overlap' then 'an attached cohort was just given a lecture at that time'
          else 'it clashes with an existing booking'
        end
        using errcode = 'exclusion_violation';
    end;

    if v_first_event_id is null then
      v_first_event_id := v_event_id;
    end if;

    insert into event_audit_log (event_id, action, changed_by, snapshot)
    values (
      v_event_id, 'created', p_acting_user,
      jsonb_build_object(
        'cohort_ids', v_cohort_ids,
        'initial_status', v_initial_status,
        'recurrence_group_id', v_group_id
      )
    );
  end loop;

  -- --- Notify --------------------------------------------------------------
  -- ONE notification per cohort for the whole series. A fifteen-week series
  -- would otherwise write fifteen rows to every student for a single action.
  if v_initial_status = 'proposed' then
    foreach v_cohort_id in array v_cohort_ids loop
      if v_cohort_id != v_caller_cohort_id then
        perform notify_cohort_members(
          v_cohort_id, v_first_event_id, 'cohort_confirmation_needed',
          'Combined lecture needs your confirmation',
          case
            when array_length(v_starts, 1) > 1 then
              format('A class rep has proposed a recurring combined lecture with your '
                     'cohort (%s occurrences). Confirming accepts the whole series.',
                     array_length(v_starts, 1))
            else
              'A class rep from another cohort has proposed a combined lecture with yours.'
          end,
          'class_rep'
        );
      end if;
    end loop;
  else
    perform notify_cohort_members(
      v_caller_cohort_id, v_first_event_id, 'created',
      'New lecture scheduled',
      case
        when array_length(v_starts, 1) > 1 then
          format('%s lectures have been added to your schedule.', array_length(v_starts, 1))
        else
          'A new lecture has been added to your schedule.'
      end
    );
  end if;

  return v_first_event_id;
end;
$$;

comment on function create_event(jsonb, uuid, text, text, timestamptz, timestamptz, recurrence_type, date, uuid) is
  'Creates a lecture, or a whole recurring series, for one or more cohorts — '
  'including a RECURRING COMBINED series as of 0030. p_attachments is '
  '[{"cohort_id":...,"course_id":...}]. Recurrence is bounded by '
  'least(p_until, the EARLIEST term end among all attached cohorts). A clash '
  'aborts the whole series and names every offending date. Returns the first '
  'occurrence''s id.';


-- ============================================================================
-- 2. confirm_recurrence_group
-- ============================================================================
-- The reason §1's guard could be lifted at all. Without this, a fifteen-week
-- combined series would land fifteen separate proposals on the partner rep —
-- the churn `0.1` refused to design around.
--
-- One decision covers the series, mirroring cancel_recurrence_group (0022 §2),
-- which already proved the shape. Deliberately NOT per-occurrence: a rep either
-- accepts the arrangement or does not. A rep who accepts the series but cannot
-- host one particular week uses leave_event_cohort or decline on that single
-- occurrence afterwards — the exception stays an exception.
create function confirm_recurrence_group(
  p_group_id    uuid,
  p_acting_user uuid
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cohort_id uuid;
  v_role      user_role;
  v_count     int := 0;
  v_event_id  uuid;
  v_first     uuid;
  v_other     uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_role, v_cohort_id from users where id = p_acting_user;
  if v_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may confirm a combined lecture';
  end if;

  -- Locked in start order, both to serialize concurrent confirmations and so
  -- the flip to 'scheduled' below evaluates the EXCLUDE constraints in a
  -- deterministic order.
  for v_event_id in
    select e.id
    from events e
    join event_cohorts ec on ec.event_id = e.id
    where e.recurrence_group_id = p_group_id
      and e.status = 'proposed'
      and ec.cohort_id = v_cohort_id
      and ec.confirmation_status = 'pending'
    order by e.start_time
    for update of e
  loop
    update event_cohorts
    set confirmation_status = 'confirmed', decided_by = p_acting_user, decided_at = now()
    where event_id = v_event_id and cohort_id = v_cohort_id
      and confirmation_status = 'pending';

    -- The real conflict check: flipping to 'scheduled' is what makes both
    -- EXCLUDE constraints bite. A 23P01 here means someone took the slot while
    -- the proposal was outstanding, which is the intended safety net — and it
    -- aborts the whole confirmation, consistent with §1's all-or-nothing.
    if (select count(*) from event_cohorts
        where event_id = v_event_id and confirmation_status = 'pending') = 0 then
      update events set status = 'scheduled', updated_at = now() where id = v_event_id;
    end if;

    if v_first is null then
      v_first := v_event_id;
    end if;

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception
      'No pending confirmation for your cohort on series %', p_group_id;
  end if;

  -- One notification per cohort, not one per occurrence — same reasoning as
  -- create_event's.
  for v_other in
    select distinct ec.cohort_id
    from event_cohorts ec
    join events e on e.id = ec.event_id
    where e.recurrence_group_id = p_group_id
      and ec.confirmation_status = 'confirmed'
  loop
    perform notify_cohort_members(
      v_other, v_first, 'created',
      'Recurring combined lecture confirmed',
      format('A recurring combined lecture (%s occurrences) has been confirmed.', v_count)
    );
  end loop;

  return v_count;
end;
$$;

comment on function confirm_recurrence_group(uuid, uuid) is
  'Confirms an entire proposed recurring combined series in one action, for the '
  'calling rep''s cohort. The alternative — one confirmation per occurrence — is '
  'the churn that kept recurring combined lectures out of scope until 0030.';


-- ============================================================================
-- 3. decline_recurrence_group
-- ============================================================================
-- The other half, and it mirrors decline_event_cohort's rule that ANY decline
-- cancels the lecture for everyone: a decline here cancels the whole series.
-- There is no partial state to land in — the series was proposed as one thing.
--
-- Pre-confirmation only, like decline_event_cohort after 0015: once a series is
-- scheduled, a cohort that wants out uses leave_event_cohort, which releases
-- only their own slot.
create function decline_recurrence_group(
  p_group_id    uuid,
  p_acting_user uuid
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cohort_id uuid;
  v_role      user_role;
  v_count     int := 0;
  v_event_id  uuid;
  v_first     uuid;
  v_other     uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id into v_role, v_cohort_id from users where id = p_acting_user;
  if v_role is distinct from 'class_rep' then
    raise exception 'Only a class_rep may decline a combined lecture';
  end if;

  for v_event_id in
    select e.id
    from events e
    join event_cohorts ec on ec.event_id = e.id
    where e.recurrence_group_id = p_group_id
      and e.status = 'proposed'
      and ec.cohort_id = v_cohort_id
      and ec.confirmation_status = 'pending'
    order by e.start_time
    for update of e
  loop
    update event_cohorts
    set confirmation_status = 'declined', decided_by = p_acting_user, decided_at = now()
    where event_id = v_event_id and cohort_id = v_cohort_id
      and confirmation_status = 'pending';

    update events
    set status = 'canceled', updated_by = p_acting_user, updated_at = now()
    where id = v_event_id;

    insert into event_audit_log (event_id, action, changed_by, snapshot)
    values (
      v_event_id, 'canceled', p_acting_user,
      jsonb_build_object(
        'reason', 'recurrence_group_declined',
        'recurrence_group_id', p_group_id,
        'declined_by_cohort', v_cohort_id
      )
    );

    if v_first is null then
      v_first := v_event_id;
    end if;

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception
      'No pending confirmation for your cohort on series %', p_group_id;
  end if;

  for v_other in
    select distinct ec.cohort_id
    from event_cohorts ec
    join events e on e.id = ec.event_id
    where e.recurrence_group_id = p_group_id
      and ec.confirmation_status not in ('declined', 'left')
  loop
    perform notify_cohort_members(
      v_other, v_first, 'canceled',
      'Recurring combined lecture declined',
      format('A proposed recurring combined lecture (%s occurrences) was declined '
             'and will not go ahead.', v_count)
    );
  end loop;

  return v_count;
end;
$$;

comment on function decline_recurrence_group(uuid, uuid) is
  'Declines an entire proposed recurring combined series, cancelling every '
  'occurrence for every cohort — the series was proposed as one thing, so there '
  'is no partial state to land in. Pre-confirmation only.';


-- ============================================================================
-- 4. Grants
-- ============================================================================
-- REVOKE FROM PUBLIC FIRST — CREATE FUNCTION implicitly grants EXECUTE to
-- PUBLIC, so revoking from `anon` alone is a no-op (0014 §3).
--
-- create_event keeps its existing ACL: CREATE OR REPLACE preserves privileges,
-- and its signature is unchanged.
revoke execute on function confirm_recurrence_group(uuid, uuid) from public, anon;
grant  execute on function confirm_recurrence_group(uuid, uuid) to authenticated, service_role;

revoke execute on function decline_recurrence_group(uuid, uuid) from public, anon;
grant  execute on function decline_recurrence_group(uuid, uuid) to authenticated, service_role;
