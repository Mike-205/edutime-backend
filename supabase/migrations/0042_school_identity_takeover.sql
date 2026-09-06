-- ============================================================================
-- 0042: Flow 2 — commit_school_identity gains the takeover path
-- ============================================================================
-- Part 3 of 5. Completes AUTH_FLOW_REFACTOR.md §4 step 5: if the derived
-- student_number is already held by a provisional account, approving THIS
-- request must evict that holder (not fail with a raw constraint violation,
-- 0041's accepted interim state) — unless the holder is already oauth
-- (a red flag, not a routine outcome: two proven school addresses cannot
-- legitimately derive the same number, so this refuses and escalates rather
-- than picking a winner) or holds scheduling authority (never auto-evict a
-- class rep; escalate to a faculty rep instead, mirroring claim_roster_row's
-- own third gate, 0019).
--
-- Gate re-hosting from claim_roster_row (0019, ~lines 185-205), per
-- AUTH_FLOW_REFACTOR.md §4 step 5: of its four checks, two re-host onto
-- users columns (existing claim? -> student_number lookup; is it already
-- oauth? -> claim_method), one is unchanged (class_rep? -> users.role), and
-- one does not apply here at all — "is the incoming claim not oauth" exists
-- in the old function because ONE function serves both the password and
-- OAuth branches; commit_school_identity is only ever reached via a proven
-- school email (Flow 2 is oauth-only by construction), so that gate would
-- never fire and is deliberately not reproduced.
--
-- ORDERING MATTERS: the evicted account's student_number is nulled in a
-- separate, earlier UPDATE than the incoming account's write. Both cannot
-- hold the same value at once under users_student_number_unique (0037), so
-- the only way to move the number from one row to the other is to clear the
-- old row first.
--
-- Eviction resets reg_number too, not just the four new identity fields —
-- AUTH_FLOW_REFACTOR.md §4 step 5 says so explicitly ("reg_number/the four
-- identity fields, and cohort_id"), and reg_number is still live on legacy
-- accounts until Plan 5 retires it.
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
  v_existing          users;
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

  select * into v_existing
  from users
  where student_number = v_derived.student_number and id != p_student_id;

  if v_existing.id is not null then
    if v_existing.claim_method = 'oauth' then
      raise exception
        'Two proven school-email accounts derive the same student number. This '
        'cannot happen under correct operation and needs a faculty rep to '
        'investigate before either account is touched.';
    end if;

    if v_existing.role = 'class_rep' then
      raise exception
        'That identity is held by an account with scheduling authority. A '
        'faculty rep must resolve this.';
    end if;

    update users
    set reg_number     = null,
        programme_id   = null,
        self_sponsored = null,
        student_number = null,
        admission_year = null,
        claim_method   = null,
        cohort_id      = null
    where id = v_existing.id;

    insert into notifications (user_id, event_id, title, message, type)
    values (
      v_existing.id, null,
      'Your account has been unlinked',
      'The university account for this registration number signed in, so the '
      || 'identity has moved to it. If you believe this is wrong, contact your faculty rep.',
      'account_taken_over'
    );

    insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
    values (
      null, v_reg, 'takeover', p_actor_id, v_existing.id,
      jsonb_build_object('from_method', v_existing.claim_method, 'to_method', 'oauth')
    );
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
    null, v_reg, 'claimed', p_actor_id, p_student_id,
    jsonb_build_object('method', 'oauth', 'cohort_id', p_cohort_id)
  );
end;
$$;

comment on function commit_school_identity(uuid, uuid, uuid) is
  'Flow 2 (AUTH_FLOW_REFACTOR.md §4): derives a student''s identity facts '
  'from their proven school_email and commits them as claim_method = oauth, '
  'at approval time, evicting any provisional holder of the same '
  'student_number first (never an oauth holder, never a class rep — both '
  'escalate to a faculty rep instead). Internal only, called by '
  'approve_cohort_join_request.';

revoke execute on function commit_school_identity(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
