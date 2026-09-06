# Auth Redesign — Plan 2/5: Flow 1 (Personal-Email Claim) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Flow 1 of the OAuth-only auth redesign — the path by which a personal-email (e.g. Gmail) OAuth account commits its identity facts (programme, self-sponsored flag, student number, admission year) immediately at data entry, as `claim_method = 'provisional'`, before any cohort is chosen — and the guard that keeps a claimed student's programme in sync with the cohort a class rep later approves them into.

**Architecture:** Three additive migrations, structure-then-behavior, exactly as Plan 1 (0037) established: (1) add `users.claim_method`, reusing the existing enum, and extend the write-guard trigger; (2) extend `handle_new_auth_user` — additively, never replacing its existing writes — to also populate `school_email`/`personal_email` based on address domain, alongside the `email`/`email_verified_at` writes the still-live roster system (`claim_roster_row`, unretired until Plan 5) depends on; (3) add `claim_identity_personal()`, the Flow 1 claim RPC, and extend `approve_cohort_join_request()` with a readable programme-match guard ahead of the composite FK that already enforces it structurally.

**Tech Stack:** Supabase/Postgres, SQL migrations, pgTAP (`supabase test db`).

**Spec:** `supabase/AUTH_FLOW_REFACTOR.md` (§2 identity facts and email split, §3 Flow 1, §7 uniqueness/conflict resolution). This plan also depends on the schema Plan 1 already shipped: `supabase/migrations/0037_identity_schema.sql` (the `programme_id`/`self_sponsored`/`student_number`/`admission_year` columns, `users_student_number_unique`, the `school_email`/`personal_email` column pairs, `cohorts_id_programme_unique`, `users_cohort_programme_fk`, and `guard_users_self_update`'s 17-column form).

## Global Constraints

- **Not live, no GitHub remote.** No production data, no live users. A clean, direct rewrite is fine wherever it's the simplest path — no migration-safety hedging for data that doesn't exist. Work lands directly on `main`.
- **`claim_method` is the only column any access decision reads** (AUTH_FLOW_REFACTOR.md §2). Nothing added by this plan may read `student_roster.claim_method` (the old location) — that table and column retire untouched in Plan 5.
- **`handle_new_auth_user`'s existing writes (`email`, `email_verified_at`) are never removed or made conditional differently than today.** `claim_roster_row` (0019) still reads them and the roster system does not retire until Plan 5. This plan only ADDS writes alongside them.
- **The auth sync trigger (`handle_new_auth_user`) is the sole writer of all four email columns** (`school_email`, `school_email_verified_at`, `personal_email`, `personal_email_verified_at`). `claim_identity_personal` never touches any of them — it writes only the four identity columns plus `claim_method`.
- **`CREATE OR REPLACE` discards `proconfig`.** Every `SECURITY DEFINER` function this plan replaces (`guard_users_self_update`, `handle_new_auth_user`) must restate `set search_path = public` in the same statement that replaces it. `approve_cohort_join_request` never had this pin in the first place (verified against 0003) — do not add one; that's a pre-existing, out-of-scope observation, not this plan's job to fix.
- **Every column added to `users` joins `guard_users_self_update`'s blocklist in the same migration that adds the column** — an unlisted column is a column the guard says nothing about, and this codebase treats that as a defect, not a gap to leave open.
- **`student_number` format is deliberately unvalidated beyond non-blank.** AUTH_FLOW_REFACTOR.md is silent on any replacement for the old `reg_number` encoding, and that silence is deliberate (the redesign dissolves that encoding entirely). Do not invent a format check.
- **`admission_year`'s plausibility bound (2000..current year + 1) is a named, adjustable decision**, not derived from the spec, which calls the field "descriptive only" and gives no range. State it visibly wherever it's implemented; do not bury it in an unexplained `check`.
- **File numbers:** migrations `0038`, `0039`, `0040`; tests `18`, `19`, `20` (verified against the current repo state — last migration is `0037`, last test is `17`).

---

### Task 1: `claim_method` column on `users`

**Files:**
- Create: `supabase/migrations/0038_claim_method_column.sql`
- Test: `supabase/tests/18_claim_method_column_test.sql`

**Interfaces:**
- Consumes: the `claim_method` enum type (`create type claim_method as enum ('oauth', 'provisional')`, defined in `supabase/migrations/0017_roster_and_identity.sql:52`) — reused as-is, no new enum values added. Consumes `guard_users_self_update()`'s current 17-column form from `supabase/migrations/0037_identity_schema.sql` (the function this task replaces).
- Produces: `users.claim_method claim_method` (nullable). Later tasks in this plan (Task 3) and Plan 3's Flow 2 function are the only legitimate writers.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/0038_claim_method_column.sql`:

```sql
-- ============================================================================
-- 0038: claim_method column on users
-- ============================================================================
-- Part 2 of 5 of the OAuth-only auth redesign (AUTH_FLOW_REFACTOR.md).
-- STRUCTURE ONLY, same discipline as 0037: no function reads or writes this
-- column yet. AUTH_FLOW_REFACTOR.md §2's rule is that claim_method is the
-- only column any access decision reads — today that decision lives on
-- student_roster.claim_method (0017); this is the column the redesign moves
-- it to, once claim_identity_personal (0040, this plan) and the later Flow 2
-- function (Plan 3) exist to write it. student_roster.claim_method is left
-- completely untouched here; it retires in Plan 5.
--
-- Reuses the existing claim_method enum (0017) for a NEW column — this is
-- safe in a single migration. The restriction on ALTER TYPE ... ADD VALUE
-- (cannot run inside the same transaction that uses the new value) is about
-- adding a value to an EXISTING type; it does not apply to using an
-- already-committed type for a new column. claim_method's two values
-- ('oauth', 'provisional') were both committed back in 0017, so there is
-- nothing that needs splitting across migrations here.
-- ============================================================================

alter table users
  add column claim_method claim_method;

comment on column users.claim_method is
  'The only column any access decision reads (AUTH_FLOW_REFACTOR.md §2). '
  'NULL until an identity is claimed. Written only by claim_identity_personal '
  '(Flow 1, 0040) and its Flow 2 counterpart (Plan 3) — never by client code, '
  'never by this migration.';

-- guard_users_self_update extended — see 0037 §5's note: an unlisted column
-- is a column this trigger says nothing about, so the new column joins the
-- list in the same migration that creates it, even before any writer
-- function for it exists.
--
-- CREATE OR REPLACE discards proconfig — 0019 recorded this after it
-- silently un-pinned handle_new_auth_user. `set search_path = public` is
-- restated, not decoration.
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
  or NEW.claim_method                is distinct from OLD.claim_method
  then
    raise exception
      'Only first_name, last_name and middle_name may be updated directly. '
      'role/cohort_id/class_rep_rank change via create_cohort_with_class_rep, '
      'promote_class_rep or demote_class_rep; faculty_rep status via '
      'bootstrap_faculty_rep; email and email_verified_at are written only by '
      'the auth sync trigger on an OAuth signup; programme_id, '
      'self_sponsored, student_number, admission_year, school_email, '
      'school_email_verified_at, personal_email, personal_email_verified_at '
      'and claim_method are written only by the identity-claim and '
      'identity-link functions.'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_users_self_update() from public, anon, authenticated;
```

- [ ] **Step 2: Write the failing test**

Create `supabase/tests/18_claim_method_column_test.sql`:

```sql
-- ============================================================================
-- 18: claim_method column on users (0038)
-- ============================================================================
-- Covers AUTH_FLOW_REFACTOR.md §2's rule that claim_method is the only
-- column any access decision reads. This migration adds the column and
-- extends guard_users_self_update to it, ahead of any function writing it —
-- same structure-first discipline as 17_identity_schema_test.sql.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;
-- Same fixture id 05_roster_test.sql / 17_identity_schema_test.sql use.
create function pg_temp.student() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;


-- ---------------------------------------------------------------------------
-- §1 The column exists, reuses the existing claim_method enum
-- ---------------------------------------------------------------------------
select lives_ok(
  format($$ update users set claim_method = 'provisional' where id = %L $$, pg_temp.student()),
  'claim_method accepts a valid value of the existing enum'
);

select throws_ok(
  format($$ update users set claim_method = 'bogus' where id = %L $$, pg_temp.student()),
  '22P02', null,
  'claim_method rejects a value outside the existing enum'
);


-- ---------------------------------------------------------------------------
-- §2 Not client-writable
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.student());

select throws_ok(
  $$ update users set claim_method = 'oauth' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own claim_method directly'
);

select lives_ok(
  $$ update users set first_name = 'Renamed' where id = auth.uid() $$,
  'a student can still edit their own display name — the guard extension did not regress the allowed path'
);

reset role;

select * from finish();
rollback;
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `supabase db reset` (applies migrations 0001-0037 only, since 0038 doesn't exist yet) then `supabase test db`

Expected: FAIL — `18_claim_method_column_test.sql` errors immediately, `column "claim_method" of relation "users" does not exist`.

- [ ] **Step 4: Apply the migration and verify the test passes**

Run: `supabase db reset` (now applies through 0038) then `supabase test db`

Expected: PASS — all 4 assertions in test 18 green, and all prior tests (1-17) still green (this task touches `guard_users_self_update`, which every prior identity-column test exercises).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0038_claim_method_column.sql supabase/tests/18_claim_method_column_test.sql
git commit -m "feat: add users.claim_method column (plan 2/5, task 1)"
```

---

### Task 2: `handle_new_auth_user` learns the school/personal email split

**Files:**
- Modify: `supabase/migrations/0039_signup_domain_split.sql` (new file — a `CREATE OR REPLACE` of the existing function from `supabase/migrations/0019_claim_and_takeover.sql`)
- Test: `supabase/tests/19_signup_domain_split_test.sql`

**Interfaces:**
- Consumes: `reg_number_from_email(p_email text) returns text` (`supabase/migrations/0019_claim_and_takeover.sql:49`, `immutable`) — a non-null result means the address is a school address of the expected shape; this task reuses it as the domain test rather than inlining a second copy of the regex. Consumes the four email columns from `0037_identity_schema.sql` (`school_email`, `school_email_verified_at`, `personal_email`, `personal_email_verified_at`).
- Produces: `handle_new_auth_user()` now populates `school_email`/`school_email_verified_at` for an OAuth signup whose address is school-shaped, and `personal_email`/`personal_email_verified_at` for an OAuth signup whose address is not. Task 3's `claim_identity_personal` relies on `personal_email` already being populated by the time a Flow 1 account exists (though it does not read the column itself — see Global Constraints, sole-writer rule).

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/0039_signup_domain_split.sql`:

```sql
-- ============================================================================
-- 0039: handle_new_auth_user learns the school/personal email split
-- ============================================================================
-- Part 3 of 5. ADDITIVE ONLY: this is not a rewrite of the OAuth branch, it
-- is an extension. handle_new_auth_user cannot know, at signup time, whether
-- a new google/apple account will go on to run the old roster claim
-- (claim_roster_row, 0019 — still live, still unretired until Plan 5) or the
-- new Flow 1 identity claim (0040, this plan) or a future Flow 2 claim
-- (Plan 3). All three are, from this trigger's point of view,
-- indistinguishable: "a new OAuth signup". So the old write (users.email /
-- users.email_verified_at, unconditional on provider) is left EXACTLY as it
-- was — claim_roster_row (0019:171) still reads it and must keep working —
-- and the new write (school_email or personal_email, chosen by address
-- domain) is added alongside it, never in its place.
--
-- The domain test reuses reg_number_from_email (0019) rather than inlining a
-- second copy of the '^[^@]+@student\.chuka\.ac\.ke$' regex — 0019's own
-- header warns against a derived/duplicated check drifting from the real
-- one. A non-null result already means "this is a school address of the
-- expected shape"; nothing else about that function's behavior is used
-- here.
--
-- `set search_path` is restated, not decoration — see 0019 §4's own note on
-- this exact function.
-- ============================================================================

create or replace function handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_oauth  boolean;
  v_is_school boolean;
begin
  v_is_oauth  := (new.raw_app_meta_data ->> 'provider') in ('google', 'apple');
  v_is_school := v_is_oauth and reg_number_from_email(new.email) is not null;

  insert into public.users (
    id,
    email,
    email_verified_at,
    first_name,
    last_name,
    middle_name,
    school_email,
    school_email_verified_at,
    personal_email,
    personal_email_verified_at
    -- reg_number is deliberately absent. See 0019 §4's note.
  )
  values (
    new.id,
    -- Unchanged from 0019: only store the REAL email if this was an OAuth
    -- signup; reg-number signups pass the synthetic address in new.email,
    -- which must NOT leak into public.users.email.
    case when v_is_oauth then new.email else null end,
    case when v_is_oauth then now() else null end,
    coalesce(new.raw_user_meta_data ->> 'first_name', ''),
    coalesce(new.raw_user_meta_data ->> 'last_name', ''),
    new.raw_user_meta_data ->> 'middle_name',
    case when v_is_school then new.email else null end,
    case when v_is_school then now() else null end,
    case when v_is_oauth and not v_is_school then new.email else null end,
    case when v_is_oauth and not v_is_school then now() else null end
  );
  return new;
end;
$$;

revoke execute on function handle_new_auth_user()
  from public, anon, authenticated, service_role;
```

- [ ] **Step 2: Write the failing test**

Create `supabase/tests/19_signup_domain_split_test.sql`:

```sql
-- ============================================================================
-- 19: handle_new_auth_user learns the school/personal email split (0039)
-- ============================================================================
-- Covers three signup shapes: the still-live password/synthetic path (old
-- columns unaffected, new columns untouched), an OAuth signup with a real
-- school address (both old AND new columns populate — old because
-- claim_roster_row still reads them until Plan 5 retires the roster), and an
-- OAuth signup with a personal address (old columns populate as before, new
-- personal_email columns populate, school_email columns stay null).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);


