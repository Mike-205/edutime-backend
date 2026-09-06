# Auth Identity Schema (Plan 1 of 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the structural schema the OAuth-only auth redesign needs — four identity columns and four email columns on `users`, plus the constraints that make a programme/cohort mismatch structurally impossible — without changing any existing behavior.

**Architecture:** Pure additive migration. `handle_new_auth_user`, `claim_roster_row`, and every other currently-working auth function keep running exactly as they do today, against the columns they already write (`email`, `email_verified_at`, `reg_number`). The eight new columns sit unused — nullable, unwritten by anything except `postgres`/`service_role` — until Plans 2–4 add the functions that write them. This is the same deprecate → stop-writing → drop sequence already used twice in this repo (`0021` §3 → `0022` §6 for `events.course_id`; `0023` §0 → `0024` §4 for `join_code`), applied here to the *add* half only.

**Tech Stack:** Postgres/PL/pgSQL migration (Supabase CLI), pgTAP tests.

**Spec:** `supabase/AUTH_FLOW_REFACTOR.md` §2 (the four identity facts, the email split, the write-guard note), cross-checked against the shipped schema in `supabase/migrations/0002_users_and_auth.sql`, `0017_roster_and_identity.sql`, `0025_cohort_streams.sql`, `0032_superadmin_bootstrap.sql`.

## Global Constraints

- **No live users or production data exist yet** (nothing pushed to GitHub, local seed data only) — this plan can be a clean additive change with zero backfill concern; there is no live-data blast radius to protect against.
- Every `create or replace` of a pinned `security definer` function must restate `set search_path = public` — `CREATE OR REPLACE` silently discards `proconfig`, and `0019` records the exact regression this causes (`handle_new_auth_user` briefly un-pinned, reopening `0008`'s SECURITY DEFINER escalation vector). `guard_users_self_update` is one of these; the plan below restates the line.
- `authenticated`'s column-level `UPDATE` grant on `users` (`0014`:382, `grant update (first_name, last_name, middle_name) on users to authenticated`) is an *allowlist* — any column not named there is already un-writable by `authenticated` at the privilege layer, before `guard_users_self_update` ever runs. The trigger is a value-aware backstop (it only fires on an actual change, via `IS DISTINCT FROM`), not the primary gate. Both layers get exercised by the tests below; neither is redundant to remove.
- Migration file: `supabase/migrations/0037_identity_schema.sql` (next number after `0036`). Test file: `supabase/tests/17_identity_schema_test.sql` (next number after `16`).

---

## Task 1: Identity + email columns, composite FK, guard trigger

**Files:**
- Create: `supabase/migrations/0037_identity_schema.sql`
- Create: `supabase/tests/17_identity_schema_test.sql`
- Modify (function body only, via `create or replace` inside the new migration — the underlying function was created in `0032_superadmin_bootstrap.sql:204-236`): `guard_users_self_update()`

**Interfaces:**
- Consumes: existing tables `users` (`0002`), `cohorts` (`0001`), `programmes` (`0001`); existing constraint `cohorts_id_identity_unique unique (id, programme_id, intake_year, pace)` (`0025_cohort_streams.sql:145`) — **not reused directly** (a 4-column unique constraint cannot back a 2-column FK); existing function `guard_users_self_update()` (`0032_superadmin_bootstrap.sql:204-236`).
- Produces (for Plans 2–5 to build on): columns `users.programme_id uuid`, `users.self_sponsored boolean`, `users.student_number text`, `users.admission_year int`, `users.school_email text`, `users.school_email_verified_at timestamptz`, `users.personal_email text`, `users.personal_email_verified_at timestamptz`; constraint `users_student_number_unique unique (student_number)`; constraint `cohorts_id_programme_unique unique (id, programme_id)` on `cohorts`; constraint `users_cohort_programme_fk foreign key (cohort_id, programme_id) references cohorts (id, programme_id)` on `users`.

- [ ] **Step 1: Write the failing test file**

Create `supabase/tests/17_identity_schema_test.sql`:

```sql
-- ============================================================================
-- 17: Identity schema — structure only (0037)
-- ============================================================================
-- Covers AUTH_FLOW_REFACTOR.md §2's four identity columns and four email
-- columns on `users`, before any function writes them. Three properties
-- matter: student_number is globally unique, a user's programme_id can never
-- disagree with their own cohort's programme_id (the composite FK), and none
-- of the eight new columns are client-writable — matching the "column-level
-- grants gate first, the guard trigger backstops" discipline `0014`/`0032`
-- already established for every other identity column.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
create function pg_temp.programme(p_code text) returns uuid language sql stable as $$
  select id from programmes where code = p_code;
$$;
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;
-- Plain student, BSC-CS 2023 (programme code 'EB1') — same fixture id 05_roster_test.sql uses.
create function pg_temp.student() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;


-- ---------------------------------------------------------------------------
-- §1 student_number uniqueness
-- ---------------------------------------------------------------------------
update users set student_number = 'DUP001' where id = pg_temp.student();

select throws_ok(
  format($$ update users set student_number = 'DUP001'
            where id = (select id from users where role = 'student' and id != %L limit 1) $$,
         pg_temp.student()),
  '23505',
  null,
  'student_number is globally unique — a second account cannot hold the same one'
);

select lives_ok(
  $$ update users set student_number = null where id = '22222222-0000-4000-8000-000000000013' $$,
  'student_number can be cleared back to null (multiple nulls are not a uniqueness violation)'
);


-- ---------------------------------------------------------------------------
-- §2 Composite FK: users(cohort_id, programme_id) -> cohorts(id, programme_id)
-- ---------------------------------------------------------------------------
-- The fixture student is already in cohort EB1/2023 (cohort_id set). Both
-- sides null, or both agreeing, must be allowed; disagreeing must not.
select throws_ok(
  format($$ update users set programme_id = %L where id = %L $$,
         pg_temp.programme('EB3'), pg_temp.student()),
  '23503',
  null,
  'setting programme_id to a DIFFERENT programme than the existing cohort is refused'
);

select lives_ok(
  format($$ update users set programme_id = %L where id = %L $$,
         pg_temp.programme('EB1'), pg_temp.student()),
  'setting programme_id to the SAME programme as the existing cohort is allowed'
);

select lives_ok(
  format($$ update users set cohort_id = null, programme_id = null where id = %L $$,
         pg_temp.student()),
  'both sides null satisfies the FK (pre-claim state)'
);

select lives_ok(
  format($$ update users set programme_id = %L where id = %L $$,
         pg_temp.programme('EB3'), pg_temp.student()),
  'programme_id alone, with cohort_id null, satisfies the FK (claimed-but-cohortless state, AUTH_FLOW_REFACTOR.md §3 step 5)'
);

-- ---------------------------------------------------------------------------
-- §3 The eight new columns are not client-writable
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.student());

select throws_ok(
  $$ update users set programme_id = (select id from programmes limit 1) where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own programme_id directly'
);
select throws_ok(
  $$ update users set self_sponsored = true where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own self_sponsored directly'
);
select throws_ok(
  $$ update users set student_number = 'EB1/99999/23' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own student_number directly'
);
select throws_ok(
  $$ update users set admission_year = 2099 where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own admission_year directly'
);
select throws_ok(
  $$ update users set school_email = 'nobody@student.chuka.ac.ke' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own school_email directly'
);
select throws_ok(
  $$ update users set school_email_verified_at = now() where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own school_email_verified_at directly'
);
select throws_ok(
  $$ update users set personal_email = 'nobody@gmail.com' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own personal_email directly'
);
select throws_ok(
  $$ update users set personal_email_verified_at = now() where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own personal_email_verified_at directly'
);

select lives_ok(
  $$ update users set first_name = 'Renamed' where id = auth.uid() $$,
  'a student can still edit their own display name — the guard extension did not regress the allowed path'
);

reset role;

select * from finish();
rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd "/home/mikemwongela/VSCodeProjects/Edutime DB"
supabase test db
```

Expected: `17_identity_schema_test.sql` fails immediately — `column "programme_id" of relation "users" does not exist` (or equivalent for the other new columns/constraints). This confirms the test is actually exercising something that doesn't exist yet, not passing vacuously.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/0037_identity_schema.sql`:

```sql
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
```

- [ ] **Step 4: Apply the migration and run the full local reset**

```bash
cd "/home/mikemwongela/VSCodeProjects/Edutime DB"
supabase db reset
```

Expected: completes with no errors — 37 migrations, seed loads clean. This is the check that the additive columns and new constraints don't conflict with existing seed data (they can't: every new column is nullable and unpopulated by seed, so the composite FK is satisfied via the null case for every seeded row).

