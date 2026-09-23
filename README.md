# Edutime

A backend for university lecture scheduling: cohorts see a shared, single source of
truth for what's happening and when, class reps schedule and manage it, and the
schedule survives lecturer no-shows and last-minute changes without falling back to
word-of-mouth. See [docs/DISCOVERY.md](docs/DISCOVERY.md) for the full problem
statement and target users.

## Stack

- **Database/Backend:** [Supabase](https://supabase.com) — Postgres 17, Auth
  (Google OAuth; Apple is configured in code but disabled), Row-Level Security,
  Realtime, Edge Functions (Deno/TypeScript)
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
favor of OAuth-only signup: everyone authenticates with Google OAuth, but university
emails auto-derive their student identity while personal emails need a class rep to
vouch for them at cohort-join time. See [docs/STATUS.md](docs/STATUS.md) for what's
shipped and what's next.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch workflow and testing
requirements.

## License

[MIT](LICENSE)