-- ---------------------------------------------------------------------------
-- (a) Password/synthetic signup — unaffected
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '44444444-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
  'password.case@auth.internal', 'x', now(), now(),
  jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
  jsonb_build_object('first_name', 'Password', 'last_name', 'Case'),
  now(), now(), '', '', '', ''
);

select is(
  (select email from users where id = '44444444-0000-4000-8000-000000000001'),
  null, 'password/synthetic signup: email stays null, exactly as before'
);
select is(
  (select school_email from users where id = '44444444-0000-4000-8000-000000000001'),
  null, 'password/synthetic signup: school_email stays null'
);
select is(
  (select personal_email from users where id = '44444444-0000-4000-8000-000000000001'),
  null, 'password/synthetic signup: personal_email stays null'
);


-- ---------------------------------------------------------------------------
-- (b) OAuth signup, school address
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '44444444-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
  'eb1.88888.26@student.chuka.ac.ke', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'School', 'last_name', 'Address'),
  now(), now(), '', '', '', ''
);

select is(
  (select email from users where id = '44444444-0000-4000-8000-000000000002'),
  'eb1.88888.26@student.chuka.ac.ke',
  'OAuth school-address signup: email still populates — claim_roster_row still reads it'
);
select is(
  (select school_email from users where id = '44444444-0000-4000-8000-000000000002'),
  'eb1.88888.26@student.chuka.ac.ke',
  'OAuth school-address signup: school_email populates'
);
select isnt(
  (select school_email_verified_at from users where id = '44444444-0000-4000-8000-000000000002'),
  null, 'OAuth school-address signup: school_email_verified_at is set'
);
select is(
  (select personal_email from users where id = '44444444-0000-4000-8000-000000000002'),
  null, 'OAuth school-address signup: personal_email stays null'
);


