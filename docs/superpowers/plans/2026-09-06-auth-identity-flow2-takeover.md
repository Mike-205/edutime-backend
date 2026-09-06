# Auth Redesign — Plan 3/5: Flow 2 (School-Email) and Takeover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Flow 2 of the OAuth-only auth redesign — the path by which a `@student.chuka.ac.ke` OAuth account's identity facts are derived from its proven address and committed only at the moment a class rep approves its cohort-join request (never at signup) — including the takeover this triggers when the derived `student_number` is already held by a `provisional` (Flow 1) account.

**Architecture:** Two additive migrations, both `CREATE OR REPLACE`ing the same new internal helper function, `commit_school_identity()`, called from one new branch inside `approve_cohort_join_request` (already modified three times before this plan — 0008, 0016, 0029, 0040 — this is its fourth and final modification in this plan sequence). The first migration delivers the derive-and-write path with no existing-holder handling (an accepted interim state — a collision hits a raw constraint error, not silent corruption). The second migration adds the graceful takeover: evict-or-escalate, exactly re-hosting `claim_roster_row`'s (0019) four gates onto `users` columns, minus the one gate that cannot apply here.

**Tech Stack:** Supabase/Postgres, SQL migrations, pgTAP (`supabase test db`).

**Spec:** `supabase/AUTH_FLOW_REFACTOR.md` §4 (Flow 2), §7 (uniqueness/conflict resolution), §8 (audit trail — no schema change needed yet, see Global Constraints). This plan builds on Plan 1's schema (`0037`, `0038`) and Plan 2's shipped Flow 1 (`0039`'s `handle_new_auth_user` dual-tier email split, `0040`'s `claim_identity_personal` and the first `approve_cohort_join_request` guard, `426688b`'s `is_school_email` correction).

## Global Constraints

- **Not live, no GitHub remote.** No production data, no live users. A clean, direct rewrite is fine wherever it's the simplest path. Work lands directly on `main`.
- **`commit_school_identity` derives ONLY from `users.school_email`, read server-side — never from a client-supplied parameter.** The whole point of Flow 2 is that the four facts are backed by a provider-proven address; a function parameter for any of them would hand the client the one thing this design refuses to let it assert.
- **`parse_reg_number`'s result type is `reg_number_parts` (`supabase/migrations/0017_roster_and_identity.sql`), and its self-sponsorship field is named `is_self_sponsored`.** The `users` column it writes to is named `self_sponsored`. These are two different names for related but distinct things — do not let them blur into each other in any `UPDATE` statement.
- **`commit_school_identity` is internal only — no `EXECUTE` granted to any role**, exactly matching `sync_roster_placement`'s (`0029`) existing pattern (`revoke ... from public, anon, authenticated, service_role`). It is only ever called from inside `approve_cohort_join_request`, which has already validated the caller and the target by the time it's reached.
- **The discriminator that routes a join-request approval into the Flow 2 branch is three clauses, all load-bearing:** `claim_method is null AND school_email_verified_at is not null AND cohort_id is null`. The third clause is not defensive padding — without it, seeded fixture Faith Mueni (`id 22222222-0000-4000-8000-000000000013`, `eb1.67340.23@student.chuka.ac.ke`, provider `google`) matches the first two clauses (proven school email, never claimed via either flow) but is already placed in BSC-CS 2023 via the pre-redesign roster/seed process — every one of the 18 seeded users is placed in one of the 4 seed cohorts, so `cohort_id is null` is what keeps every existing fixture out of this new branch, and it only ever fires for an account created fresh within this plan's own tests. Without it, `20_claim_identity_personal_test.sql`'s existing §4 regression assertion (approving Faith Mueni into a mismatched cohort, expecting plain success) would silently start failing.
- **This does not touch `roster_audit_log`'s schema.** AUTH_FLOW_REFACTOR.md §8 describes renaming the table, dropping `roster_id`, and rebuilding the action enum (`claimed`, `takeover`, `unbound`, `dispute_resolved`, plus a new `identity_linked`) — all of that is Plan 5 (retirement) work. This plan writes into the table exactly as it exists today: `roster_id` is left `null` (no roster row exists for these accounts — nothing to point at), and the existing `'takeover'`/`'claimed'` enum values (already present) are reused as-is.
- **`CREATE OR REPLACE FUNCTION` discards `proconfig`.** Every `SECURITY DEFINER` function this plan creates or replaces (`commit_school_identity`, `approve_cohort_join_request`) must restate `set search_path = public` in the same statement.
- **File numbers:** migrations `0041`, `0042`; tests `21`, `22` (verified against the current repo state — last migration is `0040`, last test is `20`; the final fix wave for Plan 2 modified `0039`/`0040` in place and did not add new files).

---

### Task 1: `commit_school_identity` — derive, guard, write (no takeover yet)

**Files:**
- Create: `supabase/migrations/0041_commit_school_identity.sql`
- Test: `supabase/tests/21_commit_school_identity_test.sql`

**Interfaces:**
- Consumes: `reg_number_from_email(p_email text) returns text` (`0019`, `immutable`, granted to `authenticated`/`service_role`). `parse_reg_number(p_reg_number text) returns reg_number_parts` (`0017`, `stable security definer`, granted to `authenticated`/`service_role`) — the composite type's fields are `programme_id uuid, programme_code text, is_self_sponsored boolean, student_number text, admission_year int`. Consumes `users.school_email`, `.school_email_verified_at`, `.claim_method`, `.cohort_id`, `.role`, `.programme_id` (all from Plan 1/2). Consumes the current `approve_cohort_join_request(p_request_id uuid, p_decided_by uuid) returns void` body exactly as it stands after `0040` (reproduced verbatim below — verified directly against the repo, not assumed from an earlier migration).
- Produces: `commit_school_identity(p_student_id uuid, p_cohort_id uuid, p_actor_id uuid) returns void` — internal only. Produces the extended `approve_cohort_join_request`, which now branches into it. Task 2 replaces `commit_school_identity`'s body again (same signature) to add takeover handling — nothing else in this task's surface changes under it.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/0041_commit_school_identity.sql`:

```sql
-- ============================================================================
-- 0041: Flow 2 — commit_school_identity (first-claim path)
-- ============================================================================
-- Part 3 of 5 of the OAuth-only auth redesign (AUTH_FLOW_REFACTOR.md).
-- AUTH_FLOW_REFACTOR.md §4: unlike Flow 1, a school-email account's identity
-- facts are never staged — they are always re-derivable from the proven
-- school_email address, so nothing needs writing until the moment a class
-- rep approves the student's join request ("Takeover on approval, not on
-- write", §4 step 5).
--
-- This migration delivers the FIRST-CLAIM path only: derive the four facts,
-- refuse if they don't resolve, refuse if they don't match the target
-- cohort's programme, and write them. It deliberately does NOT yet handle an
-- existing holder of the derived student_number — if one exists, the final
-- write below hits the raw users_student_number_unique constraint
-- (unique_violation) rather than a graceful takeover. That is an accepted
-- interim state, not an oversight: the constraint still prevents any silent
-- corruption, and the graceful eviction/escalation logic is a genuinely
-- separate piece of complexity, added on top of this same function in the
-- next migration (0042).
--
-- Contents
--   §1  commit_school_identity() — derive, guard, write (no takeover yet)
--   §2  approve_cohort_join_request — branches into it
-- ============================================================================


-- ============================================================================
-- 1. commit_school_identity
-- ============================================================================
-- Internal only, exactly like sync_roster_placement (0029): no EXECUTE
-- granted to any role. It trusts its caller — approve_cohort_join_request has
-- already established that p_actor_id is the real class rep of this cohort
-- and that p_student_id names a plain student, before ever reaching here.
--
-- Re-derives from users.school_email SERVER-SIDE, always — never from a
-- client-supplied value. The whole point of Flow 2 is that the four facts
-- are backed by a provider-proven address; accepting them as parameters
-- would hand the client the one thing this design refuses to let it assert.
--
-- reg_number_from_email + parse_reg_number, chained exactly as the boundary
-- parser (AUTH_FLOW_REFACTOR.md §2) describes — both already exist
-- (0017/0019), both already granted to authenticated for the client-side
-- "suggest a cohort" step this migration does not need to duplicate.
--
-- parse_reg_number's result field is is_self_sponsored (the type is
-- reg_number_parts, 0017) — NOT self_sponsored, which is the column name on
-- users. Do not let the two names blur into each other.
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

  update users
  set programme_id   = v_derived.programme_id,
      self_sponsored = v_derived.is_self_sponsored,
      student_number = v_derived.student_number,
      admission_year = v_derived.admission_year,
      claim_method   = 'oauth'
  where id = p_student_id;

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    null, v_derived.student_number, 'claimed', p_actor_id, p_student_id,
    jsonb_build_object('method', 'oauth', 'cohort_id', p_cohort_id)
  );
