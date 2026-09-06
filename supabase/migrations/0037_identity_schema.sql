-- ============================================================================
-- 0037: Identity schema — four identity columns, four email columns
-- ============================================================================
-- Part 1 of 5 of the OAuth-only auth redesign (AUTH_FLOW_REFACTOR.md).
-- STRUCTURE ONLY. No trigger or function reads or writes any of the eight
-- columns below yet — handle_new_auth_user keeps writing users.email /
-- users.email_verified_at exactly as it does today, and claim_roster_row
-- keeps writing users.reg_number exactly as it does today. This is
-- deliberate: dropping the old columns before their replacement writers
-- exist would break `supabase db reset` immediately, the same trap TODO.md
-- already names for events.course_id (0021 -> 0022) and cohorts.join_code
-- (0023 -> 0024) — "a writer cannot stop writing a column while it is still
-- required." Old columns retire in the Phase 5 (retirement) migration, after
-- Plans 2-4 land the functions that replace them.
--
-- Contents
--   §1  Four identity columns on users, plus student_number uniqueness
--   §2  Four email columns on users (school_email / personal_email split)
--   §3  cohorts_id_programme_unique  — FK target; a 4-column unique
--       constraint cannot back a 2-column FK
--   §4  Composite FK users(cohort_id, programme_id) -> cohorts(id, programme_id)
--   §5  guard_users_self_update extended to the eight new columns
-- ============================================================================


-- ============================================================================
-- 1. Four identity columns
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §2. These decompose what reg_number today encodes as
-- one composed string (parsed on demand by parse_reg_number, 0017) into four
-- stored facts. Nullable: an account has none of these until it claims an
-- identity via Flow 1 or Flow 2 (both still unbuilt — Plans 2-3).
alter table users
  add column programme_id   uuid references programmes (id) on delete restrict,
  add column self_sponsored boolean,
  add column student_number text,
  add column admission_year int;

comment on column users.programme_id is
  'Real FK, chosen from a picker (Flow 1) or derived from a proven school '
  'address (Flow 2) — never typed as a code. NULL until an identity is '
  'claimed. ON DELETE RESTRICT: once a student is anchored to a programme, '
  'deleting that programme out from under them should raise, not silently '
  'null out their identity.';
comment on column users.self_sponsored is
  'A signup toggle (Flow 1) or derived from the S-variant of a programme '
  'code (Flow 2, via the existing parse_reg_number S-stripping logic) — a '
  'real, independent fact, not inferred at read time. Feeds the deferred '
  'trimester-eligibility feature in TODO.md''s "Branching" entry.';
comment on column users.student_number is
  'The true, permanent identity anchor — survives a future inter-programme '
  'or inter-faculty transfer unchanged. Globally unique; see the constraint '
  'below.';
comment on column users.admission_year is
  'Descriptive only. Deliberately NOT part of any uniqueness or identity '
  'key, and NOT reliable for current cohort placement — a deferred '
  'student''s number still says their original year. See '
  'AUTH_FLOW_REFACTOR.md §4 step 3.';

alter table users
  add constraint users_student_number_unique unique (student_number);


-- ============================================================================
-- 2. Four email columns
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §2. Splits the existing generic email/email_verified_at
-- pair (0002 — still written by handle_new_auth_user, still load-bearing,
-- left completely untouched by this migration) into two identity-tiered
-- pairs. Needed because under the redesign BOTH Flow 1 (personal Gmail) and
-- Flow 2 (school address) are Google OAuth — "signed up via provider =
-- google" alone stops being enough to tell apart "proves a school identity"
-- from "proves nothing but an inbox", which is exactly what
-- handle_new_auth_user's provider-only check assumes today.
alter table users
  add column school_email               text,
  add column school_email_verified_at   timestamptz,
  add column personal_email             text,
  add column personal_email_verified_at timestamptz;

comment on column users.school_email is
  'The @student.chuka.ac.ke address. Written only by the Flow 2 signup/link '
  'path (Plans 3-4, unbuilt as of this migration) from a provider-proven '
  'address — never derived, never typed by a client.';
comment on column users.personal_email is
  'Any OAuth-proven address that is NOT a school address (Flow 1 signup, or '
  'linked later per AUTH_FLOW_REFACTOR.md §6). Carries no identity claim.';
comment on column users.school_email_verified_at is
  'Set only by the Flow 2 signup/link path. NOT itself a source of '
  'authorization — AUTH_FLOW_REFACTOR.md §2''s rule is that claim_method is '
  'the only column any access decision reads.';
comment on column users.personal_email_verified_at is
  'Set only by the Flow 1 signup path or the §6 link path.';


