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

- `dev` gets PR'd into `main` periodically, once a chunk of work is stable. This is
  the model going forward — Plan 5 (the auth retirement) actually merged straight
  into `main` (PR #1), before this `dev` branch existed, so it predates this
  workflow rather than being an example of it.
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