end;
$$;

comment on function commit_school_identity(uuid, uuid, uuid) is
  'Flow 2 (AUTH_FLOW_REFACTOR.md §4): derives a student''s identity facts '
  'from their proven school_email and commits them as claim_method = oauth, '
  'at approval time. First-claim path only as of this migration — an '
  'existing holder of the derived student_number hits a raw unique_violation '
  'here; 0042 adds the graceful takeover. Internal only, called by '
  'approve_cohort_join_request.';

revoke execute on function commit_school_identity(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;


-- ============================================================================
-- 2. approve_cohort_join_request — branches into the Flow 2 path
-- ============================================================================
-- Additive change to the existing function (last replaced in 0040). Every
-- pre-existing check (p_decided_by/auth.uid() self-check, class-rep-of-this-
-- cohort authorization, student-role check, 0040's stored-programme-match
-- guard, sync_roster_placement call) is preserved verbatim, in original
-- order. The only new logic is the branch below, and fetching the full
-- student row once (v_student) instead of just its role, so both the
-- existing role check and the new discriminator can read off it.
--
-- THE DISCRIMINATOR: claim_method is null AND school_email_verified_at is
-- not null AND cohort_id is null. See Global Constraints for why all three
-- clauses are load-bearing — in particular, why cohort_id is null is what
-- keeps every existing seeded fixture out of this branch.
--
-- 0040's stored-programme-match guard moves into the else branch unchanged
-- — it already no-ops correctly for a still-unclaimed Flow 2 account
-- (programme_id is null until commit_school_identity writes it), so it was
-- never wrong, just insufficient on its own: it checks what's ALREADY
-- STORED, and a Flow 2 account has nothing stored yet. commit_school_identity
-- has its own separate programme-match check (§1 above), against the
-- DERIVED programme_id — the two guards are not redundant, they check
-- different data at different moments.
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

  perform sync_roster_placement(v_student_id, v_cohort_id, p_decided_by, 'join_request_approved');
end;
$$;
```

- [ ] **Step 2: Write the failing test**

Create `supabase/tests/21_commit_school_identity_test.sql`. Note: this codebase's own convention is that an internal, `EXECUTE`-revoked-from-everyone helper (see `sync_roster_placement`, never called directly by any test file) is tested only through its public caller — this file follows that convention and never calls `commit_school_identity` directly.

```sql
-- ============================================================================
-- 21: commit_school_identity — Flow 2 first-claim path (0041)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §4: a school-email account's identity is derived and
-- committed only at approval time. Covers a clean first claim, the two
-- refusal paths (unparseable address, programme mismatch), the accepted
-- interim raw-constraint-failure state for a student_number collision (0042
-- replaces this with a graceful takeover), and — the one most likely to
-- regress silently — that an already-placed account with a proven-but-
-- unclaimed school email does NOT get swept into this new branch.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(9);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;
create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year;
$$;
-- Real seeded class reps, same ids 20_claim_identity_personal_test.sql uses.
create function pg_temp.eb1_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;   -- class rep, BSC-CS 2023 (EB1)
create function pg_temp.eb3_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000031'::uuid $$;   -- class rep, BSC-ACS 2023 (EB3)
-- Faith Mueni: proven school email, never claimed via either flow, but
-- ALREADY placed in BSC-CS 2023 by the pre-redesign seed process. This is
-- the exact fixture the discriminator's cohort_id-is-null clause exists for.
create function pg_temp.already_placed_school_account() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;

create function pg_temp.new_school_signup(p_id uuid, p_email text) returns void language sql as $$
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  )
  values (
    '00000000-0000-0000-0000-000000000000',
    p_id, 'authenticated', 'authenticated',
    p_email, 'x', now(), now(),
    jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
    jsonb_build_object('first_name', 'Test', 'last_name', 'Account'),
    now(), now(), '', '', '', ''
  );
