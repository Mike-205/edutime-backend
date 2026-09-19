-- ============================================================================
-- 0046: link_personal_email_identity — §6
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §6: any claim_method = 'oauth' account can link a
-- personal Google identity as a recovery contact for after the school
-- address stops resolving (graduation, withdrawal). Unconditional by
-- design — no rep, no derivation, no identity field touched — because a
-- personal address carries no identity claim to check against.
--
-- Scoped to claim_method = 'oauth' only. Old-system (roster/password)
-- accounts already have an entirely separate recovery-email mechanism
-- (0031: user_recovery_email, set_recovery_email/verify_recovery_email)
-- that this plan does not touch.
--
-- Re-linking a different address OVERWRITES personal_email rather than
-- refusing (explicit product decision, this plan's brainstorming) --
-- linkIdentity() never removes the superseded identity from
-- auth.identities, only the users.personal_email pointer moves, and the
-- previous address is captured in the audit row's snapshot so a faculty
-- rep has something to check if it's ever disputed.
--
-- reg_number for the audit row: users.reg_number stays null for every
-- new-system account (Flow 1 and Flow 2 alike; only the old roster path
-- ever wrote it), so it cannot be used here. Every oauth account has a
-- non-null school_email by construction (Flow 2 signup, or a completed §5
-- link) -- reg_number_from_email(v_user.school_email) is what every other
-- writer in this schema uses for exactly this reason.
-- ============================================================================
create or replace function link_personal_email_identity(p_actor_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user      users;
  v_new_email text;
  v_reg       text;
begin
  if p_actor_id is distinct from auth.uid() then
    raise exception 'p_actor_id must match the calling user';
  end if;

  select * into v_user from users where id = p_actor_id;

  if v_user.id is null then
    raise exception 'Acting user % not found', p_actor_id;
  end if;

  if v_user.claim_method is distinct from 'oauth' then
    raise exception
      'Only a school-email-verified account can link a personal email as a recovery contact';
  end if;

  select email into v_new_email
  from auth.identities
  where user_id = p_actor_id and not is_school_email(email)
  order by created_at desc
  limit 1;

  if v_new_email is null then
    raise exception 'No linked personal-email identity was found for this account';
  end if;

  v_reg := reg_number_from_email(v_user.school_email);

  update users
  set personal_email             = v_new_email,
      personal_email_verified_at = now()
  where id = p_actor_id;

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    null, v_reg, 'identity_linked', p_actor_id, p_actor_id,
    jsonb_build_object(
      'linked', 'personal_email',
      'previous_personal_email', v_user.personal_email,
      'new_personal_email', v_new_email
    )
  );
end;
$$;

comment on function link_personal_email_identity(uuid) is
  'AUTH_FLOW_REFACTOR.md §6: a claim_method = oauth account links a personal '
  'Google identity as a post-graduation recovery contact. Unconditional -- '
  'no rep, no derivation. Re-linking a different address overwrites '
  'personal_email; the superseded address is preserved in the audit row''s '
  'snapshot. Called by the client immediately after linkIdentity() '
  'succeeds.';

revoke execute on function link_personal_email_identity(uuid) from public, anon;
grant  execute on function link_personal_email_identity(uuid) to authenticated, service_role;
