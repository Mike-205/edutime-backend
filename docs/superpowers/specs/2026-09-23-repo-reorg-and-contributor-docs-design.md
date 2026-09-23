# Repo reorg and contributor docs — design

Status: approved for planning (see log at bottom)

## Context

The repo has never had a root `README.md`, `LICENSE`, or `CONTRIBUTING.md`. Every
project doc lives inside `supabase/` alongside the Supabase CLI project itself, several
of them stale (`TECHNICAL_DISCOVERY.md` and `TODO.md` both describe state as of
migration `0036`; the repo is at `0053` now, with the entire Plan 5 auth retirement
shipped and merged since). Two collaborators — the user and whoever builds the Flutter
client — need to be able to land on this repo cold and find: what it does, how it's
currently organized, what's already built, what's next, and how to contribute safely
now that `main` is branch-protected and `dev` is the integration branch.

This is an organization/documentation project, not a code change. Audience is a small,
known team (not the general public), so process artifacts are kept light — no code of
conduct, no elaborate issue templates.

## Goals

- Move everything under `supabase/` that isn't a Supabase-CLI artifact out to a proper
  `docs/` tree, so `supabase/` holds only migrations/functions/tests/seed/config.
- Preserve file history on every move (`git mv`).
- Distinguish **current, actively-maintained docs** from **historical/archived** ones,
  and mark the archived ones clearly so nobody mistakes stale content for current state.
- Add the missing front door: `README.md`, `CONTRIBUTING.md`, `LICENSE`.
- Add a living `docs/STATUS.md` that replaces `TODO.md`'s job, grounded in a real scan
  of the codebase and the old TODO's still-open items — not just the auth-retirement
  leftovers.
- Add a lightweight PR template reinforcing the `dev`-branch workflow.

## Non-goals

- No code changes. `functions/_shared/axene.ts` (dead since the recovery-email
  retirement) stays as-is — already flagged as follow-up debt by the Plan 5 final
  review; deleting it is a separate task.
- No edits to `.env.example` or `config.toml` — the stale Axene section in
  `.env.example` is described accurately in the new docs instead of edited in place.
- `docs/superpowers/plans/**` (the existing SDD planning trail) is untouched. It's an
  append-only historical record; its cross-references to `AUTH_FLOW_REFACTOR.md` etc.
  describe what was true when each plan was written and don't need updating.
- No CODE_OF_CONDUCT, issue templates, or CI setup — out of scope for a small known
  team; revisit if/when the team or process pain grows.

## Final directory structure

```
/
├── README.md
├── CONTRIBUTING.md
├── LICENSE
├── .github/
│   └── pull_request_template.md
├── docs/
│   ├── STATUS.md
│   ├── DISCOVERY.md
│   ├── AUTH_FLOW.md
│   ├── design/
│   │   └── edutime-blueprint.html
│   ├── history/
│   │   ├── AUTH_FLOW_REFACTOR.md
│   │   ├── TECHNICAL_DISCOVERY.md
│   │   ├── TODO.md
│   │   ├── PHASE1_HANDOFF.md
│   │   └── PHASE2_HANDOFF.md
│   └── superpowers/            (untouched)
└── supabase/
    ├── config.toml, .env, .env.example, .gitignore
    ├── migrations/, functions/, tests/, seed.sql
    └── .branches/, .temp/, snippets/   (CLI-managed, gitignored)
```

## File moves (all via `git mv`, one commit)

| From | To |
|---|---|
| `supabase/AUTH_FLOW.md` | `docs/AUTH_FLOW.md` |
| `supabase/DISCOVERY.md` | `docs/DISCOVERY.md` |
| `supabase/edutime-blueprint.html` | `docs/design/edutime-blueprint.html` |
| `supabase/AUTH_FLOW_REFACTOR.md` | `docs/history/AUTH_FLOW_REFACTOR.md` |
| `supabase/TECHNICAL_DISCOVERY.md` | `docs/history/TECHNICAL_DISCOVERY.md` |
| `supabase/TODO.md` | `docs/history/TODO.md` |
| `supabase/PHASE1_HANDOFF.md` | `docs/history/PHASE1_HANDOFF.md` |
| `supabase/PHASE2_HANDOFF.md` | `docs/history/PHASE2_HANDOFF.md` |

## Second commit: banners, reference fixes, new docs

**Archive banners** — prepended (not replacing any content) to each file in
`docs/history/`:

```
> **Archived 2026-09-23.** Point-in-time snapshot, kept for historical context only.
> For current state, see `docs/STATUS.md` and `docs/AUTH_FLOW.md`.
```

`TECHNICAL_DISCOVERY.md`'s banner gets one extra sentence, since old migration comments
still cite its section numbers by convention and those comments are not being touched:
`Section numbers below are still cited by number from historical migration comments —
don't renumber, this file is frozen.`

**`docs/AUTH_FLOW.md` reference fixes** (content otherwise unchanged): its intro
currently says `TECHNICAL_DISCOVERY.md §10` is stale "until it is [updated]" and names
`AUTH_FLOW_REFACTOR.md` as a sibling doc. Both claims are now permanently true in a
different way — update those two sentences to point at `docs/history/` and drop the
"until updated" framing (nobody is going to update an archived doc).

**New: `README.md`**
- One-line description + 2-3 sentence problem statement, linking `docs/DISCOVERY.md`
  for the full pitch