$$;


-- ---------------------------------------------------------------------------
-- §1 A clean first claim
-- ---------------------------------------------------------------------------
select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000001', 'eb1.98001.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000001', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000001'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'a fresh school-email account is approved and its identity derived and committed'
);

select is(
  (select claim_method::text from users where id = '66666666-0000-4000-8000-000000000001'),
  'oauth', '...as claim_method = oauth'
);
select is(
  (select student_number from users where id = '66666666-0000-4000-8000-000000000001'),
  '98001', '...with the student_number correctly derived from the address'
);
select is(
  (select cohort_id from users where id = '66666666-0000-4000-8000-000000000001'),
  pg_temp.cohort('EB1', 2023),
  '...and cohort_id set, same as any other approval'
);


-- ---------------------------------------------------------------------------
-- §2 Refusals
-- ---------------------------------------------------------------------------
-- Unparseable local part — the same address 06_claim_and_takeover_test.sql
-- uses to demonstrate this exact non-parsing shape.
select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000002', 'j.doe@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000002', pg_temp.cohort('EB1', 2023));

select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000002'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'P0001',
  'Could not derive a student identity from this school email. A faculty rep must resolve this.',
  'an address that does not parse to a student number is refused'
);

-- Derived programme (EB1) does not match the requested cohort's (EB3).
select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000003', 'eb1.98003.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000003', pg_temp.cohort('EB3', 2023));

