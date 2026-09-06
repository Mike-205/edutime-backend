-- ============================================================================
-- 0029: Placement moves the roster row too
-- ============================================================================
-- TODO §S.6. A correctness fix, not a tidy-up.
--
-- THE BUG. Two functions move a student's account into a cohort without moving
-- their roster row:
--
--   create_cohort_with_class_rep   (0003, installing a new cohort's first rep)
--   approve_cohort_join_request    (0003, the deferred/transferred/repeated path)
--
-- S.3 settled that student_roster.cohort_id is where a student IS — 0.5 says
-- plainly that "the row pins the cohort, so a claim places the student
-- automatically". Leaving it behind is not merely untidy, because
-- claim_roster_row sets users.cohort_id from the roster row UNCONDITIONALLY
-- ("The roster is authoritative for the official name and the cohort"). So a
-- student placed by either function above, who later signs in with a university
-- address and triggers a takeover, is SILENTLY DROPPED BACK into whatever
-- cohort their stale roster row still names.
--
-- That is the takeover misplacement S.3 chose its design to avoid, re-entering
-- through a different door. Demonstrated before writing this: after
-- create_cohort_with_class_rep places a student in BSC-CS 2023 (trimester),
-- their roster row still reads BSC-CS 2023 (bimester), and a claim resets the
-- account to the latter.
--
-- WHY THIS CANNOT COPY 0028. create_cohort_stream moves the roster row
-- unconditionally, and is right to: a stream inherits its parent's programme_id
-- and intake_year by construction, so the moved row is always valid. Neither
-- function here has that guarantee — see §1.
--
-- Contents
--   §1  sync_roster_placement()            — the conditional move, shared
--   §2  create_cohort_with_class_rep       — calls it
--   §3  approve_cohort_join_request        — calls it
--   §4  roster_placement_divergences()     — surfacing what could not be moved
--   §5  Grants
-- ============================================================================


-- ============================================================================
-- 1. sync_roster_placement
-- ============================================================================
-- Moves a claimed student's roster row to follow their account — BUT ONLY WHERE
-- THE RESULT STAYS LEGAL.
--
-- roster_assert_may_write requires a registration number's programme and intake
-- year to match the cohort it is filed under. So an unconditional move can
-- manufacture roster state the roster API itself forbids. This is reachable,
-- not theoretical: 0016 DELIBERATELY does not check that a first rep's
-- registration number belongs to the cohort's programme —
--
--   "NOT checked: that the student's registration number actually belongs to
--    p_programme_id. [...] the Faculty Rep is promoting someone whose election
--    they personally witnessed"
--
-- — so an EB1 student can legally become first rep of a BA2 cohort, and
-- roster_add_student then refuses that exact pairing outright. Verified both
-- halves before writing this.
--
-- Hence: move when the number still agrees with the cohort, decline silently
-- when it does not. Refusing the whole placement instead would break the
-- cross-faculty case 0016 deliberately permits; forcing the move would create a
-- row nothing else in the schema would accept. What is left over is surfaced by
-- §4 rather than hidden.
--
-- Returns true when the row moved, so callers can report it if they ever need
-- to. Internal only — no EXECUTE granted (§5), same as notify_cohort_members.
create function sync_roster_placement(
  p_user_id   uuid,
  p_cohort_id uuid,
  p_actor_id  uuid,
  p_reason    text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_roster_id     uuid;
  v_reg_number    text;
  v_from_cohort   uuid;
  v_prog          uuid;
  v_intake        int;
  v_parts         reg_number_parts;
begin
  select r.id, r.reg_number, r.cohort_id
  into v_roster_id, v_reg_number, v_from_cohort
  from student_roster r
  where r.claimed_by = p_user_id;

  -- No roster row at all: an account that has never claimed. Nothing to move,
  -- and nothing wrong — claim_roster_row will place them correctly later.
  if v_roster_id is null then
    return false;
  end if;

  if v_from_cohort = p_cohort_id then
    return false;
  end if;

  select c.programme_id, c.intake_year into v_prog, v_intake
  from cohorts c where c.id = p_cohort_id;

  v_parts := parse_reg_number(v_reg_number);

  -- The check that keeps this honest. Mirrors roster_assert_may_write exactly,
  -- so a row this function writes is always a row roster_add_student would have
  -- accepted.
  if v_parts.programme_id is distinct from v_prog
     or v_parts.admission_year is distinct from v_intake then
    return false;
  end if;

  update student_roster set cohort_id = p_cohort_id where id = v_roster_id;

  insert into roster_audit_log (
    roster_id, reg_number, action, actor_id, target_user, snapshot
  )
  values (
    v_roster_id, v_reg_number, 'reassigned', p_actor_id, p_user_id,
    jsonb_build_object(
      'from_cohort_id', v_from_cohort,
      'to_cohort_id',   p_cohort_id,
      'was_claimed',    true,
      'reason',         p_reason
    )
  );

  return true;
end;
$$;

comment on function sync_roster_placement(uuid, uuid, uuid, text) is
  'Moves a claimed student''s roster row to follow their account, but only when '
  'the registration number still agrees with the cohort''s programme and intake '
  'year — otherwise it would create roster state roster_add_student forbids. '
  'Internal; called by the placement functions.';


-- ============================================================================
-- 2. create_cohort_with_class_rep
-- ============================================================================
-- One line added. Everything else preserved from 0026 §3, including the omitted
-- `name` (derived by trigger) and the plain-student rule on the first rep.
-- `set search_path = public` restated per the CREATE OR REPLACE / proconfig
-- trap.
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

  insert into cohorts (programme_id, intake_year, current_semester, pace)
  values (p_programme_id, p_intake_year, p_current_semester, p_pace)
  returning id into v_cohort_id;

  update users
  set cohort_id = v_cohort_id,
      role = 'class_rep',
      class_rep_rank = 'primary'
  where id = p_first_rep_id;

  perform sync_roster_placement(p_first_rep_id, v_cohort_id, p_created_by, 'cohort_created');

  return v_cohort_id;
end;
$$;


-- ============================================================================
-- 3. approve_cohort_join_request
-- ============================================================================
-- The more important of the two. 0.5 keeps cohort_join_requests alive precisely
-- as the exception path for students who deferred, transferred or repeated —
-- which is exactly the situation where a roster row goes stale, and exactly the
-- student most likely to sign in later and be bounced back.
--
-- One line added; everything else preserved from 0016 §4, including the
-- refusal to admit a sitting class_rep (which is what stops authority being
-- carried sideways through a student-initiated request —
-- TECHNICAL_DISCOVERY §13.4).
create or replace function approve_cohort_join_request(
  p_request_id uuid,
  p_decided_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_cohort_id  uuid;
  v_role       user_role;
begin
  if p_decided_by is distinct from auth.uid() then
    raise exception 'p_decided_by must match the calling user';
  end if;

  select student_id, cohort_id
  into v_student_id, v_cohort_id
  from cohort_join_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    raise exception 'No pending join request with id %', p_request_id;
  end if;

  if not exists (
    select 1 from users u
    where u.id = auth.uid()
      and u.role = 'class_rep'
      and u.cohort_id = v_cohort_id
  ) then
    raise exception 'Only the class rep of this cohort may approve join requests';
  end if;

  select role into v_role from users where id = v_student_id;

  if v_role is distinct from 'student' then
    raise exception
      'User % is a % and cannot be admitted by join request. A class rep must be '
      'demoted by their faculty rep before changing cohorts, so that every role '
      'change still originates top-down.',
      v_student_id, v_role
      using errcode = 'P0001';
  end if;

  update cohort_join_requests
  set status = 'approved', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;

  update users set cohort_id = v_cohort_id where id = v_student_id;

  perform sync_roster_placement(v_student_id, v_cohort_id, p_decided_by, 'join_request_approved');
end;
$$;


-- ============================================================================
-- 4. What could not be moved
-- ============================================================================
-- §1 declines to move a roster row whose registration number disagrees with its
-- new cohort's programme or intake year. That leaves a genuine divergence — and
-- an unfixable one, because the roster API would refuse to write the corrected
-- row anyway. Such a student remains exposed to the takeover misplacement
-- described in this file's header.
--
-- That is a deliberate trade (see §1) and the answer is VISIBILITY, exactly as
-- it was for unstreamed members in 0028 §3: surface it so a human can resolve
-- it out of band, rather than enforce something that would break the
-- cross-programme placement 0016 permits on purpose.
--
-- Lists claimed roster rows whose cohort disagrees with the account's cohort.
-- Faculty-rep scoped, resolved through the cohort chain the same way
-- demote_class_rep and promote_class_rep resolve it. SECURITY DEFINER because
-- students cannot read student_roster at all (0.5).
create function roster_placement_divergences()
returns table (
  reg_number      text,
  full_name       text,
  roster_cohort   text,
  account_cohort  text
)
language sql
stable
security definer
set search_path = public
as $$
  select r.reg_number,
         r.first_name || ' ' || r.last_name,
         rc.name,
         uc.name
  from student_roster r
  join users u   on u.id = r.claimed_by
  join cohorts rc on rc.id = r.cohort_id
  join cohorts uc on uc.id = u.cohort_id
  join programmes rp  on rp.id = rc.programme_id
  join departments rd on rd.id = rp.department_id
  where r.cohort_id is distinct from u.cohort_id
    and exists (
      select 1 from users me
      where me.id = auth.uid()
        and me.role = 'faculty_rep'
        and me.faculty_id = rd.faculty_id
    )
  order by r.reg_number;
$$;

comment on function roster_placement_divergences() is
  'Claimed roster rows whose cohort disagrees with the account''s cohort — the '
  'residue sync_roster_placement could not legally fix. Faculty rep, own '
  'faculty. A takeover would re-place these students per their roster row, so '
  'they need resolving out of band.';


-- ============================================================================
-- 5. Grants
-- ============================================================================
-- sync_roster_placement is INTERNAL. It writes student_roster and
-- roster_audit_log with no scoping checks of its own — it trusts its callers,
-- which are the two definer functions above that have already established who
-- may place whom. Exposing it over RPC would hand any authenticated user a way
-- to re-point roster rows directly, bypassing roster_assert_may_write entirely.
-- Revoked from every role, exactly like notify_cohort_members.
revoke execute on function sync_roster_placement(uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;

revoke execute on function roster_placement_divergences() from public, anon;
grant  execute on function roster_placement_divergences() to authenticated, service_role;
