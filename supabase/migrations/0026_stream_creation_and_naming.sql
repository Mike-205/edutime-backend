-- ============================================================================
-- 0026: Creating a stream, and making cohort names stop lying
-- ============================================================================
-- Phase S part 2 of 2. TODO §S.2. Behaviour on top of 0025's structure.
--
-- Two jobs, and they belong together because both come down to one question:
-- WHERE DOES A COHORT'S NAME COME FROM?
--
--   1. A stream needs creating, and its name has to say which stream it is.
--   2. 0023 introduced a defect this fixes. It baked `pace` into a name
--      generated ONCE, at creation, while 0014 still grants `authenticated`
--      UPDATE on cohorts.pace. So a rep could flip pace and leave the name
--      reading '(bimester)' while pace = 'trimester' — the name actively
--      contradicting its own row (PHASE2_HANDOFF risk 2, demonstrated there).
--
-- The fix for both is the same: STOP GENERATING THE NAME AT CREATION AND START
-- DERIVING IT. Once a trigger maintains it, drift is impossible rather than
-- merely discouraged, and a stream's name follows from its stream label for
-- free.
--
-- Contents
--   §1  cohort_display_name()            — one definition of a cohort's name
--   §2  set_cohort_name trigger          — derives it on every write
--   §3  create_cohort_with_class_rep     — stops composing the name itself
--   §4  create_cohort_stream()           — the new API surface
--   §5  guard_cohorts_rep_update         — name protected, pace collision explained
--   §6  Grants
-- ============================================================================


-- ============================================================================
-- 1. One definition of a cohort's name
-- ============================================================================
-- `BSC-CS 2023 (bimester)` for a cohort, `BSC-CS 2023 (bimester) Stream A` for
-- one of its streams.
--
-- WHY PACE IS IN IT (0023): without it, two cohorts of the same programme and
-- intake on different paces get byte-identical names — and both are legitimate,
-- since 0024's identity key is (programme, intake, pace).
--
-- WHY current_semester IS NOT, and must never be: a cohort advances through
-- semesters — 0014 grants column-level UPDATE on current_semester precisely so
-- a rep can advance it. A name embedding it goes stale the moment they do,
-- which is the same staleness 0021 rejected stored semester dates to avoid.
-- Every component of this name is immutable for the life of the row, except
-- pace, which §2 handles by recomputing.
--
-- IMMUTABLE would be wrong here: it reads `programmes`, so its result depends
-- on table contents rather than on its arguments alone. STABLE is correct.
create function cohort_display_name(
  p_programme_id uuid,
  p_intake_year  int,
  p_pace         cohort_pace,
  p_stream       text
)
returns text
language sql
stable
set search_path = public
as $$
  select p.abbreviation || ' ' || p_intake_year || ' (' || p_pace::text || ')'
         || case when p_stream is null then '' else ' Stream ' || p_stream end
  from programmes p
  where p.id = p_programme_id;
$$;

comment on function cohort_display_name(uuid, int, cohort_pace, text) is
  'The canonical display name for a cohort or one of its streams. The single '
  'definition — cohorts.name is derived from this by trigger and never written '
  'by hand.';


-- ============================================================================
-- 2. The name is derived, not stored by its writer
-- ============================================================================
-- This is what closes 0023's defect. Whatever anyone tries to put in `name`,
-- the trigger replaces it with the canonical value — so the name can never
-- disagree with the row it describes, and a legitimate pace change is followed
-- by the name rather than leaving it behind.
--
-- TRIGGER NAME ORDERING IS LOAD-BEARING. Postgres fires same-timing triggers in
-- ALPHABETICAL order, and `guard_cohorts_rep_update_trigger` sorts before
-- `set_cohort_name_trigger`. That order is required:
--
--   guard first  -> sees the name the CLIENT submitted, so it can reject a
--                   hand-edited name (§5)
--   set second   -> recomputes from the (possibly changed) pace
--
-- Reverse them and the guard would compare against an already-canonicalised
-- name, see no change, and wave through exactly what it exists to stop — while
-- also raising on legitimate pace changes, because the recomputed name really
-- did change. Renaming either trigger without checking this reintroduces the
-- bug silently.
--
-- Invoker rights, matching the guard family from 0014 §13.3: it only reads
-- `programmes`, which every caller can already SELECT, so there is no reason to
-- add a SECURITY DEFINER surface. `set search_path = public` is mandatory
-- regardless (TECHNICAL_DISCOVERY §12).
create function set_cohort_name()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  NEW.name := cohort_display_name(
    NEW.programme_id, NEW.intake_year, NEW.pace, NEW.stream
  );
  return NEW;