select pg_temp.act_as(pg_temp.eb3_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000003'::uuid),
              %L) $$,
         pg_temp.eb3_rep()),
  'P0001',
  'The identity derived from this school email does not match this cohort''s programme',
  'a derived programme that does not match the requested cohort is refused'
);


-- ---------------------------------------------------------------------------
-- §3 Accepted interim state: a student_number collision hits the raw
-- constraint, not a graceful takeover (0042 replaces this).
-- ---------------------------------------------------------------------------
-- Force an existing, unrelated seeded account to hold the number the next
-- signup will derive. This does NOT reuse another account's email address —
-- auth.users.email is unique, and two genuinely different real addresses
-- cannot derive the same student number (the mapping is 1:1), so a direct
-- force-set is the only way to construct this collision for a test. Uses a
-- plain seeded student not referenced anywhere else in this file.
--
-- claim_method is forced to 'provisional' alongside student_number, not left
-- null, because that is the only state production can actually produce —
-- the sole writer of student_number, claim_identity_personal, always sets
-- claim_method in the same statement. A student_number-only fixture would
-- silently stop matching reality the moment 0042 (Task 2) adds gates that
-- read claim_method, and 0042 DOES change this exact assertion's outcome —
-- see Task 2's own required test edit below.
update users
set student_number = '98004', claim_method = 'provisional'
where id = '22222222-0000-4000-8000-000000000015';

select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000004', 'eb1.98004.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000004', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000004'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  '23505', null,
  'a student_number already held by another account hits the raw uniqueness constraint (interim state before 0042)'
);


-- ---------------------------------------------------------------------------
-- §4 The discriminator's cohort_id-is-null clause: an already-placed account
-- with a proven-but-unclaimed school email must NOT be swept into this
-- branch.
-- ---------------------------------------------------------------------------
insert into cohort_join_requests (student_id, cohort_id)
values (pg_temp.already_placed_school_account(), pg_temp.cohort('EB3', 2023));

select pg_temp.act_as(pg_temp.eb3_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = %L),
              %L) $$,
         pg_temp.already_placed_school_account(), pg_temp.eb3_rep()),
  'an already-placed account with a proven school email is approved via the plain path, unaffected by the new branch'
);

