# Backend TODO

Standing status and work order for the Edutime backend repo.
Last updated: 2026-08-25 — Phases 1, 2, **S**, **R.5**, **3.5** and **3.2** complete
(`0020`–`0036`). Phase 3 is done: `3.5`, `3.2`, and `3.1` all shipped.

---

## Where things stand

`supabase db reset` runs clean: 36 migrations, seed, and **405 pgTAP tests passing**
across seventeen files.

```
supabase db reset      # migrations + seed
supabase test db       # 405 tests, all green
```

Identity is now anchored: `reg_number` can only be set by claiming a pre-declared roster
row (`0017`–`0019`), never asserted by the client. Google OAuth is configured and live.

The event API is closed: recurrence materializes and cancels as a series, attendance can
be confirmed and un-confirmed, lectures can be edited, and `promote_class_rep` reaches the
assistant rank (`0022_event_api.sql`, `1.1`–`1.4`, `1.7`). `TECHNICAL_DISCOVERY.md` §4/§5/§8/§11
are updated to match.

Phase 2 is done (`0023`–`0024`, spec in [`PHASE2_HANDOFF.md`](PHASE2_HANDOFF.md)): the four
missing unique constraints are in, cohort names carry their pace, an account that has
scheduled lectures **can finally be deleted** without the cascade aborting, `events_current`
filters what it claims to, `demote_class_rep` leaves an audit trail, and two dead columns
are gone.

Phase S is done (`0025`–`0030`): a cohort too big for one room can be **split into
streams**, which are child cohorts — so `(programme, intake, pace)` stays unique for
anything that is actually a cohort. Splits are incremental, refuse while a timetable
exists, and carry roster rows with them. **Recurring combined lectures** now work, with one
confirmation covering a whole series.

**`R.5` shipped using Axene (`mail.axene.io`) as the transactional mailer, verified with
a real send.** `supabase/functions/` now exists — the first work in the repo that is not
SQL. The `401 not_authenticated` that looked like an Axene account bug turned out to be
a plain URL bug in this repo: `POST /v1/emails` (no trailing slash) 401s regardless of
the key; `POST /v1/emails/` (trailing slash) is the real endpoint. See `R.5` below for
how that was found.

**Phase 3 is done as of `0034`.** `3.1` (push/FCM) shipped last, reusing
`functions/_shared`: `device_tokens` + `register_device_token()`, a `pg_cron`-polled
`claim_pending_pushes()` / `invoke_push_dispatch()` pair (not an on-insert webhook — see
`3.1` below for why), and `functions/dispatch-push` + `_shared/fcm.ts` for the actual FCM
HTTP v1 send. The SQL half is pgTAP-tested and the full local pipeline runs end-to-end;
the FCM send itself is unverified — no Firebase project configured, no Flutter client to
hold a real device token yet. See `TECHNICAL_DISCOVERY.md` §11.

**Nothing left before the Flutter client.** Every API-surface change the ordering principle
below wanted done first is now done, so the remaining work no longer competes with hand-
written Dart models. `4.3` still applies to anything new.

**Done:** conflict detection, the trust chain, the combined-lecture proposal workflow,
realtime broadcast + channel authorization, notification fan-out, RLS on all 14 tables,
table/column privileges, and a Chuka-shaped dev dataset (2 faculties, 31 programmes,
75 courses, 117 rooms, 4 cohorts, 23 events).

The `0014`–`0016` trio is one correctness pass over the schema, split by theme. Apply in
order; they are not independent. `0014` grants EXECUTE on functions `0015`/`0016` then
redefine — safe because the pass drops no function anywhere and `CREATE OR REPLACE`
preserves the ACL.

**Not done:** the Flutter client itself — none of Phase 3's infrastructure (push
delivery, the confirmation-nudge job, the Superadmin runbook) has a real device or app
to exercise it against yet.

---

## The ordering principle

**API-surface changes come first, before the Flutter client exists.**

There is no code generation between this repo and the Flutter repo — Dart models are
hand-written (§1, §12 of `TECHNICAL_DISCOVERY.md`). Every change to a function signature
after the client is built is manual sync work with no compiler catching the drift.
Several of the items below change `create_event`'s signature or behaviour. Doing them in
one migration, now, costs one round of client work instead of several.

(0.1's decision took the horizon off `create_event`'s parameter list and onto `cohorts`,
so **1.2** no longer changes the signature — but it changes the *behaviour* and adds
columns the client reads, so it still belongs in the same pass.)

Everything else is ordered by dependency, then by cost.

---

## Phase 0 — decisions to make before writing code

These blocked everything downstream and needed a human answer, not a code change.
**All resolved 2026-08-01. Phase 0 is complete; Phase R is the next work.**

- [x] **0.1 — Recurrence strategy. DECIDED 2026-08-01.** **Materialize on create,
  bounded by the cohort's semester end date.** Lazy expansion is ruled out for good: the
  EXCLUDE constraints need real rows to conflict against, and conflict prevention is the
  product. Implementation lands in **1.2**. The five sub-decisions:

  1. **Horizon = `cohorts.semester_end_date`.** `cohorts` has no semester window today —
     the columns are `programme_id, name, join_code, intake_year, current_semester,
     pace, created_at`. So "bounded by the cohort's semester" is not currently
     expressible, and **1.2 must first add `semester_start_date` / `semester_end_date`
     to `cohorts`** (nullable, backfilled in `seed.sql`). `create_event` refuses
     recurrence when the initiating cohort's `semester_end_date` is null, and refuses a
     `p_start` past it. Rejected: a rep-supplied `p_until` (no guardrail — a rep can
     generate three years of rows) and a fixed `p_occurrence_count` (pushes the
     "until end of semester" translation into Flutter).
  2. **Occurrences are generated from `p_start` by the `recurrence` enum step**
     (`day`/`week`/`month`) up to and including `semester_end_date`.
  3. **All-or-nothing on a clash.** Any generated occurrence that trips either EXCLUDE
     constraint aborts the whole series with an actionable error naming the clashing
     date. This is also the cheap option — the function is one transaction, so
     skip-and-report would cost per-occurrence savepoints.
  4. **A rescheduled or edited occurrence stays in its series** — `reschedule_event`
     already copies `recurrence_group_id` onto the replacement row, so this is current
     behaviour made real rather than a change. Consequence to build in **1.2**:
     `cancel_recurrence_group` cancels moved occurrences too.
  5. **Recurrence is refused for combined lectures.** Recurring cross-cohort series are
     explicitly out of scope (DISCOVERY, and §7/§11 of `TECHNICAL_DISCOVERY.md`), so
     `create_event` raises when `p_recurrence <> 'none'` and more than one cohort is
     attached. This removes most of 1.2's complexity — no per-occurrence multi-rep
     reconfirmation to design.

     > **PICKED UP 2026-08-20 as `S.4`.** Deferred here, not rejected — the stated cost
     > was designing per-occurrence multi-rep reconfirmation, which was a fair call at the
     > time. `0022` has since built `cancel_recurrence_group`, i.e. the same
     > "act on a whole series at once" shape, so that cost is now small. The guard shipped
     > in `0022` §1 and stays until `S.4` lifts it.

  Still open, and deliberately deferred out of 1.2: **semester rollover**. When a cohort
  advances `current_semester`, its materialized occurrences do not regenerate and its
  semester dates go stale. No automatic path is planned for MVP — a rep re-creates the
  series. Revisit if it bites.

- [x] **0.2 — Split `0014`. DONE 2026-08-01.** Split into three themed migrations,
  content conserved exactly (1,393 body lines, verified by byte-identical reassembly
  before the cut):

  | File | Sections (old `0014` §) |
  |---|---|
  | `0014_access_control_and_privileges.sql` | RLS recursion §1, column guards §2, function grants §6, table privileges §10, faculties RLS §12 |
  | `0015_event_function_fixes.sql` | workflow guards §3, venue availability §5, enum cast + `reschedule_event` §7, sync trigger §11 |
  | `0016_trust_scope_and_realtime.sql` | faculty scoping §4, broadcast §8, channel authz §9, join-request privilege §13 |

  Each file's sections were renumbered `§1..§N` and every internal cross-reference
  rewritten to match; references to `TECHNICAL_DISCOVERY.md` sections are now spelled out
  so they can't be confused with migration sections. Relative order is preserved within
  and across files. **`0014` §3 grants EXECUTE on functions `0015`/`0016` redefine** —
  safe because nothing in the pass uses `DROP FUNCTION` and `CREATE OR REPLACE` preserves
  the ACL.

  **Knock-on:** every downstream migration number shifted by two — and then Phase R
  landed in front of them and shifted them again. So this document **no longer pins
  migration numbers for unwritten work**; numbers get assigned when the file is written.
  They churn on every reshuffle and carry no information until the file exists.

- [x] **0.3 — Password recovery for registration-number accounts. DECIDED 2026-08-01,
  as part of `0.5`.** A **verified personal recovery email**, collected after a password
  signup and used for nothing but password reset. It lives only in `public.users`, never
  in `auth.users.email`, so it is a delivery address and not a way to sign in. Full
  reasoning and the field-by-field separation are in `0.5`; implementation is `R.5`.
  For anyone with no email channel at all, the faculty-rep path in `0.5` is the floor.

