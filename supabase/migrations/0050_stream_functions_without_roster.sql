-- ============================================================================
-- 0050: Stream functions without the roster
-- ============================================================================
-- create_cohort_stream's only dependency on student_roster was a side effect
-- (moving the first rep's roster row to follow them into the stream, and
-- logging that move) -- everything else it does (writing cohorts, users,
-- role_audit_log) is untouched. Stripped, not dropped: splitting a cohort
-- into streams survives this plan.
--
-- assign_students_to_streams and cohort_unstreamed_members are rewritten,
-- not dropped: bulk-moving already-placed students between streams, and
-- reporting who hasn't been moved, are real functionality this project's
-- owner built deliberately (0028) because cohorts can have streams and
-- something has to populate them -- not a speculative feature with no
-- consumer. Only the input changes: keyed on users.student_number instead
-- of student_roster.reg_number, since that is the identity anchor the new
-- system actually has. The one capability that does NOT survive, under any
-- design: assigning a student who has not signed up yet. There is no row
-- for them anywhere in the new system until they do.
create or replace function create_cohort_stream(
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
  v_upcoming       int;
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

  select count(*)::int into v_upcoming
  from event_cohorts ec
  join events e on e.id = ec.event_id
  where ec.cohort_id = p_parent_cohort_id
    and e.status in ('scheduled', 'proposed')
    and e.start_time > now();

  if v_upcoming > 0 then
    raise exception
      'Cohort % has % upcoming lecture(s). Split it before its schedule is '
      'entered, or cancel those lectures first — a split does not move them, '
      'because each stream needs its own room and time.',
      p_parent_cohort_id, v_upcoming;
  end if;

  v_stream := nullif(btrim(coalesce(p_stream, '')), '');
  if v_stream is null then
    raise exception 'A stream needs a label (''A'', ''B'', ...)';
  end if;

  select u.role, u.cohort_id, u.first_name || ' ' || u.last_name
  into v_rep_role, v_rep_cohort, v_rep_name
  from users u where u.id = p_first_rep_id;

  if v_rep_role is null then
    raise exception 'User % not found — cannot make them this stream''s class rep',
      p_first_rep_id;
  end if;

  if v_rep_cohort is distinct from p_parent_cohort_id then
    raise exception
      'User % is not in cohort % — a stream''s first rep must come from the cohort being split',
      p_first_rep_id, p_parent_cohort_id;
  end if;

  if v_rep_role not in ('student', 'class_rep') then
    raise exception
      'User % is a % — only a student or a sitting class_rep of this cohort can lead a stream',
      p_first_rep_id, v_rep_role;
  end if;

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


-- ============================================================================
-- assign_students_to_streams — rewritten onto users.student_number
-- ============================================================================
create or replace function assign_students_to_streams(
  p_assignments      jsonb,   -- [{"student_number": "67312", "stream": "A"}, ...]
  p_parent_cohort_id uuid,
  p_acting_user      uuid
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role     user_role;
  v_actor_faculty  uuid;
  v_parent         record;
  v_parent_faculty uuid;
  v_count          int := 0;
  v_distinct       int;
  v_total          int;
  v_bad            int;
  v_row            record;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, faculty_id into v_actor_role, v_actor_faculty
  from users where id = p_acting_user;

  if v_actor_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may assign students to streams';
  end if;

  if v_actor_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot assign students';
  end if;

  select c.id, c.programme_id, c.parent_cohort_id into v_parent
  from cohorts c where c.id = p_parent_cohort_id;

  if v_parent.id is null then
    raise exception 'Cohort % does not exist', p_parent_cohort_id;
  end if;

  if v_parent.parent_cohort_id is not null then
    raise exception
      'Cohort % is a stream. Assign students against the cohort being split, not one of its streams',
      p_parent_cohort_id;
  end if;

  select d.faculty_id into v_parent_faculty
  from programmes p
  join departments d on d.id = p.department_id
  where p.id = v_parent.programme_id;

  if v_parent_faculty is distinct from v_actor_faculty then
    raise exception 'Cohort % belongs to another faculty', p_parent_cohort_id;
  end if;

  if p_assignments is null or jsonb_typeof(p_assignments) is distinct from 'array' then
    raise exception
      'p_assignments must be a JSON array of {"student_number": ..., "stream": ...} objects';
  end if;

  select count(*)::int,
         count(distinct student_number)::int,
         count(*) filter (where student_number is null or stream is null)::int
  into v_total, v_distinct, v_bad
  from (
    select nullif(btrim(coalesce(a ->> 'student_number', '')), '') as student_number,
           nullif(btrim(coalesce(a ->> 'stream', '')), '') as stream
    from jsonb_array_elements(p_assignments) a
  ) t;

  if v_total = 0 then
    raise exception 'p_assignments is empty — nothing to assign';
  end if;

  if v_bad > 0 then
    raise exception 'Every assignment needs both a student_number and a stream';
  end if;

  if v_distinct <> v_total then
    raise exception
      'A student number appears more than once in p_assignments — each student belongs to exactly one stream';
  end if;

  -- --- Move ------------------------------------------------------------------
  -- The join replaces "is on the roster" with "has an account with this
  -- student number" -- a student who never signed up simply is not found,
  -- and the from_cohort_id check below catches that the same way it catches
  -- an account that exists but is not in this cohort or one of its streams.
  for v_row in
    select a.student_number,
           a.stream,
           s.id  as stream_id,
           r.id  as account_id,
           r.cohort_id  as from_cohort_id,
           r.role
    from (
           select nullif(btrim(coalesce(x ->> 'student_number', '')), '') as student_number,
                  nullif(btrim(coalesce(x ->> 'stream', '')), '') as stream
           from jsonb_array_elements(p_assignments) x
         ) a
    left join cohorts s
           on s.parent_cohort_id = p_parent_cohort_id and s.stream = a.stream
    left join users r
           on r.student_number = a.student_number
  loop
    if v_row.stream_id is null then
      raise exception
        'Cohort % has no stream %. Create it with create_cohort_stream first',
        p_parent_cohort_id, v_row.stream;
    end if;

    -- The account must already belong to this cohort, or to one of its
    -- streams (so a student can be moved from Stream A to Stream B).
    -- Anything else -- including no matching account at all, since a null
    -- join produces a null from_cohort_id that never matches -- would be
    -- reaching into another cohort's students through a stream assignment,
    -- the sideways-authority shape TECHNICAL_DISCOVERY §13.4 warns about.
    if v_row.from_cohort_id is distinct from p_parent_cohort_id
       and not exists (
         select 1 from cohorts c
         where c.id = v_row.from_cohort_id
           and c.parent_cohort_id = p_parent_cohort_id
       )
    then
      raise exception
        'No account with student number % is in cohort % or any of its streams',
        v_row.student_number, p_parent_cohort_id;
    end if;

    -- A class rep's placement is set by create_cohort_stream, promote_class_rep
    -- and demote_class_rep, never here. Moving one in bulk could silently
    -- collide with users_one_primary_per_cohort, and would change who holds
    -- scheduling authority over a stream as a side effect of a bulk batch.
    if v_row.role = 'class_rep' then
      raise exception
        'Student number % belongs to a class rep. Move a rep with '
        'create_cohort_stream or demote them first — not through a bulk assignment',
        v_row.student_number;
    end if;

    update users set cohort_id = v_row.stream_id where id = v_row.account_id;

    -- reg_number here is the bare student_number, not a full slash-form
    -- string, unlike every other writer of identity_audit_log -- this
    -- function's input is a bare student number, and deriving the full
    -- form would mean re-composing it from programme code + admission year
    -- inline for an audit field with no downstream reader that needs the
    -- exact format. Not worth building.
    insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
    values (
      v_row.student_number, 'reassigned', p_acting_user, v_row.account_id,
      jsonb_build_object(
        'from_cohort_id', v_row.from_cohort_id,
        'to_cohort_id',   v_row.stream_id,
        'stream',         v_row.stream,
        'reason',         'stream_assignment'
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function assign_students_to_streams(jsonb, uuid, uuid) is
  'Moves named students into streams of the given cohort, by student_number '
  '(0037''s identity anchor, not student_roster''s reg_number -- the roster '
  'retired in plan 5/5). Faculty rep, own faculty only. A student who has '
  'not signed up yet cannot be assigned -- there is no row for them until '
  'they do.';


-- ============================================================================
-- cohort_unstreamed_members — rewritten onto users
-- ============================================================================
-- DROP first, not CREATE OR REPLACE: the return shape changes (no more
-- `claimed` column), and Postgres refuses to CREATE OR REPLACE a function
-- whose OUT-parameter row type differs from the one already on file.
-- Nothing else in the schema references this function by name, so dropping
-- it has no fallout to chase.
drop function cohort_unstreamed_members(uuid);

create function cohort_unstreamed_members(p_cohort_id uuid)
returns table (
  student_number text,
  full_name      text
)
language sql
stable
security definer
set search_path = public
as $$
  select u.student_number,
         u.first_name || ' ' || coalesce(u.middle_name || ' ', '') || u.last_name
  from users u
  where u.cohort_id = p_cohort_id
    and exists (select 1 from cohorts c where c.parent_cohort_id = p_cohort_id)
  order by u.student_number;
$$;

comment on function cohort_unstreamed_members(uuid) is
  'Accounts still sitting on a cohort that has streams -- i.e. students who '
  'have not been assigned to one yet. Empty for a cohort that was never '
  'split. No claimed/unclaimed distinction any more -- every row here is a '
  'real account, since there is no pre-signup roster to hold anyone else.';

revoke execute on function assign_students_to_streams(jsonb, uuid, uuid) from public, anon;
grant  execute on function assign_students_to_streams(jsonb, uuid, uuid) to authenticated, service_role;

revoke execute on function cohort_unstreamed_members(uuid) from public, anon;
grant  execute on function cohort_unstreamed_members(uuid) to authenticated, service_role;
