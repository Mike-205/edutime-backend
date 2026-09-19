# Auth identity linking (plan 4/5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an already-signed-up student attach a second Google identity to their existing account via Supabase's `linkIdentity()`, instead of creating (or being evicted into) a second account — a Flow 1 (personal-email) student strengthening their claim with a school address (§5), and any school-email account adding a personal address as a post-graduation recovery contact (§6).

**Architecture:** Two new client-callable RPCs, mirroring the split already established by `claim_identity_personal` (Flow 1) and `commit_school_identity` (Flow 2): `link_school_email_identity` re-derives the four identity facts from the newly-linked, proven school address and reconciles them against what Flow 1 already stored, including a takeover branch identical in shape to Flow 2's; `link_personal_email_identity` is unconditional, no derivation, no rep. Both are called by the client immediately after `linkIdentity()` succeeds — `handle_new_auth_user()` never fires for a linked identity (it's `AFTER INSERT ON auth.users`, and linking doesn't insert a new `auth.users` row), so nothing else in this schema reacts to a link on its own.

**Tech Stack:** Supabase/Postgres, plpgsql `SECURITY DEFINER` functions, pgTAP tests (`supabase db reset`, `supabase test db`).

**Spec:** `supabase/AUTH_FLOW_REFACTOR.md` §5 (linking a school email to an existing provisional account), §6 (linking a personal email to an existing school-email account), §2 (the four identity facts), §7 (uniqueness/takeover), §8 (audit trail — this plan adds the `identity_linked` event named there).

## Global Constraints

