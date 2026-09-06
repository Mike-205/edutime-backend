-- ============================================================================
-- 0025: Streams — a cohort can be split into parallel lecture groups
-- ============================================================================
-- Phase S part 1 of 2. TODO §S.1. Structure only; the functions that create
-- streams and name them land in 0026.
--
-- WHAT A STREAM IS. A large intake is split into parallel lecture groups —
-- Stream A, Stream B — because one room cannot hold it. Confirmed against how
-- Chuka actually runs: the split is WHOLE-TIMETABLE (a student is in one stream
-- for every unit, all semester), each stream elects ITS OWN class rep, and
-- streams regularly come back together for joint sessions.
--
-- Therefore a stream IS a cohort in this schema's terms. Authority here is
-- cohort-scoped by construction (TECHNICAL_DISCOVERY §2 — a rep's writ runs
-- over exactly one cohort), so a group with its own rep and its own complete
-- timetable is already what `cohorts` models. Consequences, all of them the
-- reason this migration is as small as it is:
--
--   * No change to RLS. A stream is a cohort id like any other.
--   * No change to conflict detection. Two streams are two cohort_ids, so
--     event_cohorts_no_self_overlap keeps working untouched — and correctly,
--     since Stream A and Stream B genuinely can hold lectures at the same hour.
--   * No change to the roster layer (TODO §S.3). Because §5 below forces a
--     stream to inherit its parent's programme_id and intake_year, every check
--     in roster_assert_may_write passes for a stream id.
--   * A joint session is just a combined lecture between two cohorts, which
--     has worked since 0010.
--
-- WHAT A STREAM IS NOT: branching. Branching is a pace divergence by quorum
-- inside a cohort (SSP students moving to trimester); a stream splits a cohort
-- that already shares one. See TODO's "Explicitly not doing".
--
-- Contents
--   §1  parent_cohort_id, stream         — the two columns
--   §2  cohorts_identity_unique          — becomes PARTIAL
--   §3  cohorts_stream_unique            — one Stream A per cohort
--   §4  cohorts_stream_shape             — both columns or neither
--   §5  cohorts_stream_inherits          — a stream cannot contradict its parent
--   §6  enforce_cohort_stream_depth      — streams are the lowest level
--
-- NOTHING HERE BREAKS AN EXISTING WRITER, which is why structure goes first
-- this time rather than second. Both columns are nullable with no default, the
-- new constraints only bite when parent_cohort_id is non-null, and every
-- existing cohort is left exactly as it was. Contrast 0023/0024, where columns
-- were being DROPPED and the writers had to move first.
-- ============================================================================


-- ============================================================================
-- 1. The two columns
-- ============================================================================
-- Deliberately NO `references cohorts (id)` here. §5's composite foreign key
-- already requires parent_cohort_id to match some row's id, so a second plain
-- FK on the same column would be redundant — two constraints to keep in step
-- for one guarantee.
alter table cohorts add column parent_cohort_id uuid;
alter table cohorts add column stream           text;

comment on column cohorts.parent_cohort_id is
  'NULL for a real cohort; the parent''s id for one of its streams. Exactly two '
  'levels — see enforce_cohort_stream_depth. `coalesce(parent_cohort_id, id)` '
  'answers "which cohort is this really?".';

comment on column cohorts.stream is
  'The stream label (''A'', ''B'', ...) for a stream row; NULL for a real '
  'cohort. Paired with parent_cohort_id by cohorts_stream_shape — a row has '
  'both or neither.';


-- ============================================================================
-- 2. The identity key becomes partial
-- ============================================================================
-- 0024 §1 established: ONE cohort per (programme, intake, pace). That guarantee
-- is the whole reason this section is a partial index rather than a wider key.
--
-- THE REJECTED DESIGN, recorded because it is the obvious one and it is wrong:
-- widening the key to (programme_id, intake_year, pace, stream). Widening a
-- unique key is always safe for the DATABASE — it can only ever permit more —
-- but it is not safe for the GUARANTEE. Three rows would then each claim to be
-- EB1/2023/bimester and nothing could answer "which one is the cohort?".
--
-- Scoping the index to top-level rows keeps the sentence true for everything
-- that is actually a cohort, and makes streams structurally subordinate rather
-- than sibling. The general lesson: when a new concept does not fit an existing
-- key, check whether it is really a PEER of that key's subject before widening
-- to accommodate it.
--
-- It must become an INDEX rather than staying a CONSTRAINT: Postgres will not
-- accept a WHERE clause on a UNIQUE constraint. The schema already uses this
-- shape for users_one_primary_per_cohort and cohort_join_requests_one_pending_per_student.
alter table cohorts drop constraint cohorts_identity_unique;

create unique index cohorts_identity_unique
  on cohorts (programme_id, intake_year, pace)
  where parent_cohort_id is null;


-- ============================================================================
-- 3. One Stream A per cohort
-- ============================================================================
create unique index cohorts_stream_unique
  on cohorts (parent_cohort_id, stream)
  where parent_cohort_id is not null;