- [ ] **Step 5: Run the full test suite and verify everything passes**

```bash
supabase test db
```

Expected: all pre-existing test files still pass (regression check — nothing about this change should touch existing behavior), and `17_identity_schema_test.sql` now passes all 15 assertions.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0037_identity_schema.sql supabase/tests/17_identity_schema_test.sql
git commit -m "feat: add identity schema for OAuth-only auth redesign (plan 1/5)

Adds programme_id/self_sponsored/student_number/admission_year and the
school_email/personal_email split to users, structure only. Composite FK
users(cohort_id, programme_id) -> cohorts(id, programme_id) makes a
programme/cohort mismatch structurally impossible. guard_users_self_update
extended to cover all eight new columns. No existing function or trigger is
touched — handle_new_auth_user and claim_roster_row keep writing the
columns they write today."
```

---

## Self-Review Notes

**Spec coverage:** AUTH_FLOW_REFACTOR.md §2's four identity facts (programme_id, self_sponsored, student_number, admission_year), the email-column split, the write-guard update requirement, and the composite-FK transfer-safety note are all covered by Task 1. §§3–8 (Flow 1, Flow 2 + takeover, linking, retirement) are explicitly out of scope for this plan — they are Plans 2–5, each blocked on this plan's columns existing first.

**Placeholder scan:** none — every step has literal SQL or literal shell commands, no "add appropriate X" language.

**Type consistency:** `programme_id uuid`, `student_number text`, `admission_year int`, `self_sponsored boolean`, and the four `text`/`timestamptz` email columns are the only new identifiers this plan introduces; Plans 2–5 must use these exact names and types.
