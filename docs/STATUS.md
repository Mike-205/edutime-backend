# Project Status

Last updated: 2026-09-23.

## Where things stand

`supabase db reset && supabase test db` last ran clean: **53 migrations, 22 test
files, 456 pgTAP tests passing** (verified at the Plan 5 merge, 2026-09-23). Re-run
locally to confirm current numbers before relying on them for anything load-bearing.

The original roster/password authentication system has been fully retired. Signup is
OAuth-only now:

- **University-email signup** (Google OAuth against `@student.chuka.ac.ke`) — the
  primary path; student identity (reg number, programme, cohort) is derived directly
  from the proven school email, no human step needed.
- **Personal-email signup** (Google OAuth against any other address) — requires human
  verification: a class rep vouches for the student and approves their cohort-join
  request. Can later be upgraded/displaced by a genuine school-email OAuth claim; the
  reverse never happens. Both signup paths use the same Google OAuth provider — they
  differ in verification method, not authentication mechanism.
- Email/password signup is disabled at the Supabase Auth config layer
  (`supabase/config.toml`).

See `docs/AUTH_FLOW.md` for the exact client contract, and
`docs/history/AUTH_FLOW_REFACTOR.md` for the design rationale behind the OAuth
redesign (archived — the redesign it proposed is fully shipped).

## Shipped, by phase

- **Phase 0-2** — core schema, event/lecture API, data integrity and retention rules.
- **Phase R** — Google OAuth configured, plus the original roster-based signup/claim
  system (later fully retired by the Plan 5 auth redesign below).
- **Phase S** — cohort streams: a large intake too big for one room splits into
  parallel lecture groups (Stream A, Stream B, ...) for the whole timetable, each
  electing its own class rep, with streams still able to rejoin for combined
  sessions.
- **Phase 3** — infrastructure: superadmin bootstrap, push delivery (Edge Functions),
  confirmation nudges.
- **Auth redesign, Plans 1-5** — replaced roster/password auth with OAuth-only
  signup, personal/school email identity linking, and full retirement of
  `student_roster` and the password path (migrations `0037`-`0053`).

Full historical detail (stale past migration `0036`, kept for context) is in
`docs/history/TECHNICAL_DISCOVERY.md` and `docs/history/TODO.md`.

## What's next

- **Re-run the Supabase Advisor.** 17 non-blocking warnings were noted after
  migration `0008` and never triaged — the list is stale enough now that it's worth
  regenerating rather than working from the old one.
- **No inverse for joining an in-progress combined lecture.** Leaving one works
  (`leave_event_cohort`); joining one already scheduled after the fact doesn't have an
  equivalent function yet.
- **Branching by pace (bimester/trimester split)** — deferred, not forgotten. A
  cohort currently moves as one pace; self-sponsored students may want to move to
  trimester as a group once a quorum threshold is reached, but that threshold hasn't
  been confirmed with the registrar. The schema already supports the destination
  state (a cohort's identity key includes pace, so `BSC-CS 2023 (bimester)` and
  `BSC-CS 2023 (trimester)` are both legitimate rows) — what's missing is only the
  in-app request/escalation flow.
- **Flutter client hasn't been started.** `docs/AUTH_FLOW.md` is the spec to build it
  against.

## Explicitly out of scope (not oversights)

- **Lecturer accounts.** Lecturers are free text in `events.lecturer_name` and never
  log in.
- **Faculty-wide analytics/reporting dashboards.**
- **A web app.** Mobile only for MVP.

## Known cleanup debt

Flagged by the Plan 5 final review as real but non-blocking:

- `supabase/functions/_shared/axene.ts` is dead code — the recovery-email subsystem
  it served was retired; nothing imports it anymore.
- `supabase/.env.example`'s `AXENE_*` section is stale for the same reason.
- A handful of test-file comments still describe roster functions that no longer
  exist.
- One index, `roster_audit_reg_idx`, still carries the pre-rename `roster_audit_log`
  name even though the table is now `identity_audit_log` (its sibling
  `roster_audit_roster_idx` was dropped implicitly along with `roster_id` in `0049`).

None of these affect correctness — they're readability/hygiene debt for whoever
picks them up next.
