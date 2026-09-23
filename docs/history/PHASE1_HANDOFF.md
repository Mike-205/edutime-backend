# Phase 1 handoff — what `0022` has to do

Written 2026-08-01, mid-Phase-1, so this can be picked up cold.

`0020` and `0021` are **done and applied**; `db reset` is clean and the suite is
**144/144 across 7 files**. Everything below is the remaining work, which all lands in
one migration: **`0022_event_api.sql`**.

Read `TODO.md` §0.1 and §1.1–§1.7 alongside this. This file is the *how*; the TODO is
the *why*.

---

## State you are starting from

| Migration | Status | What it left you |
|---|---|---|
| `0020_phase1_enums.sql` | applied | `audit_action += confirmed, unconfirmed`; `notif_type += attendance_confirmed, attendance_unconfirmed` |
| `0021_terms_and_per_cohort_course.sql` | applied | `term_bounds(date, cohort_pace)`; `event_cohorts.course_id` **nullable**; `events.course_id` **nullable + deprecated** |

Two things are deliberately left half-open and **`0022` must close both**:

1. `event_cohorts.course_id` → set `NOT NULL` *after* the new `create_event` populates it.
2. `events.course_id` → `DROP COLUMN` *after* no function writes it any more.

Both were deferred because `0015`'s `create_event` is the live definition until `0022`
replaces it. Structure cannot outrun the function that maintains it — tightening either
end early applies fine against the empty table at migration time and then fails on the
first seed run. That already happened once; don't repeat it.

---

## Decisions already made (do not re-litigate)

- **Terms are derived, never stored.** `cohorts` gets no date columns. `term_bounds()`
  is a pure function of date + pace.
- **Pace matters.** trimester = three terms; bimester = **two** (Jan–Apr, Sep–Dec).
  `term_bounds` returns `(null, null)` for a bimester cohort in May–Aug.
- **`term_bounds` gates recurrence only.** A one-off lecture in the break is legitimate
  (make-up classes). Do not consult it when `p_recurrence = 'none'`.
- **Un-confirming is allowed** (reversed from the earlier "one-way" decision).
- **Recurrence is refused for combined lectures** — out of scope, and it means the
  initiating cohort's pace is always the unambiguous source for the ceiling.
- **All-or-nothing on a recurrence clash.** One transaction, so this is also the cheap
  option; skip-and-report would need per-occurrence savepoints.
- **A rescheduled occurrence stays in its series** (`reschedule_event` already copies
  `recurrence_group_id`).
- **Per-cohort course** on `event_cohorts`, because cross-faculty combined lectures are
  explicitly in scope and `courses` is programme-scoped.
- **§1.6 is dropped.** No programme/faculty constraint on who a rep may propose to, and
  no rate limit. See "Accepted risks" at the bottom.
- **§1.5 is dissolved** — `mark_email_verified` was dropped in `0019`, not hardened.

---

## `0022_event_api.sql` — the work

Suggested section order. Everything is `SECURITY DEFINER` with
`set search_path = public` and the `p_acting_user = auth.uid()` check, per
`TECHNICAL_DISCOVERY` §8.

### §1 — `create_event` rewrite (§1.2, §1.3, §1.7)

The signature changes substantially. Current:

```sql
create_event(p_cohort_ids uuid[], p_venue_id uuid, p_course_id uuid,
             p_lecturer_name text, p_start timestamptz, p_end timestamptz,
             p_recurrence recurrence_type, p_recurrence_rule text,
             p_acting_user uuid)
```

Target:

```sql
create_event(
  p_attachments   jsonb,        -- [{"cohort_id": "...", "course_id": "..."}, ...]
  p_venue_id      uuid,
  p_lecturer_name text,
  p_title         text,         -- NEW (§1.3). Currently hardcoded to null.
  p_start         timestamptz,
  p_end           timestamptz,
  p_recurrence    recurrence_type,
  p_until         date,         -- NEW (§1.2), nullable. See below.
  p_acting_user   uuid
)
```

`p_course_id` and `p_recurrence_rule` both go away — the course is per-attachment now,
and the rule is redundant once occurrences are materialized from the enum + horizon.
Use the `jsonb` array shape rather than parallel `uuid[]`s; it is self-describing and
matches `roster_bulk_import`'s existing convention.

**Keep every existing guard** from `0015`: dedupe cohort ids, reject an empty array,
require the acting rep's own cohort to be present, verify every cohort exists, and keep
the `::cohort_confirmation_status` cast (that missing cast is why `create_event` never
once ran between `0010` and `0015`).

**New validation:**

- Every attachment needs a `course_id`, and it should belong to that cohort's programme.
  Reject a course from an unrelated programme — that is the bug §1.7 exists to fix, and
  it would be perverse to allow it through the new API.
- `p_title` may be null (falls back to the course name in the UI); trim it if given.

