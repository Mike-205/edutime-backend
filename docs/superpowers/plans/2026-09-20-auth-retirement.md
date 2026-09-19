# Auth system retirement (plan 5/5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the roster/password auth system now that Plans 1-4 have fully replaced it: drop `student_roster` and everything built only for it, rebuild the audit trail as the sole record of every trust decision, and give §5's escalation case (a faculty rep resolving a disputed school-email link) a real function to call instead of a dead end.

**Architecture:** Nine sequential tasks. Order matters — several later drops require an earlier task's column/table removal to have already landed, and two tasks (seed conversion, audit-log rebuild) touch schema that several *surviving* functions depend on for correctness, not just cleanliness. Read every task's "Why this order" note before reordering anything.

**Tech Stack:** Supabase/Postgres, plpgsql `SECURITY DEFINER` functions, pgTAP tests, Deno/TS Edge Functions (`supabase/functions/`).

**Spec:** `supabase/AUTH_FLOW_REFACTOR.md` §10 (what this retires), §8 (the audit trail rebuild), §5 (the dispute-resolution function this plan adds). §10 does not mention three things this plan also retires or changes — each is a scoping decision made during this plan's brainstorming, not a gap in reading the spec: the cohort-streams bulk-assignment functions (architecturally dependent on the roster in a way §10 never addresses), the recovery-email subsystem (0031 — serves password-path accounts exclusively, has no purpose once that path is gone, and Plan 4's `link_personal_email_identity` is its modern replacement), and `promote_class_rep` (reads `student_roster` directly — found by grepping for the literal string across every migration, not surfaced by name in any earlier plan).

## Global Constraints

- **Not yet live** — no real users, no GitHub remote. Every drop in this plan is a plain, additive-to-the-migration-sequence change; no backward-compat window, no data migration for real users.
- **Task 1's seed conversion changes data other tests depend on by *value*, not by name — this is a named, open-ended risk, not a closed checklist.** `supabase/tests/08_phase2_test.sql:60-65` is the one confirmed instance (relies on two seeded accounts holding specific non-null `reg_number`s to trigger a `23505`; nulling `reg_number` breaks it — the fix is given in Task 1). Grepping for table/function names cannot find the rest of this class, because the dependency is on a *value* seed.sql happens to produce, not a reference to anything being dropped. **Run the full suite (`supabase db reset && supabase test db`) at the end of Task 1, not a scoped test file, and fix any other fallout by adjusting that test's own fixture to set up the state it needs — never by re-adding old seed behavior.**
- **`ALTER TYPE ... ADD VALUE` / enum rebuilds cannot be used in the same transaction as the statement that added them** — already established convention in this repo (`0044`). Task 3's enum rebuild uses `CREATE TYPE ... AS ENUM` (a new type) plus a `USING` cast, not `ADD VALUE`, so this restriction does not apply to it directly — noted so nobody "fixes" Task 3 to match the wrong precedent.
- **Every `SECURITY DEFINER` function created or replaced in this plan restates `set search_path = public`** — a repo-wide hardening rule `00_access_control_test.sql` enforces for the whole schema; get it wrong and the *entire* suite fails, not just one file.
- **Re-read a function's current live body from the migration files immediately before writing any task that edits it — never copy body text out of this plan's prose.** This plan's own authoring caught two functions whose obvious-looking "current" body was stale by one or two migrations (`approve_cohort_join_request` looked like it was last touched by `0040`; it was actually `0041`). Every body reproduced in this plan below was re-verified against the live migration files at the time of writing — but by the time an implementer executes Task 6 or 7, other tasks in *this same plan* will have already changed some of these functions, so the instruction stands for this plan's own internal ordering too, not just for drift since Plan 4.
- **`DROP TABLE` and `DROP FUNCTION` in this plan never use `CASCADE`.** A cascade that silently drops something else is exactly the failure mode this plan's own authoring hit twice (a table drop blocked by a foreign key the author hadn't traced yet). A plain drop that fails loudly, naming the blocking dependency, is the correct outcome if a task's ordering assumption turns out wrong — stop and re-read this plan's Global Constraints and the failing task's "Why this order" note, don't add `CASCADE` to make the error go away.
- **New audit table/type names:** `roster_audit_log` → `identity_audit_log`; `roster_audit_action` → `identity_audit_action`, rebuilt down to exactly `'claimed', 'takeover', 'unbound', 'dispute_resolved', 'identity_linked'` (dropping `'created', 'updated', 'removed', 'reassigned'` — all four confirmed to have no other writer once Tasks 4-7 land; verified by grep across every migration file before this plan was written).
- **Deliberately out of scope, decided during this plan's brainstorming:** the cohort-streams *bulk pre-signup assignment* capability (`assign_students_to_streams`, keyed on registration numbers the registrar supplied before any account exists) has no equivalent under the new system and is not being redesigned here — it is dropped outright. `create_cohort_stream` (splitting a cohort into streams) survives; only its one roster-touching side effect is removed. `cohorts.parent_cohort_id`/`cohorts.stream` (the streams *schema*, `0025`) are untouched, so a future, narrower rebuild (scoped to already-claimed students, keyed on `users.student_number`) stays cheap.
- **Deliberately out of scope: `TECHNICAL_DISCOVERY.md`, `TODO.md`, and `edutime-blueprint.html`.** All three describe the system's design history and are left as historical record, matching this repo's own established convention (`AUTH_FLOW_REFACTOR.md`'s own §0 keeps its original "why this exists" reasoning intact after the system it describes shipped). Only `AUTH_FLOW.md` — the currently-authoritative "what does the client do today" doc — gets rewritten (Task 8). A reviewer should not flag the untouched docs as a miss.
- **File numbers:** migrations `0047`-`0053` (7 new files, one per task from Task 1 through Task 7 excluding the doc/config tasks, which touch no migration).

---

### Task 1: `promote_class_rep` fix + seed data conversion

**Files:**
- Modify: `supabase/migrations/0047_seed_identity_and_promote_fix.sql` (new file)
- Modify: `supabase/seed.sql:558-828` (the account list, §9.5, and §9.6's comment)
- Modify: `supabase/tests/13_bootstrap_test.sql:176-180`
- Modify: `supabase/tests/08_phase2_test.sql:56-65`

**Interfaces:**
- Consumes: `parse_reg_number(text) returns reg_number_parts` (`0017`); `is_school_email` is not needed here — the discriminator is `school_email is not null`, already set by `handle_new_auth_user` (`0039`) for every `google`-provider signup at the time `seed_user` runs.
- Produces: every seeded student/class_rep/faculty_rep account now has `claim_method`, `programme_id`, `self_sponsored`, `student_number`, `admission_year` populated the way a real Flow 1/2 account would, and `reg_number` null — the state every later task in this plan assumes seed data is already in.

**Why this order:** `promote_class_rep` (`0022`) currently reads `student_roster.claim_method` to decide whether promoting someone to class rep needs an identity attestation. `seed.sql §9.6` promotes two accounts (Brian, Naomi) *relying on that lookup returning `'oauth'`* with no attestation flag passed — so the fix to `promote_class_rep` and the seed conversion that gives `users.claim_method` a real value for those two accounts must land in the same task; fixing one without the other leaves the suite red partway through.

- [ ] **Step 1: Write the failing test evidence**

This task's tests are the *existing* files `supabase/tests/07_phase1_test.sql` (already exercises `promote_class_rep`'s attestation logic against Cynthia — provisional — and Grace — oauth) and `supabase/tests/13_bootstrap_test.sql` / `supabase/tests/08_phase2_test.sql` (both currently pass against the *old* seed shape). Run the full suite now, before any change, and record the baseline:

Run: `supabase db reset && supabase test db`
Expected: full suite currently green (this is the starting point, not a red phase — there is no new behavior to fail yet, only existing behavior being re-plumbed).

- [ ] **Step 2: Fix `promote_class_rep` to read `users.claim_method`**

Create `supabase/migrations/0047_seed_identity_and_promote_fix.sql`. Re-read `supabase/migrations/0022_event_api.sql`'s current `promote_class_rep` body before writing this — confirm no later migration redefines it (none does, as of this plan's authoring). Replace it in full:

```sql
-- ============================================================================
-- 0047: promote_class_rep reads users.claim_method; seed data gets real
-- new-system identities
-- ============================================================================
-- promote_class_rep (0022) has read claim_method off student_roster since it
-- was written, because that was the only place it lived. Plans 1-4 moved
-- claim_method onto users itself; student_roster is retiring in this plan
-- (Task 7). The fix is a one-line source change, not a behavior change: the
-- attestation rule (0.5) is unchanged, only where the claim_method comes
-- from.
create or replace function promote_class_rep(
  p_user_id            uuid,
  p_rank               class_rep_rank,
  p_acting_faculty_rep uuid,
  p_identity_attested  boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role    user_role;
  v_actor_faculty uuid;
  v_target_role   user_role;
  v_target_cohort uuid;
  v_target_faculty uuid;
  v_target_name   text;
  v_existing_reps int;
  v_rank_holder   uuid;
  v_claim         claim_method;
begin
  if p_acting_faculty_rep is distinct from auth.uid() then
    raise exception 'p_acting_faculty_rep must match the calling user';
  end if;

  select role, faculty_id into v_actor_role, v_actor_faculty
  from users where id = p_acting_faculty_rep;

  if v_actor_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may promote a class rep';
  end if;

  if v_actor_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot promote anyone';
  end if;

  select u.role, u.cohort_id, d.faculty_id, u.first_name || ' ' || u.last_name, u.claim_method
  into v_target_role, v_target_cohort, v_target_faculty, v_target_name, v_claim
  from users u
  left join cohorts c     on c.id = u.cohort_id
  left join programmes p  on p.id = c.programme_id
  left join departments d on d.id = p.department_id
  where u.id = p_user_id;

  if v_target_role is null then
    raise exception 'User % not found', p_user_id;
  end if;

  if v_target_cohort is null then
    raise exception 'User % is not in a cohort and cannot be a class rep', p_user_id;
  end if;

  if v_target_faculty is distinct from v_actor_faculty then
    raise exception 'User % is in another faculty', p_user_id;
  end if;

  if v_target_role is distinct from 'student' then
    raise exception
      'User % is a % — only a student can be promoted to class rep', p_user_id, v_target_role;
  end if;

  select count(*)::int into v_existing_reps
  from users
  where cohort_id = v_target_cohort and role = 'class_rep' and id <> p_user_id;

  if v_existing_reps >= 2 then
    raise exception
      'Cohort % already has 2 class reps — demote one before promoting another',
      v_target_cohort;
  end if;

  select id into v_rank_holder
  from users
  where cohort_id = v_target_cohort
    and role = 'class_rep'
    and class_rep_rank = p_rank
    and id <> p_user_id
  limit 1;

  if v_rank_holder is not null then
    raise exception
      'Cohort % already has a % class rep (user %)', v_target_cohort, p_rank, v_rank_holder;
  end if;

  -- --- The attestation (TODO §0.5) -----------------------------------------
  -- Same rule, new source: v_claim now comes from users.claim_method
  -- (fetched above, alongside the target's role/cohort/faculty), not from a
  -- student_roster row. student_roster retires in Task 7 of this plan.
  if v_claim is distinct from 'oauth' and not coalesce(p_identity_attested, false) then
    raise exception
      'User % has not proved their identity with a university email (%). Promote '
      'them only after physically verifying who they are, and pass '
      'p_identity_attested => true to record that you did.',
      p_user_id, coalesce(v_claim::text, 'no roster claim');
  end if;

  update users
  set role = 'class_rep', class_rep_rank = p_rank
  where id = p_user_id;

  insert into role_audit_log (user_id, user_name, cohort_id, action, new_rank, actor_id, snapshot)
  values (
    p_user_id, v_target_name, v_target_cohort, 'promoted', p_rank, p_acting_faculty_rep,
    jsonb_build_object(
      'identity_attested', coalesce(p_identity_attested, false),
      'claim_method',      v_claim,
      'previous_role',     v_target_role
    )
  );
end;
$$;
```

- [ ] **Step 3: Convert the 8 password-path seed accounts to OAuth-shaped signups**

