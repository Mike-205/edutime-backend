# Load, capacity, and concurrency testing — design

Status: approved for planning (see log at bottom)

## Context

The pgTAP suite (53 migrations, 22 files, 456 tests, all passing as of 2026-09-23)
covers correctness in isolation — one request at a time, small seed data. Nothing in
the repo answers: will this survive a realistic number of students hitting it at once,
where does the intended hosting tier (Supabase Free) actually break, does it stay
correct when many requests race the same write path, and is it burning more compute
than it needs to. There are no live users yet (see project memory
`project-not-yet-live`), so this is proactive capacity work, not incident response —
but the product's whole value proposition is a schedule that "survives lecturer
no-shows and last-minute changes," which makes notification latency and write-path
correctness under load a functional concern, not just an infra nicety.

This spec exists so whoever picks up this work — including a future session with no
memory of this conversation — doesn't have to re-derive the capacity numbers, re-read
the migrations to find the real API surface, or re-discover the `dispatch-push`
throughput ceiling from scratch.

## Goals

- An auditable capacity model translating real Chuka University numbers into concrete
  request-rate, connection-count, and storage-growth estimates, with every input
  sourced.
- A small measurement harness that exercises those numbers against a dedicated
  free-tier Supabase Cloud project to find actual ceilings, not guessed ones.
- Concurrency-correctness scenarios targeting the write paths most likely to have
  race conditions pgTAP's serial tests can't catch.
- A diagnose → fix → re-measure optimization loop with cost signals mapped to
  Supabase's actual billing dimensions, so "is it optimal" has a falsifiable answer.
- Documentation any contributor can act on without this conversation: this spec,
  `docs/CAPACITY_MODEL.md`, `docs/RESULTS.md`, and a `docs/STATUS.md` pointer.

## Non-goals (for this spec)

- **Implementing any specific optimization fix.** The `dispatch-push` throughput
  ceiling (below) is already predictable from reading the code, but *fixing* it is a
  separate, future spec once the baseline run quantifies it under a realistic
  worst-case burst. You can't write a TDD plan for a fix you haven't measured yet.
- **CI integration.** This hits a real external project and real time/quota budgets;
  it stays a manually-triggered exercise, not a PR gate.
- **Flutter client implementation.** The client repo doesn't exist yet. This effort
  documents the *contract* it must satisfy (e.g. Realtime reconnect/fallback
  behavior), not the client code itself.
- **A data retention/lifecycle policy.** Flagged below as a real, separate risk
  (unbounded storage growth) — not solved in this pass.

## Real-world inputs (sourced, not assumed)

