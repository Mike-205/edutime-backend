# Phase 2 handoff — data integrity and retention

Written 2026-08-20, at the start of Phase 2, so this can be picked up cold.

> **EXECUTED 2026-08-20.** `0023` and `0024` are written and applied; `db reset` is clean
> and the suite is **239/239 across 9 files**, with `tests/08_phase2_test.sql` covering
> everything below. Kept as the record of *why* the two migrations are shaped this way.
>
> **One correction to what this document originally said.** It claimed
> `cohorts.join_code` was nullable, so `0023` could stop writing it without touching
> structure. It is `not null unique` (`0001`), and omitting a `NOT NULL` column from an
> INSERT fails immediately — `db reset` caught it on the first run. **"Stop writing this
> column" is not a pure behaviour change when the column is NOT NULL.** `0023` therefore
> opens with a §0 that drops the `NOT NULL` and nothing else, which is exactly the
> deprecate → stop-writing → drop dance `0021` §3 did for `events.course_id` one phase
> earlier. The split survived; it just gained one loosening, which is always the safe
> direction. The section below is left as originally written, with the error struck
> through, because the mistake is instructive: it is the same "check the column, don't
> assume it" lesson the rest of this file preaches.

Phase 1 is **done and applied**; `db reset` is clean and the suite is **207/207 across 8
files**. Everything below is Phase 2, which lands in **two migrations**:
**`0023_naming_and_role_audit.sql`** (behaviour) and
**`0024_integrity_and_retention.sql`** (structure), in that order.

Read `TODO.md` §2.1–§2.6 alongside this. That list is the *why*; this file is the *what
is actually true now*, and in four places the two disagree — see "Where TODO.md is out of
date" below. **This file wins**: every claim in it was checked against the live schema on
2026-08-20.

---

## State you are starting from

| Migration | Status | What it left you |
|---|---|---|
| `0020_phase1_enums.sql` | applied | `audit_action += confirmed, unconfirmed`; `notif_type += attendance_confirmed, attendance_unconfirmed` |
| `0021_terms_and_per_cohort_course.sql` | applied | `term_bounds(date, cohort_pace)`; `event_cohorts.course_id` |
| `0022_event_api.sql` | applied | The whole event API: recurrence, attendance, `update_event`, `promote_class_rep`, `role_audit_log`; `events.course_id` dropped |

None of Phase 2 blocks the Flutter client. All of it gets harder once there is production
data, which is the entire reason it goes now.

---

## Where TODO.md is out of date

Four corrections, all verified against the running database. They are not nitpicks — two
of them change what the migration does.

1. **§2.3 names two columns. There are five.** `events.created_by` (RESTRICT),
   `events.updated_by` (RESTRICT), `event_audit_log.changed_by` (RESTRICT),
   `event_cohorts.decided_by` (NO ACTION) and `events.attendance_confirmed_by`
   (NO ACTION). **`NO ACTION` blocks a delete exactly as hard as `RESTRICT`** — the only
   difference is when the check fires — so listing only the two that say the word
   "restrict" understates the problem by three columns.

2. **`events.attendance_confirmed_by` only became a blocker in `0022`.** Before that no
   function could write it, so it was never populated and never blocked anything. Phase 1
   made it reachable; Phase 2 inherits it.

3. **§2.1's proposed cohort key is wrong.** It says
   `(programme_id, intake_year, current_semester, pace)`. `TECHNICAL_DISCOVERY` §4 says a
   cohort is "one per programme+intake-year+**pace** combination" — no semester — and §4
   is right. `current_semester` is *mutable progression state*: it sits in `0014`'s
   column-level UPDATE grant precisely so a cohort can advance. Put it in the identity key
   and advancing a cohort vacates its slot, letting a second cohort be created in the hole
   the first one just left. **Use the three-column key.** Verified: zero violations in the
   current dataset either way.

4. **§2.1 is already half done.** `programmes.code` and `student_roster.reg_number` were
   pulled forward into `R.2` and are unique today. Four remain.

---

## Decisions already made (do not re-litigate)

- **`events_current` keeps existing, with the predicate finished.** It filters
  `rescheduled` but not `canceled`; it will filter both. Considered and rejected: dropping
  it. It has *zero readers* anywhere in the repo today, which made dropping tempting and
  cheap — but the view is the intended client convenience surface and Flutter has not been
  written yet, so the moment to define it properly is before anyone depends on it, not
  after.
