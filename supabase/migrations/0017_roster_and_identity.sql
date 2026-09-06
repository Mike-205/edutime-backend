-- ============================================================================
-- 0017: Roster and identity — structure
-- ============================================================================
-- Phase R part 1 of 3 (0017 / 0018 / 0019). Tables, columns, policies,
-- privileges and the scoped write path. No claim behaviour — that is 0019.
--
-- WHY THIS EXISTS (TODO §0.5, TECHNICAL_DISCOVERY §2 and §10)
--
-- The trust chain anchors AUTHORITY in the real world: Superadmin -> Faculty
-- Rep -> Class Rep, every step witnessed by a human. IDENTITY has no such
-- anchor. handle_new_auth_user copies
--
--     new.raw_user_meta_data ->> 'reg_number'
--
-- straight from the client into public.users, the column is nullable, and
-- nothing makes it unique. So today anyone can sign up claiming any
-- registration number, and two accounts can hold the same one. Every careful
-- check in 0014-0016 sits on top of a `users` row whose identity was simply
-- asserted.
--
-- This closes it by pre-declaring who exists. Signing up stops being "create
-- an account" and becomes "claim a known one".
--
-- Contents
--   §1  Registration-number parsing        -> reg_number_parts, parse_reg_number()
--   §2  programmes.code uniqueness         (pulled forward from TODO §2.1)
--   §3  student_roster
--   §4  roster_audit_log
--   §5  user_recovery_email
--   §6  RLS
--   §7  Table privileges
--   §8  Scoped roster writes               -> add / bulk import / correct / remove
--
-- What is deliberately NOT here: claiming, OAuth binding, takeover, dispute
-- resolution, and the rewire of handle_new_auth_user. All 0019.
-- ============================================================================


-- ============================================================================
-- 0. Enums
-- ============================================================================
-- Both are NEW types, so creating and using them in this same migration is
-- fine. The 0009/0011 split exists only for `ALTER TYPE ... ADD VALUE`, which
-- cannot share a transaction with anything referencing the new value. 0018
-- carries the notif_type additions for exactly that reason.

-- How an identity was proven, and therefore how much it is worth.
--   oauth       — the provider proved the address and it matched a roster row.
--   provisional — password signup. Unauthenticated by construction (there is
--                 no channel to verify against), so it is subject to takeover
--                 the moment the real owner signs in with OAuth. See 0019.
create type claim_method as enum ('oauth', 'provisional');

create type roster_audit_action as enum (
  'created',
  'updated',
  'removed',
  'claimed',
  'takeover',
  'unbound',
  'dispute_resolved'
);


-- ============================================================================
-- 1. Registration-number parsing
-- ============================================================================
-- Format: <PROGRAMME CODE>/<STUDENT NUMBER>/<2-DIGIT ADMISSION YEAR>
-- e.g. 'EB1/67277/23'.
--
-- This is the single most load-bearing piece of string handling in the schema.
-- It decides which programme a person belongs to, which intake year, and
-- therefore which class rep is allowed to write their roster row at all (§8).
--
-- Two properties of the real code list make the obvious regex wrong:
--
--   * Codes are not "letters then one digit". 'EB10', 'EB11', 'EB12' exist,
--     and 'LLB' has no digits at all.
--   * Self-sponsored intakes insert an 'S' before the numeric suffix — 'EBS3'
--     is the self-sponsored intake of programme 'EB3'. Per TECHNICAL_DISCOVERY
--     §4 these are deliberately the SAME programmes row: identical courses,
--     differing only in pace.
--
-- So the prefix is resolved by LOOKUP, not by structure. Literal code first,
-- then the S-stripped candidate. Order matters: a legitimate code that happens
-- to carry an 'S' before its digits (say a future 'CS1') would be mangled into
-- 'C1' by the rewrite, so the code exactly as written always wins.
--
-- Returns all-NULL rather than raising when the input is unparseable or names
-- an unknown programme. Callers decide whether that is an error — signup wants
-- to answer with one deliberately vague message (§0.5), and a raised exception
-- with a specific reason would leak more than that message is willing to say.
create type reg_number_parts as (
  programme_id      uuid,
  programme_code    text,
  is_self_sponsored boolean,
  student_number    text,
  admission_year    int
);