-- ---------------------------------------------------------------------------
-- (c) OAuth signup, personal address
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '44444444-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
  'someone.new@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Personal', 'last_name', 'Address'),
  now(), now(), '', '', '', ''
);

select is(
  (select email from users where id = '44444444-0000-4000-8000-000000000003'),
  'someone.new@gmail.com',
  'OAuth personal-address signup: email still populates, same as before this migration'
);
select is(
  (select personal_email from users where id = '44444444-0000-4000-8000-000000000003'),
  'someone.new@gmail.com',
  'OAuth personal-address signup: personal_email populates'
);
select isnt(
  (select personal_email_verified_at from users where id = '44444444-0000-4000-8000-000000000003'),
  null, 'OAuth personal-address signup: personal_email_verified_at is set'
);
select is(
  (select school_email from users where id = '44444444-0000-4000-8000-000000000003'),
  null, 'OAuth personal-address signup: school_email stays null'
);

select * from finish();
rollback;
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `supabase db reset` (applies through 0038 only) then `supabase test db`

Expected: FAIL — `19_signup_domain_split_test.sql` fails on the `school_email`/`personal_email` assertions (both null in every case, since `handle_new_auth_user` doesn't populate them yet).

- [ ] **Step 4: Apply the migration and verify the test passes**

Run: `supabase db reset` (now applies through 0039) then `supabase test db`

Expected: PASS — all 11 assertions in test 19 green, and tests 6 and 16 (which both insert `auth.users` rows through this same trigger) still green.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0039_signup_domain_split.sql supabase/tests/19_signup_domain_split_test.sql
git commit -m "feat: split signup email writes by domain, additively (plan 2/5, task 2)"
```

---

### Task 3: `claim_identity_personal` and the programme-match approval guard

**Files:**
- Create: `supabase/migrations/0040_claim_identity_personal.sql`
- Test: `supabase/tests/20_claim_identity_personal_test.sql`

**Interfaces:**
- Consumes: `users.programme_id`, `self_sponsored`, `student_number`, `admission_year`, `claim_method` (`0037`, `0038`). Consumes `programmes(id)` for existence-checking. Consumes the existing `approve_cohort_join_request(p_request_id uuid, p_decided_by uuid) returns void` (`supabase/migrations/0003_cohort_membership.sql:44`) and `cohort_join_requests` table — this task replaces the function body, preserving its existing authorization surface (or lack thereof) exactly.
- Produces: `claim_identity_personal(p_programme_id uuid, p_self_sponsored boolean, p_student_number text, p_admission_year int, p_acting_user uuid) returns void` — the Flow 1 claim RPC. Produces the extended `approve_cohort_join_request`, which now refuses (readable error, before the composite FK fires) when the target student's `programme_id` disagrees with the target cohort's `programme_id`.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/0040_claim_identity_personal.sql`:

```sql
-- ============================================================================
-- 0040: Flow 1 — claim_identity_personal, and the programme-match guard
-- ============================================================================
-- Part 4 of 5. AUTH_FLOW_REFACTOR.md §3: a personal-email OAuth account picks
-- a programme, toggles self-sponsored, types a student number and admission
-- year, and that commits immediately as claim_method = 'provisional' —
-- BEFORE any cohort is chosen. This is deliberate (§3 step 4): the
-- users_student_number_unique constraint (0037) is the only thing standing
-- between two people racing to claim the same student, and it can only do
-- that job at the moment of the write it actually guards.
--
-- Contents
--   §1  claim_identity_personal() — the Flow 1 claim
--   §2  approve_cohort_join_request — programme-match guard added
-- ============================================================================


-- ============================================================================
-- 1. claim_identity_personal
-- ============================================================================
-- Mirrors claim_roster_row's (0019) idempotent-reclaim and one-identity-per-
-- account shape exactly, adapted to write facts directly onto users instead
-- of binding to a separate roster row — there is no roster row in this
-- design.
--
-- Refuses outright if the caller already holds an 'oauth' claim. This is not
-- defensive — AUTH_FLOW_REFACTOR.md §4's asymmetry (a personal-email account
-- can never evict a school-email one) and §7's non-negotiable (oauth always
-- displaces provisional, never the reverse) both break if this function
-- could overwrite an oauth claim.
--
-- student_number format: deliberately NOT validated beyond non-blank. The
-- old reg_number format lived in parse_reg_number's encoding (0017), which
-- this redesign dissolves — AUTH_FLOW_REFACTOR.md is silent on any
-- replacement format, and that silence is deliberate. The uniqueness
-- constraint (0037) is the real gate.
--
-- admission_year bound (2000..current year + 1): a named, adjustable
-- decision, not derived from the spec — AUTH_FLOW_REFACTOR.md calls the
-- field "descriptive only" and gives no range. Loosen or tighten here if it
-- turns out wrong; nothing else depends on the exact bound.
--
-- Never writes school_email/personal_email — 0039's auth sync trigger is
-- their sole writer (Global Constraints).
create or replace function claim_identity_personal(
  p_programme_id   uuid,
  p_self_sponsored boolean,
  p_student_number text,
  p_admission_year int,
  p_acting_user    uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user users;
  v_norm text;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_user from users where id = p_acting_user;

  if v_user.id is null then
    raise exception 'Acting user % not found', p_acting_user;
  end if;

  if v_user.claim_method = 'oauth' then
    raise exception
      'An OAuth-verified identity cannot be replaced by a personal-email claim';
  end if;

  v_norm := nullif(trim(p_student_number), '');

  if v_norm is null then
    raise exception 'A student number is required';
  end if;

  -- Idempotent re-claim, and a guard against one account collecting
  -- identities — same shape as claim_roster_row (0019).
  if v_user.claim_method = 'provisional' then
    if v_user.student_number = v_norm then
      return;
    end if;
    raise exception 'This account has already claimed a different identity';
  end if;

  if not exists (select 1 from programmes where id = p_programme_id) then
    raise exception 'Programme % does not exist', p_programme_id;
  end if;

  if p_admission_year < 2000
     or p_admission_year > extract(year from now())::int + 1 then
    raise exception 'Admission year % is not plausible', p_admission_year;
  end if;

  update users
  set programme_id   = p_programme_id,
      self_sponsored  = p_self_sponsored,
      student_number  = v_norm,
      admission_year  = p_admission_year,
      claim_method    = 'provisional'
  where id = p_acting_user;

exception
  when unique_violation then
    raise exception 'Student number % is already claimed', v_norm;
end;
$$;

comment on function claim_identity_personal(uuid, boolean, text, int, uuid) is
  'Flow 1 (AUTH_FLOW_REFACTOR.md §3): a personal-email OAuth account commits '
  'its identity facts immediately, as claim_method = provisional. Never '
  'touches school_email/personal_email — the auth sync trigger (0039) is '
  'their sole writer.';

revoke execute on function claim_identity_personal(uuid, boolean, text, int, uuid)
  from public, anon;
grant  execute on function claim_identity_personal(uuid, boolean, text, int, uuid)
  to authenticated, service_role;


-- ============================================================================
-- 2. approve_cohort_join_request — programme-match guard
-- ============================================================================
-- Additive change to the existing function (0003): before moving the student
-- into the cohort, refuse if the student already carries a programme_id
-- (set by claim_identity_personal, or later by Flow 2) that disagrees with
-- the target cohort's own programme_id. cohorts.programme_id is a real,
-- NOT NULL column on every cohort row including streams — cohorts_stream_
-- inherits (0025) forces a stream's own programme_id to equal its parent's
-- — so reading it directly off the target cohort row is correct with no
-- parent-cohort lookup needed.
--
-- This check only ever fires for a student who HAS a programme_id — an
-- old-style roster account (programme_id still null, since Flow 1/2 haven't
-- claimed it) skips the check entirely, exactly as approval worked before
-- this migration. The composite FK (0037 §4) is the actual enforcement;
-- this check exists only to turn its raw constraint violation into a
-- readable sentence raised before the FK would fire.
--
-- Everything else in this function — including its lack of a p_decided_by /
-- auth.uid() check, and its lack of a search_path pin — is left exactly as
-- it was; both are pre-existing and out of scope for this migration.
create or replace function approve_cohort_join_request(
  p_request_id uuid,
  p_decided_by uuid
)
returns void
language plpgsql
security definer
as $$
declare
  v_student_id        uuid;
  v_cohort_id         uuid;
  v_student_programme uuid;
  v_cohort_programme  uuid;
begin
  select student_id, cohort_id
  into v_student_id, v_cohort_id
  from cohort_join_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    raise exception 'No pending join request with id %', p_request_id;
  end if;

  select programme_id into v_student_programme from users where id = v_student_id;
  select programme_id into v_cohort_programme from cohorts where id = v_cohort_id;

  if v_student_programme is not null
     and v_student_programme is distinct from v_cohort_programme then
    raise exception
      'This student''s programme does not match this cohort''s programme — approval refused';
  end if;

  update cohort_join_requests
  set status = 'approved', decided_by = p_decided_by, decided_at = now()
  where id = p_request_id;

  update users
  set cohort_id = v_cohort_id
  where id = v_student_id;
end;
$$;
```

- [ ] **Step 2: Write the failing test**

Create `supabase/tests/20_claim_identity_personal_test.sql`:

```sql
-- ============================================================================
-- 20: claim_identity_personal and the approval programme-match guard (0040)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §3 (Flow 1) end to end: a fresh personal-email OAuth
-- account claims its identity facts immediately, collisions on
-- student_number are caught at that exact moment, an oauth-verified account
-- can never be downgraded by this path, and a class rep's approval refuses a
-- programme mismatch with a readable error before the composite FK would.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;
create function pg_temp.programme(p_code text) returns uuid language sql stable as $$
  select id from programmes where code = p_code;
$$;
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
-- Plain student, BSC-CS 2023 (programme code 'EB1') — same fixture id
-- 05_roster_test.sql / 17_identity_schema_test.sql / 18 use. programme_id is
-- still null on this fixture (never gone through Flow 1/2) — used for the
-- backward-compat regression check.
create function pg_temp.old_style_student() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;

-- Claimant A: succeeds, later used for the matching-programme approval.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
  'claimant.a@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'A'),
  now(), now(), '', '', '', ''
);
-- Claimant B: attempts, never succeeds (used only for the failure paths).
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
  'claimant.b@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'B'),
  now(), now(), '', '', '', ''
);
-- Claimant C: succeeds with a different student_number, later used for the
-- mismatched-programme approval.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
  'claimant.c@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'C'),
  now(), now(), '', '', '', ''
);
-- Claimant D: already oauth-claimed (simulating a Flow 2 account), used only
-- for the refusal test — force-set directly, bypassing the guard the same
-- way 17/18's own setup does (default test role is not 'authenticated').
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '55555555-0000-4000-8000-000000000004', 'authenticated', 'authenticated',
  'claimant.d@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Claimant', 'last_name', 'D'),
  now(), now(), '', '', '', ''
);
update users set claim_method = 'oauth' where id = '55555555-0000-4000-8000-000000000004';


-- ---------------------------------------------------------------------------
-- §1 The claim itself
-- ---------------------------------------------------------------------------
select pg_temp.act_as('55555555-0000-4000-8000-000000000001');

select lives_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0001', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000001'::uuid),
  'a fresh personal-email account can claim an identity'
);

select is(
  (select claim_method::text from users where id = '55555555-0000-4000-8000-000000000001'),
  'provisional', '...and the claim is marked provisional'
);

select is(
  (select student_number from users where id = '55555555-0000-4000-8000-000000000001'),
  'SP0001', '...and the student_number really was written'
);

select lives_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0001', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000001'::uuid),
  'reclaiming the SAME student_number is idempotent, not an error'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP9999', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000001'::uuid),
  'P0001', null,
  'claiming a DIFFERENT student_number on an already-claimed account is refused'
);


-- ---------------------------------------------------------------------------
-- §2 Collisions and validation, via claimant B (never succeeds)
-- ---------------------------------------------------------------------------
select pg_temp.act_as('55555555-0000-4000-8000-000000000002');

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0001', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'a second account cannot claim a student_number another account already holds'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0003', 2024, %L) $$,
         gen_random_uuid(), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'claiming with a programme_id that does not exist is refused'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, '   ', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'a blank/whitespace-only student_number is refused'
);

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0003', 1990, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000002'::uuid),
  'P0001', null,
  'an implausible admission_year is refused'
);


-- ---------------------------------------------------------------------------
-- §3 An oauth-verified account can never be downgraded by this path
-- ---------------------------------------------------------------------------
select pg_temp.act_as('55555555-0000-4000-8000-000000000004');

select throws_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0004', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000004'::uuid),
  'P0001', null,
  'a personal-email claim can never overwrite an existing oauth claim'
);


-- ---------------------------------------------------------------------------
-- §4 approve_cohort_join_request's programme-match guard
-- ---------------------------------------------------------------------------
-- Claimant C claims EB1 with a distinct student_number, to use against a
-- mismatched (EB3) cohort target.
select pg_temp.act_as('55555555-0000-4000-8000-000000000003');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, 'SP0002', 2024, %L) $$,
         pg_temp.programme('EB1'), '55555555-0000-4000-8000-000000000003'::uuid),
  'claimant C claims EB1 with its own student_number, for the mismatch check below'
);

insert into cohort_join_requests (student_id, cohort_id)
values ('55555555-0000-4000-8000-000000000003', pg_temp.cohort('EB3', 2023));

select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '55555555-0000-4000-8000-000000000003'::uuid),
              %L) $$,
         pg_temp.old_style_student()),
  'P0001', null,
  'approving a student into a cohort whose programme does not match theirs is refused'
);

insert into cohort_join_requests (student_id, cohort_id)
values ('55555555-0000-4000-8000-000000000001', pg_temp.cohort('EB1', 2023));

select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '55555555-0000-4000-8000-000000000001'::uuid),
              %L) $$,
         pg_temp.old_style_student()),
  'approving a student into a cohort whose programme DOES match theirs succeeds'
);

select is(
  (select cohort_id from users where id = '55555555-0000-4000-8000-000000000001'),
  pg_temp.cohort('EB1', 2023),
  '...and cohort_id really was set'
);

-- Regression: an old-style roster account with programme_id still null is
-- approved exactly as before this migration, regardless of target cohort.
insert into cohort_join_requests (student_id, cohort_id)
values (pg_temp.old_style_student(), pg_temp.cohort('EB3', 2023));

select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = %L),
              %L) $$,
         pg_temp.old_style_student(), pg_temp.old_style_student()),
  'an old-style account with no programme_id is approved unaffected by the new guard'
);

select * from finish();
rollback;
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `supabase db reset` (applies through 0039 only) then `supabase test db`

Expected: FAIL — `20_claim_identity_personal_test.sql` errors immediately, `function claim_identity_personal(uuid, boolean, text, integer, uuid) does not exist`.

- [ ] **Step 4: Apply the migration and verify the test passes**

Run: `supabase db reset` (now applies through 0040) then `supabase test db`

Expected: PASS — all 15 assertions in test 20 green, and the full suite (tests 1-19) still green, including tests 02/03/04/07/08 which exercise `approve_cohort_join_request` indirectly through cohort-membership fixtures.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0040_claim_identity_personal.sql supabase/tests/20_claim_identity_personal_test.sql
git commit -m "feat: add claim_identity_personal and the approval programme-match guard (plan 2/5, task 3)"
```

---

## Self-Review Notes

**Spec coverage:** AUTH_FLOW_REFACTOR.md §3 (Flow 1) steps 1-3 (OAuth, name display, programme/self-sponsored/student-number/admission-year entry) are client-side and out of this plan's scope (no client exists yet — this is the backend). Step 4 (commit immediately as provisional) is Task 3. Step 5 (account inert, no cohort yet) falls out of the composite FK from Plan 1 plus this plan doing nothing to `cohort_id`. Steps 6-8 (cohort suggestion, join request, approval) are the existing `cohort_join_requests` mechanism, extended in Task 3 only with the programme-match guard. §7's uniqueness point (student_number is the collision gate, caught at claim time) is Task 3's exception handler.

**Placeholder scan:** none — every task has literal SQL and literal test assertions.

**Type consistency:** `claim_identity_personal`'s parameter order (`p_programme_id uuid, p_self_sponsored boolean, p_student_number text, p_admission_year int, p_acting_user uuid`) is used identically in the migration (Task 3) and every test call (test 20). `approve_cohort_join_request`'s signature (`p_request_id uuid, p_decided_by uuid`) is unchanged from `0003`.

**Carried-forward item, not this plan's job:** the escalated ruling from Plan 1's final review — that `users`' table-wide `select` grant (`0014`) plus `0006_rls.sql`'s permissive `users_read_all` policy expose every column, including the new email columns, to any authenticated reader — becomes live risk the moment this plan's migrations land, since Task 2 is the first code path to write real data into `personal_email`/`school_email`. This plan does not fix it (out of scope: it's an RLS/view change, not an auth-flow change), but implementers and reviewers should treat it as a known, named gap, not a surprise.