-- ============================================================================
-- 4. Both columns, or neither
-- ============================================================================
-- A stream must name itself, and a real cohort must not pretend to be one.
-- Without this a row could carry a parent and no label (unnameable, and
-- invisible to §3's uniqueness, since NULL stream values do not conflict) or a
-- label and no parent (a stream of nothing).
alter table cohorts add constraint cohorts_stream_shape check (
     (parent_cohort_id is null     and stream is null)
  or (parent_cohort_id is not null and stream is not null)
);


-- ============================================================================
-- 5. A stream cannot contradict its parent
-- ============================================================================
-- programme_id, intake_year and pace are all NOT NULL, so a stream row is
-- FORCED to carry copies of them — and nothing so far stops a "stream" of a
-- bimester cohort declaring itself trimester. That is not untidy, it is
-- corrupting: term_bounds() is a pure function of date AND pace, so a
-- mislabelled stream computes the wrong academic term and materializes a
-- recurring series against the wrong horizon. The nonsense would surface weeks
-- later as wrongly-scheduled lectures, not as an error.
--
-- Read the FK as: A CHILD'S FOUR VALUES MUST MATCH SOME PARENT'S FOUR VALUES.
--
-- Rejected alternatives: a trigger (procedural, disableable, one more thing to
-- remember) and trusting the creation function (a direct INSERT as postgres
-- walks straight past it — which is exactly how seed.sql writes rows).
--
-- WHY THE NULL CASE NEEDS NO SPECIAL HANDLING: the FK is MATCH SIMPLE, the
-- default, under which a row with ANY NULL among its referencing columns
-- satisfies the constraint automatically. A top-level cohort has
-- parent_cohort_id null, so the FK never applies to it. A stream has all four
-- non-null, so it always does. No partial constraint, no sentinel value.
--
-- The unique key on (id, ...) exists only to give the FK something to
-- reference; `id` is already the primary key, so it adds no new guarantee.
alter table cohorts add constraint cohorts_id_identity_unique
  unique (id, programme_id, intake_year, pace);

alter table cohorts add constraint cohorts_stream_inherits
  foreign key  (parent_cohort_id, programme_id, intake_year, pace)
  references cohorts (id, programme_id, intake_year, pace)
  on delete restrict;

-- A side effect worth knowing about, and a welcome one: this also blocks
-- changing a parent's pace while it has streams. 0014 grants `authenticated`
-- UPDATE on cohorts.pace, and 0023 baked pace into a name generated once at
-- creation — so a rep flipping pace could leave the name contradicting the row
-- (PHASE2_HANDOFF risk 2). For a STREAMED cohort that is now impossible.
-- 0026 handles the unstreamed case.


-- ============================================================================
-- 6. Streams are the lowest level
-- ============================================================================
-- The hierarchy is exactly two deep, never three. A stream of a stream is
-- nonsense, and §5's FK does NOT stop it — a stream row is itself a perfectly
-- valid FK target, so it happily becomes a parent.
--
-- A CHECK cannot express it either; it would need a subquery. It CAN be forced
-- declaratively — add an is_stream flag, a second flag column pinned to false
-- by a CHECK, and unique (id, is_stream) so the FK can demand a non-stream
-- parent — but that is three pieces of scaffolding to replace ten lines of
-- plpgsql, and obscure enough that someone would dismantle it without
-- realising what it was holding up. Rejected on legibility.
--
-- So: a guard trigger, which is idiomatic here rather than a fallback.
-- enforce_max_class_reps solves a structurally identical problem (a rule that
-- has to look at other rows), and TECHNICAL_DISCOVERY §13 treats guard triggers
-- as a first-class mechanism alongside RLS and privileges. It also gives a
-- readable error, which an FK violation cannot.
--
-- NOT security definer, matching the guard family in 0014 §2: these run as the
-- invoker deliberately. Every caller already holds SELECT on cohorts (0014
-- grants it at table level), so the lookup resolves. `set search_path = public`
-- is mandatory regardless — see the proconfig trap in TECHNICAL_DISCOVERY §12.
create function enforce_cohort_stream_depth()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if NEW.parent_cohort_id is not null and exists (
       select 1 from cohorts c
       where c.id = NEW.parent_cohort_id
         and c.parent_cohort_id is not null
     ) then
    raise exception
      'Cohort % is itself a stream — streams are the lowest level and cannot be subdivided',
      NEW.parent_cohort_id;
  end if;

  return NEW;
end;
$$;

-- Trigger functions need no EXECUTE grant — the trigger mechanism is not
-- privilege-gated — so revoking from every role costs nothing and closes the
-- RPC door.
revoke execute on function enforce_cohort_stream_depth()
  from public, anon, authenticated, service_role;

create trigger enforce_cohort_stream_depth_trigger
  before insert or update on cohorts
  for each row
  execute function enforce_cohort_stream_depth();
