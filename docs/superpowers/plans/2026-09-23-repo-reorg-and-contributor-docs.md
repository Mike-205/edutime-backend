# Repo Reorg and Contributor Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every non-Supabase-CLI file out of `supabase/` into a proper `docs/` tree, mark stale docs as archived without rewriting them, and add the missing contributor front door (`README.md`, `CONTRIBUTING.md`, `LICENSE`, a living `docs/STATUS.md`, and a PR template).

**Architecture:** Pure file/documentation reorganization on branch `repo-reorg-docs` (cut from `dev`). No application code changes. File moves happen via `git mv` in their own commit to keep history tracking clean; each new/edited doc gets its own commit after that.

**Tech Stack:** Git, Markdown. No build step, no test framework for most tasks — verification is `git log --follow`, `grep`, and (for the one task that touches anything near `supabase/`) `supabase db reset && supabase test db`.

**Spec:** `docs/superpowers/specs/2026-09-23-repo-reorg-and-contributor-docs-design.md`

## Global Constraints

- All file moves use `git mv`, never delete+recreate — history must follow (`git log --follow` must show pre-move commits).
- Stage explicit paths only. Never `git add -A` or `git add .` — `.claude/` is untracked local state and must not be committed.
- Do not edit `supabase/.env.example`, `supabase/config.toml`, or delete `supabase/functions/_shared/axene.ts` — describe their staleness in docs instead; the code cleanup is separate, already-flagged follow-up debt.
- Do not touch anything under `docs/superpowers/plans/` other than adding this plan file — it's an append-only historical record.
- `main` stays the GitHub default branch; this plan's PR targets `dev`, not `main`.
- No CODE_OF_CONDUCT, issue templates, or CI config — explicitly out of scope per the spec.

## Review Focus

- **Archive banners land on exactly the 5 `docs/history/` files and nowhere else.** `docs/AUTH_FLOW.md` and `docs/DISCOVERY.md` must NOT get an archive banner — they're current, actively-maintained docs. A reviewer should open both and confirm no banner was added by mistake.
- **`docs/AUTH_FLOW.md`'s cross-references point at real post-move paths.** Its intro mentions `AUTH_FLOW_REFACTOR.md` and `TECHNICAL_DISCOVERY.md` by bare filename; after the move both must read `docs/history/...` or a reader following the reference lands nowhere.
- **New docs describe today's state, not copied-forward stale numbers.** `README.md`/`docs/STATUS.md` claim 53 migrations / 22 test files / 456 tests — a reviewer should run `ls supabase/migrations/*.sql | wc -l` and `ls supabase/tests/*.sql | wc -l` and confirm those numbers still match before merging (they will drift the moment a new migration lands).
- **The Google OAuth env vars named in the Quickstart actually match `.env.example`.** If `.env.example`'s variable names ever changed, a copy-pasted README quickstart with stale variable names would silently break local setup for the next person — diff the names against the real file, don't trust memory.
- **The `git mv` commit is pure — no content edits mixed in.** If banner/reference edits land in the same commit as the moves, git's rename detection can fail to register some files as renames, breaking `git log --follow`. A reviewer should check `git show --stat` on the move commit and confirm every line is a rename, zero content diff.

---

### Task 1: Move all non-Supabase-CLI files out of `supabase/`

**Files:**
- Move: `supabase/AUTH_FLOW.md` → `docs/AUTH_FLOW.md`
- Move: `supabase/DISCOVERY.md` → `docs/DISCOVERY.md`
- Move: `supabase/edutime-blueprint.html` → `docs/design/edutime-blueprint.html`
- Move: `supabase/AUTH_FLOW_REFACTOR.md` → `docs/history/AUTH_FLOW_REFACTOR.md`
- Move: `supabase/TECHNICAL_DISCOVERY.md` → `docs/history/TECHNICAL_DISCOVERY.md`
- Move: `supabase/TODO.md` → `docs/history/TODO.md`
- Move: `supabase/PHASE1_HANDOFF.md` → `docs/history/PHASE1_HANDOFF.md`
- Move: `supabase/PHASE2_HANDOFF.md` → `docs/history/PHASE2_HANDOFF.md`