-- ============================================================================
-- 3. cohorts_id_programme_unique
-- ============================================================================
-- FK target for §4. cohorts_id_identity_unique (0025_cohort_streams.sql:145)
-- is unique (id, programme_id, intake_year, pace) — a 4-column constraint
-- cannot back a 2-column foreign key, even though (id, programme_id) is
-- trivially unique given id is already the primary key: Postgres requires an
-- actual constraint or unique index on exactly the referenced column set, not
-- a subset of a wider one.
alter table cohorts
  add constraint cohorts_id_programme_unique unique (id, programme_id);


-- ============================================================================
-- 4. users(cohort_id, programme_id) -> cohorts(id, programme_id)
-- ============================================================================
-- Structurally closes the transfer risk AUTH_FLOW_REFACTOR.md §2 names:
-- once programme_id is a real column, a transfer means updating it and
-- cohort_id together — and if those two are ever set in separate
-- statements, a row could transit a moment where its programme disagrees
-- with its own cohort's programme. cohorts_stream_inherits (0025) solved
-- this exact shape of problem with a composite FK; same tool here.
--
-- MATCH SIMPLE (the default): a row with ANY null among cohort_id /
-- programme_id automatically satisfies the constraint. That covers both
-- pre-claim (both null) and claimed-but-cohortless (programme_id set,
-- cohort_id still null — AUTH_FLOW_REFACTOR.md §3 step 5, the state a
-- declined join request also leaves a Flow 1 account in) without any
-- special-casing. The constraint only ever fires once BOTH columns are
-- set, which is exactly the moment there is something to check.
--
-- ON DELETE NO ACTION, not SET NULL: a multi-column SET NULL nulls every
-- referencing column together, which would silently wipe programme_id (an
-- identity fact) as a side effect of an unrelated cohort deletion. The
-- existing single-column cohort_id FK (0002) already handles cohort
-- deletion correctly on its own.
alter table users
  add constraint users_cohort_programme_fk
  foreign key (cohort_id, programme_id)
  references cohorts (id, programme_id)
  on delete no action;


-- ============================================================================
-- 5. guard_users_self_update extended
-- ============================================================================
-- 0032's version (itself replacing 0014's original) blocks direct writes to
-- id/role/class_rep_rank/cohort_id/reg_number/email/email_verified_at/
-- faculty_id/department_id/created_at. An unlisted column is a column this
-- trigger says nothing about — so the eight columns added above join the
-- list in the SAME migration that creates them, even though no legitimate
-- writer function exists for any of them yet (Plans 2-4 add those).
--
-- Note this trigger is a BACKSTOP, not the primary gate: 0014's column-level
-- grant (`grant update (first_name, last_name, middle_name) on users to
-- authenticated`) already refuses any UPDATE that references an unlisted
-- column, before this trigger runs at all — see 02_trust_chain_test.sql's
-- own comment on this. Both layers are kept in sync anyway, since that is
-- this codebase's established defense-in-depth discipline (0014 §4: "RLS
-- and GRANTs are separate mechanisms and both are required").
--
-- CREATE OR REPLACE discards proconfig — 0019 recorded this after it
-- silently un-pinned handle_new_auth_user and reopened 0008's SECURITY
-- DEFINER escalation vector. `set search_path = public` is restated, not
-- decoration.
create or replace function guard_users_self_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return NEW;
  end if;

  if NEW.id                         is distinct from OLD.id
  or NEW.role                       is distinct from OLD.role
  or NEW.class_rep_rank             is distinct from OLD.class_rep_rank
  or NEW.cohort_id                  is distinct from OLD.cohort_id
  or NEW.reg_number                 is distinct from OLD.reg_number
  or NEW.email                      is distinct from OLD.email
  or NEW.email_verified_at          is distinct from OLD.email_verified_at
  or NEW.faculty_id                 is distinct from OLD.faculty_id
  or NEW.department_id              is distinct from OLD.department_id
  or NEW.created_at                 is distinct from OLD.created_at
  or NEW.programme_id                is distinct from OLD.programme_id
  or NEW.self_sponsored              is distinct from OLD.self_sponsored
  or NEW.student_number              is distinct from OLD.student_number
  or NEW.admission_year              is distinct from OLD.admission_year
  or NEW.school_email                is distinct from OLD.school_email
  or NEW.school_email_verified_at    is distinct from OLD.school_email_verified_at
  or NEW.personal_email              is distinct from OLD.personal_email
  or NEW.personal_email_verified_at  is distinct from OLD.personal_email_verified_at
  then
    raise exception
      'Only first_name, last_name and middle_name may be updated directly. '
      'role/cohort_id/class_rep_rank change via create_cohort_with_class_rep, '
      'promote_class_rep or demote_class_rep; faculty_rep status via '
      'bootstrap_faculty_rep; email and email_verified_at are written only by '
      'the auth sync trigger on an OAuth signup; programme_id, '
      'self_sponsored, student_number, admission_year, school_email, '
      'school_email_verified_at, personal_email and '
      'personal_email_verified_at are written only by the identity-claim '
      'and identity-link functions.'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_users_self_update() from public, anon, authenticated;