select is(
  (select programme_id from users where id = pg_temp.already_placed_school_account()),
  null,
  '...and its programme_id is still null — proof it was NOT swept into commit_school_identity'
);

select * from finish();
rollback;
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `supabase db reset` (applies through `0040` only) then `supabase test db`

Expected: FAIL — `21_commit_school_identity_test.sql` errors immediately, `function commit_school_identity(uuid, uuid, uuid) does not exist`.

- [ ] **Step 4: Apply the migration and verify the test passes**

Run: `supabase db reset` (now applies through `0041`) then `supabase test db`

Expected: PASS — all 9 assertions in test 21 green, and the full prior suite (tests 1-20, 458 assertions) still green — in particular `20_claim_identity_personal_test.sql`'s own §4 regression assertion using this same "already placed" fixture must still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0041_commit_school_identity.sql supabase/tests/21_commit_school_identity_test.sql
git commit -m "feat: add commit_school_identity, first-claim path (plan 3/5, task 1)"
```

---

### Task 2: `commit_school_identity` gains the takeover path

**Files:**
- Create: `supabase/migrations/0042_school_identity_takeover.sql`
- Create: `supabase/tests/22_school_identity_takeover_test.sql`
- Modify: `supabase/tests/21_commit_school_identity_test.sql` — §3's assertion changes shape, not just mechanism (see Step 2b below). This is a required edit, not optional cleanup.

**Interfaces:**
- Consumes: everything Task 1 produced. Consumes `claim_identity_personal` (Plan 2, `0040`) to set up a genuine `provisional` holder to evict. Consumes the `notifications` table (insert only — schema unchanged) and `roster_audit_log` (insert only — schema unchanged, see Global Constraints).
- Produces: `commit_school_identity` gains the graceful takeover — same signature, same call site in `approve_cohort_join_request` (which Task 2 does not touch again).

**Why test 21 needs an edit, not just a re-run:** trace §3's fixture under 0042's new gates — `update users set student_number = '98004', claim_method = 'provisional' where id = '...015'` sets `claim_method = 'provisional'` and `role = 'student'` (unchanged). Under 0042's gates, `v_existing.claim_method = 'oauth'` is false and `v_existing.role = 'class_rep'` is false, so `...015` now gets EVICTED and the approval SUCCEEDS — `throws_ok('23505', ...)` would fail against the post-0042 schema. This is not a bug in Task 1; it is exactly the interim state Task 1's own migration comment says 0042 replaces. The fix is to rewrite the assertion, not to preserve it.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/0042_school_identity_takeover.sql`:

```sql
-- ============================================================================
-- 0042: Flow 2 — commit_school_identity gains the takeover path
-- ============================================================================
-- Part 3 of 5. Completes AUTH_FLOW_REFACTOR.md §4 step 5: if the derived
-- student_number is already held by a provisional account, approving THIS
-- request must evict that holder (not fail with a raw constraint violation,
-- 0041's accepted interim state) — unless the holder is already oauth
-- (a red flag, not a routine outcome: two proven school addresses cannot
-- legitimately derive the same number, so this refuses and escalates rather
-- than picking a winner) or holds scheduling authority (never auto-evict a
-- class rep; escalate to a faculty rep instead, mirroring claim_roster_row's
-- own third gate, 0019).
--
-- Gate re-hosting from claim_roster_row (0019, ~lines 185-205), per
-- AUTH_FLOW_REFACTOR.md §4 step 5: of its four checks, two re-host onto
-- users columns (existing claim? -> student_number lookup; is it already
-- oauth? -> claim_method), one is unchanged (class_rep? -> users.role), and
-- one does not apply here at all — "is the incoming claim not oauth" exists
-- in the old function because ONE function serves both the password and
-- OAuth branches; commit_school_identity is only ever reached via a proven
-- school email (Flow 2 is oauth-only by construction), so that gate would
-- never fire and is deliberately not reproduced.
--
-- ORDERING MATTERS: the evicted account's student_number is nulled in a
-- separate, earlier UPDATE than the incoming account's write. Both cannot
-- hold the same value at once under users_student_number_unique (0037), so
-- the only way to move the number from one row to the other is to clear the
-- old row first.
--
-- Eviction resets reg_number too, not just the four new identity fields —
-- AUTH_FLOW_REFACTOR.md §4 step 5 says so explicitly ("reg_number/the four
-- identity fields, and cohort_id"), and reg_number is still live on legacy
-- accounts until Plan 5 retires it.
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

    insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
    values (
      null, v_derived.student_number, 'takeover', p_actor_id, v_existing.id,
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

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    null, v_derived.student_number, 'claimed', p_actor_id, p_student_id,
    jsonb_build_object('method', 'oauth', 'cohort_id', p_cohort_id)
  );
end;
$$;

comment on function commit_school_identity(uuid, uuid, uuid) is
  'Flow 2 (AUTH_FLOW_REFACTOR.md §4): derives a student''s identity facts '
  'from their proven school_email and commits them as claim_method = oauth, '
  'at approval time, evicting any provisional holder of the same '
  'student_number first (never an oauth holder, never a class rep — both '
  'escalate to a faculty rep instead). Internal only, called by '
  'approve_cohort_join_request.';

revoke execute on function commit_school_identity(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
```