**Interfaces:**
- Consumes: nothing from earlier tasks (this is the first task)
- Produces: the file paths above must exist post-move; every later task references these exact paths (especially `docs/AUTH_FLOW.md`, `docs/history/AUTH_FLOW_REFACTOR.md`, `docs/history/TECHNICAL_DISCOVERY.md`)

- [ ] **Step 1: Create the destination directories**

```bash
mkdir -p "docs/design" "docs/history"
```

- [ ] **Step 2: Move each file with `git mv`**

```bash
git mv supabase/AUTH_FLOW.md docs/AUTH_FLOW.md
git mv supabase/DISCOVERY.md docs/DISCOVERY.md
git mv supabase/edutime-blueprint.html docs/design/edutime-blueprint.html
git mv supabase/AUTH_FLOW_REFACTOR.md docs/history/AUTH_FLOW_REFACTOR.md
git mv supabase/TECHNICAL_DISCOVERY.md docs/history/TECHNICAL_DISCOVERY.md
git mv supabase/TODO.md docs/history/TODO.md
git mv supabase/PHASE1_HANDOFF.md docs/history/PHASE1_HANDOFF.md
git mv supabase/PHASE2_HANDOFF.md docs/history/PHASE2_HANDOFF.md
```

- [ ] **Step 3: Verify the moves are clean renames with no content changes**

Run: `git status` (expect 8 renamed files, nothing else touched) and `git diff --cached --stat` (expect zero insertions/deletions — pure renames)

Expected: every entry says `renamed:`, diff stat shows no `+`/`-` lines

- [ ] **Step 4: Verify `supabase/` no longer has stray docs**

Run: `ls supabase/`

Expected: only `.branches`, `.env`, `.env.example`, `.gitignore`, `.temp`, `config.toml`, `functions`, `migrations`, `seed.sql`, `snippets`, `tests` remain

- [ ] **Step 5: Commit**

```bash
git add supabase/AUTH_FLOW.md docs/AUTH_FLOW.md \
        supabase/DISCOVERY.md docs/DISCOVERY.md \
        supabase/edutime-blueprint.html docs/design/edutime-blueprint.html \
        supabase/AUTH_FLOW_REFACTOR.md docs/history/AUTH_FLOW_REFACTOR.md \
        supabase/TECHNICAL_DISCOVERY.md docs/history/TECHNICAL_DISCOVERY.md \
        supabase/TODO.md docs/history/TODO.md \
        supabase/PHASE1_HANDOFF.md docs/history/PHASE1_HANDOFF.md \
        supabase/PHASE2_HANDOFF.md docs/history/PHASE2_HANDOFF.md
git commit -m "chore: move non-Supabase-CLI docs out of supabase/ into docs/

Pure git mv, no content changes — supabase/ now holds only what the
Supabase CLI actually owns (migrations, functions, tests, seed, config)."
```

---

### Task 2: Add archive banners and fix `AUTH_FLOW.md`'s stale cross-references

**Files:**
- Modify: `docs/history/AUTH_FLOW_REFACTOR.md` (prepend banner)
- Modify: `docs/history/TECHNICAL_DISCOVERY.md` (prepend banner with extra sentence)
- Modify: `docs/history/TODO.md` (prepend banner)
- Modify: `docs/history/PHASE1_HANDOFF.md` (prepend banner)
- Modify: `docs/history/PHASE2_HANDOFF.md` (prepend banner)
- Modify: `docs/AUTH_FLOW.md` (fix two cross-reference sentences in the intro)

**Interfaces:**
- Consumes: files moved in Task 1
- Produces: nothing new consumed by later tasks — this task is a leaf

- [ ] **Step 1: Prepend the standard archive banner to four files**

For each of `docs/history/AUTH_FLOW_REFACTOR.md`, `docs/history/TODO.md`, `docs/history/PHASE1_HANDOFF.md`, `docs/history/PHASE2_HANDOFF.md`, insert this block as the very first lines of the file (above the existing `# ` title line):