end;
$$;

revoke execute on function set_cohort_name()
  from public, anon, authenticated, service_role;

create trigger set_cohort_name_trigger
  before insert or update on cohorts
  for each row
  execute function set_cohort_name();

-- Bring every existing row onto the canonical name. A no-op today — 0023
-- already produced this exact format — but it is what makes the trigger the
-- single source of truth rather than merely the source from here on.
update cohorts set name = name;

comment on column cohorts.name is
  'DERIVED, never written by hand — set_cohort_name_trigger recomputes it from '
  '(programme, intake_year, pace, stream) on every write. Display text only: '
  'the real identity is those columns, and nothing in this schema reads the '
  'name to make a decision.';


-- ============================================================================
-- 3. create_cohort_with_class_rep stops composing the name
-- ============================================================================
-- The only change: `name` leaves the INSERT entirely. §2's trigger fills it
-- before the NOT NULL check runs — BEFORE ROW triggers fire ahead of constraint
-- evaluation, so omitting the column is safe.
--
-- Everything else is preserved from 0023 §1, including the faculty scoping from
-- 0016 and the must-be-a-plain-student rule on the first rep. `set search_path`
-- restated per the CREATE OR REPLACE / proconfig trap.
create or replace function create_cohort_with_class_rep(
  p_programme_id     uuid,
  p_intake_year      int,
  p_current_semester int,
  p_pace             cohort_pace,
  p_first_rep_id     uuid,
  p_created_by       uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cohort_id         uuid;
  v_creator_role      user_role;
  v_creator_faculty   uuid;
  v_programme_faculty uuid;
  v_programme_exists  boolean;
  v_rep_role          user_role;
begin
  if p_created_by is distinct from auth.uid() then
    raise exception 'p_created_by must match the calling user';
  end if;

  select role, faculty_id into v_creator_role, v_creator_faculty
  from users where id = p_created_by;

  if v_creator_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may create a cohort';
  end if;

  if v_creator_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot create cohorts';
  end if;

  select true, d.faculty_id
  into v_programme_exists, v_programme_faculty
  from programmes p
  join departments d on d.id = p.department_id
  where p.id = p_programme_id;

  if v_programme_exists is null then
    raise exception 'Programme % not found', p_programme_id;
  end if;

  if v_programme_faculty is distinct from v_creator_faculty then
    raise exception 'Programme % belongs to another faculty', p_programme_id;
  end if;

  select role into v_rep_role from users where id = p_first_rep_id;

  if v_rep_role is null then
    raise exception 'User % not found — cannot promote them to class rep', p_first_rep_id;
  end if;

  if v_rep_role is distinct from 'student' then
    raise exception
      'User % is a % — only a student can be promoted to a new cohort''s first class rep',
      p_first_rep_id, v_rep_role;
  end if;

  -- name omitted deliberately — set_cohort_name_trigger derives it.
  insert into cohorts (programme_id, intake_year, current_semester, pace)
  values (p_programme_id, p_intake_year, p_current_semester, p_pace)
  returning id into v_cohort_id;

  update users
  set cohort_id = v_cohort_id,
      role = 'class_rep',
      class_rep_rank = 'primary'
  where id = p_first_rep_id;

  return v_cohort_id;
end;
$$;


-- ============================================================================
-- 4. create_cohort_stream
-- ============================================================================
-- TODO §S.2. A stream gets its OWN creation function rather than an extra
-- parameter on create_cohort_with_class_rep, for two reasons:
--
--   1. IT INHERITS programme_id, intake_year and pace from the parent instead
--      of taking them again. 0025 §5's composite FK would reject a mismatch,
--      but inheriting makes the mismatch unreachable rather than merely
--      refused — there is no parameter to get wrong.
--   2. IT MUST ACCEPT AN EXISTING class_rep. Splitting a cohort moves its
--      sitting rep into one of the streams, and create_cohort_with_class_rep
--      refuses anyone who is not a plain student (0016). Demote-then-promote
--      would cost two misleading audit rows and a window with no scheduling
--      authority over the cohort.
--
-- That second rule is a deliberate narrowing of 0016's, not an abandonment of
-- it: the plain-student rule exists to stop a faculty_rep being demoted into a
-- class rep and to stop silent rank changes. Neither applies to moving a
-- sitting rep of THIS cohort into one of its own streams, which is the only
-- thing accepted here.
create function create_cohort_stream(
  p_parent_cohort_id   uuid,
  p_stream             text,
  p_first_rep_id       uuid,
  p_acting_faculty_rep uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role     user_role;
  v_actor_faculty  uuid;
  v_parent         record;
  v_parent_faculty uuid;
  v_stream         text;
  v_rep_role       user_role;
  v_rep_cohort     uuid;
  v_rep_name       text;
  v_stream_id      uuid;
begin
  if p_acting_faculty_rep is distinct from auth.uid() then
    raise exception 'p_acting_faculty_rep must match the calling user';
  end if;

  select role, faculty_id into v_actor_role, v_actor_faculty
  from users where id = p_acting_faculty_rep;

  if v_actor_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may create a stream';
  end if;

  if v_actor_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot create streams';
  end if;

  select c.id, c.programme_id, c.intake_year, c.current_semester, c.pace,
         c.parent_cohort_id
  into v_parent
  from cohorts c
  where c.id = p_parent_cohort_id;

  if v_parent.id is null then
    raise exception 'Cohort % does not exist', p_parent_cohort_id;
  end if;

  -- 0025 §6's trigger would catch this, but naming it here says WHY rather
  -- than reporting a violated invariant.
  if v_parent.parent_cohort_id is not null then
    raise exception
      'Cohort % is itself a stream — streams are the lowest level and cannot be subdivided',
      p_parent_cohort_id;
  end if;

  select d.faculty_id into v_parent_faculty
  from programmes p
  join departments d on d.id = p.department_id
  where p.id = v_parent.programme_id;

  if v_parent_faculty is distinct from v_actor_faculty then
    raise exception 'Cohort % belongs to another faculty', p_parent_cohort_id;
  end if;

  v_stream := nullif(btrim(coalesce(p_stream, '')), '');
  if v_stream is null then
    raise exception 'A stream needs a label (''A'', ''B'', ...)';
  end if;

  -- --- The first rep -------------------------------------------------------
  select u.role, u.cohort_id, u.first_name || ' ' || u.last_name
  into v_rep_role, v_rep_cohort, v_rep_name
  from users u where u.id = p_first_rep_id;

  if v_rep_role is null then
    raise exception 'User % not found — cannot make them this stream''s class rep',
      p_first_rep_id;
  end if;

  -- Must already belong to the cohort being split. Without this a faculty rep
  -- could staff a stream with someone from an unrelated cohort, which is the
  -- cross-cohort authority leak 0016 §1 and TECHNICAL_DISCOVERY §13.4 exist to
  -- prevent — reached sideways through stream creation instead of a join
  -- request.
  if v_rep_cohort is distinct from p_parent_cohort_id then
    raise exception
      'User % is not in cohort % — a stream''s first rep must come from the cohort being split',
      p_first_rep_id, p_parent_cohort_id;
  end if;

  -- student OR class_rep, and nothing else. A faculty_rep must never be
  -- demoted into a class rep (0016's original concern, still enforced).
  if v_rep_role not in ('student', 'class_rep') then
    raise exception
      'User % is a % — only a student or a sitting class_rep of this cohort can lead a stream',
      p_first_rep_id, v_rep_role;
  end if;

  -- --- Create ---------------------------------------------------------------
  -- programme_id, intake_year and pace are COPIED FROM THE PARENT, never taken
  -- as parameters. name is omitted — §2's trigger derives it.
  insert into cohorts (
    programme_id, intake_year, current_semester, pace, parent_cohort_id, stream
  )
  values (
    v_parent.programme_id, v_parent.intake_year, v_parent.current_semester,
    v_parent.pace, p_parent_cohort_id, v_stream
  )
  returning id into v_stream_id;

  update users
  set cohort_id = v_stream_id,
      role = 'class_rep',
      class_rep_rank = 'primary'
  where id = p_first_rep_id;

  -- Logged even when the target was already a class_rep. Being placed in charge
  -- of a different group is an authority event whatever their previous role,
  -- and role_audit_log exists precisely so authority changes leave a trace
  -- (0022 §5).
  insert into role_audit_log (
    user_id, user_name, cohort_id, action, new_rank, actor_id, snapshot
  )
  values (
    p_first_rep_id, v_rep_name, v_stream_id, 'promoted', 'primary',
    p_acting_faculty_rep,
    jsonb_build_object(
      'previous_role',   v_rep_role,
      'previous_cohort', p_parent_cohort_id,
      'stream',          v_stream,
      'reason',          'stream_created'
    )
  );

  return v_stream_id;
end;
$$;

comment on function create_cohort_stream(uuid, text, uuid, uuid) is
  'Creates one stream of a cohort and installs its class rep. Faculty rep, own '
  'faculty only. programme/intake/pace are inherited from the parent, never '
  'passed. Unlike create_cohort_with_class_rep this accepts a sitting class_rep '
  'as the first rep, because splitting a cohort moves its existing rep into a '
  'stream.';


-- ============================================================================
-- 5. guard_cohorts_rep_update
-- ============================================================================
-- Three changes.
--
-- `name` joins the protected list. It is derived now, so there is no legitimate
-- client edit — and §6 revokes the UPDATE privilege on it as well.
--
-- BE CLEAR ABOUT WHICH LAYER ACTUALLY STOPS IT: the privilege does. Postgres
-- checks column privileges BEFORE row triggers, so a client attempting a rename
-- gets `permission denied for table cohorts` and never reaches the message
-- below. And the branch cannot fire for postgres/service_role either, since the
-- guard returns early for them. So the name check here is a FALLBACK — it
-- documents the intent where someone reading the guard will see it, and it
-- would become the operative control if the §6 grant were ever restored. That
-- is the belt-and-braces arrangement TECHNICAL_DISCOVERY §13.1 describes, not
-- two controls that both fire.
--
-- `parent_cohort_id` and `stream` join it too. Neither is in any client UPDATE
-- grant, so this is defence in depth rather than the primary control — but a
-- rep re-parenting their own cohort would be a structural change reached
-- through a self-service edit, which is exactly the shape of hole 0014 §13.3
-- was written to close.
--
-- And a pace change that would collide now explains itself. 0024's identity key
-- is (programme, intake, pace), so flipping pace onto an existing twin raises a
-- raw 23505 naming an internal index. A rep should be told what actually
-- happened.
create or replace function guard_cohorts_rep_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return NEW;
  end if;

  if NEW.id               is distinct from OLD.id
  or NEW.programme_id     is distinct from OLD.programme_id
  or NEW.intake_year      is distinct from OLD.intake_year
  or NEW.created_at       is distinct from OLD.created_at
  or NEW.parent_cohort_id is distinct from OLD.parent_cohort_id
  or NEW.stream           is distinct from OLD.stream
  then
    raise exception
      'A class rep may only update current_semester and pace on their own cohort'
      using errcode = '42501';
  end if;

  -- Separate branch and message: `name` is not forbidden because it is
  -- structural, it is forbidden because it is DERIVED. Telling a rep "you may
  -- only update current_semester and pace" when they tried to rename their
  -- cohort would leave them wondering why the field exists at all.
  if NEW.name is distinct from OLD.name then
    raise exception
      'A cohort''s name is derived from its programme, intake year, pace and '
      'stream — it cannot be set directly. Change one of those instead.'
      using errcode = '42501';
  end if;

  if NEW.pace is distinct from OLD.pace
     and NEW.parent_cohort_id is null
     and exists (
       select 1 from cohorts c
       where c.parent_cohort_id is null
         and c.programme_id = NEW.programme_id
         and c.intake_year  = NEW.intake_year
         and c.pace         = NEW.pace
         and c.id          <> NEW.id
     )
  then
    raise exception
      'A % cohort already exists for this programme and intake year. A cohort is '
      'identified by (programme, intake year, pace), so two cannot share all three.',
      NEW.pace
      using errcode = '23505';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_cohorts_rep_update() from public, anon, authenticated;


-- ============================================================================
-- 6. Grants
-- ============================================================================
-- `name` leaves the column-level UPDATE grant. 0014 gave it to `authenticated`
-- because auto-generated names were ambiguous and a rep might need to fix one;
-- 0023 removed that reason by putting pace in the name, and §2 removed it
-- permanently by deriving the whole thing. The grant is now vestigial, and a
-- privilege nobody needs is a privilege worth removing.
--
-- Restating the full set rather than issuing a bare REVOKE on one column, so
-- the intended end state is visible in one place.
revoke update on cohorts from authenticated;
grant  update (current_semester, pace) on cohorts to authenticated;

revoke execute on function cohort_display_name(uuid, int, cohort_pace, text) from public, anon;
grant  execute on function cohort_display_name(uuid, int, cohort_pace, text) to authenticated, service_role;

revoke execute on function create_cohort_stream(uuid, text, uuid, uuid) from public, anon;
grant  execute on function create_cohort_stream(uuid, text, uuid, uuid) to authenticated, service_role;