- **Not yet live** — no real users, no GitHub remote. Migrations are additive to what plans 1-3 shipped (`0037`-`0043`); no backward-compat window needed.
- **Escalation is a `raise exception`, not a queue.** Every "routes to the faculty rep" phrase in §5 means: refuse with an instructive message, write nothing, and a human finds out out-of-band. There is no dispute-record table in the new system — `resolve_roster_dispute` is the *old* roster system's mechanism and is retiring in Plan 5. Do not build a queue here.
- **`auth.identities.email` is a real, generated column** (`lower(identity_data ->> 'email')`, confirmed against the running local instance) — query it directly. Do not reach into `identity_data` JSON yourself.
- **`users.email` / `users.email_verified_at` are vestigial post-`0037`.** Nothing in the new system reads them (confirmed by grep across `0037`-`0043`); Flow 2 never touches them either. Neither new function in this plan touches them. `school_email`/`school_email_verified_at` and `personal_email`/`personal_email_verified_at` are the only email-tier columns that matter now.
- **The `reg_number_parts` naming trap, again:** the type field is `is_self_sponsored`; the `users` column is `self_sponsored`. Get this backwards and the self-sponsorship flag silently inverts or nulls. Every task touching `parse_reg_number()`'s return value restates this.
- **`roster_audit_log.reg_number` is `NOT NULL`.** Every insert in this plan supplies a real slash-form string via `reg_number_from_email(...)` — never `users.reg_number` directly (that legacy column stays null for every new-system account, Flow 1 and Flow 2 alike; only the old roster path ever wrote it).
- **`link_personal_email_identity` is scoped to `claim_method = 'oauth'` accounts only.** Old-system (roster/password) accounts already have their own, separate recovery-email mechanism (`0031`, `user_recovery_email` + `set_recovery_email`/`verify_recovery_email`) — this plan does not touch or extend that system.
- **Re-linking a personal email overwrites, not refuses** (explicit product decision, this plan): if `personal_email` is already set and a different address gets linked, the new address wins. `linkIdentity()` never removes the superseded identity from `auth.identities` — only the `users.personal_email` pointer moves, and the previous address is captured in the audit row's `snapshot` for a faculty rep to check if it's ever disputed.
- **`set search_path = public`** is restated on every `SECURITY DEFINER` function created or replaced in this plan — not decoration, a hardening rule this repo enforces (`00_access_control_test.sql`'s "every SECURITY DEFINER function pins its search_path" check will fail the whole suite otherwise).
- **File numbers:** migrations `0044` (enum value only), `0045` (`link_school_email_identity`), `0046` (`link_personal_email_identity`); tests `23`, `24`, `25` respectively.
- **`ALTER TYPE ... ADD VALUE` cannot be used in the same transaction as the new value.** `0044` adds `'identity_linked'` to `roster_audit_action` and nothing else — no function in that same file may reference it. `supabase db reset`/CLI migration apply runs each file as its own transaction, so `0045`/`0046` (separate files, applied after `0044` commits) can use it freely.

---

### Task 1: `identity_linked` audit event

**Files:**
- Modify: `supabase/migrations/0044_identity_linked_audit_event.sql` (new file)
- Test: `supabase/tests/23_identity_linked_audit_event_test.sql` (new file)

**Interfaces:**
- Produces: the enum value `'identity_linked'` on the existing `roster_audit_action` type (defined `0017`), consumed by Task 2 and Task 3's `insert into roster_audit_log (..., action, ...)`.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/23_identity_linked_audit_event_test.sql`:

```sql
-- ============================================================================
-- 23: identity_linked audit event (0044)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §8 names identity_linked as the audit event for the
-- linking flows this plan (4/5) adds. Added as its own migration, separate
-- from anything that writes a row with it — ALTER TYPE ... ADD VALUE cannot
-- be used in the same transaction it's added in, and each migration file is
-- its own transaction.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(1);

select ok(
  'identity_linked' = any(enum_range(null::roster_audit_action)::text[]),
  'roster_audit_action gained identity_linked'
);

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

With `supabase/tests/23_identity_linked_audit_event_test.sql` created but `supabase/migrations/0044_identity_linked_audit_event.sql` NOT created yet, run: `supabase test db`
Expected: FAIL — `'identity_linked'` is not a value of `roster_audit_action` yet (it does not exist in the type at all, since the migration that adds it hasn't been written).

- [ ] **Step 3: Write minimal implementation**

Create `supabase/migrations/0044_identity_linked_audit_event.sql`:

```sql
-- ============================================================================
-- 0044: identity_linked audit event
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §8 names this as the audit event for the linking
-- flows (§5/§6, plan 4/5). Added on its own, in its own migration file and
-- transaction — Postgres refuses to use a new enum value in the same
-- transaction that added it, and the functions that write this value
-- (0045, 0046) are deliberately separate files applied after this one
-- commits.
--
-- Not a full rebuild of roster_audit_action: AUTH_FLOW_REFACTOR.md §8 also
-- describes dropping 'created'/'updated'/'removed' (dead once the old
-- roster's writers retire) and renaming roster_audit_log itself — both are
-- Plan 5's job, once the old roster path is actually gone. Adding one new
-- value here doesn't block that later rebuild.
-- ============================================================================

alter type roster_audit_action add value 'identity_linked';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: `supabase/tests/23_identity_linked_audit_event_test.sql` passes (1/1).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0044_identity_linked_audit_event.sql supabase/tests/23_identity_linked_audit_event_test.sql
git commit -m "feat: add identity_linked audit event (plan 4/5, task 1)"
```

---

### Task 2: `link_school_email_identity` — §5

**Files:**
- Create: `supabase/migrations/0045_link_school_email_identity.sql`
- Test: `supabase/tests/24_link_school_email_identity_test.sql`

**Interfaces:**
- Consumes: `roster_audit_action` value `'identity_linked'` (Task 1); `reg_number_from_email(p_email text) returns text` (`0019`); `parse_reg_number(p_reg_number text) returns reg_number_parts` (`0017`) — fields `programme_id, programme_code, is_self_sponsored, student_number, admission_year`; `is_school_email(p_email text) returns boolean` (`0039`); `auth.identities.email` (generated column).
- Produces: `link_school_email_identity(p_actor_id uuid) returns void`, granted to `authenticated`, called by the client immediately after a successful `linkIdentity()` against a school address.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/24_link_school_email_identity_test.sql`:

```sql
-- ============================================================================
-- 24: link_school_email_identity (0045)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5: a Flow 1 (provisional) student links a school
-- Google identity to their existing account. Match -> upgrade in place.
-- Mismatch + nobody holds the derived number -> escalate (raise exception,
-- write nothing). Mismatch + another account already holds it -> same
-- takeover shape as Flow 2 (0042): evict unless the holder is already
-- oauth or a class_rep, in which case escalate instead.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(28);


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

-- A fresh personal-email OAuth signup, with its one starting identity row.
-- auth.identities is never populated by a raw INSERT into auth.users (that's
-- GoTrue's job on a real signup) so this fixture creates it explicitly.
create function pg_temp.new_oauth_signup(p_id uuid, p_email text) returns void
language plpgsql as $$
begin
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

  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
end;
$$;

-- Simulates a successful linkIdentity() call: a second auth.identities row
-- for the same user_id, a different address. created_at/updated_at have no
-- column default (confirmed against the running local instance) and
-- link_school_email_identity/link_personal_email_identity order by
-- created_at desc to pick the most-recently-linked candidate -- clock_timestamp()
-- (not now(), which is frozen for the whole transaction these tests run in)
-- is what makes that ordering actually mean something across sequential calls.
create function pg_temp.link_identity(p_id uuid, p_email text) returns void
language sql as $$
  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
$$;


-- ---------------------------------------------------------------------------
-- §1 Match: self-typed Flow 1 identity agrees with what the linked school
-- address derives. Upgrades in place, no rep involved.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000001', 'match.student@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88101', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000001'::uuid),
  'a Flow 1 provisional claim, matching what the school email will later derive'
);

select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000001', 'eb1.88101.26@student.chuka.ac.ke'
);
select lives_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000001'::uuid) $$,
  'linking a school email that matches the stored identity succeeds'
);
select is(
  (select claim_method::text from users where id = '88888888-0000-4000-8000-000000000001'),
  'oauth',
  '...claim_method upgrades to oauth'
);
select is(
  (select school_email from users where id = '88888888-0000-4000-8000-000000000001'),
  'eb1.88101.26@student.chuka.ac.ke',
  '...school_email is recorded'
);
select ok(
  (select school_email_verified_at from users where id = '88888888-0000-4000-8000-000000000001') is not null,
  '...school_email_verified_at is stamped'
);
select is(
  (select action::text from roster_audit_log
   where target_user = '88888888-0000-4000-8000-000000000001' and actor_id = '88888888-0000-4000-8000-000000000001'
   order by created_at desc limit 1),
  'identity_linked',
  '...an identity_linked audit row is written'
);


-- ---------------------------------------------------------------------------
-- §2 Mismatch, nobody holds the derived number: escalate. Nothing is
-- written — not claim_method, not school_email.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000002', 'mismatch.student@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000002');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88102', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000002'::uuid),
  'a Flow 1 provisional claim, deliberately different from the address linked below'
);

select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000002', 'eb1.99999.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000002'::uuid) $$,
  'P0001',
  'The identity derived from this account''s linked school email does not match what was recorded at signup. A faculty rep must resolve this before the school email can be confirmed.',
  'a derived identity that matches nobody escalates rather than auto-correcting'
);
select is(
  (select claim_method::text from users where id = '88888888-0000-4000-8000-000000000002'),
  'provisional',
  '...claim_method is untouched by the escalation'
);
select ok(
  (select school_email from users where id = '88888888-0000-4000-8000-000000000002') is null,
  '...school_email is untouched by the escalation'
);


-- ---------------------------------------------------------------------------
-- §3 Mismatch, and the derived number is already held by another
-- provisional account: same shape as Flow 2's takeover (0042) — the
-- linking account (now proven) wins, the squatter is evicted.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000003', 'squatter3@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000003');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88103', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000003'::uuid),
  'a squatter claims 88103 first'
);

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000004', 'real.owner4@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000004');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88104', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000004'::uuid),
  'the real owner''s own Flow 1 claim is deliberately wrong (88104) -- self-typed data cannot be trusted, that is the whole point of this branch'
);

select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000004', 'eb1.88103.26@student.chuka.ac.ke'
);
select lives_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000004'::uuid) $$,
  'the real owner links the school email deriving 88103 -- already held by the squatter -- and wins'
);
select is(
  (select student_number from users where id = '88888888-0000-4000-8000-000000000004'),
  '88103',
  '...the real owner now holds the derived (not self-typed) student_number'
);
select is(
  (select claim_method::text from users where id = '88888888-0000-4000-8000-000000000003'),
  null,
  '...the squatter is evicted: claim_method reset to null'
);
select is(
  (select student_number from users where id = '88888888-0000-4000-8000-000000000003'),
  null,
  '...the squatter is evicted: student_number reset to null'
);
select is(
  (select action::text from roster_audit_log
   where target_user = '88888888-0000-4000-8000-000000000003' and action = 'takeover'
   order by created_at desc limit 1),
  'takeover',
  '...a takeover audit row is written for the evicted squatter'
);


-- ---------------------------------------------------------------------------
-- §4 Mismatch, and the derived number is already held by an account that
-- is ALREADY oauth: escalate rather than picking a winner between two
-- proven claims -- confirmed unreachable in correct operation, so this is
-- a red flag needing investigation, not a routine outcome.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000010', 'already.oauth10@gmail.com'
);
update users
set programme_id   = pg_temp.programme('EB1'),
    self_sponsored = false,
    student_number = '88110',
    admission_year = 2026,
    claim_method   = 'oauth'
where id = '88888888-0000-4000-8000-000000000010';

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000008', 'linker8@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000008');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88108', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000008'::uuid),
  'a provisional claim, deliberately wrong -- about to link a school email deriving the already-oauth account''s number'
);
select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000008', 'eb1.88110.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000008'::uuid) $$,
  'P0001',
  'Two proven school-email accounts derive the same student number. This cannot happen under correct operation and needs a faculty rep to investigate before either account is touched.',
  'a derived number already held by an oauth account escalates instead of picking a winner'
);


-- ---------------------------------------------------------------------------
-- §5 Mismatch, and the derived number is already held by a class_rep:
-- escalate rather than auto-evicting scheduling authority.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000011', 'rep11@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000011');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88111', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000011'::uuid),
  'a provisional claim for the account that will hold scheduling authority'
);
-- cohort_id is left null, so enforce_max_class_reps_trigger (0003) -- which
-- only fires when NEW.cohort_id is not null -- does not apply here.
update users set role = 'class_rep' where id = '88888888-0000-4000-8000-000000000011';

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000009', 'linker9@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000009');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88109', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000009'::uuid),
  'a provisional claim, deliberately wrong -- about to link a school email deriving the class_rep''s number'
);
select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000009', 'eb1.88111.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000009'::uuid) $$,
  'P0001',
  'That identity is held by an account with scheduling authority. A faculty rep must resolve this.',
  'a derived number already held by a class_rep escalates instead of auto-evicting scheduling authority'
);


-- ---------------------------------------------------------------------------
-- §6 Guards
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000005', 'not.provisional@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000005');
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000005'::uuid) $$,
  'P0001',
  'Only a provisional-claim account can link a school email this way',
  'an account that never made a Flow 1 claim cannot use this path'
);

select pg_temp.act_as('88888888-0000-4000-8000-000000000005');
select throws_ok(
  $$ select link_school_email_identity('99999999-0000-4000-8000-000000000099'::uuid) $$,
  'P0001',
  'p_actor_id must match the calling user',
  'the acting-user parameter must match auth.uid()'
);

select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000006', 'no.link.yet@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000006');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88106', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000006'::uuid),
  'a provisional claim with no school identity linked yet'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000006'::uuid) $$,
  'P0001',
  'No linked school-email identity was found for this account',
  'calling this before linkIdentity() has actually succeeded is refused'
);


-- ---------------------------------------------------------------------------
-- §7 A genuine school address that does not shape-check to a registration
-- number (e.g. a staff-style mailbox) cannot be derived from at all.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '88888888-0000-4000-8000-000000000007', 'unparseable7@gmail.com'
);
select pg_temp.act_as('88888888-0000-4000-8000-000000000007');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '88107', 2026, %L) $$,
         pg_temp.programme('EB1'), '88888888-0000-4000-8000-000000000007'::uuid),
  'a provisional claim, about to link an unparseable school address'
);
select pg_temp.link_identity(
  '88888888-0000-4000-8000-000000000007', 'j.doe@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('88888888-0000-4000-8000-000000000007'::uuid) $$,
  'P0001',
  'Could not derive a student identity from this school email. A faculty rep must resolve this.',
  'a school address that does not shape-check to a reg number cannot be derived from'
);

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `supabase test db`
Expected: FAIL — `link_school_email_identity` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `supabase/migrations/0045_link_school_email_identity.sql`:

```sql
-- ============================================================================
-- 0045: link_school_email_identity — §5
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5: a Flow 1 (provisional) student links a school
-- Google identity to the account they already have, instead of signing up a
-- second time. handle_new_auth_user() (0002/0039) only fires on INSERT INTO
-- auth.users and a linked identity is not a new row, so this is its own RPC,
-- called by the client right after linkIdentity() succeeds.
--
-- The newly-linked address is found by querying auth.identities directly
-- (its email column is generated: lower(identity_data ->> 'email')) rather
-- than trusting anything passed in by the client — the same principle
-- 0019/0039 already apply to auth.users.email.
--
-- Match/mismatch/takeover gates mirror commit_school_identity (0041/0042)
-- closely enough that reading that function alongside this one is the
-- fastest way to see what's the same and what's different:
--   - commit_school_identity compares the DERIVED identity against a
--     COHORT's programme_id, at approval time.
--   - link_school_email_identity compares the DERIVED identity against
--     this SAME ROW's already-STORED (self-typed, Flow 1) identity, at
--     link time — there is no cohort in play here at all.
-- The takeover sub-branch (mismatch AND the derived number is already held
-- by someone else) is otherwise identical: evict unless the holder is
-- already oauth (a red flag, escalate) or a class_rep (never auto-evict
-- scheduling authority, escalate instead).
-- ============================================================================
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

  if v_user.claim_method is distinct from 'provisional' then
    raise exception
      'Only a provisional-claim account can link a school email this way';
  end if;

  select email into v_new_email
  from auth.identities
  where user_id = p_actor_id and is_school_email(email)
  order by created_at desc
  limit 1;

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

    insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
    values (
      null, v_reg, 'takeover', p_actor_id, v_existing.id,
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

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    null, v_reg, 'identity_linked', p_actor_id, p_actor_id,
    jsonb_build_object('linked', 'school_email', 'previous_claim_method', v_user.claim_method)
  );
end;
$$;

comment on function link_school_email_identity(uuid) is
  'AUTH_FLOW_REFACTOR.md §5: a provisional (Flow 1) account links a school '
  'Google identity to the account it already has. Match upgrades in place; '
  'mismatch escalates to a faculty rep unless the derived number is already '
  'held by an evictable (provisional, non-class_rep) account, in which case '
  'this account wins the takeover, same shape as commit_school_identity '
  '(0041/0042). Called by the client immediately after linkIdentity() '
  'succeeds.';

revoke execute on function link_school_email_identity(uuid) from public, anon;
grant  execute on function link_school_email_identity(uuid) to authenticated, service_role;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: `supabase/tests/24_link_school_email_identity_test.sql` passes (28/28), no other file regresses.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0045_link_school_email_identity.sql supabase/tests/24_link_school_email_identity_test.sql
git commit -m "feat: add link_school_email_identity (plan 4/5, task 2)"
```

---

### Task 3: `link_personal_email_identity` — §6

**Files:**
- Create: `supabase/migrations/0046_link_personal_email_identity.sql`
- Test: `supabase/tests/25_link_personal_email_identity_test.sql`

**Interfaces:**
- Consumes: `roster_audit_action` value `'identity_linked'` (Task 1); `reg_number_from_email(p_email text) returns text` (`0019`); `is_school_email(p_email text) returns boolean` (`0039`); `auth.identities.email` (generated column).
- Produces: `link_personal_email_identity(p_actor_id uuid) returns void`, granted to `authenticated`, called by the client immediately after a successful `linkIdentity()` against a personal address.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/25_link_personal_email_identity_test.sql`:

```sql
-- ============================================================================
-- 25: link_personal_email_identity (0046)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §6: an oauth (school-email) account links a personal
-- address as a recovery contact for after the school address stops working.
-- Unconditional — no rep, no derivation, no identity fields touched. Explicit
-- product decision (this plan): re-linking a different address OVERWRITES
-- personal_email rather than refusing, with an audit row capturing the
-- previous address.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

-- A fresh school-email OAuth signup (Flow 2's trigger path, 0039): claim_method
-- starts null, becomes 'oauth' only once approved into a cohort. For this
-- function's guard (claim_method = 'oauth'), force-set it directly, the same
-- way earlier plans' tests reach otherwise-unreachable states without a full
-- approval flow (see 06/21/22's precedent).
create function pg_temp.new_oauth_signup(p_id uuid, p_email text) returns void
language plpgsql as $$
begin
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

  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
end;
$$;

create function pg_temp.link_identity(p_id uuid, p_email text) returns void
language sql as $$
  insert into auth.identities (provider_id, user_id, identity_data, provider)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google');
$$;


-- ---------------------------------------------------------------------------
-- §1 First link: an oauth account with no personal_email yet.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '99999999-0000-4000-8000-000000000001', 'eb1.99101.26@student.chuka.ac.ke'
);
update users set claim_method = 'oauth' where id = '99999999-0000-4000-8000-000000000001';
select ok(
  (select personal_email from users where id = '99999999-0000-4000-8000-000000000001') is null,
  'sanity: no personal_email yet'
);

select pg_temp.act_as('99999999-0000-4000-8000-000000000001');
select pg_temp.link_identity(
  '99999999-0000-4000-8000-000000000001', 'first.recovery@gmail.com'
);
select lives_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000001'::uuid) $$,
  'linking a personal email for the first time succeeds'
);
select is(
  (select personal_email from users where id = '99999999-0000-4000-8000-000000000001'),
  'first.recovery@gmail.com',
  '...personal_email is recorded'
);
select ok(
  (select personal_email_verified_at from users where id = '99999999-0000-4000-8000-000000000001') is not null,
  '...personal_email_verified_at is stamped'
);
select is(
  (select action::text from roster_audit_log
   where target_user = '99999999-0000-4000-8000-000000000001' and actor_id = '99999999-0000-4000-8000-000000000001'
   order by created_at desc limit 1),
  'identity_linked',
  '...an identity_linked audit row is written'
);


-- ---------------------------------------------------------------------------
-- §2 Re-link a different address: overwrite (explicit product decision),
-- with the previous address preserved in the audit row's snapshot.
-- ---------------------------------------------------------------------------
select pg_temp.link_identity(
  '99999999-0000-4000-8000-000000000001', 'second.recovery@gmail.com'
);
select lives_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000001'::uuid) $$,
  're-linking a different personal email succeeds (overwrite, not refuse)'
);
select is(
  (select personal_email from users where id = '99999999-0000-4000-8000-000000000001'),
  'second.recovery@gmail.com',
  '...personal_email now holds the new address'
);
select is(
  (select (snapshot ->> 'previous_personal_email') from roster_audit_log
   where target_user = '99999999-0000-4000-8000-000000000001' and actor_id = '99999999-0000-4000-8000-000000000001'
   order by created_at desc limit 1),
  'first.recovery@gmail.com',
  '...the audit row''s snapshot preserves the superseded address'
);


-- ---------------------------------------------------------------------------
-- §3 Guards
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '99999999-0000-4000-8000-000000000002', 'not.oauth.yet@gmail.com'
);
-- claim_method left null -- a fresh signup that has not yet been approved
-- into anything, the state this guard must refuse.
select pg_temp.act_as('99999999-0000-4000-8000-000000000002');
select pg_temp.link_identity(
  '99999999-0000-4000-8000-000000000002', 'wontmatter@gmail.com'
);
select throws_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000002'::uuid) $$,
  'P0001',
  'Only a school-email-verified account can link a personal email as a recovery contact',
  'an account that is not yet claim_method = oauth cannot use this path'
);

select throws_ok(
  $$ select link_personal_email_identity('11111111-0000-4000-8000-000000000099'::uuid) $$,
  'P0001',
  'p_actor_id must match the calling user',
  'the acting-user parameter must match auth.uid()'
);

select pg_temp.new_oauth_signup(
  '99999999-0000-4000-8000-000000000003', 'eb1.99103.26@student.chuka.ac.ke'
);
update users set claim_method = 'oauth' where id = '99999999-0000-4000-8000-000000000003';
select pg_temp.act_as('99999999-0000-4000-8000-000000000003');
select throws_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000003'::uuid) $$,
  'P0001',
  'No linked personal-email identity was found for this account',
  'calling this before linkIdentity() has actually succeeded is refused'
);

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `supabase test db`
Expected: FAIL — `link_personal_email_identity` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `supabase/migrations/0046_link_personal_email_identity.sql`:

```sql
-- ============================================================================
-- 0046: link_personal_email_identity — §6
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §6: any claim_method = 'oauth' account can link a
-- personal Google identity as a recovery contact for after the school
-- address stops resolving (graduation, withdrawal). Unconditional by
-- design — no rep, no derivation, no identity field touched — because a
-- personal address carries no identity claim to check against.
--
-- Scoped to claim_method = 'oauth' only. Old-system (roster/password)
-- accounts already have an entirely separate recovery-email mechanism
-- (0031: user_recovery_email, set_recovery_email/verify_recovery_email)
-- that this plan does not touch.
--
-- Re-linking a different address OVERWRITES personal_email rather than
-- refusing (explicit product decision, this plan's brainstorming) --
-- linkIdentity() never removes the superseded identity from
-- auth.identities, only the users.personal_email pointer moves, and the
-- previous address is captured in the audit row's snapshot so a faculty
-- rep has something to check if it's ever disputed.
--
-- reg_number for the audit row: users.reg_number stays null for every
-- new-system account (Flow 1 and Flow 2 alike; only the old roster path
-- ever wrote it), so it cannot be used here. Every oauth account has a
-- non-null school_email by construction (Flow 2 signup, or a completed §5
-- link) -- reg_number_from_email(v_user.school_email) is what every other
-- writer in this schema uses for exactly this reason.
-- ============================================================================
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

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    null, v_reg, 'identity_linked', p_actor_id, p_actor_id,
    jsonb_build_object(
      'linked', 'personal_email',
      'previous_personal_email', v_user.personal_email,
      'new_personal_email', v_new_email
    )
  );
end;
$$;

comment on function link_personal_email_identity(uuid) is
  'AUTH_FLOW_REFACTOR.md §6: a claim_method = oauth account links a personal '
  'Google identity as a post-graduation recovery contact. Unconditional -- '
  'no rep, no derivation. Re-linking a different address overwrites '
  'personal_email; the superseded address is preserved in the audit row''s '
  'snapshot. Called by the client immediately after linkIdentity() '
  'succeeds.';

revoke execute on function link_personal_email_identity(uuid) from public, anon;
grant  execute on function link_personal_email_identity(uuid) to authenticated, service_role;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: `supabase/tests/25_link_personal_email_identity_test.sql` passes (11/11), full suite green, no regressions in any of the other 25 files.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0046_link_personal_email_identity.sql supabase/tests/25_link_personal_email_identity_test.sql
git commit -m "feat: add link_personal_email_identity (plan 4/5, task 3)"
```