create or replace function parse_reg_number(p_reg_number text)
returns reg_number_parts
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_norm   text;
  v_parts  text[];
  v_prefix text;
  v_alt    text;
  v_prog   record;
  v_result reg_number_parts;
begin
  v_result := row(null::uuid, null::text, null::boolean, null::text, null::int)
                ::reg_number_parts;

  if p_reg_number is null then
    return v_result;
  end if;

  v_norm := upper(regexp_replace(p_reg_number, '\s', '', 'g'));

  if v_norm !~ '^[A-Z]+[0-9]*/[0-9]+/[0-9]{2}$' then
    return v_result;
  end if;

  v_parts  := string_to_array(v_norm, '/');
  v_prefix := v_parts[1];

  select id, code into v_prog from programmes where code = v_prefix;

  if found then
    v_result.programme_id      := v_prog.id;
    v_result.programme_code    := v_prog.code;
    v_result.is_self_sponsored := false;
  else
    v_alt := regexp_replace(v_prefix, '^([A-Z]+)S([0-9]*)$', '\1\2');

    if v_alt <> v_prefix then
      select id, code into v_prog from programmes where code = v_alt;
      if found then
        v_result.programme_id      := v_prog.id;
        v_result.programme_code    := v_prog.code;
        v_result.is_self_sponsored := true;
      end if;
    end if;
  end if;

  if v_result.programme_id is null then
    return v_result;
  end if;

  v_result.student_number := v_parts[2];
  -- Cohorts store a four-digit intake_year ('BSC-CS 2023'); registration
  -- numbers carry two. Good until 2100, which is not this system's problem.
  v_result.admission_year := 2000 + v_parts[3]::int;

  return v_result;
end;
$$;

comment on function parse_reg_number(text) is
  'Resolves a registration number to its programme, intake year and sponsorship. '
  'Returns all-NULL on an unparseable number or unknown programme code — never raises.';

revoke execute on function parse_reg_number(text) from public, anon;
grant  execute on function parse_reg_number(text) to authenticated, service_role;


-- Normalizer, so every write path stores exactly one spelling of a number.
create or replace function normalize_reg_number(p_reg_number text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(p_reg_number, ''), '\s', '', 'g'));
$$;

revoke execute on function normalize_reg_number(text) from public, anon;
grant  execute on function normalize_reg_number(text) to authenticated, service_role;


-- ============================================================================
-- 2. programmes.code must be unique
-- ============================================================================
-- Pulled forward from TODO §2.1, where it was listed as cleanup. It is not
-- cleanup any more: §1 resolves a registration number by looking programmes up
-- on `code`, and §8 decides who may write a roster row from the result. A
-- duplicate code makes that lookup non-deterministic, which would silently
-- misfile students and mis-scope reps.
alter table programmes
  add constraint programmes_code_unique unique (code);


-- ============================================================================
-- 3. student_roster
-- ============================================================================
-- One row per person the institution says exists. Registration number and
-- full name only — no email column, ever. TECHNICAL_DISCOVERY §10 explains
-- why: a stored school address would be a derived string, and letting a
-- derived string set email_verified_at fakes the one trust signal that means
-- anything.
--
-- The cohort is pinned here, so claiming places the student automatically.
-- cohort_join_requests survives for the exception path only — students who
-- deferred, transferred or repeated, where the obvious cohort is wrong.
create table student_roster (
  id           uuid primary key default gen_random_uuid(),

  -- Canonical, normalized, globally unique. Global rather than per-cohort on
  -- purpose: two reps must not be able to roster the same human into two
  -- different cohorts. First writer wins — deterministic and detectable, which
  -- is strictly better than silently divergent.
  reg_number   text not null,

  first_name   text not null,
  last_name    text not null,
  middle_name  text,

  cohort_id    uuid not null references cohorts (id) on delete restrict,

  -- Binding. Null = unclaimed, and unclaimed rows never expire. Written by
  -- 0019, never by a client.
  claimed_by   uuid references users (id) on delete set null,
  claimed_at   timestamptz,
  claim_method claim_method,

  -- on delete set null, NOT restrict: TODO §2.3 already records that the
  -- restrict chain on events.created_by makes accounts undeletable. Do not add
  -- another link to it.
  added_by     uuid references users (id) on delete set null,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint student_roster_reg_number_unique unique (reg_number),

  constraint student_roster_reg_number_shape
    check (reg_number ~ '^[A-Z]+[0-9]*/[0-9]+/[0-9]{2}$'),

  -- Deliberately one-directional. The biconditional would be violated the
  -- moment claimed_by's ON DELETE SET NULL fires, turning an account deletion
  -- into a constraint error.
  constraint student_roster_claim_coherent
    check (claimed_by is null or (claimed_at is not null and claim_method is not null))
);

