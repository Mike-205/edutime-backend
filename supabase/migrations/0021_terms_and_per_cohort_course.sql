-- ============================================================================
-- 0021: Academic terms, and the course moves to the attachment
-- ============================================================================
-- Phase 1 part 2 of 3. Structure only — no function bodies change here, so the
-- schema is never left in a state where an existing function is broken. 0022
-- rewrites the API on top of this and drops the column this migration
-- deprecates.
--
-- Contents
--   §1  term_bounds()            — the academic calendar, derived not stored
--   §2  event_cohorts.course_id  — per-cohort course (TODO §1.7), nullable for now
--   §3  events.course_id         — deprecated, made nullable, dropped in 0022
--
-- Both column changes are half-steps on purpose. 0015's create_event is the live
-- definition until 0022 replaces it: it writes events.course_id and knows nothing
-- of event_cohorts.course_id. So this migration widens what is permitted and
-- tightens nothing, and 0022 closes both ends once the writer understands them.
-- ============================================================================


-- ============================================================================
-- 1. term_bounds
-- ============================================================================
-- The calendar year is split at fixed boundaries:
--
--   Jan 1 - Apr 30 | May 1 - Aug 31 | Sep 1 - Dec 31
--
-- ...but a cohort does not necessarily teach in all three. THIS IS WHAT
-- cohort_pace IS FOR, and getting it wrong would be silent:
--
--   trimester — all three. Jan-Apr, May-Aug, Sep-Dec.
--   bimester  — TWO only. Jan-Apr and Sep-Dec. May-Aug is the long break,
--               not a short term.
--
-- So a bimester cohort asked for the term containing 12 June is not in a term
-- at all, and term_bounds returns (null, null) rather than inventing a
-- May-Aug window. Callers must treat a null window as "no ceiling available",
-- which 0022 turns into a refusal to materialize a recurring series — a
-- bimester cohort has no recurring lectures in June, so a series starting there
-- is a mistake worth catching rather than a horizon to guess at.
--
-- Note this only ever gates RECURRENCE. A one-off lecture in the break is
-- perfectly legitimate — make-up classes, supplementary sessions — and 0022
-- does not consult this function for those.
--
-- Deliberately DERIVED from a date rather than stored on `cohorts`. TODO §0.1
-- originally planned semester_start_date / semester_end_date columns, and
-- deriving is strictly better: nothing to backfill, no cohort can sit with a
-- null window blocking recurrence, and no stored date can go stale when a
-- cohort rolls into its next semester. The calendar is a property of the
-- calendar, not of a cohort.
--
-- WHAT THIS IS FOR, and what it is NOT. Teaching does not fill a term — a
-- series might really stop on Apr 10 while the term runs to Apr 30. So this is
-- the CEILING on how far a recurring series may be materialized, not a
-- prediction of when lectures stop. The rep supplies the real last teaching
-- date via create_event's p_until (0022), and the ceiling only stops someone
-- generating three years of occurrences.
--
create type term_window as (
  term_start date,
  term_end   date
);

create or replace function term_bounds(p_date date, p_pace cohort_pace)
returns term_window
language plpgsql
immutable
as $$
declare
  v_year  int := extract(year  from p_date)::int;
  v_month int := extract(month from p_date)::int;
begin
  if v_month between 1 and 4 then
    return row(make_date(v_year, 1, 1), make_date(v_year, 4, 30))::term_window;
  elsif v_month between 9 and 12 then
    return row(make_date(v_year, 9, 1), make_date(v_year, 12, 31))::term_window;
  elsif p_pace = 'trimester' then
    return row(make_date(v_year, 5, 1), make_date(v_year, 8, 31))::term_window;
  else
    -- Bimester. May-Aug is the long break; there is no term to bound against.
    return row(null::date, null::date)::term_window;
  end if;
end;
$$;

comment on function term_bounds(date, cohort_pace) is
  'The academic term containing a date, for a cohort running at a given pace. '
  'Returns (null, null) for a bimester cohort in the May-Aug break — it has no '
  'term then. Used as the hard ceiling on recurrence materialization, NOT as a '
  'prediction of when teaching actually stops.';

revoke execute on function term_bounds(date, cohort_pace) from public, anon;
grant  execute on function term_bounds(date, cohort_pace) to authenticated, service_role;


-- ============================================================================
-- 2. The course moves onto event_cohorts
-- ============================================================================
-- TODO §1.7. `events.course_id` is a single FK into programme-scoped `courses`,
-- so a combined lecture spanning two programmes has no course row valid for
-- both — one cohort's students see a unit belonging to a programme they are not
-- enrolled in. The seed already demonstrates it: the cross-programme proposal
-- borrows EB3's AI/ML unit for a BSC-CS cohort.
--
-- This was tolerable while combined lectures were assumed to be same-programme.
-- They are not: cross-faculty combined lectures are explicitly in scope, so the
-- single FK is simply the wrong shape. Each attached cohort now carries the
-- unit from its OWN programme — same lecture, same room, same lecturer, correct
-- unit name on every student's calendar.
alter table event_cohorts
  add column course_id uuid references courses (id) on delete restrict;

-- Backfill from the event's current course before making it required. Every
-- existing attachment inherits what it was already showing, so this is
-- behaviour-preserving.
update event_cohorts ec
set course_id = e.course_id
from events e
where e.id = ec.event_id
  and ec.course_id is null;

-- NOT NULL is deliberately deferred to 0022, for the same reason §3 below defers
-- the drop: create_event as defined in 0015 is still the live definition until
-- 0022 replaces it, and it knows nothing about this column. Requiring it here
-- applies cleanly to the empty table at migration time and then fails the first
-- time anything actually creates an event — which is exactly what the seed does.
-- Structure cannot outrun the function that maintains it in either direction.

create index event_cohorts_course_idx on event_cohorts (course_id);

comment on column event_cohorts.course_id is
  'The unit THIS cohort is attending the lecture as. Per-attachment because a '
  'combined lecture may span programmes, and courses are programme-scoped.';


-- ============================================================================
-- 3. events.course_id is now redundant
-- ============================================================================
-- Made nullable here, dropped in 0022. Two steps on purpose: the create_event
-- and reschedule_event bodies defined in 0015 still write to this column, and
-- they stay live until 0022 replaces them. Dropping it now would leave the
-- schema in a state where the only way to create an event raises at runtime.
-- Nullable satisfies both the old writers and the new ones.
alter table events
  alter column course_id drop not null;

comment on column events.course_id is
  'DEPRECATED — superseded by event_cohorts.course_id in 0021, dropped in 0022. '
  'Do not read or write this column.';