- [ ] **Step 2: Write the failing test**

Create `supabase/tests/22_school_identity_takeover_test.sql`:

```sql
-- ============================================================================
-- 22: commit_school_identity — the takeover path (0042)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §4 step 5: a real school-email owner's approval
-- evicts a provisional squatter on the same student_number automatically,
-- unless the squatter is already oauth (escalate — a red flag, not routine)
-- or holds scheduling authority (escalate — never auto-evict a class rep).
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
create function pg_temp.eb1_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;   -- class rep, BSC-CS 2023 (EB1)

-- Both flows are Google OAuth; only the address domain differs (that's what
-- 0039's trigger examines), so one fixture covers both signup shapes.
create function pg_temp.new_oauth_signup(p_id uuid, p_email text) returns void language sql as $$
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  )
  values (
    '00000000-0000-0000-0000-000000000000',
    p_id, 'authenticated', 'authenticated',
    p_email, 'x', now(), now(),
    jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
    jsonb_build_object('first_name', 'Test', 'last_name', 'Account'),
    now(), now(), '', '', '', ''
  );
$$;


-- ---------------------------------------------------------------------------
-- §1 A real takeover: a provisional squatter — already placed in a cohort,
-- not just claimed-but-cohortless — is evicted when the real owner is
-- approved. AUTH_FLOW_REFACTOR.md §4 step 5 is explicit that the reset is
-- identical whether the evicted account already made it into a cohort or
-- not; placing the squatter into a real cohort first (via the pre-existing,
-- Plan 2 approval path — rather than leaving cohort_id null, which would
-- make the cohort_id assertion below pass whether or not eviction actually
-- touches it) is what makes that claim mean something.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000001', 'squatter@gmail.com'
);
select pg_temp.act_as('77777777-0000-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '98101', 2026, %L) $$,
         pg_temp.programme('EB1'), '77777777-0000-4000-8000-000000000001'::uuid),
  'a provisional squatter claims the number the real owner will later derive'
);

insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000001', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000001'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'the squatter is placed into a cohort normally first, via the pre-existing (Plan 2) path — claim_method is provisional here, not null, so this goes through the else branch, unrelated to this plan''s new logic'
);
select is(
  (select cohort_id from users where id = '77777777-0000-4000-8000-000000000001'),
  pg_temp.cohort('EB1', 2023),
  '...confirming the squatter really is in a cohort before the takeover below'
);

select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000002', 'eb1.98101.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000002', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000002'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'approving the real owner triggers the takeover'
);

select is(
  (select claim_method from users where id = '77777777-0000-4000-8000-000000000001'),
  null, '...the squatter''s claim_method is reset'
);
select is(
  (select student_number from users where id = '77777777-0000-4000-8000-000000000001'),
  null, '...the squatter''s student_number is cleared, freeing it (ordering proof)'
);
select is(
  (select cohort_id from users where id = '77777777-0000-4000-8000-000000000001'),
  null, '...the squatter''s cohort_id is reset too — even though they had already made it into a cohort, per AUTH_FLOW_REFACTOR.md §4 step 5'
);
select is(
  (select claim_method::text from users where id = '77777777-0000-4000-8000-000000000002'),
  'oauth', '...and the real owner now holds the identity as oauth'
);
select is(
  (select student_number from users where id = '77777777-0000-4000-8000-000000000002'),
  '98101', '...with the exact number that moved from the squatter'
);
select isnt_empty(
  $$ select 1 from notifications
     where user_id = '77777777-0000-4000-8000-000000000001'
       and type = 'account_taken_over' $$,
  'the squatter receives the standard account-taken-over notification'
);
select isnt_empty(
  $$ select 1 from roster_audit_log
     where reg_number = '98101' and action = 'takeover'
       and target_user = '77777777-0000-4000-8000-000000000001' $$,
  'a takeover audit row is recorded against the squatter'
);
select isnt_empty(
  $$ select 1 from roster_audit_log
     where reg_number = '98101' and action = 'claimed'
       and target_user = '77777777-0000-4000-8000-000000000002' $$,
  'a claimed audit row is recorded against the real owner'
);


-- ---------------------------------------------------------------------------
-- §2 oauth-vs-oauth collision — a red flag, refused and escalated, never
-- silently resolved. Forced fixture state simulates the "should not happen"
-- case directly on an existing, unrelated seeded account — NOT a second
-- signup sharing the first's email address (auth.users.email is unique,
-- and two genuinely different real addresses cannot derive the same
-- number, so a direct force-set is the only way to construct this for a
-- test).
-- ---------------------------------------------------------------------------
update users
set claim_method = 'oauth', student_number = '98102', programme_id = pg_temp.programme('EB1')
where id = '22222222-0000-4000-8000-000000000022';

select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000004', 'eb1.98102.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000004', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000004'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'P0001',
  'Two proven school-email accounts derive the same student number. This '
  'cannot happen under correct operation and needs a faculty rep to '
  'investigate before either account is touched.',
  'an oauth-vs-oauth collision is refused and escalated, not silently resolved'
);


-- ---------------------------------------------------------------------------
-- §3 Class-rep collision — never auto-evict scheduling authority.
-- ---------------------------------------------------------------------------
update users
set claim_method = 'provisional', student_number = '98103'
where id = pg_temp.eb1_rep();

select pg_temp.new_oauth_signup(
  '77777777-0000-4000-8000-000000000005', 'eb1.98103.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('77777777-0000-4000-8000-000000000005', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select throws_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '77777777-0000-4000-8000-000000000005'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'P0001',
  'That identity is held by an account with scheduling authority. A '
  'faculty rep must resolve this.',
  'a collision with an account holding scheduling authority is refused and escalated'
);

select is(
  (select claim_method::text from users where id = pg_temp.eb1_rep()),
  'provisional', '...and the class rep''s own claim is left completely untouched'
);

select * from finish();
rollback;
```