- **All five `ON DELETE` columns get fixed, and the retained name is filled by a trigger,
  not by its ten callers.**
- **The audit `snapshot` contract moves to match the code, not the other way round.**
  Every writer passes a small action-specific object; the documentation in `0004` claims
  full event state. The code is right — the full row is still on `events` to join to, and
  copying it into every audit row is bloat that also goes stale against schema changes.
  **Fix the comment.**
- **`events.recurrence_rule` and `cohorts.join_code` both get dropped.** Both are dead:
  `recurrence_rule` has zero non-null rows and lost its parameter in `0022`; `join_code` is
  permanently superseded by the roster (`0.5`).
- **`demote_class_rep` gets wired into `role_audit_log`.** `0022` created that table with
  `role_action = {promoted, demoted}` and only ever wrote `promoted`. Demotion strips a
  cohort's scheduling authority and currently leaves no trace — the exact gap `0022`'s own
  header says the table exists to close.
- **No unique constraint on `cohorts.name`.** Once §1 below makes the name a faithful
  rendering of the three-column identity key, name uniqueness follows from that key for
  free. A second constraint enforcing a derived property would just be another thing to
  keep in sync.

---

## `0023_naming_and_role_audit.sql` — behaviour first

**Why behaviour first.** `0024` drops `events.recurrence_rule` and `cohorts.join_code`,
and three live functions still reference them:

| Function | References |
|---|---|
| `create_cohort_with_class_rep` | writes `join_code` |
| `guard_cohorts_rep_update` | names `join_code` as a protected column |
| `reschedule_event` | copies `recurrence_rule` forward |

Drop a column out from under a function and it raises **at runtime, not at migration
time** — it applies clean and then dies on the first seed run. This is the same trap
`0021` deferred work to avoid and `0022`'s §6 was ordered around. **Structure cannot
outrun its writer**, so the writers move first, in their own file, leaving nothing broken
in between.

*As built,* `0023` also carries a §0 dropping `cohorts.join_code`'s `NOT NULL` — the one
structural change in the file, and a loosening only. A writer cannot stop writing a
`NOT NULL` column while it is still `NOT NULL`, so that one deprecating step has to travel
with the writer rather than with the drop. Same three-step shape as `0021` §3 →
`0022` §6 for `events.course_id`.

### §1 — `create_cohort_with_class_rep` (§2.2)

Two changes to one INSERT.

**The name.** Currently `v_programme_abbr || ' ' || p_intake_year`, i.e. `BSC-CS 2023`,
which omits pace — so two cohorts of the same programme and intake on different paces get
**identical names**. Add the pace:

```
BSC-CS 2023 (bimester)
BSC-CS 2023 (trimester)
```

**Do not put `current_semester` in the name.** Same reason it does not belong in the
identity key: it changes, and a name embedding it goes stale the moment a cohort advances
— the exact staleness problem `0021` chose a derived `term_bounds()` over stored dates to
avoid. Programme, intake year and pace are all immutable for the life of a cohort.

The exact format matters less than that it is unambiguous — `programme_id`, `intake_year`
and `pace` are all columns on the row, so a client that wants something terser can compose
its own. The stored name is for cheap display and log lines.

**Stop writing `join_code`.** Remove it from the column list and drop the
`encode(extensions.gen_random_bytes(6), 'hex')` expression. ~~The column still exists
until `0024`; it is nullable, so leaving it unwritten is fine in the gap between the two
migrations.~~ **Wrong — it is `not null unique`.** `0023` §0 drops the `NOT NULL` first;
see the correction at the top of this file.

### §2 — `guard_cohorts_rep_update`

Remove `join_code` from the protected-column list. Leave the rest of the guard alone.
Restate `set search_path = public` — see traps.

### §3 — `reschedule_event`

Stop copying `v_old.recurrence_rule` onto the replacement row. Everything else stays
byte-for-byte, including `0013`'s ordering fix (retire the old occurrence *before*
inserting the replacement) and `0022`'s per-attachment `course_id` carry-over. This is the
third time this function has been restated; resist the urge to tidy anything else while
you are in there.

### §4 — `demote_class_rep` writes `role_audit_log`

Insert a `'demoted'` row: `user_id`, `user_name` (denormalized, per the table's own
contract), `cohort_id`, `actor_id`, and a snapshot carrying the rank that was removed.
Read the target's name and rank **before** the UPDATE clears them.

