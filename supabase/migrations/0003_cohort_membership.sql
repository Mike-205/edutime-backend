-- ============================================================================
-- 0003: Cohort membership — join requests, creation, class-rep management
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Cohort join requests (PRIMARY join flow)
-- ----------------------------------------------------------------------------
-- Student picks a cohort from the list matching their programme (all
-- cohorts under that programme are shown — Year 1 Sem 1 through however many
-- semesters the programme runs), requests to join, and the class rep
-- approves or declines. This accommodates students who deferred,
-- transferred, or repeated a year and so don't match the "standard"
-- cohort their admission year would suggest.
--
-- Declined requests do NOT permanently block a student — they can
-- re-request (e.g. after clarifying with the rep in person). History is
-- kept as separate rows rather than overwritten.
create table cohort_join_requests (
  id           uuid primary key default gen_random_uuid(),
  student_id   uuid not null references users (id) on delete cascade,
  cohort_id    uuid not null references cohorts (id) on delete cascade,
  status       join_request_status not null default 'pending',
  requested_at timestamptz not null default now(),
  decided_by   uuid references users (id) on delete set null,
  decided_at   timestamptz
);

create index cohort_join_requests_cohort_idx on cohort_join_requests (cohort_id);
create index cohort_join_requests_student_idx on cohort_join_requests (student_id);

-- A student can only have ONE pending request at a time (across any
-- cohort) — prevents spamming multiple simultaneous requests. They're free
-- to request again once a prior one is decided (approved -> they're in
-- anyway; declined -> free to retry).
create unique index cohort_join_requests_one_pending_per_student
  on cohort_join_requests (student_id)
  where status = 'pending';

-- Approving a request moves the student into the cohort. Kept as a function
-- rather than "app does two separate writes" so the update to
-- cohort_join_requests.status and users.cohort_id happen atomically, and so
-- the app never needs a direct UPDATE grant on users.cohort_id from the
-- client for this path.
create or replace function approve_cohort_join_request(
  p_request_id uuid,
  p_decided_by uuid
)
returns void
language plpgsql
security definer
as $$
declare
  v_student_id uuid;
  v_cohort_id  uuid;
begin
  select student_id, cohort_id
  into v_student_id, v_cohort_id
  from cohort_join_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    raise exception 'No pending join request with id %', p_request_id;
  end if;

  update cohort_join_requests
  set status = 'approved', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;

  update users
  set cohort_id = v_cohort_id
  where id = v_student_id;
end;
$$;

create or replace function decline_cohort_join_request(
  p_request_id uuid,
  p_decided_by uuid
)
returns void
language plpgsql
security definer
as $$
begin
  update cohort_join_requests
  set status = 'declined', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id and status = 'pending';

  if not found then
    raise exception 'No pending join request with id %', p_request_id;
  end if;
end;
$$;


-- ----------------------------------------------------------------------------
-- Cohort creation + first class-rep promotion (single atomic action)
-- ----------------------------------------------------------------------------
-- A cohort with no rep and no members has no real-world meaning, so
-- creation and the first promotion happen together. Called by a Faculty
-- Rep only (enforced in 0006 RLS on the underlying tables + by checking the
-- caller's role here).
create or replace function create_cohort_with_class_rep(
  p_programme_id      uuid,
  p_intake_year     int,
  p_current_semester int,
  p_pace            cohort_pace,
  p_first_rep_id    uuid,
  p_created_by      uuid   -- the Faculty Rep performing this action
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_programme_abbr text;
  v_cohort_id    uuid;
  v_creator_role user_role;
begin
  select role into v_creator_role from users where id = p_created_by;
  if v_creator_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may create a cohort';
  end if;

  select abbreviation into v_programme_abbr from programmes where id = p_programme_id;
  if v_programme_abbr is null then
    raise exception 'Programme % not found', p_programme_id;
  end if;

  insert into cohorts (programme_id, name, join_code, intake_year, current_semester, pace)
  values (
    p_programme_id,
    v_programme_abbr || ' ' || p_intake_year,
    encode(gen_random_bytes(6), 'hex'),  -- unused for now (request/approve is
                                          -- the primary flow) but generated so
                                          -- a future self-service fallback
                                          -- doesn't need a migration to add it
    p_intake_year,
    p_current_semester,
    p_pace
  )
  returning id into v_cohort_id;

  update users
  set cohort_id = v_cohort_id,
      role = 'class_rep',
      class_rep_rank = 'primary'
  where id = p_first_rep_id;

  return v_cohort_id;
end;
$$;


-- ----------------------------------------------------------------------------
-- Max 2 class reps per cohort (one primary + one assistant)
-- ----------------------------------------------------------------------------
-- The two unique partial indexes in 0002 (users_one_primary_per_cohort /
-- users_one_assistant_per_cohort) already guarantee at most one of EACH
-- rank. This trigger is a belt-and-suspenders check for the promotion path
-- specifically: prevents promoting a THIRD person into a cohort that
-- already has both slots filled, with a clearer error message than a raw
-- unique-index violation would give.
create or replace function enforce_max_class_reps()
returns trigger
language plpgsql
as $$
declare
  v_existing_count int;
begin
  if NEW.role = 'class_rep' and NEW.cohort_id is not null then
    select count(*) into v_existing_count
    from users
    where cohort_id = NEW.cohort_id
      and role = 'class_rep'
      and id != NEW.id;

    if v_existing_count >= 2 then
      raise exception 'Cohort % already has 2 class reps', NEW.cohort_id;
    end if;
  end if;
  return NEW;
end;
$$;

create trigger enforce_max_class_reps_trigger
  before insert or update on users
  for each row
  execute function enforce_max_class_reps();


-- ----------------------------------------------------------------------------
-- Demotion (Faculty Rep ability — replace/remove a class rep)
-- ----------------------------------------------------------------------------
-- Demotion just empties the slot; NO auto-promotion of the assistant into
-- primary happens automatically (matches the earlier decision that
-- primary/assistant hand-off is always a manual Faculty Rep action).
create or replace function demote_class_rep(
  p_user_id uuid,
  p_demoted_by uuid
)
returns void
language plpgsql
security definer
as $$
declare
  v_demoter_role user_role;
begin
  select role into v_demoter_role from users where id = p_demoted_by;
  if v_demoter_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may demote a class rep';
  end if;

  update users
  set role = 'student', class_rep_rank = null
  where id = p_user_id and role = 'class_rep';
end;
$$;
