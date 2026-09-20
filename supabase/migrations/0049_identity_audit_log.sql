-- ============================================================================
-- 0049: identity_audit_log replaces roster_audit_log
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §8: "roster audit log" stops describing what it
-- holds once there is no roster. Two changes here, not three: rename the
-- table, and drop roster_id (nothing left for it to point at once
-- student_roster retires, Task 7 of this plan). Done here, ahead of the
-- student_roster drop, because dropping roster_id's FK does not require
-- student_roster to be gone first -- doing it now means the student_roster
-- drop never has to touch this table at all.
--
-- THE ENUM IS DELIBERATELY NOT TOUCHED IN THIS MIGRATION. roster_audit_action
-- already contains every value every writer -- old system or new -- needs:
-- created, updated, removed, claimed, takeover, unbound, dispute_resolved,
-- reassigned, identity_linked (reassigned and identity_linked were added by
-- 0027 and 0044). Narrowing it to drop 'created'/'updated'/'removed' cannot
-- happen until roster_add_student, roster_bulk_import, roster_correct_student
-- and roster_remove_student -- the only writers of those three values -- are
-- themselves dropped, which is Task 7 of this plan, not this one. Rebuilding
-- the enum now would break those four still-live functions immediately.
alter table roster_audit_log rename to identity_audit_log;
alter table identity_audit_log drop column roster_id;

comment on table identity_audit_log is
  'The entire record of every identity trust decision the system makes -- '
  'renamed from roster_audit_log (AUTH_FLOW_REFACTOR.md §8) once there was '
  'no roster left for that name to describe. Denormalized: reg_number is '
  'stored as its own plain text value, not derived by joining elsewhere, so '
  'the trail survives whatever it is about being changed or removed. The '
  'action enum (roster_audit_action) is not renamed or narrowed here -- it '
  'still backs both this table''s new-system writers and the old-system '
  'roster-row-edit functions Task 7 of this plan has not yet retired.';


-- ============================================================================
-- All twelve live writers, updated to the new table shape
-- ============================================================================
-- Bodies otherwise byte-identical to their current, live definitions --
-- confirmed by re-reading each source migration immediately before writing
-- this file. Only the audit INSERT statements change: the table name, and
-- dropping roster_id from the column list and its corresponding value (it is
-- gone). Nothing else about any function's logic changes.

-- --- from 0017_roster_and_identity.sql --------------------------------------