- [x] **0.4 — Update `TECHNICAL_DISCOVERY.md`. DONE 2026-08-01.** Rewritten from 130 to
  266 lines. Added: `0014`–`0016` in the §3 migration map (with the note that they are
  one pass split by theme, and why the grant ordering is safe), the enum-cast story,
  `user_can_see_event`, the guard triggers, the table-grant requirement, the
  `realtime.messages` policy, and the `broadcast_changes` → `realtime.send` rewrite.
  Corrected: the §8 function table, the §11 gap list, §4's cohort-name format
  (`BSC-CS 2023`, plus the fact it collides across paces), and `0004`'s
  "display metadata only" comment on `recurrence_rule`. Recorded: `0.1`'s recurrence
  decision in §4, `0.5`'s roster model in §10, and the promotion attestation's effect on
  §10's "verification affects no permissions" claim.

  **New §13 — "RLS, privileges and guard triggers".** All of `0014`'s content had no home
  in the old structure, and it is the part most likely to be got wrong: privileges and
  RLS are separate mechanisms and both are required, a policy cannot reference its own
  table, self-service UPDATE policies need column guards, and authority can be carried
  sideways through a join request.

  Sections 1–12 kept their existing numbers deliberately — migration comments cite
  `TECHNICAL_DISCOVERY §2 / §7 / §9 / §10` by number, so new material is appended rather
  than inserted. All eight migration→doc references verified to resolve.

  **Second pass after Phase R (same day), 265 → 300 lines.** §2's "identity is on the
  honour system" replaced with how it is now anchored; §3 gained `0017`–`0019`; §4 gained
  `student_roster`, `roster_audit_log` and `user_recovery_email`, and demoted
  `cohort_join_requests` to the exception path; §8's table gained the ten Phase R
  functions and lost `mark_email_verified` with a note on why it was dropped rather than
  hardened; **§10 rewritten end to end** — signup is now a claim, with the OAuth match
  rule, the accepted password-branch hole, takeover, and the
  `reg_number is not null` iff `claimed` invariant; §11 swapped the `mark_email_verified`
  and password-recovery gaps for `R.5`'s blocked delivery path; §12 and §13.1 gained the
  two regressions the suite caught this session (`CREATE OR REPLACE` discarding
  `proconfig`, and Supabase's default privileges re-granting `anon` on every new table).
  All 13 migration→doc references re-verified.

- [x] **0.5 — Roster-based identity and signup. DECIDED 2026-08-01.**
  Today `reg_number` is a client assertion: `handle_new_auth_user` copies
  `raw_user_meta_data ->> 'reg_number'` verbatim, the column is nullable, and nothing
  makes it unique — so anyone can sign up as anyone, and two accounts can hold the same
  registration number. The schema anchors *authority* in the real world (§2) but leaves
  *identity* on the honour system. This closes that by pre-declaring who exists:
  **signing up becomes claiming a known identity, not creating a new one.**
  Implementation is **Phase R**, which runs before Phase 1.

  **The roster**
  - Registration number + full name (first, middle optional, last). **No email column.**
  - **Write-mostly.** A student must never read it — it would be a directory of exactly
    the material needed to attack the claim flow.
  - **Bulk import is faculty-rep/superadmin only**, so the higher role *performs* it
    rather than reviewing it. Class reps get single-row adds for the long tail (a
    transfer arriving in week 3), scoped by the registration number itself:
    `EB1/67277/23` encodes programme and intake year, so a BSC-CS 2023 rep may write
    `EB1/*/23` and nothing else. This closes the cross-cohort hijack that "class reps can
    write" otherwise opens, and keeps the whole design free of approval queues.
  - `reg_number` **globally unique** — first-writer-wins, deterministic and detectable
    rather than silent.
  - **The row pins the cohort**, so a claim places the student automatically.
    `cohort_join_requests` survives, demoted to the exception path for students who
    deferred, transferred or repeated — DISCOVERY is explicit that the obvious cohort is
    not always the right one.
  - Unclaimed rows **never expire**. A claimed row **links** to the account rather than
    being consumed.

  **Signup**
  1. Student supplies registration number + full name.
  2. Roster match → proceed to credentials. No match → **one generic message**, never
     distinguishing "no such registration number" from "name does not match", and
     rate-limited. Anything else is an enumeration oracle over the roster.
  3. Credentials by university email (OAuth) or password.

  **The rule the whole design rests on:** on the OAuth branch, the address Google returns
  must parse to the registration number the student typed. Mismatch is refused. Without
  this check the roster is decorative — anyone could type someone else's registration
  number and then authenticate with their own Google account.

  **No school addresses are ever generated or stored.** The reg-number↔address pattern
  survives only as a transient matching key: parse the OAuth address, look up the roster,
  discard the derived string. Storing a derived address would set `email_verified_at` on
  a string match, faking the one signal §10 says is meaningful.

  **The password branch is unauthenticated, and that is accepted.** SMS OTP, rep-issued
  claim codes, and a private roster field such as date of birth were all considered and
  rejected — with no channel there is no proof, and cleverness does not manufacture one.
  The damage is bounded: a student account is read-only, so the harm is *denying someone
  their own account*, not a breach. The answer is **detect-and-recover, not prevent**.

  Whether a student has a mailbox is **inferred** from which button they press, not
  stored as a flag — the rep populating the roster does not know. Consequence, and it
  matters: the password branch is open to everyone, so **automatic OAuth takeover is
  load-bearing rather than a backstop.**

  **OAuth always wins.** Signing in with a university address whose registration number
  is bound to a provisional account **rebinds the roster row** to the OAuth account. The
  old account keeps its notifications, loses its cohort, and after `0014` can see
  nothing. Cheap precisely because students create nothing — two writes and an audit row,
  no data to migrate. Notify the evicted account.
  - **Never auto-evict an account holding `class_rep`** — that would strip scheduling
    authority mid-semester on a signup event. Escalate to the faculty rep.
  - Known wart: a legitimate student who reinstalls and signs in fresh with Google is
    indistinguishable from a takeover and loses notification history. Make in-app linking
    the prominent path while signed in so this stays rare.

  **Disputes are resolved by the faculty rep**, not the class rep — who is inside the
  cohort, and possibly the problem. Out-of-band, with a physical student-ID check, so
  there is nothing to build for intake. Resolution **unbinds rather than deletes**: it
  keeps the audit trail and sidesteps `2.3`'s `ON DELETE RESTRICT` chain entirely. Audit
  row mandatory — an unlogged manual override would be the most dangerous function in
  this schema. Watch the reverse abuse: someone claiming a *legitimately* held account is
  theirs, which is exactly why it is a physical check by a faculty rep.

  **No claims table.** Both branches bind inside a single transaction and the rep is out
  of the signup path, so no pending state exists anywhere to model. The binding is a
  *fact* on the roster row (`claimed_by`, `claimed_at`, `claim_method`); disputes and
  takeovers are *events* in an append-only `roster_audit_log` — the same idiom §4
  describes for `event_audit_log`.

  **Recovery email** (this is `0.3`). After a password signup the student is asked for a
  personal address, which is verified and used for nothing but password reset.
  - Lives only in `public.users`. **Never** `auth.users.email` — that is the login
    identity, and putting it there would make the personal address sign-in-able.
  - **Never feeds `email_verified_at`.** A verified personal mailbox proves the person
    controls that mailbox, not that they are who the roster says they are.
  - No uniqueness constraint, so a parent's or shared address works — which matters for
    exactly the first-years this branch exists to serve.
  - **Not required** to finish signup; some first-years have no email at all.
  - Changing it requires re-authentication and notifies the previous address.
    Self-readable only — class reps must not see it.

  **Three fields, three meanings, no overlap:**

  | Field | Meaning |
  |---|---|
  | `auth.users.email` | Login identity. Synthetic `@auth.internal` for password accounts, the real university address for OAuth accounts. |
  | `public.users.email` | The university address. **Identity.** Written only by OAuth, never derived. |
  | `public.users.recovery_email` | Delivery channel for password reset. No identity, no auth, no permissions. |

  **Promotion.** A hard "must be OAuth-verified to be promoted" rule would stop a
  first-year cohort ever having a rep, since nobody has a mailbox yet. Replaced with an
  attestation — see `1.4`.

  **Full name is not a second factor.** On the OAuth branch it is never checked; on the
  password branch a classmate knows it anyway. It is stored so a human can recognise the
  person during a dispute, and for display. Do not let the spec imply otherwise.

---

## Phase R — identity and the roster

Implements `0.5`. **Runs before Phase 1**, for two reasons: signup is the first screen a
user ever sees, so its API has to exist before the Flutter auth screens are written; and
`1.4`'s promotion attestation depends on verification state that does not exist until
this lands.

Lettered rather than numbered so inserting it does not renumber every item below — the
order is what matters, not the label.

Write it as **two migrations from the start** rather than one that gets split later. We
spent a session cutting `0014` apart; the lesson is to not create the second one. Same
shape as the split we landed on: structure first, behaviour second.

- [x] **R.1 — Configure Google OAuth. DONE 2026-08-01.** `[auth.external.google]` added
  to `config.toml`, `enabled = true`, credentials supplied via `env()` from
  `supabase/.env` (which is why `config.toml` stays committable). `.env.example`
  documents both variables and the exact redirect URIs.

  Verified end-to-end without a browser: `/auth/v1/authorize?provider=google` issues a
  302 to `accounts.google.com/o/oauth2/v2/auth` carrying the real client id,
  `redirect_uri = http://127.0.0.1:54321/auth/v1/callback`, `scope = email profile`,
  `response_type = code`. Suite still 114/114 with the provider live.

  **Added `supabase/.gitignore`** — there was none anywhere in the project, so the
  moment this becomes a git repo, `git add .` would have committed the client secret.
  Covers `.env`, `signing_keys.json` (which `config.toml` warns about) and
  `client_secret*.json`.

  Still unexercised: an actual browser sign-in with a real `@student.chuka.ac.ke`
  account. Worth deferring until `R.4` rewires `handle_new_auth_user` — signing in
  today would create a `public.users` row with a null `reg_number` via the old
  client-asserted path, which is the exact thing Phase R exists to remove.

  **Before launch:** an "External" consent screen starts in *Testing* mode — capped at
  100 test users and showing an unverified-app warning. Needs either Google's
  verification review or an Internal app created by a Chuka Workspace admin. Find out
  who administers the Workspace early.

- [x] **R.2 — Roster and identity structure. DONE 2026-08-01** —
  `0017_roster_and_identity.sql`, plus `tests/05_roster_test.sql` (27 assertions).
  Suite is 114/114.

  Two things came out differently from the spec, both for reasons worth keeping:

  1. **`recovery_email` is its own table (`user_recovery_email`), not a column on
     `users`.** `0014` §4 grants `select` on the *whole* `users` table to
     `authenticated` and `users_read_all` is `auth.uid() is not null` — so a column
     there would publish every student's personal address to the entire university.
     Column-level SELECT grants could fix it but are brittle: every future column has
     to remember to opt out. A separate table with a self-only policy enforces the same
     intent structurally. `0.5`'s actual rule is unchanged — it is not in `auth.users`,
     so it can never be signed in with, and it never feeds `email_verified_at`.
  2. **The programme prefix is resolved by lookup, not by regex.** Codes are not
     "letters then a digit" — `EB10`/`EB11`/`EB12` exist — and `EBS3` → `EB3` cannot be
     disambiguated structurally, since a future code like `CS1` would be mangled to
     `C1`. So `parse_reg_number()` tries the literal code first and the S-stripped
     candidate second. Verified against the real seed data.

  *Also caught:* Supabase's default privileges grant on newly created `public` tables
  to `anon` and `authenticated`, so all three new tables arrived with privileges nobody
  asked for — including `anon` on the roster. `0014` §4 cleared exactly this for the
  original fourteen tables; **every new table has to do it again.** The existing
  `00_access_control_test.sql` caught it immediately.

  <details><summary>original scope, for reference</summary>

  Tables, columns, policies, privileges. No behaviour.
  - `student_roster`: reg number (globally unique), first/middle/last name, cohort,
    `claimed_by` → `users(id)`, `claimed_at`, `claim_method`.
  - `claim_method` enum (`oauth` | `provisional`). A *new* enum is safe to create and use
    in one migration — the `0009`/`0011` restriction only applies to adding values to an
    existing type.
  - `roster_audit_log`, append-only: `claimed`, `takeover`, `unbound`,
    `dispute_resolved`, with actor, target and snapshot.
  - `users.recovery_email` + `recovery_email_verified_at`.
  - RLS: students cannot read the roster at all; reps read only their own scope;
    `recovery_email` is self-readable only.
  - Scoped roster CRUD: bulk import restricted to faculty rep / superadmin; class-rep
    single-row add constrained by parsed programme code + intake year.
  - **Pull `programmes.code`'s unique constraint forward from `2.1`** — reg-number
    parsing routes both claims and rep scoping through it, so it stops being cleanup and
    becomes load-bearing here.
  *Tests: rep cannot write outside their programme+year, class rep refused bulk import,
  student cannot read the roster, reg_number uniqueness, recovery_email invisible to a
  rep.*
  </details>

- [x] **R.3 — `notif_type` additions. DONE 2026-08-01** — `0018_identity_notif_types.sql`.
  Adds `account_taken_over` and `identity_unbound`, alone in its own file.

  <details><summary>original scope</summary>

  Takeover and dispute
  resolution need new notification types, and Postgres will not let
  `ALTER TYPE ... ADD VALUE` share a transaction with anything using it. This is exactly
  why `0009` and `0011` exist. Tiny file, and it **must** sit between `R.2` and `R.4` —
  easy to forget and annoying to discover mid-apply.
  </details>

- [x] **R.4 — Claim, takeover and dispute behaviour. DONE 2026-08-01** —
  `0019_claim_and_takeover.sql`, plus `tests/06_claim_and_takeover_test.sql`
  (30 assertions). Suite is **144/144 across 7 files**.

  Shipped: `reg_number_from_email()`, `claim_roster_row()` (with the
  OAuth-address-must-match-typed-number rule and automatic takeover),
  `resolve_roster_dispute()`, the `handle_new_auth_user` rewire, and
  `mark_email_verified` **dropped** per `1.5`.

  **Seed reworked.** Rewiring the trigger broke it — all 18 accounts got their
  `reg_number` from client metadata. `seed_user` now writes it directly as postgres
  (the Superadmin path, same as the existing cohort UPDATE), and a new §9.5 builds the
  roster *from* those accounts: 15 rows, 7 OAuth-claimed, 5 provisional, 3 unclaimed.
  §9.5 also nulls `reg_number` on anyone who did not claim, so the dataset now holds the
  post-Phase-R invariant: **`users.reg_number is not null` iff that account claimed a
  roster row.** Four accounts violated it before that fix.

  *Regression the suite caught:* `CREATE OR REPLACE` discards `proconfig`, so rewriting
  `handle_new_auth_user` silently stripped the `search_path` pinning `0008` added —
  reopening the exact SECURITY DEFINER escalation vector `0008` existed to close.
  `00_access_control_test.sql` failed on it. **Any `create or replace` of a pinned
  definer function must restate `set search_path`.**

  <details><summary>original scope</summary>
  - `claim_roster_row(...)` — roster match, then bind. Generic failure message on no
    match, identical for a bad reg number and a bad name.
  - **The OAuth-address-must-match-typed-reg-number check.** The single most important
    line in this phase; without it the roster is decorative.
  - Automatic takeover on OAuth binding over a provisional account, **with the
    `class_rep` exception** — escalate, never auto-evict.
  - `resolve_roster_dispute(...)` — faculty rep only, unbinds rather than deletes, audit
    row mandatory.
  - **Rewire `handle_new_auth_user`** so it stops trusting
    `raw_user_meta_data ->> 'reg_number'`. That trigger is the actual hole `0.5` closes,
    and leaving it in place would leave a second unguarded door into `users`.
  *Tests: OAuth address mismatching the typed reg number is refused, provisional bind
  works, takeover rebinds and leaves the old account inert, a `class_rep` account is not
  auto-evicted, dispute resolution unbinds, a non-faculty-rep is refused, and the
  no-match error is byte-identical to the name-mismatch error.*
  </details>

- [x] **R.5 — Recovery email flow. DONE 2026-08-24**, verified with a real send.
  Implements `0.3`, using Axene (`mail.axene.io`) as the mailer rather than waiting on
  `3.1`, since `3.1` (push) has no device-token table or Flutter client to build against
  yet and Axene needed no new infrastructure beyond the Edge Function itself.

  **`0031_recovery_email.sql`** — first writer for `user_recovery_email` (structure-only
  since `0017`). Three functions: `set_recovery_email` / `verify_recovery_email`
  (self-service, `SECURITY DEFINER`, `p_acting_user = auth.uid()` checked) and
  `request_password_recovery` (the unauthenticated lookup, `service_role`-only —
  never granted to `authenticated`). Setup verification is a 6-digit code from
  `extensions.gen_random_bytes`, not a GoTrue token — `generateLink` can't prove
  control of `recovery_email`, since 0.5 requires that address stay out of
  `auth.users` entirely. Reset still uses `generateLink({type:'recovery'})` against the
  account's *synthetic* `@auth.internal` address, verified working against the local
  admin API before any of this was written. Tests: `12_recovery_test.sql`, 21
  assertions — suite is 338/338 across 13 files.

  **One correction to the original plan, found writing the tests:** a wrong/expired
  setup code cannot both increment `otp_attempts` AND raise an exception in the same
  function call — Postgres rolls back everything since the call started, including the
  increment, the moment the exception fires. `verify_recovery_email` returns `boolean`
  instead; only the genuinely exceptional paths (wrong caller, no pending code,
  attempts already exhausted) still raise.

  **`functions/`** now exists — first non-SQL work in the repo.
  `functions/_shared/axene.ts` is one `sendEmail()` using plain `fetch` (Deno's is a
  web-standard global, so no SDK dependency for one endpoint); it logs to the console
  instead of sending when `AXENE_API_KEY` is unset, which is what local dev runs on.
  `functions/recovery-email-setup/` (authenticated, one endpoint with a `step` field
  for request/verify — calls the SQL functions through PostgREST with the *caller's own
  JWT*, not the service-role key, since `auth.uid()` only resolves with the right
  token). `functions/recovery-request/` (unauthenticated, service-role — the only
  caller `request_password_recovery` accepts).

  **Verified against `supabase functions serve` end to end, including a real send:**
  signed in as a seeded password-branch account, requested a setup code, read it
  straight from the table, verified it, hit the generic "forgot password" endpoint —
  correct response, and *identical* response for a real account, a nonexistent
  registration number, and a malformed body. The `generate_link` admin call inside
  `recovery-request` succeeded, and both the setup-code email and the actual
  password-reset link queued through Axene for real (`202`, a real `message_id`),
  through `recovery-email-setup` and `recovery-request` themselves — not just a bare
  `fetch` probe.

  **What looked like an Axene account bug (`0031`'s handoff note from 2026-08-23:
  `/validate` accepts a key that `/emails` 401s, reproduced with two separate keys) was
  a URL bug in this repo, not Axene's.** `POST https://mail.axene.io/v1/emails` — no
  trailing slash, what `axene.ts` originally called — 401s `not_authenticated`
  regardless of the key. `POST https://mail.axene.io/v1/emails/` — trailing slash — is
  the real collection endpoint and works. `/v1/emails/validate` never needed one
  because it's a sub-path, not the collection root, so it never surfaced the bug and
  masked it convincingly enough to look like an Axene-side inconsistency for a full
  session. Found by the user comparing against a request of theirs that actually
  worked — same host, same key, same body, only the trailing slash differed. Fixed in
  `functions/_shared/axene.ts`; the two-separate-keys "confirmation" in the earlier
  version of this note was real but pointed at the wrong layer, since neither key was
  ever the problem.

  `AXENE_SENDER_EMAIL` is the sandbox address Axene issues for free
  (`a7c2a815@test.axene.io` as of this session, from Workspace Setup > Step 1) — not an
  arbitrary address, since you can't send *from* a domain Axene hasn't verified for you.
  Sandbox mode only delivers to the workspace's own members, so **a verified real
  domain is still required before this can reach an actual student's mailbox** — that's
  the one remaining step, tracked separately, not blocking anything else in this repo.

---

## Phase 1 — close the API surface

**DONE 2026-08-20.** `0020`, `0021` and `0022_event_api.sql` are all applied; dedicated
coverage landed in `tests/07_phase1_test.sql` (62 assertions). **→ Full spec in
[`PHASE1_HANDOFF.md`](PHASE1_HANDOFF.md)** — signatures, section order, seed/test impact,
and the five traps this codebase has already sprung; kept for reference, since it is still
the most detailed record of *why* `0022` is shaped the way it is.

- [x] **Phase 1 enums** — `0020_phase1_enums.sql`. `audit_action += confirmed,
  unconfirmed`; `notif_type += attendance_confirmed, attendance_unconfirmed`. Isolated,
  per the `0009`/`0011`/`0018` rule.

- [x] **Terms and per-cohort course** — `0021_terms_and_per_cohort_course.sql`.
  `term_bounds(date, cohort_pace)`; `event_cohorts.course_id` added, backfilled, indexed
  (nullable for now); `events.course_id` deprecated and made nullable.

  **Terms are derived, not stored** — `cohorts` needs no date columns at all, which
  drops the backfill, the null-window problem and the rollover staleness that `0.1`
  originally planned around. **Pace matters:** trimester runs all three terms
  (Jan–Apr / May–Aug / Sep–Dec); **bimester runs only two** — Jan–Apr and Sep–Dec, with
  May–Aug as the long break. `term_bounds` returns `(null, null)` there rather than
  inventing a term, and `0022` turns that into a refusal to materialize a recurring
  series. It gates **recurrence only** — a one-off make-up class in the break is fine.

- [x] **`0022_event_api.sql`** — everything below, in one pass. See the handoff doc.

Everything here adds or changes a function signature. Done in one pass.

- [x] **1.1 — Attendance confirmation. Un-confirming IS allowed** (decided 2026-08-01,
  reversing the earlier lean). Shipped `confirm_attendance` *and* `unconfirm_attendance`,
  callable by the rep of **any attached cohort**, not just the initiator.
  *The headline feature, and it had no code path until now.*
  `attendance_status` used to be permanently stuck at `'pending'`: no function wrote it,
  and `events` has no client UPDATE policy or privilege. `confirm_attendance(p_event_id,
  p_acting_user)` — class rep of an attached cohort only, event must be `scheduled`,
  writes `attendance_confirmed_by/at`, audit row, and notifies the cohort.
  `unconfirm_attendance` reverses all three fields for a rep who mis-taps.
  *Tests (`07_phase1_test.sql` §7): state transition both directions, only-attached-rep
  (any of them, not just the initiator), refused on canceled/proposed, refused when
  already in that state, broadcast emits `attendance_confirmed`/`attendance_unconfirmed`
  (renamed from the borrowed `confirmation_needed`, which meant the opposite thing).*

- [x] **1.2 — Recurrence materialization.** Implements `0.1`. Shipped against a
  **derived** horizon rather than the originally planned `cohorts` date columns — see
  `0021`'s `term_bounds(date, cohort_pace)`, which reads pace-aware terms
  (trimester = 3, bimester = 2, no May–Aug) straight off the calendar instead of a
  backfilled column that could go stale on semester rollover. Concretely:
  - `create_event` materializes one row per occurrence from `p_start`, stepping by the
    `recurrence` enum, through `least(p_until, the initiating cohort's term end)`; all
    occurrences share a generated `recurrence_group_id`. Refused when the cohort has no
    term containing `p_start` (a bimester cohort in its May–Aug break — a one-off lecture
    there is still fine, `term_bounds` gates recurrence only), and when
    `p_recurrence <> 'none'` with more than one cohort attached.
  - All-or-nothing: one clashing occurrence aborts the series with an error naming the
    date, rather than a raw 23P01.
  - `cancel_recurrence_group(p_group_id, p_acting_user)` — initiating rep only,
    cancels moved occurrences too, since a rescheduled occurrence keeps its group id.
  *Tests (`07_phase1_test.sql` §1–§4): occurrence count matches the horizon exactly (an
  independent formula, not a restatement of the migration's own loop), `p_until` earlier
  respected and later clamped, refused for a bimester cohort in the break (and a one-off
  there still allowed), refused for a combined lecture, one clash aborts the whole series
  and the error names the date, cancelling a group reaches a rescheduled occurrence and
  leaves the retired original alone, authorization on both.*

- [x] **1.3 — Edit path.** Discovery says reps can "create, edit, reschedule, cancel".
  There was no way to change `lecturer_name`, `course_id` or `title` — and `create_event`
  hardcoded `title` to `null`, taking no title parameter at all. Shipped
  `update_event(...)` writing an `'updated'` audit row (the enum value existed already,
  previously only used by `leave_event_cohort`), plus a `p_title` parameter on
  `create_event`. `null` means leave a field unchanged; time/venue changes stay with
  `reschedule_event`.
  *Tests (`07_phase1_test.sql` §6): fields change, a partial edit leaves the rest alone,
  audit row written, non-initiator refused, a course from an unrelated programme refused
  on the edit path too.*

- [x] **1.4 — `promote_class_rep`.** The assistant rank was unreachable from inside the
  app. `create_cohort_with_class_rep` installs only the *first* rep and
  `demote_class_rep` only empties a slot, so appointing an assistant — or replacing a
  primary after demoting them — was impossible; `seed.sql` used to do it with a direct
  UPDATE as `postgres`, and now uses the real function (§9.6). Shipped
  `promote_class_rep(p_user_id, p_rank, p_acting_faculty_rep, p_identity_attested)` with
  the same faculty scoping as its siblings, target must be a `student` in that cohort.

  **Plus `0.5`'s attestation.** The faculty rep sees the name "Jane Doe" in a list and
  cannot tell the account behind it is Brian's. So: a target whose roster claim is not
  `oauth` requires the faculty rep to explicitly pass `p_identity_attested => true` —
  confirming they physically verified this person — recorded on the new `role_audit_log`
  alongside the claim method it overrode. Deliberately **not** a hard verified-only rule,
  which would stop a first-year cohort ever having a rep.
  *Tests (`07_phase1_test.sql` §8): promotion works with and without attestation
  (oauth-claimed vs. provisional), cross-faculty refused, third rep refused, rank
  uniqueness, unverified target refused without the attestation flag and left unmutated,
  attestation and claim method both land on the audit row.*

- [x] **1.5 — `mark_email_verified` validates the address. DISSOLVED by `0.5`.**
  The bug was that it accepted any string with no domain check and no proof of ownership,
  letting a student self-award the trust badge with a personal address. After `0.5` there
  is nothing left to validate: `email_verified_at` can only ever be written by the OAuth
  path, from an address the provider proved and the roster matched. There is no client
  assertion in the flow at all.
  **So delete the function rather than fix it** — as part of `R.4`, alongside the
  `handle_new_auth_user` rewire. Leaving a hardened version in place would preserve a
  second, weaker way to set the same field.

- [x] **1.6 — Scope who a rep may attach to a proposal. NOT DOING — decided 2026-08-01.**
  The vector is real: `'proposed'` reserves each attached cohort's slot via the
  `event_cohorts` EXCLUDE constraint, and `create_event` accepts any cohort ids
  university-wide, so a rep can blanket another cohort's calendar and block their
  scheduling until each proposal is declined individually.

  **The proposed fix was wrong.** Constraining to same-programme or same-faculty would
  break legitimate **cross-faculty combined lectures**, which are explicitly in scope —
  and it would not even fix the attack, since a rep could still blanket any cohort
  inside their own faculty. Trading a real feature for a partial mitigation.

  A volume cap was considered and deferred too: at MVP scale the reps are a small
  population each personally promoted by a faculty rep, and **the decline is the
  control**. Recorded as an accepted risk rather than deleted, so nobody mistakes it for
  an oversight. If it ever actually happens, **proposal expiry** is the better fix than a
  cap — a forgotten proposal shouldn't hold a room hostage either. That needs a scheduled
  job, so it belongs with `3.2`.

- [x] **1.7 — Cross-programme combined lecture course. DECIDED 2026-08-01, DONE
  2026-08-20: per-cohort course on `event_cohorts`.** Column added in `0021`; `0022`
  populates it, sets it `NOT NULL`, and drops `events.course_id`.

  `events.course_id` was a single FK into programme-scoped `courses`, so a combined
  lecture across two programmes had no course valid for both — the seed's cross-programme
  proposal borrows EB3's AI/ML unit for a BSC-CS cohort, and those students would see a
  unit from a programme they are not enrolled in. Each attachment now carries the unit
  from its **own** programme: same lecture, same room, same lecturer, correct unit name
  on every student's calendar. This became load-bearing rather than cosmetic once
  cross-faculty combined lectures were confirmed as in scope (see `1.6`).
  *Tests (`07_phase1_test.sql` §5): two cohorts on one combined lecture see two different
  `course_id`s, each matching its own programme; a course from an unrelated programme is
  refused on `create_event`.*

---

## Phase 2 — data integrity and retention (two migrations)

**DONE 2026-08-20.** **→ Full spec in [`PHASE2_HANDOFF.md`](PHASE2_HANDOFF.md)** — section
order, the five traps, seed/test impact, and the four places this list was found to be out
of date against the live schema. Coverage is `tests/08_phase2_test.sql` (32 assertions).

Two migrations, in order: **`0023_naming_and_role_audit.sql`** (behaviour — rewrite the
writers) then **`0024_integrity_and_retention.sql`** (structure — constraints, the
`ON DELETE` rework, the drops). Split that way from the start, per `0.2`'s lesson.

**The one thing that did not go to plan:** `cohorts.join_code` is `not null unique`, not
nullable as the handoff first assumed — so "stop writing it" was not a pure behaviour
change and `db reset` failed on the first attempt. `0023` gained a §0 that drops the
`NOT NULL` and nothing else, which is the same deprecate → stop-writing → drop sequence
`0021` §3 → `0022` §6 used for `events.course_id`. **A writer cannot stop writing a
`NOT NULL` column while it is still `NOT NULL`.**

A prerequisite step that is worth remembering: the cohort name was a lookup key in **116
literals** across `seed.sql` and six test files, so those were rekeyed onto
`(programme_code, intake_year)` **first**, with the suite verified green, before `0023`
changed the format. Two small diffs that each kept the suite passing, rather than one that
broke 116 call sites at once.

- [x] **2.1 — Missing unique constraints. DONE 2026-08-20** — `0024` §1. Four remain; all four apply against the
  current dataset with **zero violations**.
  - ~~`users.reg_number`~~ — **rehomed onto the roster by `0.5`/`R.2`**, which is where
    uniqueness now belongs. Still worth a matching constraint on `users.reg_number`
    itself so the two cannot drift. (Stays nullable — NULL is the correct state for an
    account that has not claimed.)
  - ~~`programmes.code`~~ — **pulled forward into `R.2`**, where reg-number parsing makes
    it load-bearing for both claim routing and rep scoping rather than cleanup.
  - `cohorts (programme_id, intake_year, pace)` — **three columns, not four.**
    `current_semester` was in this list and is wrong: it is mutable progression state
    (it sits in `0014`'s column-level UPDATE grant so a cohort *can* advance), so putting
    it in the identity key means advancing a cohort vacates its slot for a second one.
    `TECHNICAL_DISCOVERY` §4 already says programme+intake+**pace**; follow it.
  - `faculties.abbreviation`, `buildings.abbreviation` — used as display keys.

- [x] **2.2 — Cohort naming. DONE 2026-08-20** — `0023` §1. `create_cohort_with_class_rep` builds
  `abbreviation || ' ' || intake_year`, so two cohorts of the same programme and intake on
  different paces get *identical* names. **Add pace, not semester** — a name embedding
  `current_semester` goes stale the moment a cohort advances, the same staleness `0021`
  chose derived `term_bounds()` over stored dates to avoid.
  **This is the most expensive item in Phase 2 despite looking like the smallest:** the
  cohort name is used as a lookup key in **116 literals** across `seed.sql` and six of the
  eight test files. Rekey those helpers to `(programme_code, intake_year)` as a separate
  green-suite step *before* changing the format.

- [x] **2.3 — `ON DELETE` blocks account deletion. DONE 2026-08-20** — `0024` §3. **Five columns, not two:**
  `events.created_by`, `events.updated_by`, `event_audit_log.changed_by` (all `restrict`),
  plus `event_cohorts.decided_by` and `events.attendance_confirmed_by` (`no action`, which
  blocks identically). `users.id` cascades from `auth.users`, so the cascade hits these and
  **you can never delete an auth account that has scheduled anything.** Real operational
  landmine, and a GDPR-shaped problem if it ever matters.
  `events.attendance_confirmed_by` only became a blocker in `0022`, which made it writable
  for the first time.
  **Decided:** `set null` on all five, with a retained `changed_by_name` on
  `event_audit_log` filled by a `BEFORE INSERT` trigger — one trigger instead of editing
  the ten functions that write audit rows. `events.created_by` needs no name column; the
  `'created'` audit row already carries it. Same shape `role_audit_log` adopted in `0022`.

  `0.5` deliberately routes *around* this rather than through it — both takeover and
  dispute resolution unbind the roster row and leave the old account inert, so neither
  needs to delete anything. That keeps the audit trail and means this stays a real but
  non-blocking problem.

- [x] **2.4 — Notification index. DONE 2026-08-20** — `0024` §2. `notifications` has bare `(user_id)`; the hot queries
  are the list (newest first) and the unread badge. Wants both
  `(user_id, created_at desc)` and a partial `(user_id) where read_at is null`.

- [x] **2.5 — `events_current` view. DONE 2026-08-20** — `0024` §5. Filters `rescheduled` but not `canceled`.
  **Decided: finish the predicate, keep the view** — `status in ('scheduled','proposed')`.
  Dropping it was tempting (it has *zero readers* in the repo today) but it is the intended
  client convenience surface and Flutter has not been written yet, so define it properly
  before anything depends on it.

- [x] **2.6 — Audit `snapshot` contract. DONE 2026-08-20** — `0024` §6. Documented in `0004` as full event state at the
  time of the action; every writer passes a 2–3 key partial object.
  **Decided: fix the doc, not the code.** The full row is still on `events` to join to;
  copying it into every audit row is bloat that also goes stale against schema changes.

- [x] **2.7 — `demote_class_rep` writes `role_audit_log`. DONE 2026-08-20** — `0023` §4. *New — found 2026-08-20.*
  `0022` created that table with `role_action = {promoted, demoted}` and only ever wrote
  `promoted`, so `'demoted'` is unreachable and demotion — which strips a cohort's
  scheduling authority — still leaves no trace. That is the exact gap `0022`'s own header
  says the table exists to close. A Phase 1 loose end, cheap to close here.

- [x] **2.8 — Drop the dead columns. DONE 2026-08-20** — `0023` §0 deprecates, `0024` §4 drops. *New — found 2026-08-20.*
  - `events.recurrence_rule` — zero non-null rows, lost its parameter in `0022`, and only
    `reschedule_event` still copies it forward as null.
  - `cohorts.join_code` — permanently dormant, superseded by the roster (`0.5`), which the
    "explicitly not doing" list below already anticipated dropping here.

  Both have live writers (`reschedule_event`, `create_cohort_with_class_rep`, and
  `guard_cohorts_rep_update` names `join_code` as protected), which is exactly why the
  writers move in `0023` and the drops happen in `0024`.

---

## Phase S — streams

**DONE 2026-08-23** — `0025`–`0030`, with `09_streams_test.sql`,
`10_placement_test.sql` and `11_recurring_combined_test.sql`. `S.3` needed no code at all;
`S.6` was found while testing `S.5` and fixed in the same phase.

Lettered rather than numbered so inserting it did not renumber everything below — same
reason Phase R was.

**It ran before Phase 3** on the ordering principle at the top of this file: these were
API-surface changes (new `cohorts` columns, a new stream-creation function, a changed
`create_event` contract), Dart models are hand-written, and every signature change after
the Flutter client exists is manual sync work with no compiler catching the drift.

**What shipped:**

| item | migration |
|---|---|
| `S.1` streams as child cohorts, identity key made partial | `0025` |
| `S.2` `create_cohort_stream()`, `cohorts.name` derived by trigger | `0026` |
| `S.3` roster points at the student's real cohort | *no code — the roster layer already worked* |
| `S.5` `assign_students_to_streams()`, `cohort_unstreamed_members()` | `0027`, `0028` |
| `S.6` placement moves the roster row too | `0029` |
| `S.4` recurring combined lectures, series-level confirm/decline | `0030` |

**What a stream is, and what it is not.** A large intake is split into parallel lecture
groups — Stream A, Stream B — because one room cannot hold it. Confirmed 2026-08-20:
**the split is whole-timetable** (a student is in one stream for every unit, all
semester), **each stream elects its own class rep**, and **streams regularly come back
together for joint sessions**.

**Therefore a stream IS a cohort in this schema's terms.** Authority here is cohort-scoped
by construction (§2 — a rep's writ runs over exactly one cohort), so a group with its own
rep and its own complete timetable is already what `cohorts` models. No new authority
concept, no change to RLS, and no change to conflict detection: two streams are two
`cohort_id`s, so `event_cohorts_no_self_overlap` keeps working untouched.

**And a joint session is a combined lecture** — `create_event` with both stream ids,
proposal, both reps confirm. Already built and tested. Requiring the other stream's rep to
confirm is not friction to design around; it is the correct check, since they are the one
who knows whether their group is free.

**Explicitly NOT branching.** Branching changes a student's *pace* by quorum; a stream
splits a cohort that already shares one. See "Explicitly not doing" below.

- [x] **S.1 — Streams are CHILDREN of a cohort, not peers of one. DONE 2026-08-22** —
  `0025_cohort_streams.sql`. Every constraint below verified against the applied schema.
  **Rejected: widening the identity key to `(programme_id, intake_year, pace, stream)`.**
  That was the first sketch and it is wrong — it makes "one cohort per
  programme+intake+pace" stop being true, which is precisely the guarantee `0024` §1 was
  written to buy. Three rows would then compete for one cohort's identity.

  Streams are subordinate to a cohort, so say that structurally:

  ```sql
  alter table cohorts add column parent_cohort_id uuid references cohorts (id);
  alter table cohorts add column stream text;

  -- 0024's guarantee, unchanged in meaning, scoped to actual cohorts
  alter table cohorts drop constraint cohorts_identity_unique;
  create unique index cohorts_identity_unique
    on cohorts (programme_id, intake_year, pace)
    where parent_cohort_id is null;

  -- ...and one cohort cannot have two Stream A's
  create unique index cohorts_stream_unique
    on cohorts (parent_cohort_id, stream)
    where parent_cohort_id is not null;

  -- a stream names itself; a top-level cohort does not
  alter table cohorts add constraint cohorts_stream_shape check (
    (parent_cohort_id is null     and stream is null)
    or (parent_cohort_id is not null and stream is not null)
  );
  ```

  Partial unique **indexes**, not constraints — Postgres will not take a `WHERE` on a
  UNIQUE constraint. The schema already uses this shape for
  `users_one_primary_per_cohort`.

  **Why this beats the widened key:**
  - `(programme, intake, pace)` stays unique for anything that is actually a cohort.
  - **Unstreamed cohorts are entirely unaffected** — both columns null, behaviour
    identical to today. Most cohorts never stream, so the common case pays nothing.
  - It makes the roster layer work **unchanged** (`S.3`): because a stream inherits its
    parent's `programme_id` and `intake_year`, every check in `roster_assert_may_write`
    passes for a stream id, so `roster_add_student` and `roster_bulk_import` need no edit
    and a stream's class rep is scoped to exactly their own stream.
  - `coalesce(parent_cohort_id, id)` answers "which cohort is this really?" in one
    expression.

  **A stream MUST inherit its parent's programme, intake and pace. DECIDED 2026-08-20:
  enforce it with a composite FK, not a trigger and not trust.**

  `programme_id`, `intake_year` and `pace` are all `NOT NULL`, so a stream row is forced
  to carry copies of them — and nothing above stops a "stream" of a *bimester* cohort
  declaring itself *trimester*. Nonsense, and it would silently corrupt every pace-derived
  thing downstream, starting with `term_bounds()` and therefore recurrence.

  ```sql
  alter table cohorts add constraint cohorts_id_identity_unique
    unique (id, programme_id, intake_year, pace);

  alter table cohorts add constraint cohorts_stream_inherits
    foreign key  (parent_cohort_id, programme_id, intake_year, pace)
    references cohorts (id, programme_id, intake_year, pace) on delete restrict;
  ```

  Read the second as: **a child's four values must match some parent's four values.**
  Rejected alternatives: a trigger (procedural, disableable, one more thing to remember)
  and trusting `S.2`'s creation function (a direct INSERT as `postgres` walks straight
  past it — which is exactly how `seed.sql` writes rows).

  **Why the NULL case works without any special handling:** the FK is `MATCH SIMPLE`, the
  default, under which a row with *any* NULL among its referencing columns satisfies the
  constraint automatically. A top-level cohort has `parent_cohort_id is null`, so the FK
  never applies to it. Streams have all four non-null, so it always does. No partial
  constraint needed.

  **Verified against the live schema 2026-08-20** (in a rolled-back transaction):
  - a stream whose pace differs from its parent → rejected by `cohorts_stream_inherits`
  - a second top-level cohort with the same identity → still rejected by
    `cohorts_identity_unique`, i.e. `0024`'s guarantee survives intact
  - **changing a parent's pace while it has streams → rejected.** Unplanned bonus, and it
    closes the worst form of the naming defect in `S.2` / `PHASE2_HANDOFF` risk 2: a rep
    can no longer flip pace out from under a streamed cohort. `S.2` still has to handle
    the unstreamed case, and still owes a readable error instead of this raw FK message.

  **STREAMS ARE THE LOWEST LEVEL. The hierarchy is exactly two deep, never three.**
  A stream of a stream is nonsense, and the composite FK above does *not* stop it — a
  stream row is itself a valid FK target, so it happily becomes a parent. Verified as
  reachable 2026-08-20 before the guard below was added.

  A `CHECK` cannot express it either; it would need a subquery. It *can* be forced
  declaratively — add an `is_stream` flag, a second flag column pinned to `false` by a
  `CHECK`, and `unique (id, is_stream)` so the FK can demand a non-stream parent — but
  that is three pieces of scaffolding to replace ten lines of plpgsql, and obscure enough
  that someone would break it by accident. **Rejected on legibility.**

  **A guard trigger, which is idiomatic here** — `enforce_max_class_reps` solves a
  structurally identical problem (a rule that has to look at other rows), and
  `TECHNICAL_DISCOVERY` §13 documents guard triggers as a first-class mechanism. It also
  gives a readable error, which an FK violation cannot.

  ```sql
  create function enforce_cohort_stream_depth()
  returns trigger language plpgsql set search_path = public as $$
  begin
    if NEW.parent_cohort_id is not null and exists (
         select 1 from cohorts c
         where c.id = NEW.parent_cohort_id and c.parent_cohort_id is not null) then
      raise exception
        'Cohort % is itself a stream — streams are the lowest level and cannot be subdivided',
        NEW.parent_cohort_id;
    end if;
    return NEW;
  end $$;

  create trigger enforce_cohort_stream_depth_trigger
    before insert or update on cohorts
    for each row execute function enforce_cohort_stream_depth();
  ```

  **Verified 2026-08-20:** a stream of a real cohort inserts; a stream of a stream raises
  the message above. Remember `revoke execute ... from public, anon, authenticated,
  service_role` — trigger functions need no EXECUTE grant, and `set search_path = public`
  is mandatory per the `proconfig` trap.

  **Accepted cost:** any query wanting a whole cohort *including* its streams needs
  `where id = X or parent_cohort_id = X`. Two levels means that never has to recurse.

  **Other accepted cost:** any query wanting a whole cohort *including* its streams needs
  `where id = X or parent_cohort_id = X`.

- [x] **S.2 — creating a stream, and naming it. DONE 2026-08-22** —
  `0026_stream_creation_and_naming.sql`.
  The generated name carries the stream (`BSC-CS 2023 (bimester) Stream A`), on the same
  reasoning as `0023` §1: a name must render the whole identity key or it cannot tell two
  legitimate rows apart. Unstreamed cohorts keep today's name exactly.

  **A stream needs its own creation function rather than an extra parameter on
  `create_cohort_with_class_rep`,** for two reasons that both come from `S.5`(c):
  - It **inherits** `programme_id`, `intake_year` and `pace` from the parent instead of
    taking them again, so a caller cannot produce a stream that disagrees with its parent
    — the same guarantee `S.1`'s composite FK enforces, made unreachable rather than
    merely rejected.
  - It **must accept an existing `class_rep` as the stream's first rep.**
    `create_cohort_with_class_rep` refuses anyone who is not a plain `student` (`0016`),
    and splitting a cohort moves its sitting rep into one of the streams. Demote-then-
    promote would cost two misleading audit rows and a window with no scheduling
    authority.

  **Also fix the naming defect `0023` introduced** — see `PHASE2_HANDOFF.md` accepted
  risk 2, where it is demonstrated. `0014` grants `authenticated` UPDATE on
  `cohorts (current_semester, pace, name)`, and `0023` put `pace` into a name generated
  **once, at creation**. So a rep can flip their cohort's pace and leave the name saying
  `(bimester)` while `pace = 'trimester'` — the name silently contradicts the row. It is
  fixed here rather than in a standalone `0025` only because Phase S rewrites this exact
  expression anyway; doing it twice in consecutive migrations would buy nothing.
  1. Make `name` **trigger-maintained** from `(programme, intake, pace, stream)` so it
     recomputes whenever any component changes. Drift becomes impossible rather than
     discouraged.
  2. Drop `name` from the column-level UPDATE grant and add it to
     `guard_cohorts_rep_update`'s protected list. It was editable because auto-generated
     names used to be ambiguous; `0023` removed that reason, so the grant is vestigial.
  3. Raise a sentence, not a raw `23505`, when a pace change collides with an existing
     twin on `cohorts_identity_unique`.

- [x] **S.3 — How a student lands in the right stream. DECIDED 2026-08-20, after
  reversing an earlier call: the roster points at THE COHORT THE STUDENT IS IN. If that
  is a stream, it points at the stream. There is no special rule.**

  **The earlier decision was that the roster must always point at the unstreamed parent.
  It was wrong, and the reasoning behind it was wrong too.** That reasoning said the
  roster records identity while `users.cohort_id` records placement — but `0.5` states
  plainly that *"the row pins the cohort, so a claim places the student automatically."*
  `student_roster.cohort_id` was **always** a placement mechanism; identity is
  `reg_number` + name. There was no principle being protected, only a permanent exception
  invented to cover a transitional problem.

  **Three mechanical facts settle it, all verified against the live schema:**

  1. **Both roster writers already take an explicit `p_cohort_id`** —
     `roster_add_student(reg, first, last, middle, p_cohort_id, actor)` and
     `roster_bulk_import(rows, p_cohort_id, actor)`. A human already names the cohort; the
     registration number only *scopes* what they may write.
  2. **The registration number cannot express pace either, and that ambiguity is already
     resolved exactly this way.** `EB1/67277/23` yields programme + intake year only, so
     `BSC-CS 2023 (bimester)` and `BSC-CS 2023 (trimester)` are both valid targets and the
     importer picks. Streams are the same problem with the same existing answer.
  3. **Every check in `roster_assert_may_write` passes for a stream id**, because `S.1`'s
     composite FK forces a stream to inherit `programme_id` and `intake_year`: the
     programme check passes, the intake-year check passes, the faculty check resolves
     through the inherited programme, and the class-rep check
     (`users.cohort_id = p_cohort_id`) puts a Stream A rep in charge of exactly Stream A.

  **So this option needs NO change to the roster layer at all.**

  **What killed the parent-pointing version:** under it, a stream's class rep has
  `users.cohort_id = Stream A` while roster rows point at the parent, so
  `roster_assert_may_write` raises *"A class_rep may only add students to their own
  cohort"*. **Stream class reps could not write roster rows at all** — only faculty reps
  could. That destroys the single-row add path `0.5` built specifically for the long tail
  ("a transfer arriving in week 3"), and it is backwards: the stream rep is the person who
  actually knows the new student.

  **Everything else falls out for free.** Before a cohort is split, the roster points at
  the cohort — correct, because the student really is unstreamed then. After the split it
  points at their stream — also correct. `claim_roster_row` places them right the first
  time with no follow-up action, and **the takeover wart disappears entirely**: a takeover
  re-reads the roster, the roster names the stream, so the new account lands in the
  stream rather than being bumped somewhere with an empty timetable.

  The one thing this needs is a way to move roster rows when a cohort is split — see
  `S.5`. That is a single bulk operation per split, not a rolling manual task forever.

- [x] **S.6 — placement paths leave the roster row behind. DONE 2026-08-23** —
  `0029_roster_placement_sync.sql`, tests in `10_placement_test.sql`. Shipped as a shared
  internal `sync_roster_placement()` called by both paths, plus
  `roster_placement_divergences()` for the residue it cannot legally fix.
  *(analysis below)*

  **Two functions, not one.** An inventory of everything that writes placement
  (`update users … set … cohort_id` vs `update student_roster … set … cohort_id`) gives
  six functions, and exactly two move the account without moving the roster row:

  | function | moves `users.cohort_id` | moves roster row |
  |---|---|---|
  | `create_cohort_with_class_rep` | yes | **no** |
  | `approve_cohort_join_request`  | yes | **no** |
  | `create_cohort_stream`         | yes | yes (`0028`) |
  | `assign_students_to_streams`   | yes | yes (`0028`) |

  `approve_cohort_join_request` matters *more*, not less: `0.5` keeps
  `cohort_join_requests` alive precisely as the exception path for students who deferred,
  transferred or repeated — which is exactly when a roster row goes stale.

  **Why it is a bug and not just an inconsistency.** `claim_roster_row` sets
  `users.cohort_id = v_row.cohort_id` **unconditionally** — its own comment says *"The
  roster is authoritative for the official name and the cohort."* So a student placed by
  either function above, who later signs in with a university address and triggers a
  takeover, is **silently dropped back into whatever cohort their stale roster row
  names**. That is the takeover misplacement `S.3` chose its design to eliminate,
  re-entering through a different door. Demonstrated: after
  `create_cohort_with_class_rep` places a student in `BSC-CS 2023 (trimester)`, their
  roster row still reads `BSC-CS 2023 (bimester)`, and a claim would reset the account to
  the latter.

  **THE FIX MUST BE CONDITIONAL — do not copy `0028` verbatim.** `roster_assert_may_write`
  requires the registration number's programme and intake year to match the cohort it is
  filed under. So an unconditional move can create roster state the roster API itself
  forbids. Verified: an `EB1` student can legally be made first rep of a `BA2` cohort
  (`0016` **deliberately** does not check reg-number/programme agreement — *"the Faculty
  Rep is promoting someone whose election they personally witnessed"*), and
  `roster_add_student` then refuses that exact combination outright.

  `0028` could be unconditional only because a stream inherits its parent's programme and
  intake **by construction**, so the match is guaranteed. Neither function here has that
  guarantee.

  So: **move the roster row only where it stays valid** (reg-number programme and intake
  match the new cohort — the ordinary case of a student becoming rep of a cohort in their
  own programme), write a `'reassigned'` audit row (the enum already exists from `0027`),
  and where it does not match, leave it and surface the mismatch. A genuine cross-programme
  placement is join-request or dispute territory, not something a cohort-creation function
  should paper over.

  **`seed.sql` will hide this.** §9 creates all four cohorts through
  `create_cohort_with_class_rep` and §9.5 then builds the roster *from* `users`, so the dev
  dataset is self-consistent by construction and the divergence is invisible in it. A test
  must **create the divergence explicitly** — place someone via the function, then assert
  on their roster row. A test that only checks post-reset consistency passes whether or not
  the bug exists.

  Fold into whichever migration next touches these functions rather than a standalone one,
  the same reasoning that put the naming fix in `S.2`.

- [x] **S.4 — Recurring combined lectures. DONE 2026-08-23** —
  `0030_recurring_combined_lectures.sql`, tests in `11_recurring_combined_test.sql`.
  Clash semantics: **all-or-nothing, naming every offending date** (option (a)). The
  horizon now takes the EARLIEST term end across all attached cohorts, so a trimester
  initiator cannot drag a bimester partner into their May–Aug break.
  *(analysis below)*

  Originally noted as "not really about streams" — it would be needed if streams never
  shipped. **That understates it, in the direction that matters.** Once a cohort is
  streamed, *every* joint session is a combined lecture between Stream A and Stream B, and
  a unit taught jointly all term is precisely the recurring-combined case. And joint
  sessions happen **regularly** (`S.3`). So `S.4` stops being a nicety for cross-programme
  teaching and becomes **routine infrastructure for any streamed cohort** — without it, a
  rep of a streamed cohort hand-creates every week of every joint unit.

  This is also why `S.5` can refuse to migrate events (see `S.5`(b)): post-split, whether
  a lecture is joint or per-stream is a per-lecture human judgement, and `S.4` is what
  makes expressing the joint ones cheap.

  **But streams do NOT hard-block on `S.4`, and the phase can ship without it.** A
  **one-off** combined lecture has worked since `0010` — `create_event` with two
  attachments and `p_recurrence => 'none'` goes to `'proposed'`, the partner rep confirms,
  and it schedules. The `p_recurrence <> 'none'` guard is the *only* thing that refuses.
  Two streams are just two cohorts, and the schema does not care that they share a parent,
  so a Stream A + Stream B joint session works the moment `S.1`/`S.2` land, with no new
  code at all.

  So `S.1`/`S.2`/`S.3`/`S.5` are shippable on their own and give working streams. The cost
  of deferring `S.4` is that a rep hand-creates every week of a jointly-taught unit —
  roughly fifteen rows per unit per term. Tedious, and it gets worse the more units are
  taught jointly, but it is a quality-of-life problem rather than a blocker. **Sequence
  `S.4` on how much joint teaching a streamed cohort actually has**, not on whether
  streams can function.

  **This is a gap to close, not a redesign.** A combined lecture already works; a
  recurring series already works; the two just cannot be combined, because `0022` §1
  guards against it. Everything else is built — the materialization loop, the term-end
  horizon, `p_until`, the shared `recurrence_group_id`, and `cancel_recurrence_group`.

  It matters because term-long combined teaching is ordinary here: a lecturer took Applied
  CS together with Computer Science for a *whole semester*, and again in another unit.
  Others join for occasional one-offs, which already work. Today the rep must hand-create
  fifteen occurrences for the first case.

  **The fix is series-level confirmation, not relaxing the guard.** The guard's real
  concern was reconfirmation churn — fifteen proposals landing on a partner rep for one
  scheduling decision. Confirm the `recurrence_group_id` once instead:
  `confirm_recurrence_group(p_group_id, p_acting_user)` and its decline counterpart,
  mirroring `cancel_recurrence_group` which `0022` already built and which already proves
  the "act on a whole series" shape works.

  **The hard part is clash semantics, and it needs deciding before anything is written.**
  `create_event` is all-or-nothing on a conflict, which is right for a solo series. For a
  term-long *combined* series it is much harsher: the occurrences must clear every
  attached cohort's calendar for every week, so a single clash in week 7 kills the whole
  term. Options are (a) keep all-or-nothing and make the error name every clashing date,
  not just the first, so the rep can fix them in one pass; (b) allow the series to be
  created with the clashing occurrences skipped and reported; or (c) create them anyway as
  proposals and let the partner rep decline individual weeks. **(a) is the smallest change
  and keeps one rule; (b) needs a savepoint per occurrence, which `0.1` priced and
  rejected once already.**

- [x] **S.5 — splitting a cohort. DONE 2026-08-23** — `0027_roster_reassigned_action.sql`
  (isolated enum) and `0028_stream_assignment.sql`. Shipped as **two** functions rather
  than one `split_cohort_into_streams`, because decision (a) made splits incremental:
  `create_cohort_stream` creates and `assign_students_to_streams` populates, callable
  repeatedly as lists arrive. Plus `cohort_unstreamed_members` for the visibility half.
  *(original scope below)* Surfaced by `S.3`: **there is no function today that moves a roster row
  between cohorts.** `roster_correct_student` does not take a `cohort_id` at all — it only
  fixes names and registration numbers — and it refuses claimed rows outright, on the
  grounds that touching a claimed identity is a dispute rather than a correction. So
  splitting a cohort is currently not expressible by any existing API.

  Note this gap existed under *both* candidate designs in `S.3`; choosing the roster to
  point at the student's real cohort did not create it, it only made it visible.

  **What it has to do, atomically:**
  0. **Refuse if the cohort has upcoming lectures** — see (b). This is the precondition
     that keeps the rest of the function small.
  1. Create the stream cohorts as children of the cohort being split (`S.1`/`S.2`), each
     with its own class rep.
  2. Move each named student's `users.cohort_id` to their assigned stream.
  3. Move their `student_roster.cohort_id` to match, **including claimed rows** — which is
     exactly what `roster_correct_student` refuses, so this needs its own carefully scoped
     path rather than a relaxation of that guard.
  4. Write a `roster_audit_log` row per student. A bulk re-pointing of claimed identities
     is precisely the class of action `0.5` says must never be unlogged.

  **It does NOT touch `events` at all** — that is the whole point of step 0, and it is
  what keeps this a tractable first implementation rather than a migration engine.

  **Faculty rep only, own faculty.** A class rep must not be able to re-point roster rows
  in bulk — that is the same reasoning that made `roster_bulk_import` faculty-rep-only in
  `0.5`, so that the higher role *performs* the operation rather than reviewing it
  afterwards.

  **Input shape:** `jsonb`, `[{"reg_number": "...", "stream": "A"}, ...]`, matching
  `roster_bulk_import`'s existing convention and `create_event`'s `p_attachments`. Keying
  on registration number rather than user id matters — the department's own stream lists
  are keyed that way, and it lets the function place students who have not signed up yet.

  **The three open questions, resolved 2026-08-22.**

  **(a) Splits are INCREMENTAL, not exhaustive.** The argument that settles it:
  **"the parent has no students" can never be a durable invariant.** A student claiming a
  roster row that still points at the parent lands in the parent, and a faculty rep can
  write new roster rows against it at any time. So "exhaustive" could only ever mean
  "exhaustive at the instant the function ran", which is not worth encoding as a rule —
  and enforcing it blocks a rep whose department sends stream lists in pieces, who will
  then do it out-of-band instead.

  **Surface incompleteness instead of forbidding it:** return the number of cohort members
  left unstreamed, and provide a way to ask *"who in this cohort is not in a stream?"*.
  The failure being guarded against — a student stranded in the parent seeing an empty
  timetable — is a visibility problem, so visibility is the fix, not a constraint.

  **(b) Existing events are NOT migrated. The split REFUSES while the cohort has upcoming
  lectures.**

  Migrating them was the plan for a day, in two forms, and both are wrong:

  - **Re-attaching one event to both streams is actively dangerous, not merely
    unnecessary.** Streams exist *because one room cannot hold the intake*. After a split,
    Stream A's and Stream B's lectures are different events — different rooms, usually
    different times. Attaching one event to both puts both groups in one room at one hour,
    which is exactly what the split existed to prevent.
    **And neither EXCLUDE constraint catches it.** `events_no_venue_overlap` is on
    `events(venue_id, tstzrange)` — a single row has nothing to self-overlap.
    `event_cohorts_no_self_overlap` is on `event_cohorts(cohort_id, tstzrange)` — the two
    streams are different `cohort_id`s, so they do not conflict. The schema accepts it
    silently, because "two cohorts, one room, one time" is exactly what a legitimate
    combined lecture looks like. It just is not legitimate when the two cohorts exist
    *because* the room cannot hold them both. The error surfaces as an overfull lecture
    hall weeks later.
  - **Moving them to one stream is arbitrary**, and cancel-and-recreate discards audit
    continuity and a term of the rep's work.

  There is also no bulk answer available even in principle: streams come back together for
  joint sessions **regularly** (`S.4`), so after a split some lectures stay whole-cohort
  and some divide — a per-lecture judgement about room capacity and unit that no bulk
  function can make.

  **So make the assumption a precondition rather than a note.** `split_cohort_into_streams`
  refuses when the cohort has live upcoming lectures:

  ```sql
  where status in ('scheduled', 'proposed') and start_time > now()
  ```

  **Only FUTURE events block.** Past lectures legitimately belong to the parent — the whole
  cohort really did attend them, and that is the historically accurate record. A
  mid-semester split stays possible as long as the rep has not entered the rest of the
  term yet.

  **Put the escape hatch in the error message**, where it cannot rot the way a comment
  can: *"Cohort X has N upcoming lectures. Split it before its schedule is entered, or
  cancel those lectures first."*

  **Why refusing is the safe direction:** a refusal degrades to manual work — cancel,
  split, re-enter per stream — which is annoying, recoverable, and fully expressible with
  today's API. Building migration on guesses degrades to *subtly wrong data*: a mis-picked
  `is_initiator`, a missing `event_status_cache`, two streams silently booked into one
  room. Those surface weeks later and cost far more than a refusal on day one. If the
  precondition turns out to fire often, that will be learned from a real error with a real
  cohort attached — better evidence than anything guessable now.

  **(c) The parent's class rep MOVES to a stream; the parent ends up with none.** A rep is
  just a user whose `cohort_id` names the cohort, so this resolves itself. A rep-less
  cohort is legal — `demote_class_rep` can already empty a slot, so *"a cohort with no rep
  has no real-world meaning"* is a rule about **creation**, not a standing invariant.

  **But `create_cohort_with_class_rep` refuses a non-student first rep** (`0016`: *"only a
  student can be promoted to a new cohort's first class rep"*), and the parent's rep is
  already a `class_rep`. So `S.2`'s stream-creation function must **explicitly accept an
  existing `class_rep` and move them**. The alternative — demote then promote — costs two
  misleading audit rows and a window where the cohort has no scheduling authority. The
  plain-student rule exists to stop a `faculty_rep` being demoted into a rep and to stop
  silent rank changes; neither applies here.

  **Consequence for the client, and it will bite as confusion rather than as an error:**
  after a complete split the parent is a phantom — no students, no rep, no events, and
  under `S.3` nothing in the roster pointing at it either. Its only remaining job is
  holding the `(programme, intake, pace)` identity slot and being the FK target that binds
  the streams. Legitimate, but **every cohort list shown to a human must exclude parents
  that have streams**:

  ```sql
  where not exists (select 1 from cohorts c2 where c2.parent_cohort_id = cohorts.id)
  ```

  **The question this used to hang on is now closed by decision rather than discovery.**
  It was: *when a cohort is split, has its rep already created events for that term?*
  (Not "does a timetable exist" — the department's always does. There is no import or
  publish step here; a rep enters lectures one at a time through `create_event`, so a
  cohort's schedule accumulates gradually.)

  Rather than guess the answer, **(b) makes the favourable case a requirement**: split
  early, before the schedule is entered. If that turns out to clash with how the
  department actually works, the precondition will say so out loud, with a real cohort and
  a real count attached — which is far better evidence than a guess made now.

---

## Phase 3 — infrastructure and Edge Functions

`supabase/functions/` exists as of `R.5` (`0031`) — `_shared/` is reusable scaffolding
for whatever lands here next.

**Order: `3.5`, then `3.2`, then `3.1` — not the numeric order.** Same reasoning as
`R.5`: build what's testable today first. `3.5` is pure SQL/script, no external
dependency. `3.2` writes `notifications` rows, a DB-observable outcome the pgTAP suite
can assert on directly, with no third-party credentials needed. `3.1` needs a Firebase
project and has no device to receive a push at all — no Flutter client exists yet — so
it can be built but not verified. Doing `3.1` first would mean writing a dispatcher for
notifications `3.2` isn't generating yet.

**`3.5`, `3.2`, and `3.1` are all done. Phase 3 is closed.**

- [x] **3.1 — Push delivery (FCM). DONE 2026-08-24** — `0034_push_delivery.sql`,
  `functions/dispatch-push` + `functions/_shared/fcm.ts`, tests in
  `15_push_delivery_test.sql` (15 assertions).

  **Cron poll, not an on-insert DB webhook.** `notify_cohort_members` (`0012`) inserts one
  `notifications` row per matching user, called from a dozen different mutation
  functions — so the Postgres-side trigger has to originate in Postgres either way, and a
  webhook turns `0033`'s own accepted multi-tier burst (~20 rows in one transaction) into
  ~20 separate Edge Function invocations. `pg_cron` every minute (`invoke_push_dispatch()`)
  batches all of them into one `functions/dispatch-push` call instead. This is **not** a
  reversal of `0031`'s decision to skip `pg_net` for `request_password_recovery` — that
  call site already had a client-invoked Edge Function in the request path with nowhere
  else for the HTTP call to live; this one doesn't, so it's a structurally different call
  site, not "reaching for `pg_net` again for one more thing."

  **Split the same way `0033` did.** `claim_pending_pushes()` (which notifications are due,
  claim + stamp them) is a plain SQL function, pgTAP-testable exactly like
  `send_confirmation_nudges()`. The actual FCM call is untestable here — no Flutter client
  exists to hold a real device token — and lives entirely in `functions/dispatch-push` /
  `_shared/fcm.ts`. `cron.schedule` is the one-line, untestable trigger connecting them.

  **`notifications.pushed_at`, not a ledger table.** Unlike `0033`'s five tiers (which
  need to be told apart), a push is 1:1 with the notification it came from, so one column
  is the whole idempotency mechanism. It's stamped the moment a row is claimed — even for
  a user with zero registered devices — so a device-less user's notifications don't get
  reselected and re-joined against `device_tokens` on every single run forever.

  **`device_tokens.token` is the primary key, not `(user_id, token)`.** A resold or
  handed-down phone gives a *different* user the *same* FCM registration token.
  `register_device_token()` deletes any other user's claim on a token before claiming it
  for the caller — a reassignment that crosses row ownership, which RLS can't express, so
  (same discipline `0006` states for `event_cohorts`) `device_tokens` takes no direct
  client insert/update/delete privilege at all; the function is the only writer.

  **Stale-token cleanup is exactly FCM's `UNREGISTERED` error, nothing more** — `_shared/
  fcm.ts` returns a typed result per send, and `dispatch-push` only `DELETE`s the
  `device_tokens` row on that one specific case. Every other failure (bad payload, quota,
  transient 5xx) is logged and left alone, no retry/backoff system, per this item's
  original scope note.

  **Vault holds the URL/key pair `invoke_push_dispatch()` needs to call
  `dispatch-push`**, not a hardcoded value in the migration — `seed.sql` §12.5 seeds both
  with fixed, public local-dev values (the Docker-network `kong` hostname and the demo
  `service_role` key baked into every `supabase init` project) for local dev only. A
  hosted deployment sets its own pair once via `vault.create_secret`, pointing at its real
  functions URL and `service_role` key (comment in `seed.sql` §12.5 has the exact calls).
  Left unset, both `invoke_push_dispatch()` and `_shared/fcm.ts` no-op instead of erroring
  — the same swap-for-free discipline as `_shared/axene.ts`.

  **Verified: the full local pipeline runs end-to-end, including a live FCM call.**
  `pg_cron` → `invoke_push_dispatch()` → `net.http_post` → `functions/dispatch-push` →
  `claim_pending_pushes()` all confirmed via `net._http_response` returning `200` through
  every hop. With a real Firebase service-account key configured
  (`FCM_SERVICE_ACCOUNT`, base64 in `supabase/.env`, gitignored — **not**
  `google-services.json`, which is the Android client config and carries no private key),
  a manual send against a fabricated token exercised `_shared/fcm.ts`'s entire
  crypto/OAuth path live: PEM parsing, RS256 JWT signing, the token exchange against
  `oauth2.googleapis.com`, and an authenticated `messages:send` call to
  `fcm.googleapis.com` — which correctly came back `400 INVALID_ARGUMENT`, correctly
  classified as *not* `UNREGISTERED`, correctly leaving `device_tokens` untouched. **The
  one thing still unverified: a real registration token, which needs the Flutter client.**
  See `TECHNICAL_DISCOVERY.md` §11.

- [x] **3.2 — Confirmation nudge job. DONE 2026-08-24** — `0033_confirmation_nudges.sql`,
  tests in `14_confirmation_nudges_test.sql` (22 assertions).

  **Shipped as five escalating tiers (24h/12h/5h/1h/30m), not the single ~24h window
  planned above.** The single-window plan leaned on DISCOVERY's "the day before" line,
  but reps in practice don't share one habit — some call a day out, some call an hour
  out, some only act once something looks wrong (all reported directly, mid-build). A
  fixed window serves the first group and silently misses the rest.

  **Why escalation doesn't turn into spam:** every tier's query still filters on
  `attendance_status = 'pending'`. The moment a rep confirms, at any tier, every later
  tier's query stops matching that event — nobody who has already acted gets nagged
  again. The tiers are a reminder ladder, not a deadline: a rep who prefers calling an
  hour before can see the 24h nudge land and still act on their own clock.

  **Idempotency needed a new table, not the `notifications` not-exists check
  originally planned.** That worked for one window ("does a `confirmation_needed` row
  exist for this event") but can't tell five tiers apart — a 12h nudge would look like a
  duplicate of the 24h one and never fire. `notifications` has no structured metadata
  column to tag a tier onto, so `confirmation_nudges_sent` (event_id, tier) is a small
  dedicated ledger instead — narrower than adding a column to serve one caller.

  **Accepted, not solved: an event first seen inside more than one tier's window fires
  all of them in the same run** — e.g. created 45 minutes before start hits the 24h,
  12h, 5h and 1h windows at once. Rare (most events are scheduled well ahead) and left
  unhandled rather than adding a "supersede the less-urgent tiers" rule for a case this
  narrow.

  **Who receives it: every attached cohort's `class_rep` (both ranks), not just the
  initiator's** — `0022` already lets any attached cohort's rep confirm attendance, so
  the nudge reaches all of them the same way, via `notify_cohort_members`'s existing
  role filter. Cohorts that declined or left the lecture are excluded, matching
  `confirm_attendance`'s own exclusion.

  **Scheduling: `pg_cron` every 15 minutes**, not daily — tight enough to catch the
  smallest gap between tiers (1h → 30m) with margin. The nudge logic is a plain SQL
  function (`send_confirmation_nudges()`), unit-testable in pgTAP the way
  `request_password_recovery` is; `cron.schedule` is a one-line, untestable
  registration calling it, not where the logic lives.

  **New table needed its own RLS/grants boilerplate** (0014 §4's pattern, repeated by
  every migration that adds a table since): `confirmation_nudges_sent` got RLS enabled,
  a faculty-rep-readable policy (same shape as `role_audit_log`'s), and an explicit
  `revoke all ... from anon, authenticated` — missing this on the first pass broke three
  `00_access_control_test.sql` structural invariants (RLS coverage, anon privileges,
  authenticated SELECT-everywhere) that had nothing to do with the nudge logic itself.

- [x] **3.3 — Configure OAuth. MOVED to `R.1`.** `config.toml` has no
  `[auth.external.google]` block at all, so signup Path B (§10) cannot be exercised
  locally — the seed works around it by recording an `email` identity for every account
  while keeping `raw_app_meta_data.provider = 'google'`. Needs real Google (and Apple, if
  shipping iOS) credentials plus redirect URLs. **No longer Phase 3 work:** after `0.5`
  it is a hard prerequisite for the entire identity model, not an optional auth path.

- [x] **3.4 — Implement `0.3`'s recovery decision. MOVED to `R.5`.**

- [x] **3.5 — Superadmin bootstrap path. DONE 2026-08-24** — `0032_superadmin_bootstrap.sql`,
  tests in `13_bootstrap_test.sql` (18 assertions), runbook in `TECHNICAL_DISCOVERY.md` §14.
  Faculty Rep onboarding was manual and out-of-band with no documented or scripted
  procedure — the one role every other role's authority descends from was the only one
  installed by hand-written UPDATEs.

  **Shipped as a function *plus* a runbook, not one or the other.** §3.5 asked for "a real
  script or documented runbook"; `bootstrap_faculty_rep(p_user_id, p_faculty_id)` is the
  mechanism the runbook describes. A definer function is testable in pgTAP the way `4.2`
  requires and a shell script is not, and it puts the validation in one place rather than
  in whoever's terminal history. `request_password_recovery` (`0031`) is the precedent for
  a `service_role`-only definer function.

  **The original diagnosis was half right.** This item said a manually created rep "sits
  with a `NULL` email and a `NULL` `faculty_id`, which after `0014` means they can do
  nothing at all." The `faculty_id` half is exact — `0016` raises *"This faculty_rep has no
  faculty_id set and cannot create cohorts"*. The email half is not: no authority check
  reads `users.email` at all. It is contact information worth filling in, but `faculty_id`
  is what separates a working trust anchor from an inert one.

  **`email_verified_at` is deliberately NOT set, against the seed's example.** `seed.sql`
  §8 stamps it, and copying that would have been the obvious move — but the seed is the
  institution fabricating a starting state, while this runs against a live deployment.
  `0019` *dropped* `mark_email_verified` specifically to leave that field exactly one
  legitimate writer (the OAuth path, from a provider-proven address); stamping it here
  re-opens that door. Nothing is lost — the only functional read is `claim_roster_row`
  deciding oauth-vs-provisional, and a faculty rep never claims a roster row.

  Other decisions: idempotent for a re-run against the same faculty (bootstrap procedures
  get run twice), but re-pointing an existing rep at a *different* faculty is refused —
  that moves a trust anchor and strands cohorts under a rep who can no longer administer
  them. Only a plain `student` is promotable, same discipline as `promote_class_rep`. A
  synthetic `@auth.internal` address is never copied into `public.users.email`. Writes
  `role_audit_log` with `actor_id` null and `snapshot.actor = 'superadmin'` — the
  Superadmin has no `users` row to name, and §0.5's rule that an unlogged manual override
  would be the most dangerous function here applies with full force to installing a trust
  anchor.

  **Also fixed here:** `guard_users_self_update`'s error message had told users to change
  their email "via `mark_email_verified`" since `0014` — a function `0019` deleted. Thirteen
  migrations of pointing at something that does not exist.

  > **MISTAKE, CORRECTED 2026-08-24.** Everything in this subsection describes a wrong
  > model the repo held and then fixed — not current behavior. **The current, and only,
  > model: a faculty rep is a student, full stop.** No staff role exists in this platform,
  > at all, and nothing below should be read as describing what's actually implemented
  > today — see `TECHNICAL_DISCOVERY.md` §10 for that.

  **A DOMAIN-MODEL CORRECTION came out of building this, and it is the more important
  half.** The first draft treated a faculty rep as a different kind of person from a
  student — staff, no registration number. **They are students.** Both elevated roles are:
  a class rep and a faculty rep are students carrying more responsibility, with the same
  `@student` address, the same registration number and the same cohort they had before.
  `DISCOVERY.md` never said otherwise — it calls a class rep "a student elevated by a
  Faculty Rep" and never describes a faculty rep as staff. The "Deans on `@chuka.ac.ke`
  addresses" framing was an assumption `seed.sql` introduced, which `0002`'s `reg_number`
  comment then repeated as if it were schema fact.

  Fixed: `seed.sql` §8 now models both faculty reps as students (`@student` OAuth
  addresses, registration numbers, cohorts, claimed roster rows) and §9.5 includes
  `faculty_rep` when building the roster — excluding them was the old assumption
  reasserting itself through a `WHERE` clause. `TECHNICAL_DISCOVERY` §10 gained "Everyone
  in `users` is a student". `bootstrap_faculty_rep` needed no behavioural change — it
  already set `role` and `faculty_id` and nothing else — but `13_bootstrap_test.sql` now
  asserts a promoted student keeps their `reg_number`, cohort and `oauth` roster claim, so
  the model cannot regress silently.

  Two consequences worth knowing: a faculty rep reads their own cohort's timetable as a
  student (correct — they still attend it), and appears in `cohort_unstreamed_members` when
  that cohort is split, because they need assigning to a lecture group like anyone else.

  `0002`'s two misleading comments (`reg_number` "faculty_reps ... have no registration
  number", `faculty_id` "for users NOT tied to a cohort") were **corrected in place**.
  They are `--` source comments — never stored in the database, re-read on every
  `db reset` — so there was no applied history to protect, and leaving them would only
  have kept teaching the wrong model to the next reader.

  **Roles are exclusive — one person, one role at a time.** A class rep moving up hands
  their cohort over first (`demote_class_rep`, then `promote_class_rep` for the successor,
  usually the sitting assistant); `bootstrap_faculty_rep` refuses a sitting class rep and
  its error names that handover. Separation of duties, not an arbitrary limit: a faculty
  rep promotes class reps, so holding both would mean promoting yourself.

---

## Phase 4 — ongoing

- [ ] **4.1 — Re-run the Supabase Advisor.** 17 non-blocking warnings were noted after
  `0008` and never triaged. A great deal has changed since; the list is stale and worth
  regenerating rather than working from.
- [ ] **4.2 — Add a test alongside every new function.** The suite paid for itself
  immediately: writing `02_trust_chain_test.sql` found the join-request privilege-carrying
  bug that reading the code had missed, and all four dormant bugs `0014` fixed would have
  been caught by a single `create_event` call in a test.
- [ ] **4.3 — Keep the Flutter repo's Dart models in sync** in the same work session as
  any schema change. There is no generated-types safety net catching drift.
- [ ] **4.4 — The synthetic-auth-email transform is a client-side contract with zero
  server enforcement, and a mismatch is indistinguishable from a wrong password.**
  Different failure mode from `4.3`, which is about signature drift you'd *notice* — a
  renamed parameter fails loudly on the first call. This one fails silently: the
  registration-number-password signup path (`0002` §A, `TECHNICAL_DISCOVERY.md` §10)
  requires the client to build `<reg_number, lowercased, "/"→".">@auth.internal` and call
  `signUp`/`signInWithPassword` against it — but grepping the whole repo for
  `@auth.internal` turns up only seed data, test fixtures, and comments describing the
  format. **No migration or function builds or validates this string.** If the Flutter
  client's transform ever drifts from this one, GoTrue does a normal "no such user"
  lookup and returns a normal "invalid credentials" error — no log line distinguishes
  that from an actually-wrong password, so a whole cohort could be silently locked out
  with nothing for anyone to grep for. Verified against real seed pairs
  (`EB1/67277/23` ↔ `eb1.67277.23@auth.internal`) that lowercase + `/`→`.` is the entire
  transform, at least for every reg-number shape currently in the roster.

  **DECIDED: keep the client building the string — a server-side `synthetic_auth_email()`
  RPC was considered and rejected.** It looked like the cleaner fix (one canonical
  derivation, same precedent as `0026` making `cohorts.name` trigger-derived instead of
  client-written) but doesn't survive the discriminating question: *does the client have
  a working synthetic address at the moment it needs one?* Signup can afford an extra
  round trip before `signUp`. **Login can't** — it may run offline, on a bad connection,
  or against an unreachable backend, and gating a password login behind a successful
  unauthenticated RPC turns a network blip into "can't log in", a new failure mode on the
  hot path that doesn't exist today. Any reasonable Flutter implementation would cache
  the derived address or reimplement the transform locally as a fallback anyway — putting
  the duplication right back, now across two code paths instead of one.

  More fundamentally: **the RPC makes the transform *available*, not *verifiable*.**
  Nothing forces the client to call it — a Dart implementation that builds the string
  locally passes every test in this repo either way. `synthetic_auth_email` being
  pgTAP-correct proves nothing about what the client actually sends; the silent-lockout
  mode this item exists to close would survive the fix. Not worth paying for with the
  first `anon` grant in a schema whose `00_access_control_test.sql` asserts that closed
  door as a structural invariant.

  **What actually closes it is Flutter-side**: a unit test asserting the transform
  against a fixed table of pairs (the seed pairs already verified above), with signup and
  login sharing one function so the two can't drift from each other. That's where this
  bug would actually live, so that's where the test has to be.

  **Server-side follow-up: DONE 2026-08-25** — `0036_unclaimed_synthetic_signups.sql`,
  `unclaimed_synthetic_signups()`, tests in `16_unclaimed_synthetic_signups_test.sql` (7
  assertions). Shipped slightly differently from the sketch above: rather than re-deriving
  the email's implied reg number and checking it against the roster (a second copy of the
  exact transform this item is about, which would have been the wrong fix for the same
  reason option 1 above was), it surfaces every `@auth.internal` account with
  `reg_number is null` more than an hour past signup — the queryable symptom, regardless
  of whether the cause was a transform bug, a mistyped reg number at claim time, or an
  abandoned signup. Faculty-rep readable, not scoped to one faculty (an unclaimed account
  has no `cohort_id`/`faculty_id` to scope by — same reasoning `confirmation_nudges_sent`
  used). **Still not a replacement for the Flutter-side unit test** — this only notices
  after the fact, once someone is already stuck.

---

## Explicitly not doing (deferred, not forgotten)

From `DISCOVERY.md` "Out of Scope" and §11 of `TECHNICAL_DISCOVERY.md`. Listed so nobody
mistakes them for oversights:

- **Branching — deferred post-MVP. It is not "subgroups", and this entry used to imply it
  was.** A cohort is admitted as ONE group containing both government-sponsored (GSS) and
  self-sponsored (SSP) students. **GSS can only run bimester.** SSP students may move to
  trimester — but *collectively, not individually*: a threshold number of them must want
  it, they tell their class rep, the rep escalates, and it is confirmed above them. Below
  the threshold everyone stays bimester. So a branch is a **pace divergence by quorum
  inside an existing cohort**.

  **The threshold is unverified.** It is known to exist; its actual value has not been
  confirmed with the registrar. That is the main reason this is deferred — the rule cannot
  be encoded before it is known, and guessing it would bake a wrong number into the one
  place students' academic pace is decided.

  **Not urgent, because the schema already reaches the destination.** Students who branch
  leave their cohort and the faculty rep creates the trimester cohort through
  `create_cohort_with_class_rep`. `0024`'s identity key deliberately permits this — pace is
  part of it, so `BSC-CS 2023 (bimester)` and `BSC-CS 2023 (trimester)` are two legitimate
  rows. What is missing is only the in-app **request and escalation flow**, not anywhere
  for the result to live.

  **Distinct from streams, which are NOT out of scope** — branching changes a student's
  pace; a stream splits a cohort that already shares one. This entry previously conflated
  them and was read as ruling both out.
- Self-service join codes as a user-facing feature — `cohorts.join_code` is generated and
  deliberately dormant. **`0.5` settles this permanently:** DISCOVERY left it open
  ("whether a self-service join-code fallback will actually ship, or stay dormant"), and
  the roster supersedes it outright. A join code is a shared secret anyone in the room
  can use on anyone's behalf; the roster is per-person and pins the cohort already. The
  column stays dormant for good — **and is dropped in Phase 2, see `2.8`.**
- Lecturer accounts. Lecturers are free text in `events.lecturer_name` and never log in.
- Faculty-wide analytics and reporting dashboards.
- A web app. Mobile only for MVP.
- ~~**Recurring combined lectures**~~ — **moved to `S.4` (2026-08-20), no longer deferred.**
  A one-off combined lecture already works; what is missing is only letting one repeat.
  The reconfirmation churn that motivated the deferral is answered by confirming a series
  once rather than per occurrence, and most of the machinery (materialization, `p_until`,
  the shared group id) already shipped in `0022` for single-cohort series.
- Joining an *already-scheduled* combined lecture after the fact. Leaving one works
  (`leave_event_cohort`); there is no inverse.