- Tech stack: Supabase (Postgres 17, Auth, RLS, Edge Functions); Flutter client in a
  separate repo (not yet started — see `docs/STATUS.md`)
- Repo layout: abbreviated version of the tree above
- Quickstart:
  - Prerequisites: Supabase CLI, Docker
  - `cp supabase/.env.example supabase/.env` — only `SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID`/`SECRET` are required for local OAuth login to work; `AXENE_*` vars are vestigial (recovery-email subsystem was retired in Plan 5, see `docs/STATUS.md`) and `FCM_SERVICE_ACCOUNT` is optional (push notifications fall back to console logging when unset)
  - `supabase start`, `supabase db reset`, `supabase test db`
- Current status: short paragraph + link to `docs/STATUS.md`
- Links: `docs/AUTH_FLOW.md`, `CONTRIBUTING.md`, `LICENSE`
- One line explaining `docs/superpowers/` is an internal AI-assisted planning trail, not
  user-facing documentation — so a human contributor isn't confused by it

**New: `CONTRIBUTING.md`**
- Branch model: feature branches cut from `dev`; PR into `dev`
  (`gh pr create --base dev` or select `dev` in the GitHub UI, since `main` stays the
  repo's default branch); `dev` → `main` gets PR'd periodically once a chunk of work is
  stable, mirroring how Plan 5 shipped
- `main` is branch-protected: PRs required, no force-push, no branch deletion. Note
  honestly that `enforce_admins` is currently `false`, so the repo owner can still push
  directly if truly needed — this is a convention for collaborators, not an absolute
  technical wall
- Local setup (same commands as the quickstart)
- Testing requirement: `supabase db reset && supabase test db` must pass before opening
  a PR
- "Write a test alongside every new function" — carried forward from `TODO.md` §4.2, a
  proven practice, not a stale item
- Migration numbering/comment conventions (sequential numbers, header conventions
  already established in `supabase/migrations/`)
- Where to check current state before starting work: `docs/STATUS.md`, `docs/AUTH_FLOW.md`

**New: `docs/STATUS.md`**
- Header: migration count, test file count, last verified full-suite result, dated
  (`53 migrations, 22 test files, 456 pgTAP tests passing as of the Plan 5 merge,
  2026-09-23 — re-run `supabase db reset && supabase test db` locally to confirm current
  numbers`)
- Shipped: brief phase-by-phase list (Phase 0/R/1/2/S/3, then the OAuth auth redesign
  Plans 1-5) — a few lines each, not a rehash of the archived docs
- What's next (verified against current migrations, not copied blind from the old TODO):
  - Re-run the Supabase Advisor — stale since `0008`, never triaged since
  - No inverse for "leave a combined lecture" — joining one already in progress isn't
    supported yet
  - Branching by pace (bimester/trimester quorum split) — deferred, blocked on an
    unconfirmed threshold value from the registrar; schema already supports the
    destination state, only the request/escalation flow is missing
  - Flutter client hasn't been started yet — `docs/AUTH_FLOW.md` is the spec it needs
    to be built against
- Explicitly out of scope (so nobody mistakes these for oversights): lecturer accounts
  (free text, never log in), faculty-wide analytics/reporting dashboards, a web app
  (mobile only for MVP)
- Known cleanup debt: `functions/_shared/axene.ts` is dead code post recovery-email
  retirement; `.env.example`'s Axene section is stale; a handful of test-file comments
  still describe dropped roster functions — all flagged by the Plan 5 final review as
  intentionally deferred, not forgotten

**New: `LICENSE`** — standard MIT license text, copyright holder "Mike Mwongela", 2026.

**New: `.github/pull_request_template.md`**
```markdown
## Checklist
- [ ] Branched off `dev`
- [ ] `supabase db reset && supabase test db` passes locally
- [ ] New migration is numbered sequentially and follows existing comment conventions
- [ ] Docs updated if behavior/contract changed (`docs/AUTH_FLOW.md`, `docs/STATUS.md`)
```

## Verification

- `supabase db reset && supabase test db` still passes after the moves (moves are pure
  file relocations outside `supabase/migrations|functions|tests`, so this should be a
  no-op check, not a real risk — but confirm before opening the PR)
- `grep -rn "TECHNICAL_DISCOVERY\|TODO\.md\|AUTH_FLOW_REFACTOR\|PHASE1_HANDOFF\|PHASE2_HANDOFF"` across the new `docs/AUTH_FLOW.md` and `README.md`/`CONTRIBUTING.md`/`STATUS.md` resolves to paths that actually exist post-move
- `git log --follow docs/AUTH_FLOW.md` (and the other moved files) still shows pre-move history

## Mechanics

- Work happens on a feature branch cut from `dev` (already done: `repo-reorg-docs`), PR
  target is `dev`
- Commit 1: the `git mv`s only, nothing else, so `git log --follow` stays clean
- Commit 2: archive banners, `AUTH_FLOW.md` reference fixes, and all new files
- Stage explicit paths, never `git add -A` — `.claude/` is untracked local state and
  must not be committed

## Log

- 2026-09-23: design approved in conversation (directory structure, archive treatment,
  branch model, STATUS.md sourcing, LICENSE, PR template); advisor review incorporated
  (STATUS.md sourcing broadened beyond auth-retirement leftovers, AUTH_FLOW.md reference
  fixes added, mechanics hardened). Findings verified directly against the current
  codebase (see conversation) rather than taken from memory.