comment on table student_roster is
  'Pre-declared identities. Signup claims a row rather than creating an account. '
  'Write-mostly: a student must never be able to read this table (see §6).';
comment on column student_roster.reg_number is
  'Normalized via normalize_reg_number(). Globally unique — first writer wins.';
comment on column student_roster.claim_method is
  'oauth = provider-proven identity. provisional = password signup, unauthenticated '
  'by construction and subject to takeover (0019).';

create index student_roster_cohort_idx    on student_roster (cohort_id);
create index student_roster_claimed_idx   on student_roster (claimed_by);
-- The hot rep-facing query is "who in my cohort has not signed up yet".
create index student_roster_unclaimed_idx on student_roster (cohort_id)
  where claimed_by is null;


-- ============================================================================
-- 4. roster_audit_log
-- ============================================================================
-- Append-only, one row per meaningful action, attributed to the acting human —
-- the same idiom TECHNICAL_DISCOVERY §4 describes for event_audit_log.
--
-- This is not optional bookkeeping. 0019 adds a faculty-rep function that can
-- sever a claimed identity from its account. An unlogged manual override of
-- that kind would be the most dangerous thing in this schema.
create table roster_audit_log (
  id          uuid primary key default gen_random_uuid(),

  roster_id   uuid references student_roster (id) on delete set null,

  -- Denormalized so the trail survives the roster row being removed. An audit
  -- log that can be erased by deleting the thing it audits is not an audit log.
  reg_number  text not null,

  action      roster_audit_action not null,
  actor_id    uuid references users (id) on delete set null,
  target_user uuid references users (id) on delete set null,
  snapshot    jsonb,
  created_at  timestamptz not null default now()
);

create index roster_audit_roster_idx on roster_audit_log (roster_id);
create index roster_audit_reg_idx    on roster_audit_log (reg_number, created_at desc);


