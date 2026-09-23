-- ============================================================================
-- 0047: promote_class_rep reads users.claim_method; seed data gets real
-- new-system identities
-- ============================================================================
-- promote_class_rep (0022) has read claim_method off student_roster since it
-- was written, because that was the only place it lived. Plans 1-4 moved
-- claim_method onto users itself; student_roster is retiring in this plan
-- (Task 7). The fix is a one-line source change, not a behavior change: the
-- attestation rule (0.5) is unchanged, only where the claim_method comes
-- from.
create or replace function promote_class_rep(
  p_user_id            uuid,
  p_rank               class_rep_rank,
  p_acting_faculty_rep uuid,
  p_identity_attested  boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role    user_role;
  v_actor_faculty uuid;
  v_target_role   user_role;
  v_target_cohort uuid;
  v_target_faculty uuid;
  v_target_name   text;
  v_existing_reps int;
  v_rank_holder   uuid;
  v_claim         claim_method;
begin
  if p_acting_faculty_rep is distinct from auth.uid() then
    raise exception 'p_acting_faculty_rep must match the calling user';
  end if;

  select role, faculty_id into v_actor_role, v_actor_faculty
  from users where id = p_acting_faculty_rep;

  if v_actor_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may promote a class rep';
  end if;

  if v_actor_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot promote anyone';
  end if;

  select u.role, u.cohort_id, d.faculty_id, u.first_name || ' ' || u.last_name, u.claim_method
  into v_target_role, v_target_cohort, v_target_faculty, v_target_name, v_claim
  from users u
  left join cohorts c     on c.id = u.cohort_id
  left join programmes p  on p.id = c.programme_id
  left join departments d on d.id = p.department_id
  where u.id = p_user_id;

  if v_target_role is null then
    raise exception 'User % not found', p_user_id;
  end if;

  if v_target_cohort is null then
    raise exception 'User % is not in a cohort and cannot be a class rep', p_user_id;
  end if;

  if v_target_faculty is distinct from v_actor_faculty then
    raise exception 'User % is in another faculty', p_user_id;
  end if;

  if v_target_role is distinct from 'student' then
    raise exception
      'User % is a % — only a student can be promoted to class rep', p_user_id, v_target_role;
  end if;

  select count(*)::int into v_existing_reps
  from users
  where cohort_id = v_target_cohort and role = 'class_rep' and id <> p_user_id;

  if v_existing_reps >= 2 then
    raise exception
      'Cohort % already has 2 class reps — demote one before promoting another',
      v_target_cohort;
  end if;

  select id into v_rank_holder
  from users
  where cohort_id = v_target_cohort
    and role = 'class_rep'
    and class_rep_rank = p_rank
    and id <> p_user_id
  limit 1;

  if v_rank_holder is not null then
    raise exception
      'Cohort % already has a % class rep (user %)', v_target_cohort, p_rank, v_rank_holder;
  end if;

  -- --- The attestation (TODO §0.5) -----------------------------------------
  -- Same rule, new source: v_claim now comes from users.claim_method
  -- (fetched above, alongside the target's role/cohort/faculty), not from a
  -- student_roster row. student_roster retires in Task 7 of this plan.
  if v_claim is distinct from 'oauth' and not coalesce(p_identity_attested, false) then
    raise exception
      'User % has not proved their identity with a university email (%). Promote '
      'them only after physically verifying who they are, and pass '
      'p_identity_attested => true to record that you did.',
      p_user_id, coalesce(v_claim::text, 'no roster claim');
  end if;

  update users
  set role = 'class_rep', class_rep_rank = p_rank
  where id = p_user_id;

  insert into role_audit_log (user_id, user_name, cohort_id, action, new_rank, actor_id, snapshot)
  values (
    p_user_id, v_target_name, v_target_cohort, 'promoted', p_rank, p_acting_faculty_rep,
    jsonb_build_object(
      'identity_attested', coalesce(p_identity_attested, false),
      'claim_method',      v_claim,
      'previous_role',     v_target_role
    )
  );
end;
$$;