```markdown
> **Archived 2026-09-23.** Point-in-time snapshot, kept for historical context only.
> For current state, see `docs/STATUS.md` and `docs/AUTH_FLOW.md`.

```

- [ ] **Step 2: Prepend the `TECHNICAL_DISCOVERY.md` banner (with the extra sentence)**

Insert as the first lines of `docs/history/TECHNICAL_DISCOVERY.md`, above its existing `# ` title line:

```markdown
> **Archived 2026-09-23.** Point-in-time snapshot, kept for historical context only.
> For current state, see `docs/STATUS.md` and `docs/AUTH_FLOW.md`. Section numbers
> below are still cited by number from historical migration comments — don't
> renumber, this file is frozen.

```

- [ ] **Step 3: Fix `docs/AUTH_FLOW.md`'s intro cross-references**

Find this existing paragraph near the top of the file:

```
*`AUTH_FLOW_REFACTOR.md` is the design doc that drove this rewrite — it explains
**why** the design is what it is, in prose that is deliberately not verbatim against
the live code. This file is **what the client must do, in order**: the exact call
sequence, the exact strings, the exact thing a user sees when something goes wrong.
Function names, parameter names, and error text below are taken directly from the
live migration files, not paraphrased. (`TECHNICAL_DISCOVERY.md` §10 still describes
the old roster/password design as current — it has not been updated for this rewrite
yet, so treat it as stale, not as a second source of rationale, until it is.)*
```

Replace it with:

```
*`docs/history/AUTH_FLOW_REFACTOR.md` is the design doc that drove this rewrite — it
explains **why** the design is what it is, in prose that is deliberately not verbatim
against the live code. It's archived now that the redesign it proposed has fully
shipped, kept for rationale only. This file is **what the client must do, in order**:
the exact call sequence, the exact strings, the exact thing a user sees when something
goes wrong. Function names, parameter names, and error text below are taken directly
from the live migration files, not paraphrased. (`docs/history/TECHNICAL_DISCOVERY.md`
§10 still describes the old roster/password design — it was never updated for this
rewrite and is now archived as a permanent historical snapshot, not a second source of
rationale.)*
```

