# Technical Discovery — Lecture Scheduler Backend

*Read this to understand what exists and why, without needing to trace through 16 migration files. Written for a backend dev picking this up cold.*

**State as of 2026-08-25:** 36 migrations, `supabase db reset` runs clean, 405 pgTAP tests passing across seventeen files in `supabase/tests/`. Section numbers in this document are referenced by number from migration comments (`TECHNICAL_DISCOVERY §7`, etc.) — **don't renumber sections 1–14**, append instead.

**If you read only two sections, read §2 and §13.** §2 is the rule the whole schema exists to protect; §13 is the part that is easiest to get wrong and hardest to notice.

---

## 1. Stack

- **Database/Backend**: Supabase (Postgres 17 + Auth + Realtime + Row-Level Security + Edge Functions).
- **Client**: Flutter (separate repo, not covered here).
- **Repo split**: this repo owns *all* server-side logic — SQL migrations under `supabase/migrations/`, tests under `supabase/tests/`, and any Edge Functions (Deno/TS) under `supabase/functions/`. Those arrived with `R.5` (`0031`): `_shared/axene.ts` wraps the Axene mailer, and `recovery-email-setup/` + `recovery-request/` are the two recovery endpoints. The Flutter repo hand-writes its own Dart models mirroring this schema; there's no code generation between the two, so any breaking schema change needs a corresponding note (see §12).
- **Local dev runs on Docker.** The stack images are cached there. Don't point the CLI at podman on this machine — it hosts an unrelated project.

## 2. The one rule everything else follows

**A cohort's schedule can only be created or modified by someone whose authority traces back to a real-world election witnessed by a Faculty Rep.** Concretely: `Superadmin → Faculty Rep → Class Rep → Student`, top-down only, no role can skip a level or self-promote. Every RLS policy and every privileged function in this schema exists to protect that one guarantee. If you're ever unsure why a check exists, it's almost always this.

**Identity is anchored the same way, as of `0017`–`0019`.** It wasn't always: `handle_new_auth_user` used to copy `raw_user_meta_data ->> 'reg_number'` verbatim from the client into the column the whole trust model rests on, so anyone could sign up claiming any registration number and two accounts could hold the same one. Every careful check in `0014`–`0016` sat on top of a `users` row whose identity had simply been asserted.

Now the institution pre-declares who exists and **signing up means claiming a known identity rather than creating one** — see §10. The two halves finally match: authority traces to a witnessed election, identity traces to a roster.

## 3. Migration map