-- Single-row add. The class-rep-reachable path.
create or replace function roster_add_student(
  p_reg_number  text,
  p_first_name  text,
  p_last_name   text,
  p_middle_name text,
  p_cohort_id   uuid,
  p_acting_user uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm      text;
  v_roster_id uuid;
begin
  perform roster_assert_may_write(p_cohort_id, p_reg_number, p_acting_user);

  v_norm := normalize_reg_number(p_reg_number);

  if coalesce(trim(p_first_name), '') = '' or coalesce(trim(p_last_name), '') = '' then
    raise exception 'First and last name are required';
  end if;

  insert into student_roster (
    reg_number, first_name, last_name, middle_name, cohort_id, added_by
  )
  values (
    v_norm, trim(p_first_name), trim(p_last_name), nullif(trim(p_middle_name), ''),
    p_cohort_id, p_acting_user
  )
  returning id into v_roster_id;

  insert into identity_audit_log (reg_number, action, actor_id, snapshot)
  values (
    v_norm, 'created', p_acting_user,
    jsonb_build_object('cohort_id', p_cohort_id, 'source', 'single')
  );

  return v_roster_id;
exception
  when unique_violation then
    -- Deliberately does not say which cohort already holds it. A rep learning
    -- "that number is registered elsewhere" is fine; learning where is a small
    -- cross-faculty information leak for no operational gain.
    raise exception 'Registration number % is already on the roster', v_norm;
end;
$$;

-- Bulk import. Faculty rep and superadmin only.
--
-- p_rows is a jsonb array of {reg_number, first_name, last_name, middle_name}.
-- All-or-nothing: the whole call is one transaction, so a single bad row aborts
-- the import with the offending registration number named. A half-loaded
-- roster is worse than a clear error, and the rep would have no way to tell
-- which half landed.
create or replace function roster_bulk_import(
  p_rows        jsonb,
  p_cohort_id   uuid,
  p_acting_user uuid
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role   user_role;
  v_row    jsonb;
  v_norm   text;
  v_id     uuid;
  v_count  int := 0;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role into v_role from users where id = p_acting_user;

  -- Explicit, ahead of the shared gate, so a class rep gets a message that
  -- explains the rule rather than a generic scoping refusal. Unchecked bulk
  -- import by a class rep would collapse the roster's authority back onto the
  -- class rep, which is the thing it exists to move away from.
  if v_role = 'class_rep' then
    raise exception
      'Bulk import is a faculty_rep action. A class_rep may add students one at a time.';
  end if;

  if v_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may bulk import roster rows';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a jsonb array';
  end if;

  if jsonb_array_length(p_rows) = 0 then
    raise exception 'p_rows must contain at least one student';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    perform roster_assert_may_write(
      p_cohort_id, v_row ->> 'reg_number', p_acting_user
    );

    v_norm := normalize_reg_number(v_row ->> 'reg_number');

    if coalesce(trim(v_row ->> 'first_name'), '') = ''
       or coalesce(trim(v_row ->> 'last_name'), '') = '' then
      raise exception 'Row for % is missing a first or last name', v_norm;
    end if;

    begin
      insert into student_roster (
        reg_number, first_name, last_name, middle_name, cohort_id, added_by
      )
      values (
        v_norm,
        trim(v_row ->> 'first_name'),
        trim(v_row ->> 'last_name'),
        nullif(trim(v_row ->> 'middle_name'), ''),
        p_cohort_id,
        p_acting_user
      )
      returning id into v_id;
    exception
      when unique_violation then
        raise exception 'Registration number % is already on the roster', v_norm;
    end;

    insert into identity_audit_log (reg_number, action, actor_id, snapshot)
    values (
      v_norm, 'created', p_acting_user,
      jsonb_build_object('cohort_id', p_cohort_id, 'source', 'bulk')
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Correct a row. A mistyped digit locks a real student out with no
-- self-service fix, so this has to exist and has to be reachable by the rep
-- who made the typo.
--
-- Only while UNCLAIMED. Once an account is bound, changing the number or the
-- person underneath it is an identity change, not a correction — that goes
-- through 0019's dispute resolution, with a faculty rep and an audit row.
create or replace function roster_correct_student(
  p_roster_id   uuid,
  p_reg_number  text,
  p_first_name  text,
  p_last_name   text,
  p_middle_name text,
  p_acting_user uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing student_roster;
  v_norm     text;
begin
  select * into v_existing from student_roster where id = p_roster_id;

  if v_existing.id is null then
    raise exception 'Roster row % does not exist', p_roster_id;
  end if;

  if v_existing.claimed_by is not null then
    raise exception
      'Roster row % is already claimed — corrections to a claimed identity go through a faculty rep',
      p_roster_id;
  end if;

  -- Re-gated against the NEW number: correcting EB1/.../23 into EB3/.../23
  -- would otherwise walk the row out of the rep's scope.
  perform roster_assert_may_write(v_existing.cohort_id, p_reg_number, p_acting_user);

  v_norm := normalize_reg_number(p_reg_number);

  if coalesce(trim(p_first_name), '') = '' or coalesce(trim(p_last_name), '') = '' then
    raise exception 'First and last name are required';
  end if;

  update student_roster
  set reg_number  = v_norm,
      first_name  = trim(p_first_name),
      last_name   = trim(p_last_name),
      middle_name = nullif(trim(p_middle_name), ''),
      updated_at  = now()
  where id = p_roster_id;

  insert into identity_audit_log (reg_number, action, actor_id, snapshot)
  values (
    v_norm, 'updated', p_acting_user,
    jsonb_build_object(
      'from', jsonb_build_object(
        'reg_number', v_existing.reg_number,
        'first_name', v_existing.first_name,
        'last_name',  v_existing.last_name,
        'middle_name', v_existing.middle_name
      )
    )
  );
exception
  when unique_violation then
    raise exception 'Registration number % is already on the roster', v_norm;
end;
$$;

-- Remove a row. Unclaimed only, same reasoning as correction.
create or replace function roster_remove_student(
  p_roster_id   uuid,
  p_acting_user uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing student_roster;
begin
  select * into v_existing from student_roster where id = p_roster_id;

  if v_existing.id is null then
    raise exception 'Roster row % does not exist', p_roster_id;
  end if;

  if v_existing.claimed_by is not null then
    raise exception
      'Roster row % is already claimed — removing a claimed identity goes through a faculty rep',
      p_roster_id;
  end if;

  perform roster_assert_may_write(
    v_existing.cohort_id, v_existing.reg_number, p_acting_user
  );

  -- Log BEFORE the delete: roster_id is ON DELETE SET NULL, so writing the row
  -- afterwards would leave the audit entry pointing at nothing. reg_number is
  -- denormalized precisely so the trail still identifies who was removed.
  insert into identity_audit_log (reg_number, action, actor_id, snapshot)
  values (
    v_existing.reg_number, 'removed', p_acting_user,
    jsonb_build_object(
      'cohort_id',  v_existing.cohort_id,
      'first_name', v_existing.first_name,
      'last_name',  v_existing.last_name
    )
  );

  delete from student_roster where id = p_roster_id;
end;
$$;

-- --- from 0019_claim_and_takeover.sql ---------------------------------------

create or replace function claim_roster_row(
  p_reg_number  text,
  p_first_name  text,
  p_last_name   text,
  p_acting_user uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user      users;
  v_row       student_roster;
  v_existing  student_roster;
  v_norm      text;
  v_derived   text;
  v_method    claim_method;
  v_old_role  user_role;
  v_old_user  uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_user from users where id = p_acting_user;

  if v_user.id is null then
    raise exception 'Acting user % not found', p_acting_user;
  end if;

  v_norm := normalize_reg_number(p_reg_number);

  -- Idempotent re-claim, and a guard against one account collecting identities.
  select * into v_existing from student_roster where claimed_by = p_acting_user;

  if v_existing.id is not null then
    if v_existing.reg_number = v_norm then
      return v_existing.id;
    end if;
    raise exception 'This account has already claimed a different identity';
  end if;

  -- Number AND name must both match. The name is not a second factor — a
  -- classmate knows it, and on the OAuth branch below it is never consulted at
  -- all. It is here because the student typed it, so a mismatch is a signal
  -- something is wrong, and because it makes a wrong-number typo fail closed.
  select * into v_row
  from student_roster
  where reg_number = v_norm
    and lower(first_name) = lower(trim(coalesce(p_first_name, '')))
    and lower(last_name)  = lower(trim(coalesce(p_last_name, '')));

  if v_row.id is null then
    raise exception
      'We could not match those details. Check your registration number and full name with your class rep.';
  end if;

  -- How much is this account's word worth?
  if v_user.email is not null and v_user.email_verified_at is not null then
    v_derived := reg_number_from_email(v_user.email);

    -- *** THE RULE ***
    if v_derived is null or v_derived <> v_norm then
      raise exception
        'This university account does not belong to registration number %', v_norm;
    end if;

    v_method := 'oauth';
  else
    v_method := 'provisional';
  end if;

  if v_row.claimed_by is not null then
    -- An OAuth claim is provider-proven; nothing outranks it.
    if v_row.claim_method = 'oauth' then
      raise exception 'That identity has already been claimed';
    end if;

    -- Provisional cannot displace provisional — otherwise the row would just
    -- ping-pong between whoever ran the flow most recently.
    if v_method <> 'oauth' then
      raise exception 'That identity has already been claimed';
    end if;

    select role into v_old_role from users where id = v_row.claimed_by;

    -- The one case that must never be automatic. Evicting an account that
    -- holds scheduling authority would strip a cohort's rep mid-semester on a
    -- signup event, with no human in the loop. Escalate instead.
    if v_old_role = 'class_rep' then
      raise exception
        'That identity is held by an account with scheduling authority. A faculty rep must resolve this.';
    end if;

    v_old_user := v_row.claimed_by;

    -- Inert, not deleted: the account keeps its notifications and its history,
    -- and after 0014 an account with no cohort can see essentially nothing.
    -- Deleting would also hit 2.3's ON DELETE RESTRICT chain.
    update users
    set reg_number = null,
        cohort_id  = null
    where id = v_old_user;

    insert into notifications (user_id, event_id, title, message, type)
    values (
      v_old_user, null,
      'Your account has been unlinked',
      'The university account for this registration number signed in, so the '
      || 'identity has moved to it. If you believe this is wrong, contact your faculty rep.',
      'account_taken_over'
    );

    insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
    values (
      v_norm, 'takeover', p_acting_user, v_old_user,
      jsonb_build_object('from_method', v_row.claim_method, 'to_method', v_method)
    );
  end if;

  update student_roster
  set claimed_by   = p_acting_user,
      claimed_at   = now(),
      claim_method = v_method,
      updated_at   = now()
  where id = v_row.id;

  -- The roster is authoritative for the official name and the cohort. Both
  -- overwrite whatever the client passed at signup.
  update users
  set reg_number  = v_norm,
      cohort_id   = v_row.cohort_id,
      first_name  = v_row.first_name,
      last_name   = v_row.last_name,
      middle_name = v_row.middle_name
  where id = p_acting_user;

  insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
  values (
    v_norm, 'claimed', p_acting_user, p_acting_user,
    jsonb_build_object('method', v_method, 'cohort_id', v_row.cohort_id)
  );

  return v_row.id;
end;
$$;

-- The manual override, for when someone finds their identity already held.
--
-- FACULTY REP, not class rep. The class rep is inside the cohort and may be the
-- problem; the faculty rep is the trust anchor TECHNICAL_DISCOVERY §2 already
-- relies on for exactly this kind of real-world adjudication.
--
-- The verification is physical and out-of-band — the student turns up with an
-- ID card — so there is nothing to build for the reporting side. That also
-- means this function has no way to know whether the rep actually checked,
-- which is precisely why the audit row is not optional. Watch the reverse
-- abuse: someone claiming a legitimately held account is theirs.
--
-- Unbinds; it does not delete. The freed row can then be claimed normally.
create or replace function resolve_roster_dispute(
  p_roster_id          uuid,
  p_acting_faculty_rep uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role      user_role;
  v_faculty   uuid;
  v_row       student_roster;
  v_row_fac   uuid;
  v_old_user  uuid;
begin
  if p_acting_faculty_rep is distinct from auth.uid() then
    raise exception 'p_acting_faculty_rep must match the calling user';
  end if;

  select role, faculty_id into v_role, v_faculty
  from users where id = p_acting_faculty_rep;

  if v_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may resolve an identity dispute';
  end if;

  if v_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot resolve disputes';
  end if;

  select * into v_row from student_roster where id = p_roster_id;

  if v_row.id is null then
    raise exception 'Roster row % does not exist', p_roster_id;
  end if;

  if v_row.claimed_by is null then
    raise exception 'Roster row % is not claimed — there is nothing to resolve', p_roster_id;
  end if;

  select d.faculty_id into v_row_fac
  from cohorts c
  join programmes p  on p.id = c.programme_id
  join departments d on d.id = p.department_id
  where c.id = v_row.cohort_id;

  if v_row_fac is distinct from v_faculty then
    raise exception 'Roster row % belongs to another faculty', p_roster_id;
  end if;

  v_old_user := v_row.claimed_by;

  update users
  set reg_number = null,
      cohort_id  = null
  where id = v_old_user;

  update student_roster
  set claimed_by   = null,
      claimed_at   = null,
      claim_method = null,
      updated_at   = now()
  where id = p_roster_id;

  insert into notifications (user_id, event_id, title, message, type)
  values (
    v_old_user, null,
    'Your account has been unlinked',
    'A faculty rep has unlinked this account from its registration number. '
    || 'Contact them if you believe this is a mistake.',
    'identity_unbound'
  );

  insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
  values (
    v_row.reg_number, 'dispute_resolved', p_acting_faculty_rep, v_old_user,
    jsonb_build_object('previous_method', v_row.claim_method)
  );
end;
$$;

-- --- from 0028_stream_assignment.sql -----------------------------------------

-- `set search_path = public` restated — CREATE OR REPLACE discards proconfig
-- (TECHNICAL_DISCOVERY §12). Everything else is preserved from 0026 §4.
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
  v_rep_roster_id  uuid;
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

  -- --- The precondition ----------------------------------------------------
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

  -- THE REP'S ROSTER ROW FOLLOWS THEM. S.3's rule is that the roster points at
  -- the cohort a student is actually in, and a rep is no exception. Without
  -- this their roster row would say "parent" forever while they rep a stream —
  -- and there would be no way to correct it, because §2 deliberately refuses to
  -- move class reps in bulk. So the only function that may move a rep has to
  -- move both halves.
  update student_roster
  set cohort_id = v_stream_id
  where claimed_by = p_first_rep_id
  returning id into v_rep_roster_id;

  if v_rep_roster_id is not null then
    insert into identity_audit_log (
      reg_number, action, actor_id, target_user, snapshot
    )
    select r.reg_number, 'reassigned', p_acting_faculty_rep, p_first_rep_id,
           jsonb_build_object(
             'from_cohort_id', p_parent_cohort_id,
             'to_cohort_id',   v_stream_id,
             'stream',         v_stream,
             'was_claimed',    true,
             'reason',         'stream_created'
           )
    from student_roster r where r.id = v_rep_roster_id;
  end if;

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

-- Argument order and return type mirror roster_bulk_import(p_rows, p_cohort_id,
-- p_acting_user) returns int, because this is the same shape of operation: a
-- bulk roster write scoped to one cohort, performed by a faculty rep.
--
-- KEYED ON REGISTRATION NUMBER, not user id. The department's own stream lists
-- are keyed that way, and it means a student who has not signed up yet can
-- still be assigned — their roster row moves now and `claim_roster_row` will
-- place them straight into the right stream when they eventually claim. That is
-- the whole reason S.3 has the roster point at the student's real cohort rather
-- than permanently at the parent.
--
-- FACULTY REP ONLY. A class rep must not re-point roster rows in bulk — the
-- same reasoning that made roster_bulk_import faculty-rep-only in 0.5, so the
-- higher role performs the operation rather than reviewing it afterwards.
--
-- This is the CURRENT, roster-keyed version. Task 4 of this plan rewrites it
-- again in full; this create-or-replace only keeps it alive against the new
-- table shape, it does not redesign it.
create or replace function assign_students_to_streams(
  p_assignments      jsonb,   -- [{"reg_number": "EB1/67312/23", "stream": "A"}, ...]
  p_parent_cohort_id uuid,
  p_acting_user      uuid
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role    user_role;
  v_actor_faculty uuid;
  v_parent        record;
  v_parent_faculty uuid;
  v_count         int := 0;
  v_distinct      int;
  v_total         int;
  v_bad           int;
  v_row           record;
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
      'p_assignments must be a JSON array of {"reg_number": ..., "stream": ...} objects';
  end if;

  -- --- Normalize and sanity-check the batch --------------------------------
  -- A CTE rather than a temp table, deliberately. `create temp table _assign on
  -- commit drop` works exactly once per transaction: the second call in the
  -- same transaction fails with "relation already exists", because the drop
  -- does not happen until COMMIT. Since splits are incremental and a caller is
  -- expected to run this repeatedly as lists arrive — and since the whole test
  -- suite runs inside one transaction — that would have broken the normal case.
  select count(*)::int,
         count(distinct reg_number)::int,
         count(*) filter (where reg_number is null or stream is null)::int
  into v_total, v_distinct, v_bad
  from (
    select normalize_reg_number(a ->> 'reg_number') as reg_number,
           nullif(btrim(coalesce(a ->> 'stream', '')), '') as stream
    from jsonb_array_elements(p_assignments) a
  ) t;

  if v_total = 0 then
    raise exception 'p_assignments is empty — nothing to assign';
  end if;

  if v_bad > 0 then
    raise exception 'Every assignment needs both a reg_number and a stream';
  end if;

  -- A registration number listed twice, possibly against two different streams,
  -- has no defensible resolution — and silently taking either would put a
  -- student in a lecture group nobody chose for them.
  if v_distinct <> v_total then
    raise exception
      'A registration number appears more than once in p_assignments — each student belongs to exactly one stream';
  end if;

  -- --- Move ----------------------------------------------------------------
  for v_row in
    select a.reg_number,
           a.stream,
           s.id  as stream_id,
           r.id  as roster_id,
           r.cohort_id  as from_cohort_id,
           r.claimed_by
    from (
           select normalize_reg_number(x ->> 'reg_number') as reg_number,
                  nullif(btrim(coalesce(x ->> 'stream', '')), '') as stream
           from jsonb_array_elements(p_assignments) x
         ) a
    left join cohorts s
           on s.parent_cohort_id = p_parent_cohort_id and s.stream = a.stream
    left join student_roster r
           on r.reg_number = a.reg_number
  loop
    if v_row.stream_id is null then
      raise exception
        'Cohort % has no stream %. Create it with create_cohort_stream first',
        p_parent_cohort_id, v_row.stream;
    end if;

    if v_row.roster_id is null then
      raise exception 'Registration number % is not on the roster', v_row.reg_number;
    end if;

    -- The row must already belong to this cohort, or to one of its streams (so
    -- a student can be moved from Stream A to Stream B). Anything else would be
    -- reaching into another cohort's roster through a stream assignment, which
    -- is the sideways-authority shape TECHNICAL_DISCOVERY §13.4 warns about.
    if v_row.from_cohort_id is distinct from p_parent_cohort_id
       and not exists (
         select 1 from cohorts c
         where c.id = v_row.from_cohort_id
           and c.parent_cohort_id = p_parent_cohort_id
       )
    then
      raise exception
        'Registration number % does not belong to cohort % or any of its streams',
        v_row.reg_number, p_parent_cohort_id;
    end if;

    -- A class rep's placement is set by create_cohort_stream, promote_class_rep
    -- and demote_class_rep, never here. Moving one in bulk could silently
    -- collide with users_one_primary_per_cohort, and would change who holds
    -- scheduling authority over a stream as a side effect of a roster batch.
    if v_row.claimed_by is not null
       and (select role from users where id = v_row.claimed_by) = 'class_rep' then
      raise exception
        'Registration number % belongs to a class rep. Move a rep with '
        'create_cohort_stream or demote them first — not through a bulk assignment',
        v_row.reg_number;
    end if;

    update student_roster
    set cohort_id = v_row.stream_id
    where id = v_row.roster_id;

    -- Only if they have actually claimed. An unclaimed row still moves — that
    -- is the point of keying on registration number — and claim_roster_row will
    -- place them into the stream when they sign up.
    if v_row.claimed_by is not null then
      update users set cohort_id = v_row.stream_id where id = v_row.claimed_by;
    end if;

    insert into identity_audit_log (
      reg_number, action, actor_id, target_user, snapshot
    )
    values (
      v_row.reg_number, 'reassigned', p_acting_user, v_row.claimed_by,
      jsonb_build_object(
        'from_cohort_id', v_row.from_cohort_id,
        'to_cohort_id',   v_row.stream_id,
        'stream',         v_row.stream,
        'was_claimed',    (v_row.claimed_by is not null),
        'reason',         'stream_assignment'
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- --- from 0029_roster_placement_sync.sql -------------------------------------

-- Returns true when the row moved, so callers can report it if they ever need
-- to. Internal only — no EXECUTE granted, same as notify_cohort_members.
create or replace function sync_roster_placement(
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

  insert into identity_audit_log (
    reg_number, action, actor_id, target_user, snapshot
  )
  values (
    v_reg_number, 'reassigned', p_actor_id, p_user_id,
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

-- --- from 0041_commit_school_identity.sql / 0042_school_identity_takeover.sql -

-- Current live body is 0042's (it redefines 0041's original with the takeover
-- path added). Gate re-hosting from claim_roster_row (0019, ~lines 185-205),
-- per AUTH_FLOW_REFACTOR.md §4 step 5: of its four checks, two re-host onto
-- users columns (existing claim? -> student_number lookup; is it already
-- oauth? -> claim_method), one is unchanged (class_rep? -> users.role), and
-- one does not apply here at all.
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

    insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
    values (
      v_reg, 'takeover', p_actor_id, v_existing.id,
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

  insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
  values (
    v_reg, 'claimed', p_actor_id, p_student_id,
    jsonb_build_object('method', 'oauth', 'cohort_id', p_cohort_id)
  );
end;
$$;

-- --- from 0045_link_school_email_identity.sql --------------------------------

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

  select email into v_new_email
  from auth.identities
  where user_id = p_actor_id and is_school_email(email)
  order by created_at desc
  limit 1;

  if v_user.claim_method = 'oauth' and v_user.school_email is not distinct from v_new_email then
    return;
  end if;

  if v_user.claim_method is distinct from 'provisional' then
    raise exception
      'Only a provisional-claim account can link a school email this way';
  end if;

  if v_user.school_email is not null then
    raise exception
      'This account already signed up with a school email; use the cohort join-request flow';
  end if;

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

    insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
    values (
      v_reg, 'takeover', p_actor_id, v_existing.id,
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

  insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
  values (
    v_reg, 'identity_linked', p_actor_id, p_actor_id,
    jsonb_build_object('linked', 'school_email', 'previous_claim_method', v_user.claim_method)
  );
end;
$$;

-- --- from 0046_link_personal_email_identity.sql ------------------------------

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

  insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
  values (
    v_reg, 'identity_linked', p_actor_id, p_actor_id,
    jsonb_build_object(
      'linked', 'personal_email',
      'previous_personal_email', v_user.personal_email,
      'new_personal_email', v_new_email
    )
  );
end;
$$;

-- Note: none of the twelve functions' `comment on function`, `revoke`/`grant`
-- statements need restating — CREATE OR REPLACE FUNCTION does not touch a
-- function's existing grants (only its body/definition), and comments survive
-- a body replacement too.