(Exact wording may differ slightly by whitespace/line-wrap — match by content, not byte-for-byte, since the file's actual line breaks may vary.)

- [ ] **Step 4: Verify banners landed only where intended**

Run: `head -5 docs/history/*.md` and confirm all 5 files start with `> **Archived 2026-09-23.**`

Run: `head -5 docs/AUTH_FLOW.md docs/DISCOVERY.md` and confirm neither has an archive banner

- [ ] **Step 5: Verify the cross-reference fix**

Run: `grep -n "AUTH_FLOW_REFACTOR.md\|TECHNICAL_DISCOVERY.md" docs/AUTH_FLOW.md`

Expected: both mentions now read `docs/history/AUTH_FLOW_REFACTOR.md` and `docs/history/TECHNICAL_DISCOVERY.md`, no bare filenames remain

- [ ] **Step 6: Commit**

```bash
git add docs/history/AUTH_FLOW_REFACTOR.md docs/history/TECHNICAL_DISCOVERY.md \
        docs/history/TODO.md docs/history/PHASE1_HANDOFF.md docs/history/PHASE2_HANDOFF.md \
        docs/AUTH_FLOW.md
git commit -m "docs: mark archived docs as historical, fix AUTH_FLOW.md's stale cross-refs"
```

---

### Task 3: Write `docs/STATUS.md`

**Files:**
- Create: `docs/STATUS.md`

**Interfaces:**
- Consumes: nothing (self-contained content, verified against the repo directly in this task)
- Produces: `docs/STATUS.md`, linked from `README.md` (Task 4) and `CONTRIBUTING.md` (Task 5)

- [ ] **Step 1: Confirm the current migration/test counts before writing them down**

Run: `ls supabase/migrations/*.sql | wc -l` — expect `53`
Run: `ls supabase/tests/*.sql | wc -l` — expect `22`

If either number differs from what's below, update the numbers in Step 2 to match reality before writing the file.

- [ ] **Step 2: Write `docs/STATUS.md`**

```markdown
# Project Status

Last updated: 2026-09-23.

## Where things stand

`supabase db reset && supabase test db` last ran clean: **53 migrations, 22 test
files, 456 pgTAP tests passing** (verified at the Plan 5 merge, 2026-09-23). Re-run
locally to confirm current numbers before relying on them for anything load-bearing.

The original roster/password authentication system has been fully retired. Signup is
OAuth-only now:

- **University-email signup** (Google OAuth) — the primary path, auto-verified via
  email domain.
- **Personal-email signup** — requires human verification: a class rep vouches for the
  student at cohort-join time.
- Email/password signup is disabled at the Supabase Auth config layer
  (`supabase/config.toml`).

See `docs/AUTH_FLOW.md` for the exact client contract, and
`docs/history/AUTH_FLOW_REFACTOR.md` for the design rationale behind the OAuth
redesign (archived — the redesign it proposed is fully shipped).

## Shipped, by phase

- **Phase 0-2** — core schema, event/lecture API, data integrity and retention rules.
- **Phase S** — cohort streams (splitting a cohort that already shares a pace).
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
- Some index names still reference the pre-rename `roster_audit_log` table (now
  `identity_audit_log`).

None of these affect correctness — they're readability/hygiene debt for whoever
picks them up next.
```

- [ ] **Step 3: Verify**

Run: `test -f docs/STATUS.md && echo exists`

Expected: `exists`

- [ ] **Step 4: Commit**

```bash
git add docs/STATUS.md
git commit -m "docs: add docs/STATUS.md as the living replacement for TODO.md's job"
```

---

### Task 4: Write `README.md`

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: `docs/STATUS.md` (Task 3), `docs/AUTH_FLOW.md` (Task 1/2), `CONTRIBUTING.md` and `LICENSE` (Tasks 5-6, referenced by relative link — links are inert markdown text, so task order doesn't block this, but confirm targets exist by the time the branch is done)
- Produces: `README.md`, the repo's front door

- [ ] **Step 1: Confirm the exact required env var names before writing the quickstart**

Run: `grep -n "SUPABASE_AUTH_EXTERNAL_GOOGLE\|FCM_SERVICE_ACCOUNT\|AXENE_" supabase/.env.example`

Confirm the names below match exactly what's in the real file; if they've drifted, use the real names instead.

- [ ] **Step 2: Write `README.md`**

```markdown
# Edutime

A backend for university lecture scheduling: cohorts see a shared, single source of
truth for what's happening and when, class reps schedule and manage it, and the
schedule survives lecturer no-shows and last-minute changes without falling back to
word-of-mouth. See [docs/DISCOVERY.md](docs/DISCOVERY.md) for the full problem
statement and target users.

## Stack

- **Database/Backend:** [Supabase](https://supabase.com) — Postgres 17, Auth
  (Google/Apple OAuth), Row-Level Security, Realtime, Edge Functions (Deno/TypeScript)
- **Client:** Flutter — separate repo, not started yet. `docs/AUTH_FLOW.md` is the
  spec it needs to be built against.

## Repo layout

```
docs/            Project documentation (this is the front door beyond this README)
  STATUS.md      Current state: what's shipped, what's next
  AUTH_FLOW.md   Client contract: exact call sequences, errors, journeys
  DISCOVERY.md   Original problem statement and target users
  design/        Visual mockups
  history/       Archived point-in-time docs, kept for context only
  superpowers/   Internal AI-assisted planning trail (not user-facing docs)
supabase/
  migrations/    Numbered SQL migrations — the schema, in order
  functions/     Edge Functions (Deno/TypeScript)
  tests/         pgTAP test suite
  seed.sql       Local dev seed data
  config.toml    Supabase project config
```

## Quickstart

Prerequisites: [Supabase CLI](https://supabase.com/docs/guides/cli), Docker.

```bash
cp supabase/.env.example supabase/.env
# Fill in SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID and
# SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET — that's the only pair required for local
# OAuth login to work. FCM_SERVICE_ACCOUNT is optional (push notifications fall
# back to console logging when unset). The AXENE_* vars are vestigial — the
# recovery-email subsystem they served was retired; see docs/STATUS.md.

supabase start
supabase db reset      # applies every migration + seed.sql
supabase test db       # runs the full pgTAP suite
```

## Current status

53 migrations, 22 pgTAP test files, all passing as of the last full-suite run
(2026-09-23). The original roster/password auth system has been fully retired in
favor of OAuth-only signup (Google for university emails, human-verified class-rep
vouching for the rest). See [docs/STATUS.md](docs/STATUS.md) for what's shipped and
what's next.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch workflow and testing
requirements.

## License

[MIT](LICENSE)
```

- [ ] **Step 3: Verify**

Run: `test -f README.md && echo exists`

Expected: `exists`

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add root README"
```

---

### Task 5: Write `CONTRIBUTING.md`

**Files:**
- Create: `CONTRIBUTING.md`

**Interfaces:**
- Consumes: nothing structurally (referenced by README, Task 4, but content is self-contained)
- Produces: `CONTRIBUTING.md`

- [ ] **Step 1: Write `CONTRIBUTING.md`**

```markdown
# Contributing

This is a small, known-team project (not open to the general public yet) — this doc
is here so nobody has to re-derive the workflow from scratch.

## Branch model

- `main` is the protected, stable branch — GitHub's default branch, no direct
  pushes, no force-push, no branch deletion.
- `dev` is the integration branch. Cut feature branches from `dev`, open PRs back
  into `dev`.
- Because `main` stays the GitHub default, `gh pr create` and the web UI both target
  `main` unless you say otherwise — always specify `dev` explicitly:

  ```bash
  git checkout -b my-feature dev
  # ...work...
  gh pr create --base dev
  ```

- `dev` gets PR'd into `main` periodically, once a chunk of work is stable — the
  same way Plan 5 (the auth retirement) shipped.
- Note: `main`'s branch protection has `enforce_admins` set to `false`, so the repo
  owner can technically still push directly if truly necessary. Treat "always go
  through a PR into `dev`" as the convention regardless — the protection is a safety
  net, not a substitute for the habit.

## Local setup

```bash
cp supabase/.env.example supabase/.env
# See README.md Quickstart for which variables are actually required.
supabase start
supabase db reset
supabase test db
```

## Before opening a PR

- `supabase db reset && supabase test db` must pass locally.
- Write a test alongside every new function — this suite has already caught real
  bugs that reading the code missed (a join-request privilege bug, four dormant bugs
  in `0014`). Don't skip it because the function looks obviously correct.
- New migrations are numbered sequentially (`NNNN_description.sql`) and follow the
  header-comment conventions already established in `supabase/migrations/` — read a
  couple of recent ones (e.g. `0051`-`0053`) before writing a new one.
- If your change affects the client contract (function names, parameters, error
  strings, call order), update `docs/AUTH_FLOW.md` in the same PR.
- If your change ships or retires something meaningfully, update `docs/STATUS.md` in
  the same PR.

## Where to check current state before starting work

- `docs/STATUS.md` — what's shipped, what's next, what's deliberately out of scope
- `docs/AUTH_FLOW.md` — the current client-facing auth contract
- `docs/history/` — archived design docs, useful for "why is it built this way"
  context, not for "what does it do today"
```

- [ ] **Step 2: Verify**

Run: `test -f CONTRIBUTING.md && echo exists`

Expected: `exists`

- [ ] **Step 3: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: add CONTRIBUTING with the dev/main branch workflow"
```

---

### Task 6: Add `LICENSE`

**Files:**
- Create: `LICENSE`

**Interfaces:**
- Consumes: nothing
- Produces: `LICENSE`, referenced by `README.md` (Task 4)

- [ ] **Step 1: Write `LICENSE`**

```
MIT License

Copyright (c) 2026 Mike Mwongela

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Verify**

Run: `test -f LICENSE && echo exists`

Expected: `exists`

- [ ] **Step 3: Commit**

```bash
git add LICENSE
git commit -m "chore: add MIT license"
```

---

### Task 7: Add `.github/pull_request_template.md`

**Files:**
- Create: `.github/pull_request_template.md`

**Interfaces:**
- Consumes: nothing
- Produces: `.github/pull_request_template.md`

- [ ] **Step 1: Create the directory and file**

```bash
mkdir -p .github
```

Write `.github/pull_request_template.md`:

```markdown
## Checklist

- [ ] Branched off `dev`
- [ ] `supabase db reset && supabase test db` passes locally
- [ ] New migration (if any) is numbered sequentially and follows existing comment
      conventions
- [ ] Docs updated if behavior/contract changed (`docs/AUTH_FLOW.md`,
      `docs/STATUS.md`)

## What changed and why
```

- [ ] **Step 2: Verify**

Run: `test -f .github/pull_request_template.md && echo exists`

Expected: `exists`

- [ ] **Step 3: Commit**

```bash
git add .github/pull_request_template.md
git commit -m "chore: add lightweight PR template"
```

---

### Task 8: Whole-branch verification and PR

**Files:** none created/modified — this task only verifies and opens the PR

**Interfaces:**
- Consumes: everything from Tasks 1-7
- Produces: an open PR from `repo-reorg-docs` into `dev`

- [ ] **Step 1: Confirm the pgTAP suite is unaffected**

Run: `supabase db reset && supabase test db`

Expected: same pass count as before this branch started (53 migrations applied, all
tests green) — the moves touched nothing under `supabase/migrations|functions|tests`,
so this should be a no-op confirmation, not a real risk. If Docker isn't running
locally, note that explicitly to the human reviewer instead of skipping silently.

- [ ] **Step 2: Grep for any remaining stale bare-filename references**

```bash
grep -rn "TECHNICAL_DISCOVERY\.md\|AUTH_FLOW_REFACTOR\.md\|PHASE1_HANDOFF\.md\|PHASE2_HANDOFF\.md" README.md CONTRIBUTING.md docs/AUTH_FLOW.md docs/STATUS.md
```

Expected: every match is already prefixed with `docs/history/`; no bare filenames
that would resolve to the old (now-nonexistent) `supabase/` location remain

- [ ] **Step 3: Confirm move history followed correctly**

```bash
git log --follow --oneline docs/AUTH_FLOW.md | tail -5
git log --follow --oneline docs/history/TODO.md | tail -5
```

Expected: both show commits from before this branch (e.g. the Plan 5 merge commit or
earlier) — proof the renames preserved history rather than looking like brand-new
files

- [ ] **Step 4: Push the branch and open the PR into `dev`**

```bash
git push -u origin repo-reorg-docs
gh pr create --base dev --title "Repo reorg: docs/ tree, README, CONTRIBUTING, LICENSE, STATUS.md" --body "$(cat <<'EOF'
## Summary
- Moves every non-Supabase-CLI file out of supabase/ into docs/ (git mv, history preserved)
- Archives 5 stale/point-in-time docs under docs/history/ with a banner, content otherwise untouched
- Fixes docs/AUTH_FLOW.md's two cross-references that pointed at now-moved files
- Adds README.md, CONTRIBUTING.md, LICENSE (MIT), docs/STATUS.md, .github/pull_request_template.md

Spec: docs/superpowers/specs/2026-09-23-repo-reorg-and-contributor-docs-design.md
Plan: docs/superpowers/plans/2026-09-23-repo-reorg-and-contributor-docs.md

## Test plan
- [ ] `supabase db reset && supabase test db` passes (unaffected by this PR, confirmed as a sanity check)
- [ ] `git log --follow` on moved files shows pre-move history
- [ ] No bare-filename references to moved docs remain in the new/edited docs
EOF
)"
```

- [ ] **Step 5: Report the PR URL to the human partner**

No commit for this step — just confirm the PR opened successfully and share its URL.