- [ ] **Step 2b: Rewrite test 21's §3 — required, not optional**

`supabase/tests/21_commit_school_identity_test.sql`'s §3 currently asserts a raw `23505` failure on a `student_number` collision. Under this task's new gates, that exact fixture (`claim_method = 'provisional'`, `role = 'student'`) now gets evicted instead — the approval SUCCEEDS. Replace §3's entire block (from the `-- §3 Accepted interim state` comment through its `throws_ok`) with:

```sql
-- ---------------------------------------------------------------------------
-- §3 A student_number collision is resolved by eviction, not a raw
-- constraint failure (0042 replaces the accepted interim state from 0041 —
-- see 0042's own migration comment).
-- ---------------------------------------------------------------------------
update users
set student_number = '98004', claim_method = 'provisional'
where id = '22222222-0000-4000-8000-000000000015';

select pg_temp.new_school_signup(
  '66666666-0000-4000-8000-000000000004', 'eb1.98004.26@student.chuka.ac.ke'
);
insert into cohort_join_requests (student_id, cohort_id)
values ('66666666-0000-4000-8000-000000000004', pg_temp.cohort('EB1', 2023));

select pg_temp.act_as(pg_temp.eb1_rep());
select lives_ok(
  format($$ select approve_cohort_join_request(
              (select id from cohort_join_requests
               where student_id = '66666666-0000-4000-8000-000000000004'::uuid),
              %L) $$,
         pg_temp.eb1_rep()),
  'a student_number collision is now resolved by eviction, not a raw constraint failure'
);
select is(
  (select claim_method from users where id = '22222222-0000-4000-8000-000000000015'),
  null, '...the evicted provisional holder''s claim_method is reset'
);
select is(
  (select student_number from users where id = '66666666-0000-4000-8000-000000000004'),
  '98004', '...and the real owner now holds the number'
);
```

