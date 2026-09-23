-- ============================================================================
-- 0052: resolve_identity_dispute — the replacement for resolve_roster_dispute
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5 step 4's escalation had no landing pad: a faculty
-- rep who decides a disputed account's self-typed (Flow 1) identity facts
-- were wrong has no RPC to act on that decision. This is it.
--
-- Clears claim_method, programme_id, self_sponsored, student_number,
-- admission_year -- dropping the account out of 'provisional' so
-- claim_identity_personal (0040) will accept a fresh claim with corrected
-- data. Does NOT clear cohort_id: this account did not lose its identity to
-- anyone who proved a better claim (that is link_school_email_identity's
-- takeover branch, 0045) -- a rep simply decided the self-typed data can't
-- be trusted yet, and ejecting a student from a cohort they may legitimately
-- belong to is a real, visible consequence with no automatic path back. If
-- the dispute also involves the wrong programme, claim_identity_personal's
-- own existing guard (cohort_id is not null -> programme must match) catches
-- that on the retry.
--
-- Any faculty_rep may call this, not scoped to one faculty. A disputed
-- account's cohort_id, when set, does not necessarily belong to the
-- resolving rep's own faculty -- the student could be sitting in any
-- faculty's cohort. Resolving a dispute is a manual, out-of-band
-- investigation, not an automated decision, so any faculty rep is trusted to
-- carry it out regardless of which faculty the account currently touches.
create or replace function resolve_identity_dispute(
  p_user_id  uuid,
  p_actor_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role uuid;
  v_target     users;
begin
  if p_actor_id is distinct from auth.uid() then
    raise exception 'p_actor_id must match the calling user';
  end if;

  if not exists (select 1 from users where id = p_actor_id and role = 'faculty_rep') then
    raise exception 'Only a faculty_rep may resolve an identity dispute';
  end if;

  select * into v_target from users where id = p_user_id;

  if v_target.id is null then
    raise exception 'User % not found', p_user_id;
  end if;

  if v_target.claim_method = 'oauth' then
    raise exception
      'User % is already oauth-verified — this function is for resolving a disputed provisional claim, not for clearing a proven identity',
      p_user_id;
  end if;

  update users
  set claim_method   = null,
      programme_id   = null,
      self_sponsored = null,
      student_number = null,
      admission_year = null
  where id = p_user_id;

  insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
  values (
    coalesce(reg_number_from_email(v_target.school_email), 'unknown'),
    'dispute_resolved', p_actor_id, p_user_id,
    jsonb_build_object(
      'previous_claim_method',   v_target.claim_method,
      'previous_student_number', v_target.student_number
    )
  );
end;
$$;

comment on function resolve_identity_dispute(uuid, uuid) is
  'AUTH_FLOW_REFACTOR.md §5 step 4''s escalation, resolved: a faculty rep '
  'clears a disputed account''s self-typed identity facts (never cohort_id) '
  'so the student can redo claim_identity_personal with corrected data and '
  'retry link_school_email_identity. Replaces resolve_roster_dispute, '
  'retired in this plan (task 7) along with the roster it operated on.';

revoke execute on function resolve_identity_dispute(uuid, uuid) from public, anon;
grant  execute on function resolve_identity_dispute(uuid, uuid) to authenticated, service_role;
