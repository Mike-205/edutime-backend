-- ============================================================================
-- 0045: link_school_email_identity — §5
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5: a Flow 1 (provisional) student links a school
-- Google identity to the account they already have, instead of signing up a
-- second time. handle_new_auth_user() (0002/0039) only fires on INSERT INTO
-- auth.users and a linked identity is not a new row, so this is its own RPC,
-- called by the client right after linkIdentity() succeeds.
--
-- The newly-linked address is found by querying auth.identities directly
-- (its email column is generated: lower(identity_data ->> 'email')) rather
-- than trusting anything passed in by the client — the same principle
-- 0019/0039 already apply to auth.users.email.
--
-- Match/mismatch/takeover gates mirror commit_school_identity (0041/0042)
-- closely enough that reading that function alongside this one is the
-- fastest way to see what's the same and what's different:
--   - commit_school_identity compares the DERIVED identity against a
--     COHORT's programme_id, at approval time.
--   - link_school_email_identity compares the DERIVED identity against
--     this SAME ROW's already-STORED (self-typed, Flow 1) identity, at
--     link time — there is no cohort in play here at all.
-- The takeover sub-branch (mismatch AND the derived number is already held
-- by someone else) is otherwise identical: evict unless the holder is
-- already oauth (a red flag, escalate) or a class_rep (never auto-evict
-- scheduling authority, escalate instead).
-- ============================================================================
create or replace function link_school_email_identity(p_actor_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user      users;
  v_new_email text;
  v_reg       text;
  v_derived   reg_number_parts;
  v_existing  users;
begin
  if p_actor_id is distinct from auth.uid() then
    raise exception 'p_actor_id must match the calling user';
  end if;

  select * into v_user from users where id = p_actor_id;

  if v_user.id is null then
    raise exception 'Acting user % not found', p_actor_id;
  end if;

  if v_user.claim_method is distinct from 'provisional' then
    raise exception
      'Only a provisional-claim account can link a school email this way';
  end if;

  select email into v_new_email
  from auth.identities
  where user_id = p_actor_id and is_school_email(email)
  order by created_at desc
  limit 1;

  if v_new_email is null then
    raise exception 'No linked school-email identity was found for this account';
  end if;

  v_reg     := reg_number_from_email(v_new_email);
  v_derived := parse_reg_number(v_reg);

  if v_derived.programme_id is null then
    raise exception
      'Could not derive a student identity from this school email. A faculty rep must resolve this.';
  end if;

  if v_derived.programme_id       is distinct from v_user.programme_id
     or v_derived.is_self_sponsored is distinct from v_user.self_sponsored
     or v_derived.student_number    is distinct from v_user.student_number
     or v_derived.admission_year    is distinct from v_user.admission_year
  then
    select * into v_existing
    from users
    where student_number = v_derived.student_number and id != p_actor_id;

    if v_existing.id is null then
      raise exception
        'The identity derived from this account''s linked school email does not '
        'match what was recorded at signup. A faculty rep must resolve this before '
        'the school email can be confirmed.';
    end if;

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
  set school_email             = v_new_email,
      school_email_verified_at = now(),
      programme_id             = v_derived.programme_id,
      self_sponsored           = v_derived.is_self_sponsored,
      student_number           = v_derived.student_number,
      admission_year           = v_derived.admission_year,
      claim_method             = 'oauth'
  where id = p_actor_id;

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    null, v_reg, 'identity_linked', p_actor_id, p_actor_id,
    jsonb_build_object('linked', 'school_email', 'previous_claim_method', v_user.claim_method)
  );
end;
$$;

comment on function link_school_email_identity(uuid) is
  'AUTH_FLOW_REFACTOR.md §5: a provisional (Flow 1) account links a school '
  'Google identity to the account it already has. Match upgrades in place; '
  'mismatch escalates to a faculty rep unless the derived number is already '
  'held by an evictable (provisional, non-class_rep) account, in which case '
  'this account wins the takeover, same shape as commit_school_identity '
  '(0041/0042). Called by the client immediately after linkIdentity() '
  'succeeds.';

revoke execute on function link_school_email_identity(uuid) from public, anon;
grant  execute on function link_school_email_identity(uuid) to authenticated, service_role;