| File | What it establishes |
|---|---|
| `0001_enums_and_reference_data.sql` | Core enums; faculties → departments → programmes → courses → cohorts; buildings/rooms/venues |
| `0002_users_and_auth.sql` | `users` table, `auth.users` sync trigger, email verification |
| `0003_cohort_membership.sql` | Join requests, atomic cohort-creation-with-first-rep function, max-2-reps enforcement |
| `0004_events_and_scheduling.sql` | `events`, attendance confirmation, reschedule linkage, conflict EXCLUDE constraints, audit log, notifications table |
| `0005_realtime.sql` | Cohort-scoped realtime broadcast trigger |
| `0006_rls.sql` | RLS policies across all tables; `current_app_user()` helper |
| `0007_venue_availability.sql` | Cross-cohort venue availability (superseded by `0008`) |
| `0008_security_hardening.sql` | Fixes: `search_path` pinning, extension schema, replaced the security-definer *view* with a function, added missing `auth.uid()` checks to every privileged function (see §8 — this one matters a lot) |
| `0009_event_status_proposed.sql` | Adds `'proposed'` to `event_status`, two new `notif_type` values (isolated migration — enum `ADD VALUE` can't share a transaction with anything using it) |
| `0010_combined_lectures.sql` | The big structural change: `events.cohort_id` → `event_cohorts` join table, proposal/confirmation workflow, reworked conflict constraints, RLS, realtime fan-out |
| `0011_cohort_confirmation_left.sql` | Adds `'left'` to `cohort_confirmation_status` (isolated, same enum restriction) |
| `0012_leave_and_notifications.sql` | Post-scheduling opt-out (`leave_event_cohort`) + notification-writing wired into every event-mutation function |
| `0013_reschedule_ordering_and_broadcast_fixes.sql` | `reschedule_event` retires the old occurrence before inserting the new one (it used to collide with itself on the EXCLUDE constraints); broadcast trigger no longer touches `NEW` on DELETE; rebuilds the cohort calendar index on `event_cohorts` |
| `0014_access_control_and_privileges.sql` | RLS recursion fix (`user_can_see_event`), column-level guard triggers, function grants, **table privileges**, faculties RLS |
| `0015_event_function_fixes.sql` | Combined-lecture workflow guards, venue availability, **the enum cast that had stopped every event from ever being created**, sync trigger privilege |
| `0016_trust_scope_and_realtime.sql` | Faculty Rep scoped to their own faculty, `realtime.send` broadcast rewrite, channel subscription policy, join-request privilege fix |
| `0017_roster_and_identity.sql` | `student_roster`, `roster_audit_log`, `user_recovery_email`, registration-number parsing, scoped roster writes |
| `0018_identity_notif_types.sql` | Two `notif_type` values for takeover and dispute (isolated, same enum restriction as `0009`/`0011`) |
| `0019_claim_and_takeover.sql` | Claiming, the OAuth-address match rule, takeover, dispute resolution; `handle_new_auth_user` stops trusting client metadata; `mark_email_verified` dropped |
| `0020_phase1_enums.sql` | `audit_action += confirmed, unconfirmed`; `notif_type += attendance_confirmed, attendance_unconfirmed` (isolated, same enum restriction as `0009`/`0011`/`0018`) |
| `0021_terms_and_per_cohort_course.sql` | `term_bounds(date, cohort_pace)` — the academic calendar as a pure function, not a stored column; `event_cohorts.course_id` added (nullable); `events.course_id` deprecated and made nullable. Structure only, no function bodies change — see §4 |
| `0022_event_api.sql` | Closes the event API in one pass: `create_event` rewritten (per-cohort courses, `p_title`, recurrence materialization), `cancel_recurrence_group`, `update_event`, `confirm_attendance`/`unconfirm_attendance`, `role_audit_log` + `promote_class_rep`, `reschedule_event` restated, `event_cohorts.course_id` tightened to `NOT NULL`, `events.course_id` dropped |
| `0023_naming_and_role_audit.sql` | Phase 2 behaviour: cohort names gain their pace, `create_cohort_with_class_rep` stops writing `join_code` (deprecated here), `reschedule_event` stops copying `recurrence_rule`, `demote_class_rep` writes `role_audit_log` |
| `0024_integrity_and_retention.sql` | Phase 2 structure: four missing unique constraints, notification indexes, retained audit attribution + `ON DELETE SET NULL` across all five blocking FKs, `events.recurrence_rule` and `cohorts.join_code` dropped, `events_current` rebuilt |
| `0025_cohort_streams.sql` | Streams as **child cohorts**: `parent_cohort_id`/`stream`, the identity key made partial so `(programme, intake, pace)` stays unique for real cohorts, a composite FK forcing a stream to inherit its parent's programme/intake/pace, and a depth trigger keeping the hierarchy exactly two deep |
| `0026_stream_creation_and_naming.sql` | `create_cohort_stream()`; `cohorts.name` becomes **derived by trigger** from (programme, intake, pace, stream), closing `0023`'s drift defect; `name` loses its client UPDATE grant |
| `0027_roster_reassigned_action.sql` | `roster_audit_action += 'reassigned'` (isolated, same enum restriction as `0009`/`0011`/`0018`/`0020`) |
| `0028_stream_assignment.sql` | `assign_students_to_streams()` and `cohort_unstreamed_members()`; `create_cohort_stream` gains the precondition that a cohort with upcoming lectures **cannot be split**, and now moves the rep's roster row too |
| `0029_roster_placement_sync.sql` | `create_cohort_with_class_rep` and `approve_cohort_join_request` stop leaving the roster row behind — a real bug, since `claim_roster_row` re-places an account from the roster unconditionally. The move is **conditional** (declined where the reg number would no longer match the cohort), with `roster_placement_divergences()` surfacing the residue |
| `0030_recurring_combined_lectures.sql` | **Recurring combined lectures**, reversing `0.1`'s deferral: `create_event`'s multi-cohort recurrence guard lifts, the horizon takes the earliest term end across all attached cohorts, and a clash names every offending date. `confirm_recurrence_group()` / `decline_recurrence_group()` make it one decision instead of one per occurrence |
| `0031_recovery_email.sql` | `R.5`: first writer for `user_recovery_email` (structure-only since `0017`). `set_recovery_email` / `verify_recovery_email` (self-service, 6-digit setup code from `extensions.gen_random_bytes`, not a GoTrue token) and `request_password_recovery` (the unauthenticated lookup, `service_role`-only) — see §8 |
| `0032_superadmin_bootstrap.sql` | `3.5`: `bootstrap_faculty_rep()` — the top of the trust chain finally gets an installer instead of hand-written UPDATEs. `service_role` only; runbook in §14. Also corrects `guard_users_self_update`'s error message, which had named the dropped `mark_email_verified` since `0014` |
| `0033_confirmation_nudges.sql` | `3.2`: `send_confirmation_nudges()` — the reminder half of `0022`'s attendance-confirmation feature. Five escalating tiers (24h/12h/5h/1h/30m out), each idempotent via the new `confirmation_nudges_sent` ledger, sent to every attached cohort's `class_rep` via `notify_cohort_members`. Scheduled with `pg_cron` every 15 minutes — see §8 |
| `0036_unclaimed_synthetic_signups.sql` | `TODO` 4.4 follow-up: `unclaimed_synthetic_signups()` — every `@auth.internal` account still unclaimed an hour past signup, for whoever's investigating a client-side synthetic-address transform bug (never re-derives or validates the transform itself — see §8) |
| `0035_visibility_comment_correction.sql` | Comment-only `CREATE OR REPLACE` on `user_can_see_event()` (`0014`): its NULL-cohort_id comment named "faculty reps" as an example, which stopped being true once `0032`'s domain-model correction gave faculty reps a real `cohort_id`. Same shape as `0032`'s `guard_users_self_update` fix — no behaviour change, no ACL change |
| `0034_push_delivery.sql` | `3.1`: `device_tokens` + `register_device_token()` (client-facing, reassigns a token to whoever registers it now — a shared/resold phone hands the same FCM token to a different student), `claim_pending_pushes()` (atomic claim + stamp of `notifications.pushed_at`, `service_role`-only), `invoke_push_dispatch()` (`pg_cron` every minute, `net.http_post` to `functions/dispatch-push` using a URL/key pair from `supabase_vault`, no-ops if either secret is unset). Edge Function side: `functions/dispatch-push` + `_shared/fcm.ts` (FCM HTTP v1, service-account OAuth, deletes a `device_tokens` row only on FCM's `UNREGISTERED` error) — see §8 and §11 |

Apply in numeric order. `0009` and `0011` exist purely because Postgres won't let you `ALTER TYPE ... ADD VALUE` and then use that value in the same transaction — don't merge them into their neighbors.

**`0014`–`0016` are one correctness pass, split by theme.** They were written together while the first test suite was going in, then divided. They are not independent: `0014` grants EXECUTE on functions that `0015` and `0016` redefine. That's safe and deliberate — the pass uses `DROP FUNCTION` nowhere, and `CREATE OR REPLACE` preserves the existing ACL. Grants first, bodies after.

**The most important thing that pass found:** `create_event` and `reschedule_event` had **never successfully inserted a row** since `0010` introduced them. A `CASE` expression building `event_cohorts.confirmation_status` produced `text`, and there's no implicit cast to `cohort_confirmation_status`, so the statement died with `42804` every time. A bare literal would have been fine — wrapping it in a `CASE` forces type resolution first. Applying a migration only *defines* a function, so nothing exercised either one until the seed did. Four migrations of event logic had only ever been reasoned about. **This is why `TODO.md` §4.2 insists on a test alongside every new function.**

## 4. Core entities, plain-English

- **`faculties → departments → programmes → courses`**: standard academic hierarchy. A programme's government-sponsored and self-sponsored variants (e.g. reg-number prefixes `EB3` vs `EBS3`) are the *same* `programmes` row — they run identical courses. The only real difference is pace (see `cohorts.pace`), resolved by parsing the registration number, not by duplicating the programme.
- **`cohorts`**: one per programme+intake-year+pace combination. Created via `create_cohort_with_class_rep()` — never directly — because a cohort with no rep has no real-world meaning (see §8).
  - **No semester window, deliberately.** The columns are `programme_id, name, join_code, intake_year, current_semester, pace, created_at`. Recurrence's horizon (see below) is derived from the calendar via `term_bounds()`, not from a date column — that was the original `0.1` plan, and deriving turned out strictly better: nothing to backfill, no cohort can sit with a null window blocking recurrence, and no stored date goes stale when a cohort rolls into its next semester.
  - **Identity is `(programme_id, intake_year, pace)`**, enforced by a unique constraint as of `0024`. Note `current_semester` is deliberately *not* part of it: it is mutable progression state (a rep advances it), and including it would mean advancing a cohort vacates its identity slot for another to occupy.
  - **Naming**: `abbreviation intake_year (pace)` as of `0023` — e.g. `BSC-CS 2023 (bimester)`. The pace is there because without it two cohorts of the same programme and intake on different paces got byte-identical names. Semester is deliberately excluded for the same reason it is excluded from the key. Since the name is a faithful rendering of a unique key, name uniqueness follows for free and is not separately constrained.
  - `join_code` was generated and permanently dormant; **dropped in `0024`.** The roster (§10) supersedes it — a join code is a shared secret anyone in the room can use on anyone's behalf.
- **`users`**: one row per person, mirrored from `auth.users` via trigger. `role` is the single source of truth for permissions — **never trust a JWT claim for this, always the `users.role` column**, since RLS policies query it live. `class_rep_rank` (`primary`/`assistant`) is a label only, not a privilege tier.
- **`venues`** (physical, tied to a `room`, or online, one row per meeting link) and **`rooms`**/**`buildings`**: reference data, effectively read-only to app users, seeded by Superadmin.
- **`events`**: one row per lecture *occurrence*. No longer has a direct `cohort_id`, and as of `0022` no longer has `course_id` either — see `event_cohorts` next.
- **`event_cohorts`**: join table between `events` and `cohorts`. This is what makes combined (cross-cohort) lectures possible. Carries a denormalized copy of the event's `start_time`/`end_time`/`status` (kept in sync by a trigger) purely because Postgres EXCLUDE constraints can't reference a joined table — the self-overlap conflict check needs cohort + time range on one row. Also carries `course_id`, one per attachment (`0021`, populated and made `NOT NULL` by `0022`): `courses` is programme-scoped, so a combined lecture spanning two programmes has no single unit valid for both, and each cohort now attends as its own.
- **`event_audit_log`**: append-only, one row per meaningful action, always attributed to the acting human (never a lecturer — they have no accounts).
- **`notifications`**: one row per user per notifiable event. Written exclusively from inside the privileged functions in §8, never inserted directly by the client. **Nothing dispatches them to devices** — see §11.
- **`cohort_join_requests`**: student requests → class rep approves/declines. Declined isn't permanent — re-request is allowed. Since `0017` this is the *exception* path only: a roster row pins the cohort, so an ordinary student is placed automatically on claiming. What's left for this table is the case DISCOVERY calls out explicitly — students who deferred, transferred or repeated, where the obvious cohort is the wrong one.
- **`student_roster`**: one row per person the institution says exists — registration number, full name, cohort, and the claim binding (`claimed_by` / `claimed_at` / `claim_method`). **No email column, ever** (§10 explains why). **Write-mostly**: readable by students it would be a directory of every classmate's exact official name and registration number, which is precisely the pair needed to claim someone else's row. `reg_number` is globally unique so two reps can't roster the same human into different cohorts. Unclaimed rows never expire.
- **`roster_audit_log`**: append-only, same idiom as `event_audit_log`. `reg_number` is denormalized onto it so the trail survives its roster row being deleted — an audit log erasable by deleting the thing it audits isn't one. Not optional bookkeeping: `resolve_roster_dispute` can sever a claimed identity, and an unlogged manual override of that kind would be the most dangerous thing in this schema.
- **`role_audit_log`** (`0022`): append-only, same idiom again. Before this, role changes — including `demote_class_rep`, which can strip a cohort's scheduling authority — were entirely unlogged. Carries the `promote_class_rep` identity attestation (§10), which matters more here than ordinary bookkeeping: a Faculty Rep asserting "I physically verified this person" is exactly the kind of human override that must never be unlogged.
- **`user_recovery_email`**: a personal address for password reset, and nothing else. Its own table rather than a column on `users` for a concrete reason — `0014` §4 grants `select` on the *whole* `users` table to `authenticated` and `users_read_all` is `auth.uid() is not null`, so a column there would publish every student's personal address to the entire university. Self-readable only, deliberately not unique (a shared or parent address is valid).

### Recurrence — materialized on create, bounded by the academic term

Built in `0022`, on top of `0021`'s `term_bounds(p_date date, p_pace cohort_pace) returns term_window`: a pure function of the calendar, not a stored column. The calendar year splits at fixed boundaries — Jan 1–Apr 30, May 1–Aug 31, Sep 1–Dec 31 — but a cohort doesn't necessarily teach in all three. **Pace matters:** trimester runs all three terms; **bimester runs only two**, Jan–Apr and Sep–Dec, with May–Aug as the long break. `term_bounds` returns `(null, null)` for a bimester cohort asked about a date in that break, rather than inventing a term.

`events` carries `recurrence` (`none|day|week|month`) and `recurrence_group_id`, plus an index on the group. `recurrence_rule` (text) still exists on the table but stays unused — `0004`'s own comment already called it *"display metadata only"*, and it became fully redundant once occurrences are materialized from the enum plus a horizon; `create_event` no longer takes it as a parameter.

**How `create_event` uses it, when `p_recurrence <> 'none'`:**

- Refused if more than one cohort is attached, and restricting to one cohort is also what makes "whose pace?" unambiguous. **This refusal is scheduled to be lifted** — see §7. It was a deferral rather than a rejection, and the machinery it would need is already built.
- `term_bounds(p_start::date, initiating cohort's pace)` gives the term. If `term_end` is null (a bimester cohort starting in its May–Aug break), refused — a **one-off** lecture in that same break is still fine, since this gate applies to recurrence only.
- `horizon := least(coalesce(p_until, term_end), term_end)` — `p_until` is the rep's real last teaching date (nullable — teaching rarely fills a term exactly); the term end is the hard ceiling a rep cannot push past.
- One `events` row per occurrence, stepping by the enum, while `occurrence::date <= horizon`, all sharing one generated `recurrence_group_id`. Capped at 200 occurrences as a sanity backstop.
- **All-or-nothing.** One transaction; any occurrence that trips either EXCLUDE constraint (§6) aborts the whole series, and the error names the clashing date rather than surfacing a raw `23P01`.
- A rescheduled occurrence **stays in its series** — `reschedule_event` copies `recurrence_group_id` onto the replacement row — which is exactly why `cancel_recurrence_group(p_group_id, p_acting_user)` (initiating rep only) has to select on the group id rather than walk from the original rows: it must reach a moved occurrence too.

Lazy expansion at read time was ruled out for good, not just deferred: the EXCLUDE constraints in §6 need real rows to conflict against, and conflict prevention is the product.

**Deliberately deferred, not built:** semester rollover. When a cohort's `current_semester` advances, its already-materialized occurrences don't regenerate — there's no automatic path for MVP, a rep re-creates the series if it matters. Revisit if it bites.

## 5. Two independent status dimensions on `events` — don't conflate them

- **`event_status`**: `scheduled | proposed | canceled | rescheduled`. Structural. `proposed` only applies to combined (multi-cohort) lectures mid-confirmation. Drives the conflict constraints.
- **`attendance_status`**: `pending | confirmed`. Day-of only — "has a class rep verified the lecturer is actually coming." Completely independent of `event_status`. If a lecturer says they're not coming, that's not an attendance value, it's the rep calling `cancel_event`/`reschedule_event` — attendance never has a third "no-show" state.
- **Time-based status** (`upcoming`/`ongoing`/`ended`) is **never stored** — always computed from `start_time`/`end_time` at query time, to avoid it silently going stale.

**`attendance_status` gained a code path in `0022`** — `confirm_attendance(p_event_id, p_acting_user)` and `unconfirm_attendance(...)`, callable by the class rep of **any** attached cohort, not just the initiator (any of them may be the one who phoned the lecturer). Both refuse outside `event_status = 'scheduled'` — `'proposed'` has nothing real to confirm attendance *for* yet, `'canceled'`/`'rescheduled'` aren't happening at all. Un-confirming is allowed (reversed from an earlier one-way lean): a rep who mis-taps otherwise leaves the cohort a confirmation nobody actually made, which is worse than none. `events` still has no client UPDATE policy or privilege on this column — the two functions remain the only way in, same as every other mutation in §8. The realtime broadcast action was renamed from the borrowed `confirmation_needed` (which meant the *opposite* thing — see `notif_type`) to `attendance_confirmed`/`attendance_unconfirmed`, the last moment it could be renamed for free since the Flutter client didn't exist yet.

## 6. Conflict detection

Two `EXCLUDE` constraints, both using `btree_gist` (moved to its own `extensions` schema in `0008`, not `public`):

1. **`events_no_venue_overlap`** on `events(venue_id, tstzrange(start_time,end_time))` — no two events can share a venue at overlapping times. Scoped to `status in ('proposed','scheduled')`.
2. **`event_cohorts_no_self_overlap`** on `event_cohorts(cohort_id, tstzrange(start_time,end_time))` — the *same cohort* can't be double-booked into overlapping lectures regardless of venue. Scoped to `event_status_cache in ('proposed','scheduled') and confirmation_status <> 'left'`.

Both intentionally include `'proposed'`, not just `'scheduled'` — a pending combined-lecture proposal tentatively reserves its slot, so two unrelated proposals can't both sail through and only collide later. The trade-off: if two proposals genuinely race for the same slot, the *second one to get fully confirmed* will hit a real constraint violation at confirmation time — there's no earlier warning than that at MVP.

**The read functions must agree with the constraints.** `get_venue_occupancy()` originally counted only `'scheduled'` while `0010` had widened the constraint to `('proposed','scheduled')`, so the venue browser advertised rooms as free that `create_event` then rejected with a raw `23P01` — the one error path the feature exists to prevent. Fixed in `0015`. `is_venue_available()` delegates to `get_venue_occupancy()`, so it inherited the fix; if you ever stop delegating, you own this bug again.

## 7. Combined (cross-cohort) lectures — the proposal/confirmation workflow

This was added mid-project as a late but deliberate MVP-scope decision (the informal real-world pattern of one lecturer teaching several cohorts at once was judged too central to defer).

- A class rep calls `create_event()` with an array of cohort IDs. If it's just their own cohort, the event goes straight to `scheduled`. If it includes others, it starts `proposed`.
- The initiating cohort is auto-confirmed. Every other attached cohort's rep must call `confirm_event_cohort()` or `decline_event_cohort()`.
- The moment the **last** cohort confirms, the event flips to `scheduled` — this is also the exact moment the conflict constraints get evaluated for real.
- **Any** decline cancels the whole event, for every cohort, immediately. There's no partial-removal-and-continue at proposal stage.
- Only the **initiating** cohort's rep can call `cancel_event()` on an already-scheduled event. A non-initiating rep who wants out *after* scheduling uses `leave_event_cohort()` instead — this only removes their own cohort (marks their `event_cohorts` row `'left'`, which is what makes the self-overlap constraint above release their slot) without affecting anyone else's confirmed booking.

**Two guards added in `0015`, both of which were bypasses of the rules above:**

- `decline_event_cohort` had no status guard, so **any** attached rep could decline an already-`scheduled` lecture and cancel it for everyone — routing around both `leave_event_cohort` and the initiator-only rule on `cancel_event`. A decline is now strictly a pre-confirmation action.
- `confirm_event_cohort` could **resurrect a canceled event**: if one cohort declined (event → `canceled`) while another was still `pending`, that second rep's confirmation flipped it back to `scheduled`.

**Not built yet**: a way for a cohort to join an *already-scheduled* combined lecture after the fact. (Leaving one works — `leave_event_cohort`; there is no inverse.)

**Recurring combined series are the one gap here, and are being closed** (`TODO.md` §S.4, 2026-08-20). A one-off combined lecture works; a recurring single-cohort series works; the two cannot yet be combined, because `create_event` raises when `p_recurrence <> 'none'` with more than one cohort attached. That guard was a deferral, not a rejection — the cost cited was designing per-occurrence reconfirmation for several reps. `0022`'s `cancel_recurrence_group` has since established the "act on a whole series at once" shape, so the answer is to confirm a `recurrence_group_id` once rather than fifteen occurrences. It matters because term-long combined teaching is ordinary here — a lecturer taking two programmes together for a whole semester.

## 8. Privileged functions — the actual API surface for mutations

Every mutation to `events`/`event_cohorts`/`cohorts`/class-rep status goes through a `SECURITY DEFINER` function, **not** direct table writes. This is deliberate: `events` has no client-facing INSERT/UPDATE RLS policy at all as of `0010` — read the function, not the table, to understand what's allowed.

**Pattern every one of these follows** (established the hard way — see the note below): take a `p_acting_user` parameter, immediately check `p_acting_user = auth.uid()`, then check the caller actually holds the right role *for the specific cohort/event in question* — not just "is a class_rep somewhere."

### Callable over RPC (granted to `authenticated`)

| Function | Who can call it | What it does |
|---|---|---|
| `create_cohort_with_class_rep(...)` | Faculty Rep, **own faculty only** | Creates a cohort + promotes the first class rep, atomically. First rep must be a plain `student`. |
| `demote_class_rep(...)` | Faculty Rep, **own faculty only** | Empties a class rep slot — no auto-promotion of the assistant. Writes a `'demoted'` row to `role_audit_log` carrying the rank removed (`0023`); before that, removing a cohort's scheduling authority left no trace at all. |
| `promote_class_rep(...)` | Faculty Rep, **own faculty only** | Promotes a `student` to class rep at a given rank (`0022`). The only way to reach the `assistant` rank, or to refill `primary` after a demotion. A target whose roster claim isn't `oauth` requires `p_identity_attested => true` — the rep asserting they physically verified the person — recorded on `role_audit_log`. |
| `approve_cohort_join_request` / `decline_cohort_join_request` | The class rep of that specific cohort | Resolves a join request |
| `create_event(...)` | Class rep, must include their own cohort in the list | Creates a lecture, single or combined. `p_attachments` is a `jsonb` array of `{cohort_id, course_id}` (`0022`) — the course is per-attachment now, not a single FK, so each cohort on a combined lecture attends as its own programme's unit and a course from an unrelated programme is refused. `p_title` is new and nullable. When `p_recurrence <> 'none'`, materializes the whole series bounded by `term_bounds()` — see §4. |
| `cancel_recurrence_group(p_group_id, p_acting_user)` | The **initiating** cohort's class rep only | Cancels every live occurrence of a recurring series (`0022`), including one that was individually rescheduled — see §4. |
| `confirm_recurrence_group` / `decline_recurrence_group` | The class rep of an attached cohort with a pending confirmation | Accepts or refuses a whole proposed recurring combined series in one action (`0030`). Confirming one occurrence at a time is the churn that kept recurring combined lectures deferred; declining cancels the series for everyone, mirroring `decline_event_cohort`. |
| `update_event(...)` | The **initiating** cohort's class rep only | Edits `title`, `lecturer_name`, and the calling rep's **own** cohort's `course_id` (`0022`). `null` means leave a field unchanged. Time/venue changes stay with `reschedule_event`. |
| `confirm_attendance` / `unconfirm_attendance` | The class rep of **any** attached cohort, event must be `scheduled` | Confirms/withdraws that the lecturer is actually coming (`0022`) — see §5. |
| `confirm_event_cohort` / `decline_event_cohort` | The class rep of the specific attached cohort | Resolves a combined-lecture proposal. Decline is pre-confirmation only (§7). |
| `cancel_event` | The **initiating** cohort's class rep only | Cancels a scheduled event for everyone |
| `leave_event_cohort` | A **non-initiating** cohort's class rep, event must be `scheduled` | Opts just that cohort out |
| `reschedule_event(...)` | The **initiating** cohort's class rep only | Moves an occurrence; re-opens proposal/confirmation if combined. Carries the replacement's own `course_id` per attachment (`0022`) rather than the dropped `events.course_id`, and keeps `recurrence_group_id` — see §4. |
| `is_venue_available` / `get_venue_occupancy` | Any authenticated user | Cross-cohort venue occupancy, deliberately exposing only `venue_id` + time range, nothing else |
| `term_bounds(p_date, p_pace)` | Any authenticated user | The academic term containing a date, for a given pace (`0021`). Pure function of the calendar — see §4. |
| `current_app_user()` | Any authenticated user | Helper: the caller's own `users` row. Used ~14× across `0006`'s policies. |
| `user_can_see_event(uuid)` | Any authenticated user | **The single definition of "who can see this event"** — see §13. |
| `create_cohort_stream(...)` | Faculty Rep, **own faculty only** | Creates one stream of a cohort and installs its rep (`0026`). Inherits programme/intake/pace from the parent; accepts a sitting `class_rep`, unlike `create_cohort_with_class_rep`. Refuses if the cohort has upcoming lectures — a split does not migrate events (`0028`). |
| `assign_students_to_streams(...)` | **Faculty rep only**, own faculty | Moves named students *and their roster rows* into streams. Keyed on registration number, so an unclaimed row moves too. Safe to call repeatedly — splits are incremental. Refuses class reps. |
| `cohort_unstreamed_members(uuid)` | Any authenticated user | Roster rows still on a cohort that has streams — i.e. who has not been assigned yet. Definer, because students cannot read `student_roster` at all. |
| `roster_placement_divergences()` | **Faculty rep only**, own faculty | Claimed roster rows whose cohort disagrees with the account's — what `sync_roster_placement` could not legally move (`0029`). These students would be mis-placed by a takeover, so they need resolving out of band. |
| `roster_add_student(...)` | Class rep (own cohort) or faculty rep (own faculty) | One roster row, scoped by the registration number's own programme + intake year |
| `set_recovery_email(...)` / `verify_recovery_email(...)` | Self only (`p_acting_user = auth.uid()`) | Stores a recovery address and issues/checks a 6-digit setup code (`0031`) — not a GoTrue token, since `generateLink` can't prove control of an address GoTrue has never heard of. `verify_recovery_email` returns `boolean` rather than raising on a wrong/expired code — raising there would roll back the attempt-counter increment in the same call. |
| `roster_bulk_import(...)` | **Faculty rep only** | A whole intake at once. A class rep is refused with a message explaining the rule — unchecked bulk import by a rep would collapse the roster's authority back onto the rep |
| `roster_correct_student` / `roster_remove_student` | Same scoping as `roster_add_student` | Unclaimed rows only. Touching a *claimed* identity is a dispute, not a correction |
| `claim_roster_row(...)` | The claiming user themselves | Binds an account to a roster row. Carries **the rule** below, and the takeover path |
| `resolve_roster_dispute(...)` | **Faculty rep only**, own faculty | The manual override: severs a claimed identity, unbinding rather than deleting |
| `parse_reg_number` / `normalize_reg_number` / `reg_number_from_email` | Any authenticated user | Pure string→lookup helpers, no state |

### Callable by `service_role` only — reachable through an Edge Function, never RPC from the client

| Function | What it does |
|---|---|
| `bootstrap_faculty_rep(p_user_id, p_faculty_id)` | Installs a plain `student` account as a Faculty Rep anchored to one faculty (`0032`) — the root of the trust chain, which until now was created by hand-written UPDATEs. Takes no `p_acting_user`: Superadmin has no `users` row, so holding the `service_role` key *is* the authorization. Validates the target is a plain student, fills the `email` the sync trigger skips for non-OAuth signups, and deliberately leaves `email_verified_at` alone (see `0019`). Idempotent for the same faculty; refuses to re-point an existing rep at a different one. Runbook in §14. |
| `send_confirmation_nudges()` | Called only by `pg_cron` (`0033`, every 15 minutes), never by a client — no execute grant for `anon`/`authenticated`. Finds `scheduled`, still-`pending` events crossing one of five reminder tiers (24h/12h/5h/1h/30m out) and writes a `confirmation_needed` notification to every attached cohort's `class_rep`, once per (event, tier) via the `confirmation_nudges_sent` ledger. Stops escalating the moment a rep confirms — `attendance_status` leaving `pending` removes the event from every later tier's query. |
| `register_device_token(p_token, p_platform)` | Client-facing (`0034`): the only writer to `device_tokens`. Deletes any *other* user's claim on `p_token` before upserting the caller's own — a resold/reissued phone hands the same FCM registration token to a different student, and this is what stops that student getting the previous owner's timetable pushed to them. |
| `claim_pending_pushes(p_limit)` | Called only by `functions/dispatch-push` holding the `service_role` key (`0034`) — no execute grant for `anon`/`authenticated`. Atomically claims up to `p_limit` notifications with `pushed_at is null` (`FOR UPDATE SKIP LOCKED`), stamps `pushed_at` on every claimed row — including a device-less user's, so it isn't reselected forever — and returns one row per (notification, device token) pair for the caller to actually send. |
| `unclaimed_synthetic_signups()` | Diagnostic (`0036`, `TODO` 4.4): every `@auth.internal` account with `reg_number is null` more than an hour after signup — the queryable symptom of a stuck registration-number-password signup, whatever the cause (client transform bug, mistyped reg number at claim time, or an abandoned signup). Deliberately does not re-derive the email's implied reg number — that would duplicate the transform a second copy that `0002` and `TODO` 4.4 already decided against. Faculty-rep readable, not scoped to one faculty: an unclaimed account has no `cohort_id`/`faculty_id` to scope by. |
| `invoke_push_dispatch()` | Called only by `pg_cron` (`0034`, every minute), never by a client. Fires `net.http_post` at `functions/dispatch-push` using a URL/key pair read from `supabase_vault` (`push_dispatch_url` / `push_dispatch_key`); no-ops if either secret is unset, mirroring `_shared/axene.ts`'s swap-for-free discipline. `seed.sql` §12.5 seeds both for local dev only — a hosted deployment sets its own pair once, pointing at its real functions URL and `service_role` key. |
| `request_password_recovery(p_reg_number)` | The unauthenticated "forgot password" lookup (`0031`), called from `functions/recovery-request`. Explicitly **not** granted to `authenticated` — it resolves an arbitrary registration number to an account on no proof beyond the number itself, so only the trusted Edge Function (holding the service-role key) may call it. Per-account throttled; gated to accounts with no verified `public.users.email` (an OAuth account has no password to recover). Returns whether to send and, if so, the account's synthetic `auth.users` address plus its recovery address — never *why not*, so the caller's response is identical whether the number doesn't exist, the account is OAuth, there's no recovery address on file, or the cooldown is active. |

`mark_email_verified` **used to be on this list and was dropped by `0019`**, not hardened. It accepted any string with no proof of ownership, so a student could self-award the verified badge with a personal address. After the roster there is nothing left to validate: `email_verified_at` is written in exactly one place, by `0002`'s trigger, from an address an OAuth provider proved. Keeping a hardened version would have preserved a second, weaker way to set the same field — the shape of bug `0014`–`0016` spent 1,400 lines removing.

### Internal only — no EXECUTE granted to anyone

`notify_cohort_members(...)` (shared notification writer), plus every trigger function: `handle_new_auth_user`, `notify_cohort_event_change`, `notify_new_event_cohort`, `enforce_max_class_reps`, `sync_event_cohorts_from_event`, and the three guards from §13. **Trigger functions need no EXECUTE grant** — the trigger mechanism isn't privilege-gated, so revoking from everyone costs nothing and closes the RPC door.

**Two pieces of history worth knowing.**

An earlier version of several of these accepted the acting-user ID as a plain parameter *without verifying it against `auth.uid()`* — any authenticated caller could impersonate anyone in an RPC call. Caught via the Supabase Advisor's `SECURITY DEFINER` warnings, fixed in `0008`.

And every `REVOKE EXECUTE ... FROM anon` written in `0008`/`0010`/`0012`/`0013` was a **no-op**. Postgres can't revoke from one role a privilege that arrived via the implicit `GRANT ... TO PUBLIC` at function-creation time. You must revoke from `PUBLIC` first, then grant explicitly. `0014` does this for every function; copy that pattern, not the older one.

## 9. Realtime strategy

Students don't subscribe to `postgres_changes` directly on `events` — that would re-evaluate RLS per client per row change, which scales badly. Instead:

- One **broadcast channel per cohort**: `cohort:{cohort_id}:events`.
- A trigger on `events` (and one on `event_cohorts`, for new proposals) fans out a broadcast to every attached cohort's channel on any relevant change.
- The payload is **`{id, action}` only** — never the full row. Clients always do a fresh, RLS-checked `SELECT` in response. This is a deliberate correctness-over-latency choice: this app's core job is conflict prevention, so a client should never act on a payload that might already be stale.

**This never worked until `0016`.** Two independent reasons, both silent:

1. The trigger called `realtime.broadcast_changes(...)` with an argument list that doesn't match any overload, so every call died with `42883`. The fix wasn't to construct the right record — it was to **stop using `broadcast_changes` entirely**. That function exists to ship full `OLD`/`NEW` rows, which is precisely what this design refuses to do. `realtime.send(payload jsonb, event text, topic text, private boolean)` takes the payload directly and is the right primitive here.
2. With `private => true`, Realtime authorizes every subscribe against RLS on `realtime.messages` — and **no policy existed anywhere in `0001`–`0013`**, so the channels were unsubscribable even if the server had managed to write to them. `0016` adds `cohort_members_read_own_cohort_broadcasts`: a user may read exactly one topic, their own cohort's.

That read scope is deliberately *narrower* than the events a user can SELECT — a combined lecture broadcasts to every attached cohort's channel, and each rep only listens on their own. Correct direction: the payload carries no data, so the channel only needs to reveal "something on your cohort's calendar changed."

## 10. Auth and identity

**For the exact client call sequence, the synthetic-address transform spec, and user-journey walkthroughs (including the failure paths), see `AUTH_FLOW.md`.** This section owns the *why*; that file owns the *what, in order*.

`Superadmin` has no row in `users` and isn't a `user_role` enum value — it's the Supabase `service_role` key, which bypasses RLS entirely.

### Everyone in `users` is a student

**The two elevated roles are students carrying more responsibility, not different kinds of person.** A class rep and a faculty rep each keep the same `@student` university address and the same `reg_number` they had before being promoted, stay in their cohort, and go on seeing its timetable — because they go on attending it. `role` records the responsibility; it does not replace an identity.

> **Corrected mistake — not current behavior.** The paragraph below describes what the repo got wrong before 2026-08-24, kept only so the mistake can't quietly return. No code path, seed row, or function in this codebase treats a faculty rep as staff today — see the paragraph above for what's actually true.

The repo believed otherwise until 2026-08-24. `seed.sql` §8 modelled the two faculty reps as the sitting **Deans**, on `@chuka.ac.ke` staff addresses with no registration number — an assumption of the seed, never a requirement, since `DISCOVERY.md` describes a class rep as "a student elevated by a Faculty Rep" and nowhere describes a faculty rep as staff. **As of `0032`, the seed models them correctly and nothing in the live schema disagrees:** both hold a `@student` address, a registration number, a cohort, and an `oauth` roster claim, alongside the `faculty_id` that carries their authority.

`0002`'s comments on `users.reg_number` and `users.faculty_id` were corrected in place at the same time — both had encoded the old assumption ("faculty_reps have no registration number", "faculty_id is for users NOT tied to a cohort"). They are `--` source comments, never stored in the database and re-read on every `db reset`, so there was no applied history to preserve; leaving them would only have kept teaching the wrong model. `reg_number` is still legitimately nullable, for the real reason: an account that has not yet claimed a roster row (the `reg_number is not null` iff `claimed` invariant below).

**`cohort_id` and `faculty_id` answer different questions** and a faculty rep carries both: which lectures they attend, and which faculty they administer. Only the second is authority — `0016` checks it.

**Roles are exclusive — one person, one role at a time.** A class rep moving up to faculty rep hands their cohort over first (`demote_class_rep`, then `promote_class_rep` for the successor — usually the sitting assistant); `bootstrap_faculty_rep` refuses a sitting class rep and says so. This is separation of duties, not an arbitrary limit: a faculty rep promotes class reps, so holding both would mean promoting yourself, and DISCOVERY is explicit that a faculty rep "never schedules lectures themselves."

None of this affects authority: nothing checks a faculty rep's `reg_number`, and `0016`'s scoping keys off `role` + `faculty_id` only. What it does affect is what a faculty rep *sees* — they belong to a cohort, so they read its timetable as a student, and they show up in `cohort_unstreamed_members` when it is split, because they need assigning to a lecture group like anyone else.

### Signup is a claim, not a creation

Since `0017`–`0019`, an account cannot invent an identity. The institution pre-declares who exists in `student_roster` (§4), and the flow is:

```
registration number + full name
  → roster match?  no  → ONE generic message
                   yes → set up credentials
                           university email (OAuth) → bound, verified
                           password                 → bound, provisional
```

A freshly created `auth.users` row produces a `public.users` row with a name, possibly an email, and **nothing else** — no registration number, no cohort. Post-`0014` that account can see almost nothing, which is the correct resting state for someone who hasn't proved who they are. `claim_roster_row()` is the only way out of it.

**The rule everything rests on:** on the OAuth branch, the address the provider returns must parse back to the registration number the student typed. Mismatch is refused. Without this the roster is decorative — anyone could type a classmate's number and then authenticate with their own Google account.

**No school address is ever generated or stored.** The derivation runs one way only, in `reg_number_from_email()`: it reads an address a provider already proved and works out which roster row it describes, then discards the derived string. Generating an address *from* a registration number and storing it would set `email_verified_at` on a string match, faking the one signal that means anything.

Failures say one thing and one thing only — never distinguishing "no such registration number" from "that name doesn't match". The roster is exactly the name+number pairs an attacker needs, so a distinguishing error is an enumeration oracle over it. The cost is a worse message for a student with a typo, which is why the message points at a human who can look it up.

**The password branch is unauthenticated, and that is a deliberate accepted trade.** There is no channel to verify against; SMS, rep-issued claim codes and a private roster field were all considered and rejected. So a classmate genuinely *can* claim an unclaimed row — `06_claim_and_takeover_test.sql` asserts that it succeeds. The answer isn't prevention, it's that the claim is worthless: when the real owner signs in with the university address that proves the identity, the row rebinds to them (`claim_method` upgrades `provisional` → `oauth`) and the squatter's account goes inert — it keeps its notifications, loses its cohort, and can see nothing. Damage is bounded because student accounts are read-only, so the harm was only ever *denying someone their own account*, and takeover undoes it.

Two things are never automatic. A takeover that would unseat a **class rep** raises instead, because auto-evicting one would strip a cohort's scheduling authority mid-semester on a signup event; and nothing at all displaces an existing `oauth` claim. Both route to `resolve_roster_dispute()` — faculty rep, physical ID check, out of band, mandatory audit row.

### Two signup paths, one users table

- **Registration number + password**: Supabase Auth requires a real email as the identity, so the client signs up with a *synthetic* address (`<reg_number_with_dots>@auth.internal`). `users.email` stays `NULL` — never store the synthetic address there. Claims made this way are `provisional`.
- **University email OAuth (Google)**: real address captured immediately, `email_verified_at` set at signup. Configured and live as of `R.1`; credentials come from `supabase/.env` via `env()` substitution, which is why `config.toml` is safe to commit. Claims made this way are `oauth`.

**Verification remains a trust badge with no permissions attached** — an unverified student can do everything a verified one can, and scheduling authority is still gated entirely by the promotion chain (§2). It gains exactly one consequence, via `promote_class_rep` (`TODO.md` §1.4, shipped in `0022`): a target whose roster claim isn't `oauth` requires the Faculty Rep to pass `p_identity_attested => true`, attesting they physically verified the person, recorded on `role_audit_log`. Deliberately not a hard block — that would stop a first-year cohort ever having a rep.

### Three fields, three meanings, no overlap

| Field | Meaning |
|---|---|
| `auth.users.email` | Login identity. Synthetic for password accounts, the real university address for OAuth accounts. |
| `public.users.email` | The university address. **Identity.** Written only by OAuth, never derived. |
| `user_recovery_email.email` | Delivery channel for password reset. No identity, no auth, no permissions. Its own table — see §4. |

A verified *personal* address proves someone controls that mailbox, not that they are who the roster says. It must never feed `email_verified_at`.

**The invariant to preserve:** `users.reg_number is not null` **iff** that account claimed a roster row. `seed.sql` §9.5 enforces it in the dev dataset; an account carrying a registration number it never proved is the pre-`0017` state this whole design exists to delete.

**One consequence for this document:** once Phase R lands, "verification has zero effect on permissions" becomes *almost* true. It gains exactly one: promoting a student to class rep surfaces their verification state, and an unverified target requires the Faculty Rep to explicitly attest they physically verified the person. Not a hard block — that would stop a first-year cohort ever having a rep.

## 11. Known gaps / explicitly deferred (don't assume these are accidental oversights)

**Resolved by `0022` (Phase 1), kept here as a pointer rather than deleted — see §4/§5/§8 for what shipped:** attendance confirmation, recurrence materialization, the edit path (`update_event`), and `promote_class_rep`. All four had no code path before that migration; `tests/07_phase1_test.sql` is their dedicated coverage.

**Resolved by `0023`–`0024` (Phase 2), same treatment:** the missing unique constraints; the `ON DELETE` chain that made an account holding scheduled lectures undeletable (all five blocking columns are now `SET NULL`, with `event_audit_log.changed_by_name` retaining the actor's name so the trail survives — filled by a trigger, so none of the ten functions that write audit rows had to change); ambiguous cohort names; the half-filtering `events_current`; unlogged demotions; and the `events.recurrence_rule` / `cohorts.join_code` dead columns. Coverage is `tests/08_phase2_test.sql`.

**Known-weak, still open:**

- `create_event` accepts **any** cohort ids university-wide with no relationship check and no rate limit. Since `'proposed'` reserves each attached cohort's slot, one rep can blanket another cohort's calendar and block their scheduling until each proposal is declined individually. **Considered and explicitly not fixed** (`TODO.md` §1.6, decided 2026-08-01): a same-programme/same-faculty constraint would break legitimate cross-faculty combined lectures without even closing the hole. The decline is the control; proposal expiry is the better fix if this is ever actually exploited — `send_confirmation_nudges()` (`0033`) is a `pg_cron` job that could carry a second, unrelated check like this, but doesn't yet.
- **Password recovery (`R.5`, `0031`) works, but only in Axene's sandbox mode** — verified with a real send, `202` and a real `message_id`, through the actual Edge Functions. Sandbox only delivers to the workspace's own members, though, so a **verified real domain on Axene is still required before this can reach an actual student's mailbox.** Not a code gap — `AXENE_SENDER_EMAIL` just needs to point at a verified domain address once one exists.
- 17 non-blocking Advisor warnings as of `0008`, never triaged and now stale — regenerate rather than working from the old list.
- **Push delivery (`3.1`, `0034`) — everything is now verified except a real device.** The SQL half (`device_tokens`, `register_device_token`'s reassignment rule, `claim_pending_pushes`'s claim/stamp/idempotency) is pgTAP-tested. The full local pipeline — `pg_cron` → `invoke_push_dispatch()` → `net.http_post` → `functions/dispatch-push` → `claim_pending_pushes()` — runs end-to-end. With a real Firebase project's `FCM_SERVICE_ACCOUNT` configured (`supabase/.env`, gitignored), a manual test against a fabricated token exercised the entire crypto/OAuth path live: PEM parsing, RS256 JWT signing, the `oauth2.googleapis.com` token exchange, and an authenticated call to `fcm.googleapis.com/v1/.../messages:send` — which correctly came back `400 INVALID_ARGUMENT` (fake token format) rather than `UNREGISTERED`, and the error-classification logic correctly left the `device_tokens` row alone rather than deleting it. **The one thing that can't be checked without a Flutter client: a real registration token producing an actual `sent` result and, eventually, a real `UNREGISTERED` response to confirm the cleanup path deletes on that exact case.**

**Deliberately out of scope:** joining an already-scheduled combined lecture after the fact; lecturer accounts (free text in `events.lecturer_name`, they never log in); faculty-wide analytics; a web app; self-service join codes (§4).

## 12. If you're extending this schema

- New privileged mutation → new `SECURITY DEFINER` function with the `auth.uid()` + scoped-role check pattern from §8. Don't add a permissive RLS policy as a shortcut.
- New function → **`REVOKE EXECUTE FROM PUBLIC, anon` then `GRANT` explicitly.** Revoking from `anon` alone does nothing (§8).
- **`CREATE OR REPLACE` discards `proconfig`.** If you replace the body of a `SECURITY DEFINER` function that `0008` pinned with `alter function ... set search_path`, you must restate `set search_path` in the new definition or you silently un-pin it and reopen the escalation vector. This bit `handle_new_auth_user` in `0019`; `00_access_control_test.sql` caught it.
- New function → **write a test in the same session.** The suite has now paid for itself four times: `02_trust_chain_test.sql` found a privilege-escalation bug that reading the code had missed; all four dormant bugs `0014`–`0016` fixed would have been caught by a single `create_event` call; `00_access_control_test.sql` caught both the `anon` leak below and the `search_path` regression above.
- New enum value on an *existing* type → check whether anything in the same migration references it; if so, split it into its own file first (`0009`/`0011`). Creating a *new* enum type and using it immediately is fine — the restriction only applies to `ALTER TYPE ... ADD VALUE`.
- Retiring a column → **three steps, in three parts, never two.** Deprecate (drop `NOT NULL`), then stop every writer referencing it, then drop it. `0021` §3 → `0022` §6 did this for `events.course_id`; `0023` §0 → `0024` §4 did it for `cohorts.join_code`. **A writer cannot stop writing a `NOT NULL` column while it is still `NOT NULL`** — omitting it from an INSERT fails immediately, so "stop writing this column" is not a pure behaviour change until the loosening lands. Check `is_nullable` before assuming otherwise; Phase 2 assumed and was wrong.
- New table → **RLS and GRANTs are two different mechanisms and you need both** (§13).
- Changing any table shape → update the Dart models in the Flutter repo in the same work session; there's no generated-types safety net catching drift here.
- Prefer several themed migrations over one big one, written that way from the start. `0014` reached 1,429 lines before being split into three.

## 13. RLS, privileges and guard triggers — three separate mechanisms

The part that's easiest to get wrong. A row is only reachable if **all three** allow it, and they fail in completely different ways.

### 13.1 Table privileges are not RLS

`0001`–`0013` enabled RLS on 14 tables and wrote policies for all of them, but **never `GRANT`ed anything on any table to anyone.** A policy narrows what a role may touch; a grant is what lets it touch the table at all. With RLS alone, nothing in this schema was readable — every client query failed on permissions before a policy was ever consulted.

`0014` fixes this by clearing the inherited grants (`revoke all on all tables in schema public from anon, authenticated`) and handing back exactly what each policy needs:

- `SELECT` on reference data, profiles, events, `event_cohorts`, `event_audit_log`, `events_current`
- `INSERT, UPDATE, DELETE` on `departments, programmes, courses` (faculty rep territory)
- **Column-level** `UPDATE` grants elsewhere — `(name, current_semester, pace)` on `cohorts`, `(first_name, last_name, middle_name)` on `users`, `(read_at)` on `notifications`
- `SELECT, INSERT` on `cohort_join_requests`
- everything to `service_role`

The column-level grants matter: they enforce at the privilege layer what 13.3's triggers enforce at the trigger layer, and **Postgres checks them before the trigger ever runs.** Belt and braces, deliberately.

**This is not a one-time cleanup — every new table has to do it again.** Supabase ships default privileges that grant on newly created tables in `public` to `anon` and `authenticated`, so a table arrives with privileges nobody asked for. `0017`'s three tables all did, including `anon` on `student_roster`, the one table in this schema that must never be readable. Always `revoke all ... from anon, authenticated` before granting. `00_access_control_test.sql` fails if you forget.

### 13.2 A policy can't reference its own table

`event_cohorts`' SELECT policy referenced `event_cohorts`. A policy expression is itself subject to RLS on every table it touches, so that's a self-reference and Postgres raises `42P17` rather than looping. Because the `events` and `event_audit_log` policies both reach into `event_cohorts`, that single error **took the entire calendar read path down.**

The fix is the escape hatch `current_app_user()` already used: put the lookup in a `SECURITY DEFINER` function, which runs as the table owner and isn't subject to the policy. Hence `user_can_see_event(p_event_id uuid)` — and routing `events`, `event_cohorts` and `event_audit_log` all through **one** helper means "who can see this event" is defined in exactly one place instead of three copies of the same join drifting apart.

If you add a policy that needs to join, reach for a definer function. Don't inline the join.

### 13.3 Self-service UPDATE policies need column guards

`users_update_own_profile` let any student UPDATE their own row with **no column restriction** — so a student could set their own `role = 'class_rep'` and `cohort_id` to any cohort in the university. That is precisely the thing §2 exists to prevent, reachable with one PATCH. `cohorts` and `notifications` had the same shape of hole.

`0014` adds three `BEFORE UPDATE` triggers — `guard_users_self_update`, `guard_cohorts_rep_update`, `guard_notifications_update` — that raise if a protected column changed. Each repeats the `current_user in ('authenticated','anon')` test inline rather than factoring it into a helper, precisely *because* they run as the invoker: a shared helper would need EXECUTE granted to `authenticated`, which is a grant this migration otherwise spends its whole length taking away.

`service_role` passes straight through all three.

### 13.4 Watch for authority carried sideways

Found by the trust-chain tests, not by reading the code: a student already holding `class_rep` in cohort A could request to join cohort B, and approval **carried their role across** — making them a class rep of a cohort that never elected them, reached sideways through a student-initiated request. `0016` fixes it by refusing rather than silently demoting, since DISCOVERY is explicit that rank hand-off is always a manual Faculty Rep action.

The general lesson: when checking authority, ask "for *this* cohort?" and not just "does this user hold this role somewhere?"

## 14. Runbook — bootstrapping the first Faculty Rep

The trust chain is top-down (§2) and this is its root: a Faculty Rep is installed by the
Superadmin, out of band, and every Class Rep and Student below them derives authority from
that one act. `0032` provides `bootstrap_faculty_rep(p_user_id, p_faculty_id)`; this is how
a human invokes it.

**Superadmin is not an account.** It has no `users` row and is not a `user_role` value —
it is the `service_role` key (§10). Holding that key *is* the authorization, which is why
`bootstrap_faculty_rep` takes no `p_acting_user` and checks nothing against `auth.uid()`.
Guard the key accordingly.

**A Faculty Rep is a student.** Both elevated roles are — a class rep and a faculty rep are
students carrying more responsibility, keeping the same university address and registration
number they already had. So there is usually **no account to create**: the person already
has one, from signing up like any other student. Promotion sets `role` and `faculty_id` and
touches nothing else, so their `reg_number`, `cohort_id` and claimed roster row all survive
— they still belong to a cohort and still see its timetable, because they still attend it.

**1. Find (or create) their account.** Normally they already have one — look up the
`users.id` for their registration number. Only if they genuinely have no account yet do you
create one, via the Supabase dashboard (Authentication → Users → Add user) or the admin API,
exactly as an ordinary student signup would: either OAuth on their university address, or
the reg-number/password path. `handle_new_auth_user` (`0019`) fires on insert and builds
their `public.users` row as a plain `student`.

**2. Install them.** With the service-role key:

```sql
select bootstrap_faculty_rep(
  '<the new user id>'::uuid,
  '<the faculty id>'::uuid
);
```

It validates that the user exists, the faculty exists, and the target is a plain
`student`; sets `role` and `faculty_id` **and nothing else** — `reg_number`, `cohort_id`
and their roster claim are deliberately left alone; fills `email` from `auth.users` if it
is still null (which the sync trigger skips for non-OAuth signups, and never with a
synthetic `@auth.internal` address); and writes a `role_audit_log` row. Re-running it
against the same faculty is a no-op, so it is safe to repeat if you are unsure the first
call landed. Re-pointing an existing Faculty Rep at a *different* faculty is refused —
that would move a trust anchor and leave cohorts scoped to a rep who can no longer
administer them.

**What it deliberately does not do:** set `email_verified_at`. That field has exactly one
legitimate writer — the OAuth path, from a provider-proven address — which is why
`mark_email_verified` was dropped rather than hardened (`0019`). Nothing is lost: a rep who
signs in with Google gets it set correctly by the sync trigger, and verification is a trust
badge, not a functional gate (§2). `faculty_id` is what `0016` actually checks before
letting them create a cohort; a Faculty Rep with a null one is inert, which is the failure
this runbook exists to prevent.

**3. Verify.** They should now be able to call `create_cohort_with_class_rep` for a
programme in their own faculty, and be refused for any other — the check in `0016`.