Also change `select plan(9);` to `select plan(11);` in the same file (the new §3 has 3 assertions where the old one had 1; verify this against the actual assertion count in the file after editing, don't just trust the arithmetic).

- [ ] **Step 3: Run the test to verify it fails**

Run: `supabase db reset` (applies through `0041` only, with test 21 still in its Task-1 form) then `supabase test db`

Expected: FAIL — `22_school_identity_takeover_test.sql`'s §1 takeover assertions fail (the squatter is never evicted; the real owner's approval instead hits the raw `23505` unique-violation from `0041`'s interim behavior). After applying Step 2b's edit to test 21 (still against the `0041`-only schema), `21_commit_school_identity_test.sql`'s new §3 also fails (`lives_ok` fails because the collision still hits a raw constraint error pre-`0042`) — confirms the edit is testing something real, not a tautology.

- [ ] **Step 4: Apply the migration and verify the test passes**

Run: `supabase db reset` (now applies through `0042`) then `supabase test db`

Expected: PASS — all 15 assertions in test 22 green, all 11 assertions in the edited test 21 green, and the full prior suite (tests 1-20) still green.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0042_school_identity_takeover.sql supabase/tests/22_school_identity_takeover_test.sql supabase/tests/21_commit_school_identity_test.sql
git commit -m "feat: add graceful takeover to commit_school_identity (plan 3/5, task 2)"
```

---

## Self-Review Notes

**Spec coverage:** AUTH_FLOW_REFACTOR.md §4 steps 1-2 (OAuth against school address, proven address parsed automatically) are already delivered by Plan 2's `0039` trigger — nothing new needed here. Step 3 (cohort placement not automatic, student picks a suggested cohort) is client-side plus the existing `cohort_join_requests` mechanism (Plan 1 confirmed no schema changes needed) — out of this plan's backend scope, same as Flow 1's equivalent step. Step 4 (class rep always reviews, uniform rule) is Task 1's branch inside the existing approval function. Step 5 (takeover on approval, not on write, all four re-hosted gates, notification wording, audit trail) is Task 1 (derive/write/first-claim) plus Task 2 (the eviction gates) in full, including the explicit note on why gate 3 ("incoming not oauth") does not apply. Step 6 (`claim_method = 'oauth'` permanently stronger) falls out of Task 1's plain write and is exercised by every assertion in both test files that checks `claim_method` afterward.

**Placeholder scan:** none — every task has literal SQL and literal test assertions.

**Type consistency:** `commit_school_identity`'s signature (`p_student_id uuid, p_cohort_id uuid, p_actor_id uuid`) is identical across Task 1 and Task 2's migrations and every test call site (indirect, via `approve_cohort_join_request`). `reg_number_parts`' field names (`programme_id`, `is_self_sponsored`, `student_number`, `admission_year`) are used correctly and consistently in both migrations' `UPDATE ... set self_sponsored = v_derived.is_self_sponsored` lines — verified this exact line twice given Global Constraints flags it as the single likeliest transcription error in this plan.

**Deferred, not this plan's job:** the Plan-1-final-review-escalated email-column-exposure gap (table-wide `select` grant + permissive RLS on `users`) remains open — this plan writes real data into `school_email`-derived identity fields exactly as Plan 2 did, so the same carried-forward risk applies, unchanged. `roster_audit_log`'s rename/enum-rebuild/`roster_id`-drop (§8) is explicitly Plan 5's job, not this plan's — see Global Constraints for why writing into the table as-is is still correct now.