-- ============================================================================
-- 5. user_recovery_email
-- ============================================================================
-- TODO §0.5 says the recovery address "lives only in public.users". It cannot
-- literally be a column there, and the reason is worth writing down.
--
-- 0014 §4 grants `select on ... users` to authenticated — the WHOLE table — and
-- 0006's users_read_all policy is `auth.uid() is not null`. So every signed-in
-- student can read every column of every user row. A recovery_email column on
-- users would publish every student's personal address to the entire
-- university. Column-level SELECT grants could fix that, but they are brittle:
-- every future column has to remember to opt out.
--
-- A separate table with a self-only policy is the same intent, enforced
-- structurally. The rule §0.5 actually cares about is unchanged and absolute:
-- this address is NOT in auth.users, so it can never be signed in with, and it
-- never feeds users.email_verified_at. It is a delivery destination and
-- nothing else.
create table user_recovery_email (
  user_id     uuid primary key references users (id) on delete cascade,
  email       text not null,
  verified_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint user_recovery_email_shape check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

comment on table user_recovery_email is
  'Personal address for password reset only. Never an auth identity, never proof '
  'of who someone is — a verified mailbox proves control of that mailbox and '
  'nothing more. Deliberately NOT unique: a shared or parent address is valid, '
  'which matters for first-years who have no university mailbox yet.';


-- ============================================================================
-- 6. RLS
-- ============================================================================
-- The roster is WRITE-MOSTLY. This is the part most likely to be loosened by
-- someone who does not see why it matters, so: readable by students, the
-- roster is a directory of every classmate's exact official name and
-- registration number — which is precisely the pair needed to claim someone
-- else's row on the password branch. Never grant students SELECT here.
alter table student_roster    enable row level security;
alter table roster_audit_log  enable row level security;
alter table user_recovery_email enable row level security;

-- Reps need to see who has not signed up yet. Scoped to exactly what they
-- already know in the real world: a class rep sees their own cohort, a faculty
-- rep sees cohorts under their faculty. Plain students see nothing at all.
drop policy if exists roster_read_own_scope on student_roster;

create policy roster_read_own_scope
  on student_roster for select
  using (
    exists (
      select 1
      from users u
      where u.id = auth.uid()
        and (
          (u.role = 'class_rep' and u.cohort_id = student_roster.cohort_id)
          or (
            u.role = 'faculty_rep'
            and u.faculty_id is not null
            and u.faculty_id = (
              select d.faculty_id
              from cohorts c
              join programmes p on p.id = c.programme_id
              join departments d on d.id = p.department_id
              where c.id = student_roster.cohort_id
            )
          )
        )
    )
  );

-- Audit is oversight of reps, so it is read by the level above them.
drop policy if exists roster_audit_read_faculty on roster_audit_log;

create policy roster_audit_read_faculty
  on roster_audit_log for select
  using (
    exists (
      select 1 from users u
      where u.id = auth.uid()
        and u.role = 'faculty_rep'
        and u.faculty_id is not null
    )
  );

-- Self only. No exceptions — not the class rep, not the faculty rep.
drop policy if exists recovery_email_read_own on user_recovery_email;

create policy recovery_email_read_own
  on user_recovery_email for select
  using (user_id = auth.uid());


-- ============================================================================
-- 7. Table privileges
-- ============================================================================
-- RLS and GRANTs are separate mechanisms and both are required — the lesson
-- 0014 §4 was written to record, repeated here so these three tables are not
-- silently unreadable.
--
-- The revoke is NOT redundant. Supabase ships default privileges that grant on
-- newly created tables in `public` to anon and authenticated, so these three
-- arrived with privileges nobody asked for — anon included, on the one table
-- in this schema that must never be readable. 0014 §4 had to clear exactly the
-- same inherited grants for the original fourteen tables; every new table has
-- to do it again. The access-control suite catches this if you forget.
revoke all on student_roster, roster_audit_log, user_recovery_email
  from anon, authenticated;

-- SELECT only. Every write goes through the SECURITY DEFINER functions in §8
-- and in 0019, so there is no INSERT/UPDATE/DELETE policy or grant for any of
-- them: read the function, not the table, to know what is allowed.
grant select on student_roster      to authenticated;
grant select on roster_audit_log    to authenticated;
grant select on user_recovery_email to authenticated;

grant all on student_roster      to service_role;
grant all on roster_audit_log    to service_role;
grant all on user_recovery_email to service_role;


-- ============================================================================
-- 8. Scoped roster writes
-- ============================================================================
-- Who may write a roster row, and for whom.
--
-- TODO §0.5 settles the split: bulk import belongs to the faculty rep and
-- superadmin, so the higher role PERFORMS it rather than reviewing it — which
-- is what keeps this whole design free of approval queues. Class reps get
-- single-row adds for the long tail (a transfer arriving in week three).
--
-- The scoping rule that makes class-rep writes safe comes out of the
-- registration number itself. 'EB1/67277/23' encodes programme EB1 and intake
-- 2023, so a BSC-CS 2023 rep may write EB1/*/23 and nothing else. Without it,
-- "class reps can write" plus "the row pins the cohort" would let rep B roster
-- a student who belongs to cohort A into cohort B — and because the OAuth path
-- has no human in it, that student would be silently placed in the wrong
-- cohort on signup.

-- Shared gate. Raises on any violation; returns the parsed number so callers
-- do not parse twice. Internal only — SECURITY DEFINER callers run as the
-- owner, so no EXECUTE grant to authenticated is needed for them to reach it.
create or replace function roster_assert_may_write(
  p_cohort_id   uuid,
  p_reg_number  text,
  p_acting_user uuid
)
returns reg_number_parts
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role         user_role;
  v_user_cohort  uuid;
  v_user_faculty uuid;
  v_parts        reg_number_parts;
  v_cohort       record;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select role, cohort_id, faculty_id
  into v_role, v_user_cohort, v_user_faculty
  from users where id = p_acting_user;

  if v_role is null then
    raise exception 'Acting user % not found', p_acting_user;
  end if;

  if v_role not in ('class_rep', 'faculty_rep') then
    raise exception 'Only a class_rep or faculty_rep may write roster rows';
  end if;

  select c.id, c.programme_id, c.intake_year, d.faculty_id
  into v_cohort
  from cohorts c
  join programmes p  on p.id = c.programme_id
  join departments d on d.id = p.department_id
  where c.id = p_cohort_id;

  if v_cohort.id is null then
    raise exception 'Cohort % does not exist', p_cohort_id;
  end if;

  if v_role = 'class_rep' then
    if v_user_cohort is distinct from p_cohort_id then
      raise exception 'A class_rep may only add students to their own cohort';
    end if;
  else
    if v_user_faculty is null then
      raise exception 'This faculty_rep has no faculty_id set and cannot write roster rows';
    end if;
    if v_cohort.faculty_id is distinct from v_user_faculty then
      raise exception 'Cohort % belongs to another faculty', p_cohort_id;
    end if;
  end if;

  v_parts := parse_reg_number(p_reg_number);

  if v_parts.programme_id is null then
    raise exception
      'Registration number % is not a recognised format or names an unknown programme',
      p_reg_number;
  end if;

  -- The number must agree with the cohort it is being filed under. This is the
  -- check that closes the cross-cohort hijack; without it the two branches
  -- above only constrain WHICH cohort a rep writes to, not WHO they write.
  if v_parts.programme_id is distinct from v_cohort.programme_id then
    raise exception
      'Registration number % belongs to programme %, not this cohort''s programme',
      p_reg_number, v_parts.programme_code;
  end if;

  if v_parts.admission_year is distinct from v_cohort.intake_year then
    raise exception
      'Registration number % is a % intake; this cohort is %',
      p_reg_number, v_parts.admission_year, v_cohort.intake_year;
  end if;

  return v_parts;
end;
$$;

revoke execute on function roster_assert_may_write(uuid, text, uuid)
  from public, anon, authenticated;


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

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, snapshot)
  values (
    v_roster_id, v_norm, 'created', p_acting_user,
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

revoke execute on function roster_add_student(text, text, text, text, uuid, uuid)
  from public, anon;
grant  execute on function roster_add_student(text, text, text, text, uuid, uuid)
  to authenticated, service_role;


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

    insert into roster_audit_log (roster_id, reg_number, action, actor_id, snapshot)
    values (
      v_id, v_norm, 'created', p_acting_user,
      jsonb_build_object('cohort_id', p_cohort_id, 'source', 'bulk')
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function roster_bulk_import(jsonb, uuid, uuid) from public, anon;
grant  execute on function roster_bulk_import(jsonb, uuid, uuid)
  to authenticated, service_role;


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

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, snapshot)
  values (
    p_roster_id, v_norm, 'updated', p_acting_user,
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

revoke execute on function roster_correct_student(uuid, text, text, text, text, uuid)
  from public, anon;
grant  execute on function roster_correct_student(uuid, text, text, text, text, uuid)
  to authenticated, service_role;


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
  insert into roster_audit_log (roster_id, reg_number, action, actor_id, snapshot)
  values (
    p_roster_id, v_existing.reg_number, 'removed', p_acting_user,
    jsonb_build_object(
      'cohort_id',  v_existing.cohort_id,
      'first_name', v_existing.first_name,
      'last_name',  v_existing.last_name
    )
  );

  delete from student_roster where id = p_roster_id;
end;
$$;

revoke execute on function roster_remove_student(uuid, uuid) from public, anon;
grant  execute on function roster_remove_student(uuid, uuid)
  to authenticated, service_role;