`role_audit_log` already has RLS, privileges and a grant from `0022` — this adds no
structure, only a writer.

---

## `0024_integrity_and_retention.sql` — structure second

**Section order is load-bearing.** Three separate things change the `events` column
list (§3 adds a column, §5 drops one), and `events_current` is a `select *` view, which
Postgres expands into an explicit column list at CREATE time. So the view holds a real
dependency on every column that existed when it was made. Drop the view **before** any
column change and recreate it **once**, at the end. Recreating it in between does not help
— `select *` simply re-expands over whatever is there at that moment and the next change
fails against the new view instead of the old one. `0022` §6 learned this.

### §1 — Unique constraints (§2.1)

Four. All four apply against the current dataset with **zero violations**, so none of them
needs a cleanup step:

```sql
alter table users      add constraint users_reg_number_unique unique (reg_number);
alter table cohorts    add constraint cohorts_identity_unique
  unique (programme_id, intake_year, pace);
alter table faculties  add constraint faculties_abbreviation_unique unique (abbreviation);
alter table buildings  add constraint buildings_abbreviation_unique unique (abbreviation);
```

`users.reg_number` is nullable and stays that way — Postgres allows many NULLs under a
plain `UNIQUE`, and NULL is the correct resting state for an account that has not claimed
a roster row (`TECHNICAL_DISCOVERY` §10's invariant). This constraint is the one that stops
`users.reg_number` and `student_roster.reg_number` drifting apart.

The cohorts key is three columns, not four — see "Where TODO.md is out of date".

### §2 — Notification index (§2.4)

`notifications` has a bare `(user_id)`. The hot queries are the list (newest first) and the
unread badge:

```sql
drop index notifications_user_idx;
create index notifications_user_recent_idx on notifications (user_id, created_at desc);
create index notifications_user_unread_idx on notifications (user_id) where read_at is null;
```

The composite serves the list; the partial serves the badge count and stays small
regardless of history depth, because it only indexes rows that are still unread.

### §3 — Retained attribution, then the `ON DELETE` rework (§2.3)

The goal: deleting an `auth.users` row should succeed. Today it cannot — `users.id`
cascades from `auth.users`, that cascade hits five `RESTRICT`/`NO ACTION` columns, and the
whole delete aborts mid-cascade.

Three of the five are already nullable and convert with a plain FK swap, no other work:

```
events.updated_by               -> SET NULL
event_cohorts.decided_by        -> SET NULL
events.attendance_confirmed_by  -> SET NULL
```

Two are `NOT NULL` and need the `NOT NULL` dropped first. They divide differently, and
**this is a refinement on the "add a retained name to both" plan** — only one of them
actually needs a name:

- **`event_audit_log.changed_by`** is the attribution of record. It needs
  `changed_by_name text`, backfilled from `users`, filled on every future insert by a
  `BEFORE INSERT` trigger, then `NOT NULL` dropped and the FK recreated as `SET NULL`.
- **`events.created_by`** needs **no** name column. Every event already has a `'created'`
  row in `event_audit_log` — written by both `create_event` and `reschedule_event` — and
  that row now carries the retained name. Adding a second copy on `events` would be two
  places to keep in sync for one fact. Just drop `NOT NULL` and recreate the FK as
  `SET NULL`.

**The trigger is the point.** Ten functions insert into `event_audit_log`
(`create_event`, `update_event`, `cancel_event`, `cancel_recurrence_group`,
`reschedule_event`, `confirm_attendance`, `unconfirm_attendance`, `leave_event_cohort`,
`decline_event_cohort`, `confirm_event_cohort`). A `BEFORE INSERT` trigger that fills
`changed_by_name` from `users` leaves **all ten untouched**, one migration after `0022`
rewrote most of them. Editing ten call sites to pass a name they can all look up
themselves would be ten chances to forget one, and a forgotten one produces an audit row
with a null actor *and* no name — strictly worse than today.

Verified before recommending: **no RLS policy anywhere references `created_by` or
`changed_by`**, so dropping `NOT NULL` on either does not disturb the access-control
layer.

The asymmetry between the two groups is deliberate and worth a comment in the migration:
`changed_by` is *history* and must survive the person; `updated_by`, `decided_by` and
`attendance_confirmed_by` are *current-state pointers* whose historical values are already
captured in the audit log, so losing them on deletion loses nothing.

This is the shape `role_audit_log` already uses — `0022` adopted `SET NULL` plus a
retained `user_name` explicitly citing §2.3's proposed fix, so that table is already in the
state this section is moving the older ones into. Copy that pattern.

### §4 — Drop the dead columns

Only after `0023` has stopped every writer:

```sql
alter table events  drop column recurrence_rule;
alter table cohorts drop column join_code;   -- takes cohorts_join_code_key with it
```

### §5 — Rebuild `events_current` (§2.5)

Once, here, after every column change above:

```sql
create view events_current with (security_invoker = true) as
select * from events e
where status in ('scheduled', 'proposed');
```

`status in ('scheduled','proposed')` excludes `canceled` *and* `rescheduled`, which is the
whole fix. The old `or superseded_by is null` clause goes away as dead weight — it existed
to catch a `rescheduled` row that had not been pointed at its replacement yet, and status
alone now excludes those.

`security_invoker` stays on — `0008` removed a security-definer view for exactly the right
reason (the caller's RLS must apply) and `0010` rebuilt this one with it set. **Grants do
not survive `DROP VIEW`**, so restate them — and `revoke all ... from public, anon,
authenticated` *first*. See traps.

### §6 — The snapshot contract (§2.6)

Comment only, no code. Replace `0004`'s "snapshot holds event state (JSON) at the time of
the action" with what is actually true and intended:

> `snapshot` holds the fields relevant to **this action**, not the full event row. Join to
> `events` for full state. Keys vary by action — `created` carries
> `{cohort_ids, initial_status, recurrence_group_id}`, `rescheduled` carries
> `{superseded_by}`, `confirmed`/`unconfirmed` carry `{attendance_status, cohort_id}`, and
> so on.

### §7 — Grants

Any new trigger function: `revoke execute ... from public, anon, authenticated,
service_role`. Trigger functions need no EXECUTE grant at all — the trigger mechanism is
not privilege-gated — so revoking from everyone costs nothing and closes the RPC door.

---

## Seed and tests

**`seed.sql` will break on the cohort rename.** It, and six of the eight test files, use
the cohort *name* as a lookup key — **116 literals** of `'BSC-CS 2023'` and friends across
the repo. This is by far the largest mechanical cost in Phase 2, and it is entirely
self-inflicted by the helpers:

```sql
create or replace function seed_cohort(p_name text) ...
create function pg_temp.cohort(p_name text) ...
```

**Rekey the helpers before touching the name format.** `(programme_code, intake_year)` is
stable, already unique in every dataset here, and reads better at the call site anyway:

```sql
-- instead of  pg_temp.cohort('BSC-CS 2023')
--             pg_temp.cohort('EB1', 2023)
```

Do that as its own step, confirm 207/207 still passes, *then* change the format in `0023`.
Two small diffs that each keep the suite green beat one large diff that breaks 116 call
sites at once and leaves you guessing which failure is real.

`seed.sql` also stops needing to do anything about `join_code` — it never wrote one
directly, `create_cohort_with_class_rep` did.

**New test file `08_phase2_test.sql`.** Cover:

- each of the four unique constraints rejects a duplicate (and `users.reg_number` still
  accepts multiple NULLs — the case a plain `UNIQUE` is being relied on for)
- two cohorts, same programme and intake, different pace: both creatable, **distinguishable
  names**
- deleting an `auth.users` row that created events, confirmed attendance and wrote audit
  rows **succeeds**, and afterwards: the audit row survives with `changed_by` null and
  `changed_by_name` still populated; the event survives with `created_by` null
- the `changed_by_name` trigger fills on insert without any caller passing it
- `events_current` excludes both `canceled` and `rescheduled`
- `demote_class_rep` writes a `'demoted'` row carrying the removed rank, and the demoted
  user's name survives on it
- the dropped columns are gone (a cheap `has_column`/`hasnt_column` pair, which is what
  catches a future migration quietly re-adding one)

---

## Traps this codebase has already sprung

The first four have each cost a debugging session already. They are cheap to avoid and
expensive to find.

1. **`CREATE OR REPLACE` discards `proconfig`.** Restating the body of a function `0008`
   pinned drops its `set search_path` and silently reopens a `SECURITY DEFINER` escalation
   vector. `0023` restates four function bodies, so this applies to all four.
   `00_access_control_test.sql` catches it.
2. **New tables and views arrive with `anon` privileges.** Supabase's default privileges
   grant on creation, and **a view is no exception** — recreating `events_current` in §5
   re-opens it. `revoke all ... from public, anon, authenticated` before granting. This bit
   `0022` and `00_access_control_test.sql` caught it.
3. **Revoking from `anon` alone is a no-op.** The implicit `GRANT ... TO PUBLIC` at
   creation time is what actually holds the privilege. Revoke from `public` first.
4. **Structure cannot outrun its writer.** The whole reason Phase 2 is two files. A
   dropped column breaks its writer at *runtime*, so the migration applies clean and dies
   on the first seed run.
5. **`select *` views pin the column list at CREATE time.** Drop the view before column
   changes, recreate after. Recreating early does not help.

---

## Accepted risks (decided, not oversights)

Expanded 2026-08-20 with effects and mitigations. **One of these turned out not to be a
risk at all but a defect — see 2.**

### 1. A deleted account's events lose their live attribution

**What.** After §3, deleting a user nulls four pointers: `events.created_by`,
`events.updated_by`, `events.attendance_confirmed_by` and `event_cohorts.decided_by`. The
`event_audit_log` row keeps `changed_by_name`, so the *history* survives; the *live rows*
forget.

**Effects.** A "scheduled by —" field renders blank. The attendance badge still reads
confirmed, because `attendance_status` is a separate column and survives — only "who
phoned the lecturer" is lost, and the notification text is generic so no message breaks.
Attribution stays recoverable from the `'created'` audit row.

**The dependency nobody would guess.** `event_audit_log.event_id` is `ON DELETE CASCADE`.
So the audit-log fallback holds **only as long as events are never hard-deleted**. Today
they are canceled, never deleted, so it is sound — but anyone adding a purge or archive
job for old events destroys attribution silently and completely.

**Mitigations.**
- Mark `created_by` nullable in the Dart models (`4.3`), or the client crashes rather than
  degrades.
- If more than one screen needs "who scheduled this", put it in **one** definer function
  (`event_attribution(uuid)`) rather than repeating the audit-log join — the same argument
  that produced `user_can_see_event`.
- Do **not** add `events.created_by_name`. Two homes for one fact is what §3 avoided.
- **Never add an event purge job without revisiting this.**

### 2. `cohorts.name` can silently contradict its own row — a defect, not a tradeoff

**What this entry originally said** was that a rep could rename their cohort misleadingly.
That is true and minor. The real problem is worse and was introduced by `0023`: `0014`
grants `authenticated` UPDATE on `cohorts (current_semester, pace, name)` — and **`pace`
is now baked into a name that is generated once, at creation.**

```
update cohorts set pace='trimester' where name='BSC-ACS 2023 (bimester)';
→  name: BSC-ACS 2023 (bimester)   pace: trimester
```

Demonstrated 2026-08-20. The name actively lies about the row. And because `pace` is also
in `0024` §1's identity key, a rep flipping pace where a twin exists now gets a raw
constraint error leaking an internal name:

```
ERROR:  duplicate key value violates unique constraint "cohorts_identity_unique"
DETAIL: Key (programme_id, intake_year, pace)=(…, 2023, trimester) already exists.
```

**Effects.** Display lies about the cohort. Combined-lecture proposals render cohort
names, so a rep could confirm a proposal believing it involves a different cohort — a mild
social-engineering surface. The client sees a `23505` instead of a sentence. **No data
corruption**: nothing keys on `name` since the seed/test rekey, so this is a trust and
display problem, not an integrity one.

**Mitigations — and this one is scheduled, not accepted.** Folded into `S.2`, because
Phase S rewrites the same naming expression anyway to add the stream; fixing it in a
standalone `0025` first would mean restating
`create_cohort_with_class_rep` twice in consecutive migrations for no gain.
- Make `name` **trigger-maintained** from `(programme, intake, pace, stream)` so it
  recomputes whenever any component changes. Drift becomes structurally impossible rather
  than merely discouraged.
- Drop `name` from the column-level UPDATE grant and add it to
  `guard_cohorts_rep_update`'s protected list. The original reason it was editable was
  that auto-generated names were ambiguous — `0023` removed that reason, so the grant is
  now vestigial.
- Wrap the pace change so a collision raises a sentence rather than a `23505`.

**Partly closed already by `S.1`.** The composite FK that makes a stream inherit its
parent's programme/intake/pace also blocks changing a *streamed* cohort's pace at all —
verified 2026-08-20. So the worst version of this (flipping pace under a cohort that has
streams hanging off it) becomes impossible declaratively. `S.2` still owns the unstreamed
case, and still owes a readable error in place of the raw FK/unique message.

### 3. `current_semester` still has no rollover path

**What.** Advancing a cohort's semester is a bare UPDATE with no downstream effect.

**Effects.**
- Materialized recurring series do not regenerate for the new term; the rep re-creates
  them. That is the known, accepted cost of materializing rather than expanding lazily.
- **Verified:** `create_event` never consults `courses.semester_taught`, though all 75
  seeded courses carry one. A rep can already schedule a semester-3 unit for a semester-5
  cohort and nothing objects. Pre-existing rather than a Phase 2 regression, but a stale
  `current_semester` makes it likelier to matter, because the course picker has nothing to
  narrow itself by.
- Nothing else rots, deliberately: terms are derived via `term_bounds()`, and `0023`
  excluded semester from the cohort name for exactly this reason.

**Mitigations.**
- Now: document rollover as a faculty-rep action in the runbook `3.5` already needs.
- Later: a term-boundary job, sharing the cron infrastructure `3.2`'s nudge job needs.
- For the unit mismatch, keep it **advisory** — default the course picker to the cohort's
  current semester with an override. Enforcing it would break make-up classes and repeats,
  which are legitimate.

### 4. The identity key encodes a scope decision in the schema

**What.** `unique (programme_id, intake_year, pace)` means two cohorts of the same
programme, intake and pace cannot coexist.

**Status changed 2026-08-20, twice.** It was written assuming streams were out of scope.
They are not — see `TODO.md` Phase S.

The first proposed fix was to **widen** the key to
`(programme_id, intake_year, pace, stream)`, on the reasoning that widening a unique key
is always safe because it can only permit more. **That reasoning is true and the
conclusion was still wrong.** Widening is safe for the *database*; it is not safe for the
*guarantee*. `(programme, intake, pace)` would stop being unique — which is the exact
property `0024` §1 existed to establish — and three rows would compete for one cohort's
identity.

`S.1` instead makes streams **children** of a cohort (`parent_cohort_id`), with the
identity index made partial (`where parent_cohort_id is null`). The guarantee survives
untouched for anything that is actually a cohort, streams are structurally subordinate
rather than sibling, and unstreamed cohorts are entirely unaffected.

**The lesson worth keeping** is not about unique keys at all: when a new concept does not
fit an existing key, check whether it is really a *peer* of that key's subject before
widening to accommodate it. A stream is part of a cohort, not another one — and modelling
it as a peer would have quietly cost a guarantee to buy a feature.

### 5. The retained name is a point-in-time snapshot, and that is correct

**What.** `changed_by_name` captures the name at insert time. A later correction does not
propagate, so a typo at signup lives in the trail forever and a legal name change leaves
history under the old name.

**Assessment.** Not a bug. This is what an audit log is for — recording what was true
then — and it matches `roster_audit_log.reg_number` and `role_audit_log.user_name`.

**The mitigation is to not "fix" it.** Do not join to `users` at read time to freshen the
name; that would defeat the entire purpose of denormalizing it and reintroduce the
deletion problem §3 exists to solve.

---

## After Phase 2

- **`R.5`** — recovery email delivery. Still blocked on the Edge Function and mailer in
  `§3.1`.
- **Phase 3** — push delivery (`3.1`), the confirmation-nudge job (`3.2`, now unblocked
  since `0022` gave attendance a code path and `notif_type = 'confirmation_needed'` is
  sitting unused waiting for exactly this), and the Superadmin bootstrap runbook (`3.5`).
- **`4.1`** — re-run the Supabase Advisor. The 17 warnings from `0008` are five migrations
  stale; regenerate rather than working the old list.
- **Docs** — `TECHNICAL_DISCOVERY.md` §4 (cohort naming and the identity key), §11 (the
  gap list loses three entries), and §13.1's privilege list will all need a pass, plus
  `TODO.md` §2.1's key corrected from four columns to three.
- **Flutter** — `cohorts.join_code` and `events.recurrence_rule` disappear, `cohorts.name`
  changes format, and `events_current` narrows. All four need mirroring by hand (`§4.3`).
