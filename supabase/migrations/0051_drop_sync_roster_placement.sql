-- Task 5: Drop sync_roster_placement and its two call sites
-- The function is now a no-op (its first check fires for all accounts after Task 1)

-- ============================================================================
-- 1. Redefine create_cohort_with_class_rep without sync_roster_placement call
-- ============================================================================
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
  set cohort_id      = v_cohort_id,
      programme_id   = p_programme_id,
      role           = 'class_rep',
      class_rep_rank = 'primary'
  where id = p_first_rep_id;

  return v_cohort_id;
end;
$$;


-- ============================================================================
-- 2. Redefine approve_cohort_join_request without sync_roster_placement call
-- ============================================================================
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
end;
$$;


-- ============================================================================
-- 3. Drop the now-unused functions
-- ============================================================================
drop function sync_roster_placement(uuid, uuid, uuid, text);
drop function roster_placement_divergences();