In `supabase/seed.sql`, change these 8 `seed_user(...)` calls (lines 574-618) from `'email'` provider to `'google'`, and change their login-email domain to match the flow each is being assigned — 4 become Flow 2 (school email, matching their existing registration number's domain shape) and 4 become Flow 1 (a personal address):

```sql
-- Mercy Wanjiku Njeri -- Flow 2 (school email)
perform seed_user('22222222-0000-4000-8000-000000000011', 'eb1.67277.23@student.chuka.ac.ke',
                  'Mercy',   'Wanjiku',  'Njeri',  'EB1/67277/23', 'google');
```
```sql
-- Kevin Kariuki Mwangi -- Flow 1 (personal email)
perform seed_user('22222222-0000-4000-8000-000000000014', 'kevin.kariuki23@gmail.com',
                  'Kevin',   'Kariuki',  'Mwangi', 'EB1/67358/23', 'google');
```
```sql
-- Dennis Kiprono -- Flow 2 (school email)
perform seed_user('22222222-0000-4000-8000-000000000021', 'eb1.71004.24@student.chuka.ac.ke',
                  'Dennis',  'Kiprono',  null,     'EB1/71004/24', 'google');
```
```sql
-- Cynthia Nyambura -- Flow 1 (personal email)
perform seed_user('22222222-0000-4000-8000-000000000032', 'cynthia.nyambura23@gmail.com',
                  'Cynthia', 'Nyambura', null,     'EB3/67903/23', 'google');
```
```sql
-- Abdul Rashid Omar -- Flow 2 (school email)
perform seed_user('22222222-0000-4000-8000-000000000041', 'ba2.70115.24@student.chuka.ac.ke',
                  'Abdul',   'Rashid',   'Omar',   'BA2/70115/24', 'google');
```
```sql
-- Lydia Chebet -- Flow 1 (personal email)
perform seed_user('22222222-0000-4000-8000-000000000051', 'lydia.chebet23@gmail.com',
                  'Lydia',   'Chebet',   null,     'EB1/67455/23', 'google');
```
```sql
-- Ruth Nyaguthii -- Flow 2 (school email), cohortless -- exercises the
-- Flow 2 join-request discriminator (approve_cohort_join_request's
-- three-clause check, 0041) against real seed data.
perform seed_user('22222222-0000-4000-8000-000000000053', 'eb1.67488.23@student.chuka.ac.ke',
                  'Ruth',    'Nyaguthii',null,     'EB1/67488/23', 'google');
```
```sql
-- Ian Maina -- Flow 1 (personal email), cohortless -- "a first-year with
-- no university email yet" is still the exact case this account
-- represents; it just gets there via a personal Google signup now
-- instead of the retired password path.
perform seed_user('22222222-0000-4000-8000-000000000054', 'ian.maina26@gmail.com',
                  'Ian',     'Maina',    null,     'EB3/72010/26', 'google');
```

Leave every other `seed_user` call (the original 10 OAuth accounts) untouched. Update the comment directly above the account block (originally "Path A (provider 'email') keeps public.users.email NULL..." around line 568-571) to remove the reference to a password path that no longer exists in this seed file — one sentence noting every account is now a Google OAuth signup, split across the two email tiers, is enough.

- [ ] **Step 4: Replace §9.5's roster-building block with direct new-system identity derivation**

Still in `supabase/seed.sql`, replace the entire `-- 9.5 The roster` `do $$ ... end $$;` block (the two `insert into student_roster` statements plus the final `update users u set reg_number = null ...`) with:

```sql
-- ----------------------------------------------------------------------------
-- 9.5 Identity facts, derived from the registration numbers above
-- ----------------------------------------------------------------------------
-- student_roster is retired (Plan 5, Task 7) — this used to build claimed and
-- unclaimed roster rows from the accounts above. Its replacement writes the
-- same information onto the columns the new system actually reads:
-- claim_method, programme_id, self_sponsored, student_number, admission_year.
-- Direct UPDATE as postgres, same Superadmin-path reasoning seed_user's own
-- comment already gives for reg_number: this file IS the institution,
-- fabricating a starting state rather than pretending to be a signup.
--
-- school_email is not null is the discriminator (not the old
-- email_verified_at check, which only ever distinguished OAuth from the now-
-- retired password path) — every account here is OAuth now, and the auth
-- trigger (0039) already set school_email/personal_email at signup based on
-- address domain.
--
-- reg_number is then nulled for everyone. A genuine Flow 1 or Flow 2 account
-- never has users.reg_number set (0002/0019's invariant, unchanged by this
-- plan) — leaving it populated here would make the seed data inconsistent
-- with what a real account looks like.
do $$
begin
  update users u
  set claim_method   = case when u.school_email is not null then 'oauth' else 'provisional' end::claim_method,
      programme_id   = pr.programme_id,
      self_sponsored = pr.is_self_sponsored,
      student_number = pr.student_number,
      admission_year = pr.admission_year
  from parse_reg_number(u.reg_number) pr
  where u.reg_number is not null
    and u.role in ('student', 'class_rep', 'faculty_rep');

  update users set reg_number = null where reg_number is not null;
end $$;
```

Update `§9.6`'s comment (directly above the `do $$ ... end $$;` block that promotes Brian and Naomi to assistant class rep) — it currently says "Runs after §9.5 because promote_class_rep reads the target's roster claim." Change "roster claim" to "claim_method" so the comment matches what the function now reads (Step 2's fix).

- [ ] **Step 5: Fix `13_bootstrap_test.sql`'s roster-sourced assertion**

In `supabase/tests/13_bootstrap_test.sql:176-180`, change:

```sql
select is(
  (select claim_method::text from student_roster where claimed_by = pg_temp.faith()),
  'oauth',
  '...and their roster claim survives untouched'
);
```

to:

```sql
select is(
  (select claim_method::text from users where id = pg_temp.faith()),
  'oauth',
  '...and their identity claim survives untouched'
);
```

- [ ] **Step 6: Fix `08_phase2_test.sql`'s seed-value-dependent unique-constraint test**

`supabase/tests/08_phase2_test.sql:60-65` currently tries to set account `...014`'s (Kevin's) `reg_number` to `'EB1/67312/23'` (Brian's number), expecting a `23505` because Brian's seeded row still holds that value. After Step 4, `reg_number` is null for every seed account, so nothing conflicts. Replace the test to set up its own conflicting pair instead of borrowing seed's now-nulled values:

```sql
-- users.reg_number is a plain UNIQUE column, tolerant of any number of NULLs
-- (every account here has a null reg_number after seed's Flow 1/2 conversion
-- — that is the correct resting state for an account that never claimed
-- a roster row, back when there was a roster to claim). Set up two accounts
-- holding the SAME non-null value first, so there is something for a third
-- write to collide with.
select lives_ok(
  $$ update users set reg_number = 'EB1/99999/23' where id = '22222222-0000-4000-8000-000000000012' $$,
  'a plain UPDATE can set reg_number on an account for this test''s own setup'
);
select throws_ok(
  $$ update users set reg_number = 'EB1/99999/23' where id = '22222222-0000-4000-8000-000000000014' $$,
  '23505',
  null,
  'two accounts cannot hold the same registration number'
);
```

The count in the next assertion (`select count(*)::int from users where reg_number is null), '>=', 2`) still holds — every account except the one this fixture just set now has a null `reg_number`.

- [ ] **Step 7: Run the full suite**

Run: `supabase db reset && supabase test db`
Expected: full suite green. **This is the step that catches the unnamed risk from Global Constraints** — if any other test relied on a specific seeded `reg_number`, `claim_method`, or roster-row value, it fails here. Fix any such failure by adjusting that test's own fixture (set up the exact state it needs directly, the way Step 6 does), never by reverting seed.sql's new shape.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/0047_seed_identity_and_promote_fix.sql supabase/seed.sql supabase/tests/13_bootstrap_test.sql supabase/tests/08_phase2_test.sql
git commit -m "fix: promote_class_rep reads users.claim_method; convert seed data to new-system identities (plan 5/5, task 1)"
```

---

### Task 2: Retire the recovery-email subsystem

**Files:**
- Create: `supabase/migrations/0048_retire_recovery_email.sql`
- Delete: `supabase/tests/12_recovery_test.sql`
- Delete: `supabase/functions/recovery-request/`
- Delete: `supabase/functions/recovery-email-setup/`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: nothing anything later in this plan depends on. Fully independent — can run before or after any other task.

Fully independent of every other task in this plan. `user_recovery_email`, `set_recovery_email`, `verify_recovery_email`, and `request_password_recovery` exist only to serve password-path accounts (confirmed by `0031`'s own comments: `request_password_recovery` is explicitly "the reg-number/password branch's recovery path"). Once that path is gone, this whole subsystem has no caller. Plan 4's `link_personal_email_identity` is its modern replacement (a linked personal email as the account's post-graduation lifeline). `_shared/axene.ts` is NOT deleted — `supabase/functions/dispatch-push/index.ts` also imports it (confirmed by grep before writing this task).

- [ ] **Step 1: Confirm nothing else references what's being dropped**

Run: `grep -rn "user_recovery_email\|set_recovery_email\|verify_recovery_email\|request_password_recovery" supabase/migrations/*.sql supabase/tests/*.sql supabase/seed.sql`
Expected: every hit is inside `supabase/migrations/0031_recovery_email.sql` itself, `supabase/tests/12_recovery_test.sql`, or a comment in an unrelated file (`0032`, `0033`, `0034` — these are documentation comments explaining *why* a design choice was made elsewhere, referencing `request_password_recovery` as precedent; they do not call it, and are left untouched per the historical-record convention in Global Constraints).

- [ ] **Step 2: Drop the subsystem**

Create `supabase/migrations/0048_retire_recovery_email.sql`:

```sql
-- ============================================================================
-- 0048: Retire the recovery-email subsystem
-- ============================================================================
-- user_recovery_email (0017/0031), set_recovery_email, verify_recovery_email
-- and request_password_recovery existed to serve the password/auth.internal
-- signup path — request_password_recovery's own comment calls it "the
-- reg-number/password branch's recovery path" explicitly. That path retires
-- in this plan (Task 7); this subsystem has no caller left once it does.
-- Plan 4's link_personal_email_identity (0046) is the modern replacement: a
-- linked personal email as the account's lifeline past graduation, with no
-- separate setup-code/verification dance needed.
drop function request_password_recovery(text);
drop function verify_recovery_email(text, uuid);
drop function set_recovery_email(text, uuid);
drop table user_recovery_email;
```

- [ ] **Step 3: Delete the test file and Edge Functions**

```bash
rm supabase/tests/12_recovery_test.sql
rm -rf supabase/functions/recovery-request
rm -rf supabase/functions/recovery-email-setup
```

- [ ] **Step 4: Run the full suite**

Run: `supabase db reset && supabase test db`
Expected: full suite green, one fewer test file than before this task.

- [ ] **Step 5: Commit**

```bash
git add -A supabase/migrations/0048_retire_recovery_email.sql
git commit -m "feat: retire the recovery-email subsystem (plan 5/5, task 2)"
```

---

### Task 3: Rebuild the audit trail

**Files:**
- Create: `supabase/migrations/0049_identity_audit_log.sql`
- Modify: `supabase/tests/21_commit_school_identity_test.sql`, `supabase/tests/22_school_identity_takeover_test.sql`, `supabase/tests/24_link_school_email_identity_test.sql`, `supabase/tests/25_link_personal_email_identity_test.sql`, `supabase/tests/23_identity_linked_audit_event_test.sql` (every place any of these files reference `roster_audit_log` or `roster_audit_action` by name)

**Interfaces:**
- Consumes: nothing from any other task in this plan — this can run at any point relative to Tasks 1, 2, 4-7.
- Produces: `identity_audit_log` (table, replacing `roster_audit_log`), `identity_audit_action` (enum, replacing `roster_audit_action`, values `'claimed', 'takeover', 'unbound', 'dispute_resolved', 'identity_linked'`). Task 6 (`resolve_identity_dispute`) writes to this table directly under its final name and must run after this task.

**Why this order:** dropping `roster_audit_log.roster_id` (an FK to `student_roster`) does not require `student_roster` itself to be gone first — a column drop removes its own FK as a side effect, independent of the referenced table's existence. Doing the rebuild now, before Task 7 drops `student_roster`, means Task 7 never has to touch the audit log at all.

- [ ] **Step 1: Rename, drop the column, rebuild the enum, fix the three surviving writers**

`AUTH_FLOW_REFACTOR.md §8`'s target enum set (`claimed, takeover, unbound, dispute_resolved, identity_linked`) excludes `'created', 'updated', 'removed'` (only ever written by the roster-row-edit functions Task 7 drops) and `'reassigned'` (only ever written by `sync_roster_placement`, dropped in Task 5, and the block Task 4 strips from `create_cohort_stream`). Confirm this with `grep -rn "'reassigned'\|'created'\|'updated'\|'removed'" supabase/migrations/*.sql` before writing this migration — every writer of those four values must already be gone or about to go in a task that has landed by the time this migration is applied in a real `db reset` run (this plan's task ORDER guarantees that for `db reset`, since migrations apply in file-number order and Tasks 1/2 run first regardless).

Create `supabase/migrations/0049_identity_audit_log.sql`. Re-read `supabase/migrations/0041_commit_school_identity.sql` + `0042_school_identity_takeover.sql` (together, `commit_school_identity`'s current combined body), `0045_link_school_email_identity.sql`, and `0046_link_personal_email_identity.sql` immediately before writing this — confirm no migration after `0046` redefines any of the three (none does, as of this plan's authoring):

```sql
-- ============================================================================
-- 0049: identity_audit_log replaces roster_audit_log
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §8: "roster audit log" stops describing what it
-- holds once there is no roster. Three changes: rename the table, drop
-- roster_id (nothing left for it to point at once student_roster retires,
-- Task 7 of this plan), and rebuild the action enum down to only the values
-- that still mean something. Done here, ahead of the student_roster drop,
-- because dropping roster_id's FK does not require student_roster to be
-- gone first -- doing it now means the student_roster drop never has to
-- touch this table at all.
alter table roster_audit_log rename to identity_audit_log;
alter table identity_audit_log drop column roster_id;

create type identity_audit_action as enum (
  'claimed', 'takeover', 'unbound', 'dispute_resolved', 'identity_linked'
);

alter table identity_audit_log
  alter column action type identity_audit_action
  using action::text::identity_audit_action;

drop type roster_audit_action;

comment on table identity_audit_log is
  'The entire record of every identity trust decision the system makes -- '
  'renamed from roster_audit_log (AUTH_FLOW_REFACTOR.md §8) once there was '
  'no roster left for that name to describe. Denormalized: reg_number is '
  'stored as its own plain text value, not derived by joining elsewhere, so '
  'the trail survives whatever it is about being changed or removed.';


-- ============================================================================
-- The three surviving writers, updated to the new table/column shape
-- ============================================================================
-- Bodies otherwise unchanged from their current, live definitions --
-- confirmed by re-reading 0041/0042, 0045 and 0046 immediately before
-- writing this migration. Only the audit INSERT statements change: the
-- table name, and dropping roster_id from the column list (it is gone).
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
```

Note: none of the three functions' `comment on function`, `revoke`/`grant` statements need restating — `CREATE OR REPLACE FUNCTION` does not touch a function's existing grants (only its body/definition), and comments survive a body replacement too. Nothing else in this migration file is needed beyond the block above.

- [ ] **Step 2: Update every test that references the old table/enum names**

Run: `grep -rln "roster_audit_log\|roster_audit_action" supabase/tests/*.sql`

In each matching file (`21_commit_school_identity_test.sql`, `22_school_identity_takeover_test.sql`, `23_identity_linked_audit_event_test.sql`, `24_link_school_email_identity_test.sql`, `25_link_personal_email_identity_test.sql`), replace every occurrence of `roster_audit_log` with `identity_audit_log` and `roster_audit_action` with `identity_audit_action`. None of these tests reference the `roster_id` column (confirmed by grep — every existing assertion in these five files reads `reg_number`, `action`, `actor_id`, `target_user`, or `snapshot`, never `roster_id`), so no assertion logic changes, only the two names.

- [ ] **Step 3: Run the full suite**

Run: `supabase db reset && supabase test db`
Expected: full suite green.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0049_identity_audit_log.sql supabase/tests/21_commit_school_identity_test.sql supabase/tests/22_school_identity_takeover_test.sql supabase/tests/23_identity_linked_audit_event_test.sql supabase/tests/24_link_school_email_identity_test.sql supabase/tests/25_link_personal_email_identity_test.sql
git commit -m "feat: rebuild roster_audit_log as identity_audit_log (plan 5/5, task 3)"
```

---

### Task 4: Strip the roster from `create_cohort_stream`; drop the two roster-keyed stream functions

**Files:**
- Create: `supabase/migrations/0050_stream_functions_without_roster.sql`
- Modify: `supabase/tests/09_streams_test.sql`

**Interfaces:**
- Consumes: nothing from any other task.
- Produces: `create_cohort_stream` unchanged in every observable behavior except that it no longer touches `student_roster` or writes an `'reassigned'` audit row. `assign_students_to_streams` and `cohort_unstreamed_members` no longer exist.

Fully independent of every other task. Re-read `supabase/migrations/0028_stream_assignment.sql`'s current `create_cohort_stream` body before writing this — confirm no later migration redefines it (none does).

- [ ] **Step 1: Strip the roster-touching block and drop the two roster-keyed functions**

Create `supabase/migrations/0050_stream_functions_without_roster.sql`:

```sql
-- ============================================================================
-- 0050: Stream functions without the roster
-- ============================================================================
-- create_cohort_stream's only dependency on student_roster was a side effect
-- (moving the first rep's roster row to follow them into the stream, and
-- logging that move) -- everything else it does (writing cohorts, users,
-- role_audit_log) is untouched. Stripped, not dropped: splitting a cohort
-- into streams survives this plan.
--
-- assign_students_to_streams has no surgical fix -- it looks up rows BY
-- REGISTRATION NUMBER IN THE ROSTER, i.e. for students who have not signed
-- up yet. That input does not exist once student_roster is gone (Task 7 of
-- this plan), and there is no new-system equivalent: nothing exists for a
-- given student until they actually sign up. Scoped out of this plan
-- entirely during brainstorming -- a future, narrower rebuild (keyed on
-- users.student_number, for already-claimed students only) stays cheap
-- because cohorts.parent_cohort_id/stream (the streams SCHEMA, 0025) is
-- untouched here.
--
-- cohort_unstreamed_members reads directly from student_roster with no
-- surgical fix either, and nothing calls it besides this migration's own
-- predecessor and its test (confirmed by grep before writing this
-- migration) -- dropped rather than redesigned around a users-based
-- definition nobody has asked for.
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

drop function assign_students_to_streams(jsonb, uuid, uuid);
drop function cohort_unstreamed_members(uuid);
```

- [ ] **Step 2: Rewrite `09_streams_test.sql`**

Delete the entire `§6 Assigning students to streams (0028 §2, §3)` section (from its header comment through the last assertion before `§7`'s header) — it tests exclusively `assign_students_to_streams` and `cohort_unstreamed_members`, both dropped in Step 1. Nothing in `§1`-`§5` or `§7` references either function or `student_roster` (confirmed by reading the whole file before writing this task).

Recount the file's assertions after deleting §6 and set `plan(N)` to the exact count — do not trust this plan's own arithmetic. Run:
```bash
grep -cE "^select (is|ok|lives_ok|throws_ok|throws_like)\(" supabase/tests/09_streams_test.sql
```
after making the deletion, and set `plan(N)` in the file to match that number exactly.

- [ ] **Step 3: Run the full suite**

Run: `supabase db reset && supabase test db`
Expected: full suite green.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0050_stream_functions_without_roster.sql supabase/tests/09_streams_test.sql
git commit -m "feat: strip roster dependency from create_cohort_stream, drop roster-keyed stream functions (plan 5/5, task 4)"
```

---

### Task 5: Drop `sync_roster_placement` and its two call sites

**Files:**
- Create: `supabase/migrations/0051_drop_sync_roster_placement.sql`
- Delete: `supabase/tests/10_placement_test.sql`

**Interfaces:**
- Consumes: nothing from any other task.
- Produces: `create_cohort_with_class_rep` and `approve_cohort_join_request` unchanged in every observable behavior — `sync_roster_placement` already no-ops for every account with no `student_roster` row (its own first check, `if v_roster_id is null then return false`), which is every account in this schema after Task 1. Removing the call removes a guaranteed-no-op, not a behavior.

**Re-read the CURRENT live body of `approve_cohort_join_request` from its migration file before writing this task's replacement — do not copy the body below without re-verifying it first.** It was last redefined in `0041` (not `0040` — this plan's own authoring initially assumed `0040` and had to correct itself; confirm which file currently defines it with `grep -rn "create or replace function approve_cohort_join_request" supabase/migrations/*.sql` and read the highest-numbered match before writing anything). The body given below is what that grep found at the time this plan was written — re-verify it is still current, because Tasks 1-4 of this same plan do not touch this function, but a careless read could still transcribe it wrong.

- [ ] **Step 1: Confirm the current bodies, then edit**

Run:
```bash
grep -rn "create or replace function create_cohort_with_class_rep\|create or replace function approve_cohort_join_request" supabase/migrations/*.sql
```
Read the highest-numbered file for each. Create `supabase/migrations/0051_drop_sync_roster_placement.sql`, reproducing each function's current full body with only the `perform sync_roster_placement(...)` line removed — for `create_cohort_with_class_rep` (currently `0029`, unless your grep found a later redefinition), remove the line reading `perform sync_roster_placement(p_first_rep_id, v_cohort_id, p_created_by, 'cohort_created');` immediately before `return v_cohort_id;`. For `approve_cohort_join_request` (currently `0041`, unless your grep found a later redefinition), remove the line reading `perform sync_roster_placement(v_student_id, v_cohort_id, p_decided_by, 'join_request_approved');` immediately before the function's closing `end;`. Change nothing else in either function. Then:

```sql
drop function sync_roster_placement(uuid, uuid, uuid, text);
drop function roster_placement_divergences();
```

- [ ] **Step 2: Delete the test file**

```bash
rm supabase/tests/10_placement_test.sql
```

This file's entire subject (`sync_roster_placement`, `roster_placement_divergences`, and `roster_assert_may_write` — confirmed by reading the file's own header before writing this task) has no new-system meaning: nothing exists to "sync placement" for once there is no roster row to sync, and `roster_assert_may_write` is dropped in Task 7.

- [ ] **Step 3: Run the full suite**

Run: `supabase db reset && supabase test db`
Expected: full suite green.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0051_drop_sync_roster_placement.sql
git rm supabase/tests/10_placement_test.sql
git commit -m "feat: drop sync_roster_placement and roster_placement_divergences (plan 5/5, task 5)"
```

---

### Task 6: `resolve_identity_dispute` — the replacement for §5's escalation case

**Files:**
- Create: `supabase/migrations/0052_resolve_identity_dispute.sql`
- Create: `supabase/tests/26_resolve_identity_dispute_test.sql`

**Interfaces:**
- Consumes: `identity_audit_log` / `identity_audit_action` (Task 3 — must run after it).
- Produces: `resolve_identity_dispute(p_user_id uuid, p_actor_id uuid) returns void`, granted to `authenticated`.

`link_school_email_identity`'s escalation path ("the identity derived from this account's linked school email does not match what was recorded at signup") currently has no landing pad — a faculty rep who investigates and decides the *stored* (self-typed, Flow 1) data was wrong has no RPC to call. This function is that RPC: it clears the account's self-typed identity facts, dropping it out of `'provisional'`, so the student can redo `claim_identity_personal` with corrected data and then retry `link_school_email_identity` against the same, still-linked school identity.

**Deliberately does NOT clear `cohort_id`.** The account being unstuck here hasn't lost its identity to anyone who proved a better claim (that's what eviction, in `link_school_email_identity`'s takeover branch, is for) — a faculty rep has simply decided the *stored* data can't be trusted yet. Ejecting the student from a cohort they may legitimately belong to is a real, visible consequence with no automatic path back (re-request, re-approve). If the dispute turns out to also involve the wrong programme, `claim_identity_personal`'s own existing guard (`v_user.cohort_id is not null` → programme must match) catches that on the retry, rather than this function guessing at it.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/26_resolve_identity_dispute_test.sql`:

```sql
-- ============================================================================
-- 26: resolve_identity_dispute (0052)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5 step 4's escalation ("routes to the faculty rep")
-- had no landing pad until this function: a faculty rep, having investigated
-- out-of-band, clears the disputed account's self-typed identity facts so it
-- can redo claim_identity_personal with corrected data and retry
-- link_school_email_identity against the school identity already sitting in
-- auth.identities from the original attempt.
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
create function pg_temp.programme(p_code text) returns uuid language sql stable as $$
  select id from programmes where code = p_code;
$$;
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
  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
$$;
create function pg_temp.fst_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;


-- ---------------------------------------------------------------------------
-- §1 The disputed sequence: mistyped Flow 1 claim, escalated link, resolved,
-- retried successfully.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  'aaaaaaaa-1111-4000-8000-000000000001', 'disputed1@gmail.com'
);
select pg_temp.act_as('aaaaaaaa-1111-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '90104', 2026, %L) $$,
         pg_temp.programme('EB1'), 'aaaaaaaa-1111-4000-8000-000000000001'::uuid),
  'a Flow 1 claim, deliberately wrong -- the real number is 90103'
);

select pg_temp.link_identity(
  'aaaaaaaa-1111-4000-8000-000000000001', 'eb1.90103.26@student.chuka.ac.ke'
);
select throws_ok(
  $$ select link_school_email_identity('aaaaaaaa-1111-4000-8000-000000000001'::uuid) $$,
  'P0001',
  null,
  'the mismatch escalates -- nobody holds 90103, so this is not a takeover'
);
select is(
  (select claim_method::text from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  'provisional',
  '...the account is still stuck as provisional after the escalation'
);

select pg_temp.act_as(pg_temp.fst_rep());
select lives_ok(
  format($$ select resolve_identity_dispute(%L::uuid, %L::uuid) $$,
         'aaaaaaaa-1111-4000-8000-000000000001', pg_temp.fst_rep()),
  'a faculty rep resolves the dispute'
);
```

Continue the test file:

```sql
select is(
  (select claim_method from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  null,
  '...claim_method is cleared, dropping the account out of provisional'
);
select is(
  (select student_number from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  null,
  '...the wrong self-typed student_number is cleared too'
);
select is(
  (select action::text from identity_audit_log
   where target_user = 'aaaaaaaa-1111-4000-8000-000000000001' and action = 'dispute_resolved'
   order by created_at desc limit 1),
  'dispute_resolved',
  '...an audit row records the resolution'
);

select pg_temp.act_as('aaaaaaaa-1111-4000-8000-000000000001');
select lives_ok(
  format($$ select claim_identity_personal(%L, false, '90103', 2026, %L) $$,
         pg_temp.programme('EB1'), 'aaaaaaaa-1111-4000-8000-000000000001'::uuid),
  'the student redoes the Flow 1 claim, this time with the correct number'
);
select lives_ok(
  $$ select link_school_email_identity('aaaaaaaa-1111-4000-8000-000000000001'::uuid) $$,
  'the retry succeeds -- the school identity linked before the dispute is still there'
);
select is(
  (select claim_method::text from users where id = 'aaaaaaaa-1111-4000-8000-000000000001'),
  'oauth',
  '...and the account is fully upgraded this time'
);


-- ---------------------------------------------------------------------------
-- §2 Guards
-- ---------------------------------------------------------------------------
select pg_temp.act_as('aaaaaaaa-1111-4000-8000-000000000001');
select throws_ok(
  format($$ select resolve_identity_dispute(%L::uuid, %L::uuid) $$,
         'aaaaaaaa-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-000000000001'),
  'P0001',
  'Only a faculty_rep may resolve an identity dispute',
  'a non-faculty-rep cannot resolve a dispute'
);

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `supabase test db`
Expected: FAIL — `resolve_identity_dispute` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `supabase/migrations/0052_resolve_identity_dispute.sql`:

```sql
-- ============================================================================
-- 0052: resolve_identity_dispute — the replacement for resolve_roster_dispute
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §5 step 4's escalation had no landing pad: a faculty
-- rep who decides a disputed account's self-typed (Flow 1) identity facts
-- were wrong has no RPC to act on that decision. This is it.
--
-- Clears claim_method, programme_id, self_sponsored, student_number,
-- admission_year -- dropping the account out of 'provisional' so
-- claim_identity_personal (0040) will accept a fresh claim with corrected
-- data. Does NOT clear cohort_id: this account did not lose its identity to
-- anyone who proved a better claim (that is link_school_email_identity's
-- takeover branch, 0045) -- a rep simply decided the self-typed data can't
-- be trusted yet, and ejecting a student from a cohort they may legitimately
-- belong to is a real, visible consequence with no automatic path back. If
-- the dispute also involves the wrong programme, claim_identity_personal's
-- own existing guard (cohort_id is not null -> programme must match) catches
-- that on the retry.
--
-- Any faculty_rep may call this, not scoped to one faculty -- same shape as
-- unclaimed_synthetic_signups' precedent (0036): a disputed account has no
-- cohort_id necessarily set to any particular faculty at this point, so
-- there is nothing to scope by.
create or replace function resolve_identity_dispute(
  p_user_id  uuid,
  p_actor_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role uuid;
  v_target     users;
begin
  if p_actor_id is distinct from auth.uid() then
    raise exception 'p_actor_id must match the calling user';
  end if;

  if not exists (select 1 from users where id = p_actor_id and role = 'faculty_rep') then
    raise exception 'Only a faculty_rep may resolve an identity dispute';
  end if;

  select * into v_target from users where id = p_user_id;

  if v_target.id is null then
    raise exception 'User % not found', p_user_id;
  end if;

  update users
  set claim_method   = null,
      programme_id   = null,
      self_sponsored = null,
      student_number = null,
      admission_year = null
  where id = p_user_id;

  insert into identity_audit_log (reg_number, action, actor_id, target_user, snapshot)
  values (
    coalesce(reg_number_from_email(v_target.school_email), 'unknown'),
    'dispute_resolved', p_actor_id, p_user_id,
    jsonb_build_object(
      'previous_claim_method',   v_target.claim_method,
      'previous_student_number', v_target.student_number
    )
  );
end;
$$;

comment on function resolve_identity_dispute(uuid, uuid) is
  'AUTH_FLOW_REFACTOR.md §5 step 4''s escalation, resolved: a faculty rep '
  'clears a disputed account''s self-typed identity facts (never cohort_id) '
  'so the student can redo claim_identity_personal with corrected data and '
  'retry link_school_email_identity. Replaces resolve_roster_dispute, '
  'retired in this plan (task 7) along with the roster it operated on.';

revoke execute on function resolve_identity_dispute(uuid, uuid) from public, anon;
grant  execute on function resolve_identity_dispute(uuid, uuid) to authenticated, service_role;
```

**Note on the audit row's `reg_number` value:** unlike every other writer in this schema, the disputed account's `school_email` may itself be the thing under dispute (it was never successfully confirmed — the escalation happened before `link_school_email_identity`'s final `UPDATE` ever ran, so `school_email` is still null at the time this function is called). `reg_number_from_email(null)` returns `null`, and `identity_audit_log.reg_number` is `NOT NULL` (unchanged by Task 3) — hence the `coalesce(..., 'unknown')`. This is the one case in the whole schema where a real slash-form registration number genuinely does not exist yet to record.

- [ ] **Step 4: Run test to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: `supabase/tests/26_resolve_identity_dispute_test.sql` passes, full suite green. Recount the file's assertions yourself (`grep -cE "^select (is|ok|lives_ok|throws_ok)\(" supabase/tests/26_resolve_identity_dispute_test.sql`) and set `plan(N)` to match — every plan in this repo's history has needed at least one count correction; verify empirically rather than trusting the number written above.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0052_resolve_identity_dispute.sql supabase/tests/26_resolve_identity_dispute_test.sql
git commit -m "feat: add resolve_identity_dispute (plan 5/5, task 6)"
```

---

### Task 7: Drop the core roster functions and `student_roster` itself

**Files:**
- Create: `supabase/migrations/0053_drop_student_roster.sql`
- Delete: `supabase/tests/05_roster_test.sql`, `supabase/tests/06_claim_and_takeover_test.sql`, `supabase/tests/16_unclaimed_synthetic_signups_test.sql`
- Modify: `supabase/tests/00_access_control_test.sql:222-233`

**Interfaces:**
- Consumes: Task 1 (seed data no longer populates `student_roster`) and Task 3 (`identity_audit_log.roster_id` — the FK blocking this table drop — is already gone).
- Produces: nothing anything later depends on. This is the last schema-dropping task.

**Why this order:** `student_roster` cannot be dropped with a plain (non-`CASCADE`) `DROP TABLE` while any foreign key still references it — Task 3 already removed the only one (`identity_audit_log`'s former `roster_id` column). Seed data must already be off the roster (Task 1) or `supabase db reset` would try to insert into a table this task is about to drop.

- [ ] **Step 1: Drop the seven core functions and the table**

Create `supabase/migrations/0053_drop_student_roster.sql`:

```sql
-- ============================================================================
-- 0053: Drop student_roster and the functions built only for it
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §10: this retires student_roster, the password/
-- auth.internal signup path, and claim_roster_row's roster-matching logic
-- outright. Everything these seven functions did has a new-system
-- replacement already shipped in Plans 1-4 (claim_identity_personal,
-- commit_school_identity, link_school_email_identity) or, for
-- resolve_roster_dispute specifically, in this plan's own Task 6
-- (resolve_identity_dispute).
--
-- Plain DROP TABLE, no CASCADE: identity_audit_log's former roster_id
-- column (the only foreign key into this table) was already dropped in
-- Task 3, so this drop has nothing left to fail loudly about. If it does
-- fail, something in this plan's ordering assumption was wrong -- do not
-- add CASCADE to make the error go away; find and fix the real dependency.
drop function roster_assert_may_write(uuid, text, uuid);
drop function roster_add_student(text, text, text, text, uuid, uuid);
drop function roster_bulk_import(jsonb, uuid, uuid);
drop function roster_correct_student(uuid, text, text, text, text, uuid);
drop function roster_remove_student(uuid, uuid);
drop function claim_roster_row(text, text, text, uuid);
drop function resolve_roster_dispute(uuid, uuid);
drop function unclaimed_synthetic_signups();

drop table student_roster;
```

- [ ] **Step 2: Delete the test files this drop makes meaningless**

```bash
rm supabase/tests/05_roster_test.sql
rm supabase/tests/06_claim_and_takeover_test.sql
rm supabase/tests/16_unclaimed_synthetic_signups_test.sql
```

- [ ] **Step 3: Prune `00_access_control_test.sql`'s stale function-name list**

In `supabase/tests/00_access_control_test.sql:222-233`, the `anon` cannot-execute check's function-name array currently reads:

```sql
       'create_event', 'cancel_event', 'confirm_event_cohort', 'decline_event_cohort',
       'leave_event_cohort', 'reschedule_event', 'get_venue_occupancy',
       'is_venue_available', 'create_cohort_with_class_rep', 'demote_class_rep',
       'approve_cohort_join_request', 'decline_cohort_join_request',
       -- Phase R. mark_email_verified used to be on this list and was dropped
       -- by 0019 rather than hardened — after the roster there is no client
       -- assertion left for it to validate.
       'claim_roster_row', 'resolve_roster_dispute', 'roster_add_student',
       'roster_bulk_import', 'roster_correct_student', 'roster_remove_student',
       'roster_assert_may_write', 'parse_reg_number', 'normalize_reg_number',
       'reg_number_from_email',
       -- Phase 1 (0022). Every one of these mutates a schedule or a role, so
       -- every one of them must be closed to anon the moment it is created —
       -- CREATE FUNCTION grants EXECUTE to PUBLIC, so the revoke is not optional.
       'cancel_recurrence_group', 'update_event',
       'confirm_attendance', 'unconfirm_attendance', 'promote_class_rep'
```

Remove the seven now-dropped function names and their explanatory comment (they query `pg_proc` by name, so a dropped function's name simply stops matching — not a bug, but stale weight nobody should have to read past), and add `resolve_identity_dispute` (this plan's own new function, Task 6) to the list this check protects:

```sql
       'create_event', 'cancel_event', 'confirm_event_cohort', 'decline_event_cohort',
       'leave_event_cohort', 'reschedule_event', 'get_venue_occupancy',
       'is_venue_available', 'create_cohort_with_class_rep', 'demote_class_rep',
       'approve_cohort_join_request', 'decline_cohort_join_request',
       'parse_reg_number', 'normalize_reg_number', 'reg_number_from_email',
       -- Phase 1 (0022). Every one of these mutates a schedule or a role, so
       -- every one of them must be closed to anon the moment it is created —
       -- CREATE FUNCTION grants EXECUTE to PUBLIC, so the revoke is not optional.
       'cancel_recurrence_group', 'update_event',
       'confirm_attendance', 'unconfirm_attendance', 'promote_class_rep',
       'resolve_identity_dispute'
```

- [ ] **Step 4: Run the full suite**

Run: `supabase db reset && supabase test db`
Expected: full suite green, three fewer test files than before this task.

- [ ] **Step 5: Commit**

```bash
git add -A supabase/migrations/0053_drop_student_roster.sql supabase/tests/00_access_control_test.sql
git commit -m "feat: drop student_roster and the roster-only functions (plan 5/5, task 7)"
```

---

### Task 8: Rewrite `AUTH_FLOW.md`

**Files:**
- Modify: `supabase/AUTH_FLOW.md` (full rewrite)

**Interfaces:**
- Consumes: nothing — documentation only, no code dependency. Run last so it describes the system's actual final shape rather than an intermediate state.

`AUTH_FLOW.md` currently documents the roster/password system end-to-end and exclusively — "Path A — Registration number + password," "Path B — University email (Google OAuth)" via `claim_roster_row`, password recovery, and every numbered user journey. None of that exists after Task 7. This is a full rewrite, not a patch.

- [ ] **Step 1: Rewrite the document**

Replace the entire contents of `supabase/AUTH_FLOW.md` with a document covering, in the same "client contract and user journeys" spirit as the original (exact call sequences, exact strings, exact things a user sees):

- **Part 1, Technical: the client contract.** Two signup paths, both Google OAuth via `linkIdentity()`-capable signup: personal email (any address) and school email (`@student.chuka.ac.ke` only). For personal-email signups: the client calls `claim_identity_personal(programme_id, self_sponsored, student_number, admission_year, acting_user)` immediately after signup, before any cohort selection. For school-email signups: no client-side identity call at all — the four identity facts are derived server-side and committed only when a class rep approves a cohort join request (`commit_school_identity`, called internally by `approve_cohort_join_request`). Both paths then go through the same `cohort_join_requests` flow (insert a request, a class rep approves or declines).
- **Linking:** a personal-email account can later call `link_school_email_identity(acting_user)` immediately after a successful `linkIdentity()` call against a school address, to upgrade in place without a second signup. Any `oauth` (school-email-verified) account can call `link_personal_email_identity(acting_user)` after linking a personal address, as a post-graduation recovery contact — unconditional, overwrites on re-link.
- **Takeover:** if a school-email link (or approval) derives a `student_number` already held by a `provisional` account, that account is evicted automatically (notified, audited) — unless the holder is already `oauth` (escalates — this cannot happen under correct operation) or a `class_rep` (escalates — scheduling authority is never auto-evicted).
- **Dispute resolution:** if a linked school email's derived identity disagrees with what was recorded at signup, and nobody else holds the derived number, the link is refused and the client should tell the user to contact their faculty rep. A faculty rep resolves this with `resolve_identity_dispute(user_id, acting_faculty_rep)`, after which the student redoes `claim_identity_personal` with corrected data and retries the link.
- **Part 2, UX implications:** what a client must show for each of the above — a school-email signup showing "pending faculty approval" with no identity form at all (since there's nothing to type); a personal-email signup showing the identity form immediately; the link-flow's three outcomes (silent upgrade, "contact your faculty rep," or nothing visible at all if it's a takeover of someone else's stale squatting); the recovery-contact flow for school-email accounts.
- Remove every reference to `student_roster`, `claim_roster_row`, the password/`auth.internal` path, and `request_password_recovery` — none of it exists.

Base the exact function names, parameter names, and error message wording on the live migration files (`0040`, `0041`/`0042`, `0045`, `0046`, `0052` — all created or last touched by Plans 3-5), not on this plan's prose summary above, which is deliberately not verbatim.

- [ ] **Step 2: Commit**

```bash
git add supabase/AUTH_FLOW.md
git commit -m "docs: rewrite AUTH_FLOW.md for the OAuth-only system (plan 5/5, task 8)"
```

---

### Task 9: Close the password signup door at the config layer

**Files:**
- Modify: `supabase/config.toml`

**Interfaces:**
- Consumes: nothing. Fully independent, can run at any point in this plan.

`[auth.email] enable_signup` is still `true` — the Supabase-Auth-level toggle that lets a client call `auth.signUp({email, password})` at all, independent of the app-level `@auth.internal` synthetic-address trick this plan retires everywhere else. The top-level `enable_signup` (which gates *all* signups, OAuth included) must stay `true` — only the email-specific one changes.

- [ ] **Step 1: Flip the toggle**

In `supabase/config.toml`, under the `[auth.email]` section, change:

```toml
# Allow/disallow new user signups via email to your project.
enable_signup = true
```

to:

```toml
# Allow/disallow new user signups via email to your project. Disabled --
# the password/auth.internal signup path retired in plan 5/5 of the auth
# redesign (AUTH_FLOW_REFACTOR.md §10). Every signup is Google OAuth now
# (the top-level enable_signup above stays true for that).
enable_signup = false
```

- [ ] **Step 2: Verify the full suite still passes**

Run: `supabase db reset && supabase test db`
Expected: full suite green — this config change affects the Auth service's own signup endpoint, not anything pgTAP exercises directly, so this step is a sanity check that nothing in this plan accidentally relied on email/password signup still being open.

- [ ] **Step 3: Commit**

```bash
git add supabase/config.toml
git commit -m "chore: disable email/password signup at the config layer (plan 5/5, task 9)"
```
