-- ============================================================================
-- 0040: Flow 1 — claim_identity_personal, and the programme-match guard
-- ============================================================================
-- Part 4 of 5. AUTH_FLOW_REFACTOR.md §3: a personal-email OAuth account picks
-- a programme, toggles self-sponsored, types a student number and admission
-- year, and that commits immediately as claim_method = 'provisional' —
-- BEFORE any cohort is chosen. This is deliberate (§3 step 4): the
-- users_student_number_unique constraint (0037) is the only thing standing
-- between two people racing to claim the same student, and it can only do
-- that job at the moment of the write it actually guards.
--
-- Contents
--   §1  claim_identity_personal() — the Flow 1 claim
--   §2  approve_cohort_join_request — programme-match guard added
-- ============================================================================


-- ============================================================================
-- 1. claim_identity_personal
-- ============================================================================
-- Mirrors claim_roster_row's (0019) idempotent-reclaim and one-identity-per-
-- account shape exactly, adapted to write facts directly onto users instead
-- of binding to a separate roster row — there is no roster row in this
-- design.
--
-- Refuses outright if the caller already holds an 'oauth' claim. This is not
-- defensive — AUTH_FLOW_REFACTOR.md §4's asymmetry (a personal-email account
-- can never evict a school-email one) and §7's non-negotiable (oauth always
-- displaces provisional, never the reverse) both break if this function
-- could overwrite an oauth claim.
--
-- student_number format: deliberately NOT validated beyond non-blank. The
-- old reg_number format lived in parse_reg_number's encoding (0017), which
-- this redesign dissolves — AUTH_FLOW_REFACTOR.md is silent on any
-- replacement format, and that silence is deliberate. The uniqueness
-- constraint (0037) is the real gate.
--
-- admission_year bound (2000..current year + 1): a named, adjustable
-- decision, not derived from the spec — AUTH_FLOW_REFACTOR.md calls the
-- field "descriptive only" and gives no range. Loosen or tighten here if it
-- turns out wrong; nothing else depends on the exact bound.
--
-- Never writes school_email/personal_email — 0039's auth sync trigger is
-- their sole writer (Global Constraints).
create or replace function claim_identity_personal(
  p_programme_id   uuid,
  p_self_sponsored boolean,
  p_student_number text,
  p_admission_year int,
  p_acting_user    uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user users;
  v_norm text;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_user from users where id = p_acting_user;

  if v_user.id is null then
    raise exception 'Acting user % not found', p_acting_user;
  end if;

  if v_user.claim_method = 'oauth' then
    raise exception
      'An OAuth-verified identity cannot be replaced by a personal-email claim';
  end if;

  v_norm := nullif(trim(p_student_number), '');

  if v_norm is null then
    raise exception 'A student number is required';
  end if;

  -- Idempotent re-claim, and a guard against one account collecting
  -- identities — same shape as claim_roster_row (0019).
  if v_user.claim_method = 'provisional' then
    if v_user.student_number = v_norm then
      return;
    end if;
    raise exception 'This account has already claimed a different identity';
  end if;

  if not exists (select 1 from programmes where id = p_programme_id) then
    raise exception 'Programme % does not exist', p_programme_id;
  end if;

  if p_admission_year < 2000
     or p_admission_year > extract(year from now())::int + 1 then
    raise exception 'Admission year % is not plausible', p_admission_year;
  end if;

  update users
  set programme_id   = p_programme_id,
      self_sponsored  = p_self_sponsored,
      student_number  = v_norm,
      admission_year  = p_admission_year,
      claim_method    = 'provisional'
  where id = p_acting_user;

exception
  when unique_violation then
    raise exception 'Student number % is already claimed', v_norm;
end;
$$;

comment on function claim_identity_personal(uuid, boolean, text, int, uuid) is
  'Flow 1 (AUTH_FLOW_REFACTOR.md §3): a personal-email OAuth account commits '
  'its identity facts immediately, as claim_method = provisional. Never '
  'touches school_email/personal_email — the auth sync trigger (0039) is '
  'their sole writer.';

revoke execute on function claim_identity_personal(uuid, boolean, text, int, uuid)
  from public, anon;
grant  execute on function claim_identity_personal(uuid, boolean, text, int, uuid)
  to authenticated, service_role;


-- ============================================================================
-- 2. approve_cohort_join_request — programme-match guard
-- ============================================================================
-- Additive change to the existing function. Its live body (as of 0029,
-- confirmed against the applied schema — NOT the older 0003/0016 shape) is
-- preserved in full: the p_decided_by/auth.uid() self-check, the
-- class-rep-of-this-cohort authorization check, the student-role check, and
-- the sync_roster_placement() call are all pre-existing and out of scope
-- for this migration, and are carried forward unchanged, including the
-- search_path pin 0029 already carries. Only the programme-match guard
-- below is new, inserted after the existing authorization/role checks and
-- before the mutation, so it does not reorder error precedence ahead of
-- checks that were already there.
--
-- The guard itself: before moving the student into the cohort, refuse if
-- the student already carries a programme_id (set by claim_identity_personal,
-- or later by Flow 2) that disagrees with the target cohort's own
-- programme_id. cohorts.programme_id is a real, NOT NULL column on every
-- cohort row including streams — cohorts_stream_inherits (0025) forces a
-- stream's own programme_id to equal its parent's — so reading it directly
-- off the target cohort row is correct with no parent-cohort lookup needed.
--
-- This check only ever fires for a student who HAS a programme_id — an
-- old-style roster account (programme_id still null, since Flow 1/2 haven't
-- claimed it) skips the check entirely, exactly as approval worked before
-- this migration. The composite FK (0037 §4) is the actual enforcement;
-- this check exists only to turn its raw constraint violation into a
-- readable sentence raised before the FK would fire.
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
  v_student_id        uuid;
  v_cohort_id         uuid;
  v_role              user_role;
  v_student_programme uuid;
  v_cohort_programme  uuid;
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

  select programme_id into v_student_programme from users where id = v_student_id;
  select programme_id into v_cohort_programme from cohorts where id = v_cohort_id;

  if v_student_programme is not null
     and v_student_programme is distinct from v_cohort_programme then
    raise exception
      'This student''s programme does not match this cohort''s programme — approval refused';
  end if;

  update cohort_join_requests
  set status = 'approved', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;

  update users set cohort_id = v_cohort_id where id = v_student_id;

  perform sync_roster_placement(v_student_id, v_cohort_id, p_decided_by, 'join_request_approved');
end;
$$;
