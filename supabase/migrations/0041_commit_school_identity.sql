-- ============================================================================
-- 0041: Flow 2 — commit_school_identity (first-claim path)
-- ============================================================================
-- Part 3 of 5 of the OAuth-only auth redesign (AUTH_FLOW_REFACTOR.md).
-- AUTH_FLOW_REFACTOR.md §4: unlike Flow 1, a school-email account's identity
-- facts are never staged — they are always re-derivable from the proven
-- school_email address, so nothing needs writing until the moment a class
-- rep approves the student's join request ("Takeover on approval, not on
-- write", §4 step 5).
--
-- This migration delivers the FIRST-CLAIM path only: derive the four facts,
-- refuse if they don't resolve, refuse if they don't match the target
-- cohort's programme, and write them. It deliberately does NOT yet handle an
-- existing holder of the derived student_number — if one exists, the final
-- write below hits the raw users_student_number_unique constraint
-- (unique_violation) rather than a graceful takeover. That is an accepted
-- interim state, not an oversight: the constraint still prevents any silent
-- corruption, and the graceful eviction/escalation logic is a genuinely
-- separate piece of complexity, added on top of this same function in the
-- next migration (0042).
--
-- Contents
--   §1  commit_school_identity() — derive, guard, write (no takeover yet)
--   §2  approve_cohort_join_request — branches into it
-- ============================================================================


-- ============================================================================
-- 1. commit_school_identity
-- ============================================================================
-- Internal only, exactly like sync_roster_placement (0029): no EXECUTE
-- granted to any role. It trusts its caller — approve_cohort_join_request has
-- already established that p_actor_id is the real class rep of this cohort
-- and that p_student_id names a plain student, before ever reaching here.
--
-- Re-derives from users.school_email SERVER-SIDE, always — never from a
-- client-supplied value. The whole point of Flow 2 is that the four facts
-- are backed by a provider-proven address; accepting them as parameters
-- would hand the client the one thing this design refuses to let it assert.
--
-- reg_number_from_email + parse_reg_number, chained exactly as the boundary
-- parser (AUTH_FLOW_REFACTOR.md §2) describes — both already exist
-- (0017/0019), both already granted to authenticated for the client-side
-- "suggest a cohort" step this migration does not need to duplicate.
--
-- parse_reg_number's result field is is_self_sponsored (the type is
-- reg_number_parts, 0017) — NOT self_sponsored, which is the column name on
-- users. Do not let the two names blur into each other.
create or replace function commit_school_identity(
  p_student_id uuid,
  p_cohort_id  uuid,
  p_actor_id   uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reg               text;
  v_derived           reg_number_parts;
  v_cohort_programme  uuid;
begin
  select reg_number_from_email(school_email) into v_reg from users where id = p_student_id;
  v_derived := parse_reg_number(v_reg);

  if v_derived.programme_id is null then
    raise exception
      'Could not derive a student identity from this school email. A faculty rep must resolve this.';
  end if;

  select programme_id into v_cohort_programme from cohorts where id = p_cohort_id;

  if v_derived.programme_id is distinct from v_cohort_programme then
    raise exception
      'The identity derived from this school email does not match this cohort''s programme';
  end if;

  update users
  set programme_id   = v_derived.programme_id,
      self_sponsored = v_derived.is_self_sponsored,
      student_number = v_derived.student_number,
      admission_year = v_derived.admission_year,
      claim_method   = 'oauth'
  where id = p_student_id;

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    null, v_derived.student_number, 'claimed', p_actor_id, p_student_id,
    jsonb_build_object('method', 'oauth', 'cohort_id', p_cohort_id)
  );
end;
$$;

comment on function commit_school_identity(uuid, uuid, uuid) is
  'Flow 2 (AUTH_FLOW_REFACTOR.md §4): derives a student''s identity facts '
  'from their proven school_email and commits them as claim_method = oauth, '
  'at approval time. First-claim path only as of this migration — an '
  'existing holder of the derived student_number hits a raw unique_violation '
  'here; 0042 adds the graceful takeover. Internal only, called by '
  'approve_cohort_join_request.';

revoke execute on function commit_school_identity(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;


-- ============================================================================
-- 2. approve_cohort_join_request — branches into the Flow 2 path
-- ============================================================================
-- Additive change to the existing function (last replaced in 0040). Every
-- pre-existing check (p_decided_by/auth.uid() self-check, class-rep-of-this-
-- cohort authorization, student-role check, 0040's stored-programme-match
-- guard, sync_roster_placement call) is preserved verbatim, in original
-- order. The only new logic is the branch below, and fetching the full
-- student row once (v_student) instead of just its role, so both the
-- existing role check and the new discriminator can read off it.
--
-- THE DISCRIMINATOR: claim_method is null AND school_email_verified_at is
-- not null AND cohort_id is null. See Global Constraints for why all three
-- clauses are load-bearing — in particular, why cohort_id is null is what
-- keeps every existing seeded fixture out of this branch.
--
-- 0040's stored-programme-match guard moves into the else branch unchanged
-- — it already no-ops correctly for a still-unclaimed Flow 2 account
-- (programme_id is null until commit_school_identity writes it), so it was
-- never wrong, just insufficient on its own: it checks what's ALREADY
-- STORED, and a Flow 2 account has nothing stored yet. commit_school_identity
-- has its own separate programme-match check (§1 above), against the
-- DERIVED programme_id — the two guards are not redundant, they check
-- different data at different moments.
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
  v_student           users;
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

  select * into v_student from users where id = v_student_id;

  if v_student.role is distinct from 'student' then
    raise exception
      'User % is a % and cannot be admitted by join request. A class rep must be '
      'demoted by their faculty rep before changing cohorts, so that every role '
      'change still originates top-down.',
      v_student_id, v_student.role
      using errcode = 'P0001';
  end if;

  if v_student.claim_method is null
     and v_student.school_email_verified_at is not null
     and v_student.cohort_id is null then
    perform commit_school_identity(v_student_id, v_cohort_id, p_decided_by);
  else
    v_student_programme := v_student.programme_id;
    select programme_id into v_cohort_programme from cohorts where id = v_cohort_id;

    if v_student_programme is not null
       and v_student_programme is distinct from v_cohort_programme then
      raise exception
        'This student''s programme does not match this cohort''s programme — approval refused';
    end if;
  end if;

  update cohort_join_requests
  set status = 'approved', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;

  update users set cohort_id = v_cohort_id where id = v_student_id;

  perform sync_roster_placement(v_student_id, v_cohort_id, p_decided_by, 'join_request_approved');
end;
$$;