**Recurrence (§1.2), only when `p_recurrence <> 'none'`:**

1. Refuse if more than one attachment — recurring combined series are out of scope.
   *(Still true of the code as shipped, but the scope call behind it was **reversed on
   2026-08-20** — see `TODO.md` §S.4. Lecturers here really do take two programmes
   together for a whole semester. The refusal stays until series-level confirmation
   replaces it.)*
2. Look up the initiating cohort's `pace`; call `term_bounds(p_start::date, pace)`.
3. If `term_end is null`, refuse: the cohort has no teaching term containing that date
   (a bimester cohort in the May–Aug break).
4. `horizon := least(coalesce(p_until, term_end), term_end)` — `p_until` is the rep's
   real last teaching date, the term end is the hard ceiling.
5. Refuse if `p_start::date > horizon`.
6. Generate one `events` row per occurrence, stepping by the enum
   (`day` → `1 day`, `week` → `1 week`, `month` → `1 month`), while
   `occurrence_start::date <= horizon`. Every row shares one generated
   `recurrence_group_id`.
7. Each occurrence gets its own `event_cohorts` row(s) and its own audit row.
8. **All-or-nothing.** Both EXCLUDE constraints fire naturally inside the transaction;
   catch `exclusion_violation` and re-raise naming the clashing date, so the client gets
   something actionable instead of a raw `23P01`.
9. Return the `recurrence_group_id` (or the first event id — pick one and document it).

Sanity-cap the loop (e.g. 200 occurrences) so a bad `p_recurrence`/`p_until`
combination can't spin.

### §2 — `cancel_recurrence_group` (§1.2)

```sql
cancel_recurrence_group(p_group_id uuid, p_acting_user uuid)
```

Initiating cohort's rep only. Cancels every event in the group, **including
occurrences that were individually rescheduled** — they keep their
`recurrence_group_id`, which is precisely why cancelling the series must reach them.
One notification per cohort, not one per occurrence. Audit row per event.

### §3 — `update_event` (§1.3)

```sql
update_event(p_event_id uuid, p_title text, p_lecturer_name text,
             p_course_id uuid, p_acting_user uuid)
```

