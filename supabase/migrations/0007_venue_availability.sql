-- ============================================================================
-- 0007: Venue availability — deliberately cross-cohort
-- ============================================================================
-- Journey 3: ANY user, regardless of their own cohort, needs to see which
-- rooms are free right now or at a chosen time. This is fundamentally
-- cross-cohort data (a room's occupancy might come from a different
-- cohort's lecture), which the events RLS policy (cohort-scoped SELECT)
-- deliberately does NOT expose.
--
-- Rather than loosening events RLS, this view exposes ONLY what's needed to
-- answer "is this venue free" — venue_id and the time range — with no
-- lecturer name, course, cohort identity, or attendance status. It runs
-- with the view owner's privileges (bypassing the caller's RLS on events),
-- which is safe specifically because the exposed columns carry no
-- per-cohort private information.
create view venue_occupancy
with (security_invoker = false) as
select
  e.venue_id,
  e.start_time,
  e.end_time
from events e
where e.status = 'scheduled';

-- Grant read to all authenticated app roles; no RLS needed on the view
-- itself since it exposes nothing sensitive.
grant select on venue_occupancy to authenticated;

-- Convenience function: is a given venue free for a given time window?
create or replace function is_venue_available(
  p_venue_id uuid,
  p_start    timestamptz,
  p_end      timestamptz
)
returns boolean
language sql
stable
as $$
  select not exists (
    select 1 from venue_occupancy vo
    where vo.venue_id = p_venue_id
      and tstzrange(vo.start_time, vo.end_time) && tstzrange(p_start, p_end)
  );
$$;

-- "What's free right now" browser query, e.g.:
--   select v.*, is_venue_available(v.id, now(), now() + interval '1 hour')
--   from venues v;
