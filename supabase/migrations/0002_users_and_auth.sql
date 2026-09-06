-- ============================================================================
-- 0002: Users + Auth sync
-- ============================================================================
-- Two signup paths, both landing in this one table:
--   A) Registration number + full name + password
--      -> Supabase Auth requires a real email as the identity, so the app
--         signs the user up with a SYNTHETIC email under the hood, e.g.
--         'EB3.67277.23@auth.internal', built by dot-joining the reg number.
--         The user only ever types/sees their reg number; the synthetic
--         address is an implementation detail of auth.users and must never
--         be surfaced in the app UI. public.users.email stays NULL until a
--         real email is linked.
--      -> Unverified until the student separately links + verifies their
--         real @student.chuka.ac.ke email (see email_verified_at below).
--   B) University email (Google/Apple OAuth on @student.chuka.ac.ke)
--      -> Already verified by the OAuth provider, so email_verified_at is
--         set immediately at signup. Registration number is parsed out of
--         the email's local part (dots -> slashes).
--
-- Verification is a TRUST BADGE only, not a functional gate. An unverified
-- student can join a cohort, view the schedule, everything a verified
-- student can — because verification proves email ownership, not
-- scheduling authority. Scheduling authority is entirely controlled by the
-- Faculty Rep -> Class Rep promotion chain, which doesn't care whether the
-- underlying account is verified. Over-restricting unverified users would
-- mostly punish legitimately-enrolled first-years who haven't received
-- their university email yet — exactly the case this dual-signup flow
-- exists to accommodate.
-- ============================================================================

create table users (
  id                uuid primary key references auth.users (id) on delete cascade,

  -- Real, human email. NULLABLE: reg-number signups may not have one yet.
  -- Distinct from the synthetic auth.users identity, which is never stored
  -- here and never shown to the user.
  email             text,
  email_verified_at timestamptz,   -- null = unverified. Set the moment a
                                    -- real @student.chuka.ac.ke email is
                                    -- verified (immediately, for OAuth
                                    -- signups; later, for reg-number
                                    -- signups that link an email after
                                    -- the fact).

  first_name        text not null,
  last_name         text not null,
  middle_name       text,

  -- Format: <ProgrammeCode>/<StudentNumber>/<AdmissionYear>, e.g. 'EB3/67277/23'.
  -- Drives programme lookup at cohort-selection time.
  --
  -- NULLABLE because an account may not have claimed a roster row yet. As of
  -- 0019 the invariant is: reg_number IS NOT NULL if and only if this account
  -- claimed one (see 0017/0019 and TECHNICAL_DISCOVERY §10). The Superadmin is
  -- not an exception to it — it is the service_role key and has no row here at
  -- all.
  --
  -- EVERY ROW IN THIS TABLE IS A STUDENT, class reps and faculty reps included:
  -- both elevated roles are students carrying more responsibility, holding the
  -- same @student address and the same registration number they had before
  -- being promoted. `role` records responsibility; it never replaces identity.
  -- (This comment used to say faculty reps have no registration number. They
  -- do. That was an assumption seed.sql introduced and this file repeated —
  -- corrected 2026-08-24, with 0032 the first migration written against the
  -- right model.)
  reg_number        text,

  role              user_role not null default 'student',

  cohort_id         uuid references cohorts (id) on delete set null,
  class_rep_rank    class_rep_rank,  -- only meaningful when role = 'class_rep';
                                       -- null otherwise. Enforced by the
                                       -- check constraint + trigger below.

  -- NOT "where a student belongs" — that is DERIVABLE via
  -- cohort -> programme -> department -> faculty, so for a student these stay
  -- null and must never be treated as a source of truth; resolve through the
  -- cohort chain instead, to avoid drift.
  --
  -- `faculty_id` means something different and load-bearing: on a faculty_rep
  -- it is THE FACULTY THEY ANCHOR, i.e. the scope of their authority, and 0016
  -- refuses to let them create a cohort or demote anyone without it. A faculty
  -- rep is a student who also belongs to a cohort (see reg_number above), so
  -- they carry both a cohort_id like anyone else AND this, and the two answer
  -- different questions: which lectures they attend, and which faculty they
  -- administer.
  department_id     uuid references departments (id) on delete set null,
  faculty_id        uuid references faculties (id) on delete set null,

  created_at        timestamptz not null default now(),

  constraint users_rank_only_for_class_rep
    check (class_rep_rank is null or role = 'class_rep')
);

create index users_cohort_idx on users (cohort_id);
create index users_faculty_idx on users (faculty_id);

-- At most one 'primary' and one 'assistant' per cohort. Combined with the
-- max-2-class-reps trigger in 0003, this fully enforces the "2 per cohort,
-- one of each rank" rule.
create unique index users_one_primary_per_cohort
  on users (cohort_id)
  where role = 'class_rep' and class_rep_rank = 'primary';

create unique index users_one_assistant_per_cohort
  on users (cohort_id)
  where role = 'class_rep' and class_rep_rank = 'assistant';


-- ----------------------------------------------------------------------------
-- auth.users -> public.users sync trigger
-- ----------------------------------------------------------------------------
-- Populates the public profile row the moment a Supabase Auth account is
-- created, whichever signup path was used. raw_user_meta_data carries
-- whatever the client passed at signup (first/last/middle name, reg_number
-- for path A; parsed reg_number for path B) — the app is responsible for
-- setting these correctly at signup time before/via this trigger.
create or replace function handle_new_auth_user()
returns trigger
language plpgsql
security definer
as $$
begin
  insert into public.users (
    id,
    email,
    email_verified_at,
    first_name,
    last_name,
    middle_name,
    reg_number
  )
  values (
    new.id,
    -- Only store the REAL email if this was an OAuth signup (identified by
    -- provider metadata); reg-number signups pass the synthetic address in
    -- new.email, which must NOT leak into public.users.email.
    case
      when new.raw_app_meta_data ->> 'provider' in ('google', 'apple')
        then new.email
      else null
    end,
    case
      when new.raw_app_meta_data ->> 'provider' in ('google', 'apple')
        then now()
      else null
    end,
    coalesce(new.raw_user_meta_data ->> 'first_name', ''),
    coalesce(new.raw_user_meta_data ->> 'last_name', ''),
    new.raw_user_meta_data ->> 'middle_name',
    new.raw_user_meta_data ->> 'reg_number'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function handle_new_auth_user();


-- ----------------------------------------------------------------------------
-- Email verification (for reg-number accounts linking an email after signup)
-- ----------------------------------------------------------------------------
-- App flow: student links + verifies @student.chuka.ac.ke via OAuth or a
-- confirmation-link flow, then calls this to stamp the badge. Kept as a
-- SECURITY DEFINER function rather than a raw UPDATE so the app never needs
-- direct UPDATE grants on users.email_verified_at from the client.
create or replace function mark_email_verified(p_user_id uuid, p_email text)
returns void
language plpgsql
security definer
as $$
begin
  update public.users
  set email = p_email,
      email_verified_at = now()
  where id = p_user_id;
end;
$$;