Changes `title`, `lecturer_name`, and the **calling rep's own** `event_cohorts.course_id`
(not other cohorts' — each cohort owns the unit it attends as). Time and venue changes
stay with `reschedule_event`. Writes an `'updated'` audit row and broadcasts `updated`.
Initiator-only, and refuse on a `canceled` event.

### §4 — `confirm_attendance` / `unconfirm_attendance` (§1.1)

**The headline feature. It has no code path at all today** — `attendance_status` can
never leave `'pending'`, which makes `attendance_confirmed_by`,
`attendance_confirmed_at`, `notif_type = 'confirmation_needed'` and
`events_pending_confirmation_idx` all dead weight, and means the lecturer-reliability
story that motivates the whole product does not work.

```sql
confirm_attendance(p_event_id uuid, p_acting_user uuid)
unconfirm_attendance(p_event_id uuid, p_acting_user uuid)
```

- Class rep of **any attached cohort** (not just the initiator — any rep may have made
  the call).
- Event must be `status = 'scheduled'`. Refuse on `proposed`, `canceled`, `rescheduled`.
- `confirm` sets `attendance_status='confirmed'`, `attendance_confirmed_by`,
  `attendance_confirmed_at`; `unconfirm` clears all three back to `'pending'`.
- Audit `'confirmed'` / `'unconfirmed'`; notify every attached cohort with
  `attendance_confirmed` / `attendance_unconfirmed`.
- `events` has no client UPDATE policy or privilege — that is intentional, so this must
  go through the function, exactly like every other mutation.

### §5 — `promote_class_rep` (§1.4)

```sql
promote_class_rep(p_user_id uuid, p_rank class_rep_rank,
                  p_acting_faculty_rep uuid, p_identity_attested boolean)
```

The assistant rank is currently unreachable from inside the app; `seed.sql` does it with
a direct UPDATE as `postgres`. Same faculty scoping as its siblings
(`create_cohort_with_class_rep`, `demote_class_rep` — copy the pattern from `0016` §1).
Target must be a `student` in a cohort inside the acting rep's faculty. Respect
`enforce_max_class_reps` (max two) and rank uniqueness.

**The attestation** (from `0.5`): the faculty rep sees a *name* in a list and cannot tell
the account behind it was claimed provisionally by someone else. So:

- If the target's roster claim is `oauth`, proceed normally.
- If it is `provisional` (or absent), require `p_identity_attested = true` — the rep
  confirming they physically verified this person — and record it on the audit row.
- **Not** a hard verified-only rule: that would stop a first-year cohort ever having a
  rep, since nobody has a university mailbox yet.

### §6 — Close the two open ends

Only after every function above is redefined:

```sql
alter table event_cohorts alter column course_id set not null;
alter table events drop column course_id;
```

`reschedule_event` copies the old event row — it must now also carry over each
attachment's `course_id`, and must **stop** referencing `events.course_id`. Check it
before dropping.

`events_current` is `select *`, so it adapts on its own. `events_course_idx` on
`events(course_id)` disappears with the column; `event_cohorts_course_idx` already
exists.

### §7 — Grants

Every new function: `revoke execute ... from public, anon` then `grant ... to
authenticated, service_role`. Revoking from `anon` alone is a **no-op** — the implicit
`GRANT ... TO PUBLIC` at creation time is what actually holds the privilege. This is the
mistake `0008`/`0010`/`0012`/`0013` all made and `0014` §3 had to undo.

---

## Seed and tests

**`seed.sql`** will break — it calls `create_event` positionally with `p_course_id`.
Update §11 ("The timetable") to the new `jsonb` attachment shape. Consider adding one
recurring series so the dev dataset exercises materialization, and at least one
confirmed-attendance event so the headline feature has visible data.

**New test file `07_phase1_test.sql`.** Existing tests call `create_event` positionally
and will need their calls updated (`02`, `03`, and `04` all do). Cover:

- N occurrences created, bounded by the horizon; all share one `recurrence_group_id`
- `p_until` earlier than the term end is respected; later than it is clamped
- recurrence refused for a bimester cohort starting in May–Aug (`BSC-CS 2023` is
  bimester; `BSC-CS 2024` is trimester — use both)
- recurrence refused when more than one cohort is attached
- one clashing week aborts the entire series, and the error names the date
- `cancel_recurrence_group` also cancels a previously rescheduled occurrence
- per-cohort courses: two cohorts on one combined lecture see different `course_id`s
- a course from an unrelated programme is refused
- `update_event` changes fields, writes an `'updated'` audit row, refuses a non-initiator
- confirm → state transition, audit row, broadcast; refused on `canceled`/`proposed`;
  allowed for a non-initiating attached rep
- unconfirm returns to `'pending'` and clears `attendance_confirmed_by/at`
- `promote_class_rep`: works, cross-faculty refused, third rep refused, rank uniqueness,
  and a provisional-claim target refused without `p_identity_attested`

---

## Traps this codebase has already sprung

Four of these have bitten during this work. They are cheap to avoid and expensive to
find.

1. **`CREATE OR REPLACE` discards `proconfig`.** Restating the body of a function `0008`
   pinned drops its `set search_path` and silently reopens a `SECURITY DEFINER`
   escalation vector. `00_access_control_test.sql` catches it.
2. **New tables arrive with `anon` privileges.** Supabase's default privileges grant on
   creation. Always `revoke all ... from anon, authenticated` before granting.
3. **`ALTER TYPE ... ADD VALUE` cannot share a transaction with anything using the
   value.** That is why `0020` exists as its own file. If `0022` needs another enum
   value, it needs another isolated migration before it.
4. **A `CASE` over quoted literals is `text`, not the target enum.** A bare literal in an
   INSERT coerces fine; wrapped in a `CASE` it does not. This is the bug that meant
   `create_event` never once ran between `0010` and `0015`. Keep the explicit
   `::cohort_confirmation_status` cast.
5. **Structure cannot outrun its writer.** See the top of this file.

---

## Accepted risks (decided, not oversights)

- **Proposal griefing is not mitigated.** A `'proposed'` event reserves each attached
  cohort's slot via the `event_cohorts` EXCLUDE constraint, and `create_event` accepts
  any cohort ids university-wide. So a rep can blanket another cohort's calendar with
  proposals and block their scheduling until each is declined individually. A
  programme/faculty constraint was considered and **rejected** — it would break
  legitimate cross-faculty combined lectures, which are explicitly in scope, while only
  partially mitigating the attack. A rate limit was considered and deferred. The decline
  is the control. Revisit if it ever actually happens; proposal expiry (needing a
  scheduled job, so Phase 3 alongside §3.2) is the better fix than a cap.
- **`bimester` term boundaries are as described but unverified with the registrar.**
  Jan–Apr and Sep–Dec, no May–Aug. If wrong, `term_bounds` is the single place to fix.

---

## After Phase 1

- **`R.5`** — recovery email delivery. Blocked on the Edge Function and mailer in §3.1.
- **Phase 2** — data integrity (§2.1–§2.6), all cheap and all harder once there is real
  data.
- **§0.4 again** — `TECHNICAL_DISCOVERY.md` will need §4 (recurrence now built, terms,
  per-cohort course), §5 (attendance now has a code path), §8 (the new API surface) and
  §11 (gap list) updating. It is the document someone picks this up cold from.
- **Flutter** — Dart models are hand-written with no generated-types safety net, so
  every signature above needs mirroring by hand (§4.3).