- Chuka University: ~17,000–18,000 currently enrolled students, trending toward
  ~30,000 with ~7,000–9,000 new freshers/year.
  ([Kenya News Agency](https://www.kenyanews.go.ke/chuka-university-student-population-set-to-rise-rapidly/),
  [Chuka University official](https://www.chuka.ac.ke/chuka-set-to-welcome-nearly-7000-new-students-for-2025-2026-academic-year/))
- 9 faculties, 78 undergraduate programmes, standard 4-year duration, 2 semesters/year
  (Aug–Dec, Jan–May), 5 campuses (Main, Tharaka, Chogoria, Igembe, Embu) — venue
  conflict checks are scoped per campus, not university-wide.
  ([Chuka University faculties](https://www.kefinder.net/chuka-university-faculties/),
  [programme count](https://mabumbe.com/official-chuka-university-courses-offered-chuka-university/))
- Supabase Free tier hard limits: 60 direct DB connections / 200 pooler connections,
  **200 concurrent Realtime connections**, 500,000 Edge Function invocations/month,
  2,000,000 Realtime messages/month, 500MB database storage, 5GB egress/month, only
  **2 active projects per account**, and free projects **pause after 7 days of
  inactivity**. ([Supabase Realtime limits](https://supabase.com/docs/guides/realtime/limits),
  corroborated by multiple 2026 pricing breakdowns)

## Capacity model

Derivation (Little's-Law-style): DAU fraction of enrollment → sessions/day per DAU →
requests/session → peak RPS via burst-window concentration (a mass push notification
or the pre-class rush causes a disproportionate share of daily sessions to land in a
short window).

Three named scenarios, referenced by name everywhere else in this spec and in the
harness:

- **`single-faculty`** — ~9 cohorts, ~500 students. One-faculty pilot; realistic
  first-launch scale.
- **`full-rollout`** — ~325 active cohorts (78 programmes × ~4 concurrent year-groups),
  ~18,000 students, ~55 students/cohort on average.
- **`growth-headroom`** — ~30,000 students, Chuka's stated growth trajectory; a
  stretch check, not a launch target.

At `full-rollout`: ~40% DAU (7,200) × ~3 sessions/day × ~2.3 requests/session ≈ 49,700
REST/RPC requests/day, with ~20% of sessions clustering into a 15-minute post-event
window → peak instantaneous REST load in the **~35–55 req/s** range. This is well
within what Postgres/PostgREST can serve even on Free tier — the REST/RPC layer is
*not* expected to be the first thing to break.

**Worst-case cohort, not average, drives fanout.** Use the average (~55) for baseline
REST load, but use a **worst-case pre-stream-split cohort of ~150–400 students** —
sized to "the largest intake that still fits in one lecture hall before Phase S
splits it into streams" — for anything modeling a single notification fanout or a
single Realtime broadcast burst. The average undercounts the case that actually
stresses `dispatch-push` and Realtime.

**Realtime concurrency is a spike, not a plateau.** Mobile OSes suspend sockets when
an app backgrounds (FCM covers the backgrounded case), so "students keep the app open
all day" doesn't hold. Model concurrent Realtime connections the same way as REST —
arrival rate × foreground session length — which produces a **spike right after a
push notification fires** (everyone who got notified opens the app within ~1–2
minutes) rather than a sustained high plateau. At `full-rollout` scale this spike very
plausibly still exceeds the 200-connection cap, which is why it's in scope as a
scenario — but the shape of the test (a burst, not a ramp-and-hold) should reflect
this.

**Storage growth (informational, not a load-test target):** no retention policy
exists (see below); `events`/`notifications` rows are small (well under 1KB and
~100–300 bytes respectively) but accumulate indefinitely. Worth tracking against the
500MB Free-tier cap over multiple semesters — a capacity-model line item, not
something this harness measures directly.

## Known API surface (from a dedicated codebase read, not guesses)

- **Calendar/schedule read**: no RPC — direct `SELECT` on `events` /
  `events_current` / `event_cohorts` / `notifications`, gated by RLS.
- **Venue browsing**: `is_venue_available(venue_id, start, end)`,
  `get_venue_occupancy()`, `SELECT` on `venue_occupancy` view.
- **Lecture CRUD**: `create_event`, `update_event`, `cancel_event`,
  `cancel_recurrence_group`, `reschedule_event`, `confirm_attendance` /
  `unconfirm_attendance`, `confirm_event_cohort` / `decline_event_cohort`,
  `leave_event_cohort`.
- **Cohort/membership**: `approve_cohort_join_request`, `decline_cohort_join_request`,
  `create_cohort_with_class_rep`, `promote_class_rep`, `demote_class_rep`,
  `assign_students_to_streams`; `SELECT`/`INSERT` on `cohort_join_requests`.
- **Identity**: `resolve_identity_dispute` and related linking functions.
- **RLS on hot tables is cheap** — single indexed `EXISTS` lookups (`events`'
  `events_read_own_cohort`, and `user_can_see_event()` for combined-lecture
  visibility), not deep join chains. Not an a-priori optimization target.
- **Realtime uses Broadcast, not Postgres Changes** — a deliberate choice
  (documented inline in `0005_realtime.sql`) specifically to avoid RLS being
  re-evaluated per subscriber. The `events` update trigger broadcasts once per
  *attached cohort* (bounded, small), not once per subscriber. This means the
  200-connection cap is a pure websocket-slot ceiling, not compounded by
  per-message RLS cost.
- **`dispatch-push` is a fixed-throughput batch drain, not an N+1 fanout** (an
  earlier guess in this design was wrong). A `pg_cron` job fires every minute,
  claims up to 50 pending notifications via `claim_pending_pushes(50)`, and sends
  them **sequentially** to FCM. `notify_cohort_members` itself batches the insert
  correctly. The real bottleneck is a **hard ceiling of 3,000 notifications/hour**
  regardless of load — a mass change affecting a `growth-headroom`-scale burst of
  cohorts could take over an hour to fully deliver. This is knowable from the code
  alone; the baseline run's job is to *quantify* it against a realistic worst-case
  burst, not discover it. **Flagged as the flagship first optimization-loop
  candidate** for a follow-up spec.
- **`pg_stat_statements` is not enabled anywhere** in this repo — needed as the
  primary diagnosis tool; must be enabled on the load-test project.
- **No data retention/lifecycle policy exists** — despite the name,
  `0024_integrity_and_retention.sql` is about attribution (`created_by`/`updated_by`)
  integrity, not data lifecycle. `events`/`notifications` grow indefinitely.

## Test suite architecture

```
docs/
  CAPACITY_MODEL.md        # this design's numbers, kept current as assumptions are corrected
  RESULTS.md                # dated log of every run: scale, ceiling found, cost signals
load-tests/                 # runnable code only — no docs live here
  README.md                 # how to run, env vars needed, safety/ToS notes
  .env.example               # documents required vars; real .env is gitignored
  k6/
    smoke.js                 # single-faculty scale, pass/fail thresholds
    rest-ramp.js              # full-rollout request mix, ramps to find the REST/RPC ceiling
    concurrency-races.js      # races on venue booking, join approval, identity linking
    lib/                      # JWT minting, scenario weighting, shared config
  realtime/
    realtime-burst.ts         # Deno + supabase-js; k6 has no supabase-js client and hand-rolling
                               # the Phoenix channel protocol isn't worth it — Deno is already in
                               # this stack for Edge Functions. Models a post-notification join
                               # burst, not a sustained ramp.
  seed/
    seed-synthetic.ts         # Admin-API-based synthetic data at real scenario volumes
```

## Scenarios

1. **Smoke** (`smoke.js`, k6) — fixed load at `single-faculty` scale. Concrete
   thresholds to start from (revise once a baseline exists): p95 < 300ms on reads,
   p95 < 500ms on writes, error rate < 1%. This is the one scenario that could
   plausibly run before a release, run manually.
2. **REST/RPC ceiling** (`rest-ramp.js`, k6) — ramping-VU scenario mixing the real
   endpoints above at `full-rollout` weighting, independent of the Realtime scenario
   (so the 200-connection cap doesn't cut this measurement short). Climbs until
   error rate or p99 latency crosses a threshold; reports the breaking VU count and
   the equivalent modeled student count.
3. **Realtime connection ceiling & degradation** (`realtime-burst.ts`, Deno +
   supabase-js) — opens concurrent Realtime subscriptions in a burst pattern (per
   the "spike, not plateau" model above) past 200, and records what actually
   happens at and past the cap: rejected at handshake, existing connections
   dropped, or silent message loss. Since the Flutter client doesn't exist yet,
   this characterizes **server-side** behavior only. Output is a documented
   contract (what the eventual client must implement: reconnect/backoff, polling
   fallback, staleness indication) — not a pass/fail test.
4. **Concurrency-correctness races** (`concurrency-races.js`, k6) — many concurrent
   requests against the same write path, asserting DB-level invariants hold:
   - `is_venue_available` + `create_event` — no double-booking under concurrent
     inserts for the same venue/time.
   - `approve_cohort_join_request` — a request can't be approved twice or by two
     class reps racing each other.
   - `resolve_identity_dispute` / identity-linking functions — concurrent linking
     attempts can't produce an inconsistent identity state.
5. **pgbench** (secondary, local Docker, diagnostic only) — used only when 2 or 3
   above find a bottleneck, to separate "the database itself" from "PostgREST/the
   pooler" as the actual limiting layer.

## Synthetic auth & data seeding

- `seed-synthetic.ts` creates `auth.users` + student/cohort/event rows via the
  Supabase Admin API, namespaced (e.g. an email prefix) and idempotent, at real
  scenario volumes — not toy fixtures. `full-rollout` needs roughly a semester's
  worth of events (~325 cohorts × ~14 events/week × ~16 weeks ≈ 70,000 rows) plus
  proportional notifications/audit rows, because query plans on tiny tables won't
  reveal real bottlenecks.
- **JWT strategy — verify before committing.** The plan is to mint signed JWTs
  directly using the project's JWT signing secret (not the service-role key, which
  only authenticates as service-role, doesn't sign arbitrary user tokens). **This
  needs verifying at implementation time**: a project created now may use
  asymmetric JWT signing keys, in which case there is no shared secret to mint
  with. Fallback if so: enable password auth on the load-test project only, sign
  each synthetic user in once via GoTrue, and cache the tokens for reuse across a
  run. Either way, note that bypassing GoTrue for auth means token-refresh load
  itself stays untested — an accepted gap for this pass. The per-IP `auth.rate_limit`
  values in `config.toml` (e.g. `token_refresh = 150/5min/IP`) don't constrain
  direct JWT minting, only the fallback path.
- Cleanup: all seeded synthetic data removable by its namespace prefix after a run.

## Optimization loop & cost signals

- Enable `pg_stat_statements` on the load-test project — the primary before/after
  diagnosis tool (far less noisy than end-to-end latency on shared Free-tier
  compute).
- Loop, per scenario run: run → identify the binding constraint → root-cause it via
  `pg_stat_statements` / `EXPLAIN ANALYZE` → **write it up as a candidate follow-up
  spec** (the fix itself is out of scope here, see Non-goals) → record findings in
  `docs/RESULTS.md`.
- Track, per run, the metrics that map to actual Supabase billing dimensions, not
  just latency/error rate: DB CPU% / compute-ms per request (the Pro-tier cost
  driver), egress volume, Realtime message count, Edge Function invocation count —
  each reported against its Free-tier cap so "how close to the limit" is explicit.
- Project Pro-tier compute cost as: measured DB time per request × modeled peak
  RPS. This is how a Free-tier measurement answers "is this optimal past Free tier"
  without actually running on Pro.

## Environment

- One dedicated free-tier Supabase Cloud project for load testing, separate from
  any future production project. This uses one of the account's two Free-tier
  project slots — confirm that's acceptable before creating it.
- **I will ask for explicit confirmation before actually creating this project** —
  it's an external resource, not local repo state.
- Region: pick whichever available Supabase region is geographically closest to
  Kenya at creation time (not resolved here — decide when actually creating the
  project).
- Enable `pg_stat_statements` on creation.
- Secrets (JWT signing secret or service-role key, whichever the auth strategy
  ends up needing) live only in a gitignored `load-tests/.env`; never committed,
  never echoed into `docs/RESULTS.md`.
- Before running ramp-to-failure-style scenarios (2 and 3 above), check Supabase's
  current acceptable-use / fair-use terms for the Free tier to confirm this kind of
  testing doesn't violate them.

## Reporting

- `docs/CAPACITY_MODEL.md` — this spec's estimation methodology and numbers,
  updated as assumptions get corrected by real measurements.
- `docs/RESULTS.md` — dated entries per run: scenario, scale, ceiling found, cost
  signals, and (once follow-up fixes land) before/after deltas.
- `docs/STATUS.md` "What's next" gets one line pointing here, noting the baseline
  hasn't run yet.

## Scope decomposition

This spec covers: the capacity model, the full harness (all 5 scenario types
above), seed tooling, and **one baseline run** against the real Free-tier project —
including the concurrency-correctness scenarios, since they're cheap to add once
the harness and synthetic auth exist.

Each fix an optimization-loop run surfaces — starting predictably with
`dispatch-push`'s fixed throughput ceiling — becomes its **own small
spec → plan → PR**, following `CONTRIBUTING.md`'s existing convention (numbered
migration + pgTAP test alongside every new function). A fix can't be TDD-planned
before it's been measured and root-caused.

## Open risks / follow-ups tracked but not solved here

- No data retention/lifecycle policy — indefinite storage growth against the
  500MB cap. Separate from load; worth its own `docs/STATUS.md` line regardless of
  this effort.
- JWT signing key type on a newly-created Supabase Cloud project needs verifying
  before the direct-minting synthetic-auth approach is locked in.
- Supabase's acceptable-use terms for ramp-to-failure testing on Free tier should
  be checked before running scenarios 2 and 3.

## Log

- 2026-09-23: design brainstormed and approved in conversation. Chuka University
  scale/structure grounded via web search rather than assumed. Codebase facts
  (RPC surface, RLS cost, Realtime mechanism, `dispatch-push` implementation, cron
  jobs, `pg_stat_statements` absence, retention gap) verified via a dedicated
  read-only research pass rather than guessed. Advisor review incorporated:
  corrected an initial wrong guess that `dispatch-push` was an N+1 fanout (it's
  actually a fixed-rate batch drain — a more interesting and more precisely
  fixable finding); corrected an initial overstated Realtime RLS-cost concern
  given the Broadcast-not-Postgres-Changes finding; corrected a wrong claim that
  the service-role key signs user JWTs; added the concurrency-correctness
  scenario per explicit user request; decomposed scope into this baseline spec
  plus future per-fix specs; corrected cohort-size modeling to use worst-case
  rather than average for fanout scenarios; added cost-signal tracking mapped to
  Supabase billing dimensions per user's cost-optimization request; moved doc
  placement under `docs/` to match the existing repo-reorg convention rather than
  under `load-tests/`.
